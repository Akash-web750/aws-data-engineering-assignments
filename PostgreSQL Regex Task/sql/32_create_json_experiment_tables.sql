-- =============================================================================
-- Step 6B / 32 - Create the JSON vs JSONB experiment tables (structure only)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/32_create_json_experiment_tables.sql
--
-- Implements docs/Step6A_JSON_vs_JSONB_Experiment_Design.md section 3 in one transaction:
--   schema log_regex_json
--   log_regex_json.access_log_json   (log_id integer, doc json)
--   log_regex_json.access_log_jsonb  (log_id integer, doc jsonb)
-- The two tables are identical except the type of doc: primary key (log_id), no foreign keys, no CHECK, default
-- fillfactor, column storage and compression, autovacuum disabled (explicit VACUUM (ANALYZE) after the load).
-- Creates no query index (the primary key index belongs to the designed table), inserts no rows.
--
-- Safety:
--   * Never drops or replaces anything: refuses (SQLSTATE LR010) if schema log_regex_json already exists.
--   * Refuses (LR010) unless log_regex.access_log_flat holds exactly one row per raw log from one run and
--     verify_raw_access_logs() passes 10 / 10. Full source verification is sql/27, sql/29 and sql/31 (the runner).
--   * Touches no object in schema log_regex: no foreign key, trigger or dependency on the flat table or the raw input.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

SET LOCAL lock_timeout = '10s';

-- BEGIN guard and preconditions
DO $$
DECLARE
    v_flat_rows bigint;
    v_flat_ids  bigint;
    v_runs      bigint;
    v_raw_rows  bigint;
    v_checks    bigint;
    v_failed    bigint;
BEGIN
    IF to_regnamespace('log_regex_json') IS NOT NULL THEN
        RAISE EXCEPTION 'sql/32_create_json_experiment_tables.sql refused: schema log_regex_json already exists; this script never drops or replaces objects'
            USING ERRCODE = 'LR010',
                  HINT    = 'Verify the existing tables with sql/34 and sql/35.';
    END IF;
    IF to_regclass('log_regex.access_log_flat') IS NULL THEN
        RAISE EXCEPTION 'sql/32_create_json_experiment_tables.sql refused: log_regex.access_log_flat does not exist' USING ERRCODE = 'LR010';
    END IF;

    SELECT count(*), count(DISTINCT log_id), count(DISTINCT run_id) INTO v_flat_rows, v_flat_ids, v_runs FROM log_regex.access_log_flat;
    SELECT count(*) INTO v_raw_rows FROM log_regex.raw_access_logs;
    SELECT count(*), count(*) FILTER (WHERE NOT passed) INTO v_checks, v_failed FROM log_regex.verify_raw_access_logs();

    IF v_flat_rows <> v_raw_rows OR v_flat_ids <> v_raw_rows OR v_runs <> 1 OR v_checks <> 10 OR v_failed <> 0 THEN
        RAISE EXCEPTION 'sql/32_create_json_experiment_tables.sql refused: access_log_flat % rows / % log_ids / % runs for % raw logs; raw input checks failed: % of %',
            v_flat_rows, v_flat_ids, v_runs, v_raw_rows, v_failed, v_checks
            USING ERRCODE = 'LR010';
    END IF;
    RAISE NOTICE 'preconditions passed: access_log_flat % rows from 1 run for % raw logs; raw input 10 / 10', v_flat_rows, v_raw_rows;
END
$$;
-- END guard and preconditions

-- BEGIN Step 6A DDL (design section 3)
CREATE SCHEMA log_regex_json;

CREATE TABLE log_regex_json.access_log_json (
    log_id  integer NOT NULL,
    doc     json    NOT NULL,
    CONSTRAINT access_log_json_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);

CREATE TABLE log_regex_json.access_log_jsonb (
    log_id  integer NOT NULL,
    doc     jsonb   NOT NULL,
    CONSTRAINT access_log_jsonb_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);
-- END Step 6A DDL

COMMENT ON SCHEMA log_regex_json IS
    'Step 6 JSON vs JSONB experiment (docs/Step6A_JSON_vs_JSONB_Experiment_Design.md). Derived, disposable tables; '
    'no dependency on or from schema log_regex.';
COMMENT ON TABLE log_regex_json.access_log_json IS
    'Step 6B: one json document per access_log_flat row (document version 1). Not loaded yet.';
COMMENT ON TABLE log_regex_json.access_log_jsonb IS
    'Step 6B: one jsonb document per access_log_flat row (document version 1). Not loaded yet.';

-- Post-condition before COMMIT: exactly the designed objects -----------------------------------------------------
DO $$
DECLARE
    v_summary text;
BEGIN
    SELECT string_agg(format('%s:%s', c.relkind, c.relname), ' ' ORDER BY c.relname) INTO v_summary
    FROM pg_class c WHERE c.relnamespace = 'log_regex_json'::regnamespace;
    IF v_summary IS DISTINCT FROM 'r:access_log_json i:access_log_json_pkey r:access_log_jsonb i:access_log_jsonb_pkey' THEN
        RAISE EXCEPTION 'sql/32_create_json_experiment_tables.sql: unexpected objects in log_regex_json (%); rolled back', v_summary
            USING ERRCODE = 'LR010';
    END IF;
    IF (SELECT count(*) FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
        WHERE c.relnamespace = 'log_regex_json'::regnamespace AND k.contype <> 'p') <> 0 THEN
        RAISE EXCEPTION 'sql/32_create_json_experiment_tables.sql: constraints other than the primary keys; rolled back' USING ERRCODE = 'LR010';
    END IF;
END
$$;

COMMIT;

SELECT c.oid::regclass AS created_table, format_type(a.atttypid, a.atttypmod) AS doc_type, a.attstorage AS storage,
       coalesce(nullif(a.attcompression::text, ''), 'default (' || current_setting('default_toast_compression') || ')') AS compression,
       c.reloptions, (SELECT count(*) FROM pg_index i WHERE i.indrelid = c.oid) AS indexes
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'doc'
WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
ORDER BY c.relname;
