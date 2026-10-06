"""AWS Lambda entry point: generate one hourly order file and upload it to S3.

Handler: handler.lambda_handler

Event (all optional):
    {"run_ts": "2026-10-05T14:00:00Z"}   generate that hour (backfill / tests)
    {"dry_run": true}                     build the file but skip the upload

With no run_ts, the previous completed UTC hour is generated (the schedule
fires a few minutes past each hour). Re-running an hour rewrites identical
bytes to the same key, so Snowpipe's load history skips it.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from config import GeneratorConfig
from generator import GENERATOR_VERSION, generate_batch
from naming import build_s3_key, resolve_batch_hour

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_s3_client = None


def _s3():
    """Create the S3 client once per container (boto3 ships with the Lambda runtime)."""
    global _s3_client
    if _s3_client is None:
        import boto3

        _s3_client = boto3.client("s3")
    return _s3_client


def lambda_handler(event: dict[str, Any] | None, context: Any = None, *, s3_client=None) -> dict[str, Any]:
    event = event if isinstance(event, dict) else {}
    config = GeneratorConfig.from_env()
    dry_run = bool(event.get("dry_run", False))

    batch_hour = resolve_batch_hour(event.get("run_ts"))
    key = build_s3_key(batch_hour, config.landing_prefix)
    batch = generate_batch(batch_hour, config)
    body = batch.to_csv_bytes()

    result: dict[str, Any] = {
        "status": "DRY_RUN" if dry_run else "UPLOADED",
        "bucket": config.bucket,
        "key": key,
        "batch_hour": f"{batch_hour:%Y-%m-%dT%H:00:00Z}",
        "row_count": batch.row_count,
        "defect_count": batch.defect_count,
        "defects_by_type": batch.defect_counts(),
        "bytes": len(body),
        "generator_version": GENERATOR_VERSION,
    }

    if not dry_run:
        if not config.bucket:
            raise ValueError("S3_BUCKET environment variable is not set")
        response = (s3_client or _s3()).put_object(
            Bucket=config.bucket,
            Key=key,
            Body=body,
            ContentType="text/csv",
            Metadata={
                "row-count": str(batch.row_count),
                "defect-count": str(batch.defect_count),
                "generator-version": GENERATOR_VERSION,
            },
        )
        result["etag"] = str(response.get("ETag", "")).strip('"')

    logger.info(json.dumps(result))
    return result
