-- =============================================================================
-- Step 3B-3 / 10 - F1 extraction: f1_candidates() (pipe / TAB key=value logs)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/10_parser_f1.sql
--
-- Implements the F1-specific stages S3/S4 (Step 3A section 7.1):
--   f1_candidates()   quote-aware segmentation, key -> field by ref_key_alias, clean-up, positions
-- The shared stages (line_event_end, detect_format, run_parser) are in sql/15_parser_core.sql
-- since Step 3B-4. The body of f1_candidates() is unchanged from Step 3B-3.
-- Reads nothing but its argument and ref_key_alias.
-- Re-runnable (drop + create of these functions only).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DROP FUNCTION IF EXISTS log_regex.f1_candidates(text);

-- S3/S4: F1 candidates --------------------------------------------------------------------------------
-- One row per candidate value (role primary / secondary) or diagnostic (role diagnostic).
-- start_pos is the 1-based character position of value inside raw_log. value may be '' (key with an
-- empty value); run_parser() turns that into MISSING (empty).
CREATE FUNCTION log_regex.f1_candidates(p_raw text)
RETURNS TABLE (field_name text, value text, start_pos integer, slot_id text, role text,
               secondary_kind text, doc_order integer, diagnostic text)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_len      integer := log_regex.line_event_end(p_raw);
    v_event    text    := left(p_raw, v_len);
    v_pos      integer := 1;
    v_seg_no   integer := 0;
    v_seg      text;
    v_lead     integer;
    v_trail    integer;
    v_core     text;
    v_core_pos integer;
    v_key      text;
    v_val      text;
    v_val_pos  integer;
    v_slot     text;
    a          log_regex.ref_key_alias%ROWTYPE;
    m          text[];
BEGIN
    IF p_raw IS NULL THEN
        RETURN;
    END IF;

    LOOP
        v_seg_no := v_seg_no + 1;
        -- A segment runs to the next | or TAB that is not inside a quoted value. Quoting applies only to a
        -- whole value directly after key= (optional spaces): key="..." (closed, any tail up to the next
        -- delimiter) or key="... (unclosed, runs to the end of the event). Anywhere else a double quote is an
        -- ordinary character, e.g. the arc-seconds sign in 51 deg 33'01.8"N.
        -- PostgreSQL ARE returns the longest overall match among the alternatives, which is what lets a
        -- closed quoted value containing | win over the plain run.
        v_seg := (regexp_match(substr(v_event, v_pos),
                    '^((?:[ \u00A0]*[A-Za-z_][A-Za-z0-9_]*=[ \u00A0]*"[^"]*"[^|\t]*)|(?:[ \u00A0]*[A-Za-z_][A-Za-z0-9_]*=[ \u00A0]*"[^"]*$)|[^|\t]*)'))[1];

        -- Trim spaces and NBSP around the segment (positions adjusted, text not changed).
        v_lead  := char_length((regexp_match(v_seg, '^[ \u00A0]*'))[1]);
        v_core  := substr(v_seg, v_lead + 1);
        v_trail := char_length((regexp_match(v_core, '[ \u00A0]*$'))[1]);
        v_core  := left(v_core, char_length(v_core) - v_trail);
        v_core_pos := v_pos + v_lead;

        IF v_core <> '' THEN
            m := regexp_match(v_core, '^([A-Za-z_][A-Za-z0-9_]*)=');
            IF m IS NULL THEN
                IF v_seg_no = 1 THEN
                    -- First segment without key= is the timestamp slot.
                    RETURN QUERY SELECT 'event_timestamp'::text, v_core, v_core_pos, 'F1.segment[1]'::text,
                                        'primary'::text, NULL::text, v_seg_no * 10, NULL::text;
                ELSE
                    RETURN QUERY SELECT NULL::text, v_core, v_core_pos, ('F1.segment[' || v_seg_no || ']')::text,
                                        'diagnostic'::text, NULL::text, v_seg_no * 10, 'unrecognised_segment'::text;
                END IF;
            ELSE
                v_key     := m[1];
                v_slot    := 'F1.key.' || v_key;
                v_val     := substr(v_core, char_length(v_key) + 2);
                v_val_pos := v_core_pos + char_length(v_key) + 1;
                v_lead    := char_length((regexp_match(v_val, '^[ \u00A0]*'))[1]);
                v_val     := substr(v_val, v_lead + 1);
                v_val_pos := v_val_pos + v_lead;

                -- Enclosing double quotes are delimiters, not part of the value.
                IF char_length(v_val) >= 2 AND v_val ~ '^".*"$' THEN
                    v_val     := substr(v_val, 2, char_length(v_val) - 2);
                    v_val_pos := v_val_pos + 1;
                ELSIF v_val ~ '^"' THEN
                    RETURN QUERY SELECT NULL::text, v_val, v_val_pos, v_slot, 'diagnostic'::text, NULL::text,
                                        v_seg_no * 10, 'unclosed_quote'::text;
                END IF;

                SELECT * INTO a FROM log_regex.ref_key_alias k WHERE k.format_family = 'F1' AND k.key_name = v_key;

                IF NOT FOUND THEN
                    RETURN QUERY SELECT NULL::text, v_val, v_val_pos, v_slot, 'diagnostic'::text, NULL::text,
                                        v_seg_no * 10, ('unknown_key:' || v_key)::text;

                ELSIF a.role = 'coordinate_pair' THEN
                    -- geo=<lat>,<lon> (latitude first, Step 3A C-03); no comma: the token applies to both axes.
                    m := regexp_match(v_val, '^([^,]*),(.*)$');
                    IF m IS NULL THEN
                        RETURN QUERY SELECT 'latitude'::text, v_val, v_val_pos, v_slot, 'primary'::text, NULL::text,
                                            v_seg_no * 10, NULL::text;
                        RETURN QUERY SELECT 'longitude'::text, v_val, v_val_pos, v_slot, 'primary'::text, NULL::text,
                                            v_seg_no * 10 + 1, NULL::text;
                    ELSE
                        RETURN QUERY SELECT 'latitude'::text, m[1], v_val_pos, (v_slot || '[1]')::text,
                                            'primary'::text, NULL::text, v_seg_no * 10, NULL::text;
                        RETURN QUERY SELECT 'longitude'::text, m[2], v_val_pos + char_length(m[1]) + 1,
                                            (v_slot || '[2]')::text, 'primary'::text, NULL::text,
                                            v_seg_no * 10 + 1, NULL::text;
                    END IF;

                ELSE
                    IF a.field_name = 'email_address' THEN
                        IF v_val ~ '^<.*>$' THEN
                            v_val     := substr(v_val, 2, char_length(v_val) - 2);
                            v_val_pos := v_val_pos + 1;
                        ELSIF v_val ~ '^mailto:' THEN
                            v_val     := substr(v_val, 8);
                            v_val_pos := v_val_pos + 7;
                        END IF;
                    ELSIF a.field_name = 'status' THEN
                        -- STATUS (reason): the reason is a secondary value (EC-127).
                        m := regexp_match(v_val, '^([^ (]+) [(]([^)]*)[)]$');
                        IF m IS NOT NULL THEN
                            RETURN QUERY SELECT 'status'::text, m[2], v_val_pos + char_length(m[1]) + 2,
                                                (v_slot || '.reason')::text, 'secondary'::text,
                                                'status_reason'::text, v_seg_no * 10 + 1, NULL::text;
                            v_val := m[1];
                        END IF;
                    END IF;
                    RETURN QUERY SELECT a.field_name, v_val, v_val_pos, v_slot, a.role, a.secondary_kind,
                                        v_seg_no * 10, NULL::text;
                END IF;
            END IF;
        END IF;

        v_pos := v_pos + char_length(v_seg);
        EXIT WHEN v_pos > v_len;
        v_pos := v_pos + 1;  -- skip the | or TAB delimiter
    END LOOP;
END;
$$;

COMMIT;
