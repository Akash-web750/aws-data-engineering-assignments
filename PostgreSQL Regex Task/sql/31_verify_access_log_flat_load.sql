-- =============================================================================
-- Step 5B / 31 - Verify the loaded log_regex.access_log_flat (read-only)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/31_verify_access_log_flat_load.sql
--   optional: -v source_run_id=<run>   (default 14)
--
-- Run after sql/30_load_access_log_flat.sql, together with sql/27 (foreign-key definitions) and sql/29 (structure).
-- READ ONLY transaction, rolled back; TimeZone UTC for the timestamp oracles. Exits non-zero (SQLSTATE LR009) unless
-- every check passes. Expected values come from the parser output of the source run and from the answer key, not from
-- the loaded table; typed values are compared with independent oracles:
--   V-01 rows            one row per raw log, all from the source run, one load time
--   V-02 foreign keys    4 validated; no orphan log, run/log, entity code or timestamp shape
--   V-03 CHECKs          22 validated; every stored CHECK expression re-evaluated on every row (0 violations)
--   V-04 correspondence  50 field columns = parsed_field; record columns = parsed_log; answer key values and validity
--   V-05 typed columns   entity code; shape = first match; local time vs to_timestamp / ISO text casts (12-hour
--                        included); offset vs interval casts; instant vs extract(epoch) / timestamptz input with
--                        TZH:TZM; coordinates vs separate numeric parsing (no rounding for decimal and hemisphere
--                        forms, DMS rounded once) and the precision rule; inet equality and zone ID; status code/word
--   V-06 record validity counts equal parsed_log and the answer key; record-validity rule recomputed
--   V-07 field validity  counts per field equal parsed_field and the answer key
--   V-08 positions       exact substrings of raw_log; within the event scope and the raw text
--   V-09 NULLs / values  MISSING <=> SQL NULL; no empty strings; literal NULL/null tokens kept as text; NULLs only where
--                        the design allows them; typed values only for VALID values
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\if :{?source_run_id}
\else
    \set source_run_id 14
\endif

BEGIN TRANSACTION READ ONLY;

SET LOCAL search_path = pg_catalog, pg_temp;
SET LOCAL TimeZone = 'UTC';
SELECT set_config('flat_load_check.source_run_id', :'source_run_id', true) AS source_run_id;

\echo '== Record validity: loaded table, parser run, answer key'
SELECT v.record_validity,
       (SELECT count(*) FROM log_regex.access_log_flat a WHERE a.record_validity::text = v.record_validity) AS loaded,
       (SELECT count(*) FROM log_regex.parsed_log l
        WHERE l.run_id = current_setting('flat_load_check.source_run_id')::bigint AND l.record_validity = v.record_validity) AS parser_run,
       (SELECT count(*) FROM log_regex.expected_fields e WHERE e.record_validity = v.record_validity) AS answer_key
FROM (VALUES ('VALID'), ('INVALID'), ('BROKEN')) AS v (record_validity);

\echo '== Field validity in the loaded table'
SELECT x.field_name,
       count(*) FILTER (WHERE x.validity = 'VALID') AS valid, count(*) FILTER (WHERE x.validity = 'INVALID') AS invalid,
       count(*) FILTER (WHERE x.validity = 'PLACEHOLDER') AS placeholder, count(*) FILTER (WHERE x.validity = 'MISSING') AS missing,
       count(x.value) AS non_null_values, count(*) AS total
FROM log_regex.access_log_flat a
CROSS JOIN LATERAL (VALUES
    (1, 'entity_type', a.entity_type_validity::text, a.entity_type), (2, 'email_address', a.email_address_validity::text, a.email_address),
    (3, 'resource_url', a.resource_url_validity::text, a.resource_url), (4, 'event_timestamp', a.event_timestamp_validity::text, a.event_timestamp),
    (5, 'tool', a.tool_validity::text, a.tool), (6, 'latitude', a.latitude_validity::text, a.latitude),
    (7, 'longitude', a.longitude_validity::text, a.longitude), (8, 'ip_address', a.ip_address_validity::text, a.ip_address),
    (9, 'action_phrase', a.action_phrase_validity::text, a.action_phrase), (10, 'status', a.status_validity::text, a.status)
) AS x (field_order, field_name, validity, value)
GROUP BY x.field_order, x.field_name ORDER BY x.field_order;

\echo '== Typed columns'
SELECT count(entity_type_code) AS entity_code, count(event_timestamp_shape) AS ts_shape, count(event_timestamp_local) AS ts_local,
       count(event_timestamp_utc_offset) AS ts_offset, count(event_timestamp_utc) AS ts_utc,
       count(latitude_degrees) AS lat, count(longitude_degrees) AS lon, count(ip_address_inet) AS inet,
       count(ip_address_zone_id) AS zone_id, count(status_code) AS status_code, count(status_word) AS status_word
FROM log_regex.access_log_flat;

\echo '== Timestamps (VALID): shape, offset and instant presence'
SELECT event_timestamp_shape AS shape, count(*) AS valid, count(event_timestamp_utc_offset) AS with_offset,
       count(event_timestamp_utc) AS with_instant, min(event_timestamp) AS example_text, min(event_timestamp_local) AS earliest_local
FROM log_regex.access_log_flat WHERE event_timestamp_validity = 'VALID' GROUP BY 1 ORDER BY 1;

\echo '== 12-hour values (us_mdy_12h, VALID)'
SELECT substring(event_timestamp FROM ' ([AP]M)$') AS ampm, substring(event_timestamp FROM ' ([0-9]{1,2}):') AS hour_text,
       extract(hour FROM event_timestamp_local) AS stored_hour, count(*) AS n
FROM log_regex.access_log_flat
WHERE event_timestamp_shape = 'us_mdy_12h' AND event_timestamp_validity = 'VALID'
  AND substring(event_timestamp FROM ' ([0-9]{1,2}):')::integer IN (1, 11, 12)
GROUP BY 1, 2, 3 ORDER BY 1, 2;

\echo '== Examples of typed values'
SELECT log_id, event_timestamp, event_timestamp_shape, event_timestamp_local, event_timestamp_utc_offset, event_timestamp_utc
FROM log_regex.access_log_flat
WHERE log_id IN (SELECT min(log_id) FROM log_regex.access_log_flat WHERE event_timestamp_validity = 'VALID'
                 GROUP BY event_timestamp_shape, event_timestamp_utc_offset IS NULL)
ORDER BY event_timestamp_shape, log_id;
SELECT log_id, latitude, latitude_degrees, longitude, longitude_degrees
FROM log_regex.access_log_flat
WHERE log_id IN (SELECT min(log_id) FROM log_regex.access_log_flat
                 WHERE latitude_validity = 'VALID' GROUP BY substring(latitude FROM '[NS"]|' || chr(8243)), latitude LIKE '-%')
ORDER BY log_id;
SELECT log_id, ip_address, ip_address_inet, ip_address_zone_id, status, status_code, status_word, entity_type, entity_type_code
FROM log_regex.access_log_flat
WHERE ip_address_zone_id IS NOT NULL OR status = chr(10003) OR log_id IN (SELECT min(log_id) FROM log_regex.access_log_flat GROUP BY family(ip_address_inet))
ORDER BY log_id;

\echo '== Verdict'
DO $verify$
DECLARE
    v_failed    text[] := '{}';
    v_checks    integer := 0;
    v_violation bigint;
    v_total     bigint := 0;
    v_detail    text := '';
    chk         record;
BEGIN
    IF to_regclass('log_regex.access_log_flat') IS NULL THEN
        RAISE EXCEPTION 'access_log_flat load check FAILED: log_regex.access_log_flat does not exist' USING ERRCODE = 'LR009';
    END IF;

    FOR chk IN
        WITH params AS (
            SELECT pr.run_id, pr.assumed_year
            FROM log_regex.parser_run pr
            WHERE pr.run_id = current_setting('flat_load_check.source_run_id')::bigint
        ),
        a AS (SELECT * FROM log_regex.access_log_flat),
        u AS (
            SELECT a.log_id, a.event_end_pos, x.*
            FROM a
            CROSS JOIN LATERAL (VALUES
                ('entity_type',     a.entity_type,     a.entity_type_validity::text,     a.entity_type_start_pos,     a.entity_type_source,     a.entity_type_missing_reason::text),
                ('email_address',   a.email_address,   a.email_address_validity::text,   a.email_address_start_pos,   a.email_address_source,   a.email_address_missing_reason::text),
                ('resource_url',    a.resource_url,    a.resource_url_validity::text,    a.resource_url_start_pos,    a.resource_url_source,    a.resource_url_missing_reason::text),
                ('event_timestamp', a.event_timestamp, a.event_timestamp_validity::text, a.event_timestamp_start_pos, a.event_timestamp_source, a.event_timestamp_missing_reason::text),
                ('tool',            a.tool,            a.tool_validity::text,            a.tool_start_pos,            a.tool_source,            a.tool_missing_reason::text),
                ('latitude',        a.latitude,        a.latitude_validity::text,        a.latitude_start_pos,        a.latitude_source,        a.latitude_missing_reason::text),
                ('longitude',       a.longitude,       a.longitude_validity::text,       a.longitude_start_pos,       a.longitude_source,       a.longitude_missing_reason::text),
                ('ip_address',      a.ip_address,      a.ip_address_validity::text,      a.ip_address_start_pos,      a.ip_address_source,      a.ip_address_missing_reason::text),
                ('action_phrase',   a.action_phrase,   a.action_phrase_validity::text,   a.action_phrase_start_pos,   a.action_phrase_source,   a.action_phrase_missing_reason::text),
                ('status',          a.status,          a.status_validity::text,          a.status_start_pos,          a.status_source,          a.status_missing_reason::text)
            ) AS x (field_name, value, validity, start_pos, slot_id, missing_reason)
        ),
        p AS (
            SELECT f.log_id, f.field_name, f.value, f.validity, f.start_pos, f.slot_id, f.missing_reason
            FROM log_regex.parsed_field f JOIN params ON params.run_id = f.run_id
        ),
        k AS (
            SELECT e.log_id, x.*
            FROM log_regex.expected_fields e
            CROSS JOIN LATERAL (VALUES
                ('entity_type', e.entity_type, e.entity_type_validity), ('email_address', e.email_address, e.email_address_validity),
                ('resource_url', e.resource_url, e.resource_url_validity), ('event_timestamp', e.event_timestamp, e.event_timestamp_validity),
                ('tool', e.tool, e.tool_validity), ('latitude', e.latitude, e.latitude_validity),
                ('longitude', e.longitude, e.longitude_validity), ('ip_address', e.ip_address, e.ip_address_validity),
                ('action_phrase', e.action_phrase, e.action_phrase_validity), ('status', e.status, e.status_validity)
            ) AS x (field_name, value, validity)
        ),
        ts AS (
            SELECT a.log_id, a.event_timestamp AS v, a.event_timestamp_validity::text AS validity, a.event_timestamp_shape,
                   a.event_timestamp_local, a.event_timestamp_utc_offset, a.event_timestamp_utc,
                   (SELECT s.shape_name FROM log_regex.ref_timestamp_shape s
                    WHERE a.event_timestamp ~ s.pattern ORDER BY s.match_order LIMIT 1) AS first_shape
            FROM a WHERE a.event_timestamp IS NOT NULL
        ),
        ts_oracle AS (
            SELECT t.*,
                   CASE WHEN t.validity <> 'VALID' THEN NULL
                        WHEN t.first_shape = 'epoch_seconds'      THEN timestamp '1970-01-01 00:00:00' + t.v::bigint * interval '1 second'
                        WHEN t.first_shape = 'epoch_milliseconds' THEN timestamp '1970-01-01 00:00:00' + t.v::bigint * interval '1 millisecond'
                        WHEN t.first_shape = 'iso8601' THEN
                             (substring(t.v FROM '^([0-9]{4}-[0-9]{2}-[0-9]{2})') || ' '
                              || substring(t.v FROM '^.{11}([0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.][0-9]+)?)'))::timestamp(6)
                        WHEN t.first_shape = 'apache_clf'     THEN to_timestamp(left(t.v, 20), 'DD/Mon/YYYY:HH24:MI:SS')::timestamp
                        WHEN t.first_shape = 'us_mdy_12h'     THEN
                             to_timestamp(t.v, CASE WHEN t.v ~ ':[0-9]{2}:[0-9]{2} [AP]M$' THEN 'MM/DD/YYYY HH12:MI:SS AM'
                                                    ELSE 'MM/DD/YYYY HH12:MI AM' END)::timestamp
                        WHEN t.first_shape = 'syslog_rfc3164' THEN to_timestamp(params.assumed_year || ' ' || t.v, 'YYYY Mon DD HH24:MI:SS')::timestamp
                        WHEN t.first_shape = 'dmy_dash'       THEN
                             to_timestamp(t.v, CASE WHEN char_length(t.v) = 19 THEN 'DD-MM-YYYY HH24:MI:SS' ELSE 'DD-MM-YYYY HH24:MI' END)::timestamp
                        WHEN t.first_shape = 'ymd_slash'      THEN to_timestamp(t.v, 'YYYY/MM/DD HH24:MI:SS')::timestamp
                        WHEN t.first_shape = 'compact_basic'  THEN to_timestamp(t.v, 'YYYYMMDD"T"HH24MISS')::timestamp
                   END AS local_oracle,
                   CASE WHEN t.validity <> 'VALID' THEN NULL
                        WHEN t.first_shape IN ('epoch_seconds', 'epoch_milliseconds') THEN interval '0'
                        WHEN t.first_shape = 'iso8601' AND t.v ~ '[Zz]$' THEN interval '0'
                        WHEN t.first_shape = 'iso8601' AND t.v ~ '[+-][0-9]{2}:[0-9]{2}$' THEN right(t.v, 6)::interval
                        WHEN t.first_shape = 'apache_clf' THEN (left(right(t.v, 5), 3) || ':' || right(t.v, 2))::interval
                   END AS offset_oracle,
                   CASE WHEN t.validity <> 'VALID' THEN t.event_timestamp_utc IS NULL
                        WHEN t.first_shape = 'epoch_seconds'      THEN extract(epoch FROM t.event_timestamp_utc) = t.v::numeric
                        WHEN t.first_shape = 'epoch_milliseconds' THEN extract(epoch FROM t.event_timestamp_utc) = t.v::numeric / 1000
                        WHEN t.first_shape = 'iso8601' AND t.v ~ '([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN t.event_timestamp_utc = upper(t.v)::timestamptz
                        WHEN t.first_shape = 'apache_clf' THEN t.event_timestamp_utc = to_timestamp(t.v, 'DD/Mon/YYYY:HH24:MI:SS TZHTZM')
                        ELSE t.event_timestamp_utc IS NULL
                   END AS utc_ok
            FROM ts t CROSS JOIN params
        ),
        geo AS (
            SELECT x.axis, x.value, x.degrees,
                   regexp_match(x.value, '^([0-9]{1,3})' || chr(176) || ' ?([0-9]{2})[''' || chr(8242) || '] ?([0-9]{2}([.][0-9]+)?)["'
                                         || chr(8243) || '] ?([NSEW])$') AS dms
            FROM a
            CROSS JOIN LATERAL (VALUES ('latitude', a.latitude, a.latitude_validity::text, a.latitude_degrees),
                                       ('longitude', a.longitude, a.longitude_validity::text, a.longitude_degrees)) AS x (axis, value, validity, degrees)
            WHERE x.validity = 'VALID'
        ),
        geo_oracle AS (
            SELECT g.*,
                   CASE WHEN g.value ~ '^-?[0-9.]+$' THEN g.value::numeric
                        WHEN g.dms IS NULL THEN CASE WHEN g.value ~ '[SW]' THEN -1 ELSE 1 END * translate(g.value, 'NSEW ', '')::numeric
                        ELSE CASE WHEN g.dms[5] IN ('S', 'W') THEN -1 ELSE 1 END
                             * round(g.dms[1]::numeric + g.dms[2]::numeric(40, 30) / 60 + g.dms[3]::numeric(40, 30) / 3600, 7)
                   END AS oracle,
                   CASE WHEN g.dms IS NULL THEN coalesce(char_length(substring(g.value FROM '[.]([0-9]+)')), 0) END AS decimals,
                   CASE WHEN g.dms IS NOT NULL THEN coalesce(char_length(g.dms[4]) - 1, 0) END             AS dms_second_decimals
            FROM geo g
        ),
        counts AS (
            SELECT (SELECT count(*) FROM log_regex.raw_access_logs) AS raw_rows,
                   (SELECT count(*) FROM p WHERE value IS NOT NULL) AS parser_values
        )
        SELECT c.id, c.name, c.expected, c.actual
        FROM (VALUES
            -- V-01 rows
            ('V-01a', 'rows = raw logs', (SELECT raw_rows FROM counts)::text, (SELECT count(*) FROM a)::text),
            ('V-01b', 'distinct log_id = raw logs', (SELECT raw_rows FROM counts)::text, (SELECT count(DISTINCT log_id) FROM a)::text),
            ('V-01c', 'raw logs without a row', '0', (SELECT count(*) FROM log_regex.raw_access_logs r WHERE NOT EXISTS (SELECT 1 FROM a WHERE a.log_id = r.log_id))::text),
            ('V-01d', 'rows not from the source run', '0', (SELECT count(*) FROM a WHERE a.run_id <> (SELECT run_id FROM params))::text),
            ('V-01e', 'distinct loaded_at values (one load)', '1', (SELECT count(DISTINCT loaded_at) FROM a)::text),
            -- V-02 foreign keys
            ('V-02a', 'foreign keys defined and validated', '4',
                (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = 'log_regex.access_log_flat'::regclass AND k.contype = 'f' AND k.convalidated)::text),
            ('V-02b', 'rows without raw_access_logs row', '0', (SELECT count(*) FROM a WHERE NOT EXISTS (SELECT 1 FROM log_regex.raw_access_logs r WHERE r.log_id = a.log_id))::text),
            ('V-02c', 'rows without parsed_log (run_id, log_id)', '0',
                (SELECT count(*) FROM a WHERE NOT EXISTS (SELECT 1 FROM log_regex.parsed_log l WHERE l.run_id = a.run_id AND l.log_id = a.log_id))::text),
            ('V-02d', 'entity_type_code not in ref_entity_type', '0',
                (SELECT count(*) FROM a WHERE a.entity_type_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM log_regex.ref_entity_type t WHERE t.entity_type = a.entity_type_code))::text),
            ('V-02e', 'event_timestamp_shape not in ref_timestamp_shape', '0',
                (SELECT count(*) FROM a WHERE a.event_timestamp_shape IS NOT NULL AND NOT EXISTS (SELECT 1 FROM log_regex.ref_timestamp_shape s WHERE s.shape_name = a.event_timestamp_shape))::text),
            -- V-03 CHECK constraints (row-level re-evaluation follows below)
            ('V-03a', 'CHECK constraints defined and validated', '22',
                (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = 'log_regex.access_log_flat'::regclass AND k.contype = 'c' AND k.convalidated)::text),
            -- V-04 correspondence with parser output and answer key
            ('V-04a', 'field rows compared (10 per log)', ((SELECT raw_rows FROM counts) * 10)::text, (SELECT count(*) FROM u)::text),
            ('V-04b', 'field differences to parsed_field (value, validity, start_pos, source, missing_reason)', '0',
                ((SELECT count(*) FROM (SELECT log_id, field_name, value, validity, start_pos, slot_id, missing_reason FROM u
                                        EXCEPT ALL SELECT * FROM p) AS x)
               + (SELECT count(*) FROM (SELECT * FROM p
                                        EXCEPT ALL SELECT log_id, field_name, value, validity, start_pos, slot_id, missing_reason FROM u) AS y))::text),
            ('V-04c', 'record differences to parsed_log', '0',
                ((SELECT count(*) FROM (SELECT log_id, run_id, format_family, detection_rule, sub_format, record_validity::text, is_truncated, event_end_pos, diagnostics FROM a
                                        EXCEPT ALL
                                        SELECT log_id, run_id, format_family, detection_rule, sub_format, record_validity, is_truncated, event_end_pos, diagnostics
                                        FROM log_regex.parsed_log WHERE run_id = (SELECT run_id FROM params)) AS x)
               + (SELECT count(*) FROM (SELECT log_id, run_id, format_family, detection_rule, sub_format, record_validity, is_truncated, event_end_pos, diagnostics
                                        FROM log_regex.parsed_log WHERE run_id = (SELECT run_id FROM params)
                                        EXCEPT ALL
                                        SELECT log_id, run_id, format_family, detection_rule, sub_format, record_validity::text, is_truncated, event_end_pos, diagnostics FROM a) AS y))::text),
            ('V-04d', 'values equal to the answer key', ((SELECT raw_rows FROM counts) * 10)::text,
                (SELECT count(*) FROM u JOIN k ON k.log_id = u.log_id AND k.field_name = u.field_name WHERE u.value IS NOT DISTINCT FROM k.value)::text),
            ('V-04e', 'validity equal to the answer key', ((SELECT raw_rows FROM counts) * 10)::text,
                (SELECT count(*) FROM u JOIN k ON k.log_id = u.log_id AND k.field_name = u.field_name WHERE u.validity = k.validity)::text),
            ('V-04f', 'format family and record validity equal to the answer key', (SELECT raw_rows FROM counts)::text,
                (SELECT count(*) FROM a JOIN log_regex.expected_fields e ON e.log_id = a.log_id
                 WHERE e.format_family = a.format_family AND e.record_validity = a.record_validity::text)::text),
            -- V-05 typed columns
            ('V-05a', 'entity_type_code count = VALID entity_type', (SELECT count(*) FROM p WHERE field_name = 'entity_type' AND validity = 'VALID')::text,
                (SELECT count(entity_type_code) FROM a)::text),
            ('V-05b', 'entity_type_code <> upper(regexp_replace(entity_type, [[:space:]_-]+, _))', '0',
                (SELECT count(*) FROM a WHERE a.entity_type_code IS DISTINCT FROM
                    CASE WHEN a.entity_type_validity = 'VALID' THEN upper(regexp_replace(a.entity_type, '[[:space:]_-]+', '_', 'g')) END)::text),
            ('V-05c', 'coded entity types rejected by is_valid_entity_type()', '0',
                (SELECT count(*) FROM a WHERE a.entity_type_code IS NOT NULL AND NOT log_regex.is_valid_entity_type(a.entity_type))::text),
            ('V-05d', 'event_timestamp_shape count = non-NULL event_timestamp', (SELECT count(*) FROM p WHERE field_name = 'event_timestamp' AND value IS NOT NULL)::text,
                (SELECT count(event_timestamp_shape) FROM a)::text),
            ('V-05e', 'shape <> first matching ref_timestamp_shape', '0', (SELECT count(*) FROM ts WHERE event_timestamp_shape IS DISTINCT FROM first_shape)::text),
            ('V-05f', 'event_timestamp_local count = VALID event_timestamp', (SELECT count(*) FROM p WHERE field_name = 'event_timestamp' AND validity = 'VALID')::text,
                (SELECT count(event_timestamp_local) FROM a)::text),
            ('V-05g', 'event_timestamp_local <> oracle (to_timestamp / ISO text / epoch arithmetic)', '0',
                (SELECT count(*) FROM ts_oracle WHERE event_timestamp_local IS DISTINCT FROM local_oracle)::text),
            ('V-05h', '12-hour VALID values equal to_timestamp(MM/DD/YYYY HH12:MI[:SS] AM)', (SELECT count(*) FROM ts_oracle WHERE first_shape = 'us_mdy_12h' AND validity = 'VALID')::text,
                (SELECT count(*) FROM ts_oracle WHERE first_shape = 'us_mdy_12h' AND validity = 'VALID' AND event_timestamp_local = local_oracle)::text),
            ('V-05i', '12 AM stored as hour 00 / 12 PM stored as hour 12',
                (SELECT count(*) FILTER (WHERE v ~ ' 12:[0-9]{2}(:[0-9]{2})? AM$') || ' / ' || count(*) FILTER (WHERE v ~ ' 12:[0-9]{2}(:[0-9]{2})? PM$')
                 FROM ts_oracle WHERE first_shape = 'us_mdy_12h' AND validity = 'VALID'),
                (SELECT count(*) FILTER (WHERE v ~ ' 12:[0-9]{2}(:[0-9]{2})? AM$' AND extract(hour FROM event_timestamp_local) = 0) || ' / '
                     || count(*) FILTER (WHERE v ~ ' 12:[0-9]{2}(:[0-9]{2})? PM$' AND extract(hour FROM event_timestamp_local) = 12)
                 FROM ts_oracle WHERE first_shape = 'us_mdy_12h' AND validity = 'VALID')),
            ('V-05j', 'event_timestamp_utc_offset <> oracle (Z, +-hh:mm, +-hhmm, epoch 0, else NULL)', '0',
                (SELECT count(*) FROM ts_oracle WHERE event_timestamp_utc_offset IS DISTINCT FROM offset_oracle)::text),
            ('V-05k', 'event_timestamp_utc wrong (extract(epoch), timestamptz input, TZHTZM) or not NULL without a zone', '0',
                (SELECT count(*) FROM ts_oracle WHERE utc_ok IS NOT TRUE)::text),
            ('V-05l', 'latitude_degrees count = VALID latitude', (SELECT count(*) FROM p WHERE field_name = 'latitude' AND validity = 'VALID')::text,
                (SELECT count(latitude_degrees) FROM a)::text),
            ('V-05m', 'longitude_degrees count = VALID longitude', (SELECT count(*) FROM p WHERE field_name = 'longitude' AND validity = 'VALID')::text,
                (SELECT count(longitude_degrees) FROM a)::text),
            ('V-05n', 'degrees <> oracle (decimal and hemisphere exact, DMS rounded once to 7 places)', '0',
                (SELECT count(*) FROM geo_oracle WHERE degrees IS DISTINCT FROM oracle)::text),
            ('V-05o', 'precision rule violations (decimal places > 7, DMS second decimals > 3)', '0',
                (SELECT count(*) FROM geo_oracle WHERE decimals > 7 OR dms_second_decimals > 3)::text),
            ('V-05p', 'ip_address_inet count = VALID ip_address', (SELECT count(*) FROM p WHERE field_name = 'ip_address' AND validity = 'VALID')::text,
                (SELECT count(ip_address_inet) FROM a)::text),
            ('V-05q', 'ip_address_inet <> split_part(ip_address, %, 1)::inet (compared as inet)', '0',
                (SELECT count(*) FROM a WHERE a.ip_address_validity = 'VALID' AND a.ip_address_inet IS DISTINCT FROM split_part(a.ip_address, '%', 1)::inet)::text),
            ('V-05r', 'ip_address_zone_id <> text after % (VALID) or set on a non-VALID address', '0',
                (SELECT count(*) FROM a WHERE a.ip_address_zone_id IS DISTINCT FROM
                    CASE WHEN a.ip_address_validity = 'VALID' THEN nullif(split_part(a.ip_address, '%', 2), '') END)::text),
            ('V-05s', 'VALID addresses rejected by is_valid_ip()', '0',
                (SELECT count(*) FROM a WHERE a.ip_address_inet IS NOT NULL AND NOT log_regex.is_valid_ip(a.ip_address))::text),
            ('V-05t', 'status_code count / status_word count',
                (SELECT count(*) FILTER (WHERE value ~ '^[0-9]{3}( .+)?$') || ' / ' || count(*) FILTER (WHERE value !~ '^[0-9]{3}( .+)?$')
                 FROM p WHERE field_name = 'status' AND validity = 'VALID'),
                (SELECT count(status_code) || ' / ' || count(status_word) FROM a)),
            ('V-05u', 'status_code <> 3-digit code, status_word <> upper(status), or word outside ref_status_word and the check mark', '0',
                (SELECT count(*) FROM a WHERE a.status_validity = 'VALID'
                   AND (a.status_code IS DISTINCT FROM CASE WHEN a.status ~ '^[0-9]{3}( .+)?$' THEN left(a.status, 3)::smallint END
                        OR a.status_word IS DISTINCT FROM CASE WHEN a.status !~ '^[0-9]{3}( .+)?$' THEN upper(a.status) END
                        OR (a.status_word IS NOT NULL AND a.status_word <> chr(10003)
                            AND NOT EXISTS (SELECT 1 FROM log_regex.ref_status_word w WHERE w.status_word = a.status_word))))::text),
            ('V-05v', 'typed values on non-VALID fields', '0',
                (SELECT count(*) FROM a WHERE (a.entity_type_validity <> 'VALID' AND a.entity_type_code IS NOT NULL)
                   OR (a.event_timestamp_validity <> 'VALID' AND (a.event_timestamp_local IS NOT NULL OR a.event_timestamp_utc_offset IS NOT NULL OR a.event_timestamp_utc IS NOT NULL))
                   OR (a.latitude_validity <> 'VALID' AND a.latitude_degrees IS NOT NULL)
                   OR (a.longitude_validity <> 'VALID' AND a.longitude_degrees IS NOT NULL)
                   OR (a.ip_address_validity <> 'VALID' AND (a.ip_address_inet IS NOT NULL OR a.ip_address_zone_id IS NOT NULL))
                   OR (a.status_validity <> 'VALID' AND (a.status_code IS NOT NULL OR a.status_word IS NOT NULL)))::text),
            -- V-06 record validity
            ('V-06a', 'record validity counts = parsed_log',
                (SELECT string_agg(record_validity || ' ' || n, ', ' ORDER BY record_validity) FROM
                    (SELECT record_validity, count(*) AS n FROM log_regex.parsed_log WHERE run_id = (SELECT run_id FROM params) GROUP BY 1) AS s),
                (SELECT string_agg(rv || ' ' || n, ', ' ORDER BY rv) FROM (SELECT record_validity::text AS rv, count(*) AS n FROM a GROUP BY 1) AS s)),
            ('V-06b', 'record validity counts = answer key',
                (SELECT string_agg(record_validity || ' ' || n, ', ' ORDER BY record_validity) FROM
                    (SELECT record_validity, count(*) AS n FROM log_regex.expected_fields GROUP BY 1) AS s),
                (SELECT string_agg(rv || ' ' || n, ', ' ORDER BY rv) FROM (SELECT record_validity::text AS rv, count(*) AS n FROM a GROUP BY 1) AS s)),
            ('V-06c', 'record validity <> rule recomputed from format, truncation and field validity', '0',
                (SELECT count(*) FROM a WHERE a.record_validity::text <> CASE
                    WHEN a.format_family = 'NONE' OR a.is_truncated THEN 'BROKEN'
                    WHEN EXISTS (SELECT 1 FROM u WHERE u.log_id = a.log_id AND u.validity = 'INVALID') THEN 'INVALID'
                    ELSE 'VALID' END)::text),
            -- V-07 field validity
            ('V-07a', 'field validity counts = parsed_field',
                (SELECT string_agg(field_name || ' ' || validity || ' ' || n, '; ' ORDER BY field_name, validity) FROM
                    (SELECT field_name, validity, count(*) AS n FROM p GROUP BY 1, 2) AS s),
                (SELECT string_agg(field_name || ' ' || validity || ' ' || n, '; ' ORDER BY field_name, validity) FROM
                    (SELECT field_name, validity, count(*) AS n FROM u GROUP BY 1, 2) AS s)),
            ('V-07b', 'field validity counts = answer key',
                (SELECT string_agg(field_name || ' ' || validity || ' ' || n, '; ' ORDER BY field_name, validity) FROM
                    (SELECT field_name, validity, count(*) AS n FROM k GROUP BY 1, 2) AS s),
                (SELECT string_agg(field_name || ' ' || validity || ' ' || n, '; ' ORDER BY field_name, validity) FROM
                    (SELECT field_name, validity, count(*) AS n FROM u GROUP BY 1, 2) AS s)),
            -- V-08 positions
            ('V-08a', 'stored values = parser values', (SELECT parser_values FROM counts)::text, (SELECT count(*) FROM u WHERE value IS NOT NULL)::text),
            ('V-08b', 'values <> substr(raw_log, start_pos, char_length(value))', '0',
                (SELECT count(*) FROM u JOIN log_regex.raw_access_logs r ON r.log_id = u.log_id
                 WHERE u.value IS NOT NULL AND substr(r.raw_log, u.start_pos, char_length(u.value)) IS DISTINCT FROM u.value)::text),
            ('V-08c', 'values starting before 1 or ending after event_end_pos or after raw_log', '0',
                (SELECT count(*) FROM u JOIN log_regex.raw_access_logs r ON r.log_id = u.log_id
                 WHERE u.value IS NOT NULL AND (u.start_pos < 1 OR u.start_pos + char_length(u.value) - 1 > u.event_end_pos
                                                OR u.start_pos + char_length(u.value) - 1 > char_length(r.raw_log)))::text),
            -- V-09 NULLs and values
            ('V-09a', 'MISSING fields = SQL NULL values = NULL positions',
                (SELECT count(*) FROM p WHERE validity = 'MISSING')::text || ' / ' || (SELECT count(*) FROM p WHERE validity = 'MISSING')::text
                    || ' / ' || (SELECT count(*) FROM p WHERE validity = 'MISSING')::text,
                (SELECT count(*) FILTER (WHERE validity = 'MISSING') || ' / ' || count(*) FILTER (WHERE value IS NULL)
                        || ' / ' || count(*) FILTER (WHERE start_pos IS NULL) FROM u)),
            ('V-09b', 'NULL value on a non-MISSING field, or value on a MISSING field', '0',
                (SELECT count(*) FROM u WHERE (value IS NULL) <> (validity = 'MISSING') OR (start_pos IS NULL) <> (value IS NULL))::text),
            ('V-09c', 'empty-string values or sources', '0', (SELECT count(*) FROM u WHERE value = '' OR slot_id = '')::text),
            ('V-09d', 'literal NULL / null tokens stored as text', (SELECT count(*) FROM p WHERE value IN ('NULL', 'null'))::text,
                (SELECT count(*) FROM u WHERE value IN ('NULL', 'null') AND validity = 'PLACEHOLDER')::text),
            ('V-09e', 'missing reasons (absent / empty / sentinel) and NULL sources',
                (SELECT count(*) FILTER (WHERE missing_reason = 'absent') || ' / ' || count(*) FILTER (WHERE missing_reason = 'empty') || ' / '
                        || count(*) FILTER (WHERE missing_reason = 'sentinel') || '; sources NULL ' || count(*) FILTER (WHERE slot_id IS NULL) FROM p),
                (SELECT count(*) FILTER (WHERE missing_reason = 'absent') || ' / ' || count(*) FILTER (WHERE missing_reason = 'empty') || ' / '
                        || count(*) FILTER (WHERE missing_reason = 'sentinel') || '; sources NULL ' || count(*) FILTER (WHERE slot_id IS NULL) FROM u)),
            ('V-09f', 'NULL in run_id, loaded_at, format, detection rule, record validity, truncation or diagnostics', '0',
                (SELECT count(*) FROM a WHERE a.run_id IS NULL OR a.loaded_at IS NULL OR a.format_family IS NULL OR a.detection_rule IS NULL
                   OR a.record_validity IS NULL OR a.is_truncated IS NULL OR a.diagnostics IS NULL)::text),
            ('V-09g', 'NULL sub_format / NULL event_end_pos rows = NONE rows',
                (SELECT count(*) || ' / ' || count(*) FROM a WHERE a.format_family = 'NONE'),
                (SELECT count(*) FILTER (WHERE a.sub_format IS NULL) || ' / ' || count(*) FILTER (WHERE a.event_end_pos IS NULL) FROM a)),
            ('V-09h', 'typed value missing on a VALID field (code, local time, degrees, inet, status)', '0',
                (SELECT count(*) FROM a WHERE (a.entity_type_validity = 'VALID' AND a.entity_type_code IS NULL)
                   OR (a.event_timestamp_validity = 'VALID' AND (a.event_timestamp_local IS NULL OR a.event_timestamp_shape IS NULL))
                   OR (a.latitude_validity = 'VALID' AND a.latitude_degrees IS NULL)
                   OR (a.longitude_validity = 'VALID' AND a.longitude_degrees IS NULL)
                   OR (a.ip_address_validity = 'VALID' AND a.ip_address_inet IS NULL)
                   OR (a.status_validity = 'VALID' AND a.status_code IS NULL AND a.status_word IS NULL))::text),
            ('V-09i', 'VALID timestamps without offset = zone-less text (no Z, no numeric offset, not epoch)',
                (SELECT count(*) FROM ts_oracle WHERE validity = 'VALID' AND offset_oracle IS NULL)::text,
                (SELECT count(*) FROM a WHERE a.event_timestamp_validity = 'VALID' AND a.event_timestamp_utc_offset IS NULL)::text)
        ) AS c (id, name, expected, actual)
        ORDER BY c.id
    LOOP
        v_checks := v_checks + 1;
        IF chk.expected IS NOT DISTINCT FROM chk.actual THEN
            RAISE NOTICE '% PASS  %: %', chk.id, chk.name, chk.actual;
        ELSE
            v_failed := v_failed || chk.id;
            RAISE WARNING '% FAIL  %: expected %, actual %', chk.id, chk.name, chk.expected, chk.actual;
        END IF;
    END LOOP;

    -- V-03b: every stored CHECK expression evaluated on every row (a CHECK rejects only FALSE)
    FOR chk IN
        SELECT k.conname, substr(pg_get_constraintdef(k.oid), 7) AS expr
        FROM pg_constraint k
        WHERE k.conrelid = 'log_regex.access_log_flat'::regclass AND k.contype = 'c'
        ORDER BY k.oid
    LOOP
        EXECUTE format('SELECT count(*) FROM log_regex.access_log_flat WHERE %s IS FALSE', chk.expr) INTO v_violation;
        v_total := v_total + v_violation;
        IF v_violation > 0 THEN
            v_detail := v_detail || format(' %s=%s', chk.conname, v_violation);
        END IF;
    END LOOP;
    v_checks := v_checks + 1;
    IF v_total = 0 THEN
        RAISE NOTICE 'V-03b PASS  22 CHECK expressions re-evaluated on every row: 0 violations';
    ELSE
        v_failed := v_failed || 'V-03b'::text;
        RAISE WARNING 'V-03b FAIL  CHECK violations:%', v_detail;
    END IF;

    IF cardinality(v_failed) > 0 THEN
        RAISE EXCEPTION 'access_log_flat load check FAILED: % of % checks: %', cardinality(v_failed), v_checks, array_to_string(v_failed, ', ')
            USING ERRCODE = 'LR009';
    END IF;
    RAISE NOTICE 'access_log_flat load check PASSED: all % checks', v_checks;
END
$verify$;

ROLLBACK;
