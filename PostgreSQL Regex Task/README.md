![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17.9-blue)
![PostGIS](https://img.shields.io/badge/PostGIS-3.6.2-green)
![Regex](https://img.shields.io/badge/Regex-POSIX%20ARE-informational)
![JSON](https://img.shields.io/badge/JSON%20%7C%20JSONB-Indexing-orange)
![Parser](https://img.shields.io/badge/Parser-50%2C000%20%2F%2050%2C000%20PASS-brightgreen)
![Audit](https://img.shields.io/badge/Final%20Audit-PASS%20WITH%20WARNINGS-yellowgreen)
![License](https://img.shields.io/badge/License-MIT-brightgreen)

# PostgreSQL Regex, JSON/JSONB and PostGIS Task

> **Status: `FINAL_CONCLUSION_REPORTED` — the project is complete.**
> An end-to-end PostgreSQL project that parses 5,000 heterogeneous raw access logs with regular expressions, stores the
> result in a typed relational table, and then measures **JSON vs JSONB** and **PostGIS spatial indexing** under a fixed,
> verifiable measurement protocol. Every figure in this repository is recorded output — nothing is estimated.

---

## 1. Executive Summary

- **Problem solved:** 5,000 raw log lines in five different formats had to be turned into 10 named fields per log, each with an exact value, a validity label and its position in the original text — without ever modifying the raw input.
- **Parser result:** **50,000 / 50,000** field values match the answer key in value *and* validity (100.00 %), with **47,374** values exact at their recorded character positions and all **10 acceptance tests (T-01 … T-10) PASS**.
- **JSON vs JSONB:** no type wins across the board. json is faster for storing and returning whole documents; jsonb is about **5–13×** faster for value access and is the only type with GIN search and `jsonb_set`.
- **PostGIS:** **GiST** is the index method to use; geography for metric distance, geometry for degree boxes. Of 109 index-vs-control comparisons, **90** showed a measurable benefit, **3** regressed and **7** were never used by the planner.
- **Integrity:** the raw input was never modified — proven by per-row fingerprints, a dataset digest and `10 / 10` integrity checks at every step that ran them.

> 💡 The project separates **fair comparisons** (identical SQL, identical indexes) from **type-only capabilities** (jsonb GIN, `jsonb_set`) and **representation-specific results**, so no capability is ever presented as a type verdict.

---

## 2. Objective

This project demonstrates, in one continuous pipeline:

- **Regex** — pattern matching, extraction, validation and replacement inside PostgreSQL
- **JSON / JSONB** — storage, querying, operators and indexing
- **PostGIS** — spatial types and operations
- **Geospatial indexing** — GiST / SP-GiST / BRIN and spatial query planning
- **Performance analysis** — `EXPLAIN (ANALYZE, BUFFERS)`, index strategy and query tuning

The goal was not only to make it work, but to **prove** it worked: every stage is verified against an independent oracle, and every performance claim follows a pre-agreed measurement rule.

---

## 3. Project Status

| Phase | Work | Result |
|---|---|---|
| **Step 1** | Seeded synthetic dataset and answer key | ✅ 5,000 rows (150 curated + 4,850 generated) |
| **Step 2** | Requirements, field variants, raw-log profile | ✅ Contract G-01 … G-09 |
| **Step 3A** | Regex parser design | ✅ Decisions C-01 … C-09 |
| **Step 3B-1** | PostgreSQL setup, byte-exact raw load | ✅ 10 / 10 integrity checks |
| **Step 3B-2** | IP validation rule | ✅ 4,986 / 4,986 values, 43 / 43 probes |
| **Step 3B-3 … 3B-7** | Parsers F1 … F5 | ✅ Every format matches the answer key |
| **Step 3C** | Combined all-format validation | ✅ 50,000 / 50,000 field values |
| **Step 4A** | Final parser validation report | ✅ T-01 … T-10 PASS |
| **Step 5A / 5B** | Flat schema design, create, populate | ✅ 57 / 57 load checks |
| **Step 6A … 6F** | JSON vs JSONB: storage, queries, indexes, writes | ✅ Consolidated in Step 6F |
| **Step 7A … 7F** | PostGIS: setup, spatial indexes, analysis, cleanup | ✅ 943 PASS, then 343 PASS cleanup |
| **Final** | Overall conclusion + read-only audit | ✅ Audit: PASS WITH WARNINGS |

---

## 4. Solution Architecture

```text
              data/raw_access_logs.csv
                          │
                          │  \copy — byte-exact load (Step 3B-1)
                          ▼
              log_regex.raw_access_logs
        (immutable: guard triggers, per-row SHA-256,
         dataset digest, verify_raw_access_logs())
                          │
                          │  PostgreSQL regex parser
                          │  detect_format() → f1..f5_candidates() → run_parser()
                          ▼
     parser_run / parsed_log / parsed_field / parsed_secondary
                   (accepted run 14)
                          │
                          │  sql/30 load: typed conversions, CHECKs, FKs
                          ▼
             log_regex.access_log_flat
     (71 columns: exact text + validity + positions + typed columns)
                          │
            ┌─────────────┴─────────────┐
            ▼                           ▼
   log_regex_json                 log_regex_gis
   json vs jsonb documents        numeric / geometry / geography
   btree + GIN indexes            GiST / SP-GiST / BRIN indexes
   (Steps 6A–6F)                  (Steps 7A–7F)
```

---

## 5. Database Overview

| Property | Value |
|---|---|
| Engine | **PostgreSQL 17.9** (Windows x64) |
| Spatial extension | **PostGIS 3.6.2** (GEOS 3.14.1dev, PROJ 8.2.1) in schema `postgis` |
| Database | `postgresql_regex_task` |
| Core schema | `log_regex` — raw logs, parser objects, flat table |
| Experiment schemas | `log_regex_json`, `log_regex_json_write`, `log_regex_gis` |
| Access discipline | All measurements and verifications run in **read-only** sessions |

**Final verified state (Step 7F):**

| Schema | Relations | Contents |
|---|--:|---|
| `log_regex` | 49 | raw logs, parser output, flat table, reference data |
| `log_regex_json` | 16 | json / jsonb document tables + Step 6D index set |
| `log_regex_json_write` | 8 | isolated write-experiment schema (write tables empty) |
| `log_regex_gis` | 30 | 15 spatial tables + 15 primary keys, **0 secondary indexes** |
| `postgis` | 6 | extension objects |
| `public` | 0 | intentionally empty |

---

## 6. Dataset

| Property | Value |
|---|---|
| Rows | **5,000** (150 curated edge cases EC-001 … EC-150 + 4,850 generated) |
| Generator | `data/generate_raw_logs.py`, seed **20260911**, standard library only |
| Answer key | `data/expected_fields.csv` — 10 fields per log |
| Manifest | `data/dataset_manifest.json` — seed, distributions, SHA-256 checksums |
| Verification | `generate_raw_logs.py --check` confirms all three files byte-identical |

**Log formats detected** (priority F4 → F3 → F1 → F5 → F2 → NONE):

| Format | Shape | Rows |
|---|---|--:|
| F1 | pipe / TAB `key=value` | 1,528 |
| F2 | natural-language sentence | 992 |
| F3 | syslog header + JSON payload | 985 |
| F4 | web-server access log + extras | 986 |
| F5 | semicolon-positional export | 500 |
| NONE | blank input / junk / header rows | 9 |

**The 10 target fields:** `entity_type`, `email_address`, `resource_url`, `event_timestamp`, `tool`, `latitude`, `longitude`, `ip_address`, `action_phrase`, `status`.

**Validity labels:** `VALID` · `INVALID` · `PLACEHOLDER` · `MISSING` — and per record: `VALID` · `INVALID` · `BROKEN`.

---

## 7. Project Structure

```text
PostgreSQL Regex Task/
│
├── data/                    # dataset, answer key, manifest, generator (7 files)
│   ├── raw_access_logs.csv
│   ├── expected_fields.csv
│   ├── dataset_manifest.json
│   ├── generate_raw_logs.py
│   └── curated_edge_cases.py
│
├── sql/                     # 53 numbered SQL files + 17 PowerShell runners
│   ├── 00–05   database, raw load, protection, IP validation
│   ├── 06–26   parser: reference data, validators, F1–F5, combined test
│   ├── 27–31   flat table: create, verify, load, verify
│   ├── 32–44   JSON / JSONB: build, query, index and write experiments
│   ├── 45–52   PostGIS: extension, tables, indexes, measurement, cleanup
│   └── run_step*.ps1        # one runner per executing step
│
├── scripts/                 # Python generators and analysers (7 files)
│
├── analysis/                # recorded measurement output (70 files)
│   ├── step6/               # JSON vs JSONB raw EXPLAIN, CSVs, summaries
│   └── step7/               # PostGIS raw EXPLAIN, verdicts, check reports
│
├── docs/                    # 34 step reports, conclusions and the audit
└── README.md                # this file
```

---

## 8. Regex Parser

### 8.1 Design

| Element | Approach |
|---|---|
| Principles | Raw logs read-only · format first, then slots · extract, then judge · candidates, then selection · offsets everywhere · vocabularies stored as data · deterministic and set-based |
| Pipeline | load → input guard → format detection → event scope → slot extraction → clean-up → primary selection → value state → validation → output |
| Implementation | PostgreSQL functions in schema `log_regex`: `detect_format()`, `f1_candidates()` … `f5_candidates()`, `run_parser()` |
| Output tables | `parser_run`, `parsed_log`, `parsed_field`, `parsed_secondary` |
| Views | `v_parsed_access_logs` (wide output), `v_parser_field_comparison`, `v_parser_mismatches` |

### 8.2 Results

| Result | Recorded value |
|---|---|
| Field values matching the answer key (value **and** validity) | **50,000 / 50,000 (100.00 %)** |
| Curated edge cases EC-001 … EC-150 | 1,500 / 1,500 |
| Exact positions (`substr(raw_log, start_pos, length) = value`) | **47,374 / 47,374**, plus 1,113 / 1,113 secondary values |
| Record validity | VALID 4,750 · INVALID 238 · BROKEN 12 |
| Field validity (all 50,000) | VALID 46,506 · INVALID 255 · PLACEHOLDER 613 · MISSING 2,626 |
| Determinism | Runs 13 and 14 identical in all three output tables |
| Acceptance tests | **T-01 … T-10 — 10 / 10 PASS** |

### 8.3 IP validation finding

A plain `inet` cast **disagreed with the answer key on 5 of 4,986** labelled IP values (4 leading-zero IPv4 values wrongly accepted, 1 IPv6 zone ID wrongly rejected). The adopted **VAL-IP rule** — strict patterns plus `inet` on the part before `%` — agreed on **4,986 / 4,986** values and **43 / 43** probes.

---

## 9. Flat Relational Schema

`log_regex.access_log_flat` — the typed, constrained store and the correctness oracle for every later experiment.

| Property | Value |
|---|---|
| Grain | One row per raw log (5,000, including the 9 NONE rows), for accepted run 14 |
| Columns | **71** — identity, record classification, 5 columns per field (× 10), 11 typed columns |
| Domains | `field_validity_status`, `record_validity_status`, `missing_reason_code` |
| Keys | Primary key `(log_id)` — the only index; **4 foreign keys**, all validated |
| Constraints | **22 CHECK constraints** (6 record, 10 per-field, 6 typed) |
| Load verification | **57 / 57 checks PASS**, 0 CHECK violations, 0 oracle mismatches |

**Typed columns** (populated for VALID values only):

| Column | Type | Rows |
|---|---|--:|
| `entity_type_code` | `text` (normalised, FK) | 4,634 |
| `event_timestamp_shape` | `text` (FK) | 4,990 |
| `event_timestamp_local` | `timestamp(6)` | 4,928 |
| `event_timestamp_utc_offset` / `event_timestamp_utc` | `interval` / `timestamptz(6)` | 2,941 / 2,941 |
| `latitude_degrees` / `longitude_degrees` | `numeric(10,7)` | 4,249 / 4,252 |
| `ip_address_inet` / `ip_address_zone_id` | `inet` / `text` | 4,948 / 1 |
| `status_code` / `status_word` | `smallint` / `text` | 2,035 / 2,666 |

---

## 10. JSON vs JSONB Experiment (Steps 6A–6F)

5,000 documents, 82 keys and 70 leaf values each, built from one canonical minified text (8,416,033 bytes) and cast to **both** types — so the comparison is genuinely like-for-like.

### 10.1 Storage

| Measure | json | jsonb | Difference |
|---|--:|--:|---|
| Uncompressed document size | 8,436,033 | 10,084,876 | jsonb **+19.5 %** |
| Stored bytes (`pg_column_size`) | 8,434,066 | 7,219,683 | jsonb **−14.4 %** |
| Documents compressed inline | 1 | 2,880 | TOAST threshold effect |
| Heap | 10,240,000 (1,250 pages) | 8,036,352 (981 pages) | jsonb **−21.5 %** |

### 10.2 Query performance (fair, no secondary indexes)

| Access pattern | Winner | Evidence |
|---|---|---|
| Whole documents (Q01, Q02) | **json** | 0.012 vs 0.030 ms · 2.956 vs 68.709 ms |
| Value extraction, filters, aggregates, SQL/JSON (23 statements) | **jsonb** | ratios 0.08–0.49, about **5–13×** faster |
| Planning time | = | no measurable difference |

### 10.3 Indexes and writes

| Situation | Result |
|---|---|
| Identical btree expression indexes answer the query (7 statements) | **no measurable difference** |
| Index build time per index | json 66–122 ms vs **jsonb 16–21 ms** |
| Inserts / updates **without** secondary indexes | **json faster** (×1.29–2.52) |
| Inserts / updates **with** the 5 btree indexes | **jsonb faster** (0.51–0.59) — json pays text parsing per index entry |
| WAL, whole-table writes | jsonb **8–13 % less** |

### 10.4 JSONB-only capabilities *(no json counterpart — never used as a type verdict)*

| Capability | Measured |
|---|---|
| GIN containment / jsonpath | 10–12 ms → **0.027–0.528 ms** (`jsonb_path_ops`) |
| GIN cost | index 46–56 % of heap; writes ×1.5–4.3; WAL up to ×3.9 |
| `jsonb_set` partial update | fastest partial-update mechanism measured (39.2 ms / 238 rows) |

> **Step 6F verdict:** *neither type is better across the board.* The correct choice depends on whether the workload returns whole documents or reads values out of them.

---

## 11. PostGIS Spatial Indexing (Steps 7A–7F)

15 tables of 5,000 rows (4,161 non-NULL points), **10 indexes**, **192 query × configuration series**, two read-only sessions, **7,680 executions**, and **2,424 / 2,424** correctness checks against plain-SQL oracles.

### 11.1 Index vs its own control (109 series)

| Verdict | Series |
|---|--:|
| ✅ Measurable benefit | **90** |
| ➖ Used, no measurable benefit | 5 |
| ⚠️ Measurable regression | 3 |
| ⛔ Not used by the planner | 7 |
| 🚫 Not supported (no ordering operator) | 4 |

### 11.2 Method comparison

| Method | Outcome |
|---|---|
| **GiST** | The method to use — and the only one supporting nearest-neighbour ordering |
| **SP-GiST** | Never measurably faster than GiST on the same column |
| **BRIN** | 39-page tables collapse into a single block range → not used, or slower |

### 11.3 Representation

| Comparison | Result |
|---|---|
| Geography + GiST | Correct metric distances everywhere, including antimeridian and pole; benefit in all 14 distance series (1.41–103×) |
| Geometry + GiST | Degree boxes and planar nearest neighbours; index 1.85× smaller than geography |
| Flat vs JSONB coordinates (fair) | Flat faster in 14 of 23 indexed series, **never slower** |
| JSONB stored column vs expression index | Stored column faster in **21 of 23**, and 3–4× faster to build |
| Sphere vs spheroid | Identical result sets here; sphere measurably faster for distance to every point (5.188 vs 10.226 ms) |

### 11.4 Cost side

Every index adds planning time — indexed tables planned measurably slower in **97 of 109** series, and geography distance planning reached **0.43–1.30 ms** against about 0.04 ms without an index.

---

## 12. Validation and Integrity

| Verification | Scope | Result |
|---|---|---|
| `verify_raw_access_logs()` | Raw input, 10 checks | **10 / 10** in every run that called it |
| `sql/27` | Flat foreign keys | PASS |
| `sql/29` | Flat structure (S-01 … S-15, 212 probe rows) | PASS |
| `sql/31` | Flat load | **57 / 57** |
| `sql/34` | JSON / JSONB tables | **38 / 38** |
| `sql/38` | JSON index phases | **70 / 70** |
| `sql/47` | PostGIS setup | **155 / 155** |
| `sql/50` | PostGIS index phase | **113 / 745** per phase |
| Step 7B runner | PostGIS setup | **317 PASS / 0 FAIL** |
| Step 7C runner | Spatial index experiment | **943 PASS / 0 FAIL / 0 FLAG** |
| Step 7F runner | Cleanup and final state | **343 PASS / 0 FAIL** |

**Baseline manifests (SHA-256), all re-verified with 0 mismatches:** Step 6C (11 files) · Step 6D (26) · Step 7B (14) · Step 7F (32).

**Safeguards used throughout:** guard SQLSTATEs (`LR001` … `LR026`) that refuse unsafe runs · rolled-back harnesses before real writes · read-only measurement sessions · single-transaction writes · generated SQL checked against a static statement allowlist.

---

## 13. Evidence

This project has no screenshots: the evidence is the **recorded output** itself, committed in `analysis/`.

| Evidence | Location |
|---|---|
| Check reports (PASS / FAIL per check) | `analysis/step7/step7b_setup_checks.txt`, `step7c_checks.txt`, `step7f_cleanup_checks.txt`, `analysis/step6/step6e_preflight_report.txt` |
| Raw `EXPLAIN` output | `analysis/step6/step6c_*_explain.txt`, `step6d_*_explain.txt`, `analysis/step7/step7c_session{1,2}_raw.txt` |
| Per-execution metrics | `analysis/step6/step6*_executions.csv`, `analysis/step7/step7c_executions.csv` |
| Verdicts and comparisons | `analysis/step7/step7c_verdicts.csv`, `step7c_comparisons.csv`, `analysis/step6/step6*_comparisons.csv` |
| Index builds and sizes | `analysis/step7/step7c_builds.csv`, `step7c_sizes.csv`, `analysis/step6/step6d_builds.csv` |

---

## 14. How to Run

Each executing step has its own runner. Connection settings come from environment variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`); **no credentials are stored in this repository**.

```bash
# 1. Database, schema and byte-exact raw load
powershell -File "sql/run_step3b1_setup.ps1"

# 2. Parser: install and validate all formats (two full runs + T-01..T-10)
powershell -File "sql/run_step3c_combined_parser.ps1"

# 3. Flat table: create and populate
powershell -File "sql/run_step5b_create_flat_table.ps1"
powershell -File "sql/run_step5b_populate_flat_table.ps1"

# 4. JSON vs JSONB: build, query, index and write experiments
powershell -File "sql/run_step6b_build_json_tables.ps1"
powershell -File "sql/run_step6c_json_queries.ps1"
powershell -File "sql/run_step6d_json_indexes.ps1"
powershell -File "sql/run_step6e_json_writes.ps1"

# 5. PostGIS: setup, spatial index experiment, cleanup
powershell -File "sql/run_step7b_postgis_setup.ps1"
powershell -File "sql/run_step7c_spatial_indexes.ps1"
powershell -File "sql/run_step7f_cleanup.ps1"
```

Every runner writes a PASS / FAIL report and refuses to continue when a check fails.

---

## 15. Documentation Index

**Start here:**

| Document | Content |
|---|---|
| [Final_Project_Conclusion.md](docs/Final_Project_Conclusion.md) | Consolidated report of Steps 1–7F: results, comparison table, recommended architecture, decisions, caveats |
| [Final_Project_Audit.md](docs/Final_Project_Audit.md) | Read-only audit of the whole project — **PASS WITH WARNINGS** |

**Dataset, requirements and parser:**

| Step | Document |
|---|---|
| 1 | [Sample_Data.md](docs/Sample_Data.md) |
| 2 | [Step2_Requirements_and_Variants.md](docs/Step2_Requirements_and_Variants.md) · [Step2_Raw_Log_Profile.md](docs/Step2_Raw_Log_Profile.md) |
| 3A | [Step3A_Parser_Design.md](docs/Step3A_Parser_Design.md) |
| 3B-1 / 3B-2 | [Step3B1_PostgreSQL_Setup.md](docs/Step3B1_PostgreSQL_Setup.md) · [Step3B2_IP_Validation.md](docs/Step3B2_IP_Validation.md) |
| 3B-3 … 3B-7 | [F1](docs/Step3B3_F1_Parser.md) · [F2](docs/Step3B4_F2_Parser.md) · [F3](docs/Step3B5_F3_Parser.md) · [F4](docs/Step3B6_F4_Parser.md) · [F5](docs/Step3B7_F5_Parser.md) |
| 3C / 4A | [Step3C_Combined_Parser_Validation.md](docs/Step3C_Combined_Parser_Validation.md) · [Step4A_Parser_Validation_Report.md](docs/Step4A_Parser_Validation_Report.md) |

**Flat schema:**

| Step | Document |
|---|---|
| 5A | [Step5A_Flat_Schema_Design.md](docs/Step5A_Flat_Schema_Design.md) |
| 5B | [Step5B_Create_Flat_Table.md](docs/Step5B_Create_Flat_Table.md) · [Step5B_Populate_Flat_Table.md](docs/Step5B_Populate_Flat_Table.md) |

**JSON vs JSONB:**

| Step | Document |
|---|---|
| 6A | [Step6A_JSON_vs_JSONB_Experiment_Design.md](docs/Step6A_JSON_vs_JSONB_Experiment_Design.md) |
| 6B | [Step6B_Build_JSON_Tables_and_Storage.md](docs/Step6B_Build_JSON_Tables_and_Storage.md) |
| 6C | [Step6C_JSON_vs_JSONB_Query_Experiment.md](docs/Step6C_JSON_vs_JSONB_Query_Experiment.md) |
| 6D | [Step6D_JSON_vs_JSONB_Index_Experiment.md](docs/Step6D_JSON_vs_JSONB_Index_Experiment.md) |
| 6E | [design](docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md) · [results](docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment.md) |
| 6F | [Step6F_JSON_vs_JSONB_Final_Comparison_Report.md](docs/Step6F_JSON_vs_JSONB_Final_Comparison_Report.md) |

**PostGIS:**

| Step | Document |
|---|---|
| 7A | [design](docs/Step7A_PostGIS_Experiment_Design.md) · [install preflight](docs/Step7A1_PostGIS_Installation_Preflight.md) · [post-install verification](docs/Step7A2_PostGIS_Post_Installation_Verification.md) |
| 7B | [Step7B_PostGIS_Setup_Preflight.md](docs/Step7B_PostGIS_Setup_Preflight.md) |
| 7C | [design](docs/Step7C_Spatial_Index_Experiment_Design.md) · [experiment](docs/Step7C_Spatial_Index_Experiment.md) |
| 7D / 7E | [Step7D_PostGIS_Results_Analysis.md](docs/Step7D_PostGIS_Results_Analysis.md) · [Step7E_PostGIS_Final_Conclusion.md](docs/Step7E_PostGIS_Final_Conclusion.md) |
| 7F | [Step7F_PostGIS_Cleanup_and_Final_State_Plan.md](docs/Step7F_PostGIS_Cleanup_and_Final_State_Plan.md) |

---

## 16. Technologies Used

## Database

- PostgreSQL 17.9
- PostGIS 3.6.2 (GEOS, PROJ)

## Languages

- SQL (POSIX ARE regular expressions, PL/pgSQL)
- Python 3.10+ (standard library only)
- PowerShell 5.1 (runners)

## PostgreSQL Features

- Regular expressions, domains, CHECK constraints, foreign keys
- `json` / `jsonb`, btree expression indexes, GIN (`jsonb_ops`, `jsonb_path_ops`)
- PostGIS `geometry` / `geography`, GiST / SP-GiST / BRIN
- `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, SERIALIZE, MEMORY, WAL)`

## Tools

- pgAdmin 4
- Git and GitHub
- Visual Studio Code

---

## 17. Measurement Methodology

| Item | Protocol |
|---|---|
| Correctness first | Every timed statement verified against an oracle before **and** after timing, in default and forced plan modes |
| Fixed settings | `jit` off, no parallel workers, UTC, `track_io_timing` on; planner settings at server defaults |
| Rounds | 3 warm-up + 15 measured rounds, interleaved across the compared configurations |
| Verdict rule | IQRs must not overlap **and** the faster median ≤ 90 % of the slower; below 0.1 ms the direction must repeat in a second session |
| Excluded | Forced-plan timings never carry a verdict; only within-session interleaved ratios are compared |

---

## 18. Skills Demonstrated

- PostgreSQL regular expressions (POSIX ARE) and text parsing
- Deterministic, set-based SQL design
- Data validation and answer-key driven testing
- Relational schema design with domains, CHECKs and foreign keys
- JSON / JSONB modelling, querying and indexing
- GIN, btree expression and spatial index strategy
- PostGIS geometry / geography and spatial query planning
- Performance measurement with `EXPLAIN (ANALYZE, BUFFERS)`
- Statistical comparison rules and measurement hygiene
- WAL, TOAST and buffer analysis
- Data integrity: fingerprints, digests, SHA-256 manifests
- Reproducible automation with runners and guarded scripts
- Technical documentation and self-auditing
- Git version control and repository management

---

## 19. Limitations and Scope

All performance conclusions are scoped to **this dataset and environment** and are not general PostgreSQL rules:

- 5,000 rows / 5,000 documents of about 1.7 kB; spatial tables of 31–39 pages
- One Windows laptop, PostgreSQL 17.9, PostGIS 3.6.2, default planner settings
- Warm cache, single client, no concurrency and no replication
- Storage results depend on the TOAST inline-compression threshold of this data
- The BRIN result depends on the 39-page table size vs the default `pages_per_range`
- **Not measured:** write and maintenance cost of spatial indexes, concurrency, cold cache, larger volumes, real (non-synthetic) logs

---

## 20. Future Work

- Validate the parser against real access logs with an independently produced answer key
- Repeat the JSON experiment with larger documents, out-of-line TOAST and `lz4` compression
- Measure write and maintenance cost of spatial indexes and generated columns
- Repeat the spatial experiment at larger table sizes and with other `pages_per_range` values
- Compare the flat table directly against jsonb for the same filters
- Test cold cache, concurrency and other PostgreSQL / PostGIS versions

---

## 21. Project Summary

| Component | Status |
|---|---|
| Synthetic dataset and answer key | ✅ Completed |
| Regex parser (F1–F5 + NONE) | ✅ Completed — 50,000 / 50,000 |
| Parser validation (T-01 … T-10) | ✅ Completed — 10 / 10 PASS |
| Flat typed schema | ✅ Completed — 57 / 57 checks |
| JSON vs JSONB experiment | ✅ Completed — Step 6F conclusion |
| PostGIS spatial index experiment | ✅ Completed — 943 PASS |
| Results analysis and conclusion | ✅ Completed — Step 7E |
| Cleanup and final state | ✅ Completed — 343 PASS |
| Final project conclusion | ✅ Completed |
| Independent read-only audit | ✅ Completed — PASS WITH WARNINGS |

---

## 22. Relationship to the Rest of This Repository

This project is a sibling of the other assignments at the repository root. It is **independent** of `packers_movers_synthetic_data/`, a separate, completed analytics project against the `relocation_services` database, which is not affected by anything here.

---

# Author

**Akash More**

**Data Engineer**

GitHub Repository:

https://github.com/Akash-web750/aws-data-engineering-assignments

---

# License

This project is licensed under the MIT License.

---

# Acknowledgement

This project was created for learning, portfolio development, interview preparation, and practical experience with PostgreSQL regular expressions, JSON / JSONB modelling and indexing, PostGIS spatial indexing, and disciplined performance measurement.

*All figures in this README are actual recorded output from the project's verification and measurement runs. No value is estimated or invented.*
