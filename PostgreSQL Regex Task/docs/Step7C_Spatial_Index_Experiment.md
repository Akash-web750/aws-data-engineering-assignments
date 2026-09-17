# Step 7C — Spatial Index Experiment (Results)

**Status:** executed 13/09/2026. The runner `sql/run_step7c_spatial_indexes.ps1` finished with **943 PASS / 0 FAIL / 0 FLAG**
(`analysis/step7/step7c_checks.txt`). Measurement sessions started 2026-09-12 21:14:29 UTC and 21:15:27 UTC.

**Scope of this document:** the experiment and its verification, exactly per the approved design
[Step7C_Spatial_Index_Experiment_Design.md](Step7C_Spatial_Index_Experiment_Design.md) (all 8 decisions of §13).
- **Not included:** Step 7D and final PostGIS conclusions. Every statement below is scoped to this data set and machine (§11).
- **Unchanged:** existing project data, Step 6 objects, the Step 7B source data and the query matrix.
- **Indexes:** no index beyond the 10 designed ones was created.

---

## 1. Execution order and results

| # | Stage | Result |
|---|---|---|
| 1 | Static checks: `sql/45`–`48` match the unchanged 7B generator; `sql/49`–`52` match the 7C generator; statement allowlist (sql/49 = the 10 `sql/48` statements × 3, 20 `DROP INDEX` of those names, `ANALYZE` of the 15 tables; sql/50–51 without write statements; no reference to an existing schema; 3,840 `EXPLAIN` in sql/51); ASCII | R-01 … R-04 PASS |
| 2 | Step 7B manifest (14 files: generator, sql/45–48, 7B runner, `step7b_*` outputs, Step 7A/7A1/7A2/7B docs, the approved 7C design) created, then verified | M-01, M-02 PASS |
| 3 | Before-integrity checks (read-only, §2) | all PASS |
| 4 | Rolled-back harness: 10 builds + `ANALYZE` of 15 tables + `sql/50 phase after` (745 checks incl. the 606-row matrix) in one transaction, `ROLLBACK`; then verification of the Step 7B state | H-01 … H-07, HR-01, HR-13, HB-* PASS |
| 5 | `sql/49 -v approved_step=7C`: 10 indexes × 3 timed builds (third kept), `ANALYZE` of all 15 tables | S-49, S-49b, S-49c, A49-* PASS (30 build records, 10 final sizes) |
| 6 | Gate G-50a (read-only) before session 1 | 745/745; C-03 606/606; fingerprints unchanged |
| 7 | Session 1 (read-only), AC power polled every 2 s | 3,840 executions, 24.9 s, 0 other active sessions |
| 8 | Gate G-50b before session 2 | 745/745; C-03 606/606; fingerprints unchanged |
| 9 | Session 2 (read-only) | 3,840 executions, 24.8 s, 0 other active sessions |
| 10 | Gate G-50c after session 2 | 745/745; C-03 606/606; fingerprints unchanged |
| 11 | After-integrity checks (§2) | all PASS |
| 12 | Analysis (`analyze`): 7,680 executions, all row counts as expected, no JIT, 30 builds | N-01 PASS, problems: none |

The harness was also run once on its own (`-HarnessOnly`, 154 PASS / 0 FAIL, kept as
`analysis/step7/step7c_harness_only_checks.txt`) before the full run; the full run repeated it before building.

## 2. Integrity and isolation (before / after)

| Area | Before build | After session 2 |
|---|---|---|
| `log_regex` digest | `f8042db0…` over 203 items | identical |
| `log_regex_json` data digest | `9e6f8831…` over 10 items | identical |
| Step 6D index digest | `e20752ca…`, 14 indexes, 9,510,912 bytes | identical |
| `raw_access_logs` integrity | 10 / 10 | 10 / 10 |
| `sql/27` / `sql/34` / `sql/38 final` | 4 FKs / 38 of 38 / 70 of 70 | same |
| Step 6E write schema, source fingerprints (`f562354d…` / `fb3bc163…`), relations 49 / 16 / 8 | as expected | identical |
| Manifests Step 6C (11), Step 6D (26), Step 7B (14) | 0 mismatches | 0 mismatches |
| PostGIS state | `plpgsql 1.0`, `postgis 3.6.2` in `postgis`; 6 schemas; `public` 0/0/0; 0 event triggers; 0 `pg_db_role_setting` rows; no preload | identical |
| `log_regex_gis` inventory | 15 tables, 15 PKs, **0** secondary indexes | 15 tables, 15 PKs, exactly the **10** designed indexes |
| `sql/47` (Step 7B, read-only) | 155 / 155 | — (it asserts "no secondary index"; C-02 replaces it after the build) |
| `sql/50 before` / `after` | 113 / 113 | 745 / 745 (three gates) |
| Data fingerprints of the 15 tables | recorded | equal in the harness, after `ROLLBACK`, and in G-50a, G-50b, G-50c |
| Dependency edges to existing schemas (A-04a / A-04b) | 0 / 0 | 0 / 0 |
| `pg_class` + `pg_statistic` digest of `log_regex_gis` | `0e146575…` (30 relations), 36 statistic rows `fe5ceda5…` | after build + `ANALYZE`: `559fc36d…` (40 relations), 38 rows `add13686…`; unchanged by both read-only sessions |

**Rollback verification (harness):**
- **Inventory:** after `ROLLBACK`, 15 / 15 / 0 secondary indexes.
- **Step 7B checks:** `sql/47` 155 / 155 and `sql/50 before` 113 / 113.
- **Data and catalog:** fingerprints equal; `pg_class` (pages, tuples, `relhasindex`, filenode) and `pg_statistic` of the schema byte-identical to before.
- **Project state:** all digests and the Step 7B manifest unchanged.

## 3. Index builds and sizes

Settings: `maintenance_work_mem = 64MB`, `max_parallel_maintenance_workers = 0`. Each build ran in its own `DO` block
(`clock_timestamp()` difference, WAL insert-LSN difference). Size = the kept third build.

| ID | Index (method, operator class) | Build ms median [min–max] | WAL bytes median | Size bytes / pages | Index ÷ point-column bytes | Index ÷ heap |
|---|---|---|---:|---:|---:|---:|
| N-1 | btree (lat, lon), `numeric_ops` | 3.793 [3.688–14.394] | 149,928 | 180,224 / 22 | 2.78 | 71.0 % |
| G-1 | gist, `gist_geometry_ops_2d` | 9.073 [8.717–12.122] | 137,576 | 212,992 / 26 | 1.77 | 66.7 % |
| G-2 | spgist, `spgist_geometry_ops_2d` | 10.607 [10.341–11.928] | 192,840 | 278,528 / 34 | 2.31 | 87.2 % |
| G-3 | brin, `brin_geometry_inclusion_ops_2d` | 3.322 [2.967–4.374] | 2,024 | 24,576 / 3 | 0.20 | 7.7 % |
| Y-1 | gist, `gist_geography_ops` | 13.137 [13.026–14.219] | 206,888 | 393,216 / 48 | 3.26 | 123.1 % |
| Y-2 | spgist, `spgist_geography_ops_nd` | 13.387 [13.154–14.526] | 264,896 | 376,832 / 46 | 3.12 | 117.9 % |
| J-1 | gist expression (geometry from `doc`) | 38.385 [36.915–39.057] | 138,824 | 212,992 / 26 | 1.77 ¹ | 2.7 % |
| J-2 | gist expression (geography from `doc`) | 40.477 [39.831–40.830] | 208,400 | 393,216 / 48 | 3.26 ¹ | 4.9 % |
| J-3 | gist stored `geom`, `gist_geometry_ops_2d` | 9.669 [9.643–12.819] | 137,600 | 212,992 / 26 | 1.77 | 3.0 % |
| J-4 | gist stored `geog`, `gist_geography_ops` | 13.419 [13.411–17.756] | 207,056 | 393,216 / 48 | 3.26 | 5.5 % |

**Reference sizes** (read-only, after the sessions):
- **Point columns:** geometry and geography 120,669 bytes (4,161 non-NULL points × 29 bytes); numeric lat + lon 64,747 bytes.
- **Heaps:**

  | Tables | Bytes | Pages |
  |---|---:|---:|
  | flat geometry / geography tables | 319,488 | 39 |
  | `flat_numeric*` | 253,952 | 31 |
  | `jsonb_doc*` | 8,036,352 | 981 |
  | `jsonb_geom*` / `jsonb_geog*` | 7,200,768 | 879 |

- **Per-table totals** before and after: `step7c_sizes.csv`.

¹ J-1 / J-2 index an expression that is not stored in the heap; the ratio uses the size of the equivalent stored column.

**Observations** (build time has 3 samples; "consistent" = min–max ranges do not overlap, design §11):
- **Expression indexes are consistently slower to build than stored-column indexes:**
  - J-1 [36.9–39.1 ms] vs J-3 [9.6–12.8 ms]
  - J-2 [39.8–40.8 ms] vs J-4 [13.4–17.8 ms]
- **Other consistent build-time differences:**
  - BRIN G-3 [3.0–4.4 ms] builds faster than G-1, G-2, Y-1 and Y-2.
  - Geometry GiST G-1 [8.7–12.1 ms] builds faster than geography GiST Y-1 [13.0–14.2 ms].
- **Not consistent:**
  - G-1 vs G-2, and Y-1 vs Y-2.
  - Flat vs JSONB stored column: G-1 vs J-3, Y-1 vs J-4.
  - N-1 vs G-1 / G-3: N-1's first build took 14.4 ms, while its builds 2 and 3 took 3.7 and 3.8 ms.
- **BRIN block ranges:** the heap has 39 pages and `pages_per_range` is 128 (default), so G-3 summarises the whole
  heap as a **single block range**.
- **Sizes across the 3 builds:**
  - **Identical:** B-tree, BRIN and the geometry GiST indexes (G-1, J-1, J-3).
  - **Varied:**

    | Index | Size range across builds (bytes) |
    |---|---|
    | G-2 | 270,336–278,528 |
    | Y-1 | 368,640–393,216 |
    | Y-2 | 360,448–376,832 |
    | J-2 | 368,640–393,216 |
    | J-4 | 393,216–401,408 |

  - This deviates from the design's statement that "sizes are deterministic" (§9, item 4). The table reports the kept build.

## 4. Correctness (C-01 … C-04)

| Check | Result |
|---|---|
| C-01 data unchanged | 103 Step 7B construction / copy checks (O-1a … O-1g, O-7a … O-7c) pass in every gate; the fingerprints of the 15 tables equal the pre-build values in the harness and in all three gates |
| C-02 index state | all 10 indexes: expected table, method, operator class, `indisvalid` / `indisready` true, key column or expression with longitude before latitude; no other secondary index |
| Recorded oracles (R-*) | the 15 Step 7B oracle checksums (B1–B6, D1–D7, K1, K2) and P3 `5000:4161` reproduced |
| C-03 / C-04 | 202 checks × 3 plan modes (default; `enable_seqscan = off`; `enable_indexscan` and `enable_bitmapscan` off) = **606 per gate**. Harness + G-50a + G-50b + G-50c = **2,424 PASS, 0 FAIL** |

**Details:**
- **MD1 / MD2 / MD6:** equal to D1 / D2 / D6.
- **Distances:** every spheroid and sphere distance series equals the haversine oracle.
- **K1 / K2:** every configuration returns the oracle set (`b8bcc3f1…` / `ff4ae07b…`).
- **K3 and K1g:**
  - No tie at rank 10, so set equality was required and holds: K3 set `81da4e78…` (6 of its 10 distances are 0), K1g set `347b1c8b…`.
  - The planar-distance multisets are equal on every configuration and in every mode.
  - K1 vs K1g overlap: **8 of 10** `log_id`s (GG observation; the sets may legitimately differ).
- **P1 = P3 = P4:** checksum `5000:4161:4cd03979…` for every `log_id`.
- **P2:** within 0.001 m of haversine.
- **Row counts:** every one of the 7,680 recorded executions returned the expected number of rows.

## 5. Measurement sessions

| | Session 1 | Session 2 |
|---|---|---|
| Start (UTC) / duration | 21:14:29 / 24.9 s | 21:15:27 / 24.8 s |
| Executions | 3,840 (192 series × 3 warm-up + 15 measured + 1 detail + 1 forced) | 3,840 |
| Other active client sessions before each of the 23 blocks | 0 (4 idle pgAdmin sessions) | 0 |
| Power before / after | AC online, battery 100 %; CPU 2,592 MHz, processor performance 103 % / 103 % | AC online; 115 % / 123 % |
| psql stderr | empty | empty |

**Settings and buffers:**
- **Settings in the plans:** `EXPLAIN (SETTINGS)` shows only `jit = off`, `max_parallel_workers_per_gather = 0` and
  `search_path = pg_catalog, postgis`, plus `enable_seqscan = off` in the 192 forced runs. Every other planner setting
  was at the server default.
- **Settings not shown:** `TimeZone = 'UTC'` and `track_io_timing = on` were set by sql/51, but `SETTINGS` does not list
  them (they do not affect planning).
- **Buffers:** 0 shared blocks read, 0 dirtied and 0 temp blocks written in all measured runs (warm cache), so there is
  no I/O time.

**Session-to-session consistency:**
- **Plans:** each series used one plan shape in all 15 measured runs, and it was identical in both sessions.
- **Timing drift:** the session 2 / session 1 execution-median ratio over the 192 series is 0.83–1.13 (median 1.00).

## 6. Class I — index vs its own control (session 1; Step 6A rule; session-2 confirmation below 0.1 ms)

**Verdicts (109 index-vs-control series):**

| Verdict | Series |
|---|---:|
| measurable benefit | **90** |
| index used, no measurable benefit | 5 |
| measurable regression | 3 |
| index not used by the planner | 7 |
| not supported (no ordering operator) | 4 |

**Verdicts per index** (with cost context):

| Index | Size bytes | Build ms | Series | Benefit | Used, no benefit | Regression | Not used | Not supported |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| N-1 btree | 180,224 | 3.8 | 6 | 4 (B1, B2, B3, B6) | – | – | 2 (B4, B5) | – |
| G-1 geometry GiST | 212,992 | 9.1 | 11 | 8 (B1, B2, B5, B6, MD1, MD6, K1g, K3) | 2 (B3, MD2) | 1 (B4) | – | – |
| G-2 geometry SP-GiST | 278,528 | 10.6 | 7 | 4 (B1, B2, B5, B6) | 1 (B3) | 1 (B4) | – | 1 (K3) |
| G-3 geometry BRIN | 24,576 | 3.3 | 7 | – | – | 1 (B5) | 5 (B1–B4, B6) | 1 (K3) |
| Y-1 geography GiST | 393,216 | 13.1 | 16 | 16 (D1–D7, D1-s–D7-s, K1, K2) | – | – | – | – |
| Y-2 geography SP-GiST | 376,832 | 13.4 | 16 | 13 | 1 (D4-s) | – | – | 2 (K1, K2) |
| J-1 JSONB expression geometry GiST | 212,992 | 38.4 | 7 | 7 (B1–B6, K3) | – | – | – | – |
| J-2 JSONB expression geography GiST | 393,216 | 40.5 | 16 | 16 | – | – | – | – |
| J-3 JSONB stored geometry GiST | 212,992 | 9.7 | 7 | 6 (B1–B3, B5, B6, K3) | 1 (B4) | – | – | – |
| J-4 JSONB stored geography GiST | 393,216 | 13.4 | 16 | 16 | – | – | – | – |

**Speed-up = control median ÷ indexed median.** Codes:
- `B` measurable benefit
- `U` index used, no measurable benefit
- `R` measurable regression
- `NU` index not used by the planner
- `NS` not supported
- `*` a median below 0.1 ms; the direction was confirmed in session 2 (all 22 such class I cases were confirmed)

Full medians and IQRs: `analysis/step7/step7c_summary.md`, `step7c_verdicts.csv`.

**Boxes** (default plans: B1/B2 bitmap scans; B3/B4 plain index scans on G-1/G-2, bitmap scans on J-1/J-3; B5 BitmapOr; B6 index scans, bitmap scan on N-1):

| Query (rows) | N-1 | G-1 | G-2 | G-3 | J-1 | J-3 |
|---|---|---|---|---|---|---|
| B1 (410) | 3.14 B | 3.40 B | 3.30 B | 0.94 NU | 9.84 B | 3.56 B |
| B2 (416) | 2.29 B | 3.35 B | 3.05 B | 0.92 NU | 10.16 B | 3.58 B |
| B3 (1,580) | 1.65 B | 1.07 U | 1.19 U | 0.98 NU | 2.82 B | 1.36 B |
| B4 (3,897) | 0.96 NU | **0.64 R** | **0.68 R** | 0.93 NU | 1.14 B | 0.90 U |
| B5 (0) | 0.99 NU | 32.5 B* | 18.4 B* | **0.82 R** | 930 B* | 53.7 B* |
| B6 (1) | 24.1 B* | 31.4 B* | 18.0 B* | 0.95 NU | 751 B* | 58.0 B* |

**Distances and geography nearest neighbours** (default plans: index or bitmap scans for every indexed configuration;
K1/K2 on Y-2 use `Limit → Sort → Seq Scan`):

| Query (rows) | Y-1 | Y-2 | J-2 | J-4 |
|---|---|---|---|---|
| D1 (410) | 17.7 B | 9.82 B | 11.9 B | 15.2 B |
| D2 (1,101) | 6.36 B | 4.80 B | 4.68 B | 5.29 B |
| D3 (599) | 12.4 B | 8.00 B | 7.88 B | 9.51 B |
| D4 (2,059) | 3.06 B | 2.50 B | 2.34 B | 2.69 B |
| D5 (262) | 6.02 B | 5.02 B | 7.08 B | 5.62 B |
| D6 (15) | 70.4 B | 18.2 B | 103 B | 92.9 B* |
| D7 (1) | 103 B* | 10.3 B | 531 B* | 147 B* |
| D1-s (410) | 6.02 B | 3.30 B | 10.2 B | 6.06 B |
| D2-s (1,101) | 2.44 B | 1.63 B | 3.97 B | 2.37 B |
| D3-s (599) | 4.44 B | 2.89 B | 7.01 B | 3.91 B |
| D4-s (2,059) | 1.41 B | 1.20 U | 1.99 B | 1.52 B |
| D5-s (262) | 5.00 B | 3.07 B | 6.96 B | 4.44 B |
| D6-s (15) | 29.4 B* | 6.10 B | 93.0 B | 40.9 B* |
| D7-s (1) | 74.7 B* | 7.11 B | 657 B* | 111 B* |
| K1 (10) | 29.1 B | 0.93 NS | 155 B | 35.4 B |
| K2 (100) | 11.5 B | 0.94 NS | 20.3 B | 12.1 B |

**Geometry nearest neighbours and the geometry distance method:**

| Series | G-1 | G-2 | G-3 | J-1 | J-3 |
|---|---|---|---|---|---|
| K3 (10) | 22.3 B* | 0.96 NS | 0.92 NS | 173 B | 33.2 B* |
| K1g (10) | 27.4 B* | | | | |
| MD1 (410) | 1.92 B | | | | |
| MD2 (1,101) | 1.17 U | | | | |
| MD6 (15) | 9.13 B* | | | | |

**Plan evidence for the series without a benefit** (session 1 detail and forced runs; forced timings carry no verdict,
decision 5):
- **B3 / B4 on G-1 and G-2 (U / R).** The planner chose a plain Index Scan for 1,580 / 3,897 rows (32 % / 78 % of the
  table):
  - GiST: 1,556 / 3,828 shared-buffer hits; SP-GiST: 870 / 2,134.
  - The control's sequential scan: 39.
  - B4 medians: G-1 2.528 ms and G-2 2.354 ms vs G-0 1.612 ms.
- **B4 on J-3 (U).** A Bitmap Heap Scan over 878 exact heap blocks (900 hits) against a sequential scan of 879 pages:
  2.633 vs 2.374 ms, not measurable.
- **B4 on J-1 (B).** The control J-0g builds the point from every document (26.4 ms); the expression index avoids that
  for rows outside the box (23.2 ms).
- **G-3 BRIN (NU, and R on B5).**
  - **Default plans:** B1–B4 and B6 used a sequential scan.
  - **Forced plans:** a Bitmap Index Scan that marks all 39 heap blocks lossy and rechecks every row. Examples: B1
    1.135 ms forced vs 0.916 ms in the default detail run; B4 1.955 vs 1.651 ms.
  - **B5:** the default plan used the BRIN index (BitmapOr): 39 of 39 lossy blocks, 5,000 rows removed by recheck,
    1.504 ms vs 1.235 ms for G-0.
  - **Consistent with:** the single block range (§3).
- **N-1 on B4 (78 % of rows) and B5** (`longitude >= 170 OR longitude <= -170`). The default plan was a sequential scan;
  the forced Bitmap Index Scan took 1.405 ms (B4) and 0.801 ms (B5), shown without a verdict.
- **MD2 on G-1 (U):** an index scan with 1,080 hits; 1.798 vs 2.111 ms, IQRs overlap.
- **D4-s on Y-2 (U):** an index scan with 1,552 hits; 2.282 vs 2.736 ms, IQRs overlap.
- **Not supported:** K1 / K2 on Y-2 and K3 on G-2 / G-3 used `Limit → Sort → Seq Scan` in both the default and the forced
  plan. The operator class has no ordering operator (design §1), so no index path exists.

**Planning time (secondary metric, same rule):**
- **Direction:** the indexed configuration plans measurably slower than its control in 97 of 109 series; 12 are not
  measurable and none is faster.
- **Geography `ST_DWithin` with a geography index present:**

  | Configurations | Planning median |
  |---|---|
  | Y-1, Y-2, J-2, J-4 | 0.43–1.30 ms (largest on D4 / D4-s) |
  | Y-0, J-0y, J-4c (controls) | 0.03–0.04 ms |

- **Box queries on indexed tables:** 0.06–0.25 ms. **Nearest-neighbour queries:** 0.04–0.08 ms.
- **Planning vs execution:** in one benefit series, D4-s on Y-1, the median planning increase (1.096 ms) exceeds the
  median execution saving (0.799 ms). This is recorded; the design's verdict is based on execution time.

**Estimates vs actual rows** (detail runs; recorded, not investigated further in 7C):
- **Geography `ST_DWithin`:** estimated at 1 row on every configuration (actual 15–2,059).
- **Boxes:**
  - Numeric `BETWEEN`: 29 / 101 / 511 estimated for 410 / 416 / 1,580 actual.
  - Geometry boxes: 64 / 500 / 1,899 / 4,740 estimated for 410 / 416 / 1,580 / 3,897.
- **On-the-fly construction (J-0g, J-0y):** estimated at 1 row.
- **MD2:** 441 estimated vs 1,101 actual.

**Session 2 alone:** the same execution-rule direction and index usage in 105 of 109 class I series. The 4 marginal
differences are shown below; per the design, the session 1 verdict stands.

| Series | Session 1 verdict | Session 2 alone |
|---|---|---|
| B4 on J-1 | benefit | not measurable |
| B4 on J-3 | not measurable | control faster |
| MD2 on G-1 | not measurable | indexed faster |
| D4-s on Y-2 | not measurable | indexed faster |

## 7. Other comparison classes (execution time, session 1)

Classes IM and F are fair index comparisons. Classes J, GG and NB compare **methods** and give no verdict on a type or
storage format (design §4). Full rows, including planning time: `step7c_comparisons.csv`.

### 7.1 IM — index method on the same column (fair)

| Comparison | Result |
|---|---|
| G-1 GiST vs G-2 SP-GiST, boxes | not measurable B1–B4; GiST faster B5 (1.76×) and B6 (1.75×), both confirmed in session 2 |
| G-1 / G-2 vs G-3 BRIN, boxes | GiST and SP-GiST faster on B1, B2, B5, B6 (3.3–39.6×; BRIN not used or lossy); B3: G-2 faster than G-3 (1.21×), G-1 vs G-3 not measurable; **B4: G-3 (sequential scan) faster than G-1 and G-2** (1.45× / 1.35×) |
| K3 geometry | G-1 faster than G-2 (23.2×) and G-3 (24.3×); G-2 vs G-3 not measurable (both Sort) |
| Y-1 GiST vs Y-2 SP-GiST, distances | Y-1 faster in 13 of 14 series (1.18–10.5×); D5 not measurable |
| Y-1 vs Y-2, K1 / K2 | Y-1 faster (31.3× / 12.1×); Y-2 not supported |

30 of 37 IM execution comparisons are measurable.

### 7.2 F — flat vs JSONB-stored points (same type, same index method, same query; fair)

| Pair | Flat faster | Not measurable | JSONB faster |
|---|---:|---:|---:|
| Indexed: G-1 vs J-3 (boxes, K3), Y-1 vs J-4 (distances, K1, K2) — 23 series | 14 (1.17–1.72×) | 9 | 0 |
| Controls: G-0 vs J-3c, Y-0 vs J-4c — 23 series | 21 (1.11–1.85×) | 2 (D1, D2) | 0 |

**Not measurable (indexed pairs):**

| Series | Why |
|---|---|
| B4, B5, B6 | not measurable (B5 and B6 medians identical: 0.038 and 0.024 ms) |
| D7, D7-s | not measurable |
| D6, D6-s | session 2 does not confirm (medians below 0.1 ms) |
| K1, K3 | not measurable |

**Context:**
- **Heaps:** the JSONB tables also store the documents; heap 879 pages vs 39 (reported, not corrected; design §4).
- **Buffers:**
  - Sequential scans read 879 vs 39 pages.
  - Indexed B1 hits: 331 on J-3 vs 42 on G-1.
  - Nearest-neighbour index scans: equal (13–14 hits).

### 7.3 J — JSONB storage forms (JSONB-specific, not a fair comparison)

| Comparison | Result |
|---|---|
| Expression index J-1 vs stored-column index J-3 (B1–B6, K3) | stored column faster in all 7 (1.32–8.8×; B5 / B6 confirmed in session 2) |
| Expression index J-2 vs stored-column index J-4 (D, D-s, K1, K2) | stored column faster in 14 of 16 (1.7–5.8×); D7 not confirmed in session 2, D7-s not measurable |
| On-the-fly construction J-0g / J-0y vs stored column without index J-3c / J-4c | stored column faster in all 23: boxes 11.1–22.8×, spheroid distances 3.7–5.9×, sphere distances 7.6–8.8×, K1 / K2 / K3 7.6–12.1× |
| Distance to every point: P4 (build geography from JSONB) vs P1 (stored geography) vs P3 (build from numeric) | P1 10.226 ms < P3 14.413 ms < P4 36.468 ms, all measurable |

**Build and size cost** (§3): the expression indexes are the same size as the stored-column indexes but take about
3–4× longer to build. The stored-column tables carry the generated column in the heap.

### 7.4 GG — geometry vs geography (method comparison; different semantics)

| Comparison | Result |
|---|---|
| Geography `ST_DWithin` (Y-1) vs geometry `&&` box + `ST_DistanceSphere` (MD on G-1) | Y-1 faster for D1 (1.36×) and D2 (1.57×); MD6 faster for D6 (0.071 vs 0.116 ms, confirmed in session 2) |
| Same, without an index (Y-0 vs MD on G-0) | MD faster in all three (6.8×, 3.5×, 12.6×) |
| K1 geography (Y-1) vs K1g geometry (G-1) | K1g faster (0.054 vs 0.105 ms, confirmed); without index K1g 1.481 vs K1 3.056 ms. Result sets differ: 8 of 10 common (§4) |
| P1 spheroid vs P2 sphere `ST_Distance` | sphere faster (5.188 vs 10.226 ms) |

### 7.5 NB — numeric B-tree vs spatial (method comparison)

| Comparison | Result |
|---|---|
| N-1 vs G-1 | N-1 faster: B1 (1.35×), B3 (2.01×), B4 (1.98×; N-1 sequential scan vs G-1 index scan), B6 (1.33×, confirmed). Not measurable: B2. G-1 faster: B5 (24×, confirmed; N-1 uses a sequential scan for the `OR` predicate) |
| N-0 vs G-0 (both sequential scans) | numeric faster in all 6 boxes (1.30–1.74×) |

## 8. Deviations, fixes and observations

1. **Static-check false positive (fixed before any database access).** The read-only "write keyword" scan matched the
   `ANALYZE` option inside `EXPLAIN (ANALYZE, …)`. The checker now strips the `EXPLAIN` option list before scanning.
   The SQL and the query matrix did not change.
2. **Runner parse error (no database access).** The first harness-only invocation failed in the PowerShell parser
   (`"$When:"` read as a drive-qualified variable). It was fixed with `${When}` / `${N}`, and the runner was re-run.
3. **Duplicate check ID.** `H-01` was used twice in the harness-only report. The post-rollback state checks are now
   `HR-01` / `HR-13`.
4. **The harness ran twice** (harness-only run and full run), with PASS both times. Each run ended in `ROLLBACK`, which
   was verified.
5. **Index sizes varied across the three builds** for SP-GiST and the geography GiST indexes (§3). The design expected
   deterministic sizes; the kept third build is reported.
6. **`EXPLAIN (SETTINGS)` does not list `TimeZone` or `track_io_timing`** (§5). With 0 shared blocks read, no I/O time
   was recorded.
7. **Two measured sessions ran back to back** (about 1 minute apart), both on AC power with no other active session.
   The CPU "processor performance" counter read 102–129 % (turbo), recorded before and after each session and build.
8. **README not changed.** `README.md` still shows the Step 6F status; it was not part of this request.

## 9. State left in the database

- **Indexes:** the 10 designed indexes remain built in `log_regex_gis`, and the statistics from the post-build `ANALYZE`
  remain in place.
- **Unchanged:** everything else is identical to Step 7B.
- **`sql/52_drop_gis_indexes.sql`:** not run (only on request, with `-v confirm_cleanup=yes`). It would drop exactly
  the 10 names, then run `ANALYZE` on the affected tables. Afterwards, `sql/47` (155 / 155) and the §2 checks would
  verify the Step 7B state.

## 10. Scope of the results

Every verdict above holds only for:
- 5,000 points (4,161 non-NULL)
- a warm cache and a single client
- one Windows laptop on AC power, PostgreSQL 17.9 with default planner settings
- statistics from one `ANALYZE`

**Comparisons:** only interleaved within-session comparisons carry a verdict.

**Not measured:** write and maintenance cost of the spatial indexes.

No final PostGIS conclusion is drawn here, and Step 7D has not been started.

## 11. Files

| File | Content |
|---|---|
| `scripts/step7c_spatial_index_experiment.py` | generator (`generate`, `harness`, `static-check`, `analyze`); imports the Step 7B definitions unchanged |
| `sql/49_build_measure_gis_indexes.sql` | 3 timed builds per index, `ANALYZE` (LR023 guard) |
| `sql/50_verify_gis_index_phase.sql` | read-only gate, `phase=before` (113) / `after` (745) (LR024) |
| `sql/51_measure_gis_queries.sql` | read-only measurement session (LR025) |
| `sql/52_drop_gis_indexes.sql` | cleanup, not run (LR026) |
| `sql/run_step7c_spatial_indexes.ps1` | runner (`-HarnessOnly` available) |
| `analysis/step7/step7c_checks.txt`, `step7c_run_log.txt` | 943 checks; full log |
| `analysis/step7/step7c_harness_only_checks.txt`, `step7c_harness_only_log.txt`, `step7c_harness.sql` | harness-only run (154 PASS) and harness SQL |
| `analysis/step7/step7c_baseline_step7b_sha256.txt` | Step 7B manifest (14 files) |
| `analysis/step7/step7c_build_log.txt` | `@@BUILD`, `@@TABLESIZE`, `@@INDEXSIZE` records |
| `analysis/step7/step7c_session1_raw.txt`, `step7c_session2_raw.txt` (+ `_stderr`, `_stdout`) | raw EXPLAIN JSON of both sessions |
| `analysis/step7/step7c_executions.csv` | 7,680 executions with plan metrics |
| `analysis/step7/step7c_summary.csv`, `step7c_verdicts.csv`, `step7c_comparisons.csv` | per-series statistics, class I verdicts, IM / F / J / GG / NB comparisons |
| `analysis/step7/step7c_builds.csv`, `step7c_sizes.csv` | builds and sizes |
| `analysis/step7/step7c_summary.md` | generated tables, including every plan shape |
