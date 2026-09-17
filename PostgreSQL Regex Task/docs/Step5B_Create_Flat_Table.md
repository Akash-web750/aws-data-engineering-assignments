# Step 5B — Create the Flat Table

**Status:** `log_regex.access_log_flat` created in `postgresql_regex_task` (12/09/2026) with **0 rows** and verified
with read-only checks. It has since been **populated** from run 14; see
[Step 5B population](Step5B_Populate_Flat_Table.md). The results below describe the table as created.

**Inputs**
- [Step 5A design](Step5A_Flat_Schema_Design.md): Appendix A DDL with the Step 5A review corrections.
- Accepted source run **14** ([Step 4A](Step4A_Parser_Validation_Report.md)).

**Not done in this step:**
- loading rows and load verification
- JSON/JSONB
- PostGIS
- secondary indexes

Nothing outside the new objects changed. A digest of every other `log_regex` function, view, column, constraint,
index, guard trigger and table row is identical before and after (§6.2).

---

## 1. Files

| File | Change |
|---|---|
| `sql/28_create_access_log_flat.sql` | **new** — the only write: install guard, preconditions, the Step 5A DDL, comments, post-condition, one transaction |
| `sql/29_verify_access_log_flat_structure.sql` | **new** — read-only structural verification S-01 … S-15 (`LR006` on failure) |
| `sql/run_step5b_create_flat_table.ps1` | **new** — runner: static guard checks, digest, `sql/28`, `sql/27`, `sql/29`, digest; `-VerifyOnly` |
| `sql/27_verify_access_log_flat_foreign_keys.sql` | unchanged (Step 5A review); run by the runner after creation |
| `docs/Step5A_Flat_Schema_Design.md` | status line; Appendix A zone-ID CHECK line (§4) |
| `docs/Step5B_Create_Flat_Table.md` | this document |
| `README.md` | status and Step 5B summary |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step5b_create_flat_table.ps1"              # create + verify
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step5b_create_flat_table.ps1" -VerifyOnly  # verify an existing table
```

New SQLSTATEs:
- `LR005`: `sql/28` precondition or post-condition failed.
- `LR006`: `sql/29` structural verification failed.

## 2. What was created

| Object | Details |
|---|---|
| Domains (3) | `log_regex.field_validity_status` (`VALID`, `INVALID`, `PLACEHOLDER`, `MISSING`), `log_regex.record_validity_status` (`VALID`, `INVALID`, `BROKEN`), `log_regex.missing_reason_code` (`absent`, `empty`, `sentinel`). Each is over `text`, nullable, with one CHECK |
| Table | `log_regex.access_log_flat`: 71 columns in the Step 5A §4.5 order, 18 NOT NULL, defaults `loaded_at now()` and `diagnostics '{}'`; owner `postgres`; **0 rows** |
| Primary key | `access_log_flat_pkey (log_id)`; its unique btree index is the table's **only index** |
| Foreign keys (4) | see below; all validated |
| CHECK constraints (22) | 6 record classification, 10 per-field state, 6 typed-column; all validated |
| Comments (16) | table, 3 domains, `run_id` and the 11 typed columns (each typed column's comment records its derivation rule) |
| Internal triggers | PostgreSQL's referential-integrity triggers only: 8 on `access_log_flat`, plus 2 on each referenced table (`raw_access_logs` now 8 internal + its 1 guard trigger; `parsed_log` 10; `ref_entity_type` 2; `ref_timestamp_shape` 2). No user triggers |

Foreign keys as stored in the catalog:

| # | Constraint | Definition |
|---:|---|---|
| 1 | `access_log_flat_raw_log_fkey` | `FOREIGN KEY (log_id) REFERENCES log_regex.raw_access_logs(log_id) ON UPDATE RESTRICT ON DELETE RESTRICT` |
| 2 | `access_log_flat_parsed_log_fkey` | `FOREIGN KEY (run_id, log_id) REFERENCES log_regex.parsed_log(run_id, log_id) ON UPDATE RESTRICT ON DELETE RESTRICT` |
| 3 | `access_log_flat_entity_type_code_fkey` | `FOREIGN KEY (entity_type_code) REFERENCES log_regex.ref_entity_type(entity_type)` |
| 4 | `access_log_flat_event_timestamp_shape_fkey` | `FOREIGN KEY (event_timestamp_shape) REFERENCES log_regex.ref_timestamp_shape(shape_name)` |

CHECK constraints:
- **Record classification (6):** `format_family`, `detection_rule`, `event_end_pos`, `sub_format`, `none_rows`,
  `record_validity_rule`.
- **Per-field state (10):** `<field>_state` for each of the 10 fields.
- **Typed columns (6):** `entity_type_code`, `event_timestamp_typed`, `latitude_degrees`, `longitude_degrees`,
  `ip_address_typed`, `status_typed`.

All names carry the prefix `access_log_flat_`.

## 3. How the Step 5A decisions are implemented

A table can enforce only rules that are decidable within one row. Each typed-column derivation is enforced when rows
are loaded, and its rule is recorded in the column comment. None of those derivations has been exercised yet: the
table is empty.

| Decision | In the table now | Applied and verified at load (next step) |
|---|---|---|
| Entity normalisation | `entity_type_code text`, FK → `ref_entity_type`; CHECK: code present exactly for VALID; rule in the column comment | `upper(regexp_replace(entity_type, '[[:space:]_-]+', '_', 'g'))`, and `is_valid_entity_type()` true for every coded row |
| IP: `inet` + zone ID | `ip_address_inet inet`, `ip_address_zone_id text`; CHECK: inet exactly for VALID, host mask (/32 or /128), zone ID non-empty and only with a non-NULL IPv6 inet (§4) | `ip_address_inet = split_part(ip_address, '%', 1)::inet` compared as `inet`, never as text; zone ID = text after `%` |
| Timestamps | `event_timestamp_shape text` FK → `ref_timestamp_shape`; `event_timestamp_local timestamp(6)`; `event_timestamp_utc_offset interval`; `event_timestamp_utc timestamptz(6)`. CHECK: local exactly for VALID; offset ⇔ instant; offset within ±14 h and only with a local value; shape only with a value | shape group maps; assumed year 2026; epoch as UTC; **12 AM → 00, 12 PM → 12**; instant = `(local - offset) AT TIME ZONE 'UTC'`; NULL offset without a stated zone |
| Coordinates `numeric(10,7)` | `latitude_degrees`, `longitude_degrees numeric(10,7)`; CHECK: present exactly for VALID, within ±90 / ±180 | DMS computed exactly and rounded once to 7 places; load **rejects** values with more than 7 decimal places (DMS seconds: more than 3) |
| MISSING / INVALID / PLACEHOLDER | validity domains; per-field state CHECKs:<br>• MISSING ⇔ NULL value ⇔ NULL position ⇔ missing reason<br>• source NULL ⇔ `absent`<br>• no `''`<br>• value within the event scope<br>Also: NONE rows all MISSING; record-validity rule | values copied from `parsed_field`; exact substring at each position (47,374 values) |
| CHECK constraints | the 22 constraints of §8 of the design, all validated; semantics proven with 212 probe rows (§6.3, S-09) | — |
| Four foreign keys | created and validated; `sql/27` PASSED | `sql/27` again after the load |
| Rebuild / drop guards | `sql/07` and `sql/08` refuse (`LR003`), shown against the real table; the Step 3B-3 runner refuses; `sql/28` never drops and refuses (`LR003`) when any of its objects exists | — |

## 4. Correction found during implementation: the zone-ID CHECK

The Appendix A sketch wrote the zone-ID rule as:

```sql
AND (ip_address_zone_id IS NULL OR (ip_address_zone_id <> '' AND family(ip_address_inet) = 6))
```

The rule is meant for a zone ID stored on a non-VALID address. There `ip_address_inet` is NULL, so `family()` returns NULL
and the whole CHECK evaluates to NULL. PostgreSQL rejects only FALSE, so it accepts that row. The sketch therefore
allowed a zone ID on an INVALID address, contrary to the §8 rule "zone ID only with IPv6". Implemented form (Appendix A
updated to match):

```sql
AND (ip_address_zone_id IS NULL OR (ip_address_zone_id <> '' AND ip_address_inet IS NOT NULL AND family(ip_address_inet) = 6))
```

**Evidence** (two rolled-back harness runs of `sql/28` followed by `sql/29` in the same transaction):
- **Sketch form:** S-09 FAIL. Exactly 1 of 212 probes differed: "zone ID on an INVALID IP without inet" expected
  `ip_address_typed` to reject and nothing rejected.
- **Corrected form:** 212 / 212 probes as expected.

The probes also cover the NULL behaviour of the other 21 CHECKs; none showed a similar gap.

This is the only change to the design DDL. The DDL block of `sql/28` (between `-- BEGIN Step 5A DDL` and
`-- END Step 5A DDL`) matches the updated Appendix A token for token (1,234 / 1,234 tokens).

## 5. Safety of the creation script

| Safeguard | Behaviour |
|---|---|
| Install guard | inside the transaction, before any DDL: raises `LR003` if `access_log_flat` or any of the three domains exists. No `DROP`, no `CREATE OR REPLACE`, no `IF NOT EXISTS` |
| Preconditions (`LR005`) | `verify_raw_access_logs()` 10 / 10.<br>Source run: succeeded, formats exactly `{F1,F2,F3,F4,F5,NONE}`, fingerprint checks before and after.<br>One `parsed_log` row with format and record validity per raw log; 10 `parsed_field` rows per raw log.<br>`ref_entity_type` = the 7 codes; `ref_timestamp_shape` = the 9 shapes |
| Run 14 result | raw input 10 / 10; run 14 `3C combined v1`, succeeded, fingerprints t / t; 5,000 `parsed_log` and 50,000 `parsed_field` rows for 5,000 raw logs; run 14 is also the latest accepted all-format run |
| One transaction | `lock_timeout` 10 s; a post-condition before `COMMIT` requires 71 columns, 0 rows, 1 index and constraints `c=22 f=4 p=1`, otherwise everything rolls back |
| Statement check | the runner confirms `sql/28` contains no `DROP`, `TRUNCATE`, `DELETE`, `INSERT`, `UPDATE`, `ALTER` or `COPY` statement |

## 6. Verification

All verification sessions except the harness runs and the `sql/28` creation ran with
`default_transaction_read_only = on`, inside transactions that were rolled back.

### 6.1 Before creating: rolled-back harness

| Check | Result |
|---|---|
| Encoding | `sql/27`, `sql/28`, `sql/29` and the runner: 0 non-ASCII bytes |
| DDL versus design | `sql/28` DDL = Appendix A (1,234 tokens, identical) |
| Harness 1 (implemented DDL) | preconditions passed; `sql/27` FK 1–4 OK, PASSED; `sql/29` S-01 … S-15 PASSED; `ROLLBACK`; exit 0 |
| Harness 2 (sketch zone-ID line) | S-09 FAIL on exactly the one zone-ID probe (§4); exit 3 |
| State afterwards | `access_log_flat` absent, 0 `log_regex` domains, `raw_access_logs` internal triggers still 6 |

### 6.2 Runner: `sql/run_step5b_create_flat_table.ps1` (exit 0, 7 s)

| Step | Result |
|---|---|
| 1. Static guards | `sql/07` guard ends at character 1,387, before `BEGIN` (1,417) and `DROP` (1,425). `sql/08` guard ends at 1,492, before `BEGIN` (1,522) and `DROP` (1,530). The Step 3B-3 runner queries and refuses before any other database call. `sql/28` has no forbidden statements. The files are ASCII |
| 2. State | required objects present; `access_log_flat` absent |
| 3. Digest before | `9dff2869f796a2142269078041329deb` over 160 items (functions, views, columns, constraints, indexes, guard triggers, rows of every other table) |
| 4. `sql/28` | preconditions passed; 3 × `CREATE DOMAIN`, `CREATE TABLE`, 16 × `COMMENT`; `COMMIT`; summary: 71 columns, 1 primary key, 4 foreign keys, 22 CHECKs, 1 index, 0 rows |
| 5. `sql/27` | FK 1 … 4 OK; "exactly the 4 expected foreign keys, all validated" |
| 6. `sql/29` | S-01 … S-15 PASSED (§6.3) |
| 7. Digest after | `9dff2869f796a2142269078041329deb` over 160 items — unchanged |

### 6.3 Structural verification (`sql/29`)

| Check | Result |
|---|---|
| S-01 | ordinary permanent table (`relkind r`, `relpersistence p`), not partitioned, no inheritance, row security off, owner `postgres` |
| S-02 | 0 rows |
| S-03 | 3 domains over `text`, nullable, no default, exactly one validated CHECK each whose definition lists exactly the allowed values; 24 / 24 cast probes as expected (10 allowed values accepted; 14 look-alikes such as `valid`, `MISSING `, `broken`, `ABSENT`, `''` rejected) |
| S-04 | 71 columns match the design in order, name, type, NOT NULL (18) and default (2); types include `timestamp(6) without time zone`, `timestamp(6) with time zone`, `interval`, `numeric(10,7)`, `inet`, `smallint` |
| S-05 | no JSON/JSONB, `geometry`/`geography` or extension-owned column types; extensions: `plpgsql` only |
| S-06 | primary key `access_log_flat_pkey (log_id)`, validated |
| S-07 | exactly the 4 foreign keys by name, all validated (definitions by `sql/27`) |
| S-08 | exactly the 22 CHECK constraints of the design, all validated; no unique, exclusion or constraint triggers |
| S-09 | 212 probe rows (3 base rows, 59 targeted probes, 15 state probes × 10 fields) evaluated with the stored CHECK expressions; each violates exactly the expected CHECKs, and each of the 22 CHECKs rejects at least one probe. Probes include boundaries (±90, ±180, ±14:00, codes 100/599), just-outside values and NULL cases |
| S-10 | exactly 1 index: `access_log_flat_pkey` (btree, unique, `log_id`) |
| S-11 | 0 user triggers; each foreign key has 2 enabled internal triggers on the table (8) and 2 on its referenced table |
| S-12 | no views, rules or policies on the table; the domains are used by 21 columns, all in `access_log_flat` |
| S-13 | the comments on the table, the domains, `run_id` and the 11 typed columns contain the Step 5A rules (entity normalisation, 12-hour rule, `inet` + zone ID, precision rule, …) |
| S-14 | `verify_raw_access_logs()` 10 / 10; `raw_access_logs` keeps its 1 guard trigger |
| S-15 | source run 14 still accepted: succeeded, `{F1,F2,F3,F4,F5,NONE}`, 5,000 `parsed_log` and 50,000 `parsed_field` rows for 5,000 raw logs |

### 6.4 Refusal tests against the real table (read-only sessions)

| Test | Result |
|---|---|
| `sql/28` run again | exit 3: `LR003 … log_regex.access_log_flat, log_regex.field_validity_status, log_regex.missing_reason_code, log_regex.record_validity_status already exists; this script never drops or replaces objects` |
| exact guard block of `sql/07` | exit 3: `LR003 sql/07_parser_reference_data.sql refused: log_regex.access_log_flat exists; DROP ... CASCADE would silently remove its foreign keys` |
| exact guard block of `sql/08` | exit 3: `LR003 sql/08_parser_output_tables.sql refused: … its foreign keys and the runs it references` |
| Step 3B-3 runner guard query | returns `t`, so the runner refuses (it proceeds only on `f`) |
| Step 5B runner again (no `-VerifyOnly`) | exit 1 at step 2: `refused: log_regex.access_log_flat already exists; use -VerifyOnly to verify it` |
| Step 5B runner `-VerifyOnly` | exit 0: `sql/27` PASSED, `sql/29` PASSED, digest unchanged (`9dff2869…` over 160 items) |

The complete `sql/07` and `sql/08` scripts were not executed: only their exact guard blocks. The guard runs first in
each script, before `BEGIN` and `DROP` (static check, §6.2).

### 6.5 Problem during the run

The first runner attempt stopped at step 3 (digest query), before any write: `collation "c" for encoding "UTF8" does
not exist`.

- **Cause:** Windows PowerShell 5.1 removes embedded double quotes from arguments passed to native programs, so
  `COLLATE "C"` reached psql as `COLLATE C`, which is folded to lower case.
- **State afterwards:** a read-only check confirmed the table and domains were absent.
- **Fix:** the runner's inline queries use the built-in collation `ucs_basic` (code-point order, no quotes needed).
  `sql/28` and `sql/29` are run with `-f` and are not affected.

The second attempt passed.

## 7. Notes and remaining risks

- **The foreign keys protect nothing until rows exist.** Once loaded, `RESTRICT` refuses:
  - deleting or re-keying a referenced raw log or `parsed_log` row
  - deleting parser run 14, whose `parsed_log` rows would otherwise cascade
  - deleting a referenced reference code
- **`TRUNCATE … CASCADE` is not covered by the guards.** Truncating `parser_run`, `parsed_log`, `ref_entity_type` or
  `ref_timestamp_shape` with `CASCADE` would also empty `access_log_flat`. Foreign-key actions do not block `TRUNCATE`,
  and PostgreSQL only issues a NOTICE. No project script truncates these tables. `raw_access_logs` cannot be truncated
  (guard trigger, `LR001`). A plain `TRUNCATE` without `CASCADE` fails because of the foreign keys. This case is outside
  the Step 5A design.
- **A deliberate `DROP TABLE log_regex.access_log_flat` is not blocked.** The guards stop collateral removal by rebuild
  scripts, not an explicit decision. After such a drop, `sql/28` still refuses while the three domains exist.

## 8. Next step (not started)

Populate `access_log_flat` from run 14 and verify the load, following Step 5A §4.6 and §10:
- round trip to `parsed_field`
- exact positions
- answer key 50,000 / 50,000
- typed counts, including 12-hour, `inet` and entity-code checks
- the precision rule
- `sql/27` and `sql/29` again (S-02 will then expect 5,000 rows)
