# Experiment Index

Live tracker for all experiments. One experiment at a time; stop for approval before the next.

| Exp ID | Business Question | Prompt Versions | Validation Status | Main Finding | Business Value | Screenshots | Documentation |
|---|---|---|---|---|---|---|---|
| **EXP01** | Which diseases drive the highest claim cost & risk (volume vs severity)? | V1, V2 | ✅ **8/8 PASS** (independent) | Cardiovascular = 40.5% of claimed spend; Heart Disease alone = 30.1% (only "both volume+severity" driver); ₹1.84B in 2 procedures | Targets highest-ROI cost-management + concentration-risk area; separates cost-saving vs profitability levers | 11 planned (manual) | ✅ Complete |
| **EXP02** | Which hospitals drive cost; are any materially more expensive? | V1, V2 | ✅ **9/9 PASS** (independent) | Hospital cost is **NOT** concentrated — top hospital = 0.34%, max only 1.69× avg; out-of-network not more expensive; avg cost/claim uniform across types; ranking driven by a few large claims | Prevents a low-value "renegotiate top hospital" action; redirects cost levers to disease/procedure + high-cost-claim tail | ✅ 17 pgAdmin grids + prompts | ✅ Complete |
| EXP03 | Which procedures drive cost (claim vs base_cost)? | — | ⏳ | — | — | — | ⏳ Not started |
| EXP04 | What drives approvals/rejections & the claim→approved gap? | — | ⏳ | — | — | — | ⏳ Not started |
| EXP05 | Settlement behavior: PAID vs PROCESSING aging / payables? | — | ⏳ | — | — | — | ⏳ Not started |
| EXP06 | Policy profitability (premium vs claim cost)? | — | ⏳ | — | — | — | ⏳ Not started |
| EXP07 | Loss ratio (portfolio & segment)? | — | ⏳ | — | — | — | ⏳ Not started |
| EXP08+ | See PROJECT_PLAN.md roadmap | — | ⏳ | — | — | — | ⏳ Not started |

## EXP01 file manifest
- `experiments/EXP01_disease_cost_analysis.md` — full 14-section analysis
- `experiments/EXP01_prompts.md` — exact V1 & V2 prompts, V1 evaluation, V1↔V2 comparison, final conclusion
- `sql/EXP01_v1.sql`, `sql/EXP01_v2.sql`, `sql/EXP01_validation.sql`
- `validation/EXP01_validation.md` — 8/8 PASS
- `results/EXP01_actual_results.md` — captured raw results
- `screenshots/EXP01_Disease_Cost/` — 23 organized screenshots + index; `EXP01_screenshot_checklist.md`

## EXP02 file manifest
- `experiments/EXP02_hospital_cost_analysis.md` — full 15-section analysis
- `experiments/EXP02_prompts.md` — exact V1 & V2 prompts + V1 evaluation
- `experiments/EXP02_v1_vs_v2_comparison.md` — V1↔V2 comparison
- `sql/EXP02_v1.sql`, `sql/EXP02_v2.sql`, `sql/EXP02_validation.sql`
- `validation/EXP02_validation.md` — 9/9 PASS
- `results/EXP02_actual_results.md` — captured raw results
- `screenshots/EXP02_Hospital_Cost/` (structure + index) + `screenshots/EXP02_screenshot_checklist.md` — ⏳ capture pending

## Legend
✅ Complete · ⏳ Not started · 🔄 In progress · ⚠️ Needs attention
