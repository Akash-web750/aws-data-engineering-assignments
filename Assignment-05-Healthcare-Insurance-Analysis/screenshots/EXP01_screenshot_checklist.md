# EXPERIMENT 01 — Screenshot Checklist

Screenshots are captured **manually** by the project owner from Claude Code and saved into this `screenshots/` folder using the filenames below. This checklist maps each screenshot to its content and the document section that uses it. (Count is a recommendation, not a hard limit — add more if a result spans multiple screens.)

| # | Filename | Should contain | Used in section |
|--:|---|---|---|
| 1 | `EXP01_DiseaseCost_Prompt_V1.png` | The exact V1 prompt text | EXP01_prompts.md — Prompt V1 |
| 2 | `EXP01_DiseaseCost_Output_V1_1.png` | V1 SQL + Top-10 diseases result | EXP01 §6 (V1 output) |
| 3 | `EXP01_DiseaseCost_Output_V1_2.png` | V1 category rollup + grand total | EXP01 §6 (V1 output) |
| 4 | `EXP01_DiseaseCost_Prompt_V2.png` | The exact V2 prompt text | EXP01_prompts.md — Prompt V2 |
| 5 | `EXP01_DiseaseCost_Output_V2_1.png` | V2 payment validation + grand totals (3 layers) | EXP01 §6 (V2) |
| 6 | `EXP01_DiseaseCost_Output_V2_2.png` | V2 Top-15 disease table (claimed/approved/settled) | EXP01 §6 (V2) |
| 7 | `EXP01_DiseaseCost_Output_V2_3.png` | V2 category rollup + volume/severity classification | EXP01 §6 (V2) |
| 8 | `EXP01_DiseaseCost_Output_V2_4.png` | V2 Heart Disease linkage (procedure/network/policy) | EXP01 §6 (V2) |
| 9 | `EXP01_DiseaseCost_Validation_1.png` | Validation items 1–5b (grand totals, PAID, cardio, Heart Disease) | EXP01_validation.md |
| 10 | `EXP01_DiseaseCost_Validation_2.png` | Validation items 6–8 (CAD, procedures, fan-out/standalone-vs-join) | EXP01_validation.md |
| 11 | `EXP01_DiseaseCost_Comparison.png` | V1 vs V2 comparison summary | EXP01_prompts.md — comparison |

**Capture tips:** include the `psql` command context where visible so the read-only session and DB name are provable; ensure full result rows (no truncation) or split across the numbered `_1/_2` files.
