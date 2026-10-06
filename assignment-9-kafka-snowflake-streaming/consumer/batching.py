"""
In-memory micro-batch buffer used by the consumer.

The consumer does not load messages one at a time: each COPY INTO has a fixed
overhead, so records are collected for a few seconds and loaded together.

This module is pure (no Kafka, no Snowflake), so the flush rules can be unit
tested with a fake clock.

Two things are tracked separately on purpose:

    * records  - valid messages waiting to be loaded into Snowflake;
    * offsets  - the highest offset SEEN per partition, including messages
                 that were rejected and sent to the dead-letter topic.

Rejected messages produce no record but must still move the committed offset
forward; otherwise they would be read again after every restart.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class PartitionRange:
    """First and last offset seen in one partition during the current batch."""

    first_offset: int
    last_offset: int


@dataclass
class BatchBuffer:
    """Collects records until it is time to flush them to Snowflake.

    Attributes:
        max_records: Flush once this many records are buffered.
        max_seconds: Flush once this many seconds have passed since the first
            message of the batch was seen.
    """

    max_records: int
    max_seconds: float
    records: list[dict[str, Any]] = field(default_factory=list)
    ranges: dict[int, PartitionRange] = field(default_factory=dict)
    # Clock reading when the first message of this batch arrived; None = empty.
    started_at: float | None = None
    # For each column name: (partition, offset) of the first record carrying it.
    # Used only for the schema-evolution audit log.
    first_seen: dict[str, tuple[int, int]] = field(default_factory=dict)

    def track(self, partition: int, offset: int, now: float) -> None:
        """Note that the message at (partition, offset) has been consumed.

        Called for EVERY message, valid or rejected, so that the offset to
        commit also covers rejected messages.
        """
        if self.started_at is None:
            # The time limit counts from the first message, so a quiet topic
            # never triggers a flush and never wakes the warehouse.
            self.started_at = now
        existing = self.ranges.get(partition)
        if existing is None:
            self.ranges[partition] = PartitionRange(first_offset=offset, last_offset=offset)
        else:
            existing.first_offset = min(existing.first_offset, offset)
            existing.last_offset = max(existing.last_offset, offset)

    def add(self, record: dict[str, Any], partition: int, offset: int) -> None:
        """Add one valid record to the batch. ``track`` must be called as well."""
        self.records.append(record)
        for column in record:
            # setdefault keeps the first (partition, offset) seen per column.
            self.first_seen.setdefault(column, (partition, offset))

    @property
    def is_empty(self) -> bool:
        """True when no message at all has been consumed since the last flush."""
        return self.started_at is None

    def seconds_until_flush(self, now: float) -> float | None:
        """Seconds left before the time limit is reached, or ``None`` if empty."""
        if self.started_at is None:
            return None
        return max(0.0, self.max_seconds - (now - self.started_at))

    def should_flush(self, now: float) -> bool:
        """Return True when the batch must be flushed now.

        The batch is flushed when it is full or when it is old enough,
        whichever comes first. An empty batch is never flushed.
        """
        if self.started_at is None:
            return False
        if len(self.records) >= self.max_records:
            return True
        return (now - self.started_at) >= self.max_seconds

    def column_names(self) -> set[str]:
        """Return every column name that appears in at least one buffered record."""
        return set(self.first_seen)

    def offsets_to_commit(self) -> dict[int, int]:
        """Return, per partition, the offset to commit after a successful load.

        Kafka expects the offset of the NEXT message to read, hence ``+ 1``.
        """
        return {partition: rng.last_offset + 1 for partition, rng in self.ranges.items()}

    def offset_ranges_text(self) -> str:
        """Describe the batch's offsets as JSON text for the batch audit log."""
        return json.dumps(
            {str(partition): [rng.first_offset, rng.last_offset] for partition, rng in sorted(self.ranges.items())}
        )

    def file_name(self, topic: str) -> str:
        """Build a unique, traceable file name for this batch.

        Example: ``order_events_p0-2_o15-212_3f9a1c2e.json`` (partitions 0 to
        2, offsets 15 to 212). The random suffix guarantees uniqueness, which
        matters because Snowflake skips a file name it has already loaded.
        """
        partitions = sorted(self.ranges)
        lowest = min(rng.first_offset for rng in self.ranges.values())
        highest = max(rng.last_offset for rng in self.ranges.values())
        return f"{topic}_p{partitions[0]}-{partitions[-1]}_o{lowest}-{highest}_{uuid.uuid4().hex[:8]}.json"

    def write_file(self, path: Path) -> None:
        """Write the buffered records to ``path`` as newline-delimited JSON.

        One record per line is the layout the NDJSON_FF file format expects.
        """
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            for record in self.records:
                # allow_nan=False makes a NaN fail here, loudly, instead of
                # producing a file Snowflake cannot parse.
                handle.write(json.dumps(record, allow_nan=False) + "\n")

    def clear(self) -> None:
        """Empty the buffer after a successful flush."""
        self.records.clear()
        self.ranges.clear()
        self.first_seen.clear()
        self.started_at = None
