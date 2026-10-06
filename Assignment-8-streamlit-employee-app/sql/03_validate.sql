-- =============================================================================
-- Assignment 8 - Employee Manager
-- 03_validate.sql : read-only checks on the EMPLOYEES table
--
-- Changes nothing. Every check in section 2 should return ISSUES = 0.
-- Run with:  snow sql -c <connection> -f sql/03_validate.sql
-- =============================================================================

-- 1. Overview: row counts and value ranges.
SELECT
    COUNT(*)                          AS TOTAL_EMPLOYEES,
    COUNT_IF(IS_ACTIVE)               AS ACTIVE_EMPLOYEES,
    COUNT_IF(IS_REMOTE)               AS REMOTE_EMPLOYEES,
    COUNT(DISTINCT DEPARTMENT)        AS DEPARTMENTS,
    COUNT(DISTINCT WORK_LOCATION)     AS LOCATIONS,
    MIN(SALARY)                       AS MIN_SALARY,
    MAX(SALARY)                       AS MAX_SALARY,
    MIN(HIRE_DATE)                    AS FIRST_HIRE_DATE,
    MAX(HIRE_DATE)                    AS LAST_HIRE_DATE
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES;

-- 2. Data-quality checks: the same rules the app enforces in validation.py.
SELECT 'Duplicate employee IDs' AS CHECK_NAME,
       COUNT(*) - COUNT(DISTINCT EMPLOYEE_ID) AS ISSUES
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES
UNION ALL
SELECT 'Duplicate e-mail addresses',
       COUNT(*) - COUNT(DISTINCT LOWER(EMAIL))
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES
UNION ALL
SELECT 'Younger than 18 on the hire date',
       COUNT_IF(DATEADD(year, 18, DATE_OF_BIRTH) > HIRE_DATE)
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES
UNION ALL
SELECT 'Salary not above zero',
       COUNT_IF(SALARY <= 0)
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES
UNION ALL
SELECT 'Experience outside 0-50 years',
       COUNT_IF(EXPERIENCE_YEARS < 0 OR EXPERIENCE_YEARS > 50)
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES
UNION ALL
SELECT 'Unknown employment type',
       COUNT_IF(EMPLOYMENT_TYPE NOT IN ('Full-time', 'Part-time', 'Contract', 'Intern'))
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES
UNION ALL
SELECT 'More than 10 skills',
       COUNT_IF(ARRAY_SIZE(SKILLS) > 10)
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES;

-- 3. Headcount and average salary by department.
SELECT
    DEPARTMENT,
    COUNT(*)               AS EMPLOYEES,
    COUNT_IF(IS_ACTIVE)    AS ACTIVE,
    ROUND(AVG(SALARY))     AS AVERAGE_SALARY
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES
GROUP BY DEPARTMENT
ORDER BY DEPARTMENT;

-- 4. The ten most recently changed employees: the quickest way to confirm that
--    an Add or Edit made in the app reached the table.
SELECT EMPLOYEE_ID, FIRST_NAME, LAST_NAME, DEPARTMENT, JOB_TITLE, SALARY,
       IS_ACTIVE, CREATED_AT, UPDATED_AT
FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES
ORDER BY UPDATED_AT DESC, EMPLOYEE_ID DESC
LIMIT 10;
