-- =============================================================================
-- Step 3B-5 / 19 - Test the F3 parser against the answer key (and F1 + F2 against the Step 3B-4 run)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/19_test_f3_parser.sql
--
-- Runs the F1 + F2 + F3 parser twice (determinism), then reports detection (incl. DET-F3 false positives and
-- format conflicts), output shape, offsets, F3 per-field accuracy, validity distribution, accuracy by header type
-- and source, record validity and truncation, mismatches, secondary values, diagnostics, header/JSON separation,
-- event scope, NaN / truncated / pretty-printed JSON, coordinate order by container, the absence of JSON type
-- casts, non-overlapping spans, the F1 + F2 regression against the latest {F1,F2} run, examples, determinism and
-- raw-input integrity.
-- Exits non-zero only if an invariant fails. The F3 acceptance verdict (C-05) is printed in section 21.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\echo
\echo '== 1. Raw input integrity before parsing =='
SELECT count(*) FILTER (WHERE passed) AS checks_passed, count(*) AS checks_total
FROM log_regex.verify_raw_access_logs();

\echo
\echo '== 2. F1 + F2 regression baseline: latest successful run with formats {F1,F2} (Step 3B-4) =='
SELECT coalesce(max(run_id), 0) AS baseline_run
FROM log_regex.parser_run
WHERE status = 'succeeded' AND formats_implemented = ARRAY['F1', 'F2'] \gset
SELECT :baseline_run AS baseline_run,
       (SELECT parser_version FROM log_regex.parser_run WHERE run_id = :baseline_run)         AS parser_version,
       (SELECT reference_data_version FROM log_regex.parser_run WHERE run_id = :baseline_run) AS reference_data_version,
       (SELECT formats_implemented FROM log_regex.parser_run WHERE run_id = :baseline_run)    AS formats_implemented;

\echo
\echo '== 3. Parser runs (run A and run B, identical inputs) =='
SELECT log_regex.run_parser('3B-5 F1+F2+F3 v1') AS run_a \gset
SELECT log_regex.run_parser('3B-5 F1+F2+F3 v1') AS run_b \gset
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
       count(*) FILTER (WHERE e.format_family = 'F3' AND l.format_family = 'F3')                AS f3_true_positive,
       count(*) FILTER (WHERE e.format_family <> 'F3' AND l.format_family = 'F3')               AS f3_false_positive,
       count(*) FILTER (WHERE e.format_family = 'F3' AND l.format_family IS DISTINCT FROM 'F3') AS f3_false_negative,
       count(*) FILTER (WHERE l.detection_rule = 'DET-00' AND e.format_family <> 'NONE')        AS det00_not_none,
       count(*) FILTER (WHERE cardinality(l.format_candidates) > 1)                             AS format_conflicts
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b;
SELECT * FROM t_detection;

\echo 'DET-F3 on rows of other formats (expected: no rows)'
SELECT e.format_family AS expected_format, count(*) AS det_f3_rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b AND l.detection_rule = 'DET-F3' AND e.format_family <> 'F3'
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
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F3')              AS f3_logs,
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
\echo '== 7. Per-field accuracy on all answer-key F3 rows (latest run) =='
CREATE TEMP TABLE t_accuracy AS
SELECT field_order,
       field_name,
       count(*)                                                    AS rows,
       count(*) FILTER (WHERE value_match)                         AS value_match,
       count(*) FILTER (WHERE validity_match)                      AS validity_match,
       count(*) FILTER (WHERE value_match AND validity_match)      AS both_match,
       round(100.0 * count(*) FILTER (WHERE value_match AND validity_match) / count(*), 2) AS pct
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F3'
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
\echo '== 8. Validity distribution on F3 rows: answer key vs parser =='
SELECT c.field_name,
       v.validity,
       count(*) FILTER (WHERE c.expected_validity = v.validity) AS expected,
       count(*) FILTER (WHERE c.parsed_validity   = v.validity) AS parsed
FROM log_regex.v_parser_field_comparison c
CROSS JOIN (VALUES (1, 'VALID'), (2, 'INVALID'), (3, 'PLACEHOLDER'), (4, 'MISSING')) AS v (ord, validity)
WHERE c.expected_format = 'F3'
GROUP BY c.field_order, c.field_name, v.ord, v.validity
ORDER BY c.field_order, v.ord;

SELECT c.field_name, c.parsed_validity, c.rule_id, count(*) AS rows
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F3' AND c.parsed_validity IN ('MISSING', 'PLACEHOLDER')
   OR c.expected_format = 'F3' AND c.rule_id LIKE 'VS-5%'
GROUP BY c.field_order, c.field_name, c.parsed_validity, c.rule_id
ORDER BY c.field_order, c.parsed_validity, c.rule_id;

\echo
\echo '== 9. F3 accuracy by syslog header type (sub_format) and by source =='
SELECT l.sub_format,
       count(DISTINCT c.log_id)                                                         AS logs,
       count(*)                                                                         AS field_values,
       count(*) FILTER (WHERE c.value_match AND c.validity_match)                       AS both_match,
       count(DISTINCT c.log_id) FILTER (WHERE NOT (c.value_match AND c.validity_match)) AS logs_with_mismatch
FROM log_regex.v_parser_field_comparison c
JOIN log_regex.parsed_log l ON l.run_id = c.run_id AND l.log_id = c.log_id
WHERE c.expected_format = 'F3'
GROUP BY l.sub_format
ORDER BY l.sub_format;

SELECT source,
       count(DISTINCT log_id)                                                      AS logs,
       count(*)                                                                    AS field_values,
       count(*) FILTER (WHERE value_match AND validity_match)                      AS both_match,
       count(DISTINCT log_id) FILTER (WHERE NOT (value_match AND validity_match))  AS logs_with_mismatch
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F3'
GROUP BY source
ORDER BY source;

\echo
\echo '== 10. Record validity and truncation on F3 rows =='
SELECT e.record_validity AS expected, l.record_validity AS parsed, l.is_truncated, count(*) AS rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b AND e.format_family = 'F3'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

\echo
\echo '== 11. Mismatches on F3 rows (first 60) =='
SELECT case_id, log_id, field_name, expected_value, parsed_value, expected_validity, parsed_validity, rule_id, slot_id
FROM log_regex.v_parser_mismatches
WHERE expected_format = 'F3'
ORDER BY log_id, field_order
LIMIT 60;

\echo
\echo '== 12. Secondary values on F3 rows (informational; not part of C-05) =='
CREATE TEMP TABLE t_secondary AS
WITH parsed AS (
    SELECT l.log_id,
           (SELECT string_agg(k, ';' ORDER BY k)
            FROM (SELECT s.kind || '=' || s.value AS k
                  FROM log_regex.parsed_secondary s
                  WHERE s.run_id = l.run_id AND s.log_id = l.log_id) q) AS parsed_set
    FROM log_regex.parsed_log l
    WHERE l.run_id = :run_b AND l.format_family = 'F3'
),
expected AS (
    SELECT e.log_id, e.case_id,
           (SELECT string_agg(k, ';' ORDER BY k) FROM unnest(string_to_array(e.secondary_values, ';')) AS k) AS expected_set
    FROM log_regex.expected_fields e
    WHERE e.format_family = 'F3'
)
SELECT x.log_id, x.case_id, x.expected_set, p.parsed_set, x.expected_set IS NOT DISTINCT FROM p.parsed_set AS same
FROM expected x
JOIN parsed p USING (log_id);

SELECT count(*) AS f3_logs,
       count(*) FILTER (WHERE same) AS same_secondary_set,
       count(*) FILTER (WHERE NOT same) AS different
FROM t_secondary;
SELECT case_id, log_id, expected_set, parsed_set FROM t_secondary WHERE NOT same ORDER BY log_id;

SELECT s.kind, count(*) AS values
FROM log_regex.parsed_secondary s
JOIN log_regex.parsed_log l ON l.run_id = s.run_id AND l.log_id = s.log_id
WHERE s.run_id = :run_b AND l.format_family = 'F3'
GROUP BY s.kind
ORDER BY s.kind;

\echo
\echo '== 13. Diagnostics, header types and key paths on F3 rows (run B) =='
SELECT d.code, count(*) AS logs, string_agg(e.case_id, ', ' ORDER BY e.log_id) FILTER (WHERE e.source = 'curated') AS curated_cases
FROM log_regex.parsed_log l
CROSS JOIN LATERAL unnest(l.diagnostics) AS d (code)
JOIN log_regex.expected_fields e ON e.log_id = l.log_id
WHERE l.run_id = :run_b AND l.format_family = 'F3'
GROUP BY d.code
ORDER BY d.code;

SELECT sub_format, count(*) AS logs FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F3' GROUP BY 1 ORDER BY 1;

SELECT f.field_name, f.slot_id, count(*) AS values
FROM log_regex.parsed_field f
JOIN log_regex.parsed_log l ON l.run_id = f.run_id AND l.log_id = f.log_id
JOIN log_regex.ref_field rf ON rf.field_name = f.field_name
WHERE f.run_id = :run_b AND l.format_family = 'F3' AND f.slot_id IS NOT NULL
GROUP BY rf.field_order, f.field_name, f.slot_id
ORDER BY rf.field_order, f.slot_id;

\echo
\echo '== 14. Syslog header parsed separately from the JSON event (run B) =='
CREATE TEMP TABLE t_f3_logs AS
SELECT l.log_id, e.case_id, r.raw_log, l.sub_format, l.event_end_pos, l.is_truncated,
       regexp_instr(r.raw_log, '\{[[:space:]]*"') AS json_open
FROM log_regex.parsed_log l
JOIN log_regex.raw_access_logs r ON r.log_id = l.log_id
JOIN log_regex.expected_fields e ON e.log_id = l.log_id
WHERE l.run_id = :run_b AND l.format_family = 'F3';

CREATE TEMP TABLE t_header AS
SELECT (SELECT count(*) FROM t_f3_logs)                                                           AS f3_logs,
       (SELECT count(*) FROM t_f3_logs t
        JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = t.log_id AND f.field_name = 'event_timestamp'
        WHERE f.slot_id LIKE 'F3.header.%' AND f.start_pos + char_length(f.value) <= t.json_open)  AS timestamps_from_header,
       (SELECT count(*) FROM t_f3_logs t
        JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = t.log_id AND f.field_name <> 'event_timestamp'
        WHERE f.value IS NOT NULL AND f.start_pos < t.json_open)                                  AS json_fields_inside_header,
       (SELECT count(*) FROM t_f3_logs t
        JOIN log_regex.parsed_secondary s ON s.run_id = :run_b AND s.log_id = t.log_id
        WHERE s.start_pos < t.json_open)                                                          AS secondary_inside_header,
       (SELECT count(*) FROM t_f3_logs t
        WHERE (t.sub_format = 'rfc5424') <> (t.raw_log ~ '^<[0-9]{1,3}>1 '))                      AS sub_format_disagreements;
SELECT * FROM t_header;

SELECT t.sub_format, f.slot_id, count(*) AS timestamps
FROM t_f3_logs t
JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = t.log_id AND f.field_name = 'event_timestamp'
GROUP BY 1, 2
ORDER BY 1, 2;

\echo
\echo '== 15. Event scope, truncated, pretty-printed and NaN JSON (run B) =='
CREATE TEMP TABLE t_event_end AS
SELECT count(*) FILTER (WHERE NOT is_truncated)                                                     AS closed_logs,
       count(*) FILTER (WHERE NOT is_truncated AND substr(raw_log, event_end_pos, 1) = '}')         AS closed_ending_at_brace,
       count(*) FILTER (WHERE NOT is_truncated AND event_end_pos = char_length(raw_log))            AS closed_ending_at_text_end,
       count(*) FILTER (WHERE is_truncated)                                                         AS truncated_logs,
       count(*) FILTER (WHERE is_truncated AND event_end_pos = char_length(raw_log))                AS truncated_ending_at_text_end,
       count(*) FILTER (WHERE strpos(raw_log, E'\n') > 0)                                           AS multi_line_logs,
       count(*) FILTER (WHERE event_end_pos > log_regex.line_event_end(raw_log))                    AS events_beyond_first_line
FROM t_f3_logs;
SELECT * FROM t_event_end;

\echo 'EC-135 (truncated inside the resource string) and EC-144 (pretty-printed over 10 lines)'
SELECT t.case_id, t.sub_format, t.event_end_pos, char_length(t.raw_log) AS raw_length, t.is_truncated,
       l.record_validity, l.diagnostics
FROM t_f3_logs t
JOIN log_regex.parsed_log l ON l.run_id = :run_b AND l.log_id = t.log_id
WHERE t.case_id IN ('EC-135', 'EC-144')
ORDER BY t.case_id;

SELECT c.case_id, c.field_name, c.parsed_value, c.parsed_validity, c.expected_validity, c.start_pos,
       1 + char_length(left(t.raw_log, c.start_pos - 1))
         - char_length(replace(left(t.raw_log, c.start_pos - 1), E'\n', ''))  AS line_no,
       c.rule_id, c.slot_id
FROM log_regex.v_parser_field_comparison c
JOIN t_f3_logs t ON t.log_id = c.log_id
WHERE c.case_id IN ('EC-135', 'EC-144')
ORDER BY c.case_id, c.field_order;

\echo 'Rows containing NaN: coordinate fields'
SELECT c.case_id, c.log_id, c.field_name, c.parsed_value, c.expected_value, c.parsed_validity, c.expected_validity, c.slot_id
FROM log_regex.v_parser_field_comparison c
JOIN t_f3_logs t ON t.log_id = c.log_id
WHERE t.raw_log ~ '\yNaN\y' AND c.field_name IN ('latitude', 'longitude')
ORDER BY c.log_id, c.field_order;

\echo
\echo '== 16. Coordinate order by container (C-03), F3 rows =='
SELECT CASE
           WHEN c.slot_id LIKE 'F3.key.geometry.coordinates%' THEN '4 GeoJSON geometry.coordinates [lon, lat]'
           WHEN c.slot_id LIKE 'F3.key.geo.%'                 THEN '1 geo object {lat, lng}'
           WHEN c.slot_id IN ('F3.key.latitude', 'F3.key.longitude') THEN '2 latitude / longitude keys'
           WHEN c.slot_id LIKE 'F3.key.location%'             THEN '3 location string "lat,lon"'
           WHEN c.slot_id = 'F3.key.geo'                      THEN '5 geo null (both axes)'
           WHEN c.slot_id IS NULL                             THEN '6 absent'
           ELSE c.slot_id
       END AS container,
       c.field_name,
       count(*)                                                AS values,
       count(*) FILTER (WHERE c.value_match AND c.validity_match) AS both_match
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F3' AND c.field_name IN ('latitude', 'longitude')
GROUP BY 1, c.field_order, c.field_name
ORDER BY 1, c.field_order;

CREATE TEMP TABLE t_geojson AS
SELECT count(*)                                                                                    AS geojson_logs,
       count(*) FILTER (WHERE regexp_substr(t.raw_log, '"coordinates"[[:space:]]*:[[:space:]]*\[[[:space:]]*([^],[:space:]]+)', 1, 1, '', 1)
                              = e.latitude)                                                        AS first_element_equals_latitude,
       count(*) FILTER (WHERE lat.value IS NOT DISTINCT FROM e.latitude
                          AND lon.value IS NOT DISTINCT FROM e.longitude)                           AS parser_both_axes_correct
FROM t_f3_logs t
JOIN log_regex.expected_fields e ON e.log_id = t.log_id
JOIN log_regex.parsed_field lat ON lat.run_id = :run_b AND lat.log_id = t.log_id AND lat.field_name = 'latitude'
JOIN log_regex.parsed_field lon ON lon.run_id = :run_b AND lon.log_id = t.log_id AND lon.field_name = 'longitude'
WHERE t.raw_log ~ '"geometry"[[:space:]]*:';
\echo 'GeoJSON rows: reading the first array element as latitude would be wrong; the parser reads [1] as latitude'
SELECT * FROM t_geojson;

\echo
\echo '== 17. No JSON data types: function sources and table columns in schema log_regex =='
CREATE TEMP TABLE t_no_json AS
SELECT (SELECT count(*)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'log_regex'
          AND p.prosrc ~* '(::[[:space:]]*jsonb?\y)|(\yas[[:space:]]+jsonb?\y)|(\y(to_)?jsonb?(_[a-z_]+)?[[:space:]]*\()') AS functions_using_json,
       (SELECT count(*)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'log_regex')                                                               AS functions_checked,
       (SELECT count(*)
        FROM information_schema.columns
        WHERE table_schema = 'log_regex' AND data_type IN ('json', 'jsonb'))                        AS json_columns;
SELECT * FROM t_no_json;

\echo
\echo '== 18. Non-overlapping field spans on F3 rows (run B; a single token read for both axes is allowed) =='
CREATE TEMP TABLE t_overlap AS
SELECT count(*) AS overlapping_pairs
FROM log_regex.parsed_field a
JOIN log_regex.parsed_field b ON b.run_id = a.run_id AND b.log_id = a.log_id AND a.field_name < b.field_name
JOIN log_regex.parsed_log l   ON l.run_id = a.run_id AND l.log_id = a.log_id
WHERE a.run_id = :run_b
  AND l.format_family = 'F3'
  AND a.value IS NOT NULL
  AND b.value IS NOT NULL
  AND a.start_pos < b.start_pos + char_length(b.value)
  AND b.start_pos < a.start_pos + char_length(a.value)
  AND NOT (a.field_name = 'latitude' AND b.field_name = 'longitude'
           AND a.start_pos = b.start_pos AND a.value = b.value);
SELECT * FROM t_overlap;

\echo
\echo '== 19. F1 + F2 regression: run B vs the Step 3B-4 baseline run, F1 and F2 rows only =='
CREATE TEMP TABLE t_prev_logs AS
SELECT DISTINCT log_id
FROM log_regex.parsed_log
WHERE run_id IN (:baseline_run, :run_b) AND format_family IN ('F1', 'F2');

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
WHERE expected_format IN ('F1', 'F2')
GROUP BY expected_format;
SELECT * FROM t_prev_accuracy ORDER BY expected_format;

\echo
\echo '== 20. Examples: EC-128 (two status keys), EC-086 (GeoJSON), EC-052 (RFC 5424, location string), run B =='
SELECT e.case_id, f.field_name, f.value, f.validity, f.start_pos, f.missing_reason, f.slot_id, f.rule_id, f.candidate_count
FROM log_regex.parsed_field f
JOIN log_regex.expected_fields e ON e.log_id = f.log_id
JOIN log_regex.ref_field rf ON rf.field_name = f.field_name
WHERE f.run_id = :run_b AND e.case_id IN ('EC-052', 'EC-086', 'EC-128')
ORDER BY e.case_id, rf.field_order;

SELECT e.case_id, s.field_name, s.kind, s.value, s.start_pos
FROM log_regex.parsed_secondary s
JOIN log_regex.expected_fields e ON e.log_id = s.log_id
WHERE s.run_id = :run_b AND e.case_id IN ('EC-022', 'EC-128')
ORDER BY e.case_id, s.start_pos;

\echo
\echo '== 21. Determinism, raw integrity after parsing, and verdict =='
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
    h  record;
    ev record;
    nj record;
    t  record;
    g  record;
    a  record;
    raw_failures      integer;
    overlap_pairs     integer;
    f1_rows           bigint;
    f1_match          bigint;
    f2_rows           bigint;
    f2_match          bigint;
    regression_diffs  bigint;
BEGIN
    SELECT * INTO d  FROM t_detection;
    SELECT * INTO s  FROM t_shape;
    SELECT * INTO o  FROM t_offsets;
    SELECT * INTO h  FROM t_header;
    SELECT * INTO ev FROM t_event_end;
    SELECT * INTO nj FROM t_no_json;
    SELECT * INTO t  FROM t_determinism;
    SELECT * INTO g  FROM t_regression;
    SELECT sum(rows) AS rows, sum(both_match) AS both_match INTO a FROM t_accuracy;
    SELECT t_overlap.overlapping_pairs INTO overlap_pairs FROM t_overlap;
    SELECT rows, both_match INTO f1_rows, f1_match FROM t_prev_accuracy WHERE expected_format = 'F1';
    SELECT rows, both_match INTO f2_rows, f2_match FROM t_prev_accuracy WHERE expected_format = 'F2';
    SELECT count(*) INTO raw_failures FROM log_regex.verify_raw_access_logs() WHERE NOT passed;
    regression_diffs := g.parsed_log_only_baseline + g.parsed_log_only_current + g.parsed_field_only_baseline
                        + g.parsed_field_only_current + g.secondary_only_baseline + g.secondary_only_current;

    IF raw_failures > 0
       OR d.f1_false_positive + d.f1_false_negative + d.f2_false_positive + d.f2_false_negative
          + d.f3_false_positive + d.f3_false_negative + d.det00_not_none + d.format_conflicts > 0
       OR s.parsed_log_rows <> 5000 OR s.raw_rows_without_parsed_log > 0 OR s.parsed_logs_without_10_fields > 0
       OR o.field_values <> o.field_values_exact OR o.secondary_values <> o.secondary_values_exact
       OR h.json_fields_inside_header + h.secondary_inside_header + h.sub_format_disagreements > 0
       OR ev.closed_logs <> ev.closed_ending_at_brace OR ev.truncated_logs <> ev.truncated_ending_at_text_end
       OR nj.functions_using_json + nj.json_columns > 0
       OR overlap_pairs > 0
       OR t.parsed_log_diff + t.parsed_field_diff + t.parsed_secondary_diff + abs(t.field_row_count_diff) > 0 THEN
        RAISE EXCEPTION 'Step 3B-5 invariant FAILED (raw %, detection F1 %/% F2 %/% F3 %/% DET-00 % conflicts %, shape %/%/%, offsets %/% %/%, header %/%/%, event end %/% %/%, json %/%, overlaps %, determinism %/%/%/%)',
            raw_failures, d.f1_false_positive, d.f1_false_negative, d.f2_false_positive, d.f2_false_negative,
            d.f3_false_positive, d.f3_false_negative, d.det00_not_none, d.format_conflicts,
            s.parsed_log_rows, s.raw_rows_without_parsed_log, s.parsed_logs_without_10_fields,
            o.field_values_exact, o.field_values, o.secondary_values_exact, o.secondary_values,
            h.json_fields_inside_header, h.secondary_inside_header, h.sub_format_disagreements,
            ev.closed_ending_at_brace, ev.closed_logs, ev.truncated_ending_at_text_end, ev.truncated_logs,
            nj.functions_using_json, nj.json_columns, overlap_pairs,
            t.parsed_log_diff, t.parsed_field_diff, t.parsed_secondary_diff, t.field_row_count_diff;
    END IF;

    IF g.baseline_run = 0 THEN
        RAISE NOTICE 'F1 + F2 regression SKIPPED: parser_run has no successful run with formats {F1,F2}';
    ELSIF regression_diffs > 0 OR g.baseline_field_rows <> g.current_field_rows THEN
        RAISE EXCEPTION 'F1 + F2 regression FAILED against run %: % differing rows (field rows % vs %)',
            g.baseline_run, regression_diffs, g.baseline_field_rows, g.current_field_rows;
    ELSE
        RAISE NOTICE 'F1 + F2 regression PASSED: % logs identical to baseline run % (parsed_log, parsed_field, parsed_secondary)',
            g.logs_compared, g.baseline_run;
    END IF;

    IF f1_match <> f1_rows OR f2_match <> f2_rows THEN
        RAISE EXCEPTION 'F1 / F2 accuracy changed: F1 % / %, F2 % / %', f1_match, f1_rows, f2_match, f2_rows;
    END IF;

    RAISE NOTICE 'Invariants PASSED: raw input unchanged, F1/F2/F3 detection exact with no format conflicts, 5000 parsed_log rows, exact offsets, header and JSON separated, event scope ends at the closing brace or the text end, no JSON types used, no overlapping F3 spans, deterministic';
    RAISE NOTICE 'F1 and F2 acceptance unchanged: F1 % / %, F2 % / %', f1_match, f1_rows, f2_match, f2_rows;
    IF a.both_match = a.rows THEN
        RAISE NOTICE 'F3 acceptance (C-05) PASS: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    ELSE
        RAISE NOTICE 'F3 acceptance (C-05) FAIL: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    END IF;
END
$$;
