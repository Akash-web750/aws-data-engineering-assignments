-- =============================================================================
-- 99_teardown.sql
-- Assignment 3 (Portfolio Assignment 9) - Kafka-to-Snowflake Streaming Pipeline
--
-- PURPOSE
--   Removes everything this project created in Snowflake.
--
-- !!! DESTRUCTIVE !!!
--   Dropping the schema deletes the target table, all loaded data, both audit
--   tables, the stage and the views. Run this BY HAND, and only when the
--   project is finished. No script or program in this repository runs it.
--
-- RUN
--   snow sql -c <connection> --role CLAUDE_AI_ROLE -f sql/99_teardown.sql
-- =============================================================================

USE DATABASE AI_OPERATOR_DB;

-- Drops the schema and every object inside it (CASCADE is the default).
-- Snowflake keeps dropped objects for the Time Travel retention period, so
-- UNDROP SCHEMA KAFKA_STREAMING can bring it back shortly after a mistake.
DROP SCHEMA IF EXISTS KAFKA_STREAMING;

-- The warehouse belongs to the account administrator and is therefore not
-- dropped here. An administrator can remove it with:
--     USE ROLE ACCOUNTADMIN;
--     DROP WAREHOUSE IF EXISTS KAFKA_STREAMING_WH;
