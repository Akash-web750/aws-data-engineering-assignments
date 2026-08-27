# EXP01 — Screenshot Evidence Index

Visual evidence for Experiment 01 (Disease-wise Claim Cost & Risk Analysis), captured from **pgAdmin 4 / PostgreSQL 17** against the live `healthcare_insurance` database. Originals are preserved on the source machine; these are organized copies. **Every figure shown in these screenshots matches the documented results and the independent validation exactly.**

## Folder layout
```
EXP01_Disease_Cost/
├── 01_Prompt_V1/     the exact basic prompt
├── 02_Output_V1/     V1 SQL + results (top diseases, category rollup, grand total)
├── 03_Prompt_V2/     the exact improved prompt
├── 04_Output_V2/     V2 SQL + results (payments, top-15, grand totals, linkage)
├── 05_Validation/    independent validation (8 checks)
└── 06_Comparison/    (no screenshot — see note below)
```

## 01_Prompt_V1
| File | Shows |
|---|---|
| `EXP01_Prompt_V1_01.png` | Exact Prompt V1 (basic) |

## 02_Output_V1
| File | Shows | Key figures |
|---|---|---|
| `EXP01_Output_V1_01_query.png` | V1 ranking SQL | — |
| `EXP01_Output_V1_02_top_diseases.png` | Top-10 diseases by claim amount | Heart Disease ₹2,072,827,175.57 (30.1%) |
| `EXP01_Output_V1_03_category_rollup.png` | Category rollup | Cardiovascular 40.5% |
| `EXP01_Output_V1_04_grand_total.png` | Grand total claim spend | ₹6,889,700,889.57 |

## 03_Prompt_V2
| File | Shows |
|---|---|
| `EXP01_Prompt_V2_01.png` | Exact Prompt V2 (improved) |

## 04_Output_V2
| File | Shows | Key figures |
|---|---|---|
| `EXP01_Output_V2_01_payment_validation.png` | Payment cardinality/status check | 1 payment/claim, 83,328 |
| `EXP01_Output_V2_02_core_query.png` | Core disease-level SQL (payments pre-aggregated) | — |
| `EXP01_Output_V2_03_top15_diseases.png` | Top-15 diseases: claimed/approved/settled | Heart Disease claimed 2,072,827,175.57 · approved 1,571,375,818.98 · settled 854,252,471.66 |
| `EXP01_Output_V2_04_grand_totals.png` | Portfolio grand totals (3 layers) | claimed 6,889,700,889.57 · approved 5,225,368,586.54 (75.8%) · settled 2,834,964,771.91 (54.3%) |
| `EXP01_Output_V2_05_category_rollup.png` | Category rollup (claimed/approved/settled) | Cardiovascular 40.5% |
| `EXP01_Output_V2_06_volume_vs_severity.png` | Volume vs severity classifier | Heart Disease = BOTH |
| `EXP01_Output_V2_07_hd_policy_type.png` | Heart Disease by policy type | Individual ₹718,276,872.24 … |
| `EXP01_Output_V2_08_hd_network.png` | Heart Disease by hospital network | IN 6,019 / OUT 1,478; avg ~₹277k vs ~₹274k |
| `EXP01_Output_V2_09_hd_procedures.png` | Heart Disease top procedures (+base_cost) | Cardiac Surgery 1,081,651,850.39 · Angioplasty 763,253,747.39 |

## 05_Validation (independent, different SQL logic)
| File | Validation check | Result |
|---|---|---|
| `EXP01_Validation_01_grand_totals_rollup.png` | Grand totals via ROLLUP by status | claimed 6,889,700,889.57 · approved 5,225,368,586.54 ✅ |
| `EXP01_Validation_02_settled_paid.png` | Settled PAID via plain WHERE | 47,090 rows · 2,834,964,771.91 ✅ |
| `EXP01_Validation_03_cardiovascular.png` | Cardiovascular via IN-subquery | 9,674 · 2,789,788,039.46 · 40.49% ✅ |
| `EXP01_Validation_04_heart_disease.png` | Heart Disease via scalar subquery | 7,497 · 2,072,827,175.57 · 1,571,375,818.98 · 30.09% ✅ |
| `EXP01_Validation_05_heart_disease_settled.png` | Heart Disease settled via IN-subquery | 3,505 rows · 854,252,471.66 ✅ |
| `EXP01_Validation_06_coronary_artery.png` | CAD count + avg via WHERE | 1,077 · avg 370,534.45 ✅ |
| `EXP01_Validation_07_hd_procedures.png` | HD procedures via EXISTS + ROLLUP | combined 1,844,905,597.78 ✅ |
| `EXP01_Validation_08_fanout_check.png` | Fan-out / duplicate-counting check | 83,328 rows = 83,328 distinct claims, max 1/claim ✅ |

## 06_Comparison
> ⚠️ **No V1-vs-V2 comparison screenshot exists** in the source set. The written comparison is in [`../../experiments/EXP01_v1_vs_v2_comparison.md`](../../experiments/EXP01_v1_vs_v2_comparison.md). If a screenshot is desired later, capture the comparison table and save it here as `EXP01_Comparison_01.png`.

---
*Nothing in these screenshots was edited. All values are actual pgAdmin output; cross-checked against `results/EXP01_actual_results.md` and `validation/EXP01_validation.md`.*
