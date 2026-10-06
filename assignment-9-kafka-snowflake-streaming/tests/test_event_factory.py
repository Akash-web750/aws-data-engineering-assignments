"""
Unit tests for producer/event_factory.py.

They check that each schema version contains exactly the fields the
specification lists, because the schema-evolution demo depends on v2 and v3
adding fields and never removing or renaming one.
"""

from __future__ import annotations

import json
import random
from datetime import datetime, timezone

import pytest

from producer.event_factory import (
    V1_FIELDS,
    V2_NEW_FIELDS,
    V3_NEW_FIELDS,
    build_event,
    fields_for_version,
)

# A fixed moment so event_time is predictable in the assertions.
FIXED_NOW = datetime(2026, 10, 6, 10, 0, 0, 123000, tzinfo=timezone.utc)


def make_event(version: int, **kwargs):
    """Build an event with a seeded generator so every run gives the same data."""
    return build_event(version, sequence=1, rng=random.Random(42), now=FIXED_NOW, **kwargs)


def test_v1_has_exactly_the_base_fields():
    """A version-1 event contains the eight base fields and nothing else."""
    assert tuple(make_event(1)) == V1_FIELDS


def test_v2_adds_only_payment_and_discount():
    """Version 2 keeps every v1 field and adds payment_method and discount_pct."""
    assert tuple(make_event(2)) == V1_FIELDS + V2_NEW_FIELDS


def test_v3_adds_loyalty_gift_and_address():
    """Version 3 keeps every v2 field and adds three more, one of them nested."""
    event = make_event(3)
    assert tuple(event) == V1_FIELDS + V2_NEW_FIELDS + V3_NEW_FIELDS
    assert set(event["shipping_address"]) == {"city", "state", "pincode"}


@pytest.mark.parametrize("version", [1, 2, 3])
def test_each_version_only_adds_fields(version):
    """No version drops a field that an earlier version had."""
    if version > 1:
        assert set(fields_for_version(version - 1)) < set(fields_for_version(version))


def test_field_types_match_the_specification():
    """Field values have the JSON types listed in spec.md section 8.1."""
    event = make_event(3)
    assert isinstance(event["event_id"], str)
    assert isinstance(event["order_id"], str)
    assert isinstance(event["customer_id"], int)
    assert isinstance(event["quantity"], int)
    assert isinstance(event["unit_price"], float)
    assert isinstance(event["discount_pct"], float)
    assert isinstance(event["is_gift"], bool)
    assert isinstance(event["shipping_address"], dict)


def test_event_time_is_iso_utc_with_z_suffix():
    """event_time is ISO-8601 in UTC, millisecond precision, ending in Z."""
    assert make_event(1)["event_time"] == "2026-10-06T10:00:00.123Z"


def test_same_seed_gives_same_event():
    """A seeded generator makes the event fully repeatable."""
    assert make_event(3) == make_event(3)


def test_extra_fields_are_added():
    """--extra-field values appear as additional top-level fields."""
    event = make_event(1, extra_fields={"campaign": "diwali"})
    assert event["campaign"] == "diwali"
    assert tuple(event)[: len(V1_FIELDS)] == V1_FIELDS


def test_extra_fields_can_override_a_standard_field():
    """An extra field may replace a standard one; the type-conflict demo relies on this."""
    assert make_event(1, extra_fields={"quantity": "not-a-number"})["quantity"] == "not-a-number"


def test_event_is_json_serialisable():
    """Every event can be written as JSON, which is how it travels through Kafka."""
    assert json.loads(json.dumps(make_event(3))) == make_event(3)


@pytest.mark.parametrize("version", [0, 4, -1])
def test_unknown_version_is_refused(version):
    """A version outside 1..3 raises a clear error instead of producing odd data."""
    with pytest.raises(ValueError):
        build_event(version, sequence=1)
