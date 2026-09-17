-- =============================================================================
-- Step 5A review / 27 - Verify the four foreign keys of log_regex.access_log_flat (read-only)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/27_verify_access_log_flat_foreign_keys.sql
--
-- Required by the Step 5A review: the flat-table implementation must run this check after installing the table and
-- again after every load. It reads the system catalog only, inside a READ ONLY transaction that is rolled back.
--   * While log_regex.access_log_flat does not exist: reports "nothing to verify" and exits 0.
--   * Otherwise: exits non-zero (SQLSTATE LR004) unless the table has exactly these foreign keys, all validated,
--     compared by definition (columns, referenced table and columns, ON UPDATE and ON DELETE actions):
--       1  (log_id)                -> log_regex.raw_access_logs (log_id)            RESTRICT  / RESTRICT
--       2  (run_id, log_id)        -> log_regex.parsed_log (run_id, log_id)         RESTRICT  / RESTRICT
--       3  (entity_type_code)      -> log_regex.ref_entity_type (entity_type)       NO ACTION / NO ACTION
--       4  (event_timestamp_shape) -> log_regex.ref_timestamp_shape (shape_name)    NO ACTION / NO ACTION
--     A key with a different name but the same definition passes and its name is reported.
-- The psql variable flat_table (default log_regex.access_log_flat) exists only so the check can be tested against
-- another table; the implementation uses the default.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

\if :{?flat_table}
\else
    \set flat_table log_regex.access_log_flat
\endif

BEGIN TRANSACTION READ ONLY;

SELECT set_config('flat_fk_check.table', :'flat_table', true) AS checked_table,
       to_regclass(:'flat_table') IS NOT NULL                 AS table_exists;

\echo '== Foreign keys currently defined on the checked table'
SELECT c.conname,
       ARRAY(SELECT a.attname::text
             FROM unnest(c.conkey) WITH ORDINALITY AS k (attnum, ord)
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
             ORDER BY k.ord)                                                          AS columns,
       rn.nspname || '.' || rc.relname                                                AS referenced_table,
       ARRAY(SELECT a.attname::text
             FROM unnest(c.confkey) WITH ORDINALITY AS k (attnum, ord)
             JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum
             ORDER BY k.ord)                                                          AS referenced_columns,
       CASE c.confupdtype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT' WHEN 'c' THEN 'CASCADE'
                          WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END    AS on_update,
       CASE c.confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT' WHEN 'c' THEN 'CASCADE'
                          WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END    AS on_delete,
       c.convalidated
FROM pg_constraint c
JOIN pg_class rc     ON rc.oid = c.confrelid
JOIN pg_namespace rn ON rn.oid = rc.relnamespace
WHERE c.contype = 'f'
  AND c.conrelid = to_regclass(current_setting('flat_fk_check.table'))
ORDER BY c.conname;

\echo '== Verdict'
DO $$
DECLARE
    v_table    text     := current_setting('flat_fk_check.table');
    v_relid    regclass := to_regclass(current_setting('flat_fk_check.table'));
    v_expected integer  := 0;
    v_found    integer  := 0;
    v_failures integer  := 0;
    v_total    integer;
    r          record;
BEGIN
    IF v_relid IS NULL THEN
        RAISE NOTICE 'access_log_flat foreign-key check: % does not exist yet, nothing to verify. Run this check after installing the table and after every load.', v_table;
        RETURN;
    END IF;

    FOR r IN
        WITH expected (fk_no, expected_name, columns, referenced_table, referenced_columns, on_update, on_delete) AS (
            -- BEGIN expected foreign keys
            VALUES (1, 'access_log_flat_raw_log_fkey',               ARRAY['log_id'],                'log_regex.raw_access_logs',     ARRAY['log_id'],           'RESTRICT',  'RESTRICT'),
                   (2, 'access_log_flat_parsed_log_fkey',            ARRAY['run_id', 'log_id'],      'log_regex.parsed_log',          ARRAY['run_id', 'log_id'], 'RESTRICT',  'RESTRICT'),
                   (3, 'access_log_flat_entity_type_code_fkey',      ARRAY['entity_type_code'],      'log_regex.ref_entity_type',     ARRAY['entity_type'],      'NO ACTION', 'NO ACTION'),
                   (4, 'access_log_flat_event_timestamp_shape_fkey', ARRAY['event_timestamp_shape'], 'log_regex.ref_timestamp_shape', ARRAY['shape_name'],       'NO ACTION', 'NO ACTION')
            -- END expected foreign keys
        ),
        actual AS (
            SELECT c.conname::text AS conname,
                   c.convalidated,
                   ARRAY(SELECT a.attname::text
                         FROM unnest(c.conkey) WITH ORDINALITY AS k (attnum, ord)
                         JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                         ORDER BY k.ord)                                              AS columns,
                   rn.nspname || '.' || rc.relname                                    AS referenced_table,
                   ARRAY(SELECT a.attname::text
                         FROM unnest(c.confkey) WITH ORDINALITY AS k (attnum, ord)
                         JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum
                         ORDER BY k.ord)                                              AS referenced_columns,
                   CASE c.confupdtype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT' WHEN 'c' THEN 'CASCADE'
                                      WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END AS on_update,
                   CASE c.confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT' WHEN 'c' THEN 'CASCADE'
                                      WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END AS on_delete
            FROM pg_constraint c
            JOIN pg_class rc     ON rc.oid = c.confrelid
            JOIN pg_namespace rn ON rn.oid = rc.relnamespace
            WHERE c.contype = 'f' AND c.conrelid = v_relid
        )
        SELECT DISTINCT ON (e.fk_no)
               e.fk_no, e.expected_name, e.columns, e.referenced_table, e.referenced_columns, e.on_update, e.on_delete,
               a.conname, a.convalidated
        FROM expected e
        LEFT JOIN actual a
               ON a.columns = e.columns
              AND a.referenced_table = e.referenced_table
              AND a.referenced_columns = e.referenced_columns
              AND a.on_update = e.on_update
              AND a.on_delete = e.on_delete
        ORDER BY e.fk_no, a.convalidated DESC NULLS LAST
    LOOP
        v_expected := v_expected + 1;
        IF r.conname IS NULL THEN
            v_failures := v_failures + 1;
            RAISE WARNING 'FK % MISSING: (%) -> % (%) ON UPDATE % ON DELETE %',
                r.fk_no, array_to_string(r.columns, ', '), r.referenced_table,
                array_to_string(r.referenced_columns, ', '), r.on_update, r.on_delete;
        ELSIF NOT r.convalidated THEN
            v_failures := v_failures + 1;
            RAISE WARNING 'FK % NOT VALIDATED: %', r.fk_no, r.conname;
        ELSE
            v_found := v_found + 1;
            RAISE NOTICE 'FK % OK: % (%) -> % (%) ON UPDATE % ON DELETE %',
                r.fk_no, r.conname, array_to_string(r.columns, ', '), r.referenced_table,
                array_to_string(r.referenced_columns, ', '), r.on_update,
                r.on_delete || CASE WHEN r.conname <> r.expected_name
                                    THEN ' (expected name ' || r.expected_name || ')' ELSE '' END;
        END IF;
    END LOOP;

    SELECT count(*) INTO v_total FROM pg_constraint c WHERE c.contype = 'f' AND c.conrelid = v_relid;

    IF v_failures > 0 OR v_total <> v_found THEN
        RAISE EXCEPTION 'access_log_flat foreign-key check FAILED on %: % of % expected foreign keys present and validated; % foreign keys defined',
            v_table, v_found, v_expected, v_total
            USING ERRCODE = 'LR004';
    END IF;
    RAISE NOTICE 'access_log_flat foreign-key check PASSED on %: exactly the % expected foreign keys, all validated', v_table, v_expected;
END
$$;

ROLLBACK;
