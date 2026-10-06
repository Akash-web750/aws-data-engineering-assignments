-- =============================================================================
-- 02_cdc_setup.sql   (PostgreSQL, run with psql)
-- Assignment 3 (Portfolio Assignment 9) - Kafka-to-Snowflake Streaming Pipeline
-- Enhancement: change data capture (CDC) from PostgreSQL
--
-- PURPOSE
--   Prepares the project database for Debezium:
--     1. a dedicated login (cdc_user) that may read the log and the one table;
--     2. a publication that releases ONLY inserts of NEW rows.
--
-- PREREQUISITE (done by hand, once, by an administrator)
--   wal_level must be 'logical'. This script checks it and stops if it is not:
--       ALTER SYSTEM SET wal_level = 'logical';
--       -- then restart the Windows service postgresql-x64-17
--
-- HOW TO RUN
--   From the project root, as the PostgreSQL superuser, inside the project
--   database. The password for the new login is passed as a psql variable,
--   so it is never written in this file:
--
--     $env:PGPASSWORD = "<superuser password>"
--     & "C:\Program Files\PostgreSQL\17\bin\psql.exe" -h localhost -U postgres `
--         -d kafka_source_db -v ON_ERROR_STOP=1 `
--         -v cdc_password="<password from .env: POSTGRES_CDC_PASSWORD>" `
--         -f sql/postgres/02_cdc_setup.sql
--
-- SAFE TO RE-RUN
--   Yes. Existing objects are left as they are.
--
-- WHAT IT DOES NOT DO
--   It does not change any server setting, does not restart anything, and
--   does not create the replication slot (Debezium creates it on first start).
--   Apart from the login, which PostgreSQL stores per server, everything is
--   created inside kafka_source_db only.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Guard 1: only ever run inside the project database.
-- -----------------------------------------------------------------------------
SELECT current_database() = 'kafka_source_db' AS in_project_database \gset
\if :in_project_database
\else
    \echo 'STOPPED: connect to kafka_source_db (-d kafka_source_db). Nothing was changed.'
    \quit
\endif

-- -----------------------------------------------------------------------------
-- Guard 2: logical replication must already be enabled on the server.
-- A publication can be created without it, but CDC would not work, so stop
-- here with a clear message instead.
-- -----------------------------------------------------------------------------
SELECT current_setting('wal_level') = 'logical' AS wal_level_is_logical \gset
\if :wal_level_is_logical
\else
    \echo 'STOPPED: wal_level is not logical. Enable it and restart PostgreSQL first. Nothing was changed.'
    \quit
\endif

-- -----------------------------------------------------------------------------
-- Guard 3: the password for the new login must have been supplied.
-- -----------------------------------------------------------------------------
\if :{?cdc_password}
\else
    \echo 'STOPPED: pass the password with  -v cdc_password="..."  Nothing was changed.'
    \quit
\endif

-- -----------------------------------------------------------------------------
-- 1. Dedicated login for Debezium.
--
-- LOGIN        : may connect.
-- REPLICATION  : may open a replication connection and read the write-ahead
--                log through a replication slot. This is what CDC needs.
-- It is NOT a superuser and owns nothing.
--
-- The statement is built with format(%L), which quotes the password safely,
-- and is executed by \gexec only when the login does not exist yet.
-- -----------------------------------------------------------------------------
SELECT format('CREATE ROLE cdc_user LOGIN REPLICATION PASSWORD %L', :'cdc_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cdc_user')
\gexec

-- Least privilege: connect to this one database, see the schema, read this
-- one table. No INSERT, UPDATE or DELETE, and no other table.
GRANT CONNECT ON DATABASE kafka_source_db TO cdc_user;
GRANT USAGE ON SCHEMA public TO cdc_user;
GRANT SELECT ON TABLE public.order_events TO cdc_user;

-- -----------------------------------------------------------------------------
-- 2. Publication: the list of changes PostgreSQL is willing to hand out.
--
-- This is protection layer 2 of 4 against re-publishing the 300 backfilled
-- rows (the README lists all four).
--
-- FOR TABLE public.order_events
--     only the source table.
-- WHERE (record_source <> 'project3_backfill')
--     a row filter (PostgreSQL 15+): rows of the one-time backfill never
--     leave the database. They are already in Snowflake.
-- WITH (publish = 'insert')
--     only INSERTs are published. Updates and deletes stay inside PostgreSQL,
--     because the Snowflake table is append-only in this phase.
--
-- Debezium is configured with publication.autocreate.mode=disabled, so it
-- uses this publication exactly as defined here and cannot replace it.
-- -----------------------------------------------------------------------------
SELECT $pub$
    CREATE PUBLICATION order_events_cdc_pub
        FOR TABLE public.order_events
        WHERE (record_source <> 'project3_backfill')
        WITH (publish = 'insert')
$pub$
WHERE NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'order_events_cdc_pub')
\gexec

-- -----------------------------------------------------------------------------
-- 3. Show the result.
-- -----------------------------------------------------------------------------
-- The login: can it replicate, and is it (correctly) not a superuser?
SELECT rolname, rolcanlogin, rolreplication, rolsuper
FROM pg_roles
WHERE rolname = 'cdc_user';

-- The publication: insert only (pubinsert = t, the others = f).
SELECT pubname, pubinsert, pubupdate, pubdelete, pubtruncate
FROM pg_publication
WHERE pubname = 'order_events_cdc_pub';

-- The table in the publication and its row filter.
SELECT pubname, schemaname, tablename, rowfilter
FROM pg_publication_tables
WHERE pubname = 'order_events_cdc_pub';

-- Replication slots at this point: none is expected yet for this project.
SELECT slot_name, plugin, database, active
FROM pg_replication_slots;
