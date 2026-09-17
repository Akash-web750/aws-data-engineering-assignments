# Step 7E — Final PostGIS Conclusion

**Status:** final conclusion of the PostGIS phase (13/09/2026). **No database query, performance test or experiment was
run for this step.** Every statement rests on the recorded results of Steps 7A–7D.
- **Database state:** the 10 Step 7C indexes remain built, PostGIS stays installed, and `sql/52` has not been run.
- **Out of scope:** the overall project conclusion has not been started.

**Evidence base:**

| Step | Document | Result |
|---|---|---|
| 7A, 7A.1, 7A.2 | [Step7A_PostGIS_Experiment_Design.md](Step7A_PostGIS_Experiment_Design.md), [Step7A1_PostGIS_Installation_Preflight.md](Step7A1_PostGIS_Installation_Preflight.md), [Step7A2_PostGIS_Post_Installation_Verification.md](Step7A2_PostGIS_Post_Installation_Verification.md) | design; PostGIS 3.6.2 installed manually and verified |
| 7B | [Step7B_PostGIS_Setup_Preflight.md](Step7B_PostGIS_Setup_Preflight.md) | 15 tables, plain-SQL oracles, sphere / spheroid consistency: 317 PASS / 0 FAIL |
| 7C | [Step7C_Spatial_Index_Experiment_Design.md](Step7C_Spatial_Index_Experiment_Design.md), [Step7C_Spatial_Index_Experiment.md](Step7C_Spatial_Index_Experiment.md) | 10 indexes × 3 builds; 192 series × 2 sessions (7,680 executions); correctness 2,424 / 0; 943 PASS / 0 FAIL / 0 FLAG |
| 7D | [Step7D_PostGIS_Results_Analysis.md](Step7D_PostGIS_Results_Analysis.md) | consolidated analysis (approved) |

Section references such as "7D §8" point to the Step 7D analysis.

---

## 0. Scope of every conclusion in this document

**The conclusions hold only for this combination:**

| Dimension | Tested |
|---|---|
| Data | 5,000 access-log rows; 4,161 points with valid coordinates, spread worldwide, including points beyond ±90° longitude and the boundary rows (0, 0), (90, 180), (−90, −180) |
| Table size | flat tables 31–39 heap pages; JSONB tables 879–981 pages. All data in shared buffers (0 blocks read from disk) |
| Software | PostgreSQL 17.9 (Windows x64), PostGIS 3.6.2 (GEOS 3.14.1dev, PROJ 8.2.1); SRID 4326 only |
| Server and session | default planner settings, `shared_buffers` 128 MB, `work_mem` 4 MB, `jit` off, no parallel workers; statistics from one `ANALYZE` |
| Hardware | one Windows laptop on AC power; warm cache; single client; read-only sessions |
| Workload | 6 box queries, 7 distance queries on the spheroid and on the sphere, 3 geometry distance variants, 4 nearest-neighbour queries, 4 distance-to-all-points queries; 192 query × configuration series |
| Verdict rule | IQRs do not overlap and the faster median is ≤ 90 % of the slower; below 0.1 ms, confirmed in session 2; only interleaved comparisons within one query block |

**Meaning of "recommended":** the approach that was measurably fastest, or the only correct or supported one, **in
these measurements**. It is not a general PostgreSQL / PostGIS rule. Other data sizes, table layouts, hardware, settings
or write-heavy workloads were not tested and may behave differently.

**Fair vs method comparisons:**
- **Fair comparisons** (sections 3, 4, 7): index vs its own control, index method on the same column, and flat vs JSONB
  with the same type and index.
- **JSONB-specific findings** (section 8) and **method comparisons** (geometry vs geography, numeric B-tree vs spatial)
  are kept separate and give no verdict on a data type or storage format as such.

## 1. Conclusions at a glance

1. **GiST is the index method to use** for every spatial workload tested. SP-GiST was never measurably faster, and only
   GiST supports nearest-neighbour ordering. BRIN gave no benefit on these 39-page tables.
2. **Geography with GiST is the approach for metric distance filters and metric nearest neighbours.**
   - Correctness: one query form was correct everywhere, including across the antimeridian and at the pole.
   - Speed: it gave a measurable benefit in all 14 distance series.
   - Cost: 0.43–1.30 ms of planning per query.
3. **Geometry with GiST is the approach for degree boxes and planar nearest neighbours.** Geography box queries were not
   tested.
4. **Spatial indexes paid off for selective queries** (0 to about 22 % of rows) and for nearest neighbours. They did not
   pay off for boxes returning 32–78 % of rows. The planner still chose the index there and regressed on the 78 % box.
5. **Flat coordinates beat JSONB coordinates** with the same type and index: faster in 14 of 23 indexed series and
   never slower.
6. **Within JSONB, a stored generated column with GiST beats a GiST expression index** for reads (21 of 23). Index size
   is the same and the build is 3–4× faster. Building points from the document on the fly without an index was the
   slowest option measured (24–47 ms per box query).
7. **Sphere and spheroid distance filters returned identical sets** for this data (maximum difference 0.452 %; no point
   near any tested radius). The sphere was measurably faster for computing the distance to every point.
8. **Planning time is a real cost of spatial indexes:** the indexed table planned measurably slower in 97 of 109 series
   and never faster.

## 2. Geometry vs geography (final recommendation)

**Method comparison.** Geometry and geography differ in semantics, so this is not a verdict on the types
(7D §4, §8, §9).

| Tested need | Recommendation for this data | Measured basis |
|---|---|---|
| Distance filter in metres, any centre (D1–D7, sphere and spheroid) | **geography + GiST** | Results equal the haversine oracle for all 7 centres, including (0, 180) across the antimeridian (262 rows) and the North Pole (1 row). Measurable benefit in all 14 series (1.41–103×). No special query form needed |
| Nearest neighbours in metres (K1, K2) | **geography + GiST** | 0.105 / 0.273 ms (29.1× / 11.5×); geography `<->` orders by sphere distance, and the sets equal the haversine oracle |
| Boxes in degrees (B1–B6) | **geometry + GiST** (or the numeric B-tree, §9) | Measured on geometry and numeric only; the antimeridian box B5 needs two envelopes in geometry |
| Nearest neighbours in planar degrees (K3, K1g) | **geometry + GiST** | 0.054–0.074 ms (22.3–27.4×). Degree order is not metre order: K1g shares only 8 of 10 rows with K1 at Reykjavik |
| Metre distance with geometry (`&&` box + `ST_DistanceSphere`, MD1 / MD2 / MD6) | **measured alternative for mid-latitude centres only** | D6 (1 km): geometry faster (0.071 vs 0.116 ms). D1 (10 km) and D2 (500 km): geography faster (0.438 vs 0.597 ms, 1.146 vs 1.798 ms). Geometry planned faster (0.09 vs 0.46–0.50 ms). Needs precomputed box margins; untested at the antimeridian or pole |

**Costs of geography** (7D §1, §11):
- **Size:** the geography GiST index is 1.85× the geometry GiST (393,216 vs 212,992 bytes).
- **Build:** consistently slower (13.1 vs 9.1 ms median).
- **Planning:** distance queries plan in 0.43–1.30 ms with the index, against 0.03–0.04 ms without.

**Semantics recorded in Step 7B:**
- (0, 180) to (0, −180) is 0 m as geography but 360° as geometry.
- Two pole points are 0 m apart.
- Mixing SRIDs raises an error.

## 3. GiST vs SP-GiST vs BRIN (final recommendation) — fair comparison

**Recommendation for this data: GiST.**

| Method | Measured result (7D §3, §9, §13) |
|---|---|
| **GiST** | **Recommended.** Speed: faster than SP-GiST for B5, B6, 13 of 14 geography distance series, K1, K2 and K3; not measurably different for B1–B4 and D5. Nearest neighbours: the only method with an ordering operator |
| **SP-GiST** | **No measured advantage.** Never measurably faster than GiST. Nearest neighbours: not supported (sort over a sequential scan). Cost: geometry index 31 % larger with 40 % more WAL; geography index 4 % smaller with 28 % more WAL; build times overlap with GiST |
| **BRIN** | **Not appropriate for these tables (section 6).** Not used for 5 of 6 boxes; regression on the sixth (B5); nearest neighbours not supported |

**Planning time:** the index method did not change it (0 of 37 comparisons measurable).

## 4. When spatial indexes provided a measurable benefit — fair comparison

**Index vs its own no-index control (109 series):**

| Verdict | Series |
|---|---:|
| measurable benefit | **90** |
| index used, no measurable benefit | 5 |
| measurable regression | 3 |
| index not used by the planner | 7 |
| not supported (kept separate) | 4 |

**Benefit by result size** (7D §2):

| Result rows (share of 5,000) | Benefit range | Where no benefit occurred |
|---|---|---|
| 0–15 (B5, B6, D6 and D7 in both variants, K1, K3, K1g, MD6) | 6.1–930× | B-tree on the `OR` antimeridian box; BRIN; SP-GiST / BRIN nearest neighbours (not supported) |
| 100 (K2) | 11.5–20.3× | SP-GiST (not supported) |
| 262–1,101, 5–22 % (B1, B2, D1–D3 and D5 in both variants, MD1, MD2) | 1.6–17.7× | BRIN; MD2 on geometry GiST |
| 1,580–3,897, 32–78 % (B3, B4, D4 in both variants) | 1.14–3.06× in 11 of 20 | geometry GiST / SP-GiST on B3 (no benefit) and B4 (regression); B-tree and BRIN on B4 (not used) |

**Benefits per index:**

| Index | Measurable benefits |
|---|---|
| geography GiST: Y-1 flat, J-2 JSONB expression, J-4 JSONB stored | 16 of 16 each |
| geography SP-GiST (Y-2) | 13 of 16 |
| geometry GiST (G-1) | 8 of 11 |
| JSONB expression geometry GiST (J-1) | 7 of 7 |
| JSONB stored geometry GiST (J-3) | 6 of 7 |
| B-tree (N-1) | 4 of 6 |
| geometry SP-GiST (G-2) | 4 of 7 |
| BRIN (G-3) | 0 of 7 |

**Largest ratios:** these came where the control builds each point from the JSONB document (24–46 ms). The same
queries against a stored column without index took 1.4–9.1 ms.

## 5. When the planner did not use an index or chose poorly

**Usage** (7D §10, §12):
- **Stable:** every series used its index in 15 of 15 or 0 of 15 runs, with identical plans in both sessions.

**Not used (7):**
- **BRIN:** B1, B2, B3, B4, B6. Its forced plans showed every heap block lossy.
- **B-tree on B4** (78 % of rows): a forced bitmap plan was 1.405 ms vs 1.353 ms for the default sequential scan.
- **B-tree on B5:** the `OR` predicate on longitude.

In all 7 the indexed table ran the same sequential-scan plan as its control, with no measurable difference.

**Chosen poorly:**
- **Regressions (3):**
  - B4 on geometry GiST (2.528 vs 1.612 ms) and geometry SP-GiST (2.354 ms). Plain index scans over 78 % of rows, chosen
    with an estimate of 4,740 of 5,000 rows.
  - B5 on BRIN (1.504 vs 1.235 ms).
- **Used without measurable benefit (5):**
  - B3 on geometry GiST and SP-GiST (1,580 rows)
  - B4 on the JSONB stored geometry GiST
  - MD2 on geometry GiST
  - D4-s on geography SP-GiST

**Row estimates** (recorded, cause not analysed):
- **Geography `ST_DWithin`:** estimated at 1 row on every configuration (actual 15–2,059).
- **Boxes:** misestimated by up to 14× (numeric B1: 29 estimated vs 410 actual).
- **MD queries:** misestimated by up to 205× (MD1: 2 estimated vs 410 actual).
- **Points built on the fly:** estimated at 1 row.

**Not supported — separate from the verdicts (4):** nearest neighbours on geography SP-GiST (K1, K2) and on geometry
SP-GiST and BRIN (K3). No index path exists; default and forced plans both sort a sequential scan.

**Conclusion for this data:** the planner used every usable index for selective queries with benefit. For boxes
returning 32 % or more of the table, it chose spatial index scans that gained nothing or lost time.

## 6. BRIN limitations for this dataset

**Why BRIN could not help here** (7D §13):
- **One block range:** `flat_geom_brin` has **39 heap pages**, and the index uses the default `pages_per_range` of 128.
  The whole table is therefore a single block range.
- **Whole-globe summary:** the table contains points at (90, 180) and (−90, −180), so that one summary box covers the
  whole coordinate range.
- **Every box matches:** every query box matches the summary. A BRIN scan returns all 39 pages as lossy blocks and
  rechecks all 5,000 rows.

**Measured result:**

| Query | Outcome |
|---|---|
| B1–B4, B6 | not used |
| B5 | measurable regression (5,000 rows rechecked) |
| K3 (nearest neighbours) | not supported |
| vs GiST and SP-GiST | slower for B1, B2, B5, B6 |

**Cost:** BRIN was the cheapest index (24,576 bytes, 2,024 bytes of WAL, 3.3 ms build) but bought nothing.

**Scope:** larger tables, other `pages_per_range` values and spatially ordered tables were **not tested**. This result
says nothing about BRIN on them.

## 7. Flat coordinates vs JSONB coordinates — fair comparison

**Pairs:** the same PostGIS type, the same GiST index and the same query, on the flat table vs the JSONB table with a
stored generated column (7D §5).

| Pairing | Flat faster | Not measurable | JSONB faster |
|---|---:|---:|---:|
| Indexed (23 series) | 14 (1.17–1.72×) | 9 | **0** |
| No index (23 series) | 21 (1.11–1.85×) | 2 | **0** |

**Same on both:**
- index size (212,992 / 393,216 bytes)
- build WAL
- build time (ranges overlap)
- planning time (0 of 46 comparisons measurable)
- results

**Different:**
- **Heap width:** 879 vs 39 pages, because the JSONB table also stores the documents.
- **Buffers:** more heap buffers touched in sequential and bitmap scans.
- **Plans:** for 6 series (B3, B4, D2, D4, D2-s, D4-s) the planner chose a bitmap scan on JSONB instead of a plain
  index scan.

**Conclusion for this data:** for spatial reads, points in the flat table were faster or equal, never slower. The
difference is small for index-answered queries (at most 1.72×), and not measurable for B4–B6, D6 and D7 (both
variants), and K1 and K3.

## 8. JSONB expression index vs stored generated column — JSONB-specific

**This compares two ways of indexing points that live inside JSONB documents. It is not a verdict on JSONB vs flat
storage** (7D §6).

| Aspect | Expression index (J-1 geometry, J-2 geography) | Stored generated column + GiST (J-3, J-4) |
|---|---|---|
| Query speed | slower | **faster in 21 of 23** (geometry 7 of 7, 1.32–8.8×; geography 14 of 16, 1.7–5.8×) |
| Planning | slower in 14 of 23 | faster in 14 of 23, never slower |
| Index size | 212,992 / 393,216 bytes | identical |
| Build time | 38.4 / 40.5 ms | **9.7 / 13.4 ms** (consistently 3–4× faster) |
| Build WAL | 138,824 / 208,400 bytes | 137,600 / 207,056 bytes |
| Heap | 981 pages (no point column) | 879 pages including the generated column (cause of the smaller heap not analysed) |
| Query form | the query must repeat the indexed expression; it matched in every tested query | queries use the column name |

**Plan evidence:** the expression index rebuilds the point from the document for every candidate row in its filter;
the stored column does not. Buffer counts were similar.

**Without any index** (JSONB-specific): building the point from the document per row was the slowest option measured.
- **Speed:** 24–47 ms per box query and 27–34 ms per distance query, against 1.4–9.1 ms for a stored column without
  index (stored 3.7–22.8× faster in all 23 series).
- **Distance to every point:** the JSONB construction (P4) took 36.468 ms, vs 14.413 ms from numeric columns (P3) and
  10.226 ms from a stored geography column (P1).

**Recommendation for points inside JSONB, for this read workload:** a stored generated column with GiST.

**Caveat:** insert and update costs of maintaining a generated column vs an expression index were **not measured**
(section 11).

## 9. Bounding-box, distance and nearest-neighbour findings

**Bounding boxes** (7D §7):
- **Selective boxes (B1, B2: 410 / 416 rows):**
  - geometry GiST 3.35–3.40× and B-tree 2.29–3.14× faster than their controls
  - B-tree vs geometry GiST (method comparison): B-tree faster on B1 (1.35×), not measurable on B2
- **Very selective boxes:**
  - polar cap B6 (1 row): B-tree 0.018 ms, geometry GiST 0.024 ms; B-tree faster (1.33×, confirmed)
  - antimeridian box B5 (0 rows): geometry GiST 0.038 ms; the B-tree was not used for the `OR` form, so GiST was
    24× faster
- **Large boxes:**
  - B3 (32 %): only the B-tree helped among the flat indexes (1.65×)
  - B4 (78 %): the sequential scan was best; geometry GiST and SP-GiST regressed
- **Without index:** numeric `BETWEEN` was faster than `ST_Intersects` in all 6 boxes (1.30–1.74×).
- **Results:** `ST_Intersects` and `BETWEEN` returned identical sets for B1–B6. At an edge point, `ST_Within` and
  `ST_Intersects` differ.

**Distance filters** (7D §8):
- **Frequency:** every geography index gave a measurable benefit in every distance series, except SP-GiST on D4-s.
- **Magnitude:** falls with the result size.

  | Series | Benefit |
  |---|---|
  | D6 / D7 and their sphere variants (GiST) | 29–657× |
  | D4 (2,059 rows, 41 %) | 2.3–3.1× |
  | D4-s | 1.4–2.0× |

- **Mechanism:** the index condition `geog && _st_expand(centre, r)` returned exactly the result rows for D1–D4 and D7.
  For D5 it returned 571 candidates for 262 matches, and for D6, 28 candidates for 15.
- **Costs against the saving:** planning grows with the radius (1.13–1.30 ms for D4 / D4-s). For D4-s on geography GiST
  the planning increase (1.096 ms) exceeded the execution saving (0.799 ms), and on the *derived* planning + execution
  total the control was faster.

**Nearest neighbours** (7D §9):
- **GiST only:** 0.054–1.456 ms (the maximum is K2 on the JSONB expression index; flat and stored-column GiST
  0.054–0.319 ms), with 13–14 buffers for 10 neighbours and 100–104 for 100; 11.5–173× faster than the
  sequential scan plus sort.
- **SP-GiST and BRIN:** no index path (not supported).
- **Ordering units:** geography `<->` orders by sphere distance; geometry `<->` orders by planar degrees.
- **Ties:** the statements have no tie-breaker. No tie occurred at rank 10 or 100 in this data. K3 has 6 points exactly
  at its centre, and its set still matched the oracle.
- **Not tested:** nearest neighbours combined with a filter, `<#>`, other values of k.

## 10. Sphere vs spheroid finding

**Step 7B** (7D §14):

| Check | Result |
|---|---|
| Sphere `ST_Distance` vs haversine (R = 6,371,008.7714 m) | max difference **0.0000473 m** over 4,161 points × 6 centres |
| Spheroid vs sphere | max relative difference **0.452 %** |
| Points within ±0.6 % of any tested radius | **0** |
| Geography `<->` | returns the sphere distance (max 5.0 × 10⁻⁹ m from sphere, up to 9.87 m from spheroid) |

**Step 7C:**
- **Result sets:** spheroid and sphere `ST_DWithin` returned **identical sets** for D1–D7 on every configuration and
  plan mode, all equal to the haversine oracle.
- **Speed, interleaved:** the only interleaved comparison is the distance to every point, where the sphere was
  measurably faster (5.188 vs 10.226 ms).
- **Speed, not interleaved:** D and D-s ran in different blocks. Their *derived* ratios show the spheroid filter
  costing 1.55–3.38× the sphere filter where the whole table is filtered, but 0.95–1.25× with an index (D5 up to 2.81×).

**Conclusion for this data:** for these points and radii the sphere gave the same answers as the spheroid at lower cost
wherever many rows reach the distance function. Whether that holds for points or radii closer to the 0.45 % difference
was **not tested**.

## 11. Measured costs: index size, build, WAL, planning and write-related observations

**Build and size** (7D §1):

| Index | Size bytes / pages | Build ms median [min–max] | Build WAL bytes |
|---|---:|---|---:|
| B-tree (lat, lon) | 180,224 / 22 | 3.8 [3.7–14.4] | 149,928 |
| geometry GiST (flat / JSONB expression / JSONB stored) | 212,992 / 26 | 9.1 / 38.4 / 9.7 | 137,576 / 138,824 / 137,600 |
| geometry SP-GiST | 278,528 / 34 | 10.6 | 192,840 |
| geometry BRIN | 24,576 / 3 | 3.3 | 2,024 |
| geography GiST (flat / JSONB expression / JSONB stored) | 393,216 / 48 | 13.1 / 40.5 / 13.4 | 206,888 / 208,400 / 207,056 |
| geography SP-GiST | 376,832 / 46 | 13.4 | 264,896 |

**Relative size:**
- **Flat tables:** the indexes add 43–80 % to the table total (BRIN +10 %).
- **JSONB tables:** 3–7 %.

**Planning overhead** (7D §11):
- **Direction:** indexed tables planned measurably slower in 97 of 109 series, never faster.
- **Magnitude:**

  | Query family | Planning with index | Without index |
  |---|---|---|
  | Geography distances | 0.43–1.30 ms | 0.03–0.04 ms |
  | Boxes | 0.06–0.25 ms | — |
  | Nearest neighbours | 0.04–0.08 ms | — |

- **Planning + execution per run** (*derived*): the index was faster in 88 of 109 series and the control in 8.
- **Not a factor:** the index method (IM, 0 of 37) and flat vs JSONB (F, 0 of 46) did not change planning time.

**Write-related observations actually measured:**
- **Builds only:** the only write-related quantities recorded in Step 7 are the index builds (build time, WAL bytes,
  final size, table-size growth).
- **Build WAL** was 0.53–0.83 of the index size for B-tree, GiST and SP-GiST, and 2,024 bytes for BRIN.
- **Size variation:** index sizes varied across the three builds for SP-GiST and geography GiST (up to 6.7 %). They were
  identical for B-tree, BRIN and geometry GiST.
- **Not measured:** INSERT, UPDATE or DELETE costs, index maintenance, generated-column maintenance, bloat, `VACUUM`
  behaviour and concurrency. **No conclusion about write workloads can be drawn from Step 7.**

## 12. Important limitations and caveats

*Data and environment*
1. **Tiny tables.** Flat heaps of 31–39 pages sit in shared buffers; sequential scans are very cheap. Every
   index-vs-control ratio and the BRIN result depend on this size.
2. **One environment.** One laptop on AC power, Windows, PostgreSQL 17.9, PostGIS 3.6.2, default planner settings. A
   warm cache, single client and read-only workload.

*Timing method*
3. **Sub-millisecond timings.** Many medians are below 1 ms. The 22 class I cases below 0.1 ms were confirmed in
   session 2; 3 comparisons in other classes were not confirmed and are "not measurable".
4. **Session agreement.** Session 2 alone agrees with 105 of 109 class I verdicts; the 4 marginal cases keep the
   session 1 verdict. Session-to-session median drift is 0.83–1.13.
5. **Which comparisons have verdicts.** Only interleaved within-block comparisons have verdicts. Sphere vs spheroid
   filters and cross-block rankings are descriptive only.
6. **Forced plans.** Used for correctness and diagnosis; their timings are not used for any conclusion.

*Build and planner inputs*
7. **Build figures.** Three sequential samples per index; the first build was the slowest for 9 of 10.
8. **Statistics.** One `ANALYZE`; row estimates were far off for several predicates, and plan choices depend on them.

*Scope of the comparisons*
9. **JSONB heap width.** The JSONB tables carry the documents; this wider heap is part of the flat vs JSONB comparison.
10. **Not tested:**
    - geography box queries
    - geometry distance at the antimeridian or pole
    - projections / other SRIDs
    - nearest neighbours with filters, `<#>`, other k
    - BRIN variants and larger tables
    - write workloads, concurrency, bloat
11. **Recorded deviations.**
    - **Installation (7A.2):** the installer set four machine environment variables (raster / projection; unused).
    - **Scripts:** checker and runner fixes before database access (7B, 7C).
    - **Harness:** the harness ran twice.
    - **Index sizes:** varied across builds.
    - **Settings display:** `EXPLAIN (SETTINGS)` does not list `TimeZone` / `track_io_timing`.
    - **Correctness:** none affected the result sets (2,424 / 0) or the integrity checks (7D §15).

## 13. Decision matrix (tested workloads only)

All entries are scoped to section 0. "Avoid" means that the approach gave no benefit, regressed, was not used or was not
supported **in these measurements**.

| Tested workload | Appropriate here | Measured basis | Avoid here |
|---|---|---|---|
| Selective degree box, about 8 % of rows (B1, B2) | geometry GiST, or numeric B-tree on (lat, lon) | GiST 3.35–3.40×, B-tree 2.29–3.14× vs control; B-tree faster than GiST on B1, equal on B2 | BRIN (not used) |
| Very selective box, polar cap (B6) | numeric B-tree or geometry GiST | 0.018 / 0.024 ms (24× / 31×); B-tree faster (1.33×) | BRIN |
| Antimeridian box as two envelopes / `OR` (B5) | geometry GiST (flat or JSONB stored) | 0.038 ms (32×); 24× faster than the B-tree | numeric B-tree (not used for `OR`), BRIN (regression) |
| Large box, 32 % of rows (B3) | numeric B-tree | 1.65× vs control | geometry GiST / SP-GiST (no benefit), BRIN (not used) |
| Large box, 78 % of rows (B4) | no index (sequential scan) | fastest medians (1.224 ms numeric, 1.612 ms geometry) | geometry GiST / SP-GiST (regression 1.46–1.57×) |
| Metric distance, small to medium radius, any centre including antimeridian and pole (D1–D3, D5–D7; spheroid or sphere) | geography GiST | flat geography GiST: 2.44–103× vs control, planning 0.43–0.93 ms; correct everywhere | geography SP-GiST (always slower than GiST where measurable) |
| Metric distance, large radius, 41 % of rows (D4 spheroid) | geography GiST | 3.06×; faster also on the planning + execution total | — |
| Metric distance, large radius on the sphere (D4-s) | no clear winner | GiST 1.41× on execution, but planning cost exceeds the saving (control faster on the total) | geography SP-GiST (no benefit) |
| Metric distance, mid-latitude only (D1, D2, D6) | geography GiST for 10–500 km; geometry `&&` + `ST_DistanceSphere` measured faster at 1 km | D1 / D2: geography 1.36× / 1.57× faster; D6: geometry 0.071 vs 0.116 ms | geometry method at the antimeridian or pole (untested) |
| Nearest neighbours in metres (K1, K2) | geography GiST | 0.105 / 0.273 ms (29× / 11.5×) | SP-GiST (not supported) |
| Nearest neighbours in degrees (K3, K1g) | geometry GiST | 0.054–0.074 ms (22–27×) | SP-GiST, BRIN (not supported) |
| Distance to every point, no filter (P1–P4) | stored geography column; sphere variant where its answers suffice | P1 10.226 ms vs P3 14.413 (numeric) and P4 36.468 (JSONB); sphere P2 5.188 ms | building points from JSONB per row |
| Same query, flat vs JSONB table with the same type and index (fair) | flat coordinates | faster in 14 of 23, never slower | — |
| Points must stay in JSONB documents (JSONB-specific) | stored generated column + GiST | faster than the expression index in 21 of 23; builds 3–4× faster; same index size | expression index (slower); no index with on-the-fly construction (24–47 ms per box) |
| Tables of about 39 pages | GiST | — | BRIN with default `pages_per_range` (single block range) |
| Any tested write or update workload | **no recommendation** | not measured in Step 7 | — |

## 14. Final scope statement and state

**Scope:** every conclusion and every matrix entry above applies only to:
- the 5,000-row, 4,161-point dataset of this project
- PostgreSQL 17.9 and PostGIS 3.6.2 on the tested Windows laptop
- the default planner configuration, warm cache and single read-only client
- the 192 tested query × configuration series

Nothing here is a general rule for PostGIS, PostgreSQL or other data.

**State:**
- **PostGIS:** extension `postgis` 3.6.2 in schema `postgis`; experiment schema `log_regex_gis` with 15 tables and
  the 10 Step 7C indexes, all still in place.
- **Cleanup:** `sql/52_drop_gis_indexes.sql` has not been run.
- **Unchanged project data:** existing project data, the Step 6 objects and the Step 7B source data are unchanged
  (verified in Step 7C).

**Stopped here.** The PostGIS phase (Step 7) is concluded. The overall project conclusion has not been started.
