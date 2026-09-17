-- =============================================================================
-- Step 3B-4 / 13 - Reference data added for the F2 sentence parser
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/13_parser_reference_data_f2.sql
--
-- Adds the vocabularies the F2 grammar needs (Step 3A sections 7.2, 9 M-08 and 10.1 step 3):
--   ref_log_level        log-level words that may follow the F2 timestamp prefix (EC-047 WARN)
--   ref_sentinel_phrase  text written in a slot instead of a value; the field is MISSING (sentinel)
-- and sets ref_data_version to 3B-4.1.
-- Re-runnable (drop + create of these two tables only). The Step 3B-3 reference tables, the output
-- tables and earlier parser runs are not touched.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DROP TABLE IF EXISTS log_regex.ref_log_level, log_regex.ref_sentinel_phrase;

-- Log levels (F2 prefix, Step 3A section 7.2 step 1); matched case-sensitively ------------------------
CREATE TABLE log_regex.ref_log_level (level_name text PRIMARY KEY);
INSERT INTO log_regex.ref_log_level VALUES
    ('TRACE'), ('DEBUG'), ('INFO'), ('NOTICE'), ('WARN'), ('WARNING'), ('ERROR'), ('CRITICAL');

-- Sentinel phrases (Step 3A section 10.1 step 3); matched case-sensitively as whole words ---------------
CREATE TABLE log_regex.ref_sentinel_phrase (
    format_family text NOT NULL CHECK (format_family IN ('F1', 'F2', 'F3', 'F4', 'F5')),
    field_name    text NOT NULL REFERENCES log_regex.ref_field (field_name),
    phrase        text NOT NULL CHECK (phrase <> ''),
    PRIMARY KEY (format_family, field_name, phrase)
);
INSERT INTO log_regex.ref_sentinel_phrase VALUES
    ('F2', 'email_address', 'anonymous'),
    ('F2', 'resource_url',  'an unspecified resource');

DELETE FROM log_regex.ref_data_version;
INSERT INTO log_regex.ref_data_version VALUES
    ('3B-4.1', 'F1 key aliases; F2 log levels and sentinel phrases; shared vocabularies for all validators');

COMMIT;

SELECT 'ref_log_level' AS table_name, count(*) AS rows FROM log_regex.ref_log_level
UNION ALL
SELECT 'ref_sentinel_phrase', count(*) FROM log_regex.ref_sentinel_phrase
UNION ALL
SELECT 'ref_data_version = ' || version, 1 FROM log_regex.ref_data_version;
