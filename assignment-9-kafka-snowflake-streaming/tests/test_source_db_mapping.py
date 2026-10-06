"""
Unit tests for the PostgreSQL source database code that needs no database.

They cover:
    * ``to_source_row`` - how one Snowflake ORDER_EVENTS row becomes one
      PostgreSQL row (types, UTC handling, nullable later fields, the marker
      that tells future CDC the row is already in Snowflake);
    * the PostgreSQL settings (the password has no default in the code, and
      database names are validated before they reach SQL);
    * the table definition file (primary key, uniqueness, and that every
      column the backfill writes is declared).

No PostgreSQL server and no Snowflake account are needed.
"""

from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import pytest

from config import settings
from source_db.backfill_from_snowflake import POSTGRES_COLUMNS, to_source_row

# DDL of the PostgreSQL source table.
SOURCE_TABLE_SQL = settings.PROJECT_ROOT / "sql" / "postgres" / "01_create_source_table.sql"


def snowflake_row(**overrides):
    """A version-1 ORDER_EVENTS row the way the Snowflake driver returns it."""
    row = {
        "EVENT_ID": "3c0505b1-a75a-492f-9c0e-703388da93c1",
        "EVENT_TIME": datetime(2026, 10, 6, 12, 23, 49, 370000),        # TIMESTAMP_NTZ: no zone
        "ORDER_ID": "ORD-100001",
        "CUSTOMER_ID": 283,
        "PRODUCT": "Wireless Mouse",
        "QUANTITY": 1,
        "UNIT_PRICE": Decimal("799.00"),
        "STATUS": "DELIVERED",
        "DISCOUNT_PCT": None,
        "_KAFKA_TOPIC": "order_events",
        "_KAFKA_PARTITION": 2,
        "_KAFKA_OFFSET": 0,
        "_KAFKA_TIMESTAMP": datetime(2026, 10, 6, 12, 23, 49, 371000),
    }
    row.update(overrides)
    return row


# ---------------------------------------------------------------------------
# to_source_row
# ---------------------------------------------------------------------------

def test_row_has_exactly_the_columns_the_insert_uses():
    """The mapping produces every INSERT column and nothing else."""
    assert tuple(to_source_row(snowflake_row())) == POSTGRES_COLUMNS


def test_business_fields_are_preserved():
    """Original event and order information is carried over unchanged."""
    row = to_source_row(snowflake_row())
    assert row["event_id"] == uuid.UUID("3c0505b1-a75a-492f-9c0e-703388da93c1")
    assert row["order_id"] == "ORD-100001"
    assert row["customer_id"] == 283
    assert row["product"] == "Wireless Mouse"
    assert row["quantity"] == 1
    assert row["unit_price"] == Decimal("799.00")           # Decimal, not float: no rounding
    assert row["status"] == "DELIVERED"


def test_snowflake_timestamps_are_marked_as_utc():
    """NTZ values are UTC by convention; without the zone PostgreSQL would shift them."""
    row = to_source_row(snowflake_row())
    assert row["event_time"] == datetime(2026, 10, 6, 12, 23, 49, 370000, tzinfo=timezone.utc)
    assert row["source_kafka_timestamp"].tzinfo == timezone.utc


def test_kafka_origin_is_kept_as_provenance():
    """Topic, partition and offset of the original message travel with the row."""
    row = to_source_row(snowflake_row())
    assert (row["source_kafka_topic"], row["source_kafka_partition"], row["source_kafka_offset"]) == ("order_events", 2, 0)


def test_backfilled_rows_are_marked_for_future_cdc():
    """record_source tells CDC these rows are already in Snowflake."""
    assert to_source_row(snowflake_row())["record_source"] == settings.POSTGRES_BACKFILL_SOURCE == "project3_backfill"


def test_version_1_row_has_null_later_fields():
    """A v1 event has no v2/v3 fields; they stay NULL, also when the Snowflake columns do not exist."""
    row = to_source_row(snowflake_row())                     # evolved keys are absent from the dict
    for column in ("payment_method", "discount_pct", "loyalty_tier", "is_gift", "shipping_address"):
        assert row[column] is None


def test_version_3_row_keeps_all_later_fields():
    """v2 and v3 fields are carried over, the nested address as JSONB."""
    row = to_source_row(
        snowflake_row(
            PAYMENT_METHOD="UPI", DISCOUNT_PCT=Decimal("12.50"), LOYALTY_TIER="GOLD", IS_GIFT=False,
            # The Snowflake driver returns a VARIANT as JSON text.
            SHIPPING_ADDRESS='{"city": "Pune", "state": "Maharashtra", "pincode": "411001"}',
        )
    )
    assert row["payment_method"] == "UPI"
    assert row["discount_pct"] == Decimal("12.50")
    assert row["loyalty_tier"] == "GOLD"
    assert row["is_gift"] is False                           # False must not turn into NULL
    assert row["shipping_address"].obj == {"city": "Pune", "state": "Maharashtra", "pincode": "411001"}


def test_row_without_event_id_is_refused():
    """The event id is the primary key; a row without one must not be loaded."""
    with pytest.raises(ValueError):
        to_source_row(snowflake_row(EVENT_ID=None))


def test_malformed_event_id_is_refused():
    """A value that is not a UUID is rejected before it reaches PostgreSQL."""
    with pytest.raises(ValueError):
        to_source_row(snowflake_row(EVENT_ID="not-a-uuid"))


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

def test_password_has_no_default_in_the_source_code():
    """The settings file must not contain a PostgreSQL password literal."""
    source = (settings.PROJECT_ROOT / "config" / "settings.py").read_text(encoding="utf-8")
    assert '_get("POSTGRES_PASSWORD", "")' in source


def test_missing_password_gives_a_clear_error(monkeypatch):
    """Without a password the code explains where to set it instead of failing at login."""
    monkeypatch.setattr(settings, "POSTGRES_PASSWORD", "")
    with pytest.raises(RuntimeError, match=r"\.env"):
        settings.require_postgres_password()


def test_env_example_documents_the_keys_without_a_password():
    """.env.example lists every PostgreSQL key and leaves the password empty."""
    example = (settings.PROJECT_ROOT / ".env.example").read_text(encoding="utf-8")
    for key in ("POSTGRES_HOST", "POSTGRES_PORT", "POSTGRES_USER", "POSTGRES_DATABASE"):
        assert f"{key}=" in example
    assert re.search(r"^POSTGRES_PASSWORD=\s*$", example, re.MULTILINE)


@pytest.mark.parametrize("name", ["kafka_source_db", "db1", "_private"])
def test_safe_database_names_are_accepted(name):
    """Plain lower-case identifiers pass validation."""
    assert settings.validate_pg_identifier(name) == name


@pytest.mark.parametrize("name", ["Kafka_Source", "db-name", "db name", "1db", "db;DROP DATABASE x", '"quoted"', ""])
def test_unsafe_database_names_are_refused(name):
    """Anything that is not a plain lower-case identifier never reaches CREATE DATABASE."""
    with pytest.raises(ValueError):
        settings.validate_pg_identifier(name)


def test_default_database_is_the_project_database():
    """The project uses its own database, not an existing one."""
    assert settings.POSTGRES_DATABASE == "kafka_source_db"
    assert settings.POSTGRES_DATABASE != settings.POSTGRES_MAINTENANCE_DATABASE


# ---------------------------------------------------------------------------
# Table definition
# ---------------------------------------------------------------------------

def table_ddl() -> str:
    """The CREATE TABLE statement, with full-line comments removed."""
    lines = SOURCE_TABLE_SQL.read_text(encoding="utf-8").splitlines()
    sql_text = "\n".join(line for line in lines if not line.lstrip().startswith("--"))
    match = re.search(r"CREATE TABLE IF NOT EXISTS order_events \((.*?)\n\);", sql_text, re.DOTALL)
    assert match, "CREATE TABLE order_events not found"
    return match.group(1)


def test_event_id_is_the_primary_key():
    """The business event id is the primary key, which is what prevents duplicate events."""
    assert re.search(r"event_id\s+UUID\s+PRIMARY KEY", table_ddl())


def test_kafka_origin_is_unique():
    """The same Kafka message can never be stored twice."""
    assert "UNIQUE (source_kafka_topic, source_kafka_partition, source_kafka_offset)" in table_ddl()


def test_every_backfill_column_is_declared_in_the_table():
    """The INSERT can only name columns the table really has."""
    declared = set(re.findall(r"^\s+([a-z_]+)\s+[A-Z]", table_ddl(), re.MULTILINE))
    assert set(POSTGRES_COLUMNS) <= declared


def test_numeric_types_match_snowflake():
    """Money and discount use the same precision as in Snowflake, so no value changes on the way."""
    ddl = table_ddl()
    assert re.search(r"unit_price\s+NUMERIC\(12,2\)", ddl)
    assert re.search(r"discount_pct\s+NUMERIC\(5,2\)", ddl)


def test_table_script_is_safe_to_rerun():
    """Every CREATE uses IF NOT EXISTS; the script never drops or truncates."""
    sql_text = "\n".join(
        line for line in SOURCE_TABLE_SQL.read_text(encoding="utf-8").splitlines() if not line.lstrip().startswith("--")
    )
    assert re.findall(r"^CREATE (?:TABLE|INDEX)(?! IF NOT EXISTS)", sql_text, re.MULTILINE) == []
    assert not re.search(r"\b(DROP|TRUNCATE|DELETE)\b", sql_text)


# ---------------------------------------------------------------------------
# The backfill runs only once
# ---------------------------------------------------------------------------

class _FakeConnection:
    """Stands in for a PostgreSQL connection used as a context manager."""

    def __enter__(self):
        """Enter the ``with`` block."""
        return self

    def __exit__(self, *exc_info) -> bool:
        """Leave the ``with`` block without swallowing exceptions."""
        return False


@pytest.mark.parametrize(
    "summary",
    [
        # The state right after the backfill.
        {"total_rows": 300, "backfill_rows": 300},
        # The state once CDC is live: PostgreSQL also holds rows created there,
        # and Snowflake holds more rows than the backfill.
        {"total_rows": 301, "backfill_rows": 300},
        # Rows exist that did not come from the backfill at all.
        {"total_rows": 5, "backfill_rows": 0},
    ],
)
def test_backfill_does_nothing_once_the_source_table_holds_rows(monkeypatch, summary):
    """A second run must neither read Snowflake nor write PostgreSQL, whatever the table holds."""
    from source_db import backfill_from_snowflake as backfill

    def must_not_be_called(*args, **kwargs):
        """Fail the test if the backfill reads or writes anything."""
        raise AssertionError("the backfill tried to read Snowflake or write PostgreSQL again")

    monkeypatch.setattr(backfill.postgres, "connect", lambda *args, **kwargs: _FakeConnection())
    monkeypatch.setattr(backfill.postgres, "table_exists", lambda connection: True)
    monkeypatch.setattr(backfill.postgres, "summarise_table", lambda connection: summary)
    monkeypatch.setattr(backfill, "fetch_events_from_snowflake", must_not_be_called)
    monkeypatch.setattr(backfill, "load_rows", must_not_be_called)
    backfill.main()                          # returns quietly
