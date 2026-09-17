-- =============================================================================
-- Step 3B-3 / 12 - Test the F1 parser against the answer key
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/12_test_f1_parser.sql
--
-- Runs the parser twice (determinism), then reports detection, output shape, offsets, per-field
-- accuracy on all F1 rows, validity distributions, curated vs generated, record validity,
-- mismatches, secondary values, diagnostics and raw-input integrity.
-- Exits non-zero only if an invariant fails (raw integrity, offsets, shape, determinism, detection).
-- The acceptance verdict (C-05: 100% value and validity) is printed in section 14.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\echo
\echo '== 1. Raw input integrity before parsing =='
SELECT count(*) FILTER (WHERE passed) AS checks_passed, count(*) AS checks_total
FROM log_regex.verify_raw_access_logs();

\echo
\echo '== 2. Parser runs (run A and run B, identical inputs) =='
SELECT log_regex.run_parser('3B-3 F1 v1') AS run_a \gset
SELECT log_regex.run_parser('3B-3 F1 v1') AS run_b \gset
SELECT run_id, parser_version, reference_data_version, formats_implemented, assumed_year, raw_row_count,
       fingerprint_check_before, fingerprint_check_after, status,
       round(extract(epoch FROM finished_at - started_at)::numeric, 2) AS seconds
FROM log_regex.parser_run
WHERE run_id IN (:run_a, :run_b)
ORDER BY run_id;

\echo
\echo '== 3. Detection against the answer key (all 5,000 rows, run B) =='
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
SELECT count(*) FILTER (WHERE e.format_family = 'F1' AND l.format_family = 'F1')                    AS f1_true_positive,
       count(*) FILTER (WHERE e.format_family <> 'F1' AND l.format_family = 'F1')                   AS f1_false_positive,
       count(*) FILTER (WHERE e.format_family = 'F1' AND l.format_family IS DISTINCT FROM 'F1')     AS f1_false_negative,
       count(*) FILTER (WHERE l.detection_rule = 'DET-00' AND e.format_family <> 'NONE')            AS det00_not_none
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b;
SELECT * FROM t_detection;

\echo
\echo '== 4. Output shape (run B) =='
CREATE TEMP TABLE t_shape AS
SELECT (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b)                                   AS parsed_log_rows,
       (SELECT count(*) FROM log_regex.raw_access_logs r
        WHERE NOT EXISTS (SELECT 1 FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.log_id = r.log_id)) AS raw_rows_without_parsed_log,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F1')              AS f1_logs,
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
\echo '== 5. Exact substrings at recorded positions (run B) =='
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
\echo '== 6. Per-field accuracy on all answer-key F1 rows (latest run) =='
CREATE TEMP TABLE t_accuracy AS
SELECT field_order,
       field_name,
       count(*)                                                    AS rows,
       count(*) FILTER (WHERE value_match)                         AS value_match,
       count(*) FILTER (WHERE validity_match)                      AS validity_match,
       count(*) FILTER (WHERE value_match AND validity_match)      AS both_match,
       round(100.0 * count(*) FILTER (WHERE value_match AND validity_match) / count(*), 2) AS pct
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F1'
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
\echo '== 7. Validity distribution on F1 rows: answer key vs parser =='
SELECT c.field_name,
       v.validity,
       count(*) FILTER (WHERE c.expected_validity = v.validity) AS expected,
       count(*) FILTER (WHERE c.parsed_validity   = v.validity) AS parsed
FROM log_regex.v_parser_field_comparison c
CROSS JOIN (VALUES (1, 'VALID'), (2, 'INVALID'), (3, 'PLACEHOLDER'), (4, 'MISSING')) AS v (ord, validity)
WHERE c.expected_format = 'F1'
GROUP BY c.field_order, c.field_name, v.ord, v.validity
ORDER BY c.field_order, v.ord;

\echo
\echo '== 8. Curated vs generated F1 rows =='
SELECT source,
       count(DISTINCT log_id)                                                      AS logs,
       count(*)                                                                    AS field_values,
       count(*) FILTER (WHERE value_match AND validity_match)                      AS both_match,
       count(DISTINCT log_id) FILTER (WHERE NOT (value_match AND validity_match))  AS logs_with_mismatch
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F1'
GROUP BY source
ORDER BY source;

\echo
\echo '== 9. Record validity on F1 rows =='
SELECT e.record_validity AS expected, l.record_validity AS parsed, count(*) AS rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b AND e.format_family = 'F1'
GROUP BY 1, 2
ORDER BY 1, 2;

\echo
\echo '== 10. Mismatches on F1 rows (first 60) =='
SELECT case_id, log_id, field_name, expected_value, parsed_value, expected_validity, parsed_validity, rule_id, slot_id
FROM log_regex.v_parser_mismatches
WHERE expected_format = 'F1'
ORDER BY log_id, field_order
LIMIT 60;

\echo
\echo '== 11. Secondary values on F1 rows (informational; not part of C-05) =='
CREATE TEMP TABLE t_secondary AS
WITH parsed AS (
    SELECT l.log_id,
           (SELECT string_agg(k, ';' ORDER BY k)
            FROM (SELECT s.kind || '=' || s.value AS k
                  FROM log_regex.parsed_secondary s
                  WHERE s.run_id = l.run_id AND s.log_id = l.log_id) q) AS parsed_set
    FROM log_regex.parsed_log l
    WHERE l.run_id = :run_b AND l.format_family = 'F1'
),
expected AS (
    SELECT e.log_id, e.case_id,
           (SELECT string_agg(k, ';' ORDER BY k) FROM unnest(string_to_array(e.secondary_values, ';')) AS k) AS expected_set
    FROM log_regex.expected_fields e
    WHERE e.format_family = 'F1'
)
SELECT x.log_id, x.case_id, x.expected_set, p.parsed_set, x.expected_set IS NOT DISTINCT FROM p.parsed_set AS same
FROM expected x
JOIN parsed p USING (log_id);

SELECT count(*) AS f1_logs,
       count(*) FILTER (WHERE same) AS same_secondary_set,
       count(*) FILTER (WHERE NOT same) AS different
FROM t_secondary;
SELECT case_id, log_id, expected_set, parsed_set FROM t_secondary WHERE NOT same ORDER BY log_id;

\echo
\echo '== 12. Diagnostics on F1 rows (run B) =='
SELECT d.code, count(*) AS logs, string_agg(e.case_id, ', ' ORDER BY e.log_id) FILTER (WHERE e.source = 'curated') AS curated_cases
FROM log_regex.parsed_log l
CROSS JOIN LATERAL unnest(l.diagnostics) AS d (code)
JOIN log_regex.expected_fields e ON e.log_id = l.log_id
WHERE l.run_id = :run_b AND l.format_family = 'F1'
GROUP BY d.code
ORDER BY d.code;

SELECT sub_format, count(*) AS logs FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F1' GROUP BY 1 ORDER BY 1;

\echo
\echo '== 13. Examples: EC-127 (reason split, shuffled keys) and EC-134 (C-06 truncation), run B =='
SELECT e.case_id, f.field_name, f.value, f.validity, f.start_pos, f.missing_reason, f.slot_id, f.rule_id
FROM log_regex.parsed_field f
JOIN log_regex.expected_fields e ON e.log_id = f.log_id
JOIN log_regex.ref_field rf ON rf.field_name = f.field_name
WHERE f.run_id = :run_b AND e.case_id IN ('EC-127', 'EC-134')
ORDER BY e.case_id, rf.field_order;

\echo
\echo '== 14. Determinism, raw integrity after parsing, and verdict =='
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
    a  record;
    raw_failures integer;
BEGIN
    SELECT * INTO d FROM t_detection;
    SELECT * INTO s FROM t_shape;
    SELECT * INTO o FROM t_offsets;
    SELECT * INTO t FROM t_determinism;
    SELECT sum(rows) AS rows, sum(both_match) AS both_match INTO a FROM t_accuracy;
    SELECT count(*) INTO raw_failures FROM log_regex.verify_raw_access_logs() WHERE NOT passed;

    IF raw_failures > 0
       OR d.f1_false_positive + d.f1_false_negative + d.det00_not_none > 0
       OR s.parsed_log_rows <> 5000 OR s.raw_rows_without_parsed_log > 0 OR s.parsed_logs_without_10_fields > 0
       OR o.field_values <> o.field_values_exact OR o.secondary_values <> o.secondary_values_exact
       OR t.parsed_log_diff + t.parsed_field_diff + t.parsed_secondary_diff + abs(t.field_row_count_diff) > 0 THEN
        RAISE EXCEPTION 'Step 3B-3 invariant FAILED (raw %, detection %/%/%, shape %/%/%, offsets %/% %/%, determinism %/%/%/%)',
            raw_failures, d.f1_false_positive, d.f1_false_negative, d.det00_not_none,
            s.parsed_log_rows, s.raw_rows_without_parsed_log, s.parsed_logs_without_10_fields,
            o.field_values_exact, o.field_values, o.secondary_values_exact, o.secondary_values,
            t.parsed_log_diff, t.parsed_field_diff, t.parsed_secondary_diff, t.field_row_count_diff;
    END IF;

    RAISE NOTICE 'Invariants PASSED: raw input unchanged, F1 detection exact, 5000 parsed_log rows, exact offsets, deterministic';
    IF a.both_match = a.rows THEN
        RAISE NOTICE 'F1 acceptance (C-05) PASS: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    ELSE
        RAISE NOTICE 'F1 acceptance (C-05) FAIL: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    END IF;
END
$$;
