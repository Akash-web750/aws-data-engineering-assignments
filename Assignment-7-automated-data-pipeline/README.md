# Assignment 7 — Automated Data Pipeline

![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-Lambda%20%7C%20S3%20%7C%20SNS%20%7C%20EventBridge-FF9900?logo=amazonwebservices&logoColor=white)
![Snowflake](https://img.shields.io/badge/Snowflake-Snowpipe%20%7C%20Dynamic%20Tables%20%7C%20Tasks-29B5E8?logo=snowflake&logoColor=white)
![IaC](https://img.shields.io/badge/IaC-CloudFormation-FF4F8B)
![Unit tests](https://img.shields.io/badge/unit%20tests-75%20passed-2EA44F)
![Status](https://img.shields.io/badge/status-live-2EA44F)

An event-driven, cost-controlled data pipeline. Every hour an AWS Lambda function generates a realistic e-commerce order file and writes it to Amazon S3. Snowflake loads each file automatically through Snowpipe, then classifies every record against **11 data-quality rules** into GOOD and BAD dynamic tables. A daily task at 23:55 IST writes an end-of-day summary and emails it using Snowflake's built-in notification service.

> The two badges marked *unit tests* and *status* are static: they describe the validation that was performed (see [Validation Results](#-validation-results)). They are not live CI badges.

---

## 🚀 Project Overview

| | |
|---|---|
| **Problem** | Hourly order files must be ingested, validated and summarised without manual work |
| **Ingestion** | S3 → SNS → Snowpipe `AUTO_INGEST` (no manual `COPY INTO`) |
| **Data quality** | 11 rules; every record gets `QUALITY_STATUS` (GOOD/BAD) and a `QUALITY_REASON` listing every failed rule |
| **Curation** | Two Snowflake Dynamic Tables (GOOD, BAD), refreshed incrementally |
| **Reporting** | Daily EOD summary table + email: volumes, GOOD/BAD %, day-over-day change, 7-day trend, observations, pipeline status |
| **Operations** | Infrastructure as code (CloudFormation + numbered SQL scripts), least-privilege IAM, a resource monitor caps compute spend |

---

## 🏗️ Architecture

```text
 EventBridge Scheduler  (cron 5 * * * ? *, UTC)
          │
          ▼
 AWS Lambda  a7-orders-generator  (Python 3.12, arm64)
          │  PutObject  landing/orders/year=YYYY/month=MM/day=DD/orders_YYYYMMDD_HH.csv
          ▼
 Amazon S3  (encrypted, private, 30-day lifecycle)
          │  s3:ObjectCreated  (prefix landing/orders/, suffix .csv)
          ▼
 Amazon SNS  a7-orders-s3-events
          │  Snowflake SQS subscription
          ▼
 Snowpipe  RAW.PIPE_ORDERS_INGEST  (AUTO_INGEST, serverless)
          │
          ▼
 Snowflake RAW  RAW.ORDERS_LANDING  (source values kept as text)
          │
          ▼
 Data Quality  CURATED.V_ORDERS_DQ  (11 rules, one row per RAW record)
          │
   ┌──────┴──────┐   Dynamic Tables (INCREMENTAL, 6-hour target lag)
   ▼             ▼
 ORDERS_GOOD   ORDERS_BAD
   └──────┬──────┘
          ▼
 EOD Reporting  REPORTING.TASK_EOD_DQ_REPORT  (23:55 Asia/Kolkata)
          │  → SP_EOD_DQ_REPORT → EOD_DQ_SUMMARY (one row per IST date)
          ▼
 Email Notification  SYSTEM$SEND_EMAIL via A7_EMAIL_INT
```

The detailed design, including a Mermaid diagram, is in [docs/architecture.md](docs/architecture.md).

---

## 🔄 End-to-End Data Flow

1. **Schedule.** At 5 minutes past every hour (UTC), EventBridge Scheduler invokes the Lambda.
2. **Generate.** The Lambda builds the **previous completed hour's** file: 80–150 orders, with about 8 % deliberately defective rows. The random generator is seeded from the hour, so re-running an hour reproduces the file byte for byte.
3. **Land.** The file is written to `s3://<bucket>/landing/orders/year=YYYY/month=MM/day=DD/orders_YYYYMMDD_HH.csv` (SSE-S3 encrypted).
4. **Notify.** S3 publishes an `ObjectCreated` event to an SNS topic. Snowflake's Snowpipe queue is subscribed to that topic, which also works when the Snowflake account is in a different AWS region than the bucket.
5. **Ingest.** Snowpipe copies the 15 CSV columns *by position* into `RAW.ORDERS_LANDING` as text, and adds `SOURCE_FILE`, `SOURCE_ROW_NUMBER`, `LOADED_AT` (UTC scan time) and `LOAD_BATCH_ID`.
6. **Validate.** `CURATED.V_ORDERS_DQ` evaluates all 11 rules with safe `TRY_*` conversions, so malformed values never break the query.
7. **Curate.** `CURATED.ORDERS_GOOD` and `CURATED.ORDERS_BAD` are incremental Dynamic Tables built on that view.
8. **Report.** At 23:55 IST a task calls `SP_EOD_DQ_REPORT`, which:
   1. forces a refresh of both Dynamic Tables and checks that the refresh completed
   2. reconciles RAW against the curated tables
   3. computes the daily metrics, the previous-day change and the 7-day trend
   4. merges the result into `REPORTING.EOD_DQ_SUMMARY` (one row per date, safe to re-run)
   5. emails the summary

---

## 🧪 Data Quality Rules

| Rule | Description |
|---|---|
| `DQ01_REQUIRED_FIELDS` | None of the 15 business columns may be NULL or blank |
| `DQ02_QUANTITY_NUMERIC` | `QUANTITY` must parse as a number |
| `DQ03_QUANTITY_POSITIVE` | `QUANTITY` must be > 0 |
| `DQ04_UNIT_PRICE_NUMERIC` | `UNIT_PRICE` must parse as a number |
| `DQ05_AMOUNT_NUMERIC` | `AMOUNT` must parse as a number |
| `DQ06_AMOUNT_POSITIVE` | `AMOUNT` must be > 0 |
| `DQ07_AMOUNT_MATCH` | `AMOUNT` = `QUANTITY × UNIT_PRICE`, within 0.01 |
| `DQ08_EMAIL_VALID` | `CUSTOMER_EMAIL` matches `local@domain.tld` |
| `DQ09_ORDER_TS_NOT_FUTURE` | `ORDER_TS` must parse (strict ISO-8601 UTC) and must not be later than the record's ingestion time |
| `DQ10_STATUS_VALID` | `ORDER_STATUS` ∈ {PLACED, SHIPPED, DELIVERED, CANCELLED, RETURNED} |
| `DQ11_DUPLICATE_ORDER_ID` | For a repeated non-NULL `ORDER_ID`, the first arrival is kept; later arrivals fail |

**Design notes**
- A missing value fails only DQ01. The type and range rules evaluate present values only, so one blank field isn't counted twice.
- `QUALITY_REASON` lists **all** failed rules in rule order, e.g. `DQ06_AMOUNT_POSITIVE;DQ07_AMOUNT_MATCH`.
- DQ09 is measured against the ingestion time, not the current clock. Results are therefore fixed once a record is loaded, and the Dynamic Tables can refresh incrementally.
- DQ11 uses arrival order (`LOADED_AT, SOURCE_FILE, SOURCE_ROW_NUMBER`), because re-sent duplicates can carry an earlier order timestamp than the original.

---

## ❄️ Snowflake Design

| Layer / object | Name | Purpose |
|---|---|---|
| Database | `A7_ORDERS_DB` | Project database, 1-day Time Travel |
| RAW | `RAW.ORDERS_LANDING`, `RAW.FF_ORDERS_CSV`, `RAW.STG_ORDERS_S3`, `RAW.PIPE_ORDERS_INGEST` | Landing table, CSV file format, external stage, Snowpipe |
| CURATED | `CURATED.V_ORDERS_DQ` | The single definition of the 11 DQ rules (view) |
| CURATED | `CURATED.ORDERS_GOOD`, `CURATED.ORDERS_BAD` | Dynamic Tables: `REFRESH_MODE = INCREMENTAL`, `TARGET_LAG = '6 hours'` |
| REPORTING | `REPORTING.EOD_DQ_SUMMARY` | One row per IST business date (idempotent `MERGE`) |
| REPORTING | `REPORTING.SP_EOD_DQ_REPORT(DATE)` | EOD workflow: refresh, reconcile, summarise, merge, email (owner's rights) |
| REPORTING | `REPORTING.TASK_EOD_DQ_REPORT` | `USING CRON 55 23 * * * Asia/Kolkata`, no overlap, 10-minute timeout |
| Role | `A7_PIPELINE_ROLE` | Owns every object inside the database; no access outside the project |
| Warehouse | `A7_PIPELINE_WH` | X-Small, `AUTO_SUSPEND = 60`, owned by ACCOUNTADMIN; the project role has USAGE/OPERATE/MONITOR only |
| Resource monitor | `A7_PIPELINE_RM` | 10 credits/month; notifies at 75 % and 90 %, suspends at 100 %, suspends immediately at 110 % |
| Integrations | `A7_S3_INT` (storage), `A7_EMAIL_INT` (email) | Created by ACCOUNTADMIN; usage granted to the project role |

---

## ☁️ AWS Design

All AWS resources are in a single CloudFormation stack (`a7-orders-pipeline`). The only exception is the Snowflake read role, which is created with the AWS CLI.

| Service | Resource | Configuration |
|---|---|---|
| **S3** | `a7-orders-pipeline-<AWS_ACCOUNT_ID>` | SSE-S3, all public access blocked, ACLs disabled, HTTPS-only bucket policy; `landing/orders/` expires after 30 days |
| **Lambda** | `a7-orders-generator` | Python 3.12, arm64, 128 MB, 30 s timeout; standard library + boto3 only |
| **EventBridge Scheduler** | `a7-orders-hourly` | `cron(5 * * * ? *)` UTC → Lambda |
| **SNS** | `a7-orders-s3-events` | Only this bucket can publish; only Snowflake's principal can subscribe |
| **IAM** | `a7-orders-generator-role` | `s3:PutObject` on `landing/orders/*` + its own log group |
| **IAM** | `a7-orders-generator-scheduler-role` | `lambda:InvokeFunction` on the generator only |
| **IAM** | `a7-snowflake-s3-access-role` | Assumed by Snowflake with an external ID; read-only on `landing/orders/` |
| **CloudWatch Logs** | `/aws/lambda/a7-orders-generator` | 14-day retention |

---

## 📊 Validation Results

> **Initial end-to-end validation, 2026-10-05.** These figures come from the first two hourly files, used to validate the pipeline before go-live. They are not a running production history.

| Metric | Result |
|---|---|
| Files ingested | 2 (one via Snowpipe `REFRESH`, one fully automatic: Lambda → S3 → SNS → Snowpipe, about 3 s from upload to ingestion) |
| Total records | **295** |
| GOOD | **271 (91.86 %)** |
| BAD | **24 (8.14 %)** |
| Deliberate defects detected | **24 / 24**, 0 false positives (checked row by row against the generator's record of the defects it injected) |
| DQ rules | 11 |
| Classification mismatches (DQ view vs Dynamic Tables) | 0 |
| Snowpipe | RUNNING |
| Dynamic Tables | INCREMENTAL, 6-hour target lag |
| EOD status | HEALTHY; email accepted by `SYSTEM$SEND_EMAIL` and delivered |

---

## 💰 Cost Optimization

- **X-Small warehouse with a 60-second auto-suspend.** It runs only while it has work.
- **Dynamic Tables with a 6-hour target lag.** Checks that find no new data run without the warehouse. Each refresh batches several hourly files, and the EOD procedure forces a final refresh so the report is always complete.
- **One warehouse resume per EOD run.** Both refreshes, the reconciliation and the email share one session.
- **Resource monitor** `A7_PIPELINE_RM` caps the warehouse at **10 credits/month**.
- **Serverless ingestion.** Snowpipe needs no warehouse.
- **S3 lifecycle.** Landing files expire after 30 days; incomplete uploads after 1 day.
- **No always-on compute.** No EC2, RDS or containers. Lambda runs 24 times a day for a few seconds, and CloudWatch Logs keeps 14 days.

---

## 📧 EOD Reporting

At **23:55 IST** every day, `TASK_EOD_DQ_REPORT` calls `SP_EOD_DQ_REPORT()` for the current IST business date. A record belongs to the IST date of its ingestion time.

- **Subject:** `Assignment 7 EOD DQ Report - YYYY-MM-DD - HEALTHY | WARNING | FAILED`
- **Body:**
  - totals with GOOD/BAD counts and percentages
  - files processed, previous-day total and volume change
  - 7-day averages and trend
  - DQ failures by rule
  - pipeline status details and observations
- **Pipeline status is based on evidence:**
  - **FAILED:** refresh not verified, or a classification/reconciliation mismatch
  - **WARNING:** Snowpipe not running, no records, BAD ≥ 10 %, or RAW rows not yet curated
  - **HEALTHY:** otherwise
- **Email is isolated from the DQ result.** It's sent only after the summary row is saved. A delivery failure is recorded in `STATUS_DETAILS` and never changes the saved results.

The recipient must be a **verified** email of a user in the Snowflake account, listed in `A7_EMAIL_INT`. The repository uses the placeholder `YOUR_EMAIL@example.com`.

---

## 🧪 Testing

| Level | What was verified | Result |
|---|---|---|
| Unit (pytest, offline) | S3 key naming, `run_ts` parsing, deterministic generation, CSV structure, realistic values, defect injection (≈ 8 %, all 9 defect types), Lambda handler with a stubbed S3 client | **75 / 75 passed** |
| Storage integration | `SYSTEM$VALIDATE_STORAGE_INTEGRATION` LIST + READ | SUCCESS |
| Snowpipe | Existing file via `REFRESH`; new file fully automatic via SNS | 145 + 150 rows, 0 load errors |
| Column mapping | Every loaded cell compared with the generator output | 4,425 / 4,425 cells match |
| Data quality | Every row compared with the generator's record of injected defects | 24 / 24 detected, 0 false positives |
| Dynamic Tables | Row-by-row comparison with the validated DQ query | 0 mismatches |
| EOD workflow | Re-runs, previous-day and 7-day calculations, future-date guard, email | PASS |

```powershell
pip install -r requirements-dev.txt
python -m pytest tests/unit -q
```

See [docs/testing.md](docs/testing.md).

---

## 📁 Project Structure

```text
Assignment-7-automated-data-pipeline/
├── README.md
├── requirements.txt / requirements-dev.txt
├── config/
│   └── pipeline.example.env              # placeholders only
├── docs/
│   ├── architecture.md
│   ├── setup.md
│   ├── testing.md
│   └── troubleshooting.md
├── infra/aws/
│   ├── template.yaml                     # CloudFormation stack
│   ├── deploy.ps1 / teardown.ps1
│   └── iam/
│       ├── snowflake-s3-read-policy.json
│       └── snowflake-trust-policy.example.json
├── lambda/order_generator/               # handler, generator, naming, config
├── scripts/
│   └── package_lambda.py                 # deterministic Lambda zip
├── snowflake/
│   ├── 00_admin_bootstrap.sql            # ACCOUNTADMIN: role, warehouse, monitor, DB, storage integration
│   ├── 00b_admin_email_integration.sql   # ACCOUNTADMIN: email integration
│   ├── 01_database_warehouse.sql         # schemas
│   ├── 02_stage_file_format.sql          # file format + external stage
│   ├── 03_landing_table.sql              # RAW landing table
│   ├── 03b_snowpipe.sql                  # Snowpipe (AUTO_INGEST via SNS)
│   ├── 04_data_quality_validation.sql    # DQ rules + validation queries
│   ├── 05_curated_dynamic_tables.sql     # DQ view + GOOD/BAD Dynamic Tables
│   └── 06_eod_reporting.sql              # EOD table, procedure, task
└── tests/unit/                           # 75 pytest tests
```

---

## 🔐 Security

- **Least-privilege IAM.**
  - The generator can only `PutObject` into `landing/orders/`.
  - The scheduler can only invoke the generator.
  - Snowflake's role is read-only on the landing prefix and requires an external ID.
- **S3 hardening:** SSE-S3 encryption, all four public-access blocks, ACLs disabled, and a bucket policy that denies any non-HTTPS request.
- **Narrow SNS policy:** only the project bucket can publish, and only Snowflake's principal can subscribe.
- **Snowflake role separation:**
  - Account-level objects are created once by ACCOUNTADMIN.
  - The project role owns only its database objects, and can use but not resize the warehouse.
  - The procedure runs with owner's rights.
- **No credentials in code.**
  - AWS access uses the local CLI profile.
  - Snowflake access uses the local Snowflake CLI connection.
  - The storage integration uses an IAM role, not access keys.
- **Secrets excluded from Git:**
  - `.gitignore` blocks `.env` files, keys and certificates, Snowflake CLI config, generated CSVs and build artifacts.
  - It also blocks the account-specific trust policy that contains the external ID. Only `*.example.json` is committed.

---

## ⚙️ Setup

Prerequisites:
- an AWS account with the CLI configured, using an IAM user, not root
- a Snowflake account with ACCOUNTADMIN for the one-time bootstrap
- Snowflake CLI
- Python 3.10+

The repository contains **no account-specific values**. Supply yours as environment variables or placeholders:

```powershell
$env:AWS_ACCOUNT_ID      = "<your-aws-account-id>"
$env:AWS_REGION          = "ap-south-1"
$env:SNOWFLAKE_ACCOUNT   = "<your-snowflake-account>"
$env:EOD_EMAIL_RECIPIENT = "YOUR_EMAIL@example.com"
```

The SQL and IAM files use `<AWS_ACCOUNT_ID>`, `<DEVELOPER_USER>` and `YOUR_EMAIL@example.com` placeholders. The bucket name `a7-orders-pipeline-<AWS_ACCOUNT_ID>` is environment-specific. See the placeholder table in [docs/setup.md](docs/setup.md#2-environment-variables--placeholders).

```powershell
# 1. AWS: bucket, Lambda, SNS, schedule (deployed DISABLED)
.\infra\aws\deploy.ps1

# 2. Snowflake (ACCOUNTADMIN, once): snowflake/00_admin_bootstrap.sql
#    then create the Snowflake IAM role from infra/aws/iam/ using the integration's
#    STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID

# 3. Snowflake (project role): scripts 01 → 06
snow sql -c <connection> --role A7_PIPELINE_ROLE --warehouse A7_PIPELINE_WH -f snowflake/01_database_warehouse.sql

# 4. Go live
.\infra\aws\deploy.ps1 -ScheduleState ENABLED
#    ALTER TASK A7_ORDERS_DB.REPORTING.TASK_EOD_DQ_REPORT RESUME;
```

The full ordered procedure is in [docs/setup.md](docs/setup.md), including the Snowflake ↔ AWS dependency order, the email verification step and teardown.

---

## 📚 Documentation

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Components, data model, DQ design, refresh strategy, EOD logic, cost model |
| [docs/setup.md](docs/setup.md) | Step-by-step deployment, dependency order, go-live, teardown |
| [docs/testing.md](docs/testing.md) | Unit tests, integration and end-to-end validation evidence |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Real issues encountered and how they were diagnosed |

---

## 🎯 What This Project Demonstrates

- **AWS:** Lambda, S3, SNS, EventBridge Scheduler, IAM, CloudWatch, CloudFormation
- **Snowflake:** storage integration, external stage, Snowpipe auto-ingest, Dynamic Tables (incremental), SQL stored procedure, tasks, native email notifications, resource monitors
- **Python:** deterministic synthetic-data generator, Lambda handler, pytest suite
- **SQL:** safe `TRY_*` parsing, window-function duplicate detection, idempotent `MERGE`, time-zone-correct business dates
- **Data quality engineering:** 11 explainable rules with every failed rule recorded per row
- **Event-driven architecture:** cross-region S3 → SNS → Snowpipe
- **Monitoring:** evidence-based pipeline status and a daily report
- **Cost optimization:** auto-suspend, a lag sized to the ingestion pattern, a resource monitor
- **Production deployment:** pre-production audit, then a controlled go-live

---

## 👨‍💻 Author

**Akash** — [github.com/Akash-web750](https://github.com/Akash-web750)

Part of the [AWS Data Engineering Assignments](../README.md) portfolio.
