-- =============================================================================
-- Step 3B-3 / 07 - Parser reference data (vocabularies are data, Step 3A P-06)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/07_parser_reference_data.sql
--
-- Re-runnable: drops and recreates only the ref_* tables (never the raw input or the answer key).
-- Key aliases are loaded for F1 only in this step.
-- Refuses to run (SQLSTATE LR003) while log_regex.access_log_flat exists (Step 5A review, see the guard below).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

-- BEGIN access_log_flat guard
-- The DROP below uses CASCADE. If the published flat table exists, CASCADE would silently remove its foreign keys to
-- ref_entity_type and ref_timestamp_shape. Stop before anything is dropped.
DO $$
BEGIN
    IF to_regclass('log_regex.access_log_flat') IS NOT NULL THEN
        RAISE EXCEPTION 'sql/07_parser_reference_data.sql refused: log_regex.access_log_flat exists; DROP ... CASCADE would silently remove its foreign keys'
            USING ERRCODE = 'LR003',
                  HINT    = 'Rebuild reference tables only after deliberately removing or unpublishing log_regex.access_log_flat.';
    END IF;
END
$$;
-- END access_log_flat guard

BEGIN;

DROP TABLE IF EXISTS log_regex.ref_data_version,
                     log_regex.ref_key_alias,
                     log_regex.ref_field,
                     log_regex.ref_placeholder_token,
                     log_regex.ref_entity_type,
                     log_regex.ref_status_word,
                     log_regex.ref_http_reason,
                     log_regex.ref_resource_scheme,
                     log_regex.ref_timestamp_shape,
                     log_regex.ref_month_name CASCADE;

CREATE TABLE log_regex.ref_data_version (
    version text PRIMARY KEY,
    note    text NOT NULL
);
INSERT INTO log_regex.ref_data_version VALUES
    ('3B-3.1', 'F1 key aliases; shared vocabularies for all validators');

-- The 10 target fields, their output order and validator label ---------------
CREATE TABLE log_regex.ref_field (
    field_name  text     PRIMARY KEY,
    field_order smallint NOT NULL UNIQUE,
    validator   text     NOT NULL
);
INSERT INTO log_regex.ref_field VALUES
    ('entity_type',      1, 'VAL-ENT'),
    ('email_address',    2, 'VAL-EML'),
    ('resource_url',     3, 'VAL-RES'),
    ('event_timestamp',  4, 'VAL-TS'),
    ('tool',             5, 'VAL-TL'),
    ('latitude',         6, 'VAL-GEO'),
    ('longitude',        7, 'VAL-GEO'),
    ('ip_address',       8, 'VAL-IP'),
    ('action_phrase',    9, 'VAL-ACT'),
    ('status',          10, 'VAL-STS');

-- Key aliases (Step 3A section 7.1) --------------------------------------------------
CREATE TABLE log_regex.ref_key_alias (
    format_family  text NOT NULL,
    key_name       text NOT NULL,
    field_name     text REFERENCES log_regex.ref_field (field_name),
    role           text NOT NULL CHECK (role IN ('primary', 'secondary', 'coordinate_pair')),
    secondary_kind text,
    PRIMARY KEY (format_family, key_name),
    CHECK (   (role = 'primary'         AND field_name IS NOT NULL AND secondary_kind IS NULL)
           OR (role = 'secondary'       AND field_name IS NOT NULL AND secondary_kind IS NOT NULL)
           OR (role = 'coordinate_pair' AND field_name IS NULL     AND secondary_kind IS NULL))
);
INSERT INTO log_regex.ref_key_alias VALUES
    ('F1', 'entity',       'entity_type',     'primary',   NULL),
    ('F1', 'entity_type',  'entity_type',     'primary',   NULL),
    ('F1', 'type',         'entity_type',     'primary',   NULL),
    ('F1', 'email',        'email_address',   'primary',   NULL),
    ('F1', 'user',         'email_address',   'primary',   NULL),
    ('F1', 'principal',    'email_address',   'primary',   NULL),
    ('F1', 'action',       'action_phrase',   'primary',   NULL),
    ('F1', 'event',        'action_phrase',   'primary',   NULL),
    ('F1', 'resource',     'resource_url',    'primary',   NULL),
    ('F1', 'url',          'resource_url',    'primary',   NULL),
    ('F1', 'path',         'resource_url',    'primary',   NULL),
    ('F1', 'tool',         'tool',            'primary',   NULL),
    ('F1', 'client',       'tool',            'primary',   NULL),
    ('F1', 'agent',        'tool',            'primary',   NULL),
    ('F1', 'ip',           'ip_address',      'primary',   NULL),
    ('F1', 'src_ip',       'ip_address',      'primary',   NULL),
    ('F1', 'client_ip',    'ip_address',      'primary',   NULL),
    ('F1', 'lat',          'latitude',        'primary',   NULL),
    ('F1', 'latitude',     'latitude',        'primary',   NULL),
    ('F1', 'lon',          'longitude',       'primary',   NULL),
    ('F1', 'lng',          'longitude',       'primary',   NULL),
    ('F1', 'longitude',    'longitude',       'primary',   NULL),
    ('F1', 'status',       'status',          'primary',   NULL),
    ('F1', 'result',       'status',          'primary',   NULL),
    ('F1', 'outcome',      'status',          'primary',   NULL),
    ('F1', 'geo',          NULL,              'coordinate_pair', NULL),
    ('F1', 'ingested_at',  'event_timestamp', 'secondary', 'ingested_at'),
    ('F1', 'retry_action', 'action_phrase',   'secondary', 'retry_action');

-- Placeholder tokens (Step 3A section 10.1 step 4), case-sensitive --------------------
CREATE TABLE log_regex.ref_placeholder_token (
    token text PRIMARY KEY,
    note  text NOT NULL
);
INSERT INTO log_regex.ref_placeholder_token VALUES
    ('-',       'dash'),
    ('N/A',     'not available'),
    ('NULL',    'uppercase NULL text'),
    ('null',    'JSON null'),
    ('unknown', 'unknown value');

-- Entity types (VAL-ENT) ---------------------------------------------------------
CREATE TABLE log_regex.ref_entity_type (entity_type text PRIMARY KEY);
INSERT INTO log_regex.ref_entity_type VALUES
    ('USER'), ('CUSTOMER'), ('ADMIN'), ('SERVICE_ACCOUNT'), ('API_CLIENT'), ('GUEST'), ('BOT');

-- Status words (VAL-STS), compared upper-cased ------------------------------------
CREATE TABLE log_regex.ref_status_word (status_word text PRIMARY KEY);
INSERT INTO log_regex.ref_status_word VALUES
    ('SUCCESS'), ('OK'), ('ALLOWED'), ('DENIED'), ('FAILED'), ('FAIL'), ('BLOCKED'), ('PASS'), ('REJECTED'),
    ('PENDING'), ('NOT_FOUND'), ('ERROR'), ('RATE_LIMITED'), ('THROTTLED'), ('EXPIRED'), ('TIMEOUT'),
    ('CHALLENGE'), ('DECLINED');

-- HTTP reason phrases (VAL-STS) --------------------------------------------------
CREATE TABLE log_regex.ref_http_reason (
    status_code smallint PRIMARY KEY CHECK (status_code BETWEEN 100 AND 599),
    reason      text     NOT NULL
);
INSERT INTO log_regex.ref_http_reason VALUES
    (200, 'OK'), (201, 'Created'), (202, 'Accepted'), (204, 'No Content'), (302, 'Found'),
    (401, 'Unauthorized'), (403, 'Forbidden'), (404, 'Not Found'), (429, 'Too Many Requests'),
    (500, 'Internal Server Error'), (502, 'Bad Gateway'), (503, 'Service Unavailable');

-- Resource schemes (VAL-RES) -----------------------------------------------------
CREATE TABLE log_regex.ref_resource_scheme (scheme text PRIMARY KEY);
INSERT INTO log_regex.ref_resource_scheme VALUES
    ('http'), ('https'), ('ftp'), ('s3'), ('db'), ('postgres'), ('vpn');

-- Month names (VAL-TS) -------------------------------------------------------------
CREATE TABLE log_regex.ref_month_name (
    month_abbr text     PRIMARY KEY,
    month_no   smallint NOT NULL UNIQUE CHECK (month_no BETWEEN 1 AND 12)
);
INSERT INTO log_regex.ref_month_name VALUES
    ('Jan', 1), ('Feb', 2), ('Mar', 3), ('Apr', 4), ('May', 5), ('Jun', 6),
    ('Jul', 7), ('Aug', 8), ('Sep', 9), ('Oct', 10), ('Nov', 11), ('Dec', 12);

-- Timestamp shapes (VAL-TS): pattern + capture-group map -----------------------------
-- Group numbers refer to regexp_match() result positions. NULL year_group = year-less shape
-- (uses the run parameter assumed_year, Step 3A C-04).
CREATE TABLE log_regex.ref_timestamp_shape (
    shape_name       text     PRIMARY KEY,
    match_order      smallint NOT NULL UNIQUE,
    pattern          text     NOT NULL,
    is_epoch         boolean  NOT NULL DEFAULT false,
    year_group       smallint,
    month_group      smallint,
    month_name_group smallint,
    day_group        smallint,
    hour_group       smallint,
    minute_group     smallint,
    second_group     smallint,
    ampm_group       smallint,
    example          text     NOT NULL
);
INSERT INTO log_regex.ref_timestamp_shape
    (shape_name, match_order, pattern, is_epoch, year_group, month_group, month_name_group, day_group,
     hour_group, minute_group, second_group, ampm_group, example)
VALUES
    ('epoch_milliseconds', 1, '^[0-9]{13}$', true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        '1773480137482'),
    ('epoch_seconds', 2, '^[0-9]{10}$', true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        '1773480137'),
    ('iso8601', 3,
        '^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2}):([0-9]{2})([.][0-9]{1,6})?([Zz]|[+-][0-9]{2}:[0-9]{2}| [A-Z]{2,5})?$',
        false, 1, 2, NULL, 3, 4, 5, 6, NULL, '2026-03-15T08:01:02.123456+05:30'),
    ('apache_clf', 4,
        '^([0-9]{2})/([A-Z][a-z]{2})/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2}) [+-][0-9]{4}$',
        false, 3, NULL, 2, 1, 4, 5, 6, NULL, '14/Mar/2026:09:22:17 +0530'),
    ('us_mdy_12h', 5,
        '^([0-9]{1,2})/([0-9]{1,2})/([0-9]{4}) ([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))? ([AP]M)$',
        false, 3, 1, NULL, 2, 4, 5, 7, 8, '03/04/2026 09:30:00 AM'),
    ('syslog_rfc3164', 6,
        '^([A-Z][a-z]{2}) ([ 0-9][0-9]) ([0-9]{2}):([0-9]{2}):([0-9]{2})$',
        false, NULL, NULL, 1, 2, 3, 4, 5, NULL, 'Jan  9 14:02:11'),
    ('dmy_dash', 7,
        '^([0-9]{2})-([0-9]{2})-([0-9]{4}) ([0-9]{2}):([0-9]{2})(:([0-9]{2}))?$',
        false, 3, 2, NULL, 1, 4, 5, 7, NULL, '23-01-2026 12:02'),
    ('ymd_slash', 8,
        '^([0-9]{4})/([0-9]{2})/([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})$',
        false, 1, 2, NULL, 3, 4, 5, 6, NULL, '2026/05/14 01:26:02'),
    ('compact_basic', 9,
        '^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})$',
        false, 1, 2, NULL, 3, 4, 5, 6, NULL, '20260209T173435');

COMMIT;

SELECT 'ref_field' AS table_name, count(*) AS rows FROM log_regex.ref_field
UNION ALL SELECT 'ref_key_alias (F1)', count(*) FROM log_regex.ref_key_alias
UNION ALL SELECT 'ref_placeholder_token', count(*) FROM log_regex.ref_placeholder_token
UNION ALL SELECT 'ref_entity_type', count(*) FROM log_regex.ref_entity_type
UNION ALL SELECT 'ref_status_word', count(*) FROM log_regex.ref_status_word
UNION ALL SELECT 'ref_http_reason', count(*) FROM log_regex.ref_http_reason
UNION ALL SELECT 'ref_resource_scheme', count(*) FROM log_regex.ref_resource_scheme
UNION ALL SELECT 'ref_month_name', count(*) FROM log_regex.ref_month_name
UNION ALL SELECT 'ref_timestamp_shape', count(*) FROM log_regex.ref_timestamp_shape;
