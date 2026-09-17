-- =============================================================================
-- Step 6B / 33 - Load the JSON and JSONB experiment tables from the same canonical text
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/33_load_json_experiment_tables.sql
--
-- Implements docs/Step6A_JSON_vs_JSONB_Experiment_Design.md sections 2 and 8 in one REPEATABLE READ transaction:
--   1. stage one canonical document text per access_log_flat row: minified, keys in design order, 82 keys / 70 leaves,
--      every key present, SQL NULL -> JSON null; string escaping by to_json()
--   2. gate: one text per flat row; every text IS JSON OBJECT WITH UNIQUE KEYS; UTC offsets are whole minutes
--   3. INSERT the same staged text as json and as jsonb (ORDER BY log_id)
--   4. gate before COMMIT: 5,000 rows each; log_id sets equal to the flat table; json text byte-identical to the staged
--      text; jsonb equal to the staged text cast to jsonb and to the json document cast to jsonb
--   5. record the canonical input (documents, bytes, md5 of the texts in log_id order joined by LF) in both table
--      comments; COMMIT; VACUUM (ANALYZE) both experiment tables
-- Document leaf formats: local time YYYY-MM-DD"T"HH24:MI:SS.US; UTC instant the same with "Z" (from
-- event_timestamp_utc AT TIME ZONE 'UTC'); UTC offset integer minutes; coordinates numeric(10,7) text; IP host().
--
-- Safety: refuses (SQLSTATE LR011) unless both experiment tables exist and are empty and access_log_flat holds one row
-- per raw log from one run. Reads access_log_flat only; inserts only into the two experiment tables; staging uses a
-- temporary table dropped at COMMIT; no index, no EXPLAIN. Full verification: sql/34; storage figures: sql/35.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN ISOLATION LEVEL REPEATABLE READ;

SET LOCAL lock_timeout = '10s';
SET LOCAL TimeZone = 'UTC';

-- BEGIN load guard
DO $$
DECLARE
    v_json  bigint;
    v_jsonb bigint;
    v_flat  bigint;
    v_ids   bigint;
    v_runs  bigint;
    v_raw   bigint;
BEGIN
    IF to_regclass('log_regex_json.access_log_json') IS NULL OR to_regclass('log_regex_json.access_log_jsonb') IS NULL THEN
        RAISE EXCEPTION 'sql/33_load_json_experiment_tables.sql refused: the experiment tables do not exist (run sql/32 first)'
            USING ERRCODE = 'LR011';
    END IF;
    SELECT count(*) INTO v_json FROM log_regex_json.access_log_json;
    SELECT count(*) INTO v_jsonb FROM log_regex_json.access_log_jsonb;
    IF v_json <> 0 OR v_jsonb <> 0 THEN
        RAISE EXCEPTION 'sql/33_load_json_experiment_tables.sql refused: the experiment tables already hold % / % rows; this script never deletes or replaces rows', v_json, v_jsonb
            USING ERRCODE = 'LR011',
                  HINT    = 'Verify the loaded tables with sql/34 and sql/35.';
    END IF;
    SELECT count(*), count(DISTINCT log_id), count(DISTINCT run_id) INTO v_flat, v_ids, v_runs FROM log_regex.access_log_flat;
    SELECT count(*) INTO v_raw FROM log_regex.raw_access_logs;
    IF v_flat <> v_raw OR v_ids <> v_raw OR v_runs <> 1 THEN
        RAISE EXCEPTION 'sql/33_load_json_experiment_tables.sql refused: access_log_flat % rows / % log_ids / % runs for % raw logs', v_flat, v_ids, v_runs, v_raw
            USING ERRCODE = 'LR011';
    END IF;
    RAISE NOTICE 'load guard passed: both experiment tables empty; access_log_flat % rows from one run', v_flat;
END
$$;
-- END load guard

-- BEGIN canonical document text (document version 1)
CREATE TEMP TABLE json_stage ON COMMIT DROP AS
SELECT a.log_id,
       '{"log_id":' || a.log_id::text
    || ',"run_id":' || a.run_id::text
    || ',"record":{'
    ||   '"format_family":'   || to_json(a.format_family)::text
    ||  ',"detection_rule":'  || to_json(a.detection_rule)::text
    ||  ',"sub_format":'      || coalesce(to_json(a.sub_format)::text, 'null')
    ||  ',"record_validity":' || to_json(a.record_validity::text)::text
    ||  ',"is_truncated":'    || CASE WHEN a.is_truncated THEN 'true' ELSE 'false' END
    ||  ',"event_end_pos":'   || coalesce(a.event_end_pos::text, 'null')
    ||  ',"diagnostics":'     || to_json(a.diagnostics)::text
    || '},"fields":{'
    || '"entity_type":{'
    ||   '"value":'           || coalesce(to_json(a.entity_type)::text, 'null')
    ||  ',"validity":'        || to_json(a.entity_type_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.entity_type_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.entity_type_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.entity_type_missing_reason::text)::text, 'null')
    ||  ',"code":'            || coalesce(to_json(a.entity_type_code)::text, 'null')
    || '},"email_address":{'
    ||   '"value":'           || coalesce(to_json(a.email_address)::text, 'null')
    ||  ',"validity":'        || to_json(a.email_address_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.email_address_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.email_address_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.email_address_missing_reason::text)::text, 'null')
    || '},"resource_url":{'
    ||   '"value":'           || coalesce(to_json(a.resource_url)::text, 'null')
    ||  ',"validity":'        || to_json(a.resource_url_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.resource_url_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.resource_url_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.resource_url_missing_reason::text)::text, 'null')
    || '},"event_timestamp":{'
    ||   '"value":'           || coalesce(to_json(a.event_timestamp)::text, 'null')
    ||  ',"validity":'        || to_json(a.event_timestamp_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.event_timestamp_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.event_timestamp_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.event_timestamp_missing_reason::text)::text, 'null')
    ||  ',"shape":'           || coalesce(to_json(a.event_timestamp_shape)::text, 'null')
    ||  ',"local":'           || coalesce(to_json(to_char(a.event_timestamp_local, 'YYYY-MM-DD"T"HH24:MI:SS.US'))::text, 'null')
    ||  ',"utc_offset_minutes":' || coalesce((extract(epoch FROM a.event_timestamp_utc_offset) / 60)::integer::text, 'null')
    ||  ',"utc":'             || coalesce(to_json(to_char(a.event_timestamp_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))::text, 'null')
    || '},"tool":{'
    ||   '"value":'           || coalesce(to_json(a.tool)::text, 'null')
    ||  ',"validity":'        || to_json(a.tool_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.tool_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.tool_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.tool_missing_reason::text)::text, 'null')
    || '},"latitude":{'
    ||   '"value":'           || coalesce(to_json(a.latitude)::text, 'null')
    ||  ',"validity":'        || to_json(a.latitude_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.latitude_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.latitude_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.latitude_missing_reason::text)::text, 'null')
    ||  ',"degrees":'         || coalesce(a.latitude_degrees::text, 'null')
    || '},"longitude":{'
    ||   '"value":'           || coalesce(to_json(a.longitude)::text, 'null')
    ||  ',"validity":'        || to_json(a.longitude_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.longitude_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.longitude_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.longitude_missing_reason::text)::text, 'null')
    ||  ',"degrees":'         || coalesce(a.longitude_degrees::text, 'null')
    || '},"ip_address":{'
    ||   '"value":'           || coalesce(to_json(a.ip_address)::text, 'null')
    ||  ',"validity":'        || to_json(a.ip_address_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.ip_address_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.ip_address_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.ip_address_missing_reason::text)::text, 'null')
    ||  ',"address":'         || coalesce(to_json(host(a.ip_address_inet))::text, 'null')
    ||  ',"zone_id":'         || coalesce(to_json(a.ip_address_zone_id)::text, 'null')
    || '},"action_phrase":{'
    ||   '"value":'           || coalesce(to_json(a.action_phrase)::text, 'null')
    ||  ',"validity":'        || to_json(a.action_phrase_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.action_phrase_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.action_phrase_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.action_phrase_missing_reason::text)::text, 'null')
    || '},"status":{'
    ||   '"value":'           || coalesce(to_json(a.status)::text, 'null')
    ||  ',"validity":'        || to_json(a.status_validity::text)::text
    ||  ',"start_pos":'       || coalesce(a.status_start_pos::text, 'null')
    ||  ',"source":'          || coalesce(to_json(a.status_source)::text, 'null')
    ||  ',"missing_reason":'  || coalesce(to_json(a.status_missing_reason::text)::text, 'null')
    ||  ',"code":'            || coalesce(a.status_code::text, 'null')
    ||  ',"word":'            || coalesce(to_json(a.status_word)::text, 'null')
    || '}}}' AS doc_text
FROM log_regex.access_log_flat a;
-- END canonical document text

-- BEGIN stage gate
DO $$
DECLARE
    v_staged      bigint;
    v_flat        bigint;
    v_not_json    bigint;
    v_bad_offsets bigint;
    v_bytes       bigint;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE NOT (doc_text IS JSON OBJECT WITH UNIQUE KEYS)), sum(octet_length(doc_text))
      INTO v_staged, v_not_json, v_bytes FROM pg_temp.json_stage;
    SELECT count(*) INTO v_flat FROM log_regex.access_log_flat;
    SELECT count(*) INTO v_bad_offsets
      FROM log_regex.access_log_flat
     WHERE event_timestamp_utc_offset IS NOT NULL AND extract(epoch FROM event_timestamp_utc_offset) % 60 <> 0;
    IF v_staged <> v_flat OR v_not_json <> 0 OR v_bad_offsets <> 0 THEN
        RAISE EXCEPTION 'sql/33_load_json_experiment_tables.sql stage gate FAILED, rolled back: % staged texts for % flat rows; % not a JSON object with unique keys; % offsets not whole minutes',
            v_staged, v_flat, v_not_json, v_bad_offsets
            USING ERRCODE = 'LR011';
    END IF;
    RAISE NOTICE 'stage gate passed: % canonical texts (% bytes), all JSON objects with unique keys; all UTC offsets whole minutes', v_staged, v_bytes;
END
$$;
-- END stage gate

-- Load: the same staged text, cast once to each type ----------------------------------------------------------------
INSERT INTO log_regex_json.access_log_json (log_id, doc)
SELECT log_id, doc_text::json FROM pg_temp.json_stage ORDER BY log_id;

INSERT INTO log_regex_json.access_log_jsonb (log_id, doc)
SELECT log_id, doc_text::jsonb FROM pg_temp.json_stage ORDER BY log_id;

-- BEGIN load gate (before COMMIT)
DO $$
DECLARE
    v_flat          bigint;
    v_run           bigint;
    v_json          bigint;
    v_jsonb         bigint;
    v_set_diff      bigint;
    v_text_diff     bigint;
    v_semantic_diff bigint;
    v_bytes         bigint;
    v_md5           text;
    v_input         text;
BEGIN
    SELECT count(*), min(run_id) INTO v_flat, v_run FROM log_regex.access_log_flat;
    SELECT count(*) INTO v_json FROM log_regex_json.access_log_json;
    SELECT count(*) INTO v_jsonb FROM log_regex_json.access_log_jsonb;

    SELECT (SELECT count(*) FROM (SELECT log_id FROM log_regex.access_log_flat EXCEPT SELECT log_id FROM log_regex_json.access_log_json) AS x)
         + (SELECT count(*) FROM (SELECT log_id FROM log_regex_json.access_log_json EXCEPT SELECT log_id FROM log_regex.access_log_flat) AS x)
         + (SELECT count(*) FROM (SELECT log_id FROM log_regex.access_log_flat EXCEPT SELECT log_id FROM log_regex_json.access_log_jsonb) AS x)
         + (SELECT count(*) FROM (SELECT log_id FROM log_regex_json.access_log_jsonb EXCEPT SELECT log_id FROM log_regex.access_log_flat) AS x)
      INTO v_set_diff;

    SELECT count(*) INTO v_text_diff
      FROM pg_temp.json_stage s
      LEFT JOIN log_regex_json.access_log_json j ON j.log_id = s.log_id
     WHERE j.doc::text IS DISTINCT FROM s.doc_text;

    SELECT count(*) INTO v_semantic_diff
      FROM pg_temp.json_stage s
      LEFT JOIN log_regex_json.access_log_json j  ON j.log_id = s.log_id
      LEFT JOIN log_regex_json.access_log_jsonb b ON b.log_id = s.log_id
     WHERE b.doc IS DISTINCT FROM s.doc_text::jsonb OR j.doc::jsonb IS DISTINCT FROM b.doc;

    SELECT sum(octet_length(doc_text)), md5(string_agg(doc_text, chr(10) ORDER BY log_id))
      INTO v_bytes, v_md5 FROM pg_temp.json_stage;

    IF v_json <> v_flat OR v_jsonb <> v_flat OR v_set_diff <> 0 OR v_text_diff <> 0 OR v_semantic_diff <> 0 THEN
        RAISE EXCEPTION 'sql/33_load_json_experiment_tables.sql load gate FAILED, rolled back: json % rows, jsonb % rows, flat % rows; log_id set differences %; json text differences %; semantic differences %',
            v_json, v_jsonb, v_flat, v_set_diff, v_text_diff, v_semantic_diff
            USING ERRCODE = 'LR011';
    END IF;

    v_input := format('Canonical input: %s documents from access_log_flat run %s, %s bytes of minified text, md5 %s (texts in log_id order joined by LF).',
                      v_json, v_run, v_bytes, v_md5);
    EXECUTE format('COMMENT ON TABLE log_regex_json.access_log_json IS %L',
                   'Step 6B: one json document per access_log_flat row (document version 1). ' || v_input);
    EXECUTE format('COMMENT ON TABLE log_regex_json.access_log_jsonb IS %L',
                   'Step 6B: one jsonb document per access_log_flat row (document version 1), cast from the same canonical text. ' || v_input);

    RAISE NOTICE 'load gate passed: json % rows, jsonb % rows; log_id sets equal to access_log_flat; json text = canonical text for all; jsonb = canonical text::jsonb = json::jsonb for all; input % bytes, md5 %',
        v_json, v_jsonb, v_bytes, v_md5;
END
$$;
-- END load gate

COMMIT;

VACUUM (ANALYZE) log_regex_json.access_log_json;
VACUUM (ANALYZE) log_regex_json.access_log_jsonb;

SELECT c.relname AS loaded_table, c.reltuples::bigint AS rows_after_analyze, c.relpages AS pages,
       obj_description(c.oid, 'pg_class') AS comment
FROM pg_class c
WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
ORDER BY c.relname;
