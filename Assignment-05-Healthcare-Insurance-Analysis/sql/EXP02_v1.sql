-- ============================================================
-- EXPERIMENT 02 — Hospital / Provider Cost Analysis
-- PROMPT VERSION: V1 (basic prompt)
-- Business question: Which hospitals are driving the highest claim costs?
-- Read-only. Actual PostgreSQL 17 / schema healthcare.
-- ============================================================

-- V1.1 — Top 10 hospitals by total claim amount (+ count, avg, share)
SELECT
    h.hospital_id,
    h.hospital_name,
    h.hospital_type,
    h.network_status,
    COUNT(*)                          AS claim_count,
    ROUND(SUM(c.claim_amount),2)      AS total_claim_amount,
    ROUND(AVG(c.claim_amount),2)      AS avg_claim_amount,
    ROUND(100.0*SUM(c.claim_amount)/SUM(SUM(c.claim_amount)) OVER (),2) AS pct_of_total_spend
FROM healthcare.claims c
JOIN healthcare.hospitals h ON c.hospital_id = h.hospital_id
GROUP BY h.hospital_id, h.hospital_name, h.hospital_type, h.network_status
ORDER BY total_claim_amount DESC
LIMIT 10;

-- V1.2 — Context: grand total, number of hospitals, overall averages
SELECT ROUND(SUM(claim_amount),2)     AS grand_total_claimed,
       COUNT(DISTINCT hospital_id)    AS hospitals_with_claims,
       ROUND(AVG(claim_amount),2)     AS overall_avg_claim,
       ROUND(100000.0/COUNT(DISTINCT hospital_id),0) AS avg_claims_per_hospital
FROM healthcare.claims;
