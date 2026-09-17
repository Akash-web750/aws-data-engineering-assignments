-- =============================================================================
-- Step 3B-4 / 15 - Parser core: event scope, format detection and the parser run (F1 - F5, NONE)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/15_parser_core.sql
--
-- Shared stages (Step 3A), moved here from sql/10_parser_f1.sql in Step 3B-4 and extended for F3 (3B-5), F4 (3B-6), F5 (3B-7) and NONE (3C):
--   S2     line_event_end()     event scope of F1/F2 = first line, CR before LF excluded (unchanged)
--   S0/S1  detect_format()      DET-00, DET-F4, DET-F3, DET-F1, DET-F5, DET-F2 (fallback), DET-NONE (3C)
--   S5-S8  run_parser()         candidates from f1_candidates() .. f5_candidates(), selection,
--                                value state (VS-3 sentinel, C-06 for F1, unclosed JSON for F3, unclosed quote for F4),
--                                validation, secondary values, record validity, invariants, raw fingerprint checks
-- Earlier formats are unchanged by each step: their rows are identical to the previous run (checked by
-- sql/16 for F1, sql/19 for F1 + F2, sql/22 for F1 - F3, sql/25 for F1 - F4, sql/26_test_combined_parser.sql
-- for F1 - F5 against each format's first accepted run).
-- Reads raw_access_logs only; writes only parser_run / parsed_log / parsed_field / parsed_secondary.
-- Re-runnable (drop + create of these functions only).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DROP FUNCTION IF EXISTS log_regex.run_parser(text, integer);
DROP FUNCTION IF EXISTS log_regex.detect_format(text);
DROP FUNCTION IF EXISTS log_regex.line_event_end(text);

-- S2: length of the event on the first line (CR immediately before the first LF excluded) -----------
CREATE FUNCTION log_regex.line_event_end(p_raw text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
               WHEN p_raw IS NULL THEN NULL
               WHEN strpos(p_raw, E'\n') = 0 THEN char_length(p_raw)
               WHEN strpos(p_raw, E'\n') > 1 AND substr(p_raw, strpos(p_raw, E'\n') - 1, 1) = E'\r'
                   THEN strpos(p_raw, E'\n') - 2
               ELSE strpos(p_raw, E'\n') - 1
           END
$$;

-- S0/S1: format detection ------------------------------------------------------------------------------
-- DET-00: NULL, empty or whitespace only.
-- DET-F4: on the event line, three tokens (IP field, ident, remote user), a [...] bracket and a quoted request
--         field that is "METHOD target HTTP/n.n" or "-". Priority 1 of Step 3A 4.2.
-- DET-F3: a JSON object opening anywhere in raw_log: { followed (across optional whitespace or newlines) by ".
--         Priority 2 of Step 3A 4.2, before DET-F1.
-- DET-F1: at least two key= segments, each at the start of the event line or after | or TAB.
-- DET-F2: the fallback rule (Step 3A 4.2, order 5): evaluated only when no structural rule matched, and
--         requires at least two sentence cues on the event line:
--           (a) leading timestamp: [Apache CLF], ISO date-time, MM/DD/YYYY hh:mm:ss AM|PM, or a 10/13-digit epoch
--           (b) actor token: a token containing @, " [at] ", or the word anonymous
--           (c) IP clause: from / client followed by an IP-like token
-- format_candidates lists every structural rule that matched; more than one gives the diagnostic format_conflict.
-- DET-F5: exactly 9 semicolons on the event line and column 1 matches a ref_timestamp_shape pattern.
--         Priority 4, after DET-F1. The header row EC-138 has 9 semicolons but no timestamp, so it is not F5.
-- DET-NONE: a non-blank row that matches no rule is NONE (Step 3A 4.2, order 6): diagnostic no_format_detected,
--           all fields MISSING, record BROKEN. Every row therefore gets exactly one final classification.
CREATE FUNCTION log_regex.detect_format(p_raw text)
RETURNS TABLE (format_family text, detection_rule text, format_candidates text[])
LANGUAGE sql
STABLE
AS $$
    WITH e AS (
        SELECT p_raw IS NULL OR p_raw ~ '^[[:space:]]*$' AS is_blank,
               left(p_raw, log_regex.line_event_end(p_raw))  AS event_line
    ),
    structural AS (
        SELECT is_blank,
               event_line,
               NOT is_blank AND event_line ~ '^ *[^ ]+ [^ ]+ [^ ]+ \[[^]]*\] "([A-Z]+ [^"]* HTTP/[0-9]+[.][0-9]+|-)"' AS is_f4,
               NOT is_blank AND p_raw ~ '\{[[:space:]]*"' AS is_f3,
               NOT is_blank AND regexp_count(event_line, '(^|[|\t])[ \t\u00A0]*[A-Za-z_][A-Za-z0-9_]*=') >= 2 AS is_f1,
               NOT is_blank AND regexp_count(event_line, ';') = 9
               AND EXISTS (SELECT 1 FROM log_regex.ref_timestamp_shape s
                           WHERE split_part(event_line, ';', 1) ~ s.pattern) AS is_f5
        FROM e
    ),
    f2 AS (
        SELECT is_blank,
               is_f4,
               is_f3,
               is_f1,
               is_f5,
               NOT is_blank AND NOT is_f4 AND NOT is_f3 AND NOT is_f1 AND NOT is_f5
               AND (  (event_line ~ '^[ \u00A0]*(\[[0-9]{2}/[A-Z][a-z]{2}/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\]|[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}|[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} [AP]M|[0-9]{10}([0-9]{3})?( |$))')::integer
                    + (event_line ~ '(^| )[^ ]*@' OR event_line ~ ' \[at\] ' OR event_line ~ '(^| )anonymous( |$)')::integer
                    + (event_line ~ '(^|[ (])(from|client) [0-9A-Fa-f:][0-9A-Za-z.:%]*[.:]')::integer
                   ) >= 2 AS is_f2
        FROM structural
    )
    SELECT CASE WHEN is_blank THEN 'NONE'   WHEN is_f4 THEN 'F4'     WHEN is_f3 THEN 'F3'     WHEN is_f1 THEN 'F1'
                WHEN is_f5 THEN 'F5'        WHEN is_f2 THEN 'F2'     ELSE 'NONE' END,
           CASE WHEN is_blank THEN 'DET-00' WHEN is_f4 THEN 'DET-F4' WHEN is_f3 THEN 'DET-F3' WHEN is_f1 THEN 'DET-F1'
                WHEN is_f5 THEN 'DET-F5'    WHEN is_f2 THEN 'DET-F2' ELSE 'DET-NONE' END,
           CASE WHEN is_blank THEN ARRAY['DET-00']
                WHEN is_f4 OR is_f3 OR is_f1 OR is_f5 THEN array_remove(ARRAY[CASE WHEN is_f4 THEN 'DET-F4' END,
                                                                              CASE WHEN is_f3 THEN 'DET-F3' END,
                                                                              CASE WHEN is_f1 THEN 'DET-F1' END,
                                                                              CASE WHEN is_f5 THEN 'DET-F5' END], NULL)
                WHEN is_f2 THEN ARRAY['DET-F2']
                ELSE ARRAY['DET-NONE'] END
    FROM f2
$$;

-- S5-S8: parser run ---------------------------------------------------------------------------------
CREATE FUNCTION log_regex.run_parser(p_parser_version text, p_assumed_year integer DEFAULT 2026)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id      bigint;
    v_before      boolean;
    v_after       boolean;
    v_raw_rows    integer;
    v_bad_fields  integer;
    v_bad_second  integer;
BEGIN
    SELECT bool_and(passed) INTO v_before FROM log_regex.verify_raw_access_logs();
    IF v_before IS NOT TRUE THEN
        RAISE EXCEPTION 'raw input integrity check failed before parsing';
    END IF;
    SELECT count(*) INTO v_raw_rows FROM log_regex.raw_access_logs;

    INSERT INTO log_regex.parser_run (parser_version, reference_data_version, formats_implemented, assumed_year,
                                      raw_row_count, fingerprint_check_before, status)
    SELECT p_parser_version, v.version, ARRAY['F1', 'F2', 'F3', 'F4', 'F5', 'NONE'], p_assumed_year, v_raw_rows, v_before, 'running'
    FROM log_regex.ref_data_version v
    RETURNING run_id INTO v_run_id;

    -- S0/S1 detection for every raw row (one parsed_log row per log_id) ----------------------------
    INSERT INTO log_regex.parsed_log (run_id, log_id, format_family, detection_rule, format_candidates, sub_format,
                                      event_end_pos, is_truncated, record_validity, diagnostics)
    SELECT v_run_id,
           r.log_id,
           d.format_family,
           d.detection_rule,
           d.format_candidates,
           CASE d.format_family
               WHEN 'F1' THEN CASE WHEN strpos(e.event_line, E'\t') > 0 THEN 'tab-delimited' ELSE 'pipe-delimited' END
               WHEN 'F2' THEN CASE WHEN strpos(e.event_line, ' connecting from ') > 0 THEN 'template-C'
                                   WHEN strpos(e.event_line, ', result ') > 0 OR strpos(e.event_line, ' using ') > 0
                                       THEN 'template-B'
                                   ELSE 'template-A' END
               WHEN 'F3' THEN CASE WHEN r.raw_log ~ '^<[0-9]{1,3}>1 ' THEN 'rfc5424' ELSE 'rfc3164' END
               WHEN 'F4' THEN CASE WHEN e.event_line ~ '^ *\[[^] ]*\]:[0-9]+ ' THEN 'ipv6-bracket-port'
                                   WHEN e.event_line ~ '^ *[0-9]+([.][0-9]+)*:[0-9]{1,5} ' THEN 'ipv4-port'
                                   WHEN e.event_line ~ '^ *[^ ]*:' THEN 'ipv6'
                                   ELSE 'ipv4' END
               -- F5: the timestamp shape of column 1 (informational).
               WHEN 'F5' THEN (SELECT s.shape_name FROM log_regex.ref_timestamp_shape s
                               WHERE split_part(e.event_line, ';', 1) ~ s.pattern
                               ORDER BY s.match_order LIMIT 1)
           END,
           -- F3: set below from the scanner's event_end row.
           CASE WHEN d.format_family IN ('F1', 'F2', 'F4', 'F5') THEN log_regex.line_event_end(r.raw_log) END,
           false,
           CASE WHEN d.format_family = 'NONE' THEN 'BROKEN' END,
           CASE WHEN d.detection_rule = 'DET-NONE' THEN ARRAY['no_format_detected']
                WHEN cardinality(d.format_candidates) > 1 THEN ARRAY['format_conflict']
                ELSE ARRAY[]::text[] END
    FROM log_regex.raw_access_logs r
    CROSS JOIN LATERAL log_regex.detect_format(r.raw_log) d
    CROSS JOIN LATERAL (SELECT left(r.raw_log, log_regex.line_event_end(r.raw_log)) AS event_line) e;

    -- S3/S4 candidates ------------------------------------------------------------------------------
    DROP TABLE IF EXISTS pg_temp.parse_candidate;
    CREATE TEMP TABLE parse_candidate AS
    SELECT l.log_id, c.field_name, c.value, c.start_pos, c.slot_id, c.role, c.secondary_kind, c.doc_order, c.diagnostic
    FROM log_regex.parsed_log l
    JOIN log_regex.raw_access_logs r ON r.log_id = l.log_id
    CROSS JOIN LATERAL log_regex.f1_candidates(r.raw_log) c
    WHERE l.run_id = v_run_id
      AND l.format_family = 'F1'
    UNION ALL
    SELECT l.log_id, c.field_name, c.value, c.start_pos, c.slot_id, c.role, c.secondary_kind, c.doc_order, c.diagnostic
    FROM log_regex.parsed_log l
    JOIN log_regex.raw_access_logs r ON r.log_id = l.log_id
    CROSS JOIN LATERAL log_regex.f2_candidates(r.raw_log) c
    WHERE l.run_id = v_run_id
      AND l.format_family = 'F2'
    UNION ALL
    SELECT l.log_id, c.field_name, c.value, c.start_pos, c.slot_id, c.role, c.secondary_kind, c.doc_order, c.diagnostic
    FROM log_regex.parsed_log l
    JOIN log_regex.raw_access_logs r ON r.log_id = l.log_id
    CROSS JOIN LATERAL log_regex.f3_candidates(r.raw_log) c
    WHERE l.run_id = v_run_id
      AND l.format_family = 'F3'
    UNION ALL
    SELECT l.log_id, c.field_name, c.value, c.start_pos, c.slot_id, c.role, c.secondary_kind, c.doc_order, c.diagnostic
    FROM log_regex.parsed_log l
    JOIN log_regex.raw_access_logs r ON r.log_id = l.log_id
    CROSS JOIN LATERAL log_regex.f4_candidates(r.raw_log) c
    WHERE l.run_id = v_run_id
      AND l.format_family = 'F4'
    UNION ALL
    SELECT l.log_id, c.field_name, c.value, c.start_pos, c.slot_id, c.role, c.secondary_kind, c.doc_order, c.diagnostic
    FROM log_regex.parsed_log l
    JOIN log_regex.raw_access_logs r ON r.log_id = l.log_id
    CROSS JOIN LATERAL log_regex.f5_candidates(r.raw_log) c
    WHERE l.run_id = v_run_id
      AND l.format_family = 'F5';

    UPDATE log_regex.parsed_log l
    SET diagnostics = l.diagnostics || d.codes
    FROM (SELECT log_id, array_agg(diagnostic ORDER BY doc_order) AS codes
          FROM parse_candidate
          WHERE role = 'diagnostic'
          GROUP BY log_id) d
    WHERE l.run_id = v_run_id AND l.log_id = d.log_id;

    -- F3 event scope end and truncation (Step 3A sections 5 and 10.3) --------------------------------
    UPDATE log_regex.parsed_log l
    SET event_end_pos = c.start_pos,
        is_truncated  = 'truncated' = ANY (l.diagnostics)
    FROM parse_candidate c
    WHERE l.run_id = v_run_id
      AND l.format_family = 'F3'
      AND c.log_id = l.log_id
      AND c.role = 'event_end';

    -- F4 truncation: a quoted field not closed before the end of the event (Step 3A 10.3, EC-136) ----------
    UPDATE log_regex.parsed_log l
    SET is_truncated = true
    WHERE l.run_id = v_run_id
      AND l.format_family = 'F4'
      AND 'truncated' = ANY (l.diagnostics);

    -- S5 selection: first primary (or sentinel) candidate per field in document order ------------------
    DROP TABLE IF EXISTS pg_temp.parse_selected;
    CREATE TEMP TABLE parse_selected AS
    SELECT c.*,
           row_number() OVER (PARTITION BY c.log_id, c.field_name ORDER BY c.doc_order, c.start_pos) AS rn,
           count(*)     OVER (PARTITION BY c.log_id, c.field_name)                                   AS candidate_count
    FROM parse_candidate c
    WHERE c.role IN ('primary', 'sentinel');

    UPDATE log_regex.parsed_log l
    SET diagnostics = l.diagnostics || d.codes
    FROM (SELECT log_id, array_agg(DISTINCT 'duplicate_field:' || field_name) AS codes
          FROM parse_selected
          WHERE rn > 1
          GROUP BY log_id) d
    WHERE l.run_id = v_run_id AND l.log_id = d.log_id;

    -- C-06: an F1 event with neither an action nor a status is truncated ------------------------------
    UPDATE log_regex.parsed_log l
    SET is_truncated = true,
        diagnostics  = l.diagnostics || ARRAY['truncated', 'heuristic_truncation']
    WHERE l.run_id = v_run_id
      AND l.format_family = 'F1'
      AND NOT EXISTS (SELECT 1 FROM parse_selected s
                      WHERE s.log_id = l.log_id AND s.field_name IN ('action_phrase', 'status'));

    -- S6/S7 value state and validation, 10 rows per F1 / F2 / F3 log ------------------------------------
    INSERT INTO log_regex.parsed_field (run_id, log_id, field_name, value, validity, start_pos, missing_reason,
                                        slot_id, rule_id, candidate_count)
    WITH base AS (
        SELECT l.log_id,
               l.format_family,
               l.is_truncated,
               f.field_name,
               s.value,
               s.role,
               s.start_pos,
               s.slot_id,
               s.doc_order,
               coalesce(s.candidate_count, 0)::integer AS candidate_count,
               max(s.doc_order) FILTER (WHERE s.value <> '') OVER (PARTITION BY l.log_id) AS last_doc_order
        FROM log_regex.parsed_log l
        CROSS JOIN log_regex.ref_field f
        LEFT JOIN parse_selected s ON s.log_id = l.log_id AND s.field_name = f.field_name AND s.rn = 1
        WHERE l.run_id = v_run_id
          AND l.format_family IN ('F1', 'F2', 'F3', 'F4', 'F5')
    ),
    stated AS (
        SELECT b.*,
               CASE WHEN b.value IS NULL THEN 'absent' WHEN b.role = 'sentinel' THEN 'sentinel'
                    WHEN b.value = '' THEN 'empty' END AS missing_reason,
               CASE
                   WHEN b.value IS NULL OR b.value = '' OR b.role = 'sentinel' THEN 'MISSING'
                   WHEN EXISTS (SELECT 1 FROM log_regex.ref_placeholder_token p WHERE p.token = b.value) THEN 'PLACEHOLDER'
                   WHEN b.is_truncated AND b.doc_order = b.last_doc_order THEN 'TRUNCATED'
                   ELSE log_regex.field_validity(b.field_name, b.value, p_assumed_year)
               END AS state
        FROM base b
    )
    SELECT v_run_id,
           s.log_id,
           s.field_name,
           CASE WHEN s.state = 'MISSING' THEN NULL ELSE s.value END,
           CASE WHEN s.state = 'TRUNCATED' THEN 'INVALID' ELSE s.state END,
           CASE WHEN s.state = 'MISSING' THEN NULL ELSE s.start_pos END,
           s.missing_reason,
           s.slot_id,
           CASE
               WHEN s.missing_reason = 'absent'   THEN 'VS-1 absent'
               WHEN s.missing_reason = 'empty'    THEN 'VS-2 empty'
               WHEN s.missing_reason = 'sentinel' THEN 'VS-3 sentinel'
               WHEN s.state = 'PLACEHOLDER'       THEN 'VS-4 placeholder'
               WHEN s.state = 'TRUNCATED' AND s.format_family = 'F1' THEN 'VS-5 truncated (C-06)'
               WHEN s.state = 'TRUNCATED' AND s.format_family = 'F4' THEN 'VS-5 truncated (unclosed quote)'
               WHEN s.state = 'TRUNCATED'         THEN 'VS-5 truncated (unclosed JSON)'
               ELSE 'VS-6 ' || rf.validator
           END,
           s.candidate_count
    FROM stated s
    JOIN log_regex.ref_field rf ON rf.field_name = s.field_name;

    -- NONE rows (DET-00 no event, DET-NONE no format): every field MISSING --------------------------------------------------------
    INSERT INTO log_regex.parsed_field (run_id, log_id, field_name, value, validity, start_pos, missing_reason,
                                        slot_id, rule_id, candidate_count)
    SELECT v_run_id, l.log_id, f.field_name, NULL, 'MISSING', NULL, 'absent', NULL,
           CASE l.detection_rule WHEN 'DET-00' THEN 'DET-00 no event' ELSE 'DET-NONE no format' END, 0
    FROM log_regex.parsed_log l
    CROSS JOIN log_regex.ref_field f
    WHERE l.run_id = v_run_id
      AND l.format_family = 'NONE';

    -- Record validity (Step 3A section 10.4) ---------------------------------------------------------------------
    UPDATE log_regex.parsed_log l
    SET record_validity = CASE
                              WHEN l.is_truncated THEN 'BROKEN'
                              WHEN EXISTS (SELECT 1 FROM log_regex.parsed_field f
                                           WHERE f.run_id = l.run_id AND f.log_id = l.log_id AND f.validity = 'INVALID')
                                  THEN 'INVALID'
                              ELSE 'VALID'
                          END
    WHERE l.run_id = v_run_id
      AND l.format_family IN ('F1', 'F2', 'F3', 'F4', 'F5');

    -- Secondary values: secondary candidates, later duplicates (kind = the candidate's own secondary_kind, e.g.
    -- the F3 key "result", else duplicate_<field>), IPv4 look-alikes in resource / tool ----------------------
    INSERT INTO log_regex.parsed_secondary (run_id, log_id, field_name, kind, value, start_pos)
    SELECT v_run_id, c.log_id, c.field_name, c.secondary_kind, c.value, c.start_pos
    FROM parse_candidate c
    WHERE c.role = 'secondary' AND c.value <> ''
    UNION ALL
    SELECT v_run_id, s.log_id, s.field_name, coalesce(s.secondary_kind, 'duplicate_' || s.field_name), s.value, s.start_pos
    FROM parse_selected s
    WHERE s.rn > 1 AND s.value <> '' AND s.role = 'primary'
    UNION ALL
    SELECT v_run_id, f.log_id, 'ip_address',
           CASE f.field_name WHEN 'resource_url' THEN 'ip_like_in_resource' ELSE 'ip_like_in_tool' END,
           regexp_substr(f.value, '(?<![0-9.])[0-9]{1,3}([.][0-9]{1,3}){3}(?![0-9.])'),
           f.start_pos + regexp_instr(f.value, '(?<![0-9.])[0-9]{1,3}([.][0-9]{1,3}){3}(?![0-9.])') - 1
    FROM log_regex.parsed_field f
    WHERE f.run_id = v_run_id
      AND f.field_name IN ('resource_url', 'tool')
      AND f.value ~ '(?<![0-9.])[0-9]{1,3}([.][0-9]{1,3}){3}(?![0-9.])';

    -- S8 invariants: every stored value is the exact substring at its position ----------------------------
    SELECT count(*) INTO v_bad_fields
    FROM log_regex.parsed_field f
    JOIN log_regex.raw_access_logs r ON r.log_id = f.log_id
    WHERE f.run_id = v_run_id
      AND f.value IS NOT NULL
      AND substr(r.raw_log, f.start_pos, char_length(f.value)) IS DISTINCT FROM f.value;

    SELECT count(*) INTO v_bad_second
    FROM log_regex.parsed_secondary s
    JOIN log_regex.raw_access_logs r ON r.log_id = s.log_id
    WHERE s.run_id = v_run_id
      AND substr(r.raw_log, s.start_pos, char_length(s.value)) IS DISTINCT FROM s.value;

    IF v_bad_fields + v_bad_second > 0 THEN
        RAISE EXCEPTION 'exact-substring invariant violated: % field values, % secondary values', v_bad_fields, v_bad_second;
    END IF;

    IF EXISTS (SELECT 1 FROM log_regex.parsed_log
               WHERE run_id = v_run_id AND format_family IS NOT NULL AND record_validity IS NULL) THEN
        RAISE EXCEPTION 'record validity missing for parsed rows';
    END IF;

    IF EXISTS (SELECT 1 FROM log_regex.parsed_log WHERE run_id = v_run_id AND format_family IS NULL) THEN
        RAISE EXCEPTION 'rows without a final format classification';
    END IF;

    SELECT bool_and(passed) INTO v_after FROM log_regex.verify_raw_access_logs();
    IF v_after IS NOT TRUE THEN
        RAISE EXCEPTION 'raw input integrity check failed after parsing';
    END IF;

    UPDATE log_regex.parser_run
    SET fingerprint_check_after = v_after,
        finished_at             = clock_timestamp(),
        status                  = 'succeeded'
    WHERE run_id = v_run_id;

    RETURN v_run_id;
END;
$$;

COMMENT ON FUNCTION log_regex.run_parser(text, integer) IS
    'Parses all raw_access_logs rows (F1 - F5 and NONE since Step 3C; every row classified) into parsed_log, '
    'parsed_field and parsed_secondary. Returns the run_id.';

COMMIT;
