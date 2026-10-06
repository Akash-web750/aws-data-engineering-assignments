"""Deterministic, realistic e-commerce order generator.

Every batch hour is seeded from a hash of (seed_salt, hour), so generating the
same hour twice yields byte-identical CSV content. About `defect_rate` of the
rows are deliberately corrupted so the Snowflake data quality rules always
have something to catch. The defect codes match the DQ rule codes in
docs/architecture.md.
"""

from __future__ import annotations

import csv
import hashlib
import io
import random
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from config import GeneratorConfig
from naming import floor_to_hour

GENERATOR_VERSION = "1.0.0"

COLUMNS = (
    "order_id",
    "order_ts",
    "customer_id",
    "customer_name",
    "customer_email",
    "product_id",
    "product_category",
    "quantity",
    "unit_price",
    "amount",
    "currency",
    "payment_method",
    "order_status",
    "city",
    "batch_ts",
)

REQUIRED_FIELDS = (
    "order_id",
    "order_ts",
    "customer_id",
    "customer_email",
    "product_id",
    "quantity",
    "unit_price",
    "amount",
)

VALID_STATUSES = ("PLACED", "SHIPPED", "DELIVERED", "CANCELLED", "RETURNED")

DEFECT_TYPES = (
    "MISSING_REQUIRED_FIELD",
    "INVALID_NUMBER",
    "INVALID_QUANTITY",
    "INVALID_AMOUNT",
    "AMOUNT_MISMATCH",
    "INVALID_EMAIL",
    "INVALID_TIMESTAMP",
    "INVALID_STATUS",
    "DUPLICATE_ORDER_ID",
)

_FIRST_NAMES = (
    "Aarav", "Vivaan", "Aditya", "Arjun", "Sai", "Reyansh", "Krishna", "Ishaan",
    "Rohan", "Kabir", "Priya", "Ananya", "Diya", "Isha", "Kavya", "Meera",
    "Neha", "Pooja", "Riya", "Sneha", "Tanvi", "Aisha", "Fatima", "Joseph",
)
_LAST_NAMES = (
    "Sharma", "Verma", "Patel", "Reddy", "Iyer", "Nair", "Kulkarni", "Deshmukh",
    "Gupta", "Singh", "Joshi", "Mehta", "Rao", "Khan", "D'Souza", "Banerjee",
)
_EMAIL_DOMAINS = ("gmail.com", "yahoo.co.in", "outlook.com", "rediffmail.com", "example.in")
_CITIES = (
    ("Mumbai", 14), ("Delhi", 13), ("Bengaluru", 13), ("Pune", 10), ("Hyderabad", 10),
    ("Chennai", 9), ("Kolkata", 8), ("Ahmedabad", 7), ("Jaipur", 5), ("Lucknow", 4),
    ("Kochi", 4), ("Indore", 3),
)
_PAYMENT_METHODS = (("UPI", 45), ("CARD", 25), ("NET_BANKING", 10), ("COD", 12), ("WALLET", 8))
_STATUSES = (("PLACED", 55), ("SHIPPED", 20), ("DELIVERED", 15), ("CANCELLED", 6), ("RETURNED", 4))
# category: (sku code, min price, max price, popularity weight)
_CATEGORIES = {
    "Electronics": ("EL", 999, 49999, 18),
    "Fashion": ("FA", 299, 4999, 22),
    "Home & Kitchen": ("HK", 199, 9999, 16),
    "Beauty": ("BE", 149, 2499, 12),
    "Books": ("BK", 99, 1499, 10),
    "Sports": ("SP", 299, 7999, 8),
    "Grocery": ("GR", 49, 999, 14),
}
# Relative order volume by IST hour of day (0-23): quiet nights, evening peak.
_IST_HOUR_WEIGHT = (
    0.30, 0.20, 0.15, 0.10, 0.10, 0.15, 0.25, 0.40, 0.55, 0.70, 0.80, 0.85,
    0.90, 0.85, 0.80, 0.80, 0.85, 0.90, 0.95, 1.00, 1.00, 0.90, 0.70, 0.50,
)
_IST_OFFSET = timedelta(hours=5, minutes=30)


def _build_catalog() -> tuple[tuple[str, str, float], ...]:
    """Fixed product catalog: (product_id, category, unit_price). Same on every run."""
    rng = random.Random(20261005)
    products = []
    for category, (code, low, high, _weight) in _CATEGORIES.items():
        for n in range(1, 7):
            price = round(rng.uniform(low, high)) - 0.01 if high > 1000 else round(rng.uniform(low, high), 2)
            products.append((f"SKU-{code}{n:03d}", category, max(price, float(low))))
    return tuple(products)


CATALOG = _build_catalog()
_CATEGORY_WEIGHT = {name: spec[3] for name, spec in _CATEGORIES.items()}
_PRODUCT_WEIGHTS = tuple(_CATEGORY_WEIGHT[category] for _, category, _ in CATALOG)


@dataclass
class GeneratedBatch:
    batch_hour: datetime
    rows: list[dict[str, str]]
    # row index -> defect code, for rows that were deliberately corrupted
    defects: dict[int, str] = field(default_factory=dict)

    @property
    def row_count(self) -> int:
        return len(self.rows)

    @property
    def defect_count(self) -> int:
        return len(self.defects)

    def defect_counts(self) -> dict[str, int]:
        return dict(sorted(Counter(self.defects.values()).items()))

    def to_csv_bytes(self) -> bytes:
        return rows_to_csv(self.rows).encode("utf-8")


def seed_for_hour(batch_hour: datetime, salt: str) -> int:
    key = f"{salt}|{floor_to_hour(batch_hour):%Y-%m-%dT%H}".encode("utf-8")
    return int.from_bytes(hashlib.sha256(key).digest()[:8], "big")


def _weighted(rng: random.Random, options: tuple[tuple[str, int], ...]) -> str:
    values, weights = zip(*options)
    return rng.choices(values, weights=weights, k=1)[0]


def _ts(value: datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def row_count_for_hour(rng: random.Random, batch_hour: datetime, config: GeneratorConfig) -> int:
    ist = batch_hour + _IST_OFFSET
    factor = _IST_HOUR_WEIGHT[ist.hour]
    if ist.weekday() >= 5:  # weekend bump
        factor = min(1.0, factor * 1.15)
    span = config.rows_max - config.rows_min
    jitter = rng.uniform(-0.08, 0.08) * span
    count = round(config.rows_min + factor * span + jitter)
    return max(config.rows_min, min(config.rows_max, count))


def _valid_row(rng: random.Random, batch_hour: datetime, seq: int) -> dict[str, str]:
    first, last = rng.choice(_FIRST_NAMES), rng.choice(_LAST_NAMES)
    customer_num = rng.randint(10000, 99999)
    local_last = "".join(ch for ch in last.lower() if ch.isalpha())
    email = f"{first.lower()}.{local_last}{customer_num % 1000}@{rng.choice(_EMAIL_DOMAINS)}"
    product_id, category, unit_price = rng.choices(CATALOG, weights=_PRODUCT_WEIGHTS, k=1)[0]
    quantity = rng.choices((1, 2, 3, 4, 5), weights=(60, 22, 10, 5, 3), k=1)[0]
    order_ts = batch_hour + timedelta(seconds=rng.randint(0, 3599))
    return {
        "order_id": f"ORD-{batch_hour:%Y%m%d%H}-{seq:05d}",
        "order_ts": _ts(order_ts),
        "customer_id": f"CUST-{customer_num}",
        "customer_name": f"{first} {last}",
        "customer_email": email,
        "product_id": product_id,
        "product_category": category,
        "quantity": str(quantity),
        "unit_price": f"{unit_price:.2f}",
        "amount": f"{quantity * unit_price:.2f}",
        "currency": "INR",
        "payment_method": _weighted(rng, _PAYMENT_METHODS),
        "order_status": _weighted(rng, _STATUSES),
        "city": _weighted(rng, _CITIES),
        "batch_ts": _ts(batch_hour),
    }


def _apply_defect(
    rng: random.Random, row: dict[str, str], defect: str, donor_order_id: str
) -> None:
    """Corrupt `row` in place so that DQ rule `defect` fails."""
    if defect == "MISSING_REQUIRED_FIELD":
        row[rng.choice(REQUIRED_FIELDS)] = ""
    elif defect == "INVALID_NUMBER":
        target = rng.choice(("quantity", "unit_price", "amount"))
        row[target] = rng.choice(("two", "N/A", "12,50", "1O0"))
    elif defect == "INVALID_QUANTITY":
        quantity = rng.choice((0, -1, -2))
        row["quantity"] = str(quantity)
        row["amount"] = f"{quantity * float(row['unit_price']):.2f}"
    elif defect == "INVALID_AMOUNT":
        row["amount"] = rng.choice(("0.00", f"-{row['amount']}"))
    elif defect == "AMOUNT_MISMATCH":
        row["amount"] = f"{float(row['amount']) + rng.choice((50, 100, 250, 500)):.2f}"
    elif defect == "INVALID_EMAIL":
        local, _, domain = row["customer_email"].partition("@")
        row["customer_email"] = rng.choice(
            (f"{local}@", f"{local}{domain}", f"{local}@@{domain}", f"{local} @{domain}", f"{local}@{domain.split('.')[0]}")
        )
    elif defect == "INVALID_TIMESTAMP":
        if rng.random() < 0.5:
            row["order_ts"] = rng.choice(("2026-13-45T25:61:00Z", "not-a-date", "05/10/2026 14:30"))
        else:  # far enough ahead to stay "future" for any backfilled test data
            future = datetime.strptime(row["order_ts"], "%Y-%m-%dT%H:%M:%SZ") + timedelta(days=365)
            row["order_ts"] = _ts(future)
    elif defect == "INVALID_STATUS":
        row["order_status"] = rng.choice(("UNKNOWN", "PENDING_PAYMENT", "placed?", "DISPATCHED"))
    elif defect == "DUPLICATE_ORDER_ID":
        row["order_id"] = donor_order_id
    else:
        raise ValueError(f"unknown defect type: {defect}")


def generate_batch(batch_hour: datetime, config: GeneratorConfig | None = None) -> GeneratedBatch:
    config = config or GeneratorConfig()
    hour = floor_to_hour(batch_hour)
    rng = random.Random(seed_for_hour(hour, config.seed_salt))

    count = row_count_for_hour(rng, hour, config)
    rows = [_valid_row(rng, hour, seq) for seq in range(1, count + 1)]

    n_defects = round(count * config.defect_rate)
    if config.defect_rate > 0 and count > 1:
        n_defects = max(1, n_defects)
    n_defects = min(n_defects, count - 1)  # row 0 always stays clean

    # Row 0 is never corrupted, so every DUPLICATE_ORDER_ID has a clean donor.
    defect_indices = sorted(rng.sample(range(1, count), n_defects)) if n_defects else []
    defects: dict[int, str] = {}
    for index in defect_indices:
        defect = rng.choice(DEFECT_TYPES)
        clean_earlier = [i for i in range(index) if i not in defects]
        donor = rows[rng.choice(clean_earlier)]["order_id"]
        _apply_defect(rng, rows[index], defect, donor)
        defects[index] = defect

    return GeneratedBatch(batch_hour=hour, rows=rows, defects=defects)


def rows_to_csv(rows: list[dict[str, str]]) -> str:
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=COLUMNS, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
    writer.writeheader()
    writer.writerows(rows)
    return buffer.getvalue()
