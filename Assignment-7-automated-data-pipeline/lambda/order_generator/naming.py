"""Batch-hour resolution and deterministic S3 key naming.

Key format:
    <prefix>year=YYYY/month=MM/day=DD/orders_YYYYMMDD_HH.csv
All times are UTC. One file per business hour.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone


def parse_run_ts(value: str) -> datetime:
    """Parse an ISO-8601 timestamp; naive values are treated as UTC."""
    if not isinstance(value, str) or not value.strip():
        raise ValueError("run_ts must be a non-empty ISO-8601 string")
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise ValueError(f"run_ts is not a valid ISO-8601 timestamp: {value!r}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def floor_to_hour(ts: datetime) -> datetime:
    return ts.astimezone(timezone.utc).replace(minute=0, second=0, microsecond=0)


def resolve_batch_hour(run_ts: str | None = None, now: datetime | None = None) -> datetime:
    """Return the UTC business hour to generate.

    An explicit run_ts selects the hour it falls in. Without one, the most
    recently *completed* hour is used, so no generated order_ts is in the future
    when the scheduled run fires a few minutes past the hour.
    """
    if run_ts:
        return floor_to_hour(parse_run_ts(run_ts))
    current = now or datetime.now(timezone.utc)
    return floor_to_hour(current) - timedelta(hours=1)


def build_s3_key(batch_hour: datetime, prefix: str = "landing/orders/") -> str:
    hour = floor_to_hour(batch_hour)
    prefix = prefix if not prefix or prefix.endswith("/") else prefix + "/"
    return (
        f"{prefix}year={hour:%Y}/month={hour:%m}/day={hour:%d}/"
        f"orders_{hour:%Y%m%d_%H}.csv"
    )
