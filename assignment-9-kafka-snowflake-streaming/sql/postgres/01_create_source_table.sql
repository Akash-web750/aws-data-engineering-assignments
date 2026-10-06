-- =============================================================================
-- 01_create_source_table.sql   (PostgreSQL, NOT Snowflake)
-- Assignment 3 (Portfolio Assignment 9) - Kafka-to-Snowflake Streaming Pipeline
-- Enhancement: local PostgreSQL source database
--
-- PURPOSE
--   Creates the source table for order events in the project's own PostgreSQL
--   database (default name: kafka_source_db). In a later step, change data
--   capture (CDC) will read this table and publish its changes to Kafka; the
--   existing consumer then loads them into Snowflake as it does today.
--
-- WHO RUNS THIS
--   Not run by hand. "python -m source_db.setup_database" creates the database
--   if it is missing and then executes this file inside it.
--
-- SAFE TO RE-RUN
--   Yes. Every statement uses IF NOT EXISTS, so existing data is kept.
--
-- SCOPE
--   Only objects inside the project database are created. No other database
--   on the server is touched.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Source table: one row per order event.
--
-- The business columns mirror the Snowflake table ORDER_EVENTS so that a row
-- can travel PostgreSQL -> Kafka -> Snowflake without renaming anything:
--   event_id ... status            = schema version 1 fields (always present)
--   payment_method, discount_pct   = added in schema version 2 (nullable)
--   loyalty_tier, is_gift,
--   shipping_address               = added in schema version 3 (nullable)
--
-- Unlike the Snowflake table, this is a classic typed source table: columns
-- are declared here and are not added automatically.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS order_events (
    -- Business key of the event. It is the same UUID the producer put in the
    -- Kafka message and the same value as EVENT_ID in Snowflake, so a row can
    -- be matched across all three systems. PRIMARY KEY also makes the one-time
    -- backfill safe to repeat (a second load cannot insert the row again).
    event_id                UUID            PRIMARY KEY,

    -- When the event happened. TIMESTAMPTZ stores an absolute moment; the
    -- backfill writes the UTC values held in Snowflake.
    event_time              TIMESTAMPTZ     NOT NULL,

    -- Order the event belongs to. NOT unique: one order has several events.
    order_id                VARCHAR(50)     NOT NULL,
    customer_id             INTEGER         NOT NULL,
    product                 VARCHAR(200)    NOT NULL,
    -- An order line always has at least one unit.
    quantity                INTEGER         NOT NULL CHECK (quantity > 0),
    -- Price of one unit in INR; same precision as UNIT_PRICE in Snowflake.
    unit_price              NUMERIC(12,2)   NOT NULL CHECK (unit_price >= 0),
    status                  VARCHAR(30)     NOT NULL,

    -- Schema version 2 fields. NULL for events that predate them.
    payment_method          VARCHAR(30),
    -- Same explicit type as DISCOUNT_PCT in Snowflake (NUMBER(5,2)).
    discount_pct            NUMERIC(5,2),

    -- Schema version 3 fields. NULL for events that predate them.
    loyalty_tier            VARCHAR(30),
    is_gift                 BOOLEAN,
    -- Nested object (city, state, pincode); JSONB keeps it queryable, like the
    -- VARIANT column SHIPPING_ADDRESS in Snowflake.
    shipping_address        JSONB,

    -- Where the row came from:
    --   'application'       = created in PostgreSQL (the default, for new rows)
    --   'project3_backfill' = copied once from the Project 3 production demo
    -- The backfilled rows are ALREADY in Snowflake. Future CDC must use this
    -- column (or skip its initial snapshot) so they are not sent to Kafka and
    -- loaded into Snowflake a second time.
    record_source           VARCHAR(30)     NOT NULL DEFAULT 'application',

    -- Original Kafka position of a backfilled row (topic, partition, offset)
    -- and the broker timestamp, taken from the _KAFKA_* columns in Snowflake.
    -- They are provenance only, and NULL for rows created in PostgreSQL.
    source_kafka_topic      VARCHAR(255),
    source_kafka_partition  INTEGER,
    source_kafka_offset     BIGINT,
    source_kafka_timestamp  TIMESTAMPTZ,

    -- Bookkeeping, useful for CDC and for debugging.
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- A Kafka message is identified by (topic, partition, offset). This
    -- constraint guarantees the backfill never stores the same message twice.
    -- PostgreSQL treats NULLs as distinct, so rows created in PostgreSQL
    -- (all three columns NULL) are not affected.
    CONSTRAINT uq_order_events_kafka_origin
        UNIQUE (source_kafka_topic, source_kafka_partition, source_kafka_offset)
);

-- Table and column descriptions, visible in psql (\d+) and in database tools.
COMMENT ON TABLE order_events IS
    'Source table of order events. Future CDC publishes its changes to Kafka; the existing consumer loads them into Snowflake.';
COMMENT ON COLUMN order_events.event_id IS
    'Business key of the event (UUID); equals EVENT_ID in Snowflake and event_id in the Kafka message';
COMMENT ON COLUMN order_events.record_source IS
    'application = created in PostgreSQL; project3_backfill = copied once from the Project 3 demo and already present in Snowflake';
COMMENT ON COLUMN order_events.source_kafka_offset IS
    'Original Kafka offset of a backfilled row; NULL for rows created in PostgreSQL';

-- -----------------------------------------------------------------------------
-- Indexes for the lookups this table is expected to serve.
-- -----------------------------------------------------------------------------
-- All events of one order, in time order.
CREATE INDEX IF NOT EXISTS ix_order_events_order_id   ON order_events (order_id, event_time);
-- Time-range scans (for example "events of the last hour").
CREATE INDEX IF NOT EXISTS ix_order_events_event_time ON order_events (event_time);
