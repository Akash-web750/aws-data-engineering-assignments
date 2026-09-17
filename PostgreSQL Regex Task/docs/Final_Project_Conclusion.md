# Final Project Conclusion — PostgreSQL Regex Parsing, Flat Schema, JSON vs JSONB and PostGIS

**Status:** final report (13/09/2026), corrected after the read-only final audit
([Final_Project_Audit.md](Final_Project_Audit.md)). **Documentation only.** No SQL, `EXPLAIN ANALYZE`, Python test, experiment or
database change was run for this report. The database stays in the verified Step 7F state.

**How to read this report:**
- **Measured vs derived:** every figure is a recorded result from Steps 1–7F. Figures marked *derived* are arithmetic on
  recorded values and carry no verdict.
- **Fair vs specific:** fair comparisons are kept apart from type-only capabilities (jsonb) and from
  representation-specific observations (PostGIS), as in the source reports.
- **Scope:** every conclusion is limited to the tested dataset, PostgreSQL 17.9, PostGIS 3.6.2, one Windows laptop and
  the tested workloads (§11, §13).

**Sources:**

| Phase | Documents |
|---|---|
| Step 1 — sample data | [Sample_Data.md](Sample_Data.md) |
| Step 2 — requirements, profile | [Step2_Requirements_and_Variants.md](Step2_Requirements_and_Variants.md), [Step2_Raw_Log_Profile.md](Step2_Raw_Log_Profile.md) |
| Step 3 — parser design and implementation | [Step3A_Parser_Design.md](Step3A_Parser_Design.md), [Step3B1_PostgreSQL_Setup.md](Step3B1_PostgreSQL_Setup.md), [Step3B2_IP_Validation.md](Step3B2_IP_Validation.md), [Step3B3_F1_Parser.md](Step3B3_F1_Parser.md) … [Step3B7_F5_Parser.md](Step3B7_F5_Parser.md), [Step3C_Combined_Parser_Validation.md](Step3C_Combined_Parser_Validation.md) |
| Step 4 — parser validation | [Step4A_Parser_Validation_Report.md](Step4A_Parser_Validation_Report.md) |
| Step 5 — flat schema | [Step5A_Flat_Schema_Design.md](Step5A_Flat_Schema_Design.md), [Step5B_Create_Flat_Table.md](Step5B_Create_Flat_Table.md), [Step5B_Populate_Flat_Table.md](Step5B_Populate_Flat_Table.md) |
| Step 6 — JSON vs JSONB | [Step6A_JSON_vs_JSONB_Experiment_Design.md](Step6A_JSON_vs_JSONB_Experiment_Design.md), [Step6B_Build_JSON_Tables_and_Storage.md](Step6B_Build_JSON_Tables_and_Storage.md), [Step6C_JSON_vs_JSONB_Query_Experiment.md](Step6C_JSON_vs_JSONB_Query_Experiment.md), [Step6D_JSON_vs_JSONB_Index_Experiment.md](Step6D_JSON_vs_JSONB_Index_Experiment.md), [Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md](Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md), [Step6E_JSON_vs_JSONB_Write_Update_Experiment.md](Step6E_JSON_vs_JSONB_Write_Update_Experiment.md), [Step6F_JSON_vs_JSONB_Final_Comparison_Report.md](Step6F_JSON_vs_JSONB_Final_Comparison_Report.md) |
| Step 7 — PostGIS | [Step7A_PostGIS_Experiment_Design.md](Step7A_PostGIS_Experiment_Design.md), [Step7A1_PostGIS_Installation_Preflight.md](Step7A1_PostGIS_Installation_Preflight.md), [Step7A2_PostGIS_Post_Installation_Verification.md](Step7A2_PostGIS_Post_Installation_Verification.md), [Step7B_PostGIS_Setup_Preflight.md](Step7B_PostGIS_Setup_Preflight.md), [Step7C_Spatial_Index_Experiment_Design.md](Step7C_Spatial_Index_Experiment_Design.md), [Step7C_Spatial_Index_Experiment.md](Step7C_Spatial_Index_Experiment.md), [Step7D_PostGIS_Results_Analysis.md](Step7D_PostGIS_Results_Analysis.md), [Step7E_PostGIS_Final_Conclusion.md](Step7E_PostGIS_Final_Conclusion.md), [Step7F_PostGIS_Cleanup_and_Final_State_Plan.md](Step7F_PostGIS_Cleanup_and_Final_State_Plan.md) |

---

## 1. Project objective and original problem

The project is an end-to-end PostgreSQL study of five areas:
- regex pattern matching, extraction and validation
- JSON / JSONB storage, querying and indexing
- PostGIS spatial types
- geospatial indexing (GiST / SP-GiST / BRIN)
- performance analysis with `EXPLAIN (ANALYZE, BUFFERS)`

The original assignment text is not recorded in the project documents. **The problem as recorded** (Step 2 extraction
contract G-01 … G-09; Step 3A):
- **Input:** 5,000 heterogeneous raw access-log lines in five formats, plus blank and junk lines.
- **Output:** for every `log_id`, 10 fields, each as a *value* and a *validity* label.
- **Exact values:** each value is the exact substring of `raw_log`.
- **Primary and secondary:** exactly one primary value per field; other candidates become secondary values.
- **Robust input handling:** NULL, empty or whitespace-only logs give all fields MISSING without error.
- **Raw data is never modified.**
- **Verifiable:** results are deterministic and checked against an answer key.
- **Implementation:** PostgreSQL regular expressions in database `postgresql_regex_task`, schema `log_regex`.

**Later steps built on the parser output:**
- a typed, constrained **flat relational table** (Step 5)
- a fair **JSON vs JSONB** comparison for storing the records as documents (Step 6)
- a **PostGIS** comparison of spatial representations and index methods on the parsed coordinates (Step 7)

| Step | Work | Recorded outcome |
|---|---|---|
| 1 | Seeded synthetic dataset and answer key | 5,000 rows (150 curated edge cases + 4,850 generated) |
| 2 | Requirements, variants, profile | contract G-01 … G-09, validity rules, edge-case register |
| 3A–3C | Parser design, setup, formats F1–F5, combined validation | all formats accepted; runs 13 and 14 identical |
| 4A | Final parser validation | 50,000 / 50,000 field values; T-01 … T-10 PASS |
| 5A–5B | Flat schema design, creation, load | `access_log_flat`: 5,000 rows, 57 / 57 load checks |
| 6A–6F | JSON vs JSONB storage, queries, indexes, writes | Step 6F: no type better across the board; results split by access pattern |
| 7A–7F | PostGIS installation, setup, spatial index experiment, analysis, conclusion, cleanup | Step 7E conclusion; Step 7F final state 343 PASS / 0 FAIL |

## 2. Dataset and its characteristics

| Property | Recorded value |
|---|---|
| Rows | 5,000: 150 curated edge cases (EC-001 … EC-150) + 4,850 generated; seed 20260911; standard-library Python generator (`data/generate_raw_logs.py`, `--check` verifies byte-identity) |
| Files | `data/raw_access_logs.csv` (`log_id`, `raw_log`; SHA-256 `a94fc3cc…e661e`), `data/expected_fields.csv` (answer key), `data/dataset_manifest.json` |
| Target fields (10) | `entity_type`, `email_address`, `resource_url`, `event_timestamp`, `tool`, `latitude`, `longitude`, `ip_address`, `action_phrase`, `status` |
| Validity labels | `VALID` (present, well-formed) · `INVALID` (present, malformed or out of range) · `PLACEHOLDER` (token for "no value", e.g. `-`, `N/A`, `NULL`, JSON `null`) · `MISSING` (absent or empty) |
| Record validity | `BROKEN` = format NONE or truncated; `INVALID` = at least one INVALID field; otherwise `VALID` |
| Event time range | 2026-01-01T00:00:00Z – 2026-06-30T23:59:59Z |
| Data safety | placeholder domains; private or documentation IP ranges |

**Formats:**

| Format | Shape | Rows (generated / curated / total) |
|---|---|---|
| F1 | pipe / TAB `key=value` | 1,455 / 73 / 1,528 |
| F2 | natural-language sentence (three templates) | 970 / 22 / 992 |
| F3 | syslog header (RFC 3164 or 5424) + JSON payload | 970 / 15 / 985 |
| F4 | web-server access log with `key=value` extras | 970 / 16 / 986 |
| F5 | semicolon-positional export (10 columns) | 485 / 15 / 500 |
| NONE | blank input, junk, header rows | 0 / 9 / 9 |

**Recorded characteristics** (Step 1 / Step 2 profile):

| Area | Distribution |
|---|---|
| Record validity | VALID 4,750 · INVALID 238 · BROKEN 12 |
| Field validity, all 50,000 values | VALID 46,506 · INVALID 255 · PLACEHOLDER 613 · MISSING 2,626 |
| Coordinates | signed decimal, DMS (including a Unicode-prime DMS), hemisphere prefix and suffix; longitude-first containers F4 `POINT(lon lat)` (334) and F3 GeoJSON `[lon,lat]` (132); 158 partial pairs |
| Timestamps | 19 shapes (e.g. Apache CLF 880, ISO `Z` 661, syslog without year 621); 231 VALID values with ambiguous day/month order |
| IP addresses | IPv4 3,905; IPv6 compressed 727, full 203, IPv4-mapped 112; one link-local IPv6 with a zone ID (EC-100) |
| Input characteristics | 1 SQL NULL, 1 empty string, 2 whitespace-only, 294 non-ASCII, 2 multi-line; maximum 2,289 characters |
| Edge cases | 150 curated, in ranges entity (10), email (16), resource (16), timestamp (18), tool (10), coordinates (20), IP (16), action (12), status (10), whole-record (22) |

**Later derived representations of the same data:**
- the flat table (Step 5)
- one JSON document per flat row (Step 6): 82 keys and 70 leaf values; canonical minified text of 8,416,033 bytes,
  md5 `aeaef323…`
- 4,161 points with both coordinates VALID (Step 7), 856 of them with |longitude| > 90

## 3. Regex parser — design and final validation

### 3.1 Design

**Principles** (Step 3A, P-01 … P-08):
- raw logs are read-only
- detect the format first, then extract slots
- extract first, then judge validity
- collect candidates, then select one
- offsets everywhere
- vocabularies stored as data
- deterministic, set-based processing
- the answer key is never a parser input

**Pipeline:** load → input guard → format detection → event scope → slot extraction → clean-up → primary selection →
value state → validation → output.

**Implementation:** PostgreSQL functions and reference tables in schema `log_regex`.
- **Per-format candidate functions:** `f1_candidates` … `f5_candidates`.
- **`detect_format()`:** assigns the format.
- **`run_parser()`:** applies selection, value state, validators, record validity and secondary values.
- **Run tables:** `parser_run`, `parsed_log`, `parsed_field`, `parsed_secondary`.
- **Output and evaluation views:** `v_parsed_access_logs` (wide output view), `v_parser_field_comparison` and
  `v_parser_mismatches`.

**Recorded review decisions:**

| Decision | Content |
|---|---|
| C-01 | first status token wins |
| C-02 | the event's own action wins |
| C-03 | `POINT(...)` and GeoJSON are longitude-first, other pairs latitude-first; values are never swapped |
| C-04 | validity is checked in PostgreSQL; year 2026 for year-less syslog dates |
| C-05 | acceptance target: 100 % value and validity match |
| C-06 | an F1 log with neither action nor status is truncated |
| C-07 | one row per field plus a wide view; MISSING = SQL NULL |
| C-08 | own database and schema |
| C-09 | F3 JSON is parsed by regex only, with no `json` / `jsonb` casts |

### 3.2 Format detection

**Detection priority:** F4 → F3 → F1 → F5 → F2 → NONE. The first matching rule wins.

| Format | Rule | Rows | Equal to answer key |
|---|---|---:|---:|
| F1 pipe / TAB `key=value` | DET-F1 | 1,528 | 1,528 |
| F2 sentence | DET-F2 | 992 | 992 |
| F3 syslog + JSON | DET-F3 | 985 | 985 |
| F4 web-server access log | DET-F4 | 986 | 986 |
| F5 semicolon-positional | DET-F5 (exactly 9 semicolons + column-1 timestamp shape) | 500 | 500 |
| NONE blank input | DET-00 | 4 | 4 |
| NONE no recognised format | DET-NONE | 5 | 5 |
| **Total** | | **5,000** | **5,000** |

Every row has exactly one format and one rule; 0 format conflicts; 0 unclassified rows.

### 3.3 Extraction and exact-match results (runs 13 and 14, parser `3C combined v1`)

| Result | Recorded value |
|---|---|
| Field values, value **and** validity equal to the answer key | **50,000 / 50,000 (100.00 %)**; F1 15,280 · F2 9,920 · F3 9,850 · F4 9,860 · F5 5,000 · NONE 90 |
| Curated edge cases EC-001 … EC-150 | 1,500 / 1,500 field values |
| Exact positions (`substr(raw_log, start_pos, length) = value`) | 47,374 / 47,374 stored values; secondary values 1,113 / 1,113 |
| MISSING field rows | 2,626, all with NULL value and NULL position; 0 inconsistencies |
| Look-alike traps (T-08) | 0 overlapping spans; no IP, coordinate or timestamp taken from inside another field |
| Determinism (T-09) | runs 13 and 14 identical in `parsed_log`, `parsed_field`, `parsed_secondary` (0 differences both ways) |
| Regression | 4,995 rows identical to the Step 3B-7 run; F1–F5 each identical to their first accepted run |
| Acceptance tests T-01 … T-10 | **10 / 10 PASS** |

### 3.4 Validity classification

| Field | VALID | INVALID | PLACEHOLDER | MISSING |
|---|---:|---:|---:|---:|
| entity_type | 4,634 | 18 | 42 | 306 |
| email_address | 4,544 | 58 | 109 | 289 |
| resource_url | 4,756 | 15 | 78 | 151 |
| event_timestamp | 4,928 | 62 | 0 | 10 |
| tool | 4,507 | 1 | 160 | 332 |
| latitude | 4,249 | 24 | 66 | 661 |
| longitude | 4,252 | 27 | 67 | 654 |
| ip_address | 4,948 | 38 | 1 | 13 |
| action_phrase | 4,987 | 0 | 0 | 13 |
| status | 4,701 | 12 | 90 | 197 |
| **All** | **46,506** | **255** | **613** | **2,626** |

**Validity results:**
- **Field validity:** all 40 cells equal the answer key and the Step 3A target.
- **Record validity:** VALID 4,750 · INVALID 238 · BROKEN 12, all 5,000 equal to the answer key.
- **IP rule (Step 3B-2):** a plain `inet` cast disagreed with the answer key on 5 of 4,986 labelled IP values (4
  leading-zero IPv4 values accepted, 1 IPv6 zone ID rejected). The adopted VAL-IP rule (strict patterns plus `inet` on
  the part before `%`) agreed on 4,986 / 4,986 values and 43 / 43 probes.

### 3.5 Edge cases

- **BROKEN rows:** 12, made up of 9 NONE rows and 3 truncated rows.
  - The NONE rows are 4 DET-00 cases (SQL NULL, empty, spaces, TAB/CR LF) and 5 DET-NONE cases (literal `NULL`, pipe
    header, 9-semicolon header, `##########`, ANSI escapes and mojibake).
  - The truncated rows are EC-134 (F1, C-06 heuristic), EC-135 (F3 JSON cut inside the resource) and EC-136 (F4 line
    cut inside the user agent).
- **Diagnostics:** equal to the expected register (10 codes, 0 unexpected, 0 missing), including
  `duplicate_field:status` on EC-128.
- **Secondary values** (informational, not part of C-05): 4,990 / 5,000 logs equal the answer key's set. The 10
  differences are all registered answer-key annotation differences (EC-002, EC-030, EC-100, EC-143, EC-110, EC-005,
  EC-036, EC-063, EC-085, EC-142). None affects a primary value, a validity label, record validity or T-01 … T-10.

### 3.6 Raw-data preservation

**How the raw input is protected:**
- **Load:** `log_regex.raw_access_logs` was loaded byte-exactly with client-side `\copy`: 5,000 rows, 1 SQL NULL,
  1 empty string.
- **Fingerprints:** per-row SHA-256 in `raw_log_fingerprint`.
- **Load audit:** `raw_load_audit`.
- **Guards:** 3 read-only guard triggers (`LR001`).
- **Integrity function:** `verify_raw_access_logs()` with 10 checks: row count, `log_id` range and contiguity, NULL and
  empty rows, 1,194,267 characters, 1,194,874 UTF-8 bytes, 0 fingerprint differences, dataset digest, guard triggers.

**Evidence:**
- **Dataset digest:** `1bcff42a6cd6634bd722064b629a0088dbbd7c67ac5276d013c505ac3fb06275`, checked as part of
  `verify_raw_access_logs()`.
- **Where 10 / 10 was recorded:** in every run that called `verify_raw_access_logs()`: Steps 3B-1 … 3C, 5B, 6B (via
  `sql/29`), 7A.2, 7B, 7C and 7F.
- **Steps 6C–6E:** the raw rows were covered by the unchanged `log_regex` digest instead.
- **Export round trip:** byte-identical to the CSV. **Protection tests:** 11 / 11 modification attempts rejected.

### 3.7 Recorded parser limitations

- **Fitted to synthetic data:** the C-06 truncation heuristic and the closed vocabularies were fitted to this dataset.
- **Zone IDs:** syntax checked, meaning not checked.
- **Look-alike rule:** covers IPv4 (the IPv6 look-alike in EC-100 is a registered annotation difference).
- **`outcome_class`:** not computed.
- **Guards:** they stop accidental changes only. A superuser or owner could disable them; checks 8–10 would detect that.
- **Parser role:** a SELECT-only parser role was deferred.

## 4. Flat PostgreSQL schema (`log_regex.access_log_flat`)

### 4.1 Structure

| Item | Recorded design |
|---|---|
| Grain and source | one row per raw log (5,000, including the 9 NONE rows) for one accepted parser run (run 14); secondary values stay in `parsed_secondary` |
| Columns | 71 (18 NOT NULL). Identity `log_id`, `run_id`, `loaded_at`. Record columns `format_family`, `detection_rule`, `sub_format`, `record_validity`, `is_truncated`, `event_end_pos`, `diagnostics text[]`. Per field (× 10): `<f>`, `<f>_validity`, `<f>_start_pos`, `<f>_source`, `<f>_missing_reason`. Plus 11 typed columns |
| Domains | `field_validity_status` (VALID / INVALID / PLACEHOLDER / MISSING), `record_validity_status` (VALID / INVALID / BROKEN), `missing_reason_code` (absent / empty / sentinel) |
| Keys | primary key `(log_id)`, the only index. Foreign keys: `(log_id)` → `raw_access_logs` and `(run_id, log_id)` → `parsed_log`, both `RESTRICT`; plus `ref_entity_type` and `ref_timestamp_shape` |
| Constraints | 22 CHECK constraints: 6 record classification, 10 per-field state, 6 typed columns |
| Text rule | exact values stored as `text`. MISSING = NULL value and NULL position. The literal `NULL` text is PLACEHOLDER text. Empty strings are never stored |

### 4.2 Typed columns (VALID values only; counts after the load)

| Column | Type and rule | Rows |
|---|---|---:|
| `entity_type_code` | validator normalisation | 4,634 |
| `event_timestamp_shape` | first matching reference shape | 4,990 |
| `event_timestamp_local` | `timestamp(6)`; 12 AM → 00, 12 PM → 12; syslog year 2026 | 4,928 |
| `event_timestamp_utc_offset` / `event_timestamp_utc` | `interval` / `timestamptz(6)`, only when the text defines the zone | 2,941 / 2,941 |
| `latitude_degrees` / `longitude_degrees` | `numeric(10,7)`; DMS rounded to 7 places; precision rule `LR008` (0 rejections) | 4,249 / 4,252 |
| `ip_address_inet` / `ip_address_zone_id` | `inet` of the part before `%` / IPv6 zone ID | 4,948 / 1 |
| `status_code` / `status_word` | `smallint` 3-digit code / upper-case word | 2,035 / 2,666 |

### 4.3 Validation and integrity

**Creation and load:**
- **Creation (Step 5B):**
  - **Structure:** `sql/29` S-01 … S-15 PASS (212 probe rows; each of the 22 CHECKs rejects at least one probe).
  - **Foreign keys:** `sql/27` PASS.
  - **Rest of the database:** digest of all other objects and rows unchanged over 160 items.
  - **Refusals:** a second creation, and the destructive `sql/07` / `sql/08`, refuse with `LR003`.
- **Load (Step 5B):**
  - **Transaction and gate:** one transaction, gated on row count, exact round trip and exact substrings.
  - **Checks:** `sql/31` 57 / 57 PASS.
  - **Rows and values:** 5,000 rows; 50,000 / 50,000 field values equal `parsed_field` and the answer key.
  - **Validity:** record validity 4,750 / 238 / 12.
  - **Positions:** 47,374 exact.
  - **Constraints and oracles:** 0 CHECK violations, 0 typed-column oracle mismatches.
  - **Rerun:** a second load refuses (`LR007`).

**Correction found during implementation:** the zone-ID CHECK originally evaluated to NULL, and so passed, for a zone ID
without an `inet` value. The implemented CHECK requires a non-NULL IPv6 `inet`.

**Later role:** `access_log_flat` served as the correctness oracle for every JSON / JSONB query (Step 6) and the source
of every PostGIS table (Step 7). Its rows and constraints were unchanged at every later check (`log_regex` digest
`f8042db0…` over 203 items from Step 6B on; `sql/27` PASS wherever it was run).

### 4.4 Advantages and limitations (as recorded)

**Advantages** (recorded design reasons; no dedicated advantages section exists):
- **Exact values kept:** every extracted value remains, with its validity, position and source.
- **Typed forms only where defined:** a `timestamptz` only where the text defines the zone, instead of inventing a zone
  for the 1,987 VALID timestamps without an offset.
- **Exact coordinates:** `numeric(10,7)` gives exact comparison and the same arithmetic as the validator.
- **IP validity decided by the validator:** `inet` is used only for VALID values, because 4 INVALID leading-zero IPv4
  values are castable.
- **Integrity in the database:** CHECKs, domains and foreign keys enforce the per-row rules.

**Limitations and trade-offs:**
- **`numeric` cost:** larger and slower than `double precision`, and PostGIS needs an explicit cast.
- **Row-level rules only:** only rules decidable within one row can be CHECKs; the exact-substring invariant is
  enforced by the load gate and verification.
- **Unguarded destructive paths:** `TRUNCATE … CASCADE` and a deliberate `DROP TABLE` are not blocked by the guards.
- **No normalised text columns:** email, URL and tool have no normalised typed columns.
- **One run only:** the table holds one run; refreshing from a later run is a separate step.
- **Not benchmarked:** query performance of the flat table against documents was **not measured** (Step 6 used it as
  the oracle only). In Step 7, copies of its numeric coordinates were measured only in the box queries (§6.7) and in
  P3, the distance to every point built from the numeric columns (14.413 ms; Step 7D §6).

## 5. JSON vs JSONB (Steps 6A–6F)

### 5.1 Setup and rule

**Tables and documents:**
- **Tables:** `log_regex_json.access_log_json` and `access_log_jsonb`, identical except the `doc` type.
- **Documents:** 5,000 documents built from `access_log_flat`, one canonical minified text for both types.
- **Equivalence:** `json::jsonb = jsonb` for 5,000 / 5,000; all 70 values round-trip to the flat table.

**Environment:**
- **Hardware and server:** PostgreSQL 17.9 on a Windows 11 laptop (Intel i7-9850H), 8 kB pages, pglz compression,
  `shared_buffers` 128 MB, `work_mem` 4 MB.
- **Durability settings:** `synchronous_commit` on, `wal_compression` off, `data_checksums` off.
- **Sessions:** `jit` off, no parallel workers, warm cache, single client.

**Measurement rule** (Step 6A §9, as recorded in Step 6F):
- **Measurable:** the IQRs of 15 runs do not overlap **and** the medians differ by at least 10 %.
- **Sub-0.1 ms:** the same direction must repeat in a second session.
- **Verification before timing:** every timing counted only after its result was verified (6C / 6D against the flat
  oracle under default and forced plans; 6E 756 / 756 attempts correct).

**Evidence volume:** 6C 1,900 executions; 6D 4,028 executions and 37 builds; 6E 756 attempts.

### 5.2 Storage (fair)

| Measure | json | jsonb | Recorded difference |
|---|---:|---:|---|
| Uncompressed document size (sum) | 8,436,033 | 10,084,876 | jsonb +19.5 % |
| Stored document bytes (`pg_column_size`) | 8,434,066 | 7,219,683 | jsonb −14.4 % |
| Documents compressed inline | 1 | 2,880 (57.6 %) | — |
| Out-of-line TOAST documents | 0 | 0 | — |
| Heap | 10,240,000 (1,250 pages) | 8,036,352 (981 pages) | jsonb −21.5 % |
| Output text | canonical text preserved exactly | reordered and re-spaced (+151–152 bytes per document) | — |

**Storage caveat:** the inverted stored size is recorded as a **TOAST inline-compression threshold effect of this
dataset**. It is not a general property.

### 5.3 Extraction and query performance without secondary indexes (fair, Step 6C)

| Access pattern | Result |
|---|---|
| Whole documents: Q01 one by primary key; Q02 all 5,000 | **json faster**: 0.012 vs 0.030 ms; 2.956 vs 68.709 ms (jsonb serialisation to text) |
| Value extraction, filters, aggregates, `JSON_VALUE` / `JSON_EXISTS` (23 statements) | **jsonb faster in all 23**, ratios 0.08–0.49 (e.g. Q05 1,069.9 vs 81.9 ms; Q06 7,413.2 vs 592.2 ms) |
| Planning time | no measurable difference |

Plans, row estimates and results were identical on both types (only the Q17 / Q18 group-count estimate differed).

### 5.4 B-tree expression indexes (fair, Step 6D configuration I-1)

**Setup:** the same five btree expression indexes were built on both types (`record_validity`, `entity_type.code`,
`status.code::integer`, `latitude.degrees::numeric`, `event_timestamp.utc`).

| Situation | Result |
|---|---|
| Index answers the predicate (7 statements) | **no measurable difference** |
| Index narrows, documents still read (Q16); planner keeps a sequential scan (Q11b, Q17); control Q09 | **jsonb faster** |
| Index size and build WAL | identical (499,712 bytes per table; WAL within 48 bytes) |
| Build time per index | json 66.3–122.4 ms vs jsonb 16.3–20.6 ms |
| Index effect per type (control → I-1) | json about 14× (Q16) to 9,600× (Q12a); jsonb about 8.5× to 860× |
| Planner blind spot (Q11b) | sequential scan and index path costed almost equally. The forced index path took 1.236 ms vs 184.0 ms on json and 1.137 vs 21.6 ms on jsonb |

### 5.5 JSONB-only GIN capabilities (separate — not a json vs jsonb verdict)

json has no `@>`, `?`, `@?`, `@@` operators, no GIN operator class and no `jsonb_set`.

**Read benefit:** containment and jsonpath statements took 10–12 ms without GIN and 0.03–0.8 ms with it.

| Measured cost | `jsonb_ops` | `jsonb_path_ops` |
|---|---|---|
| Size | 4,521,984 bytes (56 % of heap) | 3,727,360 bytes (46 %) |
| Build | 554.4 ms | 243.7 ms |
| Build WAL | 2,413,808 bytes | 1,958,528 bytes |
| W1 bulk insert vs X-1 (Step 6E) | ×3.49 time, ×2.82 WAL | ×2.22 time, ×2.09 WAL |
| UA-1 238-row update vs X-1 (Step 6E) | ×1.96 time | ×1.51 time |

**Findings:**
- **`jsonb_path_ops`:** smaller, faster to build, faster to query and cheaper to maintain in every measured statement.
- **Not indexable by GIN on `doc`:** `?` on a nested expression, and `JSON_EXISTS`.
- **Both GIN indexes together vs X-1:** bulk insert ×4.33 time and ×3.90 WAL.

### 5.6 INSERT cost (fair, Step 6E)

| Statement | Without secondary indexes (X-0) | With the 5 btree expression indexes (X-1) |
|---|---|---|
| W1 bulk insert of 5,000 | **json faster** (jsonb / json 1.82) | **jsonb faster** (0.51) |
| W1b 250 single-row inserts | **json faster** (2.52; session 2: 2.31) | **jsonb faster** (0.54; session 2: 0.59) |

### 5.7 UPDATE cost — full-document replacement (fair, Step 6E)

| Statement | X-0 (jsonb / json) | X-1 (jsonb / json) |
|---|---|---|
| UA-1 238 rows, indexed path changed | **json faster** (2.15) | **jsonb faster** (0.55) |
| UA-2 238 rows, non-indexed path | **json faster** (2.01) | **jsonb faster** (0.55) |
| UA-3 5,000 rows | **json faster** (1.29) | **jsonb faster** (0.59) |

**Row-version behaviour (identical on both types):**
- **Dead tuples:** every updated row left one.
- **HOT updates:** almost never (none with the expression indexes).
- **New pages:** nearly every new version went to another page; UA-3 doubled the heap.
- **Indexed vs non-indexed path:** with X-1, changing a non-indexed path cost the same as changing an indexed one.

### 5.8 Partial-update observations (separate, mechanism-specific)

| Mechanism (X-1) | 238 rows | 5,000 rows | Stored result |
|---|---|---|---|
| `jsonb_set` on jsonb | 39.2 ms | 932.8 ms | expected document |
| text `regexp_replace` on json | 106.8 ms | 1,933.7 ms | canonical text preserved |
| `jsonb_set(doc::jsonb)::json` on json | 131.6 ms | 2,496.2 ms | semantically equal, every text differs from canonical (+9.0 % text bytes) |

**Findings:**
- **Fastest:** `jsonb_set` was the fastest partial-update mechanism measured.
- **Slowest:** round-tripping json through jsonb was the slowest, and it lost the canonical text.

### 5.9 WAL and write overhead (fair, Step 6E)

**WAL by write type:**
- **Whole-table writes and single-row inserts:** jsonb wrote 8–13 % less WAL.
- **238-row updates:** jsonb wrote 5.6–6.1 % more WAL (cause not isolated; a plausible explanation is recorded as
  unverified).

**Cost of the five btree expression indexes (X-0 → X-1):**
- **Same on both types:** WAL, index growth and index size.
- **Different:** maintenance **time**, json ×2.5–6.6 vs jsonb ×1.1–1.4.

### 5.10 Final Step 6F conclusion (unchanged)

Within this dataset, PostgreSQL 17.9 environment and single-client, warm-cache workload, **neither type was better
across the board**. The results split by access pattern:
1. **Storing and returning documents unchanged, without secondary indexes on document paths:** json was measurably
   faster (inserts, full-document updates, whole-document reads) and preserved the input text exactly. jsonb stored
   14 % fewer bytes and wrote less WAL for whole-table writes, but only because of the compression threshold.
2. **Reading values out of documents:** jsonb was measurably and consistently faster for every extraction, filter,
   aggregate and SQL/JSON function tested without indexes, by about 5–13×.
3. **Identical btree expression indexes:** index-answered queries showed no difference. Every plan that still read
   documents was faster on jsonb, and writes were measurably faster on jsonb, because json paid text parsing for every
   index entry. Index sizes and WAL were identical.
4. **Containment and jsonpath search:** only jsonb could use GIN. Speedups were large, and so were the write, WAL and
   storage costs.
5. **Partial updates:** only jsonb has a native path update (`jsonb_set`), the fastest mechanism measured. On json,
   keeping the canonical text required a text rewrite; the jsonb round trip changed the stored text.

Step 6F does **not** claim that these ratios hold for other document sizes, compression settings, index sets, data
volumes, concurrency, cold caches, hardware or PostgreSQL versions.

## 6. PostGIS (Steps 7A–7F)

### 6.1 Setup and verification

**Installation (7A.1 / 7A.2):**
- PostGIS 3.6.2 (GEOS 3.14.1dev, PROJ 8.2.1) was installed **manually**; an automated installation was not possible
  without administrator rights.
- The post-installation verification passed with one recorded deviation: four installer environment variables, unused
  by the experiment.

**Setup (Step 7B, 317 PASS / 0 FAIL):**
- **Placement:** extension in schema `postgis`.
- **Tables:** experiment schema `log_regex_gis` with 15 tables of 5,000 rows, copied once from `access_log_flat` and
  `access_log_jsonb`. They cover numeric, geometry and geography points, JSONB documents, expression-index and stored
  generated-column variants, and a no-index control for every indexed table.

**Experiment (Step 7C, 943 PASS / 0 FAIL / 0 FLAG):**
- **Indexes:** 10 indexes, 3 timed builds each.
- **Queries:** 192 query × configuration series in two read-only sessions (7,680 executions).
- **Correctness:** 2,424 / 2,424 checks against plain-SQL oracles on `flat_numeric`, in three plan modes.

**Settings:** `jit` off, no parallel workers, `shared_buffers` 128 MB, `work_mem` 4 MB; AC power required; 0 other
active sessions.

**Rule (Step 6A, as applied in Step 7C):**
- **Measurable:** IQRs do not overlap **and** the faster median is ≤ 90 % of the slower.
- **Sub-0.1 ms:** confirmed in session 2.
- **Which comparisons count:** only interleaved within-block comparisons get verdicts.

**Comparison classes:**
- **Fair:** I (index vs control), IM (index method), F (flat vs JSONB, same type and index).
- **Representation- or method-specific:** J (JSONB storage forms), GG (geometry vs geography), NB (numeric B-tree vs
  spatial).

### 6.2 Geometry vs geography (method comparison, different semantics)

| Workload | Recorded finding |
|---|---|
| Distance filters in metres, all 7 centres | Geography + GiST returned the haversine-oracle sets everywhere, including across the antimeridian (D5, 262 rows) and at the pole (D7, 1 row). Measurable benefit in all 14 series (1.41–103×) |
| Nearest neighbours in metres | geography GiST 0.105 ms (K1) / 0.273 ms (K2); geography `<->` orders by sphere distance |
| Degree boxes | measured on geometry and numeric only; the antimeridian box B5 needs two envelopes in geometry |
| Nearest neighbours in degrees | geometry GiST 0.054–0.074 ms; planar degree order is not metre order (K1 vs K1g: 8 of 10 rows common) |
| Geometry `&&` box + `ST_DistanceSphere` (mid-latitude D1, D2, D6 only) | geography faster at 10 km (0.438 vs 0.597 ms) and 500 km (1.146 vs 1.798 ms); geometry faster at 1 km (0.071 vs 0.116 ms) and in planning (0.09 vs 0.46–0.50 ms) |
| Cost | geography GiST 393,216 vs geometry GiST 212,992 bytes (1.85×, *derived*); build 13.1 vs 9.1 ms median (consistent); geography distance planning 0.43–1.30 ms with an index vs 0.03–0.04 ms without |
| Semantics (7B) | (0, 180)–(0, −180) is 0 m as geography and 360° as geometry; mixing SRIDs raises an error |

### 6.3 GiST vs SP-GiST vs BRIN (fair, class IM)

| Method | Recorded result |
|---|---|
| **GiST** | Faster than SP-GiST for B5, B6, 13 of 14 geography distance series and the nearest-neighbour queries K1, K2 and K3 (K1g had no SP-GiST configuration); not measurably different for B1–B4 and D5. The only method with an ordering operator |
| **SP-GiST** | Never measurably faster than GiST. Nearest neighbours not supported. Geometry index 31 % larger with 40 % more WAL; geography index 4 % smaller with 28 % more WAL |
| **BRIN** | Not used for 5 of 6 boxes, regression on B5, nearest neighbours not supported. Cheapest index (24,576 bytes, 2,024 bytes WAL, 3.3 ms) |
| Planning | the index method did not change planning time (0 of 37 measurable) |

### 6.4 Spatial index benefits and limitations (fair, class I)

**Verdicts** (109 index-vs-own-control series):

| Verdict | Series |
|---|---:|
| measurable benefit | **90** |
| index used, no measurable benefit | 5 |
| measurable regression | 3 |
| index not used by the planner | 7 |
| not supported (no ordering operator; kept separate) | 4 |

**Benefit by result size:**

| Rows returned | Benefit |
|---|---|
| 0–15 | 6.1–930× |
| 100 | 11.5–20.3× |
| 262–1,101 (5–22 %) | 1.6–17.7× |
| 1,580–3,897 (32–78 %) | 1.14–3.06×, in 11 of 20 series |

**Poor choices and non-use:**
- **Regressions:** geometry GiST and SP-GiST on the 78 % box B4 (plain index scans chosen with an estimate of 4,740 of
  5,000 rows), and BRIN on B5.
- **Not used:** BRIN (B1–B4, B6), and the numeric B-tree on B4 and on the `OR` antimeridian box B5.
- **Row estimates:** geography `ST_DWithin` was always estimated at 1 row; boxes were misestimated by up to 14×; MD
  queries by up to 205×.

**BRIN limitation:**
- **One block range:** `flat_geom_brin`, like the other flat geometry and geography tables, has **39 heap pages**, below
  the default `pages_per_range` of 128. The whole table is one block range, whose summary covers the whole globe.
- **Effect:** every BRIN scan returned all 39 blocks as lossy and rechecked every row.
- **Scope:** larger tables and other `pages_per_range` values were not tested.

**Planning overhead:**
- **Direction:** the indexed table planned measurably slower in 97 of 109 series and never faster.
- **Totals (*derived*):** on per-run planning + execution totals the index was faster in 88 series and the control in 8.
- **D4-s on geography GiST:** the planning increase (1.096 ms) exceeded the execution saving (0.799 ms).

### 6.5 Flat vs JSONB coordinates (fair, class F — same type, same index, same query)

| Pairing | Flat faster | Not measurable | JSONB faster |
|---|---:|---:|---:|
| Indexed (23 series) | 14 (1.17–1.72×) | 9 | **0** |
| No index (23 series) | 21 (1.11–1.85×) | 2 | **0** |

**What was the same:** index size, build WAL, build time (ranges overlap), planning time (0 of 46 measurable) and results.

**What differed:** the JSONB heap also stores the documents (879 vs 39 pages); this is reported, not corrected.

### 6.6 JSONB expression index vs stored generated column (JSONB-specific, class J)

| Aspect | Expression GiST index | Stored generated column + GiST |
|---|---|---|
| Query speed | slower | **faster in 21 of 23** |
| Build | 38.4 / 40.5 ms | **9.7 / 13.4 ms** (3–4× faster, consistent) |
| Index size | 212,992 / 393,216 bytes | identical |
| Without any index | building the point from the document per row was the slowest option (24–47 ms per box query; stored column 3.7–22.8× faster) | — |

**Not measured:** the write and maintenance cost of generated columns vs expression indexes.

### 6.7 Bounding-box, distance and nearest-neighbour findings

**Bounding boxes:**
- **Selective boxes (410–416 rows):** geometry GiST 3.35–3.40× and numeric B-tree 2.29–3.14× faster than their
  controls. The numeric B-tree was faster than GiST on B1 and equal on B2 (class NB).
- **Polar cap B6:** B-tree 0.018 ms, GiST 0.024 ms (B-tree faster).
- **Antimeridian box B5:** GiST 0.038 ms, 24× faster than the unused B-tree.
- **Large box B3 (1,580 rows, 32 %; class I):**
  - **Flat-table indexes:** only the numeric B-tree helped (1.65×). The flat geometry GiST and SP-GiST gave no
    measurable benefit, and BRIN was not used.
  - **JSONB GiST indexes:** both had recorded measurable benefits: the expression index J-1 (2.82×, against a control
    that builds every point from the document) and the stored-column index J-3 (1.36×).
- **Large box B4 (3,897 rows, 78 %; class I):**
  - **Lowest medians:** the tables scanned sequentially (numeric 1.224 ms, geometry 1.612 ms).
  - **Flat-table indexes:** the flat geometry GiST and SP-GiST regressed; the B-tree and BRIN were not used.
  - **JSONB GiST indexes:** J-1 had a measurable benefit (1.14×, against its on-the-fly control); J-3 had none.
- **Without index:** numeric `BETWEEN` was faster than `ST_Intersects` in all 6 boxes (1.30–1.74×).

**Distances:**
- **Result size:** the benefit fell with result size: GiST 29–657× for 1–15 rows, 2.3–3.1× at 41 % of rows (D4), and
  1.4–2.0× on the sphere variant D4-s.
- **Candidates:** the index condition `geog && _st_expand(centre, r)` returned exactly the result rows for D1–D4 and
  D7.

**Nearest neighbours:**
- **GiST:** 0.054–1.456 ms, touching 13–14 buffers for 10 rows and 100–104 for 100; 11.5–173× faster than a sequential
  scan plus sort.
- **SP-GiST and BRIN:** no index path.
- **Ties:** no tie at rank 10 or 100 in this data. The statements have no tie-breaker (design decision).

### 6.8 Sphere vs spheroid (Step 7B finding)

| Check | Result |
|---|---|
| Sphere `ST_Distance` vs haversine (R = 6,371,008.7714 m) | max difference 0.0000473 m |
| Spheroid vs sphere | max relative difference 0.452 % |
| Points within ±0.6 % of any tested radius | 0 |
| Consequence | spheroid and sphere `ST_DWithin` returned identical sets for D1–D7 on every configuration |
| Geography `<->` | sphere distance (within 5.0 × 10⁻⁹ m of it) |
| Cost | interleaved distance to all points: sphere 5.188 vs spheroid 10.226 ms (measurable). Non-interleaved *derived* ratios: spheroid 1.55–3.38× the sphere cost without an index (Y-0, J-4c), 0.95–1.25× with one (Y-1, Y-2, J-4; D5 up to 2.81×); J-0y and J-2 are not included in these ranges |

### 6.9 Final Step 7E conclusion (one scope correction) and Step 7F state

**Step 7E** (scoped to this data and environment):
- **Index method:** GiST is the method to use; SP-GiST was never measurably faster; BRIN gave no benefit on 39-page
  tables.
- **Metric workloads:** geography + GiST for metric distance and metric nearest neighbours.
- **Degree workloads:** geometry + GiST for degree boxes and planar nearest neighbours.
- **When indexes pay off:** mainly selective queries (up to about 22 % of rows) and nearest neighbours. At larger
  result sizes the benefits were smaller: 1.14–3.06× in 11 of 20 series at 32–78 %, including the 41 % distance query
  D4.
  - **Boxes returning 32–78 % of rows, flat-table indexes:** the GiST, SP-GiST and BRIN indexes gave no benefit, were not
    used, or regressed (B4).
  - **Same boxes, other indexes:** the JSONB GiST indexes still had measurable benefits (J-1 on B3 and B4, J-3 on B3),
    and the numeric B-tree helped on B3. See the scope correction below.
- **Where points live:** flat coordinates are faster or equal to JSONB coordinates with the same type and index. Within
  JSONB, a stored generated column beats an expression index for reads.
- **Sphere vs spheroid:** identical sets here; the sphere was measurably faster for computing the distance to every
  point, and cheaper wherever many rows reach the distance function.
- **Write workloads:** no recommendation; not measured.

**Scope correction (final audit, 13/09/2026):**
- **Original wording:** Step 7D §7 and Step 7E §1 item 4 / §5 say that spatial indexes did not pay off for boxes
  returning 32–78 % of rows.
- **What the recorded class I verdicts show:** this holds for the flat-table geometry GiST, SP-GiST and BRIN indexes
  only (0 benefits in 6 series). J-1 had measurable benefits on B3 (2.82×) and B4 (1.14×), and J-3 on B3 (1.36×)
  (`analysis/step7/step7c_summary.md:42`, `:43`, `:48`).
- **Handling:** Step 7D and Step 7E are hash-locked by the Step 7F manifest and were not edited. The scoped statement
  above supersedes their wording.

**Step 7F (Option A, 343 PASS / 0 FAIL):**
- **Dropped:** the 10 Step 7C indexes, with `sql/52` in one transaction after a rolled-back harness.
- **Kept:** the 15 `log_regex_gis` tables (5,000 rows each, fingerprints unchanged) and PostGIS 3.6.2.
- **Verification:** `sql/47` 155 / 155 and `sql/50 phase before` 113 / 113.
- **Catalog and statistics:** returned exactly to the recorded Step 7B values.

## 7. Consolidated comparison table

"Measured evidence" cites recorded results; details are in §3–§6 and the step reports.

| Approach | Strengths | Weaknesses | Measured evidence | Appropriate workload / use case (tested scope) |
|---|---|---|---|---|
| **PostgreSQL regex parser** (`log_regex`, F1–F5 + NONE) | exact values with positions, validity labels, secondary values, deterministic, set-based | heuristics and vocabularies fitted to synthetic data; zone IDs syntax-only | 50,000 / 50,000; 47,374 positions; T-01 … T-10 PASS | extracting the 10 fields from these five log formats |
| **Immutable raw table** (guards, fingerprints, digest) | proves the input unchanged at every recorded check | guards stop accidental changes only | integrity 10 / 10 wherever checked (Steps 3B-1 … 3C, 5B, 6B, 7A.2, 7B, 7C, 7F); `log_regex` digest unchanged from 6B to 7F; 11 / 11 modification attempts rejected | the source of record for all derived data |
| **Flat typed table** `access_log_flat` | typed, constrained, exact text kept, foreign-key lineage | one run; `numeric` cost; `TRUNCATE CASCADE` / `DROP` unguarded | 57 / 57 load checks; 22 CHECKs; 0 violations | structured store and correctness oracle; typed filtering (query speed vs documents not measured) |
| **json** documents (fair) | exact text preserved; fastest whole-document return; fastest writes without path indexes | about 5–13× slower value extraction without indexes (Q03 about 2×); slow btree index maintenance | Q02 2.956 vs 68.709 ms; W1 X-0 jsonb / json 1.82; X-1 maintenance ×2.5–6.6 | store and return documents unchanged, no path indexes |
| **jsonb** documents (fair) | fastest value extraction, filters, aggregates; faster writes with btree expression indexes; smaller here (TOAST effect) | slower whole-document return; normalised text | 23 / 23 extraction statements faster; W1 X-1 0.51; heap −21.5 % | documents queried by value; indexed document paths |
| **Btree expression indexes on JSON paths** (fair) | identical size and WAL on both types; large read gains | write-time cost (json ×2.5–6.6, jsonb ×1.1–1.4) | no difference for index-answered queries; effects 8.5–9,600× | selective filters on known paths |
| **GIN `jsonb_path_ops`** (jsonb-only) | containment / jsonpath 10–12 ms → 0.027–0.528 ms (0.03–0.8 ms across both GIN types); cheaper than `jsonb_ops` | size 46 % of heap; write ×2.22 time, ×2.09 WAL (bulk) | Step 6D / 6E | containment and jsonpath search on jsonb |
| **GIN `jsonb_ops`** (jsonb-only) | also supports key-existence operators | larger, slower, costlier than `jsonb_path_ops` in every measured statement | 56 % of heap; build 554.4 ms | only if key-existence operators are needed (not exercised) |
| **`jsonb_set`** (jsonb-only) | fastest partial update | no json counterpart; on json the text rewrite kept the canonical text but was slower, and the jsonb round trip changed the text | 39.2 ms / 238 rows; 932.8 ms / 5,000 rows | path-level updates of jsonb documents |
| **geometry + GiST** (index vs control: class I; type difference: method comparison GG) | degree boxes, planar nearest neighbours; smaller index | not metric; antimeridian needs two envelopes; flat-table index regressed on the 78 % box | B1 / B2 3.35–3.40×; K3 (10 nearest, New York) 22.3×; B4 regression 1.57× | selective degree boxes, planar nearest neighbours |
| **geography + GiST** (index vs control: class I; type difference: method comparison GG) | correct metric distances everywhere including antimeridian and pole; metric nearest neighbours | planning 0.43–1.30 ms; index 1.85× geometry | 14 / 14 distance series with benefit; K1 29.1× | metric distance filters and nearest neighbours |
| **SP-GiST** (geometry / geography; fair, class IM) | usable for boxes and distances | never faster than GiST; no nearest-neighbour support; more WAL | IM: 0 SP-GiST wins | not recommended here |
| **BRIN** (geometry; fair, classes I / IM) | smallest and cheapest to build | one lossy block range on 39 pages; not used or regression | 0 of 7 benefits | not appropriate for tables of this size |
| **Numeric B-tree (lat, lon)** (index vs control: class I; vs GiST: method comparison NB) | fastest for some selective non-wrapping boxes; no PostGIS needed | not used for the `OR` antimeridian box or the 78 % box | B1 1.35× and B6 1.33× faster than GiST (NB) | selective, non-wrapping degree boxes |
| **Flat coordinates vs JSONB coordinates** (fair) | flat never slower | JSONB heap carries documents | indexed 14 flat faster / 9 = / 0 JSONB | spatial reads: keep points in the flat table |
| **JSONB stored generated column vs expression index** (JSONB-specific) | stored: faster reads, 3–4× faster build, same index size | write cost not measured | 21 / 23 faster | points that must stay in JSONB documents |
| **Sphere vs spheroid** (Step 7B finding; method comparison) | same sets here; sphere measurably faster for the distance to every point | up to 0.452 % difference; sets could differ near that band (not tested) | distance to every point: P2 (sphere) 5.188 vs P1 (spheroid) 10.226 ms | sphere where its answers suffice for these points and radii |

## 8. Final recommended architecture for this project

This architecture is **assembled only from the recorded decisions and conclusions** of Steps 3–7. It adds no new
measurement, and no new object was built for it.

```text
data/raw_access_logs.csv
  |  \copy, byte-exact (Step 3B-1)
  v
log_regex.raw_access_logs          immutable: guard triggers, per-row fingerprints, dataset digest, verify_raw_access_logs()
  |  PostgreSQL regex parser: detect_format(), f1..f5_candidates(), run_parser(), ref_* vocabularies
  v
parser_run / parsed_log / parsed_field / parsed_secondary      accepted run 14 (50,000 / 50,000; T-01..T-10 PASS)
  |  sql/30 load: typed conversions, CHECKs, domains, foreign keys
  v
log_regex.access_log_flat          primary structured store (exact text + validity + positions + typed columns)
  |
  +-- optional document layer: jsonb for value queries; GIN jsonb_path_ops only for containment/jsonpath search
  |                            (json only when exact document text and whole-document return are the requirement)
  |
  +-- optional spatial layer:  geography(Point,4326) + GiST for metric distance / nearest neighbours
                               geometry(Point,4326)  + GiST for degree boxes / planar nearest neighbours
                               points taken from the flat typed coordinates; if they must live in JSONB,
                               a stored generated column + GiST (not an expression index)
```

| Layer | Recommendation for this project | Basis |
|---|---|---|
| Raw input | keep the immutable, fingerprinted raw table as the source of record | T-01 / T-02 PASS; 10 / 10 integrity wherever checked through Step 7F (§3.6) |
| Parsing | keep the validated PostgreSQL regex parser and its run tables; publish one accepted run | C-05 met; runs 13 and 14 identical |
| Structured store | `access_log_flat` as the primary store and oracle | 57 / 57 load checks; used as oracle in Steps 6–7 |
| Documents (optional) | **jsonb** when documents are queried by value or by containment / jsonpath; btree expression indexes for known selective paths; `jsonb_path_ops` rather than `jsonb_ops`. **json** only for unchanged-document storage and return without path indexes | Step 6F §4, §8, §11 |
| Spatial (optional) | **GiST** only. Geography for metres, geometry for degrees. Points in flat columns. No BRIN or SP-GiST at this table size. The flat-table GiST / SP-GiST / BRIN indexes gave no benefit for boxes returning 32–78 % of rows (JSONB GiST results differ; §6.7, §6.9) | Step 7E §1, §13; class I verdicts (§6.7) |
| Experiment objects | `log_regex_json` (Step 6D index set) and `log_regex_json_write` (write tables empty) remain as recorded in Step 6F. `log_regex_gis` is kept without secondary indexes for reproducibility (Step 7F Option A). These retained experiment objects are not the recommended architecture: `log_regex_json` still holds the json table and GIN `jsonb_ops`, no spatial GiST index remains, and the `log_regex_gis` tables are experiment copies | Step 6F §13, Step 7F §8 |

## 9. Clear decisions

### 9.1 What should be used (for the tested data and workloads)

1. **Raw data:** the immutable raw table with fingerprints, digest and guard triggers.
2. **Parsing:** the PostgreSQL regex parser, including the VAL-IP rule rather than a plain `inet` cast for IP validity.
3. **Structured store:** `access_log_flat` with exact text, validity, positions and typed columns.
4. **Document value queries:** **jsonb** (23 / 23 extraction statements faster).
5. **Selective JSON-path filters:** **btree expression indexes** (no json / jsonb difference when index-answered).
6. **Containment and jsonpath search on jsonb:** **GIN `jsonb_path_ops`**, cheaper than `jsonb_ops` in every measured
   statement. Its write, WAL and size costs must be accepted.
7. **Partial updates of jsonb documents:** **`jsonb_set`**.
8. **Spatial indexes:** **GiST**. **Geography + GiST** for metric distance filters and nearest neighbours (correct
   across the antimeridian and pole). **Geometry + GiST** for selective degree boxes and planar nearest neighbours.
9. **Points for spatial reads:** keep them in **flat columns**. Where points must stay in JSONB, use a **stored
   generated column + GiST**.

### 9.2 What should not be used (in the tested scope)

1. **json for value extraction, filtering or aggregation** (about 5–13× slower without indexes; ratios 0.08–0.49, Q03
   about 2×).
2. **Round-tripping json through jsonb for partial updates:** slowest mechanism measured, and it changes the stored
   text.
3. **BRIN with default `pages_per_range` on tables of about 39 pages:** single lossy block range; not used, or slower.
4. **SP-GiST for these spatial workloads:** never faster than GiST; no nearest-neighbour support.
5. **Flat-table geometry GiST, SP-GiST or BRIN indexes for boxes returning 32–78 % of rows:** no benefit, not used,
   or regression (B4). This does not apply to the JSONB GiST indexes, which had measurable benefits on these boxes
   (J-1 on B3 and B4, J-3 on B3).
6. **Building points from JSONB per row without an index:** slowest spatial option measured (24–47 ms per box query).
7. **A JSONB expression GiST index** where a stored generated column is possible (slower reads in 21 of 23 series,
   3–4× slower build).
8. **Plain `inet` castability as the IP validity rule:** it disagreed with the answer key on 5 values.

### 9.3 Where the choice depends on the workload

| Choice | Depends on | Recorded evidence |
|---|---|---|
| json vs jsonb for storing and returning unchanged documents | whether exact text and whole-document return matter more than value access | json faster for whole documents and for writes without path indexes; jsonb smaller here only through the TOAST threshold effect |
| Adding btree expression indexes on documents | read selectivity vs write volume | large read effects; write-time cost json ×2.5–6.6, jsonb ×1.1–1.4; identical WAL |
| Adding GIN indexes | frequency of containment / jsonpath search vs write load and storage | read 10–12 ms → 0.03–0.8 ms; write time ×1.5–4.3, WAL up to ×3.9, size 46–56 % of heap |
| Numeric B-tree vs geometry GiST for degree boxes | antimeridian wrapping and selectivity | numeric B-tree table faster for B1, B3, B4 and B6 (on B4 its index was not used; the table ran a sequential scan); GiST for the antimeridian box B5 |
| Geography `ST_DWithin` vs geometry box + `ST_DistanceSphere` | centre location and radius | geography faster at 10 km and 500 km; geometry faster at 1 km; geometry method untested at the antimeridian and pole |
| Sphere vs spheroid | the accuracy the application needs | identical sets here; up to 0.452 % distance difference; sphere measurably faster for the distance to every point |
| Spatial index for large-radius distances | whether planning time counts | D4-s: planning increase exceeded the execution saving |
| Keeping or removing experiment objects | reproducibility vs footprint | Step 7F Option A kept `log_regex_gis` (about 50.2 MB) |
| Any write-heavy spatial workload | — | **not measured**; no decision possible |

## 10. Data integrity, reproducibility and isolation achievements

**Raw input never modified:**
- **Integrity checks:** `verify_raw_access_logs()`, including the dataset digest `1bcff42a…`, returned 10 / 10 in every
  run that called it: Steps 3B-1 … 3C, 5B, 6B (via `sql/29`), 7A.2, 7B, 7C and 7F.
- **Steps 6C–6E:** the raw rows were covered by the unchanged `log_regex` digest.
- **Step 1 files:** `generate_raw_logs.py --check` confirmed them identical.

**Derived data proven unchanged across steps:**
- **`log_regex` digest:** `f8042db0…` over 203 items (raw, parser output, flat table, answer key), from Step 6B to Step
  7F.
- **`log_regex_json` data digest:** `9e6f8831…` over 10 items.
- **Step 6D index digest:** `e20752ca…` (14 indexes, 9,510,912 bytes).
- **Step 6E write-schema state and source fingerprints:** `f562354d…` / `fb3bc163…`.

**Verification scripts, and the step runners that ran them (before or after the writing stages, or inside rolled-back
harnesses, as recorded per step):**

| Script | What it verifies | Result | Run by the runners of |
|---|---|---|---|
| `sql/27` | flat foreign keys | PASS | Steps 5B, 6B, 7B, 7C, 7F |
| `sql/29` | flat structure | S-01 … S-15 | Steps 5B, 6B |
| `sql/31` | flat load | 57 checks | Steps 5B (populate), 6B |
| `sql/34` | Step 6B | 38 checks | Steps 6B, 6C, 6D, 6E, 7B, 7C, 7F |
| `sql/38` (phase final) | Step 6D | 70 checks | Steps 6D (every phase), 6E, 7B, 7C, 7F |
| `sql/47` | Step 7B | 155 checks | Steps 7B, 7C, 7F |
| `sql/50` | Step 7C | 113 / 745 checks | Steps 7C, 7F |

**Baseline manifests (SHA-256), all verified 0 mismatches at Step 7F:**
- Step 6C: 11 files
- Step 6D: 26 files
- Step 7B: 14 files
- Step 7F: 32 files, including the Step 7C outputs, the Step 7C–7E reports and the sample data

**Isolation:**
- **One schema per experiment:** `log_regex_json`, `log_regex_json_write`, `postgis`, `log_regex_gis`.
- **No dependency edges** between the experiment schemas and the existing ones (Step 7F: 0 objects outside the PostGIS
  schemas depend on PostGIS).
- **`public`:** stayed empty (0 / 0 / 0).

**Safe execution pattern (scope per step as recorded):**
- **Guard SQLSTATEs** (`LR001` … `LR026`, Steps 3–7): they refuse unsafe runs and reruns, and report failed
  verifications and precision violations.
- **Static checks in the runners:** forbidden-statement and ASCII checks from Step 5B on. SQL generated by Python
  scripts with static statement allowlists from Step 6C on.
- **Rolled-back harnesses before real writes** (Steps 5B, 6B, 6D, 7B, 7C, 7F). The Step 6E preflight also created its index
  definitions inside a rolled-back transaction.
- **Read-only sessions** for measurements and verifications from Step 5B on. The Step 3B-1 protection tests ran in
  rolled-back sub-transactions.
- **Single-transaction writes:** the Step 5B load, the Step 7B scripts, and Step 7F `--single-transaction` with
  `lock_timeout` 5 s.

**Reproducibility:**
- **Dataset:** seeded generator with `--check`.
- **Runners:** every step that wrote to the database or ran measurements has a runner script (`sql/run_step*.ps1`).
  - **Without a runner:** Step 3B-2 used a single read-only script. The documentation and read-only verification steps
    (4A, 5A, 6A, 6F, 7A, 7A.1, 7A.2, 7D, 7E) have none.
  - **Where results are stored:** Step 6–7 check and measurement outputs are in `analysis/`; Step 3–5 results are
    recorded in the step documents.
- **Parser validation:** reproducible with `sql/run_step3c_combined_parser.ps1`.
- **Spatial indexes:** rebuildable exactly from `sql/49` (Step 7F §6.3).

**Honest reporting of failures and deviations:**
- the initial PostGIS installation failure (7A.2)
- false-positive runner detections (7B, 7C)
- the Step 6E CPU slowdown
- index-size variation across builds (7C)

## 11. Performance methodology and important measurement caveats

**Methodology (Steps 6A, 6C–6E, 7C):**
- **Correctness first:** every timed read statement was verified before and after timing, in default and forced plan
  modes, against an oracle: the flat table in Step 6C / 6D, plain SQL on `flat_numeric` in Step 7C. Step 6E instead
  verified every write attempt against the expected documents.
- **Fixed session settings:** `jit` off, no parallel workers, UTC, `track_io_timing` on. Planner settings at server
  defaults, captured with `EXPLAIN (SETTINGS)`.
- **Rounds:** 3 warm-up and 15 measured rounds, interleaved across the compared configurations. The order was:
  - Step 6C / 6D: json / jsonb alternated.
  - Step 6E: json / jsonb in ABBA order by round, with the configuration order reversed every round.
  - Step 7C: configurations rotated and reversed on alternate rounds.
- **Second batch or session:**
  - Step 6C batch 2 reproduced every direction.
  - Steps 6D and 7C used a second batch or session, required for medians below 0.1 ms.
  - The Step 6E second session covered W1b only.
- **Verdict rule:** IQR non-overlap plus a 10 % median threshold (Step 7: faster median ≤ 90 % of slower). Only
  within-session, interleaved ratios are compared. Forced-plan timings never carry a verdict.
- **Recorded per execution:** plan shapes, buffers, planning time, estimates vs actual rows and (Step 6E) WAL.
- **Measurement commands:**
  - **Measured runs:** `EXPLAIN (ANALYZE, TIMING OFF, …)` in Steps 6C, 6D, 6E and 7C, with the option set of each step
    as recorded in its report. Step 6E added `WAL`; the W1b loop ran without `EXPLAIN`.
  - **Detail runs:** `TIMING ON`.

**Caveats:**
1. **Single machine.** One Windows laptop, PostgreSQL 17.9, 8 kB pages, `shared_buffers` 128 MB. Warm cache, single client,
   no concurrency or replication.
   - **Shared reads, Steps 6C, 6D and 7C:** 0 in the measured runs.
   - **Shared reads, Step 6E:** 48–53 shared reads in 257 of 605 measured runs, all in update series with secondary
     indexes (`analysis/step6/step6e_attempts.csv`).
     - The 605 measured attempt rows include 5 repeated attempts and 152 W1b loop rows without buffer data.
     - 255 of the 600 runs used for the statistics have shared reads.
   - **Not assessed:** the effect of those shared reads on the Step 6E timing ratios.
2. **Small data.** 5,000 rows. JSON documents about 1.7 kB, sitting at the TOAST inline-compression threshold. Spatial
   flat tables of 31–39 pages that fit in shared buffers.
3. **Session drift.**
   - 6C batch 2 medians were up to 10–50 % higher.
   - 6D drifted 7–15 % between phases.
   - 7C session ratio was 0.83–1.13.
4. **Step 6E power drop.** CPU speed dropped about 3× partway through session 1 (the laptop was running on battery
   afterwards; the cause is not proven). Only interleaved ratios are compared. Step 7C required AC power.
5. **Normalised write protocol.** Step 6E ran a `CHECKPOINT` before every measured write (near worst-case full-page
   images) and reset tables per run; bloat and `VACUUM` were not measured.
6. **Sub-millisecond timings.** Many Step 6D / 7C medians are below 1 ms; those below 0.1 ms required confirmation in a
   second batch or session. Step 7C had 4 marginal session-2 disagreements out of 109 class I verdicts.
7. **Planner inputs.** Plan choices depend on one `ANALYZE`. Several row estimates were far off:
   - Step 6D default expression estimates, and the constant GIN estimate of 50
   - Step 7C geography `ST_DWithin`, estimated at 1 row

   Step 6D Q11b is different: a cost-model blind spot. Its row estimate was accurate (3,086 vs 3,064), but the cost
   model does not reflect per-row extraction cost.
8. **Absolute times across steps are not comparable.** For example, 6C reads vs 6E writes vs 7C spatial queries.
9. **Derived values are not verdicts.** Planning + execution totals, ratios of medians and size ratios.
10. **Build timings.** Three sequential samples per index. The first build was the slowest in 9 of 10 Step 7C
    indexes and in 6 of 12 Step 6D build series.

## 12. What was NOT measured or tested

**Parser:**
- real (non-synthetic) logs
- parser throughput as a performance experiment (run durations were recorded only)
- log formats beyond F1–F5
- `outcome_class`
- a SELECT-only parser role (deferred)

**Flat schema:**
- query performance of the flat table against JSON / JSONB documents
- refresh from a later parser run
- normalised email, URL and tool columns

**JSON / JSONB** (Step 6F §2, §7, §8, §12; the Step 6E shared-reads item: final audit):
- whole-document equality (C4)
- a GIN index on `doc::jsonb` of the json table (I-4)
- formatting sensitivity of json text (M-09)
- larger documents, out-of-line TOAST, `lz4`
- accumulated bloat, `VACUUM` after updates, reads on updated tables
- separate decompression cost
- the GIN pending-list state
- the cause of the higher jsonb WAL on 238-row updates
- other document shapes, compression methods and page sizes
- write timing under normal checkpoint intervals (every measured Step 6E write followed a forced `CHECKPOINT`)
- a formal planning-time comparison for writes
- the effect of the Step 6E shared reads on its timing ratios

**PostGIS** (Step 7D §4, §9, §11, §15; Step 7E §5, §8, §10, §12):
- INSERT, UPDATE, DELETE and index-maintenance cost of spatial indexes and generated columns
- bloat, `VACUUM`, concurrency
- projections / `ST_Transform` and SRIDs other than 4326 (only the mixed-SRID error was recorded)
- geography box queries
- the geometry distance method for D3, D4, D5 (antimeridian) and D7 (pole)
- nearest neighbours with filters, `<#>`, other k values
- BRIN `pages_per_range` variants, larger or spatially ordered tables
- points or radii near the 0.45 % sphere / spheroid band
- why geography planning time grows with the radius
- planning memory (recorded, not analysed)
- nearest-neighbour centres other than Reykjavik and New York
- the causes of the row misestimates and of the smaller stored-column JSONB heap

**Environment:**
- other hardware, operating systems or PostgreSQL / PostGIS versions
- cold cache, concurrency, replication
- `data_checksums` or `wal_compression` on
- fillfactor below 100
- larger data volumes

## 13. Limitations and threats to validity

1. **Construct validity of the parser result.** The dataset and its answer key come from the project's own seeded
   generator and curated edge cases. The 100 % match proves agreement with that specification. It does not prove
   performance on real logs.
2. **Heuristics fitted to the data.** The C-06 truncation rule and closed vocabularies were fitted to this synthetic
   dataset.
3. **External validity of performance results.** One laptop, one PostgreSQL version, one PostGIS version, default
   settings, warm cache, a single client and 5,000 rows. Many results depend on dataset-specific thresholds: TOAST
   inline compression, and the 39-page heap vs BRIN `pages_per_range`.
4. **Measurement stability.** Session drift, the Step 6E slowdown (cause not proven) and sub-millisecond medians limit
   precision. The verdict rule reduces but does not remove chance findings. It is applied per comparison, without
   correction for the number of comparisons.
5. **Planner dependence.** Several outcomes depend on the planner:
   - the B3 / B4 index scans, on row estimates from one statistics sample
   - the Q11b sequential scan, on the cost model, despite an accurate row estimate

   Other statistics or costs could lead to other plans.
6. **Fairness boundaries.** The JSONB heap in the flat-vs-JSONB PostGIS comparison carries the documents. Type-only
   capabilities (GIN, `jsonb_set`) and representation-specific forms (expression index, on-the-fly construction) have
   no fair counterpart and are reported separately.
7. **Scope of "recommendation".** Recommendations mean "best, or the only correct or supported option, in these
   measurements". They are not general PostgreSQL / PostGIS rules.
8. **Operational deviations.** Recorded; none changed a result set, verdict or integrity check. Index-size variation
   means the kept-build sizes are single values of a varying quantity.
   - PostGIS installed manually, with four installer environment variables left set
   - runner and checker fixes, before the affected database runs or between runs
   - harnesses run twice
   - index sizes varying across builds

## 14. Final overall conclusion

1. **Regex parsing in PostgreSQL met its target** on this dataset.
   - All 5,000 raw logs were classified into F1–F5 or NONE.
   - All 50,000 field values matched the answer key in value and validity.
   - 47,374 values were exact at their recorded positions.
   - Two runs were identical, all 10 acceptance tests passed, and the raw input stayed byte-for-byte unchanged.
2. **The flat typed table** holds the validated result with exact text, validity, positions and typed columns under 22
   CHECKs and 4 foreign keys (57 / 57 load checks). It served as the correctness oracle for the Step 6C / 6D queries
   and, through its copy `flat_numeric`, for Step 7C.
3. **JSON vs JSONB:** no type was better across the board (Step 6F).
   - json is faster to store and return unchanged documents without path indexes, and keeps the exact text.
   - jsonb is about 5–13× faster for value access without indexes (Q03 about 2×), faster for writes with btree
     expression indexes, and the only type with
     GIN search and `jsonb_set`, at measured write, WAL and storage costs.
4. **PostGIS** (Step 7E):
   - **Index method:** GiST is the index method.
   - **Metric workloads:** geography + GiST for metric distances and nearest neighbours.
   - **Degree workloads:** geometry + GiST for degree boxes and planar nearest neighbours.
   - **Where indexes pay off:** mainly selective queries and nearest neighbours; benefits were smaller at larger result
     sizes.
     - **Boxes returning 32–78 % of rows:** the flat-table GiST, SP-GiST and BRIN indexes gave no benefit (and
       regressed on B4), while the JSONB GiST indexes still had measurable benefits (J-1 on B3 and B4, J-3 on B3).
     - **Table size:** BRIN and SP-GiST gave no advantage at this table size.
   - **Where points live:** flat coordinates are never slower than JSONB coordinates. Within JSONB, a stored generated
     column beats an expression index for reads (write cost not measured).
   - **Sphere vs spheroid:** the sphere gave the same sets as the spheroid here, and was measurably faster for computing
     the distance to every point.
5. **Integrity and isolation held throughout.** Digests, verification scripts and four manifests show no unintended
   change from Step 3 to the final Step 7F state, in which the 10 experiment indexes are removed and the experiment
   tables and PostGIS remain.
6. **Scope.** Every performance conclusion applies only to this 5,000-row synthetic dataset, PostgreSQL 17.9, PostGIS
   3.6.2, one Windows laptop and the tested single-client, warm-cache workloads. Write-heavy spatial workloads were not
   measured.

## 15. Suggested future experiments if the project were extended

1. **Parser on real data:** validate against real (non-synthetic) access logs, with an independently produced answer
   key, and measure parser throughput as an experiment.
2. **Larger JSON workloads:** repeat Step 6 with larger documents, out-of-line TOAST and `lz4` compression, to test the
   TOAST threshold effect directly.
3. **Unmeasured JSON items:** C4 whole-document equality, I-4 GIN on `doc::jsonb` for the json table, and M-09 text
   formatting sensitivity.
4. **Realistic write protocol:** no forced `CHECKPOINT`, accumulated bloat, `VACUUM` and reads on updated tables, and
   the GIN pending-list state.
5. **Flat vs documents:** measure query performance of `access_log_flat` against jsonb for the same filters.
6. **Spatial write costs:** INSERT / UPDATE / maintenance of spatial indexes, stored generated columns vs expression
   indexes, and bloat.
7. **Scale and BRIN:** repeat Step 7 at larger table sizes, with spatially ordered data and BRIN `pages_per_range`
   variants.
8. **Untested spatial queries:** geography box queries, geometry distance methods at the antimeridian and pole,
   nearest-neighbour queries with filters, `<#>` and other k values, and projected SRIDs with `ST_Transform`.
9. **Sphere / spheroid boundary:** construct points and radii inside the 0.45 % band to test when their results diverge.
10. **Planner behaviour:** extended statistics or expression statistics for the misestimated predicates (Q11b, B3 / B4,
    geography `ST_DWithin`), and why geography planning time grows with the radius.
11. **Environment variation:** cold cache, concurrency, other hardware or operating systems, other PostgreSQL /
    PostGIS versions, and `data_checksums` / `wal_compression` on.

---

**Final database state** (Step 7F, verified 343 PASS / 0 FAIL), unchanged by this report:

| Item | State |
|---|---|
| Database | `postgresql_regex_task` |
| Extensions | `plpgsql` 1.0, `postgis` 3.6.2 in schema `postgis` |
| Schemas and relation counts | `log_regex` (49 relations), `log_regex_json` (16), `log_regex_json_write` (8), `postgis` (6), `log_regex_gis` (30: 15 tables + 15 primary keys, no secondary index), `public` (0) |
| Indexes | Step 6D: 14 indexes; no Step 7C index |
| Git | nothing committed |

**Stopped here.** This is the final project report; no further step is started.
