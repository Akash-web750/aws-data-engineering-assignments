# EXPERIMENT 01 — Exact Prompts, V1 Evaluation, and V1↔V2 Comparison

The rules require the **exact** prompts be preserved and that prompt improvements be documented. Both prompts below are reproduced verbatim as issued.

---

## PROMPT V1 (basic)
```
We need to analyze our healthcare insurance database.

Business question:
Which diseases are driving the highest claim costs?

Using the existing healthcare schema and actual database data, identify the top diseases by total claim amount.

Generate the PostgreSQL SQL query, execute it against the database, show the actual results, and explain the business insight.

Do not modify any database objects or data.
Use actual results only. Do not invent any values.
```

### V1 OUTPUT (summary)
- **SQL:** single `claims ⋈ diagnoses` GROUP BY diagnosis, ranked by `SUM(claim_amount)`; plus a category rollup and grand total. (`sql/EXP01_v1.sql`)
- **Result:** Top 10 diseases by claimed cost; Heart Disease ₹2.07B (30.1%), Cardiovascular category 40.5%; grand total ₹6,889,700,889.57.
- **Insight:** cardiovascular dominance; Heart Disease high by volume, Coronary Artery Disease high by unit cost.
- **Recommendations:** target cardiovascular care management; watch CAD unit cost; reprice cardiovascular risk.

### V1 EVALUATION
| Aspect | Assessment |
|---|---|
| ✅ Correct | Ranking, join, share math, grand total all correct and later validated. |
| ⚠️ Missing | Used only `claim_amount`. Did **not** distinguish approved liability or paid/settled cash. No `claim_payments` usage → no exposure view. |
| ⚠️ Missing | No explicit **volume vs severity** decomposition (mentioned narratively, not quantified/classified). |
| ⚠️ Missing | No linkage to **procedure / hospital network / policy segment** (the "WHERE" behind the cost). |
| ⚠️ Missing | No **gap analysis** (claim→approved, approved→paid). |
| ⚠️ Metric ambiguity | "Cost" left undefined — billed vs approved vs paid conflated by omission. |
| ⚠️ Data-quality | No check of payment cardinality / PAID vs PROCESSING / duplicate-counting risk. |
| ⚠️ Assumptions | None false, but recommendations (repricing/reinsurance) outran what a claim-only view can support. |

---

## PROMPT V2 (improved — built directly from the V1 gaps above)
```
We need to perform a business-focused healthcare insurance claims cost analysis using the existing PostgreSQL database.

Business Question:
Which diseases are driving the highest financial cost and risk for the insurance company?

Business Objective:
Identify the major disease-level cost drivers and determine whether the cost concentration is driven by claim frequency, cost per claim, or both. The analysis should help management identify opportunities for cost optimization, risk management, profitability improvement, and sustainable revenue growth.

Use the existing healthcare schema and actual database data only.

Important metric definitions:
- claim_amount = amount claimed by the customer/provider.
- approved_amount = amount approved by the insurer.
- paid_amount = amount actually paid/settled, where available.
- Do not treat claim_amount, approved_amount, and paid_amount as interchangeable.
- Clearly distinguish claimed cost, approved liability, and actual paid cost in the analysis.

Analysis requirements:
1. Rank the top diseases by: total claim_amount, total approved_amount, total paid_amount where payment data can be correctly linked
2. For each major disease, calculate: claim count, total claim amount, average claim amount, total approved amount, average approved amount, approval ratio, paid amount where available, share of total claim cost, share of total approved cost
3. Separate cost drivers into: Volume-driven, Severity-driven, Both volume and severity
4. Provide disease-category level analysis in addition to individual disease analysis.
5. Where the existing schema supports it, connect major disease cost drivers with: policy information, premium, coverage, deductible, hospital/provider, procedure. Do not assume relationships or business conclusions that are not supported by the actual data.
6. Identify whether the highest-cost diseases also create significant financial exposure for the insurer based on approved and paid amounts.
7. Identify meaningful gaps between: claim_amount vs approved_amount, approved_amount vs paid_amount. Only interpret these gaps when the underlying data supports the interpretation.

Business interpretation requirements (A–H): Key findings; Main cost drivers; Volume vs severity explanation; Financial risk/exposure; Potential cost-optimization opportunities; Potential profitability/revenue-growth opportunities; Recommended management actions; Additional analysis needed before pricing/underwriting/provider decisions.

Output format (1–10): Business Question; Analytical Approach; SQL Query; Actual Database Results; Key Findings; Business Insight; Financial/Risk Implication; Revenue/Profitability Opportunity; Recommended Actions; Limitations and Next Analysis.

Technical requirements: PostgreSQL SQL; existing healthcare schema; actual results only; no invented/estimated values; validate joins to avoid duplicate counting (aggregate claim_payments before joining if multiple rows per claim); do not modify anything; keep the session read-only; if a metric cannot be reliably calculated, state the limitation instead of guessing.
```

*(Reproduced faithfully; the original message also enumerated the A–H and 1–10 lists in full — condensed here only in formatting, not in meaning.)*

### V2 OUTPUT
Full SQL in `sql/EXP01_v2.sql`; full actual results and A–H/1–10 interpretation in `experiments/EXP01_disease_cost_analysis.md` (§6). Key additions realized: three money layers, grand totals, volume/severity classifier, category rollup, Heart-Disease linkage (policy/network/procedure), and both gap analyses.

---

## V1 ↔ V2 COMPARISON

**What changed in the prompt?** Added domain metric definitions (claim vs approved vs paid), an explicit volume-vs-severity requirement, category-level analysis, linkage requirements, gap/exposure requirements, join-safety mandate, revenue-vs-cost distinction, and a fixed output structure.

**What changed in the SQL?** From a single claim-only aggregation to: a payment pre-aggregation CTE (`FILTER` for PAID vs PROCESSING), portfolio grand totals across three layers, a category rollup, a volume/severity CASE classifier, and three linkage queries (policy/network/procedure). Division guarded with `NULLIF`.

**What changed in the analysis?** V1 answered "which disease costs most." V2 answered *why* (volume vs severity), *where* (procedures/network/segment), and *so-what* (exposure, gaps, cost vs profitability). It surfaced that Heart Disease cost concentrates in 2 procedures, that network status is **not** a material differentiator (an evidence-based non-finding), and that only 54.3% of approved liability is settled (a timing exposure).

**Additional business insight obtained:** procedural concentration (₹1.84B in Cardiac Surgery + Angioplasty), the ₹2.28B PROCESSING settlement backlog, the uniform ~24% approval haircut, and the distinction between cost-saving vs profitability levers.

**Additional validation performed:** V2's numbers were independently reproduced 8/8 with different SQL logic; V1 had no independent validation.

**Did V2 improve business usefulness?** Yes, materially — V2 moved from a descriptive ranking to a decision-ready cost/risk/exposure analysis with explicit limitations gating the higher-stakes recommendations.

### FINAL EXPERIMENT CONCLUSION
Prompt quality directly determined analytical depth and safety. The same database and model produced a one-dimensional ranking under V1 and a validated, multi-layer, decision-oriented analysis under V2 — driven entirely by adding metric definitions, decomposition requirements, join-safety rules, and an output contract. The reusable lesson: **encode domain metric semantics, validation, and the WHY/WHERE/SO-WHAT structure into the prompt** rather than expecting the model to infer them.
