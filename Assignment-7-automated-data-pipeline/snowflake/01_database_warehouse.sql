/* =============================================================================
   Assignment 7 - 01_database_warehouse.sql
   -----------------------------------------------------------------------------
   RUN AS: A7_PIPELINE_ROLE  (after 00 has run)
       snow sql -c <connection> --role A7_PIPELINE_ROLE --warehouse A7_PIPELINE_WH -f snowflake/01_database_warehouse.sql

   The database and warehouse are CREATED by 00_admin_bootstrap.sql (ACCOUNTADMIN).
   A7_PIPELINE_WH stays owned by ACCOUNTADMIN with its final settings (X-Small,
   AUTO_SUSPEND 60, monitor A7_PIPELINE_RM). This role has only USAGE/OPERATE/MONITOR
   on it and deliberately cannot resize it. This script creates the schemas.

   --warehouse only pins the session to the A7 warehouse instead of the connection's
   default warehouse (which this role may not be able to use). Setting it does NOT
   resume it. Nothing here needs compute: DDL runs in cloud services.
   Idempotent; no CREATE OR REPLACE.
   ============================================================================= */

USE ROLE A7_PIPELINE_ROLE;

-- -----------------------------------------------------------------------------
-- Database settings
-- -----------------------------------------------------------------------------
ALTER DATABASE A7_ORDERS_DB SET DATA_RETENTION_TIME_IN_DAYS = 1;

-- -----------------------------------------------------------------------------
-- Layered schemas
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS A7_ORDERS_DB.RAW
    COMMENT = 'Raw landing layer for Assignment 7';

CREATE SCHEMA IF NOT EXISTS A7_ORDERS_DB.CURATED
    COMMENT = 'Curated good and bad records';

CREATE SCHEMA IF NOT EXISTS A7_ORDERS_DB.REPORTING
    COMMENT = 'EOD data quality reporting';

-- -----------------------------------------------------------------------------
-- Verification (read-only, metadata only)
-- -----------------------------------------------------------------------------
SHOW SCHEMAS IN DATABASE A7_ORDERS_DB;
SHOW WAREHOUSES LIKE 'A7_PIPELINE_WH';
