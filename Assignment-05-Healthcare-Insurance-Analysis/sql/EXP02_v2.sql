-- ============================================================
-- EXPERIMENT 02 — Hospital / Provider Cost Analysis
-- PROMPT VERSION: V2 (improved, business-focused prompt)
-- Distinguishes claim_amount (billed) vs approved_amount (liability) vs paid_amount (cash: PAID vs PROCESSING).
-- Payments aggregated per claim BEFORE joining -> no duplicate counting (claim_payments verified 1:1).
-- Read-only. Actual PostgreSQL 17 / schema healthcare.
-- ============================================================

-- V2.0 — Payment safety: verify claim_payments is 1:1 with claims (no fan-out)
SELECT MAX(cnt) AS max_payments_per_claim, COUNT(*) AS rows, COUNT(DISTINCT claim_id) AS distinct_claims
FROM (SELECT claim_id, COUNT(*) AS cnt FROM healthcare.claim_payments GROUP BY claim_id) t;

-- V2.1 — Core per-hospital metrics: volume, avg, MEDIAN, approved, paid(settled), ratios, share
WITH payments_agg AS (           -- aggregate BEFORE joining (defensive against fan-out)
    SELECT claim_id,
           SUM(paid_amount)                                      AS paid_all,
           SUM(paid_amount) FILTER (WHERE payment_status='PAID') AS paid_settled
    FROM healthcare.claim_payments
    GROUP BY claim_id
)
SELECT h.hospital_id, h.hospital_name, h.hospital_type, h.network_status,
       COUNT(*)                                                             AS claims,
       ROUND(SUM(c.claim_amount),2)                                         AS total_claimed,
       ROUND(AVG(c.claim_amount),2)                                         AS avg_claim,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.claim_amount)::numeric,2) AS median_claim,
       ROUND(SUM(c.approved_amount),2)                                      AS total_approved,
       ROUND(SUM(pa.paid_settled),2)                                        AS paid_settled,
       ROUND(100.0*SUM(c.approved_amount)/NULLIF(SUM(c.claim_amount),0),1)  AS approval_ratio_pct,
       ROUND(100.0*SUM(pa.paid_settled)/NULLIF(SUM(c.approved_amount),0),1) AS settlement_ratio_pct,
       ROUND(100.0*SUM(c.claim_amount)/SUM(SUM(c.claim_amount)) OVER (),3)  AS pct_of_total
FROM healthcare.claims c
JOIN healthcare.hospitals h ON c.hospital_id = h.hospital_id
LEFT JOIN payments_agg pa    ON c.claim_id   = pa.claim_id
GROUP BY h.hospital_id, h.hospital_name, h.hospital_type, h.network_status
ORDER BY total_claimed DESC
LIMIT 15;

-- V2.2 — Dispersion: is any hospital MATERIALLY more expensive? (max vs avg, ranges)
WITH per_h AS (
  SELECT hospital_id, COUNT(*) claims, SUM(claim_amount) total_claimed, AVG(claim_amount) avg_claim
  FROM healthcare.claims GROUP BY hospital_id)
SELECT ROUND(MIN(total_claimed),0) min_total, ROUND(MAX(total_claimed),0) max_total,
       ROUND(AVG(total_claimed),0) avg_total, ROUND(STDDEV(total_claimed),0) sd_total,
       ROUND(MAX(total_claimed)/AVG(total_claimed),2) max_vs_avg_x,
       ROUND(MIN(avg_claim),0) min_avgclaim, ROUND(MAX(avg_claim),0) max_avgclaim, ROUND(AVG(avg_claim),0) mean_avgclaim
FROM per_h;

-- V2.3 — High-cost hospital OUTLIERS: avg_claim beyond mean + 2*stddev
WITH per_h AS (SELECT hospital_id, AVG(claim_amount) avg_claim FROM healthcare.claims GROUP BY hospital_id),
     stats AS (SELECT AVG(avg_claim) m, STDDEV(avg_claim) s FROM per_h)
SELECT COUNT(*) AS hospitals_above_mean_plus_2sd,
       ROUND((SELECT m FROM stats),0) AS mean_avgclaim,
       ROUND((SELECT m+2*s FROM stats),0) AS threshold
FROM per_h, stats WHERE avg_claim > m+2*s;

-- V2.4 — NETWORK comparison (IN vs OUT): volume, avg, approved, ratios, share
WITH payments_agg AS (SELECT claim_id, SUM(paid_amount) FILTER (WHERE payment_status='PAID') paid_settled FROM healthcare.claim_payments GROUP BY claim_id)
SELECT h.network_status, COUNT(DISTINCT h.hospital_id) hospitals, COUNT(*) claims,
       ROUND(SUM(c.claim_amount),2) total_claimed, ROUND(AVG(c.claim_amount),2) avg_claim,
       ROUND(SUM(c.approved_amount),2) total_approved,
       ROUND(100.0*SUM(c.approved_amount)/SUM(c.claim_amount),1) approval_ratio_pct,
       ROUND(100.0*SUM(pa.paid_settled)/SUM(c.approved_amount),1) settlement_ratio_pct,
       ROUND(100.0*SUM(c.claim_amount)/SUM(SUM(c.claim_amount)) OVER (),1) pct_of_total
FROM healthcare.claims c JOIN healthcare.hospitals h ON c.hospital_id=h.hospital_id
LEFT JOIN payments_agg pa ON c.claim_id=pa.claim_id
GROUP BY h.network_status ORDER BY total_claimed DESC;

-- V2.5 — HOSPITAL TYPE comparison
SELECT h.hospital_type, COUNT(DISTINCT h.hospital_id) hospitals, COUNT(*) claims,
       ROUND(SUM(c.claim_amount),2) total_claimed, ROUND(AVG(c.claim_amount),2) avg_claim,
       ROUND(100.0*SUM(c.approved_amount)/SUM(c.claim_amount),1) approval_ratio_pct,
       ROUND(100.0*SUM(c.claim_amount)/SUM(SUM(c.claim_amount)) OVER (),1) pct_of_total
FROM healthcare.claims c JOIN healthcare.hospitals h ON c.hospital_id=h.hospital_id
GROUP BY h.hospital_type ORDER BY total_claimed DESC;

-- V2.6 — CASE-MIX test for the top hospital (why is it expensive?) — diagnosis mix
SELECT d.diagnosis_name, d.diagnosis_category, COUNT(*) claims,
       ROUND(SUM(c.claim_amount),2) total_claimed, ROUND(AVG(c.claim_amount),2) avg_claim
FROM healthcare.claims c
JOIN healthcare.diagnoses d ON c.diagnosis_id=d.diagnosis_id
WHERE c.hospital_id=362                          -- top hospital by total claimed
GROUP BY d.diagnosis_name, d.diagnosis_category
ORDER BY total_claimed DESC LIMIT 6;

-- V2.7 — Does case mix explain the high-avg outliers? (cardiovascular share: outliers vs rest)
WITH per_h AS (SELECT hospital_id, AVG(claim_amount) avg_claim FROM healthcare.claims GROUP BY hospital_id),
     stats AS (SELECT AVG(avg_claim) m, STDDEV(avg_claim) s FROM per_h),
     flagged AS (SELECT hospital_id, CASE WHEN avg_claim > (SELECT m+2*s FROM stats) THEN 'high_avg_outlier' ELSE 'rest' END grp FROM per_h)
SELECT f.grp, COUNT(*) claims,
       ROUND(100.0*COUNT(*) FILTER (WHERE d.diagnosis_category='Cardiovascular')/COUNT(*),1) AS cardio_claim_share_pct,
       ROUND(100.0*SUM(c.claim_amount) FILTER (WHERE d.diagnosis_category='Cardiovascular')/SUM(c.claim_amount),1) AS cardio_spend_share_pct,
       ROUND(AVG(c.claim_amount),2) avg_claim
FROM healthcare.claims c
JOIN flagged f ON c.hospital_id=f.hospital_id
JOIN healthcare.diagnoses d ON c.diagnosis_id=d.diagnosis_id
GROUP BY f.grp ORDER BY avg_claim DESC;
