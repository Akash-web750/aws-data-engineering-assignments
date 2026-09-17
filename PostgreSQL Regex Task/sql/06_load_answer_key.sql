-- =============================================================================
-- Step 3B-3 / 06 - Load the Step 1 answer key (evaluation only)
-- =============================================================================
-- Run from the project folder (the \copy path is relative to the psql working directory):
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/06_load_answer_key.sql
--
-- The answer key is never read by the parser (Step 3A P-08); only the evaluation views use it.
-- Plain CREATE on purpose: a second run fails instead of replacing the loaded answer key.
-- MISSING values are unquoted empty fields in the CSV and therefore load as SQL NULL (Step 3A C-07).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

CREATE TABLE log_regex.expected_fields (
    log_id                    integer NOT NULL,
    case_id                   text    NOT NULL,
    source                    text    NOT NULL CHECK (source IN ('curated', 'generated')),
    format_family             text    NOT NULL CHECK (format_family IN ('F1', 'F2', 'F3', 'F4', 'F5', 'NONE')),
    outcome_class             text    NOT NULL,
    record_validity           text    NOT NULL CHECK (record_validity IN ('VALID', 'INVALID', 'BROKEN')),
    entity_type               text,
    entity_type_validity      text    NOT NULL CHECK (entity_type_validity      IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    email_address             text,
    email_address_validity    text    NOT NULL CHECK (email_address_validity    IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    resource_url              text,
    resource_url_validity     text    NOT NULL CHECK (resource_url_validity     IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    event_timestamp           text,
    event_timestamp_validity  text    NOT NULL CHECK (event_timestamp_validity  IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    tool                      text,
    tool_validity             text    NOT NULL CHECK (tool_validity             IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    latitude                  text,
    latitude_validity         text    NOT NULL CHECK (latitude_validity         IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    longitude                 text,
    longitude_validity        text    NOT NULL CHECK (longitude_validity        IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    ip_address                text,
    ip_address_validity       text    NOT NULL CHECK (ip_address_validity       IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    action_phrase             text,
    action_phrase_validity    text    NOT NULL CHECK (action_phrase_validity    IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    status                    text,
    status_validity           text    NOT NULL CHECK (status_validity           IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    secondary_values          text,
    scenario_tags             text,
    notes                     text,
    CONSTRAINT expected_fields_pkey PRIMARY KEY (log_id),
    CONSTRAINT expected_fields_log_id_fkey FOREIGN KEY (log_id) REFERENCES log_regex.raw_access_logs (log_id)
);

COMMENT ON TABLE log_regex.expected_fields IS
    'Step 1 answer key loaded unchanged from data/expected_fields.csv. Evaluation only; never read by the parser. Read-only.';

\copy log_regex.expected_fields FROM 'data/expected_fields.csv' WITH (FORMAT csv, HEADER MATCH, ENCODING 'UTF8')

DO $$
BEGIN
    IF (SELECT count(*) FROM log_regex.expected_fields) <> (SELECT count(*) FROM log_regex.raw_access_logs) THEN
        RAISE EXCEPTION 'answer key row count differs from raw_access_logs';
    END IF;
END
$$;

CREATE FUNCTION log_regex.block_answer_key_modification()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION '% on %.% is blocked: the Step 1 answer key is read-only', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = 'LR002',
              HINT    = 'Reload data/expected_fields.csv into a rebuilt database instead of changing loaded rows.';
END;
$$;

CREATE TRIGGER expected_fields_read_only
    BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON log_regex.expected_fields
    FOR EACH STATEMENT EXECUTE FUNCTION log_regex.block_answer_key_modification();

REVOKE ALL ON log_regex.expected_fields FROM PUBLIC;

COMMIT;

SELECT format_family, count(*) AS rows FROM log_regex.expected_fields GROUP BY format_family ORDER BY format_family;
