# EXPERIMENT 01 — Independent Validation Report

**Method:** every figure re-derived with **different SQL logic** than `EXP01_v2.sql` — ROLLUP decomposition, scalar/`IN`/`EXISTS` subqueries, plain `WHERE` filters, and standalone-vs-join comparisons. Read-only. Queries in `sql/EXP01_validation.sql`. Nothing invented.

> Structural note: `claim_payments.claim_id` carries a **UNIQUE index (`uq_payment_claim`)**, and `diagnoses.diagnosis_name` / `procedures.procedure_name` are UNIQUE — so the fan-out guarantee and the name-based lookup subqueries are enforced by the schema, not merely observed.

| # | Item | Reported (V2) | Independent result | Δ | Verdict |
|--:|---|--:|--:|--:|:--:|
| 1 | Grand total claim amount | 6,889,700,889.57 | 6,889,700,889.57 (ROLLUP) | 0.00 | **PASS** ✅ |
| 2 | Total approved amount | 5,225,368,586.54 | 5,225,368,586.54 (ROLLUP) | 0.00 | **PASS** ✅ |
| 3 | Total settled / PAID | 2,834,964,771.91 | 2,834,964,771.91 (WHERE, 47,090 rows) | 0.00 | **PASS** ✅ |
| 4 | Cardiovascular claimed | 2,789,788,039.46 | 2,789,788,039.46 (IN-subquery) | 0.00 | **PASS** ✅ |
| 4 | Cardiovascular share | 40.5% | 40.49% (→40.5) | 0.00 | **PASS** ✅ |
| 5 | Heart Disease claim count | 7,497 | 7,497 (scalar subquery) | 0 | **PASS** ✅ |
| 5 | Heart Disease claimed | 2,072,827,175.57 | 2,072,827,175.57 | 0.00 | **PASS** ✅ |
| 5 | Heart Disease approved | 1,571,375,818.98 | 1,571,375,818.98 | 0.00 | **PASS** ✅ |
| 5 | Heart Disease settled | 854,252,471.66 | 854,252,471.66 (IN-subquery) | 0.00 | **PASS** ✅ |
| 5 | Heart Disease share | 30.1% | 30.09% (→30.1) | 0.00 | **PASS** ✅ |
| 6 | CAD claim count | 1,077 | 1,077 (WHERE) | 0 | **PASS** ✅ |
| 6 | CAD avg claim | 370,534.45 | 370,534.45 | 0.00 | **PASS** ✅ |
| 7 | Cardiac Surgery claimed | ≈1.08B | 1,081,651,850.39 (EXISTS) | ~0 | **PASS** ✅ |
| 7 | Angioplasty claimed | ≈763M | 763,253,747.39 | ~0 | **PASS** ✅ |
| 7 | Combined | ≈1.84B | 1,844,905,597.78 (ROLLUP) | ~0 | **PASS** ✅ |
| 8 | No fan-out / duplicate counting | 1:1 | 83,328 rows = 83,328 distinct claims, max 1/claim; standalone PAID = joined PAID = 2,834,964,771.91 | 0.00 | **PASS** ✅ |

### Independent cross-check (bonus)
ROLLUP by status shows approved = 0 for REJECTED (₹691,298,150.49 claimed) and PENDING (₹339,359,442.98 claimed); APPROVED approved ₹4,552,116,648.83 + PARTIALLY_APPROVED ₹673,251,937.71 = ₹5,225,368,586.54 — internally consistent with the reported approved total.

## VALIDATION SUMMARY
- **PASS: 8 / 8** (all reported items)
- **FAIL: 0**
- **NEEDS INVESTIGATION: 0**

**Conclusion:** Every reported EXP01 numerical finding reproduced exactly (Δ = 0.00) via independent aggregation paths; the only nominal differences are 1-decimal rounding of share percentages where underlying rupee amounts match to the cent. `claim_payments` is confirmed strictly 1:1 with `claims` → no duplicate-counting risk. **The V2 numerical findings are validated and safe to use in project documentation.**
