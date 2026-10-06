"""
Turns one Debezium change event into one order-event message in the EXISTING format.

This module is pure: no Kafka import, no database access, no I/O. Everything
that decides what reaches the existing ``order_events`` topic is here, so it
can be unit tested with plain dictionaries.

WHAT COMES IN
    A Debezium change event for the PostgreSQL table ``order_events``:

        {"before": null,
         "after":  {"event_id": "...", "event_time": "2026-10-06T12:23:49.370000Z",
                    "unit_price": 799.0, "shipping_address": "{\\"city\\": ...}",
                    "record_source": "application", "created_at": "...", ...},
         "source": {"table": "order_events", "snapshot": "false", ...},
         "op": "c", "ts_ms": 1791289429000}

WHAT GOES OUT
    Exactly what ``producer/event_factory.py`` produces, so the existing
    consumer cannot tell the difference:

        {"event_id": "...", "event_time": "2026-10-06T12:23:49.370Z",
         "order_id": "...", "customer_id": 1, "product": "...", "quantity": 1,
         "unit_price": 799.0, "status": "...", ...}

    with the message key set to the order id, as the producer does.

THREE POSSIBLE OUTCOMES for a change event (see ``transform_change_event``)
    Forward  - a new row was INSERTED in PostgreSQL: send it on.
    Skip     - a valid change event that must NOT be sent on: a snapshot read,
               an update, a delete, or a row of the one-time backfill. Skipping
               is the normal, silent case; nothing is wrong with the message.
    rejected - the message cannot be understood or converted. ``CdcRejected``
               is raised and the bridge sends the original bytes to the
               dead-letter topic.

WHY THE BACKFILL AND SNAPSHOTS ARE SKIPPED HERE
    The 300 rows copied from the Project 3 demo are already in Snowflake.
    Debezium is configured not to snapshot the table and PostgreSQL's
    publication filters those rows out, so they should never arrive here. This
    module is the third, independent safeguard: even if both of those were
    misconfigured, a snapshot read (operation "r") or a row marked
    ``project3_backfill`` is dropped and never reaches Snowflake a second time.
"""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

from config import settings

# Debezium operation codes.
OP_CREATE = "c"        # a row was inserted
OP_SNAPSHOT_READ = "r"  # a row read during an initial snapshot (not a new row)
OP_UPDATE = "u"
OP_DELETE = "d"
OP_TRUNCATE = "t"
OP_MESSAGE = "m"       # a logical decoding message, not a row change

# Operations that are understood but deliberately not forwarded in this phase.
# Only INSERTs flow to Snowflake: ORDER_EVENTS is an append-only event table,
# so an update or delete has no defined meaning there yet.
_SKIPPED_OPERATIONS: dict[str, str] = {
    OP_SNAPSHOT_READ: "snapshot read: the row existed before CDC started",
    OP_UPDATE: "update: only inserts are forwarded in this phase",
    OP_DELETE: "delete: only inserts are forwarded in this phase",
    OP_TRUNCATE: "truncate: only inserts are forwarded in this phase",
    OP_MESSAGE: "logical decoding message: not a row change",
}

# Columns whose PostgreSQL type is JSONB. Debezium sends JSONB as a JSON
# *string*; the existing message format carries a nested object instead.
# A JSONB column added to the table later must be listed here as well.
JSON_COLUMNS: frozenset[str] = frozenset({"shipping_address"})

# Columns that must hold a number in the outgoing message. Debezium is
# configured with decimal.handling.mode=double, which already sends numbers;
# numeric text (decimal.handling.mode=string) is accepted as well.
NUMERIC_COLUMNS: frozenset[str] = frozenset({"unit_price", "discount_pct"})

# Columns that must hold a whole number in the outgoing message.
INTEGER_COLUMNS: frozenset[str] = frozenset({"customer_id", "quantity"})

# An ISO-8601 timestamp with a zone, as Debezium sends TIMESTAMPTZ values:
# 2026-10-06T12:23:49Z, ...49.37Z, ...49.370000Z or ...49.370000+00:00.
# The fraction can have any number of digits, which datetime.fromisoformat
# does not accept on every supported Python version, so it is parsed here.
_ISO_TIMESTAMP = re.compile(
    r"^(?P<date>\d{4}-\d{2}-\d{2})[T ](?P<time>\d{2}:\d{2}:\d{2})"
    r"(?:\.(?P<fraction>\d{1,9}))?"
    r"(?P<zone>Z|[+-]\d{2}:?\d{2})$"
)


class CdcRejected(Exception):
    """Raised when a change event cannot be understood or converted.

    The text explains why; the bridge stores it in the ``error`` header of the
    dead-letter message.
    """


@dataclass(frozen=True)
class Forward:
    """A new order event to send to the existing order-events topic."""

    # Kafka message key: the order id, exactly as the producer sets it.
    key: bytes
    # The message value, in the producer's format and field order.
    event: dict[str, Any]


@dataclass(frozen=True)
class Skip:
    """A valid change event that is deliberately not forwarded."""

    reason: str


def format_event_time(value: Any) -> str:
    """Convert Debezium's TIMESTAMPTZ text into the producer's timestamp format.

    The producer writes UTC with millisecond precision and a trailing ``Z``
    (``2026-10-06T12:23:49.370Z``). Debezium writes microseconds and may use
    any zone offset, so the value is converted to UTC and cut to milliseconds.

    Raises:
        CdcRejected: if the value is not an ISO-8601 timestamp with a zone.
    """
    if not isinstance(value, str):
        raise CdcRejected(f"event_time must be an ISO-8601 text, got {type(value).__name__}")
    match = _ISO_TIMESTAMP.match(value.strip())
    if not match:
        raise CdcRejected(f"event_time is not an ISO-8601 timestamp with a zone: {value!r}")

    try:
        moment = datetime.strptime(f"{match['date']} {match['time']}", "%Y-%m-%d %H:%M:%S")
    except ValueError as exc:
        raise CdcRejected(f"event_time is not a valid date and time: {value!r}") from exc

    # Fraction of a second: pad or cut to microseconds (6 digits).
    fraction = (match["fraction"] or "").ljust(6, "0")[:6]
    moment = moment.replace(microsecond=int(fraction))

    # Apply the zone offset to get UTC.
    zone = match["zone"]
    if zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        digits = zone[1:].replace(":", "")
        moment -= sign * timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    moment = moment.replace(tzinfo=timezone.utc)

    # Same expression as producer/event_factory.py uses, so the text is identical.
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _to_number(column: str, value: Any) -> int | float:
    """Return a JSON number for a numeric column.

    Raises:
        CdcRejected: if the value is not a number or numeric text. A base64
            text is what Debezium sends with decimal.handling.mode=precise,
            which this bridge does not support; the message says so.
    """
    # bool is a subclass of int in Python, but true/false is not a price.
    if isinstance(value, bool):
        raise CdcRejected(f"{column} must be a number, got a boolean")
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError as exc:
            raise CdcRejected(
                f"{column} is not numeric: {value!r} "
                "(Debezium must use decimal.handling.mode=double or string)"
            ) from exc
    raise CdcRejected(f"{column} must be a number, got {type(value).__name__}")


def _to_integer(column: str, value: Any) -> int:
    """Return a whole number for an integer column.

    Raises:
        CdcRejected: if the value is not a whole number.
    """
    if isinstance(value, bool) or not isinstance(value, int):
        raise CdcRejected(f"{column} must be a whole number, got {value!r}")
    return value


def _to_json_value(column: str, value: Any) -> Any:
    """Return the nested object for a JSONB column.

    Debezium sends JSONB as JSON text. A value that is already an object or a
    list is passed through.

    Raises:
        CdcRejected: if the text is not valid JSON.
    """
    if isinstance(value, (dict, list)):
        return value
    if not isinstance(value, str):
        raise CdcRejected(f"{column} must be JSON text or an object, got {type(value).__name__}")
    try:
        return json.loads(value)
    except json.JSONDecodeError as exc:
        raise CdcRejected(f"{column} does not contain valid JSON: {exc}") from exc


def build_order_event(row: dict[str, Any]) -> dict[str, Any]:
    """Convert the ``after`` image of an inserted row into an order event.

    Rules, in order:
        * technical columns are removed (``CDC_TECHNICAL_COLUMNS``);
        * a column that is NULL is left out, as the producer leaves out a
          field a schema version does not have;
        * known columns are converted to the producer's types;
        * every other column is forwarded unchanged, so a genuinely new
          business column still reaches Snowflake and becomes a new column
          there through schema evolution.

    The column order of the row is kept, which is the producer's field order.

    Raises:
        CdcRejected: if a required field is missing or a value cannot be converted.
    """
    event: dict[str, Any] = {}
    for column, value in row.items():
        if column in settings.CDC_TECHNICAL_COLUMNS:
            continue
        if value is None:
            continue
        if column == "event_id":
            try:
                # Validates the id and normalises it to the canonical lower-case form.
                event[column] = str(uuid.UUID(str(value)))
            except ValueError as exc:
                raise CdcRejected(f"event_id is not a UUID: {value!r}") from exc
        elif column == "event_time":
            event[column] = format_event_time(value)
        elif column in NUMERIC_COLUMNS:
            event[column] = _to_number(column, value)
        elif column in INTEGER_COLUMNS:
            event[column] = _to_integer(column, value)
        elif column in JSON_COLUMNS:
            event[column] = _to_json_value(column, value)
        else:
            # Text, boolean and any new business column: unchanged.
            event[column] = value

    # Without these three the message would not be a usable order event:
    # event_id identifies it, event_time orders it, order_id is the Kafka key.
    for required in ("event_id", "event_time", "order_id"):
        if required not in event:
            raise CdcRejected(f"Inserted row has no {required}")
    if not isinstance(event["order_id"], str) or not event["order_id"]:
        raise CdcRejected(f"order_id must be non-empty text, got {event['order_id']!r}")
    return event


def transform_change_event(value: bytes | None) -> Forward | Skip:
    """Decide what to do with one message from the CDC topic.

    Args:
        value: Raw message value written by Debezium, or ``None`` for a tombstone.

    Returns:
        ``Forward`` for an inserted row, ``Skip`` for a valid change event
        that must not be forwarded.

    Raises:
        CdcRejected: if the message is not a usable Debezium change event.
    """
    if value is None:
        # A tombstone follows a delete so that log compaction can remove the key.
        return Skip("tombstone: carries no row")

    try:
        message = json.loads(value.decode("utf-8"))
    except UnicodeDecodeError as exc:
        raise CdcRejected(f"Change event is not valid UTF-8: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise CdcRejected(f"Change event is not valid JSON: {exc}") from exc
    if not isinstance(message, dict):
        raise CdcRejected(f"Change event must be a JSON object, got {type(message).__name__}")

    # With "schemas.enable=true" the JSON converter wraps the event as
    # {"schema": ..., "payload": ...}. The worker is configured without
    # schemas, but accepting both keeps a configuration slip from losing data.
    if "payload" in message and "schema" in message:
        message = message["payload"]
        if not isinstance(message, dict):
            raise CdcRejected("Change event has an empty payload")

    operation = message.get("op")
    if operation is None:
        raise CdcRejected("Message has no 'op' field; it is not a Debezium change event")
    if operation in _SKIPPED_OPERATIONS:
        return Skip(_SKIPPED_OPERATIONS[operation])
    if operation != OP_CREATE:
        raise CdcRejected(f"Unknown Debezium operation {operation!r}")

    # Only the project's source table is expected in this topic.
    source = message.get("source") or {}
    table = source.get("table")
    if table is not None and table != settings.POSTGRES_TABLE:
        return Skip(f"change event of another table: {table}")

    row = message.get("after")
    if not isinstance(row, dict):
        raise CdcRejected("Insert event has no 'after' row image")

    # Rows of the one-time backfill are already in Snowflake.
    if row.get("record_source") == settings.POSTGRES_BACKFILL_SOURCE:
        return Skip("backfill row: already present in Snowflake")

    event = build_order_event(row)
    # The producer keys every message by the order id (UTF-8).
    return Forward(key=event["order_id"].encode("utf-8"), event=event)
