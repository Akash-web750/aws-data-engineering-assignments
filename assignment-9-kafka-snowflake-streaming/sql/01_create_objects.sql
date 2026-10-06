-- =============================================================================
-- 01_create_objects.sql
-- Assignment 3 (Portfolio Assignment 9) - Kafka-to-Snowflake Streaming Pipeline
--
-- PURPOSE
--   Creates every Snowflake object the pipeline needs except the warehouse
--   (see 00_admin_setup.sql): schema, file format, stage, target table,
--   audit tables and views.
--
-- WHO RUNS THIS
--   The pipeline role, CLAUDE_AI_ROLE:
--     snow sql -c <connection> --role CLAUDE_AI_ROLE -f sql/01_create_objects.sql
--
-- SAFE TO RE-RUN
--   Yes. Tables, stage and schema use IF NOT EXISTS, so existing data and any
--   columns already added by schema evolution are kept.
--
-- NOTE
--   No statement here needs a running warehouse; these are metadata-only DDL.
-- =============================================================================

-- The pipeline role owns AI_OPERATOR_DB, so it can create a schema inside it.
USE DATABASE AI_OPERATOR_DB;

-- -----------------------------------------------------------------------------
-- Schema: one container for all pipeline objects, so teardown is one DROP.
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS KAFKA_STREAMING
    COMMENT = 'Kafka-to-Snowflake streaming pipeline with schema evolution (Assignment 3 / Portfolio 9)';

USE SCHEMA KAFKA_STREAMING;

-- -----------------------------------------------------------------------------
-- File format for the batch files written by the consumer.
--
-- TYPE = JSON              : each batch file is newline-delimited JSON (NDJSON),
--                            one Kafka message per line.
-- STRIP_OUTER_ARRAY = FALSE: the file is NOT one big JSON array; every line is
--                            its own object and becomes its own row.
-- -----------------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS NDJSON_FF
    TYPE              = JSON
    STRIP_OUTER_ARRAY = FALSE
    COMMENT           = 'Newline-delimited JSON, one Kafka message per line';

-- -----------------------------------------------------------------------------
-- Internal stage: the consumer PUTs each batch file here, then COPY INTO reads
-- it. Internal means Snowflake stores the files; no S3 bucket or other AWS
-- resource is involved.
-- -----------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS ORDER_EVENTS_STAGE
    FILE_FORMAT = NDJSON_FF
    COMMENT     = 'Landing stage for consumer micro-batch files; files are purged after a successful COPY';

-- -----------------------------------------------------------------------------
-- Target table.
--
-- This is the schema-version-1 shape plus ONE explicitly typed later field,
-- DISCOUNT_PCT (see below). Columns for every other field that Kafka
-- introduces later are NOT listed here: Snowflake adds them during COPY INTO.
--
-- WHY DISCOUNT_PCT IS DECLARED HERE AND NOT LEFT TO SCHEMA EVOLUTION
--     Verified on this account (README, "Numeric widening check"): when
--     schema evolution creates a numeric column, Snowflake sizes it to the
--     first values it sees (7 -> NUMBER(1,0), 12.5 -> NUMBER(3,1)) and never
--     widens it afterwards. A later, larger value is rejected, and a
--     fractional value sent to an integer-sized column is stored with the
--     fraction silently dropped. A known business number must therefore be
--     given its proper type up front. NUMBER(5,2) holds 0.00 to 999.99, which
--     covers any percentage with two decimal places.
--     Unknown new fields (PAYMENT_METHOD, LOYALTY_TIER, IS_GIFT,
--     SHIPPING_ADDRESS, anything sent with --extra-field) are still created
--     automatically by schema evolution.
--
-- ENABLE_SCHEMA_EVOLUTION = TRUE : the switch that allows COPY INTO (with
--     MATCH_BY_COLUMN_NAME) to add a column when a batch file contains a
--     top-level key that has no matching column. The loading role must own
--     the table (or hold EVOLVE SCHEMA on it); CLAUDE_AI_ROLE owns it.
--
-- Every column is nullable on purpose: a message that lacks a field loads as
-- NULL instead of being rejected.
--
-- Columns starting with "_" are metadata added by the consumer, not by the
-- producer.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ORDER_EVENTS (
    EVENT_ID          VARCHAR        COMMENT 'Unique id of the event (UUID from the producer)',
    EVENT_TIME        TIMESTAMP_NTZ  COMMENT 'When the event happened, UTC',
    ORDER_ID          VARCHAR        COMMENT 'Order the event belongs to; also the Kafka message key',
    CUSTOMER_ID       NUMBER         COMMENT 'Customer who placed the order',
    PRODUCT           VARCHAR        COMMENT 'Product name',
    QUANTITY          NUMBER         COMMENT 'Units ordered',
    UNIT_PRICE        NUMBER(12,2)   COMMENT 'Price of one unit, INR',
    STATUS            VARCHAR        COMMENT 'Order status at the time of the event',
    _KAFKA_TOPIC      VARCHAR        COMMENT 'Kafka topic the message was read from',
    _KAFKA_PARTITION  NUMBER         COMMENT 'Kafka partition the message was read from',
    _KAFKA_OFFSET     NUMBER         COMMENT 'Offset of the message inside its partition',
    _KAFKA_TIMESTAMP  TIMESTAMP_NTZ  COMMENT 'Kafka broker timestamp of the message, UTC',
    _INGESTED_AT      TIMESTAMP_NTZ  COMMENT 'When the consumer built the batch holding this row, UTC',
    DISCOUNT_PCT      NUMBER(5,2)    COMMENT 'Discount in percent (sent from schema version 2 on). Explicitly typed: evolved numeric columns never widen'
)
ENABLE_SCHEMA_EVOLUTION = TRUE
COMMENT = 'Order events streamed from Kafka. Columns are added automatically by Snowflake schema evolution.';

-- -----------------------------------------------------------------------------
-- Bring a table created by an earlier version of this script up to date.
--
-- CREATE TABLE IF NOT EXISTS leaves an existing table untouched, so a table
-- created before DISCOUNT_PCT was declared would not have the column. This
-- statement adds it; IF NOT EXISTS makes it do nothing on a current table.
-- It runs here, at setup time, by hand. The consumer itself never issues
-- ALTER TABLE: at run time, new columns come only from schema evolution.
-- -----------------------------------------------------------------------------
ALTER TABLE ORDER_EVENTS ADD COLUMN IF NOT EXISTS
    DISCOUNT_PCT NUMBER(5,2) COMMENT 'Discount in percent (sent from schema version 2 on). Explicitly typed: evolved numeric columns never widen';

-- -----------------------------------------------------------------------------
-- Batch audit log: one row per micro-batch the consumer loads.
-- Written by the consumer after each COPY INTO. It is the evidence for
-- "continuous ingestion" and records rejected rows (type conflicts).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS INGEST_BATCH_LOG (
    BATCH_ID        VARCHAR        COMMENT 'Unique id of the batch (UUID from the consumer)',
    TARGET_TABLE    VARCHAR        COMMENT 'Table the batch was loaded into',
    FILE_NAME       VARCHAR        COMMENT 'Name of the staged batch file',
    KAFKA_TOPIC     VARCHAR        COMMENT 'Kafka topic the batch was read from',
    OFFSET_RANGES   VARCHAR        COMMENT 'JSON text: first and last offset per partition in the batch',
    RECORD_COUNT    NUMBER         COMMENT 'Rows the consumer wrote to the batch file',
    ROWS_PARSED     NUMBER         COMMENT 'Rows Snowflake read from the file (COPY result)',
    ROWS_LOADED     NUMBER         COMMENT 'Rows Snowflake loaded into the table (COPY result)',
    ERRORS_SEEN     NUMBER         COMMENT 'Rows Snowflake rejected (COPY result)',
    FIRST_ERROR     VARCHAR        COMMENT 'Text of the first rejection error, if any (COPY result)',
    COPY_STATUS     VARCHAR        COMMENT 'Status returned by COPY: LOADED, PARTIALLY_LOADED, LOAD_FAILED',
    COPY_QUERY_ID   VARCHAR        COMMENT 'Snowflake query id of the COPY INTO statement',
    NEW_COLUMNS     VARCHAR        COMMENT 'Comma-separated columns Snowflake added while loading this batch',
    LOAD_SECONDS    NUMBER(10,3)   COMMENT 'Seconds taken by PUT + COPY',
    LOGGED_AT       TIMESTAMP_NTZ  COMMENT 'When this log row was written, UTC'
)
COMMENT = 'One row per micro-batch loaded by the Kafka consumer';

-- -----------------------------------------------------------------------------
-- Schema evolution audit log: one row per column that appeared.
--
-- IMPORTANT: this is an APPLICATION-LEVEL AUDIT TABLE. Snowflake itself
-- performs the schema evolution. The consumer never issues ALTER TABLE; after
-- a COPY it only detects columns that Snowflake has already created and writes
-- one row here for each.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SCHEMA_EVOLUTION_LOG (
    TARGET_TABLE          VARCHAR        COMMENT 'Table that gained the column',
    COLUMN_NAME           VARCHAR        COMMENT 'Name of the column Snowflake added',
    DATA_TYPE             VARCHAR        COMMENT 'Data type Snowflake inferred for the column',
    BATCH_ID              VARCHAR        COMMENT 'Batch whose COPY added the column (joins to INGEST_BATCH_LOG)',
    FILE_NAME             VARCHAR        COMMENT 'Staged batch file that first contained the field',
    FIRST_SEEN_PARTITION  NUMBER         COMMENT 'Kafka partition of the first message that carried the field',
    FIRST_SEEN_OFFSET     NUMBER         COMMENT 'Kafka offset of the first message that carried the field',
    DETECTED_AT           TIMESTAMP_NTZ  COMMENT 'When the consumer detected the new column, UTC'
)
COMMENT = 'Application-level audit of columns added by Snowflake schema evolution';

-- -----------------------------------------------------------------------------
-- View: de-duplicated order events.
--
-- Delivery is at-least-once, so the same Kafka message can be loaded twice if
-- the consumer stops between a successful COPY and the offset commit. A Kafka
-- message is uniquely identified by (topic, partition, offset), so keeping one
-- row per such key removes those duplicates.
--
-- The column list is deliberately the columns DECLARED in the CREATE TABLE
-- above, not SELECT *. A Snowflake view fixes its column list when it is
-- created. Verified on this account: a SELECT * view fails with error 002057
-- ("declared 5 column(s), but view query produces 13 column(s)") as soon as
-- schema evolution adds a column to the table. A view that names its columns
-- is unaffected, no matter how many columns are added later.
-- Queries that need the automatically added columns read ORDER_EVENTS directly.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW ORDER_EVENTS_LATEST
    COMMENT = 'One row per Kafka message (topic, partition, offset); declared columns only'
AS
SELECT
    EVENT_ID,
    EVENT_TIME,
    ORDER_ID,
    CUSTOMER_ID,
    PRODUCT,
    QUANTITY,
    UNIT_PRICE,
    STATUS,
    _KAFKA_TOPIC,
    _KAFKA_PARTITION,
    _KAFKA_OFFSET,
    _KAFKA_TIMESTAMP,
    _INGESTED_AT,
    DISCOUNT_PCT
FROM ORDER_EVENTS
-- Keep the earliest-ingested copy of each Kafka message.
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY _KAFKA_TOPIC, _KAFKA_PARTITION, _KAFKA_OFFSET
    ORDER BY _INGESTED_AT
) = 1;

-- -----------------------------------------------------------------------------
-- View: one-row health summary of the pipeline, for quick checks and demos.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW PIPELINE_HEALTH
    COMMENT = 'One-row summary: rows loaded, last load time, lag, schema changes'
AS
SELECT
    -- Total rows in the target table, duplicates included.
    (SELECT COUNT(*) FROM ORDER_EVENTS)                                   AS TOTAL_ROWS,
    -- Distinct Kafka messages; equals TOTAL_ROWS when there are no duplicates.
    (SELECT COUNT(DISTINCT _KAFKA_TOPIC, _KAFKA_PARTITION, _KAFKA_OFFSET)
       FROM ORDER_EVENTS)                                                 AS DISTINCT_MESSAGES,
    -- When the newest row was ingested.
    (SELECT MAX(_INGESTED_AT) FROM ORDER_EVENTS)                          AS LAST_INGESTED_AT,
    -- Seconds since the newest row was ingested (large = pipeline idle/stopped).
    DATEDIFF('second',
             (SELECT MAX(_INGESTED_AT) FROM ORDER_EVENTS),
             SYSDATE())                                                   AS SECONDS_SINCE_LAST_LOAD,
    -- Batches loaded and rows rejected, from the application audit log.
    (SELECT COUNT(*) FROM INGEST_BATCH_LOG
      WHERE TARGET_TABLE = 'ORDER_EVENTS')                                AS BATCHES_LOADED,
    (SELECT COALESCE(SUM(ERRORS_SEEN), 0) FROM INGEST_BATCH_LOG
      WHERE TARGET_TABLE = 'ORDER_EVENTS')                                AS ROWS_REJECTED,
    -- Columns added by schema evolution, from the application audit log.
    (SELECT COUNT(*) FROM SCHEMA_EVOLUTION_LOG
      WHERE TARGET_TABLE = 'ORDER_EVENTS')                                AS COLUMNS_ADDED;

-- -----------------------------------------------------------------------------
-- View: one row per business event (EVENT_ID).
--
-- ADDED for the PostgreSQL CDC enhancement. It is a NEW view; the table and
-- the two views above are not changed by it.
--
-- WHY A SECOND DE-DUPLICATED VIEW
--   ORDER_EVENTS_LATEST removes a Kafka message that was LOADED twice: it
--   keeps one row per (topic, partition, offset).
--   With change data capture there is a second way to get a repeat: Debezium
--   or the CDC bridge can SEND the same event again after a restart. That
--   repeat is a new Kafka message with a new offset, so ORDER_EVENTS_LATEST
--   cannot recognise it. The business key EVENT_ID is the same in both
--   copies, so this view keeps one row per EVENT_ID (the earliest ingested).
--
-- A row without EVENT_ID cannot be matched with any other row. COALESCE gives
-- each such row its own key built from its Kafka position, so those rows are
-- all kept instead of being collapsed into one.
--
-- Like ORDER_EVENTS_LATEST it names the declared columns instead of using
-- SELECT *, so it keeps working when schema evolution adds columns.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW ORDER_EVENTS_UNIQUE
    COMMENT = 'One row per business event (EVENT_ID); declared columns only'
AS
SELECT
    EVENT_ID,
    EVENT_TIME,
    ORDER_ID,
    CUSTOMER_ID,
    PRODUCT,
    QUANTITY,
    UNIT_PRICE,
    STATUS,
    _KAFKA_TOPIC,
    _KAFKA_PARTITION,
    _KAFKA_OFFSET,
    _KAFKA_TIMESTAMP,
    _INGESTED_AT,
    DISCOUNT_PCT
FROM ORDER_EVENTS
-- Keep the earliest-ingested copy of each business event.
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY COALESCE(EVENT_ID, _KAFKA_TOPIC || ':' || _KAFKA_PARTITION || ':' || _KAFKA_OFFSET)
    ORDER BY _INGESTED_AT, _KAFKA_PARTITION, _KAFKA_OFFSET
) = 1;
