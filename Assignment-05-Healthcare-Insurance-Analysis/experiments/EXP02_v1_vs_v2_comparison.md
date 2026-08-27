# EXPERIMENT 02 — V1 vs V2 Comparison

*Hospital / Provider Cost Analysis. Built only from documented EXP02 results. No invented values.*

## Side-by-side

| # | Dimension | **Prompt V1 (basic)** | **Prompt V2 (improved)** |
|--:|---|---|---|
| 1 | Prompt | "Which hospitals drive the highest claim costs?" → top hospitals by total. | Adds metric definitions, payment safety, median, network/type comparison, case-mix test, outlier detection, ratios, WHY-interpretation. |
| 2 | Scope | Ranking by `SUM(claim_amount)` + count/avg/share. | Volume-vs-unit-cost, dispersion, statistical outliers, network, type, case mix, approval/settlement ratios. |
| 3 | Metrics | `claim_amount` only. | claimed / approved / paid (PAID vs PROCESSING) + median + ratios. |
| 4 | Central measure | Mean only. | Mean **and median** — exposes right-skew (median ₹13k–27k vs mean ₹88k–112k). |
| 5 | Conclusion reached | Implies a "top hospital cost problem". | Shows cost is **diffuse** (top 0.34%, max 1.69× avg) — no single-provider problem. |
| 6 | Network | Not tested. | IN vs OUT ≈ equal (₹69,185 vs ₹67,655) → out-of-network **not** more expensive. |
| 7 | Case mix | Not tested. | Outlier hospitals only marginally more cardiac (42.1% vs 40.4%) → mix explains little. |
| 8 | Validation | None. | 9/9 independent PASS (Δ=0.00). |

## What changed in the analysis
V1 answers "*which* hospitals rank highest." V2 answers the real management question — "*are any hospitals materially more expensive, and why*" — and the honest, data-driven answer is **no**: cost tracks volume, per-claim cost is uniform across networks and types, and top rankings are driven by a few large high-severity claims. This is the opposite of a naive read of the V1 ranking.

## Additional business value from V2
- Prevented a **false conclusion** ("renegotiate the top hospital") that the V1 ranking would suggest but the data does not support.
- Produced an evidence-based **non-finding** on network status (no cost lever there).
- Redirected the cost lever to disease/procedure level (EXP01) and the high-cost-claim tail.

## Additional validation performed
V2's figures independently reproduced 9/9 with different SQL logic; V1 had none.

## Final conclusion
Same database + same question + a better prompt turned a misleading "top-hospital" ranking into a correct, validated conclusion that **hospital cost is not concentrated** — and pointed management away from a low-value action toward higher-value ones. The reusable lesson from EXP01 holds: encoding metric definitions, decomposition, and a WHY/skew/validation requirement into the prompt changes the *conclusion*, not just the presentation.
