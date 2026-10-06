"""
Live checks for change data capture (PostgreSQL -> Debezium -> Kafka -> bridge -> Snowflake).

Everything in this file is SKIPPED by default. There are three groups, each
switched on by its own environment variable, because they need different
amounts of infrastructure:

1. PREFLIGHT  -  $env:CDC_PREFLIGHT = "1"
   Read-only checks that can be run BEFORE logical replication is enabled.
   They confirm the starting point is what the CDC design assumes: PostgreSQL
   reachable, 300 backfilled rows all marked ``project3_backfill``, a
   PostgreSQL version that supports publication row filters, enough
   replication slots, the Kafka broker and the existing topics present, and
   Kafka Connect available in the Kafka installation.
   Needs: local PostgreSQL and the local Kafka broker. Changes nothing.

2. ENABLED  -  $env:CDC_LIVE = "1"
   Read-only checks for AFTER CDC has been switched on: wal_level is logical,
   the login, publication and replication slot exist and are defined as
   intended, the CDC topic exists, the connector is RUNNING, and the CDC topic
   contains no snapshot of the existing rows (the "zero-message gate").
   Needs: logical replication enabled, sql/postgres/02_cdc_setup.sql run,
   Kafka Connect started. Changes nothing.

3. END TO END  -  $env:CDC_LIVE_E2E = "1"   (in addition to CDC_LIVE)
   Inserts ONE new row into PostgreSQL and waits for it to appear in
   Snowflake ORDER_EVENTS: the 300 -> 301 proof.
   Needs: everything above plus the bridge and the existing consumer running.
   WRITES one row to PostgreSQL and, through the pipeline, one row to the
   production Snowflake table.

    python -m pytest tests/test_cdc_live.py -v
"""

from __future__ import annotations

import json
import os
import time
import urllib.request
import uuid

import pytest

from config import settings

PREFLIGHT = os.environ.get("CDC_PREFLIGHT") == "1"
LIVE = os.environ.get("CDC_LIVE") == "1"
LIVE_E2E = LIVE and os.environ.get("CDC_LIVE_E2E") == "1"

preflight = pytest.mark.skipif(not PREFLIGHT, reason="set CDC_PREFLIGHT=1 (read-only; needs local PostgreSQL and Kafka)")
enabled = pytest.mark.skipif(not LIVE, reason="set CDC_LIVE=1 only after logical replication, CDC setup and Kafka Connect are in place")
end_to_end = pytest.mark.skipif(
    not LIVE_E2E, reason="set CDC_LIVE=1 and CDC_LIVE_E2E=1; inserts one row that reaches the production Snowflake table"
)

# Number of events copied once from the Project 3 demo; they must never be published.
BACKFILL_ROWS = 300
# Longest time to wait for the inserted row to reach Snowflake, in seconds.
E2E_WAIT_SECONDS = 180


# ---------------------------------------------------------------------------
# Helpers (imported lazily so that collecting this file needs no infrastructure)
# ---------------------------------------------------------------------------

def pg(database: str | None = None, autocommit: bool = True):
    """Open a PostgreSQL connection through the project's own helper."""
    from source_db import postgres

    return postgres.connect(database, autocommit=autocommit)


def kafka_admin():
    """Create a Kafka admin client for read-only metadata calls."""
    from confluent_kafka.admin import AdminClient

    return AdminClient({"bootstrap.servers": settings.KAFKA_BOOTSTRAP_SERVERS, "broker.address.family": "v4"})


def topic_names() -> set[str]:
    """Names of all topics on the local broker."""
    return set(kafka_admin().list_topics(timeout=15).topics)


def read_all_messages(topic: str) -> list:
    """Read every message currently in ``topic`` with a throw-away consumer group.

    A new group each time, so nothing is committed for the bridge's own group
    and the bridge's position is not disturbed.
    """
    from confluent_kafka import Consumer

    reader = Consumer(
        {
            "bootstrap.servers": settings.KAFKA_BOOTSTRAP_SERVERS, "broker.address.family": "v4",
            "group.id": f"cdc-live-check-{uuid.uuid4().hex[:8]}", "auto.offset.reset": "earliest",
            "enable.auto.commit": False,
        }
    )
    messages = []
    try:
        reader.subscribe([topic])
        quiet_polls = 0
        # Stop after a few seconds without a message: the end of the topic.
        while quiet_polls < 5:
            message = reader.poll(1.0)
            if message is None:
                quiet_polls += 1
            elif not message.error():
                messages.append(message)
                quiet_polls = 0
    finally:
        reader.close()
    return messages


def connector_status() -> dict:
    """Ask Kafka Connect's REST interface for the state of the Debezium connector."""
    url = f"{settings.CONNECT_REST_URL}/connectors/{settings.CONNECT_CONNECTOR_NAME}/status"
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def snowflake_query(sql_text: str, params: tuple | None = None) -> list[tuple]:
    """Run one read-only query on Snowflake and return all rows."""
    import snowflake.connector

    connection = snowflake.connector.connect(
        connection_name=settings.require_snowflake_connection_name(),
        role=settings.SNOWFLAKE_ROLE, warehouse=settings.SNOWFLAKE_WAREHOUSE,
        database=settings.SNOWFLAKE_DATABASE, schema=settings.SNOWFLAKE_SCHEMA,
        session_parameters={"QUERY_TAG": settings.SNOWFLAKE_QUERY_TAG + "_cdc_live"},
    )
    try:
        cursor = connection.cursor()
        cursor.execute(sql_text, params)
        return cursor.fetchall()
    finally:
        connection.close()


# ===========================================================================
# 1. PREFLIGHT - can run before logical replication is enabled (read-only)
# ===========================================================================

@preflight
def test_preflight_postgresql_is_reachable():
    """The source server answers with the configured login."""
    with pg(settings.POSTGRES_MAINTENANCE_DATABASE) as connection:
        assert connection.execute("SELECT current_user").fetchone()[0] == settings.POSTGRES_USER


@preflight
def test_preflight_postgresql_supports_publication_row_filters():
    """Row filters in publications (protection layer 2) need PostgreSQL 15 or later."""
    with pg(settings.POSTGRES_MAINTENANCE_DATABASE) as connection:
        version = int(connection.execute("SHOW server_version_num").fetchone()[0])
    assert version >= 150000, f"PostgreSQL 15+ is required for publication row filters, found {version}"


@preflight
def test_preflight_replication_capacity_is_available():
    """There is room for one more replication slot and one more WAL sender."""
    with pg(settings.POSTGRES_MAINTENANCE_DATABASE) as connection:
        max_slots = int(connection.execute("SHOW max_replication_slots").fetchone()[0])
        max_senders = int(connection.execute("SHOW max_wal_senders").fetchone()[0])
        used_slots = connection.execute("SELECT COUNT(*) FROM pg_replication_slots").fetchone()[0]
    assert max_slots - used_slots >= 1
    assert max_senders >= 1


@preflight
def test_preflight_every_existing_row_is_marked_as_backfill():
    """All 300 existing rows carry the marker that the publication filter and the bridge rely on."""
    with pg() as connection:
        total, backfill = connection.execute(
            "SELECT COUNT(*), COUNT(*) FILTER (WHERE record_source = %s) FROM order_events",
            (settings.POSTGRES_BACKFILL_SOURCE,),
        ).fetchone()
    assert backfill == BACKFILL_ROWS
    assert total == backfill, "rows without the backfill marker exist before CDC is enabled"


@preflight
def test_preflight_source_table_has_a_primary_key():
    """Debezium keys change events by the primary key; the table has one."""
    with pg() as connection:
        has_key = connection.execute(
            "SELECT EXISTS (SELECT 1 FROM pg_index WHERE indrelid = 'public.order_events'::regclass AND indisprimary)"
        ).fetchone()[0]
    assert has_key


@preflight
def test_preflight_cdc_objects_do_not_exist_yet():
    """Before CDC is enabled there is no leftover publication or replication slot of this project."""
    with pg() as connection:
        publications = connection.execute(
            "SELECT COUNT(*) FROM pg_publication WHERE pubname = %s", (settings.POSTGRES_CDC_PUBLICATION,)
        ).fetchone()[0]
        slots = connection.execute(
            "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = %s", (settings.POSTGRES_CDC_SLOT,)
        ).fetchone()[0]
    assert (publications, slots) == (0, 0)


@preflight
def test_preflight_kafka_broker_and_existing_topics_are_present():
    """The broker answers and the two existing topics are there for the bridge to use."""
    names = topic_names()
    assert settings.KAFKA_TOPIC in names
    assert settings.KAFKA_DLQ_TOPIC in names


@preflight
def test_preflight_kafka_connect_ships_with_the_installed_kafka():
    """The standalone launcher the start script calls exists in the Kafka installation."""
    kafka_home = os.environ.get("KAFKA_HOME", r"C:\kafka")
    assert os.path.exists(os.path.join(kafka_home, "bin", "windows", "connect-standalone.bat"))


# ===========================================================================
# 2. ENABLED - only after logical replication, CDC setup and Kafka Connect
# ===========================================================================

@enabled
def test_enabled_wal_level_is_logical():
    """PostgreSQL writes the information logical decoding needs."""
    with pg(settings.POSTGRES_MAINTENANCE_DATABASE) as connection:
        assert connection.execute("SHOW wal_level").fetchone()[0] == "logical"


@enabled
def test_enabled_cdc_login_can_replicate_and_is_not_a_superuser():
    """The dedicated login has exactly the rights CDC needs."""
    with pg() as connection:
        row = connection.execute(
            "SELECT rolcanlogin, rolreplication, rolsuper FROM pg_roles WHERE rolname = %s",
            (settings.POSTGRES_CDC_USER,),
        ).fetchone()
    assert row == (True, True, False)


@enabled
def test_enabled_publication_publishes_inserts_only():
    """Protection layer 2a: updates, deletes and truncates never leave PostgreSQL."""
    with pg() as connection:
        row = connection.execute(
            "SELECT pubinsert, pubupdate, pubdelete, pubtruncate FROM pg_publication WHERE pubname = %s",
            (settings.POSTGRES_CDC_PUBLICATION,),
        ).fetchone()
    assert row == (True, False, False, False)


@enabled
def test_enabled_publication_filters_out_backfill_rows():
    """Protection layer 2b: the publication covers the one table with the backfill row filter."""
    with pg() as connection:
        rows = connection.execute(
            "SELECT schemaname, tablename, rowfilter FROM pg_publication_tables WHERE pubname = %s",
            (settings.POSTGRES_CDC_PUBLICATION,),
        ).fetchall()
    assert len(rows) == 1
    schema, table, row_filter = rows[0]
    assert (schema, table) == ("public", settings.POSTGRES_TABLE)
    assert "record_source" in row_filter and settings.POSTGRES_BACKFILL_SOURCE in row_filter


@enabled
def test_enabled_replication_slot_exists_for_the_project_database():
    """Debezium created its slot, with the built-in decoding plugin, in the project database."""
    with pg() as connection:
        row = connection.execute(
            "SELECT plugin, database, slot_type FROM pg_replication_slots WHERE slot_name = %s",
            (settings.POSTGRES_CDC_SLOT,),
        ).fetchone()
    assert row == ("pgoutput", settings.POSTGRES_DATABASE, "logical")


@enabled
def test_enabled_cdc_topic_exists():
    """The topic Debezium writes to is present."""
    assert settings.CDC_SOURCE_TOPIC in topic_names()


@enabled
def test_enabled_connector_is_running():
    """Kafka Connect reports the connector and its task as RUNNING."""
    status = connector_status()
    assert status["connector"]["state"] == "RUNNING"
    assert [task["state"] for task in status["tasks"]] == ["RUNNING"]


@enabled
def test_enabled_cdc_topic_contains_no_snapshot_of_existing_rows():
    """The zero-message gate (protection layer 4).

    Nothing that Debezium has written is a snapshot read, and nothing carries
    the backfill marker. Directly after the first start, before any new row is
    inserted, the topic is simply empty.
    """
    snapshot_reads, backfill_rows = 0, 0
    for message in read_all_messages(settings.CDC_SOURCE_TOPIC):
        if message.value() is None:
            continue
        event = json.loads(message.value())
        if event.get("op") == "r":
            snapshot_reads += 1
        if (event.get("after") or {}).get("record_source") == settings.POSTGRES_BACKFILL_SOURCE:
            backfill_rows += 1
    assert (snapshot_reads, backfill_rows) == (0, 0)


@enabled
def test_enabled_backfill_rows_are_still_exactly_300_in_postgresql():
    """Enabling CDC did not touch the existing rows."""
    with pg() as connection:
        backfill = connection.execute(
            "SELECT COUNT(*) FROM order_events WHERE record_source = %s", (settings.POSTGRES_BACKFILL_SOURCE,)
        ).fetchone()[0]
    assert backfill == BACKFILL_ROWS


# ===========================================================================
# 3. END TO END - inserts one row; needs the bridge and the consumer running
# ===========================================================================

@end_to_end
def test_e2e_one_insert_in_postgresql_becomes_one_new_row_in_snowflake():
    """PostgreSQL +1 -> Kafka +1 event -> Snowflake +1, and nothing else changes.

    Checked afterwards:
        * the new event id is in Snowflake exactly once, with the inserted values;
        * the Snowflake row count grew by exactly one;
        * no column was added to ORDER_EVENTS (no technical column leaked);
        * the row arrived through the existing topic (its _KAFKA_TOPIC).
    """
    from producer.event_factory import build_event
    from source_db import postgres
    from source_db.insert_order_event import insert_events

    rows_before = snowflake_query(f"SELECT COUNT(*) FROM {settings.SNOWFLAKE_TABLE}")[0][0]
    columns_before = [row[0] for row in snowflake_query(f"DESCRIBE TABLE {settings.SNOWFLAKE_TABLE}")]
    with pg() as connection:
        pg_before = postgres.summarise_table(connection)["total_rows"]

    event = build_event(3, uuid.uuid4().int % 4000)
    (event_id, record_source), = insert_events([event])
    assert record_source == "application"

    with pg() as connection:
        assert postgres.summarise_table(connection)["total_rows"] == pg_before + 1

    # Wait for the row to travel PostgreSQL -> Debezium -> Kafka -> bridge -> Kafka -> consumer -> Snowflake.
    deadline = time.monotonic() + E2E_WAIT_SECONDS
    found: list[tuple] = []
    while time.monotonic() < deadline and not found:
        found = snowflake_query(
            f"SELECT ORDER_ID, QUANTITY, UNIT_PRICE, DISCOUNT_PCT, SHIPPING_ADDRESS:city::STRING, _KAFKA_TOPIC "
            f"FROM {settings.SNOWFLAKE_TABLE} WHERE EVENT_ID = %s",
            (event_id,),
        )
        if not found:
            time.sleep(5)

    assert len(found) == 1, f"event {event_id} appears {len(found)} times in Snowflake after {E2E_WAIT_SECONDS} s"
    order_id, quantity, unit_price, discount_pct, city, kafka_topic = found[0]
    assert order_id == event["order_id"]
    assert quantity == event["quantity"]
    assert float(unit_price) == event["unit_price"]
    assert float(discount_pct) == event["discount_pct"]
    assert city == event["shipping_address"]["city"]
    assert kafka_topic == settings.KAFKA_TOPIC

    assert snowflake_query(f"SELECT COUNT(*) FROM {settings.SNOWFLAKE_TABLE}")[0][0] == rows_before + 1
    assert [row[0] for row in snowflake_query(f"DESCRIBE TABLE {settings.SNOWFLAKE_TABLE}")] == columns_before
