# Testing

Testing ran at three levels:
- **Unit tests** that run offline
- **Integration checks** of each AWS ↔ Snowflake connection
- **End-to-end validation** of the deployed pipeline

All numbers below are from the **initial validation on 2026-10-05**, before go-live.

## 1. Unit Tests (offline, no cloud access)

```powershell
pip install -r requirements-dev.txt
python -m pytest tests/unit -q
```

**Result: 75 passed.**

| File | Tests | Covers |
|------|-------|--------|
| `tests/unit/test_naming.py` | 16 | S3 key format, zero-padding, prefix handling, `run_ts` parsing (UTC, naive, offsets, invalid input), default "previous completed hour" |
| `tests/unit/test_generator.py` | 49 | Byte-identical output per hour, CSV header and quoting, row-count bounds and daily pattern, realistic clean rows, ≈ 8 % defect rate, all 9 defect types, every defect fails its intended rule, config validation |
| `tests/unit/test_handler.py` | 10 | Upload key/body/metadata via a stubbed S3 client (no AWS calls), `dry_run`, scheduled event, missing bucket, invalid `run_ts` |
| *(collected test cases, including parametrized ones)* | **75** | |
| `tests/unit/dq_reference.py` | — | Python reference implementation of the DQ rules, used by the tests |

## 2. Integration Checks

| # | Check | Command | Result |
|---|-------|---------|--------|
| 1 | Lambda dry run | `aws lambda invoke … {"run_ts":"…","dry_run":true}` | Same row count and bytes as the local generator (Python 3.12 arm64 = local 3.10) |
| 2 | Lambda upload | `aws lambda invoke … {"run_ts":"…"}` | 1 object, SSE AES256, content byte-identical to local generation |
| 3 | Storage integration | `SYSTEM$VALIDATE_STORAGE_INTEGRATION('A7_S3_INT', '<s3 path>', '<file>', 'list' / 'read')` | `LIST` success, `READ` success |
| 4 | Stage | `LIST @A7_ORDERS_DB.RAW.STG_ORDERS_S3` | File visible; MD5 equals the S3 ETag |
| 5 | SNS subscription | `aws sns list-subscriptions-by-topic` | One confirmed `sqs` subscription owned by Snowflake |

## 3. End-to-End Validation

| # | Stage | Evidence | Result |
|---|-------|----------|--------|
| 1 | Snowpipe (existing file) | `ALTER PIPE … REFRESH`, `COPY_HISTORY` | 145 rows, `Loaded`, 0 errors |
| 2 | **Automatic path** (no refresh) | Lambda → S3 → SNS → Snowpipe, `SYSTEM$PIPE_STATUS` | New file ingested about 3 s after upload; 150 rows, 0 errors |
| 3 | Column mapping | Every loaded cell compared with the generator output | 4,425 / 4,425 cells match |
| 4 | DQ rules | `04_data_quality_validation.sql` compared with the generator's record of the defects it injected | 24 / 24 detected, **0 false positives**; GOOD 271, BAD 24 |
| 5 | Dynamic tables | Row-level comparison of GOOD ∪ BAD with the validated DQ query | 295 rows, **0 mismatches**, `INCREMENTAL` |
| 6 | EOD procedure | `CALL SP_EOD_DQ_REPORT()` (twice, same date) | 1 row per date, `RUN_COUNT` incremented, status HEALTHY |
| 7 | EOD edge cases | 0-record day, previous day = 0, 7-day average over 2 days, future date | WARNING / safe NULL % / 147.50 / rejected (`-20001`) |
| 8 | Email | Test email, then one production-format email from the procedure | `SYSTEM$SEND_EMAIL` = true; delivered |
| 9 | Cost behaviour | Warehouse state while dynamic tables ran scheduled no-data checks | Warehouse stayed SUSPENDED; auto-suspends about 60–90 s after work |

Final validated state:

| Metric | Value |
|---|---|
| RAW / GOOD / BAD | 295 / 271 / 24 |
| GOOD % / BAD % | 91.86 % / 8.14 % |
| Files | 2 |
| `classification_mismatch` / `raw_not_curated` / `curated_not_in_raw` / `duplicate_row_keys` | 0 / 0 / 0 / 0 |
| Snowpipe | RUNNING |
| EOD status | HEALTHY |

## 4. Re-running the Checks

```sql
-- Snowpipe health (no warehouse)
SELECT SYSTEM$PIPE_STATUS('A7_ORDERS_DB.RAW.PIPE_ORDERS_INGEST');

-- Dynamic table state (no warehouse)
SHOW DYNAMIC TABLES IN SCHEMA A7_ORDERS_DB.CURATED;

-- Full DQ validation + summaries (uses A7_PIPELINE_WH briefly)
-- snow sql ... -f snowflake/04_data_quality_validation.sql

-- Latest EOD results
SELECT REPORT_DATE, PIPELINE_STATUS, TOTAL_RECORDS, GOOD_PERCENTAGE, BAD_PERCENTAGE, STATUS_DETAILS
FROM A7_ORDERS_DB.REPORTING.EOD_DQ_SUMMARY ORDER BY REPORT_DATE DESC;
```

Note: `CALL SP_EOD_DQ_REPORT()` always sends an email.
