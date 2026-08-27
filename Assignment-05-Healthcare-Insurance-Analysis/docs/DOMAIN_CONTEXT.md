# Healthcare Insurance Domain Context

Supporting context for interpreting the analysis. This is background/methodology, not derived from the data unless a figure is cited.

## The money flow (why three amounts exist)
A claim moves through stages, each with its own monetary field:

1. **Billed / Claimed** (`claims.claim_amount`) — what the hospital/provider or member submits.
2. **Approved liability** (`claims.approved_amount`) — what the insurer accepts as its obligation after adjudication (deductibles, coverage limits, non-covered items, partial approvals). Zero for REJECTED/PENDING.
3. **Paid / Settled cash** (`claim_payments.paid_amount`) — money actually disbursed. Split by `payment_status`: **PAID** = settled, **PROCESSING** = authorized but in-flight.

**These are not interchangeable.** Cost analysis uses claimed; liability/reserving uses approved; cash-flow/settlement uses paid (PAID only for "settled").

## Key ratios used
- **Approval ratio** = approved ÷ claimed (portfolio ≈ 75.8%). The complement (~24%) is the "approval haircut."
- **Settlement ratio** = settled (PAID) ÷ approved (portfolio ≈ 54.3%). The remainder is mostly PROCESSING (timing), not disallowed.
- **Loss ratio** (future experiments) = claim cost ÷ premium earned — the core profitability metric; requires `policies.annual_premium`.

## Cost decomposition
Total cost ≈ **frequency × severity**. Frequency = claim count; severity = average cost per claim. A driver is:
- **Volume-driven** — many claims, moderate unit cost.
- **Severity-driven** — few claims, high unit cost.
- **Both** — high on both axes (the most dangerous concentration; e.g. Heart Disease).

## Cost-saving vs profitability vs revenue growth (kept distinct)
- **Cost saving** — reduce claim outflow (care management, case rates, network steering).
- **Profitability improvement** — improve margin at similar volume (loss-ratio improvement, risk-adjusted pricing).
- **Revenue growth** — grow premium income (new profitable segments, products, retention).
A cost saving is never labeled revenue growth.

## Recommendation discipline
Pricing, underwriting, reinsurance, provider, and product recommendations are made only where the available tables support them; otherwise the required follow-up analysis is named as a prerequisite (see each experiment's §14).
