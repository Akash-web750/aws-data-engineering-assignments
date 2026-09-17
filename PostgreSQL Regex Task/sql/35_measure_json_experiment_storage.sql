-- =============================================================================
-- Step 6B / 35 - Storage measurements of the JSON and JSONB experiment tables (read-only)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/35_measure_json_experiment_storage.sql [-o <file>]
--
-- Design section 5 (M-01 ... M-07; M-08 write cost and M-09 are not part of Step 6B). Core functions only, READ ONLY
-- transaction, rolled back. Run after sql/33 (which ends with VACUUM (ANALYZE) on both tables). No EXPLAIN, no timing.
-- Section headers use \qecho so they go to the same output as the result tables.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\pset footer off

BEGIN TRANSACTION READ ONLY;

SET LOCAL search_path = pg_catalog, pg_temp;

\qecho '== Environment'
SELECT current_setting('server_version') AS server_version, current_setting('block_size') AS block_size,
       current_setting('default_toast_compression') AS default_toast_compression, now() AS measured_at;

\qecho '== M-01 .. M-04  Relations (bytes) after VACUUM (ANALYZE)'
SELECT c.relname                                                       AS table_name,
       format_type(a.atttypid, a.atttypmod)                            AS doc_type,
       a.attstorage                                                    AS storage,
       coalesce(nullif(a.attcompression::text, ''), 'default')         AS compression,
       c.reloptions,
       c.relpages                                                      AS pages,
       c.reltuples::bigint                                             AS reltuples,
       pg_relation_size(c.oid, 'main')                                 AS main_bytes,
       pg_relation_size(c.oid, 'fsm')                                  AS fsm_bytes,
       pg_relation_size(c.oid, 'vm')                                   AS vm_bytes,
       pg_relation_size(c.reltoastrelid)                               AS toast_bytes,
       pg_indexes_size(c.reltoastrelid)                                AS toast_index_bytes,
       pg_table_size(c.oid)                                            AS table_bytes,
       pg_indexes_size(c.oid)                                          AS pk_index_bytes,
       pg_total_relation_size(c.oid)                                   AS total_bytes
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'doc'
WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
ORDER BY c.relname;

SELECT c.relname AS table_name,
       pg_size_pretty(pg_relation_size(c.oid, 'main'))    AS main,
       pg_size_pretty(pg_relation_size(c.reltoastrelid))  AS toast,
       pg_size_pretty(pg_table_size(c.oid))               AS table_size,
       pg_size_pretty(pg_indexes_size(c.oid))             AS pk_index,
       pg_size_pretty(pg_total_relation_size(c.oid))      AS total,
       round(pg_relation_size(c.oid, 'main')::numeric / nullif(c.reltuples, 0)::numeric, 1) AS main_bytes_per_row,
       round(c.reltuples::numeric / nullif(c.relpages, 0), 2)                               AS rows_per_page,
       s.n_live_tup, s.n_dead_tup, s.vacuum_count + s.autovacuum_count AS vacuums, s.analyze_count + s.autoanalyze_count AS analyzes
FROM pg_class c
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
ORDER BY c.relname;

\qecho '== Reference only (not part of the comparison): access_log_flat'
SELECT 'access_log_flat' AS table_name, c.relpages AS pages, pg_relation_size(c.oid, 'main') AS main_bytes,
       pg_relation_size(c.reltoastrelid) AS toast_bytes, pg_indexes_size(c.oid) AS index_bytes, pg_total_relation_size(c.oid) AS total_bytes
FROM pg_class c WHERE c.oid = 'log_regex.access_log_flat'::regclass;

\qecho '== M-05 / M-06  Per document (bytes): stored datum (pg_column_size), text (octet_length(doc::text)), whole row'
WITH d AS (
    SELECT 'json' AS doc_type, pg_column_size(t.doc) AS stored_bytes, octet_length(t.doc::text) AS text_bytes, pg_column_size(t.*) AS row_bytes
    FROM log_regex_json.access_log_json t
    UNION ALL
    SELECT 'jsonb', pg_column_size(t.doc), octet_length(t.doc::text), pg_column_size(t.*)
    FROM log_regex_json.access_log_jsonb t
),
m AS (
    SELECT doc_type, 'stored datum' AS measure, stored_bytes AS bytes FROM d
    UNION ALL SELECT doc_type, 'output text', text_bytes FROM d
    UNION ALL SELECT doc_type, 'whole row', row_bytes FROM d
)
SELECT measure, doc_type, count(*) AS docs, min(bytes) AS min,
       percentile_disc(0.25) WITHIN GROUP (ORDER BY bytes) AS p25,
       percentile_disc(0.50) WITHIN GROUP (ORDER BY bytes) AS p50,
       percentile_disc(0.75) WITHIN GROUP (ORDER BY bytes) AS p75,
       percentile_disc(0.90) WITHIN GROUP (ORDER BY bytes) AS p90,
       percentile_disc(0.99) WITHIN GROUP (ORDER BY bytes) AS p99,
       max(bytes) AS max, round(avg(bytes), 1) AS avg, sum(bytes) AS sum
FROM m
GROUP BY measure, doc_type
ORDER BY measure, doc_type;

\qecho '== M-06  Canonical input text (identical input for both types; equals the stored json text, see sql/34 B-03)'
SELECT count(*) AS docs, min(octet_length(doc::text)) AS min, percentile_disc(0.5) WITHIN GROUP (ORDER BY octet_length(doc::text)) AS p50,
       max(octet_length(doc::text)) AS max, sum(octet_length(doc::text)) AS sum,
       sum(char_length(doc::text)) AS characters
FROM log_regex_json.access_log_json;

\qecho '== Per-document stored size, jsonb minus json (same log_id)'
WITH p AS (
    SELECT pg_column_size(b.doc) - pg_column_size(j.doc) AS diff,
           octet_length(b.doc::text) - octet_length(j.doc::text) AS text_diff
    FROM log_regex_json.access_log_json j JOIN log_regex_json.access_log_jsonb b ON b.log_id = j.log_id
)
SELECT count(*) AS docs, min(diff) AS min_diff, percentile_disc(0.5) WITHIN GROUP (ORDER BY diff) AS p50_diff, max(diff) AS max_diff,
       sum(diff) AS sum_diff, count(*) FILTER (WHERE diff > 0) AS jsonb_larger, count(*) FILTER (WHERE diff = 0) AS equal,
       count(*) FILTER (WHERE diff < 0) AS jsonb_smaller,
       min(text_diff) AS min_output_text_diff, max(text_diff) AS max_output_text_diff
FROM p;

\qecho '== Uncompressed datum size per document (value rebuilt in memory from its text, never compressed)'
WITH d AS (
    SELECT 'json' AS doc_type, pg_column_size(t.doc::text::json) AS bytes FROM log_regex_json.access_log_json t
    UNION ALL
    SELECT 'jsonb', pg_column_size(t.doc::text::jsonb) FROM log_regex_json.access_log_jsonb t
)
SELECT doc_type, count(*) AS docs, min(bytes) AS min,
       percentile_disc(0.25) WITHIN GROUP (ORDER BY bytes) AS p25,
       percentile_disc(0.50) WITHIN GROUP (ORDER BY bytes) AS p50,
       percentile_disc(0.75) WITHIN GROUP (ORDER BY bytes) AS p75,
       percentile_disc(0.99) WITHIN GROUP (ORDER BY bytes) AS p99,
       max(bytes) AS max, round(avg(bytes), 1) AS avg, sum(bytes) AS sum
FROM d GROUP BY doc_type ORDER BY doc_type;

\qecho '== jsonb documents split by inline compression, with the same documents in json (bytes)'
WITH p AS (
    SELECT pg_column_compression(b.doc) IS NOT NULL AS jsonb_compressed,
           pg_column_compression(j.doc) IS NOT NULL AS json_compressed,
           pg_column_size(j.doc) AS json_stored, pg_column_size(b.doc) AS jsonb_stored,
           pg_column_size(j.doc::text::json) AS json_uncompressed, pg_column_size(b.doc::text::jsonb) AS jsonb_uncompressed,
           pg_column_size(j.*) AS json_row, pg_column_size(b.*) AS jsonb_row
    FROM log_regex_json.access_log_json j JOIN log_regex_json.access_log_jsonb b ON b.log_id = j.log_id
)
SELECT CASE WHEN jsonb_compressed THEN 'jsonb compressed' ELSE 'jsonb not compressed' END AS jsonb_group,
       count(*) AS docs, count(*) FILTER (WHERE json_compressed) AS json_compressed_docs,
       round(avg(json_uncompressed), 1) AS avg_json_uncompressed, round(avg(jsonb_uncompressed), 1) AS avg_jsonb_uncompressed,
       round(avg(json_stored), 1) AS avg_json_stored, round(avg(jsonb_stored), 1) AS avg_jsonb_stored,
       min(jsonb_uncompressed - json_uncompressed) AS min_uncompressed_diff, max(jsonb_uncompressed - json_uncompressed) AS max_uncompressed_diff,
       min(jsonb_row) AS min_jsonb_row, max(jsonb_row) AS max_jsonb_row, max(json_row) AS max_json_row,
       sum(json_stored) AS sum_json_stored, sum(jsonb_stored) AS sum_jsonb_stored
FROM p GROUP BY 1 ORDER BY 1;

\qecho '== Stored-size distribution (100-byte buckets)'
WITH d AS (
    SELECT 'json' AS doc_type, pg_column_size(doc) AS bytes FROM log_regex_json.access_log_json
    UNION ALL SELECT 'jsonb', pg_column_size(doc) FROM log_regex_json.access_log_jsonb
)
SELECT (bytes / 100) * 100 AS from_bytes, (bytes / 100) * 100 + 99 AS to_bytes,
       count(*) FILTER (WHERE doc_type = 'json') AS json_docs, count(*) FILTER (WHERE doc_type = 'jsonb') AS jsonb_docs
FROM d GROUP BY 1, 2 ORDER BY 1;

\qecho '== M-07  Compression and out-of-line (TOAST) storage'
WITH d AS (
    SELECT 'json' AS doc_type, t.log_id, pg_column_compression(t.doc) AS compression, pg_column_toast_chunk_id(t.doc) AS chunk_id,
           pg_column_size(t.doc) AS stored_bytes, octet_length(t.doc::text) AS text_bytes
    FROM log_regex_json.access_log_json t
    UNION ALL
    SELECT 'jsonb', t.log_id, pg_column_compression(t.doc), pg_column_toast_chunk_id(t.doc), pg_column_size(t.doc), octet_length(t.doc::text)
    FROM log_regex_json.access_log_jsonb t
)
SELECT doc_type, count(*) AS docs,
       count(*) FILTER (WHERE compression IS NOT NULL) AS compressed,
       coalesce(string_agg(DISTINCT compression, ','), '-') AS methods,
       count(*) FILTER (WHERE chunk_id IS NOT NULL) AS out_of_line,
       count(*) FILTER (WHERE text_bytes >= 2000) AS text_2000_bytes_or_more,
       count(*) FILTER (WHERE stored_bytes >= 2000) AS stored_2000_bytes_or_more
FROM d GROUP BY doc_type ORDER BY doc_type;

SELECT c.relname AS table_name, c.reltoastrelid::regclass AS toast_table,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM %s', c.reltoastrelid::regclass), false, true, '')))[1]::text AS toast_chunks,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(DISTINCT chunk_id) AS n FROM %s', c.reltoastrelid::regclass), false, true, '')))[1]::text AS toasted_values,
       (xpath('/row/n/text()', query_to_xml(format('SELECT coalesce(sum(octet_length(chunk_data)), 0) AS n FROM %s', c.reltoastrelid::regclass), false, true, '')))[1]::text AS chunk_data_bytes
FROM pg_class c
WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
ORDER BY c.relname;

\qecho '== Documents that are compressed or stored out of line: total per type, then the first 20 by log_id (no rows = none)'
WITH d AS (
    SELECT 'json' AS doc_type, pg_column_compression(t.doc) AS compression, pg_column_toast_chunk_id(t.doc) AS chunk_id
    FROM log_regex_json.access_log_json t
    UNION ALL
    SELECT 'jsonb', pg_column_compression(t.doc), pg_column_toast_chunk_id(t.doc)
    FROM log_regex_json.access_log_jsonb t
)
SELECT doc_type, count(*) FILTER (WHERE compression IS NOT NULL OR chunk_id IS NOT NULL) AS compressed_or_out_of_line
FROM d GROUP BY doc_type ORDER BY doc_type;

WITH d AS (
    SELECT 'json' AS doc_type, t.log_id, octet_length(t.doc::text) AS text_bytes, pg_column_size(t.doc) AS stored_bytes,
           pg_column_size(t.*) AS row_bytes, pg_column_compression(t.doc) AS compression, pg_column_toast_chunk_id(t.doc) AS chunk_id
    FROM log_regex_json.access_log_json t
    UNION ALL
    SELECT 'jsonb', t.log_id, octet_length(t.doc::text), pg_column_size(t.doc), pg_column_size(t.*),
           pg_column_compression(t.doc), pg_column_toast_chunk_id(t.doc)
    FROM log_regex_json.access_log_jsonb t
)
SELECT log_id, doc_type, text_bytes, stored_bytes, row_bytes, coalesce(compression, '-') AS compression, chunk_id IS NOT NULL AS out_of_line
FROM d
WHERE compression IS NOT NULL OR chunk_id IS NOT NULL
ORDER BY log_id, doc_type
LIMIT 20;

\qecho '== Documents near the TOAST threshold (whole row at least 2,032 bytes before compression is attempted)'
WITH d AS (
    SELECT 'json' AS doc_type, octet_length(t.doc::text) AS text_bytes, pg_column_size(t.*) AS row_bytes FROM log_regex_json.access_log_json t
    UNION ALL
    SELECT 'jsonb', octet_length(t.doc::text), pg_column_size(t.*) FROM log_regex_json.access_log_jsonb t
)
SELECT doc_type, count(*) FILTER (WHERE text_bytes >= 1500) AS text_1500_or_more, count(*) FILTER (WHERE text_bytes >= 2000) AS text_2000_or_more,
       count(*) FILTER (WHERE row_bytes >= 2032) AS stored_row_2032_or_more, max(row_bytes) AS max_stored_row_bytes
FROM d GROUP BY doc_type ORDER BY doc_type;

\qecho '== Five largest documents by stored size'
(SELECT 'json' AS doc_type, t.log_id, octet_length(t.doc::text) AS text_bytes, pg_column_size(t.doc) AS stored_bytes,
        coalesce(pg_column_compression(t.doc), '-') AS compression, pg_column_toast_chunk_id(t.doc) IS NOT NULL AS out_of_line
 FROM log_regex_json.access_log_json t ORDER BY pg_column_size(t.doc) DESC, t.log_id LIMIT 5)
UNION ALL
(SELECT 'jsonb', t.log_id, octet_length(t.doc::text), pg_column_size(t.doc),
        coalesce(pg_column_compression(t.doc), '-'), pg_column_toast_chunk_id(t.doc) IS NOT NULL
 FROM log_regex_json.access_log_jsonb t ORDER BY pg_column_size(t.doc) DESC, t.log_id LIMIT 5);

\qecho '== Heap accounting: documents, rows and page overhead (bytes)'
SELECT 'access_log_json' AS table_name, sum(pg_column_size(t.doc)) AS doc_bytes, sum(pg_column_size(t.*)) AS row_bytes,
       pg_relation_size('log_regex_json.access_log_json'::regclass, 'main') AS main_bytes,
       pg_relation_size('log_regex_json.access_log_json'::regclass, 'main') - sum(pg_column_size(t.*)) AS main_minus_rows
FROM log_regex_json.access_log_json t
UNION ALL
SELECT 'access_log_jsonb', sum(pg_column_size(t.doc)), sum(pg_column_size(t.*)),
       pg_relation_size('log_regex_json.access_log_jsonb'::regclass, 'main'),
       pg_relation_size('log_regex_json.access_log_jsonb'::regclass, 'main') - sum(pg_column_size(t.*))
FROM log_regex_json.access_log_jsonb t;

ROLLBACK;
