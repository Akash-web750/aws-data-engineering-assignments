"""
Inserts new order events into the PostgreSQL source table.

Run from the project root:

    python -m source_db.insert_order_event                      # one schema-v3 order event
    python -m source_db.insert_order_event --schema-version 1
    python -m source_db.insert_order_event --count 5

This is the "application" side of the CDC demonstration: it writes a new row
to PostgreSQL and does nothing else. It does not talk to Kafka or Snowflake.
Once CDC is enabled, the row travels on its own:

    PostgreSQL (301 rows) -> Debezium -> Kafka -> CDC bridge -> Kafka -> consumer -> Snowflake (301 rows)

The event is built by the existing ``producer/event_factory.py``, so a row
inserted here has exactly the fields and value ranges the pipeline has been
tested with. The row is stored with ``record_source = 'application'`` (the
column's default), which is what distinguishes it from the 300 backfilled
rows that are already in Snowflake.

Each run prints the new event id, so the row can be looked up in Snowflake.
"""

from __future__ import annotations

import argparse
import logging
import uuid
from datetime import datetime, timezone
from typing import Any

from psycopg import sql
from psycopg.types.json import Jsonb

from config import settings
from producer.event_factory import MAX_SCHEMA_VERSION, MIN_SCHEMA_VERSION, build_event
from source_db import postgres

logger = logging.getLogger("source_db.insert_order_event")

# Columns this utility fills. record_source and the source_kafka_* columns are
# deliberately absent: a new row gets record_source = 'application' from the
# column default and has no Kafka origin.
INSERT_COLUMNS: tuple[str, ...] = (
    "event_id", "event_time", "order_id", "customer_id", "product", "quantity", "unit_price", "status",
    "payment_method", "discount_pct", "loyalty_tier", "is_gift", "shipping_address",
)


def event_to_row(event: dict[str, Any]) -> dict[str, Any]:
    """Convert an order event (producer format) into a PostgreSQL row.

    This function is pure (no database access), so it is unit tested directly.

    Args:
        event: An event as built by ``producer.event_factory.build_event``.

    Returns:
        ``{column: value}`` for every column in ``INSERT_COLUMNS``. Fields the
        event does not have (a version-1 event has no payment method) are None.
    """
    address = event.get("shipping_address")
    return {
        "event_id": uuid.UUID(event["event_id"]),
        # The producer writes ISO-8601 UTC ending in "Z"; make it a real
        # timestamp with a zone for the TIMESTAMPTZ column.
        "event_time": datetime.fromisoformat(event["event_time"].replace("Z", "+00:00")).astimezone(timezone.utc),
        "order_id": event["order_id"],
        "customer_id": event["customer_id"],
        "product": event["product"],
        "quantity": event["quantity"],
        "unit_price": event["unit_price"],
        "status": event["status"],
        "payment_method": event.get("payment_method"),
        "discount_pct": event.get("discount_pct"),
        "loyalty_tier": event.get("loyalty_tier"),
        "is_gift": event.get("is_gift"),
        # Jsonb() tells the driver to store the dictionary as JSONB.
        "shipping_address": Jsonb(address) if address is not None else None,
    }


def insert_events(events: list[dict[str, Any]]) -> list[tuple[str, str]]:
    """Insert the events into PostgreSQL in one transaction.

    Returns:
        ``(event_id, record_source)`` of every inserted row, as stored by
        PostgreSQL. ``record_source`` is read back to show that the row is
        marked as a new application row, not as a backfill row.
    """
    insert = sql.SQL("INSERT INTO {} ({}) VALUES ({}) RETURNING event_id, record_source").format(
        sql.Identifier(settings.POSTGRES_TABLE),
        sql.SQL(", ").join(sql.Identifier(name) for name in INSERT_COLUMNS),
        # Named placeholders: values are sent as bind variables.
        sql.SQL(", ").join(sql.Placeholder(name) for name in INSERT_COLUMNS),
    )
    inserted: list[tuple[str, str]] = []
    with postgres.connect() as connection:
        for event in events:
            event_id, record_source = connection.execute(insert, event_to_row(event)).fetchone()
            inserted.append((str(event_id), record_source))
        # Leaving the "with" block commits; an exception rolls everything back.
    return inserted


def main() -> None:
    """Entry point: build the requested events, insert them, report the result."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    parser = argparse.ArgumentParser(description="Insert new order events into the PostgreSQL source table.")
    parser.add_argument("--count", type=int, default=1, help="Number of order events to insert (default 1).")
    parser.add_argument(
        "--schema-version", type=int, default=MAX_SCHEMA_VERSION,
        choices=range(MIN_SCHEMA_VERSION, MAX_SCHEMA_VERSION + 1),
        help="Schema version of the events (default 3: every business field is filled).",
    )
    args = parser.parse_args()
    if args.count < 1:
        raise SystemExit("--count must be at least 1")

    with postgres.connect() as connection:
        before = postgres.summarise_table(connection)["total_rows"]

    # A random sequence number spreads the test orders over the order-id range.
    start = uuid.uuid4().int % 4000
    events = [build_event(args.schema_version, start + index) for index in range(args.count)]
    inserted = insert_events(events)

    with postgres.connect() as connection:
        after = postgres.summarise_table(connection)["total_rows"]

    for (event_id, record_source), event in zip(inserted, events):
        logger.info(
            "Inserted event_id=%s order_id=%s record_source=%s", event_id, event["order_id"], record_source
        )
    logger.info("PostgreSQL %s.%s: %d rows before, %d rows after.", settings.POSTGRES_DATABASE, settings.POSTGRES_TABLE, before, after)


if __name__ == "__main__":
    main()
