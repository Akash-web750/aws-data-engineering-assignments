-- Step 7F rolled-back harness (written by sql/run_step7f_cleanup.ps1): sql/52 + sql/47 + sql/50 phase before in one transaction, then ROLLBACK.
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
