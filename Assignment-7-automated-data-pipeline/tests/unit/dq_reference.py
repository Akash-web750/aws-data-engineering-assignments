"""Simplified Python reference of the data quality rules, for unit tests only.

Purpose: prove at generation time that clean rows pass every rule and that each
deliberately corrupted row fails the rule it was corrupted for (labelled with
the generator's defect names, e.g. INVALID_EMAIL).

It is NOT a line-for-line copy of the production rules in Snowflake
(snowflake/04_data_quality_validation.sql / CURATED.V_ORDERS_DQ). Differences:
- required fields: the generator's 8 REQUIRED_FIELDS (Snowflake DQ01 checks all 15)
- "future" timestamp: compared with a caller-supplied `now` (Snowflake DQ09
  compares with the row's ingestion time, LOADED_AT_UTC)
- duplicates: first occurrence within the given row sequence (Snowflake DQ11
  uses arrival order across all loaded files)
The production rules were validated separately against the loaded data
(see docs/testing.md).
"""

from __future__ import annotations

import re
from datetime import datetime, timezone

from generator import REQUIRED_FIELDS, VALID_STATUSES

# Same local@domain.tld pattern as Snowflake DQ08 (REGEXP_LIKE matches the whole value).
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
# Plain decimal numbers only, so "12,50", "1O0", "two" and "N/A" are rejected.
NUMBER_RE = re.compile(r"^-?\d+(\.\d+)?$")


def _num(value: str) -> float | None:
    return float(value) if NUMBER_RE.match(value or "") else None


def _parse_ts(value: str) -> datetime | None:
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def dq_reasons(row: dict[str, str], seen_order_ids: set[str], now: datetime) -> list[str]:
    """Return every failed check for one row (all failures, like QUALITY_REASON).

    `seen_order_ids` is mutated: pass the same set for all rows of a batch so the
    duplicate check sees earlier rows.
    """
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
