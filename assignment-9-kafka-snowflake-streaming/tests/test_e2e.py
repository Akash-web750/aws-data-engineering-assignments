"""
End-to-end tests against the REAL local Kafka broker and the REAL Snowflake account.

    $env:KAFKA_SF_LIVE = "1"
    python -m pytest tests/test_e2e.py -v

Skipped unless KAFKA_SF_LIVE=1, because they need a running broker, a usable
warehouse, and they spend a little Snowflake credit.

They never touch the production topic or table. Each run creates:
    * its own Kafka topics   (order_events_e2e_<random>, ..._dlq)
    * its own target table   ORDER_EVENTS_E2E   (same declared columns as
                             ORDER_EVENTS, read from sql/01_create_objects.sql;
                             schema evolution on)
Afterwards the test table is dropped. The topics are deleted too, EXCEPT ON
WINDOWS, where they are left in place: deleting a topic crashes the local
Kafka broker there (see ``topic_deletion_is_safe``). Audit rows are written to
the normal log tables with TARGET_TABLE = 'ORDER_EVENTS_E2E' and are deleted
at the start of each run.

The tests run in file order and build on each other, like the demo script:
v1 load -> new fields -> ad-hoc field -> type conflict -> malformed message
-> consumer restart.
"""

from __future__ import annotations

import os
import sys
import threading
import time
import uuid
from typing import Any

import pytest

# Skip the whole file unless explicitly enabled. This line must come before
# the imports below are USED, but importing them is harmless.
pytestmark = pytest.mark.skipif(
    os.environ.get("KAFKA_SF_LIVE") != "1",
    reason="live test: set KAFKA_SF_LIVE=1 (needs local Kafka and Snowflake)",
)

import snowflake.connector  # noqa: E402
from confluent_kafka import Consumer  # noqa: E402
from confluent_kafka.admin import AdminClient, NewTopic  # noqa: E402

from config import settings  # noqa: E402
from consumer.consumer import StreamingConsumer, create_kafka_consumer  # noqa: E402
from consumer.dead_letter import DeadLetterPublisher  # noqa: E402
from consumer.snowflake_loader import SnowflakeLoader  # noqa: E402
from producer.event_factory import build_event  # noqa: E402
from producer.producer import (  # noqa: E402
    MALFORMED_MESSAGE,
    DeliveryStats,
    create_producer,
    run_type_conflict_demo,
    send_event,
)
from sql_text import order_events_columns, order_events_ddl  # noqa: E402

# Separate target table so the production table is never touched.
TEST_TABLE = "ORDER_EVENTS_E2E"
# Longest time to wait for rows to appear in Snowflake (includes a possible
# warehouse resume of a few seconds).
WAIT_SECONDS = 90


def topic_deletion_is_safe(platform: str = sys.platform) -> bool:
    """Return False on Windows, where deleting a Kafka topic kills the local broker.

    Observed on this machine with Kafka 4.3.1 (2026-10-06): after the test
    deleted its topics, the broker tried to rename each topic's data folder to
    "<name>-delete". Windows refused because the broker itself still had files
    in that folder open:

        java.nio.file.AccessDeniedException:
            C:\\kafka\\data\\order_events_e2e_...-1 -> ...-1.<id>-delete
        ERROR Shutdown broker because all log dirs in C:\\kafka\\data have failed

    The broker shut itself down and could not start again until the whole data
    folder was cleared with scripts/reset_kafka.ps1. Other operating systems
    allow renaming a folder that has open files, so deletion is safe there.

    Args:
        platform: Value of ``sys.platform``; a parameter so the rule can be unit tested.
    """
    return not platform.startswith("win")


class Pipeline:
    """Everything one test run needs: topics, a producer, a consumer thread, a query helper."""

    def __init__(self) -> None:
        """Create unique topic names and open the helper connections."""
        suffix = uuid.uuid4().hex[:8]
        self.topic = f"order_events_e2e_{suffix}"
        self.dlq_topic = f"{self.topic}_dlq"
        self.group_id = f"e2e-{suffix}"
        self.admin = AdminClient(
            {"bootstrap.servers": settings.KAFKA_BOOTSTRAP_SERVERS, "broker.address.family": "v4"}
        )
        self.producer = create_producer()
        self.stats = DeliveryStats()
        self.sequence = 0
        self.consumer: StreamingConsumer | None = None
        self.thread: threading.Thread | None = None
        # A separate connection for the test's own checks, so they do not
        # interfere with the consumer's connection.
        self.connection = snowflake.connector.connect(
            connection_name=settings.require_snowflake_connection_name(),
            role=settings.SNOWFLAKE_ROLE,
            warehouse=settings.SNOWFLAKE_WAREHOUSE,
            database=settings.SNOWFLAKE_DATABASE,
            schema=settings.SNOWFLAKE_SCHEMA,
            session_parameters={"QUERY_TAG": settings.SNOWFLAKE_QUERY_TAG + "_e2e"},
        )

    # ---- Snowflake helpers -------------------------------------------------

    def query(self, sql: str, params: tuple | None = None) -> list[tuple]:
        """Run one statement on the test connection and return all rows."""
        cursor = self.connection.cursor()
        try:
            cursor.execute(sql, params)
            return cursor.fetchall()
        finally:
            cursor.close()

    def scalar(self, sql: str, params: tuple | None = None) -> Any:
        """Run a query that returns a single value and return that value."""
        return self.query(sql, params)[0][0]

    def row_count(self) -> int:
        """Number of rows currently in the test table."""
        return self.scalar(f"SELECT COUNT(*) FROM {TEST_TABLE}")

    def columns(self) -> dict[str, str]:
        """Current columns of the test table: name -> data type."""
        return {row[0]: row[1] for row in self.query(f"DESCRIBE TABLE {TEST_TABLE}")}

    def wait_for_rows(self, expected: int) -> None:
        """Wait until the test table holds ``expected`` rows; fail on timeout."""
        deadline = time.monotonic() + WAIT_SECONDS
        count = -1
        while time.monotonic() < deadline:
            count = self.row_count()
            if count >= expected:
                break
            time.sleep(2)
        assert count == expected, f"expected {expected} rows in {TEST_TABLE}, found {count}"

    # ---- Kafka helpers -----------------------------------------------------

    def create_topics(self) -> None:
        """Create this run's topics and wait until the broker confirms them."""
        futures = self.admin.create_topics(
            [NewTopic(self.topic, num_partitions=3, replication_factor=1),
             NewTopic(self.dlq_topic, num_partitions=1, replication_factor=1)]
        )
        for future in futures.values():
            future.result(30)

    def delete_topics(self) -> bool:
        """Remove this run's topics again, unless that would crash the broker.

        On Windows the topics are deliberately LEFT IN PLACE (see
        ``topic_deletion_is_safe``). They are small, have unique names, and
        are never read again; scripts/reset_kafka.ps1 clears them together
        with all other local Kafka data when a clean broker is wanted.

        Returns:
            True if the topics were deleted, False if deletion was skipped.
        """
        if not topic_deletion_is_safe():
            print(
                f"\nE2E cleanup: leaving Kafka topics {self.topic} and {self.dlq_topic} in place "
                "(deleting a topic crashes the local Kafka broker on Windows)."
            )
            return False
        for future in self.admin.delete_topics([self.topic, self.dlq_topic]).values():
            future.result(30)
        return True

    def produce(self, count: int, schema_version: int = 1, extra_fields: dict | None = None) -> None:
        """Send ``count`` valid events and wait until the broker has them all."""
        for _ in range(count):
            self.sequence += 1
            send_event(
                self.producer, self.topic,
                build_event(schema_version, self.sequence, extra_fields=extra_fields), self.stats,
            )
        assert self.producer.flush(30) == 0, "producer could not deliver every message"

    def start_consumer(self) -> None:
        """Start the real consumer loop in a background thread."""
        self.consumer = StreamingConsumer(
            kafka_consumer=create_kafka_consumer(self.group_id),
            loader=SnowflakeLoader(table=TEST_TABLE),
            dead_letter=DeadLetterPublisher(topic=self.dlq_topic),
            topic=self.topic,
            max_seconds=2.0,           # short batches keep the test quick
        )
        self.thread = threading.Thread(target=self.consumer.run, name="e2e-consumer", daemon=True)
        self.thread.start()

    def stop_consumer(self) -> None:
        """Stop the consumer loop and wait for its final flush."""
        if self.consumer and self.thread:
            self.consumer.stop()
            self.thread.join(60)
            assert not self.thread.is_alive(), "consumer did not stop within 60 s"

    def consumer_is_running(self) -> bool:
        """True while the consumer thread is alive (the pipeline has not crashed)."""
        return bool(self.thread and self.thread.is_alive())


@pytest.fixture(scope="module")
def pipeline():
    """Set up topics, the test table and a running consumer; clean up afterwards."""
    pipe = Pipeline()
    # Fresh table with the columns DECLARED for ORDER_EVENTS in
    # sql/01_create_objects.sql and schema evolution ON, exactly like production.
    pipe.query(order_events_ddl(TEST_TABLE))
    # Remove audit rows left by earlier test runs so the assertions count only this run.
    pipe.query(f"DELETE FROM {settings.SNOWFLAKE_BATCH_LOG_TABLE} WHERE TARGET_TABLE = %s", (TEST_TABLE,))
    pipe.query(f"DELETE FROM {settings.SNOWFLAKE_SCHEMA_LOG_TABLE} WHERE TARGET_TABLE = %s", (TEST_TABLE,))
    pipe.create_topics()
    pipe.start_consumer()
    try:
        yield pipe
    finally:
        pipe.stop_consumer()
        pipe.delete_topics()
        pipe.query(f"DROP TABLE IF EXISTS {TEST_TABLE}")
        pipe.connection.close()


def test_1_v1_messages_are_loaded_automatically(pipeline):
    """Produced messages appear in Snowflake with no manual step; no columns are added."""
    pipeline.produce(20, schema_version=1)
    pipeline.wait_for_rows(20)
    # Only the declared columns exist: nothing was added by schema evolution yet.
    assert list(pipeline.columns()) == [name for name, _ in order_events_columns()]
    # Typed columns hold real values, including the ISO timestamp with "Z".
    assert pipeline.scalar(
        f"SELECT COUNT(*) FROM {TEST_TABLE} WHERE EVENT_TIME IS NOT NULL AND QUANTITY > 0 AND UNIT_PRICE > 0"
    ) == 20


def test_2_new_fields_create_columns_and_old_rows_stay(pipeline):
    """v2 fields become columns automatically; earlier rows remain, with NULL in them."""
    pipeline.produce(10, schema_version=2)
    pipeline.wait_for_rows(30)
    columns = pipeline.columns()
    # PAYMENT_METHOD is new to the table: Snowflake added it.
    assert "PAYMENT_METHOD" in columns
    # DISCOUNT_PCT was declared up front and keeps its explicit type.
    assert columns["DISCOUNT_PCT"] == "NUMBER(5,2)"
    # The 20 old rows are untouched and show NULL in the new columns.
    assert pipeline.scalar(
        f"SELECT COUNT(*) FROM {TEST_TABLE} WHERE PAYMENT_METHOD IS NULL AND DISCOUNT_PCT IS NULL"
    ) == 20
    # The 10 new rows carry values: they were loaded by the same COPY that added the columns.
    assert pipeline.scalar(
        f"SELECT COUNT(*) FROM {TEST_TABLE} WHERE PAYMENT_METHOD IS NOT NULL AND DISCOUNT_PCT IS NOT NULL"
    ) == 10
    # A query written against the original columns still works.
    assert pipeline.scalar(f"SELECT COUNT(DISTINCT EVENT_ID) FROM {TEST_TABLE}") == 30
    # The application audit table recorded what Snowflake added.
    logged = {
        row[0]
        for row in pipeline.query(
            f"SELECT COLUMN_NAME FROM {settings.SNOWFLAKE_SCHEMA_LOG_TABLE} WHERE TARGET_TABLE = %s", (TEST_TABLE,)
        )
    }
    assert "PAYMENT_METHOD" in logged
    # A pre-declared column is not a schema change, so it is not in the audit log.
    assert "DISCOUNT_PCT" not in logged
    # Every discount arrived exactly as produced: nothing rejected, nothing rounded.
    assert pipeline.scalar(
        f"SELECT COUNT(*) FROM {TEST_TABLE} WHERE DISCOUNT_PCT NOT IN (0, 5, 7.5, 10, 12.5, 15)"
    ) == 0


def test_3_v3_and_adhoc_fields_are_added_too(pipeline):
    """v3 fields (including a nested object) and an arbitrary extra field become columns."""
    pipeline.produce(5, schema_version=3, extra_fields={"campaign": "diwali"})
    pipeline.wait_for_rows(35)
    columns = pipeline.columns()
    assert {"LOYALTY_TIER", "IS_GIFT", "SHIPPING_ADDRESS", "CAMPAIGN"} <= set(columns)
    assert pipeline.scalar(f"SELECT COUNT(*) FROM {TEST_TABLE} WHERE CAMPAIGN = 'diwali'") == 5
    # The nested object is one column whose inner keys can be queried.
    assert pipeline.scalar(
        f"SELECT COUNT(*) FROM {TEST_TABLE} WHERE SHIPPING_ADDRESS:city::STRING IS NOT NULL"
    ) == 5


def test_4_type_conflict_row_is_rejected_and_pipeline_keeps_running(pipeline):
    """valid -> invalid type -> valid: both valid rows load, the invalid one does not."""
    run_type_conflict_demo(pipeline.producer, pipeline.topic, pipeline.stats)
    assert pipeline.producer.flush(30) == 0
    pipeline.wait_for_rows(37)                      # 35 + the two valid rows
    assert pipeline.scalar(f"SELECT COUNT(*) FROM {TEST_TABLE} WHERE ORDER_ID = 'ORD-TYPE-CONFLICT'") == 2
    # The batch log shows exactly one rejected row, with Snowflake's error text.
    errors, first_error = pipeline.query(
        f"SELECT SUM(ERRORS_SEEN), MAX(FIRST_ERROR) FROM {settings.SNOWFLAKE_BATCH_LOG_TABLE} WHERE TARGET_TABLE = %s",
        (TEST_TABLE,),
    )[0]
    assert errors == 1
    assert first_error
    # The pipeline is still alive and loads the next message.
    assert pipeline.consumer_is_running()
    pipeline.produce(1)
    pipeline.wait_for_rows(38)


def test_5_malformed_message_goes_to_dead_letter_topic(pipeline):
    """A non-JSON message lands in the dead-letter topic; the pipeline continues."""
    pipeline.producer.produce(pipeline.topic, key=b"bad", value=MALFORMED_MESSAGE)
    pipeline.produce(1)
    pipeline.wait_for_rows(39)
    assert pipeline.consumer_is_running()

    # Read the dead-letter topic with a throw-away consumer.
    reader = Consumer(
        {
            "bootstrap.servers": settings.KAFKA_BOOTSTRAP_SERVERS, "broker.address.family": "v4",
            "group.id": f"dlq-reader-{uuid.uuid4().hex[:8]}", "auto.offset.reset": "earliest",
        }
    )
    try:
        reader.subscribe([pipeline.dlq_topic])
        dead = None
        deadline = time.monotonic() + 30
        while dead is None and time.monotonic() < deadline:
            message = reader.poll(1.0)
            if message is not None and not message.error():
                dead = message
    finally:
        reader.close()
    assert dead is not None, "no message arrived in the dead-letter topic"
    assert dead.value() == MALFORMED_MESSAGE         # original bytes are preserved
    headers = dict(dead.headers())
    assert b"not valid JSON" in headers["error"]
    assert headers["source_topic"] == pipeline.topic.encode()


def test_6_restart_loses_nothing_and_view_logic_finds_no_duplicates(pipeline):
    """Messages produced while the consumer is down are loaded after it restarts."""
    pipeline.stop_consumer()
    pipeline.produce(15)                             # nobody is consuming right now
    time.sleep(3)
    assert pipeline.row_count() == 39                # proves the consumer really was down
    pipeline.start_consumer()                        # same consumer group -> resumes from the commit
    pipeline.wait_for_rows(54)
    # Every Kafka message is present exactly once.
    total, distinct = pipeline.query(
        f"SELECT COUNT(*), COUNT(DISTINCT _KAFKA_PARTITION, _KAFKA_OFFSET) FROM {TEST_TABLE}"
    )[0]
    assert total == distinct == 54
