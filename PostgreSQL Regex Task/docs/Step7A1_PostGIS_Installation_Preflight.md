# Step 7A.1 — PostGIS Installation Preflight Checklist

**Status:** preflight only (13/09/2026). **Nothing was downloaded or installed, and the database was not modified.**
Evidence came from:
- a read-only database session (`default_transaction_read_only = on`)
- file and registry reads
- the public Stack Builder catalogue and download listings

Design: [Step7A_PostGIS_Experiment_Design.md](Step7A_PostGIS_Experiment_Design.md) (approved).

---

## 1. Verified facts

| Item | Result | Verified by |
|---|---|---|
| PostgreSQL 17 installation | **PostgreSQL 17.9** (EDB installer, registry version `17.9-3`, uninstall entry "PostgreSQL 17"), `x86_64-windows`, MSVC, 64-bit | `version()`, registry, file versions of `postgres.exe` / `psql.exe` / `pg_config.exe` |
| Location | base `C:\Program Files\PostgreSQL\17`; data directory `...\17\data`; `pg_config --pkglibdir` / `--sharedir` point to `...\17\lib` and `...\17\share` | registry, `pg_config` |
| Service | `postgresql-x64-17`: running, automatic start, account `NT AUTHORITY\NetworkService`, port 5432, UTF8 | service list, registry, `pg_settings` |
| Server start (baseline) | `2026-08-02 08:38:17.458403+05:30` (41 days of uptime) | `pg_postmaster_start_time()` |
| Stack Builder | **available:** `C:\Program Files\PostgreSQL\17\bin\stackbuilder.exe`, version 4.2.2 (437,880 bytes, 15/04/2026); its catalogue `https://www.postgresql.org/applications-v2.xml` is reachable | file check, catalogue fetch |
| Compatible PostGIS 3.x packages (Stack Builder, *Spatial Extensions*, `windows-x64`, PostgreSQL 17) | **2 offered.** `PostGIS 3.6 Bundle for PostgreSQL 17 (64 bit)` v**3.6.2** (GEOS 3.14.1, PROJ 8.2.1, GDAL 3.9.2) and `PostGIS 3.5 Bundle for PostgreSQL 17 (64 bit)` v**3.5.3** (GEOS 3.13.1, PROJ 8.2.1, GDAL 3.9.2) | catalogue |
| Installer files | `postgis-bundle-pg17x64-setup-3.6.2-1.exe`, 104,702,291 bytes, 16/03/2026. `postgis-bundle-pg17x64-setup-3.5.3-2.exe`, 124,065,253 bytes, 05/06/2025. Both under `ftp.postgresql.org/pub/postgis/pg17/…/win64/`; **no checksum files are published there** | download listings |
| Upstream guidance | postgis.net ("released versions"): the 3.6.2 bundles cover PostgreSQL 14–18; "Run StackBuilder … choose the latest PostGIS bundle option". The OSGeo download listing and the support-matrix wiki returned HTTP 403 and were not checked | postgis.net |
| Extension availability now | `pg_available_extensions`: 61 entries (md5 of the sorted name/version list `5026359a2d9433cccd75c4528c04302f`), **no `postgis*`, `address_standardizer`, `sfcgal`, `topology` or `tiger`** | catalog |
| Installed in `postgresql_regex_task` | `plpgsql 1.0` only. `geometry` / `geography` types: 0. Schemas `postgis` and `log_regex_gis`: absent. `public`: 0 relations / 0 functions / 0 types. Event triggers: 0 | catalog |
| PostGIS files | none: no `postgis*.control`, no `postgis*` library, no `shp2pgsql` / `raster2pgsql`, no PostGIS uninstall entry, no `GDAL` / `PROJ` / `POSTGIS` environment variables | file, registry and environment checks |
| Preload | `shared_preload_libraries`, `session_preload_libraries` and `local_preload_libraries` all empty; `dynamic_library_path = $libdir` | `pg_settings` |
| Machine | Windows 11 Pro 64-bit, on AC power (47 %), 307.2 GB free on C:. User `AzureAD\AkashMore` is a member of Administrators, but the current session is **not elevated** | CIM, identity check |
| Cluster activity | 5 databases; 4 other client sessions (pgAdmin, other databases), all idle | `pg_database`, `pg_stat_activity` |

## 2. Exact installation prerequisite

1. **Install exactly one bundle into the existing PostgreSQL 17 installation** (`C:\Program Files\PostgreSQL\17`, service
   `postgresql-x64-17`, port 5432):
   - **Recommended:** *PostGIS 3.6 Bundle for PostgreSQL 17 (64 bit)*, v3.6.2. It is the latest bundle offered, which
     matches the postgis.net advice.
   - **Alternative:** v3.5.3. Your choice is recorded, and Step 7B pins the version it finds.
2. **Needed by the experiment: only the `postgis` extension.** The bundle also ships raster, topology, SFCGAL, the tiger
   geocoder, address_standardizer, pgRouting, ogr_fdw, pgPointcloud, h3-pg, MobilityDB (and pgSphere in 3.6). These only
   become *available*; the experiment creates none of them.
3. **Access and environment:**
   - administrator elevation (UAC), because files are written under `C:\Program Files`
   - internet access for the Stack Builder download
   - AC power
4. **No PostgreSQL configuration change** (no preload entries). A service restart should not be needed for
   `CREATE EXTENSION`; if the installer restarts the service, that is recorded.

## 3. Installation checklist (you perform it; nothing is automated)

**Before:**
- [ ] AC power connected; no other work running against the server.
- [ ] Note the start time.

**During:**
- [ ] Start *Application Stack Builder* **as administrator** (`C:\Program Files\PostgreSQL\17\bin\stackbuilder.exe`).
- [ ] Select the installation *PostgreSQL 17 (x64) on port 5432*.
- [ ] Under *Spatial Extensions*, tick **only** the chosen bundle (3.6.2 recommended), then download.
- [ ] Before running the installer, confirm its file name and size match §1 (3.6.2: 104,702,291 bytes; 3.5.3:
      124,065,253 bytes). Stop if they differ.
- [ ] In the installer:
  - keep the target directory `C:\Program Files\PostgreSQL\17`
  - **do not** create a sample or spatial database if one is offered
  - decline optional environment-variable prompts (e.g. `GDAL_DATA`, `PROJ_LIB`, out-of-database raster or GDAL
    driver settings); the experiment does not use raster
  - postgis.net does not document these screens, so **write down every option shown and your choice**
- [ ] Do **not** run `CREATE EXTENSION` or any SQL, in pgAdmin or elsewhere.

**After:**
- [ ] Finish, and note the end time and whether the installer restarted the service.

## 4. Post-installation gate G-EXT (read-only; run only after your go-ahead)

| Check | Expected |
|---|---|
| V-01 service | `postgresql-x64-17` running. `pg_postmaster_start_time()` = `2026-08-02 08:38:17.458403+05:30`; a change is recorded as a restart |
| V-02 server | `version()` still PostgreSQL 17.9, `x86_64-windows`, 64-bit |
| V-03 availability | `pg_available_extensions` lists `postgis` with `default_version` = the installed bundle (3.6.2 or 3.5.3); the new list is recorded (was 61, md5 `5026359a…`) |
| V-04 files | `share\extension\postgis.control` and the PostGIS library in `lib` present |
| V-05 database untouched | installed extensions `plpgsql` only; 0 `geometry` / `geography` types; no `postgis` / `log_regex_gis` schema; `public` 0 / 0 / 0; 0 event triggers; still 5 databases |
| V-06 configuration | preload settings still empty |
| V-07 project data unchanged | `log_regex` digest `f8042db0…` (203 items); `log_regex_json` data digest `9e6f8831…` (10 items); Step 6D index digest `e20752ca…`; `sql/34` 38 / 38; `sql/38 final` 70 / 70; `sql/42` 41 / 41; Step 6C / 6D manifests |

## 5. Stop conditions

- Stack Builder offers no bundle for PostgreSQL 17 x64, or the downloaded file name or size differs from §1.
- The installer targets a different directory or PostgreSQL version.
- After installation:
  - `postgis` is not available, or its version differs from the chosen bundle
  - any database object or extension was created
  - a digest or verification changed

In those cases, stop and report. Removal of the bundle is a Windows uninstall outside this project.

## 6. Decisions for you

1. **Bundle:** 3.6.2 (recommended) or 3.5.3.
2. **Installation:** you install it with administrator rights, following §3.
3. **Next:** approval to run the read-only gate G-EXT (§4), then Step 7B (extension in schema `postgis`, rolled-back
   harness first).
