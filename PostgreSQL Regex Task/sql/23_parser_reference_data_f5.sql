-- =============================================================================
-- Step 3B-7 / 23 - Reference data added for the F5 semicolon-positional parser
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/23_parser_reference_data_f5.sql
--
-- Adds the F5 column map (Step 3A section 7.5) to ref_key_alias and sets ref_data_version to 3B-7.1.
-- For F5 the key is the 1-based column number:
--   1 timestamp, 2 entity_type, 3 email_address, 4 tool, 5 resource_url, 6 latitude, 7 longitude,
--   8 ip_address, 9 action_phrase, 10 status
-- Latitude and longitude are labelled by their columns (6, 7), so no coordinate pair is ever reordered (C-03).
-- Re-runnable (replaces the F5 rows only).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DELETE FROM log_regex.ref_key_alias WHERE format_family = 'F5';

INSERT INTO log_regex.ref_key_alias VALUES
    ('F5', '1',  'event_timestamp', 'primary', NULL),
    ('F5', '2',  'entity_type',     'primary', NULL),
    ('F5', '3',  'email_address',   'primary', NULL),
    ('F5', '4',  'tool',            'primary', NULL),
    ('F5', '5',  'resource_url',    'primary', NULL),
    ('F5', '6',  'latitude',        'primary', NULL),
    ('F5', '7',  'longitude',       'primary', NULL),
    ('F5', '8',  'ip_address',      'primary', NULL),
    ('F5', '9',  'action_phrase',   'primary', NULL),
    ('F5', '10', 'status',          'primary', NULL);

DELETE FROM log_regex.ref_data_version;
INSERT INTO log_regex.ref_data_version VALUES
    ('3B-7.1', 'F1, F3, F4 key aliases and F5 column map; F2 log levels and sentinel phrases; shared vocabularies');

COMMIT;

SELECT format_family, role, count(*) AS aliases
FROM log_regex.ref_key_alias
GROUP BY format_family, role
ORDER BY format_family, role;

SELECT version FROM log_regex.ref_data_version;
