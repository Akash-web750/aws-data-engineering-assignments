-- =============================================================================
-- Step 3B-5 / 18 - F3 extraction: syslog header + regex-only scan of the JSON event
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/18_parser_f3.sql
--
-- Implements the F3-specific stages S2-S4 (Step 3A sections 5 and 7.3, C-09):
--   1. Header: only the text before the JSON opening is read.
--        RFC 5424  <PRI>1 TIMESTAMP HOST APP PROCID MSGID SD
--        RFC 3164  Mon dd HH:MM:SS HOST TAG:        (double space before a one-digit day kept)
--   2. Body: a forward-only scanner over the JSON text. Regular expressions anchored at the cursor recognise
--      strings (escaped characters allowed), numbers, NaN, null, true, false and the structural characters;
--      a container stack gives every scalar its key path. The text is never converted to a JSON data type.
--   3. Key path -> field through ref_key_alias (F3). A top-level non-alias key whose string value is e-mail
--      shaped is a secondary value <key>_email (EC-022 notify).
-- Event scope (S2): from the start of raw_log to the closing brace of the top-level object, or to the end of the
-- text if the object never closes (EC-135). Pretty-printed JSON over several lines is one event (EC-144).
-- Truncation (Step 3A 10.3): a string, object or array still open at the end of the text gives the diagnostic
-- "truncated"; a value cut off inside its string is extracted as far as it goes.
-- Reads nothing but its argument and ref_key_alias. Re-runnable (drop + create of this function only).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DROP FUNCTION IF EXISTS log_regex.f3_candidates(text);

-- S2-S4: F3 candidates ---------------------------------------------------------------------------------
-- Same output shape as f1_candidates() / f2_candidates(). Roles: primary, secondary, diagnostic, and one
-- event_end row whose start_pos is the last character of the event (run_parser stores it as event_end_pos).
-- For a primary candidate, secondary_kind is the JSON key path: the kind recorded if a value for the same field
-- appeared earlier in the document (C-01, EC-128 "status":401 before "result":"FAILED").
CREATE FUNCTION log_regex.f3_candidates(p_raw text)
RETURNS TABLE (field_name text, value text, start_pos integer, slot_id text, role text,
               secondary_kind text, doc_order integer, diagnostic text)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    c_ws        constant text := ' ' || chr(9) || chr(10) || chr(13);
    -- A closed string token; group 1 = the characters between the quotes.
    c_string    constant text := '^"((?:[^"\\]|\\.)*)"';
    -- A bare token: number, NaN (not valid JSON, present in the data), null, true, false.
    c_bare      constant text := '^(-?[0-9]+(?:[.][0-9]+)?(?:[eE][+-]?[0-9]+)?|NaN|null|true|false)(?![A-Za-z0-9_.])';
    v_len       integer := char_length(p_raw);
    v_open      integer;
    v_header    text;
    v_pos       integer;
    v_rest      text;
    v_ch        text;
    v_expect    text := 'value';            -- value | key | colon | next
    v_kinds     text[]    := ARRAY[]::text[];     -- container stack: object | array
    v_paths     text[]    := ARRAY[]::text[];     -- key path of each open container
    v_indexes   integer[] := ARRAY[]::integer[];  -- current element index of each open array
    v_depth     integer;
    v_key       text;
    v_path      text;
    v_value     text;
    v_value_pos integer;
    v_is_string boolean;
    v_event_end integer;
    v_truncated boolean := false;
    v_steps     integer := 0;
    a           log_regex.ref_key_alias%ROWTYPE;
    m           text[];
BEGIN
    IF p_raw IS NULL THEN
        RETURN;
    END IF;

    v_open := regexp_instr(p_raw, '\{[[:space:]]*"');
    IF v_open = 0 THEN
        RETURN QUERY SELECT NULL::text, NULL::text, 1, 'F3.body'::text, 'diagnostic'::text, NULL::text, 1,
                            'json_object_not_found'::text;
        RETURN;
    END IF;

    -- 1. Syslog header ---------------------------------------------------------------------------------------
    v_header := left(p_raw, v_open - 1);
    m := regexp_match(v_header, '^(<[0-9]{1,3}>1 )([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ (?:-|\[[^]]*\])+ *$');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT 'event_timestamp'::text, m[2], char_length(m[1]) + 1, 'F3.header.rfc5424'::text,
                            'primary'::text, NULL::text, char_length(m[1]) + 1, NULL::text;
    ELSE
        m := regexp_match(v_header, '^([A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2}) [^ ]+ [^ ]+: *$');
        IF m IS NOT NULL THEN
            RETURN QUERY SELECT 'event_timestamp'::text, m[1], 1, 'F3.header.rfc3164'::text, 'primary'::text,
                                NULL::text, 1, NULL::text;
        ELSE
            RETURN QUERY SELECT NULL::text, v_header, 1, 'F3.header'::text, 'diagnostic'::text, NULL::text, 1,
                                'syslog_header_not_recognised'::text;
        END IF;
    END IF;

    -- 2. JSON body scanner -----------------------------------------------------------------------------------
    v_pos := v_open;
    LOOP
        v_steps := v_steps + 1;
        IF v_steps > 5000 THEN
            RETURN QUERY SELECT NULL::text, NULL::text, v_pos, 'F3.body'::text, 'diagnostic'::text, NULL::text,
                                v_pos, 'json_scan_limit'::text;
            EXIT;
        END IF;

        v_rest := substr(p_raw, v_pos);
        v_pos  := v_pos + char_length(v_rest) - char_length(ltrim(v_rest, c_ws));
        IF v_pos > v_len THEN
            v_truncated := true;   -- the text ends while an object or array is still open
            EXIT;
        END IF;
        v_rest  := substr(p_raw, v_pos);
        v_ch    := left(v_rest, 1);
        v_depth := cardinality(v_kinds);

        -- Closing an object (after a key position or a value) or an array (after a value position or a value).
        IF (v_ch = '}' AND v_depth > 0 AND v_kinds[v_depth] = 'object' AND v_expect IN ('key', 'next'))
           OR (v_ch = ']' AND v_depth > 0 AND v_kinds[v_depth] = 'array' AND v_expect IN ('value', 'next')) THEN
            v_kinds   := v_kinds[1:v_depth - 1];
            v_paths   := v_paths[1:v_depth - 1];
            v_indexes := v_indexes[1:v_depth - 1];
            IF v_depth = 1 THEN
                v_event_end := v_pos;
                EXIT;
            END IF;
            v_pos    := v_pos + 1;
            v_expect := 'next';
            CONTINUE;
        END IF;

        IF v_expect = 'key' THEN
            m := regexp_match(v_rest, c_string);
            IF v_ch <> '"' OR m IS NULL THEN
                IF v_ch = '"' THEN
                    v_truncated := true;   -- key string not closed
                ELSE
                    RETURN QUERY SELECT NULL::text, left(v_rest, 20), v_pos, 'F3.body'::text, 'diagnostic'::text,
                                        NULL::text, v_pos, 'unexpected_json_text'::text;
                END IF;
                EXIT;
            END IF;
            v_key    := m[1];
            v_pos    := v_pos + char_length(m[1]) + 2;
            v_expect := 'colon';

        ELSIF v_expect = 'colon' THEN
            IF v_ch <> ':' THEN
                RETURN QUERY SELECT NULL::text, left(v_rest, 20), v_pos, 'F3.body'::text, 'diagnostic'::text,
                                    NULL::text, v_pos, 'unexpected_json_text'::text;
                EXIT;
            END IF;
            v_pos    := v_pos + 1;
            v_expect := 'value';

        ELSIF v_expect = 'next' THEN
            IF v_ch <> ',' THEN
                RETURN QUERY SELECT NULL::text, left(v_rest, 20), v_pos, 'F3.body'::text, 'diagnostic'::text,
                                    NULL::text, v_pos, 'unexpected_json_text'::text;
                EXIT;
            END IF;
            v_pos := v_pos + 1;
            IF v_kinds[v_depth] = 'array' THEN
                v_indexes[v_depth] := v_indexes[v_depth] + 1;
                v_expect := 'value';
            ELSE
                v_expect := 'key';
            END IF;

        ELSE
            -- A value. Its key path: key, parent.key, or parent[index].
            v_path := CASE
                          WHEN v_depth = 0                    THEN ''
                          WHEN v_kinds[v_depth] = 'array'     THEN v_paths[v_depth] || '[' || v_indexes[v_depth] || ']'
                          WHEN v_paths[v_depth] = ''          THEN v_key
                          ELSE v_paths[v_depth] || '.' || v_key
                      END;

            IF v_ch IN ('{', '[') THEN
                v_kinds   := v_kinds || CASE v_ch WHEN '{' THEN 'object' ELSE 'array' END;
                v_paths   := v_paths || v_path;
                v_indexes := v_indexes || 0;
                v_pos     := v_pos + 1;
                v_expect  := CASE v_ch WHEN '{' THEN 'key' ELSE 'value' END;
                CONTINUE;
            END IF;

            IF v_depth = 0 THEN
                RETURN QUERY SELECT NULL::text, left(v_rest, 20), v_pos, 'F3.body'::text, 'diagnostic'::text,
                                    NULL::text, v_pos, 'unexpected_json_text'::text;
                EXIT;
            END IF;

            IF v_ch = '"' THEN
                m := regexp_match(v_rest, c_string);
                v_is_string := true;
                v_value_pos := v_pos + 1;
                IF m IS NULL THEN
                    v_value     := substr(v_rest, 2);   -- string not closed before the end of the text
                    v_truncated := true;
                ELSE
                    v_value := m[1];
                END IF;
            ELSE
                m := regexp_match(v_rest, c_bare);
                IF m IS NULL THEN
                    RETURN QUERY SELECT NULL::text, left(v_rest, 20), v_pos, 'F3.body'::text, 'diagnostic'::text,
                                        NULL::text, v_pos, 'unexpected_json_text'::text;
                    EXIT;
                END IF;
                v_is_string := false;
                v_value     := m[1];
                v_value_pos := v_pos;
            END IF;

            -- 3. Key path -> field ---------------------------------------------------------------------------
            SELECT * INTO a FROM log_regex.ref_key_alias k WHERE k.format_family = 'F3' AND k.key_name = v_path;
            IF FOUND AND a.role = 'coordinate_pair' THEN
                -- "location":"lat,lon" is latitude first (C-03); a token without a comma ("geo":null) applies to
                -- both axes.
                m := regexp_match(v_value, '^([^,]*),(.*)$');
                IF m IS NULL THEN
                    RETURN QUERY SELECT 'latitude'::text, v_value, v_value_pos, ('F3.key.' || v_path)::text,
                                        'primary'::text, v_path, v_value_pos, NULL::text;
                    RETURN QUERY SELECT 'longitude'::text, v_value, v_value_pos, ('F3.key.' || v_path)::text,
                                        'primary'::text, v_path, v_value_pos, NULL::text;
                ELSE
                    RETURN QUERY SELECT 'latitude'::text, m[1], v_value_pos, ('F3.key.' || v_path || '[1]')::text,
                                        'primary'::text, v_path, v_value_pos, NULL::text;
                    RETURN QUERY SELECT 'longitude'::text, m[2], v_value_pos + char_length(m[1]) + 1,
                                        ('F3.key.' || v_path || '[2]')::text, 'primary'::text, v_path,
                                        v_value_pos + char_length(m[1]) + 1, NULL::text;
                END IF;
            ELSIF FOUND THEN
                RETURN QUERY SELECT a.field_name, v_value, v_value_pos, ('F3.key.' || v_path)::text, a.role,
                                    coalesce(a.secondary_kind, v_path), v_value_pos, NULL::text;
            ELSIF v_depth = 1 AND v_is_string AND v_value ~ '^[^@ ]+@[^@ ]+$' THEN
                RETURN QUERY SELECT 'email_address'::text, v_value, v_value_pos, ('F3.key.' || v_path)::text,
                                    'secondary'::text, (v_path || '_email')::text, v_value_pos, NULL::text;
            END IF;

            EXIT WHEN v_truncated;
            v_pos    := v_value_pos + char_length(v_value) + CASE WHEN v_is_string THEN 1 ELSE 0 END;
            v_expect := 'next';
        END IF;
    END LOOP;

    IF v_truncated THEN
        RETURN QUERY SELECT NULL::text, NULL::text, v_len, 'F3.body'::text, 'diagnostic'::text, NULL::text, v_len,
                            'truncated'::text;
    END IF;

    RETURN QUERY SELECT NULL::text, NULL::text, coalesce(v_event_end, v_len), 'F3.body'::text, 'event_end'::text,
                        NULL::text, coalesce(v_event_end, v_len), NULL::text;
END;
$$;

COMMENT ON FUNCTION log_regex.f3_candidates(text) IS
    'F3 syslog header + regex-only JSON key scan (Step 3A 7.3, C-09): candidates with exact positions, event end '
    'and truncation diagnostic for run_parser().';

COMMIT;
