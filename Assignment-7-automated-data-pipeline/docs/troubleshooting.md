# Troubleshooting

Every issue below **actually occurred** while building this pipeline, or is a direct consequence of its design.

## 1. Snowflake cannot assume the AWS role

**Symptom**
```
Error assuming AWS_ROLE: User: arn:aws:iam::<SNOWFLAKE_AWS_ACCOUNT>:user/<id> is not authorized
to perform: sts:AssumeRole on resource: arn:aws:iam::<AWS_ACCOUNT_ID>:role/a7-snowflake-s3-access-role
```
The trust policy was correct (same principal and external ID as `DESC INTEGRATION A7_S3_INT`).

**Cause:** the Snowflake account runs in `ap-southeast-7`, an **opt-in** AWS region that was disabled on the AWS account. Snowflake calls STS in its own region, and STS rejects requests for accounts that haven't enabled that region. The same CLI call returned `InvalidClientTokenId` with `--region ap-southeast-7`.

**Fix:** `aws account enable-region --region-name ap-southeast-7`, then wait for `get-region-opt-status` to report `ENABLED` (about 3 minutes here). No resources were created in that region.

## 2. Snowpipe

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ALTER PIPE … REFRESH` → `Table 'RAW.ORDERS_LANDING' does not exist` | Pipe definition used partly qualified names; a manual refresh resolves them in the **session's** database | Pipe v2 uses fully qualified names; also run `USE DATABASE A7_ORDERS_DB` |
| File in S3 but not loaded | Missing S3 → SNS notification or SNS subscription | `aws s3api get-bucket-notification-configuration`; `aws sns list-subscriptions-by-topic` (expect one `sqs` subscription owned by Snowflake) |
| `CREATE PIPE` fails to subscribe | Topic policy lacks Snowflake's `sns:Subscribe` principal | Deploy with `-SnowflakeSnsPrincipalArn` (from `SYSTEM$GET_AWS_SNS_IAM_POLICY`) |
| Files that existed before the pipe aren't loaded | Auto-ingest only reacts to new events | `ALTER PIPE A7_ORDERS_DB.RAW.PIPE_ORDERS_INGEST REFRESH;`, **once**, for a new pipe |
| Same hour loaded twice after recreating the pipe | Load history belongs to the pipe; a new pipe has none | Never `REFRESH` a recreated pipe, and never regenerate already-loaded hours |
| `GetSubscriptionAttributes` → `AuthorizationError` | The subscription is owned by Snowflake's AWS account | Expected; use `list-subscriptions-by-topic` instead |

## 3. Timestamps

| Symptom | Cause | Fix |
|---------|-------|-----|
| `LOADED_AT` 7 hours behind UTC, identical across loads | v1 pipe used `CURRENT_TIMESTAMP()::TIMESTAMP_NTZ`: account time zone `America/Los_Angeles`, evaluated once | v2 uses `CONVERT_TIMEZONE('UTC', METADATA$START_SCAN_TIME)`; the DQ view normalises older rows into `LOADED_AT_UTC` |
| A non-UTC timestamp silently shifted by 7 h | Automatic parsing applies the session time zone | Parse `ORDER_TS` with the explicit format `'YYYY-MM-DD"T"HH24:MI:SS"Z"'` |
| `090105: This session does not have a current database` | Some statements (`CREATE PIPE`, `SYSTEM$TYPEOF`) need a current database even with qualified names | Start sessions with `USE DATABASE A7_ORDERS_DB` |

## 4. Data Quality / Dynamic Tables

| Symptom | Cause | Fix |
|---------|-------|-----|
| `1097.99` became `1098` | `TRY_TO_NUMBER(x)` defaults to scale 0 | `TRY_TO_NUMBER(x, 18, 4)` |
| DQ11 flagged the clean original instead of the copy | Ordering duplicates by `ORDER_TS`; re-sent copies can have an earlier time | Arrival order: `LOADED_AT, SOURCE_FILE, SOURCE_ROW_NUMBER` |
| Dynamic table created with `refresh_mode = FULL` | A clock function (`SYSDATE()` / `CURRENT_TIMESTAMP`) in the query | DQ09 compares with `LOADED_AT_UTC`; create with `REFRESH_MODE = INCREMENTAL` so a regression fails loudly |
| GOOD/BAD behind RAW | `TARGET_LAG = '6 hours'` (by design) | `ALTER DYNAMIC TABLE A7_ORDERS_DB.CURATED.ORDERS_GOOD REFRESH;` (the EOD procedure does this automatically) |
| Same `ORDER_ID` in both GOOD and BAD | Expected for DQ11: the original is GOOD, the later copy BAD | Use (`SOURCE_FILE`, `SOURCE_ROW_NUMBER`) as the row key |

## 5. EOD Task & Email

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CREATE PROCEDURE` → `unexpected 'COMMENT'` | Clause order | `COMMENT` must come before `EXECUTE AS` |
| `SYSTEM$VALIDATE_STORAGE_INTEGRATION('A7_S3_INT')` → `expected 4, got 1` | Function needs integration, path, file and action | Use the 4-argument form with `'list'` or `'read'` |
| Email not received | Recipient not verified on a Snowflake user, or not in `ALLOWED_RECIPIENTS` | Verify in Snowsight; `DESC NOTIFICATION INTEGRATION A7_EMAIL_INT` |
| `STATUS_DETAILS` ends with `email=FAILED (...)` | Email delivery failed; the DQ summary is still saved | Check the message; `PIPELINE_STATUS` is unaffected by design |
| Task never runs | Task is suspended | `SHOW TASKS IN SCHEMA A7_ORDERS_DB.REPORTING;` then `ALTER TASK … RESUME` |

## 6. Cost / Visibility

| Symptom | Cause | Fix |
|---------|-------|-----|
| `SHOW RESOURCE MONITORS` empty, `resource_monitor = null` | Project role has no visibility on the monitor | Check as ACCOUNTADMIN |
| Warehouse resumes about 24×/day | Short target lag with hourly files | Keep `TARGET_LAG = '6 hours'` |
| `WAREHOUSE_METERING_HISTORY` returns no rows | Metering data is published with a delay | Check again a few hours later |

## 7. Useful Diagnostics

```sql
SELECT SYSTEM$PIPE_STATUS('A7_ORDERS_DB.RAW.PIPE_ORDERS_INGEST');

SELECT FILE_NAME, STATUS, ROW_COUNT, ERROR_COUNT, FIRST_ERROR_MESSAGE, LAST_LOAD_TIME
FROM TABLE(A7_ORDERS_DB.INFORMATION_SCHEMA.COPY_HISTORY(
       TABLE_NAME => 'A7_ORDERS_DB.RAW.ORDERS_LANDING',
       START_TIME => DATEADD(HOUR, -24, CURRENT_TIMESTAMP())));

SELECT NAME, REFRESH_ACTION, REFRESH_TRIGGER, STATE, REFRESH_START_TIME
FROM TABLE(A7_ORDERS_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
ORDER BY REFRESH_START_TIME DESC;

SELECT NAME, STATE, SCHEDULED_TIME, ERROR_MESSAGE
FROM TABLE(A7_ORDERS_DB.INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'TASK_EOD_DQ_REPORT'))
ORDER BY SCHEDULED_TIME DESC;
```
