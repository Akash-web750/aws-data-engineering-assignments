# EXPERIMENT 02 — Exact Prompts, V1 Evaluation, and V1↔V2 Rationale

Both prompts are reproduced **verbatim** as issued. The rules require exact preservation and documentation of why V2 improves on V1.

> 📸 Session captures of the experiment brief: [`01_Prompt_V1/EXP02_Prompt_V1_01.png`](../screenshots/EXP02_Hospital_Cost/01_Prompt_V1/EXP02_Prompt_V1_01.png) and [`03_Prompt_V2/EXP02_Prompt_V2_01.png`](../screenshots/EXP02_Hospital_Cost/03_Prompt_V2/EXP02_Prompt_V2_01.png).

---

## PROMPT V1 (basic)
```
Analyze the healthcare insurance database (PostgreSQL, schema healthcare).

Business question:
Which hospitals are driving the highest claim costs?

Using the existing healthcare schema and actual database data, identify the top
hospitals by total claim amount. Show claim count, total claim amount, and average
claim amount per hospital, and each hospital's share of total claim spend.

Generate the PostgreSQL SQL, execute it read-only, show the actual results, and give
basic business insights.

Do not modify any database objects or data. Use actual results only. Do not invent any values.
```

### V1 OUTPUT (summary)
- **SQL:** `claims ⋈ hospitals` GROUP BY hospital, ranked by `SUM(claim_amount)` + share window; plus a context total. (`sql/EXP02_v1.sql`)
- **Result:** Top-10 hospitals; #1 = Madan Private (362) ₹23.22M, **0.34%** of total spend; grand total ₹6,889,700,889.57 across **500** hospitals.
- **Insight:** top hospitals are moderately above-average on volume and unit cost, but each is a tiny share of spend.

### V1 EVALUATION — what V1 fails to explain
| Gap | Why it matters |
|---|---|
| **Volume vs unit cost** | V1 can't tell if a hospital ranks high because of many claims or expensive claims. |
| **Concentration** | V1 shows a ranking but not that the top hospital is only 0.34% — i.e. cost is **not** concentrated. |
| **Median vs mean** | V1's average hides that hospital averages are pulled up by a few huge claims (skew). |
| **Approved vs claimed / paid vs processing** | V1 uses billed `claim_amount` only — no liability or cash view. |
| **Network status** | V1 doesn't test whether out-of-network is more expensive. |
| **Hospital type** | V1 doesn't compare Private/Government/Specialty/Multi-Specialty. |
| **Disease / procedure mix** | V1 can't say whether a "expensive" hospital just treats sicker patients (case mix). |
| **Outliers** | V1 gives no statistical basis for calling a hospital an outlier. |
| **Approval / settlement behavior** | V1 ignores hospital-level approval and settlement ratios. |

---

## PROMPT V2 (improved — built directly from the V1 gaps)
```
Perform a business-focused hospital/provider cost analysis on the healthcare insurance
database (PostgreSQL, schema healthcare). Read-only. Actual data only; do not invent values.

Business question:
Which hospitals are driving the highest claim costs, and are some hospitals materially
more expensive than others?

Metric definitions (do not treat as interchangeable):
- claim_amount   = amount billed by the provider/customer.
- approved_amount = amount approved by the insurer (accepted liability).
- paid_amount    = cash settlement; distinguish payment_status='PAID' (settled) from
  'PROCESSING' (in-flight). Do not call claim_amount "insurer cost" without qualification.

Payment safety:
- First verify whether claim_payments is 1:1 with claims. If multiple rows per claim exist,
  aggregate payments to claim level BEFORE joining to claims to avoid fan-out / double counting.

Produce, using actual data:
A. Hospital ranking by total claim amount
B. Claim volume per hospital
C. Average claim amount
D. Median claim amount (if practical)
E. Approved amount
F. Paid amount, distinguishing PAID vs PROCESSING
G. Hospital share of total claim spend
H. Volume-vs-unit-cost classification
I. Network status comparison (IN vs OUT) — do not assume out-of-network is more expensive
J. Disease mix where useful
K. Procedure mix where useful
L. Hospital-level approval ratio (approved/claimed)
M. Hospital-level settlement ratio (settled/approved)
N. Identification of high-cost hospital outliers (statistical basis)
O. Business interpretation: WHY is a hospital expensive (volume, unit cost, or case mix)?
P. Actionable, evidence-based recommendations
Q. Limitations and follow-up analysis

Separate observed result -> possible explanation -> evidence required for confirmation.
Do not attribute a hospital's cost to pricing if case mix explains it. Do not claim direct
revenue growth unless the data supports it. Keep the session read-only.
```

### V2 OUTPUT
Full SQL in `sql/EXP02_v2.sql`; actual results in `results/EXP02_actual_results.md`; full interpretation in `experiments/EXP02_hospital_cost_analysis.md`. Realized additions vs V1: median, approved/settled layers, dispersion + statistical outliers, network & hospital-type comparisons, case-mix test, and approval/settlement ratios.
