![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-blue)
![SQL](https://img.shields.io/badge/SQL-Analytics-informational)
![AI Assisted](https://img.shields.io/badge/AI-Prompt%20Engineering-purple)
![Validation](https://img.shields.io/badge/Validation-8%2F8%20PASS-brightgreen)
![Access](https://img.shields.io/badge/Database-Read--Only-lightgrey)

# Healthcare Insurance Claims Cost & Risk Analysis

> **Assignment 05** — A read-only analytical project that finds *where an insurer's claim money goes and what drives the cost*, using PostgreSQL SQL plus an AI prompt-engineering experiment (basic prompt vs improved prompt), with every headline number independently re-verified.

---

## 1. Executive Summary

- **Problem analyzed:** Where is the insurance company's claim money going, and what is driving cost and risk?
- **Data used:** A populated PostgreSQL 17 database (`healthcare_insurance`, schema `healthcare`) — **100,000 claims** across patients, policies, hospitals, diagnoses, procedures, and payments.
- **What we discovered:** Cost is heavily concentrated. **Cardiovascular disease = 40.5% of all claimed cost**, and **Heart Disease alone = 30.1%** — one diagnosis out of 50 driving nearly a third of the money. Heart Disease is expensive on *both* axes (many claims **and** high cost per claim); within it, just **two procedures (Cardiac Surgery + Angioplasty) account for ₹1.84B**.
- **Why it matters:** A 40%-in-one-category concentration is both the biggest **cost-optimization target** and a **portfolio risk** the business must actively manage (pricing, reinsurance, care management).

> 💡 The analysis carefully separates **claimed** (₹6.89B) vs **approved liability** (₹5.23B) vs **actually settled cash** (₹2.83B) — these are *not* the same money, and confusing them would mislead every downstream decision.

---

## 2. Business Problem

**Management question:**
> *"Where is the insurance company's claim money going and what is driving the cost?"*

An insurer's profitability depends on understanding which conditions, providers, and procedures consume claim payouts — and whether that spend is driven by **how often** claims occur or **how expensive** each one is.

---

## 3. Business Objectives

| Objective | What it means here |
|---|---|
| **Claim cost optimization** | Find the largest, most concentrated cost pools to target first. |
| **Risk identification** | Detect dangerous concentration (single-category exposure). |
| **Profitability improvement** | Separate cost control from margin (loss-ratio) improvement. |
| **Revenue / pricing opportunity** | Identify where risk-adjusted premium pricing could improve margin. |
| **Provider / network optimization** | Test whether network status or specific providers drive cost. |
| **Preventive / care-management** | Point to conditions where prevention yields the biggest payoff. |

---

## 4. Database Overview

| Property | Value |
|---|---|
| Engine | **PostgreSQL 17.9** |
| Database | `healthcare_insurance` |
| Schema | `healthcare` |
| Central fact table | **`claims`** (100,000 rows) |
| Access mode | **Read-only** — no data or objects modified |

**Tables & exact row counts (documented):**

| Table | Rows | Role |
|---|--:|---|
| `claims` | 100,000 | central fact |
| `claim_payments` | 83,328 | payment fact (1 row per paid claim) |
| `policies` | 25,000 | dimension |
| `patients` | 20,000 | dimension |
| `hospitals` | 500 | dimension |
| `procedures` | 100 | dimension |
| `diagnoses` | 50 | dimension |

*No passwords or credentials are stored in this repository. See [§12](#12-validation--data-quality) and the `.gitignore`.*
Full details: [`MASTER_DATA_DICTIONARY.md`](MASTER_DATA_DICTIONARY.md).

---

## 5. Data Model (Star Schema)

`claims` sits at the centre; each claim links to one patient, policy, hospital, diagnosis, and procedure, and (if paid) to exactly one payment row.

```text
        patients        policies        hospitals
            \               |               /
             \              |              /
              \             |             /
   diagnoses ── ── ──►  [ CLAIMS ]  ◄── ── ── procedures
                            │  (central fact, 100,000)
                            ▼
                     claim_payments   (1 : 1 — enforced by a UNIQUE index)
```

The **1:1** guarantee between `claims` and `claim_payments` (a UNIQUE index on `claim_id`) is what makes payment totals safe to sum without double-counting — verified in validation.

---

## 6. Analytical Methodology

1. **SQL analysis** on the live database (read-only) using PostgreSQL.
2. **AI-assisted prompt engineering** — the same question asked two ways:
   - **V1 (baseline prompt):** "which diseases cost the most?" → a single ranking.
   - **V2 (improved prompt):** adds metric definitions, volume-vs-severity, provider/procedure/policy linkage, gap analysis, and join-safety rules.
3. **Independent validation** — every headline number re-computed with *different* SQL logic (ROLLUP, scalar/`IN`/`EXISTS` subqueries, standalone-vs-join). **8/8 checks passed.**

---

## 7. Experiment Index

| Experiment | Business Question | Status | Key Finding | Business Value |
|---|---|---|---|---|
| **EXP01 — Disease-wise Claim Cost & Risk** | Which diseases drive the highest cost & risk; volume or severity? | ✅ Complete · 8/8 validated | Cardiovascular = 40.5% of spend; Heart Disease = 30.1% (both volume + severity); ₹1.84B in 2 procedures | Pinpoints the highest-ROI cost + concentration-risk target |
| EXP02–EXP16 | Hospital, procedure, approval, settlement, profitability, loss-ratio, … | ⏳ Planned | — | See [`PROJECT_PLAN.md`](PROJECT_PLAN.md) |

---

## 8. Experiment 01 — Disease-wise Claim Cost & Risk Analysis

**Business Question:** Which diseases drive the highest financial cost and risk — and is it frequency, cost-per-claim, or both?
**Business Objective:** Identify disease-level cost drivers to target cost optimization, risk management, and profitability.

### 🔹 Prompt V1 (basic)
> 📸 [`01_Prompt_V1/EXP01_Prompt_V1_01.png`](screenshots/EXP01_Disease_Cost/01_Prompt_V1/EXP01_Prompt_V1_01.png) · verbatim in [`experiments/EXP01_prompts.md`](experiments/EXP01_prompts.md)

**V1 Result:** Top-10 diseases by claim amount; Heart Disease ₹2.07B (30.1%), Cardiovascular 40.5%; grand total ₹6,889,700,889.57.
> 📸 [`02_Output_V1/`](screenshots/EXP01_Disease_Cost/02_Output_V1) — query, top diseases, category rollup, grand total.

**V1 Limitation:** used only `claim_amount` (billed) — no approved liability, no paid/settled cash, no volume-vs-severity split, no procedure/network/policy linkage, no validation.

### 🔹 Prompt V2 (improved)
> 📸 [`03_Prompt_V2/EXP01_Prompt_V2_01.png`](screenshots/EXP01_Disease_Cost/03_Prompt_V2/EXP01_Prompt_V2_01.png) · verbatim in [`experiments/EXP01_prompts.md`](experiments/EXP01_prompts.md)

**V2 Result (all validated):**

| Money layer | Amount | Note |
|---|--:|---|
| Claimed | ₹6,889,700,889.57 | billed |
| Approved liability | ₹5,225,368,586.54 | 75.8% of claimed |
| Settled (PAID) | ₹2,834,964,771.91 | 54.3% of approved |

Heart Disease: 7,497 claims · claimed ₹2,072,827,175.57 · approved ₹1,571,375,818.98 · settled ₹854,252,471.66 · **30.1%** of claimed. Cardiovascular category **40.5%**. Cardiac Surgery + Angioplasty = **₹1,844,905,597.78**.
> 📸 [`04_Output_V2/`](screenshots/EXP01_Disease_Cost/04_Output_V2) — payment check, top-15, grand totals, category, volume/severity, and Heart-Disease linkage (policy / network / procedure).

### 🔹 Independent Validation — 8/8 PASS
Every figure reproduced with different SQL logic; `claim_payments` confirmed 1:1 (no duplicate counting).
> 📸 [`05_Validation/`](screenshots/EXP01_Disease_Cost/05_Validation) · report: [`validation/EXP01_validation.md`](validation/EXP01_validation.md)

### 🔹 V1 vs V2 Comparison
Written comparison: [`experiments/EXP01_v1_vs_v2_comparison.md`](experiments/EXP01_v1_vs_v2_comparison.md). *(No comparison screenshot in the source set — noted in [`06_Comparison`](screenshots/EXP01_Disease_Cost/06_Comparison).)*

### 🔹 Final Business Insight
Cost is concentrated in cardiovascular disease; Heart Disease is the only **both-volume-and-severity** driver, and its cost lives in two high-severity procedures.

### 🔹 Recommendations (evidence-backed)
1. Stand up a **cardiovascular care-management** program first (highest ROI).
2. Negotiate **bundled case rates** for Cardiac Surgery & Angioplasty (₹1.84B).
3. Address the **₹2.28B still in "PROCESSING"** settlement backlog (cash-flow).
4. **Reinsure / diversify** the 40% cardiovascular concentration.

Full write-up: [`experiments/EXP01_disease_cost_analysis.md`](experiments/EXP01_disease_cost_analysis.md).

---

## 9. Key Business Findings

- **Cardiovascular = 40.5%** of all claimed cost (₹2.79B of ₹6.89B).
- **Heart Disease alone = 30.1%** (₹2.07B) — the single biggest driver, on both frequency and severity.
- **Coronary Artery Disease** has the **highest cost per claim** (₹370,534).
- **Two procedures** (Cardiac Surgery + Angioplasty) drive **₹1.84B** of Heart Disease cost.
- Approval ratio is **uniform (~76%)** across diseases; only **54.3%** of approved liability is settled — **₹2.28B is still "PROCESSING"** (a timing exposure, not a loss).
- Hospital **network status is *not* a material cost differentiator** for Heart Disease (evidence-based non-finding).

*All numbers are actual, validated query output.*

---

## 10. Business Impact

| Lever (kept distinct) | Opportunity from the data |
|---|---|
| **Cost reduction** | Cardiovascular care management; bundled case rates for the 2 top cardiac procedures. |
| **Risk management** | Reduce/reinsure the 40% single-category concentration; monitor the ₹2.28B settlement backlog. |
| **Profitability** | Improve loss ratio on cardiovascular via prevention & network steering (margin, not just spend). |
| **Pricing** | Explore **risk-adjusted premiums** for cardiac exposure (currently premium tracks policy type/age, not cardiac risk). |
| **Provider / network** | Benchmark cardiac unit costs by hospital; network status alone didn't explain cost — dig to provider level. |

> ⚠️ **Cost savings ≠ revenue growth.** These are labeled separately; no revenue-growth claim is made beyond what the data supports.

---

## 11. Prompt Engineering Learning

The same database and model produced a **one-dimensional ranking** under V1 and a **validated, decision-ready cost/risk analysis** under V2. The difference was entirely in the prompt: V2 encoded **metric definitions** (claimed vs approved vs paid), **decomposition** (volume vs severity), **linkage** (procedure/network/policy), **gap analysis**, and **join-safety + validation** requirements. Lesson: *specify domain meaning and verification in the prompt — don't expect the model to infer them.* Details: [`experiments/EXP01_v1_vs_v2_comparison.md`](experiments/EXP01_v1_vs_v2_comparison.md).

---

## 12. Validation & Data Quality

- **8/8 independent checks PASS** — each headline number re-derived with *different* SQL logic (ROLLUP, scalar/`IN`/`EXISTS`, standalone-vs-join). Report: [`validation/EXP01_validation.md`](validation/EXP01_validation.md).
- **No duplicate counting:** `claim_payments` is **1:1** with `claims` (83,328 rows = 83,328 distinct claims, max 1/claim), enforced by a UNIQUE index.
- **Metric integrity:** claimed / approved / paid (PAID vs PROCESSING) are handled as distinct layers throughout.
- **Security:** no passwords, tokens, or credential files are committed; `.pgpass` lives outside the repo and is `.gitignore`d.

---

## 13. Project Structure

```text
Assignment-05-Healthcare-Insurance-Analysis/
├── README.md                     ← this file (manager overview)
├── PROJECT_PLAN.md               ← 16-experiment analytics roadmap
├── MASTER_DATA_DICTIONARY.md     ← full schema: tables, keys, indexes, ranges
├── EXPERIMENT_INDEX.md           ← experiment status tracker
├── docs/
│   └── DOMAIN_CONTEXT.md         ← insurance domain background & metric rules
├── experiments/
│   ├── EXP01_disease_cost_analysis.md    ← full 14-section analysis
│   ├── EXP01_prompts.md                  ← exact V1 & V2 prompts + evaluation
│   └── EXP01_v1_vs_v2_comparison.md      ← prompt-engineering comparison
├── sql/
│   ├── EXP01_v1.sql · EXP01_v2.sql · EXP01_validation.sql
├── validation/
│   └── EXP01_validation.md               ← 8/8 PASS report
├── results/
│   └── EXP01_actual_results.md           ← captured raw DB output
└── screenshots/
    ├── EXP01_Disease_Cost/               ← organized visual evidence (23 images)
    │   ├── 01_Prompt_V1/ 02_Output_V1/ 03_Prompt_V2/
    │   ├── 04_Output_V2/ 05_Validation/ 06_Comparison/
    │   └── README.md                     ← screenshot→claim index
    └── EXP01_screenshot_checklist.md     ← capture checklist
```

---

## 14. Technologies

**PostgreSQL 17** · **SQL** (window functions, ROLLUP, CTEs, FILTER, `EXISTS`/`IN`) · **pgAdmin 4** · **Git / GitHub** · **AI-assisted analytics (Claude Code)** · **WSL2 (Ubuntu)**.

---

## 15. Future Experiments

Per [`PROJECT_PLAN.md`](PROJECT_PLAN.md) and [`EXPERIMENT_INDEX.md`](EXPERIMENT_INDEX.md): Hospital/provider cost (EXP02) · Procedure cost & base-cost gap (EXP03) · Approval/rejection patterns (EXP04) · Settlement/PAID-vs-PROCESSING aging (EXP05) · Policy profitability & loss ratio (EXP06–07) · Member risk, geography, high-cost tail, trends, fraud indicators (EXP08–14) · Cost & profitability synthesis (EXP15–16).

---

*Read-only analysis. No database objects or data were modified. All figures are actual PostgreSQL output; none are invented or estimated.*
