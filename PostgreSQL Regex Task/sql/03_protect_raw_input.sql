-- =============================================================================
-- Step 3B-1 / 03 - Baseline and protection for the loaded RAW LOGS
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -v source_file_sha256=<hex> -d postgresql_regex_task \
--        -f sql/03_protect_raw_input.sql
--
-- source_file_sha256 = SHA-256 of data/raw_access_logs.csv (computed outside the database).
--
-- Creates:
--   raw_log_fingerprint          per-row baseline: NULL flag, lengths, SHA-256 of the UTF-8 bytes
--   raw_access_logs_digest()     dataset digest, same definition as scripts/raw_csv_digest.py
--   raw_load_audit               single-row record of the load (source hash, counts, digest)
--   block_raw_input_modification guard trigger function (SQLSTATE LR001)
--   *_read_only triggers         reject INSERT/UPDATE/DELETE/TRUNCATE (also MERGE and COPY FROM)
--   verify_raw_access_logs()     repeatable integrity check against the baseline
--
-- These are integrity objects for the raw input only; no parsing or regex extraction happens here.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

\if :{?source_file_sha256}
\else
    \echo 'ERROR: pass -v source_file_sha256=<SHA-256 of data/raw_access_logs.csv>'
    DO $$ BEGIN RAISE EXCEPTION 'psql variable source_file_sha256 is required'; END $$;
\endif

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Per-row fingerprints
-- -----------------------------------------------------------------------------
CREATE TABLE log_regex.raw_log_fingerprint (
    log_id        integer NOT NULL,
    is_null       boolean NOT NULL,
    char_length   integer,
    octet_length  integer,
    sha256        bytea,
    CONSTRAINT raw_log_fingerprint_pkey PRIMARY KEY (log_id),
    CONSTRAINT raw_log_fingerprint_log_id_fkey
        FOREIGN KEY (log_id) REFERENCES log_regex.raw_access_logs (log_id),
    CONSTRAINT raw_log_fingerprint_null_consistency CHECK (
           (is_null     AND char_length IS NULL     AND octet_length IS NULL     AND sha256 IS NULL)
        OR (NOT is_null AND char_length IS NOT NULL AND octet_length IS NOT NULL AND sha256 IS NOT NULL))
);

COMMENT ON TABLE log_regex.raw_log_fingerprint IS
    'Baseline taken right after the load: one row per log_id with NULL flag, character and UTF-8 byte '
    'length, and SHA-256 of the UTF-8 bytes of raw_log.';

INSERT INTO log_regex.raw_log_fingerprint (log_id, is_null, char_length, octet_length, sha256)
SELECT log_id,
       raw_log IS NULL,
       char_length(raw_log),
       octet_length(raw_log),
       sha256(convert_to(raw_log, 'UTF8'))
FROM log_regex.raw_access_logs;

-- -----------------------------------------------------------------------------
-- 2. Dataset digest (identical definition to scripts/raw_csv_digest.py)
-- -----------------------------------------------------------------------------
CREATE FUNCTION log_regex.raw_access_logs_digest()
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT encode(
               sha256(convert_to(
                   coalesce(string_agg(
                       log_id::text || ':' ||
                       coalesce(encode(sha256(convert_to(raw_log, 'UTF8')), 'hex'), 'NULL'),
                       E'\n' ORDER BY log_id), ''),
                   'UTF8')),
               'hex')
    FROM log_regex.raw_access_logs
$$;

COMMENT ON FUNCTION log_regex.raw_access_logs_digest() IS
    'SHA-256 (hex) of the lines "<log_id>:<hex sha256 of UTF-8 raw_log>" (or "<log_id>:NULL"), '
    'joined with LF in log_id order.';

-- -----------------------------------------------------------------------------
-- 3. Load audit (exactly one row)
-- -----------------------------------------------------------------------------
CREATE TABLE log_regex.raw_load_audit (
    load_id             smallint    NOT NULL DEFAULT 1,
    source_file         text        NOT NULL,
    source_file_sha256  text        NOT NULL,
    row_count           integer     NOT NULL,
    min_log_id          integer     NOT NULL,
    max_log_id          integer     NOT NULL,
    null_count          integer     NOT NULL,
    empty_string_count  integer     NOT NULL,
    total_char_length   bigint      NOT NULL,
    total_utf8_octets   bigint      NOT NULL,
    dataset_digest      text        NOT NULL,
    loaded_at           timestamptz NOT NULL DEFAULT now(),
    loaded_by           text        NOT NULL DEFAULT current_user,
    CONSTRAINT raw_load_audit_pkey        PRIMARY KEY (load_id),
    CONSTRAINT raw_load_audit_single_load CHECK (load_id = 1),
    CONSTRAINT raw_load_audit_hex_digests CHECK (source_file_sha256 ~ '^[0-9a-f]{64}$'
                                             AND dataset_digest     ~ '^[0-9a-f]{64}$')
);

COMMENT ON TABLE log_regex.raw_load_audit IS
    'Single-row record of the Step 1 RAW LOG load: source file hash, counts and dataset digest.';

INSERT INTO log_regex.raw_load_audit
       (source_file, source_file_sha256, row_count, min_log_id, max_log_id, null_count,
        empty_string_count, total_char_length, total_utf8_octets, dataset_digest)
SELECT 'data/raw_access_logs.csv',
       lower(:'source_file_sha256'),
       count(*),
       min(log_id),
       max(log_id),
       count(*) FILTER (WHERE raw_log IS NULL),
       count(*) FILTER (WHERE raw_log = ''),
       coalesce(sum(char_length(raw_log)), 0),
       coalesce(sum(octet_length(raw_log)), 0),
       log_regex.raw_access_logs_digest()
FROM log_regex.raw_access_logs;

-- -----------------------------------------------------------------------------
-- 4. Guard trigger: the input tables are read-only
-- -----------------------------------------------------------------------------
CREATE FUNCTION log_regex.block_raw_input_modification()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION '% on %.% is blocked: the RAW LOG input is read-only', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = 'LR001',
              HINT    = 'Rebuild postgresql_regex_task from data/raw_access_logs.csv instead of changing loaded rows.';
END;
$$;

COMMENT ON FUNCTION log_regex.block_raw_input_modification() IS
    'Statement-level guard for the RAW LOG input tables; always raises SQLSTATE LR001.';

CREATE TRIGGER raw_access_logs_read_only
    BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON log_regex.raw_access_logs
    FOR EACH STATEMENT EXECUTE FUNCTION log_regex.block_raw_input_modification();

CREATE TRIGGER raw_log_fingerprint_read_only
    BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON log_regex.raw_log_fingerprint
    FOR EACH STATEMENT EXECUTE FUNCTION log_regex.block_raw_input_modification();

CREATE TRIGGER raw_load_audit_read_only
    BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON log_regex.raw_load_audit
    FOR EACH STATEMENT EXECUTE FUNCTION log_regex.block_raw_input_modification();

REVOKE ALL ON log_regex.raw_access_logs, log_regex.raw_log_fingerprint, log_regex.raw_load_audit FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 5. Repeatable integrity check
-- -----------------------------------------------------------------------------
CREATE FUNCTION log_regex.verify_raw_access_logs()
RETURNS TABLE (check_no integer, check_name text, expected text, actual text, passed boolean)
LANGUAGE sql
STABLE
AS $$
    WITH audit AS (
        SELECT * FROM log_regex.raw_load_audit WHERE load_id = 1
    ),
    current_state AS (
        SELECT count(*)                                AS row_count,
               count(DISTINCT log_id)                  AS distinct_ids,
               min(log_id)                             AS min_log_id,
               max(log_id)                             AS max_log_id,
               count(*) FILTER (WHERE raw_log IS NULL) AS null_count,
               count(*) FILTER (WHERE raw_log = '')    AS empty_string_count,
               coalesce(sum(char_length(raw_log)), 0)  AS total_char_length,
               coalesce(sum(octet_length(raw_log)), 0) AS total_utf8_octets
        FROM log_regex.raw_access_logs
    ),
    fingerprint_diff AS (
        SELECT count(*) AS mismatches
        FROM log_regex.raw_access_logs r
        FULL JOIN log_regex.raw_log_fingerprint f ON f.log_id = r.log_id
        WHERE r.log_id IS NULL
           OR f.log_id IS NULL
           OR f.is_null      <> (r.raw_log IS NULL)
           OR f.char_length  IS DISTINCT FROM char_length(r.raw_log)
           OR f.octet_length IS DISTINCT FROM octet_length(r.raw_log)
           OR f.sha256       IS DISTINCT FROM sha256(convert_to(r.raw_log, 'UTF8'))
    ),
    guards AS (
        SELECT count(*) AS enabled
        FROM pg_trigger t
        JOIN pg_class c     ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'log_regex'
          AND t.tgname IN ('raw_access_logs_read_only', 'raw_log_fingerprint_read_only', 'raw_load_audit_read_only')
          AND t.tgenabled = 'O'
    ),
    digest AS (
        SELECT log_regex.raw_access_logs_digest() AS value
    )
    SELECT v.check_no, v.check_name, v.expected, v.actual, v.expected = v.actual
    FROM audit a, current_state s, fingerprint_diff d, guards g, digest x,
    LATERAL (VALUES
        (1, 'row count equals load audit',                  a.row_count::text,          s.row_count::text),
        (2, 'log_id range equals load audit',               a.min_log_id || '..' || a.max_log_id,
                                                            s.min_log_id || '..' || s.max_log_id),
        (3, 'log_ids distinct and contiguous',              s.row_count::text,
                                                            CASE WHEN s.distinct_ids = s.row_count
                                                                  AND s.max_log_id - s.min_log_id + 1 = s.row_count
                                                                 THEN s.row_count::text ELSE 'gaps or duplicates' END),
        (4, 'NULL raw_log rows equal load audit',           a.null_count::text,         s.null_count::text),
        (5, 'empty-string raw_log rows equal load audit',   a.empty_string_count::text, s.empty_string_count::text),
        (6, 'total characters equal load audit',            a.total_char_length::text,  s.total_char_length::text),
        (7, 'total UTF-8 bytes equal load audit',           a.total_utf8_octets::text,  s.total_utf8_octets::text),
        (8, 'rows differing from their fingerprint',        '0',                        d.mismatches::text),
        (9, 'dataset digest equals load audit',             a.dataset_digest,           x.value),
        (10, 'read-only guard triggers enabled',            '3',                        g.enabled::text)
    ) AS v (check_no, check_name, expected, actual)
    ORDER BY v.check_no
$$;

COMMENT ON FUNCTION log_regex.verify_raw_access_logs() IS
    'Integrity check of log_regex.raw_access_logs against raw_log_fingerprint and raw_load_audit. '
    'Every row must return passed = true.';

COMMIT;

SELECT * FROM log_regex.verify_raw_access_logs();
