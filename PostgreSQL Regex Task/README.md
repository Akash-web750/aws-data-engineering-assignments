# PostgreSQL Regex Task

**Status:** `FINAL_CONCLUSION_REPORTED` — the project is complete. The final overall project conclusion
([docs/Final_Project_Conclusion.md](docs/Final_Project_Conclusion.md)) consolidates Steps 1–7F; it is documentation
only, with no new experiment and no database change. Final read-only audit, after a documentation-only correction
pass: [docs/Final_Project_Audit.md](docs/Final_Project_Audit.md) (pass with warnings). Last executed step: PostGIS cleanup verified (Step 7F, Option A,
343 PASS / 0 FAIL; [docs/Step7F_PostGIS_Cleanup_and_Final_State_Plan.md](docs/Step7F_PostGIS_Cleanup_and_Final_State_Plan.md)).
Final PostGIS conclusion: [docs/Step7E_PostGIS_Final_Conclusion.md](docs/Step7E_PostGIS_Final_Conclusion.md). Earlier: final JSON vs JSONB comparison consolidated from Steps 6B–6E
([docs/Step6F_JSON_vs_JSONB_Final_Comparison_Report.md](docs/Step6F_JSON_vs_JSONB_Final_Comparison_Report.md)).
Write/update experiment:
[docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment.md](docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment.md).
Earlier: JSON vs JSONB index experiment done
([docs/Step6D_JSON_vs_JSONB_Index_Experiment.md](docs/Step6D_JSON_vs_JSONB_Index_Experiment.md)): identical btree
expression indexes on both types, plus jsonb-only GIN indexes, all verified. No-index queries:
[docs/Step6C_JSON_vs_JSONB_Query_Experiment.md](docs/Step6C_JSON_vs_JSONB_Query_Experiment.md). Tables and storage:
[docs/Step6B_Build_JSON_Tables_and_Storage.md](docs/Step6B_Build_JSON_Tables_and_Storage.md); design:
[docs/Step6A_JSON_vs_JSONB_Experiment_Design.md](docs/Step6A_JSON_vs_JSONB_Experiment_Design.md). Source table (Step 5B, 12/09/2026):
`log_regex.access_log_flat` was created
([docs/Step5B_Create_Flat_Table.md](docs/Step5B_Create_Flat_Table.md)) and populated with 5,000 rows from parser run 14
([docs/Step5B_Populate_Flat_Table.md](docs/Step5B_Populate_Flat_Table.md)); all 57 load checks PASS, no mismatches. It follows the Step 5A flat schema design
([docs/Step5A_Flat_Schema_Design.md](docs/Step5A_Flat_Schema_Design.md)), with one correction to the zone-ID CHECK.
Verification at that step: primary key, 4 foreign keys and 22 CHECK constraints present and validated; structural
checks S-01 … S-15 PASS; all other database objects and rows unchanged. The parser is final: 50,000 / 50,000 field
values, T-01 … T-10 all PASS ([docs/Step4A_Parser_Validation_Report.md](docs/Step4A_Parser_Validation_Report.md)).

An end-to-end PostgreSQL project covering:

- **Regex** — pattern matching, extraction, validation and replacement in PostgreSQL
- **JSON / JSONB** — storage, querying, operators and indexing
- **PostGIS** — spatial types and operations
- **Geospatial indexing** — GiST / SP-GiST / BRIN and spatial query planning
- **Performance analysis** — `EXPLAIN (ANALYZE, BUFFERS)`, index strategy, query tuning

---

## Project scope and implemented steps

The project is complete: Steps 1–7F are implemented and verified. The consolidated final report is
[docs/Final_Project_Conclusion.md](docs/Final_Project_Conclusion.md). The step-by-step record follows.

**Step 1, sample data** (see [docs/Sample_Data.md](docs/Sample_Data.md)):

- `data/raw_access_logs.csv` — 5,000 RAW LOG rows (150 curated edge cases + 4,850 generated)
- `data/expected_fields.csv` — answer key for the 10 target fields
- `data/dataset_manifest.json` — seed, distributions, SHA-256 checksums
- `data/generate_raw_logs.py`, `data/curated_edge_cases.py` — seeded, standard-library generator

**Step 2, requirements and string variants** (no parser):

- [docs/Step2_Requirements_and_Variants.md](docs/Step2_Requirements_and_Variants.md) — formats, field
  variants, optional/invalid forms, ambiguity and validity rules, edge-case register, open questions
- [docs/Step2_Raw_Log_Profile.md](docs/Step2_Raw_Log_Profile.md) and `analysis/raw_log_profile.json` —
  generated measurements, produced by `analysis/profile_raw_logs.py`

**Step 3A, parser design** — [docs/Step3A_Parser_Design.md](docs/Step3A_Parser_Design.md) (decisions C-01…C-09
confirmed; no code).

**Step 3B-1, PostgreSQL setup** — [docs/Step3B1_PostgreSQL_Setup.md](docs/Step3B1_PostgreSQL_Setup.md):

- `sql/00`–`sql/04` and `sql/run_step3b1_setup.ps1` — create `postgresql_regex_task` / `log_regex`, load the RAW LOGS
  into `log_regex.raw_access_logs` byte-exactly, add fingerprints, load audit, read-only guards and an integrity check
- `scripts/raw_csv_digest.py` — expected values computed from the CSV without the database

**Step 3B-2, IP validation check** — [docs/Step3B2_IP_Validation.md](docs/Step3B2_IP_Validation.md):
`sql/05_verify_ip_validation.sql` (read-only, TEMP tables) shows plain `inet` disagrees with the answer key on 5
values and proves the exact VAL-IP rule (4,986 / 4,986 labelled values, 43 / 43 probes).

**Step 3B-3, F1 parser** — [docs/Step3B3_F1_Parser.md](docs/Step3B3_F1_Parser.md):

- `sql/06`–`sql/12` and `sql/run_step3b3_f1_parser.ps1` — answer-key table (read-only), reference data, output tables,
  validators, F1 detection and extraction, `run_parser()`, evaluation views and the test report
- Result: 15,280 / 15,280 F1 field values match the answer key in value and validity; deterministic; raw input unchanged

**Step 3B-4, F2 parser** — [docs/Step3B4_F2_Parser.md](docs/Step3B4_F2_Parser.md):

- `sql/13`–`sql/16` and `sql/run_step3b4_f2_parser.ps1` — F2 reference data (log levels, sentinel phrases), the
  left-to-right sentence grammar (`f2_candidates()`), the shared core moved out of `sql/10` (`detect_format()` with
  DET-F2, `run_parser()` for F1 + F2) and the test report
- Result: 9,920 / 9,920 F2 field values match the answer key in value and validity; 0 DET-F2 false positives; no IP
  taken from `was blocked from accessing` (45 rows); F1 output identical to Step 3B-3; deterministic; raw input unchanged

**Step 3B-5, F3 parser** — [docs/Step3B5_F3_Parser.md](docs/Step3B5_F3_Parser.md):

- `sql/17`–`sql/19` and `sql/run_step3b5_f3_parser.ps1` — F3 key paths (`geo.lat`, `geometry.coordinates[1]`, …),
  `f3_candidates()` (RFC 3164 / RFC 5424 header parsed separately; forward-only regex scanner over the JSON text, no
  `json`/`jsonb` casts), DET-F3 and F3 truncation in `sql/15`, and the test report
- Result: 9,850 / 9,850 F3 field values match the answer key in value and validity; NaN INVALID, truncated JSON
  (EC-135) BROKEN, pretty-printed JSON (EC-144) exact; GeoJSON longitude-first in 132 / 132 rows; F1 + F2 output
  identical to Step 3B-4; deterministic; raw input unchanged

**Step 3B-6, F4 parser** — [docs/Step3B6_F4_Parser.md](docs/Step3B6_F4_Parser.md):

- `sql/20`–`sql/22` and `sql/run_step3b6_f4_parser.ps1` — F4 extras keys (also the boundary list), `f4_candidates()`
  (fixed positions → quoted request / referer / user agent → extras cut at known keys; `user=` before the remote-user
  slot, first `xff` entry before the IP field), DET-F4 and F4 truncation in `sql/15`, and the test report
- Result: 9,860 / 9,860 F4 field values match the answer key in value and validity; all 2,019 quoted values delimited
  by their quotes; entity values with spaces complete (129); `POINT(lon lat)` correct in 334 / 334 rows; truncated
  user agent (EC-136) BROKEN; F1–F3 output identical to Step 3B-5; deterministic; raw input unchanged

**Step 3B-7, F5 parser** — [docs/Step3B7_F5_Parser.md](docs/Step3B7_F5_Parser.md):

- `sql/23`–`sql/25` and `sql/run_step3b7_f5_parser.ps1` — F5 column map (reference data), `f5_candidates()` (split
  of the event line at `;` with cumulative positions, values verbatim), DET-F5 (exactly 9 semicolons + column-1
  timestamp shape from `ref_timestamp_shape`) in `sql/15`, and the test report
- Result: 5,000 / 5,000 F5 field values match the answer key in value and validity; every line rebuilt exactly from its
  10 columns; DMS quotes, placeholders, empty columns and UNC paths exact; 9-semicolon header row EC-138 not F5;
  F1–F4 output identical to Step 3B-6; deterministic; raw input unchanged

**Step 3C, combined all-format validation** — [docs/Step3C_Combined_Parser_Validation.md](docs/Step3C_Combined_Parser_Validation.md):

- `sql/26_test_combined_parser.sql` and `sql/run_step3c_combined_parser.ps1` — DET-NONE added to `sql/15` (the last
  detection rule); every parser object re-installed from source; two complete runs over all 5,000 rows; Step 3A
  acceptance tests T-01 … T-10, diagnostics and secondary-value registers, regression against each format's first
  accepted run
- Result: 5,000 / 5,000 rows classified exactly once (9 NONE, incl. the 5 DET-NONE rows); 50,000 / 50,000 field values;
  record validity 4,750 / 238 / 12 exact; 47,374 + 1,113 positions exact; F1–F5 byte-identical to their accepted runs;
  deterministic; raw input unchanged

**Step 4A, final parser validation report** — [docs/Step4A_Parser_Validation_Report.md](docs/Step4A_Parser_Validation_Report.md):
concise final report of the Step 3C runs (13 and 14), confirmed with read-only queries. It covers format distribution,
50,000-field accuracy, value and validity match, record validity, NONE and BROKEN cases, exact positions, determinism,
raw-input integrity and T-01 … T-10 (all PASS). The 10 known secondary-value annotation differences are reported
separately from the primary acceptance results. Documentation only; no parser or database changes.

**Step 5A, flat schema design** — [docs/Step5A_Flat_Schema_Design.md](docs/Step5A_Flat_Schema_Design.md):

- **Table:** `log_regex.access_log_flat`, one row per raw log for one accepted run (currently run 14). PK `log_id` →
  `raw_access_logs`; `(run_id, log_id)` → `parsed_log`.
- **Field columns:** each of the 10 fields has exact `text`, `…_validity` (text domain `VALID` / `INVALID` /
  `PLACEHOLDER` / `MISSING`), `…_start_pos`, `…_source` (parser slot) and `…_missing_reason`. MISSING = NULL value and
  NULL position.
- **Typed columns** (VALID values only): `entity_type_code`; timestamp shape, local `timestamp(6)`, UTC offset
  `interval` and `timestamptz(6)` instant only when the text defines the zone; `numeric(10,7)` coordinates; `inet` IP
  plus zone ID; `smallint` status code or upper-case status word.
- **Constraints:** CHECKs for MISSING/NULL, positions, typed columns, NONE rows and the record-validity rule.
- **Evidence:** a read-only profile of run 14, plus the DDL (Appendix A).
- **Review corrections:**
  - the entity code uses the validator's normalisation
  - IP verification compares `inet` values
  - 12 AM → 00 and 12 PM → 12
  - corrected `numeric(10,7)` reasoning, plus load-time rejection of coordinates needing more precision
  - two extra CHECK rules
  - `sql/07` and `sql/08` refuse to run while `access_log_flat` exists (`LR003`)
  - `sql/27_verify_access_log_flat_foreign_keys.sql` (read-only) must pass after install and after every load

**Step 5B, create the flat table** — [docs/Step5B_Create_Flat_Table.md](docs/Step5B_Create_Flat_Table.md):

- `sql/28_create_access_log_flat.sql` — the Step 5A DDL in one transaction. It creates the 3 validity domains and
  `access_log_flat`:
  - 71 columns
  - primary key `(log_id)`, the only index
  - 4 foreign keys: to `raw_access_logs` and `parsed_log` (`RESTRICT`), to `ref_entity_type` and `ref_timestamp_shape`
  - 22 CHECK constraints
  - comments that record the typed-column derivation rules

  It never drops anything and refuses (`LR003`) if the objects exist. Preconditions (`LR005`): raw input 10 / 10 and
  source run 14 accepted.
- `sql/29_verify_access_log_flat_structure.sql` (read-only) — S-01 … S-15 (`LR006`): table kind, 0 rows, domains,
  columns, no JSON/JSONB or PostGIS, keys, CHECK names, and CHECK semantics proven with 212 probe rows. It also checks
  that the only index is the primary key, plus triggers, comments, raw integrity and the source run.
- `sql/run_step5b_create_flat_table.ps1` — static guard checks, digest of all other objects and rows, `sql/28`, `sql/27`,
  `sql/29`, digest again; `-VerifyOnly`
- **Result:** created and verified; `sql/27` PASSED, S-01 … S-15 PASSED, digest unchanged over 160 items. Refusal tests:
  `sql/28` again → `LR003`; the `sql/07` / `sql/08` guards → `LR003` against the real table
- **Correction:** the design's zone-ID CHECK evaluated to NULL (and so passed) for a zone ID without an `inet` value.
  The implemented CHECK requires a non-NULL IPv6 `inet`, and Appendix A is updated.

**Step 5B, populate the flat table** — [docs/Step5B_Populate_Flat_Table.md](docs/Step5B_Populate_Flat_Table.md):

- `sql/30_load_access_log_flat.sql` — one transaction:
  - **Refuses** (`LR007`) unless the table is empty and run 14 is accepted.
  - **Stages** the rows from `parsed_log` + `parsed_field` and applies the Step 5A conversions to VALID values (entity
    normalisation, timestamp shape / local / offset / UTC with 12 AM → 00 and 12 PM → 12, `numeric(10,7)` coordinates,
    `inet` + zone ID, status code or word).
  - **Enforces** the precision rule (`LR008`), then runs one `INSERT` and a gate before COMMIT: row count, exact round
    trip, exact substrings.
- `sql/31_verify_access_log_flat_load.sql` (read-only) — 57 checks (`LR009`) covering:
  - rows and foreign keys
  - all CHECKs re-evaluated on every row
  - correspondence with the parser output and the answer key
  - typed columns against independent oracles
  - record and field validity counts, positions, NULLs
- `sql/run_step5b_populate_flat_table.ps1` — static checks, digest, load, `sql/27`, `sql/29`, `sql/31`, digest;
  `-VerifyOnly`. `sql/29` S-02 now also accepts the populated state.
- **Result:**
  - 5,000 rows; 50,000 / 50,000 field values equal `parsed_field` and the answer key
  - record validity 4,750 / 238 / 12
  - 47,374 exact positions; typed counts 4,634 · 4,990 · 4,928 · 2,941 · 2,941 · 4,249 · 4,252 · 4,948 · 1 · 2,035 ·
    2,666 with 0 oracle mismatches
  - 0 CHECK violations; all 57 checks PASS, no mismatches
  - digest of all other objects and rows unchanged; the load refuses to run twice

**Step 6A, JSON vs JSONB experiment design** — [docs/Step6A_JSON_vs_JSONB_Experiment_Design.md](docs/Step6A_JSON_vs_JSONB_Experiment_Design.md)
(design only; nothing created):

- **Data:** one document per `access_log_flat` row (5,000). It holds the 70 logical leaves: every column except
  `loaded_at`, nested as `record` + `fields.<field>.{value, validity, start_pos, source, missing_reason, typed keys}`,
  with MISSING as JSON `null`.
- **Build:** one minified canonical text is cast to both `json` and `jsonb`. Planned tables
  `log_regex_json.access_log_json` / `access_log_jsonb` are identical except the `doc` type and have no foreign keys.
- **Workload:**
  - 21 head-to-head queries with identical SQL: lookups, whole-document output, 1/10/70-value extraction, equality,
    range, time-window, pattern and array filters, aggregates, `JSON_VALUE` / `JSON_EXISTS`
  - `jsonb`-only capability queries: `@>`, `?`, `@?`, document equality
  - load and index-build write cost
- **Measurements:**
  - storage: forks, TOAST, per-document `pg_column_size` and text size, compression and out-of-line counts, WAL
  - indexes: I-0 baseline, I-1 identical btree expression indexes, I-2/I-3 GIN `jsonb_ops` / `jsonb_path_ops`
    (jsonb only)
  - `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, SERIALIZE, MEMORY)`: 15 interleaved runs with fixed session settings
- **Rules:** equivalence checks E1–E9 (including a full round trip of all 70 values to the flat table), pre-set
  comparability and difference-threshold rules, and a list of everything that must stay unchanged.

**Step 6B, JSON and JSONB tables and storage** — [docs/Step6B_Build_JSON_Tables_and_Storage.md](docs/Step6B_Build_JSON_Tables_and_Storage.md):

- `sql/32`–`sql/35` and `sql/run_step6b_build_json_tables.ps1` create schema `log_regex_json` with `access_log_json` and
  `access_log_jsonb`: identical tables except the `doc` type, primary keys only, no foreign keys.
- **Load:** both tables come from one minified canonical text per flat row (8,416,033 bytes, md5 `aeaef323…`), then
  VACUUM ANALYZE.
- **Verification (38 checks, all PASS):**
  - 5,000 rows each, identical `log_id` sets, byte-exact input text
  - `json::jsonb = jsonb`
  - all 70 values round-trip to `access_log_flat` in both tables
  - no duplicate keys; 82 keys in every document
  - quotes, backslashes and non-ASCII escaped correctly
  - MISSING as JSON `null` with the key present
- **Storage** (`analysis/step6/step6b_storage_measurements.txt`):
  - uncompressed, `jsonb` documents are larger (+19.5 %)
  - 2,880 `jsonb` rows cross the ~2 kB TOAST threshold and are pglz-compressed inline, so stored `jsonb` is smaller
    (heap 8.04 MB vs 10.24 MB)
  - 1 `json` document is compressed; nothing is stored out of line
  - this is reported as a threshold effect, not a conclusion
- **Unchanged:** the `log_regex` digest (203 items, including `access_log_flat` rows) before and after; `sql/27`,
  `sql/29` and `sql/31` pass. No query indexes, EXPLAIN or benchmarks in this step (they followed in Steps 6C–6E).

**Step 6C, JSON vs JSONB head-to-head queries** — [docs/Step6C_JSON_vs_JSONB_Query_Experiment.md](docs/Step6C_JSON_vs_JSONB_Query_Experiment.md)
(measurements and observations; the conclusion followed in Step 6F):

- **Files:**
  - `scripts/step6c_json_query_experiment.py` defines the 25 statements (21 query IDs), generates `sql/36`
    (correctness, 78 checks) and `sql/37` (measurement session), and analyses the output
  - `sql/run_step6c_json_queries.ps1` runs gates, two separate read-only sessions, gates again, digests and analysis
- **Protocol:** no indexes; identical SQL on both types; no jsonb-only operators; JIT off, no parallel workers, UTC, I/O
  timing on; 3 warm-ups + 15 alternating measured runs + 1 per-node detail run per statement and type;
  `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY)`.
- **Correctness:** json = jsonb = `access_log_flat` oracle for all 25 statements, before and after timing; documents,
  tables and indexes unchanged (digests).
- **Measurements** (`analysis/step6/step6c_*`), under the Step 6A rule:
  - json measurably faster for whole-document output: Q01 0.012 vs 0.030 ms, Q02 3.0 vs 68.7 ms, the latter dominated
    by jsonb serialisation
  - jsonb measurably faster for all 23 extraction, filter, aggregate and SQL/JSON statements, by about 5–13× (Q03 about 2×; e.g. Q05
    1,070 vs 82 ms, Q06 7,413 vs 592 ms)
  - planning time: no measurable difference
  - plan shapes, scan estimates and row counts identical (only the Q17/Q18 group-count estimates differ); batch 2
    reproduced every direction

**Step 6D, JSON vs JSONB indexes** — [docs/Step6D_JSON_vs_JSONB_Index_Experiment.md](docs/Step6D_JSON_vs_JSONB_Index_Experiment.md)
(measurements and observations; the conclusion followed in Step 6F):

- **Files:** `scripts/step6d_json_index_experiment.py` generates `sql/38` (per-phase verification), `sql/39` (guarded
  index builds) and `sql/40` (per-phase measurements); `sql/run_step6d_json_indexes.ps1` runs the phases I-0 → I-1 →
  I-2 → I-3 → final. The Step 6C baseline is preserved (SHA-256 manifest, 11 files) and re-measured as an I-0 control.
- **Indexes:**
  - I-1, the fair comparison: the same five btree expression indexes on both tables (`record_validity`,
    `entity_type.code`, `status.code::integer`, `latitude.degrees::numeric`, `event_timestamp.utc`); identical sizes
    (499,712 bytes per table)
  - jsonb-only: GIN `jsonb_ops` (4.52 MB) and `jsonb_path_ops` (3.73 MB)
  - no json-via-cast GIN
- **Verification:** every index valid; every result = `access_log_flat` under default and forced plans (214 checks
  across phases); documents and `log_regex` unchanged.
- **Head-to-head at I-1:**
  - no measurable json/jsonb difference for the 7 statements answered by the index
  - jsonb still measurably faster where documents are still read (Q16 heap filter, Q11b/Q17 sequential scans, Q09
    control)
  - json index builds slower (66–122 vs 16–21 ms)
  - the planner keeps a sequential scan for Q11b although the forced index path is about 150× faster on json
- **Capability (jsonb only):** GIN turns containment/jsonpath statements from about 10–12 ms into 0.03–0.8 ms;
  `jsonb_path_ops` smaller, faster to build and faster here; `?` on nested values and `JSON_EXISTS` not indexable.

**Step 6E, JSON vs JSONB write/update cost experiment design** — [docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md](docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md)
(design approved with safeguards; measured — results in
[docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment.md](docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment.md)):

- **Measurement:**
  - `scripts/step6e_json_write_measure.py` generates `sql/43` (35 series × 18 rounds + detail runs) and `sql/44`
    (second session for W1b); `sql/run_step6e_json_writes.ps1` passed 26 / 26 checks
  - all 756 attempts were correct; 4 measured runs flagged by the WAL rule and excluded
  - raw output, CSVs and the generated summary are in `analysis/step6/step6e_*`
- **Findings (no verdict):**
  - Without secondary indexes json writes faster (1.3–2.5×); with the five btree expression indexes jsonb writes
    faster (0.51–0.59×), because index maintenance costs json 2.5–6.6× and jsonb 1.1–1.4×.
  - jsonb writes 11–13 % less WAL for whole-table writes (compressed inline documents), but 5.6–6.1 % more for
    238-row updates.
  - Updates are almost never HOT; UA-3 doubles the heap.
  - GIN adds 1.5–4.3× time and up to 3.9× WAL; `jsonb_path_ops` is cheaper than `jsonb_ops`.
  - No TOAST growth.
  - CPU speed dropped about 3× partway through session 1 (laptop running on battery afterwards; the cause is not proven); only interleaved ratios are
    compared.

- **Setup and preflight:** `scripts/step6e_json_write_experiment.py` generates `sql/41_create_json_write_experiment.sql`
  (schema, staged canonical text, expected UA-1/UA-2/UA-3 documents, empty `_w` tables) and
  `sql/42_preflight_json_write_experiment.sql` (41 checks: fingerprint, idle sessions, schema objects, X-0 … X-4
  definitions created and compared inside a rolled-back transaction). `sql/run_step6e_setup_preflight.ps1` adds
  static checks, the 6C/6D manifests (`analysis/step6/step6e_baseline_step6d_sha256.txt` new), digests and
  `sql/34` / `sql/38 final` before and after: **63 / 63 PASS** (`analysis/step6/step6e_preflight_report.txt`).

- **Review:** 6A planned W1 (bulk insert with `EXPLAIN … WAL`), optional W2 (238-document update) and the load part of
  M-08; none had been measured before this step. Index maintenance on writes was a Step 6D gap.
- **Isolation:** separate schema `log_regex_json_write` with staged canonical text (md5-verified), expected update
  documents and `_w` copies of the tables. Existing raw, flat, parser and Step 6B/6D objects are never written; proven by
  digests, `sql/34`, `sql/38` and baseline manifests.
- **Writes measured:**
  - bulk insert of 5,000 documents and row-at-a-time inserts
  - full-document replacement updates with identical new text (head-to-head)
  - `jsonb_set` and json alternatives, reported separately
  - index configurations X-0 (primary key) and X-1 (the 6D btree expression indexes) head-to-head; X-2/X-3/X-4 (GIN,
    including the current 6D set) jsonb only
- **Method:**
  - `EXPLAIN (ANALYZE, BUFFERS, WAL)`, commit-inclusive LSN deltas, `pg_stat_wal` / `pg_stat_io` /
    `pg_stat_checkpointer` deltas, relation growth
  - reset + `CHECKPOINT` before every measured statement; interleaved rounds; the Step 6A rule
  - full correctness checks after every round
- The results report and conclusion move to Step 6F.

**Step 6F, final JSON vs JSONB comparison** — [docs/Step6F_JSON_vs_JSONB_Final_Comparison_Report.md](docs/Step6F_JSON_vs_JSONB_Final_Comparison_Report.md)
(consolidation of 6B–6E; no new measurement):

- **Fair comparisons** are kept apart from **jsonb-only capabilities** (GIN operators, `jsonb_set`).
- **Measured split, no single winner:**
  - json was faster for returning whole documents and for inserts and full-document updates **without** secondary
    indexes, and preserves the input text exactly.
  - jsonb was faster for every value extraction, filter and aggregate (about 5–13× without indexes), and for inserts
    and updates **with** the five btree expression indexes (json pays text parsing per index entry).
  - Index-answered queries showed no difference.
- **Storage and WAL:** jsonb stored 14 % fewer document bytes and wrote 8–13 % less WAL for whole-table writes and
  single-row inserts, a TOAST inline-compression threshold effect of this dataset; for 238-row updates it wrote 5.6–6.1 %
  more WAL.
- **Scope:** 5,000 documents of about 1.7 kB, PostgreSQL 17.9 on one Windows laptop, warm cache, single client; timing
  ratios are compared only within sessions (caveats in §12 of the report).

**Step 7, PostGIS spatial indexes**:
- **Documents:**
  - design: [docs/Step7A_PostGIS_Experiment_Design.md](docs/Step7A_PostGIS_Experiment_Design.md)
  - installation preflight: [docs/Step7A1_PostGIS_Installation_Preflight.md](docs/Step7A1_PostGIS_Installation_Preflight.md)
  - post-installation verification: [docs/Step7A2_PostGIS_Post_Installation_Verification.md](docs/Step7A2_PostGIS_Post_Installation_Verification.md)
  - setup: [docs/Step7B_PostGIS_Setup_Preflight.md](docs/Step7B_PostGIS_Setup_Preflight.md)
  - index experiment design: [docs/Step7C_Spatial_Index_Experiment_Design.md](docs/Step7C_Spatial_Index_Experiment_Design.md)
  - index experiment: [docs/Step7C_Spatial_Index_Experiment.md](docs/Step7C_Spatial_Index_Experiment.md)
  - results analysis: [docs/Step7D_PostGIS_Results_Analysis.md](docs/Step7D_PostGIS_Results_Analysis.md)
  - final conclusion: [docs/Step7E_PostGIS_Final_Conclusion.md](docs/Step7E_PostGIS_Final_Conclusion.md)
  - cleanup and final state: [docs/Step7F_PostGIS_Cleanup_and_Final_State_Plan.md](docs/Step7F_PostGIS_Cleanup_and_Final_State_Plan.md)
- **Setup (7B, 317 / 0):**
  - PostGIS 3.6.2 in schema `postgis`.
  - Schema `log_regex_gis` with 15 tables of 5,000 rows copied from `access_log_flat` / `access_log_jsonb` (4,161
    non-NULL points): numeric, geometry, geography and JSONB variants.
  - Plain-SQL oracles for boxes, distances and nearest neighbours.
- **Experiment (7C, 943 PASS / 0 FAIL):**
  - 10 indexes (B-tree; geometry GiST, SP-GiST, BRIN; geography GiST, SP-GiST; JSONB expression and stored-column
    GiST), 3 builds each.
  - 192 query × configuration series in 2 read-only sessions.
  - Results equal to the oracles in 2,424 / 2,424 checks.
- **Analysis (7D, no new measurement):**
  - **Index vs its own control:** 90 measurable benefit, 5 used without measurable benefit, 3 regressions, 7 not used,
    plus 4 unsupported nearest-neighbour cases (SP-GiST and BRIN have no ordering operator).
  - **SP-GiST vs GiST:** SP-GiST was never measurably faster than GiST on the same column.
  - **BRIN:** summarised the 39-page tables as a single block range; the planner did not use it, or it was slower.
  - **Flat vs JSONB, same type and index:** flat was faster in 14 of 23 indexed series and never slower.
  - **JSONB storage forms (JSONB-specific):** a stored generated-column index beat the expression index in 21 of 23.
  - **Planning time:** indexed tables planned measurably slower in 97 of 109 series (never faster); for geography
    distances it was 0.43–1.30 ms, against about
    0.04 ms without an index.
- **Conclusion (7E, scoped to this data and environment):**
  - GiST is the index method to use; SP-GiST was never measurably faster, and BRIN gave no benefit on 39-page tables.
  - Geography + GiST for metric distances and nearest neighbours (correct across the antimeridian and pole, planning
    0.43–1.30 ms).
  - Geometry + GiST for degree boxes and planar nearest neighbours.
  - Indexes paid off mainly up to about 22 % of rows and for nearest neighbours; benefits were smaller at larger result
    sizes (e.g. 2.3–3.1× for the 41 % distance query D4). For 32–78 % boxes the flat-table GiST / SP-GiST / BRIN indexes gave no
    benefit, while the JSONB GiST indexes still had measurable benefits (J-1 on B3 and B4, J-3 on B3).
  - Flat coordinates are preferable to JSONB coordinates; within JSONB, a stored generated column beats an expression
    index for reads.
  - Write costs were not measured.
- **Scope:** 5,000 rows (4,161 points), PostgreSQL 17.9 / PostGIS 3.6.2, one Windows laptop on AC power, warm cache, single client.
- **Final state (7F, `sql/run_step7f_cleanup.ps1`, 343 PASS / 0 FAIL):**
  - The 10 Step 7C indexes were dropped with `sql/52` in one transaction, after a rolled-back harness (48 PASS on its
    own, repeated in the full run).
  - `log_regex_gis` keeps its 15 tables (5,000 rows each, fingerprints unchanged) and 15 primary keys.
  - PostGIS 3.6.2 stays installed; no object outside `postgis` / `log_regex_gis` depends on it.
  - `sql/47` passed 155 / 155 and `sql/50 phase before` 113 / 113.
  - The raw, flat, parser and Step 6 digests and the Step 6C / 6D / 7B / 7F manifests are unchanged.

**Final overall project conclusion** — [docs/Final_Project_Conclusion.md](docs/Final_Project_Conclusion.md)
(consolidation of Steps 1–7F; no new measurement, no database change):
- **Parser:** 50,000 / 50,000 field values match the answer key in value and validity; 47,374 exact positions;
  T-01 … T-10 PASS; raw input unchanged throughout.
- **Flat table:** typed, constrained primary store and correctness oracle (57 / 57 load checks).
- **JSON vs JSONB:** no type better across the board (Step 6F).
  - json: faster for unchanged documents without path indexes, and preserves the exact text.
  - jsonb: about 5–13× faster value access without indexes (Q03 about 2×), faster writes with btree expression
    indexes, and the only type with GIN search
    and `jsonb_set`.
- **PostGIS** (Step 7E):
  - GiST is the index method.
  - Geography + GiST for metric distances and nearest neighbours; geometry + GiST for degree boxes.
  - Indexes help selective queries and nearest neighbours. For boxes returning 32–78 % of rows the flat-table GiST /
    SP-GiST / BRIN indexes gave no benefit, while the JSONB GiST indexes still had measurable benefits (J-1 on B3 and
    B4, J-3 on B3). No BRIN / SP-GiST advantage at this size.
  - Flat coordinates are never slower than JSONB coordinates. In JSONB, a stored generated column beats an expression
    index for reads.
  - Write costs were not measured.
- **Also in the report:** consolidated comparison table, recommended architecture, use / do-not-use /
  workload-dependent decisions, methodology and caveats, untested items, threats to validity, future work.
- **Scope:** 5,000-row synthetic dataset, PostgreSQL 17.9, PostGIS 3.6.2, one Windows laptop, warm cache, single
  client. Final database state as verified in Step 7F. Nothing committed to git.

## Relationship to the rest of this repository

A sibling of the other projects at the repository root. It is **independent** of
`packers_movers_synthetic_data/`, which is a separate, completed five-version analytics
project against the `relocation_services` database and is not affected by anything here.
