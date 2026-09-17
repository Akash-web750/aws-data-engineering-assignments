-- =============================================================================
-- Step 3B-5 / 17 - Reference data added for the F3 syslog + JSON parser
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/17_parser_reference_data_f3.sql
--
-- Adds the F3 key aliases (Step 3A section 7.3) to ref_key_alias and sets ref_data_version to 3B-5.1.
-- F3 key names are JSON key paths as built by f3_candidates():
--   top-level key            entity_type, user, src_ip, ...
--   key inside an object     geo.lat, geo.lng
--   array element            geometry.coordinates[0]   (0-based)
-- Coordinate order (C-03): geo.lat / geo.lng and latitude / longitude are labelled; GeoJSON
-- geometry.coordinates is [longitude, latitude]; the location string "lat,lon" is latitude first.
-- geo is a coordinate_pair only when its value is a scalar (e.g. "geo":null applies to both axes);
-- a geo object is read through geo.lat / geo.lng.
-- Re-runnable (replaces the F3 rows only).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DELETE FROM log_regex.ref_key_alias WHERE format_family = 'F3';

INSERT INTO log_regex.ref_key_alias VALUES
    ('F3', 'entity_type',             'entity_type',   'primary',         NULL),
    ('F3', 'entity',                  'entity_type',   'primary',         NULL),
    ('F3', 'principal_type',          'entity_type',   'primary',         NULL),
    ('F3', 'user',                    'email_address', 'primary',         NULL),
    ('F3', 'principal',               'email_address', 'primary',         NULL),
    ('F3', 'email',                   'email_address', 'primary',         NULL),
    ('F3', 'resource',                'resource_url',  'primary',         NULL),
    ('F3', 'target',                  'resource_url',  'primary',         NULL),
    ('F3', 'res',                     'resource_url',  'primary',         NULL),
    ('F3', 'tool',                    'tool',          'primary',         NULL),
    ('F3', 'user_agent',              'tool',          'primary',         NULL),
    ('F3', 'client',                  'tool',          'primary',         NULL),
    ('F3', 'src_ip',                  'ip_address',    'primary',         NULL),
    ('F3', 'ip',                      'ip_address',    'primary',         NULL),
    ('F3', 'remote_addr',             'ip_address',    'primary',         NULL),
    ('F3', 'msg',                     'action_phrase', 'primary',         NULL),
    ('F3', 'event',                   'action_phrase', 'primary',         NULL),
    ('F3', 'action',                  'action_phrase', 'primary',         NULL),
    ('F3', 'status',                  'status',        'primary',         NULL),
    ('F3', 'result',                  'status',        'primary',         NULL),
    ('F3', 'outcome',                 'status',        'primary',         NULL),
    ('F3', 'http_status',             'status',        'primary',         NULL),
    ('F3', 'latitude',                'latitude',      'primary',         NULL),
    ('F3', 'longitude',               'longitude',     'primary',         NULL),
    ('F3', 'geo.lat',                 'latitude',      'primary',         NULL),
    ('F3', 'geo.lng',                 'longitude',     'primary',         NULL),
    ('F3', 'geometry.coordinates[0]', 'longitude',     'primary',         NULL),
    ('F3', 'geometry.coordinates[1]', 'latitude',      'primary',         NULL),
    ('F3', 'location',                NULL,            'coordinate_pair', NULL),
    ('F3', 'geo',                     NULL,            'coordinate_pair', NULL);

DELETE FROM log_regex.ref_data_version;
INSERT INTO log_regex.ref_data_version VALUES
    ('3B-5.1', 'F1 and F3 key aliases; F2 log levels and sentinel phrases; shared vocabularies for all validators');

COMMIT;

SELECT format_family, role, count(*) AS aliases
FROM log_regex.ref_key_alias
GROUP BY format_family, role
ORDER BY format_family, role;

SELECT version FROM log_regex.ref_data_version;
