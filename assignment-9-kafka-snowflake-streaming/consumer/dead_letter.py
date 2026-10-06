"""
Dead-letter handling for the consumer.

A message the consumer cannot turn into a record (not JSON, not an object,
unusable field names) must not stop the pipeline and must not be thrown away.
It is copied, unchanged, to a separate Kafka topic together with the reason,
so it can be inspected and replayed later.
"""

from __future__ import annotations

import logging

from confluent_kafka import KafkaError, Message, Producer

from config import settings

logger = logging.getLogger("consumer.dead_letter")


class DeadLetterPublisher:
    """Publishes rejected messages to the dead-letter topic."""

    def __init__(self, topic: str | None = None) -> None:
        """Create the Kafka producer used for dead-letter messages.

        Args:
            topic: Dead-letter topic name. Defaults to ``KAFKA_DLQ_TOPIC``.
        """
        self.topic = topic or settings.KAFKA_DLQ_TOPIC
        self.published = 0
        self._failed = 0
        self._producer = Producer(
            {
                "bootstrap.servers": settings.KAFKA_BOOTSTRAP_SERVERS,
                # The local broker listens on IPv4 only (see producer.py).
                "broker.address.family": "v4",
                # Same safety settings as the main producer: no duplicates
                # from retries, and confirmation only after a safe write.
                "enable.idempotence": True,
                "client.id": "order-events-dead-letter",
            }
        )

    def _on_delivery(self, error: KafkaError | None, message: Message) -> None:
        """Record whether the broker accepted a dead-letter message."""
        if error is not None:
            self._failed += 1
            logger.error("Dead-letter delivery failed: %s", error)

    def publish(self, message: Message, reason: str) -> None:
        """Queue one rejected message for the dead-letter topic.

        The original key and value are kept byte-for-byte. Where it came from
        and why it was rejected travel as message headers, so the value itself
        stays exactly as the producer sent it.

        Args:
            message: The Kafka message that was rejected.
            reason: Human-readable explanation of the rejection.
        """
        self._producer.produce(
            self.topic,
            key=message.key(),
            value=message.value(),
            headers={
                "error": reason.encode("utf-8"),
                "source_topic": message.topic().encode("utf-8"),
                "source_partition": str(message.partition()).encode("utf-8"),
                "source_offset": str(message.offset()).encode("utf-8"),
            },
            on_delivery=self._on_delivery,
        )
        self.published += 1
        logger.warning(
            "Rejected message %s[%d]@%d sent to %s: %s",
            message.topic(), message.partition(), message.offset(), self.topic, reason,
        )

    def flush(self, timeout: float = 30.0) -> None:
        """Wait until every queued dead-letter message is confirmed.

        The consumer calls this BEFORE committing offsets. Committing first
        could lose a rejected message if the program stopped in between.

        Raises:
            RuntimeError: if messages are still unconfirmed after ``timeout``
                seconds, or the broker rejected any. The consumer then does
                not commit, so the messages are read and rejected again.
        """
        remaining = self._producer.flush(timeout)
        if remaining or self._failed:
            failed, self._failed = self._failed, 0
            raise RuntimeError(
                f"Dead-letter publishing incomplete: {remaining} unconfirmed, {failed} failed"
            )
