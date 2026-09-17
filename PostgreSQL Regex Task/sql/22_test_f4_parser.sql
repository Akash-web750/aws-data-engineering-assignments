-- =============================================================================
-- Step 3B-6 / 22 - Test the F4 parser against the answer key (and F1 + F2 + F3 against the Step 3B-5 run)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/22_test_f4_parser.sql
--
-- Runs the F1-F4 parser twice (determinism), then reports detection (incl. DET-F4 false positives and format
-- conflicts), output shape, offsets, F4 per-field accuracy, validity distribution, accuracy by IP-field form and
-- source, record validity and truncation, mismatches, secondary values, diagnostics, fixed-position order, quoted
-- values, entity values with spaces and known-key boundaries, IP forms and X-Forwarded-For, coordinate order by
-- container, truncated and long lines, whole-line probes, non-overlapping spans, the F1 + F2 + F3 regression
-- against the latest {F1,F2,F3} run, examples, determinism and raw-input integrity.
-- Exits non-zero only if an invariant fails. The F4 acceptance verdict (C-05) is printed in section 23.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\echo
\echo '== 1. Raw input integrity before parsing =='
SELECT count(*) FILTER (WHERE passed) AS checks_passed, count(*) AS checks_total
FROM log_regex.verify_raw_access_logs();

\echo
\echo '== 2. F1 + F2 + F3 regression baseline: latest successful run with formats {F1,F2,F3} (Step 3B-5) =='
SELECT coalesce(max(run_id), 0) AS baseline_run
FROM log_regex.parser_run
WHERE status = 'succeeded' AND formats_implemented = ARRAY['F1', 'F2', 'F3'] \gset
SELECT :baseline_run AS baseline_run,
       (SELECT parser_version FROM log_regex.parser_run WHERE run_id = :baseline_run)         AS parser_version,
       (SELECT reference_data_version FROM log_regex.parser_run WHERE run_id = :baseline_run) AS reference_data_version,
       (SELECT formats_implemented FROM log_regex.parser_run WHERE run_id = :baseline_run)    AS formats_implemented;

\echo
\echo '== 3. Parser runs (run A and run B, identical inputs) =='
SELECT log_regex.run_parser('3B-6 F1-F4 v1') AS run_a \gset
SELECT log_regex.run_parser('3B-6 F1-F4 v1') AS run_b \gset
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
SELECT count(*) FILTER (WHERE e.format_family = f.fmt AND l.format_family = f.fmt)                AS true_positive,
       count(*) FILTER (WHERE e.format_family <> f.fmt AND l.format_family = f.fmt)               AS false_positive,
       count(*) FILTER (WHERE e.format_family = f.fmt AND l.format_family IS DISTINCT FROM f.fmt) AS false_negative,
       f.fmt
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
CROSS JOIN (VALUES ('F1'), ('F2'), ('F3'), ('F4')) AS f (fmt)
WHERE l.run_id = :run_b
GROUP BY f.fmt;
SELECT fmt, true_positive, false_positive, false_negative FROM t_detection ORDER BY fmt;

CREATE TEMP TABLE t_detection_other AS
SELECT count(*) FILTER (WHERE l.detection_rule = 'DET-00' AND e.format_family <> 'NONE') AS det00_not_none,
       count(*) FILTER (WHERE cardinality(l.format_candidates) > 1)                     AS format_conflicts
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b;
SELECT * FROM t_detection_other;

\echo
\echo '== 5. Output shape (run B) =='
CREATE TEMP TABLE t_shape AS
SELECT (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b)                                   AS parsed_log_rows,
       (SELECT count(*) FROM log_regex.raw_access_logs r
        WHERE NOT EXISTS (SELECT 1 FROM log_regex.parsed_log l WHERE l.run_id = :run_b AND l.log_id = r.log_id)) AS raw_rows_without_parsed_log,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F1')              AS f1_logs,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F2')              AS f2_logs,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F3')              AS f3_logs,
       (SELECT count(*) FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F4')              AS f4_logs,
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
\echo '== 7. Per-field accuracy on all answer-key F4 rows (latest run) =='
CREATE TEMP TABLE t_accuracy AS
SELECT field_order,
       field_name,
       count(*)                                                    AS rows,
       count(*) FILTER (WHERE value_match)                         AS value_match,
       count(*) FILTER (WHERE validity_match)                      AS validity_match,
       count(*) FILTER (WHERE value_match AND validity_match)      AS both_match,
       round(100.0 * count(*) FILTER (WHERE value_match AND validity_match) / count(*), 2) AS pct
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F4'
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
\echo '== 8. Validity distribution on F4 rows: answer key vs parser =='
SELECT c.field_name,
       v.validity,
       count(*) FILTER (WHERE c.expected_validity = v.validity) AS expected,
       count(*) FILTER (WHERE c.parsed_validity   = v.validity) AS parsed
FROM log_regex.v_parser_field_comparison c
CROSS JOIN (VALUES (1, 'VALID'), (2, 'INVALID'), (3, 'PLACEHOLDER'), (4, 'MISSING')) AS v (ord, validity)
WHERE c.expected_format = 'F4'
GROUP BY c.field_order, c.field_name, v.ord, v.validity
ORDER BY c.field_order, v.ord;

SELECT c.field_name, c.parsed_validity, c.rule_id, count(*) AS rows
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F4'
  AND (c.parsed_validity IN ('MISSING', 'PLACEHOLDER') OR c.rule_id LIKE 'VS-5%')
GROUP BY c.field_order, c.field_name, c.parsed_validity, c.rule_id
ORDER BY c.field_order, c.parsed_validity, c.rule_id;

\echo
\echo '== 9. F4 accuracy by IP-field form (sub_format) and by source =='
SELECT l.sub_format,
       count(DISTINCT c.log_id)                                                         AS logs,
       count(*)                                                                         AS field_values,
       count(*) FILTER (WHERE c.value_match AND c.validity_match)                       AS both_match,
       count(DISTINCT c.log_id) FILTER (WHERE NOT (c.value_match AND c.validity_match)) AS logs_with_mismatch
FROM log_regex.v_parser_field_comparison c
JOIN log_regex.parsed_log l ON l.run_id = c.run_id AND l.log_id = c.log_id
WHERE c.expected_format = 'F4'
GROUP BY l.sub_format
ORDER BY l.sub_format;

SELECT source,
       count(DISTINCT log_id)                                                      AS logs,
       count(*)                                                                    AS field_values,
       count(*) FILTER (WHERE value_match AND validity_match)                      AS both_match,
       count(DISTINCT log_id) FILTER (WHERE NOT (value_match AND validity_match))  AS logs_with_mismatch
FROM log_regex.v_parser_field_comparison
WHERE expected_format = 'F4'
GROUP BY source
ORDER BY source;

\echo
\echo '== 10. Record validity and truncation on F4 rows =='
SELECT e.record_validity AS expected, l.record_validity AS parsed, l.is_truncated, count(*) AS rows
FROM log_regex.parsed_log l
JOIN log_regex.expected_fields e USING (log_id)
WHERE l.run_id = :run_b AND e.format_family = 'F4'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

\echo
\echo '== 11. Mismatches on F4 rows (first 60) =='
SELECT case_id, log_id, field_name, left(expected_value, 60) AS expected_value, left(parsed_value, 60) AS parsed_value,
       expected_validity, parsed_validity, rule_id, slot_id
FROM log_regex.v_parser_mismatches
WHERE expected_format = 'F4'
ORDER BY log_id, field_order
LIMIT 60;

\echo
\echo '== 12. Secondary values on F4 rows (informational; not part of C-05) =='
CREATE TEMP TABLE t_secondary AS
WITH parsed AS (
    SELECT l.log_id,
           (SELECT string_agg(k, ';' ORDER BY k)
            FROM (SELECT s.kind || '=' || s.value AS k
                  FROM log_regex.parsed_secondary s
                  WHERE s.run_id = l.run_id AND s.log_id = l.log_id) q) AS parsed_set
    FROM log_regex.parsed_log l
    WHERE l.run_id = :run_b AND l.format_family = 'F4'
),
expected AS (
    SELECT e.log_id, e.case_id,
           (SELECT string_agg(k, ';' ORDER BY k) FROM unnest(string_to_array(e.secondary_values, ';')) AS k) AS expected_set
    FROM log_regex.expected_fields e
    WHERE e.format_family = 'F4'
)
SELECT x.log_id, x.case_id, x.expected_set, p.parsed_set, x.expected_set IS NOT DISTINCT FROM p.parsed_set AS same
FROM expected x
JOIN parsed p USING (log_id);

SELECT count(*) AS f4_logs,
       count(*) FILTER (WHERE same) AS same_secondary_set,
       count(*) FILTER (WHERE NOT same) AS different
FROM t_secondary;
SELECT case_id, log_id, expected_set, parsed_set FROM t_secondary WHERE NOT same ORDER BY log_id LIMIT 30;

SELECT s.kind, count(*) AS values
FROM log_regex.parsed_secondary s
JOIN log_regex.parsed_log l ON l.run_id = s.run_id AND l.log_id = s.log_id
WHERE s.run_id = :run_b AND l.format_family = 'F4'
GROUP BY s.kind
ORDER BY s.kind;

\echo
\echo '== 13. Diagnostics, IP-field forms and slots on F4 rows (run B) =='
SELECT d.code, count(*) AS logs, string_agg(e.case_id, ', ' ORDER BY e.log_id) FILTER (WHERE e.source = 'curated') AS curated_cases
FROM log_regex.parsed_log l
CROSS JOIN LATERAL unnest(l.diagnostics) AS d (code)
JOIN log_regex.expected_fields e ON e.log_id = l.log_id
WHERE l.run_id = :run_b AND l.format_family = 'F4'
GROUP BY d.code
ORDER BY d.code;

SELECT sub_format, count(*) AS logs FROM log_regex.parsed_log WHERE run_id = :run_b AND format_family = 'F4' GROUP BY 1 ORDER BY 1;

SELECT f.field_name, f.slot_id, count(*) AS values
FROM log_regex.parsed_field f
JOIN log_regex.parsed_log l ON l.run_id = f.run_id AND l.log_id = f.log_id
JOIN log_regex.ref_field rf ON rf.field_name = f.field_name
WHERE f.run_id = :run_b AND l.format_family = 'F4' AND f.slot_id IS NOT NULL
GROUP BY rf.field_order, f.field_name, f.slot_id
ORDER BY rf.field_order, f.slot_id;

\echo
\echo '== 14. Fixed positions first, then quoted values (run B) =='
CREATE TEMP TABLE t_f4_logs AS
SELECT l.log_id, e.case_id, r.raw_log, l.sub_format, l.is_truncated
FROM log_regex.parsed_log l
JOIN log_regex.raw_access_logs r ON r.log_id = l.log_id
JOIN log_regex.expected_fields e ON e.log_id = l.log_id
WHERE l.run_id = :run_b AND l.format_family = 'F4';

CREATE TEMP TABLE t_positions AS
SELECT t.log_id,
       max(f.start_pos) FILTER (WHERE f.slot_id = 'F4.timestamp')                        AS ts_pos,
       max(f.start_pos) FILTER (WHERE f.slot_id LIKE 'F4.request%')                      AS resource_pos,
       max(f.start_pos) FILTER (WHERE f.slot_id = 'F4.status')                           AS status_pos,
       max(f.start_pos) FILTER (WHERE f.slot_id = 'F4.user_agent')                       AS tool_pos,
       max(f.start_pos + char_length(f.value)) FILTER (WHERE f.slot_id = 'F4.user_agent') AS tool_end,
       min(f.start_pos) FILTER (WHERE f.slot_id LIKE 'F4.extras.%')                      AS first_extra_pos
FROM t_f4_logs t
JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = t.log_id
GROUP BY t.log_id;

CREATE TEMP TABLE t_position_check AS
SELECT count(*)                                                                                  AS f4_logs,
       count(*) FILTER (WHERE ts_pos IS NOT NULL AND resource_pos IS NOT NULL AND status_pos IS NOT NULL
                          AND tool_pos IS NOT NULL)                                              AS logs_with_all_positional_slots,
       count(*) FILTER (WHERE NOT (ts_pos < resource_pos AND resource_pos < status_pos AND status_pos < tool_pos)) AS order_violations,
       count(*) FILTER (WHERE first_extra_pos IS NOT NULL AND first_extra_pos <= tool_end)       AS extras_before_user_agent_end
FROM t_positions;
SELECT * FROM t_position_check;

CREATE TEMP TABLE t_quotes AS
SELECT count(*) AS quoted_values,
       count(*) FILTER (WHERE substr(t.raw_log, f.start_pos - 1, 1) = '"'
                          AND (substr(t.raw_log, f.start_pos + char_length(f.value), 1) = '"' OR t.is_truncated))
                                                                                                 AS delimited_by_quotes,
       count(*) FILTER (WHERE strpos(f.value, '"') > 0)                                         AS values_containing_a_quote,
       (SELECT count(*) FROM t_f4_logs t2
        JOIN log_regex.parsed_field g ON g.run_id = :run_b AND g.log_id = t2.log_id AND g.slot_id = 'F4.request.target'
        WHERE substr(t2.raw_log, g.start_pos + char_length(g.value), 6) <> ' HTTP/')             AS targets_not_followed_by_http
FROM t_f4_logs t
JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = t.log_id
WHERE f.value IS NOT NULL
  AND f.slot_id IN ('F4.request', 'F4.user_agent', 'F4.extras.msg');
SELECT * FROM t_quotes;

SELECT f.slot_id, count(*) AS values, count(*) FILTER (WHERE c.value_match AND c.validity_match) AS both_match
FROM t_f4_logs t
JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = t.log_id
JOIN log_regex.v_parser_field_comparison c ON c.log_id = f.log_id AND c.field_name = f.field_name
WHERE f.slot_id IN ('F4.request', 'F4.request.target', 'F4.user_agent', 'F4.extras.msg', 'F4.extras.xff[1]')
GROUP BY f.slot_id
ORDER BY f.slot_id;

\echo
\echo '== 15. Entity values with spaces and known-key boundaries (run B) =='
SELECT c.expected_value AS expected_entity, count(*) AS rows,
       count(*) FILTER (WHERE c.value_match AND c.validity_match) AS both_match,
       min(c.slot_id) AS example_slot
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F4' AND c.field_name = 'entity_type' AND c.expected_value LIKE '% %'
GROUP BY c.expected_value
ORDER BY c.expected_value;

CREATE TEMP TABLE t_key_lookalikes AS
SELECT t.log_id, t.case_id
FROM t_f4_logs t
JOIN log_regex.parsed_field res ON res.run_id = :run_b AND res.log_id = t.log_id AND res.field_name = 'resource_url'
JOIN log_regex.parsed_field ua  ON ua.run_id  = :run_b AND ua.log_id  = t.log_id AND ua.field_name  = 'tool'
WHERE coalesce(res.value, '') ~ '(type|entity|role|user|loc|geo|lat|lon|xff|msg|status)='
   OR coalesce(ua.value, '')  ~ '(type|entity|role|user|loc|geo|lat|lon|xff|msg|status)=';
\echo 'Rows whose request target or user agent contains a key-like "name=" (must not start an extras value)'
SELECT count(DISTINCT k.log_id)                                                    AS rows,
       count(*) FILTER (WHERE c.value_match AND c.validity_match)                  AS field_values_matching,
       count(*)                                                                    AS field_values,
       string_agg(DISTINCT k.case_id, ', ') FILTER (WHERE k.case_id LIKE 'EC-%')   AS curated_cases
FROM t_key_lookalikes k
JOIN log_regex.v_parser_field_comparison c ON c.log_id = k.log_id;

\echo
\echo '== 16. IP field forms, ports and X-Forwarded-For (run B) =='
SELECT l.sub_format,
       count(*)                                                    AS logs,
       count(*) FILTER (WHERE c.value_match AND c.validity_match)  AS ip_both_match,
       count(*) FILTER (WHERE c.parsed_validity = 'INVALID')       AS ip_invalid,
       count(s.log_id)                                             AS client_ports
FROM log_regex.v_parser_field_comparison c
JOIN log_regex.parsed_log l ON l.run_id = c.run_id AND l.log_id = c.log_id
LEFT JOIN log_regex.parsed_secondary s ON s.run_id = c.run_id AND s.log_id = c.log_id AND s.kind = 'client_port'
WHERE c.expected_format = 'F4' AND c.field_name = 'ip_address'
GROUP BY l.sub_format
ORDER BY l.sub_format;

\echo
\echo '== 17. Coordinate order by container (C-03), F4 rows =='
SELECT CASE
           WHEN c.slot_id LIKE 'F4.extras.loc%' THEN '1 loc=POINT(lon lat)'
           WHEN c.slot_id LIKE 'F4.extras.geo%' THEN '2 geo=lat,lon'
           WHEN c.slot_id IN ('F4.extras.lat', 'F4.extras.lon') THEN '3 lat= / lon= keys'
           WHEN c.slot_id IS NULL THEN '4 absent'
           ELSE c.slot_id
       END AS container,
       c.field_name,
       count(*)                                                   AS values,
       count(*) FILTER (WHERE c.value_match AND c.validity_match) AS both_match
FROM log_regex.v_parser_field_comparison c
WHERE c.expected_format = 'F4' AND c.field_name IN ('latitude', 'longitude')
GROUP BY 1, c.field_order, c.field_name
ORDER BY 1, c.field_order;

CREATE TEMP TABLE t_point AS
SELECT count(*)                                                                                   AS point_logs,
       count(*) FILTER (WHERE regexp_substr(t.raw_log, 'loc=POINT\(([^ ()]*) ', 1, 1, '', 1) = e.latitude) AS first_number_equals_latitude,
       count(*) FILTER (WHERE lat.value IS NOT DISTINCT FROM e.latitude
                          AND lon.value IS NOT DISTINCT FROM e.longitude)                          AS parser_both_axes_correct
FROM t_f4_logs t
JOIN log_regex.expected_fields e ON e.log_id = t.log_id
JOIN log_regex.parsed_field lat ON lat.run_id = :run_b AND lat.log_id = t.log_id AND lat.field_name = 'latitude'
JOIN log_regex.parsed_field lon ON lon.run_id = :run_b AND lon.log_id = t.log_id AND lon.field_name = 'longitude'
WHERE t.raw_log ~ ' loc=POINT\(';
\echo 'POINT rows: reading the first number as latitude would be wrong; the parser reads POINT(lon lat)'
SELECT * FROM t_point;

\echo
\echo '== 18. Truncated (EC-136) and long (EC-145) lines, X-Forwarded-For (EC-103), run B =='
SELECT t.case_id, t.sub_format, t.is_truncated, l.record_validity, l.diagnostics, l.event_end_pos,
       char_length(t.raw_log) AS raw_length
FROM t_f4_logs t
JOIN log_regex.parsed_log l ON l.run_id = :run_b AND l.log_id = t.log_id
WHERE t.case_id IN ('EC-103', 'EC-136', 'EC-145')
ORDER BY t.case_id;

SELECT c.case_id, c.field_name, left(c.parsed_value, 60) AS parsed_value, char_length(c.parsed_value) AS length,
       c.parsed_validity, c.expected_validity, c.value_match, c.start_pos, c.rule_id, c.slot_id
FROM log_regex.v_parser_field_comparison c
WHERE c.case_id IN ('EC-136', 'EC-145')
ORDER BY c.case_id, c.field_order;

\echo
\echo '== 19. Whole-line first-match probes vs the positional grammar on F4 rows (informational) =='
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
    (1, 'email_address',   'value after the first "user="',              e.email_address,
        regexp_substr(r.raw_log, 'user=<?([^ >&]*)', 1, 1, '', 1)),
    (2, 'ip_address',      'first dotted quad anywhere',                 e.ip_address,
        regexp_substr(r.raw_log, '[0-9]{1,3}([.][0-9]{1,3}){3}')),
    (3, 'resource_url',    'first http(s) URL anywhere',                 e.resource_url,
        regexp_substr(r.raw_log, 'https?://[^ "]+')),
    (4, 'status',          'first stand-alone 3-digit number',           e.status,
        regexp_substr(r.raw_log, '(?<![0-9.:/])[0-9]{3}(?![0-9.:/])')),
    (5, 'entity_type',     'single word after type= / entity= / role=',  e.entity_type,
        regexp_substr(r.raw_log, ' (?:type|entity|role)=([^ ]*)', 1, 1, '', 1)),
    (6, 'latitude',        'first number after loc=POINT( / geo= / lat=', e.latitude,
        regexp_substr(r.raw_log, '(?:POINT\(|geo=|lat=)(-?[0-9]+(?:[.][0-9]+)?|NaN)', 1, 1, '', 1))
) AS x (probe_order, field_name, probe, expected_value, naive_value)
JOIN log_regex.parsed_field f ON f.run_id = :run_b AND f.log_id = e.log_id AND f.field_name = x.field_name
WHERE e.format_family = 'F4';

SELECT field_name,
       probe,
       count(*)                                                                    AS rows,
       count(*) FILTER (WHERE naive_value  IS NOT DISTINCT FROM expected_value)    AS naive_correct,
       count(*) FILTER (WHERE parser_value IS NOT DISTINCT FROM expected_value)    AS parser_correct
FROM t_naive
GROUP BY probe_order, field_name, probe
ORDER BY probe_order;

SELECT DISTINCT ON (probe_order) probe, case_id, log_id, left(expected_value, 50) AS expected_value,
       left(naive_value, 50) AS naive_value, left(parser_value, 50) AS parser_value
FROM t_naive
WHERE naive_value IS DISTINCT FROM expected_value
ORDER BY probe_order, (case_id LIKE 'EC-%') DESC, log_id;

\echo
\echo '== 20. Non-overlapping field spans on F4 rows (run B; a single token read for both axes is allowed) =='
CREATE TEMP TABLE t_overlap AS
SELECT count(*) AS overlapping_pairs
FROM log_regex.parsed_field a
JOIN log_regex.parsed_field b ON b.run_id = a.run_id AND b.log_id = a.log_id AND a.field_name < b.field_name
JOIN log_regex.parsed_log l   ON l.run_id = a.run_id AND l.log_id = a.log_id
WHERE a.run_id = :run_b
  AND l.format_family = 'F4'
  AND a.value IS NOT NULL
  AND b.value IS NOT NULL
  AND a.start_pos < b.start_pos + char_length(b.value)
  AND b.start_pos < a.start_pos + char_length(a.value)
  AND NOT (a.field_name = 'latitude' AND b.field_name = 'longitude'
           AND a.start_pos = b.start_pos AND a.value = b.value);
SELECT * FROM t_overlap;

\echo
\echo '== 21. F1 + F2 + F3 regression: run B vs the Step 3B-5 baseline run, F1-F3 rows only =='
CREATE TEMP TABLE t_prev_logs AS
SELECT DISTINCT log_id
FROM log_regex.parsed_log
WHERE run_id IN (:baseline_run, :run_b) AND format_family IN ('F1', 'F2', 'F3');

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
WHERE expected_format IN ('F1', 'F2', 'F3')
GROUP BY expected_format;
SELECT * FROM t_prev_accuracy ORDER BY expected_format;

\echo
\echo '== 22. Examples: EC-029 (user= inside the target, URL in the agent), EC-097 ([IPv6]:port), EC-103 (xff), EC-064 (POINT), run B =='
SELECT e.case_id, f.field_name, left(f.value, 70) AS value, f.validity, f.start_pos, f.slot_id, f.rule_id
FROM log_regex.parsed_field f
JOIN log_regex.expected_fields e ON e.log_id = f.log_id
JOIN log_regex.ref_field rf ON rf.field_name = f.field_name
WHERE f.run_id = :run_b AND e.case_id IN ('EC-029', 'EC-064', 'EC-097', 'EC-103')
ORDER BY e.case_id, rf.field_order;

SELECT e.case_id, s.field_name, s.kind, s.value, s.start_pos
FROM log_regex.parsed_secondary s
JOIN log_regex.expected_fields e ON e.log_id = s.log_id
WHERE s.run_id = :run_b AND e.case_id IN ('EC-029', 'EC-039', 'EC-097', 'EC-103')
ORDER BY e.case_id, s.start_pos;

\echo
\echo '== 23. Determinism, raw integrity after parsing, and verdict =='
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
    pc   record;
    q    record;
    t    record;
    g    record;
    a    record;
    detection_errors  bigint;
    raw_failures      integer;
    overlap_pairs     integer;
    prev_rows         bigint;
    prev_match        bigint;
    prev_summary      text;
    regression_diffs  bigint;
BEGIN
    SELECT sum(false_positive + false_negative) INTO detection_errors FROM t_detection;
    SELECT * INTO dox FROM t_detection_other;
    SELECT * INTO s   FROM t_shape;
    SELECT * INTO o   FROM t_offsets;
    SELECT * INTO pc  FROM t_position_check;
    SELECT * INTO q   FROM t_quotes;
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
       OR detection_errors + dox.det00_not_none + dox.format_conflicts > 0
       OR s.parsed_log_rows <> 5000 OR s.raw_rows_without_parsed_log > 0 OR s.parsed_logs_without_10_fields > 0
       OR o.field_values <> o.field_values_exact OR o.secondary_values <> o.secondary_values_exact
       OR pc.order_violations + pc.extras_before_user_agent_end > 0
       OR q.quoted_values <> q.delimited_by_quotes OR q.values_containing_a_quote + q.targets_not_followed_by_http > 0
       OR overlap_pairs > 0
       OR t.parsed_log_diff + t.parsed_field_diff + t.parsed_secondary_diff + abs(t.field_row_count_diff) > 0 THEN
        RAISE EXCEPTION 'Step 3B-6 invariant FAILED (raw %, detection % DET-00 % conflicts %, shape %/%/%, offsets %/% %/%, positions %/%, quotes %/% %/%, overlaps %, determinism %/%/%/%)',
            raw_failures, detection_errors, dox.det00_not_none, dox.format_conflicts,
            s.parsed_log_rows, s.raw_rows_without_parsed_log, s.parsed_logs_without_10_fields,
            o.field_values_exact, o.field_values, o.secondary_values_exact, o.secondary_values,
            pc.order_violations, pc.extras_before_user_agent_end,
            q.delimited_by_quotes, q.quoted_values, q.values_containing_a_quote, q.targets_not_followed_by_http,
            overlap_pairs, t.parsed_log_diff, t.parsed_field_diff, t.parsed_secondary_diff, t.field_row_count_diff;
    END IF;

    IF g.baseline_run = 0 THEN
        RAISE NOTICE 'F1 + F2 + F3 regression SKIPPED: parser_run has no successful run with formats {F1,F2,F3}';
    ELSIF regression_diffs > 0 OR g.baseline_field_rows <> g.current_field_rows THEN
        RAISE EXCEPTION 'F1 + F2 + F3 regression FAILED against run %: % differing rows (field rows % vs %)',
            g.baseline_run, regression_diffs, g.baseline_field_rows, g.current_field_rows;
    ELSE
        RAISE NOTICE 'F1 + F2 + F3 regression PASSED: % logs identical to baseline run % (parsed_log, parsed_field, parsed_secondary)',
            g.logs_compared, g.baseline_run;
    END IF;

    IF prev_match <> prev_rows THEN
        RAISE EXCEPTION 'F1 / F2 / F3 accuracy changed: %', prev_summary;
    END IF;

    RAISE NOTICE 'Invariants PASSED: raw input unchanged, F1-F4 detection exact with no format conflicts, 5000 parsed_log rows, exact offsets, fixed positions in order, quoted values delimited by their quotes, no overlapping F4 spans, deterministic';
    RAISE NOTICE 'F1, F2 and F3 acceptance unchanged: %', prev_summary;
    IF a.both_match = a.rows THEN
        RAISE NOTICE 'F4 acceptance (C-05) PASS: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    ELSE
        RAISE NOTICE 'F4 acceptance (C-05) FAIL: % / % field values match the answer key in value and validity', a.both_match, a.rows;
    END IF;
END
$$;
