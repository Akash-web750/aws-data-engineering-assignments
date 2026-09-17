-- =============================================================================
-- Step 3B-1 / 01 - Schema log_regex and the RAW LOG input table
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/01_create_schema_and_raw_table.sql
--
-- Plain CREATE statements on purpose: running this against an existing setup fails instead of
-- replacing the raw input.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA log_regex;

COMMENT ON SCHEMA log_regex IS
    'PostgreSQL Regex Task: RAW LOG input, and later the parser and evaluation objects.';

CREATE TABLE log_regex.raw_access_logs (
    log_id  integer NOT NULL,
    raw_log text,
    CONSTRAINT raw_access_logs_pkey             PRIMARY KEY (log_id),
    CONSTRAINT raw_access_logs_log_id_positive  CHECK (log_id > 0)
);

COMMENT ON TABLE log_regex.raw_access_logs IS
    'Step 1 RAW LOGS loaded unchanged from data/raw_access_logs.csv. Read-only after load '
    '(guard trigger, fingerprints and load audit in 03_protect_raw_input.sql).';
COMMENT ON COLUMN log_regex.raw_access_logs.log_id IS
    'Step 1 log_id (1..5000); the only row identity carried into parser output.';
COMMENT ON COLUMN log_regex.raw_access_logs.raw_log IS
    'Exact RAW LOG text. SQL NULL (one row) and the empty string (one row) are different values.';

COMMIT;
