-- =============================================================================
-- 00_admin_setup.sql
-- Assignment 3 (Portfolio Assignment 9) - Kafka-to-Snowflake Streaming Pipeline
--
-- PURPOSE
--   Creates the dedicated warehouse for this pipeline and lets the pipeline
--   role use it.
--
-- WHO RUNS THIS
--   An account administrator, ONCE, in Snowsight. The pipeline role
--   (CLAUDE_AI_ROLE) cannot create warehouses, so this script is kept apart
--   from 01_create_objects.sql, which the pipeline role runs itself.
--
-- SAFE TO RE-RUN
--   Yes. CREATE ... IF NOT EXISTS and GRANT do nothing when already applied.
-- =============================================================================

-- Creating a warehouse and granting it needs an administrative role.
USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- Warehouse that runs COPY INTO and the small audit-log inserts.
--
-- WAREHOUSE_SIZE  : >>> THE ONE VALUE TO CHANGE IF A DIFFERENT SIZE IS WANTED <<<
--                   'XSMALL' is the default because this is a low-volume
--                   learning/demo workload (a few rows per second).
-- AUTO_SUSPEND    : seconds of inactivity before the warehouse stops billing.
--                   60 is the lowest practical value.
-- AUTO_RESUME     : the consumer's first query after an idle period restarts
--                   the warehouse, so nobody has to resume it by hand.
-- INITIALLY_SUSPENDED : creating the warehouse costs nothing until first use.
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS KAFKA_STREAMING_WH
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'Dedicated warehouse for the Kafka-to-Snowflake streaming pipeline (Assignment 3 / Portfolio 9)';

-- USAGE   : lets the pipeline role run queries on the warehouse (auto-resume
--           included).
-- MONITOR : lets the pipeline role see the warehouse state, which the README
--           uses as evidence that the warehouse suspends when Kafka is idle.
GRANT USAGE, MONITOR ON WAREHOUSE KAFKA_STREAMING_WH TO ROLE CLAUDE_AI_ROLE;

-- Confirm the result: size X-Small, auto_suspend 60, auto_resume true.
SHOW WAREHOUSES LIKE 'KAFKA_STREAMING_WH';
