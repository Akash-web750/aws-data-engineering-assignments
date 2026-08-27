# Project Plan & Analytics Roadmap

## Objective

Answer: *"Where is the insurance company's claim money going, what is driving the cost and risk, and where are the opportunities to improve cost management, profitability and sustainable revenue growth?"*

Method: a sequence of focused experiments, each with a clear management question, a V1→V2 prompt-engineering experiment, actual PostgreSQL results, and independent validation. **One experiment at a time — stop and await approval before starting the next.**

## Guardrails

- Read-only DB access only. No DDL/DML, ever.
- Distinguish `claim_amount` / `approved_amount` / `paid_amount` (PAID vs PROCESSING).
- Never claim "validated" without an independent reproduction using different SQL logic.
- Never label a cost saving as revenue growth.
- Recommend pricing/underwriting/reinsurance/provider/product actions only where data supports them.

## Prioritized roadmap

Ordered so that each experiment builds on prior findings (cost drivers → where → so-what → profitability).

| # | Experiment | Management question | Primary tables | Status |
|--:|---|---|---|---|
| **01** | **Disease / diagnosis cost drivers** | Which diseases drive the highest claim cost & risk; volume vs severity? | claims, diagnoses, claim_payments | ✅ **Complete (8/8 validated)** |
| **02** | **Hospital / provider cost drivers** | Which hospitals/networks drive cost; is out-of-network more expensive? | claims, hospitals, claim_payments | ✅ **Complete (9/9 validated; 17 pgAdmin grids)** — cost NOT concentrated; out-of-network not more expensive |
| 03 | Procedure cost drivers | Which procedures drive cost; claim vs base_cost gap? | claims, procedures | ⏳ Planned |
| 04 | Claim approval & rejection patterns | What drives rejections/partial approvals; where is the claim→approved gap? | claims, diagnoses, hospitals | ⏳ Planned |
| 05 | Payment / settlement behavior | PAID vs PROCESSING aging; outstanding payables exposure? | claim_payments, claims | ⏳ Planned |
| 06 | Policy profitability | Which policy types/segments are profitable (premium vs claim cost)? | policies, claims, claim_payments | ⏳ Planned |
| 07 | Premium vs claim cost / Loss ratio | Portfolio & segment loss ratios? | policies, claims | ⏳ Planned |
| 08 | Patient / member risk segments | Which member segments are high-cost/high-risk? | patients, policies, claims | ⏳ Planned |
| 09 | Geographic cost concentration | Which states/cities concentrate cost (where data supports)? | patients/hospitals, claims | ⏳ Planned |
| 10 | High-cost claims (tail) | What share of cost comes from the top X% of claims? | claims | ⏳ Planned |
| 11 | Frequency vs severity (portfolio) | Portfolio-level frequency vs severity decomposition | claims, diagnoses | ⏳ Planned |
| 12 | Cost trends over time | Are costs rising 2024→2026; seasonality? | claims, claim_payments | ⏳ Planned |
| 13 | Policy segment risk | Risk by policy_type/status | policies, claims | ⏳ Planned |
| 14 | Fraud / anomaly indicators | Outlier claims/providers (where data supports) | claims, hospitals, procedures | ⏳ Planned |
| 15 | Cost-optimization synthesis | Consolidated savings opportunities | all prior | ⏳ Planned |
| 16 | Revenue / profitability synthesis | Consolidated pricing/growth opportunities | all prior | ⏳ Planned |

## Per-experiment deliverables

- `experiments/EXPxx_*.md` — full 14-section analysis document
- `sql/EXPxx_v1.sql`, `sql/EXPxx_v2.sql`, `sql/EXPxx_validation.sql`
- `validation/EXPxx_validation.md` — independent checks with PASS/FAIL
- `results/EXPxx_*` — captured actual results
- `screenshots/EXPxx_screenshot_checklist.md`
- Update `EXPERIMENT_INDEX.md`

## Final deliverable (later, not yet)

Markdown → professional PDF/Canva portfolio with 20 sections (see docs/ when drafted): Executive Summary → Business Problem → Objectives → Domain Context → Database Architecture → Data Dictionary → Analytical Methodology → Prompt-Engineering Methodology → Experiment-wise Analysis → SQL → Validation → Insights → Cost Drivers → Risk Drivers → Profitability → Revenue Growth → Recommendations → Limitations → Future Analysis → Final Conclusion.
