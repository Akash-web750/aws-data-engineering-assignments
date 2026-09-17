-- =============================================================================
-- Step 3B-3 / 08 - Parser output tables and the wide result view (Step 3A section 11, C-07)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/08_parser_output_tables.sql
--
-- Re-runnable during development: drops and recreates the parser output objects (and therefore
-- previous parser runs). Never touches raw_access_logs, its fingerprints/audit or the answer key.
-- Refuses to run (SQLSTATE LR003) while log_regex.access_log_flat exists (Step 5A review, see the guard below).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

-- BEGIN access_log_flat guard
-- The DROP below uses CASCADE. If the published flat table exists, CASCADE would silently remove its lineage foreign
-- key to parsed_log and discard the parser run it references. Stop before anything is dropped.
DO $$
BEGIN
    IF to_regclass('log_regex.access_log_flat') IS NOT NULL THEN
        RAISE EXCEPTION 'sql/08_parser_output_tables.sql refused: log_regex.access_log_flat exists; DROP ... CASCADE would silently remove its foreign keys and the runs it references'
            USING ERRCODE = 'LR003',
                  HINT    = 'Rebuild parser output tables only after deliberately removing or unpublishing log_regex.access_log_flat.';
    END IF;
END
$$;
-- END access_log_flat guard

BEGIN;

DROP VIEW  IF EXISTS log_regex.v_parsed_access_logs CASCADE;
DROP TABLE IF EXISTS log_regex.parsed_secondary, log_regex.parsed_field, log_regex.parsed_log, log_regex.parser_run CASCADE;

CREATE TABLE log_regex.parser_run (
    run_id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parser_version            text        NOT NULL,
    reference_data_version    text        NOT NULL,
    formats_implemented       text[]      NOT NULL,
    assumed_year              integer     NOT NULL,
    raw_row_count             integer     NOT NULL,
    fingerprint_check_before  boolean     NOT NULL,
    fingerprint_check_after   boolean,
    started_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at               timestamptz,
    status                    text        NOT NULL CHECK (status IN ('running', 'succeeded', 'failed'))
);

CREATE TABLE log_regex.parsed_log (
    run_id             bigint  NOT NULL REFERENCES log_regex.parser_run (run_id) ON DELETE CASCADE,
    log_id             integer NOT NULL REFERENCES log_regex.raw_access_logs (log_id),
    format_family      text    CHECK (format_family IN ('F1', 'F2', 'F3', 'F4', 'F5', 'NONE')),
    detection_rule     text    NOT NULL,
    format_candidates  text[]  NOT NULL,
    sub_format         text,
    event_end_pos      integer,
    is_truncated       boolean NOT NULL DEFAULT false,
    record_validity    text    CHECK (record_validity IN ('VALID', 'INVALID', 'BROKEN')),
    diagnostics        text[]  NOT NULL DEFAULT '{}',
    PRIMARY KEY (run_id, log_id),
    -- Deferred rows never carry a record validity. Parsed rows receive theirs at the end of the run;
    -- run_parser() refuses to mark a run succeeded while any parsed row still has none.
    CONSTRAINT parsed_log_deferred_rows_have_no_validity CHECK (format_family IS NOT NULL OR record_validity IS NULL)
);

COMMENT ON COLUMN log_regex.parsed_log.format_family IS
    'NULL = format not handled in this step (detection_rule DEFERRED); only DET-00 and DET-F1 exist so far.';

CREATE TABLE log_regex.parsed_field (
    run_id          bigint  NOT NULL,
    log_id          integer NOT NULL,
    field_name      text    NOT NULL REFERENCES log_regex.ref_field (field_name),
    value           text,
    validity        text    NOT NULL CHECK (validity IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING')),
    start_pos       integer,
    missing_reason  text    CHECK (missing_reason IN ('absent', 'empty', 'sentinel')),
    slot_id         text,
    rule_id         text    NOT NULL,
    candidate_count integer NOT NULL DEFAULT 0,
    PRIMARY KEY (run_id, log_id, field_name),
    FOREIGN KEY (run_id, log_id) REFERENCES log_regex.parsed_log (run_id, log_id) ON DELETE CASCADE,
    CONSTRAINT parsed_field_missing_is_null   CHECK ((validity = 'MISSING') = (value IS NULL)),
    CONSTRAINT parsed_field_no_empty_value    CHECK (value <> ''),
    CONSTRAINT parsed_field_position          CHECK ((value IS NULL) = (start_pos IS NULL) AND (start_pos IS NULL OR start_pos >= 1)),
    CONSTRAINT parsed_field_missing_reason    CHECK ((validity = 'MISSING') = (missing_reason IS NOT NULL))
);

CREATE TABLE log_regex.parsed_secondary (
    run_id     bigint  NOT NULL,
    log_id     integer NOT NULL,
    field_name text    NOT NULL REFERENCES log_regex.ref_field (field_name),
    kind       text    NOT NULL,
    value      text    NOT NULL CHECK (value <> ''),
    start_pos  integer NOT NULL CHECK (start_pos >= 1),
    PRIMARY KEY (run_id, log_id, field_name, kind, start_pos),
    FOREIGN KEY (run_id, log_id) REFERENCES log_regex.parsed_log (run_id, log_id) ON DELETE CASCADE
);

-- Wide view of the latest successful run, in the answer-key column layout (MISSING stays NULL) ----
CREATE VIEW log_regex.v_parsed_access_logs AS
WITH latest AS (
    SELECT max(run_id) AS run_id FROM log_regex.parser_run WHERE status = 'succeeded'
)
SELECT l.log_id,
       l.format_family,
       l.record_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'entity_type')     AS entity_type,
       max(f.validity) FILTER (WHERE f.field_name = 'entity_type')     AS entity_type_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'email_address')   AS email_address,
       max(f.validity) FILTER (WHERE f.field_name = 'email_address')   AS email_address_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'resource_url')    AS resource_url,
       max(f.validity) FILTER (WHERE f.field_name = 'resource_url')    AS resource_url_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'event_timestamp') AS event_timestamp,
       max(f.validity) FILTER (WHERE f.field_name = 'event_timestamp') AS event_timestamp_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'tool')            AS tool,
       max(f.validity) FILTER (WHERE f.field_name = 'tool')            AS tool_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'latitude')        AS latitude,
       max(f.validity) FILTER (WHERE f.field_name = 'latitude')        AS latitude_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'longitude')       AS longitude,
       max(f.validity) FILTER (WHERE f.field_name = 'longitude')       AS longitude_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'ip_address')      AS ip_address,
       max(f.validity) FILTER (WHERE f.field_name = 'ip_address')      AS ip_address_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'action_phrase')   AS action_phrase,
       max(f.validity) FILTER (WHERE f.field_name = 'action_phrase')   AS action_phrase_validity,
       max(f.value)    FILTER (WHERE f.field_name = 'status')          AS status,
       max(f.validity) FILTER (WHERE f.field_name = 'status')          AS status_validity,
       (SELECT string_agg(s.kind || '=' || s.value, ';' ORDER BY s.start_pos, s.kind)
        FROM log_regex.parsed_secondary s
        WHERE s.run_id = l.run_id AND s.log_id = l.log_id)             AS secondary_values,
       l.detection_rule,
       l.is_truncated,
       l.diagnostics,
       l.run_id,
       r.raw_log
FROM latest
JOIN log_regex.parsed_log l      ON l.run_id = latest.run_id
JOIN log_regex.raw_access_logs r ON r.log_id = l.log_id
LEFT JOIN log_regex.parsed_field f ON f.run_id = l.run_id AND f.log_id = l.log_id
GROUP BY l.run_id, l.log_id, l.format_family, l.record_validity, l.detection_rule, l.is_truncated, l.diagnostics, r.raw_log;

COMMENT ON VIEW log_regex.v_parsed_access_logs IS
    'Latest successful parser run pivoted into the answer-key column layout; raw_log joined from the source table.';

COMMIT;
