# Step 7A.2 — PostGIS Post-Installation Verification

**Status:** re-verified on 13/09/2026, after the manual installation of the PostGIS 3.6.2 bundle. The check was
read-only. Stopped for review.

**Nothing was created, installed or modified during verification.**
- No `CREATE EXTENSION`, not even inside a rolled-back transaction.
- No schema, table or index; no data written; no performance test.
- Every database session ran with `default_transaction_read_only = on`.
- The only non-query command was a session-level `LOAD` of the PostGIS library (V-04b). It changes no catalog; the
  extension and function counts were identical before and after.

## Result

| Area | Result |
|---|---|
| PostgreSQL 17 on port 5432: version, service | **PASS** |
| PostGIS available for PostgreSQL 17 | **PASS** |
| Installed PostGIS version is 3.6.2 | **PASS**: bundle 3.6.2; `postgis` extension version 3.6.2 available (not created) |
| Required PostGIS files and libraries | **PASS** |
| `postgis` extension can be created (not attempted) | **PASS** (all preconditions met) |
| Project data, schemas, tables, indexes unchanged | **PASS** |
| `raw_access_logs` integrity | **PASS: 10 / 10** |
| Step 6 JSON/JSONB verification | **PASS**: `sql/34` 38 / 38, `sql/38 final` 70 / 70, digests and manifests unchanged |
| **Installation prerequisite for Step 7B** | **SATISFIED** |

One deviation from the Step 7A.1 checklist is recorded in §3 (installer environment variables). It does not block
Step 7B.

## 1. Server and PostGIS installation

| ID | Check | Actual | Result |
|---|---|---|---|
| V-01 | service and restart | `postgresql-x64-17` running, automatic, `NetworkService`. Start time `2026-08-02 08:38:17.458403+05:30` = baseline; no service-control events for PostgreSQL in the last day, so **the installation did not restart the server** | PASS |
| V-02 | server | `PostgreSQL 17.9 on x86_64-windows, compiled by msvc-19.44.35225, 64-bit`, port 5432 | PASS |
| V-03 | availability and version | `pg_available_extensions`: **77** entries (baseline 61; md5 now `4eca59b0d5cc6a6e070cc42c389923ae`). `postgis`: `default_version` **3.6.2**, `installed_version` none, "PostGIS geometry and geography spatial types and functions". Version row 3.6.2: `superuser = true`, `trusted = false`, `relocatable = false`, no required extensions. 2 `postgis` version rows (install and upgrade targets) | PASS |
| V-03b | other newly available extensions (bundle; none created) | `address_standardizer`, `address_standardizer_data_us`, `postgis_raster`, `postgis_sfcgal`, `postgis_tiger_geocoder`, `postgis_topology` (all 3.6.2); `h3` / `h3_postgis` 4.1.4; `mobilitydb` / `mobilitydb_datagen` 1.3.0; `ogr_fdw` 1.1; `pg_sphere` 1.5.2; `pgrouting` 4.0.1; `pointcloud` / `pointcloud_postgis` 1.2.5; `pltcl` / `pltclu` 1.0 | recorded |
| V-04 | files | `share\extension\postgis.control` (`default_version = '3.6.2'`, `module_pathname = '$libdir/postgis-3'`, `relocatable = false`); `postgis--3.6.2.sql` 7,478,083 bytes; 126 `postgis--*.sql` install / upgrade scripts. Libraries `postgis-3.dll` (1,778,176 bytes), `postgis_raster-3.dll`, `postgis_sfcgal-3.dll`, `postgis_topology-3.dll`. Dependencies in `bin`: `libgeos.dll`, `libgeos_c.dll`, `libproj_8_2.dll`, `libgdal-35.dll`, `libsqlite3-0.dll`, `libprotobuf-c-1.dll`, `libSFCGAL.dll`. Utilities `shp2pgsql`, `pgsql2shp`, `raster2pgsql` | PASS |
| V-04a | installer registration | uninstall entry "PostGIS Bundle 3.6.2 for PostgreSQL x64 17 (remove only)" next to "PostgreSQL 17 17.9-3" | PASS |
| V-04b | library loads | `LOAD '$libdir/postgis-3'` succeeded, so the library and its GEOS / PROJ dependencies resolve. Extensions (`plpgsql`) and `st_*` functions (0) were unchanged before and after | PASS |
| V-04c | definitions needed by the Step 7A design (in `postgis--3.6.2.sql`) | functions `ST_MakePoint(float8, float8)`, `ST_SetSRID(geom geometry, srid integer)`, `geography(geometry)`, `ST_DWithin` / `ST_Distance` (geography), `ST_DistanceSphere`, `ST_MakeEnvelope`, `ST_Intersects`, `ST_Within`, `ST_X`, `ST_Y`, `ST_AsBinary`, `postgis_full_version` all defined. `ST_MakePoint`, `ST_SetSRID` and `geography(geometry)` are **IMMUTABLE**, so the JSONB expression indexes are possible. Operator classes `gist_geometry_ops_2d`, `gist_geography_ops`, `spgist_geometry_ops_2d`, `spgist_geography_ops_nd` and `brin_geometry_inclusion_ops_2d` all defined, so configurations G-1 … G-3 and Y-1 / Y-2 are feasible. `spatial_ref_sys` includes the EPSG 4326 row | PASS (to be re-confirmed from the catalog after creation in 7B) |
| V-05a | extension creatable (not attempted) | connected as superuser `postgres`; PostGIS 3.6.2 requires superuser and no other extension; control file, script and library present; the target schema `postgis` and `log_regex_gis` do not exist yet; no conflicting `geometry` / `geography` types or `st_*` functions | PASS |
| V-06 | preload configuration | `shared_preload_libraries`, `session_preload_libraries`, `local_preload_libraries` empty; `dynamic_library_path = $libdir`; PostGIS needs no preload | PASS |

## 2. Database and project data

| ID | Check | Actual | Result |
|---|---|---|---|
| V-05b | database objects | installed extensions `plpgsql 1.0` only; 0 `geometry` / `geography` types; 0 `st_*` functions; 0 `spatial_ref_sys`; schemas `log_regex`, `log_regex_json`, `log_regex_json_write`, `public`; `public` 0 relations / 0 functions / 0 types; 0 event triggers; 5 databases, unchanged (no sample spatial database created) | PASS |
| G-01 | `log_regex` digest (raw data, parser objects and runs, `access_log_flat`, answer key: every function, view, column, constraint, index, trigger and all rows) | `f8042db0318656b5929c86ea1f7888d4` over 203 items = expected | PASS |
| R-01 | `raw_access_logs` integrity: `log_regex.verify_raw_access_logs()` | **10 / 10 passed**: row count 5,000; `log_id` range 1..5,000, distinct and contiguous; NULL rows 1; empty rows 1; 1,194,267 characters; 1,194,874 UTF-8 bytes; 0 rows differing from their fingerprint; dataset digest `1bcff42a6cd6634bd722064b629a0088dbbd7c67ac5276d013c505ac3fb06275` = load audit; 3 / 3 read-only guard triggers enabled | PASS |
| R-02 | flat table | 5,000 rows; 4,161 both-VALID coordinate pairs; `sql/27`: exactly the 4 expected foreign keys, all validated | PASS |
| G-02 | `log_regex_json` data digest (Step 6B tables, constraints, comments, documents) | `9e6f883112c4a01781bdce5cf9bf3a28` over 10 items = expected | PASS |
| G-03 | Step 6D index digest (definitions and sizes) | `e20752ca02d09e89281503569650d0ce` over 14 indexes, 9,510,912 bytes = expected; 14 / 14 valid and ready | PASS |
| G-04 | Step 6 tables | 5,000 / 5,000 rows; heap 10,240,000 / 8,036,352 bytes; inserted / updated / deleted 5000/0/0 on both tables | PASS |
| V-34 | `sql/34` (read-only session) | JSON experiment check PASSED: all 38 checks | PASS |
| V-38 | `sql/38 -v phase=final` (read-only session) | JSON index phase final check PASSED: all 70 checks | PASS |
| G-05 | Step 6E write schema | the 8 designed relations only; canonical md5 `aeaef323…` = expected; expected updates 238 / 238 / 5,000; write tables empty | PASS |
| M-01 / M-02 | Step 6C and Step 6D output manifests | 11 / 11 and 26 / 26 files match (0 mismatches) | PASS |
| — | relations per project schema | `log_regex` 49, `log_regex_json` 16, `log_regex_json_write` 8 (unchanged) | recorded |
| — | other client sessions | 4, all idle | recorded |

**Scripts deliberately not run, and their replacements:**

| Script | Why not | Covered instead by |
|---|---|---|
| `sql/04` | creates temporary tables and deliberately attempts 11 modifications of the raw table | its integrity function (R-01) |
| `sql/42` | its index-definition checks create indexes inside a rolled-back transaction | G-05 |

## 3. Deviation recorded: installer environment variables

The installer set four machine-level environment variables (none at user level). The Step 7A.1 checklist had asked to
decline these prompts:

| Variable | Value |
|---|---|
| `GDAL_DATA` | `C:\Program Files\PostgreSQL\17\gdal-data` |
| `PROJ_LIB` | `C:\Program Files\PostgreSQL\17\share\contrib\postgis-3.6\proj` |
| `POSTGIS_ENABLE_OUTDB_RASTERS` | `1` |
| `POSTGIS_GDAL_ENABLED_DRIVERS` | `GTiff PNG JPEG GIF XYZ DTED USGSDEM AAIGrid` |

Assessment:
- **Raster settings:** the two `POSTGIS_*` variables affect only `postgis_raster`, which the experiment does not use.
- **Data paths:** `GDAL_DATA` / `PROJ_LIB` point PostGIS and GDAL at their data files. The Step 7A design uses no
  projection (`ST_Transform`) and no raster.
- **Running server:** it was not restarted, so these variables apply only to PostgreSQL processes started later, such
  as after the next service restart.
- **Project data:** unaffected.
- **Step 7B:** not blocked. The values are recorded so they can be removed (as an administrator) if not wanted.

## 4. Prerequisite status and next step

The Step 7A.1 prerequisite is **satisfied**: PostGIS 3.6.2 is installed into `C:\Program Files\PostgreSQL\17` and is
available to the PostgreSQL 17 server on port 5432. The server was not restarted, and no project data changed.

Step 7B has not started and awaits approval:
1. extension `postgis` 3.6.2 created in schema `postgis`, rolled-back harness first
2. schema `log_regex_gis` and its tables
3. the O-1 / O-7 gates
4. the before/after proofs of Step 7A §10

## 5. History

| Date | Run | Outcome |
|---|---|---|
| 13/09/2026 | first verification, after the reported installation | FAIL: no PostGIS files, no uninstall entry, `pg_available_extensions` unchanged (61), `LOAD` failed; project data PASS. The installer had not completed on this machine |
| 13/09/2026 | capability check for an automated installation | not possible: the session is not elevated (Medium integrity) and UAC requires consent on the secure desktop. No installation attempted; manual steps given |
| 13/09/2026 | this re-verification, after the manual installation | all checks PASS; prerequisite satisfied; one recorded deviation (§3) |
