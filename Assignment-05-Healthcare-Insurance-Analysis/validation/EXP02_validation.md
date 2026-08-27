# EXPERIMENT 02 — Independent Validation Report

**Method:** each figure re-derived with **different SQL logic** than `EXP02_v2.sql` — subtotal reconciliation, direct `WHERE`, scalar/`IN` subqueries, and standalone-vs-join. Read-only. Queries in `sql/EXP02_validation.sql`. Nothing invented.

> 📸 **Actual pgAdmin result grids** for all checks: [`../screenshots/EXP02_Hospital_Cost/05_Validation/`](../screenshots/EXP02_Hospital_Cost/05_Validation) — reconciliation, hospital-362, settled, share, network, fan-out.

> `claim_payments.claim_id` is UNIQUE (index `uq_payment_claim`), so payment aggregations carry no fan-out risk — re-confirmed below for the top hospital.

| # | Item | Reported (V2) | Independent result | Δ | Verdict |
|--:|---|--:|--:|--:|:--:|
| 1 | Grand total claim amount | 6,889,700,889.57 | 6,889,700,889.57 (sum of per-hospital subtotals) | 0.00 | **PASS** ✅ |
| 2 | Top hospital (362) total claimed | 23,220,662.41 | 23,220,662.41 (direct WHERE) | 0.00 | **PASS** ✅ |
| 3 | Top hospital (362) claim count | 214 | 214 | 0 | **PASS** ✅ |
| 4 | Top hospital (362) avg claim | 108,507.77 | 108,507.77 | 0.00 | **PASS** ✅ |
| 5 | Top hospital (362) approved | 17,133,388.83 | 17,133,388.83 | 0.00 | **PASS** ✅ |
| 6 | Top hospital (362) settled PAID | 8,043,194.07 | 8,043,194.07 (IN-subquery, 106 rows) | 0.00 | **PASS** ✅ |
| 7 | Top hospital (362) share of total | 0.337% | 0.337% (independent grand total) | 0.00 | **PASS** ✅ |
| 8 | Network comparison (IN vs OUT) | IN 5,616,020,891.37 / avg 69,184.97 · OUT 1,273,679,998.20 / avg 67,655.37 | identical (IN-subquery path) | 0.00 | **PASS** ✅ |
| 9 | No duplicate counting (hospital 362) | 1:1 | standalone PAID = joined PAID = 8,043,194.07; join_rows 187 = payment_rows 187 | 0.00 | **PASS** ✅ |

### Reconciliation cross-check
Sum of all 500 per-hospital `SUM(claim_amount)` subtotals = **₹6,889,700,889.57** = the grand total from a single `SUM` over `claims` — confirms the hospital grouping neither drops nor double-counts any claim.

## VALIDATION SUMMARY
- **PASS: 9 / 9**
- **FAIL: 0**
- **NEEDS INVESTIGATION: 0**

**Conclusion:** Every reported EXP02 figure reproduced exactly (Δ = 0.00) via independent aggregation paths. The claims↔`claim_payments` relationship is 1:1 (no fan-out), so paid/settled aggregations are safe. **The EXP02 numerical findings are validated and safe to use in project documentation.**
