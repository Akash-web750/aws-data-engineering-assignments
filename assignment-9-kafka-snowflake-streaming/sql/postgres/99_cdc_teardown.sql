-- =============================================================================
-- 99_cdc_teardown.sql   (PostgreSQL, run with psql)
-- Assignment 3 (Portfolio Assignment 9) - Kafka-to-Snowflake Streaming Pipeline
-- Enhancement: change data capture (CDC) from PostgreSQL
--
-- PURPOSE
--   Removes what CDC added to PostgreSQL: the replication slot, the
--   publication and the dedicated login. Used to roll the CDC step back.
--
-- !!! RUN BY HAND ONLY !!!
--   No script or program in this repository runs this file.
--   Stop Kafka Connect first (scripts\stop_connect.ps1): a slot that is in use
--   cannot be dropped, and this script then leaves it in place and says so.
--
-- WHAT IT KEEPS
--   The table order_events and all its rows, the database kafka_source_db,
--   and every server setting (wal_level is not changed here).
--
-- WHY THE SLOT MATTERS MOST
--   A replication slot that nobody reads makes PostgreSQL keep its log files
--   for the WHOLE server, and the disk slowly fills. Never leave an unused
--   slot behind.
--
-- HOW TO RUN
--     $env:PGPASSWORD = "<superuser password>"
--     & "C:\Program Files\PostgreSQL\17\bin\psql.exe" -h localhost -U postgres `
--         -d kafka_source_db -v ON_ERROR_STOP=1 -f sql/postgres/99_cdc_teardown.sql
--
-- SAFE TO RE-RUN
--   Yes. Objects that are already gone are skipped.
-- =============================================================================

-- Guard: only ever run inside the project database.
SELECT current_database() = 'kafka_source_db' AS in_project_database \gset
\if :in_project_database
\else
    \echo 'STOPPED: connect to kafka_source_db (-d kafka_source_db). Nothing was changed.'
    \quit
\endif

-- -----------------------------------------------------------------------------
-- 1. Replication slot.
-- Dropped only if it exists and is not in use. If Kafka Connect is still
-- running, the slot is active: nothing is dropped and the final query below
-- shows it, so it is obvious that Connect must be stopped first.
-- -----------------------------------------------------------------------------
SELECT pg_drop_replication_slot(slot_name)
FROM pg_replication_slots
WHERE slot_name = 'order_events_cdc_slot'
  AND NOT active;

-- -----------------------------------------------------------------------------
-- 2. Publication.
-- -----------------------------------------------------------------------------
DROP PUBLICATION IF EXISTS order_events_cdc_pub;

-- -----------------------------------------------------------------------------
-- 3. Dedicated login.
-- The privileges must be taken back before the login can be dropped. The
-- statements are generated only if the login exists, so a second run is quiet.
-- -----------------------------------------------------------------------------
SELECT statement
FROM (VALUES
        (1, 'REVOKE ALL ON TABLE public.order_events FROM cdc_user'),
        (2, 'REVOKE ALL ON SCHEMA public FROM cdc_user'),
        (3, 'REVOKE ALL ON DATABASE kafka_source_db FROM cdc_user'),
        (4, 'DROP ROLE cdc_user')
     ) AS steps(step, statement)
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cdc_user')
ORDER BY step
\gexec

-- -----------------------------------------------------------------------------
-- 4. Show what is left. Expected: no rows from any of the three queries.
-- A row in the first query means the slot is still in use: stop Kafka Connect
-- and run this script again.
-- -----------------------------------------------------------------------------
SELECT slot_name, active FROM pg_replication_slots WHERE slot_name = 'order_events_cdc_slot';
SELECT pubname FROM pg_publication WHERE pubname = 'order_events_cdc_pub';
SELECT rolname FROM pg_roles WHERE rolname = 'cdc_user';

-- The source data is untouched: this still reports the table's row count.
SELECT COUNT(*) AS order_events_rows FROM public.order_events;
