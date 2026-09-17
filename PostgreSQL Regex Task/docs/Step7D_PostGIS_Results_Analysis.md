# Step 7D — PostGIS Results Analysis and Comparison

**Status:** consolidated analysis (13/09/2026). **No new experiment, query or database access was run for this step.**
Every figure comes from the completed Step 7B and Step 7C reports and their analysis files.
- **Measured values:** medians and verdicts are as recorded.
- **Derived values:** figures marked *derived* are arithmetic on recorded values (ratios of recorded medians, or
  per-run planning + execution sums from `step7c_executions.csv`). They carry no verdict unless stated.
- **Database state:** the 10 indexes remain built; `sql/52` was not run; PostGIS stays installed.
- **Out of scope:** the final overall project conclusion has not been started.

**Sources:**

| Step | Report | Content used |
|---|---|---|
| 7A / 7A.1 / 7A.2 | [Step7A_PostGIS_Experiment_Design.md](Step7A_PostGIS_Experiment_Design.md), [Step7A1_PostGIS_Installation_Preflight.md](Step7A1_PostGIS_Installation_Preflight.md), [Step7A2_PostGIS_Post_Installation_Verification.md](Step7A2_PostGIS_Post_Installation_Verification.md) | design, installation history, recorded deviation |
| 7B | [Step7B_PostGIS_Setup_Preflight.md](Step7B_PostGIS_Setup_Preflight.md) §9; `analysis/step7/step7b_setup_checks.txt` | 15 tables, oracles, sphere / spheroid consistency, `<->` semantics, edge facts (317 PASS / 0 FAIL) |
| 7C design | [Step7C_Spatial_Index_Experiment_Design.md](Step7C_Spatial_Index_Experiment_Design.md) | configurations, query matrix, comparison classes, verdict rules |
| 7C | [Step7C_Spatial_Index_Experiment.md](Step7C_Spatial_Index_Experiment.md); `analysis/step7/step7c_*` | builds, sizes, correctness, 7,680 executions, verdicts, comparisons, plans (943 PASS / 0 FAIL / 0 FLAG) |

**Numbering:**
- Step 7A §11 planned 7C = storage and indexes, 7D = query workload, 7E = report.
- The approved 7C design moved builds and query measurements together into 7C, so 7D is this results analysis.

---

## 0. Conditions every result depends on

| Item | Value |
|---|---|
| Data | 5,000 access-log rows copied from `access_log_flat` / `access_log_jsonb`; 4,161 rows with both coordinates VALID, 839 without a point; 856 points with \|longitude\| > 90; boundary rows (0, 0), (90, 180), (−90, −180) |
| Software | PostgreSQL 17.9 (EDB, x64, Windows); PostGIS 3.6.2, GEOS 3.14.1dev, PROJ 8.2.1; extension in schema `postgis` |
| Hardware and server | one Windows laptop on AC power; `shared_buffers` 128 MB, `work_mem` 4 MB, every planner setting at the server default |
| Session | `jit` off, no parallel workers, read-only, warm cache (0 shared blocks read in every measured run), single client, 0 other active sessions |
| Tables | flat heaps 31–39 pages (254–319 kB); JSONB heaps 879–981 pages (7.2–8.0 MB); statistics from one `ANALYZE` after the builds |
| Measurement | 3 warm-up + 15 measured rounds per block. All configurations of a query were interleaved in every round, with the order rotated each round and reversed on alternate rounds. Two sessions, identical plan shapes in both |
| Verdict rule (Step 6A) | IQRs do not overlap **and** the faster median is ≤ 90 % of the slower. If a median is < 0.1 ms, session 2 must show the same direction. Only comparisons interleaved within one query block receive a verdict. Forced-plan timings never do |
| Correctness | 202 checks × 3 plan modes = 606 per gate; harness + 3 gates = 2,424 PASS / 0 FAIL. All 7,680 executions returned the expected row count |

**Comparison classes (design §4):**
- **Fair comparisons:** I (index vs its own control), IM (index method) and F (flat vs JSONB, same type and index).
- **Method comparisons:** J (JSONB storage forms), GG (geometry vs geography) and NB (numeric B-tree vs spatial). These
  give no verdict on a type or storage format.

The sections below keep them apart.

**Configuration labels used below:**

| Label | Table and point representation |
|---|---|
| N-0 / N-1 | `flat_numeric` / `flat_numeric_btree` (B-tree on lat, lon) |
| G-0 / G-1 / G-2 / G-3 | flat geometry: no index / GiST / SP-GiST / BRIN |
| Y-0 / Y-1 / Y-2 | flat geography: no index / GiST / SP-GiST |
| J-0g / J-0y | `jsonb_doc`, point built from the document per row (geometry / geography) |
| J-1 / J-2 | `jsonb_doc_expr`, GiST expression index on the built geometry / geography |
| J-3c / J-3 | `jsonb_geom*`, stored generated geometry column, without / with GiST |
| J-4c / J-4 | `jsonb_geog*`, stored generated geography column, without / with GiST |

**Query labels used below:**

| Label | Query |
|---|---|
| B1–B6 | box queries (`ST_Intersects`; `BETWEEN` on N-0 / N-1) |
| D1–D7 | geography `ST_DWithin` on the spheroid |
| D1-s–D7-s | geography `ST_DWithin` on the sphere |
| MD1 / MD2 / MD6 | geometry `&&` box plus `ST_DistanceSphere` |
| K1 / K2 | geography, 10 / 100 nearest neighbours |
| K3 / K1g | geometry nearest neighbours |
| P1–P4 | distance to every point |

---

## 1. Index build time, WAL, size and pages (all 10 indexes)

Three builds per index, the third kept; `maintenance_work_mem` 64 MB, no parallel maintenance workers.
- **WAL:** the insert-LSN difference measured immediately after `CREATE INDEX`.
- **Size:** of the kept build.

| ID | Index | Build ms median [min–max] | WAL bytes (median) | Size bytes / pages | *Derived:* WAL ÷ size | Table total before → after |
|---|---|---|---:|---:|---:|---|
| N-1 | B-tree (lat, lon) on `flat_numeric_btree` | 3.793 [3.688–14.394] | 149,928 | 180,224 / 22 | 0.83 | 417,792 → 598,016 |
| G-1 | geometry GiST | 9.073 [8.717–12.122] | 137,576 | 212,992 / 26 | 0.65 | 491,520 → 704,512 |
| G-2 | geometry SP-GiST | 10.607 [10.341–11.928] | 192,840 | 278,528 / 34 | 0.69 | 491,520 → 770,048 |
| G-3 | geometry BRIN | 3.322 [2.967–4.374] | 2,024 | 24,576 / 3 | 0.08 | 491,520 → 540,672 |
| Y-1 | geography GiST | 13.137 [13.026–14.219] | 206,888 | 393,216 / 48 | 0.53 | 491,520 → 884,736 |
| Y-2 | geography SP-GiST | 13.387 [13.154–14.526] | 264,896 | 376,832 / 46 | 0.70 | 491,520 → 868,352 |
| J-1 | JSONB expression, geometry GiST | 38.385 [36.915–39.057] | 138,824 | 212,992 / 26 | 0.65 | 8,208,384 → 8,814,592 ² |
| J-2 | JSONB expression, geography GiST | 40.477 [39.831–40.830] | 208,400 | 393,216 / 48 | 0.53 | (same table as J-1) ² |
| J-3 | JSONB stored geometry column, GiST | 9.669 [9.643–12.819] | 137,600 | 212,992 / 26 | 0.65 | 7,372,800 → 7,585,792 |
| J-4 | JSONB stored geography column, GiST | 13.419 [13.411–17.756] | 207,056 | 393,216 / 48 | 0.53 | 7,372,800 → 7,766,016 |

² `jsonb_doc_expr` carries both J-1 and J-2 (+606,208 bytes, +7.4 %).

**What the measurements show (this data only):**
- **Size depends on type and method, not on the source table:**
  - Every geometry GiST (G-1, J-1, J-3) is 212,992 bytes and every geography GiST (Y-1, J-2, J-4) is 393,216 bytes,
    whether the table is 39 or 981 pages wide.
  - Geography GiST is 1.85× the geometry GiST; geography SP-GiST is 1.35× the geometry SP-GiST (*derived*).
- **Relative to the point column** (120,669 bytes, 4,161 × 29 bytes; 7C §3), *derived* ratios:

  | Index | Size ÷ point column |
  |---|---:|
  | G-1 geometry GiST | 1.77 |
  | G-2 geometry SP-GiST | 2.31 |
  | G-3 BRIN | 0.20 |
  | Y-1 geography GiST | 3.26 |
  | Y-2 geography SP-GiST | 3.12 |

  N-1 is 2.78× the 64,747 bytes of the two numeric columns.
- **Build time** (only "consistent" differences, meaning min–max ranges do not overlap):
  - Expression indexes are consistently slower than stored-column indexes: J-1 vs J-3 about 4×, J-2 vs J-4 about 3×.
  - BRIN is consistently the fastest spatial build.
  - Geometry GiST is consistently faster than geography GiST (G-1 vs Y-1).
  - Not consistent: G-1 vs G-2, Y-1 vs Y-2, G-1 vs J-3, Y-1 vs J-4, and N-1 vs G-1 / G-3.
- **WAL:**
  - Close to the index size for every method except BRIN (0.53–0.83 of the kept size, *derived*); BRIN wrote 2,024 bytes.
  - SP-GiST wrote more WAL than GiST on the same column: +40 % geometry, +28 % geography.
  - Same-type indexes wrote almost identical WAL whatever the source (137,576–138,824 bytes geometry; 206,888–208,400
    geography).
- **Caveats:** the build figures have these limits.
  - **Samples:** there are only 3 per index.
  - **First builds:** first builds were the slowest in 9 of 10 indexes (N-1: 14.4 ms, then 3.7 / 3.8 ms).
  - **Order:** builds ran sequentially in `sql/48` order and were not interleaved.
  - **Size stability:** sizes were identical across the three builds for B-tree, BRIN and geometry GiST, but varied for
    G-2, Y-1, Y-2, J-2 and J-4 (up to 6.7 %; §15).

## 2. Index vs its own no-index control (class I, fair)

Same data, same query, same session; the only difference is the index.

**Verdicts:** 109 series; see §12 for the full catalogue.

| Verdict | Series |
|---|---:|
| measurable benefit | 90 |
| index used, no measurable benefit | 5 |
| measurable regression | 3 |
| index not used by the planner | 7 |
| *kept separate:* not supported (no ordering operator) | 4 |

**Size of the benefit by result size** (descriptive grouping of the recorded ratios, control median ÷ indexed median):

| Result rows (share of 5,000) | Series | Benefit range | Series without benefit |
|---|---|---|---|
| 0–15 rows (B5, B6, D6, D7, D6-s, D7-s, K1, K3, K1g, MD6) | 39 | 6.1–930× | B5 N-1 not used, B5 G-3 regression, B6 G-3 not used, 3 not supported |
| 100 rows (K2) | 4 | 11.5–20.3× | K2 Y-2 not supported |
| 262–1,101 rows, 5–22 % (B1, B2, D1–D3, D5, D1-s–D3-s, D5-s, MD1, MD2) | 46 | 1.6–17.7× | B1 / B2 G-3 not used, MD2 G-1 no benefit |
| 1,580–3,897 rows, 32–78 % (B3, B4, D4, D4-s) | 20 | 1.14–3.06× | B3 G-1 / G-2 no benefit, B3 G-3 / B4 G-3 / B4 N-1 not used, B4 G-1 / G-2 regression, B4 J-3 and D4-s Y-2 no benefit |

**Observations:**
- **Biggest ratios:** these come from controls that build the point from the JSONB document for every row. J-0g / J-0y
  take 24–46 ms, so the expression index turns B5 into 0.050 ms (930×) and D7 into 0.057 ms (531×). The same queries
  against a stored column (J-3c / J-4c, 1.4–9.1 ms) give 54× and 147×.
- **Noise-floor check:** in the 7 not-used series the indexed table ran the same sequential-scan plan as its control.
  None of the 7 timing differences (0.92–0.99×, *derived*) was measurable, so identical tables with identical plans gave
  no false verdict.
- **Session 2 alone:** agrees on direction and index usage for 105 of 109 series. The 4 marginal exceptions are
  B4 on J-1, B4 on J-3, MD2 on G-1 and D4-s on Y-2; the session 1 verdict stands per the design.

## 3. GiST vs SP-GiST vs BRIN (class IM, fair — same column, same query)

**Execution time, session 1:**

| Comparison | Result |
|---|---|
| Geometry boxes, G-1 GiST vs G-2 SP-GiST | not measurable for B1–B4; GiST faster for B5 (0.038 vs 0.067 ms) and B6 (0.024 vs 0.042 ms), both confirmed in session 2 |
| Geometry boxes, G-1 / G-2 vs G-3 BRIN | GiST and SP-GiST faster for B1, B2, B5, B6 (3.3–39.6×). B3: SP-GiST faster than BRIN (1.21×); GiST vs BRIN not measurable. **B4: BRIN faster than both (1.45× / 1.35×)**, because BRIN was not used, and a sequential scan beat their index scans (§10) |
| Geometry nearest neighbour K3 | GiST 0.074 ms vs SP-GiST 1.720 / BRIN 1.800 ms (23–24×); SP-GiST vs BRIN not measurable (both sort) |
| Geography distances, Y-1 GiST vs Y-2 SP-GiST | GiST faster in 13 of 14 series (1.18–10.5×); D5 not measurable |
| Geography nearest neighbours K1 / K2 | GiST faster (31.3× / 12.1×); SP-GiST not supported |

**Summary:** 30 of 37 execution comparisons were measurable. **SP-GiST was never measurably faster than GiST** on the
same column.

**Supporting measurements:**
- **Planning time:** no IM comparison was measurable (0 of 37). The method did not change planning time.
- **Buffer hits (distances):** SP-GiST used more shared-buffer hits than GiST: D1 425 vs 149, D2 951 vs 418,
  D4 1,552 vs 685, D7 150 vs 3.
- **Buffer hits (large boxes):** on the plain index scans of B3 / B4, SP-GiST used fewer hits (870 vs 1,556;
  2,134 vs 3,828), without a measurable time difference.
- **Cost:**
  - SP-GiST geometry is 31 % larger than GiST, with 40 % more WAL.
  - SP-GiST geography is 4 % smaller than GiST, with 28 % more WAL.
  - Build times overlap.
- **BRIN:** see §13.

## 4. Geometry vs geography (class GG — method comparison, different semantics)

These comparisons answer the same question with different types and methods. They are **not** a verdict on the types.

| Comparison | Execution (session 1) | Planning |
|---|---|---|
| **Indexed distance:** geography `ST_DWithin` on Y-1 vs geometry `&&` box + `ST_DistanceSphere` on G-1 (MD) | D1: Y-1 faster (0.438 vs 0.597 ms). D2: Y-1 faster (1.146 vs 1.798). D6: MD faster (0.071 vs 0.116, confirmed) | MD faster in all three (0.089–0.098 vs 0.463–0.503 ms) |
| **Distance without index:** Y-0 vs MD on G-0 | MD faster in all three: D1 6.8×, D2 3.5×, D6 12.6× | geography faster (0.034–0.037 vs 0.084–0.094 ms) |
| **Nearest neighbours, indexed:** K1 geography on Y-1 vs K1g geometry on G-1 | K1g faster (0.054 vs 0.105 ms, confirmed) | not measurable |
| **Nearest neighbours, no index:** K1 on Y-0 vs K1g on G-0 | K1g faster (1.481 vs 3.056 ms) | not measurable |
| **Distance to all points:** P1 spheroid vs P2 sphere (geography) | sphere faster (5.188 vs 10.226 ms) | not measurable |

**Semantics recorded with the timings (Step 7B §9.4, Step 7C §4):**
- **MD rewrite:** the planner shows the geometry `ST_DistanceSphere` filter as
  `st_distance(geography(geom), <centre>, false) <= r`, i.e. a sphere distance on the geography type. The index
  condition is `geom && <box>` with the precomputed margins.
- **Geography `ST_DWithin`:** the index condition is `geog && _st_expand(<centre>, r)`; the filter is
  `st_dwithin(geog, <centre>, r, true)`.
- **MD coverage:** MD was limited to mid-latitude centres without antimeridian or pole wrap (D1, D2, D6; decision 3).
  **No geometry method was measured** for D3, D4, D5 (antimeridian) or D7 (pole).
- **Different answers:**
  - K1 (geography, metres) and K1g (geometry, degrees) share **8 of 10** result rows at Reykjavik (64° N).
  - Geometry nearest-neighbour order is in planar degrees; geography order is in metres.
- **Edge facts:**
  - E1: (0, 180) to (0, −180) is 0.000 m as geography but 360° as geometry.
  - E2: two pole points are 0.000 m apart.
  - E3: the B6 edge point `ST_Within` false, `ST_Intersects` true.
  - B5 needed two envelopes in geometry; the geography distance D5 across the antimeridian needed none.
- **Not measured:** geography box queries (boxes were measured on geometry and numeric only), so there is no
  geometry-vs-geography box comparison.

**Cost** (§1): geography GiST is 1.85× the size of geometry GiST, and builds consistently slower (13.1 vs 9.1 ms median).

## 5. Flat vs JSONB coordinates — same representation, same index (class F, fair)

**Pairs compared:**
- geometry GiST G-1 vs J-3 (boxes, K3)
- geography GiST Y-1 vs J-4 (distances, K1, K2)
- their no-index controls G-0 vs J-3c and Y-0 vs J-4c

**Execution time** (23 series in each pairing):

| Pairing | Flat faster | Not measurable | JSONB faster |
|---|---:|---:|---:|
| Indexed (G-1 vs J-3, Y-1 vs J-4) | 14 (1.17–1.72×) | 9 | **0** |
| No index (G-0 vs J-3c, Y-0 vs J-4c) | 21 (1.11–1.85×) | 2 (D1, D2) | **0** |

**Indexed pairs in detail:**
- **Flat faster:**
  - boxes B1, B2, B3
  - spheroid distances D1–D5 and sphere distances D1-s–D5-s
  - nearest neighbour K2
- **Not measurable:**
  - B4, B5, B6 (B5 / B6 medians are identical: 0.038 / 0.024 ms)
  - D7, D7-s
  - D6, D6-s (session 2 does not confirm)
  - K1, K3

**What else was the same or different:**
- **Same:**
  - index size (212,992 / 393,216 bytes)
  - WAL (137,576 vs 137,600; 206,888 vs 207,056)
  - build time (ranges overlap)
  - planning time (none of 46 F planning comparisons measurable)
  - query results (C-03)
- **Different: the heap.**
  - The JSONB tables store the documents next to the point: 879 pages against 39.
  - Sequential scans touched 879 vs 39 buffers.
  - Indexed bitmap scans touched more heap buffers on JSONB (B1: 331 vs 42; D2: 682 vs 418).
  - Nearest-neighbour index scans touched the same 13–14 buffers on both, with no measurable difference for K1 and K3.
  - The design reports this wider heap as a property of storing points next to documents, not corrected.
- **Different: the plan.** For B3, B4, D2, D4, D2-s and D4-s the planner chose a plain index scan on the flat table
  but a bitmap heap scan on the JSONB table. The plan choice is part of what this class compares.

## 6. JSONB expression index vs stored generated-column index (class J — JSONB-specific)

**This class compares storage forms within JSONB. It is not a flat-vs-JSONB verdict.**

| Aspect | Expression index (J-1 geometry, J-2 geography) | Stored generated column + index (J-3, J-4) |
|---|---|---|
| Index size | 212,992 / 393,216 bytes | identical |
| Build time median | 38.4 / 40.5 ms | 9.7 / 13.4 ms (consistently 3–4× faster) |
| WAL | 138,824 / 208,400 bytes | 137,600 / 207,056 bytes |
| Heap | `jsonb_doc_expr`: 981 pages, no point column | `jsonb_geom_gist` / `jsonb_geog_gist`: 879 pages including the generated column. Why this heap is smaller despite the extra column was not analysed in 7B / 7C |
| Execution: boxes and K3 (J-1 vs J-3) | — | stored column faster in **all 7** (1.32–8.8×; B5 / B6 confirmed) |
| Execution: distances and K1 / K2 (J-2 vs J-4) | — | stored column faster in **14 of 16** (1.7–5.8×); D7 not confirmed in session 2, D7-s not measurable |
| Planning | J-1 0.075–0.250 ms, J-2 0.066–1.304 ms | stored faster in 14 of 23, not measurable in 9, expression never faster |

**Plan evidence** (session 1 detail plans):
- **Index condition:** J-1 / J-2 carry the full `st_setsrid(st_makepoint((doc->'fields'->'longitude'->>'degrees')…))`
  expression.
- **Filter:** the same expression, so the point is rebuilt from the document for each candidate row. J-3 / J-4 filter on
  the stored `geom` / `geog`.
- **Buffers:** hits were similar (B1: 342 vs 331; D2: 710 vs 682), so the time difference is not explained by the
  number of buffers touched. A per-node CPU breakdown was not part of the analysis.

**Building points on the fly** (no index; J-0g / J-0y vs a stored column without index, J-3c / J-4c):
- **All queries:** the stored column was faster in **all 23** series.

  | Query family | Stored column faster by |
  |---|---|
  | boxes | 11.1–22.8× |
  | spheroid distances | 3.7–5.9× |
  | sphere distances | 7.6–8.8× |
  | nearest neighbours | 7.6–12.1× |

- **Planning:** building on the fly planned faster for 5 box series and slower for K2 and K3; the other 16 were not
  measurable.

**Distance to every point** (block P, interleaved, all measurable):

| Query | Point source | Median |
|---|---|---:|
| P1 | stored geography | 10.226 ms |
| P3 | built from numeric columns | 14.413 ms |
| P4 | built from the JSONB document | 36.468 ms |

*Derived:* building 5,000 geography points from the JSONB document cost about 26.2 ms more than reading them from a
stored column, and building them from numeric columns about 4.2 ms more.

## 7. Bounding-box query performance

**Session 1 execution medians, ms** (session 2 in `step7c_summary.csv`):

| Query (rows) | N-0 | N-1 | G-0 | G-1 | G-2 | G-3 | J-0g | J-1 | J-3c | J-3 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| B1 New York (410) | 0.569 | 0.181 | 0.834 | 0.245 | 0.253 | 0.884 | 24.598 | 2.500 | 1.501 | 0.422 |
| B2 Europe (416) | 0.614 | 0.268 | 0.851 | 0.254 | 0.279 | 0.921 | 25.293 | 2.490 | 1.502 | 0.419 |
| B3 India (1,580) | 0.869 | 0.526 | 1.132 | 1.056 | 0.954 | 1.150 | 25.076 | 8.877 | 1.799 | 1.325 |
| B4 wide (3,897) | 1.224 | 1.275 | 1.612 | 2.528 | 2.354 | 1.740 | 26.417 | 23.150 | 2.374 | 2.633 |
| B5 antimeridian (0) | 0.902 | 0.912 | 1.235 | 0.038 | 0.067 | 1.504 | 46.525 | 0.050 | 2.041 | 0.038 |
| B6 polar cap (1) | 0.434 | 0.018 | 0.754 | 0.024 | 0.042 | 0.797 | 24.026 | 0.032 | 1.391 | 0.024 |

**Numeric B-tree vs spatial (class NB — method comparison, no verdict on types):**
- **N-1 vs G-1:**
  - N-1 faster for B1 (1.35×), B3 (2.01×), B4 (1.98×; N-1 sequential scan vs G-1 index scan) and B6 (1.33×, confirmed).
  - Not measurable for B2.
  - **G-1 faster for B5 (24×, confirmed):** the antimeridian box is `longitude >= 170 OR longitude <= -170` in numeric
    form, and the planner used a sequential scan for it on N-1.
- **N-0 vs G-0 (both sequential scans):** numeric `BETWEEN` faster than `ST_Intersects` in all 6 boxes (1.30–1.74×).
- **Planning:** no-index geometry planned faster than numeric in 5 of 6 boxes; B4 the other way.

**Box findings for this data:**
- **Selective boxes (B1, B2, B5, B6):** every usable index gave a measurable benefit. On the fair pairs, the lowest
  medians came from B-tree (B1, B6) or GiST (B2 with B-tree not measurable, B5).
- **Large boxes (B3 32 %, B4 78 % of rows):**
  - The spatial indexes gave no benefit, or regressed (B4 G-1 / G-2).
  - The B-tree helped on B3 only (1.65×) and was not used on B4.
  - Only the expression index J-1 helped on B4 (1.14×), because its control builds every point from JSONB.
- **Antimeridian box B5:** GiST, SP-GiST and the JSONB GiST indexes answered 0 rows with 4–20 buffer hits in a
  BitmapOr. The B-tree was not used for the `OR` predicate.
- **Building points on the fly:** 24–47 ms for every box, whatever its selectivity.
- **Box semantics:** `ST_Intersects` with an envelope and `BETWEEN` on the numeric columns returned identical sets for
  B1–B6 (Step 7B oracle). At the B6 edge, `ST_Within` and `ST_Intersects` differ (E3).

## 8. Distance-query performance

**Session 1 execution medians, ms.** "-s" = sphere (`use_spheroid = false`):

| Query (rows) | Y-0 | Y-1 | Y-2 | J-0y | J-2 | J-4c | J-4 |
|---|---:|---:|---:|---:|---:|---:|---:|
| D1 New York 10 km (410) | 7.745 | 0.438 | 0.789 | 33.305 | 2.803 | 8.519 | 0.560 |
| D2 Mumbai 500 km (1,101) | 7.290 | 1.146 | 1.519 | 32.492 | 6.950 | 7.867 | 1.487 |
| D3 Reykjavik 2,000 km (599) | 7.437 | 0.599 | 0.930 | 31.665 | 4.020 | 8.663 | 0.911 |
| D4 Mumbai 5,000 km (2,059) | 5.657 | 1.847 | 2.259 | 30.961 | 13.222 | 6.876 | 2.556 |
| D5 (0, 180) 5,000 km (262) | 8.189 | 1.360 | 1.632 | 33.550 | 4.736 | 9.136 | 1.625 |
| D6 London 1 km (15) | 8.168 | 0.116 | 0.448 | 33.963 | 0.329 | 9.100 | 0.098 |
| D7 North Pole 100 km (1) | 4.331 | 0.042 | 0.419 | 30.254 | 0.057 | 5.157 | 0.035 |
| D1-s | 2.596 | 0.431 | 0.787 | 27.860 | 2.735 | 3.241 | 0.535 |
| D2-s | 2.532 | 1.037 | 1.553 | 27.026 | 6.800 | 3.263 | 1.379 |
| D3-s | 2.741 | 0.618 | 0.950 | 28.743 | 4.099 | 3.344 | 0.856 |
| D4-s | 2.736 | 1.937 | 2.282 | 27.135 | 13.641 | 3.583 | 2.361 |
| D5-s | 2.422 | 0.484 | 0.789 | 27.399 | 3.935 | 3.115 | 0.701 |
| D6-s | 2.738 | 0.093 | 0.449 | 29.023 | 0.312 | 3.520 | 0.086 |
| D7-s | 2.539 | 0.034 | 0.357 | 27.586 | 0.042 | 3.318 | 0.030 |

**Index benefit:**
- **Frequency:** every geography index gave a measurable benefit in every distance series (4 indexes × 14), except
  SP-GiST on D4-s (no measurable benefit).
- **Magnitude:** falls with the result size:
  - D6 / D7 and their sphere variants: 6.1–657× (GiST indexes Y-1 / J-2 / J-4: 29–657×; SP-GiST Y-2: 6.1–18.2×)
  - D4 (41 % of rows): 2.3–3.1×
  - D4-s: 1.4–2.0×
- **Antimeridian and pole:** D5 and D7 were handled by the same geography index plans as the other centres. Results
  equal the haversine oracle (262 and 1 rows).

**Candidate rows** (rows removed by filter, session 1 detail):
- **Index and filter conditions:** the index condition `geog && _st_expand(centre, r)` passes candidates, and the
  `ST_DWithin` filter keeps the exact matches.
- **Exact matches:** for D1–D4 and D7 the filter removed 0 rows on all indexed configurations.
- **Filtered:** D5 removed 309 rows (571 candidates for 262 matches) and D6 removed 13.
- **Without index:** Y-0 evaluated the filter on the whole table (2,941–4,999 rows removed).

**Spheroid vs sphere cost** (*derived* ratios of medians only):
- **Not a verdict:** D and D-s run in different query blocks, so they are not interleaved and get no verdict.

  | Configuration | Spheroid ÷ sphere median |
  |---|---|
  | Y-0 (no index) | 1.71–3.38× |
  | J-4c (no index) | 1.55–2.93× |
  | Y-1 (indexed) | 0.95–1.25×, except D5 2.81× |
  | Y-2 (indexed) | 0.98–1.17×, except D5 2.07× |
  | J-4 (indexed) | 1.05–1.17×, except D5 2.32× |

- **Where the gap appears:** where many rows reach the distance function (no index; D5 with 571 candidates).
- **Interleaved comparison:** the only interleaved spheroid-vs-sphere comparison is P1 vs P2 (all points), where the
  sphere was measurably faster (5.188 vs 10.226 ms).

**Planning:** geography distance queries on indexed tables planned in 0.43–1.30 ms, the most for D4 / D4-s
(1.13–1.30 ms) and D5 / D5-s (0.89–1.08 ms); see §11.

**Row estimates:** 1 row for every `ST_DWithin` on every configuration (actual 15–2,059); see §10.

## 9. Nearest-neighbour support and limitations

**Support comes from the operator class** (catalog, 7C design §1):

| Operator class | Ordering operator | Nearest-neighbour index scan |
|---|---|---|
| `gist_geometry_ops_2d` | `<->`, `<#>` | yes |
| `gist_geography_ops` | `<->` | yes |
| `spgist_geometry_ops_2d`, `spgist_geography_ops_nd` | none | no |
| `brin_geometry_inclusion_ops_2d` | none | no |

**Measured (session 1 medians, ms; speed-up vs own control):**

| Query | Flat GiST | JSONB expression GiST | JSONB stored GiST | SP-GiST / BRIN |
|---|---|---|---|---|
| K1 geography, Reykjavik, 10 | Y-1 0.105 (29.1×) | J-2 0.190 (155×) | J-4 0.110 (35.4×) | Y-2 3.289, not supported |
| K2 geography, Reykjavik, 100 | Y-1 0.273 (11.5×) | J-2 1.456 (20.3×) | J-4 0.319 (12.1×) | Y-2 3.313, not supported |
| K3 geometry, New York, 10 | G-1 0.074 (22.3×) | J-1 0.167 (173×) | J-3 0.072 (33.2×) | G-2 1.720 / G-3 1.800, not supported |
| K1g geometry, Reykjavik, 10 | G-1 0.054 (27.4×) | — | — | — |

**Plans and buffers:**
- **GiST:** `Limit → Index Scan` with `Order By: <P> <-> <centre>`. Buffer hits were 13–14 for 10 neighbours and
  100–104 for 100, against 39 (flat) or 879–981 (JSONB) for the sequential scan plus sort.
- **SP-GiST and BRIN:** `Limit → Sort → Seq Scan` in the default **and** the forced plan (`enable_seqscan = off`). No
  index path exists, so these are recorded as "not supported", not as "not used".
- **Row estimates:** the planner estimated 5,000 rows for the GiST index scan under `Limit` (the whole table).

**Semantics and limits:**
- **Geography `<->` measures sphere distance.** 7B INFO: the maximum difference from the sphere distance is
  5.0 × 10⁻⁹ m; from the spheroid distance, up to 9.87 m. K1 / K2 therefore order by sphere distance. Their sets
  equalled the haversine oracle, with no tie at rank 10 (772.7 m) or 100 (3,273.8 m).
- **Geometry `<->` measures planar degrees.** K3 has 6 points exactly at the centre, but no tie at rank 10: its set and
  its distance multiset both equal the planar oracle.
- **No tie-breaker (decision 4):** the statements have none, so a tie at rank k would make the returned set
  non-deterministic. That did not occur in this data.
- **Not tested:** nearest-neighbour queries with an extra filter, the `<#>` operator, k values other than 10 / 100, and
  centres other than Reykjavik and New York.

## 10. Planner index usage, and cases where indexes were not used

**Usage was all-or-nothing and stable:**
- **Per series:** the default plan used the designed index in 15 of 15 or 0 of 15 measured runs.
- **Across sessions:** plan shapes were identical in both sessions for all 192 series.
- **Class I:** the index was used in 98 of 109 series (90 benefit, 5 no benefit, 3 regression). It was not used in 7,
  and not supported in 4.

**Index conditions produced from the query functions** (session 1 detail plans):

| Query form | Index condition | Remaining filter |
|---|---|---|
| `ST_Intersects(geom, envelope)` | `geom && envelope` | `st_intersects(…)` |
| `ST_DWithin(geography, centre, r[, false])` | `geog && _st_expand(centre, r)` | `st_dwithin(…, true / false)` |
| MD: `geom && ST_Expand(…) AND ST_DistanceSphere(…) <= r` | `geom && box` | `st_distance(geography(geom), centre, false) <= r` |
| `ORDER BY <P> <-> centre LIMIT k` | `Order By: <P> <-> centre` (GiST only) | — |
| JSONB expression queries | the full `st_setsrid(st_makepoint(doc…))` expression, matched to J-1 / J-2 | the same expression |
| Numeric `BETWEEN` box | `latitude` and `longitude` range on the B-tree | (recheck) |

**Plan type followed selectivity:**

| Case | Plan |
|---|---|
| 1–15 rows | index scans |
| B1 / B2, D3 / D5 and the JSONB distance queries | bitmap heap scans |
| B3 / B4 on G-1 / G-2 | plain index scans |
| B5 | BitmapOr of two index scans |

**Cases where the planner did not use the index** (forced-plan timings shown without a verdict):

| Series | Default plan | Forced plan (`enable_seqscan = off`) | Recorded detail |
|---|---|---|---|
| B1, B2, B3, B4, B6 on G-3 (BRIN) | Seq Scan | Bitmap Index Scan on BRIN, 39 of 39 heap blocks lossy | B1: 0.916 ms default vs 1.135 ms forced; B4: 1.651 vs 1.955 |
| B4 on N-1 (B-tree) | Seq Scan (1,103 rows removed by filter) | Bitmap Index Scan, 31 exact heap blocks | 1.353 vs 1.405 ms |
| B5 on N-1 (B-tree, `OR` on longitude) | Seq Scan (5,000 rows removed) | Bitmap Index Scan, 4,247 rows removed | 0.927 vs 0.801 ms |

**Cases where the planner used the index and lost time or gained nothing:**
- **B4 on G-1 / G-2 (regression).** Plain index scans over 3,897 rows. The planner estimated **4,740 of 5,000** rows and
  still chose the index scan: 3,828 / 2,134 buffer hits against 39 for the sequential scan.
- **B3 on G-1 / G-2 (no benefit).** Same pattern at 1,580 rows (estimate 1,899).
- **B5 on G-3 (regression).** BRIN BitmapOr, every block lossy, 5,000 rows removed by recheck (§13).
- **B4 on J-3, MD2 on G-1, D4-s on Y-2 (no benefit).** The index was used; IQRs overlapped with the control.

**Row estimates vs actual** (detail runs; recorded, cause not analysed):

| Predicate | Estimated | Actual |
|---|---|---|
| geography `ST_DWithin` (all configurations) | 1 | 15–2,059 |
| geometry boxes B1 / B2 / B3 / B4 | 64 / 500 / 1,899 / 4,740 | 410 / 416 / 1,580 / 3,897 |
| numeric boxes B1 / B2 / B3 / B4 | 29 / 101 / 511 / 3,347 | 410 / 416 / 1,580 / 3,897 |
| MD1 / MD2 / MD6 | 2 / 441 / 1 | 410 / 1,101 / 15 |
| points built from JSONB on the fly (J-0g / J-0y) | 1 | query result |
| GiST nearest-neighbour index scan (under `Limit`) | 5,000 | 10 / 100 |

Despite these estimates, the default plans produced a measurable benefit in 90 series. The costly choices were
confined to the large boxes B3 / B4 and to BRIN.

## 11. Planning-time overhead

**Class I** (same rule; session-2 confirmation below 0.1 ms):
- **Direction:** the indexed configuration planned **measurably slower in 97 of 109** series, not measurably different
  in 12, and **never faster**.
- **The 12 not measurable:** MD1 / MD2 / MD6 on G-1; K1 / K2 on Y-1, Y-2 and J-4; K3 on G-2, J-1 and J-3.

**Planning medians by query family** (session 1):

| Family | Indexed configurations | No-index controls |
|---|---|---|
| Boxes B1–B3, B5, B6 | 0.061–0.131 ms | 0.034–0.070 ms |
| Box B4 | 0.099–0.250 ms | 0.043–0.130 ms |
| Geography distances D / D-s | **0.425–1.304 ms**; D4 / D4-s 1.13–1.30, D5 / D5-s 0.89–1.08, others 0.43–0.64 | 0.031–0.043 ms |
| Geometry distance MD | 0.089–0.098 ms | 0.084–0.094 ms |
| Nearest neighbours | 0.041–0.075 ms | 0.033–0.050 ms |

**Planning vs execution:**
- **Largest cost:** the geography distance queries, where planning with an index present was 12–37× the control's
  (*derived*).
- **Against the saving:** in one benefit series (D4-s on Y-1), the planning increase (1.096 ms) exceeded the execution
  saving (0.799 ms).

**Planning + execution per run** (*derived* from the recorded runs; the same rule applied; **not** a design verdict):

| Result | Series |
|---:|---|
| index faster | 88 |
| not measurable | 13 |
| control faster | 8: B2 and B4 on G-3; B4 on G-1, G-2 and J-3; B5 on G-3; D4-s on Y-1 and Y-2 |

**Execution benefits that do not hold on the total:**
- D4-s on Y-1: control faster on the total.
- D4-s on J-4: not measurable on the total.

**Other classes (planning):**

| Class | Measurable comparisons | Result |
|---|---|---|
| IM | 0 of 37 | method does not change planning |
| F | 0 of 46 | source table does not change planning |
| J | 21 of 49 | expression index slower than stored column in 14; on-the-fly vs stored: 5 / 2 |
| GG | 6 of 9 | MD faster with an index; geography faster without |
| NB | 8 of 12 | mixed |

**Not analysed:** planning memory was recorded per execution (`step7c_executions.csv`); why geography planning grows
with the radius was not analysed.

## 12. Verdict catalogue: 90 benefit, 5 no benefit, 3 regression, 7 not used — and 4 unsupported (separate)

**Measurable benefit (90):**

| Index | Count | Series |
|---|---:|---|
| N-1 | 4 | B1, B2, B3, B6 |
| G-1 | 8 | B1, B2, B5, B6, MD1, MD6, K1g, K3 |
| G-2 | 4 | B1, B2, B5, B6 |
| G-3 | 0 | — |
| Y-1 | 16 | D1–D7, D1-s–D7-s, K1, K2 |
| Y-2 | 13 | D1–D7, D1-s–D3-s, D5-s–D7-s |
| J-1 | 7 | B1–B6, K3 |
| J-2 | 16 | D1–D7, D1-s–D7-s, K1, K2 |
| J-3 | 6 | B1, B2, B3, B5, B6, K3 |
| J-4 | 16 | D1–D7, D1-s–D7-s, K1, K2 |

**Index used, no measurable benefit (5)** (medians in ms, indexed vs control):

| Series | Indexed | Control | Plan evidence |
|---|---:|---:|---|
| B3 on G-1 | 1.056 | 1.132 | Index Scan, 1,556 hits vs 39 |
| B3 on G-2 | 0.954 | 1.132 | Index Scan, 870 hits |
| B4 on J-3 | 2.633 | 2.374 | Bitmap Heap Scan over 878 of 879 heap blocks |
| MD2 on G-1 | 1.798 | 2.111 | Index Scan, 1,080 hits; IQRs overlap |
| D4-s on Y-2 | 2.282 | 2.736 | Index Scan, 1,552 hits; IQRs overlap |

**Measurable regression (3):**

| Series | Indexed | Control | Plan evidence |
|---|---:|---:|---|
| B4 on G-1 | 2.528 | 1.612 | Index Scan over 78 % of rows, 3,828 hits |
| B4 on G-2 | 2.354 | 1.612 | Index Scan, 2,134 hits |
| B5 on G-3 | 1.504 | 1.235 | BRIN BitmapOr, 39 of 39 blocks lossy, 5,000 rows rechecked |

**Index not used by the planner (7)** (same sequential-scan plan as the control; no timing difference measurable):

| Series | Indexed table | Control |
|---|---:|---:|
| B1 on G-3 | 0.884 | 0.834 |
| B2 on G-3 | 0.921 | 0.851 |
| B3 on G-3 | 1.150 | 1.132 |
| B4 on G-3 | 1.740 | 1.612 |
| B6 on G-3 | 0.797 | 0.754 |
| B4 on N-1 | 1.275 | 1.224 |
| B5 on N-1 | 0.912 | 0.902 |

**Not supported — kept separate (4).** The operator class has no ordering operator; the plan is `Limit → Sort → Seq Scan`
in both default and forced runs. None is measurably different from its control.

| Series | Indexed table | Control |
|---|---:|---:|
| K1 on Y-2 | 3.289 | 3.056 |
| K2 on Y-2 | 3.313 | 3.128 |
| K3 on G-2 | 1.720 | 1.648 |
| K3 on G-3 | 1.800 | 1.648 |

## 13. The BRIN limitation caused by the 39-page table

**Mechanism:**
- **One block range:** `flat_geom_brin` has 39 heap pages, and the index uses the default `pages_per_range` of 128. The
  whole heap is therefore **one block range** with one summary box (index: 3 pages, 24,576 bytes).
- **Whole-globe summary:** the table contains the boundary points (90, 180) and (−90, −180), so that summary box spans
  the whole coordinate range.
- **Every box matches:** every query box intersects the summary. A BRIN scan can only return all 39 pages as lossy
  blocks and recheck every row.

**Measured consequences:**
- **Default plans (B1–B4, B6):** sequential scan; BRIN not used, no measurable difference from G-0.
- **Forced plans:** every BRIN bitmap was lossy on 39 of 39 blocks.
- **B5 (default plan used BRIN):** BitmapOr of two BRIN scans, 5,000 rows removed by recheck. 1.504 ms vs 1.235 ms for
  the control: **measurable regression**.
- **Nearest neighbours (K3):** not supported.
- **Against the other methods (IM):** GiST and SP-GiST were measurably faster for B1, B2, B5 and B6. BRIN (as a
  sequential scan) was faster only for B4, where the index scans regressed.

**Cost:** BRIN had the lowest cost (24,576 bytes, 2,024 bytes of WAL, 3.3 ms build), but gave no benefit here.

**Scope of this finding:** it holds for a 39-page heap with the default `pages_per_range`. Larger tables, other
`pages_per_range` values and spatially ordered heaps were not measured, so this result says nothing about BRIN on them.

## 14. Sphere vs spheroid distance (Step 7B finding, applied in 7C)

**Step 7B findings (oracle readiness, no timing):**

| Check | Result |
|---|---|
| O-3a sphere = haversine | max \|`ST_Distance(geog, centre, false)` − haversine (R = 6,371,008.7714 m)\| = **0.0000473 m** over 4,161 points × 6 centres |
| O-4a spheroid vs sphere | max relative difference **0.452 %** (limit 0.6 %) |
| O-4b ambiguity band | **0** points within ±0.6 % of any tested radius D1–D7 |
| Consequence | spheroid `ST_DWithin` and sphere `ST_DWithin` return the **same sets** for D1–D7, both equal to the haversine oracle (410, 1,101, 599, 2,059, 262, 15, 1 rows) |
| Geography `<->` | measures the sphere distance (max 5.0 × 10⁻⁹ m from sphere, up to 9.87 m from spheroid) |
| Edge facts | E1 antimeridian points 0.000 m; E2 pole points 0.000 m; E4 mixing SRID 4326 and 3857 raises an error |

**How 7C used it:**
- **Distances:** all D and D-s series on all 7 geography configurations reproduced the oracle in three plan modes, in
  every gate.
- **Timing:** D and D-s therefore return the same answer and differ only in computation. Their timings are compared
  only as *derived* ratios (§8), because they ran in different blocks.
- **Interleaved:** only P1 (spheroid) vs P2 (sphere) was interleaved, and the sphere was measurably faster
  (5.188 vs 10.226 ms). P2 stayed within 0.001 m of the haversine value.

**Limit of this finding:** the identical sets depend on the empty ±0.6 % band for these points and radii. Other points
or radii near the 0.45 % difference could give different spheroid and sphere results; that was not measured.

## 15. Deviations and measurement caveats

**Deviations (as documented in each step):**

| Step | Deviation | Effect |
|---|---|---|
| 7A.2 | First post-installation verification FAILED (installer had not completed); automated installation was not possible (session not elevated, UAC on the secure desktop); PostGIS 3.6.2 was installed manually, then verified PASS | none on data |
| 7A.2 | Installer set four machine environment variables the 7A.1 checklist asked to decline: `GDAL_DATA`, `PROJ_LIB`, `POSTGIS_ENABLE_OUTDB_RASTERS=1`, `POSTGIS_GDAL_ENABLED_DRIVERS` | raster / projection only, neither used; server not restarted |
| 7B | None from the plan; the harness-only run reported a false H-01 FAIL (case-insensitive `ERROR:` match inside a PASS text), fixed in the runner | none |
| 7C | Static-check false positive (`ANALYZE` inside `EXPLAIN (ANALYZE, …)`), fixed in the checker only | SQL and matrix unchanged |
| 7C | Runner parse error (`"$When:"`) and a duplicate check ID (`H-01` → `HR-01`), fixed before or between runs | no database access affected |
| 7C | Harness ran twice (harness-only run and full run), both PASS and rolled back | none |
| 7C | Index sizes varied across the three builds for G-2, Y-1, Y-2, J-2, J-4 (design expected deterministic sizes); kept build reported | size figures are single values of a varying quantity |
| 7C | `EXPLAIN (SETTINGS)` does not show `TimeZone` / `track_io_timing`, although both were set | none |
| 7A → 7C | Step numbering changed: 7C holds builds and queries, 7D is this analysis | documentation only |

**Measurement caveats:**

*Data and environment*
1. **Small tables.** 5,000 rows (4,161 points); flat heaps of 31–39 pages that fit many times into `shared_buffers`.
   0 blocks were read from disk, so no I/O cost is represented. Sequential scans are unusually cheap at this size,
   which bounds every index-vs-control ratio.
2. **One environment.** One laptop, Windows, PostgreSQL 17.9, PostGIS 3.6.2, default planner settings, AC power; the
   CPU performance counter showed 102–129 % (turbo). A single client, warm cache and no concurrency.

*Timing method*
3. **Sub-millisecond timings.** Many medians are below 1 ms; 22 class I cases were below 0.1 ms and were confirmed in
   session 2. In other classes 3 execution comparisons were not confirmed (F: D6, D6-s; J: D7).
4. **Session agreement and drift.** Session 2 alone agrees with 105 of 109 class I verdicts; the session 2 / session 1
   median ratio is 0.83–1.13.
5. **Only interleaved comparisons get verdicts.** D vs D-s, the choice of best configuration across pairs, and
   comparisons across query blocks are descriptive only.
6. **Forced plans.** Used for correctness and diagnosis only; their timings carry no verdict.
7. **What the times include.** `EXPLAIN (ANALYZE, TIMING OFF)`; execution time includes serialising the result
   (`SERIALIZE TEXT`). Detail runs with `TIMING ON` were not used for verdicts.

*Build and planner inputs*
8. **Build figures.** Three sequential samples per index, first build usually slowest; WAL is the insert-LSN difference
   inside the build's `DO` block.
9. **Statistics.** One `ANALYZE` after the builds. Row estimates were far off for several predicates (§10) and drove
   the plan choices that caused the regressions.

*Fairness and derived figures*
10. **JSONB heap width.** JSONB tables carry the documents; the wider heap is part of the F comparison and was not
    corrected.
11. **Derived figures.** Planning + execution totals, ratios of medians and size ratios are computed from recorded
    values; only the design's verdicts are verdicts.

*Scope*
12. **Not measured in Step 7:**
    - write, update and maintenance cost of spatial indexes
    - index bloat
    - concurrency
    - projections / `ST_Transform` and SRIDs other than 4326 (only the E4 error)
    - geography box queries
    - nearest neighbour with filters, `<#>`, other k values
    - BRIN `pages_per_range` variants and larger or spatially ordered tables
    - geometry distance methods for antimeridian / pole centres
13. **Database state.** The 10 indexes remain built with the post-build statistics; PostGIS stays installed;
    `sql/52_drop_gis_indexes.sql` has not been run.

---

**Stopped here.** This analysis covers Steps 7B–7C only. The final overall project conclusion is not started.
