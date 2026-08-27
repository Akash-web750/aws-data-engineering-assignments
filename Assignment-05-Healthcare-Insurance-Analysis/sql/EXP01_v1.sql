-- ============================================================
-- EXPERIMENT 01 — Disease-wise Claim Cost Analysis
-- PROMPT VERSION: V1 (basic prompt)
-- Business question: Which diseases are driving the highest claim costs?
-- Read-only. Actual PostgreSQL 17 / schema healthcare.
-- ============================================================

-- V1.1 — Top 10 diseases by total claim amount (+ supporting context columns)
SELECT
    d.diagnosis_name        AS disease,
    d.diagnosis_category    AS category,
    d.severity_level        AS severity,
    COUNT(*)                AS claim_count,
    ROUND(SUM(c.claim_amount), 2)     AS total_claim_amount,
    ROUND(SUM(c.approved_amount), 2)  AS total_approved_amount,
    ROUND(AVG(c.claim_amount), 2)     AS avg_claim_amount,
    ROUND(100.0 * SUM(c.approved_amount) / NULLIF(SUM(c.claim_amount),0), 1) AS approved_pct,
    ROUND(100.0 * SUM(c.claim_amount) / SUM(SUM(c.claim_amount)) OVER (), 1)  AS pct_of_total_spend
FROM healthcare.claims c
JOIN healthcare.diagnoses d ON c.diagnosis_id = d.diagnosis_id
GROUP BY d.diagnosis_name, d.diagnosis_category, d.severity_level
ORDER BY total_claim_amount DESC
LIMIT 10;

-- V1.2 — Category rollup (context)
SELECT
    d.diagnosis_category AS category,
    COUNT(*)             AS claim_count,
    ROUND(SUM(c.claim_amount),2) AS total_claim_amount,
    ROUND(100.0 * SUM(c.claim_amount) / SUM(SUM(c.claim_amount)) OVER (),1) AS pct_of_total_spend
FROM healthcare.claims c
JOIN healthcare.diagnoses d ON c.diagnosis_id=d.diagnosis_id
GROUP BY d.diagnosis_category
ORDER BY total_claim_amount DESC;

-- V1.3 — Grand total claim spend
SELECT ROUND(SUM(claim_amount),2) AS grand_total_claim_spend FROM healthcare.claims;
