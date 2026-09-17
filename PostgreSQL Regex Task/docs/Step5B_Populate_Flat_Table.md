# Step 5B — Populate the Flat Table

**Status:** `log_regex.access_log_flat` populated from accepted parser run **14** (12/09/2026).
- 5,000 rows, one per raw log.
- All verification passed: 57 load checks, structure checks S-01 … S-15, and the foreign-key check.
- **No mismatches.**

Stopped for review.

**Not done:** JSON/JSONB, PostGIS, indexes, performance work. Nothing outside `access_log_flat` changed: the digest of every
other `log_regex` function, view, column, constraint, index, guard trigger and table row is identical before and after
(`9dff2869f796a2142269078041329deb` over 160 items). The raw input and the parser logic are untouched.

---

## 1. Files

| File | Change |
|---|---|
| `sql/30_load_access_log_flat.sql` | **new** — the load: guard, preconditions, staging, precision rule, one `INSERT`, load gate, one transaction |
| `sql/31_verify_access_log_flat_load.sql` | **new** — read-only load verification, 57 checks (`LR009` on failure) |
| `sql/run_step5b_populate_flat_table.ps1` | **new** — runner: static checks, digest, `sql/30`, `sql/27`, `sql/29`, `sql/31`, digest; `-VerifyOnly` |
| `sql/29_verify_access_log_flat_structure.sql` | S-02 now accepts either 0 rows (created) or exactly one row per raw log from the source run (populated) |
| `docs/Step5B_Populate_Flat_Table.md` | this document |
| `docs/Step5B_Create_Flat_Table.md` | status line |
| `README.md` | status and Step 5B summary |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step5b_populate_flat_table.ps1"              # load + verify
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step5b_populate_flat_table.ps1" -VerifyOnly  # verify the loaded table
```

New SQLSTATEs:
- `LR007`: load refused, or load gate failed.
- `LR008`: coordinate precision rule rejection.
- `LR009`: load verification failed.

## 2. How the load works (`sql/30`, one transaction)

1. **Guard and preconditions (`LR007`).** The table must exist and be empty; the script never deletes or replaces rows.
   `verify_raw_access_logs()` must pass 10 / 10. Run 14 must be `succeeded`, implement exactly
   `{F1,F2,F3,F4,F5,NONE}`, have fingerprint checks before and after, and provide one classified `parsed_log` row and
   exactly the 10 `parsed_field` rows per raw log.
2. **Stage.** A temporary table (dropped at COMMIT) holds the complete rows: `parsed_log` + `parsed_field` pivoted by
   `field_name`, plus the typed columns.
3. **Coordinate precision rule (`LR008`, Step 5A §4.6).** Checked before the insert on the parsed notation:
   - decimal and hemisphere values: at most 7 decimal places
   - DMS seconds: at most 3 decimal places
   - no VALID value without a VAL-GEO notation

   Result: 0 rejections. Decimal and hemisphere forms had at most 7 places; DMS seconds at most 1.
4. **Publish.** One `INSERT INTO log_regex.access_log_flat … SELECT` from the stage. The foreign keys and the 22 CHECK
   constraints are enforced by the insert itself.
5. **Load gate (`LR007`), before COMMIT; any failure rolls everything back.** 5,000 rows for 5,000 raw logs from run 14.
   The 50 field columns match `parsed_field` exactly and the record columns match `parsed_log` (0 differences, both
   directions). The 47,374 stored values match `raw_log` exactly at their positions (0 mismatches).

Conversion rules as implemented (VALID values only; MISSING stays SQL NULL; INVALID and PLACEHOLDER keep their text
and get no typed value):

| Column(s) | Rule |
|---|---|
| `entity_type_code` | `upper(regexp_replace(entity_type, '[[:space:]_-]+', '_', 'g'))` |
| `event_timestamp_shape` | first `ref_timestamp_shape` (by `match_order`) whose pattern matches; every non-NULL value |
| `event_timestamp_local` | shape group map: year (year-less syslog: `assumed_year` 2026), month number or `ref_month_name`, day, hour, minute, seconds (0 when absent), ISO fraction (up to 6 digits).<br>12-hour: `hour % 12 + 12` for PM (12 AM → 00, 12 PM → 12).<br>Epoch: UTC wall clock |
| `event_timestamp_utc_offset` | `Z`/`z` → 0; ISO `±hh:mm` or Apache `±hhmm` → that offset; epoch → 0; otherwise NULL (no zone, or the `IST` abbreviation) |
| `event_timestamp_utc` | epoch: `to_timestamp(seconds)` or `to_timestamp(ms / 1000) + (ms % 1000) × 1 ms` (integer arithmetic); otherwise `(local - offset) AT TIME ZONE 'UTC'` when the offset is known |
| `latitude_degrees`, `longitude_degrees` | decimal: `value::numeric`<br>hemisphere prefix/suffix: the number, negative for `S`/`W`<br>DMS: `round((d·3600 + m·60 + s) / 3600, 7)`, negative for `S`/`W`<br>stored in `numeric(10,7)` |
| `ip_address_inet`, `ip_address_zone_id` | `split_part(ip_address, '%', 1)::inet`; `nullif(split_part(ip_address, '%', 2), '')` |
| `status_code`, `status_word` | `^[0-9]{3}( .+)?$` → the 3-digit code; otherwise `upper(status)` (the check mark is unchanged) |

The DMS pattern is VAL-GEO's own. It is written with `chr(176)`, `chr(8242)` and `chr(8243)` so the SQL files stay ASCII.

**Why one DMS rounding is exact.** With seconds of at most 3 decimals, the exact value is N / 3,600,000 for an integer
N. Such a value can never lie on a 7-place rounding boundary: the nearest one is at least 5.6 × 10⁻⁹ away. The finite
scale of `numeric` division (≥ 16 digits) therefore cannot change the rounded result. Check V-05n confirms this against
an oracle that divides separately at 30-digit scale.

## 3. Results for the 9 requested validations

| # | Requested | Checks | Result |
|---:|---|---|---|
| 1 | exactly 5,000 rows | V-01a–e, S-02 | 5,000 rows, 5,000 distinct `log_id`; 0 raw logs without a row; all from run 14; one `loaded_at` |
| 2 | all 4 foreign keys | `sql/27`, S-07, V-02a–e | FK 1–4 OK, validated, definitions and actions exact; 0 rows without a raw log, 0 without `parsed_log (run_id, log_id)`, 0 unknown entity codes, 0 unknown shapes |
| 3 | all CHECK constraints | V-03a, V-03b, S-08, S-09 | 22 validated; each stored CHECK expression re-evaluated on all 5,000 rows: **0 violations** (and the INSERT enforced them) |
| 4 | exact text/value correspondence | V-04a–f | 50,000 field rows: **0 differences** to `parsed_field` (value, validity, start_pos, source, missing_reason); 5,000 records: 0 differences to `parsed_log`. Answer key: **50,000 / 50,000 values**, 50,000 / 50,000 validity, 5,000 / 5,000 format + record validity |
| 5 | typed-column conversion rules | V-05a–v | all typed counts equal the VALID counts; 0 mismatches to every oracle (§4) |
| 6 | record validity counts | V-06a–c | VALID 4,750 · INVALID 238 · BROKEN 12, equal to `parsed_log` and the answer key; rule recomputed: 0 mismatches |
| 7 | field validity counts | V-07a–b | equal to `parsed_field` and the answer key for all 10 fields × 4 states (table below) |
| 8 | substring / position integrity | V-08a–c, load gate | 47,374 stored values; `substr(raw_log, start_pos, char_length(value)) = value` for all; 0 values outside the event scope or the raw text |
| 9 | no unexpected NULLs or values | V-09a–i, V-05v | see below |

**No unexpected NULLs or values (item 9):**
- **MISSING values:** 2,626 MISSING = 2,626 SQL NULL values = 2,626 NULL positions; 0 NULL values on non-MISSING fields.
- **Empty strings:** 0 empty-string values or sources.
- **Literal NULL tokens:** the 136 `NULL`/`null` tokens are kept as PLACEHOLDER text, not as SQL NULL.
- **Missing reasons:** absent 2,160 · empty 341 · sentinel 125; NULL sources 2,160 (= absent).
- **NONE rows:** NULL `sub_format` and NULL `event_end_pos` only on the 9 NONE rows. The record columns have no
  other NULLs.
- **Typed values:** 0 missing on VALID fields and 0 present on non-VALID fields.
- **Timestamps without an offset:** the 1,987 VALID timestamps without an offset are exactly the zone-less texts.

**Mismatches: none.**

Field validity (loaded table = parser run 14 = answer key):

| Field | VALID | INVALID | PLACEHOLDER | MISSING | Stored values |
|---|---:|---:|---:|---:|---:|
| entity_type | 4,634 | 18 | 42 | 306 | 4,694 |
| email_address | 4,544 | 58 | 109 | 289 | 4,711 |
| resource_url | 4,756 | 15 | 78 | 151 | 4,849 |
| event_timestamp | 4,928 | 62 | 0 | 10 | 4,990 |
| tool | 4,507 | 1 | 160 | 332 | 4,668 |
| latitude | 4,249 | 24 | 66 | 661 | 4,339 |
| longitude | 4,252 | 27 | 67 | 654 | 4,346 |
| ip_address | 4,948 | 38 | 1 | 13 | 4,987 |
| action_phrase | 4,987 | 0 | 0 | 13 | 4,987 |
| status | 4,701 | 12 | 90 | 197 | 4,803 |

## 4. Typed columns

| Column | Rows | Expected (Step 5A §4.4 / parser output) | Oracle check | Mismatches |
|---|---:|---:|---|---:|
| `entity_type_code` | 4,634 | 4,634 VALID | validator normalisation; `is_valid_entity_type()` true | 0 |
| `event_timestamp_shape` | 4,990 | 4,990 non-NULL | first matching shape recomputed | 0 |
| `event_timestamp_local` | 4,928 | 4,928 VALID | `to_timestamp` with each shape's format, ISO text cast, epoch interval arithmetic | 0 |
| — 12-hour subset | 345 | 345 | `to_timestamp(…, 'MM/DD/YYYY HH12:MI[:SS] AM')`; 12 AM → 00 (12 of 12), 12 PM → 12 (10 of 10) | 0 |
| `event_timestamp_utc_offset` | 2,941 | 2,941 | interval casts of `±hh:mm` / `±hhmm`; `Z` and epoch 0 | 0 |
| `event_timestamp_utc` | 2,941 | 2,941 | epoch: `extract(epoch)` = value (÷ 1000 for ms); ISO: timestamptz input; Apache: `to_timestamp(… TZHTZM)` | 0 |
| `latitude_degrees` | 4,249 | 4,249 VALID | separate numeric parse; decimal and hemisphere stored unrounded; DMS rounded once | 0 |
| `longitude_degrees` | 4,252 | 4,252 VALID | as latitude | 0 |
| `ip_address_inet` | 4,948 | 4,948 VALID | `inet` equality with `split_part(…, '%', 1)::inet`, never text; `is_valid_ip()` true | 0 |
| `ip_address_zone_id` | 1 | 1 (`eth0`) | text after `%` | 0 |
| `status_code` | 2,035 | 1,633 codes + 402 code + reason | first 3 digits | 0 |
| `status_word` | 2,666 | 2,665 words + 1 check mark | `upper(status)`; word in `ref_status_word` or the check mark | 0 |

Timestamps by shape (VALID):

| Shape | Values | With offset and instant |
|---|---:|---:|
| `iso8601` | 2,412 | 1,821 (`Z`/`z` 1,248; `±hh:mm` 573) |
| `apache_clf` | 880 | 880 |
| `syslog_rfc3164` | 621 | 0 |
| `us_mdy_12h` | 345 | 0 |
| `dmy_dash` | 292 | 0 |
| `epoch_seconds` | 132 | 132 |
| `epoch_milliseconds` | 108 | 108 |
| `ymd_slash` | 76 | 0 |
| `compact_basic` | 62 | 0 |

Examples from the table:

| Text | Typed value |
|---|---|
| `12/Mar/2026:13:49:32 +0800` | local `2026-03-12 13:49:32`, offset `08:00`, UTC `2026-03-12 05:49:32+00` |
| `1778283322860` | local `2026-05-08 23:35:22.86`, offset `00:00`, UTC `2026-05-08 23:35:22.86+00` |
| `02/18/2026 12:25:54 PM` | local `2026-02-18 12:25:54`, no offset |
| `51°33'05.8"N` / `0°05'29.4"W` | `51.5516111` / `-0.0915000` |
| `18° 31′ 13.4″ N` | `18.5203889` |
| `S33.90319` | `-33.9031900` |
| `fe80::1ff:fe23:4567:890a%eth0` | inet `fe80::1ff:fe23:4567:890a`, zone ID `eth0` |
| `2001:0db8:103e:…` | inet `2001:db8:103e:…` (equal as `inet`; shortened only in text output) |
| `192.168.037.068` (INVALID) | no `inet`, although the text is castable |
| `403` / `ok`-style word / check mark | code `403` / upper-case word / check mark |

## 5. Run log

| Step | Result |
|---|---|
| Read-only profile of run 14 | the value forms above confirmed before writing the load. The CHECK invariants already held on the parser output: 0 values beyond `event_end_pos`, 0 source/absent conflicts, 0 substring mismatches |
| Rolled-back harness, 1st attempt | load and gate passed, `sql/27` and `sql/29` passed; `sql/31` stopped with `record "r" is not assigned yet`: its PL/pgSQL loop variable `r` clashed with a query alias. Renamed to `chk`. Table still empty afterwards |
| Rolled-back harness, 2nd attempt | exit 0: load, gate, `sql/27`, `sql/29`, `sql/31` (57 checks) all passed inside the transaction, then `ROLLBACK`; table still empty |
| Runner (load) | exit 0 in 11 s: static checks, load, then `sql/27` PASSED, `sql/29` PASSED, `sql/31` PASSED (57 / 57). Digest unchanged. Static checks: `sql/07`/`sql/08` guards; Step 3B-3 runner guard; `sql/30` has exactly one `INSERT`, into `access_log_flat`, and no `DROP`/`TRUNCATE`/`DELETE`/`UPDATE`/`ALTER`/`COPY`/`CREATE INDEX`; files ASCII |
| `sql/30` again (read-only session) | exit 3: `refused: log_regex.access_log_flat already holds 5000 rows; this script never deletes or replaces rows` |
| Runner again without `-VerifyOnly` | exit 1 at step 2: `refused: … already holds 5000 rows; use -VerifyOnly to verify them` |
| Runner `-VerifyOnly` | exit 0: `sql/27`, `sql/29`, `sql/31` PASSED; digest unchanged |
| Final state | 5,000 rows, 6,432 kB; 1 index on the table (primary key); 24 indexes in `log_regex` (unchanged); `verify_raw_access_logs()` 10 / 10; extensions `plpgsql` only; 14 parser runs |

## 6. Notes

- **The foreign keys are now active.** `RESTRICT` refuses:
  - deleting raw logs or run-14 `parsed_log` rows
  - deleting parser run 14 (its `parsed_log` rows would cascade)
  - deleting a referenced entity code or timestamp shape
- **Refresh from a later run:** a deliberate, separate step. `sql/30` never replaces rows.
- **The `TRUNCATE … CASCADE` note** from [Step 5B creation](Step5B_Create_Flat_Table.md) §7 still applies.
