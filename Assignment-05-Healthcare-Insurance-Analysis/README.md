# Healthcare Insurance Claims Cost & Risk Analysis

A read-only analytical project answering the management question:

> **"Where is the insurance company's claim money going, what is driving the cost and risk, and where are the opportunities to improve cost management, profitability and sustainable revenue growth?"**

## Environment

| Item | Value |
|---|---|
| Database | PostgreSQL 17.9 (Windows host) |
| Database name | `healthcare_insurance` |
| Schema | `healthcare` |
| Access | **Read-only** (`default_transaction_read_only=on`) — no DDL/DML performed |
| Connection from WSL | `psql -h 172.18.0.1 -p 5432 -U postgres -d healthcare_insurance` |
| Central fact table | `healthcare.claims` (100,000 rows) |

> ⚠️ **Hard rule for this project:** the database is already populated and validated. No object or row is ever created, altered, dropped, truncated, inserted, updated, or deleted. All figures come from actual query output; nothing is invented or estimated.

## Repository structure

```
healthcare_insurance_analysis/
├── README.md                     ← this file
├── PROJECT_PLAN.md               ← roadmap of prioritized experiments
├── MASTER_DATA_DICTIONARY.md     ← full schema: tables, columns, keys, indexes, ranges
├── EXPERIMENT_INDEX.md           ← status tracker for all experiments
├── docs/                         ← domain context, methodology, final-deliverable drafts
├── experiments/                  ← one Markdown file per experiment (EXP01_*.md ...)
├── validation/                   ← independent validation reports (EXP01_validation.md ...)
├── sql/                          ← raw .sql files (EXP01_v1.sql, EXP01_v2.sql, EXP01_validation.sql ...)
├── results/                      ← captured actual DB results per experiment
└── screenshots/                  ← screenshot checklists + manually captured PNGs
```

## Documentation standard

Every experiment document separates these 14 sections: Business Question · Business Objective · Analytical Objective · Prompt Used · SQL Generated · Actual Database Result · Validation · Key Insight · Business Impact · Cost Optimization Opportunity · Revenue/Profitability Opportunity · Management Recommendation · Limitations · Next Analysis.

## Financial-metric discipline

`claim_amount` (billed) ≠ `approved_amount` (accepted liability) ≠ `paid_amount` (cash). Within `paid_amount`, `payment_status='PAID'` (settled) is distinguished from `PROCESSING` (in-flight). These are never treated as interchangeable. See [MASTER_DATA_DICTIONARY.md](MASTER_DATA_DICTIONARY.md).

## Status

| Experiment | Title | Status |
|---|---|---|
| EXP01 | Disease-wise Claim Cost Analysis | ✅ Complete — V1, V2, independent validation (8/8 PASS) |
| EXP02+ | See PROJECT_PLAN.md | ⏳ Not started (await approval) |

See [EXPERIMENT_INDEX.md](EXPERIMENT_INDEX.md) for the live tracker.
