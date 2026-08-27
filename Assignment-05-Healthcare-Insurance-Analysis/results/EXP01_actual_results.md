# EXPERIMENT 01 — Captured Actual Database Results

Raw actual output from PostgreSQL 17.9 / `healthcare_insurance` / schema `healthcare`. Read-only. For provenance; the analysis narrative is in `experiments/EXP01_disease_cost_analysis.md`.

## Portfolio totals
```
total_claimed              = 6,889,700,889.57
total_approved             = 5,225,368,586.54   (75.8% of claimed)
total_paid_settled (PAID)  = 2,834,964,771.91   (54.3% of approved)
total_paid_incl_processing = 5,112,332,456.18   (97.8% of approved)
```

## Claim status distribution
```
APPROVED            70,084   claimed 4,843,714,434.23   approved 4,552,116,648.83
PARTIALLY_APPROVED  14,914   claimed 1,015,328,861.87   approved   673,251,937.71
REJECTED            10,083   claimed   691,298,150.49   approved           0.00
PENDING              4,919   claimed   339,359,442.98   approved           0.00
```

## Payment status distribution (claim_payments, 83,328 rows, 1 per claim)
```
PAID        47,090 rows   sum_paid 2,834,964,771.91
PROCESSING  36,238 rows   sum_paid 2,277,367,684.27
```

## Top 15 diseases by total claimed — see experiments/EXP01_disease_cost_analysis.md §6 (V2 table)

## Category rollup — see experiments/EXP01_disease_cost_analysis.md §6

## Heart Disease linkage
```
Procedures:
  Cardiac Surgery  1,905  claimed 1,081,651,850.39  avg 567,796  base_cost 350,000
  Angioplasty      1,930  claimed   763,253,747.39  avg 395,468  base_cost 220,000
  Echocardiogram   1,785  claimed   215,152,064.98  avg 120,533  base_cost   4,500
  ECG              1,877  claimed    12,769,512.81  avg   6,803  base_cost   1,800
  (Cardiac Surgery + Angioplasty combined = 1,844,905,597.78)

Network:
  IN_NETWORK      6,019  claimed 1,668,214,600.22  avg 277,158  appr 76.1%
  OUT_OF_NETWORK  1,478  claimed   404,612,575.35  avg 273,757  appr 74.6%

Policy type:
  Individual      2,641  claimed 718,276,872.24  avg_premium 48,746  avg_coverage 1,224,044  avg_deductible 9,771
  Family          2,292  claimed 627,731,634.57  avg_premium 59,239  avg_coverage 1,287,260  avg_deductible 9,459
  Corporate       1,472  claimed 413,706,161.60  avg_premium 48,330  avg_coverage 1,208,628  avg_deductible 8,855
  Senior Citizen  1,092  claimed 313,112,507.16  avg_premium 65,326  avg_coverage 1,227,106  avg_deductible 10,334
```
