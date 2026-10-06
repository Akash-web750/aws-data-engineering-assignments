"""
Live verification of the PostgreSQL source database.

    $env:PG_SOURCE_LIVE = "1"
    python -m pytest tests/test_source_db_live.py -v

Skipped unless PG_SOURCE_LIVE=1, because it needs the local PostgreSQL server
and the password in ``.env``. Every test only READS; nothing is created,
changed or deleted, so it is safe to run at any time.

It verifies, against the real server:
    * the server is reachable with the configured login;
    * the project database exists;
    * the source table exists with the expected columns;
    * the one-time backfill holds exactly 300 rows;
    * there are no duplicate event ids and no duplicate Kafka messages.

One further test compares every backfilled row, field by field, with
Snowflake ORDER_EVENTS. It additionally needs PG_SOURCE_COMPARE_SNOWFLAKE=1,
because it runs one read-only query on the Snowflake warehouse.
"""

from __future__ import annotations

import os

import pytest

pytestmark = pytest.mark.skipif(
    os.environ.get("PG_SOURCE_LIVE") != "1",
    reason="live test: set PG_SOURCE_LIVE=1 (needs local PostgreSQL and POSTGRES_PASSWORD in .env)",
)

from psycopg import sql  # noqa: E402

from config import settings  # noqa: E402
from source_db import postgres  # noqa: E402
from source_db.backfill_from_snowflake import POSTGRES_COLUMNS, fetch_events_from_snowflake, to_source_row  # noqa: E402

# Number of events produced and loaded by the Project 3 production demo.
EXPECTED_BACKFILL_ROWS = 300


@pytest.fixture(scope="module")
def connection():
    """One read-only connection to the project database for all tests in this file."""
    with postgres.connect() as conn:
        # Belt and braces: the session cannot write even by mistake.
        conn.execute("SET default_transaction_read_only = on")
        yield conn


def test_postgresql_is_reachable_with_the_configured_login():
    """The server answers and accepts the user and password from the settings."""
    with postgres.connect(settings.POSTGRES_MAINTENANCE_DATABASE, autocommit=True) as conn:
        version, user = conn.execute("SELECT version(), current_user").fetchone()
    assert version.startswith("PostgreSQL")
    assert user == settings.POSTGRES_USER


def test_project_database_exists():
    """The dedicated database was created."""
    assert postgres.database_exists(settings.POSTGRES_DATABASE)


def test_connection_is_to_the_project_database(connection):
    """The tests run inside the project database, not inside an existing one."""
    assert connection.execute("SELECT current_database()").fetchone()[0] == "kafka_source_db"


def test_source_table_exists(connection):
    """The order_events table is present."""
    assert postgres.table_exists(connection)


def test_source_table_has_the_expected_columns(connection):
    """All columns the pipeline relies on exist, with suitable types."""
    columns = postgres.table_columns(connection)
    assert set(POSTGRES_COLUMNS) <= set(columns)
    assert columns["event_id"] == "uuid"
    assert columns["event_time"] == "timestamp with time zone"
    assert columns["unit_price"] == "numeric"
    assert columns["discount_pct"] == "numeric"
    assert columns["is_gift"] == "boolean"
    assert columns["shipping_address"] == "jsonb"


def test_event_id_is_the_primary_key(connection):
    """The primary key is enforced by PostgreSQL itself, not only by the loader."""
    key_columns = [
        row[0]
        for row in connection.execute(
            "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey) "
            "WHERE i.indrelid = 'public.order_events'::regclass AND i.indisprimary"
        ).fetchall()
    ]
    assert key_columns == ["event_id"]


def test_backfill_holds_exactly_300_rows(connection):
    """The 300 production-demo events were loaded, once."""
    summary = postgres.summarise_table(connection)
    assert summary["backfill_rows"] == EXPECTED_BACKFILL_ROWS
    assert summary["distinct_event_ids"] >= EXPECTED_BACKFILL_ROWS


def test_no_duplicate_event_ids(connection):
    """No business event id occurs more than once."""
    summary = postgres.summarise_table(connection)
    assert summary["duplicate_event_ids"] == 0
    assert summary["distinct_event_ids"] == summary["total_rows"]


def test_no_duplicate_kafka_messages(connection):
    """No original Kafka message (topic, partition, offset) was stored twice."""
    assert postgres.summarise_table(connection)["duplicate_kafka_keys"] == 0


def test_backfilled_rows_keep_the_schema_version_shape(connection):
    """100 v1 rows without later fields, 100 v2 rows, 100 v3 rows: the same split as in Snowflake."""
    v1, v2, v3 = connection.execute(
        "SELECT COUNT(*) FILTER (WHERE payment_method IS NULL AND discount_pct IS NULL AND loyalty_tier IS NULL), "
        "       COUNT(*) FILTER (WHERE payment_method IS NOT NULL AND loyalty_tier IS NULL), "
        "       COUNT(*) FILTER (WHERE loyalty_tier IS NOT NULL AND is_gift IS NOT NULL AND shipping_address ? 'city') "
        "FROM order_events WHERE record_source = %s",
        (settings.POSTGRES_BACKFILL_SOURCE,),
    ).fetchone()
    assert (v1, v2, v3) == (100, 100, 100)


@pytest.mark.skipif(
    os.environ.get("PG_SOURCE_COMPARE_SNOWFLAKE") != "1",
    reason="set PG_SOURCE_COMPARE_SNOWFLAKE=1 to compare with Snowflake (runs one read-only warehouse query)",
)
def test_backfilled_rows_equal_snowflake_field_by_field(connection):
    """Every backfilled row is in Snowflake and matches its Snowflake row in every column.

    Snowflake may hold MORE rows than the backfill: once CDC is running, rows
    created in PostgreSQL arrive there too. Those are not backfilled rows and
    are left out of this comparison.
    """
    in_snowflake = {}
    for event in fetch_events_from_snowflake():
        row = to_source_row(event)
        # Unwrap the JSONB marker so plain dictionaries are compared.
        row["shipping_address"] = row["shipping_address"].obj if row["shipping_address"] is not None else None
        in_snowflake[row["event_id"]] = row

    query = sql.SQL("SELECT {} FROM order_events WHERE record_source = %s").format(
        sql.SQL(", ").join(sql.Identifier(name) for name in POSTGRES_COLUMNS)
    )
    actual = {
        row[0]: dict(zip(POSTGRES_COLUMNS, row))
        for row in connection.execute(query, (settings.POSTGRES_BACKFILL_SOURCE,)).fetchall()
    }

    assert len(actual) == EXPECTED_BACKFILL_ROWS
    assert set(actual) <= set(in_snowflake), "a backfilled row is missing from Snowflake"
    # Compare only the backfilled rows; every one of them has its Snowflake row.
    expected = {event_id: in_snowflake[event_id] for event_id in actual}
    differences = [
        (str(event_id), column, expected[event_id][column], actual[event_id][column])
        for event_id in expected
        for column in POSTGRES_COLUMNS
        if expected[event_id][column] != actual[event_id][column]
    ]
    assert differences == [], f"{len(differences)} field differences, first: {differences[:3]}"
