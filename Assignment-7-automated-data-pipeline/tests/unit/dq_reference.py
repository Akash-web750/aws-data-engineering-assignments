"""Python reference implementation of the DQ rules in docs/architecture.md.

Used only by tests: generated clean rows must pass every rule, and each
deliberately corrupted row must fail the rule it was corrupted for. The
Snowflake SQL rules are checked against the same expectations.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone

from generator import REQUIRED_FIELDS, VALID_STATUSES

EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
NUMBER_RE = re.compile(r"^-?\d+(\.\d+)?$")


def _num(value: str) -> float | None:
    return float(value) if NUMBER_RE.match(value or "") else None


def _parse_ts(value: str) -> datetime | None:
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def dq_reasons(row: dict[str, str], seen_order_ids: set[str], now: datetime) -> list[str]:
    reasons: list[str] = []
    if any(not (row.get(f) or "").strip() for f in REQUIRED_FIELDS):
        reasons.append("MISSING_REQUIRED_FIELD")

    raw = {f: (row.get(f) or "").strip() for f in ("quantity", "unit_price", "amount")}
    nums = {f: _num(v) for f, v in raw.items()}
    if any(v and nums[f] is None for f, v in raw.items()):
        reasons.append("INVALID_NUMBER")
    qty, price, amount = nums["quantity"], nums["unit_price"], nums["amount"]
    if qty is not None and qty <= 0:
        reasons.append("INVALID_QUANTITY")
    if amount is not None and amount <= 0:
        reasons.append("INVALID_AMOUNT")
    if None not in (qty, price, amount) and abs(amount - qty * price) > 0.01:
        reasons.append("AMOUNT_MISMATCH")

    email = (row.get("customer_email") or "").strip()
    if email and not EMAIL_RE.match(email):
        reasons.append("INVALID_EMAIL")

    ts_raw = (row.get("order_ts") or "").strip()
    if ts_raw:
        ts = _parse_ts(ts_raw)
        if ts is None or ts > now:
            reasons.append("INVALID_TIMESTAMP")

    if row.get("order_status") not in VALID_STATUSES:
        reasons.append("INVALID_STATUS")

    order_id = (row.get("order_id") or "").strip()
    if order_id:
        if order_id in seen_order_ids:
            reasons.append("DUPLICATE_ORDER_ID")
        seen_order_ids.add(order_id)
    return reasons
