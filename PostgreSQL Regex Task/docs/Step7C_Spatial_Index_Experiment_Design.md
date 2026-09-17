# Step 7C — Spatial Index Experiment Design

**Status:** design only (13/09/2026). **Nothing was built, run or measured:** no index, no `EXPLAIN ANALYZE`, no
timing, and no change to project data, Step 6 objects or the Step 7B tables. The only database access was read-only
catalog queries (§1). Stopped for review.

**Based strictly on:**
- the approved design: [Step7A_PostGIS_Experiment_Design.md](Step7A_PostGIS_Experiment_Design.md)
- the executed setup: [Step7B_PostGIS_Setup_Preflight.md](Step7B_PostGIS_Setup_Preflight.md) (317 PASS / 0 FAIL)

**Numbering:** Step 7A §11 planned 7C as index builds and storage, 7D as the query workload. Step 7C now covers index
builds, index sizes **and** the query measurements; its report is `docs/Step7C_Spatial_Index_Experiment.md`.

**Out of scope, as in Step 6F:** JSONB-only capabilities (`@>`, `?`, jsonpath, GIN on documents) and the `json` type.
JSONB-specific *storage forms* (expression index vs stored generated column, on-the-fly construction) form their own
comparison class J (§4) and are kept apart from the fair flat-vs-JSONB comparisons.

---

## 1. Verified starting state (read-only catalog queries, 13/09/2026)

| Item | Result |
|---|---|
| Extension | `postgis` 3.6.2 in schema `postgis` |
| `log_regex_gis` | 15 tables, 5,000 rows each (`reltuples`); 15 primary keys; **0 secondary indexes** |
| Step 7B verification | 317 PASS / 0 FAIL (`analysis/step7/step7b_setup_checks.txt`) |
| Other sessions | 4 other client sessions, all idle |

**What each operator class supports** (`pg_amop`):

| Operator class | Method | Search operators | Ordering (KNN) |
|---|---|---|---|
| `gist_geometry_ops_2d` | GiST | `&&` plus 13 box operators (`@`, `~`, `<<`, …) | **`<->`, `<#>`** |
| `spgist_geometry_ops_2d` | SP-GiST | `&&` plus 11 box operators | none |
| `brin_geometry_inclusion_ops_2d` | BRIN | `&&`, `@`, `~` | none |
| `gist_geography_ops` | GiST | `&&` | **`<->`** |
| `spgist_geography_ops_nd` | SP-GiST | `&&` | none |

**Index support of the query functions** (`pg_proc.prosupport`):

| Function | Index support |
|---|---|
| `ST_Intersects(geometry, geometry)`, `ST_Within(geometry, geometry)`, `ST_DWithin(geometry, geometry, float8)`, `ST_DWithin(geography, geography, float8, boolean)` | `postgis_index_supportfn` |
| `ST_Distance(geography, geography, boolean)`, `ST_DistanceSphere`, `ST_Expand`, `ST_MakeEnvelope` | none |

All of these functions are IMMUTABLE.

**Consequences:**
- Every box and distance filter can use any of the five spatial index types.
- **Nearest-neighbour ordering can use only the GiST indexes** (G-1, Y-1, J-1, J-2, J-3, J-4). SP-GiST and BRIN are
  still run for KNN, as evidence that they are not usable there.

## 2. The 10 index definitions (exactly as in `sql/48`)

| ID | Statement |
|---|---|
| N-1 | `CREATE INDEX flat_numeric_btree_lat_lon_idx ON log_regex_gis.flat_numeric_btree USING btree (latitude_degrees, longitude_degrees);` |
| G-1 | `CREATE INDEX flat_geom_gist_idx ON log_regex_gis.flat_geom_gist USING gist (geom postgis.gist_geometry_ops_2d);` |
| G-2 | `CREATE INDEX flat_geom_spgist_idx ON log_regex_gis.flat_geom_spgist USING spgist (geom postgis.spgist_geometry_ops_2d);` |
| G-3 | `CREATE INDEX flat_geom_brin_idx ON log_regex_gis.flat_geom_brin USING brin (geom postgis.brin_geometry_inclusion_ops_2d);` |
| Y-1 | `CREATE INDEX flat_geog_gist_idx ON log_regex_gis.flat_geog_gist USING gist (geog postgis.gist_geography_ops);` |
| Y-2 | `CREATE INDEX flat_geog_spgist_idx ON log_regex_gis.flat_geog_spgist USING spgist (geog postgis.spgist_geography_ops_nd);` |
| J-1 | `CREATE INDEX jsonb_doc_expr_geom_gist_idx ON log_regex_gis.jsonb_doc_expr USING gist ((postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8, (doc->'fields'->'latitude'->>'degrees')::float8), 4326)) postgis.gist_geometry_ops_2d);` |
| J-2 | `CREATE INDEX jsonb_doc_expr_geog_gist_idx ON log_regex_gis.jsonb_doc_expr USING gist ((postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8, (doc->'fields'->'latitude'->>'degrees')::float8), 4326))) postgis.gist_geography_ops);` |
| J-3 | `CREATE INDEX jsonb_geom_gist_idx ON log_regex_gis.jsonb_geom_gist USING gist (geom postgis.gist_geometry_ops_2d);` |
| J-4 | `CREATE INDEX jsonb_geog_gist_idx ON log_regex_gis.jsonb_geog_gist USING gist (geog postgis.gist_geography_ops);` |

`sql/48` stays the reference definition. The 7C build script executes the same statement text; a static check asserts
byte identity with `sql/48`.

## 3. Configurations per representation

`<P>` is the point expression a query uses on that configuration.

| Representation | No-index control(s) | Indexed configuration(s) | `<P>` |
|---|---|---|---|
| numeric B-tree baseline | N-0 `flat_numeric` | N-1 `flat_numeric_btree` (btree lat, lon) | columns `latitude_degrees`, `longitude_degrees` |
| flat geometry | G-0 `flat_geom` | G-1 `flat_geom_gist` (GiST), G-2 `flat_geom_spgist` (SP-GiST), G-3 `flat_geom_brin` (BRIN) | `geom` |
| flat geography | Y-0 `flat_geog` | Y-1 `flat_geog_gist` (GiST), Y-2 `flat_geog_spgist` (SP-GiST) | `geog` |
| JSONB geometry | J-0g `jsonb_doc` (built on the fly); J-3c `jsonb_geom` (stored) | J-1 `jsonb_doc_expr` (expression GiST); J-3 `jsonb_geom_gist` (stored-column GiST) | J-0g / J-1: `E_JSONB_GEOM`; J-3c / J-3: `geom` |
| JSONB geography | J-0y `jsonb_doc` (built on the fly); J-4c `jsonb_geog` (stored) | J-2 `jsonb_doc_expr` (expression GiST); J-4 `jsonb_geog_gist` (stored-column GiST) | J-0y / J-2: `E_JSONB_GEOG`; J-4c / J-4: `geog` |

The JSONB point expressions:
- `E_JSONB_GEOM` = `postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8, (doc->'fields'->'latitude'->>'degrees')::float8), 4326)`
- `E_JSONB_GEOG` = `postgis.geography(` + `E_JSONB_GEOM` + `)`

Queries repeat them character for character so the planner can match J-1 / J-2. `jsonb_doc_expr` carries both J-1 and
J-2: geometry queries can match only J-1, geography queries only J-2.

## 4. Comparison classes (each reported separately)

| Class | Question | Pairs |
|---|---|---|
| **I** index vs control (same table, same data) | does the index help? | N-1 vs N-0; G-1, G-2, G-3 vs G-0; Y-1, Y-2 vs Y-0; J-1 vs J-0g; J-2 vs J-0y; J-3 vs J-3c; J-4 vs J-4c |
| **IM** index method, same column (item 3) | GiST vs SP-GiST vs BRIN | geometry: G-1 vs G-2 vs G-3 (boxes, K3); geography: Y-1 vs Y-2 (distances, K1 / K2) |
| **F** fair source comparison (same PostGIS type, same index method, same query) | flat vs JSONB-stored points | geometry GiST G-1 vs J-3 (control G-0 vs J-3c); geography GiST Y-1 vs J-4 (control Y-0 vs J-4c). The JSONB tables also carry the 7.2 MB of documents; that wider heap is a property of storing points next to documents, reported and not corrected |
| **J** JSONB storage forms (JSONB-specific, item 6) | expression index vs stored generated column; on-the-fly construction | J-1 vs J-3; J-2 vs J-4; J-0g vs J-3c; J-0y vs J-4c; P4 vs P1 / P3 |
| **GG** geometry vs geography (different semantics, item 5) | same answer by different types or methods | distance D1, D2, D6: Y-1 geography `ST_DWithin` vs G-1 geometry box + `ST_DistanceSphere` (MD); nearest neighbours: K1 (geography, metres) vs K1g (geometry, degrees), sets may legitimately differ; P1 vs P2 (spheroid vs sphere) |
| **NB** numeric B-tree vs spatial | box search without PostGIS | N-1 vs G-1 for B1–B6 |

Only classes I, IM and F are fair index comparisons. J, GG and NB compare *methods*, and are never used as a verdict on a
type or storage format.

## 5. Queries (exact)

**Literal helpers:**

| Helper | SQL |
|---|---|
| envelope | `postgis.ST_MakeEnvelope(<w>, <s>, <e>, <n>, 4326)` |
| geometry centre | `postgis.ST_SetSRID(postgis.ST_MakePoint(<lon>, <lat>), 4326)` |
| geography centre | `postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(<lon>, <lat>), 4326))` |

`<T>` is the configuration's table in schema `log_regex_gis`.

| ID | Statement template |
|---|---|
| B1–B4, B6 | `SELECT log_id FROM log_regex_gis.<T> WHERE postgis.ST_Intersects(<P>, postgis.ST_MakeEnvelope(<w>, <s>, <e>, <n>, 4326));` |
| B5 | `SELECT log_id FROM log_regex_gis.<T> WHERE postgis.ST_Intersects(<P>, postgis.ST_MakeEnvelope(170, -60, 180, 70, 4326)) OR postgis.ST_Intersects(<P>, postgis.ST_MakeEnvelope(-180, -60, -170, 70, 4326));` |
| BN1–BN6 (N-0, N-1) | `SELECT log_id FROM log_regex_gis.<T> WHERE latitude_degrees BETWEEN <s> AND <n> AND longitude_degrees BETWEEN <w> AND <e>;` (BN5: `… AND (longitude_degrees >= 170 OR longitude_degrees <= -170);`) |
| D1–D7 (spheroid) | `SELECT log_id FROM log_regex_gis.<T> WHERE postgis.ST_DWithin(<P>, <geography centre>, <r>);` |
| D1-s–D7-s (sphere) | `SELECT log_id FROM log_regex_gis.<T> WHERE postgis.ST_DWithin(<P>, <geography centre>, <r>, false);` |
| MD1, MD2, MD6 (G-0, G-1) | `SELECT log_id FROM log_regex_gis.<T> WHERE geom OPERATOR(postgis.&&) postgis.ST_Expand(<geometry centre>, <dx>, <dy>) AND postgis.ST_DistanceSphere(geom, <geometry centre>) <= <r>;` |
| K1, K2 | `SELECT log_id FROM log_regex_gis.<T> ORDER BY <P> OPERATOR(postgis.<->) <geography centre Reykjavik> LIMIT <10 \| 100>;` |
| K3 | `SELECT log_id FROM log_regex_gis.<T> ORDER BY <P> OPERATOR(postgis.<->) <geometry centre New York> LIMIT 10;` |
| K1g (G-0, G-1) | `SELECT log_id FROM log_regex_gis.<T> ORDER BY geom OPERATOR(postgis.<->) <geometry centre Reykjavik> LIMIT 10;` |
| P1 | `SELECT log_id, postgis.ST_Distance(geog, <geography centre Reykjavik>) FROM log_regex_gis.flat_geog;` |
| P2 | `SELECT log_id, postgis.ST_Distance(geog, <geography centre Reykjavik>, false) FROM log_regex_gis.flat_geog;` |
| P3 | `SELECT log_id, postgis.ST_Distance(postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(longitude_degrees::float8, latitude_degrees::float8), 4326)), <geography centre Reykjavik>) FROM log_regex_gis.flat_numeric;` |
| P4 | `SELECT log_id, postgis.ST_Distance(<E_JSONB_GEOG>, <geography centre Reykjavik>) FROM log_regex_gis.jsonb_doc;` |

**Notes on the templates:**
- **KNN statements** have no tie-breaker, so an ordering index scan is possible. Correctness is checked by set or
  multiset (§8).
- **MD box margins** are computed by the generator, rounded up to 7 decimals, and verified by the gate:
  - `dy = r / 110000` (degrees; 110,000 m underestimates a degree of latitude)
  - `dx = dy / cos(radians(|lat| + dy))`
  - Only mid-latitude centres without antimeridian or pole wrap are used (D1, D2, D6).

**Parameters** (from Step 7A §6; the expected rows are the plain-SQL oracle values verified in Step 7B §9.4):

| Query | Parameters | Expected rows |
|---|---|---:|
| B1 | s 40.4, w −74.3, n 41.0, e −73.6 | 410 |
| B2 | 35, −10, 60, 30 | 416 |
| B3 | 8, 68, 23, 80 | 1,580 |
| B4 | −60, −130, 70, 150 | 3,897 |
| B5 | −60, 170, 70, −170 (two envelopes) | 0 |
| B6 | 80, −180, 90, 180 | 1 |
| D1 | New York (40.7128, −74.0060), 10,000 m | 410 |
| D2 | Mumbai (19.0760, 72.8777), 500,000 m | 1,101 |
| D3 | Reykjavik (64.1466, −21.9426), 2,000,000 m | 599 |
| D4 | Mumbai, 5,000,000 m | 2,059 |
| D5 | (0, 180), 5,000,000 m | 262 |
| D6 | London (51.5074, −0.1278), 1,000 m | 15 |
| D7 | North Pole (90, 0), 100,000 m | 1 |
| K1 / K2 | Reykjavik | 10 / 100 |
| K3 | New York | 10 (6 points lie exactly at the centre) |
| K1g | Reykjavik | 10 |
| P1–P4 | Reykjavik | 5,000 (4,161 non-NULL distances) |

**Query × configuration matrix:**

| Queries | Configurations | Series |
|---|---|---:|
| B1–B6 | N-0, N-1 (BN form); G-0, G-1, G-2, G-3; J-0g, J-1, J-3c, J-3 | 60 |
| D1–D7 spheroid | Y-0, Y-1, Y-2; J-0y, J-2, J-4c, J-4 | 49 |
| D1-s–D7-s sphere | the same 7 | 49 |
| MD1, MD2, MD6 | G-0, G-1 | 6 |
| K1, K2 | Y-0, Y-1, Y-2; J-0y, J-2, J-4c, J-4 | 14 |
| K3 | G-0, G-1, G-2, G-3; J-0g, J-1, J-3c, J-3 | 8 |
| K1g | G-0, G-1 | 2 |
| P1–P4 | `flat_geog` (P1, P2), `flat_numeric` (P3), `jsonb_doc` (P4) | 4 |
| **Total** | | **192** |

## 6. Index build and index-size measurements

**Build phase** (after the before-gate and the rolled-back harness; §9):
1. Each of the 10 statements is built 3 times, in `sql/48` order.
   - Each build runs in a `DO` block that records the `clock_timestamp()` difference and the WAL insert-LSN difference.
   - `DROP INDEX` between builds; the third build is kept.
   - Session settings: `maintenance_work_mem = '64MB'`, `max_parallel_maintenance_workers = 0` (as in Step 6D).
2. `ANALYZE` of **all 15 tables** afterwards. Control and indexed tables thus get statistics at the same time, and
   J-1 / J-2 collect expression statistics.

**Recorded per index:**
- `pg_relation_size` (bytes), `relpages`, `reltuples`
- build time: median, min and max of the 3 builds
- build WAL bytes: median
- access method and operator class (catalog)
- for G-3: the BRIN `pages_per_range` (default 128) against the heap pages of `flat_geom_brin`, i.e. the number of block
  ranges

**Recorded per table (before and after the build):**
- `pg_relation_size`, `pg_table_size`, `pg_indexes_size`, `pg_total_relation_size`
- the index size relative to the point column's share of the heap

Sizes are deterministic and reported exactly. No `pgstattuple` is used, because no additional extension is installed.

## 7. EXPLAIN ANALYZE methodology

| Item | Protocol |
|---|---|
| Sessions | two independent **read-only** sessions (`default_transaction_read_only = on`) after the build phase; each measures all 192 series |
| Fixed settings | `jit = off`, `max_parallel_workers_per_gather = 0`, `TimeZone = 'UTC'`, `track_io_timing = on`, `search_path = pg_catalog, postgis`; every other planner and memory setting stays at the server default and is captured by `EXPLAIN (SETTINGS)` (e.g. `work_mem` 4 MB, `random_page_cost` 4, `shared_buffers` 128 MB, all `enable_*` on) |
| Command | `EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY, SUMMARY, FORMAT JSON)` |
| Warm-up | 3 unmeasured rounds per query block |
| Measurement | 15 measured rounds per query block. Every round runs **all** configurations of the query, so flat and JSONB, and indexed and control, are interleaved. The configuration order is rotated cyclically by round number and reversed on alternate rounds |
| Detail run | 1 run per series with `TIMING ON`: per-node times, and serialisation separated |
| Forced diagnostic | 1 run per series with `enable_seqscan = off` and `TIMING ON`, reported separately, no timing verdict. Shows the index path when the default plan does not use it |
| Recorded per execution | planning time; execution time (serialisation included); planning buffers and memory; shared hit / read / dirtied blocks; temp blocks; I/O time; **plan shape** (node tree with index names); whether and which index is used; estimated vs actual rows (top and scan node); rows removed by filter or index recheck; exact / lossy heap blocks |
| Environment | **AC power required**: power source and CPU frequency recorded before and after each session, and a session is aborted if on battery. Other active client sessions must be 0 before each query block (flagged otherwise). The machine is kept awake during sessions |
| Volume | 192 series × (3 + 15 + 1 + 1) executions × 2 sessions ≈ 7,700 executions |

## 8. Correctness checks (plain-SQL oracle on `flat_numeric`)

The gate runs read-only before timing in each session, and again after the second session. A mismatch stops the runner
(`LR024`), and a series counts only when its gate passed.

| ID | Check |
|---|---|
| C-01 data unchanged | the Step 7B construction and copy checks (O-1a … O-1g, O-7a … O-7c) pass; per-table data fingerprints of all 15 tables equal the pre-build values |
| C-02 index state | exactly the 10 designed indexes: name, table, access method, operator class, key column or expression (longitude before latitude), `indisvalid` / `indisready`; no other secondary index |
| C-03 results = oracle | every query × configuration returns the oracle checksum (count : md5 of sorted `log_id`s), as listed below |
| C-04 plan invariance | every C-03 checksum is identical in three modes: default; `enable_seqscan = off`; `enable_indexscan = off, enable_bitmapscan = off` |

**The C-03 oracles:**
- **Boxes:** the `BETWEEN` oracle — B1 `410:e8583952…`, B2 `416:7e9ec48e…`, B3 `1580:e07244d9…`, B4 `3897:69112583…`,
  B5 `0:-`, B6 `1:743394be…`.
- **Distances, spheroid and sphere:** the haversine oracle with R = 6,371,008.7714 m — D1 `410:e8583952…`,
  D2 `1101:09f877d4…`, D3 `599:56123c81…`, D4 `2059:5231b94f…`, D5 `262:67d6fd7d…`, D6 `15:1425ecba…`,
  D7 `1:743394be…`. MD1 / MD2 / MD6 must equal D1 / D2 / D6.
- **K1 / K2:** result set = oracle set `b8bcc3f1…` / `ff4ae07b…` (no tie at rank 10 or 100, O-5a).
- **K3 and K1g:** planar-degree oracle `ORDER BY (lon - clon)^2 + (lat - clat)^2` on `flat_numeric`. The multiset of
  the 10 distances must be equal; set equality is required only if there is no tie at rank 10 (the tie count is
  recorded). K1g's overlap with the K1 set is recorded as a GG observation.
- **P1–P4:** 5,000 rows, 4,161 non-NULL distances. P3 and P4 must equal P1 for every `log_id` (the points are
  byte-identical, Step 7B O-1e). P2 must be within 0.001 m of the haversine value.

## 9. Before/after integrity and isolation checks

**Before the build phase and after the second session:**

| Area | Checks |
|---|---|
| Project data | `log_regex` digest `f8042db0…` (203 items); `log_regex_json` data digest `9e6f8831…` (10 items); Step 6D index digest `e20752ca…` (14 indexes, 9,510,912 bytes); `raw_access_logs` integrity 10 / 10; `sql/27` 4 foreign keys; `sql/34` 38 / 38; `sql/38 final` 70 / 70; Step 6E write schema unchanged; manifests Step 6C (11) and Step 6D (26); source fingerprints `f562354d…` / `fb3bc163…`; relations 49 / 16 / 8 |
| PostGIS state | extensions `plpgsql` + `postgis` 3.6.2 in `postgis`; the 6 schemas; `public` 0 / 0 / 0; 0 event triggers; 0 `pg_db_role_setting` rows |
| `log_regex_gis` | before the build: `sql/47` 155 / 155 (including no secondary index). After: 15 tables + 15 primary keys + exactly the 10 designed indexes (C-02); data fingerprints unchanged (C-01); 0 dependency edges to existing schemas |
| New manifest | before the build, SHA-256 of the Step 7B outputs (generator, `sql/45`–`sql/48`, runner, `analysis/step7/step7b_*`, the Step 7B doc) into `analysis/step7/step7c_baseline_step7b_sha256.txt`; verified at the end |
| Static allowlist | the build script contains only the 10 designed `CREATE INDEX` statements (byte-identical to `sql/48`), `DROP INDEX` of those names, and `ANALYZE` of the 15 tables. Verification and measurement scripts contain no write statement. No script references an existing schema |
| Rolled-back harness | before the real build: 1 build per index, `ANALYZE`, C-02, C-03 and C-04 inside one transaction, then `ROLLBACK`. Afterwards 0 secondary indexes, and `sql/47` passes 155 / 155 |

## 10. Rollback and cleanup

- **Builds:** each build statement runs in its own transaction, so a failed build leaves no partial index. The
  measurement sessions are read-only, so they have nothing to roll back.
- **Back to the Step 7B state.** Run automatically if the build phase fails midway, otherwise only on request:
  1. `DROP INDEX IF EXISTS log_regex_gis.<name>;` for exactly the 10 designed names.
  2. `ANALYZE` of the affected tables.
  3. Verify `sql/47` 155 / 155 and all integrity checks of §9.
- **Full removal** (Step 7B §7, only on request): `DROP SCHEMA log_regex_gis CASCADE; DROP EXTENSION postgis; DROP SCHEMA
  postgis;` followed by the Step 7B B-checks.

## 11. Criteria for a measurable index benefit

**Verdicts for class I** (index vs its own control):

| Verdict | Condition |
|---|---|
| **measurable benefit** | all of: (1) C-03 / C-04 pass; (2) the **default plan uses the index** (an Index, Index Only or Bitmap Index Scan node names it); (3) the Step 6A rule: IQRs do not overlap and the faster median is at most 90 % of the control median; (4) if either median is below 0.1 ms, the same measurable direction holds in session 2 |
| index used, no measurable benefit | (1) and (2) hold, (3) or (4) does not |
| index not used by the planner | the default plan does not scan the index. The forced diagnostic is shown, with no timing verdict |
| measurable regression | (1) and (2) hold, and the rule holds with the indexed configuration slower |
| not supported | the operator class lacks the operator (§1: KNN on SP-GiST and BRIN); confirmed by the plan shape |

**Other classes:**
- **IM, F, J, GG, NB:** the same timing rule applied pairwise, labelled with its class. GG and NB are method comparisons
  without a verdict on types or formats.
- **Secondary metrics:** planning time uses the same rule. Buffer counts are deterministic and reported exactly.
- **Cost context:** every benefit is reported next to the index size and build time. Build time has only 3 samples, so
  it is given as a median with min–max, and a difference is "consistent" when the ranges do not overlap. Write and
  maintenance cost of spatial indexes is **not** measured in 7C.
- **Scope of any verdict:** 5,000 points, warm cache, a single client, one laptop on AC power, statistics from one
  `ANALYZE`. Session-to-session drift is expected (Step 6D: 7–15 %); only interleaved within-session comparisons
  receive a verdict. No benefit is predicted in advance.

## 12. Planned files (not created)

| File | Content |
|---|---|
| `scripts/step7c_spatial_index_experiment.py` | imports the Step 7B definitions unchanged (tables, expressions, indexes); defines queries, configurations, oracles; `generate [--check]`, `harness`, `static-check`, `analyze` |
| `sql/49_build_measure_gis_indexes.sql` | 3 timed builds per index, keeping the third, then `ANALYZE`; refuses without `-v approved_step=7C` (`LR023`) |
| `sql/50_verify_gis_index_phase.sql` | read-only; `-v phase=before\|after`: index state, data fingerprints, C-01 … C-04 (`LR024`) |
| `sql/51_measure_gis_queries.sql` | read-only measurement session; `-v session=1\|2` (`LR025`) |
| `sql/52_drop_gis_indexes.sql` | cleanup to the Step 7B state; only on request or after a failed build (`LR026`) |
| `sql/run_step7c_spatial_indexes.ps1` | runner: static checks → manifest → before checks → harness → builds → `sql/50 after` → session 1 → session 2 → `sql/50 after` → after checks → analysis |
| `analysis/step7/step7c_*` | build log, index-size CSV, raw EXPLAIN output, executions, summary and comparison CSVs, generated summary |
| `docs/Step7C_Spatial_Index_Experiment.md` | results report with scoped conclusions |

## 13. Decisions for review

1. **Scope:** Step 7C covers builds, sizes and query measurements; the report is the Step 7C document.
2. **Matrix:** 192 series, including KNN on SP-GiST / BRIN as "not supported" evidence and the sphere variants of D1–D7.
3. **Geometry distance method:** MD is limited to D1, D2 and D6 (no antimeridian or pole).
4. **KNN correctness:** no tie-breaker in KNN statements; checked by set / multiset.
5. **Forced plans:** used for correctness in three modes; one forced diagnostic run per series, with no timing verdict.
6. **Statistics:** `ANALYZE` of all 15 tables after the builds.
7. **Harness:** 1 build per index before the real 3-build phase.
8. **Environment:** AC power required during measurement sessions.
