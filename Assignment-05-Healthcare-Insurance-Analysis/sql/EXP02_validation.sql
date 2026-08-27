-- ============================================================
-- EXPERIMENT 02 — INDEPENDENT VALIDATION
-- Deliberately different aggregation logic from EXP02_v2.sql:
--   subtotal reconciliation, direct WHERE, scalar/IN subqueries, standalone-vs-join.
-- Read-only. Actual PostgreSQL 17 / schema healthcare.
-- ============================================================

-- (1) Grand total via reconciliation: sum of per-hospital subtotals == grand total
SELECT ROUND(SUM(tot),2) AS sum_of_hospital_totals
FROM (SELECT hospital_id, SUM(claim_amount) tot FROM healthcare.claims GROUP BY hospital_id) t;

-- (2)(3)(4)(5) Top hospital (362) via direct WHERE: count / total / avg / approved
SELECT COUNT(*) AS claims, ROUND(SUM(claim_amount),2) AS total_claimed,
       ROUND(AVG(claim_amount),2) AS avg_claim, ROUND(SUM(approved_amount),2) AS total_approved
FROM healthcare.claims WHERE hospital_id=362;

-- (6) Top hospital (362) settled PAID via IN-subquery (not LEFT JOIN aggregate)
SELECT COUNT(*) AS paid_rows, ROUND(SUM(paid_amount),2) AS paid_settled
FROM healthcare.claim_payments
WHERE payment_status='PAID' AND claim_id IN (SELECT claim_id FROM healthcare.claims WHERE hospital_id=362);

-- (7) Top hospital share via independent grand total
SELECT ROUND(100.0*(SELECT SUM(claim_amount) FROM healthcare.claims WHERE hospital_id=362)
                    /(SELECT SUM(claim_amount) FROM healthcare.claims),3) AS share_pct;

-- (8) Network comparison via IN-subquery (independent path)
SELECT 'IN_NETWORK' AS net, COUNT(*) claims, ROUND(SUM(claim_amount),2) total_claimed, ROUND(AVG(claim_amount),2) avg_claim
FROM healthcare.claims WHERE hospital_id IN (SELECT hospital_id FROM healthcare.hospitals WHERE network_status='IN_NETWORK')
UNION ALL
SELECT 'OUT_OF_NETWORK', COUNT(*), ROUND(SUM(claim_amount),2), ROUND(AVG(claim_amount),2)
FROM healthcare.claims WHERE hospital_id IN (SELECT hospital_id FROM healthcare.hospitals WHERE network_status='OUT_OF_NETWORK');

-- (9) Duplicate-count / fan-out check for hospital 362 (standalone vs joined PAID)
SELECT
 (SELECT ROUND(SUM(paid_amount),2) FROM healthcare.claim_payments WHERE payment_status='PAID'
    AND claim_id IN (SELECT claim_id FROM healthcare.claims WHERE hospital_id=362)) AS standalone_paid,
 (SELECT ROUND(SUM(cp.paid_amount),2) FROM healthcare.claims c
    JOIN healthcare.claim_payments cp ON c.claim_id=cp.claim_id
    WHERE c.hospital_id=362 AND cp.payment_status='PAID') AS joined_paid,
 (SELECT COUNT(*) FROM healthcare.claims c JOIN healthcare.claim_payments cp ON c.claim_id=cp.claim_id WHERE c.hospital_id=362) AS join_rows,
 (SELECT COUNT(*) FROM healthcare.claim_payments WHERE claim_id IN (SELECT claim_id FROM healthcare.claims WHERE hospital_id=362)) AS payment_rows;
