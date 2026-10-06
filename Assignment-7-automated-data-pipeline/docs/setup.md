# Setup & Deployment

This guide deploys the pipeline into **your own** AWS and Snowflake accounts. Replace every `<PLACEHOLDER>`. No credentials are stored in this repository:
- **AWS** uses your local CLI profile.
- **Snowflake** uses your local Snowflake CLI connection.

## 1. Prerequisites

| Requirement | Check |
|-------------|-------|
| AWS CLI v2, signed in as an IAM admin user (not root) | `aws sts get-caller-identity` |
| Snowflake CLI 3.x with a working connection | `snow connection test -c <connection>` |
| A Snowflake user that can use `ACCOUNTADMIN` once, for the bootstrap scripts | Snowsight |
| A **verified** email on a Snowflake user (the EOD report recipient) | Snowsight → Settings → Profile |
| Python 3.10+ locally; the Lambda runtime is 3.12 | `python --version` |

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt -r requirements-dev.txt
python -m pytest tests/unit -q          # 75 tests, offline
```

Optionally copy `config/pipeline.example.env` to `config/pipeline.env`, which git ignores, and fill it in as your own reference.

## 2. Environment Variables / Placeholders

The repository contains **no account-specific values**. Set these for your environment (example values only):

```powershell
$env:AWS_ACCOUNT_ID      = "<your-aws-account-id>"      # used by deploy.ps1 / teardown.ps1
$env:AWS_REGION          = "ap-south-1"
$env:SNOWFLAKE_ACCOUNT   = "<your-snowflake-account>"   # configured in your Snowflake CLI connection
$env:EOD_EMAIL_RECIPIENT = "YOUR_EMAIL@example.com"     # must be verified on a Snowflake user
```

The same list is in [`config/pipeline.example.env`](../config/pipeline.example.env). Copy it to `config/pipeline.env`, which git ignores.

| Placeholder in the files | Replace with | Files |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | Your AWS account ID (`aws sts get-caller-identity`) | `snowflake/00_admin_bootstrap.sql`, `02_stage_file_format.sql`, `03b_snowpipe.sql`, `infra/aws/iam/snowflake-s3-read-policy.json` |
| `a7-orders-pipeline-<AWS_ACCOUNT_ID>` | Your bucket name. It's environment-specific: `deploy.ps1` derives it from `AWS_ACCOUNT_ID`, or pass `-BucketName` | (same files) |
| `<DEVELOPER_USER>` | The Snowflake user that runs scripts `01`–`06` | `snowflake/00_admin_bootstrap.sql` |
| `<DEVELOPER_ROLE>`, `<DEVELOPER_WAREHOUSE>` | Your existing developer role and warehouse. They're only used by read-only checks | `snowflake/00_admin_bootstrap.sql` |
| `<connection>` | Your Snowflake CLI connection name | `snow sql -c <connection> …` commands |
| `<STORAGE_AWS_IAM_USER_ARN>`, `<STORAGE_AWS_EXTERNAL_ID>` | `DESC INTEGRATION A7_S3_INT` (after step 3) | `infra/aws/iam/snowflake-trust-policy.json` (git-ignored copy of the `.example.json`) |
| `<SNOWFLAKE_SNS_PRINCIPAL_ARN>` | `SELECT SYSTEM$GET_AWS_SNS_IAM_POLICY('<SNS_TOPIC_ARN>')` → `Principal.AWS` | `deploy.ps1 -SnowflakeSnsPrincipalArn` |
| `<VERIFIED_EMAIL>` / `YOUR_EMAIL@example.com` | The verified recipient address | `snowflake/00b_admin_email_integration.sql`, `06_eod_reporting.sql` |

## 3. Deployment Order

There are two dependencies across the platforms:
- **The integration comes first.** Snowflake generates the IAM user and external ID that the AWS role must trust.
- **The SNS permission comes before the pipe.** The topic must allow Snowflake to subscribe before the pipe can be created.

| Step | Where | Run as | Action |
|------|-------|--------|--------|
| 1 | AWS | IAM admin | `$env:AWS_ACCOUNT_ID = "<your-aws-account-id>"; .\infra\aws\deploy.ps1`. Creates the bucket `a7-orders-pipeline-<AWS_ACCOUNT_ID>`, Lambda, SNS topic and S3 notification, and the hourly schedule **DISABLED** |
| 2 | AWS | IAM admin | If your Snowflake account is in an **opt-in** AWS region (e.g. `ap-southeast-7`), enable that region on the AWS account: `aws account enable-region --region-name <region>` |
| 3 | Snowflake | **ACCOUNTADMIN** | `snowflake/00_admin_bootstrap.sql`: role, resource monitor, warehouse (suspended), database, `A7_S3_INT`, grants. Note the two `DESC INTEGRATION` values |
| 4 | AWS | IAM admin | Create the Snowflake read role (section 4) |
| 5 | Snowflake | `A7_PIPELINE_ROLE` | `01_database_warehouse.sql`, `02_stage_file_format.sql`, `03_landing_table.sql` |
| 6 | Snowflake | `A7_PIPELINE_ROLE` | `LIST @A7_ORDERS_DB.RAW.STG_ORDERS_S3`: proves the trust works (allow about a minute for IAM propagation) |
| 7 | AWS | IAM admin | `.\infra\aws\deploy.ps1 -SnowflakeSnsPrincipalArn <SNOWFLAKE_SNS_PRINCIPAL_ARN>`. Adds the subscribe permission to the topic policy |
| 8 | Snowflake | `A7_PIPELINE_ROLE` | `03b_snowpipe.sql` (creates the pipe; Snowflake subscribes to SNS) |
| 9 | Snowflake | `A7_PIPELINE_ROLE` | `04_data_quality_validation.sql` (read-only check) and `05_curated_dynamic_tables.sql` |
| 10 | Snowflake | **ACCOUNTADMIN** | Verify `<VERIFIED_EMAIL>` in Snowsight, then run `00b_admin_email_integration.sql` |
| 11 | Snowflake | `A7_PIPELINE_ROLE` | Replace `YOUR_EMAIL@example.com` in `06_eod_reporting.sql` with `<VERIFIED_EMAIL>`, then run it. The task is created **suspended** |
| 12 | Both | — | Test (see [testing.md](testing.md)), then go live (section 5) |

Running the project-role scripts:

```powershell
snow sql -c <connection> --role A7_PIPELINE_ROLE --warehouse A7_PIPELINE_WH -f snowflake/01_database_warehouse.sql
```

Always pass `--warehouse A7_PIPELINE_WH`. The scripts start with `USE DATABASE A7_ORDERS_DB`; Snowflake needs a current database even for some fully qualified statements.

## 4. Snowflake Read Role (AWS CLI)

```powershell
# 1. Fill the example with the DESC INTEGRATION values (the real file is git-ignored)
Copy-Item infra\aws\iam\snowflake-trust-policy.example.json infra\aws\iam\snowflake-trust-policy.json
#    edit: Principal.AWS = <STORAGE_AWS_IAM_USER_ARN>, sts:ExternalId = <STORAGE_AWS_EXTERNAL_ID>
#    edit snowflake-s3-read-policy.json: replace <AWS_ACCOUNT_ID> (3 places) with your account ID

# 2. IAM is global, so no --region is needed
aws iam create-role --role-name a7-snowflake-s3-access-role `
  --assume-role-policy-document file://infra/aws/iam/snowflake-trust-policy.json
aws iam put-role-policy --role-name a7-snowflake-s3-access-role `
  --policy-name a7-snowflake-read-landing `
  --policy-document file://infra/aws/iam/snowflake-s3-read-policy.json
```

Never recreate `A7_S3_INT` afterwards: a new integration gets a new external ID, and the trust breaks.

## 5. Go-Live

```powershell
.\infra\aws\deploy.ps1 -ScheduleState ENABLED      # hourly Lambda (through the stack, not the console)
```
```sql
ALTER TASK A7_ORDERS_DB.REPORTING.TASK_EOD_DQ_REPORT RESUME;   -- daily 23:55 IST report + email
```

## 6. Operating Notes

- **Every `CALL SP_EOD_DQ_REPORT()` sends an email,** scheduled or manual.
- **Dynamic tables refresh at least every 6 hours.** The EOD procedure forces a final refresh before reporting.
- **Snowpipe history.** A pipe skips files it has already loaded. If the pipe is ever **recreated**, its load history is empty, so don't run `ALTER PIPE … REFRESH` and don't regenerate hours that are already loaded.
- **For a live demo,** temporarily lower the lag with `ALTER DYNAMIC TABLE … SET TARGET_LAG = '1 minute'`, then restore `'6 hours'`.

## 7. Teardown (removes only Assignment 7 objects)

```sql
-- Snowflake, as ACCOUNTADMIN (order matters: the task and pipe first)
ALTER TASK A7_ORDERS_DB.REPORTING.TASK_EOD_DQ_REPORT SUSPEND;
DROP DATABASE A7_ORDERS_DB;                 -- pipe, tables, dynamic tables, procedure, task
DROP INTEGRATION A7_EMAIL_INT;
DROP INTEGRATION A7_S3_INT;
DROP WAREHOUSE A7_PIPELINE_WH;
DROP RESOURCE MONITOR A7_PIPELINE_RM;
DROP ROLE A7_PIPELINE_ROLE;
```
```powershell
# AWS: empties the project bucket, deletes the stack and the CLI-created Snowflake role
.\infra\aws\teardown.ps1
```
