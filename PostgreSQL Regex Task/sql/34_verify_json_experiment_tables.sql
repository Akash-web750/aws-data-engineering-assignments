-- =============================================================================
-- Step 6B / 34 - Verify the JSON and JSONB experiment tables (read-only)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/34_verify_json_experiment_tables.sql
--
-- READ ONLY transaction, rolled back. Exits non-zero (SQLSTATE LR012) unless every check passes. Expected values come
-- from access_log_flat and from the Step 6A design, not from the loaded documents:
--   B-01 rows          5,000 in each table, = access_log_flat = raw logs
--   B-02 log_id sets   json = jsonb = access_log_flat
--   B-03 input text    md5 and byte count of the stored json texts = canonical input recorded at load (both comments);
--                      every json text reduces to the designed minified skeleton (exact keys, order, no whitespace);
--                      doc log_id / run_id match the row
--   B-04 equivalence   json::jsonb = jsonb for all documents
--   B-05 round trip    all 70 leaves of each table vs access_log_flat: key present with the designed JSON type (null
--                      exactly where the flat value is NULL), exact text form, typed cast back IS NOT DISTINCT FROM
--   B-06 duplicates    json texts IS JSON OBJECT WITH UNIQUE KEYS; no object with repeated keys
--   B-07 structure     82 keys in every document of both tables; keys per object = design (ordered for json)
--   B-08 escaping      values with double quotes, backslashes and non-ASCII characters: escaped form present in the json
--                      text, value equal after ->> in json and jsonb
--   B-09 MISSING       JSON null leaves (key present) = SQL NULL cells of the 70 flat columns, in both tables
--   B-10 isolation     log_regex_json holds only the two tables, their primary keys and the designed Step 6D experiment
--                      indexes; no foreign keys, triggers or dependencies between log_regex and log_regex_json
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

BEGIN TRANSACTION READ ONLY;

SET LOCAL search_path = pg_catalog, pg_temp;
SET LOCAL TimeZone = 'UTC';

\echo '== Escaping examples: shortest value of each kind'
WITH v AS (
    SELECT a.log_id, x.field, x.value
    FROM log_regex.access_log_flat a
    CROSS JOIN LATERAL (VALUES ('entity_type', a.entity_type), ('email_address', a.email_address), ('resource_url', a.resource_url),
                               ('event_timestamp', a.event_timestamp), ('tool', a.tool), ('latitude', a.latitude),
                               ('longitude', a.longitude), ('ip_address', a.ip_address), ('action_phrase', a.action_phrase),
                               ('status', a.status)) AS x (field, value)
    WHERE x.value IS NOT NULL
),
kinds AS (
    SELECT 'double quote' AS kind, v.* FROM v WHERE strpos(v.value, chr(34)) > 0
    UNION ALL SELECT 'backslash', v.* FROM v WHERE strpos(v.value, chr(92)) > 0
    UNION ALL SELECT 'non-ASCII', v.* FROM v WHERE octet_length(v.value) <> char_length(v.value)
),
e AS (SELECT DISTINCT ON (kind) * FROM kinds ORDER BY kind, octet_length(value), log_id)
SELECT e.kind, e.log_id, e.field, e.value AS flat_value, to_json(e.value)::text AS escaped_form,
       strpos(j.doc::text, to_json(e.value)::text) > 0 AS in_json_text,
       j.doc -> 'fields' -> e.field ->> 'value' = e.value AS json_equal,
       b.doc -> 'fields' -> e.field ->> 'value' = e.value AS jsonb_equal
FROM e
JOIN log_regex_json.access_log_json j  ON j.log_id = e.log_id
JOIN log_regex_json.access_log_jsonb b ON b.log_id = e.log_id
ORDER BY e.kind;

\echo '== One document (log_id 3212): json text (as stored) and jsonb output text'
SELECT j.doc::text AS json_text FROM log_regex_json.access_log_json j WHERE j.log_id = 3212;
SELECT b.doc::text AS jsonb_text FROM log_regex_json.access_log_jsonb b WHERE b.log_id = 3212;

\echo '== Verdict'
DO $verify$
DECLARE
    c_fields constant text[] := ARRAY['entity_type', 'email_address', 'resource_url', 'event_timestamp', 'tool',
                                      'latitude', 'longitude', 'ip_address', 'action_phrase', 'status'];
    c_common_keys constant text[] := ARRAY['value', 'validity', 'start_pos', 'source', 'missing_reason'];
    -- skeleton reduction: keys -> <key>, JSON strings -> <>, scalars -> #, arrays of scalars -> #
    c_string_pattern constant text := '"([a-z_]+)":|"(?:[^"' || chr(92) || chr(92) || ']|' || chr(92) || chr(92) || '.)*"';
    c_key_replacement constant text := '<' || chr(92) || '1>';
    c_common_skeleton constant text := '<value>#,<validity>#,<start_pos>#,<source>#,<missing_reason>#';
    c_skeleton constant text :=
           '{<log_id>#,<run_id>#,<record>{<format_family>#,<detection_rule>#,<sub_format>#,<record_validity>#,'
        || '<is_truncated>#,<event_end_pos>#,<diagnostics>#},<fields>{'
        || '<entity_type>{' || c_common_skeleton || ',<code>#},'
        || '<email_address>{' || c_common_skeleton || '},'
        || '<resource_url>{' || c_common_skeleton || '},'
        || '<event_timestamp>{' || c_common_skeleton || ',<shape>#,<local>#,<utc_offset_minutes>#,<utc>#},'
        || '<tool>{' || c_common_skeleton || '},'
        || '<latitude>{' || c_common_skeleton || ',<degrees>#},'
        || '<longitude>{' || c_common_skeleton || ',<degrees>#},'
        || '<ip_address>{' || c_common_skeleton || ',<address>#,<zone_id>#},'
        || '<action_phrase>{' || c_common_skeleton || '},'
        || '<status>{' || c_common_skeleton || ',<code>#,<word>#}}}';
    v_failed     text[] := '{}';
    v_checks     integer := 0;
    v_paths      text[];
    v_types      text[];
    v_flat       text[];
    v_text       text[];
    v_back       text[];
    v_sql        text;
    v_l          text;
    v_j          text;
    v_counts     bigint[];
    v_type_bad   bigint;
    v_text_bad   bigint;
    v_typed_bad  bigint;
    v_flat_nulls bigint;
    v_json_nulls bigint;
    v_bad        text;
    chk          record;
    tbl          record;
BEGIN
    IF to_regclass('log_regex_json.access_log_json') IS NULL OR to_regclass('log_regex_json.access_log_jsonb') IS NULL THEN
        RAISE EXCEPTION 'JSON experiment check FAILED: the experiment tables do not exist' USING ERRCODE = 'LR012';
    END IF;

    FOR chk IN
        WITH objects (path, keys) AS (
            VALUES ('{}'::text[], ARRAY['log_id', 'run_id', 'record', 'fields']),
                   ('{record}', ARRAY['format_family', 'detection_rule', 'sub_format', 'record_validity', 'is_truncated', 'event_end_pos', 'diagnostics']),
                   ('{fields}', c_fields),
                   ('{fields,entity_type}', c_common_keys || ARRAY['code']),
                   ('{fields,email_address}', c_common_keys),
                   ('{fields,resource_url}', c_common_keys),
                   ('{fields,event_timestamp}', c_common_keys || ARRAY['shape', 'local', 'utc_offset_minutes', 'utc']),
                   ('{fields,tool}', c_common_keys),
                   ('{fields,latitude}', c_common_keys || ARRAY['degrees']),
                   ('{fields,longitude}', c_common_keys || ARRAY['degrees']),
                   ('{fields,ip_address}', c_common_keys || ARRAY['address', 'zone_id']),
                   ('{fields,action_phrase}', c_common_keys),
                   ('{fields,status}', c_common_keys || ARRAY['code', 'word'])
        ),
        j AS (SELECT * FROM log_regex_json.access_log_json),
        b AS (SELECT * FROM log_regex_json.access_log_jsonb),
        f AS (SELECT * FROM log_regex.access_log_flat),
        v AS (
            SELECT a.log_id, x.field, x.value
            FROM f a
            CROSS JOIN LATERAL (VALUES ('entity_type', a.entity_type), ('email_address', a.email_address), ('resource_url', a.resource_url),
                                       ('event_timestamp', a.event_timestamp), ('tool', a.tool), ('latitude', a.latitude),
                                       ('longitude', a.longitude), ('ip_address', a.ip_address), ('action_phrase', a.action_phrase),
                                       ('status', a.status)) AS x (field, value)
            WHERE x.value IS NOT NULL
        ),
        esc AS (
            SELECT strpos(v.value, chr(34)) > 0                            AS has_quote,
                   strpos(v.value, chr(92)) > 0                            AS has_backslash,
                   octet_length(v.value) <> char_length(v.value)           AS has_non_ascii,
                   strpos(j.doc::text, '"value":' || to_json(v.value)::text) > 0
                   AND (j.doc -> 'fields' -> v.field ->> 'value') = v.value
                   AND (b.doc -> 'fields' -> v.field ->> 'value') = v.value AS all_ok
            FROM v
            JOIN j ON j.log_id = v.log_id
            JOIN b ON b.log_id = v.log_id
        ),
        comments AS (
            SELECT obj_description('log_regex_json.access_log_json'::regclass, 'pg_class')  AS json_comment,
                   obj_description('log_regex_json.access_log_jsonb'::regclass, 'pg_class') AS jsonb_comment
        )
        SELECT c.id, c.name, c.expected, c.actual
        FROM (VALUES
            -- B-01 rows
            ('B-01a', 'access_log_flat rows = raw logs', (SELECT count(*) FROM log_regex.raw_access_logs)::text, (SELECT count(*) FROM f)::text),
            ('B-01b', 'access_log_json rows = access_log_flat rows', (SELECT count(*) FROM f)::text, (SELECT count(*) FROM j)::text),
            ('B-01c', 'access_log_jsonb rows = access_log_flat rows', (SELECT count(*) FROM f)::text, (SELECT count(*) FROM b)::text),
            -- B-02 log_id sets
            ('B-02a', 'log_id differences json vs access_log_flat', '0',
                ((SELECT count(*) FROM (SELECT log_id FROM j EXCEPT SELECT log_id FROM f) AS x)
               + (SELECT count(*) FROM (SELECT log_id FROM f EXCEPT SELECT log_id FROM j) AS x))::text),
            ('B-02b', 'log_id differences jsonb vs access_log_flat', '0',
                ((SELECT count(*) FROM (SELECT log_id FROM b EXCEPT SELECT log_id FROM f) AS x)
               + (SELECT count(*) FROM (SELECT log_id FROM f EXCEPT SELECT log_id FROM b) AS x))::text),
            ('B-02c', 'log_id differences json vs jsonb', '0',
                ((SELECT count(*) FROM (SELECT log_id FROM j EXCEPT SELECT log_id FROM b) AS x)
               + (SELECT count(*) FROM (SELECT log_id FROM b EXCEPT SELECT log_id FROM j) AS x))::text),
            -- B-03 exact input text
            ('B-03a', 'md5 of stored json texts (log_id order, LF) = canonical input md5 recorded at load',
                (SELECT substring(json_comment FROM 'md5 ([0-9a-f]{32})') FROM comments),
                (SELECT md5(string_agg(doc::text, chr(10) ORDER BY log_id)) FROM j)),
            ('B-03b', 'bytes of stored json texts = canonical input bytes recorded at load',
                (SELECT substring(json_comment FROM '([0-9]+) bytes') FROM comments),
                (SELECT sum(octet_length(doc::text))::text FROM j)),
            ('B-03c', 'canonical input recorded for jsonb = recorded for json',
                (SELECT substring(json_comment FROM 'Canonical input: .*$') FROM comments),
                (SELECT substring(jsonb_comment FROM 'Canonical input: .*$') FROM comments)),
            ('B-03d', 'json texts equal to the designed minified skeleton (keys, order, nesting, no whitespace)', (SELECT count(*) FROM f)::text,
                (SELECT count(*) FROM j
                 WHERE regexp_replace(regexp_replace(regexp_replace(j.doc::text, c_string_pattern, c_key_replacement, 'g'),
                                                     '(?<=[>,[])(true|false|null|-?[0-9][0-9.eE+-]*|<>)', '#', 'g'),
                                      '[[](#(,#)*)?[]]', '#', 'g') = c_skeleton)::text),
            ('B-03e', 'documents whose log_id / run_id differ from the row and access_log_flat', '0',
                ((SELECT count(*) FROM j JOIN f ON f.log_id = j.log_id
                  WHERE (j.doc ->> 'log_id')::integer <> j.log_id OR (j.doc ->> 'run_id')::bigint <> f.run_id)
               + (SELECT count(*) FROM b JOIN f ON f.log_id = b.log_id
                  WHERE (b.doc ->> 'log_id')::integer <> b.log_id OR (b.doc ->> 'run_id')::bigint <> f.run_id))::text),
            -- B-04 semantic equivalence
            ('B-04', 'json documents cast to jsonb = jsonb documents', (SELECT count(*) FROM f)::text,
                (SELECT count(*) FROM j JOIN b ON b.log_id = j.log_id WHERE j.doc::jsonb = b.doc)::text),
            -- B-06 duplicate keys
            ('B-06a', 'json texts IS JSON OBJECT WITH UNIQUE KEYS', (SELECT count(*) FROM f)::text,
                (SELECT count(*) FROM j WHERE j.doc::text IS JSON OBJECT WITH UNIQUE KEYS)::text),
            ('B-06b', 'json objects with a repeated key (13 objects per document)', '0',
                (SELECT count(*) FROM j CROSS JOIN objects o
                 WHERE (SELECT count(*) FROM json_object_keys(j.doc #> o.path) AS k) <> (SELECT count(DISTINCT k) FROM json_object_keys(j.doc #> o.path) AS k))::text),
            -- B-07 structure
            ('B-07a', 'designed keys in total (13 objects)', '82', (SELECT sum(cardinality(keys))::text FROM objects)),
            ('B-07b', 'json documents with exactly 82 keys', (SELECT count(*) FROM f)::text,
                (SELECT count(*) FROM j WHERE (SELECT count(*) FROM objects o CROSS JOIN LATERAL json_object_keys(j.doc #> o.path) AS k) = 82)::text),
            ('B-07c', 'jsonb documents with exactly 82 keys', (SELECT count(*) FROM f)::text,
                (SELECT count(*) FROM b WHERE (SELECT count(*) FROM objects o CROSS JOIN LATERAL jsonb_object_keys(b.doc #> o.path) AS k) = 82)::text),
            ('B-07d', 'json documents whose keys per object equal the design, in design order', (SELECT count(*) FROM f)::text,
                (SELECT count(*) FROM j WHERE NOT EXISTS (
                    SELECT 1 FROM objects o
                    WHERE (SELECT array_agg(x.k ORDER BY x.n) FROM json_object_keys(j.doc #> o.path) WITH ORDINALITY AS x (k, n)) IS DISTINCT FROM o.keys))::text),
            ('B-07e', 'jsonb documents whose keys per object equal the design (as sets)', (SELECT count(*) FROM f)::text,
                (SELECT count(*) FROM b WHERE NOT EXISTS (
                    SELECT 1 FROM objects o
                    WHERE (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(b.doc #> o.path) AS k)
                          IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(o.keys) AS k)))::text),
            -- B-08 escaping
            ('B-08a', 'values with double quotes: escaped in json text, equal after ->> in json and jsonb',
                (SELECT count(*) FROM esc WHERE has_quote)::text, (SELECT count(*) FROM esc WHERE has_quote AND all_ok)::text),
            ('B-08b', 'values with backslashes: escaped in json text, equal after ->> in json and jsonb',
                (SELECT count(*) FROM esc WHERE has_backslash)::text, (SELECT count(*) FROM esc WHERE has_backslash AND all_ok)::text),
            ('B-08c', 'values with non-ASCII characters: present in json text, equal after ->> in json and jsonb',
                (SELECT count(*) FROM esc WHERE has_non_ascii)::text, (SELECT count(*) FROM esc WHERE has_non_ascii AND all_ok)::text),
            ('B-08d', 'all stored values: present in json text, equal after ->> in json and jsonb',
                (SELECT count(*) FROM esc)::text, (SELECT count(*) FROM esc WHERE all_ok)::text),
            -- B-10 isolation
            -- Step 6D adds designed experiment indexes (docs/Step6D_JSON_vs_JSONB_Index_Experiment.md); any other relation fails
            ('B-10a', 'relations in schema log_regex_json: the two tables and their primary keys; other relations that are not designed Step 6D indexes',
                'r:access_log_json r:access_log_jsonb i:access_log_json_pkey i:access_log_jsonb_pkey; other: 0',
                (SELECT string_agg(c.relkind::text || ':' || c.relname, ' ' ORDER BY c.relkind DESC, c.relname)
                            FILTER (WHERE c.relname IN ('access_log_json', 'access_log_jsonb', 'access_log_json_pkey', 'access_log_jsonb_pkey'))
                        || '; other: '
                        || count(*) FILTER (WHERE c.relname NOT IN ('access_log_json', 'access_log_jsonb', 'access_log_json_pkey', 'access_log_jsonb_pkey')
                                              AND NOT (c.relkind = 'i' AND c.relname IN (
                                                  'access_log_json_i1a_record_validity', 'access_log_jsonb_i1a_record_validity',
                                                  'access_log_json_i1b_entity_type_code', 'access_log_jsonb_i1b_entity_type_code',
                                                  'access_log_json_i1c_status_code', 'access_log_jsonb_i1c_status_code',
                                                  'access_log_json_i1d_latitude_degrees', 'access_log_jsonb_i1d_latitude_degrees',
                                                  'access_log_json_i1e_event_timestamp_utc', 'access_log_jsonb_i1e_event_timestamp_utc',
                                                  'access_log_jsonb_i2_gin_jsonb_ops', 'access_log_jsonb_i3_gin_jsonb_path_ops')))
                 FROM pg_class c WHERE c.relnamespace = 'log_regex_json'::regnamespace)),
            ('B-10b', 'doc column types', 'json / jsonb',
                (SELECT format_type(a1.atttypid, a1.atttypmod) || ' / ' || format_type(a2.atttypid, a2.atttypmod)
                 FROM pg_attribute a1, pg_attribute a2
                 WHERE a1.attrelid = 'log_regex_json.access_log_json'::regclass AND a1.attname = 'doc'
                   AND a2.attrelid = 'log_regex_json.access_log_jsonb'::regclass AND a2.attname = 'doc')),
            ('B-10c', 'constraints other than the 2 primary keys, and foreign keys to or from log_regex_json', '0',
                (SELECT count(*) FROM pg_constraint k
                 WHERE (k.conrelid IN ('log_regex_json.access_log_json'::regclass, 'log_regex_json.access_log_jsonb'::regclass) AND k.contype <> 'p')
                    OR k.confrelid IN ('log_regex_json.access_log_json'::regclass, 'log_regex_json.access_log_jsonb'::regclass))::text),
            ('B-10d', 'triggers on the experiment tables', '0',
                (SELECT count(*) FROM pg_trigger t
                 WHERE t.tgrelid IN ('log_regex_json.access_log_json'::regclass, 'log_regex_json.access_log_jsonb'::regclass))::text),
            ('B-10e', 'dependencies between log_regex and log_regex_json relations', '0',
                (SELECT count(*) FROM pg_depend d
                 JOIN pg_class c1 ON d.classid = 'pg_class'::regclass AND c1.oid = d.objid
                 JOIN pg_class c2 ON d.refclassid = 'pg_class'::regclass AND c2.oid = d.refobjid
                 WHERE (c1.relnamespace = 'log_regex_json'::regnamespace AND c2.relnamespace = 'log_regex'::regnamespace)
                    OR (c1.relnamespace = 'log_regex'::regnamespace AND c2.relnamespace = 'log_regex_json'::regnamespace))::text),
            ('B-10f', 'functions, views and sequences in log_regex_json', '0',
                ((SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'log_regex_json'::regnamespace)
               + (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind IN ('v', 'm', 'S')))::text)
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

    -- B-05 / B-09: the 70 leaves, one scan per table ------------------------------------------------------------------
    SELECT array_agg(m.path ORDER BY m.leaf_no), array_agg(m.json_type ORDER BY m.leaf_no), array_agg(m.flat_expr ORDER BY m.leaf_no),
           array_agg(m.text_form ORDER BY m.leaf_no), array_agg(m.back_expr ORDER BY m.leaf_no)
      INTO v_paths, v_types, v_flat, v_text, v_back
      FROM (
        VALUES (1, '{log_id}', 'number', 'a.log_id', 'a.log_id::text', '$L::integer'),
               (2, '{run_id}', 'number', 'a.run_id', 'a.run_id::text', '$L::bigint'),
               (3, '{record,format_family}', 'string', 'a.format_family', 'a.format_family', '$L'),
               (4, '{record,detection_rule}', 'string', 'a.detection_rule', 'a.detection_rule', '$L'),
               (5, '{record,sub_format}', 'string', 'a.sub_format', 'a.sub_format', '$L'),
               (6, '{record,record_validity}', 'string', 'a.record_validity::text', 'a.record_validity::text', '$L'),
               (7, '{record,is_truncated}', 'boolean', 'a.is_truncated', 'CASE WHEN a.is_truncated THEN ''true'' ELSE ''false'' END', '$L::boolean'),
               (8, '{record,event_end_pos}', 'number', 'a.event_end_pos', 'a.event_end_pos::text', '$L::integer'),
               (9, '{record,diagnostics}', 'array', 'a.diagnostics', NULL,
                   'ARRAY(SELECT e.x FROM $P_array_elements_text($J) WITH ORDINALITY AS e (x, o) ORDER BY e.o)'),
               (216, '{fields,entity_type,code}', 'string', 'a.entity_type_code', 'a.entity_type_code', '$L'),
               (246, '{fields,event_timestamp,shape}', 'string', 'a.event_timestamp_shape', 'a.event_timestamp_shape', '$L'),
               (247, '{fields,event_timestamp,local}', 'string', 'a.event_timestamp_local',
                     'to_char(a.event_timestamp_local, ''YYYY-MM-DD"T"HH24:MI:SS.US'')', '$L::timestamp(6)'),
               (248, '{fields,event_timestamp,utc_offset_minutes}', 'number', 'a.event_timestamp_utc_offset',
                     '(extract(epoch FROM a.event_timestamp_utc_offset) / 60)::integer::text', '$L::integer * interval ''1 minute'''),
               (249, '{fields,event_timestamp,utc}', 'string', 'a.event_timestamp_utc',
                     'to_char(a.event_timestamp_utc AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS.US"Z"'')', '$L::timestamptz'),
               (266, '{fields,latitude,degrees}', 'number', 'a.latitude_degrees', 'a.latitude_degrees::text', '$L::numeric'),
               (276, '{fields,longitude,degrees}', 'number', 'a.longitude_degrees', 'a.longitude_degrees::text', '$L::numeric'),
               (286, '{fields,ip_address,address}', 'string', 'a.ip_address_inet', 'host(a.ip_address_inet)', '$L::inet'),
               (287, '{fields,ip_address,zone_id}', 'string', 'a.ip_address_zone_id', 'a.ip_address_zone_id', '$L'),
               (306, '{fields,status,code}', 'number', 'a.status_code', 'a.status_code::text', '$L::smallint'),
               (307, '{fields,status,word}', 'string', 'a.status_word', 'a.status_word', '$L')
        UNION ALL
        SELECT 200 + f.o::integer * 10 - 10 + c.key_no,
               format('{fields,%s,%s}', f.name, c.key_name), c.json_type,
               format('a.%I', f.name || c.suffix) || c.flat_cast,
               format('a.%I', f.name || c.suffix) || c.text_cast,
               c.back_expr
        FROM unnest(c_fields) WITH ORDINALITY AS f (name, o)
        CROSS JOIN (VALUES (1, 'value', 'string', '', '', '', '$L'),
                           (2, 'validity', 'string', '_validity', '::text', '::text', '$L'),
                           (3, 'start_pos', 'number', '_start_pos', '', '::text', '$L::integer'),
                           (4, 'source', 'string', '_source', '', '', '$L'),
                           (5, 'missing_reason', 'string', '_missing_reason', '::text', '::text', '$L')
                   ) AS c (key_no, key_name, json_type, suffix, flat_cast, text_cast, back_expr)
      ) AS m (leaf_no, path, json_type, flat_expr, text_form, back_expr);

    v_checks := v_checks + 1;
    IF cardinality(v_paths) = 70 AND (SELECT count(DISTINCT p) FROM unnest(v_paths) AS p) = 70 THEN
        RAISE NOTICE 'B-05  PASS  leaf map: 70 distinct designed leaves';
    ELSE
        v_failed := v_failed || 'B-05'::text;
        RAISE WARNING 'B-05  FAIL  leaf map has % leaves', cardinality(v_paths);
    END IF;

    FOR tbl IN SELECT * FROM (VALUES ('access_log_json', 'json'), ('access_log_jsonb', 'jsonb')) AS x (table_name, prefix) LOOP
        v_sql := '';
        FOR i IN 1 .. cardinality(v_paths) LOOP
            v_l := format('(t.doc #>> %L)', v_paths[i]);
            v_j := format('(t.doc #> %L)', v_paths[i]);
            v_sql := v_sql || CASE WHEN i > 1 THEN ', ' ELSE '' END
                || format('count(*) FILTER (WHERE %s_typeof(%s) IS DISTINCT FROM CASE WHEN (%s) IS NULL THEN %L ELSE %L END)',
                          tbl.prefix, v_j, v_flat[i], 'null', v_types[i])
                || ', ' || CASE WHEN v_text[i] IS NULL THEN '0::bigint'
                                ELSE format('count(*) FILTER (WHERE %s IS DISTINCT FROM (%s))', v_l, v_text[i]) END
                || ', ' || format('count(*) FILTER (WHERE (%s) IS DISTINCT FROM (%s))',
                                  replace(replace(replace(v_back[i], '$L', v_l), '$J', v_j), '$P', tbl.prefix), v_flat[i])
                || ', ' || format('count(*) FILTER (WHERE (%s) IS NULL)', v_flat[i])
                || ', ' || format('count(*) FILTER (WHERE %s_typeof(%s) = %L)', tbl.prefix, v_j, 'null');
        END LOOP;
        EXECUTE format('SELECT ARRAY[%s]::bigint[] FROM log_regex_json.%I AS t JOIN log_regex.access_log_flat AS a ON a.log_id = t.log_id',
                       v_sql, tbl.table_name)
           INTO v_counts;

        v_type_bad := 0; v_text_bad := 0; v_typed_bad := 0; v_flat_nulls := 0; v_json_nulls := 0; v_bad := '';
        FOR i IN 1 .. cardinality(v_paths) LOOP
            v_type_bad   := v_type_bad   + v_counts[5 * i - 4];
            v_text_bad   := v_text_bad   + v_counts[5 * i - 3];
            v_typed_bad  := v_typed_bad  + v_counts[5 * i - 2];
            v_flat_nulls := v_flat_nulls + v_counts[5 * i - 1];
            v_json_nulls := v_json_nulls + v_counts[5 * i];
            IF v_counts[5 * i - 4] + v_counts[5 * i - 3] + v_counts[5 * i - 2] > 0 THEN
                v_bad := v_bad || format(' %s (type %s, text %s, typed %s);', v_paths[i], v_counts[5 * i - 4], v_counts[5 * i - 3], v_counts[5 * i - 2]);
            END IF;
        END LOOP;

        v_checks := v_checks + 4;
        IF v_type_bad = 0 THEN
            RAISE NOTICE 'B-05a PASS  %: 70 leaves x rows present with the designed JSON type (null exactly for SQL NULL): 0 mismatches', tbl.table_name;
        ELSE v_failed := v_failed || ('B-05a ' || tbl.table_name); RAISE WARNING 'B-05a FAIL  %: % type/presence mismatches', tbl.table_name, v_type_bad; END IF;
        IF v_text_bad = 0 THEN
            RAISE NOTICE 'B-05b PASS  %: 69 scalar leaves equal their exact text form: 0 mismatches', tbl.table_name;
        ELSE v_failed := v_failed || ('B-05b ' || tbl.table_name); RAISE WARNING 'B-05b FAIL  %: % text mismatches', tbl.table_name, v_text_bad; END IF;
        IF v_typed_bad = 0 THEN
            RAISE NOTICE 'B-05c PASS  %: 70 leaves cast back IS NOT DISTINCT FROM access_log_flat: 0 mismatches', tbl.table_name;
        ELSE v_failed := v_failed || ('B-05c ' || tbl.table_name); RAISE WARNING 'B-05c FAIL  %: % typed mismatches:%', tbl.table_name, v_typed_bad, left(v_bad, 2000); END IF;
        IF v_json_nulls = v_flat_nulls THEN
            RAISE NOTICE 'B-09  PASS  %: JSON null leaves with key present = SQL NULL cells of the 70 flat columns: %', tbl.table_name, v_json_nulls;
        ELSE v_failed := v_failed || ('B-09 ' || tbl.table_name); RAISE WARNING 'B-09  FAIL  %: JSON null leaves %, flat NULL cells %', tbl.table_name, v_json_nulls, v_flat_nulls; END IF;
    END LOOP;

    IF cardinality(v_failed) > 0 THEN
        RAISE EXCEPTION 'JSON experiment check FAILED: % of % checks: %', cardinality(v_failed), v_checks, array_to_string(v_failed, ', ')
            USING ERRCODE = 'LR012';
    END IF;
    RAISE NOTICE 'JSON experiment check PASSED: all % checks', v_checks;
END
$verify$;

ROLLBACK;
