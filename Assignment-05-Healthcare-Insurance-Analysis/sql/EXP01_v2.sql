-- ============================================================
-- EXPERIMENT 01 — Disease-wise Claim Cost & Risk Analysis
-- PROMPT VERSION: V2 (improved, business-focused prompt)
-- Distinguishes claim_amount vs approved_amount vs paid_amount (PAID vs PROCESSING).
-- Payments aggregated per claim BEFORE joining -> no duplicate counting.
-- Read-only. Actual PostgreSQL 17 / schema healthcare.
-- ============================================================

-- V2.1 — Pre-join payment validation (cardinality / status)
SELECT payment_status, COUNT(*) AS rows, COUNT(DISTINCT claim_id) AS distinct_claims,
       ROUND(SUM(paid_amount),2) AS sum_paid
FROM healthcare.claim_payments
GROUP BY payment_status
ORDER BY rows DESC;

SELECT payments_per_claim, COUNT(*) AS num_claims
FROM (SELECT claim_id, COUNT(*) AS payments_per_claim
      FROM healthcare.claim_payments GROUP BY claim_id) t
GROUP BY payments_per_claim ORDER BY 1;   -- expect single row: 1 payment / claim

-- V2.2 — Core disease-level metrics: claimed vs approved vs paid, with shares
WITH payments_agg AS (           -- aggregate BEFORE joining (defensive against fan-out)
    SELECT claim_id,
           SUM(paid_amount)                                        AS paid_all,
           SUM(paid_amount) FILTER (WHERE payment_status='PAID')   AS paid_settled
    FROM healthcare.claim_payments
    GROUP BY claim_id
)
SELECT
    d.diagnosis_name        AS disease,
    d.diagnosis_category    AS category,
    COUNT(*)                AS claim_count,
    ROUND(SUM(c.claim_amount),2)     AS total_claimed,
    ROUND(AVG(c.claim_amount),2)     AS avg_claim,
    ROUND(SUM(c.approved_amount),2)  AS total_approved,
    ROUND(AVG(c.approved_amount),2)  AS avg_approved,
    ROUND(100.0*SUM(c.approved_amount)/NULLIF(SUM(c.claim_amount),0),1) AS approval_ratio_pct,
    ROUND(SUM(pa.paid_settled),2)    AS paid_settled,
    ROUND(SUM(pa.paid_all),2)        AS paid_incl_processing,
    ROUND(100.0*SUM(c.claim_amount)   /SUM(SUM(c.claim_amount))   OVER (),1) AS pct_of_total_claimed,
    ROUND(100.0*SUM(c.approved_amount)/SUM(SUM(c.approved_amount))OVER (),1) AS pct_of_total_approved
FROM healthcare.claims c
JOIN healthcare.diagnoses d   ON c.diagnosis_id = d.diagnosis_id
LEFT JOIN payments_agg pa     ON c.claim_id     = pa.claim_id
GROUP BY d.diagnosis_name, d.diagnosis_category
ORDER BY total_claimed DESC
LIMIT 15;

-- V2.3 — Portfolio grand totals (claimed vs approved vs settled)
WITH pa AS (
    SELECT SUM(paid_amount) AS paid_all,
           SUM(paid_amount) FILTER (WHERE payment_status='PAID') AS paid_settled
    FROM healthcare.claim_payments
)
SELECT
  ROUND(SUM(c.claim_amount),2)     AS total_claimed,
  ROUND(SUM(c.approved_amount),2)  AS total_approved,
  ROUND((SELECT paid_settled FROM pa),2) AS total_paid_settled,
  ROUND((SELECT paid_all FROM pa),2)     AS total_paid_incl_processing,
  ROUND(100.0*SUM(c.approved_amount)/SUM(c.claim_amount),1)           AS overall_approval_ratio_pct,
  ROUND(100.0*(SELECT paid_settled FROM pa)/SUM(c.approved_amount),1) AS settled_pct_of_approved
FROM healthcare.claims c;

-- V2.4 — Category rollup (claimed vs approved vs settled)
WITH payments_agg AS (
    SELECT claim_id, SUM(paid_amount) AS paid_all,
           SUM(paid_amount) FILTER (WHERE payment_status='PAID') AS paid_settled
    FROM healthcare.claim_payments GROUP BY claim_id
)
SELECT d.diagnosis_category AS category,
  COUNT(*) AS claims,
  ROUND(SUM(c.claim_amount),2)    AS total_claimed,
  ROUND(SUM(c.approved_amount),2) AS total_approved,
  ROUND(SUM(pa.paid_settled),2)   AS paid_settled,
  ROUND(100.0*SUM(c.approved_amount)/SUM(c.claim_amount),1) AS approval_ratio_pct,
  ROUND(100.0*SUM(c.claim_amount)/SUM(SUM(c.claim_amount)) OVER (),1) AS pct_of_total_claimed
FROM healthcare.claims c
JOIN healthcare.diagnoses d ON c.diagnosis_id=d.diagnosis_id
LEFT JOIN payments_agg pa ON c.claim_id=pa.claim_id
GROUP BY d.diagnosis_category
ORDER BY total_claimed DESC;

-- V2.5 — Volume vs Severity classification
-- thresholds: avg claims/disease = 100000/50 = 2000 ; overall avg claim = 68,897
WITH per_disease AS (
  SELECT d.diagnosis_name AS disease, d.diagnosis_category AS category,
         COUNT(*) AS claim_count, AVG(c.claim_amount) AS avg_claim, SUM(c.claim_amount) AS total_claimed
  FROM healthcare.claims c JOIN healthcare.diagnoses d ON c.diagnosis_id=d.diagnosis_id
  GROUP BY d.diagnosis_name, d.diagnosis_category)
SELECT disease, category, claim_count, ROUND(avg_claim,0) AS avg_claim, ROUND(total_claimed,0) AS total_claimed,
  CASE WHEN claim_count > 2000 AND avg_claim > 68897 THEN 'BOTH volume+severity'
       WHEN claim_count > 2000 THEN 'VOLUME-driven'
       WHEN avg_claim > 68897 THEN 'SEVERITY-driven'
       ELSE 'neither (low)' END AS driver_type
FROM per_disease ORDER BY total_claimed DESC LIMIT 15;

-- V2.6 — Heart Disease cost-driver linkage: policy type (premium/coverage/deductible)
SELECT po.policy_type,
       COUNT(*) AS claims,
       ROUND(SUM(c.claim_amount),2)   AS total_claimed,
       ROUND(AVG(po.annual_premium),2)    AS avg_premium,
       ROUND(AVG(po.coverage_amount),2)   AS avg_coverage,
       ROUND(AVG(po.deductible_amount),2) AS avg_deductible
FROM healthcare.claims c
JOIN healthcare.diagnoses d ON c.diagnosis_id=d.diagnosis_id
JOIN healthcare.policies po ON c.policy_id=po.policy_id
WHERE d.diagnosis_name='Heart Disease'
GROUP BY po.policy_type ORDER BY total_claimed DESC;

-- V2.7 — Heart Disease linkage: hospital network status
SELECT h.network_status, COUNT(*) AS claims,
       ROUND(SUM(c.claim_amount),2) AS total_claimed, ROUND(AVG(c.claim_amount),2) AS avg_claim,
       ROUND(100.0*SUM(c.approved_amount)/SUM(c.claim_amount),1) AS approval_ratio_pct
FROM healthcare.claims c
JOIN healthcare.diagnoses d ON c.diagnosis_id=d.diagnosis_id
JOIN healthcare.hospitals h ON c.hospital_id=h.hospital_id
WHERE d.diagnosis_name='Heart Disease'
GROUP BY h.network_status ORDER BY total_claimed DESC;

-- V2.8 — Heart Disease linkage: top procedures by total claimed (+ base_cost reference)
SELECT pr.procedure_name, pr.procedure_category, COUNT(*) AS claims,
       ROUND(SUM(c.claim_amount),2) AS total_claimed, ROUND(AVG(c.claim_amount),2) AS avg_claim,
       ROUND(AVG(pr.base_cost),2) AS avg_base_cost
FROM healthcare.claims c
JOIN healthcare.diagnoses d ON c.diagnosis_id=d.diagnosis_id
JOIN healthcare.procedures pr ON c.procedure_id=pr.procedure_id
WHERE d.diagnosis_name='Heart Disease'
GROUP BY pr.procedure_name, pr.procedure_category ORDER BY total_claimed DESC LIMIT 8;
