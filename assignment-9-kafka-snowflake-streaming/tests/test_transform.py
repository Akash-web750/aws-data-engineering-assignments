"""
Unit tests for consumer/transform.py.

They cover the rules that decide what is loaded into Snowflake and what is
sent to the dead-letter topic: JSON parsing, column-name normalisation, name
collisions and the Kafka metadata fields.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone

import pytest

from consumer.transform import (
    METADATA_FIELDS,
    MessageRejected,
    build_record,
    format_timestamp,
    normalise_field_name,
    parse_message,
)

# Fixed values used wherever a test needs Kafka coordinates and a time.
INGESTED_AT = datetime(2026, 10, 6, 11, 0, 0, 5000, tzinfo=timezone.utc)
# 2026-10-06 10:00:00.250 UTC in milliseconds since 1970.
KAFKA_TS_MS = int(datetime(2026, 10, 6, 10, 0, 0, 250000, tzinfo=timezone.utc).timestamp() * 1000)


def record_for(payload, **overrides):
    """Build a record from a Python object (or raw bytes) with default metadata."""
    value = payload if isinstance(payload, (bytes, type(None))) else json.dumps(payload).encode("utf-8")
    arguments = dict(
        value=value, topic="order_events", partition=2, offset=17,
        kafka_timestamp_ms=KAFKA_TS_MS, ingested_at=INGESTED_AT,
    )
    arguments.update(overrides)
    return build_record(**arguments)


# ---------------------------------------------------------------------------
# normalise_field_name
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("original", "expected"),
    [
        ("quantity", "QUANTITY"),            # lower case is upper-cased
        ("discount_pct", "DISCOUNT_PCT"),    # underscores are kept
        ("discount %", "DISCOUNT__"),        # space and % each become _
        ("shipping-address", "SHIPPING_ADDRESS"),
        ("price.inr", "PRICE_INR"),
        ("2nd_item", "_2ND_ITEM"),           # may not start with a digit
        ("Ünïcode", "_N_CODE"),              # non-ASCII letters become _
        ("AlreadyUPPER", "ALREADYUPPER"),
    ],
)
def test_field_names_are_normalised(original, expected):
    """Each JSON field name maps to a valid, predictable Snowflake column name."""
    assert normalise_field_name(original) == expected


def test_empty_field_name_is_rejected():
    """An empty name cannot become a column."""
    with pytest.raises(MessageRejected):
        normalise_field_name("")


def test_overlong_field_name_is_rejected():
    """Names beyond Snowflake's 255-character limit are rejected, not truncated."""
    with pytest.raises(MessageRejected):
        normalise_field_name("x" * 256)


# ---------------------------------------------------------------------------
# parse_message
# ---------------------------------------------------------------------------

def test_valid_object_is_parsed():
    """A JSON object is returned as a dictionary."""
    assert parse_message(b'{"a": 1}') == {"a": 1}


@pytest.mark.parametrize(
    "value",
    [
        None,                          # tombstone / no value
        b"",                           # empty
        b'{"event_id": "broken", ',    # truncated JSON
        b"not json at all",
        b"[1, 2, 3]",                  # valid JSON, but a list
        b'"just a string"',            # valid JSON, but a string
        b"42",                         # valid JSON, but a number
        b"\xff\xfe\x00",               # not UTF-8
        b'{"a": NaN}',                 # NaN is not strict JSON
        b'{"a": Infinity}',
    ],
)
def test_unusable_messages_are_rejected(value):
    """Anything that is not a JSON object raises MessageRejected (-> dead letter)."""
    with pytest.raises(MessageRejected):
        parse_message(value)


# ---------------------------------------------------------------------------
# build_record
# ---------------------------------------------------------------------------

def test_business_fields_are_kept_with_normalised_names():
    """Field values pass through unchanged; only the names are normalised."""
    record = record_for({"order_id": "ORD-1", "quantity": 3, "unit_price": 10.5})
    assert record["ORDER_ID"] == "ORD-1"
    assert record["QUANTITY"] == 3
    assert record["UNIT_PRICE"] == 10.5


def test_unknown_fields_pass_through():
    """A field the table has never seen is NOT dropped: Snowflake will add its column."""
    assert record_for({"brand_new_field": "x"})["BRAND_NEW_FIELD"] == "x"


def test_nested_values_are_kept_whole():
    """A nested object stays one value (one VARIANT column), keys untouched."""
    record = record_for({"shipping_address": {"city": "Pune", "pin code": "411001"}})
    assert record["SHIPPING_ADDRESS"] == {"city": "Pune", "pin code": "411001"}


def test_metadata_fields_are_added():
    """Topic, partition, offset and both timestamps are added to every record."""
    record = record_for({"a": 1})
    assert record["_KAFKA_TOPIC"] == "order_events"
    assert record["_KAFKA_PARTITION"] == 2
    assert record["_KAFKA_OFFSET"] == 17
    assert record["_KAFKA_TIMESTAMP"] == "2026-10-06 10:00:00.250"
    assert record["_INGESTED_AT"] == "2026-10-06 11:00:00.005"
    assert METADATA_FIELDS <= set(record)


def test_missing_kafka_timestamp_becomes_null():
    """A message without a broker timestamp gets NULL, not a wrong date."""
    assert record_for({"a": 1}, kafka_timestamp_ms=None)["_KAFKA_TIMESTAMP"] is None
    assert record_for({"a": 1}, kafka_timestamp_ms=-1)["_KAFKA_TIMESTAMP"] is None


def test_empty_object_gives_metadata_only_record():
    """An empty JSON object is valid; it yields a row holding only metadata."""
    assert set(record_for({})) == METADATA_FIELDS


def test_colliding_field_names_are_rejected():
    """Two fields that normalise to the same column are rejected, not merged."""
    with pytest.raises(MessageRejected, match="ORDER_ID"):
        record_for({"order id": 1, "order_id": 2})


def test_field_clashing_with_metadata_is_rejected():
    """A producer field may not overwrite the consumer's metadata columns."""
    with pytest.raises(MessageRejected, match="_KAFKA_OFFSET"):
        record_for({"_kafka_offset": 999})


def test_malformed_message_is_rejected_by_build_record():
    """build_record raises MessageRejected for a message that is not JSON."""
    with pytest.raises(MessageRejected):
        record_for(b'{"event_id": "broken", ')


def test_timestamp_format_is_utc_without_zone():
    """Timestamps are written as UTC wall-clock text with milliseconds."""
    moment = datetime(2026, 1, 2, 3, 4, 5, 678000, tzinfo=timezone.utc)
    assert format_timestamp(moment) == "2026-01-02 03:04:05.678"
