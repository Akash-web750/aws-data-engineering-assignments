-- =============================================================================
-- Step 3B-4 / 14 - F2 extraction: left-to-right sentence grammar
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/14_parser_f2.sql
--
-- Implements the F2-specific stages S3/S4 (Step 3A section 7.2):
--   f2_match_coordinates()  coordinate containers, anchored at the start of a text
--   f2_ip_candidates()      an IP-like clause token: address, and port as a secondary value
--   f2_candidates()         prefix -> template-C brackets -> actor + entity -> template-C clauses ->
--                           resource + action phrase -> trailing clauses
-- Every pattern is anchored (^) at a cursor that only moves forward. A word inside a consumed span, such as
-- the "from" in "was blocked from accessing", can therefore never start a clause, and no field is found by
-- searching the whole line for its first look-alike.
-- Reads nothing but its argument, ref_log_level, ref_entity_type and ref_sentinel_phrase.
-- Re-runnable (drop + create of these functions only).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DROP FUNCTION IF EXISTS log_regex.f2_candidates(text);
DROP FUNCTION IF EXISTS log_regex.f2_ip_candidates(text, integer, text, text, text);
DROP FUNCTION IF EXISTS log_regex.f2_match_coordinates(text);

-- Coordinate containers (Step 3A section 7.2 step 7; C-03: unlabelled pairs are latitude first) ---------
-- Offsets are 0-based and relative to p_text; no row means no container at the start of p_text.
--   paren     (lat, lon)  or  (loc: lat, lon)     bracket   [lat lon]
--   lat_lon   at lat <lat> lon <lon>              lat_only  at lat <lat>        lon_only  at lon <lon>
--   pair      at <lat> <lon>
-- Any form may be introduced by "location " (template B) or "located " (template C).
-- A coordinate token is DMS (deg sign, minute and second signs incl. primes), NaN, or a decimal with an
-- optional hemisphere prefix; validity is decided later by VAL-GEO.
CREATE FUNCTION log_regex.f2_match_coordinates(p_text text)
RETURNS TABLE (match_length integer, latitude text, latitude_offset integer,
               longitude text, longitude_offset integer, form text)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    c_where constant text := '(?:location |located )?';
    c_coord constant text := '(?:[0-9]{1,3}\u00B0 ?[0-9]{1,2}[''\u2032] ?[0-9]{1,2}(?:[.][0-9]+)?["\u2033] ?[NSEW]|NaN|[NSEW]?-?[0-9]+(?:[.][0-9]+)?)';
    c_end   constant text := '(?=[ ,;)]|$)';
    m       text[];
BEGIN
    IF p_text IS NULL THEN
        RETURN;
    END IF;

    -- Group map for the pair forms: 1 whole, 2 lead, 3 latitude, 4 separator, 5 longitude.
    m := regexp_match(p_text, '^((' || c_where || '[(](?:loc: )?)(' || c_coord || ')(, )(' || c_coord || ')[)])');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT char_length(m[1]), m[3], char_length(m[2]), m[5], char_length(m[2] || m[3] || m[4]), 'paren'::text;
        RETURN;
    END IF;

    m := regexp_match(p_text, '^((' || c_where || '\[)(' || c_coord || ')( )(' || c_coord || ')\])');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT char_length(m[1]), m[3], char_length(m[2]), m[5], char_length(m[2] || m[3] || m[4]), 'bracket'::text;
        RETURN;
    END IF;

    m := regexp_match(p_text, '^((' || c_where || 'at lat )(' || c_coord || ')( lon )(' || c_coord || ')' || c_end || ')');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT char_length(m[1]), m[3], char_length(m[2]), m[5], char_length(m[2] || m[3] || m[4]), 'lat_lon'::text;
        RETURN;
    END IF;

    -- Group map for the single-axis forms: 1 whole, 2 lead, 3 value.
    m := regexp_match(p_text, '^((' || c_where || 'at lat )(' || c_coord || ')' || c_end || ')');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT char_length(m[1]), m[3], char_length(m[2]), NULL::text, NULL::integer, 'lat_only'::text;
        RETURN;
    END IF;

    m := regexp_match(p_text, '^((' || c_where || 'at lon )(' || c_coord || ')' || c_end || ')');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT char_length(m[1]), NULL::text, NULL::integer, m[3], char_length(m[2]), 'lon_only'::text;
        RETURN;
    END IF;

    m := regexp_match(p_text, '^((' || c_where || 'at )(' || c_coord || ')( )(' || c_coord || ')' || c_end || ')');
    IF m IS NOT NULL THEN
        RETURN QUERY SELECT char_length(m[1]), m[3], char_length(m[2]), m[5], char_length(m[2] || m[3] || m[4]), 'pair'::text;
    END IF;
END;
$$;

-- IP clause token (Step 3A D-03, TK-PORT): IPv4:port is split; the port is a secondary value ----------------
CREATE FUNCTION log_regex.f2_ip_candidates(p_token text, p_token_pos integer, p_slot text, p_role text, p_kind text)
RETURNS TABLE (field_name text, value text, start_pos integer, slot_id text, role text,
               secondary_kind text, doc_order integer, diagnostic text)
LANGUAGE sql
IMMUTABLE
AS $$
    WITH t AS (SELECT regexp_match(p_token, '^([0-9]+(?:[.][0-9]+)*):([0-9]{1,5})$') AS m)
    SELECT 'ip_address'::text, coalesce(t.m[1], p_token), p_token_pos, p_slot, p_role, p_kind, p_token_pos, NULL::text
    FROM t
    UNION ALL
    SELECT 'ip_address'::text, t.m[2], p_token_pos + char_length(t.m[1]) + 1, p_slot || '.port', 'secondary'::text,
           CASE WHEN p_role = 'primary' THEN 'client_port' ELSE 'proxy_port' END,
           p_token_pos + char_length(t.m[1]) + 1, NULL::text
    FROM t
    WHERE t.m IS NOT NULL
$$;

-- S3/S4: F2 candidates ---------------------------------------------------------------------------------
-- Same output shape as f1_candidates(). Roles: primary, secondary, sentinel (a sentinel phrase in the slot,
-- turned into MISSING by run_parser) and diagnostic. start_pos is the 1-based character position inside
-- raw_log; doc_order is the position, so "first in document order" is literal.
CREATE FUNCTION log_regex.f2_candidates(p_raw text)
RETURNS TABLE (field_name text, value text, start_pos integer, slot_id text, role text,
               secondary_kind text, doc_order integer, diagnostic text)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    c_blank    constant text := ' ' || chr(160);
    -- TK-PRODUCT: name/version, name_version, or name + space + dotted version (Ansible 2.16.4).
    c_tool     constant text := '[A-Za-z][A-Za-z0-9._-]*(?:/v?[0-9][A-Za-z0-9.]*|_[0-9][A-Za-z0-9.]*| [0-9]+(?:[.][0-9]+)+)';
    -- A clause value ends at a space, comma, semicolon, closing parenthesis or the end of the event.
    c_end      constant text := '(?=[ ,;)]|$)';
    -- TK-RESOURCE start: /, \\, X:\, scheme:/ or scheme// (so typos such as http//host remain resources).
    c_resource constant text := '(?:/|\\\\|[A-Za-z]:\\|[A-Za-z][A-Za-z0-9+.-]*:/|[A-Za-z][A-Za-z0-9+.-]*//)';
    -- IP-like clause token (lenient; must also contain . or :). VAL-IP decides validity later.
    c_ip_like  constant text := '^[0-9A-Fa-f:][0-9A-Za-z.:%]*$';
    v_len            integer := log_regex.line_event_end(p_raw);
    v_event          text    := left(p_raw, v_len);
    v_end            integer;
    v_template_c     boolean;
    v_pos            integer := 1;
    v_tok            integer;
    v_rest           text;
    v_value          text;
    v_lead           integer;
    v_tail           integer;
    v_slot           text;
    v_role           text;
    v_found          boolean;
    v_entity_from    integer;
    v_entity_bracket boolean := false;
    v_status_bracket boolean := false;
    v_actor_tok      integer;
    v_phrase_from    integer;
    m                text[];
    cm               record;
BEGIN
    IF p_raw IS NULL THEN
        RETURN;
    END IF;

    -- The event ends before trailing blanks (EC-149); every position still refers to raw_log.
    v_end        := char_length(rtrim(v_event, c_blank));
    v_template_c := strpos(v_event, ' connecting from ') > 0;

    -- 1. Prefix: leading blanks, timestamp, optional " -", optional log level ------------------------------
    v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
    v_pos  := v_pos + char_length(v_rest) - char_length(ltrim(v_rest, c_blank));
    v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));

    v_lead := 1;
    m := regexp_match(v_rest, '^\[([0-9][^]]*)\]');
    IF m IS NULL THEN
        v_lead := 0;
        m := regexp_match(v_rest, '^([0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][^ ]*|[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} [AP]M|[0-9]{10}(?:[0-9]{3})?)(?= |$)');
    END IF;
    IF m IS NULL THEN
        RETURN QUERY SELECT NULL::text, NULL::text, v_pos, 'F2.prefix'::text, 'diagnostic'::text, NULL::text,
                            v_pos, 'timestamp_not_found'::text;
    ELSE
        RETURN QUERY SELECT 'event_timestamp'::text, m[1], v_pos + v_lead, 'F2.prefix.timestamp'::text,
                            'primary'::text, NULL::text, v_pos + v_lead, NULL::text;
        v_pos  := v_pos + char_length(m[1]) + 2 * v_lead;
        v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
        m := regexp_match(v_rest, '^ +-(?= )');
        IF m IS NOT NULL THEN
            v_pos  := v_pos + char_length(m[1]);
            v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
        END IF;
    END IF;

    v_pos  := v_pos + char_length(v_rest) - char_length(ltrim(v_rest, c_blank));
    v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
    m := regexp_match(v_rest, '^([A-Z]+)(?= )');
    IF m IS NOT NULL AND EXISTS (SELECT 1 FROM log_regex.ref_log_level l WHERE l.level_name = m[1]) THEN
        v_pos  := v_pos + char_length(m[1]);
        v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
    END IF;

    -- 2. Brackets directly after the prefix, classified by content and position (Step 3A 7.2) ---------------
    -- Template A/B: [ENTITY]. Template C: a known entity type is the entity, otherwise the first one is the
    -- template-C status ([OK] [USER] email connecting from ...).
    FOR i IN 1..2 LOOP
        v_pos  := v_pos + char_length(v_rest) - char_length(ltrim(v_rest, c_blank));
        v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
        m := regexp_match(v_rest, '^\[([^] ]+)\](?= |$)');
        EXIT WHEN m IS NULL;
        IF NOT v_entity_bracket
           AND (NOT v_template_c OR EXISTS (SELECT 1 FROM log_regex.ref_entity_type t WHERE t.entity_type = m[1])) THEN
            RETURN QUERY SELECT 'entity_type'::text, m[1], v_pos + 1, 'F2.prefix.bracket'::text, 'primary'::text,
                                NULL::text, v_pos + 1, NULL::text;
            v_entity_bracket := true;
        ELSIF v_template_c AND NOT v_status_bracket AND NOT v_entity_bracket THEN
            RETURN QUERY SELECT 'status'::text, m[1], v_pos + 1, 'F2.prefix.bracket'::text, 'primary'::text,
                                NULL::text, v_pos + 1, NULL::text;
            v_status_bracket := true;
        ELSE
            EXIT;
        END IF;
        v_pos  := v_pos + char_length(m[1]) + 2;
        v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
    END LOOP;

    -- 3. Actor = first actor token within the next 3 tokens; entity = the words before it ---------------------
    v_pos  := v_pos + char_length(v_rest) - char_length(ltrim(v_rest, c_blank));
    v_entity_from := v_pos;
    v_tok := v_pos;
    FOR i IN 1..3 LOOP
        v_rest := substr(v_event, v_tok, greatest(v_end - v_tok + 1, 0));
        EXIT WHEN v_rest = '';
        v_value := NULL;
        v_lead  := 0;
        v_tail  := 0;
        v_slot  := 'F2.actor';
        v_role  := 'primary';

        m := regexp_match(v_rest, '^("[^"]*" <)([^> ]*)>(?= |$)');
        IF m IS NOT NULL THEN
            v_value := m[2]; v_lead := char_length(m[1]); v_tail := 1; v_slot := 'F2.actor.display_name';
        ELSE
            m := regexp_match(v_rest, '^<([^> ]*)>(?= |$)');
            IF m IS NOT NULL THEN
                v_value := m[1]; v_lead := 1; v_tail := 1; v_slot := 'F2.actor.angle';
            ELSE
                m := regexp_match(v_rest, '^([^ ]+ \[at\] [^ ]+ \[dot\] [^ ]+)(?= |$)');
                IF m IS NULL THEN
                    m := regexp_match(v_rest, '^([^ ]*@[^ ]*)');
                END IF;
                IF m IS NOT NULL THEN
                    v_value := m[1];
                ELSE
                    SELECT s.phrase INTO v_value
                    FROM log_regex.ref_sentinel_phrase s
                    WHERE s.format_family = 'F2'
                      AND s.field_name = 'email_address'
                      AND (v_rest = s.phrase OR left(v_rest, char_length(s.phrase) + 1) = s.phrase || ' ')
                    ORDER BY char_length(s.phrase) DESC
                    LIMIT 1;
                    v_role := 'sentinel';
                END IF;
            END IF;
        END IF;

        IF v_value IS NOT NULL THEN
            v_actor_tok := v_tok;
            RETURN QUERY SELECT 'email_address'::text, v_value, v_tok + v_lead, v_slot, v_role, NULL::text,
                                v_tok + v_lead, NULL::text;
            v_pos := v_tok + v_lead + char_length(v_value) + v_tail;
            EXIT;
        END IF;

        EXIT WHEN strpos(v_rest, ' ') = 0;
        v_tok  := v_tok + strpos(v_rest, ' ');
        v_rest := substr(v_event, v_tok, greatest(v_end - v_tok + 1, 0));
        v_tok  := v_tok + char_length(v_rest) - char_length(ltrim(v_rest, c_blank));
    END LOOP;

    IF v_actor_tok IS NULL THEN
        RETURN QUERY SELECT NULL::text, NULL::text, v_entity_from, 'F2.actor'::text, 'diagnostic'::text, NULL::text,
                            v_entity_from, 'actor_not_found'::text;
        v_pos := v_entity_from;
    ELSE
        v_value := rtrim(substr(v_event, v_entity_from, v_actor_tok - v_entity_from), c_blank);
        IF v_value <> '' AND v_entity_bracket THEN
            RETURN QUERY SELECT NULL::text, v_value, v_entity_from, 'F2.entity'::text, 'diagnostic'::text, NULL::text,
                                v_entity_from, 'extra_entity_text'::text;
        ELSIF v_value <> '' THEN
            RETURN QUERY SELECT 'entity_type'::text, v_value, v_entity_from, 'F2.entity'::text, 'primary'::text,
                                NULL::text, v_entity_from, NULL::text;
        END IF;

        -- "(on behalf of <email>)" directly after the actor: secondary (Step 3A D-01, EC-021).
        v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
        m := regexp_match(v_rest, '^( [(]on behalf of )([^) ]+)[)]');
        IF m IS NOT NULL THEN
            RETURN QUERY SELECT 'email_address'::text, m[2], v_pos + char_length(m[1]), 'F2.actor.on_behalf_of'::text,
                                'secondary'::text, 'delegated_email'::text, v_pos + char_length(m[1]), NULL::text;
            v_pos := v_pos + char_length(m[1]) + char_length(m[2]) + 1;
        END IF;
    END IF;

    -- 4. Template-C clauses between the actor and the action phrase ------------------------------------------
    IF v_template_c THEN
        LOOP
            v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
            v_pos  := v_pos + char_length(v_rest) - char_length(ltrim(v_rest, c_blank));
            v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));

            m := regexp_match(v_rest, '^(connecting from )([^ ,;)]+)');
            IF m IS NOT NULL AND m[2] ~ c_ip_like AND m[2] ~ '[.:]' THEN
                RETURN QUERY SELECT * FROM log_regex.f2_ip_candidates(m[2], v_pos + char_length(m[1]),
                                                                      'F2.clause.connecting_from', 'primary', NULL::text);
                v_pos := v_pos + char_length(m[1]) + char_length(m[2]);
                CONTINUE;
            END IF;

            m := regexp_match(v_rest, '^(with )(' || c_tool || ')' || c_end);
            IF m IS NOT NULL THEN
                RETURN QUERY SELECT 'tool'::text, m[2], v_pos + char_length(m[1]), 'F2.clause.with'::text,
                                    'primary'::text, NULL::text, v_pos + char_length(m[1]), NULL::text;
                v_pos := v_pos + char_length(m[1]) + char_length(m[2]);
                CONTINUE;
            END IF;

            SELECT * INTO cm FROM log_regex.f2_match_coordinates(v_rest);
            IF FOUND THEN
                IF cm.latitude IS NOT NULL THEN
                    RETURN QUERY SELECT 'latitude'::text, cm.latitude, v_pos + cm.latitude_offset,
                                        ('F2.clause.' || cm.form)::text, 'primary'::text, NULL::text,
                                        v_pos + cm.latitude_offset, NULL::text;
                END IF;
                IF cm.longitude IS NOT NULL THEN
                    RETURN QUERY SELECT 'longitude'::text, cm.longitude, v_pos + cm.longitude_offset,
                                        ('F2.clause.' || cm.form)::text, 'primary'::text, NULL::text,
                                        v_pos + cm.longitude_offset, NULL::text;
                END IF;
                v_pos := v_pos + cm.match_length;
                CONTINUE;
            END IF;

            EXIT;
        END LOOP;
    END IF;

    -- 5/6. Resource (first TK-RESOURCE token or sentinel within 12 tokens) and the action phrase before it ----
    v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
    v_pos  := v_pos + char_length(v_rest) - char_length(ltrim(v_rest, c_blank));
    v_phrase_from := v_pos;
    v_tok   := v_pos;
    v_found := false;
    FOR i IN 1..12 LOOP
        v_rest := substr(v_event, v_tok, greatest(v_end - v_tok + 1, 0));
        EXIT WHEN v_rest = '';
        v_lead := 0;
        v_tail := 0;
        v_slot := 'F2.resource';
        v_role := 'primary';

        SELECT s.phrase INTO v_value
        FROM log_regex.ref_sentinel_phrase s
        WHERE s.format_family = 'F2'
          AND s.field_name = 'resource_url'
          AND (v_rest = s.phrase
               OR left(v_rest, char_length(s.phrase) + 1) IN (s.phrase || ' ', s.phrase || '.', s.phrase || ','))
        ORDER BY char_length(s.phrase) DESC
        LIMIT 1;

        IF v_value IS NOT NULL THEN
            v_role := 'sentinel';
        ELSE
            -- "(resource)," : the parentheses are not part of the value (EC-028).
            m := regexp_match(v_rest, '^[(](' || c_resource || '[^ )]*)[)]');
            IF m IS NOT NULL THEN
                v_value := m[1]; v_lead := 1; v_tail := 1; v_slot := 'F2.resource.parenthesised';
            ELSE
                v_value := (regexp_match(v_rest, '^(' || c_resource || '[^ ]*)'))[1];
                -- Template C ends with a full stop that is not part of the resource (EC-027).
                IF v_template_c AND v_value IS NOT NULL AND char_length(v_value) > 1 AND right(v_value, 1) = '.'
                   AND v_tok + char_length(v_value) - 1 = v_end THEN
                    v_value := left(v_value, -1);
                END IF;
            END IF;
        END IF;

        IF v_value IS NOT NULL THEN
            v_found := true;
            RETURN QUERY SELECT 'resource_url'::text, v_value, v_tok + v_lead, v_slot, v_role, NULL::text,
                                v_tok + v_lead, NULL::text;
            v_pos   := v_tok + v_lead + char_length(v_value) + v_tail;
            v_value := rtrim(substr(v_event, v_phrase_from, v_tok - v_phrase_from), c_blank);
            IF v_value <> '' THEN
                RETURN QUERY SELECT 'action_phrase'::text, v_value, v_phrase_from, 'F2.phrase'::text, 'primary'::text,
                                    NULL::text, v_phrase_from, NULL::text;
            ELSE
                RETURN QUERY SELECT NULL::text, NULL::text, v_phrase_from, 'F2.phrase'::text, 'diagnostic'::text,
                                    NULL::text, v_phrase_from, 'action_phrase_not_found'::text;
            END IF;
            EXIT;
        END IF;

        EXIT WHEN strpos(v_rest, ' ') = 0;
        v_tok  := v_tok + strpos(v_rest, ' ');
        v_rest := substr(v_event, v_tok, greatest(v_end - v_tok + 1, 0));
        v_tok  := v_tok + char_length(v_rest) - char_length(ltrim(v_rest, c_blank));
    END LOOP;

    IF NOT v_found THEN
        RETURN QUERY SELECT NULL::text, NULL::text, v_phrase_from, 'F2.resource'::text, 'diagnostic'::text, NULL::text,
                            v_phrase_from, 'resource_not_found'::text;
    END IF;

    -- 7. Trailing clauses in any order; 8. template-C sentence end --------------------------------------------
    FOR i IN 1..50 LOOP
        v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
        v_pos  := v_pos + char_length(v_rest) - char_length(ltrim(v_rest, ' ,;' || chr(160)));
        v_rest := substr(v_event, v_pos, greatest(v_end - v_pos + 1, 0));
        EXIT WHEN v_rest = '';
        EXIT WHEN v_template_c AND v_rest = '.';

        -- Coordinates: (lat, lon), (loc: ...), [lat lon], at lat .. lon .., at <lat> <lon>, location ...
        SELECT * INTO cm FROM log_regex.f2_match_coordinates(v_rest);
        IF FOUND THEN
            IF cm.latitude IS NOT NULL THEN
                RETURN QUERY SELECT 'latitude'::text, cm.latitude, v_pos + cm.latitude_offset,
                                    ('F2.trailing.' || cm.form)::text, 'primary'::text, NULL::text,
                                    v_pos + cm.latitude_offset, NULL::text;
            END IF;
            IF cm.longitude IS NOT NULL THEN
                RETURN QUERY SELECT 'longitude'::text, cm.longitude, v_pos + cm.longitude_offset,
                                    ('F2.trailing.' || cm.form)::text, 'primary'::text, NULL::text,
                                    v_pos + cm.longitude_offset, NULL::text;
            END IF;
            v_pos := v_pos + cm.match_length;
            CONTINUE;
        END IF;

        -- [WORD] status
        m := regexp_match(v_rest, '^\[([^]]*)\]');
        IF m IS NOT NULL THEN
            RETURN QUERY SELECT 'status'::text, m[1], v_pos + 1, 'F2.trailing.bracket'::text, 'primary'::text,
                                NULL::text, v_pos + 1, NULL::text;
            v_pos := v_pos + char_length(m[1]) + 2;
            CONTINUE;
        END IF;

        -- from / client <ip> = client address; via <ip> = proxy (secondary). Only when the token is IP-like.
        m := regexp_match(v_rest, '^((via|from|client) )([^ ,;)]+)');
        IF m IS NOT NULL AND m[3] ~ c_ip_like AND m[3] ~ '[.:]' THEN
            IF m[2] = 'via' THEN
                RETURN QUERY SELECT * FROM log_regex.f2_ip_candidates(m[3], v_pos + char_length(m[1]),
                                                                      'F2.trailing.via', 'secondary', 'proxy_ip');
            ELSE
                RETURN QUERY SELECT * FROM log_regex.f2_ip_candidates(m[3], v_pos + char_length(m[1]),
                                                                      'F2.trailing.' || m[2], 'primary', NULL::text);
            END IF;
            v_pos := v_pos + char_length(m[1]) + char_length(m[3]);
            CONTINUE;
        END IF;

        -- via / using / with / tool: <product>
        m := regexp_match(v_rest, '^((via|using|with|tool:) )(' || c_tool || ')' || c_end);
        IF m IS NULL THEN
            m := regexp_match(v_rest, '^((via|using|with|tool:) )([^ ,;)]+)');
        END IF;
        IF m IS NOT NULL THEN
            RETURN QUERY SELECT 'tool'::text, m[3], v_pos + char_length(m[1]), ('F2.trailing.' || rtrim(m[2], ':'))::text,
                                'primary'::text, NULL::text, v_pos + char_length(m[1]), NULL::text;
            v_pos := v_pos + char_length(m[1]) + char_length(m[3]);
            CONTINUE;
        END IF;

        -- - status: WORD | status=X | - CODE Reason (sentence end) | result X (sentence end)
        m := regexp_match(v_rest, '^(- status: |status=)([^ ,;)]+)');
        IF m IS NULL THEN
            m := regexp_match(v_rest, '^(- |result )([0-9A-Za-z]{3}(?: [A-Za-z]+)*)$');
        END IF;
        IF m IS NULL THEN
            m := regexp_match(v_rest, '^(result )([^ ]+)$');
        END IF;
        IF m IS NOT NULL THEN
            RETURN QUERY SELECT 'status'::text, m[2], v_pos + char_length(m[1]),
                                ('F2.trailing.' || CASE m[1] WHEN '- status: ' THEN 'status_label'
                                                            WHEN 'status='    THEN 'status_key'
                                                            WHEN '- '         THEN 'dash'
                                                            ELSE 'result' END)::text,
                                'primary'::text, NULL::text, v_pos + char_length(m[1]), NULL::text;
            v_pos := v_pos + char_length(m[1]) + char_length(m[2]);
            CONTINUE;
        END IF;

        IF left(v_rest, 1) IN ('(', ')') THEN
            v_pos := v_pos + 1;
            CONTINUE;
        END IF;

        RETURN QUERY SELECT NULL::text, split_part(v_rest, ' ', 1), v_pos, 'F2.trailing'::text, 'diagnostic'::text,
                            NULL::text, v_pos, 'unrecognised_text'::text;
        EXIT WHEN strpos(v_rest, ' ') = 0;
        v_pos := v_pos + strpos(v_rest, ' ');
    END LOOP;
END;
$$;

COMMENT ON FUNCTION log_regex.f2_candidates(text) IS
    'F2 sentence grammar (Step 3A 7.2): anchored, forward-only clause matching; returns candidates with exact '
    'positions for run_parser().';

COMMIT;
