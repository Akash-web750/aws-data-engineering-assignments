-- =============================================================================
-- Step 3B-1 / 02 - Load the Step 1 RAW LOGS without modifying them
-- =============================================================================
-- Run from the project folder (the \copy path is relative to the psql working directory):
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/02_load_raw_access_logs.sql
--
-- \copy (client side)  psql reads the file, so no server file permissions are needed.
-- FORMAT csv           raw_log is always double-quoted in the file; an unquoted empty value
--                      becomes SQL NULL, "" stays an empty string, quoted CR/LF/TAB are kept.
-- HEADER MATCH         the header must be exactly: log_id,raw_log
-- ENCODING 'UTF8'      the file is decoded as UTF-8 whatever the client encoding is.
-- No expressions, casts other than integer for log_id, trimming or defaults are applied.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM log_regex.raw_access_logs) THEN
        RAISE EXCEPTION 'log_regex.raw_access_logs already contains rows; refusing to load again';
    END IF;
END
$$;

\copy log_regex.raw_access_logs (log_id, raw_log) FROM 'data/raw_access_logs.csv' WITH (FORMAT csv, HEADER MATCH, ENCODING 'UTF8')

COMMIT;

SELECT count(*) AS rows_loaded,
       min(log_id) AS min_log_id,
       max(log_id) AS max_log_id
FROM log_regex.raw_access_logs;
