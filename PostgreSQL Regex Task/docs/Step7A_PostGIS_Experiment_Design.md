# Step 7A — PostGIS Experiment Design

**Status:** design only (13/09/2026). Nothing was installed, created, indexed or measured, and no project data was
modified. The inspection used read-only queries (`default_transaction_read_only = on`) and read-only file checks.
Stopped for review.

**Numbering:** Step 7 is the PostGIS phase: 7A design, 7B setup, 7C storage and indexes, 7D queries, 7E report.

---

## 0. Evidence from the completed project (read-only)

| Area | Finding | Source |
|---|---|---|
| **PostGIS availability** | **Not available on this server.**<br>• `pg_available_extensions` has no `postgis*` entry.<br>• No `postgis*` control file in `share\extension`, no `postgis*` library in `lib`.<br>• Installed extensions: `plpgsql` only.<br>• Stack Builder is present; PostgreSQL 17.9 is the only installation | catalog and file checks |
| Schemas | `log_regex`, `log_regex_json`, `log_regex_json_write`, `public` | catalog |
| Flat coordinates | `latitude_degrees`, `longitude_degrees` `numeric(10,7)`. CHECKs: non-NULL exactly when the axis is VALID; ranges [−90, 90] and [−180, 180] inclusive | Step 5A §4.6, `sql/28` |
| Designated PostGIS input | "`geometry` / `geography` point from latitude/longitude: later PostGIS step; `latitude_degrees` / `longitude_degrees` are its input" | Step 5A §4 (deferred items) |
| Parsing and validation | • Labels decide.<br>• `POINT(...)` and GeoJSON are longitude-first; every other unlabelled pair is latitude-first; values are never swapped (C-03).<br>• Hemisphere letter must match the axis; sign combined with a hemisphere ⇒ INVALID.<br>• DMS minutes and seconds < 60; `NaN` and decimal comma ⇒ INVALID.<br>• DMS = d + m/60 + s/3600, computed exactly and rounded once to 7 places. The precision rule rejected 0 values in run 14 | Step 3A (C-03, VAL-GEO), Step 5A §4.6 |
| Axis-order sources already resolved | 333 pairs from F4 `loc=POINT(lon lat)` and 132 pairs from F3 GeoJSON `coordinates [lon, lat]` arrive as labelled degrees | flat `*_source` columns |
| Pairs in run 14 | **4,161 both VALID** (4,121 distinct points; 4,001 from VALID records, 160 from INVALID records); latitude only 88; longitude only 91; neither 660. Other validity states: PLACEHOLDER (`-`, `N/A`, `null`), INVALID (e.g. latitude `115.6258`) | `access_log_flat` |
| Distribution | • 20 occupied 1° cells, i.e. city clusters: Mumbai/Pune 951, Bangalore 479, New York 410, São Paulo 309, Tokyo 309, Singapore 283, Sydney 262, London 257, …<br>• Quadrants: NE 2,178, NW 1,009, SW 518, SE 456.<br>• Most frequent point: ×6 | `access_log_flat` |
| Boundary points | `log_id` 2122 (0, 0); 2272 (90, 180); 2280 (−90, −180). No other point with \|lat\| ≥ 80 or \|lon\| ≥ 170 | `access_log_flat` |
| JSONB coordinates | `fields.latitude` / `fields.longitude` objects: `value`, `validity`, `start_pos`, `source`, `missing_reason`, `degrees` (JSON number with 7 decimals, or `null`). `degrees` = flat value for 5,000 / 5,000 rows; types number/number 4,161, number/null 88, null/number 91, null/null 660 | Step 6A §2, 6B |
| Double-precision round trip | For all 4,161 pairs, `round(x::float8::numeric, 7) = x` on both axes (0 mismatches), and jsonb text → `float8` equals `numeric` → `float8` (4,161 / 4,161). **PostGIS double coordinates can therefore be verified exactly against the flat values** | read-only query |
| Step 6F conclusions carried forward | • jsonb extraction is 5–13× faster than json.<br>• Identical expression indexes behave the same when the index answers.<br>• Scans still pay extraction cost, and the planner does not price it.<br>• Timing ratios are valid only within a session; the 6D phase drift was 7–15 %; 6E showed a CPU slowdown on battery | Step 6F |
| Isolation approach so far | • One schema per experiment; nothing written outside it.<br>• Digests: `log_regex` `f8042db0…` (203 items), `log_regex_json` data `9e6f8831…` (10 items), Step 6D indexes `e20752ca…`.<br>• `sql/34` 38 / 38, `sql/38 final` 70 / 70, `sql/42` 41 / 41.<br>• SHA-256 manifests of earlier outputs.<br>• Generated SQL with static statement allowlists.<br>• Rolled-back harnesses; read-only measurement sessions; runners with PASS/FAIL reports | Steps 6B–6E |

## 1. PostGIS extension setup

1. **Prerequisite outside the database (needs your action and approval; no SQL does this).**
   - Install the PostGIS 3.x bundle for PostgreSQL 17 (x64) through Stack Builder → *Spatial Extensions*.
   - Decline the optional sample spatial database and any other optional component.
   - Record the installer name and version.
2. **Gate G-EXT (read-only), before any spatial SQL:**
   - `pg_available_extensions` lists `postgis`; record its `default_version`.
   - The server version is still 17.9, and the existing digests are unchanged.
3. **Scope:** only the `postgis` extension. Not `postgis_raster`, `postgis_topology`, `postgis_sfcgal`,
   `address_standardizer`, `btree_gist`, `cube` or `earthdistance`.
4. **Creation:**
   - `CREATE SCHEMA postgis; CREATE EXTENSION postgis WITH SCHEMA postgis VERSION '<recorded>';` in one transaction.
   - A rolled-back run comes first (`CREATE EXTENSION` is transactional).
   - No `ALTER DATABASE`, `ALTER ROLE` or `ALTER SYSTEM`. Experiment sessions set `search_path = log_regex_gis, postgis`
     themselves, and existing scripts keep the default search path.
5. **Recorded after creation:**
   - `postgis_full_version()`, including the GEOS and PROJ versions
   - the `spatial_ref_sys` row for SRID 4326
   - the volatility of `ST_MakePoint`, `ST_SetSRID` and the geography cast
   - which operator classes exist: `gist_geometry_ops_2d`, `spgist_geometry_ops_2d`, `brin_geometry_inclusion_ops_2d`,
     and the geography GiST / SP-GiST classes

   A configuration whose operator class or immutable function is missing is dropped and reported, never substituted.

## 2. Flat latitude/longitude → geometry / geography

- **Source:** one read of `log_regex.access_log_flat (log_id, latitude_degrees, longitude_degrees)`.
- **Target:** new schema `log_regex_gis`. There is no foreign key to `log_regex`, because a foreign key would add
  internal triggers to `access_log_flat` and change its digest.

| Table (sketch, built in 7B) | Content |
|---|---|
| `flat_numeric` | `log_id` PK, `latitude_degrees numeric(10,7)`, `longitude_degrees numeric(10,7)`: verbatim copy of all 5,000 rows (non-PostGIS baseline) |
| `flat_geom` | `log_id` PK, `geom geometry(Point, 4326)` = `ST_SetSRID(ST_MakePoint(longitude_degrees::float8, latitude_degrees::float8), 4326)` |
| `flat_geog` | `log_id` PK, `geog geography(Point, 4326)` = the same point `::geography` |

Rules:
- A point exists **only when both axes are VALID**, i.e. 4,161 points.
- Rows with one axis (179) or none (660) get SQL NULL. There is no partial point, no `(0, 0)` default and no
  imputation.
- The 160 points from INVALID records keep their valid coordinates; a record-validity filter can join by `log_id`.
- All tables hold 5,000 rows in `log_id` order, with default fillfactor and `autovacuum_enabled = false`, as in Step 6.

## 3. JSONB coordinates → geometry / geography

- **Source:** one read of `log_regex_json.access_log_jsonb (log_id, doc)`. The Step 6B/6D table and its indexes are not
  touched, and no index is added to it.

| Form | Table (sketch) | Point expression |
|---|---|---|
| J-EXPR | `jsonb_doc`: `log_id` PK, `doc jsonb` (a copy verified equal to the source) with **expression** indexes | `ST_SetSRID(ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8, (doc->'fields'->'latitude'->>'degrees')::float8), 4326)`, and its `::geography` form |
| J-STORED | `jsonb_geom` / `jsonb_geog`: `log_id`, `doc jsonb`, plus a `GENERATED ALWAYS AS (…) STORED` point column | the same expression |

- **Expressions:** each is defined once in the generator; queries repeat it character for character so the planner can
  match the index.
- **NULLs:** `null` degrees become SQL NULL, and the strict point functions return NULL.
- **Raw text:** the raw `value` text (DMS, `POINT(…)` WKT, GeoJSON) is **never** parsed; only the labelled `degrees`
  number is used.
- **json:** out of scope. Step 6F measured slower extraction for json and no json advantage relevant to this workload.

## 4. SRID and coordinate-order rules

1. **SRID 4326 (WGS 84, degrees) for every geometry and geography value.** Typmod columns `geometry(Point, 4326)` /
   `geography(Point, 4326)` reject any other SRID or geometry type.
2. **Axis order:** PostGIS x = **longitude**, y = **latitude**, so points are always built as
   `ST_MakePoint(longitude, latitude)`. WKT, EWKT and GeoJSON output are longitude-first. This is consistent with C-03,
   and nothing is swapped.
3. **Inputs** are labelled degrees only. Axis order from `POINT(...)` and GeoJSON sources was already resolved by the
   parser.
4. **No projection** (`ST_Transform`) and no datum change.
   - geometry works in planar degrees: bounding boxes and degree ordering only.
   - Metric distance comes only from geography: spheroid by default, or `use_spheroid => false` for the sphere variant.
5. **Boundaries are kept, not normalised.** The points (0, 0), (90, 180) and (−90, −180) stay as they are. Geography
   treats ±180 as one meridian and all longitudes at a pole as one point; this is tested (E1–E3), not corrected.
6. **Build gates:**
   - For all 4,161 points, `round(ST_X::numeric, 7) = longitude_degrees` and `round(ST_Y::numeric, 7) =
     latitude_degrees` (exact; proven possible in §0).
   - `ST_SRID = 4326`, `GeometryType = 'POINT'`, `ST_IsValid`.
   - Flat-derived and JSONB-derived points are byte-identical (`ST_AsBinary`).
   - A swap would put latitude beyond ±90 for every point with \|longitude\| > 90 (e.g. the Tokyo and Sydney clusters),
     so a swapped build fails the geography typmod or the gate.
7. **Comparisons** use rounded numeric coordinates or binary equality, never `ST_AsText` strings (float formatting
   depends on `extra_float_digits`).

## 5. Spatial index strategy

**One table per representation × index method.** All configurations then exist at the same time, so every query is
interleaved across configurations within one session. This avoids the cross-phase drift seen in Step 6D; the
duplicated storage is small at 5,000 rows.

| ID | Table | Index | Role |
|---|---|---|---|
| N-0 / N-1 | `flat_numeric` copies | none / btree `(latitude_degrees, longitude_degrees)` | non-PostGIS baseline for boxes |
| G-0 | `flat_geom` | none | control |
| G-1 | `flat_geom_gist` | GiST (`gist_geometry_ops_2d`) | primary geometry index |
| G-2 | `flat_geom_spgist` | SP-GiST (`spgist_geometry_ops_2d`) | if available |
| G-3 | `flat_geom_brin` | BRIN (`brin_geometry_inclusion_ops_2d`) | rows are in `log_id` order, **not** spatially clustered; measured as is |
| Y-0 / Y-1 / Y-2 | `flat_geog` copies | none / GiST / SP-GiST (if available) | geography |
| J-0 | `jsonb_doc` copy | none | control; points built on the fly |
| J-1 / J-2 | `jsonb_doc` | expression GiST on the geometry / geography expression | JSONB expression index |
| J-3 / J-4 | `jsonb_geom` / `jsonb_geog` | GiST on the stored generated column | JSONB stored point |

**Builds:** 3 builds per index; median time, size and WAL (as in Step 6D), `maintenance_work_mem = 64MB`, no parallel
maintenance workers, `ANALYZE` afterwards. No index is created on any existing table.

**Comparison classes, reported separately:**
1. **Same PostGIS type and index method, different source** (fair): G-1 vs J-1 vs J-3; Y-1 vs J-2 vs J-4.
2. **Index method on the same column:** none vs GiST vs SP-GiST vs BRIN.
3. **Method comparisons with the same answer but different operators:** numeric btree vs geometry GiST for boxes;
   geography `ST_DWithin` vs geometry box + `ST_DistanceSphere`. These are never read as an equivalence verdict.

## 6. Query workload

The centres, boxes and radii below were chosen with read-only haversine and `BETWEEN` counts on the flat values:
- They cover a spread of selectivities.
- **No point lies within ±0.6 % of any timed radius** (the sphere/spheroid ambiguity band).
- Expected counts are planning figures; the 7B gate recomputes them.

**Bounding boxes** (geometry `&&` / `ST_Intersects` with `ST_MakeEnvelope(w, s, e, n, 4326)`; numeric baseline
`BETWEEN`):

| ID | s, w, n, e | Expected rows | Notes |
|---|---|---:|---|
| B1 | 40.4, −74.3, 41.0, −73.6 | 410 | one cluster (New York) |
| B2 | 35, −10, 60, 30 | 416 | Europe |
| B3 | 8, 68, 23, 80 | 1,580 | India, 3 clusters |
| B4 | −60, −130, 70, 150 | 3,897 | 94 % of the points |
| B5 | −60, 170, 70, −170 | 0 | crosses ±180: two envelopes (geometry does not wrap); oracle `lon >= 170 OR lon <= -170` |
| B6 | 80, −180, 90, 180 | 1 | point (90, 180) lies on two edges: inclusive predicates only |

**Distance** (geography `ST_DWithin(geog, centre, metres)`, spheroid; each has a sphere variant `…-s`):

| ID | Centre (lat, lon) | Radius | Expected (sphere oracle) |
|---|---|---:|---:|
| D1 | New York 40.7128, −74.0060 | 10 km | 410 |
| D2 | Mumbai 19.0760, 72.8777 | 500 km | 1,101 |
| D3 | Reykjavik 64.1466, −21.9426 | 2,000 km | 599 |
| D4 | Mumbai | 5,000 km | 2,059 |
| D5 | 0, 180 (on the antimeridian) | 5,000 km | 262 |
| D6 | London 51.5074, −0.1278 | 1 km | 15 |
| D7 | North Pole 90, 0 | 100 km | 1 (`log_id` 2272 at 90, 180) |

Not timed, because the band is not empty: New York 1 km (1 point), Sydney 1 km (1), London 5,000 km (2).

**Nearest neighbours** (geography `ORDER BY geog <-> centre LIMIT k`; geometry `<->` in degrees as a separate method):

| ID | Query | Oracle facts |
|---|---|---|
| K1 | 10 nearest to Reykjavik | 10th sphere distance 772.7 m, no tie at rank 10 |
| K2 | 100 nearest to Reykjavik | 100th 3,273.8 m, no tie |
| K3 | 10 nearest to New York (geometry `<->`, degrees) | 6 points at the centre itself; the oracle handles ties |

**Construction and projection cost:**
- P1 `ST_Distance(geog, centre)` for all points, spheroid; P2 the same on the sphere.
- P3 points built on the fly from `flat_numeric`; P4 points built on the fly from `jsonb_doc`, both without a stored
  column.

**Edge facts** (correctness only, not timed):
- E1: distance (0, 180) → (0, −180) is 0 in geography and 360° in geometry.
- E2: distance between the pole points (90, 180) and (90, 0) is 0.
- E3: B6 `ST_Within` excludes the edge point, while `ST_Intersects` includes it.
- E4: mixing SRIDs raises an error. Tested only inside a rolled-back harness.

## 7. Correctness and oracle checks

The oracle uses the flat `numeric` values and plain SQL (`radians`, `sin`, `cos`, `asin`), **never PostGIS functions**.
A timing counts only when its result matches (Step 6A rule 1).

| ID | Check |
|---|---|
| O-1 construction | 4,161 non-NULL points in every representation; NULL exactly where the flat pair is not both VALID; the exact coordinate round trip, SRID, type and validity; flat-derived = JSONB-derived, byte-identical |
| O-2 boxes | result `log_id` set = `BETWEEN` oracle (B5 in OR form); checksum = count + md5 of the sorted `log_id`s |
| O-3 sphere distance | `…-s` results = haversine oracle with R = 6,371,008.7714 m. The gate first verifies max \|`ST_Distance(geog, c, false)` − oracle\| ≤ 1 mm over all points; otherwise it stops |
| O-4 spheroid distance | result set = oracle set, which is exact because every timed radius has an empty ±0.6 % band. The gate verifies the maximum relative sphere/spheroid difference is below 0.6 % |
| O-5 nearest neighbours | the returned distances equal the first k oracle distances; sets compared where there is no tie at rank k; the `<->` distance semantics for geography are recorded at setup |
| O-6 plan invariance | every query × configuration returns the same checksum with default plans and with `enable_seqscan = off` |
| O-7 sources | copied tables equal their sources (md5 / equality); the existing digests are unchanged |
| O-8 edge facts | E1–E4 results recorded |

## 8. Storage and index-size measurements

Per table after load and `VACUUM (ANALYZE)`:
- **Relation sizes:** main / FSM / VM, TOAST, `pg_table_size`, `pg_indexes_size`, `pg_total_relation_size`;
  `relpages`, `reltuples`.
- **Per value:** `pg_column_size` of `geom`, `geog`, the numeric pair and the jsonb document — min, median, max and sum
  over non-NULL values.
- **Per index:** size, page count, build time (median of 3) and build WAL; BRIN `pages_per_range` recorded.
- **Reference only:** `access_log_flat` 6,586,368 bytes; `access_log_jsonb` 16,957,440 bytes with the Step 6D indexes.

Sizes are near-deterministic and reported exactly; no timing rule applies to them.

## 9. EXPLAIN ANALYZE methodology

The Step 6C/6D protocol, with the Step 6E lessons added:
- **Sessions:** read-only (`default_transaction_read_only = on`); `jit = off`, `max_parallel_workers_per_gather = 0`,
  `TimeZone = 'UTC'`, `track_io_timing = on`, `search_path = log_regex_gis, postgis`.
- **EXPLAIN options:** `(ANALYZE, TIMING OFF, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY, SUMMARY, FORMAT JSON)`, plus
  one `TIMING ON` detail run per series.
- **Repetitions:**
  - 3 warm-ups and 15 measured runs per query × configuration.
  - Configurations of a query are interleaved within each round, with the order alternating by round.
  - Two independent sessions.
- **Rule:**
  - A difference is measurable only with non-overlapping IQRs and at least a 10 % median difference; medians below
    0.1 ms must be confirmed in session 2.
  - Row estimates vs actual rows are recorded (PostGIS selectivity estimation).
- **Plans:** default plans are primary. Forced diagnostics (`enable_seqscan = off`, `enable_bitmapscan = off`) are
  reported separately.
- **Machine state:**
  - AC power is required. The power source and CPU frequency are recorded before and after each session.
  - Other active client sessions must be 0, checked per run; runs are flagged otherwise.
  - Shared hit/read blocks are recorded (warm cache).

## 10. Isolation and rollback safeguards

- **Schemas:**
  - Experiment relations live only in `log_regex_gis`; the extension only in `postgis`.
  - Nothing is created in `log_regex`, `log_regex_json`, `log_regex_json_write` or `public`.
- **Never written:**
  - raw data, `access_log_flat`, parser objects and runs, the answer key
  - the Step 6B/6D tables and indexes, and the Step 6E write schema

  There are no foreign keys, triggers or views referencing existing objects. The only reads of existing data are one
  `SELECT` each from `access_log_flat` and `access_log_jsonb`.
- **Proofs before and after every writing step:**
  - `log_regex` digest `f8042db0…` (203 items); `log_regex_json` data digest `9e6f8831…`; Step 6D index digest
    `e20752ca…`
  - `sql/34` 38 / 38, `sql/38 final` 70 / 70, `sql/42` 41 / 41
  - the Step 6C/6D manifests
  - new: the extension inventory (`plpgsql`, then `plpgsql` + `postgis`), the object count of `public`, and 0 event
    triggers
- **Generated SQL:**
  - A Python generator writes it, and a static allowlist confirms that every `CREATE`, `INSERT`, `ANALYZE` or `VACUUM`
    targets `log_regex_gis`; only the extension step targets `postgis`.
  - Rolled-back harnesses run before every committing script; `VACUUM` is replaced by `ANALYZE` inside a harness.
  - Guards: stop if `log_regex_gis` already exists, if `postgis` is unavailable or differs from the recorded version,
    or if other sessions are active (new SQLSTATEs from LR019).
- **Rollback, documented but not executed unless asked:**
  - `DROP SCHEMA log_regex_gis CASCADE` removes every experiment object, after listing them.
  - `DROP EXTENSION postgis; DROP SCHEMA postgis;` restores the pre-PostGIS catalog; verify `pg_extension` = `plpgsql`
    and that the digests are unchanged.
  - Removing the PostGIS binaries is an installer action outside this project.

## 11. Planned steps (not started)

| Step | Content |
|---|---|
| 7B | G-EXT gate; extension in schema `postgis` (harness first); `log_regex_gis` tables from flat and JSONB; O-1 / O-7 gates |
| 7C | index builds (§5) and storage measurements (§8) |
| 7D | query workload (§6) with oracles (§7) and the EXPLAIN protocol (§9) |
| 7E | results report (no generalisation beyond this data and environment) |

## 12. Decisions for review

1. **PostGIS binaries:** install the PostGIS 3.x bundle for PostgreSQL 17 through Stack Builder. This is required, and
   it is your action, outside the database.
2. **Schemas:** the extension goes into its own schema `postgis`; experiment objects into `log_regex_gis`.
3. **SRID and axis order:** SRID 4326 only, with no projection; points built as `ST_MakePoint(longitude, latitude)`.
4. **When a point exists:** only when both axes are VALID (4,161). The 160 points from INVALID records are kept.
5. **Index layout:** one table per representation × index method, so all configurations are measured interleaved.
6. **JSONB forms:** both expression indexes and stored generated columns; json is excluded.
7. **Workload:** B1–B6, D1–D7 (spheroid and sphere), K1–K3, P1–P4 and edge facts E1–E4, with centres and radii fixed
   from the read-only profile.
8. **Optional index methods:** SP-GiST, BRIN and geography SP-GiST are included only if the installed version provides
   the operator class.
9. **Machine state:** AC power is required during measurement sessions.
