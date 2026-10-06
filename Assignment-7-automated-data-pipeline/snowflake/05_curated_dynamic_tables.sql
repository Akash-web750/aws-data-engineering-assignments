/* =============================================================================
   Assignment 7 - 05_curated_dynamic_tables.sql
   -----------------------------------------------------------------------------
   RUN AS: A7_PIPELINE_ROLE
       snow sql -c <connection> --role A7_PIPELINE_ROLE --warehouse A7_PIPELINE_WH -f snowflake/05_curated_dynamic_tables.sql

   DESIGN
     RAW.ORDERS_LANDING (Snowpipe)
        -> CURATED.V_ORDERS_DQ    plain view, the ONE definition of the 11 DQ rules
              -> CURATED.ORDERS_GOOD   dynamic table, QUALITY_STATUS = 'GOOD'
              -> CURATED.ORDERS_BAD    dynamic table, QUALITY_STATUS = 'BAD'

   - The view body is generated VERBATIM from the validated main query in
     04_data_quality_validation.sql (only the ORDER BY is removed). Both dynamic
     tables apply a single filter to it, so GOOD and BAD can never disagree.
     A view stores nothing and uses no compute; dynamic tables expand it at refresh.
   - Preserved exactly as validated:
       * safe parsing: TRY_TO_NUMBER(x, 18, 4), and
         TRY_TO_TIMESTAMP_NTZ(ORDER_TS, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
       * DQ07 tolerance 0.01; DQ08 email pattern; QUALITY_REASON in rule order
       * DQ09 is ingestion-relative: ORDER_TS_PARSED > LOADED_AT_UTC.
         LOADED_AT_UTC converts pipe-v1 rows (Pacific time, before
         2026-10-05 15:53:30.544 UTC) to UTC. RAW rows are not rewritten.
       * DQ11 by arrival order: ROW_NUMBER() OVER (PARTITION BY ORDER_ID
         ORDER BY LOADED_AT, SOURCE_FILE, SOURCE_ROW_NUMBER). The first
         arrival is GOOD; later arrivals are BAD.
   - No clock / non-deterministic functions (SYSDATE, CURRENT_TIMESTAMP, ...).
     With them Snowflake forces FULL refresh (verified 2026-10-05).
   - REFRESH_MODE = INCREMENTAL is set explicitly. If Snowflake could not
     refresh incrementally, CREATE fails instead of silently falling back to FULL.
     Incremental refresh needs change tracking on RAW.ORDERS_LANDING. Snowflake
     enables it automatically (it is ON); it changes no data.
   - PRODUCTION TARGET_LAG = '6 hours' (changed from '1 minute' on 2026-10-05 with
     ALTER DYNAMIC TABLE ... SET TARGET_LAG; tables not recreated).
     WAREHOUSE = A7_PIPELINE_WH (X-Small, AUTO_SUSPEND 60 s, resource monitor
     A7_PIPELINE_RM, 10 credits/month, unchanged). Refresh stays INCREMENTAL.
       * Reason: hourly ingestion + cost control. Observed with the 1-minute lag:
           - NO_DATA checks ran in cloud services and never resumed the warehouse.
           - Each refresh that found new data needed about 1 s of work, but cost a
             full warehouse resume (60 s minimum, then the 60 s auto-suspend tail).
           - At 1 file/hour, any lag of 1 hour or less means about 24 resumes per
             day, estimated at about 13-20 credits/month (over the 10-credit cap).
           - A 6-hour lag batches several hourly files per refresh. Estimated at
             about 3-7 credits/month. This is an extrapolation; check it against
             DYNAMIC_TABLE_REFRESH_HISTORY and warehouse metering once the
             schedule runs.
       * GOOD/BAD may trail RAW by up to 6 hours during the day. The EOD process
         (later step) will run ALTER DYNAMIC TABLE ... REFRESH on both tables
         before building the report, so the report always sees all RAW rows.
         Verified: manual refresh is supported, and with no new data it returns
         "No new data" without resuming the warehouse.
       * For a live demo the lag can be set to '1 minute' temporarily and then
         restored.
   - Output columns: 15 business columns (source text), 5 metadata columns
     (incl. LOADED_AT_UTC), 4 parsed columns for reporting, and
     QUALITY_STATUS / QUALITY_REASON.
   ============================================================================= */

USE ROLE A7_PIPELINE_ROLE;
USE DATABASE A7_ORDERS_DB;
USE SCHEMA CURATED;

-- -----------------------------------------------------------------------------
-- 1. Single DQ definition (copied verbatim from 04_data_quality_validation.sql)
--    CREATE VIEW IF NOT EXISTS: re-running this script does NOT update an
--    existing view. If the rules in 04 change, the view must be replaced
--    deliberately, and the dynamic tables then pick it up at their next refresh.
-- -----------------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS A7_ORDERS_DB.CURATED.V_ORDERS_DQ
    COMMENT = 'Assignment 7 - DQ evaluation of RAW.ORDERS_LANDING (rules DQ01-DQ11), one row per RAW row'
AS
    WITH src AS (
        SELECT
            l.*,
            -- Safe parsing: TRY_* returns NULL for malformed text instead of failing the
            -- whole query. Scale 4 keeps decimals (1-arg TRY_TO_NUMBER rounds to integers).
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
            -- DQ02 / DQ04 / DQ05: value present but not numeric (NULL is DQ01's job).
            COALESCE(QUANTITY   IS NOT NULL AND QUANTITY_PARSED   IS NULL, FALSE)         AS DQ02_FAIL,
            -- DQ03 / DQ06: evaluated only on parsed values; COALESCE turns NULL into a pass.
            COALESCE(QUANTITY_PARSED <= 0, FALSE)                                         AS DQ03_FAIL,
            COALESCE(UNIT_PRICE IS NOT NULL AND UNIT_PRICE_PARSED IS NULL, FALSE)         AS DQ04_FAIL,
            COALESCE(AMOUNT     IS NOT NULL AND AMOUNT_PARSED     IS NULL, FALSE)         AS DQ05_FAIL,
            COALESCE(AMOUNT_PARSED <= 0, FALSE)                                           AS DQ06_FAIL,
            -- DQ07: needs all three numbers; 0.01 tolerance absorbs 2-decimal rounding.
            COALESCE(ABS(AMOUNT_PARSED - QUANTITY_PARSED * UNIT_PRICE_PARSED) > 0.01, FALSE) AS DQ07_FAIL,
            -- local@domain.tld; REGEXP_LIKE matches the whole string
            COALESCE(NOT REGEXP_LIKE(CUSTOMER_EMAIL,
                     '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}'), FALSE)             AS DQ08_FAIL,
            -- DQ09: unparseable, or later than the row's ingestion time (LOADED_AT_UTC).
            -- No clock function here, so the dynamic tables stay INCREMENTAL.
            COALESCE(ORDER_TS IS NOT NULL
                     AND (ORDER_TS_PARSED IS NULL OR ORDER_TS_PARSED > LOADED_AT_UTC), FALSE) AS DQ09_FAIL,
            -- DQ10: exact, case-sensitive match against the generator's status list.
            COALESCE(ORDER_STATUS NOT IN ('PLACED', 'SHIPPED', 'DELIVERED', 'CANCELLED', 'RETURNED'),
                     FALSE)                                                                AS DQ10_FAIL,
            -- DQ11: second or later arrival of the same non-NULL ORDER_ID.
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
        -- GOOD only when every rule passed; any failure makes the row BAD.
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
    FROM rules;

-- -----------------------------------------------------------------------------
-- 2. GOOD records
--    Both dynamic tables expose the same 26 columns: the source values as text,
--    the load metadata, the parsed values (for reporting) and the quality
--    columns. Only the WHERE filter differs, so every RAW row lands in exactly one.
--    INITIALIZE = ON_CREATE performs the first (incremental) refresh at creation.
-- -----------------------------------------------------------------------------
CREATE DYNAMIC TABLE IF NOT EXISTS A7_ORDERS_DB.CURATED.ORDERS_GOOD
    TARGET_LAG = '6 hours'
    WAREHOUSE = A7_PIPELINE_WH
    REFRESH_MODE = INCREMENTAL
    INITIALIZE = ON_CREATE
    COMMENT = 'Assignment 7 - orders that pass all DQ rules (QUALITY_REASON is NULL)'
AS
SELECT
    ORDER_ID, ORDER_TS, CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_EMAIL,
    PRODUCT_ID, PRODUCT_CATEGORY, QUANTITY, UNIT_PRICE, AMOUNT,
    CURRENCY, PAYMENT_METHOD, ORDER_STATUS, CITY, BATCH_TS,
    SOURCE_FILE, SOURCE_ROW_NUMBER, LOADED_AT, LOAD_BATCH_ID, LOADED_AT_UTC,
    ORDER_TS_PARSED, QUANTITY_PARSED, UNIT_PRICE_PARSED, AMOUNT_PARSED,
    QUALITY_STATUS, QUALITY_REASON
FROM A7_ORDERS_DB.CURATED.V_ORDERS_DQ
WHERE QUALITY_STATUS = 'GOOD';

-- -----------------------------------------------------------------------------
-- 3. BAD records
-- -----------------------------------------------------------------------------
CREATE DYNAMIC TABLE IF NOT EXISTS A7_ORDERS_DB.CURATED.ORDERS_BAD
    TARGET_LAG = '6 hours'
    WAREHOUSE = A7_PIPELINE_WH
    REFRESH_MODE = INCREMENTAL
    INITIALIZE = ON_CREATE
    COMMENT = 'Assignment 7 - orders failing one or more DQ rules (all failed codes in QUALITY_REASON)'
AS
SELECT
    ORDER_ID, ORDER_TS, CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_EMAIL,
    PRODUCT_ID, PRODUCT_CATEGORY, QUANTITY, UNIT_PRICE, AMOUNT,
    CURRENCY, PAYMENT_METHOD, ORDER_STATUS, CITY, BATCH_TS,
    SOURCE_FILE, SOURCE_ROW_NUMBER, LOADED_AT, LOAD_BATCH_ID, LOADED_AT_UTC,
    ORDER_TS_PARSED, QUANTITY_PARSED, UNIT_PRICE_PARSED, AMOUNT_PARSED,
    QUALITY_STATUS, QUALITY_REASON
FROM A7_ORDERS_DB.CURATED.V_ORDERS_DQ
WHERE QUALITY_STATUS = 'BAD';

-- -----------------------------------------------------------------------------
-- 4. Verification
-- -----------------------------------------------------------------------------
-- Metadata (no warehouse): expect refresh_mode = INCREMENTAL, target_lag = 6 hours,
-- warehouse = A7_PIPELINE_WH, scheduling_state = ACTIVE
SHOW DYNAMIC TABLES IN SCHEMA A7_ORDERS_DB.CURATED;

-- Refresh history (expect INITIAL then INCREMENTAL / NO_DATA refreshes, state SUCCEEDED):
-- SELECT name, state, refresh_action, refresh_trigger, data_timestamp,
--        refresh_start_time, refresh_end_time
-- FROM TABLE(A7_ORDERS_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
-- ORDER BY refresh_start_time DESC;

-- Reconciliation (needs the warehouse): GOOD + BAD = RAW, every RAW row exactly once
-- SELECT (SELECT COUNT(*) FROM A7_ORDERS_DB.CURATED.ORDERS_GOOD) AS good_rows,
--        (SELECT COUNT(*) FROM A7_ORDERS_DB.CURATED.ORDERS_BAD)  AS bad_rows,
--        (SELECT COUNT(*) FROM A7_ORDERS_DB.RAW.ORDERS_LANDING)  AS raw_rows;
