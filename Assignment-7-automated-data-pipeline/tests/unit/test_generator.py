import csv
import io
from datetime import datetime, timedelta, timezone

import pytest

from config import GeneratorConfig
from dq_reference import EMAIL_RE, dq_reasons
from generator import (
    COLUMNS,
    DEFECT_TYPES,
    VALID_STATUSES,
    generate_batch,
    rows_to_csv,
)

HOUR = datetime(2026, 10, 5, 14, tzinfo=timezone.utc)
# One week of hourly batches (168 files) for statistical checks.
WEEK = [datetime(2026, 9, 28, tzinfo=timezone.utc) + timedelta(hours=h) for h in range(168)]


def check_reasons(batch):
    seen: set[str] = set()
    now = batch.batch_hour + timedelta(days=1)
    return [dq_reasons(row, seen, now) for row in batch.rows]


# ---------- determinism ----------

def test_same_hour_produces_identical_bytes():
    assert generate_batch(HOUR).to_csv_bytes() == generate_batch(HOUR).to_csv_bytes()


def test_any_time_within_the_hour_is_the_same_batch():
    assert (
        generate_batch(HOUR.replace(minute=37)).to_csv_bytes()
        == generate_batch(HOUR).to_csv_bytes()
    )


def test_different_hours_produce_different_content():
    assert generate_batch(HOUR).to_csv_bytes() != generate_batch(HOUR + timedelta(hours=1)).to_csv_bytes()


def test_seed_salt_changes_content():
    assert (
        generate_batch(HOUR, GeneratorConfig(seed_salt="other")).to_csv_bytes()
        != generate_batch(HOUR).to_csv_bytes()
    )


# ---------- CSV structure ----------

def test_csv_header_and_column_count():
    text = generate_batch(HOUR).to_csv_bytes().decode("utf-8")
    lines = text.splitlines()
    assert lines[0] == ",".join(COLUMNS)
    parsed = list(csv.reader(io.StringIO(text)))
    assert all(len(r) == len(COLUMNS) for r in parsed)


def test_csv_round_trip_preserves_values():
    batch = generate_batch(HOUR)
    parsed = list(csv.DictReader(io.StringIO(batch.to_csv_bytes().decode("utf-8"))))
    assert parsed == batch.rows


def test_csv_quotes_values_containing_commas():
    row = dict.fromkeys(COLUMNS, "x")
    row["customer_name"] = "Doe, Jane"
    text = rows_to_csv([row])
    assert '"Doe, Jane"' in text
    assert next(csv.DictReader(io.StringIO(text)))["customer_name"] == "Doe, Jane"


def test_csv_uses_unix_line_endings_and_utf8():
    data = generate_batch(HOUR).to_csv_bytes()
    assert b"\r\n" not in data
    data.decode("utf-8")


# ---------- volume ----------

@pytest.mark.parametrize("hour", WEEK[::7])
def test_row_count_within_configured_bounds(hour):
    config = GeneratorConfig()
    assert config.rows_min <= generate_batch(hour, config).row_count <= config.rows_max


def test_volume_follows_daily_pattern():
    # 14:00 UTC = 19:30 IST (peak) vs 21:00 UTC = 02:30 IST (night)
    day = datetime(2026, 10, 6, tzinfo=timezone.utc)
    peak = generate_batch(day.replace(hour=14)).row_count
    night = generate_batch(day.replace(hour=21)).row_count
    assert peak > night


def test_custom_row_range_respected():
    config = GeneratorConfig(rows_min=10, rows_max=12)
    assert 10 <= generate_batch(HOUR, config).row_count <= 12


# ---------- valid records ----------

def test_clean_rows_pass_every_dq_rule():
    for hour in WEEK[::12]:
        batch = generate_batch(hour)
        for index, reasons in enumerate(check_reasons(batch)):
            if index not in batch.defects:
                assert reasons == [], (hour, index, batch.rows[index], reasons)


def test_clean_row_field_values_are_realistic():
    batch = generate_batch(HOUR)
    for index, row in enumerate(batch.rows):
        if index in batch.defects:
            continue
        assert row["order_id"].startswith("ORD-2026100514-")
        assert row["batch_ts"] == "2026-10-05T14:00:00Z"
        assert row["order_ts"].startswith("2026-10-05T14:")
        assert row["currency"] == "INR"
        assert row["order_status"] in VALID_STATUSES
        assert EMAIL_RE.match(row["customer_email"])
        assert 1 <= int(row["quantity"]) <= 5
        assert abs(float(row["amount"]) - int(row["quantity"]) * float(row["unit_price"])) < 0.005
        assert float(row["unit_price"]) > 0


def test_clean_order_ids_are_unique():
    batch = generate_batch(HOUR)
    ids = [r["order_id"] for i, r in enumerate(batch.rows) if batch.defects.get(i) != "DUPLICATE_ORDER_ID"]
    assert len(ids) == len(set(ids))


# ---------- deliberate DQ defects ----------

def test_every_defective_row_fails_its_own_rule():
    for hour in WEEK:
        batch = generate_batch(hour)
        reasons = check_reasons(batch)
        for index, defect in batch.defects.items():
            assert defect in reasons[index], (hour, index, defect, batch.rows[index], reasons[index])


def test_defect_rate_is_about_eight_percent():
    rows = defects = 0
    for hour in WEEK:
        batch = generate_batch(hour)
        rows += batch.row_count
        defects += batch.defect_count
    assert 0.07 <= defects / rows <= 0.09


def test_each_file_contains_defects_and_a_clean_first_row():
    for hour in WEEK[::6]:
        batch = generate_batch(hour)
        assert batch.defect_count >= 1
        assert 0 not in batch.defects


def test_all_defect_types_occur_over_a_week():
    seen = set()
    for hour in WEEK:
        seen.update(generate_batch(hour).defects.values())
    assert seen == set(DEFECT_TYPES)


def test_duplicates_reuse_an_earlier_clean_order_id():
    found = 0
    for hour in WEEK:
        batch = generate_batch(hour)
        for index, defect in batch.defects.items():
            if defect != "DUPLICATE_ORDER_ID":
                continue
            found += 1
            donors = [
                i for i in range(index)
                if batch.rows[i]["order_id"] == batch.rows[index]["order_id"] and i not in batch.defects
            ]
            assert donors, (hour, index)
    assert found > 0


def test_defect_counts_summary_matches_defects():
    batch = generate_batch(HOUR)
    assert sum(batch.defect_counts().values()) == batch.defect_count


def test_zero_defect_rate_produces_only_clean_rows():
    batch = generate_batch(HOUR, GeneratorConfig(defect_rate=0.0))
    assert batch.defects == {}
    assert all(r == [] for r in check_reasons(batch))


# ---------- configuration ----------

@pytest.mark.parametrize(
    "kwargs",
    [{"rows_min": 0}, {"rows_min": 50, "rows_max": 10}, {"defect_rate": -0.1}, {"defect_rate": 0.9}],
)
def test_invalid_config_rejected(kwargs):
    with pytest.raises(ValueError):
        GeneratorConfig(**kwargs)


def test_config_from_env(monkeypatch):
    monkeypatch.setenv("S3_BUCKET", "my-bucket")
    monkeypatch.setenv("ROWS_PER_FILE_MIN", "5")
    monkeypatch.setenv("ROWS_PER_FILE_MAX", "9")
    monkeypatch.setenv("DEFECT_RATE", "0.2")
    config = GeneratorConfig.from_env()
    assert (config.bucket, config.rows_min, config.rows_max, config.defect_rate) == ("my-bucket", 5, 9, 0.2)
    assert config.landing_prefix == "landing/orders/"
