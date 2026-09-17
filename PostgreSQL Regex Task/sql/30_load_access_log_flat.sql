-- =============================================================================
-- Step 5B / 30 - Populate log_regex.access_log_flat from the accepted parser run (one transaction)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/30_load_access_log_flat.sql
--   optional: -v source_run_id=<run>   (default 14, the run accepted in Step 4A)
--
-- Publishes the primary fields of one accepted parser run: one row per raw log. Record columns are copied from
-- parsed_log; value, validity, start_pos, source (slot_id) and missing_reason from parsed_field, unchanged. Typed
-- columns are derived for VALID values only, with the Step 5A rules (docs/Step5A_Flat_Schema_Design.md 4.4, 4.6):
--   entity_type_code      upper(regexp_replace(entity_type, '[[:space:]_-]+', '_', 'g'))
--   event_timestamp_*     first ref_timestamp_shape by match_order (every non-NULL value); wall clock from the shape
--                         group map (year-less shape: parser_run.assumed_year; missing seconds: 0; 12-hour: hour mod 12,
--                         plus 12 for PM); iso8601 fraction kept (up to 6 digits); offset from Z/z, +-hh:mm (iso8601)
--                         or +-hhmm (apache_clf), 0 for epoch, NULL otherwise; instant = (local - offset) AT TIME ZONE
--                         'UTC'; epoch values are exact integer seconds / milliseconds since 1970-01-01 UTC
--   *_degrees             VAL-GEO notations: decimal as written; hemisphere prefix/suffix with S/W negative; DMS
--                         (d*3600 + m*60 + s) / 3600 in numeric, rounded once to 7 places
--   ip_address_inet       split_part(ip_address, '%', 1)::inet; ip_address_zone_id = text after '%'
--   status_code / _word   3-digit code of "403" or "403 Forbidden"; otherwise upper(status) (check mark unchanged)
-- MISSING values stay SQL NULL; PLACEHOLDER and INVALID values keep their text and get no typed value.
--
-- Safety:
--   * Refuses (LR007) unless access_log_flat exists and is empty, verify_raw_access_logs() passes 10 / 10, and the run
--     succeeded with formats {F1,F2,F3,F4,F5,NONE}, fingerprint checks before and after, one classified parsed_log row
--     and exactly the ten parsed_field rows per raw log.
--   * Coordinate precision rule (5A section 4.6): raises LR008 and publishes nothing if a VALID coordinate matches no
--     VAL-GEO notation, has more than 7 decimal places (decimal, hemisphere) or DMS seconds with more than 3.
--   * The only INSERT targets access_log_flat; nothing is updated or deleted. Staging uses a temporary table dropped at
--     COMMIT. Foreign keys and the 22 CHECK constraints are enforced by the INSERT itself.
--   * Before COMMIT (LR007, everything rolls back): one row per raw log from the run; exact round trip of the 50 field
--     columns to parsed_field and of the record columns to parsed_log; exact substrings at the stored positions.
-- Full read-only verification afterwards: sql/27, sql/29 and sql/31.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

\if :{?source_run_id}
\else
    \set source_run_id 14
\endif

BEGIN;

SET LOCAL lock_timeout = '10s';
SELECT set_config('flat_load.source_run_id', :'source_run_id', true) AS source_run_id;

-- BEGIN load guard and preconditions
DO $$
DECLARE
    c_formats  constant text[] := ARRAY['F1', 'F2', 'F3', 'F4', 'F5', 'NONE'];
    v_run_id   bigint := current_setting('flat_load.source_run_id')::bigint;
    v_problems text[] := '{}';
    v_run      record;
    v_rows     bigint;
    v_checks   bigint;
    v_failed   bigint;
    v_raw      bigint;
    v_logs     bigint;
    v_fields   bigint;
    v_bad_logs bigint;
BEGIN
    IF to_regclass('log_regex.access_log_flat') IS NULL THEN
        RAISE EXCEPTION 'sql/30_load_access_log_flat.sql refused: log_regex.access_log_flat does not exist (run sql/28 first)'
            USING ERRCODE = 'LR007';
    END IF;
    SELECT count(*) INTO v_rows FROM log_regex.access_log_flat;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'sql/30_load_access_log_flat.sql refused: log_regex.access_log_flat already holds % rows; this script never deletes or replaces rows', v_rows
            USING ERRCODE = 'LR007',
                  HINT    = 'Verify the published rows with sql/31_verify_access_log_flat_load.sql.';
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
            v_problems := v_problems || format('run %s implements formats %s', v_run_id, v_run.formats_implemented);
        END IF;
        IF v_run.fingerprint_check_before IS NOT TRUE OR v_run.fingerprint_check_after IS NOT TRUE THEN
            v_problems := v_problems || format('run %s fingerprint checks before/after: %s/%s', v_run_id,
                                               v_run.fingerprint_check_before, v_run.fingerprint_check_after);
        END IF;
    END IF;

    SELECT count(*) INTO v_raw FROM log_regex.raw_access_logs;
    SELECT count(*) INTO v_logs
      FROM log_regex.parsed_log WHERE run_id = v_run_id AND format_family IS NOT NULL AND record_validity IS NOT NULL;
    SELECT count(*) INTO v_fields FROM log_regex.parsed_field WHERE run_id = v_run_id;
    SELECT count(*) INTO v_bad_logs
      FROM (SELECT log_id FROM log_regex.parsed_field WHERE run_id = v_run_id
            GROUP BY log_id HAVING count(*) <> 10 OR count(DISTINCT field_name) <> 10) AS s;
    IF v_logs <> v_raw OR v_fields <> 10 * v_raw OR v_bad_logs <> 0 THEN
        v_problems := v_problems || format('run %s: %s classified parsed_log rows, %s parsed_field rows, %s logs without exactly the 10 fields, for %s raw logs',
                                           v_run_id, v_logs, v_fields, v_bad_logs, v_raw);
    END IF;

    IF cardinality(v_problems) > 0 THEN
        RAISE EXCEPTION 'sql/30_load_access_log_flat.sql refused: %', array_to_string(v_problems, '; ')
            USING ERRCODE = 'LR007';
    END IF;
    RAISE NOTICE 'load preconditions passed: access_log_flat empty; raw input 10 / 10; run % succeeded (%): % parsed_log and % parsed_field rows for % raw logs',
        v_run_id, v_run.parser_version, v_logs, v_fields, v_raw;
END
$$;
-- END load guard and preconditions

-- Stage: the complete rows plus the coordinate notation helpers (temporary, dropped at COMMIT) --------------------
CREATE TEMP TABLE flat_stage ON COMMIT DROP AS
WITH run AS (
    SELECT r.run_id, r.assumed_year
    FROM log_regex.parser_run r
    WHERE r.run_id = current_setting('flat_load.source_run_id')::bigint
),
fields AS (
    SELECT pf.log_id,
           max(pf.value)          FILTER (WHERE pf.field_name = 'entity_type')     AS entity_type,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'entity_type')     AS entity_type_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'entity_type')     AS entity_type_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'entity_type')     AS entity_type_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'entity_type')     AS entity_type_missing_reason,
           max(pf.value)          FILTER (WHERE pf.field_name = 'email_address')   AS email_address,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'email_address')   AS email_address_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'email_address')   AS email_address_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'email_address')   AS email_address_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'email_address')   AS email_address_missing_reason,
           max(pf.value)          FILTER (WHERE pf.field_name = 'resource_url')    AS resource_url,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'resource_url')    AS resource_url_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'resource_url')    AS resource_url_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'resource_url')    AS resource_url_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'resource_url')    AS resource_url_missing_reason,
           max(pf.value)          FILTER (WHERE pf.field_name = 'event_timestamp') AS event_timestamp,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'event_timestamp') AS event_timestamp_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'event_timestamp') AS event_timestamp_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'event_timestamp') AS event_timestamp_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'event_timestamp') AS event_timestamp_missing_reason,
           max(pf.value)          FILTER (WHERE pf.field_name = 'tool')            AS tool,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'tool')            AS tool_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'tool')            AS tool_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'tool')            AS tool_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'tool')            AS tool_missing_reason,
           max(pf.value)          FILTER (WHERE pf.field_name = 'latitude')        AS latitude,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'latitude')        AS latitude_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'latitude')        AS latitude_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'latitude')        AS latitude_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'latitude')        AS latitude_missing_reason,
           max(pf.value)          FILTER (WHERE pf.field_name = 'longitude')       AS longitude,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'longitude')       AS longitude_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'longitude')       AS longitude_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'longitude')       AS longitude_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'longitude')       AS longitude_missing_reason,
           max(pf.value)          FILTER (WHERE pf.field_name = 'ip_address')      AS ip_address,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'ip_address')      AS ip_address_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'ip_address')      AS ip_address_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'ip_address')      AS ip_address_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'ip_address')      AS ip_address_missing_reason,
           max(pf.value)          FILTER (WHERE pf.field_name = 'action_phrase')   AS action_phrase,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'action_phrase')   AS action_phrase_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'action_phrase')   AS action_phrase_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'action_phrase')   AS action_phrase_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'action_phrase')   AS action_phrase_missing_reason,
           max(pf.value)          FILTER (WHERE pf.field_name = 'status')          AS status,
           max(pf.validity)       FILTER (WHERE pf.field_name = 'status')          AS status_validity,
           max(pf.start_pos)      FILTER (WHERE pf.field_name = 'status')          AS status_start_pos,
           max(pf.slot_id)        FILTER (WHERE pf.field_name = 'status')          AS status_source,
           max(pf.missing_reason) FILTER (WHERE pf.field_name = 'status')          AS status_missing_reason
    FROM log_regex.parsed_field pf
    JOIN run ON run.run_id = pf.run_id
    GROUP BY pf.log_id
),
-- event_timestamp: first matching shape (by match_order) for every non-NULL value
ts AS (
    SELECT pf.log_id, pf.value, pf.validity, s.shape_name, s.is_epoch, regexp_match(pf.value, s.pattern) AS m,
           s.year_group, s.month_group, s.month_name_group, s.day_group, s.hour_group, s.minute_group, s.second_group,
           s.ampm_group
    FROM log_regex.parsed_field pf
    JOIN run ON run.run_id = pf.run_id
    CROSS JOIN LATERAL (SELECT sh.*
                        FROM log_regex.ref_timestamp_shape sh
                        WHERE pf.value ~ sh.pattern
                        ORDER BY sh.match_order
                        LIMIT 1) AS s
    WHERE pf.field_name = 'event_timestamp' AND pf.value IS NOT NULL
),
ts_parts AS (
    SELECT t.log_id, t.value, t.validity, t.shape_name, t.is_epoch,
           CASE WHEN t.year_group IS NULL THEN run.assumed_year ELSE t.m[t.year_group]::integer END AS y,
           coalesce(t.m[t.month_group]::integer, mn.month_no::integer)                             AS mo,
           btrim(t.m[t.day_group])::integer                                                        AS d,
           t.m[t.hour_group]::integer                                                              AS h,
           t.m[t.minute_group]::integer                                                            AS mi,
           coalesce(t.m[t.second_group], '0')                                                      AS second_text,
           CASE WHEN t.shape_name = 'iso8601' THEN coalesce(t.m[7], '') ELSE '' END                AS fraction_text,
           t.m[t.ampm_group]                                                                       AS ampm,
           CASE t.shape_name WHEN 'iso8601'    THEN t.m[8]
                             WHEN 'apache_clf' THEN substring(t.value FROM ' ([+-][0-9]{4})$') END AS zone_text
    FROM ts t
    CROSS JOIN run
    LEFT JOIN log_regex.ref_month_name mn ON mn.month_abbr = t.m[t.month_name_group]
),
ts_typed AS (
    SELECT p.log_id, p.shape_name,
           CASE WHEN p.validity = 'VALID' AND NOT p.is_epoch THEN
                make_timestamp(p.y, p.mo, p.d,
                               CASE WHEN p.ampm IS NULL THEN p.h
                                    ELSE p.h % 12 + CASE WHEN p.ampm = 'PM' THEN 12 ELSE 0 END END,
                               p.mi, (p.second_text || p.fraction_text)::double precision)
           END AS local_wall,
           CASE WHEN p.validity = 'VALID' AND p.shape_name = 'epoch_seconds' THEN
                     to_timestamp(p.value::bigint)
                WHEN p.validity = 'VALID' AND p.shape_name = 'epoch_milliseconds' THEN
                     to_timestamp(p.value::bigint / 1000) + (p.value::bigint % 1000) * interval '1 millisecond'
           END AS epoch_utc,
           CASE WHEN p.validity <> 'VALID' THEN NULL
                WHEN p.is_epoch OR p.zone_text IN ('Z', 'z') THEN interval '0'
                WHEN p.zone_text ~ '^[+-][0-9]{2}:?[0-9]{2}$' THEN
                     CASE WHEN left(p.zone_text, 1) = '-' THEN -1 ELSE 1 END
                     * (substr(p.zone_text, 2, 2)::integer * interval '1 hour' + right(p.zone_text, 2)::integer * interval '1 minute')
           END AS utc_offset
    FROM ts_parts p
),
-- latitude / longitude: the four VAL-GEO notations (VALID values only)
geo AS (
    SELECT pf.log_id, pf.field_name, pf.value,
           regexp_match(pf.value, '^-?[0-9]{1,3}([.][0-9]+)?$')                                              AS dec,
           regexp_match(pf.value, '^([0-9]{1,3}([.][0-9]+)?) ([NSEW])$')                                     AS suf,
           regexp_match(pf.value, '^([NSEW])([0-9]{1,3}([.][0-9]+)?)$')                                      AS pre,
           -- DMS exactly as VAL-GEO: degree sign U+00B0 = chr(176); minutes ' or U+2032 = chr(8242); seconds " or
           -- U+2033 = chr(8243); optional single spaces (chr() keeps this file ASCII)
           regexp_match(pf.value, '^([0-9]{1,3})' || chr(176) || ' ?([0-9]{2})[''' || chr(8242) || '] ?([0-9]{2}([.][0-9]+)?)["'
                                  || chr(8243) || '] ?([NSEW])$')                                    AS dms
    FROM log_regex.parsed_field pf
    JOIN run ON run.run_id = pf.run_id
    WHERE pf.field_name IN ('latitude', 'longitude') AND pf.validity = 'VALID'
),
geo_typed AS (
    SELECT g.log_id, g.field_name,
           CASE WHEN g.dec IS NOT NULL THEN 'decimal'
                WHEN g.suf IS NOT NULL THEN 'hemisphere suffix'
                WHEN g.pre IS NOT NULL THEN 'hemisphere prefix'
                WHEN g.dms IS NOT NULL THEN 'DMS' END                                                  AS notation,
           CASE WHEN g.dec IS NOT NULL THEN coalesce(char_length(g.dec[1]) - 1, 0)
                WHEN g.suf IS NOT NULL THEN coalesce(char_length(g.suf[2]) - 1, 0)
                WHEN g.pre IS NOT NULL THEN coalesce(char_length(g.pre[3]) - 1, 0) END                AS decimal_places,
           CASE WHEN g.dms IS NOT NULL THEN coalesce(char_length(g.dms[4]) - 1, 0) END               AS dms_second_places,
           CASE WHEN g.dec IS NOT NULL THEN g.value::numeric
                WHEN g.suf IS NOT NULL THEN CASE WHEN g.suf[3] IN ('S', 'W') THEN -1 ELSE 1 END * g.suf[1]::numeric
                WHEN g.pre IS NOT NULL THEN CASE WHEN g.pre[1] IN ('S', 'W') THEN -1 ELSE 1 END * g.pre[2]::numeric
                WHEN g.dms IS NOT NULL THEN CASE WHEN g.dms[5] IN ('S', 'W') THEN -1 ELSE 1 END
                     * round((g.dms[1]::numeric * 3600 + g.dms[2]::numeric * 60 + g.dms[3]::numeric) / 3600, 7) END AS degrees
    FROM geo g
)
SELECT l.log_id, l.run_id,
       l.format_family, l.detection_rule, l.sub_format, l.record_validity, l.is_truncated, l.event_end_pos, l.diagnostics,
       f.entity_type, f.entity_type_validity, f.entity_type_start_pos, f.entity_type_source, f.entity_type_missing_reason,
       CASE WHEN f.entity_type_validity = 'VALID'
            THEN upper(regexp_replace(f.entity_type, '[[:space:]_-]+', '_', 'g')) END                AS entity_type_code,
       f.email_address, f.email_address_validity, f.email_address_start_pos, f.email_address_source, f.email_address_missing_reason,
       f.resource_url, f.resource_url_validity, f.resource_url_start_pos, f.resource_url_source, f.resource_url_missing_reason,
       f.event_timestamp, f.event_timestamp_validity, f.event_timestamp_start_pos, f.event_timestamp_source,
       f.event_timestamp_missing_reason,
       t.shape_name                                                                                   AS event_timestamp_shape,
       coalesce(t.local_wall, t.epoch_utc AT TIME ZONE 'UTC')                                         AS event_timestamp_local,
       t.utc_offset                                                                                   AS event_timestamp_utc_offset,
       CASE WHEN t.epoch_utc IS NOT NULL THEN t.epoch_utc
            WHEN t.utc_offset IS NOT NULL THEN (t.local_wall - t.utc_offset) AT TIME ZONE 'UTC' END   AS event_timestamp_utc,
       f.tool, f.tool_validity, f.tool_start_pos, f.tool_source, f.tool_missing_reason,
       f.latitude, f.latitude_validity, f.latitude_start_pos, f.latitude_source, f.latitude_missing_reason,
       lat.degrees                                                                                    AS latitude_degrees,
       f.longitude, f.longitude_validity, f.longitude_start_pos, f.longitude_source, f.longitude_missing_reason,
       lon.degrees                                                                                    AS longitude_degrees,
       f.ip_address, f.ip_address_validity, f.ip_address_start_pos, f.ip_address_source, f.ip_address_missing_reason,
       CASE WHEN f.ip_address_validity = 'VALID' THEN split_part(f.ip_address, '%', 1)::inet END      AS ip_address_inet,
       CASE WHEN f.ip_address_validity = 'VALID' THEN nullif(split_part(f.ip_address, '%', 2), '') END AS ip_address_zone_id,
       f.action_phrase, f.action_phrase_validity, f.action_phrase_start_pos, f.action_phrase_source, f.action_phrase_missing_reason,
       f.status, f.status_validity, f.status_start_pos, f.status_source, f.status_missing_reason,
       CASE WHEN f.status_validity = 'VALID'
            THEN substring(f.status FROM '^([0-9]{3})( .+)?$')::smallint END                          AS status_code,
       CASE WHEN f.status_validity = 'VALID' AND f.status !~ '^[0-9]{3}( .+)?$'
            THEN upper(f.status) END                                                                  AS status_word,
       -- helpers for the precision rule; not published
       lat.notation AS latitude_notation, lat.decimal_places AS latitude_decimal_places, lat.dms_second_places AS latitude_dms_second_places,
       lon.notation AS longitude_notation, lon.decimal_places AS longitude_decimal_places, lon.dms_second_places AS longitude_dms_second_places
FROM log_regex.parsed_log l
JOIN run                  ON run.run_id = l.run_id
JOIN fields f             ON f.log_id = l.log_id
LEFT JOIN ts_typed t      ON t.log_id = l.log_id
LEFT JOIN geo_typed lat   ON lat.log_id = l.log_id AND lat.field_name = 'latitude'
LEFT JOIN geo_typed lon   ON lon.log_id = l.log_id AND lon.field_name = 'longitude';

-- BEGIN coordinate precision rule (Step 5A section 4.6)
DO $$
DECLARE
    v_rejected text;
    v_count    bigint;
    v_summary  text;
BEGIN
    SELECT count(*), string_agg(format('log %s %s %L: %s', s.log_id, s.axis, s.value, s.reason), '; ' ORDER BY s.log_id, s.axis)
      INTO v_count, v_rejected
      FROM (SELECT log_id, 'latitude' AS axis, latitude AS value,
                   CASE WHEN latitude_notation IS NULL THEN 'matches no VAL-GEO notation'
                        WHEN latitude_notation = 'DMS' AND latitude_dms_second_places > 3 THEN 'DMS seconds with more than 3 decimal places'
                        WHEN latitude_notation <> 'DMS' AND latitude_decimal_places > 7 THEN 'more than 7 decimal places' END AS reason
            FROM pg_temp.flat_stage WHERE latitude_validity = 'VALID'
            UNION ALL
            SELECT log_id, 'longitude', longitude,
                   CASE WHEN longitude_notation IS NULL THEN 'matches no VAL-GEO notation'
                        WHEN longitude_notation = 'DMS' AND longitude_dms_second_places > 3 THEN 'DMS seconds with more than 3 decimal places'
                        WHEN longitude_notation <> 'DMS' AND longitude_decimal_places > 7 THEN 'more than 7 decimal places' END
            FROM pg_temp.flat_stage WHERE longitude_validity = 'VALID') AS s
     WHERE s.reason IS NOT NULL;

    IF v_count > 0 THEN
        RAISE EXCEPTION 'sql/30_load_access_log_flat.sql: % VALID coordinates rejected by the precision rule; nothing published: %', v_count, left(v_rejected, 3000)
            USING ERRCODE = 'LR008';
    END IF;

    SELECT string_agg(format('%s %s %s (max decimals %s, max DMS second decimals %s)', axis, notation, n, coalesce(max_dec::text, '-'), coalesce(max_dms::text, '-')), '; ' ORDER BY axis, notation)
      INTO v_summary
      FROM (SELECT 'latitude' AS axis, latitude_notation AS notation, count(*) AS n,
                   max(latitude_decimal_places) AS max_dec, max(latitude_dms_second_places) AS max_dms
            FROM pg_temp.flat_stage WHERE latitude_validity = 'VALID' GROUP BY latitude_notation
            UNION ALL
            SELECT 'longitude', longitude_notation, count(*), max(longitude_decimal_places), max(longitude_dms_second_places)
            FROM pg_temp.flat_stage WHERE longitude_validity = 'VALID' GROUP BY longitude_notation) AS x;
    RAISE NOTICE 'coordinate precision rule: 0 rejections; %', v_summary;
END
$$;
-- END coordinate precision rule

-- Publish -----------------------------------------------------------------------------------------------------------
INSERT INTO log_regex.access_log_flat (
    log_id, run_id,
    format_family, detection_rule, sub_format, record_validity, is_truncated, event_end_pos, diagnostics,
    entity_type, entity_type_validity, entity_type_start_pos, entity_type_source, entity_type_missing_reason, entity_type_code,
    email_address, email_address_validity, email_address_start_pos, email_address_source, email_address_missing_reason,
    resource_url, resource_url_validity, resource_url_start_pos, resource_url_source, resource_url_missing_reason,
    event_timestamp, event_timestamp_validity, event_timestamp_start_pos, event_timestamp_source, event_timestamp_missing_reason,
    event_timestamp_shape, event_timestamp_local, event_timestamp_utc_offset, event_timestamp_utc,
    tool, tool_validity, tool_start_pos, tool_source, tool_missing_reason,
    latitude, latitude_validity, latitude_start_pos, latitude_source, latitude_missing_reason, latitude_degrees,
    longitude, longitude_validity, longitude_start_pos, longitude_source, longitude_missing_reason, longitude_degrees,
    ip_address, ip_address_validity, ip_address_start_pos, ip_address_source, ip_address_missing_reason, ip_address_inet, ip_address_zone_id,
    action_phrase, action_phrase_validity, action_phrase_start_pos, action_phrase_source, action_phrase_missing_reason,
    status, status_validity, status_start_pos, status_source, status_missing_reason, status_code, status_word)
SELECT
    log_id, run_id,
    format_family, detection_rule, sub_format, record_validity, is_truncated, event_end_pos, diagnostics,
    entity_type, entity_type_validity, entity_type_start_pos, entity_type_source, entity_type_missing_reason, entity_type_code,
    email_address, email_address_validity, email_address_start_pos, email_address_source, email_address_missing_reason,
    resource_url, resource_url_validity, resource_url_start_pos, resource_url_source, resource_url_missing_reason,
    event_timestamp, event_timestamp_validity, event_timestamp_start_pos, event_timestamp_source, event_timestamp_missing_reason,
    event_timestamp_shape, event_timestamp_local, event_timestamp_utc_offset, event_timestamp_utc,
    tool, tool_validity, tool_start_pos, tool_source, tool_missing_reason,
    latitude, latitude_validity, latitude_start_pos, latitude_source, latitude_missing_reason, latitude_degrees,
    longitude, longitude_validity, longitude_start_pos, longitude_source, longitude_missing_reason, longitude_degrees,
    ip_address, ip_address_validity, ip_address_start_pos, ip_address_source, ip_address_missing_reason, ip_address_inet, ip_address_zone_id,
    action_phrase, action_phrase_validity, action_phrase_start_pos, action_phrase_source, action_phrase_missing_reason,
    status, status_validity, status_start_pos, status_source, status_missing_reason, status_code, status_word
FROM pg_temp.flat_stage
ORDER BY log_id;

-- BEGIN load gate (before COMMIT)
DO $$
DECLARE
    v_run_id     bigint := current_setting('flat_load.source_run_id')::bigint;
    v_raw        bigint;
    v_rows       bigint;
    v_ids        bigint;
    v_missing    bigint;
    v_other_run  bigint;
    v_field_diff bigint;
    v_log_diff   bigint;
    v_values     bigint;
    v_substr     bigint;
BEGIN
    SELECT count(*) INTO v_raw FROM log_regex.raw_access_logs;
    SELECT count(*), count(DISTINCT log_id), count(*) FILTER (WHERE run_id <> v_run_id)
      INTO v_rows, v_ids, v_other_run FROM log_regex.access_log_flat;
    SELECT count(*) INTO v_missing
      FROM log_regex.raw_access_logs r
     WHERE NOT EXISTS (SELECT 1 FROM log_regex.access_log_flat a WHERE a.log_id = r.log_id);

    WITH published AS (
        SELECT a.log_id, u.field_name, u.value, u.validity, u.start_pos, u.slot_id, u.missing_reason
        FROM log_regex.access_log_flat a
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
        ) AS u (field_name, value, validity, start_pos, slot_id, missing_reason)
    ),
    parser AS (
        SELECT log_id, field_name, value, validity, start_pos, slot_id, missing_reason
        FROM log_regex.parsed_field WHERE run_id = v_run_id
    )
    SELECT (SELECT count(*) FROM (SELECT * FROM published EXCEPT ALL SELECT * FROM parser) AS x)
         + (SELECT count(*) FROM (SELECT * FROM parser EXCEPT ALL SELECT * FROM published) AS y),
           (SELECT count(*) FROM published WHERE value IS NOT NULL),
           (SELECT count(*) FROM published p JOIN log_regex.raw_access_logs r ON r.log_id = p.log_id
            WHERE p.value IS NOT NULL AND substr(r.raw_log, p.start_pos, char_length(p.value)) IS DISTINCT FROM p.value)
      INTO v_field_diff, v_values, v_substr;

    SELECT (SELECT count(*) FROM (
                SELECT log_id, run_id, format_family::text, detection_rule, sub_format, record_validity::text, is_truncated, event_end_pos, diagnostics
                FROM log_regex.access_log_flat
                EXCEPT ALL
                SELECT log_id, run_id, format_family, detection_rule, sub_format, record_validity, is_truncated, event_end_pos, diagnostics
                FROM log_regex.parsed_log WHERE run_id = v_run_id) AS x)
         + (SELECT count(*) FROM (
                SELECT log_id, run_id, format_family, detection_rule, sub_format, record_validity, is_truncated, event_end_pos, diagnostics
                FROM log_regex.parsed_log WHERE run_id = v_run_id
                EXCEPT ALL
                SELECT log_id, run_id, format_family::text, detection_rule, sub_format, record_validity::text, is_truncated, event_end_pos, diagnostics
                FROM log_regex.access_log_flat) AS y)
      INTO v_log_diff;

    IF v_rows <> v_raw OR v_ids <> v_raw OR v_missing <> 0 OR v_other_run <> 0 OR v_field_diff <> 0 OR v_log_diff <> 0 OR v_substr <> 0 THEN
        RAISE EXCEPTION 'sql/30_load_access_log_flat.sql load gate FAILED, rolled back: rows %, distinct log_ids %, raw logs without a row %, rows from another run %, field differences to parsed_field %, record differences to parsed_log %, substring mismatches %',
            v_rows, v_ids, v_missing, v_other_run, v_field_diff, v_log_diff, v_substr
            USING ERRCODE = 'LR007';
    END IF;
    RAISE NOTICE 'load gate passed: % rows for % raw logs from run %; 50 field columns = parsed_field (0 differences); record columns = parsed_log (0 differences); % stored values, 0 substring mismatches',
        v_rows, v_raw, v_run_id, v_values;
END
$$;
-- END load gate

COMMIT;

SELECT count(*)                                              AS rows,
       count(DISTINCT run_id)                                AS runs,
       min(run_id)                                           AS run_id,
       count(DISTINCT loaded_at)                             AS load_times,
       count(entity_type_code)                               AS entity_type_code,
       count(event_timestamp_shape)                          AS ts_shape,
       count(event_timestamp_local)                          AS ts_local,
       count(event_timestamp_utc_offset)                     AS ts_offset,
       count(event_timestamp_utc)                            AS ts_utc,
       count(latitude_degrees)                               AS lat_degrees,
       count(longitude_degrees)                              AS lon_degrees,
       count(ip_address_inet)                                AS ip_inet,
       count(ip_address_zone_id)                             AS ip_zone,
       count(status_code)                                    AS status_code,
       count(status_word)                                    AS status_word
FROM log_regex.access_log_flat;
