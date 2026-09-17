# Step 3B-7 — F5 Parser (semicolon-positional export)

**Status:** implemented and tested (12/09/2026). Stopped for review.

**Result:** all **5,000 / 5,000** F5 field values (500 rows × 10 fields) match the answer key in **value and
validity** — the C-05 target for F5.

- Detection is exact: 500 true positives, 0 false positives, 0 format conflicts. The 9-semicolon header row EC-138 is
  not F5, and no truncated or padded F5-like row exists.
- Every F5 line is rebuilt exactly from its 10 extracted columns, and every value is the exact substring at its
  recorded position.
- Quote and apostrophe characters (DMS coordinates), placeholders, empty columns and backslashes are handled as
  documented.
- The IP and coordinate rules are applied; runs are deterministic, and the raw input is unchanged.

**F1–F4 unchanged:** the 4,491 F1–F4 rows of the new run are identical to the Step 3B-6 run in `parsed_log`,
`parsed_field` and `parsed_secondary` (0 differing rows). F1 15,280 / 15,280, F2 9,920 / 9,920, F3 9,850 / 9,850 and
F4 9,860 / 9,860.

**Not included:** the combined all-format validation (including DET-NONE), JSON/JSONB, PostGIS. The raw input table
was not modified.

---

## 1. What was built

All objects are in database `postgresql_regex_task`, schema `log_regex`.

| Layer (Step 3A §2) | Object | Change in this step |
|---|---|---|
| L1 reference | `ref_key_alias` | 10 F5 rows: column number → field (Step 3A §7.5); `ref_data_version` = `3B-7.1` |
| L2 parser, F5 | `f5_candidates` | new: one SQL split of the event line at `;` with cumulative positions |
| L2 parser, shared | `detect_format` (+ DET-F5, now `STABLE` because it reads `ref_timestamp_shape`), `run_parser` (F5 candidates, F5 sub-format) | patched in `sql/15` |
| L2 parser, F1–F4 | `f1_candidates` … `f4_candidates` | unchanged |
| L3 output / L4 evaluation | tables and views | unchanged; earlier runs kept |

## 2. Files and how to run

| File | Purpose | Re-runnable |
|---|---|---|
| [sql/23_parser_reference_data_f5.sql](../sql/23_parser_reference_data_f5.sql) | F5 column map, reference-data version | yes (replaces the F5 rows) |
| [sql/24_parser_f5.sql](../sql/24_parser_f5.sql) | `f5_candidates()` | yes |
| [sql/15_parser_core.sql](../sql/15_parser_core.sql) | `detect_format()` with DET-F5, `run_parser()` for F1–F5 (asserted text patch; DET-NONE added in Step 3C, see [Step3C_Combined_Parser_Validation.md](Step3C_Combined_Parser_Validation.md)) | yes |
| [sql/25_test_f5_parser.sql](../sql/25_test_f5_parser.sql) | Two parser runs, the F5 report, F1–F4 regression, invariants and verdict | yes (adds two runs) |
| [sql/run_step3b7_f5_parser.ps1](../sql/run_step3b7_f5_parser.ps1) | Answer-key hash check, Step 3B-6 object check, then 23, 24, 15, 11, 25 | yes |
| Runners for Steps 3B-3 … 3B-6 | Changed: also install 23 and 24 before 15, because `run_parser()` now calls `f5_candidates()` | yes |

```powershell
# PGHOST, PGPORT, PGUSER, PGPASSWORD set in the environment
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b7_f5_parser.ps1"
```

The 3B-7 runner does not re-run `sql/07` or `sql/08`. The Step 3B-6 run (formats `{F1,F2,F3,F4}`) therefore stays in
`parser_run` as the regression baseline. The older runners were updated but not re-run.

A parser run on its own: `SELECT log_regex.run_parser('3B-7 F1-F5 v1');` (returns the `run_id`).

---

## 3. How the F5 parser works

### 3.1 Detection (S0/S1)

| Order | Rule | Condition | Result |
|---:|---|---|---|
| 0 | DET-00 | `raw_log` NULL, empty or whitespace only | NONE |
| 1–3 | DET-F4, DET-F3, DET-F1 | unchanged | F4, F3, F1 |
| 4 | DET-F5 | **exactly 9 semicolons** on the event line **and** column 1 matches a timestamp shape from `ref_timestamp_shape` | F5 |
| 5 | DET-F2 | fallback sentence cues | F2 (unchanged) |
| — | DEFERRED | the 5 DET-NONE rows (combined step) | no field rows |

The column-1 test uses the same shape patterns as the timestamp validator (`dmy_dash`, `us_mdy_12h`, `ymd_slash`,
`compact_basic`, …). These patterns check shape only, so an impossible date such as `29-02-2026 12:00` is still F5 and
is judged later by VAL-TS. The header row EC-138 (`TIMESTAMP;ENTITY_TYPE;…;STATUS`) has 9 semicolons, but `TIMESTAMP`
is not a timestamp shape, so it is not F5. Because `detect_format()` now reads a reference table, it is declared
`STABLE` instead of `IMMUTABLE`; the results for F1–F4 are unchanged (§4.10).

### 3.2 Ten positional columns (S3, Step 3A §7.5)

The event line (first line) is split at every semicolon:

| Column | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| Field | timestamp | entity_type | email_address | tool | resource_url | latitude | longitude | ip_address | action_phrase | status |

- The map is reference data (`ref_key_alias`, F5, key = column number). Nothing is inferred from content.
- `start_pos` of column *n* = 1 + the lengths of columns 1…*n*−1 + (*n*−1) semicolons.
- DET-F5 guarantees 10 columns. Any other count would produce the diagnostic `column_count_not_10` and no field
  values (0 rows).

### 3.3 Quoted and special values

| Value | Rule | Example |
|---|---|---|
| Double quote, apostrophe | ordinary characters. No F5 value contains `;` (Step 2 §4.6), so splitting is not quote-aware and nothing is unquoted | `23°33'01.8"S` (EC-083) |
| Empty column | MISSING, `missing_reason` empty (VS-2); a blanks-only column is treated the same (none in the data) | `;;` (EC-007) |
| `-`, `N/A`, `NULL` | PLACEHOLDER (VS-4), any column | `-` in the IP column (EC-105) |
| Backslashes | kept verbatim | `\\fileserver01\hr$\contracts\2026\` (EC-034) |
| Uppercase / non-ASCII | kept verbatim; judged by the validators | `PRIYA.SHARMA@CORP.EXAMPLE.COM` (EC-018) |
| Anything else | taken as written, no trimming, then validated | `51.5074 N`, `N51.5074`, `3/18/2026 9:05 PM` |

### 3.4 Coordinates (C-03)

Latitude and longitude are labelled by position (columns 6 and 7), so the pair is never reordered. Every notation
stays in its own column: decimal, hemisphere suffix (`51.5074 N`), hemisphere prefix (`N51.5074`) and DMS. A sign
combined with a hemisphere letter (`-33.8688 S`, EC-090) is INVALID through VAL-GEO.

### 3.5 Validation, truncation and invalid rows

- Validators unchanged: the exact Step 3B-2 IP rule, VAL-GEO, VAL-TS (impossible dates, e.g. EC-059
  `29-02-2026 12:00`), VAL-EML (e.g. EC-024 without `@`), VAL-RES (EC-042 `htps://`), VAL-STS.
- **Record validity:** INVALID if any field is INVALID, otherwise VALID.
- **Truncation:** Step 3A §10.3 records truncation as not observed for F5, so there is no F5 truncation rule. A line
  cut short would have fewer than 9 semicolons and would not be detected as F5. The test lists near-F5 rows
  (timestamp-shaped column 1 with a different semicolon count) to prove none is hidden in the data (§4.6).
- **Sub-format:** records the column-1 timestamp shape (informational).
- **Secondary values:** only the shared IPv4 look-alike rule (`ip_like_in_resource`).

---

## 4. Results

PostgreSQL 17.9; two parser runs (A = run 11, B = run 12) on identical input: 19.39 s and 19.22 s for all 5,000 rows
(Step 3B-6 with F1–F4: about 18 s).

### 4.1 Detection (all 5,000 rows)

| Answer key | Parsed | Rule | Rows |
|---|---|---|---:|
| F1 / F2 / F3 / F4 | same | DET-F1 / DET-F2 / DET-F3 / DET-F4 | 1,528 / 992 / 985 / 986 |
| F5 | F5 | DET-F5 | 500 |
| NONE | deferred / NONE | — / DET-00 | 5 / 4 |

- F5: 500 true positives, **0 false positives**, 0 false negatives; F1–F4 unchanged (0 errors); `format_conflict` 0.
- Rows with exactly 9 semicolons: 501 — the 500 F5 rows (column 1 a timestamp) and EC-138 (`TIMESTAMP`, deferred).

### 4.2 Output shape and positions (run B)

| Check | Result |
|---|---|
| `parsed_log` rows / raw rows without one | 5,000 / 0 |
| F5 / F1–F4 / DET-00 / deferred logs | 500 / 4,491 / 4 / 5 |
| `parsed_field` rows; parsed logs without exactly 10 fields | 49,950; 0 |
| Field values equal to `substr(raw_log, start_pos, length)` | 47,374 / 47,374 |
| Secondary values equal to their substring | 1,113 / 1,113 |
| Overlapping value spans in one F5 log | 0 |

### 4.3 Per-field accuracy on all F5 rows

| Field | Rows | Value match | Validity match | Both |
|---|---:|---:|---:|---:|
| entity_type | 500 | 500 | 500 | 500 |
| email_address | 500 | 500 | 500 | 500 |
| resource_url | 500 | 500 | 500 | 500 |
| event_timestamp | 500 | 500 | 500 | 500 |
| tool | 500 | 500 | 500 | 500 |
| latitude | 500 | 500 | 500 | 500 |
| longitude | 500 | 500 | 500 | 500 |
| ip_address | 500 | 500 | 500 | 500 |
| action_phrase | 500 | 500 | 500 | 500 |
| status | 500 | 500 | 500 | 500 |
| **All fields** | **5,000** | **5,000** | **5,000** | **5,000 (100.00%)** |

Mismatches: none.

### 4.4 Validity distribution on F5 rows (answer key = parser in every cell)

| Field | VALID | INVALID | PLACEHOLDER | MISSING (empty column) |
|---|---:|---:|---:|---:|
| entity_type | 472 | 1 | 6 | 21 |
| email_address | 448 | 10 | 7 | 35 |
| resource_url | 476 | 1 | 7 | 16 |
| event_timestamp | 495 | 5 | 0 | 0 |
| tool | 453 | 0 | 11 | 36 |
| latitude | 431 | 1 | 14 | 54 |
| longitude | 431 | 3 | 21 | 45 |
| ip_address | 497 | 2 | 1 | 0 |
| action_phrase | 500 | 0 | 0 | 0 |
| status | 469 | 3 | 5 | 23 |

### 4.5 By column-1 timestamp shape and source

| Group | Logs | Field values | Both match |
|---|---:|---:|---:|
| `dmy_dash` (`DD-MM-YYYY HH:MM[:SS]`) | 296 | 2,960 | 2,960 |
| `ymd_slash` (`YYYY/MM/DD HH:MM:SS`) | 77 | 770 | 770 |
| `us_mdy_12h` (`M/D/YYYY h:mm AM`) | 65 | 650 | 650 |
| `compact_basic` (`YYYYMMDDTHHMMSS`) | 62 | 620 | 620 |
| curated | 15 | 150 | 150 |
| generated | 485 | 4,850 | 4,850 |

**Record validity:** INVALID 26 = 26, VALID 474 = 474. Truncated F5 rows: 0.

### 4.6 Positional columns, special values, truncated and invalid rows

| Check | Result |
|---|---|
| F5 logs with exactly 10 column slots | 500 / 500 |
| Lines rebuilt exactly by joining the 10 columns with `;` | 500 / 500 |
| Logs where every value equals its `split_part(line, ';', n)` column | 500 / 500 |
| Logs where MISSING occurs only for empty columns | 500 / 500 |
| Near-F5 rows (timestamp-shaped column 1, semicolon count not 0 or 9) | 0 |

| Special value | Values (all match) |
|---|---|
| DMS with `"` (and `'`) | latitude 93, longitude 95 |
| Backslash paths (Windows / UNC) | resource 19 |
| Empty columns | entity 21, email 35, resource 16, tool 36, latitude 54, longitude 45, status 23 |
| `-` | entity 4, email 4, resource 2, tool 5, latitude 8, longitude 5, IP 1, status 2 |
| `N/A` | entity 1, email 2, resource 2, tool 3, latitude 3, longitude 11, status 2 |
| `NULL` | entity 1, email 1, resource 3, tool 3, latitude 3, longitude 5, status 1 |

INVALID values (all match): email 10 (EC-024), timestamp 5 (EC-059), longitude 3, status 3, IP 2, entity 1,
resource 1 (EC-042), latitude 1 (EC-090).

### 4.7 Coordinate columns (C-03)

| Notation | Latitude (column 6) | Longitude (column 7) |
|---|---:|---:|
| decimal | 215 / 215 | 212 / 212 (2 INVALID) |
| hemisphere suffix `51.5074 N` | 91 / 91 (1 INVALID, EC-090) | 94 / 94 |
| hemisphere prefix `N51.5074` | 33 / 33 | 33 / 33 (1 INVALID) |
| DMS `23°33'01.8"S` | 93 / 93 | 95 / 95 |
| empty | 54 / 54 | 45 / 45 |
| placeholder | 14 / 14 | 21 / 21 |

Every latitude comes from column 6 and every longitude from column 7.

### 4.8 Whole-line first-match probes vs the column map (informational)

| Field | Whole-line probe | Probe correct | Parser correct | Example failure |
|---|---|---:|---:|---|
| email_address | first token containing `@` | 488 | 500 | EC-024 `ethan.murphy.example.com` has no `@` |
| ip_address | first dotted quad | 382 | 500 | EC-007 takes `10.20.0.15` from the resource |
| resource_url | first `http(s)://` URL | 238 | 500 | EC-034 UNC path |
| latitude | first decimal number | 20 | 500 | EC-007 takes `1.29` from `kube-probe/1.29` |
| status | last word of the line | 496 | 500 | GEN-01003 placeholder `-` |

### 4.9 Secondary values and diagnostics

500 / 500 F5 logs have exactly the answer key's secondary set (`ip_like_in_resource` 15, e.g. EC-007
`10.20.0.15`). Diagnostics on F5 rows: none.

### 4.10 F1–F4 regression (run B vs Step 3B-6 run 10)

| Comparison on the 4,491 F1–F4 logs | Rows only in baseline | Rows only in run B |
|---|---:|---:|
| `parsed_log` | 0 | 0 |
| `parsed_field` (44,910 rows each) | 0 | 0 |
| `parsed_secondary` | 0 | 0 |

Accuracy in the new run: F1 15,280 / 15,280, F2 9,920 / 9,920, F3 9,850 / 9,850, F4 9,860 / 9,860.

### 4.11 Determinism and integrity

- Run A vs run B: 0 differing rows in all three output tables; equal row counts.
- `verify_raw_access_logs()`: 10 / 10 before and after both runs.
- Step 1 files: `generate_raw_logs.py --check` reports all three files identical; dataset digest
  `1bcff42a6cd6634bd722064b629a0088dbbd7c67ac5276d013c505ac3fb06275` unchanged.
- All SQL / PowerShell files in `sql/` are ASCII.

`parser_run` now holds runs 1–12; the evaluation views use run 12.

---

## 5. Issues found while implementing

All three were found before the first database run by the ASCII scan or by review; the test then passed on its first
run.

| Issue | Fix |
|---|---|
| The test's coordinate-notation query used a literal degree sign | Replaced by the `\u00B0` escape |
| The test's special-value summary used a `HAVING` filter that would not have removed ordinary values | Rewritten as a subquery filtered on the computed category |
| A comment in `sql/23` used `·` separators | Replaced by commas |

## 6. Choices made in this step (for review)

1. **DET-F5 column-1 test uses `ref_timestamp_shape`** (shape only), so detection and the timestamp validator share one
   definition of "timestamp shape". `detect_format()` became `STABLE` because it reads that table.
2. **Split is not quote-aware and values are not trimmed:** Step 2 found no `;` inside any F5 value and no padding;
   all 500 × 10 raw columns equal the answer-key values exactly. A blanks-only column is treated as empty (none
   occur).
3. **No F5 truncation rule:** truncation is "not observed" for F5 (Step 3A §10.3). A cut-off line fails the exact
   9-semicolon rule and stays DEFERRED; the test's near-F5 check (0 rows) would expose one.
4. **Column map as reference data** (`ref_key_alias`, key = column number) rather than hard-coded positions.
5. **`sub_format`** = the column-1 timestamp shape, recorded for reporting only.
6. **DET-NONE and the combined all-format validation** are left for the next step. The 5 DET-NONE rows (EC-130,
   EC-137–140) remain DEFERRED here.
