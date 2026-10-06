"""AWS Lambda entry point: generate one hourly order file and upload it to S3.

Handler: handler.lambda_handler

Event (all optional):
    {"run_ts": "2026-10-05T14:00:00Z"}   generate that hour (backfill / tests)
    {"dry_run": true}                     build the file but skip the upload

With no run_ts, the previous completed UTC hour is generated (the schedule
fires a few minutes past each hour). Re-running an hour rewrites identical
bytes to the same key. Re-running the same hourly file is normally skipped by
Snowpipe's load history for the same pipe while the file remains within the
applicable load-history retention (a re-created pipe has no history; see
snowflake/03b_snowpipe.sql).

Flow: event -> config (env vars) -> batch hour -> S3 key -> generate rows ->
CSV bytes -> PutObject -> S3 ObjectCreated event -> SNS -> Snowpipe.
The handler never talks to Snowflake; ingestion is fully event-driven.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from config import GeneratorConfig
from generator import GENERATOR_VERSION, generate_batch
from naming import build_s3_key, resolve_batch_hour

# Lambda routes the root logger to CloudWatch Logs (log group created by the stack).
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Module-level cache: Lambda reuses the execution environment between invocations,
# so the S3 client is created once per container instead of once per call.
_s3_client = None


def _s3():
    """Create the S3 client once per container (boto3 ships with the Lambda runtime)."""
    global _s3_client
    if _s3_client is None:
        # Imported lazily so the generator and unit tests run without boto3 installed.
        import boto3

        _s3_client = boto3.client("s3")
    return _s3_client


def lambda_handler(event: dict[str, Any] | None, context: Any = None, *, s3_client=None) -> dict[str, Any]:
    # EventBridge Scheduler sends "{}" (template.yaml Target.Input); anything that is
    # not a dict (e.g. None from a manual test) is treated as "no options".
    event = event if isinstance(event, dict) else {}
    config = GeneratorConfig.from_env()
    # Note: plain truthiness - any truthy value (including the string "false")
    # selects a dry run.
    dry_run = bool(event.get("dry_run", False))

    # Hour -> key -> content are all deterministic for the same inputs.
    batch_hour = resolve_batch_hour(event.get("run_ts"))
    key = build_s3_key(batch_hour, config.landing_prefix)
    batch = generate_batch(batch_hour, config)
    body = batch.to_csv_bytes()

    # The returned summary is also logged; it is the evidence used in end-to-end
    # tests (row/defect counts are compared with what Snowflake classifies).
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
        # Raising (instead of returning an error dict) makes the invocation fail, so
        # EventBridge Scheduler / Lambda async retries and CloudWatch see the error.
        if not config.bucket:
            raise ValueError("S3_BUCKET environment variable is not set")
        # s3_client is injectable for unit tests (a stub that never calls AWS).
        # Encryption (SSE-S3) is applied by the bucket default; the IAM role only
        # allows s3:PutObject under the landing prefix.
        response = (s3_client or _s3()).put_object(
            Bucket=config.bucket,
            Key=key,
            Body=body,
            ContentType="text/csv",
            # Object metadata lets an operator check expected counts without
            # downloading the file (aws s3api head-object).
            Metadata={
                "row-count": str(batch.row_count),
                "defect-count": str(batch.defect_count),
                "generator-version": GENERATOR_VERSION,
            },
        )
        result["etag"] = str(response.get("ETag", "")).strip('"')

    logger.info(json.dumps(result))
    return result
