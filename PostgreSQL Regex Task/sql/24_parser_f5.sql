-- =============================================================================
-- Step 3B-7 / 24 - F5 extraction: ten semicolon-positional columns
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/24_parser_f5.sql
--
-- Implements the F5-specific stages S3/S4 (Step 3A section 7.5):
--   The event line (first line) is split at every semicolon into columns. No F5 value contains a semicolon
--   (Step 2 4.6), so the split is not quote-aware: a double quote or apostrophe is an ordinary character, e.g. the
--   arc-minute and arc-second signs of a DMS coordinate (23 deg 33'01.8"S), and the value is kept verbatim.
--   Column n -> field through ref_key_alias (F5, key = n). start_pos = 1 + the lengths of the previous columns
--   and their semicolons.
--   A column that is empty (or blanks only) is returned as '' and becomes MISSING (empty) in run_parser();
--   placeholder tokens (-, N/A, NULL) are returned as written and become PLACEHOLDER; everything else is validated.
--   DET-F5 only accepts exactly 9 semicolons, so a detected row always has 10 columns; any other count gives the
--   diagnostic column_count_not_10 and no field candidates.
-- Reads nothing but its argument and ref_key_alias. Re-runnable (drop + create of this function only).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

DROP FUNCTION IF EXISTS log_regex.f5_candidates(text);

-- S3/S4: F5 candidates ---------------------------------------------------------------------------------
-- Same output shape as the other extractors; doc_order = column number * 10.
CREATE FUNCTION log_regex.f5_candidates(p_raw text)
RETURNS TABLE (field_name text, value text, start_pos integer, slot_id text, role text,
               secondary_kind text, doc_order integer, diagnostic text)
LANGUAGE sql
STABLE
AS $$
    WITH ev AS (
        SELECT left(p_raw, log_regex.line_event_end(p_raw)) AS event_line
        WHERE p_raw IS NOT NULL
    ),
    cols AS (
        SELECT c.col_no::integer AS col_no,
               c.col_text,
               (1 + coalesce(sum(char_length(c.col_text) + 1)
                                 OVER (ORDER BY c.col_no ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0))::integer
                   AS col_pos,
               count(*) OVER () AS col_count
        FROM ev
        CROSS JOIN LATERAL regexp_split_to_table(ev.event_line, ';') WITH ORDINALITY AS c (col_text, col_no)
    )
    SELECT k.field_name,
           CASE WHEN c.col_text ~ '^[[:space:]]*$' THEN '' ELSE c.col_text END,
           c.col_pos,
           'F5.column[' || c.col_no || ']',
           'primary'::text,
           NULL::text,
           c.col_no * 10,
           NULL::text
    FROM cols c
    JOIN log_regex.ref_key_alias k ON k.format_family = 'F5' AND k.key_name = c.col_no::text
    WHERE c.col_count = 10
    UNION ALL
    SELECT NULL::text, NULL::text, 1, 'F5'::text, 'diagnostic'::text, NULL::text, 0,
           'column_count_not_10:' || max(c.col_count)
    FROM cols c
    HAVING max(c.col_count) <> 10
$$;

COMMENT ON FUNCTION log_regex.f5_candidates(text) IS
    'F5 semicolon-positional export (Step 3A 7.5): ten columns mapped by ref_key_alias, values verbatim with exact '
    'positions for run_parser().';

COMMIT;
