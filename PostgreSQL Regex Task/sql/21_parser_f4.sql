-- =============================================================================
-- Step 3B-6 / 21 - F4 extraction: combined access-log positions + known-key extras
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/21_parser_f4.sql
--
-- Implements the F4-specific stages S3/S4 (Step 3A section 7.4):
--   1. Fixed positions, left to right, each pattern anchored at the cursor:
--        IP field, ident, remote user, [timestamp], "METHOD target HTTP/n.n" or "-", status, bytes,
--        "referer", "user agent"
--      Quoted fields end at their closing double quote; a user agent that is never closed is truncated (EC-136).
--   2. Extras after the user agent: a value starts after " key=" and ends where the next known key starts
--      (" type=", " user=", ... from ref_key_alias F4) or at the end of the event, so entity values keep their
--      spaces (Service Account). A value that starts with a double quote ends at its closing quote (msg, xff).
--   3. Precedence (Step 3A 7.4, 8.2): email from user=<...> when present, else the remote-user slot; IP from
--      the first xff entry when present (the connection address becomes secondary proxy_ip), else the IP field.
--      IP field forms: IPv4, IPv4:port, bare IPv6 (no port parsing), [IPv6]:port; the port is secondary.
--      Coordinates: loc=POINT(lon lat) longitude first, geo=lat,lon latitude first, lat= / lon= labelled (C-03).
--   Secondary values: referer_url, url_in_tool (a URL inside the user agent), client_port / proxy_port, proxy_ip.
-- Event scope: first line (line_event_end). Reads nothing but its argument and ref_key_alias.
-- Uses log_regex.f2_ip_candidates() from sql/14 for the IPv4:port split.
-- Re-runnable (drop + create of this function only).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DROP FUNCTION IF EXISTS log_regex.f4_candidates(text);

-- S3/S4: F4 candidates ---------------------------------------------------------------------------------
-- Same output shape as the other extractors; doc_order is the position.
CREATE FUNCTION log_regex.f4_candidates(p_raw text)
RETURNS TABLE (field_name text, value text, start_pos integer, slot_id text, role text,
               secondary_kind text, doc_order integer, diagnostic text)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_len        integer := log_regex.line_event_end(p_raw);
    v_event      text    := left(p_raw, v_len);
    v_keys       text;
    v_pos        integer := 1;
    v_rest       text;
    v_ip_token   text;
    v_ip_pos     integer;
    v_user_token text;
    v_user_pos   integer;
    v_key        text;
    v_start      integer;
    v_after      text;
    v_value      text;
    v_value_pos  integer;
    v_used       integer;
    v_next       integer;
    v_lead       integer;
    v_slot       text;
    v_has_user   boolean := false;
    v_has_xff    boolean := false;
    v_truncated  boolean := false;
    a            log_regex.ref_key_alias%ROWTYPE;
    m            text[];
BEGIN
    IF p_raw IS NULL THEN
        RETURN;
    END IF;

    -- Boundary keys, longest first.
    SELECT string_agg(k.key_name, '|' ORDER BY char_length(k.key_name) DESC, k.key_name)
    INTO v_keys
    FROM log_regex.ref_key_alias k
    WHERE k.format_family = 'F4';

    v_pos  := 1 + char_length(v_event) - char_length(ltrim(v_event, ' '));
    v_rest := substr(v_event, v_pos);

    -- 1-3. IP field, ident, remote user --------------------------------------------------------------------
    m := regexp_match(v_rest, '^(([^ ]+) ([^ ]+) ([^ ]+) )');
    IF m IS NULL THEN
        RETURN QUERY SELECT NULL::text, NULL::text, v_pos, 'F4'::text, 'diagnostic'::text, NULL::text, v_pos,
                            'positional_fields_not_found'::text;
        RETURN;
    END IF;
    v_ip_token   := m[2];
    v_ip_pos     := v_pos;
    v_user_token := m[4];
    v_user_pos   := v_pos + char_length(m[2]) + char_length(m[3]) + 2;
    v_pos        := v_pos + char_length(m[1]);

    -- 4. [timestamp] --------------------------------------------------------------------------------------
    m := regexp_match(substr(v_event, v_pos), '^\[([^]]*)\]');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT 'event_timestamp'::text, m[1], v_pos + 1, 'F4.timestamp'::text, 'primary'::text,
                            NULL::text, v_pos + 1, NULL::text;
        v_pos := v_pos + char_length(m[1]) + 2;
    ELSE
        RETURN QUERY SELECT NULL::text, NULL::text, v_pos, 'F4.timestamp'::text, 'diagnostic'::text, NULL::text,
                            v_pos, 'timestamp_not_found'::text;
    END IF;

    -- 5. "METHOD target HTTP/n.n" or "-" -----------------------------------------------------------------
    -- Group map: 1 whole (with the leading space), 2 method, 3 target. The target ends before the last
    -- " HTTP/n.n" in front of the closing quote.
    m := regexp_match(substr(v_event, v_pos), '^( "([A-Z]+) ([^"]*) HTTP/[0-9]+[.][0-9]+")');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT 'resource_url'::text, m[3], v_pos + 3 + char_length(m[2]), 'F4.request.target'::text,
                            'primary'::text, NULL::text, v_pos + 3 + char_length(m[2]), NULL::text;
        v_pos := v_pos + char_length(m[1]);
    ELSE
        m := regexp_match(substr(v_event, v_pos), '^( "(-)")');
        IF m IS NOT NULL THEN
            RETURN QUERY SELECT 'resource_url'::text, m[2], v_pos + 2, 'F4.request'::text, 'primary'::text,
                                NULL::text, v_pos + 2, NULL::text;
            v_pos := v_pos + char_length(m[1]);
        ELSE
            RETURN QUERY SELECT NULL::text, NULL::text, v_pos, 'F4.request'::text, 'diagnostic'::text, NULL::text,
                                v_pos, 'request_not_found'::text;
        END IF;
    END IF;

    -- 6. status (lenient token: 20O, 4O3, -) and bytes ------------------------------------------------------
    m := regexp_match(substr(v_event, v_pos), '^( ([^ "]+))');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT 'status'::text, m[2], v_pos + 1, 'F4.status'::text, 'primary'::text, NULL::text,
                            v_pos + 1, NULL::text;
        v_pos := v_pos + char_length(m[1]);
        m := regexp_match(substr(v_event, v_pos), '^( [^ "]+)');
        IF m IS NOT NULL THEN
            v_pos := v_pos + char_length(m[1]);
        END IF;
    ELSE
        RETURN QUERY SELECT NULL::text, NULL::text, v_pos, 'F4.status'::text, 'diagnostic'::text, NULL::text,
                            v_pos, 'status_not_found'::text;
    END IF;

    -- 7. "referer": never the resource; secondary referer_url unless "-" -----------------------------------
    m := regexp_match(substr(v_event, v_pos), '^( "([^"]*)")');
    IF m IS NOT NULL THEN
        IF m[2] NOT IN ('-', '') THEN
            RETURN QUERY SELECT 'resource_url'::text, m[2], v_pos + 2, 'F4.referer'::text, 'secondary'::text,
                                'referer_url'::text, v_pos + 2, NULL::text;
        END IF;
        v_pos := v_pos + char_length(m[1]);
    END IF;

    -- 8. "user agent" = tool; not closed before the end of the event = truncated (EC-136) ------------------
    m := regexp_match(substr(v_event, v_pos), '^( "([^"]*)")');
    IF m IS NULL THEN
        m := regexp_match(substr(v_event, v_pos), '^( "(.*))$');
        v_truncated := m IS NOT NULL;
    END IF;
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT 'tool'::text, m[2], v_pos + 2, 'F4.user_agent'::text, 'primary'::text, NULL::text,
                            v_pos + 2, NULL::text;
        IF m[2] ~ 'https?://[^ )"]+' THEN
            RETURN QUERY SELECT 'resource_url'::text, regexp_substr(m[2], 'https?://[^ )"]+'),
                                v_pos + 1 + regexp_instr(m[2], 'https?://[^ )"]+'), 'F4.user_agent.url'::text,
                                'secondary'::text, 'url_in_tool'::text,
                                v_pos + 1 + regexp_instr(m[2], 'https?://[^ )"]+'), NULL::text;
        END IF;
        v_pos := v_pos + char_length(m[1]);
    ELSE
        RETURN QUERY SELECT NULL::text, NULL::text, v_pos, 'F4.user_agent'::text, 'diagnostic'::text, NULL::text,
                            v_pos, 'user_agent_not_found'::text;
    END IF;

    -- 9. Extras: " key=value" pairs cut at the next known key -------------------------------------------------
    IF NOT v_truncated THEN
        FOR i IN 1..50 LOOP
            v_rest := substr(v_event, v_pos);
            EXIT WHEN v_rest = '';

            m := regexp_match(v_rest, '^ (' || v_keys || ')=');
            IF m IS NULL THEN
                v_next := regexp_instr(substr(v_rest, 2), ' (' || v_keys || ')=');
                RETURN QUERY SELECT NULL::text, CASE WHEN v_next = 0 THEN v_rest ELSE left(v_rest, v_next) END,
                                    v_pos, 'F4.extras'::text, 'diagnostic'::text, NULL::text, v_pos,
                                    'unrecognised_text'::text;
                EXIT WHEN v_next = 0;
                v_pos := v_pos + v_next;
                CONTINUE;
            END IF;

            v_key   := m[1];
            v_start := v_pos + char_length(v_key) + 2;
            v_after := substr(v_event, v_start);
            v_slot  := 'F4.extras.' || v_key;

            IF left(v_after, 1) = '"' THEN
                m := regexp_match(v_after, '^"([^"]*)"');
                v_value_pos := v_start + 1;
                IF m IS NULL THEN
                    v_value     := substr(v_after, 2);   -- quote not closed before the end of the event
                    v_used      := char_length(v_after);
                    v_truncated := true;
                ELSE
                    v_value := m[1];
                    v_used  := char_length(m[1]) + 2;
                END IF;
            ELSE
                v_next      := regexp_instr(v_after, ' (' || v_keys || ')=');
                v_value     := CASE WHEN v_next = 0 THEN v_after ELSE left(v_after, v_next - 1) END;
                v_value_pos := v_start;
                v_used      := char_length(v_value);
            END IF;

            SELECT * INTO a FROM log_regex.ref_key_alias k WHERE k.format_family = 'F4' AND k.key_name = v_key;

            IF a.role = 'coordinate_pair' THEN
                m := regexp_match(v_value, '^POINT\(([^ ()]*) ([^ ()]*)\)$');
                IF m IS NOT NULL THEN
                    -- WKT POINT(longitude latitude): longitude first (C-03).
                    RETURN QUERY SELECT 'longitude'::text, m[1], v_value_pos + 6, (v_slot || '[1]')::text,
                                        'primary'::text, NULL::text, v_value_pos + 6, NULL::text;
                    RETURN QUERY SELECT 'latitude'::text, m[2], v_value_pos + 7 + char_length(m[1]),
                                        (v_slot || '[2]')::text, 'primary'::text, NULL::text,
                                        v_value_pos + 7 + char_length(m[1]), NULL::text;
                ELSE
                    -- lat,lon: latitude first (C-03); without a comma the token applies to both axes.
                    m := regexp_match(v_value, '^([^,]*),(.*)$');
                    IF m IS NULL THEN
                        RETURN QUERY SELECT 'latitude'::text, v_value, v_value_pos, v_slot, 'primary'::text,
                                            NULL::text, v_value_pos, NULL::text;
                        RETURN QUERY SELECT 'longitude'::text, v_value, v_value_pos, v_slot, 'primary'::text,
                                            NULL::text, v_value_pos, NULL::text;
                    ELSE
                        RETURN QUERY SELECT 'latitude'::text, m[1], v_value_pos, (v_slot || '[1]')::text,
                                            'primary'::text, NULL::text, v_value_pos, NULL::text;
                        RETURN QUERY SELECT 'longitude'::text, m[2], v_value_pos + char_length(m[1]) + 1,
                                            (v_slot || '[2]')::text, 'primary'::text, NULL::text,
                                            v_value_pos + char_length(m[1]) + 1, NULL::text;
                    END IF;
                END IF;

            ELSIF a.field_name = 'email_address' THEN
                v_has_user := true;
                IF v_value ~ '^<.*>$' THEN
                    RETURN QUERY SELECT 'email_address'::text, substr(v_value, 2, char_length(v_value) - 2),
                                        v_value_pos + 1, v_slot, 'primary'::text, NULL::text, v_value_pos + 1,
                                        NULL::text;
                ELSE
                    RETURN QUERY SELECT 'email_address'::text, v_value, v_value_pos, v_slot, 'primary'::text,
                                        NULL::text, v_value_pos, NULL::text;
                END IF;

            ELSIF a.field_name = 'ip_address' THEN
                -- xff="client, proxy, ...": the first entry is the original client (D-03).
                v_has_xff := true;
                v_lead := char_length(v_value) - char_length(ltrim(v_value, ' '));
                RETURN QUERY SELECT 'ip_address'::text, (regexp_match(substr(v_value, v_lead + 1), '^([^, ]*)'))[1],
                                    v_value_pos + v_lead, (v_slot || '[1]')::text, 'primary'::text, NULL::text,
                                    v_value_pos + v_lead, NULL::text;

            ELSE
                RETURN QUERY SELECT a.field_name, v_value, v_value_pos, v_slot, 'primary'::text, NULL::text,
                                    v_value_pos, NULL::text;
            END IF;

            v_pos := v_start + v_used;
            EXIT WHEN v_truncated;
        END LOOP;
    END IF;

    -- IP field (slot 1): the client address unless xff named the original client ------------------------------
    m := regexp_match(v_ip_token, '^\[([^]]*)\](?::([0-9]{1,5}))?$');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT 'ip_address'::text, m[1], v_ip_pos + 1, 'F4.ip_field'::text,
                            CASE WHEN v_has_xff THEN 'secondary' ELSE 'primary' END,
                            CASE WHEN v_has_xff THEN 'proxy_ip' END, v_ip_pos + 1, NULL::text;
        IF m[2] IS NOT NULL THEN
            RETURN QUERY SELECT 'ip_address'::text, m[2], v_ip_pos + char_length(m[1]) + 3, 'F4.ip_field.port'::text,
                                'secondary'::text, CASE WHEN v_has_xff THEN 'proxy_port' ELSE 'client_port' END,
                                v_ip_pos + char_length(m[1]) + 3, NULL::text;
        END IF;
    ELSE
        RETURN QUERY SELECT * FROM log_regex.f2_ip_candidates(v_ip_token, v_ip_pos, 'F4.ip_field',
                                                              CASE WHEN v_has_xff THEN 'secondary' ELSE 'primary' END,
                                                              CASE WHEN v_has_xff THEN 'proxy_ip' END);
    END IF;

    -- Remote-user slot: the email unless user=<...> is present (a "-" there is a placeholder, AMB-10) -----------
    IF NOT v_has_user THEN
        RETURN QUERY SELECT 'email_address'::text, v_user_token, v_user_pos, 'F4.remote_user'::text,
                            'primary'::text, NULL::text, v_user_pos, NULL::text;
    ELSIF v_user_token <> '-' THEN
        RETURN QUERY SELECT 'email_address'::text, v_user_token, v_user_pos, 'F4.remote_user'::text,
                            'secondary'::text, 'remote_user_email'::text, v_user_pos, NULL::text;
    END IF;

    IF v_truncated THEN
        RETURN QUERY SELECT NULL::text, NULL::text, v_len, 'F4'::text, 'diagnostic'::text, NULL::text, v_len,
                            'truncated'::text;
    END IF;
END;
$$;

COMMENT ON FUNCTION log_regex.f4_candidates(text) IS
    'F4 access log (Step 3A 7.4): fixed positions, quoted fields, known-key extras; candidates with exact positions '
    'for run_parser().';

COMMIT;
