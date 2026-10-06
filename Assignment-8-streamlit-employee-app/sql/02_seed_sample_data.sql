-- =============================================================================
-- Assignment 8 - Employee Manager
-- 02_seed_sample_data.sql : 60 sample employees
--
-- Every value is derived from the row number with HASH, not RANDOM, so each
-- run produces exactly the same 60 employees.
-- Safe to run again: rows are inserted only when the table is empty.
-- Run with:  snow sql -c <connection> -f sql/02_seed_sample_data.sql
-- =============================================================================

INSERT INTO AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES (
    FIRST_NAME, LAST_NAME, EMAIL, PHONE, GENDER, DATE_OF_BIRTH,
    DEPARTMENT, JOB_TITLE, EMPLOYMENT_TYPE, WORK_LOCATION, HIRE_DATE,
    SALARY, EXPERIENCE_YEARS, SKILLS, IS_ACTIVE, IS_REMOTE, NOTES
)
WITH
-- Row numbers 0..59; N drives every generated value below.
numbers AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS N
    FROM TABLE(GENERATOR(ROWCOUNT => 60))
),
-- 30 first names, each with a matching gender.
first_names (IDX, FIRST_NAME, GENDER) AS (
    SELECT * FROM VALUES
        (0,  'Aarav',   'Male'),   (1,  'Ananya',  'Female'), (2,  'Rohan',   'Male'),
        (3,  'Priya',   'Female'), (4,  'Vikram',  'Male'),   (5,  'Sneha',   'Female'),
        (6,  'Arjun',   'Male'),   (7,  'Kavya',   'Female'), (8,  'Karan',   'Male'),
        (9,  'Meera',   'Female'), (10, 'Rahul',   'Male'),   (11, 'Isha',    'Female'),
        (12, 'Aditya',  'Male'),   (13, 'Neha',    'Female'), (14, 'Siddharth','Male'),
        (15, 'Pooja',   'Female'), (16, 'Manish',  'Male'),   (17, 'Divya',   'Female'),
        (18, 'Nikhil',  'Male'),   (19, 'Riya',    'Female'), (20, 'Varun',   'Male'),
        (21, 'Shreya',  'Female'), (22, 'Amit',    'Male'),   (23, 'Tanvi',   'Female'),
        (24, 'Deepak',  'Male'),   (25, 'Aisha',   'Female'), (26, 'Harsh',   'Male'),
        (27, 'Nandini', 'Female'), (28, 'Kunal',   'Male'),   (29, 'Sana',    'Female')
),
-- 20 last names.
last_names (IDX, LAST_NAME) AS (
    SELECT * FROM VALUES
        (0, 'Sharma'),  (1, 'Patil'),    (2, 'Iyer'),     (3, 'Reddy'),   (4, 'Gupta'),
        (5, 'Nair'),    (6, 'Deshmukh'), (7, 'Singh'),    (8, 'Kulkarni'),(9, 'Mehta'),
        (10, 'Joshi'),  (11, 'Verma'),   (12, 'Menon'),   (13, 'Chopra'), (14, 'Rao'),
        (15, 'Bose'),   (16, 'Kapoor'),  (17, 'Pillai'),  (18, 'Jain'),   (19, 'Shetty')
),
-- 8 departments, each with four job titles (junior -> lead) and a skill pool.
departments (IDX, DEPARTMENT, TITLES, SKILL_POOL) AS (
    SELECT COLUMN1, COLUMN2, SPLIT(COLUMN3, ';'), SPLIT(COLUMN4, ';') FROM VALUES
        (0, 'Engineering',      'Software Engineer;Senior Software Engineer;Staff Engineer;Engineering Manager',
                                'Python;Java;JavaScript;AWS;SQL'),
        (1, 'Data & Analytics', 'Data Analyst;Data Engineer;Senior Data Engineer;Analytics Manager',
                                'SQL;Snowflake;Python;Data Modelling;Machine Learning;Power BI'),
        (2, 'Product',          'Associate Product Manager;Product Manager;Senior Product Manager;Head of Product',
                                'Product Strategy;Project Management;Communication;SQL'),
        (3, 'Sales',            'Sales Executive;Account Manager;Senior Account Manager;Sales Director',
                                'Negotiation;CRM;Communication;Excel'),
        (4, 'Marketing',        'Marketing Executive;Content Specialist;Marketing Manager;Head of Marketing',
                                'SEO;Content Writing;Communication;Excel'),
        (5, 'Finance',          'Accounts Executive;Financial Analyst;Senior Financial Analyst;Finance Manager',
                                'Financial Analysis;Excel;SQL;Power BI'),
        (6, 'Human Resources',  'HR Executive;Talent Acquisition Specialist;HR Business Partner;HR Manager',
                                'Recruitment;Communication;Excel;Project Management'),
        (7, 'Customer Support', 'Support Associate;Support Specialist;Support Team Lead;Support Manager',
                                'Customer Service;Communication;CRM;Excel')
),
-- Pick the building blocks for each employee. Different salt strings give
-- independent hash values, so the attributes do not move in step.
picks AS (
    SELECT
        N,
        MOD(N, 30)                              AS FIRST_IDX,
        -- 7*N mod 20 never repeats a (first, last) pair within 60 rows,
        -- which keeps every generated e-mail address unique.
        MOD(N * 7, 20)                          AS LAST_IDX,
        MOD(ABS(HASH(N, 'dept')), 8)            AS DEPT_IDX,
        MOD(ABS(HASH(N, 'level')), 4)           AS LEVEL_IDX,     -- 0 junior .. 3 lead
        MOD(ABS(HASH(N, 'type')), 20)           AS TYPE_ROLL,     -- 0..19
        MOD(ABS(HASH(N, 'city')), 6)            AS CITY_IDX,
        MOD(ABS(HASH(N, 'age')), 8)             AS AGE_EXTRA,     -- extra years of age
        MOD(ABS(HASH(N, 'birthday')), 365)      AS BIRTHDAY_OFFSET,
        MOD(ABS(HASH(N, 'tenure')), 1000)       AS TENURE_PERMILLE,
        MOD(ABS(HASH(N, 'pay')), 40)            AS PAY_STEP,      -- 0..39
        MOD(ABS(HASH(N, 'active')), 100)        AS ACTIVE_ROLL,   -- 0..99
        MOD(ABS(HASH(N, 'remote')), 100)        AS REMOTE_ROLL,   -- 0..99
        MOD(ABS(HASH(N, 'phone')), 100000000)   AS PHONE_DIGITS,
        ABS(HASH(N, 'skill1'))                  AS SKILL_HASH_1,
        ABS(HASH(N, 'skill2'))                  AS SKILL_HASH_2,
        ABS(HASH(N, 'skill3'))                  AS SKILL_HASH_3
    FROM numbers
),
-- Turn the picks into employee attributes.
employees AS (
    SELECT
        p.N,
        f.FIRST_NAME,
        l.LAST_NAME,
        f.GENDER,
        d.DEPARTMENT,
        p.LEVEL_IDX,
        d.TITLES[p.LEVEL_IDX]::VARCHAR                                   AS JOB_TITLE,
        -- 70 % full-time, 10 % part-time, 15 % contract, 5 % intern (juniors only).
        CASE
            WHEN p.TYPE_ROLL < 14 THEN 'Full-time'
            WHEN p.TYPE_ROLL < 16 THEN 'Part-time'
            WHEN p.TYPE_ROLL < 19 THEN 'Contract'
            WHEN p.LEVEL_IDX = 0  THEN 'Intern'
            ELSE 'Full-time'
        END                                                              AS EMPLOYMENT_TYPE,
        ARRAY_CONSTRUCT('Bengaluru', 'Pune', 'Mumbai', 'Hyderabad', 'Chennai', 'Delhi NCR')[p.CITY_IDX]::VARCHAR
                                                                         AS WORK_LOCATION,
        -- Age on 2026-10-01 grows with seniority: 23-30, 28-35, 33-40, 38-45.
        DATEADD(day, -p.BIRTHDAY_OFFSET,
                DATEADD(year, -(23 + p.LEVEL_IDX * 5 + p.AGE_EXTRA), DATE '2026-10-01'))
                                                                         AS DATE_OF_BIRTH,
        p.TENURE_PERMILLE,
        -- Salary band by level, in steps of 10,000.
        (400000 + p.LEVEL_IDX * 600000) + p.PAY_STEP * 10000             AS FULL_TIME_SALARY,
        -- Up to three distinct skills from the department's pool.
        ARRAY_DISTINCT(ARRAY_CONSTRUCT(
            d.SKILL_POOL[MOD(p.SKILL_HASH_1, ARRAY_SIZE(d.SKILL_POOL))]::VARCHAR,
            d.SKILL_POOL[MOD(p.SKILL_HASH_2, ARRAY_SIZE(d.SKILL_POOL))]::VARCHAR,
            d.SKILL_POOL[MOD(p.SKILL_HASH_3, ARRAY_SIZE(d.SKILL_POOL))]::VARCHAR
        ))                                                               AS SKILLS,
        p.ACTIVE_ROLL >= 12                                              AS IS_ACTIVE,   -- about 88 % active
        p.REMOTE_ROLL < 30                                               AS IS_REMOTE,   -- about 30 % remote
        -- About one employee in six has no phone number on file.
        IFF(MOD(p.N, 6) = 5, NULL, '+91 9' || LPAD(p.PHONE_DIGITS::VARCHAR, 9, '0')) AS PHONE
    FROM picks p
    JOIN first_names f ON f.IDX = p.FIRST_IDX
    JOIN last_names  l ON l.IDX = p.LAST_IDX
    JOIN departments d ON d.IDX = p.DEPT_IDX
),
-- Dates and experience that depend on the date of birth.
dated AS (
    SELECT
        e.*,
        -- The earliest possible hire date is the 21st birthday.
        DATEADD(year, 21, e.DATE_OF_BIRTH)                               AS EARLIEST_HIRE,
        -- Hire date: a point between the 21st birthday and 2026-09-30.
        DATEADD(day,
                FLOOR(DATEDIFF(day, DATEADD(year, 21, e.DATE_OF_BIRTH), DATE '2026-09-30')
                      * e.TENURE_PERMILLE / 1000),
                DATEADD(year, 21, e.DATE_OF_BIRTH))                      AS HIRE_DATE
    FROM employees e
)
SELECT
    FIRST_NAME,
    LAST_NAME,
    LOWER(FIRST_NAME || '.' || LAST_NAME) || '@example.com'              AS EMAIL,
    PHONE,
    GENDER,
    DATE_OF_BIRTH,
    DEPARTMENT,
    JOB_TITLE,
    EMPLOYMENT_TYPE,
    WORK_LOCATION,
    HIRE_DATE,
    -- Interns and part-time staff earn a fraction of the full-time band.
    CASE EMPLOYMENT_TYPE
        WHEN 'Intern'    THEN 240000 + MOD(N, 7) * 20000
        WHEN 'Part-time' THEN ROUND(FULL_TIME_SALARY * 0.5, -4)
        ELSE FULL_TIME_SALARY
    END                                                                  AS SALARY,
    -- Experience: working years since age 21, rounded to half a year.
    ROUND(DATEDIFF(month, EARLIEST_HIRE, DATE '2026-10-01') / 12 * 2) / 2 AS EXPERIENCE_YEARS,
    SKILLS,
    IS_ACTIVE,
    IS_REMOTE,
    -- A note on some rows so the text-area field has data to show.
    CASE
        WHEN NOT IS_ACTIVE     THEN 'Left the company; record kept for reference.'
        WHEN MOD(N, 9) = 0     THEN 'Mentor in the graduate onboarding programme.'
        WHEN MOD(N, 11) = 0    THEN 'Eligible for promotion review in the next cycle.'
        WHEN IS_REMOTE AND MOD(N, 4) = 0 THEN 'Visits the office once a quarter.'
    END                                                                  AS NOTES
FROM dated
-- Insert only into an empty table, so running the script twice adds nothing.
WHERE NOT EXISTS (SELECT 1 FROM AI_OPERATOR_DB.EMPLOYEE_APP.EMPLOYEES)
ORDER BY N;
