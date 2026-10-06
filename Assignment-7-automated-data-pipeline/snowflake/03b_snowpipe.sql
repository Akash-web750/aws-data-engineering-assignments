/* =============================================================================
   Assignment 7 - 03b_snowpipe.sql
   -----------------------------------------------------------------------------
   RUN AS: A7_PIPELINE_ROLE
       snow sql -c <connection> --role A7_PIPELINE_ROLE --warehouse A7_PIPELINE_WH -f snowflake/03b_snowpipe.sql

   Snowpipe with AUTO_INGEST via the SNS topic in ap-south-1. Creating the pipe
   subscribes Snowflake's SQS queue to the topic. The topic policy must already
   allow Snowflake's principal sns:Subscribe (CloudFormation stack a7-orders-pipeline).

   v2 (2026-10-05), replacing v1:
     - All names fully qualified, so the pipe no longer depends on session
       database/schema (v1's ALTER PIPE ... REFRESH failed without USE DATABASE).
     - LOADED_AT = CONVERT_TIMEZONE('UTC', METADATA$START_SCAN_TIME)::TIMESTAMP_NTZ
         v1 used CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, which (a) was the account
         time zone (America/Los_Angeles), not UTC, and (b) repeated the same
         value (08:44:00.641) for two loads 3 minutes apart.
         METADATA$START_SCAN_TIME is TIMESTAMP_LTZ (verified with SYSTEM$TYPEOF)
         and is the time the file was scanned, so it is converted to UTC NTZ.
     - LOAD_BATCH_ID = MD5(file name | that UTC scan time).

   Mapping: $1..$15 are POSITIONAL and must match the generator header
   (order_id, order_ts, customer_id, customer_name, customer_email, product_id,
   product_category, quantity, unit_price, amount, currency, payment_method,
   order_status, city, batch_ts).

   - Snowpipe is serverless: no warehouse is used.
   - ON_ERROR not set, so the Snowpipe default SKIP_FILE applies.
   - Load history belongs to the pipe. A re-created pipe starts with EMPTY history,
     so never REFRESH it to load files that an earlier pipe version already loaded.
     Re-writing an old hour's file in S3 would also be loaded again.
   ============================================================================= */

USE ROLE A7_PIPELINE_ROLE;
-- A current database is required even though every name below is fully
-- qualified (Snowflake rejected CREATE PIPE without it during deployment).
USE DATABASE A7_ORDERS_DB;
USE SCHEMA RAW;

-- ORDER: after 03_landing_table.sql AND after the SNS topic policy allows
-- Snowflake's principal sns:Subscribe (deploy.ps1 -SnowflakeSnsPrincipalArn).
-- Creating the pipe subscribes Snowflake's queue to the topic.
CREATE PIPE A7_ORDERS_DB.RAW.PIPE_ORDERS_INGEST
    AUTO_INGEST = TRUE
    AWS_SNS_TOPIC = 'arn:aws:sns:ap-south-1:<AWS_ACCOUNT_ID>:a7-orders-s3-events'
AS
COPY INTO A7_ORDERS_DB.RAW.ORDERS_LANDING
(
    ORDER_ID,
    ORDER_TS,
    CUSTOMER_ID,
    CUSTOMER_NAME,
    CUSTOMER_EMAIL,
    PRODUCT_ID,
    PRODUCT_CATEGORY,
    QUANTITY,
    UNIT_PRICE,
    AMOUNT,
    CURRENCY,
    PAYMENT_METHOD,
    ORDER_STATUS,
    CITY,
    BATCH_TS,
    SOURCE_FILE,
    SOURCE_ROW_NUMBER,
    LOADED_AT,
    LOAD_BATCH_ID
)
FROM
(
    SELECT
        $1::VARCHAR,
        $2::VARCHAR,
        $3::VARCHAR,
        $4::VARCHAR,
        $5::VARCHAR,
        $6::VARCHAR,
        $7::VARCHAR,
        $8::VARCHAR,
        $9::VARCHAR,
        $10::VARCHAR,
        $11::VARCHAR,
        $12::VARCHAR,
        $13::VARCHAR,
        $14::VARCHAR,
        $15::VARCHAR,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        CONVERT_TIMEZONE('UTC', METADATA$START_SCAN_TIME)::TIMESTAMP_NTZ,
        MD5(
            CONCAT(
                METADATA$FILENAME,
                '|',
                CONVERT_TIMEZONE('UTC', METADATA$START_SCAN_TIME)::TIMESTAMP_NTZ::VARCHAR
            )
        )
    FROM @A7_ORDERS_DB.RAW.STG_ORDERS_S3
);

-- Validation (metadata only). Healthy: executionState = RUNNING,
-- pendingFileCount = 0, numOutstandingMessagesOnChannel = 0.
SHOW PIPES LIKE 'PIPE_ORDERS_INGEST' IN SCHEMA A7_ORDERS_DB.RAW;
SELECT SYSTEM$PIPE_STATUS('A7_ORDERS_DB.RAW.PIPE_ORDERS_INGEST');

-- NOT run automatically. ALTER PIPE ... REFRESH loads files already in the
-- stage (from the last 7 days) that the pipe has not loaded yet. Use it only for
-- a NEW pipe with no earlier version; on a re-created pipe it would load files a
-- previous pipe version already loaded (duplicates).
