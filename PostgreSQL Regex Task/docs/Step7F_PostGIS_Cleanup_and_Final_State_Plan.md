# Step 7F — PostGIS Cleanup and Final Integrity Plan

**Status:** plan approved with **Option A** and **executed 13/09/2026**:
- **Result:** 343 PASS / 0 FAIL (`analysis/step7/step7f_cleanup_checks.txt`); results in §11.
- **Dropped:** exactly the 10 Step 7C secondary indexes (with `sql/52`, in one transaction, after a rolled-back
  harness).
- **Kept:** the 15 `log_regex_gis` tables, the `postgis` schema and PostGIS 3.6.2.
- **Unchanged:** project data and Step 6 objects.
- **Not run:** no performance test.
- **Out of scope:** the overall project conclusion had not been started at the time of this step; it followed in
  [Final_Project_Conclusion.md](Final_Project_Conclusion.md).

Sections 1–10 are the approved plan as written. §1 is the read-only snapshot taken before approval.

**Based on:** Steps 7A–7E, in particular:
- the Step 7B rollback procedure ([Step7B_PostGIS_Setup_Preflight.md](Step7B_PostGIS_Setup_Preflight.md) §7)
- the Step 7C cleanup script `sql/52_drop_gis_indexes.sql`
- the Step 7C integrity checks ([Step7C_Spatial_Index_Experiment.md](Step7C_Spatial_Index_Experiment.md) §2)
- the approved final conclusion ([Step7E_PostGIS_Final_Conclusion.md](Step7E_PostGIS_Final_Conclusion.md))

---

## 1. Current state (read-only snapshot, 13/09/2026 11:09 IST)

| Item | Value |
|---|---|
| Extensions | `plpgsql` 1.0 in `pg_catalog`; `postgis` 3.6.2 in `postgis` (available 3.6.2, installed 3.6.2) |
| Schemas | `log_regex`, `log_regex_gis`, `log_regex_json`, `log_regex_json_write`, `postgis`, `public` |
| Relations per schema | `log_regex` 49, `log_regex_json` 16, `log_regex_json_write` 8, `log_regex_gis` 40, `postgis` 6, `public` 0 |
| Schema `postgis` | 1 table (`spatial_ref_sys`, 8,500 rows), 2 views, 776 functions, 24 types |
| `log_regex_gis` | 15 tables, 15 primary keys, **10 secondary indexes** (all valid; 2,678,784 bytes, 327 pages); schema total 52,887,552 bytes (heap + TOAST 48,218,112; all indexes 4,669,440) |
| The 10 indexes | `flat_numeric_btree_lat_lon_idx` 180,224 · `flat_geom_gist_idx` 212,992 · `flat_geom_spgist_idx` 278,528 · `flat_geom_brin_idx` 24,576 · `flat_geog_gist_idx` 393,216 · `flat_geog_spgist_idx` 376,832 · `jsonb_doc_expr_geom_gist_idx` 212,992 · `jsonb_doc_expr_geog_gist_idx` 393,216 · `jsonb_geom_gist_idx` 212,992 · `jsonb_geog_gist_idx` 393,216 bytes |
| Dependencies on PostGIS outside `postgis` / `log_regex_gis` | 0 objects; 0 columns of PostGIS types |
| `public`, event triggers, role settings, preload | 0 / 0 / 0; 0; 0; empty |
| Database size | 231,921,331 bytes |
| Other client sessions | 4, all idle |

**The last verified integrity state is the Step 7C after-checks** (943 PASS / 0 FAIL / 0 FLAG). Nothing was written to
the database afterwards: Steps 7D and 7E were document-only, and this snapshot was read-only.

## 2. Decisions and recommendations

| # | Question | Recommendation | Reason | Alternative (documented, not recommended) |
|---|---|---|---|---|
| 1 | Which of the 10 Step 7C indexes should be dropped? | **All 10** | See below | Keep some or all indexes (Option C, §3) |
| 2 | Retain or remove the `log_regex_gis` tables? | **Retain all 15 tables** (Option A) | See below | Remove them (Option B, §7) |
| 3 | Should the PostGIS extension remain installed? | **Yes** (Option A) | See below | Remove it together with the tables (Option B) |

**Why drop all 10 indexes:**
- **The experiment is concluded.** The measurements, verdicts and conclusions are recorded in 7C–7E.
- **Exact rebuild is available.** `sql/49` rebuilds all 10 from the unchanged `sql/48` statements.
- **Back to the verified baseline.** Dropping them returns `log_regex_gis` to the Step 7B state, which the existing
  `sql/47` (155 checks, asserting 0 secondary indexes) and `sql/50 phase before` (113 checks) verify without new code.
- **No partial set.** Keeping some indexes would leave a state that no existing verification script describes.

**Why retain the 15 tables:**
- **Reproducibility.** The Step 7B oracles and the Step 7C experiment (`sql/47`, `sql/49`–`sql/51`) can be re-verified
  or rerun without rebuilding the data.
- **Isolation.** The tables are in their own schema with 0 dependency edges to existing schemas.
- **Cost.** About 50.2 MB (§8).
- **Final decision later.** Removal can still be decided at the overall project conclusion.

**Why keep the PostGIS extension:**
- **Required by the tables.** The retained tables have `geometry` / `geography` columns and generated expressions that
  depend on it. `DROP EXTENSION postgis` would fail without `CASCADE`, and with `CASCADE` it would destroy them.
- **No other dependents.** No object outside `postgis` / `log_regex_gis` depends on PostGIS.

**Execution safeguards (both options):**
- a rolled-back harness first
- one transaction for the real change
- `lock_timeout = 5s`
- before- and after-integrity checks

Recommended final state: **Option A = drop the 10 indexes; keep the 15 tables, schema `log_regex_gis` and the extension
`postgis`.**

## 3. Options at a glance

| Option | Database change | Final `log_regex_gis` | Extension | Undo |
|---|---|---|---|---|
| **A (recommended)** | `DROP INDEX` of the 10 designed names + `ANALYZE` of the 9 affected tables (`sql/52`) | 15 tables + 15 primary keys, 0 secondary indexes (= Step 7B state) | kept | rerun `sql/49 -v approved_step=7C`, verify `sql/50 phase after` |
| B (alternative) | Option A, then `DROP SCHEMA log_regex_gis CASCADE; DROP EXTENSION postgis; DROP SCHEMA postgis;` | absent | removed (binaries stay installed) | rerun `sql/45`, `sql/46`, `sql/47`; for indexes also `sql/49` |
| C (not recommended) | none | 15 tables + 25 indexes | kept | — |

## 4. Objects that must remain untouched (all options)

| Object | How it is proven unchanged (before and after) | Expected value |
|---|---|---|
| `log_regex.raw_access_logs` | `log_regex` digest (rows of every table, functions, views, constraints, indexes, triggers); `log_regex.verify_raw_access_logs()` | `f8042db0318656b5929c86ea1f7888d4` over 203 items; 10 / 10 checks passed |
| `log_regex.access_log_flat` | same digest; source fingerprint; `sql/27` | flat fingerprint `f562354dbf6c155f3ed0a93da433e79c`; exactly 4 validated foreign keys |
| Parser objects, parser runs, answer key (`log_regex`) | `log_regex` digest; relation count | 203 items; `log_regex` = 49 relations |
| Step 6B / 6D JSON / JSONB tables | `log_regex_json` data digest; JSONB source fingerprint; `sql/34` | `9e6f883112c4a01781bdce5cf9bf3a28` over 10 items; `fb3bc16318e6a81c7930aed2217986ea`; 38 / 38 |
| Step 6D indexes | Step 6D index digest; `sql/38 phase final` | `e20752ca02d09e89281503569650d0ce` over 14 indexes, 9,510,912 bytes; 70 / 70 |
| Step 6E write schema | relation list, canonical md5, expected-update counts, empty `_w` tables | `…|aeaef32371fa8143c088d4fdce9f6e0d|UA-1:238 UA-2:238 UA-3:5000|0/0` (exact string in the Step 7C runner); `log_regex_json_write` = 8 relations |
| Manifests | SHA-256 verification | Step 6C `analysis/step6/step6d_baseline_step6c_sha256.txt` 11 / 11; Step 6D `analysis/step6/step6e_baseline_step6d_sha256.txt` 26 / 26; Step 7B `analysis/step7/step7c_baseline_step7b_sha256.txt` 14 / 14 |
| Sample data files | new Step 7F manifest (§9) | `data/raw_access_logs.csv`, `data/expected_fields.csv`, `data/dataset_manifest.json` unchanged |
| Database-wide | state query | `public` 0 / 0 / 0; 0 event triggers; 0 `pg_db_role_setting` rows; `shared_preload_libraries` empty |
| Option A only: the 15 `log_regex_gis` tables | per-table data fingerprints (`sql/50` `@@FP`) equal to the Step 7C values (§8) | unchanged |

**Outside the database:** Step 7F does not change these.
- the PostGIS 3.6.2 binaries in `C:\Program Files\PostgreSQL\17`
- the four installer environment variables (Step 7A.2 §3)
- the `postgresql-x64-17` service (no restart)
- any other database on the server

## 5. Before- and after-integrity checks (exact)

All checks are PASS / FAIL and are written to `analysis/step7/step7f_cleanup_checks.txt`. Any FAIL stops the runner
before the next writing stage.

### 5.1 Static checks (before any database access)

| ID | Check | Expected |
|---|---|---|
| R-01 | `python -B scripts/step7_postgis_experiment.py generate --check` | `sql/45`–`sql/48` up to date |
| R-02 | `python -B scripts/step7c_spatial_index_experiment.py generate --check` | `sql/49`–`sql/52` up to date (`sql/52` unchanged, not edited by hand) |
| R-03 | `python -B scripts/step7c_spatial_index_experiment.py static-check` | PASSED; `sql/52` = exactly 10 `DROP INDEX IF EXISTS` of the designed names + `ANALYZE` of the 9 affected tables |
| R-04 | new Step 7F files ASCII; Option B script (if chosen) contains exactly its 3 statements (§7) | PASS |
| M-01 | Step 6C / 6D / 7B manifests | 11 / 11, 26 / 26, 14 / 14 |
| M-02 | create the Step 7F manifest (§9), then verify it | 32 / 32 |

### 5.2 Before checks (read-only sessions)

| ID | Check | Expected |
|---|---|---|
| F-01 | extensions, schemas, `public`, event triggers, role settings, preload | `plpgsql 1.0 pg_catalog, postgis 3.6.2 postgis|log_regex,log_regex_gis,log_regex_json,log_regex_json_write,postgis,public|0/0/0|0|0|` |
| F-02 | `log_regex_gis` tables \| primary keys \| secondary indexes \| names | `15|15|10|flat_geog_gist_idx,flat_geog_spgist_idx,flat_geom_brin_idx,flat_geom_gist_idx,flat_geom_spgist_idx,flat_numeric_btree_lat_lon_idx,jsonb_doc_expr_geog_gist_idx,jsonb_doc_expr_geom_gist_idx,jsonb_geog_gist_idx,jsonb_geom_gist_idx` |
| F-03 | objects outside `postgis` / `log_regex_gis` depending on PostGIS; PostGIS-type columns elsewhere | 0; 0 |
| F-04 | other client sessions not idle (includes `idle in transaction`) | 0 |
| B-02 … B-12 | the Step 7C project checks: `log_regex` digest, `log_regex_json` digest, Step 6D index digest, raw integrity, `sql/27`, `sql/34`, `sql/38 final`, Step 6E write schema, source fingerprints, relations 49 / 16 / 8 | values of §4 |
| F-05 | `sql/50 -v phase=after` (read-only): 10 index definitions, recorded oracles, 202-row matrix in 3 plan modes | `sql/50 phase after PASSED: all 745 checks`; C-03 606 / 606 |
| F-06 | data fingerprints of the 15 tables (from F-05) | equal to the Step 7C values (§8) |
| F-07 | `pg_class` / `pg_statistic` digest of `log_regex_gis` | recorded; expected to equal the Step 7C after-state (`559fc36d…` over 40 relations; 38 statistic rows `add13686…`) |

### 5.3 After checks

**Option A** (read-only sessions):

| ID | Check | Expected |
|---|---|---|
| Z-01 | as F-01 | unchanged string |
| Z-02 | as F-02 | `15|15|0|` |
| Z-03 | relations per schema | `log_regex_gis` 30, `postgis` 6, `log_regex` 49, `log_regex_json` 16, `log_regex_json_write` 8, `public` 0 |
| Z-04 | as F-03 | 0; 0 |
| Z-05 | `sql/47` (Step 7B verification, includes "no secondary index", construction checks and oracles) | `sql/47 PostGIS setup verification PASSED: all 155 checks` |
| Z-06 | `sql/50 -v phase=before` | `sql/50 phase before PASSED: all 113 checks` |
| Z-07 | data fingerprints (from Z-06) | equal to F-06 |
| Z-08 … Z-18 | B-02 … B-12 again | values of §4 |
| Z-19 | manifests Step 6C, 6D, 7B, 7F | 11 / 11, 26 / 26, 14 / 14, 32 / 32 |
| Z-20 | `python -B scripts/step7_postgis_experiment.py generate --check` and the 7C `generate --check` | up to date |
| INFO | `pg_class` / `pg_statistic` digest; pg_statistic row count (expected 36, the expression statistics of the two dropped expression indexes are removed); `log_regex_gis` total bytes (expected about 50.2 MB); database size | recorded, not pass criteria |

**Option B** (read-only sessions):

| ID | Check | Expected |
|---|---|---|
| ZB-01 | the Step 7B pre-setup state B-01 | `3.6.2|none|plpgsql|true|true|0|0/0/0|0||0` (postgis available, not installed; only `plpgsql`; `postgis` and `log_regex_gis` absent; 0 `geometry` / `geography` types; `public` 0 / 0 / 0; 0 event triggers; empty preload; 0 non-idle sessions) |
| ZB-02 | schemas | `log_regex,log_regex_json,log_regex_json_write,public` |
| ZB-03 … ZB-13 | B-02 … B-12 again | values of §4 |
| ZB-14 | manifests Step 6C, 6D, 7B, 7F | 11 / 11, 26 / 26, 14 / 14, 32 / 32 |

## 6. Cleanup procedure — Option A (recommended)

**Planned runner:** `sql/run_step7f_cleanup.ps1` (not created yet):
- **Switches:** `-HarnessOnly` and `-Option A|B`.
- **Credentials:** from the environment, exactly as in the Step 7B / 7C runners.
- **Timing:** no timing is measured, so AC power is not required.

| Stage | Action | Pass condition |
|---|---|---|
| 1 | Static checks R-01 … R-04, manifests M-01 / M-02 | all PASS |
| 2 | Before checks F-01 … F-07, B-02 … B-12 | all PASS |
| 3 | **Rolled-back harness** (§6.1) | H-01 … H-06 PASS |
| 4 | **Real cleanup** (§6.2) | H-real PASS |
| 5 | After checks Z-01 … Z-20 | all PASS |
| 6 | Write `analysis/step7/step7f_cleanup_checks.txt` and `step7f_cleanup_log.txt`; add a results section to this document; update the README status | — |

### 6.1 Rolled-back harness

**Harness file:** `analysis/step7/step7f_harness.sql`, written by the runner. It reuses the existing scripts unchanged;
none of them contains transaction control.

```sql
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
\set confirm_cleanup yes
\i sql/52_drop_gis_indexes.sql
\i sql/47_verify_gis_setup.sql
\set phase before
\i sql/50_verify_gis_index_phase.sql
DO $h$ BEGIN RAISE NOTICE 'Step 7F harness PASSED: 10 drops, ANALYZE, sql/47 and sql/50 before inside one transaction'; END $h$;
ROLLBACK;
```

**Harness checks:**

| ID | Check | Expected |
|---|---|---|
| H-01 | harness exit code; `sql/47 … PASSED: all 155 checks`; `sql/50 phase before PASSED: all 113 checks`; harness notice; no `WARNING … FAIL` or `ERROR:` (case-sensitive) | all present, 0 failures |
| H-02 | fingerprints inside the harness | equal to F-06 |
| H-03 | after `ROLLBACK`: F-02 | still `15|15|10|…` (all 10 names) |
| H-04 | after `ROLLBACK`: `sql/50 -v phase=after` (read-only) | 745 / 745, fingerprints equal to F-06 |
| H-05 | after `ROLLBACK`: `pg_class` / `pg_statistic` digest | equal to F-07 |
| H-06 | after `ROLLBACK`: B-02 … B-12 and F-01 | unchanged |

### 6.2 Real cleanup (one transaction)

```text
PGOPTIONS='-c lock_timeout=5s'
psql -X -v ON_ERROR_STOP=1 --single-transaction -d postgresql_regex_task \
     -v confirm_cleanup=yes -f sql/52_drop_gis_indexes.sql
```

- **Atomicity:** `--single-transaction` wraps the 10 `DROP INDEX IF EXISTS` and the 9 `ANALYZE` statements in one
  transaction. With `ON_ERROR_STOP` any error rolls everything back. `ANALYZE` is allowed inside a transaction block.
- **Guard:** `sql/52` refuses without `-v confirm_cleanup=yes` (`LR026`).
- **Locks:** `DROP INDEX` takes an `ACCESS EXCLUSIVE` lock on each of the 9 tables for the transaction. F-04 requires 0
  non-idle sessions, and `lock_timeout` stops the run instead of waiting.
- **H-real:** exit code 0, no `ERROR:`; F-02 immediately afterwards is `15|15|0|`.

### 6.3 Failure handling and rollback for Option A

| Situation | Action |
|---|---|
| A static or before check fails | stop; nothing written |
| Harness fails | stop; the transaction was rolled back (H-03 … H-06 are still run and reported) |
| Real cleanup fails | nothing committed (single transaction); run F-02 and F-05 to confirm the Step 7C state; report |
| After checks fail with the indexes dropped | stop and report. To restore the Step 7C state: `psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -v approved_step=7C -f sql/49_build_measure_gis_indexes.sql` (its guard requires 0 secondary indexes), then `sql/50 -v phase=after` 745 / 745 and B-02 … B-12. The rebuild re-creates the identical 10 definitions; SP-GiST and geography GiST sizes may differ slightly (Step 7C §3), and its build timings are not new results |

## 7. Alternative procedure — Option B (full removal of the Step 7 database objects)

Only if Option B is approved instead of A.
- **Order:** Option A (§6) runs first, so the 10 indexes are already gone and verified.
- **Script:** a new single-transaction script `sql/53_remove_postgis_objects.sql` (planned, not created).
- **Guard (`LR027`):** it refuses without `-v confirm_removal=yes`, and refuses unless all of these hold:
  - F-01 still matches
  - `log_regex_gis` holds exactly 15 tables + 15 primary keys
  - F-03 = 0 / 0

```sql
DROP SCHEMA log_regex_gis CASCADE;   -- the 15 tables, their primary keys and TOAST relations only
DROP EXTENSION postgis;
DROP SCHEMA postgis;
```

| Stage | Action | Pass condition |
|---|---|---|
| B1 | Before: all Option A after checks (Z-01 … Z-20) | PASS |
| B2 | Record the `DROP SCHEMA … CASCADE` object list inside a rolled-back harness: `BEGIN;` the three statements; ZB-01 / ZB-02 inside; `ROLLBACK;` | NOTICE list = exactly the 15 tables (dependent objects: their primary keys only); ZB-01 / ZB-02 PASS inside; after `ROLLBACK` Z-01, Z-02, Z-05 PASS |
| B3 | Real run: `psql --single-transaction -v confirm_removal=yes -f sql/53_remove_postgis_objects.sql` | exit 0 |
| B4 | After checks ZB-01 … ZB-14 | all PASS |

**Rollback for Option B** (re-creates the verified Step 7B state from the unchanged sources):
1. `sql/45_create_postgis_extension.sql` (guard `LR019` requires the ZB-01 state).
2. `sql/46_create_gis_tables.sql` (reads `access_log_flat` and `access_log_jsonb` once each; gates O-1 / O-7).
3. `sql/47` 155 / 155 and `sql/50 phase before` 113 / 113, with fingerprints equal to §8.
4. For the Step 7C state, also `sql/49 -v approved_step=7C` and `sql/50 phase after`.

**Outside the database:** removing the PostGIS binaries or the installer environment variables is an administrator
action outside the project. It is **not** part of Option B.

## 8. Final expected database, schema and index state

**Option A (recommended):**

| Item | Final value |
|---|---|
| Database | `postgresql_regex_task` |
| Extensions | `plpgsql` 1.0 (`pg_catalog`), `postgis` 3.6.2 (`postgis`) |
| Schemas | `log_regex`, `log_regex_gis`, `log_regex_json`, `log_regex_json_write`, `postgis`, `public` |
| Relations per schema | `log_regex` 49; `log_regex_json` 16; `log_regex_json_write` 8; `log_regex_gis` 30; `postgis` 6; `public` 0 |
| `log_regex_gis` tables | `flat_numeric`, `flat_numeric_btree`, `flat_geom`, `flat_geom_gist`, `flat_geom_spgist`, `flat_geom_brin`, `flat_geog`, `flat_geog_gist`, `flat_geog_spgist`, `jsonb_doc`, `jsonb_doc_expr`, `jsonb_geom`, `jsonb_geom_gist`, `jsonb_geog`, `jsonb_geog_gist` (5,000 rows each) |
| `log_regex_gis` indexes | the 15 primary keys `<table>_pkey`; **0 secondary indexes** |
| `log_regex_gis` data fingerprints | `flat_numeric`, `flat_numeric_btree`: `aa8e40226347b042954cb74662f2c990`; the seven flat geometry / geography tables: `9f32c783e7ea53beefdf1efee8be7aa5`; `jsonb_doc`, `jsonb_doc_expr`: `66e5ca3a787032464c934cd2336366f1`; `jsonb_geom`, `jsonb_geom_gist`, `jsonb_geog`, `jsonb_geog_gist`: `01db45d3dfeffa423eb79f85e07a9a13` |
| `log_regex_gis` size | about 50.2 MB (Step 7C before-build total 50,184,192 bytes; recorded as INFO) |
| Step 6D indexes | 14, digest `e20752ca…`, 9,510,912 bytes (unchanged) |
| Project digests | `log_regex` `f8042db0…` (203 items); `log_regex_json` `9e6f8831…` (10 items); raw integrity 10 / 10; sources `f562354d…` / `fb3bc163…`; Step 6E write schema unchanged |
| Isolation | 0 dependency edges between `log_regex_gis` / `postgis` and the existing schemas; 0 PostGIS-type columns elsewhere |
| Database-wide | `public` 0 / 0 / 0; 0 event triggers; 0 `pg_db_role_setting` rows; empty `shared_preload_libraries` |
| Verification scripts | `sql/27` PASS; `sql/34` 38 / 38; `sql/38 final` 70 / 70; `sql/47` 155 / 155; `sql/50 phase before` 113 / 113 |
| Server (unchanged) | PostgreSQL 17.9, service not restarted; PostGIS 3.6.2 binaries installed; four installer environment variables present |

**Option B:** as Option A, with these differences:
- **Extensions:** `plpgsql` only.
- **Schemas:** `log_regex`, `log_regex_json`, `log_regex_json_write`, `public`.
- **`postgis` / `log_regex_gis`:** absent.
- **PostGIS availability:** 3.6.2 available but not installed (the Step 7B B-01 state).
- **Verification:** `sql/47` / `sql/50` cannot run; everything else in the table above is unchanged.

## 9. Files, manifests and reports to preserve

**Step 7F neither deletes nor modifies any existing file.** The planned new outputs are:
- `sql/run_step7f_cleanup.ps1`
- `analysis/step7/step7f_harness.sql`
- `analysis/step7/step7f_cleanup_checks.txt`, `step7f_cleanup_log.txt`
- the Step 7F manifest (below)
- for Option B only, `sql/53_remove_postgis_objects.sql`

**Preserve for the final project documentation:**

| Group | Files |
|---|---|
| Step 7 documents | `docs/Step7A_PostGIS_Experiment_Design.md`, `docs/Step7A1_PostGIS_Installation_Preflight.md`, `docs/Step7A2_PostGIS_Post_Installation_Verification.md`, `docs/Step7B_PostGIS_Setup_Preflight.md`, `docs/Step7C_Spatial_Index_Experiment_Design.md`, `docs/Step7C_Spatial_Index_Experiment.md`, `docs/Step7D_PostGIS_Results_Analysis.md`, `docs/Step7E_PostGIS_Final_Conclusion.md`, this plan |
| Generators | `scripts/step7_postgis_experiment.py`, `scripts/step7c_spatial_index_experiment.py` |
| SQL | `sql/45_create_postgis_extension.sql` … `sql/52_drop_gis_indexes.sql` (8 files) |
| Runners | `sql/run_step7b_postgis_setup.ps1`, `sql/run_step7c_spatial_indexes.ps1` |
| Step 7B outputs | `analysis/step7/step7b_harness.sql`, `step7b_setup_checks.txt`, `step7b_setup_log.txt` |
| Step 7C outputs (20) | `analysis/step7/step7c_baseline_step7b_sha256.txt`, `step7c_build_log.txt`, `step7c_builds.csv`, `step7c_sizes.csv`, `step7c_checks.txt`, `step7c_run_log.txt`, `step7c_harness.sql`, `step7c_harness_only_checks.txt`, `step7c_harness_only_log.txt`, `step7c_session1_raw.txt` / `_stderr.txt` / `_stdout.txt`, `step7c_session2_raw.txt` / `_stderr.txt` / `_stdout.txt`, `step7c_executions.csv`, `step7c_summary.csv`, `step7c_summary.md`, `step7c_verdicts.csv`, `step7c_comparisons.csv` |
| Earlier manifests | `analysis/step6/step6d_baseline_step6c_sha256.txt` (11), `analysis/step6/step6e_baseline_step6d_sha256.txt` (26), `analysis/step7/step7c_baseline_step7b_sha256.txt` (14) |
| Sample data | `data/raw_access_logs.csv`, `data/expected_fields.csv`, `data/dataset_manifest.json` |
| Project status | `README.md` (updated after execution; not in a manifest because it changes) |

**New Step 7F manifest** `analysis/step7/step7f_baseline_step7c_step7e_sha256.txt`: SHA-256 of 32 files, created in
stage 1 before any database change and verified at the end.

| Group in the manifest | Files |
|---|---:|
| `scripts/step7c_spatial_index_experiment.py` | 1 |
| `sql/49`–`sql/52` | 4 |
| `sql/run_step7c_spatial_indexes.ps1` | 1 |
| the 20 `analysis/step7/step7c_*` files | 20 |
| `docs/Step7C_Spatial_Index_Experiment.md`, `docs/Step7D_PostGIS_Results_Analysis.md`, `docs/Step7E_PostGIS_Final_Conclusion.md` | 3 |
| the 3 sample data files | 3 |

The Step 7B manifest (14 files, including the Step 7A–7B documents and the 7C design) is verified alongside it.

**Notes:**
- **Size:** the two raw session files are about 13.2 MB each.
- **Git:** nothing is committed. Committing these files is a separate decision and is not part of Step 7F.

## 10. Decisions for review

1. **Indexes:** drop all 10 Step 7C indexes with the unchanged `sql/52`, in one transaction, after a rolled-back harness.
2. **Tables:** retain `log_regex_gis` with its 15 tables for reproducibility (Option A). The Option B removal remains
   documented for a later decision.
3. **Extension:** keep `postgis` 3.6.2 installed (required by the retained tables). No action on binaries or
   environment variables.
4. **Checks:** the before / harness / after checks of §5 and §6, with `sql/47` 155 / 155 and `sql/50 phase before`
   113 / 113 as the final `log_regex_gis` proof.
5. **Manifests:** create the 32-file Step 7F manifest before the change and verify the Step 6C, 6D, 7B and 7F manifests
   at the end.
6. **Safeguards:** `lock_timeout = 5s`; 0 non-idle sessions required; no timing, no AC-power requirement.
7. **Documentation:** after execution, add a results section to this plan and update `README.md`. The overall project
   conclusion starts only after that.

---

## 11. Execution results (Option A, 13/09/2026)

**Runner:** `sql/run_step7f_cleanup.ps1`. It implements Option A only; switches `-HarnessOnly` and `-AfterOnly`
(read-only re-verification).

### 11.1 Runs

| # | Run | Result | Report |
|---|---|---|---|
| 1 | `-HarnessOnly`: static checks, manifests (Step 7F manifest created), before checks, rolled-back harness, rollback verification. **No committed change** | **48 PASS / 0 FAIL** | `analysis/step7/step7f_harness_only_checks.txt` (+ `_log.txt`) |
| 2 | Full run (started 2026-09-13 05:53:45 UTC): all of run 1 again, then the real cleanup and the after checks | **343 PASS / 0 FAIL** | `analysis/step7/step7f_cleanup_checks.txt` (+ `step7f_cleanup_log.txt`) |

### 11.2 Stages of the full run

| Stage | Checks | Result |
|---|---|---|
| Static | R-01 (`sql/45`–`48` up to date), R-02 (`sql/49`–`52` up to date, `sql/52` unchanged), R-03 (Step 7C allowlist), R-03b (`sql/52` drops exactly the 10 designed names; its only other statements are `ANALYZE` of 9 `log_regex_gis` tables), R-04 (runner and harness ASCII) | PASS |
| Manifests | M-01a Step 6C 11 / 11; M-01b Step 6D 26 / 26; M-01c Step 7B 14 / 14; M-02 Step 7F manifest `analysis/step7/step7f_baseline_step7c_step7e_sha256.txt` created in run 1 (32 files); M-03 32 / 32 | PASS |
| Before (read-only) | F-01 PostGIS state; F-02 `15|15|10|` + the 10 names; F-03 relations per schema (`log_regex_gis` 40); F-04 dependencies `0|0`; F-05 0 non-idle sessions; B-02 … B-12 (digests, raw 10 / 10, `sql/27`, `sql/34` 38 / 38, `sql/38 final` 70 / 70, Step 6E write schema, sources, relations, manifests); F-06 `sql/50 phase after` 745 / 745 with C-03 606 / 606; F-07 fingerprints = Step 7C values; F-08 statistics digest = Step 7C after-state (`559fc36d…` over 40 relations, 38 rows `add13686…`) | PASS |
| Harness | H-01: `sql/52` + `sql/47` (155 / 155) + `sql/50 phase before` (113 / 113) in one transaction, 268 check lines, no FAIL, then `ROLLBACK`; H-02 fingerprints inside = Step 7C values | PASS |
| Rollback verification | HR-01 PostGIS state; **HR-02 all 10 indexes present again** (`15|15|10|…`); HR-03 relations `log_regex_gis` 40; HR-04 dependencies `0|0`; **H-04 `sql/50 phase after` 745 / 745, C-03 606 / 606, fingerprints equal (exact Step 7C state)**; H-05 statistics digest = before; HB-02 … HB-12 unchanged; H-07 0 non-idle sessions | PASS |
| Real cleanup | S-52: `psql -X -v ON_ERROR_STOP=1 --single-transaction -v confirm_cleanup=yes -f sql/52_drop_gis_indexes.sql` with `PGOPTIONS=-c lock_timeout=5s`, exit 0, no error; S-52b immediately after commit `15|15|0|` | PASS |
| After (read-only) | 292 checks (Z-01 … Z-12, ZP-02 … ZP-12, 155 `sql/47` and 113 `sql/50` individual checks), Z-22 summary | PASS |

### 11.3 Final state verified (the approved §8, requested items 7–12)

| Requested verification | Check | Observed |
|---|---|---|
| 15 tables, 15 primary keys, 0 secondary indexes | Z-02, S-52b | `15|15|0|` |
| Tables intact | Z-05 | all 15 tables have exactly 5,000 rows; primary keys `<table>_pkey` × 15 |
| | Z-08 | data fingerprints equal to the Step 7C values (`aa8e4022…` numeric, `9f32c783…` flat points, `66e5ca3a…` documents, `01db45d3…` documents with points) |
| `sql/47` and `sql/50` | Z-06 | `sql/47 PostGIS setup verification PASSED: all 155 checks` (extension, isolation incl. no secondary index, construction, oracles) |
| | Z-07 | `sql/50 phase before PASSED: all 113 checks` |
| Project fingerprints and protected objects | ZP-02 | `log_regex` digest `f8042db0…` over 203 items (raw_access_logs, access_log_flat, parser, answer key) |
| | ZP-05 | `raw_access_logs` integrity 10 / 10 |
| | ZP-06 | `sql/27`: 4 validated foreign keys |
| | ZP-11 | sources `f562354d…` / `fb3bc163…` |
| | ZP-03, ZP-07 | `log_regex_json` digest `9e6f8831…`; `sql/34` 38 / 38 |
| | ZP-04, ZP-08 | Step 6D index digest `e20752ca…` (14 indexes, 9,510,912 bytes); `sql/38 final` 70 / 70 |
| | ZP-09, ZP-12 | Step 6E write schema unchanged; relations 49 / 16 / 8 |
| Manifests | ZP-10a / ZP-10b / Z-09 / Z-10 | Step 6C 11 / 11, Step 6D 26 / 26, Step 7B 14 / 14, Step 7F 32 / 32 |
| PostGIS remains installed | Z-01 | `plpgsql 1.0 pg_catalog, postgis 3.6.2 postgis`; schemas `log_regex, log_regex_gis, log_regex_json, log_regex_json_write, postgis, public`; `public` 0 / 0 / 0; 0 event triggers; 0 role settings; empty preload |
| | Z-06 | `postgis_lib_version()` 3.6.2 (X-02 inside `sql/47`) |
| No dependency on PostGIS outside `postgis` / `log_regex_gis` | Z-04 | 0 objects; 0 PostGIS-type columns |
| Relations per schema | Z-03 | `log_regex` 49, `log_regex_gis` 30, `log_regex_json` 16, `log_regex_json_write` 8, `postgis` 6, `public` 0 |
| Generated SQL unchanged | Z-11, Z-12 | `sql/45`–`48` and `sql/49`–`52` up to date |
| Final state = approved plan §8 | Z-22 | 292 after checks, 0 FAIL |

**Recorded (INFO):**
- **Catalog and statistics:** the `pg_class` / `pg_statistic` digests of `log_regex_gis` after cleanup are
  `0e146575…` over 30 relations and 36 statistic rows `fe5ceda5…`. These are **identical to the values recorded before
  the Step 7C builds** (Step 7C B-18), so the schema's catalog and planner statistics returned exactly to the Step 7B
  state.
- **Sizes:**

  | Measure | Before cleanup | After cleanup |
  |---|---:|---:|
  | `log_regex_gis` total bytes | 52,887,552 | **50,184,192** (= the Step 7C before-build total) |
  | `log_regex_gis` indexes (bytes) | 4,669,440 | 1,966,080 (15 primary keys) |
  | Database bytes | 231,921,331 | 229,217,971 |

- **Sessions:** 4 other client sessions, all idle, before and after.

### 11.4 Differences from the plan text

1. **Runner switches:** the runner implements Option A only, with `-HarnessOnly` and `-AfterOnly`. §6 had planned
   `-Option A|B`; Option B was not approved, and `sql/53` was not created.
2. **Check IDs:**
   - §5's before checks became F-01 … F-08 plus B-02 … B-12. Relations per schema and the sessions check were added as
     F-03 / F-05.
   - §5's after checks became Z-01 … Z-12, ZP-02 … ZP-12 and Z-22.
   - Added: R-03b (explicit drop names), Z-05 (row counts and primary-key names) and H-07 (sessions before the real
     cleanup).
   - All checks listed in §5 / §6 are covered.
3. **Statistics check:** F-07 of the plan ("statistics digest, expected to equal the Step 7C after-state") was run as a
   PASS / FAIL check (F-08) and passed.
4. **Harness runs:** the harness ran twice, as the harness-only run and inside the full run, both PASS with verified
   rollback.

None of these changes the database actions: the 10 `DROP INDEX IF EXISTS` and 9 `ANALYZE` of the unchanged `sql/52`,
committed once.

### 11.5 Files created by Step 7F

- `sql/run_step7f_cleanup.ps1`
- `analysis/step7/step7f_harness.sql`
- `analysis/step7/step7f_baseline_step7c_step7e_sha256.txt` (32 files)
- `analysis/step7/step7f_harness_only_checks.txt`, `step7f_harness_only_log.txt`
- `analysis/step7/step7f_cleanup_checks.txt`, `step7f_cleanup_log.txt`

No existing file was deleted. The README status was set to `STEP_7F_REPORTED`, later superseded by
`FINAL_CONCLUSION_REPORTED`. Nothing is committed to git.

**Undo:** the Option A rollback in §6.3 remains available: `sql/49 -v approved_step=7C`, then `sql/50 phase after`.

**Stopped here.** The overall project conclusion had not been started at this point; it followed in
[Final_Project_Conclusion.md](Final_Project_Conclusion.md).
