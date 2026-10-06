"""Unit tests for handler.py (the Lambda entry point).

AWS is never called: a StubS3 records put_object calls, and the autouse fixture
makes any attempt to create a real boto3 client fail the test.
"""

import csv
import io

import pytest

import handler
from generator import COLUMNS


class StubS3:
    """Records put_object calls; never talks to AWS."""

    def __init__(self):
        self.calls = []

    def put_object(self, **kwargs):
        self.calls.append(kwargs)
        return {"ETag": '"abc123"'}


@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("S3_BUCKET", "test-bucket")
    for name in ("S3_LANDING_PREFIX", "ROWS_PER_FILE_MIN", "ROWS_PER_FILE_MAX", "DEFECT_RATE", "SEED_SALT"):
        monkeypatch.delenv(name, raising=False)
    # Guard: any attempt to build a real boto3 client fails the test.
    monkeypatch.setattr(handler, "_s3", lambda: pytest.fail("real S3 client used"))


def test_uploads_csv_to_expected_key():
    s3 = StubS3()
    result = handler.lambda_handler({"run_ts": "2026-10-05T14:20:00Z"}, None, s3_client=s3)

    assert len(s3.calls) == 1
    call = s3.calls[0]
    assert call["Bucket"] == "test-bucket"
    assert call["Key"] == "landing/orders/year=2026/month=10/day=05/orders_20261005_14.csv"
    assert call["ContentType"] == "text/csv"
    rows = list(csv.DictReader(io.StringIO(call["Body"].decode("utf-8"))))
    assert len(rows) == result["row_count"]
    assert list(rows[0].keys()) == list(COLUMNS)
    assert call["Metadata"]["row-count"] == str(result["row_count"])
    assert call["Metadata"]["defect-count"] == str(result["defect_count"])


def test_result_summary():
    result = handler.lambda_handler({"run_ts": "2026-10-05T14:00:00Z"}, None, s3_client=StubS3())
    assert result["status"] == "UPLOADED"
    assert result["batch_hour"] == "2026-10-05T14:00:00Z"
    assert result["etag"] == "abc123"
    assert result["defect_count"] == sum(result["defects_by_type"].values())
    assert result["defect_count"] > 0
    assert result["bytes"] > 0


def test_same_run_ts_uploads_identical_body():
    s3 = StubS3()
    handler.lambda_handler({"run_ts": "2026-10-05T14:00:00Z"}, None, s3_client=s3)
    handler.lambda_handler({"run_ts": "2026-10-05T14:45:00Z"}, None, s3_client=s3)
    assert s3.calls[0]["Key"] == s3.calls[1]["Key"]
    assert s3.calls[0]["Body"] == s3.calls[1]["Body"]


def test_dry_run_skips_upload():
    s3 = StubS3()
    result = handler.lambda_handler({"run_ts": "2026-10-05T14:00:00Z", "dry_run": True}, None, s3_client=s3)
    assert s3.calls == []
    assert result["status"] == "DRY_RUN"
    assert "etag" not in result


def test_scheduled_event_without_run_ts_generates_previous_hour(monkeypatch):
    from datetime import datetime, timezone

    import naming

    real = naming.resolve_batch_hour
    monkeypatch.setattr(
        handler,
        "resolve_batch_hour",
        lambda run_ts=None: real(run_ts, now=datetime(2026, 10, 5, 14, 5, tzinfo=timezone.utc)),
    )
    # EventBridge Scheduler's default payload carries no run_ts.
    result = handler.lambda_handler({}, None, s3_client=StubS3())
    assert result["key"].endswith("orders_20261005_13.csv")


def test_non_dict_event_is_treated_as_empty(monkeypatch):
    result = handler.lambda_handler(None, None, s3_client=StubS3())
    assert result["status"] == "UPLOADED"


def test_missing_bucket_raises(monkeypatch):
    monkeypatch.delenv("S3_BUCKET")
    with pytest.raises(ValueError, match="S3_BUCKET"):
        handler.lambda_handler({"run_ts": "2026-10-05T14:00:00Z"}, None, s3_client=StubS3())


def test_dry_run_works_without_bucket(monkeypatch):
    monkeypatch.delenv("S3_BUCKET")
    result = handler.lambda_handler({"run_ts": "2026-10-05T14:00:00Z", "dry_run": True}, None)
    assert result["status"] == "DRY_RUN"


def test_invalid_run_ts_raises():
    with pytest.raises(ValueError, match="run_ts"):
        handler.lambda_handler({"run_ts": "not-a-time"}, None, s3_client=StubS3())


def test_custom_prefix_from_env(monkeypatch):
    monkeypatch.setenv("S3_LANDING_PREFIX", "test/landing")
    result = handler.lambda_handler({"run_ts": "2026-10-05T14:00:00Z", "dry_run": True}, None)
    assert result["key"] == "test/landing/year=2026/month=10/day=05/orders_20261005_14.csv"
