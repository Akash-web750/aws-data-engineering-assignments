# Step 7B — PostGIS Setup and Preflight Plan

**Status:** plan approved and **setup executed** (13/09/2026). The rolled-back harness passed first; the real setup,
verification and integrity checks then passed 317 / 0, as §9 records. Created: extension `postgis` 3.6.2 in schema
`postgis`; schema `log_regex_gis` with the 15 tables. Not done: no Step 7C index, no EXPLAIN or timing, no change outside
these two schemas. Stopped after Step 7B.

**Based on:**
- the approved design: [Step7A_PostGIS_Experiment_Design.md](Step7A_PostGIS_Experiment_Design.md)
- the installation checks: [Step7A1_PostGIS_Installation_Preflight.md](Step7A1_PostGIS_Installation_Preflight.md) and
  [Step7A2_PostGIS_Post_Installation_Verification.md](Step7A2_PostGIS_Post_Installation_Verification.md) (PASS)

---

## 0. What Step 7B implements from the approved design

| Design rule (Step 7A) | Implementation in 7B |
|---|---|
| extension only in schema `postgis`; experiment objects only in `log_regex_gis` (§1, §10) | `sql/45` and `sql/46` |
| SRID 4326; points built as `ST_MakePoint(longitude, latitude)`; no projection (§4) | the four point expressions of §4 |
| a point exists only when both axes are VALID; no imputation (§2) | follows from strict `ST_MakePoint` and `degrees` being NULL / JSON `null` exactly when not VALID (S-02, J-04) |
| one table per representation × index method (§5) | the 15 tables of §4 |
| JSONB as both expression index and stored generated column; json excluded (§3) | `jsonb_doc_expr`, `jsonb_geom*`, `jsonb_geog*` |
| oracle from the flat numeric values, never PostGIS (§7) | the checks of §6 |
| before/after proofs, harness first, allowlisted generated SQL (§10) | §7 |

**Scope split:**

| Step | Content |
|---|---|
| 7B | extension, tables, loads, correctness and oracle gates |
| 7C | index builds (defined in §5) and storage measurements |
| 7D | EXPLAIN measurements |

**Refinement of Step 7A §5:** two no-index controls, `jsonb_geom` and `jsonb_geog`, are added for the stored JSONB
points. The GiST effect on J-3 / J-4 is then measured against a table of identical shape.

## 1. Current state (verified read-only, 13/09/2026)

| ID | Check | Result |
|---|---|---|
| A-01 | server | PostgreSQL 17.9, `x86_64-windows`, port 5432; user `postgres` (superuser) |
| A-02 | PostGIS availability and version | `postgis` default version **3.6.2**, installed: none. Version row 3.6.2: `superuser = true`, `trusted = false`, `relocatable = false`, no required extensions |
| A-03 | not yet created | installed extensions `plpgsql 1.0` only; schemas `postgis` and `log_regex_gis` absent; 0 `geometry` / `geography` types |
| S-01 | flat coordinate counts (`log_regex.access_log_flat`) | 5,000 rows: **both VALID 4,161**; latitude only 88; longitude only 91; neither 660 |
| S-02 | flat rules | `degrees` NOT NULL exactly when VALID: 0 violations; out of range: 0; distinct both-VALID points 4,121; both-VALID points with \|longitude\| > 90: **856**, which is the swap detector of §6 |
| S-03 | validity pairs (latitude / longitude) | VALID/VALID 4,161; MISSING/MISSING 549; MISSING/VALID 80; VALID/MISSING 73; PLACEHOLDER/PLACEHOLDER 33; PLACEHOLDER/MISSING 32; MISSING/PLACEHOLDER 31; INVALID/INVALID 14; VALID/INVALID 12; INVALID/VALID 10; VALID/PLACEHOLDER 3; MISSING/INVALID 1; PLACEHOLDER/VALID 1 |
| S-04 | boundary points | `log_id` 2122 = (0, 0); 2272 = (90, 180); 2280 = (−90, −180) |
| S-05 | double-precision round trip | `round(x::float8::numeric, 7) = x`: 0 mismatches on either axis |
| S-06 | flat source fingerprint | md5 of `log_id:latitude_degrees:longitude_degrees` in `log_id` order = `f562354dbf6c155f3ed0a93da433e79c` (5,000 rows) |
| J-01 | JSONB source | `log_regex_json.access_log_jsonb`: 5,000 rows; md5 of `log_id:doc::text` in `log_id` order = `fb3bc16318e6a81c7930aed2217986ea` |
| J-02 | JSONB coordinate structure | `fields.latitude` and `fields.longitude` have exactly the keys {`degrees`, `missing_reason`, `source`, `start_pos`, `validity`, `value`} in 5,000 / 5,000 documents |
| J-03 | `degrees` JSON types (latitude / longitude) | number/number 4,161; number/null 88; null/number 91; null/null 660 |
| J-04 | JSONB rules | `degrees` is a number exactly when `validity` = VALID: 0 violations; every number has the 7-decimal form `-?d{1,3}.ddddddd`: 0 exceptions |
| J-05 | JSONB = flat (same `log_id`) | validity equal 5,000; `degrees` equal as numeric 5,000; text → `float8` = numeric → `float8` on both axes 5,000 / 5,000 |
| J-06 | planned JSONB point inputs | both `(…->>'degrees')::float8` values non-NULL for 4,161 of 5,000 = S-01 |
| Z-01 | reference sizes | `access_log_flat` total 6,586,368 bytes; `access_log_jsonb` heap 8,036,352 / table 8,077,312; stored documents 7,219,683 bytes |
| Z-02 | sessions | 4 other client sessions, all idle |

The Step 7A.2 checks of the project data (digests, raw integrity 10 / 10, `sql/34`, `sql/38 final`, manifests) passed
earlier the same day. They are repeated as the before-proofs of §7.

## 2. Implementation plan

| Artefact | Content |
|---|---|
| `scripts/step7_postgis_experiment.py` | the single definition of the schema, the 15 tables, the 4 point expressions, the index DDL and every check; `generate [--check]` |
| `sql/45_create_postgis_extension.sql` | guard; `CREATE SCHEMA postgis`; `CREATE EXTENSION postgis`; extension gate. One transaction; refusal / gate SQLSTATE `LR019` |
| `sql/46_create_gis_tables.sql` | guard; `CREATE SCHEMA log_regex_gis`; the 15 tables; loads; setup gate before COMMIT. One transaction; `LR020` |
| `sql/47_verify_gis_setup.sql` | read-only verification: extension, catalog, construction, copies, oracle readiness (§6). `LR021` |
| `sql/48_build_gis_indexes.sql` | the Step 7C index builds (§5); generated and statically checked in 7B, **not run** |
| `sql/run_step7b_postgis_setup.ps1` | runner: static checks → before-proofs → rolled-back harness → `sql/45` → `sql/46` → `VACUUM (ANALYZE)` of the 15 tables → `sql/47` → after-proofs → PASS/FAIL report |

**Session settings of the writing scripts:**
- `SET LOCAL search_path = log_regex_gis, postgis`
- `lock_timeout = '10s'`
- all PostGIS functions, types and operator classes schema-qualified (`postgis.`) in DDL
- no `ALTER DATABASE`, `ALTER ROLE` or `ALTER SYSTEM`

**Source reads:** exactly one `SELECT` from each existing source (`access_log_flat` into `flat_numeric`,
`access_log_jsonb` into `jsonb_doc`). Every other table is loaded from these copies inside `log_regex_gis`.

## 3. Extension setup (exact; `sql/45`)

```sql
-- guard (LR019): postgis 3.6.2 available; pg_extension = {plpgsql}; schemas postgis and log_regex_gis absent;
--                no geometry/geography type; current_user is superuser
CREATE SCHEMA postgis;
CREATE EXTENSION postgis WITH SCHEMA postgis VERSION '3.6.2';
```

**Extension gate** (before COMMIT, and again read-only in `sql/47`):

| ID | Check |
|---|---|
| X-01 | `pg_extension`: `postgis` version 3.6.2 in namespace `postgis`; `plpgsql` unchanged; no other extension |
| X-02 | `postgis.postgis_lib_version()` = `3.6.2`; `postgis.postgis_full_version()` recorded (GEOS, PROJ) |
| X-03 | `postgis.spatial_ref_sys` has SRID 4326 with `auth_name` = `EPSG` and `auth_srid` = 4326 |
| X-04 | `pg_opclass` in namespace `postgis` contains `gist_geometry_ops_2d`, `spgist_geometry_ops_2d`, `brin_geometry_inclusion_ops_2d`, `gist_geography_ops`, `spgist_geography_ops_nd` |
| X-05 | `provolatile = 'i'` for `postgis.st_makepoint(float8, float8)`, `postgis.st_setsrid(postgis.geometry, integer)`, `postgis.geography(postgis.geometry)` |
| X-06 | only the schemas `postgis` (new) and the existing four exist; `public` still 0 / 0 / 0; 0 event triggers |

## 4. Experiment tables (exact definitions; `sql/46`)

**Point expressions** (defined once in the generator; queries and indexes repeat them character for character):

| Name | Expression |
|---|---|
| `E_FLAT_GEOM` | `postgis.ST_SetSRID(postgis.ST_MakePoint(longitude_degrees::float8, latitude_degrees::float8), 4326)` |
| `E_FLAT_GEOG` | `postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(longitude_degrees::float8, latitude_degrees::float8), 4326))` |
| `E_JSONB_GEOM` | `postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8, (doc->'fields'->'latitude'->>'degrees')::float8), 4326)` |
| `E_JSONB_GEOG` | `postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8, (doc->'fields'->'latitude'->>'degrees')::float8), 4326))` |

Longitude is always the first argument. NULL or `null` on either axis gives a NULL point.

**Common to every table:**
- schema `log_regex_gis`; `log_id integer NOT NULL`, `PRIMARY KEY (log_id)`
- `WITH (autovacuum_enabled = false)`; default fillfactor and storage
- loaded with `ORDER BY log_id`; 5,000 rows each; no foreign keys, triggers or defaults

| # | ID | Table | Columns besides `log_id` | Loaded from | Index (built in 7C) |
|---:|---|---|---|---|---|
| 1 | N-0 | `flat_numeric` | `latitude_degrees numeric(10,7)`, `longitude_degrees numeric(10,7)` | `log_regex.access_log_flat` (**only read**) | none (control) |
| 2 | N-1 | `flat_numeric_btree` | same | `flat_numeric` | btree (lat, lon) |
| 3 | G-0 | `flat_geom` | `geom postgis.geometry(Point, 4326)` = `E_FLAT_GEOM` | `flat_numeric` | none (control) |
| 4 | G-1 | `flat_geom_gist` | same | `flat_numeric` | GiST |
| 5 | G-2 | `flat_geom_spgist` | same | `flat_numeric` | SP-GiST |
| 6 | G-3 | `flat_geom_brin` | same | `flat_numeric` | BRIN |
| 7 | Y-0 | `flat_geog` | `geog postgis.geography(Point, 4326)` = `E_FLAT_GEOG` | `flat_numeric` | none (control) |
| 8 | Y-1 | `flat_geog_gist` | same | `flat_numeric` | GiST |
| 9 | Y-2 | `flat_geog_spgist` | same | `flat_numeric` | SP-GiST |
| 10 | J-0 | `jsonb_doc` | `doc jsonb NOT NULL` | `log_regex_json.access_log_jsonb` (**only read**) | none (control; points built on the fly) |
| 11 | J-X | `jsonb_doc_expr` | `doc jsonb NOT NULL` | `jsonb_doc` | J-1 GiST on `E_JSONB_GEOM`, J-2 GiST on `E_JSONB_GEOG` |
| 12 | J-3c | `jsonb_geom` | `doc jsonb NOT NULL`, `geom postgis.geometry(Point, 4326) GENERATED ALWAYS AS (E_JSONB_GEOM) STORED` | `jsonb_doc` (`log_id`, `doc`) | none (control) |
| 13 | J-3 | `jsonb_geom_gist` | same | `jsonb_doc` | GiST |
| 14 | J-4c | `jsonb_geog` | `doc jsonb NOT NULL`, `geog postgis.geography(Point, 4326) GENERATED ALWAYS AS (E_JSONB_GEOG) STORED` | `jsonb_doc` | none (control) |
| 15 | J-4 | `jsonb_geog_gist` | same | `jsonb_doc` | GiST |

**The four requested mappings:**

| Mapping | Tables | Index |
|---|---|---|
| flat → geometry | 3–6 | |
| flat → geography | 7–9 | |
| JSONB → geometry | 11 | expression J-1 |
| JSONB → geometry | 12–13 | stored column |
| JSONB → geography | 11 | expression J-2 |
| JSONB → geography | 14–15 | stored column |

Tables 1, 2 and 10 are the non-PostGIS baselines.

**Representative DDL** (the generator emits all 15 from these templates; copies differ only by name):

```sql
CREATE SCHEMA log_regex_gis;

CREATE TABLE log_regex_gis.flat_numeric (
    log_id            integer       NOT NULL,
    latitude_degrees  numeric(10,7),
    longitude_degrees numeric(10,7),
    CONSTRAINT flat_numeric_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);
INSERT INTO log_regex_gis.flat_numeric (log_id, latitude_degrees, longitude_degrees)
SELECT log_id, latitude_degrees, longitude_degrees FROM log_regex.access_log_flat ORDER BY log_id;

CREATE TABLE log_regex_gis.flat_geom (
    log_id integer NOT NULL,
    geom   postgis.geometry(Point, 4326),
    CONSTRAINT flat_geom_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);
INSERT INTO log_regex_gis.flat_geom (log_id, geom)
SELECT log_id, postgis.ST_SetSRID(postgis.ST_MakePoint(longitude_degrees::float8, latitude_degrees::float8), 4326)
FROM log_regex_gis.flat_numeric ORDER BY log_id;

CREATE TABLE log_regex_gis.flat_geog (
    log_id integer NOT NULL,
    geog   postgis.geography(Point, 4326),
    CONSTRAINT flat_geog_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);
INSERT INTO log_regex_gis.flat_geog (log_id, geog)
SELECT log_id, postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(longitude_degrees::float8, latitude_degrees::float8), 4326))
FROM log_regex_gis.flat_numeric ORDER BY log_id;

CREATE TABLE log_regex_gis.jsonb_doc (
    log_id integer NOT NULL,
    doc    jsonb   NOT NULL,
    CONSTRAINT jsonb_doc_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);
INSERT INTO log_regex_gis.jsonb_doc (log_id, doc)
SELECT log_id, doc FROM log_regex_json.access_log_jsonb ORDER BY log_id;

CREATE TABLE log_regex_gis.jsonb_geom (
    log_id integer NOT NULL,
    doc    jsonb   NOT NULL,
    geom   postgis.geometry(Point, 4326) GENERATED ALWAYS AS (
               postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8,
                                                       (doc->'fields'->'latitude'->>'degrees')::float8), 4326)) STORED,
    CONSTRAINT jsonb_geom_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);
INSERT INTO log_regex_gis.jsonb_geom (log_id, doc) SELECT log_id, doc FROM log_regex_gis.jsonb_doc ORDER BY log_id;

CREATE TABLE log_regex_gis.jsonb_geog (
    log_id integer NOT NULL,
    doc    jsonb   NOT NULL,
    geog   postgis.geography(Point, 4326) GENERATED ALWAYS AS (
               postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8,
                                                                         (doc->'fields'->'latitude'->>'degrees')::float8), 4326))) STORED,
    CONSTRAINT jsonb_geog_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);
INSERT INTO log_regex_gis.jsonb_geog (log_id, doc) SELECT log_id, doc FROM log_regex_gis.jsonb_doc ORDER BY log_id;
```

**Expected size:** the six JSONB tables hold about 8 MB of documents each, about 50 MB in total.

## 5. Planned spatial indexes (exact definitions; built in Step 7C, not in 7B)

| ID | Index DDL |
|---|---|
| N-1 | `CREATE INDEX flat_numeric_btree_lat_lon_idx ON log_regex_gis.flat_numeric_btree USING btree (latitude_degrees, longitude_degrees);` |
| G-1 | `CREATE INDEX flat_geom_gist_idx ON log_regex_gis.flat_geom_gist USING gist (geom postgis.gist_geometry_ops_2d);` |
| G-2 | `CREATE INDEX flat_geom_spgist_idx ON log_regex_gis.flat_geom_spgist USING spgist (geom postgis.spgist_geometry_ops_2d);` |
| G-3 | `CREATE INDEX flat_geom_brin_idx ON log_regex_gis.flat_geom_brin USING brin (geom postgis.brin_geometry_inclusion_ops_2d);` (default `pages_per_range` 128, recorded; rows are in `log_id` order, not spatial order) |
| Y-1 | `CREATE INDEX flat_geog_gist_idx ON log_regex_gis.flat_geog_gist USING gist (geog postgis.gist_geography_ops);` |
| Y-2 | `CREATE INDEX flat_geog_spgist_idx ON log_regex_gis.flat_geog_spgist USING spgist (geog postgis.spgist_geography_ops_nd);` |
| J-1 | `CREATE INDEX jsonb_doc_expr_geom_gist_idx ON log_regex_gis.jsonb_doc_expr USING gist ((postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8, (doc->'fields'->'latitude'->>'degrees')::float8), 4326)) postgis.gist_geometry_ops_2d);` |
| J-2 | `CREATE INDEX jsonb_doc_expr_geog_gist_idx ON log_regex_gis.jsonb_doc_expr USING gist ((postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8, (doc->'fields'->'latitude'->>'degrees')::float8), 4326))) postgis.gist_geography_ops);` |
| J-3 | `CREATE INDEX jsonb_geom_gist_idx ON log_regex_gis.jsonb_geom_gist USING gist (geom postgis.gist_geometry_ops_2d);` |
| J-4 | `CREATE INDEX jsonb_geog_gist_idx ON log_regex_gis.jsonb_geog_gist USING gist (geog postgis.gist_geography_ops);` |

**Requirements:**
- J-1 and J-2 are possible only because `ST_MakePoint`, `ST_SetSRID` and `geography(geometry)` are `IMMUTABLE`; the
  install script shows this and X-05 re-checks it.
- No index is ever created on an existing table.

**7C build protocol (Step 6D):**
- 3 builds per index; median time, size and WAL
- `maintenance_work_mem = 64MB`, `max_parallel_maintenance_workers = 0`
- `ANALYZE` afterwards
- `indisvalid` / `indisready` checked
- a catalog comparison of `pg_get_indexdef` with this table

## 6. Correctness and oracle checks (before any performance measurement)

Every check must PASS; any failure stops the step, and no measurement follows. The oracle uses `flat_numeric` and plain
SQL only. PostGIS results are compared with it, never with themselves.

**Group O-1: construction** (in the `sql/46` gate and in `sql/47`):

| ID | Check |
|---|---|
| O-1a | every table has 5,000 rows, and its `log_id` set equals `flat_numeric`'s |
| O-1b | non-NULL points = 4,161 in every point column and in both J-X expressions; the NULL `log_id` set equals the flat rows whose pair is not both VALID (839) |
| O-1c | exact coordinates for all 4,161 points: `round(ST_X(p)::numeric, 7) = longitude_degrees` and `round(ST_Y(p)::numeric, 7) = latitude_degrees` (geography via `::postgis.geometry`) |
| O-1d | `ST_SRID = 4326`, `GeometryType = 'POINT'`, `ST_IsValid`; `format_type` = `postgis.geometry(Point,4326)` / `postgis.geography(Point,4326)`; generated columns have `attgenerated = 's'`, and their `pg_get_expr` matches `E_JSONB_GEOM` / `E_JSONB_GEOG` after normalisation |
| O-1e | byte identity by `log_id`: `ST_AsEWKB` of every geometry table and of the J-X geometry expression = `flat_geom`; every geography table and the J-X geography expression = `postgis.geography(flat_geom.geom)` |
| O-1f | axis order: for the 856 points with \|longitude\| > 90, `ST_X` = longitude and \|`ST_Y`\| ≤ 90. Boundary rows 2122 (0, 0), 2272 (90, 180) and 2280 (−90, −180) exact in every point table |

**Group O-7: copies and sources:**

| ID | Check |
|---|---|
| O-7a | `flat_numeric` fingerprint = `f562354dbf6c155f3ed0a93da433e79c`, identical to the source (S-06) |
| O-7b | `jsonb_doc` fingerprint = `fb3bc16318e6a81c7930aed2217986ea` = source (J-01); `doc` of every JSONB copy equals `jsonb_doc` for 5,000 / 5,000 |
| O-7c | `flat_numeric_btree` equals `flat_numeric` (`IS NOT DISTINCT FROM`, 5,000 / 5,000) |

**Group O-2 … O-5: oracle readiness.** These are read-only, run on the no-index tables and involve no timing; `sql/47`
runs them, and 7D repeats them per configuration before timing.

| ID | Check | Expected |
|---|---|---|
| O-2 | boxes B1–B6: `ST_Intersects(geom, ST_MakeEnvelope(w, s, e, n, 4326))` on `flat_geom` (B5 as two envelopes) = `BETWEEN` oracle on `flat_numeric` (count + md5 of sorted `log_id`s) | 410, 416, 1,580, 3,897, 0, 1 |
| O-3 | sphere: max \|`ST_Distance(geog, centre, false)` − haversine (R = 6,371,008.7714 m)\| over 4,161 points × 7 centres ≤ 0.001 m; D1–D7 sphere `ST_DWithin` sets = oracle sets | 410, 1,101, 599, 2,059, 262, 15, 1 |
| O-4 | spheroid: max relative \|spheroid − sphere\| / sphere < 0.6 %; no point within ±0.6 % of any timed radius; spheroid `ST_DWithin` sets = oracle sets | same counts |
| O-5 | nearest neighbours from Reykjavik: rank-10 and rank-100 oracle distances with no ties; `geog <-> centre` compared with `ST_Distance(…, false)` and `(…, true)` to record which distance the operator returns | 772.7 m / 3,273.8 m |
| E1–E3 | edge facts: (0, 180)–(0, −180) is 0 in geography and 360° in geometry; pole points (90, 180)–(90, 0) are 0 apart; `ST_Within` vs `ST_Intersects` on B6 | recorded |
| E4 | mixing SRIDs raises an error: tested only inside the rolled-back harness | recorded |

**Group O-6, plan invariance** (identical checksums with default plans and with `enable_seqscan = off`), needs the
indexes; it belongs to 7C / 7D.

## 7. Rollback and before/after integrity checks

**Before any write (read-only; all must PASS):**

| ID | Check | Expected |
|---|---|---|
| B-01 | installation state | `postgis` 3.6.2 available, not installed; `pg_extension` = {`plpgsql`}; schemas `postgis`, `log_regex_gis` absent; 0 `geometry` / `geography` types; `public` 0 / 0 / 0; 0 event triggers; preload settings empty; server start time recorded; other client sessions idle |
| B-02 | `log_regex` digest | `f8042db0318656b5929c86ea1f7888d4` over 203 items |
| B-03 | `log_regex_json` data digest | `9e6f883112c4a01781bdce5cf9bf3a28` over 10 items |
| B-04 | Step 6D index digest | `e20752ca02d09e89281503569650d0ce` over 14 indexes, 9,510,912 bytes |
| B-05 | `log_regex.verify_raw_access_logs()` | 10 / 10; dataset digest `1bcff42a…` |
| B-06 | `sql/27` | exactly 4 foreign keys, all validated |
| B-07 / B-08 | `sql/34` / `sql/38 final` | 38 / 38 and 70 / 70 (read-only sessions) |
| B-09 | Step 6E write schema | 8 relations; canonical md5 `aeaef323…`; 238 / 238 / 5,000; write tables empty |
| B-10 | manifests | Step 6C 11 / 11, Step 6D 26 / 26 |
| B-11 | source fingerprints | flat `f562354d…`, jsonb `fb3bc163…` |
| B-12 | relations per schema | `log_regex` 49, `log_regex_json` 16, `log_regex_json_write` 8 |

**After `sql/45`, after `sql/46` and at the end:** B-02 … B-12 unchanged, plus:

| ID | Check |
|---|---|
| A-01 | `pg_extension` = {`plpgsql` 1.0, `postgis` 3.6.2 in namespace `postgis`}; no other extension |
| A-02 | new schemas are exactly `postgis` and `log_regex_gis`; `public` 0 / 0 / 0; 0 event triggers; `pg_db_role_setting` unchanged |
| A-03 | `log_regex_gis` holds exactly the 15 tables and their 15 primary keys (plus their TOAST relations in `pg_toast`); 0 secondary indexes in 7B; no views, functions, sequences, triggers or foreign keys |
| A-04 | 0 `pg_depend` edges between `log_regex_gis` / `postgis` and `log_regex`, `log_regex_json` or `log_regex_json_write` |

**Static checks in the runner:**
- the generated files are up to date and ASCII
- every write statement matches the allowlist:
  - `CREATE SCHEMA postgis` / `log_regex_gis`
  - `CREATE EXTENSION postgis WITH SCHEMA postgis VERSION '3.6.2'`
  - `CREATE TABLE` of the 15 names
  - `INSERT INTO log_regex_gis.<table>`
  - `VACUUM (ANALYZE)` / `ANALYZE` of those tables
- reads of existing data are exactly one `SELECT` from `log_regex.access_log_flat` and one from
  `log_regex_json.access_log_jsonb`
- `sql/47` contains no write statement
- `sql/48` holds exactly the 10 index statements of §5

**Rolled-back harness (before the real run):**
- `sql/45`, `sql/46` and `sql/47` run in one transaction, with `ANALYZE` in place of `VACUUM`, including E4; then
  `ROLLBACK`.
- Afterwards B-01 must hold exactly: no `postgis` extension, no new schemas.

**Guards:**
- `sql/45` refuses (`LR019`) unless the B-01 state holds.
- `sql/46` refuses (`LR020`) if `log_regex_gis` exists, `postgis` is not 3.6.2 in schema `postgis`, or any gate fails.
- `sql/47` raises `LR021` if any check fails.

Each writing script is a single transaction, so a failure leaves nothing behind. If `sql/45` committed and `sql/46`
failed, only the extension exists.

**Rollback procedure** (documented; run only on request):
1. `DROP SCHEMA log_regex_gis CASCADE;` (after listing its objects; only the designed ones may exist)
2. `DROP EXTENSION postgis;`
3. `DROP SCHEMA postgis;`
4. Rerun B-01 … B-12: `pg_extension` = {`plpgsql`}, both schemas absent, all digests unchanged.

Removing the PostGIS binaries is an installer action outside the project. The installer environment variables recorded
in Step 7A.2 §3 are not used by this setup, and no server restart is needed.

## 8. Decisions for review

1. **Tables:** the 15 tables of §4, including the two added no-index controls `jsonb_geom` and `jsonb_geog`.
2. **Source reads:** each source is read once into a base copy (`flat_numeric`, `jsonb_doc`); all other tables load
   from those copies.
3. **Geography expression:** written as `postgis.geography(…)` in columns, indexes and queries, repeated exactly.
4. **Oracle checks in 7B:** O-2 … O-5 run after setup on the no-index tables, with no timing.
5. **Numbering:** files `sql/45`–`sql/48`; SQLSTATEs `LR019`–`LR021`. Indexes are built in 7C, measurements run in 7D.

## 9. Setup results (executed 13/09/2026)

**Run:** `sql/run_step7b_postgis_setup.ps1` finished with exit 0 in 82 s.

**Result: 317 PASS, 0 FAIL.** That is 313 checks plus 4 recorded INFO values.

**Files written:**
- `analysis/step7/step7b_setup_checks.txt`: every check
- `analysis/step7/step7b_setup_log.txt`: full psql output
- `analysis/step7/step7b_harness.sql`: the generated harness

### 9.1 Files created in this step

| File | Content |
|---|---|
| `scripts/step7_postgis_experiment.py` | single source of the tables, expressions, index DDL and checks; `generate [--check]`, `harness`, `static-check` |
| `sql/45_create_postgis_extension.sql` | guard, extension, gate X-01 … X-06 (`LR019`) |
| `sql/46_create_gis_tables.sql` | guard, schema, 15 tables, loads, gate O-1 / O-7 with 103 checks (`LR020`), `VACUUM (ANALYZE)` |
| `sql/47_verify_gis_setup.sql` | read-only verification, 155 checks plus 4 INFO values (`LR021`) |
| `sql/48_build_gis_indexes.sql` | the 10 Step 7C index statements. **Not run**: it refuses without `-v approved_step=7C` (`LR022`) |
| `sql/run_step7b_postgis_setup.ps1` | runner (`-HarnessOnly` stops after the rollback verification) |

### 9.2 Stages

| Stage | What was verified | Checks |
|---|---|---|
| Static R-01 … R-03 | generated files up to date; allowlist: `sql/45` 12 statement lines, `sql/46` 57 with exactly 1 read of `access_log_flat` and 1 of `access_log_jsonb`, `sql/47` no write statement, `sql/48` exactly 10 `CREATE INDEX`; ASCII | 3 PASS |
| Before B-01 … B-12 | see the detail list below | 13 PASS |
| Harness H-01, H-02, HB | one transaction ran `sql/45` (gate 6 / 6), `sql/46` (gate 103 / 103), `sql/47` (155 / 155) and E4 (PASS), then ROLLBACK. Afterwards: pre-setup state exact (no extension, no schemas) and all digests, raw integrity, write schema, fingerprints and relation counts unchanged | 9 PASS |
| `sql/45` S-45, A-45, A45 | extension created, gate 6 / 6; afterwards extensions `plpgsql 1.0 pg_catalog, postgis 3.6.2 postgis`, schemas plus `postgis` only, `public` 0 / 0 / 0, 0 event triggers, 0 `pg_db_role_setting` rows, preload empty; project digests unchanged | 15 PASS |
| `sql/46` S-46 | schema `log_regex_gis`, 15 tables loaded, gate 103 / 103, `VACUUM (ANALYZE)` of the 15 tables | 104 PASS |
| `sql/47` V-47 | read-only verification 155 / 155, plus 4 INFO values (§9.4) | 160 PASS |
| After A-01 / A-02, Z-02 … Z-12 | extensions `plpgsql` + `postgis` 3.6.2; schemas `log_regex`, `log_regex_gis`, `log_regex_json`, `log_regex_json_write`, `postgis`, `public`; `public` 0 / 0 / 0; 0 event triggers; 0 role settings; plus every before-check again | 13 PASS |

**The before-checks (B-01 … B-12), all with the expected values:**
- pre-setup state `3.6.2|none|plpgsql|true|true|0|0/0/0|0||0`
- `log_regex` digest `f8042db0…` (203 items); `log_regex_json` data digest `9e6f8831…` (10 items); Step 6D index
  digest `e20752ca…` (14 indexes, 9,510,912 bytes)
- raw integrity 10 / 10; `sql/27` 4 foreign keys; `sql/34` 38 / 38; `sql/38 final` 70 / 70
- Step 6E write schema unchanged; manifests 11 / 11 and 26 / 26
- source fingerprints `f562354d…` / `fb3bc163…`; relations 49 / 16 / 8

### 9.3 Correctness results (`sql/47`; the same O-1 / O-7 checks also passed as the `sql/46` gate)

| Group | Result |
|---|---|
| X-01 … X-06 extension | `postgis` 3.6.2 in schema `postgis`; `postgis_lib_version()` = 3.6.2; SRID 4326 = EPSG / 4326; operator classes `brin_geometry_inclusion_ops_2d`, `gist_geography_ops`, `gist_geometry_ops_2d`, `spgist_geography_ops_nd`, `spgist_geometry_ops_2d` present; `ST_MakePoint`, `ST_SetSRID`, `geography(geometry)` IMMUTABLE (`i/i/i`); schemas as expected; `public` empty; 0 event triggers |
| A-03, A-04 isolation | `log_regex_gis` = exactly the 15 tables and 15 primary keys, **no secondary index**; 0 functions, triggers, policies, rules, non-PK constraints or standalone types; 0 dependency edges between the new schemas and `log_regex` / `log_regex_json` / `log_regex_json_write`; 0 existing objects depending on PostGIS |
| O-1a row counts | all 15 tables: 5,000 rows, `log_id` set identical to `flat_numeric` (0 unmatched) |
| O-1b point existence | all 13 point sources: 4,161 non-NULL points; NULL exactly where the flat pair is not both VALID (0 mismatches). Sources: 7 geometry (4 flat tables, 2 stored JSONB columns, 1 JSONB expression) and 6 geography (3 flat tables, 2 stored JSONB columns, 1 JSONB expression) |
| O-1c coordinate values | all 13 sources: `round(ST_X, 7)` = `longitude_degrees` and `round(ST_Y, 7)` = `latitude_degrees` for 4,161 / 4,161 points |
| O-1d SRID and type | all 13 sources: SRID 4326, `GeometryType` POINT, `ST_IsValid` for 4,161 / 4,161. The 11 point columns are typed `geometry(Point,4326)` (6) and `geography(Point,4326)` (5) |
| O-1e flat = JSONB | all 13 sources byte-identical to `flat_geom` (EWKB), and geography binaries identical to `geography(flat_geom)`, for 5,000 / 5,000 rows |
| O-1f axis order | all 13 sources: the 856 points with \|longitude\| > 90 have `ST_X` = longitude and \|`ST_Y`\| ≤ 90; boundary rows 2122 = (0, 0), 2272 = (90, 180), 2280 = (−90, −180) exact |
| O-1g generated columns | `jsonb_geom`, `jsonb_geom_gist`, `jsonb_geog`, `jsonb_geog_gist`: stored generated (`s`); expression uses `st_setsrid`, `st_makepoint` with longitude before latitude, SRID 4326 (geography columns via `geography`) |
| O-7 source copies | `flat_numeric` fingerprint `f562354dbf6c155f3ed0a93da433e79c` = source; `jsonb_doc` fingerprint `fb3bc16318e6a81c7930aed2217986ea` = source; `doc` of the 5 other JSONB tables = `jsonb_doc` (5,000 / 5,000 each); `flat_numeric_btree` = `flat_numeric` (5,000 / 5,000) |

### 9.4 Oracle-readiness results (no timing; PostGIS compared with plain SQL on `flat_numeric`)

**Bounding boxes:**

| Query | PostGIS = oracle (count : md5 of sorted `log_id`s) |
|---|---|
| B1 New York box | 410 : `e8583952…` |
| B2 Europe | 416 : `7e9ec48e…` |
| B3 India | 1,580 : `e07244d9…` |
| B4 wide | 3,897 : `69112583…` |
| B5 antimeridian-crossing (two envelopes) | 0 |
| B6 polar cap | 1 : `743394be…` (`log_id` 2272) |

**Distances** (sphere and spheroid variants identical to the oracle):

| Query | Result |
|---|---|
| D1 New York 10 km | 410 |
| D2 Mumbai 500 km | 1,101 |
| D3 Reykjavik 2,000 km | 599 |
| D4 Mumbai 5,000 km | 2,059 |
| D5 (0, 180) 5,000 km | 262 |
| D6 London 1 km | 15 |
| D7 North Pole 100 km | 1 |

**Distance consistency:**

| Check | Result |
|---|---|
| O-3a sphere = haversine | max \|`ST_Distance(…, false)` − haversine\| = **0.0000473 m** over 4,161 points × 6 centres (limit 0.001 m) |
| O-4a spheroid vs sphere | max relative difference **0.452 %** (limit 0.6 %) |
| O-4b ambiguity band | 0 points within ±0.6 % of any timed radius |

**Nearest neighbours:**

| Check | Result |
|---|---|
| O-5a oracle | Reykjavik rank-10 distance 772.7 m and rank-100 distance 3,273.8 m, no ties |
| O-5b PostGIS | the 10- and 100-nearest sets by geography `<->` = the oracle sets |
| `<->` semantics (INFO) | max \|`<->` − sphere distance\| = 5.0 × 10⁻⁹ m, max \|`<->` − spheroid distance\| = 9.87 m, so geography `<->` returns the **sphere** distance. Relevant for K1 / K2 in 7D |

**Edge facts:**

| Fact | Result |
|---|---|
| E1 | (0, 180)–(0, −180): 0.000 m in geography, 360° in geometry |
| E2 | pole points (90, 180)–(90, 0): 0.000 m |
| E3 | edge point 2272 against the B6 envelope: `ST_Within` false, `ST_Intersects` true |
| E4 (harness only) | mixing SRID 4326 and 3857 raises `XX000: ST_Intersects: Operation on mixed SRID geometries (Point, 4326) != (Point, 3857)` |

**Recorded version (INFO):** `POSTGIS="3.6.2 3.6.2" [EXTENSION] PGSQL="170" GEOS="3.14.1dev-CAPI-1.20.4"
PROJ="8.2.1 …" LIBXML="2.12.5" LIBJSON="0.12" LIBPROTOBUF="1.2.1" WAGYU="0.5.0 (Internal)"`.

### 9.5 Run history and deviations

**Run history:**
1. **`-HarnessOnly` run:**
   - The harness itself passed (gates 6 / 103 / 155, E4) and rolled back; H-02 and every digest confirmed the database
     was unchanged.
   - The runner reported H-01 as FAIL: its detector matched `ERROR:` case-insensitively inside the E4 PASS text
     ("raises an error: error XX000").
   - The detector was made case-sensitive. No database change resulted.
2. **Full run:** static checks, before-checks, harness, rollback verification, real setup, verification and
   after-checks, 317 / 0.

**Deviations from the approved plan:** none. Tables, expressions, loads, source reads, checks and safeguards are as
specified. The four INFO values are recorded observations, not checks.

**Unchanged and not done:**
- `raw_access_logs`, `access_log_flat`, parser data, the Step 6 JSON / JSONB tables and indexes, the Step 6E write
  schema and the manifests are all unchanged (Z-checks).
- No Step 7C index exists. No EXPLAIN ANALYZE or spatial performance measurement was run.
- The rollback procedure of §7 remains available and was not executed.
