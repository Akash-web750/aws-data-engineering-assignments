"""
CDC bridge: copies new PostgreSQL rows from Debezium's topic into the existing topic.

Run from the project root (only after CDC has been enabled, see the README):

    python -m cdc.bridge

    PostgreSQL -> Debezium -> [pgcdc.public.order_events] -> THIS BRIDGE -> [order_events] -> existing consumer -> Snowflake

It reads the raw change events Debezium writes, converts each inserted row
into the message format the existing producer uses (``cdc/transform.py``), and
writes it to the existing ``order_events`` topic. The existing consumer then
loads it into Snowflake exactly as it loads the producer's messages; it is not
changed and does not know the bridge exists.

What happens to each change event:
    inserted row              -> forwarded to ``order_events``
    snapshot / update / delete / backfill row -> skipped (counted, not forwarded)
    unusable message          -> copied to the existing dead-letter topic

DELIVERY GUARANTEE: at-least-once, the same as the rest of the pipeline.
The bridge's position in the CDC topic is committed only AFTER the forwarded
messages (and any dead letters) have been confirmed by Kafka. If the bridge
stops before that commit, it reads the same change events again on restart and
forwards them again. Such a repeat carries the same ``event_id``, which is
what the Snowflake view ORDER_EVENTS_UNIQUE uses to remove it.
"""

from __future__ import annotations

import json
import logging
import logging.handlers
import queue
import signal
import threading
import time
from typing import Any, Callable

from confluent_kafka import Consumer, KafkaError, KafkaException, Message, Producer, TopicPartition

from cdc.transform import CdcRejected, Forward, Skip, transform_change_event
from config import settings
from consumer.dead_letter import DeadLetterPublisher

logger = logging.getLogger("cdc.bridge")

# Longest time one poll() waits for a change event, in seconds. Short enough
# that Ctrl+C is noticed promptly and a quiet topic is checkpointed quickly.
POLL_SECONDS = 1.0

# Longest time to wait for Kafka to confirm forwarded messages, in seconds.
FLUSH_SECONDS = 30.0


def configure_logging(console: logging.Handler | None = None) -> logging.handlers.QueueListener:
    """Send log output through a queue so that writing it can never stall the bridge.

    WHY THIS EXISTS (observed on 2026-10-06 during the first live run)
        The bridge ran in a Windows console window. It forwarded an order
        event, then never committed its position, and after five minutes Kafka
        removed it from its consumer group although the process was still
        alive. A Windows console suspends a program at its next write to the
        window while text is selected in it ("QuickEdit" mode), and the next
        write was the bridge's own "Forwarded ..." log line, which sits
        between forwarding an event and committing the position.

    With a queue in between, the main loop only puts the log record into
    memory and carries on to the commit. A separate thread writes the records
    to the console; if the console is suspended, only that thread waits.

    Args:
        console: Handler that does the actual writing. Defaults to the
            standard error stream; tests pass a handler that blocks.

    Returns:
        The started listener. Call ``stop()`` on it at exit to write out
        whatever is still queued.
    """
    if console is None:
        console = logging.StreamHandler()
    console.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))

    log_queue: queue.SimpleQueue = queue.SimpleQueue()
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    # The only handler on the root logger is the queue; nothing in the main
    # thread writes to the console directly.
    root.handlers = [logging.handlers.QueueHandler(log_queue)]

    listener = logging.handlers.QueueListener(log_queue, console)
    # The listener's thread is a daemon thread, so a suspended console cannot
    # keep the process alive either.
    listener.start()
    return listener


def create_cdc_consumer() -> Consumer:
    """Create the Kafka consumer that reads Debezium's change events."""
    return Consumer(
        {
            "bootstrap.servers": settings.KAFKA_BOOTSTRAP_SERVERS,
            # The local broker listens on IPv4 only (see producer/producer.py).
            "broker.address.family": "v4",
            "group.id": settings.CDC_BRIDGE_GROUP_ID,
            # The bridge commits its position itself, and only after the
            # forwarded messages are confirmed. A timer-based commit could
            # skip change events that were never forwarded.
            "enable.auto.commit": False,
            # A brand-new group starts from the oldest change event, so an
            # insert made before the bridge first started is not missed. This
            # is safe because Debezium takes no snapshot: the topic holds only
            # rows inserted after CDC was switched on.
            "auto.offset.reset": "earliest",
            "client.id": "order-events-cdc-bridge",
        }
    )


def create_target_producer() -> Producer:
    """Create the Kafka producer that writes to the existing order-events topic.

    Same safety settings as ``producer/producer.py``: idempotence stops the
    client's own retries from creating duplicates and implies acks=all.
    """
    return Producer(
        {
            "bootstrap.servers": settings.KAFKA_BOOTSTRAP_SERVERS,
            "broker.address.family": "v4",
            "enable.idempotence": True,
            "linger.ms": 50,
            "client.id": "order-events-cdc-bridge",
        }
    )


class CdcBridge:
    """Reads change events, forwards inserts, and checkpoints its position.

    The Kafka clients, the dead-letter publisher, the clock and the sleep
    function are passed in, so unit tests can replace each with a fake.
    """

    def __init__(
        self,
        cdc_consumer: Any,
        target_producer: Any,
        dead_letter: Any,
        source_topic: str | None = None,
        target_topic: str | None = None,
        commit_every: int | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        """Wire the bridge together.

        Args:
            cdc_consumer: confluent-kafka ``Consumer`` on the CDC topic (or a fake).
            target_producer: confluent-kafka ``Producer`` (or a fake).
            dead_letter: ``DeadLetterPublisher`` (or a fake) with ``publish`` and ``flush``.
            source_topic: Topic to read. Defaults to ``CDC_SOURCE_TOPIC``.
            target_topic: Topic to write. Defaults to ``CDC_TARGET_TOPIC``.
            commit_every: Checkpoint after this many handled change events.
            sleep: Waits the given number of seconds (replaced in tests).
        """
        self.kafka = cdc_consumer
        self.producer = target_producer
        self.dead_letter = dead_letter
        self.source_topic = source_topic or settings.CDC_SOURCE_TOPIC
        self.target_topic = target_topic or settings.CDC_TARGET_TOPIC
        self.commit_every = commit_every or settings.CDC_BRIDGE_COMMIT_EVERY
        self.sleep = sleep
        # Set by stop(); the main loop checks it between polls.
        self._stop = threading.Event()
        # For each partition: offset of the first change event handled since
        # the last checkpoint (where to go back to if the checkpoint fails) ...
        self._first_offsets: dict[int, int] = {}
        # ... and offset of the last one (what to commit when it succeeds).
        self._last_offsets: dict[int, int] = {}
        # Forwarded messages Kafka refused since the last checkpoint.
        self._delivery_errors: list[str] = []
        # Pause before the next attempt after a failed checkpoint; doubles on
        # every failure and returns to the start value after a success.
        self._retry_delay: float = settings.RETRY_INITIAL_SECONDS
        # Running totals, reported in the log and used by the tests.
        self.forwarded = 0
        self.skipped = 0
        self.rejected = 0

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def stop(self) -> None:
        """Ask the main loop to finish: checkpoint what is pending, then exit."""
        self._stop.set()

    def run(self) -> None:
        """Run until ``stop`` is called. This is the bridge's main loop."""
        # on_revoke: Kafka is taking the partition away (or we are leaving the
        # group). Confirm and commit what has been handled first.
        self.kafka.subscribe([self.source_topic], on_revoke=self._on_partitions_revoked)
        logger.info(
            "Bridging %s -> %s (inserts only, checkpoint every %d events). Ctrl+C to stop.",
            self.source_topic, self.target_topic, self.commit_every,
        )
        try:
            while not self._stop.is_set():
                message = self.kafka.poll(POLL_SECONDS)
                if message is None:
                    # The topic is quiet: confirm whatever is still pending,
                    # so a single insert is forwarded and committed promptly.
                    self.checkpoint()
                    continue
                if message.error():
                    self._handle_kafka_error(message.error())
                    continue
                self.handle_message(message)
                if self._pending_count() >= self.commit_every:
                    self.checkpoint()
        finally:
            self._shutdown()

    def _shutdown(self) -> None:
        """Checkpoint once more, then release the Kafka clients."""
        try:
            self._checkpoint_once()
        except Exception:  # noqa: BLE001 - shutdown must continue whatever went wrong
            # Not committed, so these change events are read again on the next start.
            logger.exception("Final checkpoint failed; uncommitted change events will be re-read on next start.")
        finally:
            self.kafka.close()
            logger.info(
                "Stopped. Forwarded %d, skipped %d, sent to dead-letter topic %d.",
                self.forwarded, self.skipped, self.rejected,
            )

    def _handle_kafka_error(self, error: KafkaError) -> None:
        """Log a Kafka error event; raise only if the client cannot recover."""
        if error.fatal():
            raise KafkaException(error)
        # Broker briefly unavailable and similar: the client retries by itself.
        logger.warning("Kafka reported: %s", error)

    # ------------------------------------------------------------------
    # Handling one change event
    # ------------------------------------------------------------------

    def handle_message(self, message: Message) -> None:
        """Forward, skip or dead-letter one change event."""
        partition, offset = message.partition(), message.offset()
        # Remember the position for EVERY change event, also skipped and
        # rejected ones, so the committed position moves past them too.
        self._first_offsets.setdefault(partition, offset)
        self._last_offsets[partition] = offset

        try:
            outcome = transform_change_event(message.value())
        except CdcRejected as rejection:
            # An unusable message must not stop the bridge: park the original
            # bytes in the existing dead-letter topic and carry on.
            self.dead_letter.publish(message, f"CDC bridge: {rejection}")
            self.rejected += 1
            return

        if isinstance(outcome, Skip):
            self.skipped += 1
            logger.info("Skipped %s[%d]@%d: %s", message.topic(), partition, offset, outcome.reason)
            return

        self._forward(outcome)

    def _forward(self, outcome: Forward) -> None:
        """Write one order event to the existing topic, in the producer's format."""
        self.producer.produce(
            self.target_topic,
            key=outcome.key,
            # Same serialisation as producer/producer.py: json.dumps with its
            # defaults, UTF-8, fields in the order the transform produced them.
            value=json.dumps(outcome.event).encode("utf-8"),
            on_delivery=self._on_delivery,
        )
        # Lets the client run delivery callbacks without waiting.
        self.producer.poll(0)
        self.forwarded += 1
        logger.info("Forwarded order event %s (order %s).", outcome.event["event_id"], outcome.event["order_id"])

    def _on_delivery(self, error: KafkaError | None, message: Message) -> None:
        """Kafka calls this once per forwarded message, with the result."""
        if error is not None:
            self._delivery_errors.append(str(error))

    # ------------------------------------------------------------------
    # Checkpointing
    # ------------------------------------------------------------------

    def _pending_offsets(self) -> dict[int, int]:
        """Positions to commit: for each partition, the offset AFTER the last handled event."""
        return {partition: offset + 1 for partition, offset in self._last_offsets.items()}

    def _pending_count(self) -> int:
        """Number of change events handled since the last checkpoint."""
        return sum(self._last_offsets[p] - self._first_offsets[p] + 1 for p in self._last_offsets)

    def checkpoint(self) -> bool:
        """Confirm the pending work and commit the bridge's position.

        If Kafka cannot confirm the forwarded messages, nothing is committed.
        The bridge then goes back to the first change event of the failed
        stretch, waits (longer after each failure in a row), and the main loop
        reads and handles those events again. No change event can be lost this
        way; one may be forwarded twice (at-least-once).

        Returns:
            True if the position was committed (or there was nothing pending),
            False if the attempt failed and the bridge went back.
        """
        try:
            self._checkpoint_once()
        except Exception as error:  # noqa: BLE001 - any failure must be retried, not lose events
            if self._stop.is_set():
                # Stopping anyway: the uncommitted events are re-read on next start.
                logger.warning("Checkpoint failed while stopping; leaving the change events uncommitted: %s", error)
                self._forget_pending()
                return False
            logger.error("Checkpoint failed; going back and retrying in %.0f s: %s", self._retry_delay, error)
            self._rewind()
            self.sleep(self._retry_delay)
            self._retry_delay = min(self._retry_delay * 2, settings.RETRY_MAX_SECONDS)
            return False
        self._retry_delay = settings.RETRY_INITIAL_SECONDS
        return True

    def _checkpoint_once(self) -> None:
        """Make one attempt to confirm and commit the pending change events.

        The order is what makes delivery at-least-once:

            1. wait until Kafka has confirmed every forwarded message
            2. wait until every dead letter is confirmed
            3. commit the bridge's position in the CDC topic

        Raises:
            RuntimeError: if a forwarded message was not confirmed. The
                position is then NOT committed.
        """
        if not self._last_offsets:
            return

        unconfirmed = self.producer.flush(FLUSH_SECONDS)
        if unconfirmed or self._delivery_errors:
            errors, self._delivery_errors = self._delivery_errors, []
            raise RuntimeError(
                f"{unconfirmed} forwarded message(s) unconfirmed, {len(errors)} refused: {errors[:3]}"
            )
        # Raises if a dead letter could not be stored.
        self.dead_letter.flush()

        # Synchronous: when this returns, Kafka has stored the new position.
        self.kafka.commit(
            offsets=[
                TopicPartition(self.source_topic, partition, next_offset)
                for partition, next_offset in self._pending_offsets().items()
            ],
            asynchronous=False,
        )
        self._forget_pending()

    def _rewind(self) -> None:
        """Go back to the first uncommitted change event of each partition."""
        for partition, offset in self._first_offsets.items():
            self.kafka.seek(TopicPartition(self.source_topic, partition, offset))
        self._forget_pending()

    def _forget_pending(self) -> None:
        """Clear the record of uncommitted positions (after a commit or a rewind)."""
        self._first_offsets.clear()
        self._last_offsets.clear()
        self._delivery_errors.clear()

    def _on_partitions_revoked(self, consumer: Any, partitions: list[TopicPartition]) -> None:
        """Kafka callback: confirm and commit before the partition is taken away."""
        try:
            self._checkpoint_once()
        except Exception:  # noqa: BLE001 - a callback must not raise into the Kafka client
            # Not committed: whoever owns the partition next reads the events again.
            logger.exception("Checkpoint during rebalance failed; the change events will be re-read.")
            self._forget_pending()


def main() -> None:
    """Entry point: build the real bridge and run it until Ctrl+C."""
    # Log through a queue: see configure_logging for why this matters here.
    log_listener = configure_logging()

    bridge = CdcBridge(
        cdc_consumer=create_cdc_consumer(),
        target_producer=create_target_producer(),
        # Reuses the existing dead-letter publisher and the existing topic
        # order_events_dlq; nothing in the consumer package is modified.
        dead_letter=DeadLetterPublisher(),
    )

    def request_stop(signum: int, frame: Any) -> None:
        """Signal handler: turn Ctrl+C into an orderly stop."""
        logger.info("Stop requested (signal %d).", signum)
        bridge.stop()

    # SIGINT is Ctrl+C. SIGBREAK is Ctrl+Break and exists only on Windows.
    signal.signal(signal.SIGINT, request_stop)
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, request_stop)

    try:
        bridge.run()
    finally:
        # Write out the log lines that are still queued.
        log_listener.stop()


if __name__ == "__main__":
    main()
