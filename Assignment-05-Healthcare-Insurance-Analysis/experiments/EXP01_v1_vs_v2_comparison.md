# EXPERIMENT 01 — V1 vs V2 Final Comparison

*Disease-wise Claim Cost & Risk Analysis. Built only from documented EXP01 results (`EXP01_disease_cost_analysis.md`, `EXP01_prompts.md`, `EXP01_validation.md`). No new analysis; no invented values.*

## Side-by-side

| # | Dimension | **Prompt V1 (basic)** | **Prompt V2 (improved)** |
|--:|---|---|---|
| 1 | **Prompt** | "Which diseases drive the highest claim costs? … top diseases by total claim amount." One metric, no structure. | Adds metric definitions, volume-vs-severity, category level, policy/provider/procedure linkage, gap/exposure analysis, join-safety, and a fixed A–H / 1–10 output contract. |
| 2 | **Analytical scope** | Single ranking: top diseases by `claim_amount`, + category rollup + grand total. Answers *"which costs most."* | Multi-layer: rank by claimed/approved/settled, category rollup, volume/severity classifier, Heart-Disease linkage. Answers *why / where / so-what.* |
| 3 | **Metrics used** | `claim_amount` only (claim count, sum, avg, share). | Three distinct layers — `claim_amount` (billed), `approved_amount` (liability), `paid_amount` split **PAID vs PROCESSING** — plus approval ratio, settlement ratio, both gaps. |
| 4 | **Business context** | Cost ranking; recommendations somewhat ahead of the evidence. | Cost vs risk vs exposure; explicitly separates cost-saving / profitability / revenue growth; links to premium, coverage, deductible, network, procedure. |
| 5 | **Validation approach** | None (results correct but unverified at the time). | Independent reproduction with different SQL logic (ROLLUP, scalar/IN/EXISTS, standalone-vs-join, fan-out) → **8/8 PASS**, Δ = 0.00. |
| 6 | **Business insights** | Cardiovascular dominant; Heart Disease 30.1%, category 40.5%; CAD highest unit cost. | Same, **plus**: Heart Disease is the only *both volume+severity* driver; ₹1.84B concentrated in Cardiac Surgery + Angioplasty; only 54.3% of approved liability settled (₹2.28B PROCESSING backlog); network status **not** a material differentiator; uniform ~24% approval haircut. |
| 7 | **Recommendations** | Target cardiovascular; watch CAD unit cost; reprice cardiovascular risk. | Cardiovascular care-management first; **bundled case rates for Cardiac Surgery + Angioplasty**; address settlement backlog; reinsure the 40% concentration; decompose the approval haircut — each tied to evidence, higher-stakes actions gated on §14 follow-ups. |

## Key documented figures (identical & validated across both)
- Grand total claimed **₹6,889,700,889.57** · approved **₹5,225,368,586.54** (75.8%) · settled/PAID **₹2,834,964,771.91** (54.3% of approved).
- Cardiovascular **40.5%** of claimed; Heart Disease **30.1%** (7,497 claims, avg ₹276,488).
- Cardiac Surgery ₹1,081,651,850.39 + Angioplasty ₹763,253,747.39 = **₹1,844,905,597.78**.

## 8. What V2 improved compared with V1
- **Metric integrity:** separated billed vs liability vs cash (V1 conflated "cost").
- **Explanatory depth:** added the *why* (volume vs severity) and *where* (procedure/network/segment).
- **Risk & exposure:** surfaced the settlement backlog and concentration risk V1 could not see.
- **Trustworthiness:** added independent 8/8 validation and join-safety (no duplicate counting).
- **Decision-readiness:** structured output + explicit limitations gating pricing/underwriting actions.

## 9. Final learning
Prompt quality — not the database or the model — determined analytical depth and safety. Encoding **metric semantics, decomposition requirements, join-safety, validation, and a WHY/WHERE/SO-WHAT output contract** into V2 turned a one-dimensional ranking into a validated, decision-ready cost/risk analysis. The reusable principle: specify domain meaning and verification in the prompt rather than expecting the model to infer them.

---

## EXPERIMENT 01 — V1 vs V2 FINAL COMPARISON

**Conclusion — why V2 was more business-useful than V1:**
1. **Correct financial meaning:** V2 distinguished claimed vs approved vs paid (PAID vs PROCESSING); V1's single "cost" number risked confusing billed amounts with actual liability/cash.
2. **Cause, not just rank:** V2 classified Heart Disease as the only *both volume+severity* driver and pinpointed ₹1.84B in two procedures — actionable; V1 only ranked.
3. **Risk visibility:** V2 exposed that just 54.3% of approved liability is settled (₹2.28B in processing) and flagged 40% single-category concentration — invisible in V1.
4. **Verified numbers:** V2's figures were independently validated 8/8 (Δ = 0.00); V1 had no validation.
5. **Safer recommendations:** V2 tied actions to evidence, separated cost-saving from profitability/revenue, and gated higher-stakes moves on named follow-up analyses.
