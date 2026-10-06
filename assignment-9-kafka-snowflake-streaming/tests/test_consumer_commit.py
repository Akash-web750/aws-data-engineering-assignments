"""
Unit tests for the consumer's delivery guarantee (consumer/consumer.py).

The rule under test: Kafka offsets are committed ONLY AFTER Snowflake has
confirmed the load. Kafka, Snowflake and the dead-letter publisher are
replaced by small fakes that write every action into one shared list, so each
test can assert the exact order in which things happened.

No broker and no Snowflake account are needed.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import snowflake.connector

from consumer.consumer import StreamingConsumer
from consumer.snowflake_loader import LoadResult

TOPIC = "order_events"


class FakeMessage:
    """Stands in for a confluent-kafka Message."""

    def __init__(self, partition: int, offset: int, value: bytes) -> None:
        """Store the coordinates and raw value of the pretend message."""
        self._partition, self._offset, self._value = partition, offset, value

    def error(self):
        """A fake message never carries a Kafka error."""
        return None

    def topic(self) -> str:
        """Topic the message 'came from'."""
        return TOPIC

    def partition(self) -> int:
        """Partition the message 'came from'."""
        return self._partition

    def offset(self) -> int:
        """Offset of the message."""
        return self._offset

    def key(self) -> bytes:
        """Message key (not relevant to these tests)."""
        return b"k"

    def value(self) -> bytes:
        """Raw message value."""
        return self._value

    def timestamp(self) -> tuple[int, int]:
        """(timestamp type, milliseconds), like the real client."""
        return (1, 1_791_000_000_000)


def good(partition: int, offset: int, **fields) -> FakeMessage:
    """A valid JSON message."""
    return FakeMessage(partition, offset, json.dumps({"event_id": f"e{offset}", **fields}).encode())


def bad(partition: int, offset: int) -> FakeMessage:
    """A message that is not valid JSON."""
    return FakeMessage(partition, offset, b'{"broken": ')


class FakeKafka:
    """Stands in for the Kafka consumer client and records what is asked of it."""

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
        self.closed = False

    def subscribe(self, topics, on_revoke=None) -> None:
        """Remember the subscription."""
        self.events.append(("subscribe", tuple(topics)))

    def poll(self, timeout):
        """Return the next queued message, or None when there is none."""
        if self.messages:
            return self.messages.pop(0)
        if self.on_empty:
            self.on_empty()
        return None

    def commit(self, offsets, asynchronous) -> None:
        """Record a commit as {partition: next offset}."""
        assert asynchronous is False, "commits must be synchronous"
        committed = {tp.partition: tp.offset for tp in offsets}
        self.commits.append(committed)
        self.events.append(("commit", committed))

    def assignment(self) -> list:
        """Pretend one partition is assigned."""
        return ["partition-0"]

    def pause(self, partitions) -> None:
        """Record that consumption was paused."""
        self.events.append(("pause",))

    def resume(self, partitions) -> None:
        """Record that consumption was resumed."""
        self.events.append(("resume",))

    def close(self) -> None:
        """Record that the client was closed."""
        self.closed = True


class FakeLoader:
    """Stands in for SnowflakeLoader. Can be told to fail a number of times first."""

    def __init__(self, events: list, failures: list[Exception] | None = None, errors_seen: int = 0) -> None:
        """
        Args:
            events: Shared action list.
            failures: Exceptions to raise, one per call, before succeeding.
            errors_seen: Rows the pretend Snowflake rejects in each batch.
        """
        self.events = events
        self.failures = list(failures or [])
        self.errors_seen = errors_seen
        self.calls: list[dict] = []
        self.closed = False

    def known_columns(self) -> dict[str, str]:
        """Pretend the table has no columns yet; the test messages have only a few fields."""
        return {}

    def load_batch(self, file_path: Path, info, is_retry: bool = False) -> LoadResult:
        """Record the call; fail if a failure is queued, otherwise 'load' the file."""
        rows = [json.loads(line) for line in file_path.read_text(encoding="utf-8").splitlines()]
        self.calls.append({"file": file_path.name, "rows": rows, "is_retry": is_retry, "info": info})
        if self.failures:
            self.events.append(("load_failed",))
            raise self.failures.pop(0)
        self.events.append(("load", len(rows)))
        return LoadResult(
            batch_id="b", file_name=file_path.name, status="LOADED",
            rows_parsed=len(rows), rows_loaded=len(rows) - self.errors_seen, errors_seen=self.errors_seen,
        )

    def close(self) -> None:
        """Record that the loader was closed."""
        self.closed = True


class FakeDeadLetter:
    """Stands in for DeadLetterPublisher."""

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
        """Record a rejected message."""
        self.published.append((message.offset(), reason))
        self.events.append(("dlq_publish", message.offset()))

    def flush(self, timeout: float = 30.0) -> None:
        """Pretend to confirm the dead-letter messages, or fail."""
        if self.flush_error:
            raise self.flush_error
        self.events.append(("dlq_flush",))


class FakeClock:
    """A clock the test moves by hand; sleeping simply advances it."""

    def __init__(self) -> None:
        """Start at time zero."""
        self.now = 0.0

    def __call__(self) -> float:
        """Return the current pretend time."""
        return self.now

    def sleep(self, seconds: float) -> None:
        """Advance the pretend time instead of waiting."""
        self.now += max(seconds, 0.01)


@pytest.fixture
def parts(tmp_path):
    """Build a consumer wired to fakes; returns everything a test may inspect."""

    def build(messages=None, failures=None, flush_error=None, errors_seen=0, max_records=100):
        events: list = []
        clock = FakeClock()
        kafka = FakeKafka(events, messages)
        loader = FakeLoader(events, failures, errors_seen)
        dead_letter = FakeDeadLetter(events, flush_error)
        consumer = StreamingConsumer(
            kafka_consumer=kafka, loader=loader, dead_letter=dead_letter, topic=TOPIC,
            batch_dir=tmp_path, max_records=max_records, max_seconds=5.0,
            clock=clock, sleep=clock.sleep,
        )
        return consumer, kafka, loader, dead_letter, events

    return build


def kinds(events: list) -> list[str]:
    """Reduce the action list to action names, for order assertions."""
    return [event[0] for event in events]


def test_offsets_are_committed_only_after_the_load(parts):
    """The commit comes after the load, never before."""
    consumer, kafka, loader, _, events = parts()
    consumer._handle_message(good(0, 10))
    consumer._handle_message(good(0, 11))
    consumer.flush()
    assert kinds(events) == ["load", "dlq_flush", "commit"]
    assert kafka.commits == [{0: 12}]
    assert len(loader.calls[0]["rows"]) == 2


def test_no_commit_when_the_load_fails(parts):
    """A single failed attempt commits nothing and keeps the batch."""
    consumer, kafka, _, _, events = parts(failures=[RuntimeError("boom")])
    consumer._handle_message(good(0, 10))
    with pytest.raises(RuntimeError):
        consumer._flush_once(copy_may_have_run=False)
    assert kafka.commits == []
    assert "commit" not in kinds(events)
    assert len(consumer.buffer.records) == 1          # nothing was dropped


def test_failed_load_is_retried_then_committed_once(parts):
    """After Snowflake errors the batch is retried; the commit happens once, at the end."""
    error = snowflake.connector.errors.OperationalError("network down")
    consumer, kafka, loader, _, events = parts(failures=[error, error])
    consumer._handle_message(good(0, 10))
    consumer.flush()
    assert kinds(events) == ["load_failed", "pause", "load_failed", "load", "dlq_flush", "commit", "resume"]
    assert kafka.commits == [{0: 11}]
    assert consumer.buffer.is_empty
    assert consumer.batches_loaded == 1
    assert loader.calls[0]["rows"] == loader.calls[2]["rows"]   # same data every attempt


def test_retry_reuses_the_same_file_name_and_flags_the_retry(parts):
    """Same file name on every attempt, so Snowflake can recognise an already loaded file."""
    error = snowflake.connector.errors.OperationalError("timeout after COPY was sent")
    consumer, _, loader, _, _ = parts(failures=[error])
    consumer._handle_message(good(0, 10))
    consumer.flush()
    first, second = loader.calls
    assert first["file"] == second["file"]
    assert first["is_retry"] is False
    assert second["is_retry"] is True      # a Snowflake error means COPY may have run


def test_non_snowflake_failure_is_not_flagged_as_possible_duplicate(parts):
    """A failure before Snowflake was involved must not let 'already loaded' pass as success."""
    consumer, _, loader, _, _ = parts(failures=[OSError("disk full")])
    consumer._handle_message(good(0, 10))
    consumer.flush()
    assert [call["is_retry"] for call in loader.calls] == [False, False]


def test_next_batch_gets_a_new_file_name(parts):
    """File names are per batch: the retry name is not carried into the next batch."""
    consumer, _, loader, _, _ = parts()
    consumer._handle_message(good(0, 10))
    consumer.flush()
    consumer._handle_message(good(0, 11))
    consumer.flush()
    assert loader.calls[0]["file"] != loader.calls[1]["file"]


def test_malformed_message_goes_to_dead_letter_and_pipeline_continues(parts):
    """valid, malformed, valid -> two rows loaded, one dead letter, all three offsets committed."""
    consumer, kafka, loader, dead_letter, events = parts()
    for message in (good(0, 10), bad(0, 11), good(0, 12)):
        consumer._handle_message(message)
    consumer.flush()
    assert [row["EVENT_ID"] for row in loader.calls[0]["rows"]] == ["e10", "e12"]
    assert [offset for offset, _ in dead_letter.published] == [11]
    assert kafka.commits == [{0: 13}]
    assert kinds(events) == ["dlq_publish", "load", "dlq_flush", "commit"]


def test_batch_of_only_malformed_messages_commits_without_loading(parts):
    """Nothing to load, but the offsets must still advance past the bad messages."""
    consumer, kafka, loader, _, events = parts()
    consumer._handle_message(bad(0, 5))
    consumer.flush()
    assert loader.calls == []
    assert kafka.commits == [{0: 6}]
    assert kinds(events) == ["dlq_publish", "dlq_flush", "commit"]


def test_no_commit_when_dead_letter_cannot_be_confirmed(parts):
    """If a rejected message is not safely in the DLQ, its offset is not committed."""
    consumer, kafka, _, _, _ = parts(flush_error=RuntimeError("dlq unreachable"))
    consumer._handle_message(bad(0, 5))
    with pytest.raises(RuntimeError):
        consumer._flush_once(copy_may_have_run=False)
    assert kafka.commits == []


def test_rows_rejected_by_snowflake_do_not_block_the_commit(parts):
    """A type-conflict row is counted, the batch still commits, the pipeline moves on."""
    consumer, kafka, _, _, _ = parts(errors_seen=1)
    for message in (good(0, 1, quantity=1), good(0, 2, quantity="not-a-number"), good(0, 3, quantity=2)):
        consumer._handle_message(message)
    consumer.flush()
    assert kafka.commits == [{0: 4}]
    assert consumer.rows_loaded == 2
    assert consumer.rows_rejected == 1
    # The pipeline keeps running: a later message loads and commits normally.
    consumer._handle_message(good(0, 4, quantity=3))
    consumer.flush()
    assert kafka.commits[-1] == {0: 5}


def test_unknown_fields_reach_the_loader_untouched(parts):
    """The consumer does not filter new fields; it reports them to the loader as column names."""
    consumer, _, loader, _, _ = parts()
    consumer._handle_message(good(1, 7, discount_pct=12.5))
    consumer.flush()
    call = loader.calls[0]
    assert call["rows"][0]["DISCOUNT_PCT"] == 12.5
    assert "DISCOUNT_PCT" in call["info"].column_names
    assert call["info"].first_seen["DISCOUNT_PCT"] == (1, 7)


def test_batch_file_is_deleted_after_success(parts, tmp_path):
    """No batch files are left behind once the data is loaded and committed."""
    consumer, _, _, _, _ = parts()
    consumer._handle_message(good(0, 10))
    consumer.flush()
    assert list(tmp_path.iterdir()) == []


def test_run_loop_flushes_on_size_and_again_on_shutdown(parts):
    """The main loop loads a full batch, then flushes the remainder when stopped."""
    messages = [good(0, 0), good(0, 1), good(0, 2)]
    consumer, kafka, loader, _, _ = parts(messages=messages, max_records=2)
    kafka.on_empty = consumer.stop          # stop once every message was handed out
    consumer.run()
    assert [len(call["rows"]) for call in loader.calls] == [2, 1]
    assert kafka.commits == [{0: 2}, {0: 3}]
    assert kafka.closed and loader.closed


def test_shutdown_with_failing_snowflake_does_not_commit(parts):
    """If the final flush fails, nothing is committed, so the messages are re-read later."""
    consumer, kafka, _, _, _ = parts(messages=[good(0, 0)], failures=[RuntimeError("down")])
    kafka.on_empty = consumer.stop
    consumer.run()                          # must not raise
    assert kafka.commits == []
    assert kafka.closed
