-- =============================================================================
-- Step 3B-2 - Verify PostgreSQL 17 IP validation behaviour
-- =============================================================================
-- Run from the project folder (the \copy path is relative to the psql working directory):
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/05_verify_ip_validation.sql
--
-- Purpose: compare PostgreSQL inet input behaviour with the Step 2 VAL-IP requirement and the
-- Step 1 answer key, and prove the exact validation rule proposed for the parser.
--
-- Read-only for the database: only TEMP tables are created (dropped at session end); nothing in
-- schema log_regex is written. No parser code: the proposed rule is evaluated once, inline, in the
-- TEMP table ip_eval.
-- Exit status is non-zero if the proposed rule disagrees with the answer key or with the probe
-- expectations, or if the raw input integrity check fails.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\echo
\echo '== 1. Environment =='
SELECT version() AS server, current_database() AS database, current_setting('server_encoding') AS encoding;

-- -----------------------------------------------------------------------------
-- Inputs: targeted probes and the answer key (TEMP only)
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE ip_probe (
    probe_no       integer,
    form           text,
    value          text,
    step2_expected text,
    reference      text
);

INSERT INTO ip_probe VALUES
    ( 1, 'IPv4 dotted quad (documentation range)', '192.0.2.115',                              'VALID',   'GEN rows'),
    ( 2, 'IPv4 dotted quad (private)',              '10.40.3.8',                                'VALID',   'EC-003'),
    ( 3, 'IPv4 loopback',                           '127.0.0.1',                                'VALID',   'EC-013'),
    ( 4, 'IPv4 all-zero octets',                    '0.0.0.0',                                  'VALID',   'boundary'),
    ( 5, 'IPv4 all-255 octets',                     '255.255.255.255',                          'VALID',   'boundary'),
    ( 6, 'IPv4 leading zeros',                      '192.168.001.010',                          'INVALID', 'EC-094'),
    ( 7, 'IPv4 leading zeros',                      '192.168.037.068',                          'INVALID', 'GEN-00190'),
    ( 8, 'IPv4 leading zero, first octet',          '010.0.0.1',                                'INVALID', 'not in data'),
    ( 9, 'IPv4 one leading zero',                   '1.2.3.04',                                 'INVALID', 'not in data'),
    (10, 'IPv4 octet > 255',                        '198.51.100.781',                           'INVALID', 'GEN-00954'),
    (11, 'IPv4 octet > 255',                        '256.10.1.300',                             'INVALID', 'EC-091'),
    (12, 'IPv4-like, 3 octets',                     '192.168.1',                                'INVALID', 'EC-092'),
    (13, 'IPv4-like, 2 octets',                     '10.1',                                     'INVALID', 'not in data'),
    (14, 'IPv4-like, 5 octets',                     '1.2.3.4.5',                                'INVALID', 'EC-093'),
    (15, 'IPv4 with CIDR suffix /24',               '192.0.2.1/24',                             'INVALID', 'not in data'),
    (16, 'IPv4 with CIDR suffix /32',               '192.0.2.1/32',                             'INVALID', 'not in data'),
    (17, 'IPv4 with port',                          '192.0.2.1:80',                             'INVALID', 'port is stripped before validation'),
    (18, 'IPv4 with leading space',                 ' 192.0.2.1',                               'INVALID', 'not in data'),
    (19, 'IPv6 compressed',                         '2001:db8:d09:e59e::3b83',                  'VALID',   'GEN-00013'),
    (20, 'IPv6 compressed, short',                  '2001:db8::1',                              'VALID',   'EC-097'),
    (21, 'IPv6 full 8 groups',                      '2001:0db8:0000:0000:0000:ff00:0042:8329',  'VALID',   'EC-096'),
    (22, 'IPv6 uppercase hex',                      '2001:DB8::1',                              'VALID',   'not in data'),
    (23, 'IPv6 loopback',                           '::1',                                      'VALID',   'EC-098'),
    (24, 'IPv6 unspecified',                        '::',                                       'VALID',   'not in data'),
    (25, 'IPv6 IPv4-mapped',                        '::ffff:192.0.2.10',                        'VALID',   'EC-099'),
    (26, 'IPv6 IPv4-mapped, octet > 255',           '::ffff:192.0.2.999',                       'INVALID', 'not in data'),
    (27, 'IPv6 IPv4-mapped, leading zero',          '::ffff:192.0.2.010',                       'INVALID', 'not in data'),
    (28, 'IPv6 link-local with zone id',            'fe80::1ff:fe23:4567:890a%eth0',            'VALID',   'EC-100'),
    (29, 'IPv6 with numeric zone id',               'fe80::1%1',                                'VALID',   'not in data'),
    (30, 'IPv6 global with zone id',                '2001:db8::1%eth0',                         'VALID',   'not in data'),
    (31, 'IPv6 with empty zone id',                 'fe80::1%',                                 'INVALID', 'not in data'),
    (32, 'IPv6 in brackets',                        '[2001:db8::1]',                            'INVALID', 'brackets are stripped before validation'),
    (33, 'IPv6 in brackets with port',              '[2001:db8::1]:443',                        'INVALID', 'brackets/port are stripped before validation'),
    (34, 'IPv6-like, two ::',                       '2001:db8::85a3::7334',                     'INVALID', 'EC-101'),
    (35, 'IPv6-like, non-hex group',                '2001:db8:gggg::1',                         'INVALID', 'EC-102'),
    (36, 'IPv6-like, 5-digit group',                '2001:db8:12345::1',                        'INVALID', 'not in data'),
    (37, 'IPv6-like, 9 groups',                     '1:2:3:4:5:6:7:8:9',                        'INVALID', 'not in data'),
    (38, 'IPv6-like, 7 groups without ::',          '1:2:3:4:5:6:7',                            'INVALID', 'not in data'),
    (39, 'IPv6-like, 8 groups plus ::',             '1:2:3:4:5:6:7::8',                         'INVALID', 'not in data'),
    (40, 'IPv6 with CIDR suffix',                   '2001:db8::/32',                            'INVALID', 'not in data'),
    (41, 'IPv6-like, trailing single colon',        '2001:db8::1:',                             'INVALID', 'not in data'),
    (42, 'IPv6-like, leading single colon',         ':2001:db8::1',                             'INVALID', 'not in data'),
    (43, 'empty string',                            '',                                         'INVALID', 'not in data');

CREATE TEMP TABLE answer_key (
    log_id integer, case_id text, source text, format_family text, outcome_class text, record_validity text,
    entity_type text, entity_type_validity text, email_address text, email_address_validity text,
    resource_url text, resource_url_validity text, event_timestamp text, event_timestamp_validity text,
    tool text, tool_validity text, latitude text, latitude_validity text, longitude text, longitude_validity text,
    ip_address text, ip_address_validity text, action_phrase text, action_phrase_validity text,
    status text, status_validity text, secondary_values text, scenario_tags text, notes text
);

\copy answer_key FROM 'data/expected_fields.csv' WITH (FORMAT csv, HEADER MATCH, ENCODING 'UTF8')

CREATE TEMP TABLE key_ip AS
SELECT log_id, case_id, format_family, ip_address AS value, ip_address_validity AS key_validity
FROM answer_key
WHERE ip_address_validity IN ('VALID', 'INVALID');

-- -----------------------------------------------------------------------------
-- Evaluation of every distinct value: PostgreSQL inet input + the proposed VAL-IP rule
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE ip_eval AS
WITH v AS (
    SELECT value FROM ip_probe
    UNION
    SELECT value FROM key_ip
)
SELECT value,
       pg_input_is_valid(value, 'inet')                                          AS inet_valid,
       (pg_input_error_info(value, 'inet')).message                              AS inet_error,
       CASE WHEN pg_input_is_valid(value, 'inet') THEN value::inet::text END     AS inet_text,
       CASE WHEN pg_input_is_valid(value, 'inet') THEN family(value::inet) END   AS inet_family,
       CASE WHEN pg_input_is_valid(value, 'inet') THEN masklen(value::inet) END  AS inet_masklen,
       -- Proposed VAL-IP rule, part A: IPv4 dotted quad, octets 0-255, no leading zeros
       value ~ '^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$'
                                                                                 AS rule_ipv4,
       -- Proposed VAL-IP rule, part B1: IPv6 character shape (hex groups and colons, optional strict
       -- dotted IPv4 tail, optional zone id); no brackets, port, prefix length or whitespace
       value ~ '^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3})?(%[0-9A-Za-z._~-]+)?$'
                                                                                 AS rule_ipv6_shape
FROM v;

-- Part B2: PostgreSQL inet decides group count, "::" usage and group length for the address without the zone id
ALTER TABLE ip_eval ADD COLUMN rule_ipv6_inet boolean;
UPDATE ip_eval
SET rule_ipv6_inet = CASE WHEN rule_ipv6_shape THEN pg_input_is_valid(split_part(value, '%', 1), 'inet') ELSE false END;

ALTER TABLE ip_eval ADD COLUMN rule_validity text;
UPDATE ip_eval
SET rule_validity = CASE WHEN rule_ipv4 OR (rule_ipv6_shape AND rule_ipv6_inet) THEN 'VALID' ELSE 'INVALID' END;

-- -----------------------------------------------------------------------------
\echo
\echo '== 2. Targeted probes: PostgreSQL inet vs Step 2 VAL-IP =='
SELECT p.probe_no                         AS no,
       p.form,
       p.value,
       p.step2_expected                   AS step2,
       e.inet_valid                       AS inet_ok,
       e.inet_text,
       e.inet_family                      AS fam,
       e.inet_masklen                     AS mask,
       e.inet_error,
       e.rule_validity                    AS rule,
       e.rule_validity = p.step2_expected AS rule_ok
FROM ip_probe p
JOIN ip_eval e USING (value)
ORDER BY p.probe_no;

-- -----------------------------------------------------------------------------
\echo
\echo '== 3. Answer key: IP values by form (VALID and INVALID labels only) =='
CREATE TEMP TABLE key_ip_form AS
SELECT k.*,
       CASE
           WHEN k.value ~ '^[0-9]+([.][0-9]+)*$' THEN
               CASE
                   WHEN cardinality(string_to_array(k.value, '.')) <> 4
                       THEN 'IPv4-like, ' || cardinality(string_to_array(k.value, '.')) || ' groups'
                   WHEN k.value ~ '(^|[.])0[0-9]' THEN 'IPv4 leading zeros'
                   WHEN EXISTS (SELECT 1 FROM unnest(string_to_array(k.value, '.')) AS o(octet)
                                WHERE length(o.octet) > 3 OR o.octet::integer > 255)
                       THEN 'IPv4 octet > 255'
                   ELSE 'IPv4 dotted quad'
               END
           WHEN strpos(k.value, ':') > 0 THEN
               CASE
                   WHEN strpos(k.value, '%') > 0 THEN 'IPv6 with zone id'
                   WHEN k.value ~ '[^0-9A-Fa-f:.]' THEN 'IPv6-like, non-hex characters'
                   WHEN (length(k.value) - length(replace(k.value, '::', ''))) / 2 > 1 THEN 'IPv6-like, two ::'
                   WHEN strpos(k.value, '.') > 0 THEN 'IPv6 IPv4-mapped'
                   WHEN strpos(k.value, '::') > 0 THEN 'IPv6 compressed'
                   ELSE 'IPv6 full 8 groups'
               END
           ELSE 'other'
       END AS form
FROM key_ip k;

SELECT f.form,
       f.key_validity,
       count(*)                                                              AS rows,
       count(*) FILTER (WHERE e.inet_valid)                                  AS inet_accepts,
       count(*) FILTER (WHERE NOT e.inet_valid)                              AS inet_rejects,
       count(*) FILTER (WHERE e.inet_valid = (f.key_validity = 'VALID'))     AS inet_agrees,
       count(*) FILTER (WHERE e.rule_validity = f.key_validity)              AS rule_agrees
FROM key_ip_form f
JOIN ip_eval e USING (value)
GROUP BY f.form, f.key_validity
ORDER BY f.key_validity DESC, rows DESC;

\echo
\echo '== 4. Answer-key values where plain inet input disagrees with the label =='
SELECT f.form,
       f.value,
       f.key_validity,
       e.inet_valid,
       e.inet_text,
       count(*)                                           AS rows,
       string_agg(f.case_id, ', ' ORDER BY f.log_id)      AS cases
FROM key_ip_form f
JOIN ip_eval e USING (value)
WHERE e.inet_valid <> (f.key_validity = 'VALID')
GROUP BY f.form, f.value, f.key_validity, e.inet_valid, e.inet_text
ORDER BY f.form, f.value;

\echo
\echo '== 5. Summary: plain inet vs proposed rule, against the answer key =='
SELECT 'plain inet input (pg_input_is_valid)'                         AS method,
       count(*)                                                       AS labelled_values,
       count(*) FILTER (WHERE e.inet_valid = (k.key_validity = 'VALID')) AS agree,
       count(*) FILTER (WHERE e.inet_valid <> (k.key_validity = 'VALID')) AS disagree
FROM key_ip k JOIN ip_eval e USING (value)
UNION ALL
SELECT 'proposed VAL-IP rule',
       count(*),
       count(*) FILTER (WHERE e.rule_validity = k.key_validity),
       count(*) FILTER (WHERE e.rule_validity <> k.key_validity)
FROM key_ip k JOIN ip_eval e USING (value);

\echo
\echo '== 6. inet text normalisation (why the parser must store the original substring) =='
SELECT value, inet_text, value = inet_text AS unchanged
FROM ip_eval
WHERE inet_valid
  AND value IN ('2001:0db8:0000:0000:0000:ff00:0042:8329', '2001:DB8::1', '::ffff:192.0.2.10',
                '192.0.2.115', '192.0.2.1/32', '192.0.2.1/24', '2001:db8::/32', '2001:db8:d09:e59e::3b83')
ORDER BY value;

\echo
\echo '== 7. Raw input untouched and answer-key IP values present in their raw logs =='
SELECT (SELECT count(*) FILTER (WHERE passed) FROM log_regex.verify_raw_access_logs()) AS integrity_checks_passed,
       (SELECT count(*) FROM log_regex.verify_raw_access_logs())                       AS integrity_checks_total,
       count(*)                                                                         AS key_ip_values,
       count(*) FILTER (WHERE strpos(r.raw_log, k.value) > 0)                           AS found_in_raw_log
FROM key_ip k
JOIN log_regex.raw_access_logs r USING (log_id);

\echo
\echo '== 8. Result =='
DO $$
DECLARE
    rule_vs_key    integer;
    rule_vs_probes integer;
    raw_failures   integer;
    not_in_raw     integer;
BEGIN
    SELECT count(*) INTO rule_vs_key
    FROM key_ip k JOIN ip_eval e USING (value) WHERE e.rule_validity <> k.key_validity;
    SELECT count(*) INTO rule_vs_probes
    FROM ip_probe p JOIN ip_eval e USING (value) WHERE e.rule_validity <> p.step2_expected;
    SELECT count(*) INTO raw_failures FROM log_regex.verify_raw_access_logs() WHERE NOT passed;
    SELECT count(*) INTO not_in_raw
    FROM key_ip k JOIN log_regex.raw_access_logs r USING (log_id) WHERE strpos(r.raw_log, k.value) = 0;
    IF rule_vs_key + rule_vs_probes + raw_failures + not_in_raw > 0 THEN
        RAISE EXCEPTION 'Step 3B-2 FAILED: rule vs key %, rule vs probes %, raw integrity %, values not in raw %',
            rule_vs_key, rule_vs_probes, raw_failures, not_in_raw;
    END IF;
    RAISE NOTICE 'Step 3B-2 PASSED: proposed VAL-IP rule matches all labelled answer-key values and all 43 probes; raw input unchanged';
END
$$;
