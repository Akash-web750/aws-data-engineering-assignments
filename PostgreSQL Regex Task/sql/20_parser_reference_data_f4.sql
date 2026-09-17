-- =============================================================================
-- Step 3B-6 / 20 - Reference data added for the F4 web-server access-log parser
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/20_parser_reference_data_f4.sql
--
-- Adds the F4 extras keys (Step 3A section 7.4, slot 10) to ref_key_alias and sets ref_data_version to 3B-6.1.
-- The extras part of an F4 line is split where each of these keys starts (" key="), so the key list is also the
-- boundary list used by f4_candidates().
--   type / entity / role   entity_type   (values may contain spaces: Service Account, API Client)
--   user                   email_address (user=<...>; takes precedence over the remote-user slot)
--   lat / lon              latitude / longitude (labelled)
--   loc / geo              coordinate pairs: loc=POINT(lon lat) is longitude first, geo=lat,lon latitude first (C-03)
--   xff                    ip_address: the first X-Forwarded-For entry is the original client (D-03)
--   msg                    action_phrase (msg="...")
-- The positional slots (IP field, ident, remote user, [timestamp], "request", status, bytes, "referer",
-- "user agent") are fixed by position and are not listed here.
-- Re-runnable (replaces the F4 rows only).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DELETE FROM log_regex.ref_key_alias WHERE format_family = 'F4';

INSERT INTO log_regex.ref_key_alias VALUES
    ('F4', 'type',   'entity_type',   'primary',         NULL),
    ('F4', 'entity', 'entity_type',   'primary',         NULL),
    ('F4', 'role',   'entity_type',   'primary',         NULL),
    ('F4', 'user',   'email_address', 'primary',         NULL),
    ('F4', 'lat',    'latitude',      'primary',         NULL),
    ('F4', 'lon',    'longitude',     'primary',         NULL),
    ('F4', 'loc',    NULL,            'coordinate_pair', NULL),
    ('F4', 'geo',    NULL,            'coordinate_pair', NULL),
    ('F4', 'xff',    'ip_address',    'primary',         NULL),
    ('F4', 'msg',    'action_phrase', 'primary',         NULL);

DELETE FROM log_regex.ref_data_version;
INSERT INTO log_regex.ref_data_version VALUES
    ('3B-6.1', 'F1, F3 and F4 key aliases; F2 log levels and sentinel phrases; shared vocabularies for all validators');

COMMIT;

SELECT format_family, role, count(*) AS aliases
FROM log_regex.ref_key_alias
GROUP BY format_family, role
ORDER BY format_family, role;

SELECT version FROM log_regex.ref_data_version;
