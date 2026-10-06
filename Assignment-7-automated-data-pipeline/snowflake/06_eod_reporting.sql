/* =============================================================================
   Assignment 7 - 06_eod_reporting.sql
   -----------------------------------------------------------------------------
   RUN AS: A7_PIPELINE_ROLE
       snow sql -c <connection> --role A7_PIPELINE_ROLE --warehouse A7_PIPELINE_WH -f snowflake/06_eod_reporting.sql

   Creates:
     REPORTING.EOD_DQ_SUMMARY        one row per IST business date (idempotent MERGE)
     REPORTING.SP_EOD_DQ_REPORT()    the EOD workflow
     REPORTING.TASK_EOD_DQ_REPORT    daily 23:55 Asia/Kolkata, created SUSPENDED

   Grants: none created here. A7_PIPELINE_ROLE owns the schema and holds EXECUTE TASK
   plus USAGE/OPERATE on A7_PIPELINE_WH (00_admin_bootstrap.sql), and USAGE on the
   email integration A7_EMAIL_INT (00b_admin_email_integration.sql).

   EMAIL (step 8 of the procedure, Snowflake-native, no AWS)
   - Runs only AFTER the summary row has been MERGEd. Subject and body are read
     back from that saved row:
       Subject: Assignment 7 EOD DQ Report - YYYY-MM-DD - <HEALTHY|WARNING|FAILED>
       Sent with SYSTEM$SEND_EMAIL('A7_EMAIL_INT', '<verified recipient>', subject, body)
   - DEPLOYMENT NOTE: the recipient in this file is the placeholder
     YOUR_EMAIL@example.com. Replace it with the verified address configured in
     A7_EMAIL_INT ALLOWED_RECIPIENTS (00b_admin_email_integration.sql) before
     running CREATE OR REPLACE PROCEDURE. Otherwise every send fails with
     "email=FAILED", which is recorded and does not affect the DQ results.
   - Delivery is isolated in its own exception block. If it fails, the saved row
     and PIPELINE_STATUS are left as they are (PIPELINE_STATUS describes the DQ
     pipeline, not email delivery). The outcome is appended to STATUS_DETAILS
     ("email=SENT" or "email=FAILED (...)") and to the procedure's return string.
   - Every CALL of the procedure (scheduled or manual) sends exactly one email.

   BUSINESS DATE (IST)
   - A record belongs to the IST calendar date of its INGESTION time, LOADED_AT_UTC
     (always present, also for BAD rows whose ORDER_TS is broken).
   - The window is computed explicitly, never from the session time zone
     (America/Los_Angeles):
       window_start_utc = CONVERT_TIMEZONE('Asia/Kolkata', 'UTC', report_date::TIMESTAMP_NTZ)
       window_end_utc   = window_start_utc + 1 day
   - The default date is today in IST:
       CONVERT_TIMEZONE('UTC', 'Asia/Kolkata', SYSDATE())::DATE
     At 23:55 IST this is the day being closed.
   - The hourly Lambda files land at about :35 IST (05 min past each UTC hour),
     so the last file of an IST day arrives at about 23:35 IST, before the 23:55 run.
   - Future dates are rejected. Past dates can be re-run (backfill / correction).

   DYNAMIC TABLES (TARGET_LAG = 6 hours)
   - GOOD/BAD may trail RAW by up to 6 hours, so the procedure first runs
       ALTER DYNAMIC TABLE ... REFRESH   (ORDERS_GOOD, then ORDERS_BAD)
     The statement is synchronous. Completion is still VERIFIED: the
     data_timestamp it returns must be >= the procedure start time, otherwise
     the run is FAILED.
   - Both refreshes and all reporting SQL run in this one procedure call, i.e.
     one A7_PIPELINE_WH session and at most one warehouse resume per day.
     With no new data a refresh returns "No new data" in cloud services.

   IDEMPOTENCY
   - MERGE on REPORT_DATE. A re-run updates the existing row (UPDATED_AT,
     RUN_COUNT + 1, CREATED_AT kept), so there is never a duplicate date.
   - Previous-day and 7-day history read only OTHER dates, so a re-run never
     counts its own earlier result.

   HISTORY / TREND (from EOD_DQ_SUMMARY, rows with TOTAL_RECORDS NOT NULL)
   - PREVIOUS_DAY_TOTAL = TOTAL_RECORDS of report_date - 1. NULL if that row
     does not exist (no fabricated zero).
   - 7-day window = report_date - 6 .. report_date (current day included).
       SEVEN_DAY_AVG_TOTAL = (sum of available prior days + today) / days available
       SEVEN_DAY_AVG_BAD_PERCENTAGE = mean of the daily BAD_PERCENTAGE values that
         exist (days with 0 records have no percentage and are skipped)
       SEVEN_DAY_DAYS_AVAILABLE records how many days were actually used.

   THRESHOLDS (documented, deterministic)
   - BAD rate >= 10 %                           -> "Attention" observation + WARNING
   - |volume change vs previous day| >= 25 %    -> "significant" increase/decrease
     observation (informational)

   PIPELINE_STATUS (evidence-based, not "the SQL ran")
   - FAILED if:
       * a DT refresh did not complete for this run
       * the DT classification differs from V_ORDERS_DQ for the same RAW row
       * curated rows do not exist in RAW
       * a RAW row appears more than once across GOOD + BAD
   - WARNING if:
       * Snowpipe executionState is not RUNNING
       * there are 0 records for the date
       * the BAD rate is >= 10 %
       * RAW rows of the date are not yet curated
   - HEALTHY otherwise.
   - Any runtime error writes a FAILED row (best effort) and re-raises, so the
     task history shows the failure.
   ============================================================================= */

USE ROLE A7_PIPELINE_ROLE;
USE DATABASE A7_ORDERS_DB;
USE SCHEMA REPORTING;

-- -----------------------------------------------------------------------------
-- 1. Reporting table (one row per IST business date)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS A7_ORDERS_DB.REPORTING.EOD_DQ_SUMMARY (
    REPORT_DATE                    DATE          NOT NULL,   -- IST business date (logical key)
    REPORT_TIMEZONE                VARCHAR(32)   NOT NULL,   -- 'Asia/Kolkata'
    WINDOW_START_UTC               TIMESTAMP_NTZ,
    WINDOW_END_UTC                 TIMESTAMP_NTZ,
    TOTAL_RECORDS                  NUMBER(12,0),
    GOOD_RECORDS                   NUMBER(12,0),
    BAD_RECORDS                    NUMBER(12,0),
    GOOD_PERCENTAGE                NUMBER(5,2),
    BAD_PERCENTAGE                 NUMBER(5,2),
    FILES_PROCESSED                NUMBER(6,0),
    BAD_REASON_SUMMARY             VARCHAR(1000),            -- e.g. DQ08_EMAIL_VALID=5; ...
    PREVIOUS_DAY_TOTAL             NUMBER(12,0),
    VOLUME_CHANGE                  NUMBER(12,0),
    VOLUME_CHANGE_PERCENTAGE       NUMBER(9,2),
    SEVEN_DAY_AVG_TOTAL            NUMBER(12,2),
    SEVEN_DAY_AVG_BAD_PERCENTAGE   NUMBER(5,2),
    SEVEN_DAY_DAYS_AVAILABLE       NUMBER(2,0),
    SEVEN_DAY_TREND                VARCHAR(400),             -- MM-DD:total | ...
    PIPELINE_STATUS                VARCHAR(10)   NOT NULL,   -- HEALTHY / WARNING / FAILED
    STATUS_DETAILS                 VARCHAR(1000),
    OBSERVATIONS                   VARCHAR(2000),
    CURATED_AS_OF_UTC              TIMESTAMP_NTZ,            -- min(data_timestamp) of both DTs after refresh
    CREATED_AT                     TIMESTAMP_NTZ NOT NULL,   -- UTC, first run for the date
    UPDATED_AT                     TIMESTAMP_NTZ NOT NULL,   -- UTC, latest run for the date
    RUN_COUNT                      NUMBER(6,0)   NOT NULL,
    CONSTRAINT PK_EOD_DQ_SUMMARY PRIMARY KEY (REPORT_DATE)   -- informational; MERGE enforces uniqueness
)
COMMENT = 'Assignment 7 - daily (IST) data quality summary, one row per REPORT_DATE';

-- -----------------------------------------------------------------------------
-- 2. EOD procedure
--    CALL A7_ORDERS_DB.REPORTING.SP_EOD_DQ_REPORT();                    -- today (IST)
--    CALL A7_ORDERS_DB.REPORTING.SP_EOD_DQ_REPORT('2026-10-05'::DATE);  -- specific date
--    Every CALL refreshes both dynamic tables and SENDS ONE EMAIL.
--    EXECUTE AS OWNER: runs with A7_PIPELINE_ROLE's privileges (DT refresh, pipe
--    status, email integration usage) regardless of who calls it.
--    CREATE OR REPLACE replaces the live procedure. Substitute the recipient
--    placeholder before re-running this statement in production.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE A7_ORDERS_DB.REPORTING.SP_EOD_DQ_REPORT(P_REPORT_DATE DATE DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Assignment 7 - EOD DQ report: refresh GOOD/BAD DTs, reconcile, summarise, MERGE into EOD_DQ_SUMMARY'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_tz                 VARCHAR DEFAULT 'Asia/Kolkata';
    v_bad_threshold      NUMBER(5,2) DEFAULT 10;
    v_volume_threshold   NUMBER(5,2) DEFAULT 25;
    v_started_utc        TIMESTAMP_NTZ;
    v_today_ist          DATE;
    v_report_date        DATE;
    v_win_start          TIMESTAMP_NTZ;
    v_win_end            TIMESTAMP_NTZ;
    v_good_ts            TIMESTAMP_NTZ;
    v_bad_ts             TIMESTAMP_NTZ;
    v_curated_asof       TIMESTAMP_NTZ;
    v_refresh_ok         BOOLEAN;
    v_good               NUMBER;
    v_bad                NUMBER;
    v_total              NUMBER;
    v_files              NUMBER;
    v_reason_summary     VARCHAR;
    v_top_reason         VARCHAR;
    v_raw_rows           NUMBER;
    v_class_mismatch     NUMBER;
    v_raw_not_curated    NUMBER;
    v_curated_not_raw    NUMBER;
    v_dup_keys           NUMBER;
    v_pipe_state         VARCHAR;
    v_good_pct           NUMBER(5,2);
    v_bad_pct            NUMBER(5,2);
    v_prev_total         NUMBER;
    v_vol_change         NUMBER;
    v_vol_change_pct     NUMBER(9,2);
    v_hist_days          NUMBER;
    v_hist_total_sum     NUMBER;
    v_hist_bad_sum       NUMBER(12,2);
    v_hist_bad_n         NUMBER;
    v_hist_trend         VARCHAR;
    v_days               NUMBER;
    v_avg_total          NUMBER(12,2);
    v_avg_bad            NUMBER(5,2);
    v_trend              VARCHAR;
    v_status             VARCHAR;
    v_details            VARCHAR;
    v_obs                VARCHAR;
    v_err                VARCHAR;
    -- email notification (step 8)
    v_subject            VARCHAR;
    v_body               VARCHAR;
    v_email_sent         BOOLEAN;
    v_email_status       VARCHAR DEFAULT 'NOT_ATTEMPTED';
    future_date_error    EXCEPTION (-20001, 'REPORT_DATE is in the future (IST)');
BEGIN
    -- ---- run context (explicit UTC / IST, never the session time zone) -----
    SELECT SYSDATE(), CONVERT_TIMEZONE('UTC', :v_tz, SYSDATE())::DATE
      INTO :v_started_utc, :v_today_ist;
    v_report_date := COALESCE(P_REPORT_DATE, v_today_ist);
    IF (v_report_date > v_today_ist) THEN
        RAISE future_date_error;
    END IF;
    SELECT CONVERT_TIMEZONE(:v_tz, 'UTC', :v_report_date::TIMESTAMP_NTZ),
           DATEADD(DAY, 1, CONVERT_TIMEZONE(:v_tz, 'UTC', :v_report_date::TIMESTAMP_NTZ))
      INTO :v_win_start, :v_win_end;

    -- ---- 1. bring both DTs up to date (TARGET_LAG is 6 hours), then verify --
    -- ALTER ... REFRESH returns one row with "data_timestamp" (the point in time
    -- the table now reflects). It is read back through RESULT_SCAN and must be
    -- at or after this run's start; otherwise the report would describe stale data.
    ALTER DYNAMIC TABLE A7_ORDERS_DB.CURATED.ORDERS_GOOD REFRESH;
    SELECT CONVERT_TIMEZONE('UTC', "data_timestamp"::TIMESTAMP_LTZ)::TIMESTAMP_NTZ
      INTO :v_good_ts FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    ALTER DYNAMIC TABLE A7_ORDERS_DB.CURATED.ORDERS_BAD REFRESH;
    SELECT CONVERT_TIMEZONE('UTC', "data_timestamp"::TIMESTAMP_LTZ)::TIMESTAMP_NTZ
      INTO :v_bad_ts FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    v_curated_asof := LEAST(v_good_ts, v_bad_ts);
    v_refresh_ok   := (v_good_ts >= v_started_utc AND v_bad_ts >= v_started_utc);

    -- ---- 2. counts for the business date ----------------------------------
    SELECT COUNT(*) INTO :v_good FROM A7_ORDERS_DB.CURATED.ORDERS_GOOD
     WHERE LOADED_AT_UTC >= :v_win_start AND LOADED_AT_UTC < :v_win_end;
    SELECT COUNT(*) INTO :v_bad FROM A7_ORDERS_DB.CURATED.ORDERS_BAD
     WHERE LOADED_AT_UTC >= :v_win_start AND LOADED_AT_UTC < :v_win_end;
    v_total := v_good + v_bad;

    SELECT COUNT(DISTINCT SOURCE_FILE) INTO :v_files FROM (
        SELECT SOURCE_FILE FROM A7_ORDERS_DB.CURATED.ORDERS_GOOD
         WHERE LOADED_AT_UTC >= :v_win_start AND LOADED_AT_UTC < :v_win_end
        UNION ALL
        SELECT SOURCE_FILE FROM A7_ORDERS_DB.CURATED.ORDERS_BAD
         WHERE LOADED_AT_UTC >= :v_win_start AND LOADED_AT_UTC < :v_win_end);

    -- Failures per rule code (a BAD row can carry several codes), most frequent first;
    -- ties are broken alphabetically. The first entry is the most frequent failure.
    SELECT LISTAGG(code || '=' || n, '; ') WITHIN GROUP (ORDER BY n DESC, code)
      INTO :v_reason_summary
      FROM (SELECT f.VALUE::VARCHAR AS code, COUNT(*) AS n
              FROM A7_ORDERS_DB.CURATED.ORDERS_BAD b,
                   TABLE(SPLIT_TO_TABLE(b.QUALITY_REASON, ';')) f
             WHERE b.LOADED_AT_UTC >= :v_win_start AND b.LOADED_AT_UTC < :v_win_end
             GROUP BY f.VALUE::VARCHAR);
    v_top_reason := NULLIF(SPLIT_PART(COALESCE(v_reason_summary, ''), '; ', 1), '');

    -- ---- 3. evidence: RAW vs curated reconciliation (same date window) -----
    -- V_ORDERS_DQ re-evaluates the DQ rules on RAW; the DTs must agree with it.
    SELECT COUNT_IF(v.SOURCE_FILE IS NOT NULL),
           COUNT_IF(v.SOURCE_FILE IS NOT NULL AND d.SOURCE_FILE IS NOT NULL
                    AND (v.QUALITY_STATUS IS DISTINCT FROM d.QUALITY_STATUS
                         OR v.QUALITY_REASON IS DISTINCT FROM d.QUALITY_REASON)),
           COUNT_IF(d.SOURCE_FILE IS NULL),
           COUNT_IF(v.SOURCE_FILE IS NULL)
      INTO :v_raw_rows, :v_class_mismatch, :v_raw_not_curated, :v_curated_not_raw
      FROM (SELECT SOURCE_FILE, SOURCE_ROW_NUMBER, QUALITY_STATUS, QUALITY_REASON
              FROM A7_ORDERS_DB.CURATED.V_ORDERS_DQ
             WHERE LOADED_AT_UTC >= :v_win_start AND LOADED_AT_UTC < :v_win_end) v
      FULL OUTER JOIN
           (SELECT SOURCE_FILE, SOURCE_ROW_NUMBER, QUALITY_STATUS, QUALITY_REASON
              FROM A7_ORDERS_DB.CURATED.ORDERS_GOOD
             WHERE LOADED_AT_UTC >= :v_win_start AND LOADED_AT_UTC < :v_win_end
            UNION ALL
            SELECT SOURCE_FILE, SOURCE_ROW_NUMBER, QUALITY_STATUS, QUALITY_REASON
              FROM A7_ORDERS_DB.CURATED.ORDERS_BAD
             WHERE LOADED_AT_UTC >= :v_win_start AND LOADED_AT_UTC < :v_win_end) d
        ON v.SOURCE_FILE = d.SOURCE_FILE AND v.SOURCE_ROW_NUMBER = d.SOURCE_ROW_NUMBER;

    SELECT COUNT(*) INTO :v_dup_keys FROM (
        SELECT SOURCE_FILE, SOURCE_ROW_NUMBER FROM (
            SELECT SOURCE_FILE, SOURCE_ROW_NUMBER FROM A7_ORDERS_DB.CURATED.ORDERS_GOOD
             WHERE LOADED_AT_UTC >= :v_win_start AND LOADED_AT_UTC < :v_win_end
            UNION ALL
            SELECT SOURCE_FILE, SOURCE_ROW_NUMBER FROM A7_ORDERS_DB.CURATED.ORDERS_BAD
             WHERE LOADED_AT_UTC >= :v_win_start AND LOADED_AT_UTC < :v_win_end)
        GROUP BY SOURCE_FILE, SOURCE_ROW_NUMBER HAVING COUNT(*) > 1);

    SELECT PARSE_JSON(SYSTEM$PIPE_STATUS('A7_ORDERS_DB.RAW.PIPE_ORDERS_INGEST')):executionState::VARCHAR
      INTO :v_pipe_state;

    -- ---- 4. percentages, previous day, 7-day trend -------------------------
    -- A day with 0 records gets NULL percentages (not 0 %, not a division error).
    v_good_pct := IFF(v_total = 0, NULL, ROUND(100 * v_good / v_total, 2));
    v_bad_pct  := IFF(v_total = 0, NULL, ROUND(100 * v_bad  / v_total, 2));

    SELECT MAX(TOTAL_RECORDS) INTO :v_prev_total
      FROM A7_ORDERS_DB.REPORTING.EOD_DQ_SUMMARY
     WHERE REPORT_DATE = DATEADD(DAY, -1, :v_report_date) AND TOTAL_RECORDS IS NOT NULL;
    v_vol_change     := IFF(v_prev_total IS NULL, NULL, v_total - v_prev_total);
    v_vol_change_pct := IFF(v_prev_total IS NULL OR v_prev_total = 0, NULL,
                            ROUND(100 * (v_total - v_prev_total) / v_prev_total, 2));

    SELECT COUNT(*), COALESCE(SUM(TOTAL_RECORDS), 0), COALESCE(SUM(BAD_PERCENTAGE), 0), COUNT(BAD_PERCENTAGE),
           LISTAGG(TO_VARCHAR(REPORT_DATE, 'MM-DD') || ':' || TOTAL_RECORDS, ' | ') WITHIN GROUP (ORDER BY REPORT_DATE)
      INTO :v_hist_days, :v_hist_total_sum, :v_hist_bad_sum, :v_hist_bad_n, :v_hist_trend
      FROM A7_ORDERS_DB.REPORTING.EOD_DQ_SUMMARY
     WHERE REPORT_DATE BETWEEN DATEADD(DAY, -6, :v_report_date) AND DATEADD(DAY, -1, :v_report_date)
       AND TOTAL_RECORDS IS NOT NULL;
    v_days      := v_hist_days + 1;
    v_avg_total := ROUND((v_hist_total_sum + v_total) / v_days, 2);
    v_avg_bad   := IFF(v_hist_bad_n + IFF(v_bad_pct IS NULL, 0, 1) = 0, NULL,
                       ROUND((v_hist_bad_sum + COALESCE(v_bad_pct, 0))
                             / (v_hist_bad_n + IFF(v_bad_pct IS NULL, 0, 1)), 2));
    v_trend := IFF(v_hist_trend IS NULL OR v_hist_trend = '', '', v_hist_trend || ' | ')
               || TO_VARCHAR(v_report_date, 'MM-DD') || ':' || v_total;

    -- ---- 5. pipeline status from evidence ----------------------------------
    IF (NOT v_refresh_ok OR v_class_mismatch > 0 OR v_curated_not_raw > 0 OR v_dup_keys > 0) THEN
        v_status := 'FAILED';
    ELSEIF (v_pipe_state IS DISTINCT FROM 'RUNNING' OR v_total = 0
            OR v_bad_pct >= v_bad_threshold OR v_raw_not_curated > 0) THEN
        v_status := 'WARNING';
    ELSE
        v_status := 'HEALTHY';
    END IF;
    v_details := 'refresh_verified=' || IFF(v_refresh_ok, 'Y', 'N')
              || '; curated_as_of_utc=' || TO_VARCHAR(v_curated_asof, 'YYYY-MM-DD HH24:MI:SS')
              || '; raw_rows=' || v_raw_rows || '; curated_rows=' || v_total
              || '; classification_mismatch=' || v_class_mismatch
              || '; raw_not_curated=' || v_raw_not_curated
              || '; curated_not_in_raw=' || v_curated_not_raw
              || '; duplicate_row_keys=' || v_dup_keys
              || '; snowpipe=' || COALESCE(v_pipe_state, 'UNKNOWN');

    -- ---- 6. observations (deterministic, thresholds documented in header) --
    IF (v_total = 0) THEN
        v_obs := 'No records processed for this business date.';
    ELSEIF (v_bad_pct >= v_bad_threshold) THEN
        v_obs := 'Attention: BAD rate ' || v_bad_pct || '% is at or above the ' || v_bad_threshold || '% threshold.';
    ELSE
        v_obs := 'BAD rate ' || v_bad_pct || '% is below the ' || v_bad_threshold || '% threshold.';
    END IF;
    IF (v_prev_total IS NULL) THEN
        v_obs := v_obs || ' No previous-day comparison available.';
    ELSEIF (v_prev_total = 0) THEN
        v_obs := v_obs || ' Previous day had 0 records; percentage change not computable.';
    ELSEIF (v_vol_change_pct >= v_volume_threshold) THEN
        v_obs := v_obs || ' Volume increased significantly (+' || v_vol_change_pct || '%) versus previous day.';
    ELSEIF (v_vol_change_pct <= -v_volume_threshold) THEN
        v_obs := v_obs || ' Volume decreased significantly (' || v_vol_change_pct || '%) versus previous day.';
    ELSE
        v_obs := v_obs || ' Volume stable versus previous day (' || v_vol_change_pct || '%).';
    END IF;
    IF (v_top_reason IS NOT NULL) THEN
        v_obs := v_obs || ' Most frequent failure: ' || v_top_reason || '.';
    END IF;
    v_obs := v_obs || ' Files processed: ' || v_files || '.'
                   || ' 7-day figures use ' || v_days || ' of 7 days.';
    IF (v_raw_not_curated > 0) THEN
        v_obs := v_obs || ' ' || v_raw_not_curated || ' RAW rows not yet curated.';
    END IF;
    IF (v_pipe_state IS DISTINCT FROM 'RUNNING') THEN
        v_obs := v_obs || ' Snowpipe state: ' || COALESCE(v_pipe_state, 'UNKNOWN') || '.';
    END IF;

    -- ---- 7. idempotent upsert ----------------------------------------------
    MERGE INTO A7_ORDERS_DB.REPORTING.EOD_DQ_SUMMARY t
    USING (SELECT :v_report_date AS REPORT_DATE) s
       ON t.REPORT_DATE = s.REPORT_DATE
    WHEN MATCHED THEN UPDATE SET
        REPORT_TIMEZONE = :v_tz, WINDOW_START_UTC = :v_win_start, WINDOW_END_UTC = :v_win_end,
        TOTAL_RECORDS = :v_total, GOOD_RECORDS = :v_good, BAD_RECORDS = :v_bad,
        GOOD_PERCENTAGE = :v_good_pct, BAD_PERCENTAGE = :v_bad_pct, FILES_PROCESSED = :v_files,
        BAD_REASON_SUMMARY = :v_reason_summary, PREVIOUS_DAY_TOTAL = :v_prev_total,
        VOLUME_CHANGE = :v_vol_change, VOLUME_CHANGE_PERCENTAGE = :v_vol_change_pct,
        SEVEN_DAY_AVG_TOTAL = :v_avg_total, SEVEN_DAY_AVG_BAD_PERCENTAGE = :v_avg_bad,
        SEVEN_DAY_DAYS_AVAILABLE = :v_days, SEVEN_DAY_TREND = :v_trend,
        PIPELINE_STATUS = :v_status, STATUS_DETAILS = :v_details, OBSERVATIONS = :v_obs,
        CURATED_AS_OF_UTC = :v_curated_asof, UPDATED_AT = :v_started_utc, RUN_COUNT = t.RUN_COUNT + 1
    WHEN NOT MATCHED THEN INSERT (
        REPORT_DATE, REPORT_TIMEZONE, WINDOW_START_UTC, WINDOW_END_UTC,
        TOTAL_RECORDS, GOOD_RECORDS, BAD_RECORDS, GOOD_PERCENTAGE, BAD_PERCENTAGE, FILES_PROCESSED,
        BAD_REASON_SUMMARY, PREVIOUS_DAY_TOTAL, VOLUME_CHANGE, VOLUME_CHANGE_PERCENTAGE,
        SEVEN_DAY_AVG_TOTAL, SEVEN_DAY_AVG_BAD_PERCENTAGE, SEVEN_DAY_DAYS_AVAILABLE, SEVEN_DAY_TREND,
        PIPELINE_STATUS, STATUS_DETAILS, OBSERVATIONS, CURATED_AS_OF_UTC, CREATED_AT, UPDATED_AT, RUN_COUNT)
    VALUES (
        :v_report_date, :v_tz, :v_win_start, :v_win_end,
        :v_total, :v_good, :v_bad, :v_good_pct, :v_bad_pct, :v_files,
        :v_reason_summary, :v_prev_total, :v_vol_change, :v_vol_change_pct,
        :v_avg_total, :v_avg_bad, :v_days, :v_trend,
        :v_status, :v_details, :v_obs, :v_curated_asof, :v_started_utc, :v_started_utc, 1);

    -- ---- 8. EOD email: only AFTER the summary row is saved -----------------
    -- Subject/body are built from the row just MERGEd (no recalculation).
    -- Isolated in its own block: an email failure never undoes or changes the saved
    -- DQ results and never sets PIPELINE_STATUS (DQ status != email delivery status).
    -- The outcome is appended to STATUS_DETAILS as "email=SENT" / "email=FAILED (...)".
    BEGIN
        SELECT 'Assignment 7 EOD DQ Report - ' || TO_VARCHAR(REPORT_DATE, 'YYYY-MM-DD') || ' - ' || PIPELINE_STATUS,
               'Assignment 7 - EOD Data Quality Report'
            || '\n\nReport date (IST): ' || TO_VARCHAR(REPORT_DATE, 'YYYY-MM-DD')
            || '\nPipeline status: ' || PIPELINE_STATUS
            || '\n\nTotal records: ' || COALESCE(TO_VARCHAR(TOTAL_RECORDS), 'n/a')
            || '\nGOOD records: ' || COALESCE(TO_VARCHAR(GOOD_RECORDS), 'n/a')
                || ' (' || COALESCE(TO_VARCHAR(GOOD_PERCENTAGE) || '%', 'n/a') || ')'
            || '\nBAD records: ' || COALESCE(TO_VARCHAR(BAD_RECORDS), 'n/a')
                || ' (' || COALESCE(TO_VARCHAR(BAD_PERCENTAGE) || '%', 'n/a') || ')'
            || '\nFiles processed: ' || COALESCE(TO_VARCHAR(FILES_PROCESSED), 'n/a')
            || '\n\nPrevious-day total: ' || COALESCE(TO_VARCHAR(PREVIOUS_DAY_TOTAL), 'n/a (no previous-day report)')
            || '\nVolume change: ' || COALESCE(TO_VARCHAR(VOLUME_CHANGE), 'n/a')
                || ' (' || COALESCE(TO_VARCHAR(VOLUME_CHANGE_PERCENTAGE) || '%', 'n/a') || ')'
            || '\n7-day average total: ' || COALESCE(TO_VARCHAR(SEVEN_DAY_AVG_TOTAL), 'n/a')
            || '\n7-day average BAD %: ' || COALESCE(TO_VARCHAR(SEVEN_DAY_AVG_BAD_PERCENTAGE) || '%', 'n/a')
            || '\n7-day days available: ' || COALESCE(TO_VARCHAR(SEVEN_DAY_DAYS_AVAILABLE), 'n/a') || ' of 7'
            || '\n7-day trend (MM-DD:total): ' || COALESCE(SEVEN_DAY_TREND, 'n/a')
            || '\n\nTop DQ failure reasons (rule=count, most frequent first):\n'
                || COALESCE(REPLACE(BAD_REASON_SUMMARY, '; ', '\n'), 'none')
            || '\n\nPipeline status details:\n' || COALESCE(REPLACE(STATUS_DETAILS, '; ', '\n'), 'n/a')
            || '\n\nObservations:\n' || COALESCE(OBSERVATIONS, 'n/a')
            || '\n\nCurated data as of (UTC): ' || COALESCE(TO_VARCHAR(CURATED_AS_OF_UTC, 'YYYY-MM-DD HH24:MI:SS'), 'n/a')
            || '\nReport window (UTC): ' || COALESCE(TO_VARCHAR(WINDOW_START_UTC, 'YYYY-MM-DD HH24:MI'), 'n/a')
                || ' to ' || COALESCE(TO_VARCHAR(WINDOW_END_UTC, 'YYYY-MM-DD HH24:MI'), 'n/a')
            || '\n\nGenerated by A7_ORDERS_DB.REPORTING.SP_EOD_DQ_REPORT (run ' || RUN_COUNT || ' for this date).'
          INTO :v_subject, :v_body
          FROM A7_ORDERS_DB.REPORTING.EOD_DQ_SUMMARY
         WHERE REPORT_DATE = :v_report_date;

        -- Recipient placeholder: replace YOUR_EMAIL@example.com with the verified address
        -- listed in A7_EMAIL_INT ALLOWED_RECIPIENTS before deploying. The public repository
        -- never contains the real address.
        CALL SYSTEM$SEND_EMAIL('A7_EMAIL_INT', 'YOUR_EMAIL@example.com', :v_subject, :v_body);
        SELECT $1::BOOLEAN INTO :v_email_sent FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        v_email_status := IFF(v_email_sent, 'SENT', 'FAILED (SYSTEM$SEND_EMAIL returned FALSE)');
    EXCEPTION
        WHEN OTHER THEN
            v_email_status := 'FAILED (' || LEFT(SQLERRM, 300) || ')';
    END;
    UPDATE A7_ORDERS_DB.REPORTING.EOD_DQ_SUMMARY
       SET STATUS_DETAILS = LEFT(COALESCE(STATUS_DETAILS, '') || '; email=' || :v_email_status, 1000)
     WHERE REPORT_DATE = :v_report_date;

    RETURN 'SUCCESS report_date=' || v_report_date || ' status=' || v_status
        || ' total=' || v_total || ' good=' || v_good || ' bad=' || v_bad
        || ' bad_pct=' || COALESCE(TO_VARCHAR(v_bad_pct), 'n/a')
        || ' prev_total=' || COALESCE(TO_VARCHAR(v_prev_total), 'n/a')
        || ' days_7d=' || v_days || ' curated_as_of_utc=' || TO_VARCHAR(v_curated_asof, 'YYYY-MM-DD HH24:MI:SS')
        || ' email=' || v_email_status;

EXCEPTION
    WHEN OTHER THEN
        v_err := 'SQLCODE=' || SQLCODE || ' STATE=' || SQLSTATE || ' ' || SQLERRM;
        IF (v_report_date IS NOT NULL AND v_report_date <= v_today_ist) THEN
            BEGIN
                MERGE INTO A7_ORDERS_DB.REPORTING.EOD_DQ_SUMMARY t
                USING (SELECT :v_report_date AS REPORT_DATE) s
                   ON t.REPORT_DATE = s.REPORT_DATE
                WHEN MATCHED THEN UPDATE SET
                    PIPELINE_STATUS = 'FAILED', STATUS_DETAILS = LEFT(:v_err, 1000),
                    OBSERVATIONS = 'EOD run failed; see STATUS_DETAILS.', UPDATED_AT = SYSDATE(),
                    RUN_COUNT = t.RUN_COUNT + 1
                WHEN NOT MATCHED THEN INSERT (REPORT_DATE, REPORT_TIMEZONE, PIPELINE_STATUS, STATUS_DETAILS,
                                              OBSERVATIONS, CREATED_AT, UPDATED_AT, RUN_COUNT)
                VALUES (:v_report_date, :v_tz, 'FAILED', LEFT(:v_err, 1000),
                        'EOD run failed; see STATUS_DETAILS.', SYSDATE(), SYSDATE(), 1);
            EXCEPTION
                WHEN OTHER THEN NULL;
            END;
        END IF;
        RAISE;
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. Daily task: 23:55 IST. Tasks are created SUSPENDED; do NOT resume until approved.
--    Runs on A7_PIPELINE_WH (same warehouse as the DT refreshes it triggers).
--    The CRON time zone is explicit (Asia/Kolkata), independent of the account
--    time zone. Overlapping runs are not allowed (Snowflake default), and
--    USER_TASK_TIMEOUT_MS = 600000 stops a run after 10 minutes.
--    CAUTION: CREATE OR REPLACE TASK recreates the task in the SUSPENDED state.
--    Re-running this statement against a live deployment stops the daily
--    report until ALTER TASK ... RESUME is run again.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK A7_ORDERS_DB.REPORTING.TASK_EOD_DQ_REPORT
    WAREHOUSE = A7_PIPELINE_WH
    SCHEDULE = 'USING CRON 55 23 * * * Asia/Kolkata'
    USER_TASK_TIMEOUT_MS = 600000
    COMMENT = 'Assignment 7 - daily 23:55 IST EOD DQ report (calls SP_EOD_DQ_REPORT)'
AS
    CALL A7_ORDERS_DB.REPORTING.SP_EOD_DQ_REPORT();

-- To enable later (approval required):
--   ALTER TASK A7_ORDERS_DB.REPORTING.TASK_EOD_DQ_REPORT RESUME;

-- -----------------------------------------------------------------------------
-- 4. Verification
-- -----------------------------------------------------------------------------
SHOW TASKS LIKE 'TASK_EOD_DQ_REPORT' IN SCHEMA A7_ORDERS_DB.REPORTING;   -- expect state = suspended
SHOW USER PROCEDURES LIKE 'SP_EOD_DQ_REPORT' IN SCHEMA A7_ORDERS_DB.REPORTING;
-- Manual run (needs the warehouse):
--   CALL A7_ORDERS_DB.REPORTING.SP_EOD_DQ_REPORT();
--   SELECT * FROM A7_ORDERS_DB.REPORTING.EOD_DQ_SUMMARY ORDER BY REPORT_DATE DESC;
