# EXP02 — Screenshot Evidence Index

Visual evidence for Experiment 02 (Hospital / Provider Cost Analysis), captured from **pgAdmin 4 / PostgreSQL 17** against the live `healthcare_insurance` database. **Every figure in these grids matches the documented results and the independent validation exactly.** Originals preserved in the Windows source; these are organized copies.

## 01_Prompt_V1 & 03_Prompt_V2
| File | Shows |
|---|---|
| `01_Prompt_V1/EXP02_Prompt_V1_01.png` | Experiment brief / business question (V1 stage) |
| `03_Prompt_V2/EXP02_Prompt_V2_01.png` | Experiment brief (V2 stage requirements) |

## 02_Output_V1 — actual pgAdmin grids (`sql/EXP02_v1.sql`)
| File | Query | Key figures |
|---|---|---|
| `EXP02_Output_V1_01_top10_grid.png` | V1.1 | Top-10; Madan Private (362) ₹23,220,662.41 · 214 · 0.34% |
| `EXP02_Output_V1_02_context.png` | V1.2 | grand_total ₹6,889,700,889.57 · 500 hospitals · avg 68,897.01 |

## 04_Output_V2 — actual pgAdmin grids (`sql/EXP02_v2.sql`)
| File | Query | Key figures |
|---|---|---|
| `EXP02_Output_V2_01_payment_safety.png` | V2.0 | max 1 payment/claim · 83,328 = 83,328 (no fan-out) |
| `EXP02_Output_V2_02_top15_sql.png` | V2.1 | the full V2.1 SQL (readable) |
| `EXP02_Output_V2_03_top15_grid.png` | V2.1 | Top-15 grid (362 median 14,909.91 · settle 46.9%) |
| `EXP02_Output_V2_04_dispersion.png` | V2.2 | max_vs_avg **1.69** · min 8,748,757 · max 23,220,662 |
| `EXP02_Output_V2_05_outliers.png` | V2.3 | **15** hospitals > threshold 90,128 (mean 68,898) |
| `EXP02_Output_V2_06_network.png` | V2.4 | IN avg 69,184.97 (81.5%) vs OUT avg 67,655.37 (18.5%) |
| `EXP02_Output_V2_07_type.png` | V2.5 | Private/Multi/Govt/Specialty avg 67,477–69,918 (uniform) |
| `EXP02_Output_V2_08_casemix_362.png` | V2.6 | Hospital 362: Heart Disease ₹7,597,447.15 (avg 422,080), CAD (avg 551,064) |
| `EXP02_Output_V2_09_casemix_test.png` | V2.7 | outliers cardio spend 42.1% vs rest 40.4%; avg 100,035 vs 67,954 |

## 05_Validation — actual pgAdmin grids (`sql/EXP02_validation.sql`)
| File | Check | Result |
|---|---|---|
| `EXP02_Validation_01_reconciliation.png` | (1) subtotal reconciliation | 6,889,700,889.57 ✅ |
| `EXP02_Validation_02_hospital362.png` | (2–5) hospital 362 direct WHERE | 214 · 23,220,662.41 · 108,507.77 · 17,133,388.83 ✅ |
| `EXP02_Validation_03_settled.png` | (6) 362 settled via IN-subquery | 106 rows · 8,043,194.07 ✅ |
| `EXP02_Validation_04_share.png` | (7) 362 share | 0.337 ✅ |
| `EXP02_Validation_05_network.png` | (8) network via IN-subquery | IN 5,616,020,891.37 · OUT 1,273,679,998.20 ✅ |
| `EXP02_Validation_06_fanout.png` | (9) fan-out / duplicate-count | standalone = joined = 8,043,194.07; 187 = 187 ✅ |

## 06_Comparison — workflow / documentation (session captures)
| File | Shows |
|---|---|
| `EXP02_Comparison_01_index_update.png` | EXPERIMENT_INDEX update + EXP02 file manifest |
| `EXP02_Comparison_02_sql_files.png` | Creation of the EXP02 SQL files |
| `EXP02_Comparison_03_doc_files.png` | Creation of the EXP02 documentation files |
| *(written V1↔V2 comparison)* | [`../../experiments/EXP02_v1_vs_v2_comparison.md`](../../experiments/EXP02_v1_vs_v2_comparison.md) |

## Status
✅ **Evidence gap closed** — actual pgAdmin database-result grids now cover the V1 ranking, all V2 outputs, and all 9 validation checks. All numbers cross-checked against [`../../results/EXP02_actual_results.md`](../../results/EXP02_actual_results.md) and [`../../validation/EXP02_validation.md`](../../validation/EXP02_validation.md). No passwords/tokens/credentials visible in any image.
