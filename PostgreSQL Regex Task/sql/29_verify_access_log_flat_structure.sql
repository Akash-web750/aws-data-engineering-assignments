-- =============================================================================
-- Step 5B / 29 - Structural verification of log_regex.access_log_flat (read-only)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/29_verify_access_log_flat_structure.sql
--   optional: -v source_run_id=<run>   (default 14)
--
-- Run after sql/28_create_access_log_flat.sql, together with sql/27_verify_access_log_flat_foreign_keys.sql (which
-- verifies the four foreign-key definitions). Reads the system catalog and evaluates the table's own CHECK expressions
-- against probe rows with SELECT only, inside a READ ONLY transaction that is rolled back. Nothing is inserted.
-- Exits non-zero (SQLSTATE LR006) unless every check passes:
--   S-01  ordinary permanent table; no inheritance, partitioning or row security
--   S-02  0 rows (created, not populated) or exactly one row per raw log, all from the source run (populated)
--   S-03  the three domains: base type text, nullable, no default, exactly one validated CHECK with exactly the allowed
--         values; casts accept every allowed value and reject look-alikes
--   S-04  71 columns in design order: names, types, NOT NULL flags and defaults
--   S-05  no JSON/JSONB, PostGIS or other extension types; plpgsql is the only extension
--   S-06  primary key access_log_flat_pkey (log_id), validated
--   S-07  exactly the four foreign keys by name, all validated (definitions: sql/27)
--   S-08  exactly the 22 CHECK constraints of the design by name, all validated; no other constraint kinds
--   S-09  CHECK semantics: every probe row violates exactly the expected CHECKs (PostgreSQL semantics: only FALSE
--         rejects, NULL passes), and every CHECK rejects at least one probe
--   S-10  exactly one index: the primary key (btree, unique, log_id)
--   S-11  no user triggers; each foreign key has 2 internal triggers here and 2 on the referenced table
--   S-12  no views, rules or policies on the table; the domains are used only by its 21 status columns
--   S-13  comments on the table, the domains, run_id and the 11 typed columns, recording the derivation rules
--   S-14  raw input intact: verify_raw_access_logs() 10 / 10 and its single guard trigger
--   S-15  the source run is still an accepted source (succeeded, all formats, one row per raw log, 10 fields per log)
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
SELECT set_config('flat_structure_check.source_run_id', :'source_run_id', true) AS source_run_id,
       to_regclass('log_regex.access_log_flat') IS NOT NULL                    AS table_exists;

\echo '== Table'
SELECT c.oid::regclass                                                                          AS table_name,
       (SELECT count(*) FROM pg_attribute a
        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped)                       AS columns,
       (SELECT count(*) FROM pg_attribute a
        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attnotnull)      AS not_null_columns,
       (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p')      AS primary_keys,
       (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f')      AS foreign_keys,
       (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'c')      AS check_constraints,
       (SELECT count(*) FROM pg_index i WHERE i.indrelid = c.oid)                               AS indexes,
       (SELECT count(*) FROM log_regex.access_log_flat)                                         AS rows
FROM pg_class c
WHERE c.oid = to_regclass('log_regex.access_log_flat');

\echo '== Domains'
SELECT t.typname AS domain_name, format_type(t.typbasetype, t.typtypmod) AS base_type, pg_get_constraintdef(k.oid) AS check_definition
FROM pg_type t
JOIN pg_constraint k ON k.contypid = t.oid
WHERE t.typnamespace = 'log_regex'::regnamespace AND t.typtype = 'd'
ORDER BY t.typname;

\echo '== Constraints (creation order; CHECK definitions shortened)'
SELECT k.conname,
       CASE k.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY' WHEN 'c' THEN 'CHECK' ELSE k.contype::text END AS kind,
       k.convalidated                                                                           AS validated,
       CASE WHEN k.contype = 'c' AND length(pg_get_constraintdef(k.oid)) > 70
            THEN left(pg_get_constraintdef(k.oid), 70) || ' ...'
            ELSE pg_get_constraintdef(k.oid) END                                                 AS definition
FROM pg_constraint k
WHERE k.conrelid = to_regclass('log_regex.access_log_flat')
ORDER BY CASE k.contype WHEN 'p' THEN 1 WHEN 'f' THEN 2 ELSE 3 END, k.oid;

\echo '== Indexes'
SELECT ic.relname AS index_name, pg_get_indexdef(i.indexrelid) AS definition
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
WHERE i.indrelid = to_regclass('log_regex.access_log_flat');

\echo '== Internal triggers created by the foreign keys'
SELECT k.conname, t.tgrelid::regclass AS on_table, count(*) AS triggers
FROM pg_constraint k
JOIN pg_trigger t ON t.tgconstraint = k.oid
WHERE k.conrelid = to_regclass('log_regex.access_log_flat') AND k.contype = 'f'
GROUP BY k.conname, t.tgrelid
ORDER BY k.conname, t.tgrelid::regclass::text;

\echo '== Verdict'
DO $verify$
DECLARE
    c_fields constant text[] := ARRAY['entity_type', 'email_address', 'resource_url', 'event_timestamp', 'tool',
                                      'latitude', 'longitude', 'ip_address', 'action_phrase', 'status'];
    c_formats constant text[] := ARRAY['F1', 'F2', 'F3', 'F4', 'F5', 'NONE'];
    c_foreign_keys constant text[] := ARRAY[
        'access_log_flat_raw_log_fkey', 'access_log_flat_parsed_log_fkey',
        'access_log_flat_entity_type_code_fkey', 'access_log_flat_event_timestamp_shape_fkey'];
    c_checks constant text[] := ARRAY[
        'access_log_flat_format_family', 'access_log_flat_detection_rule', 'access_log_flat_event_end_pos',
        'access_log_flat_sub_format', 'access_log_flat_none_rows', 'access_log_flat_record_validity_rule',
        'access_log_flat_entity_type_state', 'access_log_flat_email_address_state', 'access_log_flat_resource_url_state',
        'access_log_flat_event_timestamp_state', 'access_log_flat_tool_state', 'access_log_flat_latitude_state',
        'access_log_flat_longitude_state', 'access_log_flat_ip_address_state', 'access_log_flat_action_phrase_state',
        'access_log_flat_status_state',
        'access_log_flat_entity_type_code', 'access_log_flat_event_timestamp_typed', 'access_log_flat_latitude_degrees',
        'access_log_flat_longitude_degrees', 'access_log_flat_ip_address_typed', 'access_log_flat_status_typed'];

    -- Probe base rows (all 71 columns). CHECKs are evaluated with SELECT; nothing is inserted.
    c_base_valid constant text := $base$
        SELECT 1 AS log_id, 14 AS run_id, now() AS loaded_at,
               'F1' AS format_family, 'DET-F1' AS detection_rule, 'pipe-delimited' AS sub_format,
               'VALID' AS record_validity, false AS is_truncated, 200 AS event_end_pos, '{}' AS diagnostics,
               'Service Account' AS entity_type, 'VALID' AS entity_type_validity, 10 AS entity_type_start_pos,
               'F1.key.entity' AS entity_type_source, NULL AS entity_type_missing_reason, 'SERVICE_ACCOUNT' AS entity_type_code,
               'a.b@example.com' AS email_address, 'VALID' AS email_address_validity, 30 AS email_address_start_pos,
               'F1.key.email' AS email_address_source, NULL AS email_address_missing_reason,
               'https://example.com/x' AS resource_url, 'VALID' AS resource_url_validity, 50 AS resource_url_start_pos,
               'F1.key.resource' AS resource_url_source, NULL AS resource_url_missing_reason,
               '2026-01-08T10:45:30+05:30' AS event_timestamp, 'VALID' AS event_timestamp_validity, 1 AS event_timestamp_start_pos,
               'F1.timestamp' AS event_timestamp_source, NULL AS event_timestamp_missing_reason, 'iso8601' AS event_timestamp_shape,
               '2026-01-08 10:45:30' AS event_timestamp_local, '05:30' AS event_timestamp_utc_offset,
               '2026-01-08 05:15:30+00' AS event_timestamp_utc,
               'curl/8.4.0' AS tool, 'VALID' AS tool_validity, 80 AS tool_start_pos,
               'F1.key.tool' AS tool_source, NULL AS tool_missing_reason,
               '19.0760' AS latitude, 'VALID' AS latitude_validity, 100 AS latitude_start_pos,
               'F1.key.lat' AS latitude_source, NULL AS latitude_missing_reason, 19.0760 AS latitude_degrees,
               '72.8777' AS longitude, 'VALID' AS longitude_validity, 110 AS longitude_start_pos,
               'F1.key.lon' AS longitude_source, NULL AS longitude_missing_reason, 72.8777 AS longitude_degrees,
               '203.0.113.7' AS ip_address, 'VALID' AS ip_address_validity, 120 AS ip_address_start_pos,
               'F1.key.ip' AS ip_address_source, NULL AS ip_address_missing_reason, '203.0.113.7' AS ip_address_inet,
               NULL AS ip_address_zone_id,
               'login' AS action_phrase, 'VALID' AS action_phrase_validity, 140 AS action_phrase_start_pos,
               'F1.key.action' AS action_phrase_source, NULL AS action_phrase_missing_reason,
               '200' AS status, 'VALID' AS status_validity, 150 AS status_start_pos,
               'F1.key.status' AS status_source, NULL AS status_missing_reason, 200 AS status_code, NULL AS status_word
    $base$;
    c_base_none constant text := $base$
        SELECT 2 AS log_id, 14 AS run_id, now() AS loaded_at,
               'NONE' AS format_family, 'DET-NONE' AS detection_rule, NULL AS sub_format,
               'BROKEN' AS record_validity, false AS is_truncated, NULL AS event_end_pos, '{no_format_detected}' AS diagnostics,
               NULL AS entity_type, 'MISSING' AS entity_type_validity, NULL AS entity_type_start_pos,
               NULL AS entity_type_source, 'absent' AS entity_type_missing_reason, NULL AS entity_type_code,
               NULL AS email_address, 'MISSING' AS email_address_validity, NULL AS email_address_start_pos,
               NULL AS email_address_source, 'absent' AS email_address_missing_reason,
               NULL AS resource_url, 'MISSING' AS resource_url_validity, NULL AS resource_url_start_pos,
               NULL AS resource_url_source, 'absent' AS resource_url_missing_reason,
               NULL AS event_timestamp, 'MISSING' AS event_timestamp_validity, NULL AS event_timestamp_start_pos,
               NULL AS event_timestamp_source, 'absent' AS event_timestamp_missing_reason, NULL AS event_timestamp_shape,
               NULL AS event_timestamp_local, NULL AS event_timestamp_utc_offset, NULL AS event_timestamp_utc,
               NULL AS tool, 'MISSING' AS tool_validity, NULL AS tool_start_pos,
               NULL AS tool_source, 'absent' AS tool_missing_reason,
               NULL AS latitude, 'MISSING' AS latitude_validity, NULL AS latitude_start_pos,
               NULL AS latitude_source, 'absent' AS latitude_missing_reason, NULL AS latitude_degrees,
               NULL AS longitude, 'MISSING' AS longitude_validity, NULL AS longitude_start_pos,
               NULL AS longitude_source, 'absent' AS longitude_missing_reason, NULL AS longitude_degrees,
               NULL AS ip_address, 'MISSING' AS ip_address_validity, NULL AS ip_address_start_pos,
               NULL AS ip_address_source, 'absent' AS ip_address_missing_reason, NULL AS ip_address_inet,
               NULL AS ip_address_zone_id,
               NULL AS action_phrase, 'MISSING' AS action_phrase_validity, NULL AS action_phrase_start_pos,
               NULL AS action_phrase_source, 'absent' AS action_phrase_missing_reason,
               NULL AS status, 'MISSING' AS status_validity, NULL AS status_start_pos,
               NULL AS status_source, 'absent' AS status_missing_reason, NULL AS status_code, NULL AS status_word
    $base$;
    -- INVALID F2 record: INVALID timestamp with its shape, PLACEHOLDER tool, empty and sentinel MISSING values with a
    -- source, IPv6 address with a zone ID, word status.
    c_base_mixed constant text := $base$
        SELECT 3 AS log_id, 14 AS run_id, now() AS loaded_at,
               'F2' AS format_family, 'DET-F2' AS detection_rule, 'template-C' AS sub_format,
               'INVALID' AS record_validity, false AS is_truncated, 300 AS event_end_pos, '{}' AS diagnostics,
               NULL AS entity_type, 'MISSING' AS entity_type_validity, NULL AS entity_type_start_pos,
               'F2.subject' AS entity_type_source, 'empty' AS entity_type_missing_reason, NULL AS entity_type_code,
               NULL AS email_address, 'MISSING' AS email_address_validity, NULL AS email_address_start_pos,
               'F2.subject' AS email_address_source, 'sentinel' AS email_address_missing_reason,
               'db://orders' AS resource_url, 'VALID' AS resource_url_validity, 40 AS resource_url_start_pos,
               'F2.resource' AS resource_url_source, NULL AS resource_url_missing_reason,
               '29-02-2026 12:00' AS event_timestamp, 'INVALID' AS event_timestamp_validity, 1 AS event_timestamp_start_pos,
               'F2.timestamp' AS event_timestamp_source, NULL AS event_timestamp_missing_reason, 'dmy_dash' AS event_timestamp_shape,
               NULL AS event_timestamp_local, NULL AS event_timestamp_utc_offset, NULL AS event_timestamp_utc,
               '-' AS tool, 'PLACEHOLDER' AS tool_validity, 60 AS tool_start_pos,
               'F2.tool' AS tool_source, NULL AS tool_missing_reason,
               'N51.5074' AS latitude, 'VALID' AS latitude_validity, 70 AS latitude_start_pos,
               'F2.coordinates' AS latitude_source, NULL AS latitude_missing_reason, 51.5074 AS latitude_degrees,
               '-0.1278' AS longitude, 'VALID' AS longitude_validity, 80 AS longitude_start_pos,
               'F2.coordinates' AS longitude_source, NULL AS longitude_missing_reason, -0.1278 AS longitude_degrees,
               'fe80::1%eth0' AS ip_address, 'VALID' AS ip_address_validity, 90 AS ip_address_start_pos,
               'F2.ip' AS ip_address_source, NULL AS ip_address_missing_reason, 'fe80::1' AS ip_address_inet,
               'eth0' AS ip_address_zone_id,
               'was blocked from accessing' AS action_phrase, 'VALID' AS action_phrase_validity, 100 AS action_phrase_start_pos,
               'F2.action' AS action_phrase_source, NULL AS action_phrase_missing_reason,
               'ok' AS status, 'VALID' AS status_validity, 140 AS status_start_pos,
               'F2.status' AS status_source, NULL AS status_missing_reason, NULL AS status_code, 'OK' AS status_word
    $base$;

    v_relid     oid := to_regclass('log_regex.access_log_flat');
    v_run_id    bigint := current_setting('flat_structure_check.source_run_id')::bigint;
    v_failed    text[] := '{}';
    v_ok        boolean;
    v_detail    text;
    v_n         bigint;
    v_m         bigint;
    v_k         bigint;
    v_value     text;
    v_names     text[];
    v_problems  text[];
    v_cols      text[];
    v_types     text[];
    v_check_sql text;
    v_select    text;
    v_expr      text;
    v_matched   integer;
    v_actual    text[];
    v_expected  text[];
    v_probes    integer := 0;
    v_mismatch  integer := 0;
    v_exercised text[] := '{}';
    d           record;
    p           record;
BEGIN
    IF v_relid IS NULL THEN
        RAISE EXCEPTION 'access_log_flat structure check FAILED: log_regex.access_log_flat does not exist'
            USING ERRCODE = 'LR006';
    END IF;

    -- S-01 ----------------------------------------------------------------------------------------------------------
    SELECT c.relkind = 'r' AND c.relpersistence = 'p' AND NOT c.relispartition AND NOT c.relrowsecurity
           AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid OR i.inhparent = c.oid),
           format('%s: relkind %s, persistence %s, partition %s, row security %s, owner %s',
                  c.oid::regclass, c.relkind, c.relpersistence, c.relispartition, c.relrowsecurity, pg_get_userbyid(c.relowner))
      INTO v_ok, v_detail
      FROM pg_class c WHERE c.oid = v_relid;
    IF v_ok THEN RAISE NOTICE 'S-01 PASS  ordinary permanent table: %', v_detail;
    ELSE v_failed := v_failed || 'S-01'::text; RAISE WARNING 'S-01 FAIL  table kind: %', v_detail; END IF;

    -- S-02 ----------------------------------------------------------------------------------------------------------
    -- Either created and not yet populated (0 rows), or populated: exactly one row per raw log, all from the source run.
    SELECT count(*), count(DISTINCT log_id), count(*) FILTER (WHERE run_id = v_run_id)
      INTO v_n, v_m, v_k FROM log_regex.access_log_flat;
    IF v_n = 0 THEN
        RAISE NOTICE 'S-02 PASS  0 rows (created, not populated)';
    ELSIF v_n = (SELECT count(*) FROM log_regex.raw_access_logs) AND v_m = v_n AND v_k = v_n THEN
        RAISE NOTICE 'S-02 PASS  % rows (populated): one row per raw log, all from source run %', v_n, v_run_id;
    ELSE v_failed := v_failed || 'S-02'::text;
        RAISE WARNING 'S-02 FAIL  % rows, % distinct log_ids, % from source run %; expected 0 or one row per raw log from the source run', v_n, v_m, v_k, v_run_id; END IF;

    -- S-03 ----------------------------------------------------------------------------------------------------------
    v_problems := '{}';
    v_k := 0;
    FOR d IN
        SELECT e.domain_name, e.accepted, e.rejected, t.oid AS type_oid, t.typbasetype, t.typnotnull, t.typdefault,
               (SELECT count(*) FROM pg_constraint k WHERE k.contypid = t.oid)                                 AS constraints,
               (SELECT count(*) FROM pg_constraint k WHERE k.contypid = t.oid AND k.contype = 'c' AND k.convalidated) AS valid_checks,
               (SELECT pg_get_constraintdef(k.oid) FROM pg_constraint k WHERE k.contypid = t.oid AND k.contype = 'c' LIMIT 1) AS definition
        FROM (VALUES ('field_validity_status',  ARRAY['VALID', 'INVALID', 'PLACEHOLDER', 'MISSING'],
                                                ARRAY['valid', 'Valid', 'BROKEN', 'MISSING ', '', 'NULL']),
                     ('record_validity_status', ARRAY['VALID', 'INVALID', 'BROKEN'],
                                                ARRAY['PLACEHOLDER', 'MISSING', 'broken', '']),
                     ('missing_reason_code',    ARRAY['absent', 'empty', 'sentinel'],
                                                ARRAY['ABSENT', 'Empty', 'placeholder', ''])) AS e (domain_name, accepted, rejected)
        LEFT JOIN pg_type t ON t.typname = e.domain_name AND t.typnamespace = 'log_regex'::regnamespace AND t.typtype = 'd'
    LOOP
        IF d.type_oid IS NULL THEN
            v_problems := v_problems || format('%s does not exist', d.domain_name);
            CONTINUE;
        END IF;
        IF d.typbasetype <> 'text'::regtype OR d.typnotnull OR d.typdefault IS NOT NULL OR d.constraints <> 1 OR d.valid_checks <> 1 THEN
            v_problems := v_problems || format('%s: base type %s, NOT NULL %s, default %s, %s constraints, %s validated CHECK',
                                               d.domain_name, d.typbasetype::regtype, d.typnotnull, d.typdefault, d.constraints, d.valid_checks);
        END IF;
        IF d.definition IS DISTINCT FROM
           'CHECK ((VALUE = ANY (ARRAY[' || (SELECT string_agg(quote_literal(u.x) || '::text', ', ' ORDER BY u.o)
                                              FROM unnest(d.accepted) WITH ORDINALITY AS u (x, o)) || '])))' THEN
            v_problems := v_problems || format('%s: definition %s', d.domain_name, d.definition);
        END IF;
        FOREACH v_value IN ARRAY d.accepted LOOP
            BEGIN
                EXECUTE format('SELECT %L::log_regex.%I', v_value, d.domain_name);
                v_k := v_k + 1;
            EXCEPTION WHEN check_violation THEN
                v_problems := v_problems || format('%s rejects %L', d.domain_name, v_value);
            END;
        END LOOP;
        FOREACH v_value IN ARRAY d.rejected LOOP
            BEGIN
                EXECUTE format('SELECT %L::log_regex.%I', v_value, d.domain_name);
                v_problems := v_problems || format('%s accepts %L', d.domain_name, v_value);
            EXCEPTION WHEN check_violation THEN
                v_k := v_k + 1;
            END;
        END LOOP;
    END LOOP;
    IF cardinality(v_problems) = 0 THEN
        RAISE NOTICE 'S-03 PASS  3 domains over text, nullable, no default, one validated CHECK each with exactly the allowed values; % of 24 cast probes as expected', v_k;
    ELSE v_failed := v_failed || 'S-03'::text; RAISE WARNING 'S-03 FAIL  domains: %', array_to_string(v_problems, '; '); END IF;

    -- S-04 ----------------------------------------------------------------------------------------------------------
    WITH expected (ordinal, column_name, data_type, not_null, default_expr) AS (
        VALUES (1, 'log_id', 'integer', true, NULL::text),
               (2, 'run_id', 'bigint', true, NULL),
               (3, 'loaded_at', 'timestamp with time zone', true, 'now()'),
               (4, 'format_family', 'text', true, NULL),
               (5, 'detection_rule', 'text', true, NULL),
               (6, 'sub_format', 'text', false, NULL),
               (7, 'record_validity', 'log_regex.record_validity_status', true, NULL),
               (8, 'is_truncated', 'boolean', true, NULL),
               (9, 'event_end_pos', 'integer', false, NULL),
               (10, 'diagnostics', 'text[]', true, '''{}''::text[]'),
               (11, 'entity_type', 'text', false, NULL),
               (12, 'entity_type_validity', 'log_regex.field_validity_status', true, NULL),
               (13, 'entity_type_start_pos', 'integer', false, NULL),
               (14, 'entity_type_source', 'text', false, NULL),
               (15, 'entity_type_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (16, 'entity_type_code', 'text', false, NULL),
               (17, 'email_address', 'text', false, NULL),
               (18, 'email_address_validity', 'log_regex.field_validity_status', true, NULL),
               (19, 'email_address_start_pos', 'integer', false, NULL),
               (20, 'email_address_source', 'text', false, NULL),
               (21, 'email_address_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (22, 'resource_url', 'text', false, NULL),
               (23, 'resource_url_validity', 'log_regex.field_validity_status', true, NULL),
               (24, 'resource_url_start_pos', 'integer', false, NULL),
               (25, 'resource_url_source', 'text', false, NULL),
               (26, 'resource_url_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (27, 'event_timestamp', 'text', false, NULL),
               (28, 'event_timestamp_validity', 'log_regex.field_validity_status', true, NULL),
               (29, 'event_timestamp_start_pos', 'integer', false, NULL),
               (30, 'event_timestamp_source', 'text', false, NULL),
               (31, 'event_timestamp_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (32, 'event_timestamp_shape', 'text', false, NULL),
               (33, 'event_timestamp_local', 'timestamp(6) without time zone', false, NULL),
               (34, 'event_timestamp_utc_offset', 'interval', false, NULL),
               (35, 'event_timestamp_utc', 'timestamp(6) with time zone', false, NULL),
               (36, 'tool', 'text', false, NULL),
               (37, 'tool_validity', 'log_regex.field_validity_status', true, NULL),
               (38, 'tool_start_pos', 'integer', false, NULL),
               (39, 'tool_source', 'text', false, NULL),
               (40, 'tool_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (41, 'latitude', 'text', false, NULL),
               (42, 'latitude_validity', 'log_regex.field_validity_status', true, NULL),
               (43, 'latitude_start_pos', 'integer', false, NULL),
               (44, 'latitude_source', 'text', false, NULL),
               (45, 'latitude_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (46, 'latitude_degrees', 'numeric(10,7)', false, NULL),
               (47, 'longitude', 'text', false, NULL),
               (48, 'longitude_validity', 'log_regex.field_validity_status', true, NULL),
               (49, 'longitude_start_pos', 'integer', false, NULL),
               (50, 'longitude_source', 'text', false, NULL),
               (51, 'longitude_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (52, 'longitude_degrees', 'numeric(10,7)', false, NULL),
               (53, 'ip_address', 'text', false, NULL),
               (54, 'ip_address_validity', 'log_regex.field_validity_status', true, NULL),
               (55, 'ip_address_start_pos', 'integer', false, NULL),
               (56, 'ip_address_source', 'text', false, NULL),
               (57, 'ip_address_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (58, 'ip_address_inet', 'inet', false, NULL),
               (59, 'ip_address_zone_id', 'text', false, NULL),
               (60, 'action_phrase', 'text', false, NULL),
               (61, 'action_phrase_validity', 'log_regex.field_validity_status', true, NULL),
               (62, 'action_phrase_start_pos', 'integer', false, NULL),
               (63, 'action_phrase_source', 'text', false, NULL),
               (64, 'action_phrase_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (65, 'status', 'text', false, NULL),
               (66, 'status_validity', 'log_regex.field_validity_status', true, NULL),
               (67, 'status_start_pos', 'integer', false, NULL),
               (68, 'status_source', 'text', false, NULL),
               (69, 'status_missing_reason', 'log_regex.missing_reason_code', false, NULL),
               (70, 'status_code', 'smallint', false, NULL),
               (71, 'status_word', 'text', false, NULL)
    ),
    actual AS (
        SELECT a.attnum::integer AS ordinal, a.attname::text AS column_name, format_type(a.atttypid, a.atttypmod) AS data_type,
               a.attnotnull AS not_null, pg_get_expr(ad.adbin, ad.adrelid) AS default_expr,
               a.attisdropped, a.attgenerated::text AS generated, a.attidentity::text AS identity
        FROM pg_attribute a
        LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
        WHERE a.attrelid = v_relid AND a.attnum > 0
    )
    SELECT count(*) FILTER (WHERE s.mismatch),
           count(*) FILTER (WHERE s.actual_ordinal IS NOT NULL),
           count(*) FILTER (WHERE s.actual_not_null),
           string_agg(s.description, '; ' ORDER BY s.ordinal) FILTER (WHERE s.mismatch)
      INTO v_n, v_m, v_k, v_detail
      FROM (SELECT coalesce(e.ordinal, a.ordinal) AS ordinal,
                   a.ordinal AS actual_ordinal,
                   a.not_null AS actual_not_null,
                   e.ordinal IS NULL OR a.ordinal IS NULL
                   OR e.column_name IS DISTINCT FROM a.column_name OR e.data_type IS DISTINCT FROM a.data_type
                   OR e.not_null IS DISTINCT FROM a.not_null OR e.default_expr IS DISTINCT FROM a.default_expr
                   OR a.attisdropped OR a.generated <> '' OR a.identity <> '' AS mismatch,
                   format('#%s expected %s %s%s%s, found %s %s%s%s', coalesce(e.ordinal, a.ordinal),
                          e.column_name, e.data_type, CASE WHEN e.not_null THEN ' NOT NULL' ELSE '' END,
                          coalesce(' DEFAULT ' || e.default_expr, ''),
                          a.column_name, a.data_type, CASE WHEN a.not_null THEN ' NOT NULL' ELSE '' END,
                          coalesce(' DEFAULT ' || a.default_expr, '')) AS description
            FROM expected e
            FULL JOIN actual a ON a.ordinal = e.ordinal) AS s;
    IF v_n = 0 AND v_m = 71 THEN
        RAISE NOTICE 'S-04 PASS  71 columns in design order with the exact names, types, % NOT NULL flags and the 2 defaults (loaded_at now(), diagnostics ''{}'')', v_k;
    ELSE v_failed := v_failed || 'S-04'::text; RAISE WARNING 'S-04 FAIL  % column mismatches (% columns): %', v_n, v_m, v_detail; END IF;

    -- S-05 ----------------------------------------------------------------------------------------------------------
    SELECT count(*) FILTER (WHERE t.typname IN ('json', 'jsonb', 'geometry', 'geography')
                              OR t.typelem IN (SELECT e.oid FROM pg_type e WHERE e.typname IN ('json', 'jsonb', 'geometry', 'geography'))
                              OR t.typnamespace NOT IN ('pg_catalog'::regnamespace, 'log_regex'::regnamespace)
                              OR EXISTS (SELECT 1 FROM pg_depend dp
                                         WHERE dp.classid = 'pg_type'::regclass AND dp.objid = t.oid AND dp.deptype = 'e'))
      INTO v_n
      FROM pg_attribute a
      JOIN pg_type t ON t.oid = a.atttypid
     WHERE a.attrelid = v_relid AND a.attnum > 0 AND NOT a.attisdropped;
    SELECT string_agg(extname, ', ' ORDER BY extname) INTO v_value FROM pg_extension;
    SELECT count(*) INTO v_m FROM pg_type WHERE typname IN ('geometry', 'geography');
    IF v_n = 0 AND v_value = 'plpgsql' AND v_m = 0 THEN
        RAISE NOTICE 'S-05 PASS  no JSON/JSONB, PostGIS or extension column types; extensions: %; geometry/geography types: 0', v_value;
    ELSE v_failed := v_failed || 'S-05'::text;
        RAISE WARNING 'S-05 FAIL  % disallowed column types; extensions: %; geometry/geography types: %', v_n, v_value, v_m; END IF;

    -- S-06 ----------------------------------------------------------------------------------------------------------
    SELECT count(*), bool_and(k.conname = 'access_log_flat_pkey' AND k.convalidated AND k.conkey = ARRAY[1]::smallint[])
      INTO v_n, v_ok
      FROM pg_constraint k WHERE k.conrelid = v_relid AND k.contype = 'p';
    IF v_n = 1 AND coalesce(v_ok, false) THEN RAISE NOTICE 'S-06 PASS  primary key access_log_flat_pkey (log_id), validated';
    ELSE v_failed := v_failed || 'S-06'::text; RAISE WARNING 'S-06 FAIL  % primary keys, expected access_log_flat_pkey (log_id)', v_n; END IF;

    -- S-07 ----------------------------------------------------------------------------------------------------------
    SELECT count(*), coalesce(array_agg(k.conname::text ORDER BY k.conname COLLATE "C"), '{}'), coalesce(bool_and(k.convalidated), false)
      INTO v_n, v_names, v_ok
      FROM pg_constraint k WHERE k.conrelid = v_relid AND k.contype = 'f';
    IF v_n = 4 AND v_ok AND v_names = (SELECT array_agg(x ORDER BY x COLLATE "C") FROM unnest(c_foreign_keys) AS x) THEN
        RAISE NOTICE 'S-07 PASS  exactly the 4 foreign keys, all validated: % (definitions verified by sql/27)', array_to_string(v_names, ', ');
    ELSE v_failed := v_failed || 'S-07'::text;
        RAISE WARNING 'S-07 FAIL  % foreign keys (all validated: %): %', v_n, v_ok, array_to_string(v_names, ', '); END IF;

    -- S-08 ----------------------------------------------------------------------------------------------------------
    SELECT count(*), coalesce(array_agg(k.conname::text ORDER BY k.conname COLLATE "C"), '{}'), coalesce(bool_and(k.convalidated), false)
      INTO v_n, v_names, v_ok
      FROM pg_constraint k WHERE k.conrelid = v_relid AND k.contype = 'c';
    SELECT count(*) INTO v_m FROM pg_constraint k WHERE k.conrelid = v_relid AND k.contype NOT IN ('p', 'f', 'c');
    IF v_n = 22 AND v_ok AND v_m = 0 AND v_names = (SELECT array_agg(x ORDER BY x COLLATE "C") FROM unnest(c_checks) AS x) THEN
        RAISE NOTICE 'S-08 PASS  exactly the 22 CHECK constraints of the design, all validated; 0 other constraint kinds';
    ELSE v_failed := v_failed || 'S-08'::text;
        RAISE WARNING 'S-08 FAIL  % CHECKs (all validated: %), % other constraints; missing: %; unexpected: %', v_n, v_ok, v_m,
            (SELECT string_agg(x, ', ') FROM unnest(c_checks) AS x WHERE x <> ALL (v_names)),
            (SELECT string_agg(x, ', ') FROM unnest(v_names) AS x WHERE x <> ALL (c_checks)); END IF;

    -- S-09 CHECK semantics ------------------------------------------------------------------------------------------
    SELECT array_agg(a.attname::text ORDER BY a.attnum), array_agg(format_type(a.atttypid, a.atttypmod) ORDER BY a.attnum)
      INTO v_cols, v_types
      FROM pg_attribute a WHERE a.attrelid = v_relid AND a.attnum > 0 AND NOT a.attisdropped;

    SELECT string_agg(format('CASE WHEN %s IS FALSE THEN %L END', substr(pg_get_constraintdef(k.oid), 7), k.conname), ', ' ORDER BY k.oid),
           count(*) FILTER (WHERE left(pg_get_constraintdef(k.oid), 6) <> 'CHECK ')
      INTO v_check_sql, v_n
      FROM pg_constraint k WHERE k.conrelid = v_relid AND k.contype = 'c';
    IF v_check_sql IS NULL OR v_n <> 0 THEN
        RAISE EXCEPTION 'access_log_flat structure check FAILED: CHECK definitions cannot be read' USING ERRCODE = 'LR006';
    END IF;

    FOR p IN
        WITH fld (f, typed_nulls) AS (
            VALUES ('entity_type',     ARRAY['entity_type_code', 'NULL']),
                   ('email_address',   '{}'::text[]),
                   ('resource_url',    '{}'::text[]),
                   ('event_timestamp', ARRAY['event_timestamp_local', 'NULL', 'event_timestamp_utc_offset', 'NULL', 'event_timestamp_utc', 'NULL']),
                   ('tool',            '{}'::text[]),
                   ('latitude',        ARRAY['latitude_degrees', 'NULL']),
                   ('longitude',       ARRAY['longitude_degrees', 'NULL']),
                   ('ip_address',      ARRAY['ip_address_inet', 'NULL', 'ip_address_zone_id', 'NULL']),
                   ('action_phrase',   '{}'::text[]),
                   ('status',          ARRAY['status_code', 'NULL', 'status_word', 'NULL'])
        ),
        probe (probe_name, base, overrides, expected) AS (
            VALUES
            -- base rows
            ('base: VALID F1 row', 'valid', '{}'::text[], '{}'::text[]),
            ('base: NONE row', 'none', '{}', '{}'),
            ('base: INVALID F2 row', 'mixed', '{}', '{}'),
            -- record classification
            ('format_family F6 with DET-F6', 'valid', ARRAY['format_family', '''F6''', 'detection_rule', '''DET-F6'''], ARRAY['access_log_flat_format_family']),
            ('F1 row with DET-F2', 'valid', ARRAY['detection_rule', '''DET-F2'''], ARRAY['access_log_flat_detection_rule']),
            ('NONE row with DET-00', 'none', ARRAY['detection_rule', '''DET-00'''], '{}'),
            ('NONE row with DET-F1', 'none', ARRAY['detection_rule', '''DET-F1'''], ARRAY['access_log_flat_detection_rule']),
            ('F1 row without event_end_pos', 'valid', ARRAY['event_end_pos', 'NULL'], ARRAY['access_log_flat_event_end_pos']),
            ('F1 row with event_end_pos 0', 'valid', ARRAY['event_end_pos', '0'],
                ARRAY['access_log_flat_event_end_pos', 'access_log_flat_entity_type_state', 'access_log_flat_email_address_state',
                      'access_log_flat_resource_url_state', 'access_log_flat_event_timestamp_state', 'access_log_flat_tool_state',
                      'access_log_flat_latitude_state', 'access_log_flat_longitude_state', 'access_log_flat_ip_address_state',
                      'access_log_flat_action_phrase_state', 'access_log_flat_status_state']),
            ('NONE row with event_end_pos', 'none', ARRAY['event_end_pos', '5'], ARRAY['access_log_flat_event_end_pos']),
            ('F1 row without sub_format', 'valid', ARRAY['sub_format', 'NULL'], ARRAY['access_log_flat_sub_format']),
            ('NONE row with sub_format', 'none', ARRAY['sub_format', '''pipe-delimited'''], ARRAY['access_log_flat_sub_format']),
            ('NONE row with a PLACEHOLDER entity_type', 'none',
                ARRAY['entity_type', '''-''', 'entity_type_validity', '''PLACEHOLDER''', 'entity_type_start_pos', '1',
                      'entity_type_source', '''F1.key.entity''', 'entity_type_missing_reason', 'NULL'],
                ARRAY['access_log_flat_none_rows']),
            ('truncated row marked VALID', 'valid', ARRAY['is_truncated', 'true'], ARRAY['access_log_flat_record_validity_rule']),
            ('truncated row marked BROKEN', 'valid', ARRAY['is_truncated', 'true', 'record_validity', '''BROKEN'''], '{}'),
            ('truncated row with an INVALID field marked INVALID', 'mixed', ARRAY['is_truncated', 'true'], ARRAY['access_log_flat_record_validity_rule']),
            ('truncated row with an INVALID field marked BROKEN', 'mixed', ARRAY['is_truncated', 'true', 'record_validity', '''BROKEN'''], '{}'),
            ('row with an INVALID field marked VALID', 'mixed', ARRAY['record_validity', '''VALID'''], ARRAY['access_log_flat_record_validity_rule']),
            ('NONE row marked INVALID', 'none', ARRAY['record_validity', '''INVALID'''], ARRAY['access_log_flat_record_validity_rule']),
            ('row without INVALID fields marked BROKEN', 'valid', ARRAY['record_validity', '''BROKEN'''], ARRAY['access_log_flat_record_validity_rule']),
            -- entity_type_code
            ('VALID entity_type without code', 'valid', ARRAY['entity_type_code', 'NULL'], ARRAY['access_log_flat_entity_type_code']),
            ('PLACEHOLDER entity_type with code', 'valid', ARRAY['entity_type', '''-''', 'entity_type_validity', '''PLACEHOLDER'''], ARRAY['access_log_flat_entity_type_code']),
            -- event timestamp
            ('VALID timestamp without local value', 'valid', ARRAY['event_timestamp_local', 'NULL'], ARRAY['access_log_flat_event_timestamp_typed']),
            ('offset without UTC instant', 'valid', ARRAY['event_timestamp_utc', 'NULL'], ARRAY['access_log_flat_event_timestamp_typed']),
            ('UTC instant without offset', 'valid', ARRAY['event_timestamp_utc_offset', 'NULL'], ARRAY['access_log_flat_event_timestamp_typed']),
            ('VALID timestamp without zone (no offset, no instant)', 'valid', ARRAY['event_timestamp_utc_offset', 'NULL', 'event_timestamp_utc', 'NULL'], '{}'),
            ('offset +14:00', 'valid', ARRAY['event_timestamp_utc_offset', '''14:00'''], '{}'),
            ('offset -14:00', 'valid', ARRAY['event_timestamp_utc_offset', '''-14:00'''], '{}'),
            ('offset +14:01', 'valid', ARRAY['event_timestamp_utc_offset', '''14:01'''], ARRAY['access_log_flat_event_timestamp_typed']),
            ('offset -14:30', 'valid', ARRAY['event_timestamp_utc_offset', '''-14:30'''], ARRAY['access_log_flat_event_timestamp_typed']),
            ('shape on a MISSING timestamp', 'none', ARRAY['event_timestamp_shape', '''iso8601'''], ARRAY['access_log_flat_event_timestamp_typed']),
            ('local value on an INVALID timestamp', 'mixed', ARRAY['event_timestamp_local', '''2026-02-28 12:00'''], ARRAY['access_log_flat_event_timestamp_typed']),
            ('offset and instant without local value', 'mixed',
                ARRAY['event_timestamp_utc_offset', '''00:00''', 'event_timestamp_utc', '''2026-02-28 12:00:00+00'''],
                ARRAY['access_log_flat_event_timestamp_typed']),
            -- coordinates
            ('latitude 90', 'valid', ARRAY['latitude_degrees', '90'], '{}'),
            ('latitude -90', 'valid', ARRAY['latitude_degrees', '-90'], '{}'),
            ('latitude 90.0000001', 'valid', ARRAY['latitude_degrees', '90.0000001'], ARRAY['access_log_flat_latitude_degrees']),
            ('latitude -90.0000001', 'valid', ARRAY['latitude_degrees', '-90.0000001'], ARRAY['access_log_flat_latitude_degrees']),
            ('longitude 180', 'valid', ARRAY['longitude_degrees', '180'], '{}'),
            ('longitude -180', 'valid', ARRAY['longitude_degrees', '-180'], '{}'),
            ('longitude 180.0000001', 'valid', ARRAY['longitude_degrees', '180.0000001'], ARRAY['access_log_flat_longitude_degrees']),
            ('longitude -180.0000001', 'valid', ARRAY['longitude_degrees', '-180.0000001'], ARRAY['access_log_flat_longitude_degrees']),
            ('VALID latitude without degrees', 'valid', ARRAY['latitude_degrees', 'NULL'], ARRAY['access_log_flat_latitude_degrees']),
            ('VALID longitude without degrees', 'valid', ARRAY['longitude_degrees', 'NULL'], ARRAY['access_log_flat_longitude_degrees']),
            ('INVALID latitude with degrees', 'valid', ARRAY['latitude_validity', '''INVALID''', 'record_validity', '''INVALID'''], ARRAY['access_log_flat_latitude_degrees']),
            -- IP address
            ('VALID IP without inet', 'valid', ARRAY['ip_address_inet', 'NULL'], ARRAY['access_log_flat_ip_address_typed']),
            ('IPv4 network /8', 'valid', ARRAY['ip_address_inet', '''10.0.0.0/8'''], ARRAY['access_log_flat_ip_address_typed']),
            ('IPv6 network /64', 'valid', ARRAY['ip_address_inet', '''2001:db8::/64'''], ARRAY['access_log_flat_ip_address_typed']),
            ('IPv6 host address', 'valid', ARRAY['ip_address_inet', '''2001:db8::1'''], '{}'),
            ('IPv4-mapped IPv6 host address', 'valid', ARRAY['ip_address_inet', '''::ffff:192.0.2.1'''], '{}'),
            ('zone ID on IPv4', 'valid', ARRAY['ip_address_zone_id', '''eth0'''], ARRAY['access_log_flat_ip_address_typed']),
            ('empty zone ID on IPv6', 'mixed', ARRAY['ip_address_zone_id', ''''''], ARRAY['access_log_flat_ip_address_typed']),
            ('zone ID on an INVALID IP without inet', 'mixed', ARRAY['ip_address_validity', '''INVALID''', 'ip_address_inet', 'NULL'], ARRAY['access_log_flat_ip_address_typed']),
            ('inet on an INVALID IP', 'valid', ARRAY['ip_address_validity', '''INVALID''', 'record_validity', '''INVALID'''], ARRAY['access_log_flat_ip_address_typed']),
            -- status
            ('VALID status without code or word', 'valid', ARRAY['status_code', 'NULL'], ARRAY['access_log_flat_status_typed']),
            ('status code and word together', 'valid', ARRAY['status_word', '''OK'''], ARRAY['access_log_flat_status_typed']),
            ('status code 100', 'valid', ARRAY['status_code', '100'], '{}'),
            ('status code 599', 'valid', ARRAY['status_code', '599'], '{}'),
            ('status code 99', 'valid', ARRAY['status_code', '99'], ARRAY['access_log_flat_status_typed']),
            ('status code 600', 'valid', ARRAY['status_code', '600'], ARRAY['access_log_flat_status_typed']),
            ('lower-case status word', 'mixed', ARRAY['status_word', '''ok'''], ARRAY['access_log_flat_status_typed']),
            ('check-mark status word', 'mixed', ARRAY['status_word', 'U&''\2713'''], '{}'),
            ('PLACEHOLDER status with code', 'valid', ARRAY['status', '''-''', 'status_validity', '''PLACEHOLDER'''], ARRAY['access_log_flat_status_typed'])
            -- per-field state, for each of the 10 fields
            UNION ALL
            SELECT format('%s: value NULL while not MISSING', f), 'valid',
                   ARRAY[f, 'NULL', f || '_start_pos', 'NULL'] || CASE WHEN f = 'event_timestamp' THEN ARRAY['event_timestamp_shape', 'NULL'] ELSE '{}'::text[] END,
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: MISSING with a value', f), 'valid',
                   ARRAY[f || '_validity', '''MISSING''', f || '_missing_reason', '''empty'''] || typed_nulls,
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: value without position', f), 'valid', ARRAY[f || '_start_pos', 'NULL'],
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: empty string', f), 'valid', ARRAY[f, ''''''],
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: position 0', f), 'valid', ARRAY[f || '_start_pos', '0'],
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: value ends after event_end_pos', f), 'valid', ARRAY[f || '_start_pos', '200'],
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: missing reason on a present value', f), 'valid', ARRAY[f || '_missing_reason', '''empty'''],
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: MISSING without reason', f), 'none', ARRAY[f || '_missing_reason', 'NULL'],
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: present value without source', f), 'valid', ARRAY[f || '_source', 'NULL'],
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: absent value with source', f), 'none', ARRAY[f || '_source', '''F1.key.x'''],
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: empty MISSING without source', f), 'none', ARRAY[f || '_missing_reason', '''empty'''],
                   ARRAY['access_log_flat_' || f || '_state'] FROM fld
            UNION ALL
            SELECT format('%s: sentinel MISSING with source', f), 'none', ARRAY[f || '_missing_reason', '''sentinel''', f || '_source', '''F2.subject'''],
                   '{}'::text[] FROM fld
            UNION ALL
            SELECT format('%s: PLACEHOLDER without typed value', f), 'valid', ARRAY[f || '_validity', '''PLACEHOLDER'''] || typed_nulls,
                   '{}'::text[] FROM fld
            UNION ALL
            SELECT format('%s: INVALID on a row marked VALID', f), 'valid', ARRAY[f || '_validity', '''INVALID'''] || typed_nulls,
                   ARRAY['access_log_flat_record_validity_rule'] FROM fld
            UNION ALL
            SELECT format('%s: INVALID on a row marked INVALID', f), 'valid',
                   ARRAY[f || '_validity', '''INVALID''', 'record_validity', '''INVALID'''] || typed_nulls,
                   '{}'::text[] FROM fld
        )
        SELECT probe_name, base, overrides, expected FROM probe
    LOOP
        v_probes := v_probes + 1;
        v_select := '';
        v_matched := 0;
        FOR i IN 1 .. cardinality(v_cols) LOOP
            v_expr := format('b.%I', v_cols[i]);
            FOR j IN 1 .. coalesce(cardinality(p.overrides), 0) / 2 LOOP
                IF p.overrides[2 * j - 1] = v_cols[i] THEN
                    v_expr := p.overrides[2 * j];
                    v_matched := v_matched + 1;
                END IF;
            END LOOP;
            v_select := v_select || CASE WHEN i > 1 THEN ', ' ELSE '' END || format('(%s)::%s AS %I', v_expr, v_types[i], v_cols[i]);
        END LOOP;
        IF v_matched * 2 <> coalesce(cardinality(p.overrides), 0) THEN
            RAISE EXCEPTION 'probe harness error in "%": an override names no column', p.probe_name USING ERRCODE = 'LR006';
        END IF;

        EXECUTE format('SELECT array_remove(ARRAY[%s]::text[], NULL) FROM (SELECT %s FROM (%s) AS b) AS t',
                       v_check_sql, v_select,
                       CASE p.base WHEN 'valid' THEN c_base_valid WHEN 'none' THEN c_base_none ELSE c_base_mixed END)
           INTO v_actual;

        v_actual   := coalesce((SELECT array_agg(x ORDER BY x COLLATE "C") FROM unnest(v_actual) AS x), '{}');
        v_expected := coalesce((SELECT array_agg(x ORDER BY x COLLATE "C") FROM unnest(p.expected) AS x), '{}');
        v_exercised := v_exercised || v_expected;
        IF v_actual IS DISTINCT FROM v_expected THEN
            v_mismatch := v_mismatch + 1;
            RAISE WARNING 'S-09 probe "%": expected to violate {%}, violates {%}',
                p.probe_name, array_to_string(v_expected, ', '), array_to_string(v_actual, ', ');
        END IF;
    END LOOP;

    SELECT count(*) INTO v_n FROM unnest(c_checks) AS x WHERE x <> ALL (v_exercised);
    IF v_mismatch = 0 AND v_n = 0 THEN
        RAISE NOTICE 'S-09 PASS  % probe rows: each violates exactly the expected CHECKs; all 22 CHECKs reject at least one probe', v_probes;
    ELSE v_failed := v_failed || 'S-09'::text;
        RAISE WARNING 'S-09 FAIL  % of % probes differ; % CHECKs never expected to reject', v_mismatch, v_probes, v_n; END IF;

    -- S-10 ----------------------------------------------------------------------------------------------------------
    SELECT count(*),
           bool_and(ic.relname = 'access_log_flat_pkey' AND i.indisunique AND i.indisprimary AND am.amname = 'btree'
                    AND i.indkey::text = '1' AND i.indpred IS NULL AND i.indexprs IS NULL)
      INTO v_n, v_ok
      FROM pg_index i
      JOIN pg_class ic ON ic.oid = i.indexrelid
      JOIN pg_am am    ON am.oid = ic.relam
     WHERE i.indrelid = v_relid;
    IF v_n = 1 AND coalesce(v_ok, false) THEN RAISE NOTICE 'S-10 PASS  exactly 1 index: access_log_flat_pkey (btree, unique, log_id)';
    ELSE v_failed := v_failed || 'S-10'::text; RAISE WARNING 'S-10 FAIL  % indexes; expected only the primary key index', v_n; END IF;

    -- S-11 ----------------------------------------------------------------------------------------------------------
    SELECT count(*) INTO v_n FROM pg_trigger t WHERE t.tgrelid = v_relid AND NOT t.tgisinternal;
    SELECT count(*) FILTER (WHERE s.on_flat = 2 AND s.on_referenced = 2), coalesce(sum(s.on_flat), 0)
      INTO v_m, v_k
      FROM (SELECT k.oid,
                   count(t.oid) FILTER (WHERE t.tgrelid = k.conrelid AND t.tgisinternal AND t.tgenabled = 'O')  AS on_flat,
                   count(t.oid) FILTER (WHERE t.tgrelid = k.confrelid AND t.tgisinternal AND t.tgenabled = 'O') AS on_referenced
            FROM pg_constraint k
            LEFT JOIN pg_trigger t ON t.tgconstraint = k.oid
            WHERE k.conrelid = v_relid AND k.contype = 'f'
            GROUP BY k.oid) AS s;
    IF v_n = 0 AND v_m = 4 AND v_k = 8 THEN
        RAISE NOTICE 'S-11 PASS  0 user triggers; each of the 4 foreign keys has 2 enabled internal triggers here (8) and 2 on its referenced table';
    ELSE v_failed := v_failed || 'S-11'::text;
        RAISE WARNING 'S-11 FAIL  % user triggers; % of 4 foreign keys with 2 + 2 internal triggers; % internal triggers here', v_n, v_m, v_k; END IF;

    -- S-12 ----------------------------------------------------------------------------------------------------------
    SELECT count(*) INTO v_n
      FROM pg_depend dp
     WHERE dp.refclassid = 'pg_class'::regclass AND dp.refobjid = v_relid AND dp.classid = 'pg_rewrite'::regclass;
    SELECT count(*) INTO v_m FROM pg_policy WHERE polrelid = v_relid;
    SELECT count(*) FILTER (WHERE a.attrelid = v_relid), count(*)
      INTO v_k, v_value
      FROM pg_attribute a
      JOIN pg_type t ON t.oid = a.atttypid
     WHERE t.typnamespace = 'log_regex'::regnamespace AND t.typtype = 'd' AND a.attnum > 0 AND NOT a.attisdropped;
    IF v_n = 0 AND v_m = 0 AND v_k = 21 AND v_value = '21' THEN
        RAISE NOTICE 'S-12 PASS  no views, rules or policies on the table; the 3 domains are used by 21 columns, all in access_log_flat';
    ELSE v_failed := v_failed || 'S-12'::text;
        RAISE WARNING 'S-12 FAIL  % dependent rules/views, % policies; domain columns here % of %', v_n, v_m, v_k, v_value; END IF;

    -- S-13 ----------------------------------------------------------------------------------------------------------
    SELECT count(*) FILTER (WHERE a.attnum IS NULL OR strpos(coalesce(col_description(v_relid, a.attnum), ''), e.needle) = 0),
           string_agg(e.column_name, ', ') FILTER (WHERE a.attnum IS NULL OR strpos(coalesce(col_description(v_relid, a.attnum), ''), e.needle) = 0)
      INTO v_n, v_detail
      FROM (VALUES ('run_id',                     'Accepted source run for the first load: 14'),
                   ('entity_type_code',           'upper(regexp_replace(entity_type, ''[[:space:]_-]+'', ''_'', ''g''))'),
                   ('event_timestamp_shape',      'First ref_timestamp_shape (by match_order)'),
                   ('event_timestamp_local',      '12 AM -> 00, 1-11 AM -> 01-11, 12 PM -> 12, 1-11 PM -> 13-23'),
                   ('event_timestamp_utc_offset', 'NULL when the text states no zone'),
                   ('event_timestamp_utc',        '(event_timestamp_local - event_timestamp_utc_offset) AT TIME ZONE ''UTC'''),
                   ('latitude_degrees',           'more than 7 decimal places or DMS seconds have more than 3'),
                   ('longitude_degrees',          'more than 7 decimal places or DMS seconds have more than 3'),
                   ('ip_address_inet',            'split_part(ip_address, ''%'', 1)::inet'),
                   ('ip_address_zone_id',         'the text after %'),
                   ('status_code',                '3-digit HTTP code'),
                   ('status_word',                'upper(status)')) AS e (column_name, needle)
      LEFT JOIN pg_attribute a ON a.attrelid = v_relid AND a.attname = e.column_name AND NOT a.attisdropped;
    SELECT count(*) FILTER (WHERE obj_description(t.oid, 'pg_type') IS NULL) INTO v_m
      FROM pg_type t WHERE t.typnamespace = 'log_regex'::regnamespace AND t.typtype = 'd';
    SELECT count(*) INTO v_k FROM pg_type t WHERE t.typnamespace = 'log_regex'::regnamespace AND t.typtype = 'd';
    IF v_n = 0 AND v_m = 0 AND v_k = 3 AND obj_description(v_relid, 'pg_class') IS NOT NULL THEN
        RAISE NOTICE 'S-13 PASS  comments on the table, the 3 domains, run_id and the 11 typed columns contain the derivation rules';
    ELSE v_failed := v_failed || 'S-13'::text;
        RAISE WARNING 'S-13 FAIL  columns without the expected comment: %; domains without comment: %; table comment present: %',
            v_detail, v_m, obj_description(v_relid, 'pg_class') IS NOT NULL; END IF;

    -- S-14 ----------------------------------------------------------------------------------------------------------
    SELECT count(*) FILTER (WHERE passed), count(*) INTO v_n, v_m FROM log_regex.verify_raw_access_logs();
    SELECT count(*) INTO v_k FROM pg_trigger WHERE tgrelid = 'log_regex.raw_access_logs'::regclass AND NOT tgisinternal;
    IF v_n = 10 AND v_m = 10 AND v_k = 1 THEN
        RAISE NOTICE 'S-14 PASS  verify_raw_access_logs() % / %; raw_access_logs keeps its 1 guard trigger', v_n, v_m;
    ELSE v_failed := v_failed || 'S-14'::text;
        RAISE WARNING 'S-14 FAIL  verify_raw_access_logs() % / %; guard triggers on raw_access_logs: %', v_n, v_m, v_k; END IF;

    -- S-15 ----------------------------------------------------------------------------------------------------------
    SELECT coalesce(bool_and(r.status = 'succeeded' AND r.formats_implemented @> c_formats AND r.formats_implemented <@ c_formats
                             AND r.fingerprint_check_before AND r.fingerprint_check_after), false)
      INTO v_ok FROM log_regex.parser_run r WHERE r.run_id = v_run_id;
    SELECT count(*) INTO v_n FROM log_regex.raw_access_logs;
    SELECT count(*) FILTER (WHERE format_family IS NOT NULL AND record_validity IS NOT NULL) INTO v_m
      FROM log_regex.parsed_log WHERE run_id = v_run_id;
    SELECT count(*) INTO v_k FROM log_regex.parsed_field WHERE run_id = v_run_id;
    IF v_ok AND v_m = v_n AND v_k = 10 * v_n THEN
        RAISE NOTICE 'S-15 PASS  source run % succeeded with formats {F1,F2,F3,F4,F5,NONE}: % parsed_log rows and % parsed_field rows for % raw logs', v_run_id, v_m, v_k, v_n;
    ELSE v_failed := v_failed || 'S-15'::text;
        RAISE WARNING 'S-15 FAIL  source run %: accepted %, % classified parsed_log rows and % parsed_field rows for % raw logs', v_run_id, v_ok, v_m, v_k, v_n; END IF;

    IF cardinality(v_failed) > 0 THEN
        RAISE EXCEPTION 'access_log_flat structure check FAILED: %', array_to_string(v_failed, ', ')
            USING ERRCODE = 'LR006';
    END IF;
    RAISE NOTICE 'access_log_flat structure check PASSED: S-01 ... S-15';
END
$verify$;

ROLLBACK;
