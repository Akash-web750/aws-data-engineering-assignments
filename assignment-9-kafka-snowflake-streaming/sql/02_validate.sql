-- =============================================================================
-- 02_validate.sql
-- Assignment 3 (Portfolio Assignment 9) - Kafka-to-Snowflake Streaming Pipeline
--
-- PURPOSE
--   Read-only checks of the pipeline. Nothing is created, changed or deleted.
--   The output of this script is the evidence used in the README.
--
-- RUN
--   snow sql -c <connection> --role CLAUDE_AI_ROLE --warehouse KAFKA_STREAMING_WH -f sql/02_validate.sql
-- =============================================================================

USE DATABASE AI_OPERATOR_DB;
USE SCHEMA KAFKA_STREAMING;

-- -----------------------------------------------------------------------------
-- 1. Pipeline health in one row: rows, last load, lag, rejected rows, columns
--    added. Run it twice a few seconds apart while the producer is running:
--    TOTAL_ROWS rises without anyone doing anything.
-- -----------------------------------------------------------------------------
SELECT * FROM PIPELINE_HEALTH;

-- -----------------------------------------------------------------------------
-- 2. Current columns of the target table.
--    The first 14 are the columns declared in 01_create_objects.sql (the
--    version 1 columns plus the explicitly typed DISCOUNT_PCT). Any column
--    after them was added by Snowflake schema evolution.
-- -----------------------------------------------------------------------------
SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'KAFKA_STREAMING'
  AND TABLE_NAME   = 'ORDER_EVENTS'
ORDER BY ORDINAL_POSITION;

-- -----------------------------------------------------------------------------
-- 3. Application-level audit of schema evolution: which column appeared, with
--    which inferred type, in which batch and at which Kafka offset.
--    (Snowflake created the columns; the consumer only recorded them.)
-- -----------------------------------------------------------------------------
SELECT COLUMN_NAME, DATA_TYPE, FIRST_SEEN_PARTITION, FIRST_SEEN_OFFSET, FILE_NAME, DETECTED_AT
FROM SCHEMA_EVOLUTION_LOG
WHERE TARGET_TABLE = 'ORDER_EVENTS'
ORDER BY DETECTED_AT, COLUMN_NAME;

-- -----------------------------------------------------------------------------
-- 4. The 10 most recent batches: continuous loading, rows per batch, rejected
--    rows and the columns each batch introduced.
-- -----------------------------------------------------------------------------
SELECT LOGGED_AT, FILE_NAME, RECORD_COUNT, ROWS_LOADED, ERRORS_SEEN, COPY_STATUS,
       NEW_COLUMNS, LOAD_SECONDS, FIRST_ERROR
FROM INGEST_BATCH_LOG
WHERE TARGET_TABLE = 'ORDER_EVENTS'
ORDER BY LOGGED_AT DESC
LIMIT 10;

-- -----------------------------------------------------------------------------
-- 5. Duplicate check. A Kafka message is identified by (topic, partition,
--    offset). Any row returned here is a message that was loaded more than
--    once (possible with at-least-once delivery). Expected: no rows.
-- -----------------------------------------------------------------------------
SELECT _KAFKA_TOPIC, _KAFKA_PARTITION, _KAFKA_OFFSET, COUNT(*) AS COPIES
FROM ORDER_EVENTS
GROUP BY _KAFKA_TOPIC, _KAFKA_PARTITION, _KAFKA_OFFSET
HAVING COUNT(*) > 1
ORDER BY COPIES DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 6. Gap check per partition. Offsets in a partition are consecutive, so
--    (highest - lowest + 1) should equal the number of distinct offsets
--    loaded. A difference means messages that are not in the table: malformed
--    messages (see the dead-letter topic) or rows rejected by Snowflake
--    (see ERRORS_SEEN in query 4).
-- -----------------------------------------------------------------------------
SELECT _KAFKA_PARTITION,
       MIN(_KAFKA_OFFSET)                                           AS FIRST_OFFSET,
       MAX(_KAFKA_OFFSET)                                           AS LAST_OFFSET,
       COUNT(DISTINCT _KAFKA_OFFSET)                                AS OFFSETS_LOADED,
       MAX(_KAFKA_OFFSET) - MIN(_KAFKA_OFFSET) + 1
           - COUNT(DISTINCT _KAFKA_OFFSET)                          AS OFFSETS_NOT_LOADED
FROM ORDER_EVENTS
GROUP BY _KAFKA_PARTITION
ORDER BY _KAFKA_PARTITION;

-- -----------------------------------------------------------------------------
-- 7. Latency: seconds between Kafka receiving a message and the consumer
--    batching it, over the last hour of data.
-- -----------------------------------------------------------------------------
SELECT COUNT(*)                                                               AS ROWS_LAST_HOUR,
       ROUND(AVG(DATEDIFF('millisecond', _KAFKA_TIMESTAMP, _INGESTED_AT)) / 1000, 2) AS AVG_SECONDS,
       ROUND(MAX(DATEDIFF('millisecond', _KAFKA_TIMESTAMP, _INGESTED_AT)) / 1000, 2) AS MAX_SECONDS
FROM ORDER_EVENTS
WHERE _INGESTED_AT >= DATEADD('hour', -1, SYSDATE());

-- -----------------------------------------------------------------------------
-- 8. The de-duplicated view still works after columns were added (it lists
--    only the original columns, see 01_create_objects.sql).
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS ROWS_IN_DEDUP_VIEW FROM ORDER_EVENTS_LATEST;

-- -----------------------------------------------------------------------------
-- 9. Warehouse state. STATE = SUSPENDED when no data has flowed for about a
--    minute, which shows that an idle pipeline costs nothing.
-- -----------------------------------------------------------------------------
SHOW WAREHOUSES LIKE 'KAFKA_STREAMING_WH';
