"""
Unit tests for cdc/transform.py: Debezium change event -> existing order-event message.

The payloads used here have the shape the Debezium PostgreSQL connector writes
with the settings in cdc/debezium-postgres.properties (JSON without schemas,
decimal.handling.mode=double): a ``before``/``after``/``source``/``op``
envelope in which TIMESTAMPTZ is ISO text with microseconds, NUMERIC is a JSON
number and JSONB is JSON *text*.

The central claim under test is that a row inserted into PostgreSQL comes out
of the bridge as EXACTLY the message the existing producer would have sent, so
the existing consumer and Snowflake cannot tell the difference. That is
checked by a round trip: producer event -> PostgreSQL row -> Debezium payload
-> transform -> must equal the producer event.

No Kafka, PostgreSQL or Snowflake is needed.
"""

from __future__ import annotations

import json
import random
from datetime import datetime, timezone
from typing import Any

import pytest

from cdc.transform import (
    CdcRejected,
    Forward,
    Skip,
    build_order_event,
    format_event_time,
    transform_change_event,
)
from config import settings
from consumer.transform import build_record
from producer.event_factory import V1_FIELDS, V2_NEW_FIELDS, V3_NEW_FIELDS, build_event
from source_db.insert_order_event import event_to_row

# A fixed moment so timestamps are predictable in the assertions.
FIXED_NOW = datetime(2026, 10, 6, 12, 23, 49, 370000, tzinfo=timezone.utc)


def producer_event(version: int = 3, **extra: Any) -> dict[str, Any]:
    """An order event exactly as the existing producer builds it (seeded, so repeatable)."""
    return build_event(version, sequence=7, rng=random.Random(11), now=FIXED_NOW, extra_fields=extra or None)


def debezium_after(event: dict[str, Any], record_source: str = "application", **overrides: Any) -> dict[str, Any]:
    """The ``after`` image Debezium would send for ``event`` stored in PostgreSQL.

    The event first becomes a PostgreSQL row through the project's own insert
    utility (``event_to_row``), then each value is written the way Debezium
    serialises that column type. All 20 table columns are present, the
    technical ones included, and columns without a value are null.
    """
    row = event_to_row(event)
    after: dict[str, Any] = {
        "event_id": str(row["event_id"]),
        # TIMESTAMPTZ: ISO-8601 UTC text with microseconds.
        "event_time": row["event_time"].strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        "order_id": row["order_id"],
        "customer_id": row["customer_id"],
        "product": row["product"],
        "quantity": row["quantity"],
        # NUMERIC with decimal.handling.mode=double: a JSON number.
        "unit_price": float(row["unit_price"]),
        "status": row["status"],
        "payment_method": row["payment_method"],
        "discount_pct": None if row["discount_pct"] is None else float(row["discount_pct"]),
        "loyalty_tier": row["loyalty_tier"],
        "is_gift": row["is_gift"],
        # JSONB: JSON text, not a nested object.
        "shipping_address": None if row["shipping_address"] is None else json.dumps(row["shipping_address"].obj),
        # Technical columns of the source table.
        "record_source": record_source,
        "source_kafka_topic": None,
        "source_kafka_partition": None,
        "source_kafka_offset": None,
        "source_kafka_timestamp": None,
        "created_at": "2026-10-06T13:00:00.123456Z",
        "updated_at": "2026-10-06T13:00:00.123456Z",
    }
    after.update(overrides)
    return after


def change_event(
    op: str = "c", after: dict[str, Any] | None = None, before: dict[str, Any] | None = None, snapshot: str = "false",
) -> bytes:
    """A complete Debezium change event (envelope) as the bytes found in the CDC topic."""
    envelope = {
        "before": before,
        "after": after,
        "source": {
            "version": "3.7.0.Final", "connector": "postgresql", "name": "pgcdc",
            "ts_ms": 1791289429370, "snapshot": snapshot, "db": "kafka_source_db",
            "sequence": '[null,"24023928"]', "schema": "public", "table": "order_events",
            "txId": 756, "lsn": 24023928, "xmin": None,
        },
        "transaction": None,
        "op": op,
        "ts_ms": 1791289429512,
    }
    return json.dumps(envelope).encode("utf-8")


def forwarded(value: bytes) -> Forward:
    """Transform a change event and assert that it is forwarded."""
    outcome = transform_change_event(value)
    assert isinstance(outcome, Forward), f"expected Forward, got {outcome!r}"
    return outcome


def skipped(value: bytes | None) -> Skip:
    """Transform a change event and assert that it is skipped."""
    outcome = transform_change_event(value)
    assert isinstance(outcome, Skip), f"expected Skip, got {outcome!r}"
    return outcome


# ---------------------------------------------------------------------------
# INSERT / create event: the existing producer contract is preserved exactly
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("version", [1, 2, 3])
def test_insert_becomes_exactly_the_producer_message(version):
    """Round trip: what comes out of the bridge equals what the producer would have sent."""
    event = producer_event(version)
    outcome = forwarded(change_event("c", debezium_after(event)))
    assert outcome.event == event


@pytest.mark.parametrize("version", [1, 2, 3])
def test_serialised_message_is_byte_identical_to_the_producers(version):
    """Same fields, same order, same JSON text: the Kafka value is byte for byte the producer's."""
    event = producer_event(version)
    outcome = forwarded(change_event("c", debezium_after(event)))
    # producer/producer.py serialises with json.dumps(event).encode("utf-8").
    assert json.dumps(outcome.event).encode("utf-8") == json.dumps(event).encode("utf-8")


def test_message_key_is_the_order_id_like_the_producer():
    """The producer keys every message by order id; so does the bridge."""
    event = producer_event(3)
    assert forwarded(change_event("c", debezium_after(event))).key == event["order_id"].encode("utf-8")


@pytest.mark.parametrize("version", [1, 2, 3])
def test_existing_consumer_builds_the_same_record_from_both_sources(version):
    """The existing consumer transform gives an identical Snowflake record for a CDC message."""
    event = producer_event(version)
    bridge_value = json.dumps(forwarded(change_event("c", debezium_after(event))).event).encode("utf-8")
    producer_value = json.dumps(event).encode("utf-8")
    arguments = dict(topic="order_events", partition=0, offset=300, kafka_timestamp_ms=1791289429512, ingested_at=FIXED_NOW)
    assert build_record(bridge_value, **arguments) == build_record(producer_value, **arguments)


def test_field_names_and_order_match_the_producer_schema():
    """A v3 insert carries the 13 producer fields in the producer's order, and nothing else."""
    outcome = forwarded(change_event("c", debezium_after(producer_event(3))))
    assert tuple(outcome.event) == V1_FIELDS + V2_NEW_FIELDS + V3_NEW_FIELDS


# ---------------------------------------------------------------------------
# Snapshot / read event
# ---------------------------------------------------------------------------

def test_snapshot_read_event_is_skipped():
    """Operation "r" is a row read during a snapshot: it existed before CDC and must not be forwarded."""
    outcome = skipped(change_event("r", debezium_after(producer_event(3)), snapshot="true"))
    assert "snapshot" in outcome.reason


def test_last_snapshot_event_is_skipped_too():
    """Debezium marks the final snapshot row with snapshot="last"; it is still operation "r"."""
    assert isinstance(transform_change_event(change_event("r", debezium_after(producer_event(1)), snapshot="last")), Skip)


# ---------------------------------------------------------------------------
# UPDATE and DELETE events
# ---------------------------------------------------------------------------

def test_update_event_is_skipped():
    """Only inserts are forwarded in this phase; an update is dropped, not turned into a new row."""
    before = debezium_after(producer_event(3))
    after = dict(before, status="CANCELLED")
    assert "update" in skipped(change_event("u", after, before=before)).reason


def test_delete_event_is_skipped():
    """A delete has no meaning for the append-only Snowflake table and is dropped."""
    before = debezium_after(producer_event(3))
    assert "delete" in skipped(change_event("d", None, before=before)).reason


def test_tombstone_after_a_delete_is_skipped():
    """The empty message Debezium may send after a delete carries no row."""
    assert "tombstone" in skipped(None).reason


@pytest.mark.parametrize("op", ["t", "m"])
def test_truncate_and_message_events_are_skipped(op):
    """Truncate and logical-decoding messages are not row inserts."""
    assert isinstance(transform_change_event(change_event(op, None)), Skip)


# ---------------------------------------------------------------------------
# project3_backfill record
# ---------------------------------------------------------------------------

def test_backfill_row_is_skipped_even_as_an_insert():
    """A row marked project3_backfill is already in Snowflake and is never forwarded."""
    after = debezium_after(producer_event(3), record_source=settings.POSTGRES_BACKFILL_SOURCE)
    assert "backfill" in skipped(change_event("c", after)).reason


def test_backfill_row_in_a_snapshot_is_skipped():
    """The worst case (an accidental snapshot of the 300 rows) forwards nothing."""
    after = debezium_after(
        producer_event(3), record_source=settings.POSTGRES_BACKFILL_SOURCE,
        source_kafka_topic="order_events", source_kafka_partition=2, source_kafka_offset=17,
        source_kafka_timestamp="2026-10-06T12:23:49.371000Z",
    )
    assert isinstance(transform_change_event(change_event("r", after, snapshot="true")), Skip)


def test_application_row_is_forwarded():
    """A row created after the backfill (record_source = application) flows on."""
    assert isinstance(transform_change_event(change_event("c", debezium_after(producer_event(3)))), Forward)


# ---------------------------------------------------------------------------
# NULL optional fields
# ---------------------------------------------------------------------------

def test_null_optional_fields_are_left_out():
    """A v1 row has NULL in every later column; those fields are absent, as in a producer v1 message."""
    event = forwarded(change_event("c", debezium_after(producer_event(1)))).event
    assert tuple(event) == V1_FIELDS
    for field in V2_NEW_FIELDS + V3_NEW_FIELDS:
        assert field not in event


def test_no_null_value_ever_reaches_the_message():
    """Nothing in the outgoing message is null, whatever the row looks like."""
    after = debezium_after(producer_event(2), loyalty_tier=None, is_gift=None, shipping_address=None)
    assert None not in forwarded(change_event("c", after)).event.values()


def test_false_is_not_treated_as_missing():
    """is_gift = false is a real value and must be forwarded, not dropped like a null."""
    after = debezium_after(producer_event(3), is_gift=False)
    assert forwarded(change_event("c", after)).event["is_gift"] is False


def test_zero_discount_is_not_treated_as_missing():
    """A discount of 0 is a real value and must be forwarded."""
    after = debezium_after(producer_event(2), discount_pct=0.0)
    assert forwarded(change_event("c", after)).event["discount_pct"] == 0.0


# ---------------------------------------------------------------------------
# Decimal / numeric fields
# ---------------------------------------------------------------------------

def test_numeric_fields_are_json_numbers():
    """unit_price and discount_pct arrive as numbers (decimal.handling.mode=double) and stay numbers."""
    after = debezium_after(producer_event(2), unit_price=15999.0, discount_pct=12.5)
    event = forwarded(change_event("c", after)).event
    assert event["unit_price"] == 15999.0 and isinstance(event["unit_price"], float)
    assert event["discount_pct"] == 12.5 and isinstance(event["discount_pct"], float)


def test_whole_number_price_is_written_like_the_producer_writes_it():
    """A price sent as the integer 799 is serialised as 799.0, the producer's form."""
    after = debezium_after(producer_event(1), unit_price=799)
    event = forwarded(change_event("c", after)).event
    assert json.dumps(event["unit_price"]) == "799.0"


def test_numeric_text_is_accepted():
    """With decimal.handling.mode=string Debezium sends "12.50"; it becomes the number 12.5."""
    after = debezium_after(producer_event(2), unit_price="6499.00", discount_pct="12.50")
    event = forwarded(change_event("c", after)).event
    assert (event["unit_price"], event["discount_pct"]) == (6499.0, 12.5)


def test_two_decimal_places_survive():
    """A value with two decimals is not rounded on the way."""
    after = debezium_after(producer_event(2), discount_pct=7.25)
    assert forwarded(change_event("c", after)).event["discount_pct"] == 7.25


def test_base64_decimal_is_rejected_with_a_helpful_message():
    """Debezium's default (precise) mode sends base64 binary; that is refused, naming the setting to fix."""
    after = debezium_after(producer_event(2), unit_price="AThr")
    with pytest.raises(CdcRejected, match="decimal.handling.mode"):
        transform_change_event(change_event("c", after))


@pytest.mark.parametrize("bad", [True, {"scale": 2, "value": "AThr"}, [1]])
def test_non_numeric_price_is_rejected(bad):
    """A boolean, object or list in a numeric column cannot be converted."""
    with pytest.raises(CdcRejected, match="unit_price"):
        transform_change_event(change_event("c", debezium_after(producer_event(1), unit_price=bad)))


def test_integer_fields_stay_integers():
    """customer_id and quantity are whole numbers and stay whole numbers."""
    event = forwarded(change_event("c", debezium_after(producer_event(1), customer_id=283, quantity=4))).event
    assert (event["customer_id"], event["quantity"]) == (283, 4)
    assert isinstance(event["customer_id"], int) and isinstance(event["quantity"], int)


@pytest.mark.parametrize("bad", ["4", 4.5, True])
def test_non_integer_quantity_is_rejected(bad):
    """Text, a fraction or a boolean in an integer column is refused."""
    with pytest.raises(CdcRejected, match="quantity"):
        transform_change_event(change_event("c", debezium_after(producer_event(1), quantity=bad)))


# ---------------------------------------------------------------------------
# JSONB shipping_address
# ---------------------------------------------------------------------------

def test_jsonb_text_becomes_a_nested_object():
    """Debezium sends JSONB as text; the message carries a nested object, as the producer's does."""
    address = {"city": "Pune", "state": "Maharashtra", "pincode": "411001"}
    after = debezium_after(producer_event(3), shipping_address=json.dumps(address))
    event = forwarded(change_event("c", after)).event
    assert event["shipping_address"] == address
    assert isinstance(event["shipping_address"], dict)


def test_jsonb_that_is_already_an_object_is_passed_through():
    """If a converter already delivers an object, it is used as it is."""
    address = {"city": "Delhi", "state": "Delhi", "pincode": "110001"}
    after = debezium_after(producer_event(3), shipping_address=address)
    assert forwarded(change_event("c", after)).event["shipping_address"] == address


def test_broken_jsonb_text_is_rejected():
    """Text that is not valid JSON cannot become an address."""
    after = debezium_after(producer_event(3), shipping_address='{"city": "Pune", ')
    with pytest.raises(CdcRejected, match="shipping_address"):
        transform_change_event(change_event("c", after))


# ---------------------------------------------------------------------------
# Technical PostgreSQL columns
# ---------------------------------------------------------------------------

def test_technical_columns_never_reach_the_message():
    """record_source, source_kafka_*, created_at and updated_at are removed."""
    event = forwarded(change_event("c", debezium_after(producer_event(3)))).event
    assert settings.CDC_TECHNICAL_COLUMNS.isdisjoint(event)


def test_technical_columns_are_removed_even_when_filled():
    """They are removed by name, whether or not they hold a value."""
    after = debezium_after(
        producer_event(3), source_kafka_topic="order_events", source_kafka_partition=1, source_kafka_offset=9,
        source_kafka_timestamp="2026-10-06T12:00:00Z",
    )
    event = forwarded(change_event("c", after)).event
    assert settings.CDC_TECHNICAL_COLUMNS.isdisjoint(event)


def test_every_technical_column_of_the_table_is_on_the_list():
    """The remove-list covers every non-business column the source table declares."""
    ddl = (settings.PROJECT_ROOT / "sql" / "postgres" / "01_create_source_table.sql").read_text(encoding="utf-8")
    for column in settings.CDC_TECHNICAL_COLUMNS:
        assert f"\n    {column} " in ddl, f"{column} is on the remove-list but not in the table"
    declared = {"record_source", "source_kafka_topic", "source_kafka_partition", "source_kafka_offset",
                "source_kafka_timestamp", "created_at", "updated_at"}
    assert settings.CDC_TECHNICAL_COLUMNS == declared


def test_no_technical_column_would_become_a_snowflake_column():
    """After the consumer's own transform, the record has no column Snowflake does not already have."""
    value = json.dumps(forwarded(change_event("c", debezium_after(producer_event(3)))).event).encode("utf-8")
    record = build_record(value, topic="order_events", partition=0, offset=300, kafka_timestamp_ms=1, ingested_at=FIXED_NOW)
    snowflake_columns = {
        "EVENT_ID", "EVENT_TIME", "ORDER_ID", "CUSTOMER_ID", "PRODUCT", "QUANTITY", "UNIT_PRICE", "STATUS",
        "_KAFKA_TOPIC", "_KAFKA_PARTITION", "_KAFKA_OFFSET", "_KAFKA_TIMESTAMP", "_INGESTED_AT", "DISCOUNT_PCT",
        "PAYMENT_METHOD", "LOYALTY_TIER", "IS_GIFT", "SHIPPING_ADDRESS",
    }
    assert set(record) <= snowflake_columns


# ---------------------------------------------------------------------------
# A genuinely new business field
# ---------------------------------------------------------------------------

def test_new_business_column_is_forwarded():
    """A column added to the PostgreSQL table later flows on, so Snowflake can add it by schema evolution."""
    after = debezium_after(producer_event(3), campaign="diwali")
    event = forwarded(change_event("c", after)).event
    assert event["campaign"] == "diwali"


def test_new_business_column_keeps_its_value_and_type():
    """New fields are passed through unchanged, whatever JSON type they have."""
    after = debezium_after(producer_event(3), campaign="diwali", priority=2, express=True)
    event = forwarded(change_event("c", after)).event
    assert (event["campaign"], event["priority"], event["express"]) == ("diwali", 2, True)


def test_new_business_column_reaches_the_consumer_as_a_new_column():
    """Through the existing consumer transform the new field becomes a new upper-case column name."""
    after = debezium_after(producer_event(3), campaign="diwali")
    value = json.dumps(forwarded(change_event("c", after)).event).encode("utf-8")
    record = build_record(value, topic="order_events", partition=0, offset=300, kafka_timestamp_ms=1, ingested_at=FIXED_NOW)
    assert record["CAMPAIGN"] == "diwali"


def test_new_business_column_that_is_null_is_left_out():
    """A new column without a value adds nothing to the message (and creates no column)."""
    after = debezium_after(producer_event(3), campaign=None)
    assert "campaign" not in forwarded(change_event("c", after)).event


# ---------------------------------------------------------------------------
# event_time formats
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("debezium_text", "expected"),
    [
        ("2026-10-06T12:23:49.370000Z", "2026-10-06T12:23:49.370Z"),     # microseconds
        ("2026-10-06T12:23:49.37Z", "2026-10-06T12:23:49.370Z"),         # trailing zeros dropped by Debezium
        ("2026-10-06T12:23:49Z", "2026-10-06T12:23:49.000Z"),            # no fraction
        ("2026-10-06T12:23:49.123456789Z", "2026-10-06T12:23:49.123Z"),  # nanoseconds
        ("2026-10-06T17:53:49.370000+05:30", "2026-10-06T12:23:49.370Z"),  # other zone -> UTC
        ("2026-10-06T12:23:49.370+00:00", "2026-10-06T12:23:49.370Z"),
        ("2026-10-06T07:23:49.370-0500", "2026-10-06T12:23:49.370Z"),
        ("2026-12-31T23:30:00.000000-01:00", "2027-01-01T00:30:00.000Z"),  # crosses a year boundary
    ],
)
def test_event_time_is_converted_to_the_producer_format(debezium_text, expected):
    """Any ISO timestamp with a zone becomes UTC, milliseconds, trailing Z."""
    assert format_event_time(debezium_text) == expected


@pytest.mark.parametrize("bad", ["2026-10-06 12:23:49", "2026-10-06T12:23:49.370", "yesterday", "", 1791289429370, None])
def test_event_time_without_zone_or_not_text_is_rejected(bad):
    """A timestamp without a zone (or an epoch number) is ambiguous and is refused."""
    with pytest.raises(CdcRejected, match="event_time"):
        format_event_time(bad)


def test_impossible_date_is_rejected():
    """A well-formed text that is not a real date is refused."""
    with pytest.raises(CdcRejected, match="event_time"):
        format_event_time("2026-13-45T12:00:00Z")


# ---------------------------------------------------------------------------
# Invalid / unconvertible payloads
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "value",
    [
        b"",                                        # empty
        b"not json at all",
        b'{"before": null, "after": {',             # truncated JSON
        b"[1, 2, 3]",                               # valid JSON, not an object
        b'"text"',
        b"\xff\xfe\x00",                            # not UTF-8
    ],
)
def test_unparseable_message_is_rejected(value):
    """Anything that is not a JSON object is rejected (and goes to the dead-letter topic)."""
    with pytest.raises(CdcRejected):
        transform_change_event(value)


def test_message_that_is_not_a_change_event_is_rejected():
    """A JSON object without "op" (for example a producer-format message) is not a Debezium event."""
    with pytest.raises(CdcRejected, match="op"):
        transform_change_event(json.dumps(producer_event(3)).encode("utf-8"))


def test_unknown_operation_is_rejected():
    """An operation code this code does not know is refused rather than guessed at."""
    with pytest.raises(CdcRejected, match="operation"):
        transform_change_event(change_event("x", debezium_after(producer_event(1))))


@pytest.mark.parametrize("after", [None, "text", [1, 2]])
def test_insert_without_a_row_image_is_rejected(after):
    """An insert must carry the new row."""
    with pytest.raises(CdcRejected, match="after"):
        transform_change_event(change_event("c", after))


@pytest.mark.parametrize("missing", ["event_id", "event_time", "order_id"])
def test_insert_without_a_required_field_is_rejected(missing):
    """Without id, time or order id the message is not a usable order event."""
    after = debezium_after(producer_event(3))
    after[missing] = None
    with pytest.raises(CdcRejected, match=missing):
        transform_change_event(change_event("c", after))


def test_invalid_event_id_is_rejected():
    """The event id must be a UUID."""
    with pytest.raises(CdcRejected, match="event_id"):
        transform_change_event(change_event("c", debezium_after(producer_event(1), event_id="not-a-uuid")))


def test_event_id_is_normalised_to_lower_case():
    """Upper-case UUID text is the same id; it is written in the canonical form."""
    event = producer_event(1)
    after = debezium_after(event, event_id=event["event_id"].upper())
    assert forwarded(change_event("c", after)).event["event_id"] == event["event_id"]


def test_empty_order_id_is_rejected():
    """The order id is the Kafka key and may not be empty."""
    with pytest.raises(CdcRejected, match="order_id"):
        transform_change_event(change_event("c", debezium_after(producer_event(1), order_id="")))


def test_change_event_of_another_table_is_skipped():
    """Only the source table is expected; an event of another table is not forwarded."""
    payload = json.loads(change_event("c", debezium_after(producer_event(1))))
    payload["source"]["table"] = "customers"
    assert "another table" in skipped(json.dumps(payload).encode("utf-8")).reason


def test_schema_wrapped_event_is_understood():
    """If the converter is run with schemas.enable=true by mistake, the payload is still used."""
    payload = json.loads(change_event("c", debezium_after(producer_event(2))))
    wrapped = json.dumps({"schema": {"type": "struct"}, "payload": payload}).encode("utf-8")
    assert forwarded(wrapped).event == producer_event(2)


def test_build_order_event_does_not_change_its_input():
    """The transform does not modify the row it is given."""
    after = debezium_after(producer_event(3))
    copy = dict(after)
    build_order_event(after)
    assert after == copy
