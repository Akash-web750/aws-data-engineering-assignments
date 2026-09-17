-- =============================================================================
-- Step 3C / 26 - Combined all-format parser validation (F4 -> F3 -> F1 -> F5 -> F2 -> NONE)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/26_test_combined_parser.sql
--
-- Runs the complete parser twice over all 5,000 raw logs and checks the Step 3A section 12 acceptance tests
-- T-01 ... T-10 plus the Step 3C requirements:
--   1  exactly one final format per row          (sections 4, 5)      T-03, T-04
--   2  the 5 DET-NONE rows are NONE              (section 6)
--   3  all 10 fields vs the answer key           (sections 7, 9)      T-06, T-07
--   4  100% acceptance on the complete dataset   (section 7)          C-05
--   5  record validity and diagnostics           (sections 8, 10)     T-10
--   6  every value at its recorded position      (sections 11, 12)    T-05, T-08
--   7  F1-F5 regression and raw-input integrity  (sections 1, 14, 15) T-01, T-02
--   8  deterministic output of two runs          (section 16)         T-09
-- Informational: secondary values against the answer key and the register of known annotation differences (13).
-- Exits non-zero if any check fails. No JSON/JSONB, PostGIS, indexes or performance experiments.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\echo
\echo '== 1. T-01 / T-02 raw input integrity before parsing =='
SELECT check_no, check_name, expected, actual, passed
FROM log_regex.verify_raw_access_logs()
ORDER BY check_no;

\echo
\echo '== 2. Regression baselines: latest successful run for each earlier format set =='
CREATE TEMP TABLE t_baselines AS
SELECT f.ord,
       f.fmt,
       f.formats,
       (SELECT coalesce(max(p.run_id), 0)
        FROM log_regex.parser_run p
        WHERE p.status = 'succeeded' AND p.formats_implemented = f.formats) AS baseline_run
FROM (VALUES (1, 'F1', ARRAY['F1']),
             (2, 'F2', ARRAY['F1', 'F2']),
             (3, 'F3', ARRAY['F1', 'F2', 'F3']),
             (4, 'F4', ARRAY['F1', 'F2', 'F3', 'F4']),
             (5, 'F5', ARRAY['F1', 'F2', 'F3', 'F4', 'F5'])) AS f (ord, fmt, formats);
SELECT b.fmt AS format_first_accepted, b.baseline_run, p.parser_version, p.formats_implemented
FROM t_baselines b
LEFT JOIN log_regex.parser_run p ON p.run_id = b.baseline_run
ORDER BY b.ord;

SELECT baseline_run AS all_format_baseline FROM t_baselines WHERE fmt = 'F5' \gset

\echo
\echo '== 3. Combined parser runs (run A and run B, identical inputs) =='
SELECT log_regex.run_parser('3C combined v1') AS run_a \gset
SELECT log_regex.run_parser('3C combined v1') AS run_b \gset
SELECT run_id, parser_version, reference_data_version, formats_implemented, assumed_year, raw_row_count,
       fingerprint_check_before, fingerprint_check_after, status,
       round(extract(epoch FROM finished_at - started_at)::numeric, 2) AS seconds
FROM log_regex.parser_run
WHERE run_id IN (:run_a, :run_b)
ORDER BY run_id;

\echo
\echo '== 4. T-03 output shape (run B) =='
CREATE TEMP TABLE t_shape AS
SELECT (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b)                                   AS parsed_log_rows,
       (SELECT count(DISTINCT log_id) FROM log_regex.parsed_log WHERE run_id = :run_b)                     AS distinct_log_ids,
       (SELECT count(*) FROM log_regex.raw_access_logs r
        WHERE NOT EXISTS (SELECT 1 FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.log_id = r.log_id)) AS raw_rows_without_parsed_log,
       (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_b)                                     AS parsed_field_rows,
       (SELECT count(*) FROM (SELECT l.log_id
                              FROM log_regex.parsed_log l
                              LEFT JOIN log_regex.parsed_field f ON f.run_id = l.run_id AND f.log_id = l.log_id
                              WHERE l.run_id = :run_b
                              GROUP BY l.log_id
                              HAVING count(f.field_name) <> 10 OR count(DISTINCT f.field_name) <> 10) x)        AS logs_without_10_distinct_fields,
       (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_b AND value = '')                       AS stored_empty_strings,
       (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_b AND (value IS NULL) <> (validity = 'MISSING')) AS missing_value_inconsistencies;
SELECT * FROM t_shape;

\echo
\echo '== 5. Requirement 1 / T-04: exactly one final format per row (run B) =='
CREATE TEMP TABLE t_classification AS
SELECT count(*)                                                                                   AS rows,
       count(*) FILTER (WHERE l.format_family IS NULL)                                            AS unclassified,
       count(*) FILTER (WHERE l.format_family NOT IN ('F1', 'F2', 'F3', 'F4', 'F5', 'NONE'))      AS unknown_family,
       count(*) FILTER (WHERE cardinality(l.format_candidates) <> 1)                              AS rows_without_exactly_one_rule,
       count(*) FILTER (WHERE l.format_candidates <> ARRAY[l.detection_rule])                     AS candidates_not_equal_rule,
       count(*) FILTER (WHERE NOT CASE l.format_family
                                      WHEN 'NONE' THEN l.detection_rule IN ('DET-00', 'DET-NONE')
                                      ELSE l.detection_rule = 'DET-' || l.format_family
                                  END)                                                            AS rule_family_inconsistent,
       count(*) FILTER (WHERE 'format_conflict' = ANY (l.diagnostics))                            AS format_conflicts,
       count(*) FILTER (WHERE l.format_family = e.format_family)                                  AS family_equals_answer_key
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b;
SELECT * FROM t_classification;

\echo 'Answer key format vs parsed format and rule (priority F4 -> F3 -> F1 -> F5 -> F2 -> NONE)'
SELECT e.format_family AS expected_format, l.format_family AS parsed_format, l.detection_rule, count(*) AS rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

\echo
\echo '== 6. Requirement 2: NONE rows (DET-00 blank input, DET-NONE no recognised format) =='
CREATE TEMP TABLE t_none AS
SELECT e.case_id,
       l.log_id,
       l.detection_rule,
       l.record_validity,
       l.diagnostics,
       l.event_end_pos,
       (SELECT count(*) FROM log_regex.parsed_field f
        WHERE f.run_id = l.run_id AND f.log_id = l.log_id AND f.validity = 'MISSING' AND f.value IS NULL) AS missing_fields,
       (SELECT string_agg(DISTINCT f.rule_id, ', ') FROM log_regex.parsed_field f
        WHERE f.run_id = l.run_id AND f.log_id = l.log_id)                                                AS rule_ids,
       (SELECT count(*) FROM log_regex.parsed_secondary s WHERE s.run_id = l.run_id AND s.log_id = l.log_id) AS secondary_values,
       CASE WHEN r.raw_log IS NULL THEN '(SQL NULL)' ELSE left(regexp_replace(r.raw_log, '[^ -~]', '?', 'g'), 60) END AS raw_preview
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
JOIN log_regex.raw_access_logs r USING (log_id)
WHERE l.run_id = :run_b AND l.format_family = 'NONE';
SELECT case_id, detection_rule, record_validity, diagnostics, missing_fields, rule_ids, secondary_values, raw_preview
FROM t_none
ORDER BY detection_rule, case_id;

CREATE TEMP TABLE t_none_check AS
SELECT count(*)                                                                         AS none_rows,
       count(*) FILTER (WHERE detection_rule = 'DET-00')                                AS det00_rows,
       count(*) FILTER (WHERE detection_rule = 'DET-NONE')                              AS det_none_rows,
       count(*) FILTER (WHERE detection_rule = 'DET-NONE'
                          AND case_id IN ('EC-130', 'EC-137', 'EC-138', 'EC-139', 'EC-140')) AS det_none_expected_cases,
       count(*) FILTER (WHERE record_validity = 'BROKEN' AND missing_fields = 10 AND secondary_values = 0) AS broken_all_missing,
       (SELECT count(*) FROM log_regex.expected_fields WHERE format_family = 'NONE')    AS answer_key_none_rows
FROM t_none;
SELECT * FROM t_none_check;

\echo
\echo '== 7. Requirements 3 / 4, T-07 / C-05: all 10 fields of all 5,000 rows vs the answer key (latest run) =='
CREATE TEMP TABLE t_accuracy AS
SELECT field_order,
       field_name,
       count(*)                                                    AS rows,
       count(*) FILTER (WHERE value_match)                         AS value_match,
       count(*) FILTER (WHERE validity_match)                      AS validity_match,
       count(*) FILTER (WHERE value_match AND validity_match)      AS both_match
FROM log_regex.v_parser_field_comparison
GROUP BY field_order, field_name;

SELECT field_name, rows, value_match, validity_match, both_match,
       round(100.0 * both_match / rows, 2) AS pct
FROM (
    SELECT field_order, field_name, rows, value_match, validity_match, both_match FROM t_accuracy
    UNION ALL
    SELECT 99, 'ALL FIELDS', sum(rows), sum(value_match), sum(validity_match), sum(both_match) FROM t_accuracy
) u
ORDER BY field_order;

\echo 'By format (both value and validity match, per field)'
SELECT expected_format,
       count(DISTINCT log_id)                                                                            AS logs,
       count(*) FILTER (WHERE field_name = 'entity_type'     AND value_match AND validity_match)         AS entity,
       count(*) FILTER (WHERE field_name = 'email_address'   AND value_match AND validity_match)         AS email,
       count(*) FILTER (WHERE field_name = 'resource_url'    AND value_match AND validity_match)         AS resource,
       count(*) FILTER (WHERE field_name = 'event_timestamp' AND value_match AND validity_match)         AS ts,
       count(*) FILTER (WHERE field_name = 'tool'            AND value_match AND validity_match)         AS tool,
       count(*) FILTER (WHERE field_name = 'latitude'        AND value_match AND validity_match)         AS lat,
       count(*) FILTER (WHERE field_name = 'longitude'       AND value_match AND validity_match)         AS lon,
       count(*) FILTER (WHERE field_name = 'ip_address'      AND value_match AND validity_match)         AS ip,
       count(*) FILTER (WHERE field_name = 'action_phrase'   AND value_match AND validity_match)         AS action,
       count(*) FILTER (WHERE field_name = 'status'          AND value_match AND validity_match)         AS status,
       count(*) FILTER (WHERE value_match AND validity_match)                                           AS both_match,
       count(*)                                                                                          AS field_values
FROM log_regex.v_parser_field_comparison
GROUP BY expected_format
ORDER BY expected_format;

\echo 'Mismatches (first 50; expected none)'
SELECT case_id, log_id, expected_format, field_name, left(expected_value, 40) AS expected_value,
       left(parsed_value, 40) AS parsed_value, expected_validity, parsed_validity, rule_id, slot_id
FROM log_regex.v_parser_mismatches
ORDER BY log_id, field_order
LIMIT 50;

\echo
\echo '== 8. Requirement 5 / T-10: validity distribution and record validity vs answer key and Step 3A targets =='
CREATE TEMP TABLE t_distribution AS
WITH targets (field_name, field_order, valid, invalid, placeholder, missing) AS (
    VALUES ('entity_type', 1, 4634, 18, 42, 306),     ('email_address', 2, 4544, 58, 109, 289),
           ('resource_url', 3, 4756, 15, 78, 151),    ('event_timestamp', 4, 4928, 62, 0, 10),
           ('tool', 5, 4507, 1, 160, 332),            ('latitude', 6, 4249, 24, 66, 661),
           ('longitude', 7, 4252, 27, 67, 654),       ('ip_address', 8, 4948, 38, 1, 13),
           ('action_phrase', 9, 4987, 0, 0, 13),      ('status', 10, 4701, 12, 90, 197)
),
validities (ord, validity) AS (
    VALUES (1, 'VALID'), (2, 'INVALID'), (3, 'PLACEHOLDER'), (4, 'MISSING')
)
SELECT t.field_order,
       t.field_name,
       v.ord,
       v.validity,
       CASE v.validity WHEN 'VALID' THEN t.valid WHEN 'INVALID' THEN t.invalid
                       WHEN 'PLACEHOLDER' THEN t.placeholder ELSE t.missing END AS step3a_target,
       count(*) FILTER (WHERE c.expected_validity = v.validity)                AS answer_key,
       count(*) FILTER (WHERE c.parsed_validity = v.validity)                  AS parsed
FROM targets t
CROSS JOIN validities v
JOIN log_regex.v_parser_field_comparison c ON c.field_name = t.field_name
GROUP BY t.field_order, t.field_name, v.ord, v.validity, t.valid, t.invalid, t.placeholder, t.missing;

SELECT field_name,
       max(parsed) FILTER (WHERE validity = 'VALID')       AS valid,
       max(parsed) FILTER (WHERE validity = 'INVALID')     AS invalid,
       max(parsed) FILTER (WHERE validity = 'PLACEHOLDER') AS placeholder,
       max(parsed) FILTER (WHERE validity = 'MISSING')     AS missing,
       bool_and(parsed = answer_key AND parsed = step3a_target) AS equals_answer_key_and_target
FROM t_distribution
GROUP BY field_order, field_name
ORDER BY field_order;

CREATE TEMP TABLE t_record_validity AS
SELECT v.validity,
       v.target                                                                             AS step3a_target,
       (SELECT count(*) FROM log_regex.expected_fields e WHERE e.record_validity = v.validity) AS answer_key,
       (SELECT count(*) FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.record_validity = v.validity) AS parsed
FROM (VALUES ('VALID', 4750), ('INVALID', 238), ('BROKEN', 12)) AS v (validity, target);
SELECT * FROM t_record_validity;

CREATE TEMP TABLE t_record_rows AS
SELECT count(*) FILTER (WHERE l.record_validity = e.record_validity) AS rows_equal,
       count(*)                                                     AS rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b;

SELECT e.format_family, l.record_validity, count(*) AS rows,
       count(*) FILTER (WHERE l.record_validity = e.record_validity) AS equal_to_answer_key
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b
GROUP BY 1, 2
ORDER BY 1, 2;

\echo
\echo '== 9. T-06: curated fixtures EC-001 ... EC-150, field by field =='
CREATE TEMP TABLE t_curated AS
SELECT count(DISTINCT log_id)                                                      AS curated_logs,
       count(*)                                                                    AS field_values,
       count(*) FILTER (WHERE value_match AND validity_match)                      AS both_match,
       count(DISTINCT log_id) FILTER (WHERE NOT (value_match AND validity_match))  AS cases_with_mismatch
FROM log_regex.v_parser_field_comparison
WHERE source = 'curated';
SELECT * FROM t_curated;
SELECT expected_format, count(DISTINCT case_id) AS curated_cases
FROM log_regex.v_parser_field_comparison
WHERE source = 'curated'
GROUP BY expected_format
ORDER BY expected_format;

\echo
\echo '== 10. Requirement 5: diagnostics against the Step 3A register (run B) =='
CREATE TEMP TABLE t_expected_diagnostics (case_id text, code text, reason text);
INSERT INTO t_expected_diagnostics VALUES
    ('EC-128', 'duplicate_field:status', 'F3 "status":401 then "result":"FAILED" (C-01)'),
    ('EC-134', 'truncated',              'F1 with neither action nor status (C-06)'),
    ('EC-134', 'heuristic_truncation',   'F1 C-06 is content-based'),
    ('EC-135', 'truncated',              'F3 JSON string not closed'),
    ('EC-136', 'truncated',              'F4 user agent quote not closed'),
    ('EC-130', 'no_format_detected',     'literal NULL text'),
    ('EC-137', 'no_format_detected',     'pipe header row'),
    ('EC-138', 'no_format_detected',     '9-semicolon header row'),
    ('EC-139', 'no_format_detected',     '##########'),
    ('EC-140', 'no_format_detected',     'ANSI escapes and mojibake');

CREATE TEMP TABLE t_actual_diagnostics AS
SELECT e.case_id, d.code
FROM log_regex.parsed_log l
CROSS JOIN LATERAL unnest(l.diagnostics) AS d (code)
JOIN log_regex.expected_fields e ON e.log_id = l.log_id
WHERE l.run_id = :run_b;

SELECT a.code, count(*) AS logs, string_agg(a.case_id, ', ' ORDER BY a.case_id) AS cases
FROM t_actual_diagnostics a
GROUP BY a.code
ORDER BY a.code;

CREATE TEMP TABLE t_diagnostic_check AS
SELECT (SELECT count(*) FROM t_actual_diagnostics)                                                  AS actual_codes,
       (SELECT count(*) FROM t_expected_diagnostics)                                                AS register_codes,
       (SELECT count(*) FROM (SELECT case_id, code FROM t_actual_diagnostics
                              EXCEPT ALL SELECT case_id, code FROM t_expected_diagnostics) x)       AS unexpected_codes,
       (SELECT count(*) FROM (SELECT case_id, code FROM t_expected_diagnostics
                              EXCEPT ALL SELECT case_id, code FROM t_actual_diagnostics) x)         AS missing_codes,
       (SELECT count(*) FROM log_regex.parsed_log
        WHERE run_id = :run_b AND is_truncated <> ('truncated' = ANY (diagnostics)))                 AS truncation_flag_mismatches,
       (SELECT count(*) FROM log_regex.parsed_log
        WHERE run_id = :run_b AND (record_validity = 'BROKEN') <> (format_family = 'NONE' OR is_truncated)) AS broken_rule_mismatches,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND is_truncated)            AS truncated_logs;
SELECT * FROM t_diagnostic_check;

\echo
\echo '== 11. Requirement 6 / T-05: every stored value is the substring at its recorded position (run B) =='
CREATE TEMP TABLE t_offsets AS
SELECT (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_b AND value IS NOT NULL) AS field_values,
       (SELECT count(*) FROM log_regex.parsed_field f JOIN log_regex.raw_access_logs r USING (log_id)
        WHERE f.run_id = :run_b AND f.value IS NOT NULL
          AND substr(r.raw_log, f.start_pos, char_length(f.value)) = f.value)                    AS field_values_exact,
       (SELECT count(*) FROM log_regex.parsed_field
        WHERE run_id = :run_b AND ((value IS NULL) <> (start_pos IS NULL)))                      AS position_nullness_mismatches,
       (SELECT count(*) FROM log_regex.parsed_secondary WHERE run_id = :run_b)                   AS secondary_values,
       (SELECT count(*) FROM log_regex.parsed_secondary s JOIN log_regex.raw_access_logs r USING (log_id)
        WHERE s.run_id = :run_b
          AND substr(r.raw_log, s.start_pos, char_length(s.value)) = s.value)                    AS secondary_values_exact;
SELECT * FROM t_offsets;

SELECT l.format_family,
       count(*) FILTER (WHERE f.value IS NOT NULL)                                                         AS field_values,
       count(*) FILTER (WHERE f.value IS NOT NULL
                          AND substr(r.raw_log, f.start_pos, char_length(f.value)) = f.value)              AS exact
FROM log_regex.parsed_field f
JOIN log_regex.parsed_log l ON l.run_id = f.run_id AND l.log_id = f.log_id
JOIN log_regex.raw_access_logs r ON r.log_id = f.log_id
WHERE f.run_id = :run_b
GROUP BY l.format_family
ORDER BY l.format_family;

\echo
\echo '== 12. T-08: look-alike traps are never primary values (run B, all formats) =='
CREATE TEMP TABLE t_lookalike AS
SELECT
    (SELECT count(*)
     FROM log_regex.parsed_field a
     JOIN log_regex.parsed_field b ON b.run_id = a.run_id AND b.log_id = a.log_id AND a.field_name < b.field_name
     WHERE a.run_id = :run_b AND a.value IS NOT NULL AND b.value IS NOT NULL
       AND a.start_pos < b.start_pos + char_length(b.value)
       AND b.start_pos < a.start_pos + char_length(a.value)
       AND NOT (a.field_name = 'latitude' AND b.field_name = 'longitude'
                AND a.start_pos = b.start_pos AND a.value = b.value))                    AS overlapping_field_spans,
    (SELECT count(*)
     FROM log_regex.parsed_secondary s
     JOIN log_regex.parsed_field f ON f.run_id = s.run_id AND f.log_id = s.log_id
                                  AND f.field_name = s.field_name AND f.start_pos = s.start_pos
     WHERE s.run_id = :run_b)                                                            AS secondary_at_primary_position,
    (SELECT count(*)
     FROM log_regex.parsed_field ip
     JOIN log_regex.parsed_field h ON h.run_id = ip.run_id AND h.log_id = ip.log_id AND h.field_name IN ('resource_url', 'tool')
     WHERE ip.run_id = :run_b AND ip.field_name = 'ip_address' AND ip.value IS NOT NULL AND h.value IS NOT NULL
       AND ip.start_pos >= h.start_pos AND ip.start_pos < h.start_pos + char_length(h.value)) AS ip_inside_resource_or_tool,
    (SELECT count(*)
     FROM log_regex.parsed_field g
     JOIN log_regex.parsed_field h ON h.run_id = g.run_id AND h.log_id = g.log_id AND h.field_name IN ('event_timestamp', 'tool')
     WHERE g.run_id = :run_b AND g.field_name IN ('latitude', 'longitude') AND g.value IS NOT NULL AND h.value IS NOT NULL
       AND g.start_pos >= h.start_pos AND g.start_pos < h.start_pos + char_length(h.value)) AS coordinate_inside_timestamp_or_tool,
    (SELECT count(*)
     FROM log_regex.parsed_field ts
     JOIN log_regex.parsed_field h ON h.run_id = ts.run_id AND h.log_id = ts.log_id AND h.field_name = 'resource_url'
     WHERE ts.run_id = :run_b AND ts.field_name = 'event_timestamp' AND ts.value IS NOT NULL AND h.value IS NOT NULL
       AND ts.start_pos >= h.start_pos AND ts.start_pos < h.start_pos + char_length(h.value)) AS timestamp_inside_resource,
    (SELECT count(*) FROM log_regex.parsed_secondary WHERE run_id = :run_b
       AND kind IN ('ip_like_in_resource', 'ip_like_in_tool'))                                AS ip_lookalikes_kept_secondary,
    (SELECT count(*) FROM log_regex.parsed_secondary WHERE run_id = :run_b AND kind = 'referer_url') AS referers_kept_secondary;
SELECT * FROM t_lookalike;

\echo
\echo '== 13. Secondary values vs the answer key (informational; not part of C-05) =='
CREATE TEMP TABLE t_secondary AS
WITH parsed AS (
    SELECT l.log_id,
           l.format_family,
           (SELECT string_agg(k, ';' ORDER BY k)
            FROM (SELECT s.kind || '=' || s.value AS k
                  FROM log_regex.parsed_secondary s
                  WHERE s.run_id = l.run_id AND s.log_id = l.log_id) q) AS parsed_set
    FROM log_regex.parsed_log l
    WHERE l.run_id = :run_b
),
expected AS (
    SELECT e.log_id, e.case_id,
           (SELECT string_agg(k, ';' ORDER BY k) FROM unnest(string_to_array(e.secondary_values, ';')) AS k) AS expected_set
    FROM log_regex.expected_fields e
)
SELECT x.log_id, x.case_id, p.format_family, x.expected_set, p.parsed_set,
       x.expected_set IS NOT DISTINCT FROM p.parsed_set AS same
FROM expected x
JOIN parsed p USING (log_id);

SELECT format_family, count(*) AS logs, count(*) FILTER (WHERE same) AS same_secondary_set,
       count(*) FILTER (WHERE NOT same) AS different
FROM t_secondary
GROUP BY format_family
ORDER BY format_family;

CREATE TEMP TABLE t_known_secondary_differences (case_id text, reason text);
INSERT INTO t_known_secondary_differences VALUES
    ('EC-002', 'F1 answer key annotates date_in_resource'),
    ('EC-030', 'F1 answer key annotates email_like_in_resource'),
    ('EC-100', 'F1 answer key annotates an IPv6 look-alike'),
    ('EC-143', 'F1 answer key annotates stack-trace text'),
    ('EC-110', 'F2 answer key annotates keyword_in_resource'),
    ('EC-005', 'F3 answer key annotates status_word_in_resource'),
    ('EC-036', 'F3 answer key annotates date_in_resource'),
    ('EC-063', 'F4 curated row omits ip_like_in_tool for Chrome/124.0.0.0'),
    ('EC-085', 'F4 curated row omits ip_like_in_tool for Chrome/124.0.0.0'),
    ('EC-142', 'F4 curated row omits ip_like_in_tool for Chrome/124.0.0.0');

SELECT t.case_id, t.format_family, t.expected_set, t.parsed_set, k.reason
FROM t_secondary t
LEFT JOIN t_known_secondary_differences k USING (case_id)
WHERE NOT t.same
ORDER BY t.log_id;

CREATE TEMP TABLE t_secondary_check AS
SELECT (SELECT count(*) FROM t_secondary WHERE NOT same)                                            AS different_logs,
       (SELECT count(*) FROM t_secondary t WHERE NOT t.same
          AND NOT EXISTS (SELECT 1 FROM t_known_secondary_differences k WHERE k.case_id = t.case_id)) AS unregistered_differences,
       (SELECT count(*) FROM t_known_secondary_differences k
        WHERE NOT EXISTS (SELECT 1 FROM t_secondary t WHERE t.case_id = k.case_id AND NOT t.same))     AS registered_but_equal;
SELECT * FROM t_secondary_check;

\echo
\echo '== 14. Requirement 7: F1 - F5 regression =='
\echo '14a. Run B vs the Step 3B-7 run (formats {F1,F2,F3,F4,F5}): every row except the 5 formerly deferred DET-NONE rows'
CREATE TEMP TABLE t_compare_logs AS
SELECT l.log_id
FROM log_regex.parsed_log l
WHERE l.run_id = :run_b AND l.detection_rule <> 'DET-NONE';

CREATE TEMP TABLE t_regression_all AS
SELECT :all_format_baseline::bigint AS baseline_run,
    (SELECT count(*) FROM t_compare_logs) AS logs_compared,
    (SELECT count(*) FROM (
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :all_format_baseline AND log_id IN (SELECT log_id FROM t_compare_logs))
        EXCEPT
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_compare_logs))) x) AS parsed_log_only_baseline,
    (SELECT count(*) FROM (
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_compare_logs))
        EXCEPT
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :all_format_baseline AND log_id IN (SELECT log_id FROM t_compare_logs))) x) AS parsed_log_only_current,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :all_format_baseline AND log_id IN (SELECT log_id FROM t_compare_logs))
        EXCEPT
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_compare_logs))) x) AS parsed_field_only_baseline,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_compare_logs))
        EXCEPT
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :all_format_baseline AND log_id IN (SELECT log_id FROM t_compare_logs))) x) AS parsed_field_only_current,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :all_format_baseline AND log_id IN (SELECT log_id FROM t_compare_logs))
        EXCEPT
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_compare_logs))) x) AS secondary_only_baseline,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_compare_logs))
        EXCEPT
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :all_format_baseline AND log_id IN (SELECT log_id FROM t_compare_logs))) x) AS secondary_only_current;
SELECT * FROM t_regression_all;

\echo '14b. The 5 DET-NONE rows: Step 3B-7 run (deferred) vs run B (NONE)'
SELECT e.case_id,
       coalesce(old.format_family, '(deferred)') AS before_format, old.detection_rule AS before_rule,
       old.record_validity AS before_record, old.diagnostics AS before_diagnostics,
       (SELECT count(*) FROM log_regex.parsed_field f WHERE f.run_id = old.run_id AND f.log_id = old.log_id) AS before_field_rows,
       new.format_family AS after_format, new.detection_rule AS after_rule, new.record_validity AS after_record,
       new.diagnostics AS after_diagnostics,
       (SELECT count(*) FROM log_regex.parsed_field f WHERE f.run_id = new.run_id AND f.log_id = new.log_id) AS after_field_rows
FROM log_regex.parsed_log new
JOIN log_regex.expected_fields e ON e.log_id = new.log_id
LEFT JOIN log_regex.parsed_log old ON old.run_id = :all_format_baseline AND old.log_id = new.log_id
WHERE new.run_id = :run_b AND new.detection_rule = 'DET-NONE'
ORDER BY e.case_id;

\echo '14c. Each format in run B vs the run in which that format was first accepted'
CREATE TEMP TABLE t_chain AS
SELECT b.ord,
       b.fmt,
       b.baseline_run,
       (SELECT count(*) FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.format_family = b.fmt) AS logs,
       (SELECT count(*) FROM (
            SELECT l.log_id, l.format_family, l.detection_rule, l.format_candidates, l.sub_format, l.event_end_pos,
                   l.is_truncated, l.record_validity, l.diagnostics
            FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.format_family = b.fmt
            EXCEPT
            SELECT l.log_id, l.format_family, l.detection_rule, l.format_candidates, l.sub_format, l.event_end_pos,
                   l.is_truncated, l.record_validity, l.diagnostics
            FROM log_regex.parsed_log l WHERE l.run_id = b.baseline_run) x)                              AS parsed_log_diff,
       (SELECT count(*) FROM (
            SELECT f.log_id, f.field_name, f.value, f.validity, f.start_pos, f.missing_reason, f.slot_id, f.rule_id,
                   f.candidate_count
            FROM log_regex.parsed_field f
            JOIN log_regex.parsed_log l ON l.run_id = f.run_id AND l.log_id = f.log_id AND l.format_family = b.fmt
            WHERE f.run_id = :run_b
            EXCEPT
            SELECT f.log_id, f.field_name, f.value, f.validity, f.start_pos, f.missing_reason, f.slot_id, f.rule_id,
                   f.candidate_count
            FROM log_regex.parsed_field f WHERE f.run_id = b.baseline_run) x)                            AS parsed_field_only_current,
       (SELECT count(*) FROM (
            SELECT f.log_id, f.field_name, f.value, f.validity, f.start_pos, f.missing_reason, f.slot_id, f.rule_id,
                   f.candidate_count
            FROM log_regex.parsed_field f
            WHERE f.run_id = b.baseline_run
              AND f.log_id IN (SELECT l.log_id FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.format_family = b.fmt)
            EXCEPT
            SELECT f.log_id, f.field_name, f.value, f.validity, f.start_pos, f.missing_reason, f.slot_id, f.rule_id,
                   f.candidate_count
            FROM log_regex.parsed_field f WHERE f.run_id = :run_b) x)                                    AS parsed_field_only_baseline,
       (SELECT count(*) FROM (
            SELECT s.log_id, s.field_name, s.kind, s.value, s.start_pos
            FROM log_regex.parsed_secondary s
            JOIN log_regex.parsed_log l ON l.run_id = s.run_id AND l.log_id = s.log_id AND l.format_family = b.fmt
            WHERE s.run_id = :run_b
            EXCEPT
            SELECT s.log_id, s.field_name, s.kind, s.value, s.start_pos
            FROM log_regex.parsed_secondary s WHERE s.run_id = b.baseline_run) x)                        AS secondary_only_current,
       (SELECT count(*) FROM (
            SELECT s.log_id, s.field_name, s.kind, s.value, s.start_pos
            FROM log_regex.parsed_secondary s
            WHERE s.run_id = b.baseline_run
              AND s.log_id IN (SELECT l.log_id FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.format_family = b.fmt)
            EXCEPT
            SELECT s.log_id, s.field_name, s.kind, s.value, s.start_pos
            FROM log_regex.parsed_secondary s WHERE s.run_id = :run_b) x)                                AS secondary_only_baseline
FROM t_baselines b;
SELECT fmt, baseline_run, logs, parsed_log_diff, parsed_field_only_current, parsed_field_only_baseline,
       secondary_only_current, secondary_only_baseline
FROM t_chain
ORDER BY ord;

\echo
\echo '== 15. Requirement 7 / T-01 / T-02: raw input integrity after both runs =='
CREATE TEMP TABLE t_raw_after AS
SELECT (SELECT count(*) FILTER (WHERE passed) FROM log_regex.verify_raw_access_logs())               AS checks_passed,
       (SELECT count(*) FROM log_regex.verify_raw_access_logs())                                    AS checks_total,
       (SELECT bool_and(fingerprint_check_before AND fingerprint_check_after)
        FROM log_regex.parser_run WHERE run_id IN (:run_a, :run_b))                                  AS run_fingerprints_ok;
SELECT * FROM t_raw_after;

\echo
\echo '== 16. Requirement 8 / T-09: determinism of the two complete runs =='
CREATE TEMP TABLE t_determinism AS
SELECT
    (SELECT count(*) FROM (
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics FROM log_regex.parsed_log WHERE run_id = :run_a)
        EXCEPT
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics FROM log_regex.parsed_log WHERE run_id = :run_b)) x)       AS parsed_log_a_not_b,
    (SELECT count(*) FROM (
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics FROM log_regex.parsed_log WHERE run_id = :run_b)
        EXCEPT
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics FROM log_regex.parsed_log WHERE run_id = :run_a)) x)       AS parsed_log_b_not_a,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_a)
        EXCEPT
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_b)) x)                                           AS parsed_field_a_not_b,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_b)
        EXCEPT
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_a)) x)                                           AS parsed_field_b_not_a,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, kind, value, start_pos FROM log_regex.parsed_secondary WHERE run_id = :run_a)
        EXCEPT
        (SELECT log_id, field_name, kind, value, start_pos FROM log_regex.parsed_secondary WHERE run_id = :run_b)) x) AS secondary_a_not_b,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, kind, value, start_pos FROM log_regex.parsed_secondary WHERE run_id = :run_b)
        EXCEPT
        (SELECT log_id, field_name, kind, value, start_pos FROM log_regex.parsed_secondary WHERE run_id = :run_a)) x) AS secondary_b_not_a,
    (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_a)
        - (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_b)                              AS field_row_count_diff,
    (SELECT count(*) FROM log_regex.parsed_secondary WHERE run_id = :run_a)
        - (SELECT count(*) FROM log_regex.parsed_secondary WHERE run_id = :run_b)                          AS secondary_row_count_diff;
SELECT * FROM t_determinism;

\echo
\echo '== 17. Verdict =='
DO $$
DECLARE
    sh  record;
    cl  record;
    nc  record;
    ac  record;
    rr  record;
    cu  record;
    dg  record;
    os  record;
    la  record;
    sc  record;
    ra  record;
    rw  record;
    dt  record;
    distribution_failures bigint;
    record_failures       bigint;
    chain_failures        bigint;
    chain_missing         bigint;
    raw_before_failures   bigint;
    failures              text[] := ARRAY[]::text[];
BEGIN
    SELECT * INTO sh FROM t_shape;
    SELECT * INTO cl FROM t_classification;
    SELECT * INTO nc FROM t_none_check;
    SELECT sum(rows) AS rows, sum(both_match) AS both_match, sum(value_match) AS value_match,
           sum(validity_match) AS validity_match INTO ac FROM t_accuracy;
    SELECT * INTO rr FROM t_record_rows;
    SELECT * INTO cu FROM t_curated;
    SELECT * INTO dg FROM t_diagnostic_check;
    SELECT * INTO os FROM t_offsets;
    SELECT * INTO la FROM t_lookalike;
    SELECT * INTO sc FROM t_secondary_check;
    SELECT * INTO ra FROM t_regression_all;
    SELECT * INTO rw FROM t_raw_after;
    SELECT * INTO dt FROM t_determinism;
    SELECT count(*) INTO distribution_failures FROM t_distribution WHERE parsed <> answer_key OR parsed <> step3a_target;
    SELECT count(*) INTO record_failures FROM t_record_validity WHERE parsed <> answer_key OR parsed <> step3a_target;
    SELECT count(*) FILTER (WHERE parsed_log_diff + parsed_field_only_current + parsed_field_only_baseline
                                  + secondary_only_current + secondary_only_baseline > 0),
           count(*) FILTER (WHERE baseline_run = 0)
      INTO chain_failures, chain_missing
    FROM t_chain;

    -- T-01 / T-02
    IF rw.checks_passed <> rw.checks_total OR rw.run_fingerprints_ok IS NOT TRUE THEN
        failures := failures || format('T-01/T-02 raw integrity: %s/%s checks, run fingerprints %s', rw.checks_passed, rw.checks_total, rw.run_fingerprints_ok);
    END IF;
    -- T-03
    IF sh.parsed_log_rows <> 5000 OR sh.distinct_log_ids <> 5000 OR sh.raw_rows_without_parsed_log <> 0
       OR sh.parsed_field_rows <> 50000 OR sh.logs_without_10_distinct_fields <> 0 OR sh.stored_empty_strings <> 0
       OR sh.missing_value_inconsistencies <> 0 THEN
        failures := failures || format('T-03 shape: %s logs, %s fields, %s without 10, %s empty strings',
                                       sh.parsed_log_rows, sh.parsed_field_rows, sh.logs_without_10_distinct_fields, sh.stored_empty_strings);
    END IF;
    -- Requirement 1 / T-04
    IF cl.unclassified + cl.unknown_family + cl.rows_without_exactly_one_rule + cl.candidates_not_equal_rule
       + cl.rule_family_inconsistent + cl.format_conflicts <> 0 OR cl.family_equals_answer_key <> 5000 THEN
        failures := failures || format('T-04 classification: %s unclassified, %s not one rule, %s conflicts, %s/5000 equal',
                                       cl.unclassified, cl.rows_without_exactly_one_rule, cl.format_conflicts, cl.family_equals_answer_key);
    END IF;
    -- Requirement 2
    IF nc.none_rows <> nc.answer_key_none_rows OR nc.det_none_rows <> 5 OR nc.det_none_expected_cases <> 5
       OR nc.det00_rows <> 4 OR nc.broken_all_missing <> nc.none_rows THEN
        failures := failures || format('NONE rows: %s NONE (%s DET-00, %s DET-NONE), %s broken with 10 MISSING',
                                       nc.none_rows, nc.det00_rows, nc.det_none_rows, nc.broken_all_missing);
    END IF;
    -- Requirements 3 / 4, T-07, T-06
    IF ac.rows <> 50000 OR ac.both_match <> ac.rows THEN
        failures := failures || format('T-07 accuracy: %s / %s field values', ac.both_match, ac.rows);
    END IF;
    IF cu.curated_logs <> 150 OR cu.both_match <> cu.field_values OR cu.cases_with_mismatch <> 0 THEN
        failures := failures || format('T-06 curated fixtures: %s / %s', cu.both_match, cu.field_values);
    END IF;
    -- Requirement 5 / T-10
    IF distribution_failures + record_failures <> 0 OR rr.rows_equal <> rr.rows THEN
        failures := failures || format('T-10 distribution: %s field cells and %s record cells differ; %s/%s record validity equal',
                                       distribution_failures, record_failures, rr.rows_equal, rr.rows);
    END IF;
    IF dg.unexpected_codes + dg.missing_codes + dg.truncation_flag_mismatches + dg.broken_rule_mismatches <> 0 THEN
        failures := failures || format('diagnostics: %s unexpected, %s missing, %s truncation flags, %s BROKEN rule',
                                       dg.unexpected_codes, dg.missing_codes, dg.truncation_flag_mismatches, dg.broken_rule_mismatches);
    END IF;
    -- Requirement 6 / T-05 / T-08
    IF os.field_values <> os.field_values_exact OR os.secondary_values <> os.secondary_values_exact
       OR os.position_nullness_mismatches <> 0 THEN
        failures := failures || format('T-05 offsets: %s/%s field values, %s/%s secondary values',
                                       os.field_values_exact, os.field_values, os.secondary_values_exact, os.secondary_values);
    END IF;
    IF la.overlapping_field_spans + la.secondary_at_primary_position + la.ip_inside_resource_or_tool
       + la.coordinate_inside_timestamp_or_tool + la.timestamp_inside_resource <> 0 THEN
        failures := failures || format('T-08 look-alikes: %s overlaps, %s secondary at primary position, %s IP, %s coordinate, %s timestamp',
                                       la.overlapping_field_spans, la.secondary_at_primary_position, la.ip_inside_resource_or_tool,
                                       la.coordinate_inside_timestamp_or_tool, la.timestamp_inside_resource);
    END IF;
    IF sc.unregistered_differences + sc.registered_but_equal <> 0 THEN
        failures := failures || format('secondary values: %s unregistered differences, %s registered but equal',
                                       sc.unregistered_differences, sc.registered_but_equal);
    END IF;
    -- Requirement 7: regression
    IF chain_missing > 0 THEN
        failures := failures || format('regression: %s format baselines missing from parser_run', chain_missing);
    ELSIF chain_failures > 0 OR ra.parsed_log_only_baseline + ra.parsed_log_only_current + ra.parsed_field_only_baseline
          + ra.parsed_field_only_current + ra.secondary_only_baseline + ra.secondary_only_current <> 0 THEN
        failures := failures || format('regression: %s formats differ from their first accepted run; %s rows differ from run %s',
                                       chain_failures,
                                       ra.parsed_log_only_baseline + ra.parsed_log_only_current + ra.parsed_field_only_baseline
                                       + ra.parsed_field_only_current + ra.secondary_only_baseline + ra.secondary_only_current,
                                       ra.baseline_run);
    END IF;
    -- Requirement 8 / T-09
    IF dt.parsed_log_a_not_b + dt.parsed_log_b_not_a + dt.parsed_field_a_not_b + dt.parsed_field_b_not_a
       + dt.secondary_a_not_b + dt.secondary_b_not_a + abs(dt.field_row_count_diff) + abs(dt.secondary_row_count_diff) <> 0 THEN
        failures := failures || 'T-09 determinism: runs A and B differ';
    END IF;

    IF cardinality(failures) > 0 THEN
        RAISE EXCEPTION 'Step 3C combined validation FAILED: %', array_to_string(failures, ' | ');
    END IF;

    RAISE NOTICE 'T-01/T-02 PASS: raw input unchanged (% / % integrity checks; fingerprints before and after both runs)', rw.checks_passed, rw.checks_total;
    RAISE NOTICE 'T-03 PASS: 5000 parsed_log rows, 50000 parsed_field rows, 10 fields per log, no stored empty strings';
    RAISE NOTICE 'T-04 PASS (req 1): every row has exactly one final format and one detection rule; 5000 / 5000 equal the answer key; 0 conflicts';
    RAISE NOTICE 'NONE PASS (req 2): % NONE rows = % DET-00 + % DET-NONE (EC-130, EC-137, EC-138, EC-139, EC-140); all BROKEN with 10 MISSING fields', nc.none_rows, nc.det00_rows, nc.det_none_rows;
    RAISE NOTICE 'T-06 PASS: curated fixtures % / % field values', cu.both_match, cu.field_values;
    RAISE NOTICE 'T-07 / C-05 PASS (req 3, 4): % / % field values match the answer key in value (%) and validity (%)', ac.both_match, ac.rows, ac.value_match, ac.validity_match;
    RAISE NOTICE 'T-10 PASS (req 5): 40 validity cells equal the answer key and Step 3A 10.1; record validity % / % (VALID 4750, INVALID 238, BROKEN 12)', rr.rows_equal, rr.rows;
    RAISE NOTICE 'Diagnostics PASS (req 5): % codes exactly as the register; truncation flags and BROKEN rule consistent', dg.actual_codes;
    RAISE NOTICE 'T-05 PASS (req 6): % / % field values and % / % secondary values at their recorded positions', os.field_values_exact, os.field_values, os.secondary_values_exact, os.secondary_values;
    RAISE NOTICE 'T-08 PASS: no overlapping field spans, no secondary value at a primary position, no IP / coordinate / timestamp taken from another field';
    RAISE NOTICE 'Secondary values (informational): % differing logs, all in the register of known answer-key annotation differences', sc.different_logs;
    RAISE NOTICE 'Regression PASS (req 7): % rows identical to run %; F1-F5 each identical to its first accepted run', ra.logs_compared, ra.baseline_run;
    RAISE NOTICE 'T-09 PASS (req 8): runs A and B identical';
END
$$;
