# EXPERIMENT 01 — Screenshot Checklist & Capture Status

Screenshots were captured from **pgAdmin 4 / PostgreSQL 17** and are now organized under
[`EXP01_Disease_Cost/`](EXP01_Disease_Cost) (full index in its [README](EXP01_Disease_Cost/README.md)).

**Status: 23 captured · 1 optional gap (V1-vs-V2 comparison).**

| Stage | Folder | Captured | Notes |
|---|---|:--:|---|
| Prompt V1 | `01_Prompt_V1/` | ✅ 1 | exact basic prompt |
| Output V1 | `02_Output_V1/` | ✅ 4 | query, top diseases, category rollup, grand total |
| Prompt V2 | `03_Prompt_V2/` | ✅ 1 | exact improved prompt |
| Output V2 | `04_Output_V2/` | ✅ 9 | payment check, core query, top-15, grand totals, category, volume/severity, HD policy/network/procedure |
| Validation | `05_Validation/` | ✅ 8 | one image per validation check (1–8) |
| Comparison | `06_Comparison/` | ⬜ 0 | **optional gap** — no source screenshot; written comparison in `experiments/EXP01_v1_vs_v2_comparison.md`. To add later, save as `06_Comparison/EXP01_Comparison_01.png`. |

**Capture standard used:** each image shows the SQL and the pgAdmin data-output grid, so the read-only session, DB name, and exact result rows are visible and provable. Every figure shown matches `results/EXP01_actual_results.md` and `validation/EXP01_validation.md`.
