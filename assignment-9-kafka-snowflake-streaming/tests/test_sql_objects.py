"""
Unit tests for the object definitions in sql/01_create_objects.sql.

They read the SQL script as text; no Snowflake account is needed. They protect
three decisions that came out of the verification gate (README section 6):

    * DISCOUNT_PCT is declared with an explicit numeric type, because a
      numeric column created by schema evolution never widens;
    * only that one later field is pre-declared, so every other new field
      still goes through Snowflake schema evolution;
    * ORDER_EVENTS_LATEST names its columns instead of using SELECT *, because
      a SELECT * view breaks as soon as a column is added to the table.

The behaviour itself (the view still working after columns are added, the
values of DISCOUNT_PCT being stored exactly) is checked on the real account by
scripts/verify_gate.py --check shape.
"""

from __future__ import annotations

import re
from decimal import Decimal

from producer.event_factory import V1_FIELDS, V2_NEW_FIELDS, V3_NEW_FIELDS, build_event
from sql_text import CREATE_OBJECTS_SQL, latest_view_columns, latest_view_sql, order_events_columns

# Metadata columns the consumer adds to every row.
METADATA_COLUMNS = {"_KAFKA_TOPIC", "_KAFKA_PARTITION", "_KAFKA_OFFSET", "_KAFKA_TIMESTAMP", "_INGESTED_AT"}


# ---------------------------------------------------------------------------
# Numeric DISCOUNT_PCT
# ---------------------------------------------------------------------------

def test_discount_pct_is_declared_as_number_5_2():
    """The known numeric business field has an explicit type in CREATE TABLE."""
    assert dict(order_events_columns())["DISCOUNT_PCT"] == "NUMBER(5,2)"


def test_existing_tables_are_upgraded_with_the_same_type():
    """A table created by an older script gets the identical column through ALTER ... IF NOT EXISTS."""
    sql = CREATE_OBJECTS_SQL.read_text(encoding="utf-8")
    assert re.search(
        r"ALTER TABLE ORDER_EVENTS ADD COLUMN IF NOT EXISTS\s+DISCOUNT_PCT NUMBER\(5,2\)", sql
    ), "the upgrade statement for DISCOUNT_PCT is missing or uses a different type"


def test_every_discount_the_producer_sends_fits_number_5_2_exactly():
    """No produced discount is out of range or has more than two decimals (nothing to round)."""
    for sequence in range(500):
        value = Decimal(str(build_event(2, sequence)["discount_pct"]))
        assert Decimal("0") <= value <= Decimal("999.99")
        # Quantizing to two decimals must not change the value.
        assert value == value.quantize(Decimal("0.01"))


def test_schema_evolution_stays_enabled():
    """Explicitly typing one column must not switch schema evolution off."""
    # order_events_columns() only matches a CREATE TABLE that ends in ENABLE_SCHEMA_EVOLUTION = TRUE.
    assert order_events_columns()


def test_only_discount_pct_is_pre_declared_among_later_fields():
    """Every other v2/v3 field is absent from CREATE TABLE, so Snowflake must add it itself."""
    declared = {name for name, _ in order_events_columns()}
    later_fields = {name.upper() for name in V2_NEW_FIELDS + V3_NEW_FIELDS}
    assert declared & later_fields == {"DISCOUNT_PCT"}
    assert {"PAYMENT_METHOD", "LOYALTY_TIER", "IS_GIFT", "SHIPPING_ADDRESS"}.isdisjoint(declared)


def test_declared_columns_are_v1_fields_metadata_and_discount():
    """The declared shape is exactly: version-1 fields + consumer metadata + DISCOUNT_PCT."""
    declared = {name for name, _ in order_events_columns()}
    assert declared == {name.upper() for name in V1_FIELDS} | METADATA_COLUMNS | {"DISCOUNT_PCT"}


# ---------------------------------------------------------------------------
# ORDER_EVENTS_LATEST view
# ---------------------------------------------------------------------------

def test_view_does_not_use_select_star():
    """SELECT * is what breaks a view when the table gains a column (error 002057)."""
    assert "*" not in latest_view_sql()


def test_view_selects_only_declared_columns():
    """Every view column is declared in CREATE TABLE, so it exists whatever evolution adds later."""
    declared = [name for name, _ in order_events_columns()]
    assert latest_view_columns() == declared


def test_view_deduplicates_on_the_kafka_message_identity():
    """One row per (topic, partition, offset), keeping the earliest-ingested copy."""
    view = " ".join(latest_view_sql().split())
    assert "QUALIFY ROW_NUMBER() OVER (" in view
    assert "PARTITION BY _KAFKA_TOPIC, _KAFKA_PARTITION, _KAFKA_OFFSET" in view
    assert "ORDER BY _INGESTED_AT" in view
    assert view.endswith(") = 1;")
