# EXPERIMENT 02 — Captured Actual Database Results

Raw actual output from PostgreSQL 17.9 / `healthcare_insurance` / schema `healthcare`. Read-only. Provenance for the analysis narrative in `experiments/EXP02_hospital_cost_analysis.md`.

## Context totals
```
grand_total_claimed      = 6,889,700,889.57   (reconciles with EXP01)
hospitals_with_claims    = 500
overall_avg_claim        = 68,897.01
avg_claims_per_hospital  = 200
payments 1:1 with claims = YES (max 1 payment/claim; 83,328 rows = 83,328 distinct claims)
```

## V1 — Top 10 hospitals by total claim amount
| Hospital (id) | Type | Network | Claims | Total Claimed ₹ | Avg Claim ₹ | % of Total |
|---|---|---|--:|--:|--:|--:|
| Madan Private (362) | Private | IN | 214 | 23,220,662.41 | 108,507.77 | 0.34 |
| Sami Government (74) | Government | IN | 207 | 22,164,803.68 | 107,076.35 | 0.32 |
| Venkataraman Private (395) | Private | IN | 217 | 21,551,607.96 | 99,316.17 | 0.31 |
| Kaul Specialty (391) | Specialty | IN | 232 | 20,597,819.02 | 88,783.70 | 0.30 |
| Chaudhari Private (69) | Private | IN | 186 | 20,044,803.82 | 107,767.76 | 0.29 |
| Char Specialty (372) | Specialty | IN | 180 | 19,687,759.97 | 109,376.44 | 0.29 |
| Jha Specialty (451) | Specialty | IN | 204 | 19,518,117.05 | 95,677.04 | 0.28 |
| Lata Government (378) | Government | IN | 173 | 19,458,826.26 | 112,478.76 | 0.28 |
| Chahal Private (10) | Private | IN | 208 | 19,302,409.08 | 92,800.04 | 0.28 |
| Bal Multi-Specialty (195) | Multi-Specialty | IN | 186 | 19,161,315.96 | 103,017.83 | 0.28 |

## V2 — Top 15 hospitals (full metrics incl. median, approved, settled, ratios)
| Hospital (id) | Claims | Total Claimed ₹ | Avg ₹ | Median ₹ | Approved ₹ | Settled ₹ | Appr% | Settle% | %Total |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| Madan Private (362) | 214 | 23,220,662.41 | 108,507.77 | 14,909.91 | 17,133,388.83 | 8,043,194.07 | 73.8 | 46.9 | 0.337 |
| Sami Government (74) | 207 | 22,164,803.68 | 107,076.35 | 19,054.65 | 17,301,167.70 | 8,607,314.83 | 78.1 | 49.7 | 0.322 |
| Venkataraman Private (395) | 217 | 21,551,607.96 | 99,316.17 | 16,128.36 | 16,261,443.32 | 8,803,777.49 | 75.5 | 54.1 | 0.313 |
| Kaul Specialty (391) | 232 | 20,597,819.02 | 88,783.70 | 12,973.86 | 16,957,877.09 | 9,065,550.24 | 82.3 | 53.5 | 0.299 |
| Chaudhari Private (69) | 186 | 20,044,803.82 | 107,767.76 | 26,684.85 | 16,704,631.45 | 8,061,072.76 | 83.3 | 48.3 | 0.291 |
| Char Specialty (372) | 180 | 19,687,759.97 | 109,376.44 | 15,937.31 | 13,247,056.00 | 8,285,554.05 | 67.3 | 62.5 | 0.286 |
| Jha Specialty (451) | 204 | 19,518,117.05 | 95,677.04 | 17,558.45 | 15,976,076.11 | 9,250,074.38 | 81.9 | 57.9 | 0.283 |
| Lata Government (378) | 173 | 19,458,826.26 | 112,478.76 | 19,069.67 | 14,520,653.66 | 9,284,258.85 | 74.6 | 63.9 | 0.282 |
| Chahal Private (10) | 208 | 19,302,409.08 | 92,800.04 | 15,157.08 | 15,295,497.50 | 8,569,346.10 | 79.2 | 56.0 | 0.280 |
| Bal Multi-Specialty (195) | 186 | 19,161,315.96 | 103,017.83 | 15,658.15 | 14,587,258.57 | 8,674,570.20 | 76.1 | 59.5 | 0.278 |
| Kata Multi-Specialty (358) | 206 | 19,025,637.72 | 92,357.46 | 16,006.13 | 14,694,606.45 | 7,710,230.10 | 77.2 | 52.5 | 0.276 |
| Narasimhan Government (496) | 193 | 18,813,426.51 | 97,478.89 | 16,809.39 | 14,666,616.11 | 7,791,235.70 | 78.0 | 53.1 | 0.273 |
| Varghese Private (194) | 210 | 18,756,819.64 | 89,318.19 | 13,636.68 | 13,760,871.70 | 8,153,861.00 | 73.4 | 59.3 | 0.272 |
| Mohan Multi-Specialty (125) | 215 | 18,738,733.68 | 87,156.90 | 17,470.75 | 13,774,914.92 | 8,420,635.32 | 73.5 | 61.1 | 0.272 |
| Dixit Private (31) | 199 | 18,599,447.19 | 93,464.56 | 17,880.78 | 11,858,639.64 | 8,319,606.71 | 63.8 | 70.2 | 0.270 |

*Note the large avg-vs-median gap (e.g. 362: avg ₹108,508 vs median ₹14,910) — hospital averages are pulled up by a few very large claims (right-skew).*

## V2.2 — Dispersion across 500 hospitals
```
total_claimed: min 8,748,757 · max 23,220,662 · avg 13,779,402 · sd 2,314,147 · max/avg = 1.69x
avg_claim:     min 45,167 · max 112,479 · mean 68,898
```

## V2.3 — Outlier hospitals (avg_claim > mean + 2·stddev)
```
hospitals_above_mean_plus_2sd = 15   (threshold avg_claim > 90,128 ; mean 68,898)
```

## V2.4 — Network comparison (IN vs OUT)
```
IN_NETWORK     406 hospitals  81,174 claims  ₹5,616,020,891.37  avg 69,184.97  appr 76.0%  settle 54.1%  81.5% of spend
OUT_OF_NETWORK  94 hospitals  18,826 claims  ₹1,273,679,998.20  avg 67,655.37  appr 75.3%  settle 54.9%  18.5% of spend
```

## V2.5 — Hospital type comparison
```
Private          218 hosp  43,724 claims  ₹3,015,388,842.88  avg 68,964.16  appr 75.8%  43.8%
Multi-Specialty  103 hosp  20,595 claims  ₹1,439,966,718.99  avg 69,918.27  appr 75.6%  20.9%
Government       107 hosp  21,181 claims  ₹1,429,240,312.27  avg 67,477.47  appr 75.9%  20.7%
Specialty         72 hosp  14,500 claims  ₹1,005,105,015.43  avg 69,317.59  appr 76.2%  14.6%
```

## V2.6 — Top hospital (362) diagnosis mix
```
Heart Disease            18 claims  ₹7,597,447.15  avg 422,080.40
Coronary Artery Disease   5 claims  ₹2,755,321.71  avg 551,064.34
C-Section                 5 claims  ₹1,449,586.01  avg 289,917.20
Pregnancy Complication    6 claims  ₹1,401,876.24  avg 233,646.04
Cancer                    4 claims  ₹1,139,604.44  avg 284,901.11
Road Accident Injury      3 claims  ₹  855,162.73  avg 285,054.24
```

## V2.7 — Case-mix test (high-avg outliers vs rest)
```
high_avg_outlier  2,941 claims  cardio_claim_share 10.3%  cardio_spend_share 42.1%  avg_claim 100,034.84
rest             97,059 claims  cardio_claim_share  9.7%  cardio_spend_share 40.4%  avg_claim  67,953.50
```
→ Outlier hospitals' cardiovascular share is only marginally higher (42.1% vs 40.4%): case mix explains **little** of the gap; the rest is right-skew (a few very large claims).
