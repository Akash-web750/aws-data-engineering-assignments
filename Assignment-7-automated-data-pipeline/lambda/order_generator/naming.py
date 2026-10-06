"""Batch-hour resolution and deterministic S3 key naming.

Key format:
    <prefix>year=YYYY/month=MM/day=DD/orders_YYYYMMDD_HH.csv
All times are UTC. One file per business hour.

Why this layout:
- The key is a pure function of the batch hour, so re-running an hour always
  targets the same object. Combined with deterministic content (generator.py),
  a retry rewrites identical bytes instead of creating a second file.
- Hive-style year=/month=/day= folders keep listings and troubleshooting by
  date simple and match the Snowflake stage prefix (landing/orders/).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone


def parse_run_ts(value: str) -> datetime:
    """Parse an ISO-8601 timestamp; naive values are treated as UTC."""
    # Reject non-strings explicitly: an event like {"run_ts": 123} must fail with
    # a clear message rather than an AttributeError deep inside datetime parsing.
    if not isinstance(value, str) or not value.strip():
        raise ValueError("run_ts must be a non-empty ISO-8601 string")
    text = value.strip()
    # datetime.fromisoformat() on Python < 3.11 does not accept the "Z" suffix,
    # so normalise it to an explicit +00:00 offset (works on 3.10 and 3.12).
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise ValueError(f"run_ts is not a valid ISO-8601 timestamp: {value!r}") from exc
    # A timestamp without an offset is interpreted as UTC (never local time), so
    # the same event produces the same hour on any machine.
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def floor_to_hour(ts: datetime) -> datetime:
    """Truncate to the start of the UTC hour (the unit of one generated file)."""
    return ts.astimezone(timezone.utc).replace(minute=0, second=0, microsecond=0)


def resolve_batch_hour(run_ts: str | None = None, now: datetime | None = None) -> datetime:
    """Return the UTC business hour to generate.

    An explicit run_ts selects the hour it falls in. Without one, the most
    recently *completed* hour is used, so no generated order_ts is in the future
    when the scheduled run fires a few minutes past the hour.
    """
    if run_ts:
        return floor_to_hour(parse_run_ts(run_ts))
    # `now` is injectable so tests can pin the clock; production uses real UTC time.
    current = now or datetime.now(timezone.utc)
    return floor_to_hour(current) - timedelta(hours=1)


def build_s3_key(batch_hour: datetime, prefix: str = "landing/orders/") -> str:
    """Build the deterministic S3 key for one batch hour."""
    hour = floor_to_hour(batch_hour)
    # Tolerate a prefix configured without the trailing slash.
    prefix = prefix if not prefix or prefix.endswith("/") else prefix + "/"
    return (
        f"{prefix}year={hour:%Y}/month={hour:%m}/day={hour:%d}/"
        f"orders_{hour:%Y%m%d_%H}.csv"
    )
