/* =============================================================================
   Assignment 7 - 02_stage_file_format.sql
   -----------------------------------------------------------------------------
   RUN AS: A7_PIPELINE_ROLE  (after 00 and 01)
       snow sql -c <connection> --role A7_PIPELINE_ROLE --warehouse A7_PIPELINE_WH -f snowflake/02_stage_file_format.sql

   Creates:
     A7_ORDERS_DB.RAW.FF_ORDERS_CSV   CSV file format matching the Lambda output
     A7_ORDERS_DB.RAW.STG_ORDERS_S3   external stage on the landing prefix via A7_S3_INT

   IF NOT EXISTS is used on purpose. A pipe binds to its stage, so re-creating the
   stage would require re-creating the pipe. To change a definition later, use
   ALTER FILE FORMAT / ALTER STAGE.

   Uses no warehouse.
   ============================================================================= */

USE ROLE A7_PIPELINE_ROLE;
USE DATABASE A7_ORDERS_DB;

-- -----------------------------------------------------------------------------
-- File format (as deployed 2026-10-05)
-- Columns (15, header row):
--   order_id, order_ts, customer_id, customer_name, customer_email, product_id,
--   product_category, quantity, unit_price, amount, currency, payment_method,
--   order_status, city, batch_ts
--
-- TRIM_SPACE = TRUE removes only leading/trailing blanks. The generator's email
--   defect has an INTERNAL space ('name @domain'), so DQ still sees it.
-- EMPTY_FIELD_AS_NULL + NULL_IF turn blank required fields into NULLs, which
--   rule DQ01_REQUIRED_FIELDS then flags.
-- FIELD_OPTIONALLY_ENCLOSED_BY = '"' reads values the generator had to quote
--   (e.g. the defect value "12,50" that contains the delimiter).
-- Defaults that matter: ENCODING = UTF8, RECORD_DELIMITER = newline,
--   ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE.
-- Structurally broken files: the pipe (03b_snowpipe.sql) maps $1..$15 with a
--   COPY transformation and sets no ON_ERROR, so Snowpipe's default SKIP_FILE
--   applies to load errors. No additional column-count guard is implemented.
--   Malformed VALUES, as opposed to broken structure, still load and are
--   flagged by the DQ rules.
-- -----------------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS RAW.FF_ORDERS_CSV
    TYPE = CSV
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    EMPTY_FIELD_AS_NULL = TRUE
    TRIM_SPACE = TRUE
    NULL_IF = ('', 'NULL', 'null');

-- -----------------------------------------------------------------------------
-- External stage (as deployed 2026-10-05)
-- The URL stays inside A7_S3_INT's STORAGE_ALLOWED_LOCATIONS.
-- Directory table not enabled (default), so there is no auto-refresh cost.
-- -----------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS RAW.STG_ORDERS_S3
    URL = 's3://a7-orders-pipeline-<AWS_ACCOUNT_ID>/landing/orders/'
    STORAGE_INTEGRATION = A7_S3_INT
    FILE_FORMAT = RAW.FF_ORDERS_CSV
    COMMENT = 'Assignment 7 S3 landing stage';

-- -----------------------------------------------------------------------------
-- Verification
-- SHOW works immediately (metadata only). CREATE STAGE does not contact AWS.
-- -----------------------------------------------------------------------------
SHOW FILE FORMATS IN SCHEMA A7_ORDERS_DB.RAW;
SHOW STAGES IN SCHEMA A7_ORDERS_DB.RAW;

-- LIST / SELECT need the AWS role a7-snowflake-s3-access-role (created via
-- infra/aws/iam/) AND the ap-southeast-7 region enabled on the AWS account
-- (Snowflake calls STS in Bangkok).

-- LIST is metadata-only (no warehouse):
LIST @A7_ORDERS_DB.RAW.STG_ORDERS_S3;
-- LIST @RAW.STG_ORDERS_S3 PATTERN = '.*orders_20261005_14[.]csv';

-- Reading file contents needs the warehouse (a few seconds of X-Small):
-- USE WAREHOUSE A7_PIPELINE_WH;
-- SELECT METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, $1, $5, $8, $10
-- FROM @RAW.STG_ORDERS_S3 (PATTERN => '.*orders_20261005_14[.]csv')
-- LIMIT 5;
