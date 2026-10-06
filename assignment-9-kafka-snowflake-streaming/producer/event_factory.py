"""
Builds synthetic order events for the producer.

This module is pure: it has no Kafka import and does no I/O, so it can be unit
tested without a broker. ``producer.py`` calls ``build_event`` once per message.

Schema versions (spec.md section 8.1) simulate Kafka "introducing new fields
at any time":

    v1  the base fields
    v2  v1 + payment_method, discount_pct
    v3  v2 + loyalty_tier, is_gift, shipping_address (a nested object)

Each higher version only ADDS fields. Nothing is renamed or removed, which is
the kind of change Snowflake schema evolution handles.
"""

from __future__ import annotations

import random
import uuid
from datetime import datetime, timezone
from typing import Any

# Lowest and highest schema version this factory can produce.
MIN_SCHEMA_VERSION = 1
MAX_SCHEMA_VERSION = 3

# Fields present in every version. Kept as a constant so the tests can check
# the exact field set of each version.
V1_FIELDS: tuple[str, ...] = (
    "event_id",
    "event_time",
    "order_id",
    "customer_id",
    "product",
    "quantity",
    "unit_price",
    "status",
)
# Fields added by version 2 and by version 3.
V2_NEW_FIELDS: tuple[str, ...] = ("payment_method", "discount_pct")
V3_NEW_FIELDS: tuple[str, ...] = ("loyalty_tier", "is_gift", "shipping_address")

# Sample values. All data is synthetic.
_PRODUCTS: tuple[tuple[str, float], ...] = (
    ("Wireless Mouse", 799.00),
    ("Mechanical Keyboard", 3499.00),
    ("USB-C Hub", 1899.00),
    ("27-inch Monitor", 15999.00),
    ("Laptop Stand", 1299.00),
    ("Webcam", 2499.00),
    ("Noise Cancelling Headphones", 8999.00),
    ("External SSD 1TB", 6499.00),
)
_STATUSES: tuple[str, ...] = ("CREATED", "PAID", "SHIPPED", "DELIVERED", "CANCELLED")
_PAYMENT_METHODS: tuple[str, ...] = ("UPI", "CREDIT_CARD", "DEBIT_CARD", "NET_BANKING", "COD")
_LOYALTY_TIERS: tuple[str, ...] = ("BRONZE", "SILVER", "GOLD", "PLATINUM")
_ADDRESSES: tuple[tuple[str, str, str], ...] = (
    ("Pune", "Maharashtra", "411001"),
    ("Mumbai", "Maharashtra", "400001"),
    ("Bengaluru", "Karnataka", "560001"),
    ("Hyderabad", "Telangana", "500001"),
    ("Chennai", "Tamil Nadu", "600001"),
    ("Delhi", "Delhi", "110001"),
)


def fields_for_version(schema_version: int) -> tuple[str, ...]:
    """Return the field names an event of ``schema_version`` contains.

    Raises:
        ValueError: if the version is outside the supported range.
    """
    if not MIN_SCHEMA_VERSION <= schema_version <= MAX_SCHEMA_VERSION:
        raise ValueError(
            f"schema_version must be between {MIN_SCHEMA_VERSION} and "
            f"{MAX_SCHEMA_VERSION}, got {schema_version}"
        )
    fields = V1_FIELDS
    if schema_version >= 2:
        fields += V2_NEW_FIELDS
    if schema_version >= 3:
        fields += V3_NEW_FIELDS
    return fields


def build_event(
    schema_version: int,
    sequence: int,
    rng: random.Random | None = None,
    now: datetime | None = None,
    extra_fields: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build one order event.

    Args:
        schema_version: 1, 2 or 3; decides which fields the event has.
        sequence: Running number of the message; used to build the order id.
        rng: Random generator. Passing a seeded one makes the output repeatable
            (the tests do this). Defaults to a fresh generator.
        now: Event time. Defaults to the current UTC time.
        extra_fields: Additional top-level fields to add to the event, used to
            introduce an arbitrary new field without changing this code.

    Returns:
        The event as a dictionary ready to be serialised to JSON.

    Raises:
        ValueError: if ``schema_version`` is not supported.
    """
    # Validates the version as a side effect.
    fields = fields_for_version(schema_version)
    rng = rng or random.Random()
    now = now or datetime.now(timezone.utc)

    product, unit_price = rng.choice(_PRODUCTS)
    event: dict[str, Any] = {
        # uuid4 built from the supplied generator so a seeded run is repeatable.
        "event_id": str(uuid.UUID(int=rng.getrandbits(128), version=4)),
        # ISO-8601 in UTC with a trailing "Z", millisecond precision.
        "event_time": now.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        # A small pool of order ids so that several events share an order,
        # which makes the per-key ordering of Kafka visible.
        "order_id": f"ORD-{100000 + sequence % 5000}",
        "customer_id": rng.randint(1, 500),
        "product": product,
        "quantity": rng.randint(1, 5),
        "unit_price": unit_price,
        "status": rng.choice(_STATUSES),
    }

    if schema_version >= 2:
        event["payment_method"] = rng.choice(_PAYMENT_METHODS)
        # Discount in percent, one decimal place.
        event["discount_pct"] = rng.choice((0.0, 5.0, 7.5, 10.0, 12.5, 15.0))

    if schema_version >= 3:
        city, state, pincode = rng.choice(_ADDRESSES)
        event["loyalty_tier"] = rng.choice(_LOYALTY_TIERS)
        event["is_gift"] = rng.random() < 0.2
        # A nested object: in Snowflake this becomes ONE column, not three.
        event["shipping_address"] = {"city": city, "state": state, "pincode": pincode}

    # Guard against this function and fields_for_version drifting apart.
    assert tuple(event) == fields, "build_event and fields_for_version disagree"

    if extra_fields:
        # Extra fields are applied last so they can also override a standard
        # field, which is how the type-conflict demo sends text in "quantity".
        event.update(extra_fields)

    return event
