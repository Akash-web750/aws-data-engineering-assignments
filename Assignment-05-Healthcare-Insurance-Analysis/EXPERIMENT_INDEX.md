# Experiment Index

Live tracker for all experiments. One experiment at a time; stop for approval before the next.

| Exp ID | Business Question | Prompt Versions | Validation Status | Main Finding | Business Value | Screenshots | Documentation |
|---|---|---|---|---|---|---|---|
| **EXP01** | Which diseases drive the highest claim cost & risk (volume vs severity)? | V1, V2 | ✅ **8/8 PASS** (independent) | Cardiovascular = 40.5% of claimed spend; Heart Disease alone = 30.1% (only "both volume+severity" driver); ₹1.84B in 2 procedures | Targets highest-ROI cost-management + concentration-risk area; separates cost-saving vs profitability levers | 11 planned (manual) | ✅ Complete |
| EXP02 | Which hospitals/providers/networks drive cost? | — | ⏳ | — | — | — | ⏳ Not started |
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
- `screenshots/EXP01_screenshot_checklist.md` — 11-item checklist

## Legend
✅ Complete · ⏳ Not started · 🔄 In progress · ⚠️ Needs attention
