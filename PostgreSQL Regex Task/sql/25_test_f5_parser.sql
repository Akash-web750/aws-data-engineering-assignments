-- =============================================================================
-- Step 3B-7 / 25 - Test the F5 parser against the answer key (and F1 - F4 against the Step 3B-6 run)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/25_test_f5_parser.sql
--
-- Runs the F1-F5 parser twice (determinism), then reports detection (incl. DET-F5 false positives, the 9-semicolon
-- header row and near-F5 rows), output shape, offsets, F5 per-field accuracy, validity distribution, accuracy by
-- column-1 timestamp shape and source, record validity, mismatches, secondary values, diagnostics, the column map
-- and line reconstruction, special values (DMS quotes, placeholders, backslashes, non-ASCII), coordinate columns,
-- truncated and invalid rows, whole-line probes, non-overlapping spans, the F1-F4 regression against the latest
-- {F1,F2,F3,F4} run, examples, determinism and raw-input integrity.
-- Exits non-zero only if an invariant fails. The F5 acceptance verdict (C-05) is printed in section 22.
-- Combined all-format validation is not part of this step.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\echo
\echo '== 1. Raw input integrity before parsing =='
SELECT count(*) FILTER (WHERE passed) AS checks_passed, count(*) AS checks_total
FROM log_regex.verify_raw_access_logs();

\echo
\echo '== 2. F1 - F4 regression baseline: latest successful run with formats {F1,F2,F3,F4} (Step 3B-6) =='
SELECT coalesce(max(run_id), 0) AS baseline_run
FROM log_regex.parser_run
WHERE status = 'succeeded' AND formats_implemented = ARRAY['F1', 'F2', 'F3', 'F4'] \gset
SELECT :baseline_run AS baseline_run,
       (SELECT parser_version FROM log_regex.parser_run WHERE run_id = :baseline_run)         AS parser_version,
       (SELECT reference_data_version FROM log_regex.parser_run WHERE run_id = :baseline_run) AS reference_data_version,
       (SELECT formats_implemented FROM log_regex.parser_run WHERE run_id = :baseline_run)    AS formats_implemented;

\echo
\echo '== 3. Parser runs (run A and run B, identical inputs) =='
SELECT log_regex.run_parser('3B-7 F1-F5 v1') AS run_a \gset
SELECT log_regex.run_parser('3B-7 F1-F5 v1') AS run_b \gset
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
SELECT f.fmt,
       count(*) FILTER (WHERE e.format_family = f.fmt AND l.format_family = f.fmt)                AS true_positive,
       count(*) FILTER (WHERE e.format_family <> f.fmt AND l.format_family = f.fmt)               AS false_positive,
       count(*) FILTER (WHERE e.format_family = f.fmt AND l.format_family IS DISTINCT FROM f.fmt) AS false_negative
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
CROSS JOIN (VALUES ('F1'), ('F2'), ('F3'), ('F4'), ('F5')) AS f (fmt)
WHERE l.run_id = :run_b
GROUP BY f.fmt;
SELECT * FROM t_detection ORDER BY fmt;

CREATE TEMP TABLE t_detection_other AS
SELECT count(*) FILTER (WHERE l.detection_rule = 'DET-00' AND e.format_family <> 'NONE') AS det00_not_none,
       count(*) FILTER (WHERE cardinality(l.format_candidates) > 1)                     AS format_conflicts
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b;
SELECT * FROM t_detection_other;

\echo 'Rows with exactly 9 semicolons on the event line (F5 needs a timestamp shape in column 1)'
CREATE TEMP TABLE t_nine AS
SELECT e.case_id,
       e.format_family                                                        AS expected_format,
       coalesce(l.format_family, '(deferred)')                                AS parsed_format,
       split_part(left(r.raw_log, log_regex.line_event_end(r.raw_log)), ';', 1) AS column_1,
       EXISTS (SELECT 1 FROM log_regex.ref_timestamp_shape s
               WHERE split_part(left(r.raw_log, log_regex.line_event_end(r.raw_log)), ';', 1) ~ s.pattern) AS column_1_is_timestamp
FROM log_regex.parsed_log l
JOIN log_regex.raw_access_logs r USING (log_id)
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b
  AND r.raw_log IS NOT NULL
  AND regexp_count(left(r.raw_log, log_regex.line_event_end(r.raw_log)), ';') = 9;
SELECT expected_format, parsed_format, column_1_is_timestamp, count(*) AS rows,
       string_agg(case_id || ' ' || column_1, ', ') FILTER (WHERE NOT column_1_is_timestamp) AS non_timestamp_rows
FROM t_nine
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

\echo 'Near-F5 rows: timestamp-shaped column 1 but a semicolon count other than 9 (a truncated or padded F5 row would appear here)'
CREATE TEMP TABLE t_near_f5 AS
SELECT e.case_id, e.format_family AS expected_format, coalesce(l.format_family, '(deferred)') AS parsed_format,
       regexp_count(left(r.raw_log, log_regex.line_event_end(r.raw_log)), ';') AS semicolons
FROM log_regex.parsed_log l
JOIN log_regex.raw_access_logs r USING (log_id)
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b
  AND r.raw_log IS NOT NULL
  AND regexp_count(left(r.raw_log, log_regex.line_event_end(r.raw_log)), ';') NOT IN (0, 9)
  AND EXISTS (SELECT 1 FROM log_regex.ref_timestamp_shape s
              WHERE split_part(left(r.raw_log, log_regex.line_event_end(r.raw_log)), ';', 1) ~ s.pattern);
SELECT count(*) AS near_f5_rows FROM t_near_f5;
SELECT * FROM t_near_f5 ORDER BY case_id LIMIT 10;

\echo
\echo '== 5. Output shape (run B) =='
CREATE TEMP TABLE t_shape AS
SELECT (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b)                                   AS parsed_log_rows,
       (SELECT count(*) FROM log_regex.raw_access_logs r
        WHERE NOT EXISTS (SELECT 1 FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.log_id = r.log_id)) AS raw_rows_without_parsed_log,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F5')              AS f5_logs,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family IN ('F1', 'F2', 'F3', 'F4')) AS f1_to_f4_logs,
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
\echo '== 7. Per-field accuracy on all answer-key F5 rows (latest run) =='
CREATE TEMP TABLE t_accuracy AS
SELECT field_order,
       field_name,
       count(*)                                                    AS rows,
       count(*) FILTER (WHERE value_match)                         AS value_match,
       count(*) FILTER (WHERE validity_match)                      AS validity_match,
       count(*) FILTER (WHERE value_match AND validity_match)      AS both_match,
       round(100.0 * count(*) FILTER (WHERE value_match AND validity_match) / count(*), 2) AS pct
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F5'
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
\echo '== 8. Validity distribution on F5 rows: answer key vs parser =='
SELECT c.field_name,
       v.validity,
       count(*) FILTER (WHERE c.expected_validity = v.validity) AS expected,
       count(*) FILTER (WHERE c.parsed_validity   = v.validity) AS parsed
FROM log_regex.v_parser_field_comparison c
CROSS JOIN (VALUES (1, 'VALID'), (2, 'INVALID'), (3, 'PLACEHOLDER'), (4, 'MISSING')) AS v (ord, validity)
WHERE c.expected_format = 'F5'
GROUP BY c.field_order, c.field_name, v.ord, v.validity
ORDER BY c.field_order, v.ord;

SELECT c.field_name, c.parsed_validity, c.missing_reason, c.rule_id, count(*) AS rows
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F5' AND c.parsed_validity IN ('MISSING', 'PLACEHOLDER')
GROUP BY c.field_order, c.field_name, c.parsed_validity, c.missing_reason, c.rule_id
ORDER BY c.field_order, c.parsed_validity;

\echo
\echo '== 9. F5 accuracy by column-1 timestamp shape (sub_format) and by source =='
SELECT l.sub_format,
       count(DISTINCT c.log_id)                                                         AS logs,
       count(*)                                                                         AS field_values,
       count(*) FILTER (WHERE c.value_match AND c.validity_match)                       AS both_match,
       count(DISTINCT c.log_id) FILTER (WHERE NOT (c.value_match AND c.validity_match)) AS logs_with_mismatch
FROM log_regex.v_parser_field_comparison c
JOIN log_regex.parsed_log l ON l.run_id = c.run_id AND l.log_id = c.log_id
WHERE c.expected_format = 'F5'
GROUP BY l.sub_format
ORDER BY l.sub_format;

SELECT source,
       count(DISTINCT log_id)                                                      AS logs,
       count(*)                                                                    AS field_values,
       count(*) FILTER (WHERE value_match AND validity_match)                      AS both_match,
       count(DISTINCT log_id) FILTER (WHERE NOT (value_match AND validity_match))  AS logs_with_mismatch
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F5'
GROUP BY source
ORDER BY source;

\echo
\echo '== 10. Record validity and truncation on F5 rows =='
SELECT e.record_validity AS expected, l.record_validity AS parsed, l.is_truncated, count(*) AS rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b AND e.format_family = 'F5'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

\echo
\echo '== 11. Mismatches on F5 rows (first 60) =='
SELECT case_id, log_id, field_name, expected_value, parsed_value, expected_validity, parsed_validity, rule_id, slot_id
FROM log_regex.v_parser_mismatches
WHERE expected_format = 'F5'
ORDER BY log_id, field_order
LIMIT 60;

\echo
\echo '== 12. Secondary values on F5 rows (informational; not part of C-05) =='
CREATE TEMP TABLE t_secondary AS
WITH parsed AS (
    SELECT l.log_id,
           (SELECT string_agg(k, ';' ORDER BY k)
            FROM (SELECT s.kind || '=' || s.value AS k
                  FROM log_regex.parsed_secondary s
                  WHERE s.run_id = l.run_id AND s.log_id = l.log_id) q) AS parsed_set
    FROM log_regex.parsed_log l
    WHERE l.run_id = :run_b AND l.format_family = 'F5'
),
expected AS (
    SELECT e.log_id, e.case_id,
           (SELECT string_agg(k, ';' ORDER BY k) FROM unnest(string_to_array(e.secondary_values, ';')) AS k) AS expected_set
    FROM log_regex.expected_fields e
    WHERE e.format_family = 'F5'
)
SELECT x.log_id, x.case_id, x.expected_set, p.parsed_set, x.expected_set IS NOT DISTINCT FROM p.parsed_set AS same
FROM expected x
JOIN parsed p USING (log_id);

SELECT count(*) AS f5_logs,
       count(*) FILTER (WHERE same) AS same_secondary_set,
       count(*) FILTER (WHERE NOT same) AS different
FROM t_secondary;
SELECT case_id, log_id, expected_set, parsed_set FROM t_secondary WHERE NOT same ORDER BY log_id LIMIT 30;

SELECT s.kind, count(*) AS values
FROM log_regex.parsed_secondary s
JOIN log_regex.parsed_log l ON l.run_id = s.run_id AND l.log_id = s.log_id
WHERE s.run_id = :run_b AND l.format_family = 'F5'
GROUP BY s.kind
ORDER BY s.kind;

\echo
\echo '== 13. Diagnostics and column-1 timestamp shapes on F5 rows (run B) =='
SELECT d.code, count(*) AS logs
FROM log_regex.parsed_log l
CROSS JOIN LATERAL unnest(l.diagnostics) AS d (code)
WHERE l.run_id = :run_b AND l.format_family = 'F5'
GROUP BY d.code
ORDER BY d.code;

SELECT sub_format, count(*) AS logs FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F5' GROUP BY 1 ORDER BY 1;

\echo
\echo '== 14. Ten positional columns: column map and line reconstruction (run B) =='
CREATE TEMP TABLE t_f5_logs AS
SELECT l.log_id, e.case_id, r.raw_log, left(r.raw_log, log_regex.line_event_end(r.raw_log)) AS event_line,
       l.sub_format, l.is_truncated
FROM log_regex.parsed_log l
JOIN log_regex.raw_access_logs r ON r.log_id = l.log_id
JOIN log_regex.expected_fields e ON e.log_id = l.log_id
WHERE l.run_id = :run_b AND l.format_family = 'F5';

SELECT substring(f.slot_id FROM '\[([0-9]+)\]')::integer AS column_no,
       f.field_name,
       k.field_name AS step3a_field,
       count(*) AS rows,
       count(*) FILTER (WHERE f.value IS NOT NULL) AS values_present
FROM t_f5_logs t
JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = t.log_id
LEFT JOIN log_regex.ref_key_alias k ON k.format_family = 'F5' AND k.key_name = substring(f.slot_id FROM '\[([0-9]+)\]')
GROUP BY 1, 2, 3
ORDER BY 1;

CREATE TEMP TABLE t_columns AS
SELECT t.log_id,
       t.event_line,
       count(*) FILTER (WHERE f.slot_id ~ '^F5[.]column\[[0-9]+\]$')                                     AS column_slots,
       string_agg(coalesce(f.value, ''), ';' ORDER BY substring(f.slot_id FROM '\[([0-9]+)\]')::integer) AS rebuilt_line,
       bool_and(f.value IS NULL
                OR f.value = split_part(t.event_line, ';', substring(f.slot_id FROM '\[([0-9]+)\]')::integer)) AS values_equal_columns,
       bool_and(f.value IS NOT NULL
                OR split_part(t.event_line, ';', substring(f.slot_id FROM '\[([0-9]+)\]')::integer) ~ '^[[:space:]]*$') AS missing_only_when_empty
FROM t_f5_logs t
JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = t.log_id
GROUP BY t.log_id, t.event_line;

CREATE TEMP TABLE t_column_check AS
SELECT count(*)                                              AS f5_logs,
       count(*) FILTER (WHERE column_slots = 10)             AS logs_with_10_column_slots,
       count(*) FILTER (WHERE rebuilt_line = event_line)     AS lines_rebuilt_exactly,
       count(*) FILTER (WHERE values_equal_columns)          AS logs_values_equal_columns,
       count(*) FILTER (WHERE missing_only_when_empty)       AS logs_missing_only_when_empty
FROM t_columns;
SELECT * FROM t_column_check;

\echo
\echo '== 15. Quoted and special values on F5 rows (run B) =='
SELECT special_value, field_name, values, both_match
FROM (
SELECT CASE
           WHEN c.parsed_value ~ '"'                            THEN 'contains a double quote (DMS arc-seconds)'
           WHEN strpos(c.parsed_value, chr(92)) > 0             THEN 'contains a backslash (Windows / UNC path)'
           WHEN octet_length(c.parsed_value) <> char_length(c.parsed_value) THEN 'contains non-ASCII characters'
           WHEN c.parsed_validity = 'PLACEHOLDER'               THEN 'placeholder ' || c.parsed_value
           WHEN c.parsed_validity = 'MISSING'                   THEN 'empty column'
           ELSE NULL
       END AS special_value,
       c.field_order,
       c.field_name,
       count(*)                                                   AS values,
       count(*) FILTER (WHERE c.value_match AND c.validity_match) AS both_match
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F5'
GROUP BY 1, c.field_order, c.field_name
) x
WHERE special_value IS NOT NULL
ORDER BY special_value, field_order;

\echo
\echo '== 16. Coordinate columns (C-03: column 6 = latitude, column 7 = longitude; never reordered) =='
SELECT c.field_name,
       CASE
           WHEN c.parsed_value IS NULL                            THEN '5 empty'
           WHEN c.parsed_validity = 'PLACEHOLDER'                 THEN '6 placeholder'
           WHEN c.parsed_value ~ '\u00B0'                         THEN '4 DMS'
           WHEN c.parsed_value ~ '^[NSEW]'                        THEN '3 hemisphere prefix'
           WHEN c.parsed_value ~ ' [NSEW]$'                       THEN '2 hemisphere suffix'
           ELSE '1 decimal'
       END AS notation,
       count(*)                                                   AS values,
       count(*) FILTER (WHERE c.value_match AND c.validity_match) AS both_match,
       count(*) FILTER (WHERE c.parsed_validity = 'INVALID')      AS invalid,
       min(c.slot_id)                                             AS slot
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F5' AND c.field_name IN ('latitude', 'longitude')
GROUP BY c.field_order, c.field_name, 2
ORDER BY c.field_order, 2;

\echo
\echo '== 17. Truncated and invalid F5 rows (Step 3A 10.3: truncation not observed for F5) =='
SELECT count(*) FILTER (WHERE is_truncated) AS truncated_f5_logs, count(*) AS f5_logs FROM t_f5_logs;

SELECT c.field_name, count(*) AS invalid_values, count(*) FILTER (WHERE c.value_match AND c.validity_match) AS both_match,
       string_agg(DISTINCT c.case_id, ', ') FILTER (WHERE c.case_id LIKE 'EC-%') AS curated_cases
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F5' AND c.parsed_validity = 'INVALID'
GROUP BY c.field_order, c.field_name
ORDER BY c.field_order;

\echo
\echo '== 18. Whole-line first-match probes vs the column map on F5 rows (informational) =='
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
    (1, 'email_address', 'first token containing @',              e.email_address,
        regexp_substr(r.raw_log, '[^; ]*@[^; ]*')),
    (2, 'ip_address',    'first dotted quad anywhere',             e.ip_address,
        regexp_substr(r.raw_log, '[0-9]{1,3}([.][0-9]{1,3}){3}')),
    (3, 'resource_url',  'first http(s) URL anywhere',             e.resource_url,
        regexp_substr(r.raw_log, 'https?://[^;]+')),
    (4, 'latitude',      'first decimal number anywhere',          e.latitude,
        regexp_substr(r.raw_log, '-?[0-9]+[.][0-9]+')),
    (5, 'status',        'last word of the line',                  e.status,
        regexp_substr(r.raw_log, '[A-Za-z_]+$'))
) AS x (probe_order, field_name, probe, expected_value, naive_value)
JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = e.log_id AND f.field_name = x.field_name
WHERE e.format_family = 'F5';

SELECT field_name,
       probe,
       count(*)                                                                    AS rows,
       count(*) FILTER (WHERE naive_value  IS NOT DISTINCT FROM expected_value)    AS naive_correct,
       count(*) FILTER (WHERE parser_value IS NOT DISTINCT FROM expected_value)    AS parser_correct
FROM t_naive
GROUP BY probe_order, field_name, probe
ORDER BY probe_order;

SELECT DISTINCT ON (probe_order) probe, case_id, log_id, left(expected_value, 45) AS expected_value,
       left(naive_value, 45) AS naive_value, left(parser_value, 45) AS parser_value
FROM t_naive
WHERE naive_value IS DISTINCT FROM expected_value
ORDER BY probe_order, (case_id LIKE 'EC-%') DESC, log_id;

\echo
\echo '== 19. Non-overlapping field spans on F5 rows (run B) =='
CREATE TEMP TABLE t_overlap AS
SELECT count(*) AS overlapping_pairs
FROM log_regex.parsed_field a
JOIN log_regex.parsed_field b ON b.run_id = a.run_id AND b.log_id = a.log_id AND a.field_name < b.field_name
JOIN log_regex.parsed_log l   ON l.run_id = a.run_id AND l.log_id = a.log_id
WHERE a.run_id = :run_b
  AND l.format_family = 'F5'
  AND a.value IS NOT NULL
  AND b.value IS NOT NULL
  AND a.start_pos < b.start_pos + char_length(b.value)
  AND b.start_pos < a.start_pos + char_length(a.value);
SELECT * FROM t_overlap;

\echo
\echo '== 20. F1 - F4 regression: run B vs the Step 3B-6 baseline run, F1-F4 rows only =='
CREATE TEMP TABLE t_prev_logs AS
SELECT DISTINCT log_id
FROM log_regex.parsed_log
WHERE run_id IN (:baseline_run, :run_b) AND format_family IN ('F1', 'F2', 'F3', 'F4');

CREATE TEMP TABLE t_regression AS
SELECT :baseline_run::bigint AS baseline_run,
    (SELECT count(*) FROM t_prev_logs) AS logs_compared,
    (SELECT count(*) FROM (
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_prev_logs))
        EXCEPT
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_prev_logs))) x) AS parsed_log_only_baseline,
    (SELECT count(*) FROM (
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_prev_logs))
        EXCEPT
        (SELECT log_id, format_family, detection_rule, format_candidates, sub_format, event_end_pos, is_truncated,
                record_validity, diagnostics
         FROM log_regex.parsed_log WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_prev_logs))) x) AS parsed_log_only_current,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_prev_logs))
        EXCEPT
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_prev_logs))) x) AS parsed_field_only_baseline,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_prev_logs))
        EXCEPT
        (SELECT log_id, field_name, value, validity, start_pos, missing_reason, slot_id, rule_id, candidate_count
         FROM log_regex.parsed_field WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_prev_logs))) x) AS parsed_field_only_current,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_prev_logs))
        EXCEPT
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_prev_logs))) x) AS secondary_only_baseline,
    (SELECT count(*) FROM (
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_prev_logs))
        EXCEPT
        (SELECT log_id, field_name, kind, value, start_pos
         FROM log_regex.parsed_secondary WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_prev_logs))) x) AS secondary_only_current,
    (SELECT count(*) FROM log_regex.parsed_field
     WHERE run_id = :baseline_run AND log_id IN (SELECT log_id FROM t_prev_logs))                         AS baseline_field_rows,
    (SELECT count(*) FROM log_regex.parsed_field
     WHERE run_id = :run_b AND log_id IN (SELECT log_id FROM t_prev_logs))                                AS current_field_rows;
SELECT * FROM t_regression;

CREATE TEMP TABLE t_prev_accuracy AS
SELECT expected_format,
       count(*)                                               AS rows,
       count(*) FILTER (WHERE value_match AND validity_match) AS both_match
FROM log_regex.v_parser_field_comparison
WHERE expected_format IN ('F1', 'F2', 'F3', 'F4')
GROUP BY expected_format;
SELECT * FROM t_prev_accuracy ORDER BY expected_format;

\echo
\echo '== 21. Examples: EC-007 (empty columns, IP in resource), EC-034 (UNC path), EC-083 (DMS), EC-105 (IP placeholder), run B =='
SELECT e.case_id, f.field_name, f.value, f.validity, f.start_pos, f.missing_reason, f.slot_id, f.rule_id
FROM log_regex.parsed_field f
JOIN log_regex.expected_fields e ON e.log_id = f.log_id
JOIN log_regex.ref_field rf ON rf.field_name = f.field_name
WHERE f.run_id = :run_b AND e.case_id IN ('EC-007', 'EC-034', 'EC-083', 'EC-105')
ORDER BY e.case_id, substring(f.slot_id FROM '\[([0-9]+)\]')::integer;

SELECT e.case_id, s.field_name, s.kind, s.value, s.start_pos
FROM log_regex.parsed_secondary s
JOIN log_regex.expected_fields e ON e.log_id = s.log_id
WHERE s.run_id = :run_b AND e.case_id IN ('EC-007')
ORDER BY e.case_id, s.start_pos;

\echo
\echo '== 22. Determinism, raw integrity after parsing, and verdict =='
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
    dox  record;
    s    record;
    o    record;
    cc   record;
    t    record;
    g    record;
    a    record;
    detection_errors  bigint;
    header_as_f5      bigint;
    near_f5           bigint;
    raw_failures      integer;
    overlap_pairs     integer;
    prev_rows         bigint;
    prev_match        bigint;
    prev_summary      text;
    regression_diffs  bigint;
BEGIN
    SELECT sum(false_positive + false_negative) INTO detection_errors FROM t_detection;
    SELECT count(*) INTO header_as_f5 FROM t_nine WHERE NOT column_1_is_timestamp AND parsed_format = 'F5';
    SELECT count(*) INTO near_f5 FROM t_near_f5 WHERE expected_format = 'F5';
    SELECT * INTO dox FROM t_detection_other;
    SELECT * INTO s   FROM t_shape;
    SELECT * INTO o   FROM t_offsets;
    SELECT * INTO cc  FROM t_column_check;
    SELECT * INTO t   FROM t_determinism;
    SELECT * INTO g   FROM t_regression;
    SELECT sum(rows) AS rows, sum(both_match) AS both_match INTO a FROM t_accuracy;
    SELECT t_overlap.overlapping_pairs INTO overlap_pairs FROM t_overlap;
    SELECT sum(rows), sum(both_match), string_agg(expected_format || ' ' || both_match || ' / ' || rows, ', ' ORDER BY expected_format)
      INTO prev_rows, prev_match, prev_summary
    FROM t_prev_accuracy;
    SELECT count(*) INTO raw_failures FROM log_regex.verify_raw_access_logs() WHERE NOT passed;
    regression_diffs := g.parsed_log_only_baseline + g.parsed_log_only_current + g.parsed_field_only_baseline
                        + g.parsed_field_only_current + g.secondary_only_baseline + g.secondary_only_current;

    IF raw_failures > 0
       OR detection_errors + dox.det00_not_none + dox.format_conflicts + header_as_f5 + near_f5 > 0
       OR s.parsed_log_rows <> 5000 OR s.raw_rows_without_parsed_log > 0 OR s.parsed_logs_without_10_fields > 0
       OR o.field_values <> o.field_values_exact OR o.secondary_values <> o.secondary_values_exact
       OR cc.f5_logs <> cc.logs_with_10_column_slots OR cc.f5_logs <> cc.lines_rebuilt_exactly
       OR cc.f5_logs <> cc.logs_values_equal_columns OR cc.f5_logs <> cc.logs_missing_only_when_empty
       OR overlap_pairs > 0
       OR t.parsed_log_diff + t.parsed_field_diff + t.parsed_secondary_diff + abs(t.field_row_count_diff) > 0 THEN
        RAISE EXCEPTION 'Step 3B-7 invariant FAILED (raw %, detection % DET-00 % conflicts % header % near-F5 %, shape %/%/%, offsets %/% %/%, columns %/%/%/%/%, overlaps %, determinism %/%/%/%)',
            raw_failures, detection_errors, dox.det00_not_none, dox.format_conflicts, header_as_f5, near_f5,
            s.parsed_log_rows, s.raw_rows_without_parsed_log, s.parsed_logs_without_10_fields,
            o.field_values_exact, o.field_values, o.secondary_values_exact, o.secondary_values,
            cc.f5_logs, cc.logs_with_10_column_slots, cc.lines_rebuilt_exactly, cc.logs_values_equal_columns,
            cc.logs_missing_only_when_empty, overlap_pairs,
            t.parsed_log_diff, t.parsed_field_diff, t.parsed_secondary_diff, t.field_row_count_diff;
    END IF;

    IF g.baseline_run = 0 THEN
        RAISE NOTICE 'F1 - F4 regression SKIPPED: parser_run has no successful run with formats {F1,F2,F3,F4}';
    ELSIF regression_diffs > 0 OR g.baseline_field_rows <> g.current_field_rows THEN
        RAISE EXCEPTION 'F1 - F4 regression FAILED against run %: % differing rows (field rows % vs %)',
            g.baseline_run, regression_diffs, g.baseline_field_rows, g.current_field_rows;
    ELSE
        RAISE NOTICE 'F1 - F4 regression PASSED: % logs identical to baseline run % (parsed_log, parsed_field, parsed_secondary)',
            g.logs_compared, g.baseline_run;
    END IF;

    IF prev_match <> prev_rows THEN
        RAISE EXCEPTION 'F1 - F4 accuracy changed: %', prev_summary;
    END IF;

    RAISE NOTICE 'Invariants PASSED: raw input unchanged, F1-F5 detection exact with no format conflicts (9-semicolon header not F5, no near-F5 rows), 5000 parsed_log rows, exact offsets, every F5 line rebuilt exactly from its 10 columns, no overlapping F5 spans, deterministic';
    RAISE NOTICE 'F1 - F4 acceptance unchanged: %', prev_summary;
    IF a.both_match = a.rows THEN
        RAISE NOTICE 'F5 acceptance (C-05) PASS: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    ELSE
        RAISE NOTICE 'F5 acceptance (C-05) FAIL: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    END IF;
END
$$;
