# Step 6D — JSON vs JSONB Index Experiment

**Status:** indexes created, verified, measured and analysed (12/09/2026). Stopped for review. This report contains
measurements and observations only; **it is not the final JSON vs JSONB conclusion.**

**Scope** (Step 6A §6):
- **I-0:** control with no secondary index.
- **I-1:** the **same five btree expression indexes** on `access_log_json` and `access_log_jsonb`. This is the fair
  head-to-head.
- **I-2:** native GIN `jsonb_ops` on `access_log_jsonb`.
- **I-3:** native GIN `jsonb_path_ops` on `access_log_jsonb`.

I-2 and I-3 are **jsonb-only capabilities, reported separately.** The optional JSON-via-cast GIN index (I-4) was **not**
created.

**Unchanged:**
- `raw_access_logs`, `access_log_flat`, parser objects and parser runs: the `log_regex` digest is
  `f8042db0318656b5929c86ea1f7888d4` (203 items) before and after.
- The JSON and JSONB tables, constraints, comments and documents: the digest is `9e6f883112c4a01781bdce5cf9bf3a28` (10
  items, indexes excluded) before and after. `sql/34` passes 38 / 38 before and after, and the canonical document md5
  `aeaef323…` is checked in every phase.
- The Step 6C baseline: 11 files verified against a SHA-256 manifest at the start and the end (§2).

---

## 1. Files

| File | Role |
|---|---|
| `scripts/step6d_json_index_experiment.py` | **new**: index, statement and phase definitions (imports the Step 6C statements unchanged). `generate` writes `sql/38`–`sql/40`; `analyze` produces the CSVs and summary |
| `sql/38_verify_json_index_phase.sql` | **new, generated**: read-only state and result verification per phase (`LR015`) |
| `sql/39_build_json_experiment_indexes.sql` | **new, generated**: guarded index builds per step (`LR014`); 3 timed builds per index; ANALYZE |
| `sql/40_measure_json_index_phase.sql` | **new, generated**: read-only measurements per phase, default and forced plans |
| `sql/run_step6d_json_indexes.ps1` | **new** runner: static checks, baseline manifest, digests, the four phases, final state, checks, analysis; `-AnalyzeOnly` |
| `sql/34_verify_json_experiment_tables.sql` | check B-10a changed: besides the two tables and primary keys it now accepts exactly the 12 designed Step 6D index names; any other relation still fails |
| `analysis/step6/step6d_baseline_step6c_sha256.txt` | SHA-256 manifest of the Step 6C baseline (11 files) |
| `analysis/step6/step6d_build_{i1,i2,i3,final}.txt` | build output: time, WAL bytes and size per build |
| `analysis/step6/step6d_{i0,i1,i2,i3}_batch{1,2}_explain.txt` | raw EXPLAIN (JSON) output of the 8 measurement sessions |
| `analysis/step6/step6d_executions.csv`, `step6d_summary.csv`, `step6d_comparisons.csv`, `step6d_builds.csv`, `step6d_indexes.csv`, `step6d_summary.md` | parsed measurements, statistics, rule results, builds and index catalog |
| `docs/Step6D_JSON_vs_JSONB_Index_Experiment.md` | this report |
| `README.md` | status and Step 6D summary |

**Static checks in the runner:**
- the generated files are up to date, and the Step 6C generated files are unchanged
- `sql/38` and `sql/40` contain no write statement
- all 67 write statements in `sql/39` are designed `CREATE INDEX` / `DROP INDEX` / `ANALYZE` statements on the two
  experiment tables
- there is no `doc::jsonb` index expression and no GIN index on `access_log_json`
- all files are ASCII

## 2. Step 6C baseline preserved

- **Files:** the Step 6C measurement outputs, report, generated SQL, runner and generator (11 files) were hashed
  before any index existed and verified again at the end. All match.
- **Control:** the I-0 statements were re-measured in this step, just before the first index build, with the Step 6C
  protocol. The control medians are within −7 % to +4 % of Step 6C:

| Statement | json: I-0 (6D) / Step 6C ms | jsonb: I-0 (6D) / Step 6C ms |
|---|---|---|
| Q07 | 57.08 / 56.66 | 10.39 / 10.25 |
| Q08 | 100.97 / 104.75 | 10.96 / 10.70 |
| Q10 | 103.72 / 110.98 | 11.02 / 11.34 |
| Q11a / Q11b | 117.76 / 119.99 · 172.87 / 184.37 | 13.64 / 13.67 · 19.33 / 20.10 |
| Q12a / Q12b / Q12c | 153.86 / 155.21 · 149.10 / 154.69 · 151.96 / 156.04 | 14.69 / 15.66 · 14.77 / 15.28 · 14.90 / 14.98 |
| Q16 / Q17 / Q09 | 78.58 / 76.97 · 101.42 / 105.03 · 56.32 / 57.65 | 12.03 / 12.15 · 12.04 / 11.60 · 10.84 / 10.67 |

Index effects below are computed against the same-step I-0 control. The Step 6C value is shown alongside for reference.

## 3. Indexes

### 3.1 Fair comparison: identical btree expression indexes (I-1)

The same statement is built on each table (e.g. `CREATE INDEX access_log_json_i1a_record_validity ON
log_regex_json.access_log_json ((doc->'record'->>'record_validity'))`, and the same for `access_log_jsonb`). Check G-10
confirms both catalog definitions are identical once table names are normalised.

| Concept | Indexed expression (path) | Operator class | Statements | Size json / jsonb (bytes) | Build median json / jsonb (ms) | WAL median json / jsonb (bytes) |
|---|---|---|---|---|---|---|
| I-1a | `doc->'record'->>'record_validity'` (text) | btree `text_ops` | Q07 | 57,344 / 57,344 | 66.3 / 16.3 | 34,184 / 34,232 |
| I-1b | `doc->'fields'->'entity_type'->>'code'` (text) | btree `text_ops` | Q08, Q17 | 57,344 / 57,344 | 110.0 / 20.6 | 34,760 / 34,728 |
| I-1c | `(doc->'fields'->'status'->>'code')::integer` | btree `int4_ops` | Q10, Q16 | 57,344 / 57,344 | 109.1 / 18.8 | 34,704 / 34,704 |
| I-1d | `(doc->'fields'->'latitude'->>'degrees')::numeric` | btree `numeric_ops` | Q11a, Q11b | 147,456 / 147,456 | 109.4 / 16.8 | 117,448 / 117,448 |
| I-1e | `doc->'fields'->'event_timestamp'->>'utc'` (text, fixed-width ISO UTC) | btree `text_ops` | Q12a, Q12b, Q12c | 180,224 / 180,224 | 122.4 / 19.6 | 148,232 / 148,232 |
| **total** | | | | **499,712 / 499,712** | | |

Index names: `access_log_{json|jsonb}_i1a_record_validity`, `…_i1b_entity_type_code`, `…_i1c_status_code`,
`…_i1d_latitude_degrees`, `…_i1e_event_timestamp_utc`.

### 3.2 JSONB-only capability: native GIN indexes (I-2, I-3)

| Concept | Index | Definition | Covers | Size (bytes) | Build median (ms) | WAL median (bytes) |
|---|---|---|---|---:|---:|---:|
| I-2 | `access_log_jsonb_i2_gin_jsonb_ops` | `USING gin (doc)` — default `jsonb_ops`: every key and every value of the whole document | `@>`, `?`, `?\|`, `?&`, `@?`, `@@` on `doc` | 4,521,984 | 554.4 (final rebuild 500.9) | 2,413,808 |
| I-3 | `access_log_jsonb_i3_gin_jsonb_path_ops` | `USING gin (doc jsonb_path_ops)` — a hash of each path to a value | `@>`, `@?`, `@@` on `doc` | 3,727,360 | 243.7 | 1,958,528 |

### 3.3 Validity and final state
- **Validity:** every index is `indisvalid`, `indisready` and `indislive` (G-06 in every phase). `reltuples` is 5,000
  for all 14 indexes. Every build of the same index produced the same size.
- **Operator classes:** G-09 matches the design in every phase.

Final catalog:

| Table | Heap bytes | Indexes | Index bytes | Total bytes |
|---|---:|---|---:|---:|
| `access_log_json` | 10,240,000 | primary key + I-1 (6) | 630,784 | 10,911,744 |
| `access_log_jsonb` | 8,036,352 | primary key + I-1 + I-2 + I-3 (8) | 8,880,128 | 16,957,440 |

Both GIN indexes are kept in the final state only so that every measured index remains available. `jsonb_ops` and
`jsonb_path_ops` on the same column overlap.

## 4. Methodology

| Item | Protocol |
|---|---|
| Phases | **I-0:** control, before any index.<br>**I-1:** build I-1 on both tables, ANALYZE both.<br>**I-2:** build GIN `jsonb_ops`, ANALYZE jsonb.<br>**I-3:** drop `jsonb_ops`, build GIN `jsonb_path_ops`, ANALYZE jsonb.<br>**final:** rebuild `jsonb_ops`, ANALYZE jsonb |
| Builds | inside a DO block: server-side time (`clock_timestamp`), WAL bytes (`pg_current_wal_insert_lsn` difference), size; each index built 3 times (dropped between builds, third kept; json/jsonb order alternating); `max_parallel_maintenance_workers = 0`, `maintenance_work_mem = 64MB` |
| Statistics | `ANALYZE` after each build step collects expression statistics for the btree expression indexes (same for both tables) |
| Verification per phase (`sql/38`) | G-01 … G-10: rows, documents unchanged, index set, valid/ready/live, no row changes, heap pages, access method/opclass, identical I-1 definitions. R-checks: result checksum of every phase statement = `access_log_flat` oracle, with default settings **and** with `enable_seqscan = off` |
| Measurement sessions (`sql/40`) | two separate read-only sessions per phase, same protocol as Step 6C: `jit` off, no parallel workers, TimeZone UTC, `track_io_timing` on; 3 warm-ups + 15 measured runs (json/jsonb order alternating) + 1 detail run; `EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY)`. Other active sessions: 0 in all 8 |
| Statements | **Head-to-head (both types; I-0, I-1):** Q07, Q08, Q10, Q11a, Q11b, Q12a, Q12b, Q12c, Q16, Q17 (indexed by I-1), plus Q09 as an unindexed control.<br>**Capability (jsonb; I-0, I-2, I-3):** C1, C1b, C1c, C1d (containment), C2 (`?` on a nested value), C3 (`@?`), C3b (`@@`), Q21 (`JSON_EXISTS`) |
| Modes | **default:** planner defaults (primary result).<br>**forced:** `enable_seqscan = off`, a diagnostic that shows the index path; reported separately |
| Rule | Step 6A: IQRs do not overlap and the medians differ by at least 10 %; below 0.1 ms the result must be confirmed in the second session |
| Cross-phase caution | phases run in different sessions at different times. The unindexed control Q09 moved by +7 % (json) and +15 % (jsonb) between I-0 and I-1 with an identical plan, so differences of that size between phases on identical plans are **not** attributed to indexes (§9) |

## 5. Correctness and validity results

| Check | Result |
|---|---|
| `sql/38` I-0 | 38 / 38 PASS (8 gate checks + 30 result checks) |
| `sql/38` I-1 | 54 / 54 PASS (10 gate + 22 default + 22 forced result checks) |
| `sql/38` I-2 | 26 / 26 PASS (10 gate + 8 default + 8 forced) |
| `sql/38` I-3 | 26 / 26 PASS |
| `sql/38` final | 70 / 70 PASS (10 gate + 30 default + 30 forced) |
| Rolled-back harness before the real run | the same checks passed for all phases; afterwards only the primary keys existed |
| EXPLAIN actual rows | equal to the expected row count, and identical for json and jsonb, for every statement, phase, mode and session (4,028 executions) |
| `sql/34` before / after | 38 / 38 PASS both times (documents, 70-leaf round trip, structure, escaping) |

Every query result under every index configuration and plan mode is identical to `access_log_flat`.

## 6. Fair head-to-head: identical btree expression indexes (I-1, default plans)

Execution ms, batch 1 median [p25–p75]; batch 2 median; the rule result for json vs jsonb.

| Statement | Index | Plan (both types) | json | jsonb | jsonb/json | Batch 2 json / jsonb | Result | Heap blocks json / jsonb |
|---|---|---|---|---|---:|---|---|---|
| Q07 BROKEN (12) | I-1a | Index Scan | 0.015 [0.015–0.015] | 0.015 [0.015–0.015] | 1.00 | 0.019 / 0.019 | no measurable difference | 14 / 14 buffers |
| Q08 BOT (225) | I-1b | Bitmap Heap Scan | 0.110 [0.105–0.111] | 0.109 [0.105–0.110] | 0.99 | 0.110 / 0.110 | no measurable difference | 205 / 198 |
| Q10 code 404 (30) | I-1c | Bitmap Heap Scan | 0.036 [0.029–0.037] | 0.029 [0.029–0.037] | 0.81 | 0.030 / 0.031 | no measurable difference | 32 / 32 buffers |
| Q11a lat 50–55 (422) | I-1d | Bitmap Heap Scan | 0.210 [0.208–0.216] | 0.210 [0.203–0.213] | 1.00 | 0.228 / 0.226 | no measurable difference | 362 / 337 |
| Q12a 1 day (13) | I-1e | Index Scan | 0.016 [0.016–0.017] | 0.017 [0.016–0.017] | 1.06 | 0.019 / 0.019 | no measurable difference | 15 / 15 buffers |
| Q12b 1 week (108) | I-1e | Bitmap Heap Scan | 0.066 [0.065–0.067] | 0.067 [0.066–0.069] | 1.02 | 0.071 / 0.072 | no measurable difference | 105 / 105 buffers |
| Q12c 1 month (498) | I-1e | Bitmap Heap Scan | 0.237 [0.229–0.244] | 0.226 [0.225–0.236] | 0.95 | 0.287 / 0.281 | no measurable difference | 419 / 403 |
| Q16 F3 and code 403 (78) | I-1c | Bitmap Heap Scan + Filter on `format_family` | 5.735 [5.576–5.882] | 1.420 [1.344–1.471] | 0.25 | 5.733 / 1.476 | **measurable: jsonb faster** | 427 / 404 |
| Q11b lat 0–60 (3,064) | I-1d (not chosen) | Seq Scan | 184.045 [175.327–194.592] | 21.574 [20.021–22.948] | 0.12 | 178.398 / 20.664 | **measurable: jsonb faster** | 1,250 / 981 pages |
| Q17 group by code | I-1b (not chosen) | Aggregate, Seq Scan | 104.302 [102.694–106.341] | 11.597 [11.357–12.264] | 0.11 | 114.294 / 13.771 | **measurable: jsonb faster** | 1,250 / 981 pages |
| Q09 F1 (1,528), control | none | Seq Scan | 60.333 [59.202–67.129] | 12.510 [12.149–13.054] | 0.21 | 63.170 / 12.467 | **measurable: jsonb faster** | 1,250 / 981 pages |

**Summary:**

| Plan situation | Statements | Result |
|---|---|---|
| index plan with nothing left to evaluate on the document | 7: Q07, Q08, Q10, Q11a, Q12a, Q12b, Q12c | no measurable difference (below 0.1 ms also in batch 2) |
| plan still reads documents | Q16 (heap filter), Q11b and Q17 (seq scan kept), Q09 (control) | jsonb measurably faster, by about the Step 6C factors |

- **Planning time:** no measurable json vs jsonb difference for any statement.
- **Plans:** the plan shapes and indexes chosen are identical on both types.
- **Estimates:** identical on both types, and much closer to the actual rows than at I-0 thanks to expression
  statistics: Q07 12 / 12, Q08 225 / 225, Q10 30 / 30, Q11a 406 / 422, Q11b 3,086 / 3,064, Q12c 500 / 498. Still off
  for Q12a (1 / 13), Q12b (88 / 108) and Q16 (2 / 78, a conjunction).
- **For comparison, I-0 control (json vs jsonb, no index):** jsonb was measurably faster for all 11 statements (ratios
  0.10–0.19).

## 7. Index effect per type (I-0 control → I-1, default plans)

| Statement | Plan change | json I-0 → I-1 ms (result) | jsonb I-0 → I-1 ms (result) | Planning ms I-0 → I-1 (json / jsonb) |
|---|---|---|---|---|
| Q07 | Seq Scan → Index Scan | 57.08 → 0.015 (I-1 faster) | 10.39 → 0.015 (I-1 faster) | 0.044 → 0.041 / 0.041 → 0.040 |
| Q08 | Seq Scan → Bitmap Heap Scan | 100.97 → 0.110 (I-1 faster) | 10.96 → 0.109 (I-1 faster) | 0.043 → 0.044 / 0.040 → 0.043 |
| Q10 | Seq Scan → Bitmap Heap Scan | 103.72 → 0.036 (I-1 faster) | 11.02 → 0.029 (I-1 faster) | 0.042 → 0.052 / 0.043 → 0.042 |
| Q11a | Seq Scan → Bitmap Heap Scan | 117.76 → 0.210 (I-1 faster) | 13.64 → 0.210 (I-1 faster) | 0.046 → 0.066 / 0.045 → 0.066 (I-0 faster) |
| Q11b | Seq Scan → Seq Scan | 172.87 → 184.05 (no measurable difference) | 19.33 → 21.57 (flagged I-0 faster; same plan, within the drift of §4) | 0.039 → 0.116 / 0.046 → 0.114 (I-0 faster) |
| Q12a | Seq Scan → Index Scan | 153.86 → 0.016 (I-1 faster) | 14.69 → 0.017 (I-1 faster) | 0.045 → 0.053 / 0.045 → 0.053 (I-0 faster) |
| Q12b | Seq Scan → Bitmap Heap Scan | 149.10 → 0.066 (I-1 faster) | 14.77 → 0.067 (I-1 faster) | 0.043 → 0.057 / 0.041 → 0.056 (I-0 faster) |
| Q12c | Seq Scan → Bitmap Heap Scan | 151.96 → 0.237 (I-1 faster) | 14.90 → 0.226 (I-1 faster) | 0.040 → 0.059 / 0.042 → 0.058 (I-0 faster) |
| Q16 | Seq Scan → Bitmap Heap Scan + Filter | 78.58 → 5.735 (I-1 faster) | 12.03 → 1.420 (I-1 faster) | 0.042 → 0.055 / 0.041 → 0.053 (I-0 faster) |
| Q17 | unchanged (Aggregate, Seq Scan) | 101.42 → 104.30 (no measurable difference) | 12.04 → 11.60 (no measurable difference) | 0.044 → 0.082 / 0.050 → 0.081 (I-0 faster) |
| Q09 control | unchanged (Seq Scan) | 56.32 → 60.33 (no measurable difference) | 10.84 → 12.51 (flagged I-0 faster; no index involved: drift) | 0.039 → 0.067 / 0.033 → 0.065 (I-0 faster) |

- The indexes make the 8 selective statements about 14× (Q16) to 9,600× (Q12a) faster on json and about 8.5× (Q16) to
  860× (Q12a) faster on jsonb.
- Planning time changes by −0.003 to +0.077 ms once indexes exist (largest for Q11b), similarly on both types.

## 8. Forced index paths (`enable_seqscan = off`, diagnostic)

- **Q11b (3,064 rows, 61 % of the table):**
  - **Default:** the planner keeps the Seq Scan. Estimated cost 1,450 (json) and 1,181 (jsonb), against 1,453.35 and
    1,184.35 for the bitmap path.
  - **Forced bitmap scan:** 1.236 ms on json against 184.0 ms by default, and 1.137 ms on jsonb against 21.6 ms.
    json vs jsonb on the forced plan: no measurable difference.
- **Q17:** the forced Index Scan over all 5,000 rows is no faster (json 112.8 ms, jsonb 13.5 ms). The estimated cost
  rises to 4,954 / 3,917.
- **Other indexed statements:** the same plans and timings as the default mode. Q16 remains jsonb faster (5.61 vs
  1.53 ms).

## 9. JSONB-only capability (separate from the head-to-head)

There is no json counterpart: `@>`, `?`, `@?` and `@@` do not exist for `json`, and `json` has no GIN operator class.
Execution ms, batch 1 median; the rule results compare configurations on `access_log_jsonb`.

| Statement (rows) | I-0 (no GIN) | I-2 `jsonb_ops` | I-3 `jsonb_path_ops` | I-0 vs I-2 | I-0 vs I-3 | I-2 vs I-3 |
|---|---:|---:|---:|---|---|---|
| C1 `@> {"record":{"record_validity":"BROKEN"}}` (12) | 10.230 | 0.112 | 0.027 | I-2 faster | I-3 faster | I-3 faster |
| C1b `@> {"fields":{"status":{"code":404}}}` (30) | 11.042 | 0.273 | 0.125 | I-2 faster | I-3 faster | I-3 faster |
| C1c `@> {"record":{"diagnostics":["truncated"]}}` (3) | 10.616 | 0.093 | 0.030 | I-2 faster | I-3 faster | I-3 faster |
| C1d `@> {"fields":{"entity_type":{"code":"BOT"}}}` (225) | 10.947 | 0.803 | 0.528 | I-2 faster | I-3 faster | I-3 faster |
| C3 `@? '$.fields.status.code ? (@ == 404)'` (30) | 11.644 | 0.215 | 0.104 | I-2 faster | I-3 faster | I-3 faster |
| C3b `@@ '$.record.record_validity == "BROKEN"'` (12) | 10.831 | 0.093 | 0.029 | I-2 faster | I-3 faster | I-3 faster |
| C2 `doc->'record'->'diagnostics' ? 'truncated'` (3) | 10.846 | 12.280 (Seq Scan) | 11.566 (Seq Scan) | no measurable difference | no measurable difference | no measurable difference |
| Q21 `JSON_EXISTS(doc, …)` (30) | 10.982 | 15.619 (Seq Scan) | 14.253 (Seq Scan) | flagged I-0 faster (same plan; batch 2: 11.1 vs 12.0) | flagged I-0 faster (same plan; batch 2: 11.1 vs 12.6) | no measurable difference |

- **Plans with GIN:** Bitmap Heap Scan on the GIN index for C1–C1d, C3 and C3b under both opclasses.
  - `jsonb_ops` needed one recheck removal for C3 (31 candidates, 30 rows); `jsonb_path_ops` returned exactly 30.
  - Heap blocks equal the matching rows (e.g. C1 12, C1d 198).
  - The GIN row estimate is a constant 50 whatever the actual count (3–225).
- **Not indexable by a GIN index on `doc`:**
  - C2 applies `?` to an expression (`doc->'record'->'diagnostics'`), not to the indexed column.
  - Q21 is a function call (`JSON_EXISTS`), not an indexable operator.
  - Both remain sequential scans. Their I-0 vs I-2/I-3 differences come from phase-to-phase drift on identical plans,
    not from the indexes.
- **Forced mode:** the same results. I-3 is faster than I-2 for all indexable statements. C2 (sequential scan on both)
  is flagged, but it is drift, not an index effect.

## 10. Observations (not a conclusion)

1. **With identical expression indexes, json and jsonb perform the same wherever the index answers the predicate.**
   - In the 7 statements whose plans only read the index and the matching heap rows, there is no measurable
     difference. There is no recheck (0 rows removed by index recheck, 0 lossy blocks), and only `log_id` is returned,
     so no document is parsed.
   - json reads slightly more heap blocks for the same rows (e.g. Q12c 419 vs 403), because its rows occupy more pages
     (Step 6B), but this does not reach the 10 % rule.
2. **Where a plan still evaluates documents, the Step 6C difference returns.**
   - Q16 filters 486 index candidates on `format_family`: 11.0 ms json vs 1.6 ms jsonb in the detail runs.
   - Q11b, Q17 and Q09 still scan all documents.
3. **Index builds cost more for json; sizes do not differ.**
   - The btree indexes store the same extracted keys, so their sizes and WAL are identical for json and jsonb.
   - Building on json takes 66–122 ms against 16–21 ms on jsonb, because each document's text is parsed to compute
     the key.
4. **Planner blind spot for JSON extraction cost.**
   - For Q11b the planner rates the Seq Scan and the bitmap index path as nearly equal (1,450 vs 1,453). In reality the
     index path is about 150× faster on json and about 19× faster on jsonb.
   - The cost model does not account for extracting a value from each document in a scan filter.
   - The effect exists for both types, but its consequence is far larger for json.
5. **Expression statistics.** ANALYZE after the index builds brought most estimates close to the actual row counts on
   both types (§6); at I-0 every equality used the default of 25 rows. Planning time rose by up to 0.08 ms with indexes
   present.
6. **jsonb-only GIN indexes** turn containment and jsonpath statements from about 10–12 ms sequential scans into
   0.03–0.8 ms bitmap scans.
   - In this workload `jsonb_path_ops` was smaller (3.73 MB vs 4.52 MB), faster to build (244 vs 554 ms, less WAL) and
     measurably faster for every indexable statement than `jsonb_ops`.
   - `jsonb_ops` additionally supports the `?` family on top-level keys, which no statement here could use.
   - Both GIN indexes are large relative to the jsonb heap (56 % and 46 % of 8.04 MB).
   - They do not help `?` on nested expressions or `JSON_EXISTS`.
7. **Storage with all designed indexes:** json 10.91 MB in total (indexes 0.63 MB); jsonb 16.96 MB (indexes 8.88 MB,
   of which 8.25 MB are the two GIN indexes).
8. **Limits.**
   - Covered: 5,000 rows, warm cache, a single client, and read statements only. Index maintenance cost on inserts and
     updates was not measured.
   - Phase-to-phase comparisons of identical plans carry drift of about 7–15 %, and up to 40 % in single batches
     (§4, §9). Within-phase json vs jsonb comparisons were interleaved and are not affected.

## 11. Run log

| Step | Result |
|---|---|
| Generator checks | `sql/38`–`sql/40` generated; the guards for missing psql variables raise an error (`\quit` cannot return an exit code, so the first draft was replaced); a stale `scripts/__pycache__` from a Step 6C import was removed; all Python calls use `-B` |
| `sql/34` | B-10a extended to accept exactly the designed Step 6D index names |
| Rolled-back harness | all builds and verifications I-0 → final in one transaction (I-0 38, I-1 54, I-2 26, I-3 26, final 70 checks PASS), then ROLLBACK; only primary keys afterwards |
| Runner | exit 0 in 163 s: static checks; baseline manifest created; digests; `sql/34` + `sql/38` I-0; I-0 sessions (29 s + 29 s); I-1 builds, checks, sessions (12 s + 13 s); I-2 (1 s + 1 s); I-3 (1 s + 1 s); final build and 70 checks; `sql/34`; digests unchanged; baseline verified; analysis 4,028 executions and 37 builds, no problems |

Note: `sql/run_step6c_json_queries.ps1` and `sql/36` describe the I-0 configuration. Their state checks (primary keys
only) now refuse to run while the Step 6D indexes exist. That is intended, so Step 6C cannot silently be re-measured
under a different index configuration.

## 12. Next step (not started)

Step 6E per the design: the results report and conclusions under the Step 6A rules. It draws on Step 6B (storage), 6C
(no-index queries) and 6D (indexes and jsonb-only capabilities).
