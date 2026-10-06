/* =============================================================================
   Assignment 7 - 04_data_quality_validation.sql
   -----------------------------------------------------------------------------
   RUN AS: A7_PIPELINE_ROLE (needs compute: A7_PIPELINE_WH, auto-resume/suspend)
       snow sql -c <connection> --role A7_PIPELINE_ROLE --warehouse A7_PIPELINE_WH -f snowflake/04_data_quality_validation.sql

   Read-only. Evaluates every DQ rule for every row of RAW.ORDERS_LANDING and
   returns one row per RAW record with QUALITY_STATUS / QUALITY_REASON.
   Creates nothing: the summaries reuse the main result through RESULT_SCAN.
   This SELECT is the basis for the later CURATED dynamic tables.

   SAFE CONVERSION (all RAW business columns are VARCHAR)
   - Numbers: TRY_TO_NUMBER(x, 18, 4). The 1-argument form rounds to scale 0
     (verified: '1097.99' -> 1098), which would break DQ07. Malformed values
     ('12,50', '1O0', 'two', 'N/A') return NULL instead of failing the query.
   - ORDER_TS: TRY_TO_TIMESTAMP_NTZ(ORDER_TS, 'YYYY-MM-DD"T"HH24:MI:SS"Z"').
     The generator writes strict ISO-8601 UTC with a 'Z' suffix (verified on all
     294 non-NULL RAW values). The explicit format rejects anything else and
     never guesses: automatic detection read '2026-10-05 14:37:16' in the
     session time zone (America/Los_Angeles). The parsed value is UTC, stored
     as NTZ.
   - DQ09 reference time = LOADED_AT_UTC, the row's own ingestion time in UTC
     (no clock function; see DQ09 below):
       IFF(LOADED_AT < '2026-10-05 15:53:30.544'::TIMESTAMP_NTZ,
           CONVERT_TIMEZONE('America/Los_Angeles', 'UTC', LOADED_AT),
           LOADED_AT)
     The constant is the creation time of pipe v2 (08:53:30.544 -07:00 = 15:53:30.544 UTC).
       * Pipe v1 rows (the two files loaded on 2026-10-05) stored LOADED_AT as
         America/Los_Angeles wall-clock time (CURRENT_TIMESTAMP()::TIMESTAMP_NTZ),
         at 08:44:00.641. They are converted to UTC here, giving 15:44:00.641.
         The rows themselves are NOT rewritten.
       * Pipe v2 rows already store UTC (METADATA$START_SCAN_TIME). They are
         always >= the cutover, so they pass through unchanged.
       The two ranges cannot overlap: every v1 value is Pacific time from before
       08:53:30, and every v2 value is UTC from 15:53:30 onward.

   RULE SCOPE DECISIONS
   - A NULL value fails only DQ01. Type and range rules (DQ02-DQ10) evaluate
     present values only, so one missing field is not double-counted.
   - DQ07 is evaluated only when quantity, unit price and amount are all numeric.
     Tolerance is 0.01 (one paisa).
   - DQ09 "not in the future" means: ORDER_TS must not be later than the moment
     the record was INGESTED (ORDER_TS_PARSED > LOADED_AT_UTC fails). The result
     is fixed at ingestion and does not change as time passes.
     A non-NULL ORDER_TS that cannot be parsed also fails DQ09; NULL fails only DQ01.
     Why not SYSDATE(): verified 2026-10-05 with a transient test dynamic table.
     Any clock function makes Snowflake choose FULL refresh ("Query contains the
     function 'CURRENT_TIMESTAMP' ... non-deterministic functions"). With
     LOADED_AT_UTC the same query refreshes INCREMENTAL. Both give identical
     DQ09 results on all 295 current rows.
     Why not raw LOADED_AT: the v1 rows hold Pacific time (08:44), so 294 of 295
     rows would wrongly fail DQ09.
   - DQ10 allowed values are the generator's VALID_STATUSES. Distinct RAW values
     were checked first: PLACED, SHIPPED, DELIVERED, CANCELLED, RETURNED, plus
     the defect UNKNOWN. Comparison is exact and case-sensitive.
   - DQ11 is an INGESTION-duplicate rule, decided by ARRIVAL ORDER:
       ROW_NUMBER() OVER (PARTITION BY ORDER_ID
                          ORDER BY LOADED_AT, SOURCE_FILE, SOURCE_ROW_NUMBER)
     The first record the pipeline received is the original (passes DQ11); every
     later record with the same non-NULL ORDER_ID fails. NULL ORDER_ID is not
     ranked (only DQ01 fails), so NULLs are never duplicates of each other.
     ORDER_TS is deliberately NOT used. Duplicates are re-sent copies, and their
     event time can be earlier than the original's: in the 2026-10-05 14:00
     file, 3 of the 4 injected copies had an earlier ORDER_TS, so event-time
     ordering flagged the clean originals instead.
     Tie-breakers: LOADED_AT is the Snowpipe scan time (UTC since pipe v2). Rows
     from the same file share it, and the two files loaded by pipe v1 share
     one value, so SOURCE_FILE and then SOURCE_ROW_NUMBER keep the result
     deterministic.
   ============================================================================= */

USE ROLE A7_PIPELINE_ROLE;
USE DATABASE A7_ORDERS_DB;
USE SCHEMA RAW;

-- -----------------------------------------------------------------------------
-- 1. Row-level DQ evaluation (one output row per RAW row)
-- -----------------------------------------------------------------------------
WITH src AS (
    SELECT
        l.*,
        TRY_TO_TIMESTAMP_NTZ(l.ORDER_TS, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS ORDER_TS_PARSED,
        TRY_TO_NUMBER(l.QUANTITY,   18, 4)                            AS QUANTITY_PARSED,
        TRY_TO_NUMBER(l.UNIT_PRICE, 18, 4)                            AS UNIT_PRICE_PARSED,
        TRY_TO_NUMBER(l.AMOUNT,     18, 4)                            AS AMOUNT_PARSED,
        -- Ingestion time in UTC (pipe v1 rows stored Pacific time; see header)
        IFF(l.LOADED_AT < '2026-10-05 15:53:30.544'::TIMESTAMP_NTZ,
            CONVERT_TIMEZONE('America/Los_Angeles', 'UTC', l.LOADED_AT),
            l.LOADED_AT)                                              AS LOADED_AT_UTC
    FROM A7_ORDERS_DB.RAW.ORDERS_LANDING l
),
ranked AS (
    SELECT
        src.*,
        -- DQ11 arrival order (see header): first received = original
        IFF(ORDER_ID IS NULL, NULL,
            ROW_NUMBER() OVER (PARTITION BY ORDER_ID
                               ORDER BY LOADED_AT, SOURCE_FILE, SOURCE_ROW_NUMBER)
        ) AS ORDER_ID_OCCURRENCE
    FROM src
),
rules AS (
    SELECT
        ranked.*,
        -- DQ01: every business column is required
        (   ORDER_ID IS NULL OR ORDER_TS IS NULL OR CUSTOMER_ID IS NULL OR CUSTOMER_NAME IS NULL
         OR CUSTOMER_EMAIL IS NULL OR PRODUCT_ID IS NULL OR PRODUCT_CATEGORY IS NULL
         OR QUANTITY IS NULL OR UNIT_PRICE IS NULL OR AMOUNT IS NULL OR CURRENCY IS NULL
         OR PAYMENT_METHOD IS NULL OR ORDER_STATUS IS NULL OR CITY IS NULL OR BATCH_TS IS NULL
        )                                                                              AS DQ01_FAIL,
        COALESCE(QUANTITY   IS NOT NULL AND QUANTITY_PARSED   IS NULL, FALSE)         AS DQ02_FAIL,
        COALESCE(QUANTITY_PARSED <= 0, FALSE)                                         AS DQ03_FAIL,
        COALESCE(UNIT_PRICE IS NOT NULL AND UNIT_PRICE_PARSED IS NULL, FALSE)         AS DQ04_FAIL,
        COALESCE(AMOUNT     IS NOT NULL AND AMOUNT_PARSED     IS NULL, FALSE)         AS DQ05_FAIL,
        COALESCE(AMOUNT_PARSED <= 0, FALSE)                                           AS DQ06_FAIL,
        COALESCE(ABS(AMOUNT_PARSED - QUANTITY_PARSED * UNIT_PRICE_PARSED) > 0.01, FALSE) AS DQ07_FAIL,
        -- local@domain.tld; REGEXP_LIKE matches the whole string
        COALESCE(NOT REGEXP_LIKE(CUSTOMER_EMAIL,
                 '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}'), FALSE)             AS DQ08_FAIL,
        COALESCE(ORDER_TS IS NOT NULL
                 AND (ORDER_TS_PARSED IS NULL OR ORDER_TS_PARSED > LOADED_AT_UTC), FALSE) AS DQ09_FAIL,
        COALESCE(ORDER_STATUS NOT IN ('PLACED', 'SHIPPED', 'DELIVERED', 'CANCELLED', 'RETURNED'),
                 FALSE)                                                                AS DQ10_FAIL,
        COALESCE(ORDER_ID_OCCURRENCE > 1, FALSE)                                       AS DQ11_FAIL
    FROM ranked
)
SELECT
    ORDER_ID,
    SOURCE_FILE,
    SOURCE_ROW_NUMBER,
    LOADED_AT,
    LOADED_AT_UTC,
    LOAD_BATCH_ID,
    ORDER_TS, CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_EMAIL, PRODUCT_ID, PRODUCT_CATEGORY,
    QUANTITY, UNIT_PRICE, AMOUNT, CURRENCY, PAYMENT_METHOD, ORDER_STATUS, CITY, BATCH_TS,
    ORDER_TS_PARSED,
    QUANTITY_PARSED,
    UNIT_PRICE_PARSED,
    AMOUNT_PARSED,
    ORDER_ID_OCCURRENCE,
    DQ01_FAIL, DQ02_FAIL, DQ03_FAIL, DQ04_FAIL, DQ05_FAIL, DQ06_FAIL,
    DQ07_FAIL, DQ08_FAIL, DQ09_FAIL, DQ10_FAIL, DQ11_FAIL,
    IFF(DQ01_FAIL OR DQ02_FAIL OR DQ03_FAIL OR DQ04_FAIL OR DQ05_FAIL OR DQ06_FAIL
        OR DQ07_FAIL OR DQ08_FAIL OR DQ09_FAIL OR DQ10_FAIL OR DQ11_FAIL, 'BAD', 'GOOD') AS QUALITY_STATUS,
    -- Every failed rule, in rule order; NULL when GOOD
    NULLIF(ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
        IFF(DQ01_FAIL, 'DQ01_REQUIRED_FIELDS',    NULL),
        IFF(DQ02_FAIL, 'DQ02_QUANTITY_NUMERIC',   NULL),
        IFF(DQ03_FAIL, 'DQ03_QUANTITY_POSITIVE',  NULL),
        IFF(DQ04_FAIL, 'DQ04_UNIT_PRICE_NUMERIC', NULL),
        IFF(DQ05_FAIL, 'DQ05_AMOUNT_NUMERIC',     NULL),
        IFF(DQ06_FAIL, 'DQ06_AMOUNT_POSITIVE',    NULL),
        IFF(DQ07_FAIL, 'DQ07_AMOUNT_MATCH',       NULL),
        IFF(DQ08_FAIL, 'DQ08_EMAIL_VALID',        NULL),
        IFF(DQ09_FAIL, 'DQ09_ORDER_TS_NOT_FUTURE', NULL),
        IFF(DQ10_FAIL, 'DQ10_STATUS_VALID',       NULL),
        IFF(DQ11_FAIL, 'DQ11_DUPLICATE_ORDER_ID', NULL)
    ), ';'), '')                                                                       AS QUALITY_REASON
FROM rules
ORDER BY SOURCE_FILE, SOURCE_ROW_NUMBER;

SET DQ_QID = LAST_QUERY_ID();

-- -----------------------------------------------------------------------------
-- 2. Summary (A-E) and completeness: GOOD + BAD = TOTAL = RAW row count,
--    no RAW row missing or repeated in the output
-- -----------------------------------------------------------------------------
SELECT
    COUNT(*)                                                       AS total_rows,
    COUNT_IF(QUALITY_STATUS = 'GOOD')                              AS good_rows,
    COUNT_IF(QUALITY_STATUS = 'BAD')                               AS bad_rows,
    ROUND(100 * COUNT_IF(QUALITY_STATUS = 'GOOD') / COUNT(*), 2)   AS good_pct,
    ROUND(100 * COUNT_IF(QUALITY_STATUS = 'BAD')  / COUNT(*), 2)   AS bad_pct,
    (SELECT COUNT(*) FROM A7_ORDERS_DB.RAW.ORDERS_LANDING)         AS raw_rows,
    COUNT(DISTINCT SOURCE_FILE || '#' || SOURCE_ROW_NUMBER)        AS distinct_raw_keys,
    (COUNT_IF(QUALITY_STATUS = 'GOOD') + COUNT_IF(QUALITY_STATUS = 'BAD') = COUNT(*)
     AND COUNT(*) = (SELECT COUNT(*) FROM A7_ORDERS_DB.RAW.ORDERS_LANDING)
     AND COUNT(DISTINCT SOURCE_FILE || '#' || SOURCE_ROW_NUMBER) = COUNT(*))
                                                                   AS completeness_ok,
    COUNT_IF(QUALITY_STATUS = 'GOOD' AND QUALITY_REASON IS NOT NULL)
      + COUNT_IF(QUALITY_STATUS = 'BAD' AND QUALITY_REASON IS NULL) AS status_reason_inconsistencies
FROM TABLE(RESULT_SCAN($DQ_QID));

-- -----------------------------------------------------------------------------
-- 3. F: rows per exact QUALITY_REASON combination
-- -----------------------------------------------------------------------------
SELECT QUALITY_REASON, COUNT(*) AS rows_
FROM TABLE(RESULT_SCAN($DQ_QID))
WHERE QUALITY_STATUS = 'BAD'
GROUP BY QUALITY_REASON
ORDER BY rows_ DESC, QUALITY_REASON;

-- -----------------------------------------------------------------------------
-- 4. F-N: failures per rule (a row can fail several rules)
-- -----------------------------------------------------------------------------
SELECT
    COUNT_IF(DQ01_FAIL) AS dq01_required_fields,
    COUNT_IF(DQ02_FAIL) AS dq02_quantity_numeric,
    COUNT_IF(DQ03_FAIL) AS dq03_quantity_positive,
    COUNT_IF(DQ04_FAIL) AS dq04_unit_price_numeric,
    COUNT_IF(DQ05_FAIL) AS dq05_amount_numeric,
    COUNT_IF(DQ06_FAIL) AS dq06_amount_positive,
    COUNT_IF(DQ07_FAIL) AS dq07_amount_match,
    COUNT_IF(DQ08_FAIL) AS dq08_email_valid,
    COUNT_IF(DQ09_FAIL) AS dq09_order_ts_not_future,
    COUNT_IF(DQ10_FAIL) AS dq10_status_valid,
    COUNT_IF(DQ11_FAIL) AS dq11_duplicate_order_id
FROM TABLE(RESULT_SCAN($DQ_QID));

-- -----------------------------------------------------------------------------
-- 5. DQ11 verification: every duplicated ORDER_ID with its arrival rank and the
--    DQ11 outcome (rank 1 = original passes; later arrivals fail)
-- -----------------------------------------------------------------------------
SELECT
    ORDER_ID,
    SOURCE_FILE,
    SOURCE_ROW_NUMBER,
    LOADED_AT,
    ORDER_TS,
    ORDER_ID_OCCURRENCE                                         AS arrival_rank,
    DQ11_FAIL,
    QUALITY_STATUS,
    QUALITY_REASON
FROM TABLE(RESULT_SCAN($DQ_QID))
WHERE ORDER_ID IN (SELECT ORDER_ID FROM TABLE(RESULT_SCAN($DQ_QID))
                   WHERE ORDER_ID IS NOT NULL GROUP BY ORDER_ID HAVING COUNT(*) > 1)
ORDER BY ORDER_ID, SOURCE_FILE, SOURCE_ROW_NUMBER;
