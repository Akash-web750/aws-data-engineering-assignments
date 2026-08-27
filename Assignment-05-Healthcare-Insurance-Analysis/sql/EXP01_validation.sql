-- ============================================================
-- EXPERIMENT 01 — INDEPENDENT VALIDATION
-- Deliberately different aggregation logic from EXP01_v2.sql:
--   ROLLUP, scalar/IN/EXISTS subqueries, plain WHERE, standalone-vs-join.
-- Read-only. Actual PostgreSQL 17 / schema healthcare.
-- ============================================================

-- (1)+(2) Grand total claimed & approved via ROLLUP by claim_status
SELECT COALESCE(claim_status,'>> GRAND TOTAL') AS claim_status,
       COUNT(*) AS claims,
       ROUND(SUM(claim_amount),2)    AS total_claimed,
       ROUND(SUM(approved_amount),2) AS total_approved
FROM healthcare.claims
GROUP BY ROLLUP(claim_status)
ORDER BY total_claimed;

-- (3) Total settled PAID via plain WHERE (no FILTER, no join)
SELECT COUNT(*) AS paid_rows, ROUND(SUM(paid_amount),2) AS total_settled_paid
FROM healthcare.claim_payments WHERE payment_status='PAID';

-- (4) Cardiovascular via IN-subquery + share vs independent grand total
SELECT COUNT(*) AS claims,
       ROUND(SUM(claim_amount),2) AS cardio_claimed,
       ROUND(100.0*SUM(claim_amount)/(SELECT SUM(claim_amount) FROM healthcare.claims),2) AS share_pct
FROM healthcare.claims
WHERE diagnosis_id IN (SELECT diagnosis_id FROM healthcare.diagnoses WHERE diagnosis_category='Cardiovascular');

-- (5) Heart Disease via scalar-subquery diagnosis_id
SELECT COUNT(*) AS claims,
       ROUND(SUM(claim_amount),2)    AS hd_claimed,
       ROUND(SUM(approved_amount),2) AS hd_approved,
       ROUND(100.0*SUM(claim_amount)/(SELECT SUM(claim_amount) FROM healthcare.claims),2) AS share_pct
FROM healthcare.claims
WHERE diagnosis_id = (SELECT diagnosis_id FROM healthcare.diagnoses WHERE diagnosis_name='Heart Disease');

-- (5b) Heart Disease settled PAID via IN-subquery (not LEFT JOIN aggregate)
SELECT COUNT(*) AS paid_rows, ROUND(SUM(paid_amount),2) AS hd_settled
FROM healthcare.claim_payments
WHERE payment_status='PAID'
  AND claim_id IN (SELECT claim_id FROM healthcare.claims
                   WHERE diagnosis_id=(SELECT diagnosis_id FROM healthcare.diagnoses WHERE diagnosis_name='Heart Disease'));

-- (6) Coronary Artery Disease count + AVG via WHERE
SELECT COUNT(*) AS claims, ROUND(AVG(claim_amount),2) AS avg_claim, ROUND(SUM(claim_amount),2) AS total_claimed
FROM healthcare.claims
WHERE diagnosis_id=(SELECT diagnosis_id FROM healthcare.diagnoses WHERE diagnosis_name='Coronary Artery Disease');

-- (7) Heart Disease procedures via EXISTS-filter + ROLLUP combined subtotal
SELECT pr.procedure_name, COUNT(*) AS claims, ROUND(SUM(c.claim_amount),2) AS total_claimed
FROM healthcare.claims c
JOIN healthcare.procedures pr ON c.procedure_id=pr.procedure_id
WHERE EXISTS (SELECT 1 FROM healthcare.diagnoses d
              WHERE d.diagnosis_id=c.diagnosis_id AND d.diagnosis_name='Heart Disease')
  AND pr.procedure_name IN ('Cardiac Surgery','Angioplasty')
GROUP BY ROLLUP(pr.procedure_name)
ORDER BY total_claimed DESC NULLS FIRST;

-- (8a) Fan-out check
SELECT COUNT(*) AS total_payment_rows,
       COUNT(DISTINCT claim_id) AS distinct_claims,
       MAX(cnt) AS max_payments_per_claim
FROM (SELECT claim_id, COUNT(*) AS cnt FROM healthcare.claim_payments GROUP BY claim_id) t;

-- (8b) Does joining claims->claim_payments inflate the PAID total? (standalone vs joined)
SELECT
  (SELECT ROUND(SUM(paid_amount),2) FROM healthcare.claim_payments WHERE payment_status='PAID') AS standalone_paid,
  (SELECT ROUND(SUM(cp.paid_amount),2) FROM healthcare.claims c
     JOIN healthcare.claim_payments cp ON c.claim_id=cp.claim_id WHERE cp.payment_status='PAID') AS joined_paid,
  (SELECT COUNT(*) FROM healthcare.claims c JOIN healthcare.claim_payments cp ON c.claim_id=cp.claim_id) AS join_row_count,
  (SELECT COUNT(*) FROM healthcare.claim_payments) AS payment_row_count;
