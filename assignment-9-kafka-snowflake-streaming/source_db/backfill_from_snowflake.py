"""
One-time backfill: copies the existing Project 3 order events into PostgreSQL.

Run from the project root, after ``python -m source_db.setup_database``:

    python -m source_db.backfill_from_snowflake

WHERE THE DATA COMES FROM
    The 300 events of the production demo exist in two places: the local Kafka
    topic and the Snowflake table ORDER_EVENTS. This script reads them from
    SNOWFLAKE, because that table is the verified end result of the pipeline:
    after the copy, PostgreSQL holds exactly the rows Snowflake holds.

WHAT IT DOES NOT DO
    It only READS from Snowflake and only WRITES to PostgreSQL. It sends
    nothing to Kafka and inserts nothing into Snowflake, so it cannot create
    duplicate rows in ORDER_EVENTS.

LOADED ONLY ONCE
    Running it again is harmless:
      * if the source table already holds rows, it stops before reading or
        writing anything (once CDC is running, Snowflake also holds events
        that were created in PostgreSQL, so it must not be copied again);
      * every insert uses ON CONFLICT (event_id) DO NOTHING, so even a
        repeated or interrupted run can never store an event twice;
      * the whole load is one transaction: either all rows arrive or none.
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timezone
from typing import Any

import snowflake.connector
from psycopg import sql
from psycopg.types.json import Jsonb

from config import settings
from source_db import postgres

logger = logging.getLogger("source_db.backfill_from_snowflake")

# Columns every ORDER_EVENTS table has (declared in sql/01_create_objects.sql).
_REQUIRED_SNOWFLAKE_COLUMNS: tuple[str, ...] = (
    "EVENT_ID", "EVENT_TIME", "ORDER_ID", "CUSTOMER_ID", "PRODUCT", "QUANTITY", "UNIT_PRICE", "STATUS",
    "DISCOUNT_PCT", "_KAFKA_TOPIC", "_KAFKA_PARTITION", "_KAFKA_OFFSET", "_KAFKA_TIMESTAMP",
)
# Columns Snowflake adds by schema evolution; they exist only once such a
# field has been loaded, so their presence is checked before selecting them.
_EVOLVED_SNOWFLAKE_COLUMNS: tuple[str, ...] = ("PAYMENT_METHOD", "LOYALTY_TIER", "IS_GIFT", "SHIPPING_ADDRESS")

# PostgreSQL columns filled by the backfill, in the order used by the INSERT.
POSTGRES_COLUMNS: tuple[str, ...] = (
    "event_id", "event_time", "order_id", "customer_id", "product", "quantity", "unit_price", "status",
    "payment_method", "discount_pct", "loyalty_tier", "is_gift", "shipping_address",
    "record_source", "source_kafka_topic", "source_kafka_partition", "source_kafka_offset", "source_kafka_timestamp",
)


def _as_utc(value: datetime | None) -> datetime | None:
    """Mark a Snowflake TIMESTAMP_NTZ value as UTC.

    The pipeline stores UTC wall-clock times without a zone in Snowflake.
    PostgreSQL's TIMESTAMPTZ needs to know the zone, otherwise it would assume
    the server's local zone and shift every value.
    """
    if value is None:
        return None
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def to_source_row(event: dict[str, Any]) -> dict[str, Any]:
    """Convert one ORDER_EVENTS row from Snowflake into one PostgreSQL row.

    This function is pure (no database access), so it is unit tested directly.

    Args:
        event: One Snowflake row as ``{COLUMN_NAME: value}``. Evolved columns
            may be missing or None.

    Returns:
        ``{postgres column: value}`` for every column in ``POSTGRES_COLUMNS``.

    Raises:
        ValueError: if the row has no event id, which is the primary key.
    """
    if not event.get("EVENT_ID"):
        raise ValueError("Snowflake row has no EVENT_ID; it cannot be used as a primary key")

    address = event.get("SHIPPING_ADDRESS")
    if isinstance(address, str):
        # The Snowflake driver returns a VARIANT value as JSON text.
        address = json.loads(address)

    return {
        # uuid.UUID() also validates that the id really is a UUID.
        "event_id": uuid.UUID(str(event["EVENT_ID"])),
        "event_time": _as_utc(event["EVENT_TIME"]),
        "order_id": event["ORDER_ID"],
        "customer_id": int(event["CUSTOMER_ID"]),
        "product": event["PRODUCT"],
        "quantity": int(event["QUANTITY"]),
        # Decimal values are passed through unchanged, so no precision is lost.
        "unit_price": event["UNIT_PRICE"],
        "status": event["STATUS"],
        "payment_method": event.get("PAYMENT_METHOD"),
        "discount_pct": event.get("DISCOUNT_PCT"),
        "loyalty_tier": event.get("LOYALTY_TIER"),
        "is_gift": event.get("IS_GIFT"),
        # Jsonb() tells the PostgreSQL driver to store the dict as JSONB.
        "shipping_address": Jsonb(address) if address is not None else None,
        # Marks the row as "already in Snowflake" for future CDC.
        "record_source": settings.POSTGRES_BACKFILL_SOURCE,
        "source_kafka_topic": event.get("_KAFKA_TOPIC"),
        "source_kafka_partition": event.get("_KAFKA_PARTITION"),
        "source_kafka_offset": event.get("_KAFKA_OFFSET"),
        "source_kafka_timestamp": _as_utc(event.get("_KAFKA_TIMESTAMP")),
    }


def fetch_events_from_snowflake() -> list[dict[str, Any]]:
    """Read every order event from Snowflake ORDER_EVENTS. Read-only.

    One row per Kafka message is returned: if a message was ever loaded twice
    (possible with at-least-once delivery), only its earliest copy is taken,
    the same rule the view ORDER_EVENTS_LATEST applies.
    """
    connection = snowflake.connector.connect(
        connection_name=settings.require_snowflake_connection_name(),
        role=settings.SNOWFLAKE_ROLE,
        warehouse=settings.SNOWFLAKE_WAREHOUSE,
        database=settings.SNOWFLAKE_DATABASE,
        schema=settings.SNOWFLAKE_SCHEMA,
        # TIMEZONE = UTC keeps returned timestamps free of any local shift.
        session_parameters={"QUERY_TAG": settings.SNOWFLAKE_QUERY_TAG + "_pg_backfill", "TIMEZONE": "UTC"},
    )
    try:
        cursor = connection.cursor()
        # DESCRIBE needs no warehouse; it tells us which evolved columns exist.
        cursor.execute(f"DESCRIBE TABLE {settings.SNOWFLAKE_TABLE}")
        existing = {row[0] for row in cursor.fetchall()}
        missing = [name for name in _REQUIRED_SNOWFLAKE_COLUMNS if name not in existing]
        if missing:
            raise RuntimeError(f"{settings.SNOWFLAKE_TABLE} lacks expected columns: {missing}")
        # Column names come from the fixed tuples above, never from user input.
        columns = list(_REQUIRED_SNOWFLAKE_COLUMNS) + [name for name in _EVOLVED_SNOWFLAKE_COLUMNS if name in existing]

        cursor.execute(
            f"SELECT {', '.join(columns)} FROM {settings.SNOWFLAKE_TABLE} "
            "QUALIFY ROW_NUMBER() OVER ("
            "PARTITION BY _KAFKA_TOPIC, _KAFKA_PARTITION, _KAFKA_OFFSET ORDER BY _INGESTED_AT) = 1 "
            "ORDER BY _KAFKA_TIMESTAMP, _KAFKA_PARTITION, _KAFKA_OFFSET"
        )
        names = [column[0] for column in cursor.description]
        return [dict(zip(names, row)) for row in cursor.fetchall()]
    finally:
        connection.close()


def load_rows(rows: list[dict[str, Any]]) -> int:
    """Insert the rows into PostgreSQL in one transaction.

    Returns:
        The number of rows actually inserted (rows whose event id was already
        present are skipped by ON CONFLICT and not counted).
    """
    insert = sql.SQL("INSERT INTO {} ({}) VALUES ({}) ON CONFLICT (event_id) DO NOTHING").format(
        sql.Identifier(settings.POSTGRES_TABLE),
        sql.SQL(", ").join(sql.Identifier(name) for name in POSTGRES_COLUMNS),
        # Named placeholders: values are sent as bind variables, never built into the SQL text.
        sql.SQL(", ").join(sql.Placeholder(name) for name in POSTGRES_COLUMNS),
    )
    inserted = 0
    with postgres.connect() as connection:
        with connection.cursor() as cursor:
            for row in rows:
                cursor.execute(insert, row)
                # rowcount is 1 for an inserted row and 0 for a skipped one.
                inserted += cursor.rowcount
        # Leaving the "with" block commits; an exception rolls everything back.
    return inserted


def main() -> None:
    """Entry point: copy the events once and verify the result."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # The Snowflake driver logs every statement at INFO; keep the output readable.
    logging.getLogger("snowflake.connector").setLevel(logging.WARNING)

    with postgres.connect() as connection:
        if not postgres.table_exists(connection):
            raise SystemExit("The source table does not exist. Run: python -m source_db.setup_database")
        before = postgres.summarise_table(connection)

    if before["total_rows"] > 0:
        # The backfill is a one-time step for an EMPTY source table. Once the
        # table holds rows, Snowflake is no longer a list of "rows missing in
        # PostgreSQL": with CDC running, Snowflake also contains events that
        # were created in PostgreSQL. Stop here, before reading or writing.
        logger.info(
            "PostgreSQL already holds %d rows (%d backfilled); nothing to load. The backfill runs only once.",
            before["total_rows"], before["backfill_rows"],
        )
        return

    events = fetch_events_from_snowflake()
    logger.info("Snowflake %s holds %d order events.", settings.SNOWFLAKE_TABLE, len(events))
    inserted = load_rows([to_source_row(event) for event in events])
    logger.info("Inserted %d rows into PostgreSQL %s.%s.", inserted, settings.POSTGRES_DATABASE, settings.POSTGRES_TABLE)

    with postgres.connect() as connection:
        after = postgres.summarise_table(connection)
    logger.info(
        "PostgreSQL now: %d rows (%d backfilled), %d distinct event ids, %d duplicate event ids, %d duplicate Kafka keys.",
        after["total_rows"], after["backfill_rows"], after["distinct_event_ids"],
        after["duplicate_event_ids"], after["duplicate_kafka_keys"],
    )
    if after["backfill_rows"] != len(events):
        raise SystemExit(
            f"Mismatch: Snowflake has {len(events)} events but PostgreSQL has {after['backfill_rows']} backfilled rows."
        )
    logger.info("Verified: PostgreSQL backfilled rows = Snowflake rows = %d.", len(events))


if __name__ == "__main__":
    main()
