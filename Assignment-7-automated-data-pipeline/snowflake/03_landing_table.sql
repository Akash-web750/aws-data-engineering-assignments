/* =============================================================================
   Assignment 7 - 03_landing_table.sql
   -----------------------------------------------------------------------------
   RUN AS: A7_PIPELINE_ROLE
       snow sql -c <connection> --role A7_PIPELINE_ROLE --warehouse A7_PIPELINE_WH -f snowflake/03_landing_table.sql

   RAW landing table for the hourly order CSV.
   - Business columns match the generator header EXACTLY and IN FILE ORDER
     (lambda/order_generator/generator.py COLUMNS, verified against
     landing/orders/year=2026/month=10/day=05/orders_20261005_14.csv). The pipe
     loads by position ($1..$15), so the order matters.
   - Every source value is VARCHAR, so malformed values ('two', '2026-13-45...')
     still load and are flagged later by the DQ rules (CURATED.V_ORDERS_DQ).
     Typed columns here would make the WHOLE file fail to load (Snowpipe
     ON_ERROR default SKIP_FILE) and the bad rows could never be reported.
   - Ingestion metadata is filled by the pipe (03b_snowpipe.sql, pipe v2):
       SOURCE_FILE       METADATA$FILENAME (key relative to the bucket)
       SOURCE_ROW_NUMBER METADATA$FILE_ROW_NUMBER (1 = first data row)
       LOADED_AT         CONVERT_TIMEZONE('UTC', METADATA$START_SCAN_TIME), UTC scan time.
                         Rows loaded by pipe v1 hold America/Los_Angeles time; the
                         DQ view normalises them into LOADED_AT_UTC.
       LOAD_BATCH_ID     MD5(SOURCE_FILE | scan time): one ID per file load
   - (SOURCE_FILE, SOURCE_ROW_NUMBER) uniquely identifies a RAW row and is the
     reconciliation key used by the DQ view and the EOD procedure.

   Metadata-only DDL: no warehouse compute. No CREATE OR REPLACE.
   ============================================================================= */

USE ROLE A7_PIPELINE_ROLE;
USE DATABASE A7_ORDERS_DB;
USE SCHEMA RAW;

CREATE TABLE IF NOT EXISTS RAW.ORDERS_LANDING (
    ORDER_ID            VARCHAR,   -- $1  order_id
    ORDER_TS            VARCHAR,   -- $2  order_ts          (ISO-8601 UTC as text)
    CUSTOMER_ID         VARCHAR,   -- $3  customer_id
    CUSTOMER_NAME       VARCHAR,   -- $4  customer_name
    CUSTOMER_EMAIL      VARCHAR,   -- $5  customer_email
    PRODUCT_ID          VARCHAR,   -- $6  product_id
    PRODUCT_CATEGORY    VARCHAR,   -- $7  product_category
    QUANTITY            VARCHAR,   -- $8  quantity
    UNIT_PRICE          VARCHAR,   -- $9  unit_price
    AMOUNT              VARCHAR,   -- $10 amount
    CURRENCY            VARCHAR,   -- $11 currency
    PAYMENT_METHOD      VARCHAR,   -- $12 payment_method
    ORDER_STATUS        VARCHAR,   -- $13 order_status
    CITY                VARCHAR,   -- $14 city
    BATCH_TS            VARCHAR,   -- $15 batch_ts          (business hour of the file)

    SOURCE_FILE         VARCHAR,
    SOURCE_ROW_NUMBER   NUMBER,
    LOADED_AT           TIMESTAMP_NTZ,
    LOAD_BATCH_ID       VARCHAR
)
COMMENT = 'Assignment 7 raw landing table - source values preserved as text';

-- Validation (metadata only)
DESC TABLE RAW.ORDERS_LANDING;
SHOW TABLES LIKE 'ORDERS_LANDING' IN SCHEMA RAW;
SELECT COUNT(*) AS ROW_COUNT FROM RAW.ORDERS_LANDING;   -- answered from table metadata
