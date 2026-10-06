"""
Turns one raw Kafka message into one record ready to be loaded into Snowflake.

This module is pure: no Kafka import, no Snowflake import, no I/O. That keeps
the rules below easy to unit test.

What happens to a message:
    1. The bytes are parsed as JSON. The value must be a JSON object.
    2. Every top-level field name is normalised into a valid, predictable
       Snowflake column name (see ``normalise_field_name``).
    3. Kafka metadata fields are added (topic, partition, offset, timestamps).

A message that cannot be handled raises ``MessageRejected``; the consumer then
sends it to the dead-letter topic instead of stopping the pipeline.

Note what this module does NOT do: it does not decide which columns exist.
Unknown fields are passed through untouched, and Snowflake's schema evolution
creates the columns for them during COPY INTO.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Any

# Names of the metadata fields the consumer adds to every record. They start
# with "_" so they cannot be confused with business fields from the producer.
META_TOPIC = "_KAFKA_TOPIC"
META_PARTITION = "_KAFKA_PARTITION"
META_OFFSET = "_KAFKA_OFFSET"
META_TIMESTAMP = "_KAFKA_TIMESTAMP"
META_INGESTED_AT = "_INGESTED_AT"
METADATA_FIELDS: frozenset[str] = frozenset(
    {META_TOPIC, META_PARTITION, META_OFFSET, META_TIMESTAMP, META_INGESTED_AT}
)

# Any character that is not allowed in a plain (unquoted) Snowflake identifier.
_INVALID_IDENTIFIER_CHARS = re.compile(r"[^A-Z0-9_]")

# Snowflake limits identifiers to 255 characters.
_MAX_IDENTIFIER_LENGTH = 255


class MessageRejected(Exception):
    """Raised when a Kafka message cannot be turned into a record.

    The message text explains why; the consumer stores it in the ``error``
    header of the dead-letter message.
    """


def normalise_field_name(name: str) -> str:
    """Convert a JSON field name into a valid Snowflake column name.

    Rules (spec.md section 8.3):
        * upper-case the name;
        * replace every character other than A-Z, 0-9 and ``_`` with ``_``;
        * if the result starts with a digit, put ``_`` in front.

    Examples:
        ``"discount_pct"`` -> ``"DISCOUNT_PCT"``
        ``"discount %"``   -> ``"DISCOUNT__"``
        ``"2nd_item"``     -> ``"_2ND_ITEM"``

    Raises:
        MessageRejected: if the name is empty or longer than Snowflake allows.
    """
    if not name:
        raise MessageRejected("Field name is empty")
    normalised = _INVALID_IDENTIFIER_CHARS.sub("_", name.upper())
    if normalised[0].isdigit():
        normalised = "_" + normalised
    if len(normalised) > _MAX_IDENTIFIER_LENGTH:
        raise MessageRejected(f"Field name is longer than {_MAX_IDENTIFIER_LENGTH} characters: {name[:50]}...")
    return normalised


def _reject_constant(token: str) -> Any:
    """Refuse NaN / Infinity, which Python accepts but strict JSON does not.

    Python's ``json`` module would read these and later write them back out as
    ``NaN``, producing a batch file that is not valid JSON for Snowflake.
    """
    raise MessageRejected(f"Message contains the non-JSON number {token}")


def parse_message(value: bytes | None) -> dict[str, Any]:
    """Parse the raw bytes of a Kafka message into a dictionary.

    Raises:
        MessageRejected: if the value is missing, not UTF-8, not valid JSON,
            or valid JSON that is not an object (for example a list or number).
    """
    if value is None:
        raise MessageRejected("Message has no value")
    try:
        parsed = json.loads(value.decode("utf-8"), parse_constant=_reject_constant)
    except UnicodeDecodeError as exc:
        raise MessageRejected(f"Message is not valid UTF-8: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise MessageRejected(f"Message is not valid JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise MessageRejected(f"Message must be a JSON object, got {type(parsed).__name__}")
    return parsed


def format_timestamp(moment: datetime) -> str:
    """Format a datetime as UTC text for a TIMESTAMP_NTZ column.

    Example: ``2026-10-06 11:13:31.308``. No zone suffix is written because the
    column has no time zone; the value is always UTC by convention.
    """
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def build_record(
    value: bytes | None,
    topic: str,
    partition: int,
    offset: int,
    kafka_timestamp_ms: int | None,
    ingested_at: datetime,
) -> dict[str, Any]:
    """Build the record that will be written to the batch file for one message.

    Args:
        value: Raw message value from Kafka.
        topic: Topic the message was read from.
        partition: Partition the message was read from.
        offset: Offset of the message inside its partition.
        kafka_timestamp_ms: Broker timestamp in milliseconds since 1970, or
            ``None`` if the message has none.
        ingested_at: Time the consumer handled the message.

    Returns:
        A dictionary whose keys are normalised column names: the message's own
        top-level fields plus the five metadata fields.

    Raises:
        MessageRejected: if the message cannot be parsed, a field name is not
            usable, two field names normalise to the same column, or a field
            would overwrite a metadata column.
    """
    payload = parse_message(value)

    record: dict[str, Any] = {}
    for original_name, field_value in payload.items():
        column = normalise_field_name(original_name)
        if column in METADATA_FIELDS:
            # A producer field must never replace the consumer's own metadata,
            # because de-duplication relies on these columns being trustworthy.
            raise MessageRejected(f"Field {original_name!r} clashes with the metadata column {column}")
        if column in record:
            # Example: "order id" and "order_id" would both become ORDER_ID.
            # Loading either one silently would lose data, so reject instead.
            raise MessageRejected(f"More than one field maps to the column {column}")
        record[column] = field_value

    # Metadata that identifies exactly where the row came from. Topic,
    # partition and offset together identify one Kafka message uniquely.
    record[META_TOPIC] = topic
    record[META_PARTITION] = partition
    record[META_OFFSET] = offset
    record[META_TIMESTAMP] = (
        format_timestamp(datetime.fromtimestamp(kafka_timestamp_ms / 1000, tz=timezone.utc))
        if kafka_timestamp_ms is not None and kafka_timestamp_ms >= 0
        else None
    )
    record[META_INGESTED_AT] = format_timestamp(ingested_at)
    return record
