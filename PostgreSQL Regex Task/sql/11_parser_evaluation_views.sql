-- =============================================================================
-- Step 3B-3 / 11 - Evaluation views: parser output vs the answer key (Step 3A L4)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/11_parser_evaluation_views.sql
--
-- Views over the latest successful run. Values are compared with IS NOT DISTINCT FROM, so MISSING
-- (NULL) matches MISSING (NULL). Re-runnable.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DROP VIEW IF EXISTS log_regex.v_parser_mismatches;
DROP VIEW IF EXISTS log_regex.v_parser_field_comparison;

CREATE VIEW log_regex.v_parser_field_comparison AS
WITH latest AS (
    SELECT max(run_id) AS run_id FROM log_regex.parser_run WHERE status = 'succeeded'
)
SELECT f.run_id,
       f.log_id,
       e.case_id,
       e.source,
       e.format_family                                  AS expected_format,
       l.format_family                                  AS parsed_format,
       rf.field_order,
       f.field_name,
       x.expected_value,
       f.value                                          AS parsed_value,
       x.expected_validity,
       f.validity                                       AS parsed_validity,
       f.value IS NOT DISTINCT FROM x.expected_value    AS value_match,
       f.validity = x.expected_validity                 AS validity_match,
       f.start_pos,
       f.missing_reason,
       f.slot_id,
       f.rule_id
FROM latest
JOIN log_regex.parsed_field f    ON f.run_id = latest.run_id
JOIN log_regex.ref_field rf      ON rf.field_name = f.field_name
JOIN log_regex.parsed_log l      ON l.run_id = f.run_id AND l.log_id = f.log_id
JOIN log_regex.expected_fields e ON e.log_id = f.log_id
JOIN LATERAL (VALUES
        ('entity_type',     e.entity_type,     e.entity_type_validity),
        ('email_address',   e.email_address,   e.email_address_validity),
        ('resource_url',    e.resource_url,    e.resource_url_validity),
        ('event_timestamp', e.event_timestamp, e.event_timestamp_validity),
        ('tool',            e.tool,            e.tool_validity),
        ('latitude',        e.latitude,        e.latitude_validity),
        ('longitude',       e.longitude,       e.longitude_validity),
        ('ip_address',      e.ip_address,      e.ip_address_validity),
        ('action_phrase',   e.action_phrase,   e.action_phrase_validity),
        ('status',          e.status,          e.status_validity)
     ) AS x (field_name, expected_value, expected_validity) ON x.field_name = f.field_name;

COMMENT ON VIEW log_regex.v_parser_field_comparison IS
    'One row per parsed field of the latest successful run, with the answer-key value and validity.';

CREATE VIEW log_regex.v_parser_mismatches AS
SELECT *
FROM log_regex.v_parser_field_comparison
WHERE NOT (value_match AND validity_match);

COMMENT ON VIEW log_regex.v_parser_mismatches IS
    'Parsed fields of the latest successful run whose value or validity differs from the answer key.';

COMMIT;
