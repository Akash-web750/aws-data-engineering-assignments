# Step 3B-5 — F3 Parser (syslog header + JSON event)

**Status:** implemented and tested (12/09/2026). Stopped for review.

**Result:** all **9,850 / 9,850** F3 field values (985 rows × 10 fields) match the answer key in **value and
validity** — the C-05 target for F3. Detection is exact (985 true positives, 0 false positives, 0 format conflicts),
the syslog header and the JSON event are read separately, every value is the exact substring at its recorded
position, the JSON text is never cast to `json` / `jsonb`, NaN and truncated JSON follow the Step 2 rules, the
coordinate order follows C-03 for every container, runs are deterministic, and the raw input is unchanged.

**F1 and F2 unchanged:** the 2,520 F1 and F2 rows of the new run are identical to the Step 3B-4 run in `parsed_log`,
`parsed_field` and `parsed_secondary` (0 differing rows); F1 stays at 15,280 / 15,280 and F2 at 9,920 / 9,920.

**Not included:** F4 and F5 parsing, JSON/JSONB storage, PostGIS. The raw input table was not modified.

---

## 1. What was built

All objects are in database `postgresql_regex_task`, schema `log_regex`.

| Layer (Step 3A §2) | Object | Change in this step |
|---|---|---|
| L1 reference | `ref_key_alias` | 30 F3 rows added (28 primary key paths, 2 coordinate pairs); `ref_data_version` = `3B-5.1` |
| L2 parser, F3 | `f3_candidates` | new: header parser + forward-only regex scanner over the JSON text |
| L2 parser, shared | `detect_format` (+ DET-F3, `format_candidates` for all structural rules), `run_parser` (F3 candidates, event end, truncation, duplicate-alias kind) | changed in `sql/15` |
| L2 parser, F1 / F2 | `f1_candidates`, `f2_candidates` | unchanged |
| L3 output / L4 evaluation | tables and views | unchanged; earlier runs kept |

## 2. Files and how to run

| File | Purpose | Re-runnable |
|---|---|---|
| [sql/17_parser_reference_data_f3.sql](../sql/17_parser_reference_data_f3.sql) | F3 key paths in `ref_key_alias`, reference-data version | yes (replaces the F3 rows) |
| [sql/18_parser_f3.sql](../sql/18_parser_f3.sql) | `f3_candidates()`: syslog header, JSON scanner, key path → field | yes |
| [sql/15_parser_core.sql](../sql/15_parser_core.sql) | `detect_format()` with DET-F3, `run_parser()` for F1 + F2 + F3 (extended for F4 in Step 3B-6, see [Step3B6_F4_Parser.md](Step3B6_F4_Parser.md)) | yes |
| [sql/19_test_f3_parser.sql](../sql/19_test_f3_parser.sql) | Two parser runs, the F3 report, F1 + F2 regression, invariants and verdict | yes (adds two runs) |
| [sql/run_step3b5_f3_parser.ps1](../sql/run_step3b5_f3_parser.ps1) | Answer-key hash check, Step 3B-4 object check, then 17, 18, 15, 11, 19 | yes |
| [sql/run_step3b3_f1_parser.ps1](../sql/run_step3b3_f1_parser.ps1), [sql/run_step3b4_f2_parser.ps1](../sql/run_step3b4_f2_parser.ps1) | Changed: also install 17 and 18 before 15, because `run_parser()` now calls `f3_candidates()` | yes |

```powershell
# PGHOST, PGPORT, PGUSER, PGPASSWORD set in the environment
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b5_f3_parser.ps1"
```

The 3B-5 runner does not re-run `sql/07` or `sql/08`, so the Step 3B-4 run (formats `{F1,F2}`) stays in `parser_run`
as the regression baseline. The two older runners were updated but not re-run in this step; re-running the 3B-3
runner would drop all earlier runs.

A parser run on its own: `SELECT log_regex.run_parser('3B-5 F1+F2+F3 v1');` (returns the `run_id`).

---

## 3. How the F3 parser works

### 3.1 Detection (S0/S1)

| Order | Rule | Condition | Result |
|---:|---|---|---|
| 0 | DET-00 | `raw_log` NULL, empty or whitespace only | NONE |
| 2 | DET-F3 | Anywhere in `raw_log`: `{` followed, across optional whitespace or newlines, by `"` | F3 |
| 3 | DET-F1 | At least two `key=` segments on the event line | F1 (unchanged) |
| 5 | DET-F2 | Fallback: no structural rule matched and at least two sentence cues | F2 (unchanged) |
| — | DEFERRED | F4 (order 1), F5 (order 4) and DET-NONE are not implemented yet | no field rows |

DET-F3 is tested on the whole text (EC-144 opens `{` on line 1 and continues on line 2) and takes priority over
DET-F1, as in Step 3A §4.2. `format_candidates` now lists every structural rule that matched; more than one would add
the diagnostic `format_conflict`. No row of another format contains `{"`, so there are 0 conflicts and F1 rows keep
`format_candidates = {DET-F1}`.

### 3.2 Header and JSON event are parsed separately (S2/S3)

The JSON event starts at the first `{` followed by `"`. The header is only the text before it:

| Header (`sub_format`) | Pattern on the header text | Timestamp (slot) | Rows |
|---|---|---|---:|
| RFC 5424 (`rfc5424`) | `<PRI>1 TIMESTAMP HOST APP PROCID MSGID SD` — 5 space-separated fields, then `-` or `[…]` | 2nd token (`F3.header.rfc5424`) | 358 |
| RFC 3164 (`rfc3164`) | `Mon dd HH:MM:SS HOST TAG:` — the space-padded day is kept (`Jan  9`) | `Mon dd HH:MM:SS` (`F3.header.rfc3164`) | 627 |

Host, application and process id are recognised but not extracted (they are not target fields). No field other than
the timestamp is ever taken from the header, and the timestamp is never taken from the JSON.

**Event scope:** from the start of `raw_log` to the closing brace of the top-level JSON object, or to the end of the
text if it never closes. The scanner reports that position, and `run_parser()` stores it as `event_end_pos`.

### 3.3 Regex-only JSON scanner (S3)

`f3_candidates()` moves one cursor forward through the JSON text. At each position a regular expression anchored with
`^` recognises exactly one token:

| Token | Pattern idea |
|---|---|
| String | `"` then any run of non-quote/non-backslash characters or backslash + any character, then `"` (escapes kept verbatim) |
| Unclosed string | `"` with no closing quote before the end of the text ⇒ value = the rest of the text, diagnostic `truncated` |
| Bare token | number (`-?digits[.digits][e±digits]`), `NaN`, `null`, `true`, `false` |
| Structure | `{`, `}`, `[`, `]`, `:`, `,`; spaces, TAB, CR and LF between tokens are skipped (EC-144) |

A container stack gives every scalar a **key path**: `user`, `geo.lat`, `geometry.coordinates[1]` (0-based array
index). No value is converted to a JSON data type; values are the characters between the quotes, or the bare token as
written (`-0.1278`, `403`, `NaN`, `null`).

### 3.4 Key path → field (`ref_key_alias`, F3)

| Field | Key paths |
|---|---|
| entity_type | `entity_type`, `entity`, `principal_type` |
| email_address | `user`, `principal`, `email` |
| resource_url | `resource`, `target`, `res` |
| tool | `tool`, `user_agent`, `client` |
| ip_address | `src_ip`, `ip`, `remote_addr` |
| action_phrase | `msg`, `event`, `action` |
| status | `status`, `result`, `outcome`, `http_status` (string or number) |
| latitude | `latitude`, `geo.lat`, `geometry.coordinates[1]`, `location` (1st part) |
| longitude | `longitude`, `geo.lng`, `geometry.coordinates[0]`, `location` (2nd part) |

**Coordinate order (C-03):** labelled keys (`latitude`, `geo.lat`, …) are used as labelled; GeoJSON
`geometry.coordinates` is `[longitude, latitude]`; the unlabelled `location` string `"lat,lon"` is latitude-first.
`geo` and `location` are `coordinate_pair` rows: a scalar is split at the first comma, and a token without a comma
(`"geo":null`) applies to both axes.

Other rules:

- Several aliases for one field: the first in document order is primary (C-01). The later one becomes a secondary
  value whose kind is its JSON key — EC-128 `"status":401` then `"result":"FAILED"` ⇒ status `401`, secondary
  `result=FAILED`.
- A top-level key outside the alias list with an e-mail-shaped string is a secondary `<key>_email` (EC-022 `notify`).
- Other keys (`level`, `geometry.type`) are ignored.

### 3.5 Value state, truncation and validation (S5–S7)

| Order | Rule | F3 result |
|---:|---|---|
| VS-1 | Key path absent | MISSING, `missing_reason` absent |
| VS-2 | Empty string `""` | MISSING, `missing_reason` empty (none in F3) |
| VS-4 | Value `null` (bare JSON null) | PLACEHOLDER |
| VS-5 | Truncated row: the last extracted value | INVALID, `rule_id` `VS-5 truncated (unclosed JSON)` |
| VS-6 | Field validators unchanged; exact Step 3B-2 IP rule; `NaN`, out-of-range and bad dates INVALID | VALID / INVALID |

**Truncation (Step 3A §10.3, Step 2 AMB-15):** a string, object or array still open at the end of the text sets
`is_truncated`. The value cut off inside its string is extracted as far as it goes and is INVALID. Fields after it do
not exist in the text and are MISSING. `record_validity` = BROKEN. F1 keeps its C-06 rule and the rule label
`VS-5 truncated (C-06)`.

**Record validity:** BROKEN if truncated, INVALID if any field is INVALID, otherwise VALID.

---

## 4. Results

PostgreSQL 17.9; two parser runs (A = run 7, B = run 8) on identical input: 12.82 s and 12.72 s for all 5,000 rows
(Step 3B-4 with F1 + F2: about 6 s).

### 4.1 Detection (all 5,000 rows)

| Answer key | Parsed | Rule | Rows |
|---|---|---|---:|
| F1 | F1 | DET-F1 | 1,528 |
| F2 | F2 | DET-F2 | 992 |
| F3 | F3 | DET-F3 | 985 |
| F4 / F5 | deferred | — | 986 / 500 |
| NONE | deferred / NONE | — / DET-00 | 5 / 4 |

F3: 985 true positives, **0 false positives**, 0 false negatives. F1 and F2 detection unchanged (0 errors).
`format_conflict`: 0.

### 4.2 Output shape and positions (run B)

| Check | Result |
|---|---|
| `parsed_log` rows / raw rows without one | 5,000 / 0 |
| F1 / F2 / F3 / DET-00 / deferred logs | 1,528 / 992 / 985 / 4 / 1,491 |
| `parsed_field` rows; parsed logs without exactly 10 fields | 35,090; 0 |
| Field values equal to `substr(raw_log, start_pos, length)` | 33,113 / 33,113 |
| Secondary values equal to their substring | 177 / 177 |
| Overlapping value spans in one F3 log (a single token read for both axes excepted) | 0 |

### 4.3 Per-field accuracy on all F3 rows

| Field | Rows | Value match | Validity match | Both |
|---|---:|---:|---:|---:|
| entity_type | 985 | 985 | 985 | 985 |
| email_address | 985 | 985 | 985 | 985 |
| resource_url | 985 | 985 | 985 | 985 |
| event_timestamp | 985 | 985 | 985 | 985 |
| tool | 985 | 985 | 985 | 985 |
| latitude | 985 | 985 | 985 | 985 |
| longitude | 985 | 985 | 985 | 985 |
| ip_address | 985 | 985 | 985 | 985 |
| action_phrase | 985 | 985 | 985 | 985 |
| status | 985 | 985 | 985 | 985 |
| **All fields** | **9,850** | **9,850** | **9,850** | **9,850 (100.00%)** |

Mismatches: none.

### 4.4 Validity distribution on F3 rows (answer key = parser in every cell)

| Field | VALID | INVALID | PLACEHOLDER (`null`) | MISSING |
|---|---:|---:|---:|---:|
| entity_type | 909 | 4 | 19 | 53 |
| email_address | 895 | 11 | 16 | 63 |
| resource_url | 950 | 3 (1 truncated) | 9 | 23 |
| event_timestamp | 976 | 9 | 0 | 0 |
| tool | 885 | 0 | 26 | 74 |
| latitude | 859 | 3 | 20 | 103 |
| longitude | 871 | 4 | 20 | 90 |
| ip_address | 977 | 7 | 0 | 1 |
| action_phrase | 984 | 0 | 0 | 1 (EC-135) |
| status | 948 | 0 | 9 | 28 |

All MISSING values are `absent` (VS-1).

### 4.5 By header type and source

| Group | Logs | Field values | Both match | Logs with a mismatch |
|---|---:|---:|---:|---:|
| rfc3164 | 627 | 6,270 | 6,270 | 0 |
| rfc5424 | 358 | 3,580 | 3,580 | 0 |
| curated | 15 | 150 | 150 | 0 |
| generated | 970 | 9,700 | 9,700 | 0 |

**Record validity:** BROKEN 1 = 1 (EC-135, `is_truncated`), INVALID 37 = 37, VALID 947 = 947.

### 4.6 Header / JSON separation and event scope

| Check | Result |
|---|---|
| Timestamps taken from the header (627 `rfc3164`, 358 `rfc5424`) | 985 / 985 |
| JSON fields whose position lies inside the header | 0 |
| Secondary values inside the header | 0 |
| `sub_format` disagreeing with the header shape | 0 |
| Closed events ending at `}` / at the end of the text | 984 / 984 |
| Truncated events ending at the end of the text | 1 / 1 |
| Multi-line events (EC-144) reaching past the first line | 1 |

### 4.7 NaN, truncated and pretty-printed JSON

| Case | Raw form | Parsed |
|---|---|---|
| GEN-02944 | `geo` object with only `lng`, value `NaN` | longitude `NaN` INVALID (`F3.key.geo.lng`); latitude MISSING |
| GEN-04209 | `location` string `NaN,NaN` | latitude `NaN` INVALID, longitude `NaN` INVALID |
| EC-135 | `…"resource":"https://sso.exam` (text ends) | entity `user`, email VALID; resource `https://sso.exam` INVALID (VS-5); timestamp VALID; tool, coordinates, IP, action, status MISSING; `is_truncated`, `event_end_pos` 121 = length, diagnostic `truncated`, BROKEN |
| EC-144 | JSON over 10 lines, spaces after `:` and `,` | all 10 fields VALID; values on lines 2–9 at exact positions (e.g. `geo.lat` 271 and `geo.lng` 287 on line 7); `event_end_pos` 344 = the final `}` |

### 4.8 Coordinate order by container (C-03)

| Container | Latitude (both match) | Longitude (both match) |
|---|---:|---:|
| `geo` object `{lat, lng}` | 359 / 359 | 372 / 372 |
| `latitude` / `longitude` keys | 219 / 219 | 219 / 219 |
| `location` string `"lat,lon"` | 152 / 152 | 152 / 152 |
| GeoJSON `geometry.coordinates [lon, lat]` | 132 / 132 | 132 / 132 |
| `"geo":null` (both axes PLACEHOLDER) | 20 / 20 | 20 / 20 |
| absent | 103 / 103 | 90 / 90 |

In the 132 GeoJSON rows the first array element never equals the answer-key latitude (0 / 132). Reading the pair
latitude-first there would swap every value; the parser reads element `[1]` as latitude and is correct in 132 / 132.

### 4.9 No JSON data types

- The source of every function in `log_regex` (20) was searched for casts to `json`/`jsonb` and JSON
  functions: **0**.
- Table columns of type `json`/`jsonb` in `log_regex`: **0**.

### 4.10 Secondary values (informational; not part of C-05)

983 / 985 F3 logs have exactly the answer key's secondary set: `ip_like_in_resource` 32, `notify_email` 1 (EC-022),
`result` 1 (EC-128). The two differences are answer-key annotations, not extracted values:

- EC-005 `status_word_in_resource=status=open`
- EC-036 `date_in_resource=2026-02-07`

EC-036 is the same kind as the informational F1 difference EC-002 (Step 3B-3). Diagnostics on F3 rows:
`duplicate_field:status` (EC-128) and `truncated` (EC-135).

### 4.11 Key path usage (run B)

| Field | Key paths (values) |
|---|---|
| entity_type | `entity_type` 465 · `entity` 297 · `principal_type` 170 |
| email_address | `user` 385 · `principal` 375 · `email` 162 |
| resource_url | `resource` 579 · `target` 192 · `res` 191 |
| tool | `tool` 443 · `user_agent` 267 · `client` 201 |
| ip_address | `src_ip` 498 · `ip` 255 · `remote_addr` 231 |
| action_phrase | `msg` 575 · `event` 258 · `action` 151 |
| status | `status` 377 · `result` 305 · `outcome` 147 · `http_status` 128 |

### 4.12 F1 + F2 regression (run B vs Step 3B-4 run 6)

| Comparison on the 2,520 F1 and F2 logs | Rows only in baseline | Rows only in run B |
|---|---:|---:|
| `parsed_log` | 0 | 0 |
| `parsed_field` (25,200 rows each) | 0 | 0 |
| `parsed_secondary` | 0 | 0 |

Accuracy in the new run: F1 15,280 / 15,280, F2 9,920 / 9,920.

### 4.13 Determinism and integrity

- Run A vs run B: 0 differing rows in all three output tables; equal row counts.
- `verify_raw_access_logs()`: 10 / 10 before and after both runs.
- Step 1 files: `generate_raw_logs.py --check` reports all three files identical; dataset digest
  `1bcff42a6cd6634bd722064b629a0088dbbd7c67ac5276d013c505ac3fb06275` unchanged.
- All new and changed SQL / PowerShell files are ASCII.

---

## 5. Issues found while implementing

| Issue | Fix |
|---|---|
| Rewriting `sql/15` again put literal NBSP characters into the two detection regexes, and shortened the F1 truncation label to `VS-5 truncated` (which would have changed EC-134) | Found by the pre-run script before any database run: regexes restored with `\u00A0` escapes, F1 label kept as `VS-5 truncated (C-06)`, F3 label `VS-5 truncated (unclosed JSON)` added. The first test run then passed |

`parser_run` now holds runs 1–2 (Step 3B-3, `{F1}`), 3–6 (Step 3B-4, `{F1,F2}`) and 7–8 (Step 3B-5, `{F1,F2,F3}`). The
evaluation views use the latest successful run (8).

## 6. Choices made in this step (for review)

1. **DET-F3 tested on the whole text before DET-F1:** all structural matches are stored in `format_candidates`, and
   a conflict is flagged. DET-F4 (Step 3A order 1) will be placed before it when F4 is implemented; no F4 row contains
   `{"` today.
2. **Key paths as alias names** (`geo.lat`, `geometry.coordinates[1]`) keep the coordinate-order rule in reference
   data rather than code. GeoJSON is read as `[longitude, latitude]` regardless of `geometry.type` (all 132 are
   `Point`).
3. **Demoted alias kind = JSON key:** a later duplicate is stored as secondary `result=FAILED`, matching the answer
   key. It is implemented by carrying the key in the candidate's `secondary_kind`. F1/F2 candidates carry none, so
   their kind stays `duplicate_<field>` (no such rows exist).
4. **Truncation label:** F3 truncation uses `VS-5 truncated (unclosed JSON)`; the rule itself (last value INVALID,
   later fields MISSING, BROKEN) is the shared VS-5 step.
5. **Non-alias e-mail-shaped keys** become `<key>_email` secondary values at the top level only.
6. **Header fields** other than the timestamp (host, app, pid, msgid) are not stored.
7. **Runtime:** the character-level scanner in PL/pgSQL doubled the run time (about 6 s → 12.8 s for 5,000 rows);
   performance work is a later part of the project.
