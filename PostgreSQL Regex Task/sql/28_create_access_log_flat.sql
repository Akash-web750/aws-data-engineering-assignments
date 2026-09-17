-- =============================================================================
-- Step 5B / 28 - Create log_regex.access_log_flat (structure only; not populated)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/28_create_access_log_flat.sql
--   optional: -v source_run_id=<run>   (default 14, the run accepted in Step 4A)
--
-- Implements docs/Step5A_Flat_Schema_Design.md (Appendix A, with the Step 5A review corrections) in one transaction:
-- the three text domains and the flat table with its primary key, the four foreign keys and the 22 CHECK constraints,
-- plus comments that record the typed-column derivation rules. Inserts no rows. Creates no index other than the
-- primary key, no JSON/JSONB column and no PostGIS object.
--
-- Safety:
--   * Never drops or replaces anything. Refuses (SQLSTATE LR003) while log_regex.access_log_flat or any of its three
--     domains already exists.
--   * Refuses (SQLSTATE LR005) unless the raw input passes verify_raw_access_logs() and the source run is an accepted
--     source: succeeded, formats {F1,F2,F3,F4,F5,NONE}, fingerprint checks before and after, one parsed_log row with a
--     format and record validity per raw log, ten parsed_field rows per raw log; and unless the two referenced
--     vocabularies (ref_entity_type, ref_timestamp_shape) hold exactly the expected codes.
--   * Once this table exists, sql/07 and sql/08 (DROP ... CASCADE) and sql/run_step3b3_f1_parser.ps1 refuse to run
--     (LR003, Step 5A review).
--
-- Enforced when the table is loaded (next step), not by CHECKs: exact substrings; the typed-column derivations in the
-- column comments (entity normalisation, timestamp shape and 12-hour rule, inet plus zone ID, coordinate conversion
-- and the 7-decimal-place precision rule).
-- Verify afterwards with sql/27_verify_access_log_flat_foreign_keys.sql and sql/29_verify_access_log_flat_structure.sql.
-- Never modifies raw_access_logs, the answer key, reference data, parser output tables or parser functions.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

\if :{?source_run_id}
\else
    \set source_run_id 14
\endif

BEGIN;

SET LOCAL lock_timeout = '10s';
SELECT set_config('flat_install.source_run_id', :'source_run_id', true) AS source_run_id;

-- BEGIN install guard: never replace existing objects
DO $$
DECLARE
    v_existing text;
BEGIN
    SELECT string_agg(o.name, ', ' ORDER BY o.name) INTO v_existing
    FROM (VALUES ('log_regex.access_log_flat',        to_regclass('log_regex.access_log_flat')::oid),
                 ('log_regex.field_validity_status',  to_regtype('log_regex.field_validity_status')::oid),
                 ('log_regex.record_validity_status', to_regtype('log_regex.record_validity_status')::oid),
                 ('log_regex.missing_reason_code',    to_regtype('log_regex.missing_reason_code')::oid)) AS o (name, oid)
    WHERE o.oid IS NOT NULL;

    IF v_existing IS NOT NULL THEN
        RAISE EXCEPTION 'sql/28_create_access_log_flat.sql refused: % already exists; this script never drops or replaces objects', v_existing
            USING ERRCODE = 'LR003',
                  HINT    = 'Verify the existing table with sql/27 and sql/29. Re-create it only after deliberately removing it.';
    END IF;
END
$$;
-- END install guard

-- BEGIN preconditions
DO $$
DECLARE
    c_formats  constant text[] := ARRAY['F1', 'F2', 'F3', 'F4', 'F5', 'NONE'];
    v_run_id   bigint := current_setting('flat_install.source_run_id')::bigint;
    v_problems text[] := '{}';
    v_run      record;
    v_checks   bigint;
    v_failed   bigint;
    v_raw_rows bigint;
    v_logs     bigint;
    v_logs_ok  bigint;
    v_fields   bigint;
    v_latest   bigint;
BEGIN
    IF to_regclass('log_regex.raw_access_logs') IS NULL OR to_regclass('log_regex.parser_run') IS NULL
       OR to_regclass('log_regex.parsed_log') IS NULL OR to_regclass('log_regex.parsed_field') IS NULL
       OR to_regclass('log_regex.ref_entity_type') IS NULL OR to_regclass('log_regex.ref_timestamp_shape') IS NULL
       OR to_regprocedure('log_regex.verify_raw_access_logs()') IS NULL THEN
        RAISE EXCEPTION 'sql/28_create_access_log_flat.sql refused: required objects are missing (raw table, parser output tables, reference tables or verify_raw_access_logs())'
            USING ERRCODE = 'LR005';
    END IF;

    SELECT count(*), count(*) FILTER (WHERE NOT passed) INTO v_checks, v_failed FROM log_regex.verify_raw_access_logs();
    IF v_checks <> 10 OR v_failed <> 0 THEN
        v_problems := v_problems || format('verify_raw_access_logs(): %s of %s checks failed', v_failed, v_checks);
    END IF;

    SELECT * INTO v_run FROM log_regex.parser_run WHERE run_id = v_run_id;
    IF NOT FOUND THEN
        v_problems := v_problems || format('parser run %s does not exist', v_run_id);
    ELSE
        IF v_run.status <> 'succeeded' THEN
            v_problems := v_problems || format('run %s has status %s', v_run_id, v_run.status);
        END IF;
        IF NOT (v_run.formats_implemented @> c_formats AND v_run.formats_implemented <@ c_formats) THEN
            v_problems := v_problems || format('run %s implements formats %s, not %s', v_run_id, v_run.formats_implemented, c_formats);
        END IF;
        IF v_run.fingerprint_check_before IS NOT TRUE OR v_run.fingerprint_check_after IS NOT TRUE THEN
            v_problems := v_problems || format('run %s fingerprint checks before/after: %s/%s', v_run_id,
                                               v_run.fingerprint_check_before, v_run.fingerprint_check_after);
        END IF;
    END IF;

    -- parsed_log is keyed (run_id, log_id) and log_id references raw_access_logs, so equal counts mean exactly one
    -- row per raw log.
    SELECT count(*) INTO v_raw_rows FROM log_regex.raw_access_logs;
    SELECT count(*), count(*) FILTER (WHERE format_family IS NOT NULL AND record_validity IS NOT NULL)
      INTO v_logs, v_logs_ok
      FROM log_regex.parsed_log WHERE run_id = v_run_id;
    SELECT count(*) INTO v_fields FROM log_regex.parsed_field WHERE run_id = v_run_id;
    IF v_logs <> v_raw_rows OR v_logs_ok <> v_raw_rows THEN
        v_problems := v_problems || format('run %s has %s parsed_log rows (%s with format and record validity) for %s raw logs',
                                           v_run_id, v_logs, v_logs_ok, v_raw_rows);
    END IF;
    IF v_fields <> 10 * v_raw_rows THEN
        v_problems := v_problems || format('run %s has %s parsed_field rows, expected %s', v_run_id, v_fields, 10 * v_raw_rows);
    END IF;

    IF (SELECT array_agg(entity_type ORDER BY entity_type COLLATE "C") FROM log_regex.ref_entity_type)
       IS DISTINCT FROM ARRAY['ADMIN', 'API_CLIENT', 'BOT', 'CUSTOMER', 'GUEST', 'SERVICE_ACCOUNT', 'USER'] THEN
        v_problems := v_problems || 'ref_entity_type does not hold exactly the 7 entity type codes'::text;
    END IF;
    IF (SELECT array_agg(shape_name ORDER BY shape_name COLLATE "C") FROM log_regex.ref_timestamp_shape)
       IS DISTINCT FROM ARRAY['apache_clf', 'compact_basic', 'dmy_dash', 'epoch_milliseconds', 'epoch_seconds', 'iso8601',
                              'syslog_rfc3164', 'us_mdy_12h', 'ymd_slash'] THEN
        v_problems := v_problems || 'ref_timestamp_shape does not hold exactly the 9 timestamp shapes'::text;
    END IF;

    IF cardinality(v_problems) > 0 THEN
        RAISE EXCEPTION 'sql/28_create_access_log_flat.sql refused: %', array_to_string(v_problems, '; ')
            USING ERRCODE = 'LR005';
    END IF;

    SELECT max(run_id) INTO v_latest
    FROM log_regex.parser_run
    WHERE status = 'succeeded' AND formats_implemented @> c_formats AND formats_implemented <@ c_formats;

    RAISE NOTICE 'preconditions passed: raw input % / % checks; source run % (%, %) succeeded with % parsed_log and % parsed_field rows for % raw logs; latest accepted all-format run: %',
        v_checks - v_failed, v_checks, v_run_id, v_run.parser_version, v_run.formats_implemented, v_logs, v_fields, v_raw_rows, v_latest;
END
$$;
-- END preconditions

-- BEGIN Step 5A DDL (docs/Step5A_Flat_Schema_Design.md, Appendix A)
CREATE DOMAIN log_regex.field_validity_status  AS text CHECK (VALUE IN ('VALID', 'INVALID', 'PLACEHOLDER', 'MISSING'));
CREATE DOMAIN log_regex.record_validity_status AS text CHECK (VALUE IN ('VALID', 'INVALID', 'BROKEN'));
CREATE DOMAIN log_regex.missing_reason_code    AS text CHECK (VALUE IN ('absent', 'empty', 'sentinel'));

CREATE TABLE log_regex.access_log_flat (
    -- identity and lineage
    log_id                          integer      NOT NULL,
    run_id                          bigint       NOT NULL,
    loaded_at                       timestamptz  NOT NULL DEFAULT now(),

    -- record classification
    format_family                   text         NOT NULL,
    detection_rule                  text         NOT NULL,
    sub_format                      text,
    record_validity                 log_regex.record_validity_status NOT NULL,
    is_truncated                    boolean      NOT NULL,
    event_end_pos                   integer,
    diagnostics                     text[]       NOT NULL DEFAULT '{}',

    -- entity_type
    entity_type                     text,
    entity_type_validity            log_regex.field_validity_status NOT NULL,
    entity_type_start_pos           integer,
    entity_type_source              text,
    entity_type_missing_reason      log_regex.missing_reason_code,
    entity_type_code                text,

    -- email_address
    email_address                   text,
    email_address_validity          log_regex.field_validity_status NOT NULL,
    email_address_start_pos         integer,
    email_address_source            text,
    email_address_missing_reason    log_regex.missing_reason_code,

    -- resource_url
    resource_url                    text,
    resource_url_validity           log_regex.field_validity_status NOT NULL,
    resource_url_start_pos          integer,
    resource_url_source             text,
    resource_url_missing_reason     log_regex.missing_reason_code,

    -- event_timestamp
    event_timestamp                 text,
    event_timestamp_validity        log_regex.field_validity_status NOT NULL,
    event_timestamp_start_pos       integer,
    event_timestamp_source          text,
    event_timestamp_missing_reason  log_regex.missing_reason_code,
    event_timestamp_shape           text,
    event_timestamp_local           timestamp(6),
    event_timestamp_utc_offset      interval,
    event_timestamp_utc             timestamptz(6),

    -- tool
    tool                            text,
    tool_validity                   log_regex.field_validity_status NOT NULL,
    tool_start_pos                  integer,
    tool_source                     text,
    tool_missing_reason             log_regex.missing_reason_code,

    -- latitude
    latitude                        text,
    latitude_validity               log_regex.field_validity_status NOT NULL,
    latitude_start_pos              integer,
    latitude_source                 text,
    latitude_missing_reason         log_regex.missing_reason_code,
    latitude_degrees                numeric(10,7),

    -- longitude
    longitude                       text,
    longitude_validity              log_regex.field_validity_status NOT NULL,
    longitude_start_pos             integer,
    longitude_source                text,
    longitude_missing_reason        log_regex.missing_reason_code,
    longitude_degrees               numeric(10,7),

    -- ip_address
    ip_address                      text,
    ip_address_validity             log_regex.field_validity_status NOT NULL,
    ip_address_start_pos            integer,
    ip_address_source               text,
    ip_address_missing_reason       log_regex.missing_reason_code,
    ip_address_inet                 inet,
    ip_address_zone_id              text,

    -- action_phrase
    action_phrase                   text,
    action_phrase_validity          log_regex.field_validity_status NOT NULL,
    action_phrase_start_pos         integer,
    action_phrase_source            text,
    action_phrase_missing_reason    log_regex.missing_reason_code,

    -- status
    status                          text,
    status_validity                 log_regex.field_validity_status NOT NULL,
    status_start_pos                integer,
    status_source                   text,
    status_missing_reason           log_regex.missing_reason_code,
    status_code                     smallint,
    status_word                     text,

    -- keys
    CONSTRAINT access_log_flat_pkey PRIMARY KEY (log_id),
    CONSTRAINT access_log_flat_raw_log_fkey FOREIGN KEY (log_id)
        REFERENCES log_regex.raw_access_logs (log_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT access_log_flat_parsed_log_fkey FOREIGN KEY (run_id, log_id)
        REFERENCES log_regex.parsed_log (run_id, log_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT access_log_flat_entity_type_code_fkey FOREIGN KEY (entity_type_code)
        REFERENCES log_regex.ref_entity_type (entity_type),
    CONSTRAINT access_log_flat_event_timestamp_shape_fkey FOREIGN KEY (event_timestamp_shape)
        REFERENCES log_regex.ref_timestamp_shape (shape_name),

    -- record classification
    CONSTRAINT access_log_flat_format_family CHECK (format_family IN ('F1', 'F2', 'F3', 'F4', 'F5', 'NONE')),
    CONSTRAINT access_log_flat_detection_rule CHECK (
        CASE WHEN format_family = 'NONE' THEN detection_rule IN ('DET-00', 'DET-NONE')
             ELSE detection_rule = 'DET-' || format_family END),
    CONSTRAINT access_log_flat_event_end_pos CHECK (
        (event_end_pos IS NULL) = (format_family = 'NONE') AND (event_end_pos IS NULL OR event_end_pos >= 1)),
    CONSTRAINT access_log_flat_sub_format CHECK ((sub_format IS NULL) = (format_family = 'NONE')),
    CONSTRAINT access_log_flat_none_rows CHECK (
        format_family <> 'NONE'
        OR (entity_type_validity = 'MISSING' AND email_address_validity = 'MISSING' AND resource_url_validity = 'MISSING'
            AND event_timestamp_validity = 'MISSING' AND tool_validity = 'MISSING' AND latitude_validity = 'MISSING'
            AND longitude_validity = 'MISSING' AND ip_address_validity = 'MISSING'
            AND action_phrase_validity = 'MISSING' AND status_validity = 'MISSING')),
    CONSTRAINT access_log_flat_record_validity_rule CHECK (
        record_validity = CASE
            WHEN format_family = 'NONE' OR is_truncated THEN 'BROKEN'
            WHEN 'INVALID' IN (entity_type_validity, email_address_validity, resource_url_validity,
                               event_timestamp_validity, tool_validity, latitude_validity, longitude_validity,
                               ip_address_validity, action_phrase_validity, status_validity) THEN 'INVALID'
            ELSE 'VALID' END),

    -- per-field state (MISSING <=> NULL value <=> NULL position <=> missing reason; source NULL <=> absent;
    -- no empty strings; in event scope)
    CONSTRAINT access_log_flat_entity_type_state CHECK (
        (entity_type IS NULL) = (entity_type_validity = 'MISSING')
        AND (entity_type_start_pos IS NULL) = (entity_type IS NULL)
        AND (entity_type_missing_reason IS NOT NULL) = (entity_type_validity = 'MISSING')
        AND (entity_type_source IS NULL) = (entity_type_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (entity_type IS NULL OR (entity_type <> '' AND entity_type_start_pos >= 1
             AND entity_type_start_pos + char_length(entity_type) - 1 <= event_end_pos))),
    CONSTRAINT access_log_flat_email_address_state CHECK (
        (email_address IS NULL) = (email_address_validity = 'MISSING')
        AND (email_address_start_pos IS NULL) = (email_address IS NULL)
        AND (email_address_missing_reason IS NOT NULL) = (email_address_validity = 'MISSING')
        AND (email_address_source IS NULL) = (email_address_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (email_address IS NULL OR (email_address <> '' AND email_address_start_pos >= 1
             AND email_address_start_pos + char_length(email_address) - 1 <= event_end_pos))),
    CONSTRAINT access_log_flat_resource_url_state CHECK (
        (resource_url IS NULL) = (resource_url_validity = 'MISSING')
        AND (resource_url_start_pos IS NULL) = (resource_url IS NULL)
        AND (resource_url_missing_reason IS NOT NULL) = (resource_url_validity = 'MISSING')
        AND (resource_url_source IS NULL) = (resource_url_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (resource_url IS NULL OR (resource_url <> '' AND resource_url_start_pos >= 1
             AND resource_url_start_pos + char_length(resource_url) - 1 <= event_end_pos))),
    CONSTRAINT access_log_flat_event_timestamp_state CHECK (
        (event_timestamp IS NULL) = (event_timestamp_validity = 'MISSING')
        AND (event_timestamp_start_pos IS NULL) = (event_timestamp IS NULL)
        AND (event_timestamp_missing_reason IS NOT NULL) = (event_timestamp_validity = 'MISSING')
        AND (event_timestamp_source IS NULL) = (event_timestamp_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (event_timestamp IS NULL OR (event_timestamp <> '' AND event_timestamp_start_pos >= 1
             AND event_timestamp_start_pos + char_length(event_timestamp) - 1 <= event_end_pos))),
    CONSTRAINT access_log_flat_tool_state CHECK (
        (tool IS NULL) = (tool_validity = 'MISSING')
        AND (tool_start_pos IS NULL) = (tool IS NULL)
        AND (tool_missing_reason IS NOT NULL) = (tool_validity = 'MISSING')
        AND (tool_source IS NULL) = (tool_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (tool IS NULL OR (tool <> '' AND tool_start_pos >= 1
             AND tool_start_pos + char_length(tool) - 1 <= event_end_pos))),
    CONSTRAINT access_log_flat_latitude_state CHECK (
        (latitude IS NULL) = (latitude_validity = 'MISSING')
        AND (latitude_start_pos IS NULL) = (latitude IS NULL)
        AND (latitude_missing_reason IS NOT NULL) = (latitude_validity = 'MISSING')
        AND (latitude_source IS NULL) = (latitude_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (latitude IS NULL OR (latitude <> '' AND latitude_start_pos >= 1
             AND latitude_start_pos + char_length(latitude) - 1 <= event_end_pos))),
    CONSTRAINT access_log_flat_longitude_state CHECK (
        (longitude IS NULL) = (longitude_validity = 'MISSING')
        AND (longitude_start_pos IS NULL) = (longitude IS NULL)
        AND (longitude_missing_reason IS NOT NULL) = (longitude_validity = 'MISSING')
        AND (longitude_source IS NULL) = (longitude_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (longitude IS NULL OR (longitude <> '' AND longitude_start_pos >= 1
             AND longitude_start_pos + char_length(longitude) - 1 <= event_end_pos))),
    CONSTRAINT access_log_flat_ip_address_state CHECK (
        (ip_address IS NULL) = (ip_address_validity = 'MISSING')
        AND (ip_address_start_pos IS NULL) = (ip_address IS NULL)
        AND (ip_address_missing_reason IS NOT NULL) = (ip_address_validity = 'MISSING')
        AND (ip_address_source IS NULL) = (ip_address_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (ip_address IS NULL OR (ip_address <> '' AND ip_address_start_pos >= 1
             AND ip_address_start_pos + char_length(ip_address) - 1 <= event_end_pos))),
    CONSTRAINT access_log_flat_action_phrase_state CHECK (
        (action_phrase IS NULL) = (action_phrase_validity = 'MISSING')
        AND (action_phrase_start_pos IS NULL) = (action_phrase IS NULL)
        AND (action_phrase_missing_reason IS NOT NULL) = (action_phrase_validity = 'MISSING')
        AND (action_phrase_source IS NULL) = (action_phrase_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (action_phrase IS NULL OR (action_phrase <> '' AND action_phrase_start_pos >= 1
             AND action_phrase_start_pos + char_length(action_phrase) - 1 <= event_end_pos))),
    CONSTRAINT access_log_flat_status_state CHECK (
        (status IS NULL) = (status_validity = 'MISSING')
        AND (status_start_pos IS NULL) = (status IS NULL)
        AND (status_missing_reason IS NOT NULL) = (status_validity = 'MISSING')
        AND (status_source IS NULL) = (status_missing_reason IS NOT DISTINCT FROM 'absent')
        AND (status IS NULL OR (status <> '' AND status_start_pos >= 1
             AND status_start_pos + char_length(status) - 1 <= event_end_pos))),

    -- typed columns: filled exactly for VALID values
    CONSTRAINT access_log_flat_entity_type_code CHECK (
        (entity_type_code IS NOT NULL) = (entity_type_validity = 'VALID')),
    CONSTRAINT access_log_flat_event_timestamp_typed CHECK (
        (event_timestamp_local IS NOT NULL) = (event_timestamp_validity = 'VALID')
        AND (event_timestamp_utc_offset IS NULL) = (event_timestamp_utc IS NULL)
        AND (event_timestamp_utc_offset IS NULL
             OR (event_timestamp_local IS NOT NULL
                 AND event_timestamp_utc_offset BETWEEN interval '-14 hours' AND interval '14 hours'))
        AND (event_timestamp_shape IS NULL OR event_timestamp IS NOT NULL)),
    CONSTRAINT access_log_flat_latitude_degrees CHECK (
        (latitude_degrees IS NOT NULL) = (latitude_validity = 'VALID')
        AND (latitude_degrees IS NULL OR latitude_degrees BETWEEN -90 AND 90)),
    CONSTRAINT access_log_flat_longitude_degrees CHECK (
        (longitude_degrees IS NOT NULL) = (longitude_validity = 'VALID')
        AND (longitude_degrees IS NULL OR longitude_degrees BETWEEN -180 AND 180)),
    CONSTRAINT access_log_flat_ip_address_typed CHECK (
        (ip_address_inet IS NOT NULL) = (ip_address_validity = 'VALID')
        AND (ip_address_inet IS NULL OR masklen(ip_address_inet) = CASE family(ip_address_inet) WHEN 4 THEN 32 ELSE 128 END)
        AND (ip_address_zone_id IS NULL OR (ip_address_zone_id <> '' AND ip_address_inet IS NOT NULL AND family(ip_address_inet) = 6))),
    CONSTRAINT access_log_flat_status_typed CHECK (
        (status_code IS NOT NULL OR status_word IS NOT NULL) = (status_validity = 'VALID')
        AND (status_code IS NULL OR status_word IS NULL)
        AND (status_code IS NULL OR status_code BETWEEN 100 AND 599)
        AND (status_word IS NULL OR status_word = upper(status_word)))
);

COMMENT ON TABLE log_regex.access_log_flat IS
    'Primary parsed fields of one accepted parser run, one row per raw log: exact extracted text, validity, position, '
    'source slot and missing reason per field, plus typed columns filled only for VALID values.';
-- END Step 5A DDL

-- Domain and column comments: the derivation rules the load must apply (Step 5A sections 4.4 and 4.6) ------------
COMMENT ON DOMAIN log_regex.field_validity_status IS
    'Validity of one parsed field: VALID, INVALID, PLACEHOLDER or MISSING (Step 3A C-07).';
COMMENT ON DOMAIN log_regex.record_validity_status IS
    'Validity of one parsed record: VALID, INVALID or BROKEN.';
COMMENT ON DOMAIN log_regex.missing_reason_code IS
    'Why a field is MISSING: absent (no slot, key or clause), empty (slot present but empty), '
    'sentinel (F2 anonymous / an unspecified resource).';

COMMENT ON COLUMN log_regex.access_log_flat.run_id IS
    'Parser run the row was published from; (run_id, log_id) references parsed_log. '
    'Accepted source run for the first load: 14 (Step 4A).';
COMMENT ON COLUMN log_regex.access_log_flat.entity_type_code IS
    'VALID entity_type only: upper(regexp_replace(entity_type, ''[[:space:]_-]+'', ''_'', ''g'')), exactly the '
    'normalisation of is_valid_entity_type() (every run of whitespace, underscore or hyphen becomes one underscore); '
    'NULL otherwise. References ref_entity_type.';
COMMENT ON COLUMN log_regex.access_log_flat.event_timestamp_shape IS
    'First ref_timestamp_shape (by match_order) whose pattern matches event_timestamp; recorded for every non-NULL '
    'value, VALID and INVALID.';
COMMENT ON COLUMN log_regex.access_log_flat.event_timestamp_local IS
    'VALID event_timestamp only: wall-clock date and time exactly as written, read with the shape group map. The '
    'year-less syslog shape takes parser_run.assumed_year (C-04); epoch values are read as UTC. 12-hour shapes: '
    '12 AM -> 00, 1-11 AM -> 01-11, 12 PM -> 12, 1-11 PM -> 13-23.';
COMMENT ON COLUMN log_regex.access_log_flat.event_timestamp_utc_offset IS
    'VALID event_timestamp only: Z -> 00:00; +hh:mm, -hh:mm, +hhmm or -hhmm -> that offset; epoch -> 00:00. '
    'NULL when the text states no zone, or only a zone abbreviation.';
COMMENT ON COLUMN log_regex.access_log_flat.event_timestamp_utc IS
    'VALID event_timestamp only: (event_timestamp_local - event_timestamp_utc_offset) AT TIME ZONE ''UTC''; '
    'NULL exactly when the offset is unknown.';
COMMENT ON COLUMN log_regex.access_log_flat.latitude_degrees IS
    'VALID latitude only: signed decimal as written; a hemisphere prefix or suffix gives the sign (S negative); '
    'DMS = d + m/60 + s/3600 computed in numeric and rounded once to 7 decimal places. The load rejects (publishes '
    'nothing) if a decimal or hemisphere value has more than 7 decimal places or DMS seconds have more than 3.';
COMMENT ON COLUMN log_regex.access_log_flat.longitude_degrees IS
    'VALID longitude only: signed decimal as written; a hemisphere prefix or suffix gives the sign (W negative); '
    'DMS = d + m/60 + s/3600 computed in numeric and rounded once to 7 decimal places. The load rejects (publishes '
    'nothing) if a decimal or hemisphere value has more than 7 decimal places or DMS seconds have more than 3.';
COMMENT ON COLUMN log_regex.access_log_flat.ip_address_inet IS
    'VALID ip_address only: split_part(ip_address, ''%'', 1)::inet, the host address without a zone ID. The VALID '
    'flag decides, not castability. Verify as inet values, never as text.';
COMMENT ON COLUMN log_regex.access_log_flat.ip_address_zone_id IS
    'VALID IPv6 address with a zone ID only: the text after % (inet cannot store the zone ID); NULL otherwise.';
COMMENT ON COLUMN log_regex.access_log_flat.status_code IS
    'VALID status only: the 3-digit HTTP code of "403" or "403 Forbidden"; NULL for word statuses.';
COMMENT ON COLUMN log_regex.access_log_flat.status_word IS
    'VALID status only: upper(status) for word statuses (ok -> OK) and the check mark U+2713 as written; '
    'NULL for codes.';

-- Post-condition inside the transaction: a wrong result rolls everything back -----------------------------------
DO $$
DECLARE
    v_columns     bigint;
    v_rows        bigint;
    v_indexes     bigint;
    v_constraints text;
BEGIN
    SELECT count(*) INTO v_columns
    FROM pg_attribute WHERE attrelid = 'log_regex.access_log_flat'::regclass AND attnum > 0 AND NOT attisdropped;
    SELECT count(*) INTO v_rows FROM log_regex.access_log_flat;
    SELECT count(*) INTO v_indexes FROM pg_index WHERE indrelid = 'log_regex.access_log_flat'::regclass;
    SELECT string_agg(s.kind || '=' || s.n, ' ' ORDER BY s.kind) INTO v_constraints
    FROM (SELECT contype::text AS kind, count(*) AS n
          FROM pg_constraint WHERE conrelid = 'log_regex.access_log_flat'::regclass GROUP BY contype) AS s;

    IF v_columns <> 71 OR v_rows <> 0 OR v_indexes <> 1 OR v_constraints IS DISTINCT FROM 'c=22 f=4 p=1' THEN
        RAISE EXCEPTION 'sql/28_create_access_log_flat.sql: unexpected result (columns %, rows %, indexes %, constraints %); rolled back',
            v_columns, v_rows, v_indexes, v_constraints
            USING ERRCODE = 'LR005';
    END IF;
END
$$;

COMMIT;

SELECT c.oid::regclass                                                                             AS created_table,
       (SELECT count(*) FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS columns,
       (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p')         AS primary_keys,
       (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f')         AS foreign_keys,
       (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'c')         AS check_constraints,
       (SELECT count(*) FROM pg_index i WHERE i.indrelid = c.oid)                                  AS indexes,
       (SELECT count(*) FROM log_regex.access_log_flat)                                            AS rows
FROM pg_class c
WHERE c.oid = 'log_regex.access_log_flat'::regclass;
