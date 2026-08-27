# Master Data Dictionary — `healthcare` schema

**Source:** PostgreSQL 17.9, database `healthcare_insurance`, schema `healthcare`.
**Captured:** read-only inspection (`information_schema`, `pg_stat_user_tables`, `pg_indexes`, constraint catalogs).
**Grain summary:** star schema; `claims` is the central fact table; `claim_payments` is a payment fact linked 1:1 to `claims`; the remaining five tables are dimensions.

## Row counts (exact)

| Table | Rows | Role |
|---|--:|---|
| `claims` | 100,000 | central fact |
| `claim_payments` | 83,328 | payment fact (1 row per paid claim) |
| `policies` | 25,000 | dimension |
| `patients` | 20,000 | dimension |
| `hospitals` | 500 | dimension |
| `procedures` | 100 | dimension |
| `diagnoses` | 50 | dimension |

## Relationships (verified foreign keys, 0 orphans)

```
              patients ─┐
              policies ─┤ (policies.patient_id → patients)
claim_payments ─ claims ┼─ hospitals
                        ├─ diagnoses
                        └─ procedures
```

| Child table | FK column | → Parent table | Parent column |
|---|---|---|---|
| `claims` | patient_id | `patients` | patient_id |
| `claims` | policy_id | `policies` | policy_id |
| `claims` | hospital_id | `hospitals` | hospital_id |
| `claims` | diagnosis_id | `diagnoses` | diagnosis_id |
| `claims` | procedure_id | `procedures` | procedure_id |
| `claim_payments` | claim_id | `claims` | claim_id |
| `policies` | patient_id | `patients` | patient_id |

## Table columns, keys, and data types

### `claims` (fact) — PK `claim_id`
| # | Column | Type | Null | Notes |
|--:|---|---|---|---|
| 1 | claim_id | bigint | NO | **PK** |
| 2 | patient_id | integer | NO | FK → patients |
| 3 | policy_id | integer | NO | FK → policies |
| 4 | hospital_id | integer | NO | FK → hospitals |
| 5 | diagnosis_id | varchar(10) | NO | FK → diagnoses (code) |
| 6 | procedure_id | varchar(10) | NO | FK → procedures (code) |
| 7 | admission_date | date | NO | |
| 8 | discharge_date | date | NO | |
| 9 | claim_submission_date | date | NO | |
| 10 | **claim_amount** | numeric(12,2) | NO | 💰 amount **billed/claimed** |
| 11 | **approved_amount** | numeric(12,2) | NO | 💰 amount **approved** (accepted liability); 0 for REJECTED/PENDING |
| 12 | claim_status | varchar(30) | NO | APPROVED / PARTIALLY_APPROVED / REJECTED / PENDING |
| 13 | claim_type | varchar(30) | NO | |
| 14 | rejection_reason | varchar(255) | YES | populated for rejected claims |
| 15 | created_at | timestamp | NO | |

### `claim_payments` (payment fact) — PK `payment_id`
| # | Column | Type | Null | Notes |
|--:|---|---|---|---|
| 1 | payment_id | bigint | NO | **PK** |
| 2 | claim_id | bigint | NO | FK → claims; **UNIQUE** (see below) ⇒ 1 payment per claim |
| 3 | payment_date | date | NO | |
| 4 | **paid_amount** | numeric(12,2) | NO | 💰 cash amount on the payment record |
| 5 | payment_status | varchar(30) | NO | **PAID** = settled · **PROCESSING** = in-flight |
| 6 | payment_method | varchar(30) | NO | BANK_TRANSFER / DIRECT_SETTLEMENT / CHEQUE |

### `policies` (dim) — PK `policy_id`
| # | Column | Type | Notes |
|--:|---|---|---|
| 1 | policy_id | integer | **PK** |
| 2 | patient_id | integer | FK → patients |
| 3 | policy_type | varchar(50) | Individual / Family / Corporate / Senior Citizen |
| 4 | policy_start_date | date | |
| 5 | policy_end_date | date | |
| 6 | **coverage_amount** | numeric(12,2) | 💰 max coverage |
| 7 | **annual_premium** | numeric(12,2) | 💰 premium (revenue input) |
| 8 | **deductible_amount** | numeric(12,2) | 💰 deductible |
| 9 | policy_status | varchar(20) | |

### `patients` (dim) — PK `patient_id`
patient_id (int, PK) · first_name · last_name · date_of_birth (date) · gender · city · state · registration_date (date).

### `hospitals` (dim) — PK `hospital_id`
hospital_id (int, PK) · hospital_name · hospital_type · city · state · **network_status** (IN_NETWORK / OUT_OF_NETWORK) · bed_capacity (int).

### `diagnoses` (dim) — PK `diagnosis_id` (varchar code)
diagnosis_id (varchar(10), PK) · **diagnosis_name** (varchar(150), UNIQUE) · **diagnosis_category** (varchar(100)) · severity_level (varchar(20)).

### `procedures` (dim) — PK `procedure_id` (varchar code)
procedure_id (varchar(10), PK) · **procedure_name** (varchar(150), UNIQUE) · procedure_category (varchar(100)) · **base_cost** (numeric(12,2) — reference cost, *not* actual claimed cost).

## Indexes (relevant to analysis / join safety)

| Table | Index | Definition |
|---|---|---|
| claim_payments | `uq_payment_claim` | **UNIQUE** btree (claim_id) → **structurally guarantees ≤1 payment per claim (no fan-out)** |
| claim_payments | claim_payments_pkey | UNIQUE (payment_id) |
| claim_payments | idx_payments_claim_id / idx_payments_payment_date | btree (claim_id) / (payment_date) |
| claims | claims_pkey | UNIQUE (claim_id) |
| claims | idx_claims_diagnosis_id, _hospital_id, _patient_id, _policy_id, _procedure_id | FK-column btrees |
| claims | idx_claims_status, idx_claims_admission_date | btree (claim_status) / (admission_date) |
| diagnoses | diagnoses_pkey / `diagnoses_diagnosis_name_key` | UNIQUE (diagnosis_id) / **UNIQUE (diagnosis_name)** |
| procedures | procedures_pkey / `procedures_procedure_name_key` | UNIQUE (procedure_id) / **UNIQUE (procedure_name)** |
| policies | policies_pkey / idx_policies_patient_id | UNIQUE (policy_id) / btree (patient_id) |

*The UNIQUE indexes on `diagnosis_name` and `procedure_name` make name-based lookup subqueries (used in validation) guaranteed single-valued.*

## Date ranges (from `claims`)

| Field | Min | Max |
|---|---|---|
| admission_date | 2024-01-09 | 2026-12-31 |
| discharge_date | — | 2026-12-31 |
| claim_submission_date | 2024-01-12 | 2026-12-31 |

Coverage ≈ 3 years (2024–2026) — supports trend/seasonality analysis.

## Key distributions (reference)

- **claim_status:** APPROVED 70,084 · PARTIALLY_APPROVED 14,914 · REJECTED 10,083 · PENDING 4,919.
- **payment_status:** PAID 47,090 (₹2,834,964,771.91) · PROCESSING 36,238 (₹2,277,367,684.27).
- **Payment coverage:** REJECTED & PENDING claims have **no** payment rows; 1,670 approved/partially-approved claims have no payment row yet.
- **Dimension usage in claims:** all 500 hospitals, all 50 diagnoses, 31 of 100 procedures, 14,107 of 20,000 patients, 24,543 of 25,000 policies.

## Financial-field rules (project-wide)

1. `claim_amount` (billed) → `approved_amount` (liability) → `paid_amount` (cash) are **three distinct layers**; never interchange.
2. Within `paid_amount`, only `payment_status='PAID'` is **settled**; `PROCESSING` is in-flight and must be reported separately.
3. Profitability requires premium ⟷ claim cost; use `policies.annual_premium` as the revenue input. Do not compute profitability if a required input is unavailable for the grain in question.
4. `procedures.base_cost` is a reference cost — a claim legitimately exceeds base cost; do not treat the excess as overcharging without further evidence.
