"""
Unit tests for the CDC bridge (cdc/bridge.py) and for the CDC configuration files.

Part 1 - the bridge loop. Kafka and the dead-letter publisher are replaced by
fakes that write every action into one shared list, so each test can assert
the exact ORDER of what happened. The rule under test is the bridge's delivery
guarantee: its position in the CDC topic is committed only AFTER the forwarded
messages and the dead letters are confirmed.

Part 2 - the configuration. The Debezium connector file, the Kafka Connect
worker file, the PostgreSQL setup/teardown scripts, the topic script and the
new Snowflake view are read as text and checked for the settings the four
protection layers depend on.

No Kafka, PostgreSQL or Snowflake is needed.
"""

from __future__ import annotations

import json
import re
from typing import Any

import pytest

from cdc.bridge import CdcBridge
from config import settings
from sql_text import latest_view_columns, order_events_columns
from test_cdc_transform import change_event, debezium_after, producer_event

CDC_TOPIC = "pgcdc.public.order_events"
TARGET_TOPIC = "order_events"
ROOT = settings.PROJECT_ROOT


# ===========================================================================
# Part 1: the bridge loop
# ===========================================================================

class FakeMessage:
    """Stands in for a confluent-kafka Message read from the CDC topic."""

    def __init__(self, offset: int, value: bytes | None, partition: int = 0) -> None:
        """Remember position and raw value."""
        self._offset, self._value, self._partition = offset, value, partition

    def error(self):
        """A fake message never carries a Kafka error."""
        return None

    def topic(self) -> str:
        """Topic the message 'came from'."""
        return CDC_TOPIC

    def partition(self) -> int:
        """Partition the message 'came from'."""
        return self._partition

    def offset(self) -> int:
        """Offset of the message."""
        return self._offset

    def key(self) -> bytes:
        """Debezium keys a change event by the row's primary key."""
        return b'{"event_id": "x"}'

    def value(self) -> bytes | None:
        """Raw change event."""
        return self._value


class FakeCdcConsumer:
    """Stands in for the Kafka consumer on the CDC topic."""

    def __init__(self, events: list, messages: list[FakeMessage] | None = None, on_empty=None) -> None:
        """
        Args:
            events: Shared list every fake appends its actions to.
            messages: Messages poll() hands out, in order.
            on_empty: Called when poll() finds the queue empty (used to stop the loop).
        """
        self.events = events
        self.messages = list(messages or [])
        self.on_empty = on_empty
        self.commits: list[dict[int, int]] = []
        self.seeks: list[tuple[int, int]] = []
        self.closed = False

    def subscribe(self, topics, on_revoke=None, on_lost=None) -> None:
        """Remember the subscription and the two rebalance callbacks."""
        self.on_revoke, self.on_lost = on_revoke, on_lost
        self.events.append(("subscribe", tuple(topics)))

    def poll(self, timeout):
        """Return the next queued message, or None when there is none."""
        if self.messages:
            return self.messages.pop(0)
        if self.on_empty:
            self.on_empty()
        return None

    def commit(self, offsets, asynchronous) -> None:
        """Record a commit as {partition: next offset}, or refuse it if told to."""
        assert asynchronous is False, "commits must be synchronous"
        if getattr(self, "commit_error", None) is not None:
            self.events.append(("commit_refused",))
            raise self.commit_error
        committed = {tp.partition: tp.offset for tp in offsets}
        assert all(tp.topic == CDC_TOPIC for tp in offsets), "the bridge may only commit on the CDC topic"
        self.commits.append(committed)
        self.events.append(("commit", committed))

    def seek(self, topic_partition) -> None:
        """Record a rewind to an earlier offset."""
        self.seeks.append((topic_partition.partition, topic_partition.offset))
        self.events.append(("seek", topic_partition.offset))

    def close(self) -> None:
        """Record that the client was closed."""
        self.closed = True


class FakeProducer:
    """Stands in for the Kafka producer on the existing order-events topic."""

    def __init__(self, events: list, unconfirmed: list[int] | None = None, delivery_error: str | None = None) -> None:
        """
        Args:
            events: Shared action list.
            unconfirmed: Values flush() returns, one per call, before returning 0
                (a non-zero value means "messages still unconfirmed").
            delivery_error: If given, every delivery report carries this error.
        """
        self.events = events
        self.unconfirmed = list(unconfirmed or [])
        self.delivery_error = delivery_error
        self.sent: list[dict[str, Any]] = []
        self._callbacks: list = []

    def produce(self, topic, key=None, value=None, on_delivery=None) -> None:
        """Record a message handed to Kafka."""
        self.sent.append({"topic": topic, "key": key, "value": value})
        self._callbacks.append(on_delivery)
        self.events.append(("produce", topic))

    def poll(self, timeout) -> int:
        """Nothing to serve between sends in the fake."""
        return 0

    def flush(self, timeout) -> int:
        """Deliver the callbacks, then report how many messages are still unconfirmed."""
        for callback in self._callbacks:
            callback(self.delivery_error, None)
        self._callbacks.clear()
        self.events.append(("flush",))
        return self.unconfirmed.pop(0) if self.unconfirmed else 0


class FakeDeadLetter:
    """Stands in for the existing DeadLetterPublisher."""

    def __init__(self, events: list, flush_error: Exception | None = None) -> None:
        """
        Args:
            events: Shared action list.
            flush_error: If given, flush() raises it (dead-letter topic unreachable).
        """
        self.events = events
        self.flush_error = flush_error
        self.published: list[tuple[int, str]] = []

    def publish(self, message, reason: str) -> None:
        """Record a rejected change event with its reason."""
        self.published.append((message.offset(), reason))
        self.events.append(("dlq_publish", message.offset()))

    def flush(self, timeout: float = 30.0) -> None:
        """Pretend to confirm the dead letters, or fail."""
        if self.flush_error:
            raise self.flush_error
        self.events.append(("dlq_flush",))


@pytest.fixture
def parts():
    """Build a bridge wired to fakes; returns everything a test may inspect."""

    def build(messages=None, unconfirmed=None, delivery_error=None, flush_error=None, commit_every=100):
        """Create one bridge with the given fake behaviour."""
        events: list = []
        consumer = FakeCdcConsumer(events, messages)
        producer = FakeProducer(events, unconfirmed, delivery_error)
        dead_letter = FakeDeadLetter(events, flush_error)
        slept: list[float] = []
        bridge = CdcBridge(
            cdc_consumer=consumer, target_producer=producer, dead_letter=dead_letter,
            source_topic=CDC_TOPIC, target_topic=TARGET_TOPIC, commit_every=commit_every, sleep=slept.append,
        )
        return bridge, consumer, producer, dead_letter, events, slept

    return build


def insert(offset: int, version: int = 3, **overrides) -> FakeMessage:
    """A change event for a newly inserted row."""
    return FakeMessage(offset, change_event("c", debezium_after(producer_event(version), **overrides)))


def kinds(events: list) -> list[str]:
    """Reduce the action list to action names, for order assertions."""
    return [event[0] for event in events]


def test_insert_is_forwarded_to_the_existing_topic_in_the_producer_format(parts):
    """One inserted row becomes one message in order_events, byte-identical to the producer's."""
    bridge, _, producer, _, _, _ = parts()
    bridge.handle_message(insert(0))
    bridge.checkpoint()
    event = producer_event(3)
    assert producer.sent == [
        {"topic": "order_events", "key": event["order_id"].encode("utf-8"), "value": json.dumps(event).encode("utf-8")}
    ]
    assert bridge.forwarded == 1


def test_position_is_committed_only_after_the_forward_is_confirmed(parts):
    """produce -> flush -> dead-letter flush -> commit, in that order."""
    bridge, consumer, _, _, events, _ = parts()
    bridge.handle_message(insert(5))
    assert consumer.commits == []                       # nothing is committed at forward time
    bridge.checkpoint()
    assert kinds(events) == ["produce", "flush", "dlq_flush", "commit"]
    assert consumer.commits == [{0: 6}]                 # the NEXT offset to read


def test_no_commit_when_kafka_does_not_confirm_the_forward(parts):
    """An unconfirmed forward commits nothing; the bridge goes back to re-read the event."""
    bridge, consumer, _, _, events, slept = parts(unconfirmed=[1])
    bridge.handle_message(insert(5))
    assert bridge.checkpoint() is False
    assert consumer.commits == []
    assert consumer.seeks == [(0, 5)]                   # back to the first uncommitted change event
    assert "commit" not in kinds(events)
    assert slept == [settings.RETRY_INITIAL_SECONDS]    # paused before trying again


def test_no_commit_when_kafka_refuses_a_forwarded_message(parts):
    """A delivery error reported by Kafka is treated like a missing confirmation."""
    bridge, consumer, _, _, _, _ = parts(delivery_error="Broker: Message size too large")
    bridge.handle_message(insert(5))
    assert bridge.checkpoint() is False
    assert consumer.commits == []
    assert consumer.seeks == [(0, 5)]


def test_event_is_forwarded_again_and_committed_after_a_failed_checkpoint(parts):
    """After going back, the same change event is handled again and then committed (at-least-once)."""
    bridge, consumer, producer, _, _, _ = parts(unconfirmed=[1])
    bridge.handle_message(insert(5))
    bridge.checkpoint()                                 # fails, rewinds
    bridge.handle_message(insert(5))                    # the main loop reads it again
    assert bridge.checkpoint() is True
    assert consumer.commits == [{0: 6}]
    assert len(producer.sent) == 2                      # the repeat carries the same event_id
    assert producer.sent[0]["value"] == producer.sent[1]["value"]


def test_retry_pause_grows_and_resets(parts):
    """The pause doubles after each failure in a row and returns to the start value after a success."""
    bridge, _, _, _, _, slept = parts(unconfirmed=[1, 1, 0])
    for _ in range(3):
        bridge.handle_message(insert(5))
        bridge.checkpoint()
    bridge.handle_message(insert(6))
    bridge.checkpoint()
    assert slept == [settings.RETRY_INITIAL_SECONDS, settings.RETRY_INITIAL_SECONDS * 2]
    assert bridge._retry_delay == settings.RETRY_INITIAL_SECONDS


def test_snapshot_event_is_not_forwarded_but_its_position_is_committed(parts):
    """A snapshot read produces nothing in order_events, and is not read again."""
    bridge, consumer, producer, _, events, _ = parts()
    bridge.handle_message(FakeMessage(0, change_event("r", debezium_after(producer_event(3)), snapshot="true")))
    bridge.checkpoint()
    assert producer.sent == []
    assert consumer.commits == [{0: 1}]
    assert (bridge.forwarded, bridge.skipped) == (0, 1)
    assert "produce" not in kinds(events)


def test_update_and_delete_are_not_forwarded(parts):
    """Only inserts flow on; updates and deletes are skipped and committed past."""
    bridge, consumer, producer, _, _, _ = parts()
    row = debezium_after(producer_event(3))
    bridge.handle_message(FakeMessage(0, change_event("u", dict(row, status="CANCELLED"), before=row)))
    bridge.handle_message(FakeMessage(1, change_event("d", None, before=row)))
    bridge.handle_message(FakeMessage(2, None))        # tombstone
    bridge.checkpoint()
    assert producer.sent == []
    assert consumer.commits == [{0: 3}]
    assert bridge.skipped == 3


def test_backfill_rows_are_never_forwarded(parts):
    """All 300 backfilled rows arriving (as inserts or as a snapshot) forward nothing."""
    bridge, consumer, producer, _, _, _ = parts(commit_every=1000)
    for offset in range(300):
        op, snapshot = ("r", "true") if offset % 2 else ("c", "false")
        after = debezium_after(producer_event(3), record_source=settings.POSTGRES_BACKFILL_SOURCE)
        bridge.handle_message(FakeMessage(offset, change_event(op, after, snapshot=snapshot)))
    bridge.checkpoint()
    assert producer.sent == []
    assert (bridge.forwarded, bridge.skipped) == (0, 300)
    assert consumer.commits == [{0: 300}]


def test_unusable_message_goes_to_the_existing_dead_letter_topic(parts):
    """A message that cannot be converted is parked; the bridge continues and commits past it."""
    bridge, consumer, producer, dead_letter, events, _ = parts()
    bridge.handle_message(insert(0))
    bridge.handle_message(FakeMessage(1, b'{"before": null, "after": {'))
    bridge.handle_message(insert(2))
    bridge.checkpoint()
    assert len(producer.sent) == 2
    assert [offset for offset, _ in dead_letter.published] == [1]
    assert dead_letter.published[0][1].startswith("CDC bridge: ")
    assert consumer.commits == [{0: 3}]
    assert kinds(events) == ["produce", "dlq_publish", "produce", "flush", "dlq_flush", "commit"]
    assert (bridge.forwarded, bridge.rejected) == (2, 1)


def test_unconvertible_value_goes_to_the_dead_letter_topic_with_the_reason(parts):
    """A row whose value cannot be converted is dead-lettered, and the reason names the field."""
    bridge, _, producer, dead_letter, _, _ = parts()
    bridge.handle_message(insert(0, unit_price="AThr"))
    bridge.checkpoint()
    assert producer.sent == []
    assert "unit_price" in dead_letter.published[0][1]


def test_no_commit_when_a_dead_letter_cannot_be_stored(parts):
    """If the rejected message is not safely parked, the position is not committed."""
    bridge, consumer, _, _, _, _ = parts(flush_error=RuntimeError("dlq unreachable"))
    bridge.handle_message(FakeMessage(0, b"not json"))
    assert bridge.checkpoint() is False
    assert consumer.commits == []
    assert consumer.seeks == [(0, 0)]


def test_nothing_pending_means_nothing_committed(parts):
    """A checkpoint on a quiet topic does nothing at all."""
    bridge, consumer, _, _, events, _ = parts()
    assert bridge.checkpoint() is True
    assert consumer.commits == [] and events == []


def test_technical_columns_never_leave_the_bridge(parts):
    """No message written to order_events contains a PostgreSQL bookkeeping column."""
    bridge, _, producer, _, _, _ = parts()
    for offset, version in enumerate([1, 2, 3]):
        bridge.handle_message(insert(offset, version))
    bridge.checkpoint()
    for sent in producer.sent:
        assert settings.CDC_TECHNICAL_COLUMNS.isdisjoint(json.loads(sent["value"]))


def test_run_loop_checkpoints_every_n_events_and_again_when_idle(parts):
    """The main loop commits after commit_every events, when the topic goes quiet, and on shutdown."""
    messages = [insert(offset) for offset in range(5)]
    bridge, consumer, producer, _, _, _ = parts(messages=messages, commit_every=2)
    consumer.on_empty = bridge.stop                     # stop once every message was handed out
    bridge.run()
    assert len(producer.sent) == 5
    assert consumer.commits == [{0: 2}, {0: 4}, {0: 5}]
    assert consumer.closed


def test_run_loop_subscribes_only_to_the_cdc_topic(parts):
    """The bridge reads the CDC topic and nothing else; it never reads order_events."""
    bridge, consumer, _, _, events, _ = parts()
    consumer.on_empty = bridge.stop
    bridge.run()
    assert events[0] == ("subscribe", (CDC_TOPIC,))


def test_bridge_writes_only_to_the_existing_topic(parts):
    """Every forwarded message goes to order_events; the bridge creates no other topic."""
    bridge, _, producer, _, _, _ = parts()
    for offset in range(3):
        bridge.handle_message(insert(offset))
    bridge.checkpoint()
    assert {sent["topic"] for sent in producer.sent} == {"order_events"}


def test_shutdown_with_failing_kafka_does_not_commit(parts):
    """If the final checkpoint fails, nothing is committed, so the events are re-read later."""
    bridge, consumer, _, _, _, _ = parts(messages=[insert(0)], unconfirmed=[1, 1], commit_every=100)
    consumer.on_empty = bridge.stop
    bridge.run()                                        # must not raise
    assert consumer.commits == []
    assert consumer.closed


def test_default_topics_come_from_the_settings():
    """Source and target default to the CDC topic and the existing order-events topic."""
    bridge = CdcBridge(cdc_consumer=None, target_producer=None, dead_letter=None)
    assert bridge.source_topic == settings.CDC_SOURCE_TOPIC == "pgcdc.public.order_events"
    assert bridge.target_topic == settings.CDC_TARGET_TOPIC == settings.KAFKA_TOPIC == "order_events"


# ===========================================================================
# Part 2: configuration files
# ===========================================================================

def properties(path) -> dict[str, str]:
    """Read a .properties file into a dictionary, ignoring comments and blank lines."""
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, _, value = line.partition("=")
            result[key.strip()] = value.strip()
    return result


def sql_without_comments(path) -> str:
    """Return a SQL script with full-line ``--`` comments removed."""
    return "\n".join(
        line for line in path.read_text(encoding="utf-8").splitlines() if not line.lstrip().startswith("--")
    )


CONNECTOR = properties(ROOT / "cdc" / "debezium-postgres.properties")
WORKER = properties(ROOT / "cdc" / "connect-standalone.properties")
CDC_SETUP_SQL = sql_without_comments(ROOT / "sql" / "postgres" / "02_cdc_setup.sql")
CDC_TEARDOWN_SQL = sql_without_comments(ROOT / "sql" / "postgres" / "99_cdc_teardown.sql")


# ---- Protection layer 1: no snapshot ---------------------------------------

def test_connector_takes_no_snapshot_of_existing_rows():
    """snapshot.mode=no_data: the 300 rows already in the table are not read."""
    assert CONNECTOR["snapshot.mode"] == "no_data"


# ---- Protection layer 2: the publication -----------------------------------

def test_connector_may_not_create_its_own_publication():
    """Debezium must use the hand-made, filtered publication and never replace it."""
    assert CONNECTOR["publication.autocreate.mode"] == "disabled"
    assert CONNECTOR["publication.name"] == settings.POSTGRES_CDC_PUBLICATION


def test_publication_excludes_backfill_rows_and_publishes_inserts_only():
    """The publication has the row filter and publishes nothing but inserts."""
    statement = " ".join(CDC_SETUP_SQL.split())
    assert f"CREATE PUBLICATION {settings.POSTGRES_CDC_PUBLICATION} FOR TABLE public.order_events" in statement
    assert f"WHERE (record_source <> '{settings.POSTGRES_BACKFILL_SOURCE}')" in statement
    assert "WITH (publish = 'insert')" in statement


# ---- Other connector settings the bridge relies on -------------------------

def test_connector_reads_only_the_project_table():
    """One database, one table."""
    assert CONNECTOR["database.dbname"] == settings.POSTGRES_DATABASE
    assert CONNECTOR["table.include.list"] == f"public.{settings.POSTGRES_TABLE}"


def test_connector_names_match_the_settings():
    """Topic prefix, slot and connector name are the ones the code expects."""
    assert CONNECTOR["topic.prefix"] == settings.CDC_TOPIC_PREFIX
    assert f"{CONNECTOR['topic.prefix']}.public.order_events" == settings.CDC_SOURCE_TOPIC
    assert CONNECTOR["slot.name"] == settings.POSTGRES_CDC_SLOT
    assert CONNECTOR["name"] == settings.CONNECT_CONNECTOR_NAME


def test_connector_skips_updates_and_deletes():
    """Insert-only is enforced at the connector as well as in the publication and the bridge."""
    assert set(CONNECTOR["skipped.operations"].split(",")) == {"u", "d", "t"}
    assert CONNECTOR["tombstones.on.delete"] == "false"


def test_connector_sends_numbers_not_base64():
    """NUMERIC must arrive as a JSON number, which is what the bridge and the producer contract expect."""
    assert CONNECTOR["decimal.handling.mode"] == "double"


def test_connector_uses_the_built_in_decoding_plugin():
    """pgoutput ships with PostgreSQL; nothing is installed on the database server."""
    assert CONNECTOR["plugin.name"] == "pgoutput"


def test_connector_file_contains_no_password():
    """The login is read from environment variables, so the file can be committed."""
    assert CONNECTOR["database.user"] == "${env:POSTGRES_CDC_USER}"
    assert CONNECTOR["database.password"] == "${env:POSTGRES_CDC_PASSWORD}"
    # Every setting that names a login or a password points at an environment variable.
    credentials = {key: value for key, value in CONNECTOR.items() if "password" in key or key.endswith(".user")}
    assert credentials and all(value.startswith("${env:") and value.endswith("}") for value in credentials.values())


def test_worker_resolves_only_the_cdc_environment_variables():
    """The worker can read POSTGRES_CDC_* from the environment and nothing else."""
    assert WORKER["config.providers"] == "env"
    assert WORKER["config.providers.env.class"].endswith("EnvVarConfigProvider")
    assert WORKER["config.providers.env.param.allowlist.pattern"] == "^POSTGRES_CDC_.*$"


def test_worker_writes_plain_json_without_schemas():
    """The bridge expects the bare before/after/source/op envelope."""
    for side in ("key", "value"):
        assert WORKER[f"{side}.converter"] == "org.apache.kafka.connect.json.JsonConverter"
        assert WORKER[f"{side}.converter.schemas.enable"] == "false"


def test_worker_runs_standalone_with_a_local_offsets_file():
    """Standalone mode: the position is kept in a file, so no extra compacted Kafka topics are needed."""
    assert WORKER["offset.storage.file.filename"] == "__CONNECT_DATA_DIR__/connect.offsets"
    assert WORKER["plugin.path"] == "__CONNECT_PLUGIN_DIR__"
    assert not any(key.startswith(("offset.storage.topic", "config.storage.topic", "status.storage.topic")) for key in WORKER)


def test_worker_rest_interface_is_local_only():
    """Connect's control API is not reachable from the network."""
    assert WORKER["listeners"] == "http://localhost:8083"
    assert settings.CONNECT_REST_URL == "http://localhost:8083"


def test_worker_uses_the_existing_broker():
    """Kafka Connect talks to the broker the pipeline already uses."""
    assert WORKER["bootstrap.servers"] == settings.KAFKA_BOOTSTRAP_SERVERS


# ---- PostgreSQL setup and teardown scripts ---------------------------------

def test_setup_script_changes_no_server_setting():
    """Enabling logical replication is a separate, manual step; the script never does it."""
    assert not re.search(r"\bALTER\s+SYSTEM\b", CDC_SETUP_SQL, re.IGNORECASE)
    assert "pg_reload_conf" not in CDC_SETUP_SQL


def test_setup_script_does_not_create_the_replication_slot():
    """Debezium creates the slot on first start; an unused slot would retain PostgreSQL's log."""
    assert "pg_create_logical_replication_slot" not in CDC_SETUP_SQL


def test_setup_script_stops_unless_logical_replication_is_enabled():
    """The script checks wal_level and the database before creating anything."""
    assert "current_setting('wal_level') = 'logical'" in CDC_SETUP_SQL
    assert "current_database() = 'kafka_source_db'" in CDC_SETUP_SQL
    # Both guards come before the first object is created.
    assert CDC_SETUP_SQL.index("wal_level") < CDC_SETUP_SQL.index("CREATE ROLE")
    assert CDC_SETUP_SQL.index("current_database()") < CDC_SETUP_SQL.index("CREATE ROLE")


def test_setup_script_contains_no_password():
    """The CDC login's password is passed in as a psql variable."""
    assert ":'cdc_password'" in CDC_SETUP_SQL
    assert not re.search(r"PASSWORD\s+'[^']", CDC_SETUP_SQL)


def test_cdc_login_is_least_privilege():
    """The login can replicate and read the one table; it gets no write privilege and is no superuser."""
    assert f"CREATE ROLE {settings.POSTGRES_CDC_USER} LOGIN REPLICATION" in CDC_SETUP_SQL
    assert "SUPERUSER" not in CDC_SETUP_SQL
    grants = re.findall(r"^GRANT (.+?) ON", CDC_SETUP_SQL, re.MULTILINE)
    assert sorted(grants) == ["CONNECT", "SELECT", "USAGE"]


def test_setup_script_is_safe_to_rerun_and_never_destructive():
    """Objects are created only when missing; nothing is dropped, truncated or deleted."""
    assert CDC_SETUP_SQL.count("WHERE NOT EXISTS") == 2          # role and publication
    assert not re.search(r"\b(DROP|TRUNCATE|DELETE)\b", CDC_SETUP_SQL, re.IGNORECASE)


def test_teardown_removes_slot_publication_and_login_but_keeps_the_data():
    """Rollback removes what CDC added and leaves the table and its rows alone."""
    assert "pg_drop_replication_slot" in CDC_TEARDOWN_SQL
    assert f"DROP PUBLICATION IF EXISTS {settings.POSTGRES_CDC_PUBLICATION}" in CDC_TEARDOWN_SQL
    assert f"DROP ROLE {settings.POSTGRES_CDC_USER}" in CDC_TEARDOWN_SQL
    assert not re.search(r"\bDROP\s+(TABLE|DATABASE|SCHEMA)\b", CDC_TEARDOWN_SQL, re.IGNORECASE)
    assert not re.search(r"\b(TRUNCATE|DELETE\s+FROM)\b", CDC_TEARDOWN_SQL, re.IGNORECASE)
    assert not re.search(r"\bALTER\s+SYSTEM\b", CDC_TEARDOWN_SQL, re.IGNORECASE)


def test_teardown_only_drops_a_slot_that_is_not_in_use():
    """An active slot (Kafka Connect still running) is left in place rather than failing halfway."""
    statement = " ".join(CDC_TEARDOWN_SQL.split())
    assert f"WHERE slot_name = '{settings.POSTGRES_CDC_SLOT}' AND NOT active" in statement


# ---- Kafka topics ----------------------------------------------------------

def test_topic_script_creates_cdc_topics_only_on_request():
    """Without -IncludeCdc the script behaves as before; no topic is ever deleted or altered."""
    script = (ROOT / "scripts" / "create_topics.ps1").read_text(encoding="utf-8")
    assert "[switch]$IncludeCdc" in script
    before_switch, inside_switch = script.split("if ($IncludeCdc) {")
    # The CDC topics are created only inside the switch ...
    assert "New-Topic -Name $Cdc" not in before_switch
    assert "New-Topic -Name $CdcTopic" in inside_switch
    assert "New-Topic -Name $CdcHeartbeatTopic" in inside_switch
    # ... and the two original topics are still created unconditionally, before it.
    assert "New-Topic -Name $Topic -Partitions 3" in before_switch
    assert "New-Topic -Name $DlqTopic -Partitions 1" in before_switch
    assert f"[string]$CdcTopic = '{settings.CDC_SOURCE_TOPIC}'" in script
    assert "--delete" not in script and "--alter" not in script


def test_cdc_topics_never_ask_the_broker_to_delete_data():
    """retention.ms=-1: the Windows broker is never asked to delete log files of these topics."""
    script = (ROOT / "scripts" / "create_topics.ps1").read_text(encoding="utf-8")
    assert script.count("-Config 'retention.ms=-1'") == 2
    assert CONNECTOR["topic.creation.default.retention.ms"] == "-1"


def test_helper_scripts_never_touch_the_broker_or_delete_topics():
    """The Connect scripts stop only Kafka Connect and contain no destructive Kafka command."""
    for name in ("install_debezium.ps1", "start_connect.ps1", "stop_connect.ps1"):
        script = (ROOT / "scripts" / name).read_text(encoding="utf-8")
        assert "--delete" not in script
        assert "kafka.Kafka" not in script.replace("(main class kafka.Kafka)", "")
        assert "reset_kafka" not in script and "stop_kafka" not in script
    assert "ConnectStandalone" in (ROOT / "scripts" / "stop_connect.ps1").read_text(encoding="utf-8")


# ---- Snowflake: the new EVENT_ID de-duplication view -----------------------

def unique_view_sql() -> str:
    """The CREATE VIEW statement of ORDER_EVENTS_UNIQUE, comments removed."""
    text = sql_without_comments(ROOT / "sql" / "01_create_objects.sql")
    match = re.search(r"CREATE OR REPLACE VIEW ORDER_EVENTS_UNIQUE.*?= 1;", text, re.DOTALL)
    assert match, "CREATE VIEW ORDER_EVENTS_UNIQUE not found"
    return match.group(0)


def test_unique_view_keeps_one_row_per_event_id():
    """It de-duplicates on the business key, which also catches an event that was SENT twice."""
    view = " ".join(unique_view_sql().split())
    assert "PARTITION BY COALESCE(EVENT_ID," in view
    assert "ORDER BY _INGESTED_AT" in view
    assert view.endswith(") = 1;")


def test_unique_view_does_not_collapse_rows_without_an_event_id():
    """Rows with no EVENT_ID each get their own key from their Kafka position."""
    view = " ".join(unique_view_sql().split())
    assert "_KAFKA_TOPIC || ':' || _KAFKA_PARTITION || ':' || _KAFKA_OFFSET" in view


def test_unique_view_survives_schema_evolution():
    """Like ORDER_EVENTS_LATEST it has no SELECT * and names only declared columns."""
    view = unique_view_sql()
    assert "*" not in view
    selected = re.search(r"\bAS\s+SELECT(.*?)\bFROM ORDER_EVENTS\b", view, re.DOTALL).group(1)
    columns = [name.strip() for name in selected.split(",") if name.strip()]
    assert columns == [name for name, _ in order_events_columns()]


def test_unique_view_is_additional_and_the_existing_view_is_unchanged():
    """ORDER_EVENTS_LATEST still selects the same columns and still keys on the Kafka position."""
    text = sql_without_comments(ROOT / "sql" / "01_create_objects.sql")
    assert text.count("CREATE OR REPLACE VIEW ORDER_EVENTS_LATEST") == 1
    assert text.count("CREATE OR REPLACE VIEW ORDER_EVENTS_UNIQUE") == 1
    assert latest_view_columns() == [name for name, _ in order_events_columns()]
    latest = re.search(r"CREATE OR REPLACE VIEW ORDER_EVENTS_LATEST.*?= 1;", text, re.DOTALL).group(0)
    assert "PARTITION BY _KAFKA_TOPIC, _KAFKA_PARTITION, _KAFKA_OFFSET" in " ".join(latest.split())


# ===========================================================================
# Part 3: log output cannot stall the bridge
# ===========================================================================

def test_a_blocked_console_does_not_block_the_bridge():
    """Regression test for the first live run (2026-10-06).

    The bridge forwarded an event and then hung on its own log line, because
    the Windows console it wrote to was suspended. It never committed. With
    logging routed through a queue, a log call returns at once even when the
    handler that writes the output is stuck.
    """
    import logging
    import threading
    import time

    from cdc.bridge import configure_logging

    release = threading.Event()
    written: list[str] = []

    class SuspendedConsole(logging.Handler):
        """A console that accepts no output until it is released."""

        def emit(self, record: logging.LogRecord) -> None:
            """Wait for the release, then record the line."""
            release.wait(10)
            written.append(record.getMessage())

    root = logging.getLogger()
    saved_handlers, saved_level = root.handlers, root.level
    listener = configure_logging(SuspendedConsole())
    try:
        started = time.monotonic()
        logging.getLogger("cdc.bridge").info("Forwarded order event %s", "abc")
        # The call came back immediately although nothing could be written yet.
        assert time.monotonic() - started < 1.0
        assert written == []
    finally:
        release.set()
        listener.stop()                      # writes out what was queued
        root.handlers, root.level = saved_handlers, saved_level
    assert written == ["Forwarded order event abc"]


def test_logging_setup_leaves_only_the_queue_on_the_root_logger():
    """Nothing in the main thread writes to the console directly."""
    import logging
    import logging.handlers

    from cdc.bridge import configure_logging

    root = logging.getLogger()
    saved_handlers, saved_level = root.handlers, root.level
    listener = configure_logging(logging.NullHandler())
    try:
        assert len(root.handlers) == 1
        assert isinstance(root.handlers[0], logging.handlers.QueueHandler)
    finally:
        listener.stop()
        root.handlers, root.level = saved_handlers, saved_level


def test_position_is_committed_right_after_a_forward_on_a_quiet_topic(parts):
    """One insert, then silence: the loop commits on the very next poll, not at shutdown."""
    committed_while_running: list[list] = []
    bridge, consumer, _, _, _, _ = parts(messages=[insert(0)])

    def on_empty() -> None:
        """Record the commits made so far; stop the bridge on the second quiet poll."""
        # Called on each poll that finds no message. The first such poll is the
        # one that triggers the checkpoint; by the second, the commit must exist.
        committed_while_running.append(list(consumer.commits))
        if len(committed_while_running) == 2:
            bridge.stop()

    consumer.on_empty = on_empty
    bridge.run()
    assert committed_while_running[1] == [{0: 1}]


# ===========================================================================
# Part 4: poll interval, lost partitions and rebalances
# ===========================================================================
#
# Background (observed live on 2026-10-06): a bridge whose main loop was held
# up for more than five minutes logged
#     Application maximum poll interval (300000ms) exceeded by 95ms
#     Checkpoint during rebalance failed
#     KafkaError{code=UNKNOWN_MEMBER_ID,...,str="Commit failed: Broker: Unknown member"}
# Kafka had removed it from its consumer group, and its commit was refused.

def test_consumer_allows_ten_minutes_between_polls():
    """The poll interval is raised from the Kafka default of 5 minutes to 10 minutes."""
    from cdc.bridge import cdc_consumer_config

    config = cdc_consumer_config()
    assert config["max.poll.interval.ms"] == 600000
    assert config["max.poll.interval.ms"] == settings.CDC_BRIDGE_MAX_POLL_INTERVAL_MS


def test_consumer_caps_the_records_per_poll():
    """One poll cannot hand over more than one checkpoint batch of change events."""
    from cdc.bridge import cdc_consumer_config

    config = cdc_consumer_config()
    assert config["max.poll.records"] == 100
    assert config["max.poll.records"] == settings.CDC_BRIDGE_MAX_POLL_RECORDS
    assert config["max.poll.records"] <= settings.CDC_BRIDGE_COMMIT_EVERY


def test_poll_interval_is_far_above_the_slowest_normal_loop_pass():
    """The limit must never be reached by the work of the bridge itself.

    The slowest pass through the main loop is a failed checkpoint: one flush
    of forwarded messages, one flush of dead letters, the longest retry pause,
    and the next poll. The poll interval leaves at least three times that.
    """
    from cdc.bridge import FLUSH_SECONDS, POLL_SECONDS, cdc_consumer_config

    slowest_pass_seconds = 2 * FLUSH_SECONDS + settings.RETRY_MAX_SECONDS + POLL_SECONDS
    assert cdc_consumer_config()["max.poll.interval.ms"] / 1000 >= 3 * slowest_pass_seconds


def test_fix_keeps_the_delivery_settings_unchanged():
    """Manual commits, the consumer group and the start position are as before."""
    from cdc.bridge import cdc_consumer_config

    config = cdc_consumer_config()
    assert config["enable.auto.commit"] is False            # the bridge still commits itself
    assert config["group.id"] == settings.CDC_BRIDGE_GROUP_ID == "cdc-bridge"
    assert config["auto.offset.reset"] == "earliest"
    # Nothing that would switch off group membership or rebalancing was added.
    assert not {"group.instance.id", "partition.assignment.strategy", "session.timeout.ms"} & set(config)


def test_consumer_is_created_from_exactly_that_configuration(monkeypatch):
    """create_cdc_consumer passes the tested configuration to the Kafka client unchanged."""
    import cdc.bridge as bridge_module

    captured: list[dict] = []
    monkeypatch.setattr(bridge_module, "Consumer", lambda config: captured.append(config) or "client")
    assert bridge_module.create_cdc_consumer() == "client"
    assert captured == [bridge_module.cdc_consumer_config()]


def test_scratch_group_can_be_requested_without_changing_other_settings():
    """A different group id changes only the group id."""
    from cdc.bridge import cdc_consumer_config

    default, other = cdc_consumer_config(), cdc_consumer_config(group_id="some-other-group")
    assert other["group.id"] == "some-other-group"
    assert {k: v for k, v in other.items() if k != "group.id"} == {k: v for k, v in default.items() if k != "group.id"}


def test_bridge_registers_both_rebalance_callbacks(parts):
    """The bridge handles a normal revoke and a lost partition separately."""
    bridge, consumer, _, _, _, _ = parts()
    consumer.on_empty = bridge.stop
    bridge.run()
    assert consumer.on_revoke == bridge._on_partitions_revoked
    assert consumer.on_lost == bridge._on_partitions_lost


def test_normal_revoke_still_checkpoints_before_the_partition_is_handed_over(parts):
    """An ordinary rebalance: confirm the forwards, then commit, exactly as before the fix."""
    bridge, consumer, _, _, events, _ = parts()
    bridge.handle_message(insert(7))
    bridge._on_partitions_revoked(consumer, [])
    assert kinds(events) == ["produce", "flush", "dlq_flush", "commit"]
    assert consumer.commits == [{0: 8}]


def test_lost_partition_does_not_attempt_a_commit(parts):
    """After max.poll.interval.ms is exceeded the bridge is no longer a member: no commit is tried."""
    bridge, consumer, _, _, events, _ = parts()
    bridge.handle_message(insert(7))
    bridge._on_partitions_lost(consumer, [])                # must not raise
    assert consumer.commits == []
    assert "commit" not in kinds(events) and "commit_refused" not in kinds(events)
    assert bridge._pending_count() == 0                     # the uncommitted stretch is forgotten


def test_lost_partition_loses_no_event_it_is_read_and_forwarded_again(parts):
    """At-least-once is kept: the uncommitted event is re-read, forwarded again and then committed."""
    bridge, consumer, producer, _, _, _ = parts()
    bridge.handle_message(insert(7))                        # forwarded, not yet committed
    bridge._on_partitions_lost(consumer, [])                # removed from the group
    bridge.handle_message(insert(7))                        # after rejoining, Kafka delivers it again
    assert bridge.checkpoint() is True
    assert consumer.commits == [{0: 8}]
    assert len(producer.sent) == 2
    # Both copies carry the same event_id, which is what ORDER_EVENTS_UNIQUE removes.
    first, second = (json.loads(sent["value"])["event_id"] for sent in producer.sent)
    assert first == second


def test_commit_refused_with_unknown_member_does_not_crash_the_bridge(parts):
    """The exact failure from the live log: the refused commit is survived and nothing is committed."""

    class UnknownMember(Exception):
        """Stands in for KafkaError UNKNOWN_MEMBER_ID ("Commit failed: Broker: Unknown member")."""

    bridge, consumer, _, _, events, _ = parts()
    consumer.commit_error = UnknownMember("Commit failed: Broker: Unknown member")
    bridge.handle_message(insert(7))
    bridge._on_partitions_revoked(consumer, [])             # must not raise into the Kafka client
    assert consumer.commits == []
    assert kinds(events)[-1] == "commit_refused"
    assert bridge._pending_count() == 0
    # Once the bridge is a member again, the re-read event is committed normally.
    consumer.commit_error = None
    bridge.handle_message(insert(7))
    assert bridge.checkpoint() is True
    assert consumer.commits == [{0: 8}]


def test_poll_interval_error_event_does_not_stop_the_bridge(parts):
    """Kafka reports the exceeded interval as a non-fatal error event; the loop carries on."""

    class PollIntervalExceeded:
        """Stands in for KafkaError _MAX_POLL_EXCEEDED."""

        def fatal(self) -> bool:
            """This error does not make the client unusable."""
            return False

        def __str__(self) -> str:
            """Text as the client reports it."""
            return "Application maximum poll interval (300000ms) exceeded by 95ms"

    class ErrorEvent(FakeMessage):
        """A poll result that carries an error instead of a change event."""

        def error(self):
            """Return the poll-interval error."""
            return PollIntervalExceeded()

    messages = [ErrorEvent(0, None), insert(0), insert(1)]
    bridge, consumer, producer, _, _, _ = parts(messages=messages)
    consumer.on_empty = bridge.stop
    bridge.run()                                            # must not raise
    assert len(producer.sent) == 2                          # the events after the error were forwarded
    assert consumer.commits[-1] == {0: 2}


def test_dead_letter_handling_is_unchanged_by_the_fix(parts):
    """An unusable message still goes to the dead-letter topic and is committed past."""
    bridge, consumer, producer, dead_letter, _, _ = parts()
    bridge.handle_message(FakeMessage(3, b"not a change event"))
    assert bridge.checkpoint() is True
    assert producer.sent == []
    assert [offset for offset, _ in dead_letter.published] == [3]
    assert consumer.commits == [{0: 4}]
