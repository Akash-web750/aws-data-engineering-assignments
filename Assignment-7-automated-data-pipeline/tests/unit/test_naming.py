from datetime import datetime, timezone

import pytest

from naming import build_s3_key, floor_to_hour, parse_run_ts, resolve_batch_hour


def utc(*args):
    return datetime(*args, tzinfo=timezone.utc)


def test_s3_key_matches_agreed_format():
    assert (
        build_s3_key(utc(2026, 10, 5, 14))
        == "landing/orders/year=2026/month=10/day=05/orders_20261005_14.csv"
    )


def test_s3_key_zero_pads_month_day_hour():
    assert (
        build_s3_key(utc(2026, 1, 2, 3))
        == "landing/orders/year=2026/month=01/day=02/orders_20260102_03.csv"
    )


def test_s3_key_floors_minutes_and_normalises_prefix():
    key = build_s3_key(utc(2026, 10, 5, 14, 59, 59), prefix="custom/prefix")
    assert key == "custom/prefix/year=2026/month=10/day=05/orders_20261005_14.csv"


@pytest.mark.parametrize(
    "value, expected",
    [
        ("2026-10-05T14:00:00Z", utc(2026, 10, 5, 14)),
        ("2026-10-05T14:37:12z", utc(2026, 10, 5, 14, 37, 12)),
        ("2026-10-05T14:00:00", utc(2026, 10, 5, 14)),  # naive -> UTC
        ("2026-10-05T19:30:00+05:30", utc(2026, 10, 5, 14)),  # IST -> UTC
    ],
)
def test_parse_run_ts(value, expected):
    assert parse_run_ts(value) == expected


@pytest.mark.parametrize("value", ["", "   ", "yesterday", "2026-13-01T00:00:00Z", None, 123])
def test_parse_run_ts_rejects_invalid(value):
    with pytest.raises(ValueError):
        parse_run_ts(value)


def test_resolve_batch_hour_uses_explicit_run_ts():
    assert resolve_batch_hour("2026-10-01T05:42:00Z") == utc(2026, 10, 1, 5)


def test_resolve_batch_hour_defaults_to_previous_completed_hour():
    assert resolve_batch_hour(None, now=utc(2026, 10, 5, 14, 5)) == utc(2026, 10, 5, 13)
    assert resolve_batch_hour(None, now=utc(2026, 10, 5, 0, 5)) == utc(2026, 10, 4, 23)


def test_key_is_deterministic_for_any_time_within_the_hour():
    keys = {build_s3_key(floor_to_hour(utc(2026, 10, 5, 14, m))) for m in (0, 15, 59)}
    assert len(keys) == 1
