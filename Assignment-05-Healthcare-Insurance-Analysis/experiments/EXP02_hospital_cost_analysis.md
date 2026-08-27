# EXPERIMENT 02 — Hospital / Provider Cost Analysis

> Status: ✅ Analysis + Independent Validation complete (9/9 PASS) · 📸 pgAdmin result grids captured (17) · Read-only · No DB modification.
> All figures are actual PostgreSQL 17 output from `healthcare_insurance` / schema `healthcare`. Nothing invented.
> 📸 **Evidence:** [`../screenshots/EXP02_Hospital_Cost/`](../screenshots/EXP02_Hospital_Cost) — **actual pgAdmin SQL + Data-Output grids** for the V1 ranking, all V2 outputs, and all 9 validation checks (indexed in its [README](../screenshots/EXP02_Hospital_Cost/README.md)).

**⏱️ 30-second read:** Unlike disease cost (highly concentrated), **hospital cost is NOT concentrated** — the single biggest hospital is just **0.34%** of spend, and the most expensive hospital is only **1.69× the average**. Out-of-network is **not** more expensive (₹67,655 vs ₹69,185 in-network), and average cost per claim is **uniform across hospital types** (₹67.5k–69.9k). Hospital cost tracks **claim volume**, and the modest ranking differences are driven by a **few large (high-severity) claims** (median ≪ mean), not systematic overpricing. Every figure independently validated (9/9).

---

## 1. Business Question
Which hospitals are driving the highest healthcare insurance claim costs, and are some hospitals materially more expensive than others?

## 2. Business Objective
Identify high-cost providers and determine whether high hospital cost is driven by claim volume, average cost per claim, disease mix, procedure mix, network status, or approval/payment behavior — to inform provider/network optimization, contract negotiation, and cost/risk management.

## 3. Analysis Goal
Rank hospitals by claimed cost; decompose into volume vs unit cost; quantify dispersion and statistical outliers; compare network status and hospital type; test whether case mix explains high averages; distinguish claimed vs approved vs paid — all with payment-join safety and independent validation.

## 4. Data Used
- `healthcare.claims` (100,000) — `hospital_id`, `claim_amount`, `approved_amount`, `claim_status`, `diagnosis_id`, `procedure_id`, dates.
- `healthcare.hospitals` (500) — `hospital_id`, `hospital_name`, **`hospital_type`** (Private/Government/Multi-Specialty/Specialty), **`network_status`** (IN 406 / OUT 94), `city`, `state`, `bed_capacity`.
- `healthcare.claim_payments` (83,328) — `paid_amount`, `payment_status` (PAID/PROCESSING); verified **1:1** with claims.
- `healthcare.diagnoses` — for case-mix context. *(Available but not needed for the core question: `patients`, `policies`, `procedures` used only for context.)*

## 5. Methodology
SQL on the live DB (read-only) → V1 baseline ranking → V1 gap evaluation → V2 improved prompt (metrics, dispersion, outliers, network/type, case mix, ratios) → independent validation with different SQL logic. Payments aggregated per claim **before** joining (fan-out impossible; also structurally guaranteed by a UNIQUE index).

## 6. Prompt V1
Verbatim in [`EXP02_prompts.md`](EXP02_prompts.md). 📸 Business question / brief: [`01_Prompt_V1/EXP02_Prompt_V1_01.png`](../screenshots/EXP02_Hospital_Cost/01_Prompt_V1/EXP02_Prompt_V1_01.png).

## 7. V1 Results
Top hospital = **Madan Private (362)**: 214 claims, ₹23,220,662.41, avg ₹108,507.77, **0.34%** of total spend. Grand total ₹6,889,700,889.57 across **500** hospitals (avg 200 claims each). Full top-10 in [`results/EXP02_actual_results.md`](../results/EXP02_actual_results.md). 📸 pgAdmin grids: [top-10](../screenshots/EXP02_Hospital_Cost/02_Output_V1/EXP02_Output_V1_01_top10_grid.png) · [context total](../screenshots/EXP02_Hospital_Cost/02_Output_V1/EXP02_Output_V1_02_context.png).

## 8. V1 Limitations
Volume-vs-unit-cost not separated; concentration not quantified; mean hides skew (no median); no approved/paid layers; no network/type comparison; no case-mix test; no statistical outlier basis; no approval/settlement ratios. (See `EXP02_prompts.md` → V1 Evaluation.)

## 9. Prompt V2
Verbatim in [`EXP02_prompts.md`](EXP02_prompts.md). 📸 Brief (V2 stage): [`03_Prompt_V2/EXP02_Prompt_V2_01.png`](../screenshots/EXP02_Hospital_Cost/03_Prompt_V2/EXP02_Prompt_V2_01.png).

## 10. V2 Results (all validated)

**Cost is diffuse, not concentrated.**
| Metric | Value |
|---|---|
| Biggest hospital share | **0.34%** (Madan Private, 362) |
| Max hospital total vs average | **1.69×** (₹23.2M vs ₹13.8M avg) |
| Avg-claim range across 500 hospitals | ₹45,167 – ₹112,479 (mean ₹68,898) |
| Statistical outliers (avg claim > mean+2·sd, >₹90,128) | **15 of 500** hospitals |

**Median ≪ mean (right-skew):** e.g. hospital 362 avg ₹108,508 but **median ₹14,910** — a few large claims drive the average.

**Network comparison — out-of-network is NOT more expensive:**
| Network | Hospitals | Claims | Total Claimed ₹ | Avg ₹ | Appr% | Settle% | %Total |
|---|--:|--:|--:|--:|--:|--:|--:|
| IN_NETWORK | 406 | 81,174 | 5,616,020,891.37 | 69,184.97 | 76.0 | 54.1 | 81.5 |
| OUT_OF_NETWORK | 94 | 18,826 | 1,273,679,998.20 | 67,655.37 | 75.3 | 54.9 | 18.5 |

In-network is 81.5% of spend purely because 406 of 500 hospitals are in-network (**volume**), not higher unit cost.

**Hospital type — uniform average cost per claim:**
| Type | Hospitals | Total Claimed ₹ | Avg ₹ | Appr% | %Total |
|---|--:|--:|--:|--:|--:|
| Private | 218 | 3,015,388,842.88 | 68,964.16 | 75.8 | 43.8 |
| Multi-Specialty | 103 | 1,439,966,718.99 | 69,918.27 | 75.6 | 20.9 |
| Government | 107 | 1,429,240,312.27 | 67,477.47 | 75.9 | 20.7 |
| Specialty | 72 | 1,005,105,015.43 | 69,317.59 | 76.2 | 14.6 |

Type share tracks hospital count; averages differ by <4%.

**Case-mix test (why is the top hospital "expensive"?):** hospital 362's biggest claims are cardiac (Heart Disease avg ₹422,080; CAD avg ₹551,064). But across the 15 high-average hospitals, cardiovascular **spend share is only 42.1% vs 40.4%** for the rest — so case mix explains only a small part; most of the gap is right-skew (a few very large claims).

Full tables: [`results/EXP02_actual_results.md`](../results/EXP02_actual_results.md). 📸 pgAdmin grids [`04_Output_V2/`](../screenshots/EXP02_Hospital_Cost/04_Output_V2): [payment-safety](../screenshots/EXP02_Hospital_Cost/04_Output_V2/EXP02_Output_V2_01_payment_safety.png) · [top-15](../screenshots/EXP02_Hospital_Cost/04_Output_V2/EXP02_Output_V2_03_top15_grid.png) · [dispersion](../screenshots/EXP02_Hospital_Cost/04_Output_V2/EXP02_Output_V2_04_dispersion.png) · [outliers](../screenshots/EXP02_Hospital_Cost/04_Output_V2/EXP02_Output_V2_05_outliers.png) · [network](../screenshots/EXP02_Hospital_Cost/04_Output_V2/EXP02_Output_V2_06_network.png) · [type](../screenshots/EXP02_Hospital_Cost/04_Output_V2/EXP02_Output_V2_07_type.png) · [case-mix](../screenshots/EXP02_Hospital_Cost/04_Output_V2/EXP02_Output_V2_08_casemix_362.png) · [case-mix test](../screenshots/EXP02_Hospital_Cost/04_Output_V2/EXP02_Output_V2_09_casemix_test.png).

## 11. Independent Validation
**9/9 PASS**, all Δ = 0.00, via different SQL logic (subtotal reconciliation, direct WHERE, IN/scalar subqueries, standalone-vs-join). Grand total reconciles from per-hospital subtotals; hospital-362 figures, network split, and fan-out check all reproduce. See [`validation/EXP02_validation.md`](../validation/EXP02_validation.md). 📸 pgAdmin grids [`05_Validation/`](../screenshots/EXP02_Hospital_Cost/05_Validation): [reconciliation](../screenshots/EXP02_Hospital_Cost/05_Validation/EXP02_Validation_01_reconciliation.png) · [hospital-362](../screenshots/EXP02_Hospital_Cost/05_Validation/EXP02_Validation_02_hospital362.png) · [settled](../screenshots/EXP02_Hospital_Cost/05_Validation/EXP02_Validation_03_settled.png) · [share](../screenshots/EXP02_Hospital_Cost/05_Validation/EXP02_Validation_04_share.png) · [network](../screenshots/EXP02_Hospital_Cost/05_Validation/EXP02_Validation_05_network.png) · [fan-out](../screenshots/EXP02_Hospital_Cost/05_Validation/EXP02_Validation_06_fanout.png).

## 12. V1 vs V2 Comparison
See [`EXP02_v1_vs_v2_comparison.md`](EXP02_v1_vs_v2_comparison.md). V1 produced a ranking that *looks* like "these hospitals are the cost problem"; V2 showed the ranking is nearly flat (0.27–0.34% each), driven by volume and a few large claims — a materially different and safer business conclusion.

## 13. Business Insights (WHAT / WHY / SO-WHAT / NEXT)
- **WHAT:** No hospital is a material cost driver (top = 0.34%; max only 1.69× average). **WHY:** claims are spread evenly (~200/hospital) and per-claim cost is uniform across networks and types. **SO-WHAT:** there is **no single-provider cost problem** to fix; provider-level renegotiation of "the expensive hospital" would move almost nothing. **NEXT:** focus cost levers at the **disease/procedure** level (EXP01) and on the **few large high-severity claims**, not on individual hospitals.
- **WHAT:** Out-of-network is not more expensive. **WHY:** avg claim ₹67,655 (OUT) ≈ ₹69,185 (IN); approval/settlement ratios ~equal. **SO-WHAT:** aggressive network-steering for *cost* is not justified by this data. **NEXT:** if steering is considered, justify it on quality/access, not price.
- **WHAT:** Hospital averages are skewed by a few large claims (median ₹13k–27k vs mean ₹88k–112k). **WHY:** high-severity cardiac/oncology/trauma cases. **SO-WHAT:** manage the **high-cost-claim tail**, not the hospital. **NEXT:** EXP planned — high-cost-claim (tail) analysis.

## 14. Recommendations (evidence-based, separated)
- **Cost reduction:** Do **not** prioritize single-hospital renegotiation — evidence shows negligible concentration. Redirect effort to disease/procedure cost (EXP01: cardiac bundles) and the high-cost-claim tail.
- **Risk management:** Monitor the 15 statistical outlier hospitals (avg claim > ₹90,128) for *emerging* concentration, but treat current spread as healthy diversification.
- **Provider/network strategy:** Network status is not a cost lever here; base network decisions on quality/access/coverage, not price.
- **Profitability:** Uniform approval (~76%) and settlement (~54%) across hospitals means margin levers are systemic (pricing/underwriting), not provider-specific.
- **Revenue / pricing:** *No revenue-growth claim is supported by hospital data.* Any pricing action belongs at the risk/disease level (EXP01), not the provider level.

## 15. Limitations / Follow-up
- "Expensive hospital" averages are **right-skewed**; median is the fairer central measure — reported both.
- Case mix explains only part of the outlier gap; confirming the remainder needs **claim-line-item / severity-adjusted** analysis not present in this schema.
- `bed_capacity`, `city`, `state` were not used for cost normalization — a **per-bed / geographic** cost analysis is a natural follow-up.
- Settlement ratio (~54%) reflects the portfolio-wide PROCESSING backlog (EXP01), not hospital behavior.
- **Follow-up experiments:** high-cost-claim tail (EXP planned), geographic concentration, procedure-level cost (EXP03).
