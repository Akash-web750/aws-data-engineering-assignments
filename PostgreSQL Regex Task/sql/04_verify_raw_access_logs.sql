-- =============================================================================
-- Step 3B-1 / 04 - Verify the loaded RAW LOGS and their protection
-- =============================================================================
-- Normally run by sql/run_step3b1_setup.ps1, which passes the expected values computed from the CSV
-- by scripts/raw_csv_digest.py (no database involved):
--
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/04_verify_raw_access_logs.sql \
--        -v expected_file_sha256=... -v expected_digest=... -v expected_row_count=... \
--        -v expected_null_ids=... -v expected_empty_ids=... -v expected_whitespace_only=... \
--        -v expected_lf_rows=... -v expected_cr_rows=... -v expected_tab_rows=... \
--        -v expected_nbsp_rows=... -v expected_non_ascii_rows=... -v expected_max_chars=... \
--        -v expected_total_chars=... -v expected_total_octets=...
--
-- Exit status is non-zero if any check fails or any modification is not rejected.
-- The protection tests run each statement in a sub-transaction that is always rolled back.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\echo
\echo '== 1. Integrity against the load baseline (log_regex.verify_raw_access_logs) =='
SELECT * FROM log_regex.verify_raw_access_logs();

\echo
\echo '== 2. Independent comparison with the CSV (scripts/raw_csv_digest.py) =='
CREATE TEMP TABLE csv_comparison AS
WITH s AS (
    SELECT count(*)                                                              AS row_count,
           coalesce(string_agg(log_id::text, ',' ORDER BY log_id) FILTER (WHERE raw_log IS NULL), '') AS null_ids,
           coalesce(string_agg(log_id::text, ',' ORDER BY log_id) FILTER (WHERE raw_log = ''), '')    AS empty_ids,
           count(*) FILTER (WHERE raw_log <> '' AND btrim(raw_log, E' \t\r\n') = '')   AS whitespace_only,
           count(*) FILTER (WHERE strpos(raw_log, E'\n') > 0)                          AS lf_rows,
           count(*) FILTER (WHERE strpos(raw_log, E'\r') > 0)                          AS cr_rows,
           count(*) FILTER (WHERE strpos(raw_log, E'\t') > 0)                          AS tab_rows,
           count(*) FILTER (WHERE strpos(raw_log, U&'\00A0') > 0)                      AS nbsp_rows,
           count(*) FILTER (WHERE octet_length(raw_log) <> char_length(raw_log))       AS non_ascii_rows,
           max(char_length(raw_log))                                                   AS max_chars,
           coalesce(sum(char_length(raw_log)), 0)                                      AS total_chars,
           coalesce(sum(octet_length(raw_log)), 0)                                     AS total_octets
    FROM log_regex.raw_access_logs
)
SELECT v.check_no, v.check_name, v.expected, v.actual, v.expected = v.actual AS passed
FROM s
CROSS JOIN LATERAL (VALUES
    (1,  'dataset digest (per-row SHA-256)',          :'expected_digest',          log_regex.raw_access_logs_digest()),
    (2,  'source file SHA-256 recorded at load',      :'expected_file_sha256',     (SELECT source_file_sha256 FROM log_regex.raw_load_audit)),
    (3,  'row count',                                 :'expected_row_count',       s.row_count::text),
    (4,  'log_ids of SQL NULL raw_log',               :'expected_null_ids',        s.null_ids),
    (5,  'log_ids of empty-string raw_log',           :'expected_empty_ids',       s.empty_ids),
    (6,  'whitespace-only rows',                      :'expected_whitespace_only', s.whitespace_only::text),
    (7,  'rows containing LF',                        :'expected_lf_rows',         s.lf_rows::text),
    (8,  'rows containing CR',                        :'expected_cr_rows',         s.cr_rows::text),
    (9,  'rows containing TAB',                       :'expected_tab_rows',        s.tab_rows::text),
    (10, 'rows containing NBSP (U+00A0)',             :'expected_nbsp_rows',       s.nbsp_rows::text),
    (11, 'rows containing non-ASCII characters',      :'expected_non_ascii_rows',  s.non_ascii_rows::text),
    (12, 'longest raw_log (characters)',              :'expected_max_chars',       s.max_chars::text),
    (13, 'total characters',                          :'expected_total_chars',     s.total_chars::text),
    (14, 'total UTF-8 bytes',                         :'expected_total_octets',    s.total_octets::text)
) AS v (check_no, check_name, expected, actual);

SELECT * FROM csv_comparison ORDER BY check_no;

\echo
\echo '== 3. Special rows kept exactly (NULL, empty, whitespace, CR/LF, longest, first, last) =='
SELECT log_id,
       raw_log IS NULL                      AS is_null,
       char_length(raw_log)                 AS chars,
       octet_length(raw_log)                AS utf8_bytes,
       replace(replace(replace(left(raw_log, 60), E'\r', '<CR>'), E'\n', '<LF>'), E'\t', '<TAB>') AS first_60_chars
FROM log_regex.raw_access_logs
WHERE raw_log IS NULL
   OR raw_log = ''
   OR btrim(raw_log, E' \t\r\n') = ''
   OR strpos(raw_log, E'\r') > 0
   OR strpos(raw_log, E'\n') > 0
   OR char_length(raw_log) = (SELECT max(char_length(raw_log)) FROM log_regex.raw_access_logs)
   OR log_id IN (1, 5000)
ORDER BY log_id;

\echo
\echo '== 4. Protection tests (every statement must be rejected; nothing is kept) =='
CREATE TEMP TABLE protection_test (
    test_no   integer,
    statement text,
    rejected  boolean,
    sqlstate  text,
    message   text
);

DO $$
DECLARE
    tests text[] := ARRAY[
        'INSERT INTO log_regex.raw_access_logs (log_id, raw_log) VALUES (5001, ''injected'')',
        'UPDATE log_regex.raw_access_logs SET raw_log = raw_log WHERE log_id = 1',
        'UPDATE log_regex.raw_access_logs SET raw_log = ''changed'' WHERE false',
        'DELETE FROM log_regex.raw_access_logs WHERE log_id = 5000',
        'TRUNCATE log_regex.raw_access_logs',
        'TRUNCATE log_regex.raw_access_logs CASCADE',
        'MERGE INTO log_regex.raw_access_logs t USING (SELECT 1 AS log_id) s ON t.log_id = s.log_id '
            || 'WHEN MATCHED THEN UPDATE SET raw_log = t.raw_log',
        'UPDATE log_regex.raw_log_fingerprint SET sha256 = NULL, is_null = true, char_length = NULL, octet_length = NULL WHERE log_id = 1',
        'DELETE FROM log_regex.raw_log_fingerprint WHERE log_id = 1',
        'UPDATE log_regex.raw_load_audit SET dataset_digest = repeat(''0'', 64)',
        'TRUNCATE log_regex.raw_load_audit'
    ];
    i integer;
BEGIN
    FOR i IN 1 .. array_length(tests, 1) LOOP
        BEGIN
            EXECUTE tests[i];
            -- Reaching this line means the statement was NOT rejected; abort the sub-transaction anyway.
            RAISE EXCEPTION 'statement was not rejected' USING ERRCODE = 'LR999';
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO protection_test VALUES (i, tests[i], SQLSTATE <> 'LR999', SQLSTATE, SQLERRM);
        END;
    END LOOP;
END
$$;

SELECT test_no, rejected, sqlstate, left(statement, 70) AS statement, message
FROM protection_test
ORDER BY test_no;

\echo
\echo '== 5. Integrity re-check after the protection tests =='
SELECT * FROM log_regex.verify_raw_access_logs();

\echo
\echo '== 6. Result =='
DO $$
DECLARE
    failed_integrity  integer;
    failed_comparison integer;
    not_rejected      integer;
BEGIN
    SELECT count(*) INTO failed_integrity  FROM log_regex.verify_raw_access_logs() WHERE NOT passed;
    SELECT count(*) INTO failed_comparison FROM csv_comparison WHERE NOT passed;
    SELECT count(*) INTO not_rejected      FROM protection_test WHERE NOT rejected;
    IF failed_integrity + failed_comparison + not_rejected > 0 THEN
        RAISE EXCEPTION 'Step 3B-1 verification FAILED: integrity % / CSV comparison % / not rejected %',
            failed_integrity, failed_comparison, not_rejected;
    END IF;
    RAISE NOTICE 'Step 3B-1 verification PASSED: 10 integrity checks, 14 CSV comparisons, 11 modifications rejected';
END
$$;
