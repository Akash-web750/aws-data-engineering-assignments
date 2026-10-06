"""
Kafka producer: sends synthetic order events to the Kafka topic continuously.

Run from the project root:

    python -m producer.producer --rate 5
    python -m producer.producer --rate 5 --evolve-every 300
    python -m producer.producer --schema-version 2 --count 100
    python -m producer.producer --extra-field campaign=diwali
    python -m producer.producer --type-conflict-demo

Without ``--count`` it runs until Ctrl+C. New fields can be introduced at any
time by starting at a higher ``--schema-version``, by ``--evolve-every`` or by
``--extra-field``; this is what exercises schema evolution in Snowflake.

The events themselves are built by ``event_factory.py``; this file only deals
with the command line and with Kafka.
"""

from __future__ import annotations

import argparse
import json
import logging
import time
from typing import Any

from confluent_kafka import KafkaError, Message, Producer

from config import settings
from producer.event_factory import MAX_SCHEMA_VERSION, MIN_SCHEMA_VERSION, build_event

logger = logging.getLogger("producer")

# Text sent as a deliberately malformed message by --bad-every. It is not
# valid JSON, so the consumer must route it to the dead-letter topic.
MALFORMED_MESSAGE = b'{"event_id": "broken", "quantity": '


class DeliveryStats:
    """Counts delivery reports so the producer can print a summary at the end."""

    def __init__(self) -> None:
        """Start with nothing delivered and nothing failed."""
        self.delivered = 0
        self.failed = 0

    def on_delivery(self, error: KafkaError | None, message: Message) -> None:
        """Kafka calls this once per message when the broker confirms or rejects it.

        Args:
            error: ``None`` when the broker stored the message, otherwise the reason.
            message: The message the report is about.
        """
        if error is not None:
            self.failed += 1
            logger.error("Delivery failed for key %s: %s", message.key(), error)
        else:
            self.delivered += 1


def parse_extra_field(text: str) -> tuple[str, Any]:
    """Turn ``name=value`` from the command line into a field name and a value.

    The value is read as JSON when possible, so ``n=5`` gives the number 5,
    ``flag=true`` gives a boolean and ``o={"a":1}`` gives an object. Anything
    that is not valid JSON is kept as plain text (``campaign=diwali``).

    Raises:
        argparse.ArgumentTypeError: if the text has no ``=`` or an empty name.
    """
    name, separator, raw_value = text.partition("=")
    if not separator or not name.strip():
        raise argparse.ArgumentTypeError(f"--extra-field expects name=value, got {text!r}")
    try:
        value: Any = json.loads(raw_value)
    except json.JSONDecodeError:
        value = raw_value
    return name.strip(), value


def build_arg_parser() -> argparse.ArgumentParser:
    """Define the producer's command-line options."""
    parser = argparse.ArgumentParser(description="Send synthetic order events to Kafka.")
    parser.add_argument("--rate", type=float, default=5.0, help="Messages per second (default 5).")
    parser.add_argument(
        "--count", type=int, default=None,
        help="Stop after this many messages. Default: run until Ctrl+C.",
    )
    parser.add_argument(
        "--schema-version", type=int, default=MIN_SCHEMA_VERSION,
        choices=range(MIN_SCHEMA_VERSION, MAX_SCHEMA_VERSION + 1),
        help="Schema version to start with (default 1).",
    )
    parser.add_argument(
        "--evolve-every", type=int, default=None,
        help="Move to the next schema version after this many messages.",
    )
    parser.add_argument(
        "--extra-field", type=parse_extra_field, action="append", default=[],
        metavar="NAME=VALUE", help="Add a new field to every message. Repeatable.",
    )
    parser.add_argument(
        "--bad-every", type=int, default=None,
        help="Send a malformed (non-JSON) message every N messages, to exercise the dead-letter path.",
    )
    parser.add_argument(
        "--type-conflict-demo", action="store_true",
        help="Send exactly three messages (valid, text in 'quantity', valid) and exit.",
    )
    parser.add_argument("--topic", default=settings.KAFKA_TOPIC, help="Topic to write to.")
    return parser


def create_producer() -> Producer:
    """Create the Kafka producer client with safe delivery settings."""
    return Producer(
        {
            "bootstrap.servers": settings.KAFKA_BOOTSTRAP_SERVERS,
            # The local broker listens on IPv4 only. Without this, "localhost"
            # is first tried over IPv6 on Windows and every connection waits
            # about two seconds for that attempt to fail.
            "broker.address.family": "v4",
            # Idempotence makes the broker discard duplicates caused by the
            # client's own retries, and implies acks=all (the broker confirms
            # only after the message is safely written).
            "enable.idempotence": True,
            # Wait up to 50 ms to group messages into one request: fewer,
            # larger requests with a delay nobody notices.
            "linger.ms": 50,
            # Name shown in broker logs for this client.
            "client.id": "order-events-producer",
        }
    )


def send_event(producer: Producer, topic: str, event: dict[str, Any], stats: DeliveryStats) -> None:
    """Serialise one event to JSON and hand it to the Kafka client.

    The message key is the order id, so all events of one order go to the same
    partition and stay in order.
    """
    producer.produce(
        topic,
        key=str(event.get("order_id", "")).encode("utf-8"),
        value=json.dumps(event).encode("utf-8"),
        on_delivery=stats.on_delivery,
    )
    # poll(0) lets the client run delivery callbacks without waiting.
    producer.poll(0)


def run_type_conflict_demo(producer: Producer, topic: str, stats: DeliveryStats) -> None:
    """Send valid -> invalid type -> valid, all with the same key.

    The same key keeps the three messages in one partition and in this order.
    The middle message carries text in ``quantity``, which is a NUMBER column
    in Snowflake, so Snowflake must reject that one row and load the other two.
    """
    shared_order = {"order_id": "ORD-TYPE-CONFLICT"}
    send_event(producer, topic, build_event(1, 1, extra_fields=shared_order), stats)
    send_event(
        producer, topic,
        build_event(1, 2, extra_fields={**shared_order, "quantity": "not-a-number"}),
        stats,
    )
    send_event(producer, topic, build_event(1, 3, extra_fields=shared_order), stats)
    logger.info("Type-conflict demo: sent valid, invalid-type, valid.")


def run(args: argparse.Namespace) -> DeliveryStats:
    """Run the send loop described by the command-line arguments.

    Returns:
        The delivery counters, after every message has been confirmed or failed.
    """
    stats = DeliveryStats()
    producer = create_producer()
    extra_fields: dict[str, Any] = dict(args.extra_field)

    try:
        if args.type_conflict_demo:
            run_type_conflict_demo(producer, args.topic, stats)
            return stats

        schema_version: int = args.schema_version
        # Seconds between two messages; rate is messages per second.
        interval = 1.0 / args.rate if args.rate > 0 else 0.0
        sent = 0
        logger.info(
            "Producing to %s at %.1f msg/s, schema v%d%s. Ctrl+C to stop.",
            args.topic, args.rate, schema_version,
            f", extra fields {sorted(extra_fields)}" if extra_fields else "",
        )

        while args.count is None or sent < args.count:
            started = time.monotonic()
            sent += 1

            if args.bad_every and sent % args.bad_every == 0:
                # Deliberately broken message for the dead-letter path.
                producer.produce(args.topic, key=b"bad", value=MALFORMED_MESSAGE, on_delivery=stats.on_delivery)
                producer.poll(0)
            else:
                send_event(producer, args.topic, build_event(schema_version, sent, extra_fields=extra_fields), stats)

            # Schema evolution on a schedule: after every N messages, start
            # sending the next version's additional fields.
            if args.evolve_every and sent % args.evolve_every == 0 and schema_version < MAX_SCHEMA_VERSION:
                schema_version += 1
                logger.info("After %d messages: now producing schema v%d (new fields added).", sent, schema_version)

            if sent % 50 == 0:
                logger.info("Sent %d messages (schema v%d).", sent, schema_version)

            # Sleep for the rest of the interval to hold the requested rate.
            remaining = interval - (time.monotonic() - started)
            if remaining > 0:
                time.sleep(remaining)
    except KeyboardInterrupt:
        logger.info("Stopping on Ctrl+C.")
    finally:
        # flush() blocks until every queued message is confirmed or has
        # failed, so no message is lost when the program exits.
        not_sent = producer.flush(30)
        if not_sent:
            logger.error("%d messages were still unconfirmed after 30 s.", not_sent)
        logger.info("Done. Delivered %d, failed %d.", stats.delivered, stats.failed)
    return stats


def main() -> None:
    """Entry point: configure logging, read the command line, run the producer."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    args = build_arg_parser().parse_args()
    if args.rate <= 0:
        raise SystemExit("--rate must be greater than zero")
    run(args)


if __name__ == "__main__":
    main()
