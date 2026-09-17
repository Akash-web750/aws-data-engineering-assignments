-- =============================================================================
-- Step 3B-4 / 16 - Test the F2 parser against the answer key (and F1 against its Step 3B-3 baseline)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/16_test_f2_parser.sql
--
-- Runs the F1 + F2 parser twice (determinism), then reports detection (including DET-F2 false positives on
-- F3/F4/F5/NONE rows), output shape, offsets, F2 per-field accuracy, validity distribution, accuracy by
-- template and source, record validity, mismatches, secondary values, diagnostics, the "from"-inside-phrase
-- check, whole-line first-match probes vs the grammar, non-overlapping spans, the F1 regression against the
-- latest Step 3B-3 run (formats {F1}), examples, determinism and raw-input integrity.
-- Exits non-zero only if an invariant fails. The F2 acceptance verdict (C-05) is printed in section 20.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\echo
\echo '== 1. Raw input integrity before parsing =='
SELECT count(*) FILTER (WHERE passed) AS checks_passed, count(*) AS checks_total
FROM log_regex.verify_raw_access_logs();

\echo
\echo '== 2. F1 regression baseline: latest successful run with formats {F1} (Step 3B-3) =='
SELECT coalesce(max(run_id), 0) AS baseline_run
FROM log_regex.parser_run
WHERE status = 'succeeded' AND formats_implemented = ARRAY['F1'] \gset
SELECT :baseline_run AS baseline_run,
       (SELECT parser_version FROM log_regex.parser_run WHERE run_id = :baseline_run)         AS parser_version,
       (SELECT reference_data_version FROM log_regex.parser_run WHERE run_id = :baseline_run) AS reference_data_version,
       (SELECT formats_implemented FROM log_regex.parser_run WHERE run_id = :baseline_run)    AS formats_implemented;

\echo
\echo '== 3. Parser runs (run A and run B, identical inputs) =='
SELECT log_regex.run_parser('3B-4 F1+F2 v1') AS run_a \gset
SELECT log_regex.run_parser('3B-4 F1+F2 v1') AS run_b \gset
SELECT run_id, parser_version, reference_data_version, formats_implemented, assumed_year, raw_row_count,
       fingerprint_check_before, fingerprint_check_after, status,
       round(extract(epoch FROM finished_at - started_at)::numeric, 2) AS seconds
FROM log_regex.parser_run
WHERE run_id IN (:run_a, :run_b)
ORDER BY run_id;

\echo
\echo '== 4. Detection against the answer key (all 5,000 rows, run B) =='
SELECT e.format_family                        AS expected_format,
       coalesce(l.format_family, '(deferred)') AS parsed_format,
       l.detection_rule,
       count(*)                                AS rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

CREATE TEMP TABLE t_detection AS
SELECT count(*) FILTER (WHERE e.format_family = 'F1' AND l.format_family = 'F1')                AS f1_true_positive,
       count(*) FILTER (WHERE e.format_family <> 'F1' AND l.format_family = 'F1')               AS f1_false_positive,
       count(*) FILTER (WHERE e.format_family = 'F1' AND l.format_family IS DISTINCT FROM 'F1') AS f1_false_negative,
       count(*) FILTER (WHERE e.format_family = 'F2' AND l.format_family = 'F2')                AS f2_true_positive,
       count(*) FILTER (WHERE e.format_family <> 'F2' AND l.format_family = 'F2')               AS f2_false_positive,
       count(*) FILTER (WHERE e.format_family = 'F2' AND l.format_family IS DISTINCT FROM 'F2') AS f2_false_negative,
       count(*) FILTER (WHERE l.detection_rule = 'DET-00' AND e.format_family <> 'NONE')        AS det00_not_none
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b;
SELECT * FROM t_detection;

\echo 'DET-F2 on rows of other formats (expected: no rows)'
SELECT e.format_family AS expected_format, count(*) AS det_f2_rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b AND l.detection_rule = 'DET-F2' AND e.format_family <> 'F2'
GROUP BY 1
ORDER BY 1;

\echo
\echo '== 5. Output shape (run B) =='
CREATE TEMP TABLE t_shape AS
SELECT (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b)                                   AS parsed_log_rows,
       (SELECT count(*) FROM log_regex.raw_access_logs r
        WHERE NOT EXISTS (SELECT 1 FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.log_id = r.log_id)) AS raw_rows_without_parsed_log,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F1')              AS f1_logs,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F2')              AS f2_logs,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'NONE')            AS det00_logs,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family IS NULL)             AS deferred_logs,
       (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_b)                                     AS parsed_field_rows,
       (SELECT count(*) FROM (SELECT l.log_id
                              FROM log_regex.parsed_log l
                              LEFT JOIN log_regex.parsed_field f ON f.run_id = l.run_id AND f.log_id = l.log_id
                              WHERE l.run_id = :run_b AND l.format_family IS NOT NULL
                              GROUP BY l.log_id
                              HAVING count(f.field_name) <> 10) x)                                              AS parsed_logs_without_10_fields;
SELECT * FROM t_shape;

\echo
\echo '== 6. Exact substrings at recorded positions (run B, all parsed formats) =='
CREATE TEMP TABLE t_offsets AS
SELECT (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_b AND value IS NOT NULL) AS field_values,
       (SELECT count(*) FROM log_regex.parsed_field f JOIN log_regex.raw_access_logs r USING (log_id)
        WHERE f.run_id = :run_b AND f.value IS NOT NULL
          AND substr(r.raw_log, f.start_pos, char_length(f.value)) = f.value)                    AS field_values_exact,
       (SELECT count(*) FROM log_regex.parsed_secondary WHERE run_id = :run_b)                   AS secondary_values,
       (SELECT count(*) FROM log_regex.parsed_secondary s JOIN log_regex.raw_access_logs r USING (log_id)
        WHERE s.run_id = :run_b
          AND substr(r.raw_log, s.start_pos, char_length(s.value)) = s.value)                    AS secondary_values_exact;
SELECT * FROM t_offsets;

\echo
\echo '== 7. Per-field accuracy on all answer-key F2 rows (latest run) =='
CREATE TEMP TABLE t_accuracy AS
SELECT field_order,
       field_name,
       count(*)                                                    AS rows,
       count(*) FILTER (WHERE value_match)                         AS value_match,
       count(*) FILTER (WHERE validity_match)                      AS validity_match,
       count(*) FILTER (WHERE value_match AND validity_match)      AS both_match,
       round(100.0 * count(*) FILTER (WHERE value_match AND validity_match) / count(*), 2) AS pct
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F2'
GROUP BY field_order, field_name;

SELECT field_name, rows, value_match, validity_match, both_match, pct
FROM (
    SELECT field_order, field_name, rows, value_match, validity_match, both_match, pct
    FROM t_accuracy
    UNION ALL
    SELECT 99, 'ALL FIELDS', sum(rows), sum(value_match), sum(validity_match), sum(both_match),
           round(100.0 * sum(both_match) / sum(rows), 2)
    FROM t_accuracy
) u
ORDER BY field_order;

\echo
\echo '== 8. Validity distribution on F2 rows: answer key vs parser =='
SELECT c.field_name,
       v.validity,
       count(*) FILTER (WHERE c.expected_validity = v.validity) AS expected,
       count(*) FILTER (WHERE c.parsed_validity   = v.validity) AS parsed
FROM log_regex.v_parser_field_comparison c
CROSS JOIN (VALUES (1, 'VALID'), (2, 'INVALID'), (3, 'PLACEHOLDER'), (4, 'MISSING')) AS v (ord, validity)
WHERE c.expected_format = 'F2'
GROUP BY c.field_order, c.field_name, v.ord, v.validity
ORDER BY c.field_order, v.ord;

SELECT c.field_name, c.missing_reason, c.rule_id, count(*) AS rows
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F2' AND c.parsed_validity = 'MISSING'
GROUP BY c.field_order, c.field_name, c.missing_reason, c.rule_id
ORDER BY c.field_order, c.missing_reason;

\echo
\echo '== 9. F2 accuracy by template (sub_format) and by source =='
SELECT l.sub_format,
       count(DISTINCT c.log_id)                                                         AS logs,
       count(*)                                                                         AS field_values,
       count(*) FILTER (WHERE c.value_match AND c.validity_match)                       AS both_match,
       count(DISTINCT c.log_id) FILTER (WHERE NOT (c.value_match AND c.validity_match)) AS logs_with_mismatch
FROM log_regex.v_parser_field_comparison c
JOIN log_regex.parsed_log l ON l.run_id = c.run_id AND l.log_id = c.log_id
WHERE c.expected_format = 'F2'
GROUP BY l.sub_format
ORDER BY l.sub_format;

SELECT source,
       count(DISTINCT log_id)                                                      AS logs,
       count(*)                                                                    AS field_values,
       count(*) FILTER (WHERE value_match AND validity_match)                      AS both_match,
       count(DISTINCT log_id) FILTER (WHERE NOT (value_match AND validity_match))  AS logs_with_mismatch
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F2'
GROUP BY source
ORDER BY source;

\echo
\echo '== 10. Record validity on F2 rows =='
SELECT e.record_validity AS expected, l.record_validity AS parsed, count(*) AS rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b AND e.format_family = 'F2'
GROUP BY 1, 2
ORDER BY 1, 2;

\echo
\echo '== 11. Mismatches on F2 rows (first 60) =='
SELECT case_id, log_id, field_name, expected_value, parsed_value, expected_validity, parsed_validity, rule_id, slot_id
FROM log_regex.v_parser_mismatches
WHERE expected_format = 'F2'
ORDER BY log_id, field_order
LIMIT 60;

\echo
\echo '== 12. Secondary values on F2 rows (informational; not part of C-05) =='
CREATE TEMP TABLE t_secondary AS
WITH parsed AS (
    SELECT l.log_id,
           (SELECT string_agg(k, ';' ORDER BY k)
            FROM (SELECT s.kind || '=' || s.value AS k
                  FROM log_regex.parsed_secondary s
                  WHERE s.run_id = l.run_id AND s.log_id = l.log_id) q) AS parsed_set
    FROM log_regex.parsed_log l
    WHERE l.run_id = :run_b AND l.format_family = 'F2'
),
expected AS (
    SELECT e.log_id, e.case_id,
           (SELECT string_agg(k, ';' ORDER BY k) FROM unnest(string_to_array(e.secondary_values, ';')) AS k) AS expected_set
    FROM log_regex.expected_fields e
    WHERE e.format_family = 'F2'
)
SELECT x.log_id, x.case_id, x.expected_set, p.parsed_set, x.expected_set IS NOT DISTINCT FROM p.parsed_set AS same
FROM expected x
JOIN parsed p USING (log_id);

SELECT count(*) AS f2_logs,
       count(*) FILTER (WHERE same) AS same_secondary_set,
       count(*) FILTER (WHERE NOT same) AS different
FROM t_secondary;
SELECT case_id, log_id, expected_set, parsed_set FROM t_secondary WHERE NOT same ORDER BY log_id;

SELECT s.kind, count(*) AS values
FROM log_regex.parsed_secondary s
JOIN log_regex.parsed_log l ON l.run_id = s.run_id AND l.log_id = s.log_id
WHERE s.run_id = :run_b AND l.format_family = 'F2'
GROUP BY s.kind
ORDER BY s.kind;

\echo
\echo '== 13. Diagnostics and templates on F2 rows (run B) =='
SELECT d.code, count(*) AS logs, string_agg(e.case_id, ', ' ORDER BY e.log_id) FILTER (WHERE e.source = 'curated') AS curated_cases
FROM log_regex.parsed_log l
CROSS JOIN LATERAL unnest(l.diagnostics) AS d (code)
JOIN log_regex.expected_fields e ON e.log_id = l.log_id
WHERE l.run_id = :run_b AND l.format_family = 'F2'
GROUP BY d.code
ORDER BY d.code;

SELECT sub_format, count(*) AS logs FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F2' GROUP BY 1 ORDER BY 1;

SELECT f.field_name, f.slot_id, count(*) AS values
FROM log_regex.parsed_field f
JOIN log_regex.parsed_log l ON l.run_id = f.run_id AND l.log_id = f.log_id
JOIN log_regex.ref_field rf ON rf.field_name = f.field_name
WHERE f.run_id = :run_b AND l.format_family = 'F2' AND f.slot_id IS NOT NULL
GROUP BY rf.field_order, f.field_name, f.slot_id
ORDER BY rf.field_order, f.slot_id;

\echo
\echo '== 14. "from" inside action phrases is never an IP clause (run B) =='
CREATE TEMP TABLE t_from_phrase AS
SELECT e.log_id,
       e.case_id,
       e.action_phrase AS expected_action,
       a.value         AS parsed_action,
       a.start_pos     AS action_pos,
       e.ip_address    AS expected_ip,
       i.value         AS parsed_ip,
       i.start_pos     AS ip_pos,
       i.slot_id       AS ip_slot,
       regexp_substr(r.raw_log, '\yfrom ([^ ,;)]+)', 1, 1, '', 1) AS token_after_first_from
FROM log_regex.expected_fields e
JOIN log_regex.raw_access_logs r ON r.log_id = e.log_id
JOIN log_regex.parsed_field a ON a.run_id = :run_b AND a.log_id = e.log_id AND a.field_name = 'action_phrase'
JOIN log_regex.parsed_field i ON i.run_id = :run_b AND i.log_id = e.log_id AND i.field_name = 'ip_address'
WHERE e.format_family = 'F2'
  AND e.action_phrase ~ '\yfrom\y';

SELECT expected_action,
       count(*)                                                                     AS rows,
       count(*) FILTER (WHERE parsed_action = expected_action)                      AS action_exact,
       count(*) FILTER (WHERE parsed_ip IS NOT DISTINCT FROM expected_ip)           AS ip_exact,
       count(*) FILTER (WHERE ip_pos BETWEEN action_pos AND action_pos + char_length(parsed_action) - 1) AS ip_inside_phrase,
       count(*) FILTER (WHERE token_after_first_from = 'accessing')                 AS first_from_token_is_accessing
FROM t_from_phrase
GROUP BY expected_action
ORDER BY expected_action;

SELECT case_id, log_id, parsed_action, token_after_first_from, parsed_ip, ip_slot
FROM t_from_phrase
ORDER BY log_id
LIMIT 3;

\echo
\echo '== 15. Whole-line first-match probes vs the grammar on F2 rows (informational) =='
CREATE TEMP TABLE t_naive AS
SELECT e.log_id,
       e.case_id,
       x.probe_order,
       x.field_name,
       x.probe,
       x.expected_value,
       x.naive_value,
       f.value AS parser_value
FROM log_regex.expected_fields e
JOIN log_regex.raw_access_logs r ON r.log_id = e.log_id
CROSS JOIN LATERAL (VALUES
    (1, 'email_address',   'first token containing @',                e.email_address,
        regexp_substr(r.raw_log, '[^ <>"()]*@[^ <>"()]*')),
    (2, 'ip_address',      'first dotted quad anywhere',               e.ip_address,
        regexp_substr(r.raw_log, '[0-9]{1,3}([.][0-9]{1,3}){3}')),
    (3, 'ip_address',      'token after the first word "from"',        e.ip_address,
        regexp_substr(r.raw_log, '\yfrom ([^ ,;)]+)', 1, 1, '', 1)),
    (4, 'resource_url',    'first http(s) URL anywhere',               e.resource_url,
        regexp_substr(r.raw_log, 'https?://[^ ]+')),
    (5, 'event_timestamp', 'first ISO date-time anywhere',             e.event_timestamp,
        regexp_substr(r.raw_log, '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z?')),
    (6, 'latitude',        'first number with 2+ decimals anywhere',   e.latitude,
        regexp_substr(r.raw_log, '-?[0-9]+[.][0-9]{2,}'))
) AS x (probe_order, field_name, probe, expected_value, naive_value)
JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = e.log_id AND f.field_name = x.field_name
WHERE e.format_family = 'F2';

SELECT field_name,
       probe,
       count(*)                                                                    AS rows,
       count(*) FILTER (WHERE naive_value  IS NOT DISTINCT FROM expected_value)    AS naive_correct,
       count(*) FILTER (WHERE parser_value IS NOT DISTINCT FROM expected_value)    AS parser_correct
FROM t_naive
GROUP BY probe_order, field_name, probe
ORDER BY probe_order;

SELECT DISTINCT ON (probe_order) probe, case_id, log_id, expected_value, naive_value, parser_value
FROM t_naive
WHERE naive_value IS DISTINCT FROM expected_value
ORDER BY probe_order, (case_id LIKE 'EC-%') DESC, log_id;

\echo
\echo '== 16. Non-overlapping field spans on F2 rows (run B) =='
CREATE TEMP TABLE t_overlap AS
SELECT count(*) AS overlapping_pairs
FROM log_regex.parsed_field a
JOIN log_regex.parsed_field b ON b.run_id = a.run_id AND b.log_id = a.log_id AND a.field_name < b.field_name
JOIN log_regex.parsed_log l   ON l.run_id = a.run_id AND l.log_id = a.log_id
WHERE a.run_id = :run_b
  AND l.format_family = 'F2'
  AND a.value IS NOT NULL
  AND b.value IS NOT NULL
  AND a.start_pos < b.start_pos + char_length(b.value)
  AND b.start_pos < a.start_pos + char_length(a.value);
SELECT * FROM t_overlap;

\echo
\echo '== 17. F1 regression: run B vs the Step 3B-3 baseline run, F1 rows only =='
CREATE TEMP TABLE t_f1_logs AS
SELECT DISTINCT log_id
FROM log_regex.parsed_log
WHERE run_id IN (:baseline_run, :run_b) AND format_family = 'F1';

CREATE TEMP TABLE t_regression AS
SELECT :baseline_run::bigint AS baseline_run,
    (SELECT count(*) FROM t_f1_logs) AS f1_logs_compared,
    (SELECT count(*) FROM (
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_f1_logs))
        EXCEPT
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_f1_logs))) x) AS parsed_log_only_baseline,
    (SELECT count(*) FROM (
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_f1_logs))
        EXCEPT
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_f1_logs))) x) AS parsed_log_only_current,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_f1_logs))
        EXCEPT
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_f1_logs))) x) AS parsed_field_only_baseline,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_f1_logs))
        EXCEPT
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_f1_logs))) x) AS parsed_field_only_current,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_f1_logs))
        EXCEPT
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_f1_logs))) x) AS secondary_only_baseline,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_f1_logs))
        EXCEPT
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_f1_logs))) x) AS secondary_only_current,
    (SELECT count(*) FROM log_regex.parsed_field
     WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_f1_logs))                           AS baseline_f1_field_rows,
    (SELECT count(*) FROM log_regex.parsed_field
     WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_f1_logs))                                  AS current_f1_field_rows;
SELECT * FROM t_regression;

\echo
\echo '== 18. F1 accuracy on all answer-key F1 rows (latest run) =='
CREATE TEMP TABLE t_f1_accuracy AS
SELECT count(*)                                               AS rows,
       count(*) FILTER (WHERE value_match)                    AS value_match,
       count(*) FILTER (WHERE validity_match)                 AS validity_match,
       count(*) FILTER (WHERE value_match AND validity_match) AS both_match
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F1';
SELECT * FROM t_f1_accuracy;

\echo
\echo '== 19. Examples: EC-021 (delegation), EC-027 (template C), EC-047 (epoch, WARN, trailing clauses), run B =='
SELECT e.case_id, f.field_name, f.value, f.validity, f.start_pos, f.missing_reason, f.slot_id, f.rule_id
FROM log_regex.parsed_field f
JOIN log_regex.expected_fields e ON e.log_id = f.log_id
JOIN log_regex.ref_field rf ON rf.field_name = f.field_name
WHERE f.run_id = :run_b AND e.case_id IN ('EC-021', 'EC-027', 'EC-047')
ORDER BY e.case_id, rf.field_order;

SELECT e.case_id, s.field_name, s.kind, s.value, s.start_pos
FROM log_regex.parsed_secondary s
JOIN log_regex.expected_fields e ON e.log_id = s.log_id
WHERE s.run_id = :run_b AND e.case_id IN ('EC-021', 'EC-047', 'EC-062', 'EC-095')
ORDER BY e.case_id, s.start_pos;

\echo
\echo '== 20. Determinism, raw integrity after parsing, and verdict =='
CREATE TEMP TABLE t_determinism AS
SELECT
    (SELECT count(*) FROM (
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics FROM log_regex.parsed_log WHERE run_id = :run_a)
        EXCEPT
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics FROM log_regex.parsed_log WHERE run_id = :run_b)) x)       AS parsed_log_diff,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_a)
        EXCEPT
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_b)) x)                                           AS parsed_field_diff,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, kind, value, start_pos FROM log_regex.parsed_secondary WHERE run_id = :run_a)
        EXCEPT
        (SELECT log_id, field_name, kind, value, start_pos FROM log_regex.parsed_secondary WHERE run_id = :run_b)) x) AS parsed_secondary_diff,
    (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_a)
        - (SELECT count(*) FROM log_regex.parsed_field WHERE run_id = :run_b)                              AS field_row_count_diff;
SELECT * FROM t_determinism;

SELECT count(*) FILTER (WHERE passed) AS raw_checks_passed, count(*) AS raw_checks_total
FROM log_regex.verify_raw_access_logs();

DO $$
DECLARE
    d  record;
    s  record;
    o  record;
    t  record;
    g  record;
    fa record;
    a  record;
    raw_failures      integer;
    overlap_pairs     integer;
    from_rows         integer;
    from_ip_in_phrase integer;
    regression_diffs  bigint;
BEGIN
    SELECT * INTO d  FROM t_detection;
    SELECT * INTO s  FROM t_shape;
    SELECT * INTO o  FROM t_offsets;
    SELECT * INTO t  FROM t_determinism;
    SELECT * INTO g  FROM t_regression;
    SELECT * INTO fa FROM t_f1_accuracy;
    SELECT sum(rows) AS rows, sum(both_match) AS both_match INTO a FROM t_accuracy;
    SELECT overlapping_pairs INTO overlap_pairs FROM t_overlap;
    SELECT count(*), count(*) FILTER (WHERE ip_pos BETWEEN action_pos AND action_pos + char_length(parsed_action) - 1)
      INTO from_rows, from_ip_in_phrase
    FROM t_from_phrase;
    SELECT count(*) INTO raw_failures FROM log_regex.verify_raw_access_logs() WHERE NOT passed;
    regression_diffs := g.parsed_log_only_baseline + g.parsed_log_only_current + g.parsed_field_only_baseline
                        + g.parsed_field_only_current + g.secondary_only_baseline + g.secondary_only_current;

    IF raw_failures > 0
       OR d.f1_false_positive + d.f1_false_negative + d.f2_false_positive + d.f2_false_negative + d.det00_not_none > 0
       OR s.parsed_log_rows <> 5000 OR s.raw_rows_without_parsed_log > 0 OR s.parsed_logs_without_10_fields > 0
       OR o.field_values <> o.field_values_exact OR o.secondary_values <> o.secondary_values_exact
       OR overlap_pairs > 0
       OR from_ip_in_phrase > 0
       OR t.parsed_log_diff + t.parsed_field_diff + t.parsed_secondary_diff + abs(t.field_row_count_diff) > 0 THEN
        RAISE EXCEPTION 'Step 3B-4 invariant FAILED (raw %, detection F1 %/% F2 %/% DET-00 %, shape %/%/%, offsets %/% %/%, overlap_pairs %, from-in-phrase %, determinism %/%/%/%)',
            raw_failures, d.f1_false_positive, d.f1_false_negative, d.f2_false_positive, d.f2_false_negative,
            d.det00_not_none, s.parsed_log_rows, s.raw_rows_without_parsed_log, s.parsed_logs_without_10_fields,
            o.field_values_exact, o.field_values, o.secondary_values_exact, o.secondary_values, overlap_pairs,
            from_ip_in_phrase, t.parsed_log_diff, t.parsed_field_diff, t.parsed_secondary_diff, t.field_row_count_diff;
    END IF;

    IF g.baseline_run = 0 THEN
        RAISE NOTICE 'F1 regression SKIPPED: parser_run has no successful run with formats {F1}';
    ELSIF regression_diffs > 0 OR g.baseline_f1_field_rows <> g.current_f1_field_rows THEN
        RAISE EXCEPTION 'F1 regression FAILED against run %: % differing rows (field rows % vs %)',
            g.baseline_run, regression_diffs, g.baseline_f1_field_rows, g.current_f1_field_rows;
    ELSE
        RAISE NOTICE 'F1 regression PASSED: % F1 logs identical to baseline run % (parsed_log, parsed_field, parsed_secondary)',
            g.f1_logs_compared, g.baseline_run;
    END IF;

    IF fa.both_match <> fa.rows THEN
        RAISE EXCEPTION 'F1 accuracy changed: % / % field values match the answer key', fa.both_match, fa.rows;
    END IF;

    RAISE NOTICE 'Invariants PASSED: raw input unchanged, F1/F2 detection exact, 5000 parsed_log rows, exact offsets, no overlapping F2 spans, no IP taken from inside % "from" phrases, deterministic',
        from_rows;
    RAISE NOTICE 'F1 acceptance unchanged: % / % field values match the answer key', fa.both_match, fa.rows;
    IF a.both_match = a.rows THEN
        RAISE NOTICE 'F2 acceptance (C-05) PASS: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    ELSE
        RAISE NOTICE 'F2 acceptance (C-05) FAIL: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    END IF;
END
$$;
