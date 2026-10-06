"""
Unit tests for batch splitting in consumer/snowflake_loader.py.

Snowflake lets one COPY add at most 100 new columns (measured on the real
account by scripts/verify_gate.py --check limit); a COPY that would add more
fails as a whole. These tests check that a batch introducing more new fields
is split into several COPY operations, and that the delivery guarantee
survives: no record lost, no record loaded twice, and Kafka offsets committed
only after EVERY part is loaded.

Snowflake is replaced by a fake that behaves like the real thing in the two
ways that matter here: it remembers the table's columns, and it REJECTS a COPY
that would add more columns than the limit. A test therefore fails if the
loader ever sends an oversized COPY.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import snowflake.connector

from config import settings
from consumer.consumer import StreamingConsumer
from consumer.snowflake_loader import BatchInfo, RecordTooWideError, SnowflakeLoader, plan_splits

# The limit the fake Snowflake enforces; the same value the loader is configured with.
LIMIT = settings.MAX_NEW_COLUMNS_PER_COPY
TOPIC = "order_events"

COPY_COLUMNS = (
    "file", "status", "rows_parsed", "rows_loaded", "error_limit", "errors_seen",
    "first_error", "first_error_line", "first_error_character", "first_error_column_name",
)


class FakeSnowflake:
    """A pretend Snowflake table plus stage, shared by all cursors of a test."""

    def __init__(self, fail_copy_numbers: set[int] | None = None) -> None:
        """
        Args:
            fail_copy_numbers: 1-based COPY numbers that fail with a network-style
                error BEFORE loading anything (to test retries).
        """
        # Columns the pretend table has: an event id plus the consumer's metadata columns.
        self.columns: dict[str, str] = {
            "EVENT_ID": "VARCHAR", "_KAFKA_TOPIC": "VARCHAR", "_KAFKA_PARTITION": "NUMBER",
            "_KAFKA_OFFSET": "NUMBER", "_KAFKA_TIMESTAMP": "TIMESTAMP_NTZ", "_INGESTED_AT": "TIMESTAMP_NTZ",
        }
        self.staged: dict[str, list[dict]] = {}       # staged file name -> its rows
        self.loaded_files: set[str] = set()           # files Snowflake has already loaded
        self.table_rows: list[dict] = []              # every row "in the table"
        self.copies: list[tuple[str, int]] = []       # (file, columns added) per successful COPY
        self.copy_attempts = 0
        self.fail_copy_numbers = fail_copy_numbers or set()
        self.audit_inserts: list[tuple] = []

    # -- connection interface ------------------------------------------------
    def cursor(self) -> "FakeCursor":
        """Hand out a cursor bound to this pretend account."""
        return FakeCursor(self)

    def is_closed(self) -> bool:
        """Always open."""
        return False

    def close(self) -> None:
        """Nothing to release."""


class FakeCursor:
    """Executes the handful of statements the loader sends."""

    def __init__(self, account: FakeSnowflake) -> None:
        """Bind to the shared pretend account."""
        self.account = account
        self.description: list[tuple] = []
        self.rows: list[tuple] = []
        self.sfqid = "query-id"

    def execute(self, sql: str, params: tuple | None = None) -> None:
        """Act on one statement the way Snowflake would."""
        account = self.account
        keyword = sql.split()[0].upper()
        if keyword == "DESCRIBE":
            self.rows = list(account.columns.items())
        elif keyword == "PUT":
            # Read the local file named in the PUT, as an upload would.
            local = Path(re.search(r"file://(.*?)'", sql).group(1))
            rows = [json.loads(line) for line in local.read_text(encoding="utf-8").splitlines()]
            account.staged[local.name + ".gz"] = rows
            self.rows = [(local.name, local.name + ".gz", 1, 1, "NONE", "GZIP", "UPLOADED", "")]
        elif keyword == "COPY":
            self._copy(re.search(r"FILES = \('(.*?)'\)", sql).group(1))
        elif keyword == "INSERT":
            account.audit_inserts.append(params)
            self.rows = []
        else:  # REMOVE
            self.rows = []

    def _copy(self, file_name: str) -> None:
        """Pretend COPY INTO with schema evolution and its column limit."""
        account = self.account
        account.copy_attempts += 1
        if account.copy_attempts in account.fail_copy_numbers:
            raise snowflake.connector.errors.OperationalError("connection reset during COPY")
        if file_name in account.loaded_files:
            # Snowflake skips a file it has already loaded.
            self.description = [("status",)]
            self.rows = [("Copy executed with 0 files processed.",)]
            return
        rows = account.staged[file_name]
        new_columns = {name for row in rows for name in row} - set(account.columns)
        if len(new_columns) > LIMIT:
            # Exactly what the real account returned for 101 new columns.
            raise snowflake.connector.errors.ProgrammingError(
                "000691 (22000): Error in Schema Evolution:\nadding too many columns"
            )
        account.columns.update({name: "NUMBER" for name in new_columns})
        account.table_rows.extend(rows)
        account.loaded_files.add(file_name)
        account.copies.append((file_name, len(new_columns)))
        self.description = [(name,) for name in COPY_COLUMNS]
        self.rows = [(file_name, "LOADED", len(rows), len(rows), 1, 0, None, None, None, None)]

    def fetchone(self):
        """First result row, or None."""
        return self.rows[0] if self.rows else None

    def fetchall(self) -> list[tuple]:
        """All result rows."""
        return list(self.rows)

    def close(self) -> None:
        """Nothing to release."""


def wide_record(offset: int, first_field: int, field_count: int) -> dict:
    """A record with ``field_count`` fields F0000.. starting at ``first_field``."""
    record = {"EVENT_ID": f"e{offset}", "_KAFKA_PARTITION": 0, "_KAFKA_OFFSET": offset}
    record.update({f"F{index:04d}": index for index in range(first_field, first_field + field_count)})
    return record


def write_batch(folder: Path, records: list[dict]) -> tuple[Path, BatchInfo]:
    """Write a batch file like the consumer does and build its BatchInfo."""
    path = folder / "order_events_p0-0_o0-9_abcd1234.json"
    path.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
    first_seen: dict[str, tuple[int, int]] = {}
    for record in records:
        for name in record:
            first_seen.setdefault(name, (0, record["_KAFKA_OFFSET"]))
    info = BatchInfo(
        topic=TOPIC, record_count=len(records), column_names=set(first_seen),
        first_seen=first_seen, offset_ranges_text="{}",
    )
    return path, info


def make_loader(account: FakeSnowflake) -> SnowflakeLoader:
    """A real SnowflakeLoader talking to the pretend account."""
    return SnowflakeLoader(table="ORDER_EVENTS", connection_factory=lambda: account)


# ---------------------------------------------------------------------------
# plan_splits (pure planning)
# ---------------------------------------------------------------------------

def test_batch_within_the_limit_is_one_part():
    """Exactly `limit` new columns still fit in a single COPY."""
    records = [{"A", "B"}, {"C"}]
    assert plan_splits(records, known_columns=set(), limit=3) == [(0, 2)]


def test_batch_over_the_limit_is_cut_before_the_record_that_would_exceed_it():
    """Parts are cut at record boundaries, in order."""
    records = [{"A", "B"}, {"C"}, {"D"}, {"E", "F"}]
    assert plan_splits(records, known_columns=set(), limit=3) == [(0, 2), (2, 4)]


def test_known_columns_do_not_count_as_new():
    """Only fields the table lacks count toward the limit."""
    records = [{"EVENT_ID", "A"}, {"EVENT_ID", "B"}]
    assert plan_splits(records, known_columns={"EVENT_ID"}, limit=2) == [(0, 2)]


def test_columns_added_by_an_earlier_part_are_not_new_in_a_later_part():
    """Once a part is closed its columns exist, so repeating them later costs nothing."""
    records = [{"A", "B"}, {"C", "D"}, {"A", "B", "C", "D"}]
    assert plan_splits(records, known_columns=set(), limit=2) == [(0, 1), (1, 3)]


def test_every_record_is_covered_exactly_once_in_order():
    """The ranges tile the batch: nothing skipped, nothing repeated."""
    records = [{f"C{index}"} for index in range(25)]
    ranges = plan_splits(records, known_columns=set(), limit=4)
    covered = [index for start, end in ranges for index in range(start, end)]
    assert covered == list(range(25))


def test_single_record_over_the_limit_cannot_be_split():
    """One record is one row; if it alone exceeds the limit, planning refuses it."""
    with pytest.raises(RecordTooWideError):
        plan_splits([{"A", "B", "C"}], known_columns=set(), limit=2)


# ---------------------------------------------------------------------------
# Loader: splitting against the limit-enforcing fake
# ---------------------------------------------------------------------------

def test_normal_batch_is_not_split(tmp_path):
    """A batch at exactly the limit takes one COPY; no part files are created."""
    account = FakeSnowflake()
    path, info = write_batch(tmp_path, [wide_record(0, 0, LIMIT)])
    result = make_loader(account).load_batch(path, info)
    assert result.copies == 1
    assert [file for file, _ in account.copies] == [path.name + ".gz"]
    assert list(tmp_path.iterdir()) == [path]


def test_batch_over_the_limit_is_split_and_every_copy_stays_within_the_limit(tmp_path):
    """3 records x 60 new fields = 180 new columns -> three COPYs of 60, none rejected."""
    account = FakeSnowflake()
    records = [wide_record(offset, offset * 60, 60) for offset in range(3)]
    path, info = write_batch(tmp_path, records)
    result = make_loader(account).load_batch(path, info)

    assert result.copies == 3
    assert [added for _, added in account.copies] == [60, 60, 60]       # the fake would raise above LIMIT
    assert (result.status, result.rows_parsed, result.rows_loaded, result.errors_seen) == ("LOADED", 3, 3, 0)
    assert len(result.new_columns) == 180


def test_split_loads_every_record_exactly_once_and_in_order(tmp_path):
    """No record is lost and none is duplicated by splitting."""
    account = FakeSnowflake()
    records = [wide_record(offset, offset * 30, 30) for offset in range(10)]   # 300 new columns
    path, info = write_batch(tmp_path, records)
    make_loader(account).load_batch(path, info)
    assert account.table_rows == records


def test_split_writes_one_audit_row_per_copy_and_cleans_up_part_files(tmp_path):
    """Each COPY is logged under the same batch id; only the consumer's own file remains."""
    account = FakeSnowflake()
    path, info = write_batch(tmp_path, [wide_record(offset, offset * 60, 60) for offset in range(3)])
    make_loader(account).load_batch(path, info)

    batch_rows = [params for params in account.audit_inserts if len(params) == 14]   # INGEST_BATCH_LOG rows
    assert len(batch_rows) == 3
    assert len({params[0] for params in batch_rows}) == 1                            # one shared BATCH_ID
    assert [params[2] for params in batch_rows] == [
        "order_events_p0-0_o0-9_abcd1234_part01of03.json",
        "order_events_p0-0_o0-9_abcd1234_part02of03.json",
        "order_events_p0-0_o0-9_abcd1234_part03of03.json",
    ]
    assert [json.loads(params[4]) for params in batch_rows] == [{"0": [0, 0]}, {"0": [1, 1]}, {"0": [2, 2]}]
    assert list(tmp_path.iterdir()) == [path]


def test_failure_in_a_later_part_raises_and_retry_skips_the_parts_already_loaded(tmp_path):
    """Part 2 fails -> load_batch raises. The retry loads parts 2 and 3 only; part 1 is not repeated."""
    account = FakeSnowflake(fail_copy_numbers={2})
    records = [wide_record(offset, offset * 60, 60) for offset in range(3)]
    path, info = write_batch(tmp_path, records)
    loader = make_loader(account)

    with pytest.raises(snowflake.connector.Error):
        loader.load_batch(path, info)
    assert len(account.table_rows) == 1                 # only part 1 is in the table so far

    result = loader.load_batch(path, info, is_retry=True)
    assert account.table_rows == records                # complete, in order, no duplicate of part 1
    assert [file for file, _ in account.copies] == [
        "order_events_p0-0_o0-9_abcd1234_part01of03.json.gz",
        "order_events_p0-0_o0-9_abcd1234_part02of03.json.gz",
        "order_events_p0-0_o0-9_abcd1234_part03of03.json.gz",
    ]
    assert account.copy_attempts == 4                   # 3 successful + the 1 failed attempt
    assert (result.copies, result.rows_loaded) == (3, 3)


def test_single_record_over_the_limit_is_refused_by_the_loader(tmp_path):
    """The safety net behind the consumer's own check: nothing is sent to Snowflake."""
    account = FakeSnowflake()
    path, info = write_batch(tmp_path, [wide_record(0, 0, LIMIT + 1)])
    with pytest.raises(RecordTooWideError):
        make_loader(account).load_batch(path, info)
    assert account.copy_attempts == 0


# ---------------------------------------------------------------------------
# Consumer + real loader: commit only after ALL parts are loaded
# ---------------------------------------------------------------------------

class Message:
    """Minimal stand-in for a Kafka message carrying a JSON value."""

    def __init__(self, offset: int, payload: dict) -> None:
        """Remember offset and payload."""
        self._offset, self._value = offset, json.dumps(payload).encode()

    def error(self):
        """No Kafka error."""
        return None

    def topic(self) -> str:
        """Source topic."""
        return TOPIC

    def partition(self) -> int:
        """Source partition."""
        return 0

    def offset(self) -> int:
        """Message offset."""
        return self._offset

    def key(self) -> bytes:
        """Message key."""
        return b"k"

    def value(self) -> bytes:
        """Raw JSON value."""
        return self._value

    def timestamp(self) -> tuple[int, int]:
        """(type, milliseconds)."""
        return (1, 1_791_000_000_000)


class Kafka:
    """Records commits, pauses and resumes."""

    def __init__(self) -> None:
        """Nothing committed yet."""
        self.commits: list[dict[int, int]] = []

    def commit(self, offsets, asynchronous) -> None:
        """Record {partition: next offset}."""
        self.commits.append({tp.partition: tp.offset for tp in offsets})

    def assignment(self) -> list:
        """One pretend partition."""
        return ["p0"]

    def pause(self, partitions) -> None:
        """Accept a pause."""

    def resume(self, partitions) -> None:
        """Accept a resume."""

    def poll(self, timeout):
        """No messages while waiting to retry."""
        return None


class DeadLetter:
    """Records rejected messages."""

    def __init__(self) -> None:
        """Nothing rejected yet."""
        self.published: list[tuple[int, str]] = []

    def publish(self, message, reason: str) -> None:
        """Remember offset and reason."""
        self.published.append((message.offset(), reason))

    def flush(self, timeout: float = 30.0) -> None:
        """Pretend every dead letter is confirmed."""


class Clock:
    """Hand-moved clock; sleeping advances it instantly."""

    now = 0.0

    def __call__(self) -> float:
        """Current pretend time."""
        return self.now

    def sleep(self, seconds: float) -> None:
        """Advance instead of waiting."""
        self.now += max(seconds, 0.01)


def make_consumer(tmp_path, account: FakeSnowflake):
    """A real StreamingConsumer and real SnowflakeLoader over the pretend Snowflake."""
    kafka, dead_letter, clock = Kafka(), DeadLetter(), Clock()
    consumer = StreamingConsumer(
        kafka_consumer=kafka, loader=make_loader(account), dead_letter=dead_letter, topic=TOPIC,
        batch_dir=tmp_path, max_records=1000, max_seconds=5.0, clock=clock, sleep=clock.sleep,
    )
    return consumer, kafka, dead_letter


def payload(first_field: int, field_count: int) -> dict:
    """A message with ``field_count`` lower-case fields f0000.. (the consumer upper-cases them)."""
    return {"event_id": "x", **{f"f{index:04d}": index for index in range(first_field, first_field + field_count)}}


def test_offsets_are_not_committed_when_a_later_part_fails(tmp_path):
    """Part 1 loaded, part 2 failed: one flush attempt must commit NOTHING."""
    account = FakeSnowflake(fail_copy_numbers={2})
    consumer, kafka, _ = make_consumer(tmp_path, account)
    for offset in range(3):
        consumer._handle_message(Message(offset, payload(offset * 60, 60)))

    with pytest.raises(snowflake.connector.Error):
        consumer._flush_once(copy_may_have_run=False)
    assert kafka.commits == []
    assert len(consumer.buffer.records) == 3            # the whole batch is still held


def test_offsets_are_committed_once_after_all_parts_succeed(tmp_path):
    """With retries, the commit happens exactly once and only after the last part."""
    account = FakeSnowflake(fail_copy_numbers={2})
    consumer, kafka, _ = make_consumer(tmp_path, account)
    for offset in range(3):
        consumer._handle_message(Message(offset, payload(offset * 60, 60)))

    consumer.flush()
    assert kafka.commits == [{0: 3}]
    assert [row["_KAFKA_OFFSET"] for row in account.table_rows] == [0, 1, 2]   # each once
    assert consumer.rows_loaded == 3 and consumer.buffer.is_empty
    assert list(tmp_path.iterdir()) == []               # batch file and part files removed


def test_message_that_alone_exceeds_the_limit_goes_to_the_dead_letter_topic(tmp_path):
    """Such a message can never be loaded; it is parked, and its neighbours still load."""
    account = FakeSnowflake()
    consumer, kafka, dead_letter = make_consumer(tmp_path, account)
    consumer._handle_message(Message(0, payload(0, 5)))
    consumer._handle_message(Message(1, payload(1000, LIMIT + 1)))     # 101 new fields in one message
    consumer._handle_message(Message(2, payload(5, 5)))

    consumer.flush()
    assert [offset for offset, _ in dead_letter.published] == [1]
    assert "101 new fields" in dead_letter.published[0][1]
    assert [row["_KAFKA_OFFSET"] for row in account.table_rows] == [0, 2]
    assert kafka.commits == [{0: 3}]                    # the commit moves past the parked message too
