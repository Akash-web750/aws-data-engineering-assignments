/* =============================================================================
   Assignment 7 - 00b_admin_email_integration.sql
   -----------------------------------------------------------------------------
   RUN MANUALLY, ONCE, AS ACCOUNTADMIN (Snowsight) - after the prerequisite below.
   ORDER: before 06_eod_reporting.sql (the EOD procedure sends through this
   integration). Independent of the ingestion scripts 01-05.

   Purpose: Snowflake-native email for the EOD DQ report (no AWS / SES / Lambda).
   The report procedure (owner A7_PIPELINE_ROLE) will call
       SYSTEM$SEND_EMAIL('A7_EMAIL_INT', '<recipient>', '<subject>', '<body>')

   PREREQUISITE (manual, Snowsight UI)
     Snowflake only delivers to email addresses that are VERIFIED on a user of
     this account. Sign in as the user whose address will receive the report
     (e.g. your own admin login), open  avatar menu -> Settings -> Profile,
     make sure Email is filled in, and click the verification link Snowflake
     sends to that inbox. The profile then shows the address as verified.
     (A service/automation user without an email cannot be the recipient.)

   Then replace <VERIFIED_EMAIL> below (2 places) and run.
   Creates nothing else; no warehouse is used.
   ============================================================================= */

USE ROLE ACCOUNTADMIN;

-- Pre-flight: must return no rows
SHOW NOTIFICATION INTEGRATIONS LIKE 'A7_EMAIL_INT';

-- Restrict delivery to the verified recipient only. Even a role with USAGE on the
-- integration cannot email any other address, which limits misuse if the
-- procedure (or a user of A7_PIPELINE_ROLE) passes a different recipient.
CREATE NOTIFICATION INTEGRATION A7_EMAIL_INT
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('<VERIFIED_EMAIL>')
    COMMENT = 'Assignment 7 - EOD data quality report email';

-- The EOD procedure runs with owner's rights as A7_PIPELINE_ROLE
GRANT USAGE ON INTEGRATION A7_EMAIL_INT TO ROLE A7_PIPELINE_ROLE;

-- Verification (read-only)
DESC NOTIFICATION INTEGRATION A7_EMAIL_INT;      -- expect ENABLED=true, ALLOWED_RECIPIENTS=<VERIFIED_EMAIL>
SHOW GRANTS ON INTEGRATION A7_EMAIL_INT;         -- expect USAGE -> A7_PIPELINE_ROLE
