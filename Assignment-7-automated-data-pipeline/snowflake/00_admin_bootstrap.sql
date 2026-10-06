/* =============================================================================
   Assignment 7 - 00_admin_bootstrap.sql
   -----------------------------------------------------------------------------
   RUN MANUALLY, ONCE, AS ACCOUNTADMIN (Snowsight worksheet, "Run All").

   Creates ONLY the account-level objects the project role cannot create itself:
     role                 A7_PIPELINE_ROLE
     resource monitor     A7_PIPELINE_RM     (monthly 10-credit cap)
     warehouse            A7_PIPELINE_WH     (X-Small, 60s auto-suspend, created SUSPENDED)
     database             A7_ORDERS_DB
     storage integration  A7_S3_INT          (CREATE INTEGRATION requires ACCOUNTADMIN)

   Not included: the email integration (A7_EMAIL_INT). It comes in a separate
   admin script once the recipient address is verified.

   Does NOT touch any existing role, warehouse, resource monitor or database
   (e.g. your <DEVELOPER_ROLE>, <DEVELOPER_WAREHOUSE>, <DEVELOPER_DATABASE>).

   PLACEHOLDERS to replace before running:
     <AWS_ACCOUNT_ID>   your AWS account ID (role ARN, bucket, SNS topic ARN)
     <DEVELOPER_USER>   the Snowflake user that will run scripts 01-06 as A7_PIPELINE_ROLE
     <DEVELOPER_WAREHOUSE> / <DEVELOPER_ROLE>   only used in read-only checks (section 7)

   FAIL-FAST BY DESIGN: the five CREATE statements deliberately have NO
   IF NOT EXISTS and NO OR REPLACE. If any A7 object already exists, the CREATE
   errors and "Run All" stops BEFORE anything is granted, attached or dropped on
   an object this script did not create.
   If the script stops part-way for another reason, re-run only from the
   failed statement onward.

   Compute: every statement is DDL or metadata (cloud services). The only possible
   exception, the SYSTEM$ SELECT at the very end, is pinned to the new A7
   warehouse, never a developer warehouse.
   ============================================================================= */

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- 0. Pre-flight (read-only). Run this block ON ITS OWN first; every result
--    must be empty. (The CREATEs below would also stop on a name clash.)
-- -----------------------------------------------------------------------------
SHOW ROLES             LIKE 'A7_PIPELINE_ROLE';
SHOW RESOURCE MONITORS LIKE 'A7_PIPELINE_RM';
SHOW WAREHOUSES        LIKE 'A7_PIPELINE_WH';
SHOW DATABASES         LIKE 'A7_ORDERS_DB';
SHOW INTEGRATIONS      LIKE 'A7_S3_INT';

-- -----------------------------------------------------------------------------
-- 1. Project role
--    Granted to SYSADMIN (standard hierarchy) and directly to the user that
--    deploys/operates the pipeline (<DEVELOPER_USER>), so that user can
--    USE ROLE A7_PIPELINE_ROLE without its other roles gaining privileges.
-- -----------------------------------------------------------------------------
CREATE ROLE A7_PIPELINE_ROLE
    COMMENT = 'Assignment 7 automated data pipeline - owns A7 database objects';

GRANT ROLE A7_PIPELINE_ROLE TO ROLE SYSADMIN;
GRANT ROLE A7_PIPELINE_ROLE TO USER <DEVELOPER_USER>;

-- -----------------------------------------------------------------------------
-- 2. Resource monitor: monthly 10-credit cap, attached ONLY to A7_PIPELINE_WH
--    (about USD 36/month at USD 3.60/credit)
--    100% -> SUSPEND (running queries finish); 110% -> SUSPEND_IMMEDIATE.
--    Resets monthly on the creation day. Serverless Snowpipe is not covered by
--    any warehouse monitor.
-- -----------------------------------------------------------------------------
CREATE RESOURCE MONITOR A7_PIPELINE_RM
    WITH CREDIT_QUOTA = 10
         FREQUENCY = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
         TRIGGERS ON 75  PERCENT DO NOTIFY
                  ON 90  PERCENT DO NOTIFY
                  ON 100 PERCENT DO SUSPEND
                  ON 110 PERCENT DO SUSPEND_IMMEDIATE;

-- Read-only visibility, so the project role can check its own quota usage.
GRANT MONITOR ON RESOURCE MONITOR A7_PIPELINE_RM TO ROLE A7_PIPELINE_ROLE;

-- -----------------------------------------------------------------------------
-- 3. Warehouse: X-Small, created SUSPENDED, monitor attached at creation
--    ACCOUNTADMIN stays OWNER, so the project role cannot resize it or detach
--    the monitor. It only gets USAGE (run DTs and tasks), OPERATE (suspend/resume)
--    and MONITOR (view). None of these statements resumes the warehouse.
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE A7_PIPELINE_WH
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    RESOURCE_MONITOR = A7_PIPELINE_RM
    STATEMENT_TIMEOUT_IN_SECONDS = 600
    STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 600
    COMMENT = 'Assignment 7 - Dynamic Table refresh and EOD task';

GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE A7_PIPELINE_WH TO ROLE A7_PIPELINE_ROLE;

-- -----------------------------------------------------------------------------
-- 4. Database: new, empty, owned by the project role
--    1-day Time Travel minimises storage cost. PUBLIC is the empty schema
--    auto-created a moment ago in THIS database. Because CREATE DATABASE above
--    has no IF NOT EXISTS, this DROP can never reach a pre-existing database.
-- -----------------------------------------------------------------------------
CREATE DATABASE A7_ORDERS_DB
    DATA_RETENTION_TIME_IN_DAYS = 1
    COMMENT = 'Assignment 7 automated data pipeline';

DROP SCHEMA A7_ORDERS_DB.PUBLIC;

GRANT OWNERSHIP ON DATABASE A7_ORDERS_DB TO ROLE A7_PIPELINE_ROLE COPY CURRENT GRANTS;

-- -----------------------------------------------------------------------------
-- 5. Storage integration: Snowflake -> S3 through an IAM role (no access keys)
--    Created BEFORE the AWS role exists; creation does not contact AWS.
--    Snowflake generates STORAGE_AWS_IAM_USER_ARN + STORAGE_AWS_EXTERNAL_ID
--    (section 7). The IAM role a7-snowflake-s3-access-role is then created
--    with the AWS CLI from infra/aws/iam/ (trust policy built from exactly
--    those two values; see docs/setup.md).
--    NEVER re-create this integration: a new one gets a new external ID.
--    Snowflake assumes the role through AWS STS in the Snowflake account's
--    region. If that is an opt-in AWS region (here ap-southeast-7), it must be
--    enabled on the AWS account.
-- -----------------------------------------------------------------------------
CREATE STORAGE INTEGRATION A7_S3_INT
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/a7-snowflake-s3-access-role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://a7-orders-pipeline-<AWS_ACCOUNT_ID>/landing/orders/')
    COMMENT = 'Assignment 7 - read-only access to the order landing prefix';

GRANT USAGE ON INTEGRATION A7_S3_INT TO ROLE A7_PIPELINE_ROLE;

-- -----------------------------------------------------------------------------
-- 6. Required for the EOD task: a task only runs if its OWNER role holds
--    EXECUTE TASK. This lets the role run ITS OWN tasks; it grants no access to
--    other roles' tasks or data.
-- -----------------------------------------------------------------------------
GRANT EXECUTE TASK ON ACCOUNT TO ROLE A7_PIPELINE_ROLE;

-- -----------------------------------------------------------------------------
-- 7. Verification + values to copy back (read-only, metadata only)
-- -----------------------------------------------------------------------------
-- Copy rows STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID
DESC INTEGRATION A7_S3_INT;
-- Expect: state SUSPENDED, size X-Small, auto_suspend 60, auto_resume true,
--         resource_monitor A7_PIPELINE_RM, owner ACCOUNTADMIN
SHOW WAREHOUSES LIKE 'A7_PIPELINE_WH';
-- Expect: credit_quota 10, used_credits 0, frequency MONTHLY, level WAREHOUSE,
--         suspend_at 100%, suspend_immediately_at 110%
SHOW RESOURCE MONITORS LIKE 'A7_PIPELINE_RM';
-- Expect: your existing developer warehouse is unchanged (same resource monitor)
SHOW WAREHOUSES LIKE '<DEVELOPER_WAREHOUSE>';
-- Expect: OWNERSHIP on A7_ORDERS_DB; USAGE/OPERATE/MONITOR on A7_PIPELINE_WH;
--         USAGE on A7_S3_INT; MONITOR on A7_PIPELINE_RM; EXECUTE TASK.
--         Nothing on any other warehouse.
SHOW GRANTS TO ROLE A7_PIPELINE_ROLE;
-- Every role inherits PUBLIC: check that PUBLIC has NO USAGE on <DEVELOPER_WAREHOUSE>
SHOW GRANTS TO ROLE PUBLIC;
-- Expect: DEFAULT_SECONDARY_ROLES = [] (an A7 session cannot borrow <DEVELOPER_ROLE>)
DESC USER <DEVELOPER_USER>;

-- -----------------------------------------------------------------------------
-- 8. SNS subscribe principal (LAST on purpose)
--    Pinned to the A7 warehouse in case the SELECT needs compute (at most one
--    60-second X-Small resume, about 0.017 credits). If this errors, nothing
--    above is affected (if needed, run it again after the SNS topic exists).
--    Copy: Statement[0].Principal.AWS
-- -----------------------------------------------------------------------------
USE WAREHOUSE A7_PIPELINE_WH;
SELECT SYSTEM$GET_AWS_SNS_IAM_POLICY('arn:aws:sns:ap-south-1:<AWS_ACCOUNT_ID>:a7-orders-s3-events') AS sns_policy;
