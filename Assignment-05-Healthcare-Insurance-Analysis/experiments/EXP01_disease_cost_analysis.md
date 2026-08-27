# EXPERIMENT 01 — Disease-wise Claim Cost & Risk Analysis

> Status: ✅ Complete · V1 + V2 + Independent Validation (8/8 PASS) · Read-only · No DB modification.
> All figures are actual PostgreSQL 17 output from `healthcare_insurance` / schema `healthcare`. Nothing invented.
> 📸 **Visual evidence:** [`../screenshots/EXP01_Disease_Cost/`](../screenshots/EXP01_Disease_Cost) — indexed in its [README](../screenshots/EXP01_Disease_Cost/README.md).

**⏱️ 30-second read:** Cardiovascular disease = **40.5%** of all claim cost; **Heart Disease alone = 30.1%** and is the only driver that is *both* high-frequency and high-severity; within it, **2 procedures = ₹1.84B**. Only **54.3%** of approved liability is settled (rest is in-flight, not lost). Every number independently validated (8/8).

---

## 1. Business Question
Which diseases are driving the highest claim cost and risk for the insurer — and is the concentration driven by claim frequency, cost per claim, or both?

## 2. Business Objective
Identify the major disease-level cost drivers so management can target cost optimization, risk management, and profitability improvement, while distinguishing genuine liability from billed amounts.

## 3. Analytical Objective
Rank diseases and disease categories by **claimed**, **approved**, and **settled** amounts; classify each driver as volume / severity / both; link the top driver to policy, provider network, and procedure; quantify the claim→approved and approved→paid gaps — all with join safety (no duplicate counting) and independent validation.

---

## 4. Prompt Used

This experiment is a V1 → V2 prompt-engineering study. The **exact** prompts are preserved verbatim below.

### PROMPT V1 (basic)
```
We need to analyze our healthcare insurance database.

Business question:
Which diseases are driving the highest claim costs?

Using the existing healthcare schema and actual database data, identify the top diseases by total claim amount.

Generate the PostgreSQL SQL query, execute it against the database, show the actual results, and explain the business insight.

Do not modify any database objects or data.
Use actual results only. Do not invent any values.
```

### PROMPT V2 (improved — see EXP01 V1 evaluation for the rationale behind each addition)
The V2 prompt added: explicit metric definitions (claim_amount vs approved_amount vs paid_amount), volume-vs-severity decomposition, category-level analysis, linkage to policy/premium/coverage/deductible/hospital/procedure, financial-exposure and gap analysis, join-safety requirements (aggregate `claim_payments` before joining), and a fixed A–H business-interpretation output structure. Full text stored in `experiments/EXP01_prompts.md`.

---

## 5. SQL Generated
- V1 queries: `sql/EXP01_v1.sql`
- V2 queries: `sql/EXP01_v2.sql`
- Independent validation: `sql/EXP01_validation.sql`

Core V2 query (payments aggregated per claim before joining — no fan-out):
```sql
WITH payments_agg AS (
    SELECT claim_id,
           SUM(paid_amount)                                      AS paid_all,
           SUM(paid_amount) FILTER (WHERE payment_status='PAID') AS paid_settled
    FROM healthcare.claim_payments GROUP BY claim_id
)
SELECT d.diagnosis_name AS disease, d.diagnosis_category AS category, COUNT(*) AS claim_count,
       ROUND(SUM(c.claim_amount),2)    AS total_claimed,
       ROUND(AVG(c.claim_amount),2)    AS avg_claim,
       ROUND(SUM(c.approved_amount),2) AS total_approved,
       ROUND(100.0*SUM(c.approved_amount)/NULLIF(SUM(c.claim_amount),0),1) AS approval_ratio_pct,
       ROUND(SUM(pa.paid_settled),2)   AS paid_settled,
       ROUND(SUM(pa.paid_all),2)       AS paid_incl_processing,
       ROUND(100.0*SUM(c.claim_amount)/SUM(SUM(c.claim_amount)) OVER (),1) AS pct_of_total_claimed
FROM healthcare.claims c
JOIN healthcare.diagnoses d ON c.diagnosis_id=d.diagnosis_id
LEFT JOIN payments_agg pa   ON c.claim_id=pa.claim_id
GROUP BY d.diagnosis_name, d.diagnosis_category
ORDER BY total_claimed DESC;
```

---

## 6. Actual Database Result

### V1 output — Top 10 diseases by total claim amount
> 📸 [`02_Output_V1/`](../screenshots/EXP01_Disease_Cost/02_Output_V1): [query](../screenshots/EXP01_Disease_Cost/02_Output_V1/EXP01_Output_V1_01_query.png) · [top diseases](../screenshots/EXP01_Disease_Cost/02_Output_V1/EXP01_Output_V1_02_top_diseases.png) · [category rollup](../screenshots/EXP01_Disease_Cost/02_Output_V1/EXP01_Output_V1_03_category_rollup.png) · [grand total](../screenshots/EXP01_Disease_Cost/02_Output_V1/EXP01_Output_V1_04_grand_total.png)

| # | Disease | Category | Claims | Total Claim ₹ | Avg/Claim ₹ | Approved % | % of Total Spend |
|--:|---|---|--:|--:|--:|--:|--:|
| 1 | Heart Disease | Cardiovascular | 7,497 | 2,072,827,175.57 | 276,487.55 | 75.8 | 30.1 |
| 2 | Coronary Artery Disease | Cardiovascular | 1,077 | 399,065,607.60 | 370,534.45 | 76.6 | 5.8 |
| 3 | Heart Failure | Cardiovascular | 1,100 | 317,895,256.29 | 288,995.69 | 75.4 | 4.6 |
| 4 | Cancer | Oncology | 1,821 | 278,589,933.03 | 152,987.33 | 75.9 | 4.0 |
| 5 | C-Section | Maternity | 1,129 | 248,086,115.35 | 219,739.69 | 75.3 | 3.6 |
| 6 | Stroke | Neurological | 1,854 | 244,509,352.47 | 131,882.07 | 75.5 | 3.5 |
| 7 | Road Accident Injury | Trauma | 1,061 | 234,309,476.62 | 220,838.34 | 76.3 | 3.4 |
| 8 | Chronic Kidney Disease | Renal | 1,865 | 223,682,140.11 | 119,936.80 | 75.8 | 3.2 |
| 9 | Kidney Disease | Renal | 1,818 | 223,607,442.41 | 122,996.39 | 77.1 | 3.2 |
| 10 | Burn Injury | Trauma | 1,077 | 221,396,979.46 | 205,568.23 | 77.7 | 3.2 |

Grand total claim spend (100,000 claims): **₹6,889,700,889.57**.

### V2 output — Portfolio grand totals (three money layers)
> 📸 [payment check](../screenshots/EXP01_Disease_Cost/04_Output_V2/EXP01_Output_V2_01_payment_validation.png) · [grand totals](../screenshots/EXP01_Disease_Cost/04_Output_V2/EXP01_Output_V2_04_grand_totals.png)

| Layer | Amount (₹) | Ratio |
|---|--:|--:|
| Total **claimed** | 6,889,700,889.57 | 100% |
| Total **approved** | 5,225,368,586.54 | 75.8% of claimed |
| Total paid — **settled (PAID)** | 2,834,964,771.91 | 54.3% of approved |
| Total paid incl. processing | 5,112,332,456.18 | 97.8% of approved |

### V2 output — Top 15 diseases (claimed / approved / settled / shares)
> 📸 [core query](../screenshots/EXP01_Disease_Cost/04_Output_V2/EXP01_Output_V2_02_core_query.png) · [top-15 output](../screenshots/EXP01_Disease_Cost/04_Output_V2/EXP01_Output_V2_03_top15_diseases.png)

| # | Disease | Category | Claims | Claimed ₹ | Avg ₹ | Approved ₹ | Appr% | Settled ₹ | %Claimed |
|--:|---|---|--:|--:|--:|--:|--:|--:|--:|
| 1 | Heart Disease | Cardiovascular | 7,497 | 2,072,827,175.57 | 276,488 | 1,571,375,818.98 | 75.8 | 854,252,471.66 | 30.1 |
| 2 | Coronary Artery Disease | Cardiovascular | 1,077 | 399,065,607.60 | 370,534 | 305,845,468.43 | 76.6 | 166,420,725.49 | 5.8 |
| 3 | Heart Failure | Cardiovascular | 1,100 | 317,895,256.29 | 288,996 | 239,706,234.44 | 75.4 | 132,494,711.73 | 4.6 |
| 4 | Cancer | Oncology | 1,821 | 278,589,933.03 | 152,987 | 211,577,977.12 | 75.9 | 114,136,958.97 | 4.0 |
| 5 | C-Section | Maternity | 1,129 | 248,086,115.35 | 219,740 | 186,787,590.20 | 75.3 | 102,182,726.31 | 3.6 |
| 6 | Stroke | Neurological | 1,854 | 244,509,352.47 | 131,882 | 184,685,489.81 | 75.5 | 98,077,869.33 | 3.5 |
| 7 | Road Accident Injury | Trauma | 1,061 | 234,309,476.62 | 220,838 | 178,877,724.56 | 76.3 | 90,251,290.18 | 3.4 |
| 8 | Chronic Kidney Disease | Renal | 1,865 | 223,682,140.11 | 119,937 | 169,455,598.44 | 75.8 | 89,009,337.29 | 3.2 |
| 9 | Kidney Disease | Renal | 1,818 | 223,607,442.41 | 122,996 | 172,373,591.47 | 77.1 | 94,273,492.62 | 3.2 |
| 10 | Burn Injury | Trauma | 1,077 | 221,396,979.46 | 205,568 | 172,099,290.37 | 77.7 | 93,292,291.54 | 3.2 |
| 11 | Pregnancy Complication | Maternity | 1,086 | 196,401,114.54 | 180,848 | 149,997,783.60 | 76.4 | 80,394,330.47 | 2.9 |
| 12 | Neonatal Complication | Pediatrics | 1,037 | 192,991,112.22 | 186,105 | 145,931,416.51 | 75.6 | 76,151,270.47 | 2.8 |
| 13 | Breast Cancer | Oncology | 1,145 | 175,688,443.07 | 153,440 | 133,385,687.10 | 75.9 | 69,910,022.07 | 2.6 |
| 14 | Lung Cancer | Oncology | 1,110 | 169,557,539.41 | 152,755 | 127,167,298.20 | 75.0 | 65,614,959.39 | 2.5 |
| 15 | Sepsis | Critical Care | 1,041 | 162,492,389.09 | 156,093 | 124,940,334.96 | 76.9 | 65,483,973.06 | 2.4 |

### V2 output — Category rollup (top)
> 📸 [category rollup](../screenshots/EXP01_Disease_Cost/04_Output_V2/EXP01_Output_V2_05_category_rollup.png)

| Category | Claims | Claimed ₹ | Approved ₹ | Settled ₹ | Appr% | %Total |
|---|--:|--:|--:|--:|--:|--:|
| Cardiovascular | 9,674 | 2,789,788,039.46 | 2,116,927,521.85 | 1,153,167,908.88 | 75.9 | **40.5** |
| Oncology | 4,076 | 623,835,915.51 | 472,130,962.42 | 249,661,940.43 | 75.7 | 9.1 |
| Maternity | 3,334 | 543,315,427.52 | 411,542,366.47 | 223,816,390.12 | 75.7 | 7.9 |
| Trauma | 2,138 | 455,706,456.08 | 350,977,014.93 | 183,543,581.72 | 77.0 | 6.6 |
| Renal | 3,683 | 447,289,582.52 | 341,829,189.91 | 183,282,829.91 | 76.4 | 6.5 |
| Orthopedic | 10,658 | 334,944,130.60 | 251,505,440.68 | 144,895,714.89 | 75.1 | 4.9 |
| Neurological | 7,118 | 299,812,934.01 | 226,861,078.98 | 121,075,750.99 | 75.7 | 4.4 |

### V2 output — Volume vs Severity (top drivers)
> 📸 [volume vs severity](../screenshots/EXP01_Disease_Cost/04_Output_V2/EXP01_Output_V2_06_volume_vs_severity.png)

| Disease | Claims | Avg Claim ₹ | Driver Type |
|---|--:|--:|---|
| Heart Disease | 7,497 | 276,488 | **BOTH volume + severity** |
| Coronary Artery Disease | 1,077 | 370,534 | Severity-driven |
| Heart Failure | 1,100 | 288,996 | Severity-driven |
| Cancer | 1,821 | 152,987 | Severity-driven |
| C-Section | 1,129 | 219,740 | Severity-driven |

### V2 output — Heart Disease cost-driver linkage
> 📸 [by policy type](../screenshots/EXP01_Disease_Cost/04_Output_V2/EXP01_Output_V2_07_hd_policy_type.png) · [by network](../screenshots/EXP01_Disease_Cost/04_Output_V2/EXP01_Output_V2_08_hd_network.png) · [by procedure](../screenshots/EXP01_Disease_Cost/04_Output_V2/EXP01_Output_V2_09_hd_procedures.png)

**By procedure:**
| Procedure | Claims | Claimed ₹ | Avg ₹ | Base Cost ₹ |
|---|--:|--:|--:|--:|
| Cardiac Surgery | 1,905 | 1,081,651,850.39 | 567,796 | 350,000 |
| Angioplasty | 1,930 | 763,253,747.39 | 395,468 | 220,000 |
| Echocardiogram | 1,785 | 215,152,064.98 | 120,533 | 4,500 |
| ECG | 1,877 | 12,769,512.81 | 6,803 | 1,800 |

**By network:** IN_NETWORK 6,019 claims / ₹1,668,214,600.22 (avg 277,158, appr 76.1%) · OUT_OF_NETWORK 1,478 / ₹404,612,575.35 (avg 273,757, appr 74.6%) → network status not a material cost differentiator.

**By policy type:** Individual ₹718,276,872.24 · Family ₹627,731,634.57 · Corporate ₹413,706,161.60 · Senior Citizen ₹313,112,507.16. Senior Citizen highest avg premium (₹65,326); avg coverage ~₹1.2M, deductibles ~₹9–10K across types.

---

## 7. Validation
Independent validation performed with **different SQL logic** (ROLLUP, scalar/IN/EXISTS subqueries, plain WHERE, standalone-vs-join). **8/8 checks PASS**, all differences 0.00 (only cosmetic share rounding). See [`../validation/EXP01_validation.md`](../validation/EXP01_validation.md). Fan-out risk eliminated: `claim_payments.claim_id` is UNIQUE (index `uq_payment_claim`) → structurally 1 payment per claim; standalone PAID total = joined PAID total = ₹2,834,964,771.91.

> 📸 Evidence [`05_Validation/`](../screenshots/EXP01_Disease_Cost/05_Validation): [grand totals (ROLLUP)](../screenshots/EXP01_Disease_Cost/05_Validation/EXP01_Validation_01_grand_totals_rollup.png) · [settled PAID](../screenshots/EXP01_Disease_Cost/05_Validation/EXP01_Validation_02_settled_paid.png) · [cardiovascular](../screenshots/EXP01_Disease_Cost/05_Validation/EXP01_Validation_03_cardiovascular.png) · [Heart Disease](../screenshots/EXP01_Disease_Cost/05_Validation/EXP01_Validation_04_heart_disease.png) · [HD settled](../screenshots/EXP01_Disease_Cost/05_Validation/EXP01_Validation_05_heart_disease_settled.png) · [CAD](../screenshots/EXP01_Disease_Cost/05_Validation/EXP01_Validation_06_coronary_artery.png) · [HD procedures](../screenshots/EXP01_Disease_Cost/05_Validation/EXP01_Validation_07_hd_procedures.png) · [fan-out check](../screenshots/EXP01_Disease_Cost/05_Validation/EXP01_Validation_08_fanout_check.png)

> **Why this matters:** the reported numbers are not taken on trust — each was reproduced by an independent query path, so a manager can rely on them for decisions.

---

## 8. Key Insight
- **Cardiovascular disease = 40.5% of all claimed spend** (₹2.79B). **Heart Disease alone = 30.1%** — one of 50 diagnoses consuming ~a third of the book, consistently across claimed, approved, and settled layers.
- **Heart Disease is the only "both volume + severity" driver** (7,497 claims @ ₹276K avg). Every other top disease is severity-driven (low count, high unit cost — Coronary Artery Disease highest at ₹370,534/claim).
- Within Heart Disease, **two procedures (Cardiac Surgery + Angioplasty) = ₹1.84B of ₹2.07B** claimed — cost is procedurally concentrated.

## 9. Business Impact
Because approval (~76%) and settlement (~54%) ratios are uniform across diseases, high claimed cost translates directly into high approved liability and high cash paid — so cardiovascular dominance is **real financial exposure**, not billing noise. 40% of payout tied to one category is a **concentration risk** for reserves and reinsurance.

## 10. Cost Optimization Opportunity
- Cardiovascular care-management program (highest ROI: a 3–5% reduction ≈ ₹84–140M, exceeding most whole categories).
- Bundled/case-rate negotiation for **Cardiac Surgery & Angioplasty** (₹1.84B in two procedures).
- Investigate the portfolio-wide ~24% claim→approved haircut at line-item level (confirm policy-driven vs systematic over-billing).

## 11. Revenue / Profitability Opportunity
*(distinct from cost saving)* — Risk-adjusted **premium repricing** for cardiac exposure (currently premium tracks policy type/age, not cardiac risk); managed-cardiac-network **product design**; loss-ratio improvement via preventive-cardiac riders. These change pricing/product economics, not merely claim spend.

## 12. Management Recommendation
1. Stand up cardiovascular cost-management first. 2. Negotiate cardiac procedure case rates. 3. Address the ₹2.28B PROCESSING settlement backlog (cash-flow). 4. Reinsure/diversify the 40% cardiovascular concentration. 5. Decompose the 24% approval haircut. *(All supported by the data at hand; deeper pricing/underwriting actions gated on the analyses in §14.)*

## 13. Limitations
- "Settled" = `payment_status='PAID'` only; `PROCESSING` (₹2.28B) is not final cash — settled totals are a point-in-time floor.
- 1,670 approved claims have no payment row yet (₹113M approved-not-in-pipeline gap between approved and paid-incl-processing).
- `procedures.base_cost` is a reference cost; claims legitimately exceed it — the multiple is **not** by itself evidence of overcharging.
- No fraud/readmission/line-item tables exist, so the approval-haircut root cause cannot be decomposed from this schema alone.

## 14. Next Analysis (before pricing/underwriting/provider decisions)
Loss ratio vs premium by segment · payment aging on the PROCESSING backlog · hospital-level unit-cost benchmarking for cardiac procedures · 2024–2026 trend/seasonality · per-patient utilization/readmission · line-item decomposition of the claim→approved gap. → feeds **EXP02 (hospital cost)**, **EXP05 (settlement)**, **EXP06–07 (profitability/loss ratio)**.
