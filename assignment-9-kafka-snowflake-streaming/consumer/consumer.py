"""
Kafka consumer: the long-running process that moves data from Kafka to Snowflake.

Run from the project root:

    python -m consumer.consumer

It runs until Ctrl+C and needs no manual step per batch:

    poll Kafka -> build records -> buffer -> every few seconds:
        write NDJSON file -> PUT -> COPY INTO -> audit rows -> commit offsets

Delivery guarantee: AT-LEAST-ONCE. Kafka offsets are committed only AFTER
Snowflake has confirmed the load. If the process dies before the commit, the
same messages are read again after restart; they are never skipped. The rare
duplicates this can cause are removed by the ORDER_EVENTS_LATEST view.

Schema evolution is not handled here. The consumer passes unknown fields
through, and Snowflake adds the columns during COPY (see snowflake_loader.py).
"""

from __future__ import annotations

import logging
import signal
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

import snowflake.connector
from confluent_kafka import Consumer, KafkaError, KafkaException, Message, TopicPartition

from config import settings
from consumer.batching import BatchBuffer
from consumer.dead_letter import DeadLetterPublisher
from consumer.snowflake_loader import BatchInfo, LoadResult, SnowflakeLoader
from consumer.transform import MessageRejected, build_record

logger = logging.getLogger("consumer")

# Longest time one poll() call waits for a message, in seconds. Short enough
# that Ctrl+C and the batch time limit are noticed promptly.
POLL_SECONDS = 1.0


def create_kafka_consumer(group_id: str) -> Consumer:
    """Create the Kafka consumer client.

    Args:
        group_id: Consumer group; Kafka stores committed offsets under it.
    """
    return Consumer(
        {
            "bootstrap.servers": settings.KAFKA_BOOTSTRAP_SERVERS,
            # The local broker listens on IPv4 only (see producer.py).
            "broker.address.family": "v4",
            "group.id": group_id,
            # The heart of at-least-once delivery: the client must NOT commit
            # offsets on a timer. This program commits them itself, and only
            # after Snowflake has confirmed the load.
            "enable.auto.commit": False,
            # A brand-new consumer group starts from the oldest message, so
            # nothing produced before the consumer first started is missed.
            "auto.offset.reset": "earliest",
            "client.id": "order-events-snowflake-loader",
        }
    )


class StreamingConsumer:
    """Reads Kafka continuously and loads micro-batches into Snowflake.

    The Kafka client, the loader, the dead-letter publisher and the clock are
    passed in, so unit tests can replace each with a fake.
    """

    def __init__(
        self,
        kafka_consumer: Any,
        loader: Any,
        dead_letter: Any,
        topic: str | None = None,
        batch_dir: Path | None = None,
        max_records: int | None = None,
        max_seconds: float | None = None,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        """Wire the consumer together.

        Args:
            kafka_consumer: confluent-kafka ``Consumer`` (or a fake).
            loader: ``SnowflakeLoader`` (or a fake) with ``load_batch``.
            dead_letter: ``DeadLetterPublisher`` (or a fake).
            topic: Topic to read. Defaults to ``KAFKA_TOPIC``.
            batch_dir: Folder for temporary batch files. Defaults to ``BATCH_DIR``.
            max_records: Batch size limit. Defaults to ``BATCH_MAX_RECORDS``.
            max_seconds: Batch age limit. Defaults to ``BATCH_MAX_SECONDS``.
            clock: Returns seconds from a steadily increasing clock.
            sleep: Waits the given number of seconds (replaced in tests).
        """
        self.kafka = kafka_consumer
        self.loader = loader
        self.dead_letter = dead_letter
        self.topic = topic or settings.KAFKA_TOPIC
        self.batch_dir = batch_dir or settings.BATCH_DIR
        self.clock = clock
        self.sleep = sleep
        self.buffer = BatchBuffer(
            max_records=max_records or settings.BATCH_MAX_RECORDS,
            max_seconds=max_seconds or settings.BATCH_MAX_SECONDS,
        )
        # Batch file of the flush in progress. It is remembered across retries
        # so that every attempt uploads the same file name.
        self._pending_file: Path | None = None
        # Set by stop(); the main loop checks it between polls.
        self._stop = threading.Event()
        # Running totals, reported in the log and used by the tests.
        self.batches_loaded = 0
        self.rows_loaded = 0
        self.rows_rejected = 0

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def stop(self) -> None:
        """Ask the main loop to finish: flush what is buffered, then exit."""
        self._stop.set()

    def run(self) -> None:
        """Run until ``stop`` is called. This is the pipeline's main loop."""
        # on_revoke: Kafka is about to give our partitions to another consumer
        # (or we are leaving the group). Load and commit what we hold first,
        # so the next owner does not read the same messages again.
        self.kafka.subscribe([self.topic], on_revoke=self._on_partitions_revoked)
        logger.info(
            "Consuming %s (batch: %d records or %.1f s). Ctrl+C to stop.",
            self.topic, self.buffer.max_records, self.buffer.max_seconds,
        )
        try:
            while not self._stop.is_set():
                self._poll_once()
                if self.buffer.should_flush(self.clock()):
                    self.flush()
        finally:
            self._shutdown()

    def _shutdown(self) -> None:
        """Flush the remaining buffer once, then release Kafka and Snowflake."""
        try:
            if not self.buffer.is_empty:
                logger.info("Shutting down: flushing the remaining buffer.")
                # One attempt only. If Snowflake is unreachable now, the
                # offsets stay uncommitted and the messages are read again on
                # the next start, so nothing is lost by giving up here.
                self._flush_once(copy_may_have_run=False)
        except Exception:  # noqa: BLE001 - shutdown must continue whatever went wrong
            logger.exception("Final flush failed; uncommitted messages will be re-read on next start.")
        finally:
            self.kafka.close()
            self.loader.close()
            logger.info(
                "Stopped. Batches loaded: %d, rows loaded: %d, rows rejected by Snowflake: %d.",
                self.batches_loaded, self.rows_loaded, self.rows_rejected,
            )

    # ------------------------------------------------------------------
    # Reading from Kafka
    # ------------------------------------------------------------------

    def _poll_once(self) -> None:
        """Wait briefly for one message and put it into the buffer."""
        # Never wait past the moment the current batch is due.
        timeout = POLL_SECONDS
        until_flush = self.buffer.seconds_until_flush(self.clock())
        if until_flush is not None:
            timeout = min(timeout, until_flush)

        message = self.kafka.poll(timeout)
        if message is None:
            # Nothing arrived. With an empty buffer this is the idle state:
            # no query is sent, so the Snowflake warehouse can suspend.
            return
        if message.error():
            self._handle_kafka_error(message.error())
            return
        self._handle_message(message)

    def _handle_kafka_error(self, error: KafkaError) -> None:
        """Log a Kafka error event; raise only if the client cannot recover."""
        if error.fatal():
            # Fatal means the client instance is unusable. Stop rather than
            # spin: uncommitted messages are read again after a restart.
            raise KafkaException(error)
        # Everything else (broker briefly down, leader moved, ...) is retried
        # by the client itself. Just make it visible.
        logger.warning("Kafka reported: %s", error)

    def _handle_message(self, message: Message) -> None:
        """Turn one Kafka message into a buffered record or a dead letter."""
        partition, offset = message.partition(), message.offset()
        # Track the offset for EVERY message, including rejected ones, so the
        # committed offset moves past bad messages too.
        self.buffer.track(partition, offset, self.clock())

        # message.timestamp() returns (type, milliseconds); only the value is needed.
        _, timestamp_ms = message.timestamp()
        try:
            record = build_record(
                value=message.value(),
                topic=message.topic(),
                partition=partition,
                offset=offset,
                kafka_timestamp_ms=timestamp_ms,
                ingested_at=datetime.now(timezone.utc),
            )
        except MessageRejected as rejection:
            # A bad message must not stop the pipeline: park it and move on.
            self.dead_letter.publish(message, str(rejection))
            return

        # One record is one row and must be loaded by one COPY, and Snowflake
        # lets a COPY add only a limited number of new columns. A message that
        # alone introduces more than that can never be loaded, so it is parked
        # in the dead-letter topic instead of blocking the pipeline forever.
        new_fields = self._count_new_fields(record)
        if new_fields > settings.MAX_NEW_COLUMNS_PER_COPY:
            self.dead_letter.publish(
                message,
                f"Message introduces {new_fields} new fields; Snowflake can add at most "
                f"{settings.MAX_NEW_COLUMNS_PER_COPY} columns in one COPY",
            )
            return
        self.buffer.add(record, partition, offset)

    def _count_new_fields(self, record: dict[str, Any]) -> int:
        """Return how many of the record's fields are not yet columns of the table.

        The loader keeps the column list cached, so this normally costs no
        call to Snowflake. If the list cannot be read right now (Snowflake
        unreachable), 0 is returned and the record is buffered as usual; the
        loader performs the same check again when it plans the load.
        """
        try:
            known = self.loader.known_columns()
        except snowflake.connector.Error:
            logger.warning("Could not read the table's columns; skipping the new-field count for one message.")
            return 0
        return sum(1 for column in record if column not in known)

    def _on_partitions_revoked(self, consumer: Any, partitions: list[TopicPartition]) -> None:
        """Kafka callback: load and commit the buffer before losing partitions."""
        if self.buffer.is_empty:
            return
        logger.info("Partitions are being revoked: flushing the buffer first.")
        try:
            self._flush_once(copy_may_have_run=False)
        except Exception:  # noqa: BLE001 - a callback must not raise into the Kafka client
            # Not committed, so the next owner of the partitions re-reads the
            # messages. Drop our copy to avoid loading them a second time here.
            logger.exception("Flush during rebalance failed; the messages will be re-read.")
            self._discard_buffer()

    # ------------------------------------------------------------------
    # Flushing to Snowflake
    # ------------------------------------------------------------------

    def flush(self) -> None:
        """Load the buffer into Snowflake, retrying until it succeeds.

        While retrying, the partitions are paused: the consumer keeps its
        place in the group but receives no new messages, so the buffer cannot
        grow without limit during a long Snowflake outage. The wait between
        attempts doubles each time, up to ``RETRY_MAX_SECONDS``.
        """
        delay = settings.RETRY_INITIAL_SECONDS
        # True once an attempt failed with a Snowflake error, meaning the COPY
        # may have completed on the server even though we saw an error.
        copy_may_have_run = False
        paused: list[TopicPartition] = []

        while True:
            try:
                self._flush_once(copy_may_have_run)
                break
            except snowflake.connector.Error as error:
                copy_may_have_run = True
                logger.error("Snowflake error, retrying in %.0f s: %s", delay, error)
            except Exception as error:  # noqa: BLE001 - any failure must be retried, not lose the batch
                logger.error("Flush failed, retrying in %.0f s: %s", delay, error)

            if self._stop.is_set():
                # Stop was requested during an outage. Give up; the offsets
                # are uncommitted, so the messages are re-read on next start.
                logger.warning("Stop requested while retrying; leaving the batch uncommitted.")
                self._discard_buffer()
                break

            if not paused:
                paused = self.kafka.assignment()
                self.kafka.pause(paused)
            self._wait_while_paused(delay)
            delay = min(delay * 2, settings.RETRY_MAX_SECONDS)

        if paused:
            self.kafka.resume(paused)

    def _discard_buffer(self) -> None:
        """Forget the buffered batch WITHOUT committing its offsets.

        Used only when the batch could not be loaded and this consumer is
        about to stop or lose its partitions. Because nothing was committed,
        Kafka delivers the same messages again later; no data is lost.
        """
        if self._pending_file is not None:
            self._pending_file.unlink(missing_ok=True)
            self._pending_file = None
        self.buffer.clear()

    def _wait_while_paused(self, seconds: float) -> None:
        """Wait ``seconds`` while still serving the Kafka client.

        poll() must keep being called or Kafka assumes this consumer is dead
        and removes it from the group. The partitions are paused, so these
        polls return no messages.
        """
        deadline = self.clock() + seconds
        while self.clock() < deadline and not self._stop.is_set():
            self.kafka.poll(0)
            self.sleep(min(0.5, max(0.0, deadline - self.clock())))

    def _flush_once(self, copy_may_have_run: bool) -> None:
        """Make one attempt to load the buffer and commit its offsets.

        The order of the steps is what makes delivery at-least-once:

            1. write the batch file
            2. load it into Snowflake          (may raise -> nothing committed)
            3. confirm dead-letter messages    (may raise -> nothing committed)
            4. commit Kafka offsets            (only reached after 2 and 3)
            5. delete the local file, clear the buffer

        Args:
            copy_may_have_run: Passed to the loader as ``is_retry``.

        Raises:
            Exception: whatever step failed. The buffer is left untouched so
                the caller can try again.
        """
        result: LoadResult | None = None
        file_path: Path | None = None

        if self.buffer.records:
            # Reuse the same file name on a retry: Snowflake recognises a file
            # it has already loaded and will not load it twice.
            if self._pending_file is None:
                self._pending_file = self.batch_dir / self.buffer.file_name(self.topic)
            file_path = self._pending_file
            self.buffer.write_file(file_path)
            result = self.loader.load_batch(
                file_path,
                BatchInfo(
                    topic=self.topic,
                    record_count=len(self.buffer.records),
                    column_names=self.buffer.column_names(),
                    first_seen=dict(self.buffer.first_seen),
                    offset_ranges_text=self.buffer.offset_ranges_text(),
                ),
                is_retry=copy_may_have_run,
            )

        # Rejected messages must be safely in the dead-letter topic before
        # their offsets are committed.
        self.dead_letter.flush()

        # Commit synchronously: when this returns, Kafka has stored the new
        # position, and these messages will not be delivered again.
        self.kafka.commit(
            offsets=[
                TopicPartition(self.topic, partition, next_offset)
                for partition, next_offset in self.buffer.offsets_to_commit().items()
            ],
            asynchronous=False,
        )

        if result is not None:
            self.batches_loaded += 1
            self.rows_loaded += result.rows_loaded
            self.rows_rejected += result.errors_seen
            logger.info(
                "Batch %s: %d records -> %s, loaded %d, rejected %d, %.2f s%s%s",
                result.file_name, len(self.buffer.records), result.status,
                result.rows_loaded, result.errors_seen, result.load_seconds,
                f", split into {result.copies} COPY operations" if result.copies > 1 else "",
                f", new columns: {[name for name, _ in result.new_columns]}" if result.new_columns else "",
            )
            if result.errors_seen:
                logger.warning("Snowflake rejected %d row(s). First error: %s", result.errors_seen, result.first_error)
        if file_path is not None:
            # The data is in Snowflake and the offsets are committed; the
            # local copy is no longer needed.
            file_path.unlink(missing_ok=True)
        self._pending_file = None
        self.buffer.clear()


def main() -> None:
    """Entry point: build the real consumer and run it until Ctrl+C."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # The Snowflake driver logs every statement at INFO; keep the output readable.
    logging.getLogger("snowflake.connector").setLevel(logging.WARNING)

    streaming = StreamingConsumer(
        kafka_consumer=create_kafka_consumer(settings.KAFKA_GROUP_ID),
        loader=SnowflakeLoader(),
        dead_letter=DeadLetterPublisher(),
    )

    def request_stop(signum: int, frame: Any) -> None:
        """Signal handler: turn Ctrl+C into an orderly stop instead of a crash."""
        logger.info("Stop requested (signal %d).", signum)
        streaming.stop()

    # SIGINT is Ctrl+C. SIGBREAK is Ctrl+Break and exists only on Windows.
    signal.signal(signal.SIGINT, request_stop)
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, request_stop)

    streaming.run()


if __name__ == "__main__":
    main()
