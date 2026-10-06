"""
Unit tests for consumer/batching.py.

They check when a micro-batch is flushed (size, age, never when empty), which
offsets are committed afterwards, and the layout of the batch file. A plain
number stands in for the clock, so no test has to wait.
"""

from __future__ import annotations

import json
import re

from consumer.batching import BatchBuffer


def make_buffer(max_records: int = 3, max_seconds: float = 5.0) -> BatchBuffer:
    """Create a small buffer so the limits are easy to reach in a test."""
    return BatchBuffer(max_records=max_records, max_seconds=max_seconds)


def add(buffer: BatchBuffer, partition: int, offset: int, now: float, **fields) -> None:
    """Track and add one valid record, the way the consumer does."""
    buffer.track(partition, offset, now)
    buffer.add({"EVENT_ID": f"e{offset}", **fields}, partition, offset)


def test_empty_buffer_never_flushes():
    """With no messages there is nothing to load, however much time passes."""
    buffer = make_buffer()
    assert buffer.is_empty
    assert not buffer.should_flush(now=10_000.0)
    assert buffer.seconds_until_flush(now=10_000.0) is None


def test_flushes_when_record_limit_is_reached():
    """The batch is flushed as soon as it holds max_records records."""
    buffer = make_buffer(max_records=3)
    add(buffer, 0, 0, now=0.0)
    add(buffer, 0, 1, now=0.1)
    assert not buffer.should_flush(now=0.2)
    add(buffer, 0, 2, now=0.2)
    assert buffer.should_flush(now=0.2)


def test_flushes_when_time_limit_is_reached():
    """A small batch is flushed once it is max_seconds old."""
    buffer = make_buffer(max_records=100, max_seconds=5.0)
    add(buffer, 0, 0, now=100.0)
    assert not buffer.should_flush(now=104.9)
    assert buffer.should_flush(now=105.0)


def test_time_limit_counts_from_the_first_message():
    """Later messages do not restart the timer, so latency stays bounded."""
    buffer = make_buffer(max_records=100, max_seconds=5.0)
    add(buffer, 0, 0, now=100.0)
    add(buffer, 0, 1, now=104.0)
    assert buffer.seconds_until_flush(now=104.0) == 1.0
    assert buffer.should_flush(now=105.0)


def test_rejected_only_batch_still_flushes():
    """Tracked offsets without records must flush too, so their offsets get committed."""
    buffer = make_buffer(max_seconds=5.0)
    buffer.track(0, 7, now=0.0)          # a rejected message: tracked, not added
    assert not buffer.is_empty
    assert buffer.records == []
    assert buffer.should_flush(now=5.0)
    assert buffer.offsets_to_commit() == {0: 8}


def test_offsets_to_commit_are_last_offset_plus_one_per_partition():
    """Kafka wants the NEXT offset to read, for each partition separately."""
    buffer = make_buffer(max_records=100)
    add(buffer, 0, 10, now=0.0)
    add(buffer, 0, 11, now=0.0)
    add(buffer, 2, 5, now=0.0)
    assert buffer.offsets_to_commit() == {0: 12, 2: 6}


def test_commit_offset_covers_rejected_messages():
    """A rejected message after the last valid one still moves the commit forward."""
    buffer = make_buffer(max_records=100)
    add(buffer, 1, 3, now=0.0)
    buffer.track(1, 4, now=0.0)          # rejected message at a higher offset
    assert buffer.offsets_to_commit() == {1: 5}
    assert len(buffer.records) == 1


def test_offset_ranges_text_is_json_per_partition():
    """The audit text lists first and last offset per partition."""
    buffer = make_buffer(max_records=100)
    add(buffer, 0, 10, now=0.0)
    add(buffer, 0, 12, now=0.0)
    add(buffer, 2, 5, now=0.0)
    assert json.loads(buffer.offset_ranges_text()) == {"0": [10, 12], "2": [5, 5]}


def test_first_seen_records_where_each_column_first_appeared():
    """For the schema audit log: the first (partition, offset) carrying each column."""
    buffer = make_buffer(max_records=100)
    add(buffer, 0, 1, now=0.0)
    add(buffer, 0, 2, now=0.0, DISCOUNT_PCT=5.0)
    add(buffer, 1, 9, now=0.0, DISCOUNT_PCT=7.5)
    assert buffer.first_seen["EVENT_ID"] == (0, 1)
    assert buffer.first_seen["DISCOUNT_PCT"] == (0, 2)
    assert buffer.column_names() == {"EVENT_ID", "DISCOUNT_PCT"}


def test_file_name_is_safe_traceable_and_unique():
    """The name shows partitions and offsets, uses only safe characters, and never repeats."""
    buffer = make_buffer(max_records=100)
    add(buffer, 0, 15, now=0.0)
    add(buffer, 2, 212, now=0.0)
    first, second = buffer.file_name("order_events"), buffer.file_name("order_events")
    assert re.fullmatch(r"order_events_p0-2_o15-212_[0-9a-f]{8}\.json", first)
    assert first != second


def test_write_file_produces_one_json_object_per_line(tmp_path):
    """The batch file is newline-delimited JSON, in buffer order."""
    buffer = make_buffer(max_records=100)
    add(buffer, 0, 0, now=0.0, QUANTITY=1)
    add(buffer, 0, 1, now=0.0, QUANTITY=2, ADDRESS={"city": "Pune"})
    path = tmp_path / "sub folder" / "batch.json"   # folder is created on demand
    buffer.write_file(path)
    lines = path.read_text(encoding="utf-8").splitlines()
    assert [json.loads(line) for line in lines] == buffer.records
    assert len(lines) == 2


def test_clear_resets_everything():
    """After a flush the buffer is empty and its timer is stopped."""
    buffer = make_buffer()
    add(buffer, 0, 0, now=0.0)
    buffer.clear()
    assert buffer.is_empty
    assert buffer.records == [] and buffer.ranges == {} and buffer.first_seen == {}
    assert not buffer.should_flush(now=1_000.0)
