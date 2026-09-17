# Step 3B-3 — F1 Parser (pipe / TAB key=value)

**Status:** implemented and tested (11/09/2026). Stopped for review.

**Result:** all **15,280 / 15,280** F1 field values (1,528 rows × 10 fields) match the answer key in **value and
validity** — the C-05 target for F1. Detection, positions, determinism and raw-input integrity checks all pass.

**Not included:** F2–F5 parsing, JSON/JSONB, PostGIS. The raw input table was not modified.

---

## 1. What was built

All objects are in database `postgresql_regex_task`, schema `log_regex`.

| Layer (Step 3A §2) | Object | Purpose |
|---|---|---|
| L4 evaluation input | `expected_fields` | Step 1 answer key, loaded unchanged, read-only (guard trigger, SQLSTATE `LR002`). Never read by the parser |
| L1 reference | `ref_field`, `ref_key_alias`, `ref_placeholder_token`, `ref_entity_type`, `ref_status_word`, `ref_http_reason`, `ref_resource_scheme`, `ref_month_name`, `ref_timestamp_shape`, `ref_data_version` | Vocabularies and patterns as data (P-06). Key aliases for F1 only |
| L2 validators | `is_valid_entity_type`, `is_valid_email`, `is_valid_resource`, `is_valid_timestamp`, `is_valid_coordinate`, `is_valid_ip`, `is_valid_status`, `field_validity` | VAL-* rules; error-free; never change a value |
| L2 parser | `line_event_end`, `detect_format`, `f1_candidates`, `run_parser` | S0–S8 for F1 |
| L3 output | `parser_run`, `parsed_log`, `parsed_field`, `parsed_secondary`, `v_parsed_access_logs` | One row per field (C-07), wide view on top |
| L4 evaluation | `v_parser_field_comparison`, `v_parser_mismatches` | Parser output vs answer key |

## 2. Files and how to run

| File | Purpose | Re-runnable |
|---|---|---|
| [sql/06_load_answer_key.sql](../sql/06_load_answer_key.sql) | Load and protect `expected_fields` | no (skipped by the runner once loaded) |
| [sql/07_parser_reference_data.sql](../sql/07_parser_reference_data.sql) | Reference tables | yes (refuses with `LR003` while `access_log_flat` exists, Step 5A review) |
| [sql/08_parser_output_tables.sql](../sql/08_parser_output_tables.sql) | Output tables, integrity constraints, wide view | yes (drops previous runs; refuses with `LR003` while `access_log_flat` exists, Step 5A review) |
| [sql/09_parser_validators.sql](../sql/09_parser_validators.sql) | Field validators | yes |
| [sql/10_parser_f1.sql](../sql/10_parser_f1.sql) | Detection, event scope, F1 extraction, `run_parser()` (since Step 3B-4 only `f1_candidates()`; the shared functions are in `sql/15_parser_core.sql`) | yes |
| [sql/11_parser_evaluation_views.sql](../sql/11_parser_evaluation_views.sql) | Comparison views | yes |
| [sql/12_test_f1_parser.sql](../sql/12_test_f1_parser.sql) | Two parser runs and the full report | yes |
| [sql/run_step3b3_f1_parser.ps1](../sql/run_step3b3_f1_parser.ps1) | Checks the answer-key file hash against the manifest, then runs 06–12 | yes |

```powershell
# PGHOST, PGPORT, PGUSER, PGPASSWORD set in the environment
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b3_f1_parser.ps1"
```

A parser run on its own: `SELECT log_regex.run_parser('3B-3 F1 v1');` (returns the `run_id`).

---

## 3. How the F1 parser works

### 3.1 Preservation of `log_id` and `raw_log`

- `run_parser()` only reads `raw_access_logs`. It calls `verify_raw_access_logs()` **before** and **after** parsing
  and fails the run if either check does not pass; the results are stored in `parser_run`.
- Every `parsed_log` / `parsed_field` / `parsed_secondary` row carries the original `log_id` (foreign keys to
  `raw_access_logs`). One `parsed_log` row exists for every raw row, including rows of formats not yet implemented.
- No raw text is copied into the results. Each value stores its 1-based `start_pos`; the run fails unless
  `substr(raw_log, start_pos, char_length(value)) = value` for every stored value and secondary value.
- The wide view `v_parsed_access_logs` joins `raw_log` from the source table.

### 3.2 Detection (S0/S1)

| Rule | Condition | Result |
|---|---|---|
| DET-00 | `raw_log` NULL, empty or whitespace only | NONE, all fields MISSING |
| DET-F1 | At least two `key=` segments on the event line, each at the line start or after `\|` or TAB (optional spaces, TAB, NBSP before the key) | F1 |
| DEFERRED | Anything else | `format_family` NULL, diagnostic `format_not_implemented_in_this_step`, no field rows |

The DET-F4 and DET-F3 precedence rules of Step 3A §4.2 come with those formats. Adding them cannot change the F1
result: the DET-F1 predicate, evaluated on all 5,000 rows, has no false positives (§4.1).

### 3.3 Event scope (S2)

The event is the first line of `raw_log`; a CR directly before the first LF is excluded (EC-143 stack trace, EC-148
CR LF). The scope is a prefix, so positions stay positions in `raw_log`.

### 3.4 Segmentation (S3) — delimiters outside quoted values only

The event line is cut into segments at `|` or TAB. A segment is the longest of three alternatives (one regular
expression; PostgreSQL returns the longest overall match):

| Alternative | Matches | Example |
|---|---|---|
| Closed quoted value | `key="…"` plus any tail up to the next delimiter | `action="Access denied \| escalated to SOC"` (EC-150) |
| Unclosed quoted value | `key="…` to the end of the event | (truncation; not present in F1 data) |
| Plain run | Everything up to the next `\|` or TAB | `lat=51°33'01.8"N` — the `"` is the arc-seconds sign, not a quote |

Quotes are delimiters only at the start of a value, directly after `key=`. Spaces and NBSP around a segment and after
`=` are trimmed by moving the position, never by editing text (EC-147).

### 3.5 Extraction by key (S3/S4)

- Segment 1 without `key=` is the timestamp slot; if segment 1 is a `key=` segment the timestamp is MISSING (EC-057).
- Every `key=value` segment is looked up in `ref_key_alias`. Fields are never taken by position; the data has 193
  field orders.
- Clean-up keeps the exact substring and adjusts `start_pos`:

  | Rule | Example |
  |---|---|
  | Enclosing double quotes removed | `action="Login successful"` → `Login successful` |
  | Email `<…>` and `mailto:` removed | `email=<ops@x.example>`, `email=mailto:aisha.khan@example.gov.in` (EC-020) |
  | Status reason split off as secondary `status_reason` | `outcome=BLOCKED (policy: geo-fence)` → `BLOCKED` (EC-127) |
  | `geo=lat,lon` split at the first comma, latitude first (C-03); without a comma the token applies to both axes | `geo=40.7128,-74.0060`, `geo=N/A` |

- Secondary keys: `ingested_at` → timestamp (EC-056), `retry_action` → action (EC-117). Unknown keys become the
  diagnostic `unknown_key:<key>` (none in the data).

### 3.6 Selection, value state and validation (S5–S7)

- **Selection:** the first candidate per field in document order (C-01, C-02); later duplicates become secondary
  values (none in the F1 data).
- **Value state** (Step 3A §10.1), recorded in `rule_id`:

  | Order | Rule | Result |
  |---:|---|---|
  | VS-1 | No segment for the field | MISSING, `missing_reason` absent |
  | VS-2 | `key=` with an empty value | MISSING, `missing_reason` empty |
  | VS-4 | Value is `-`, `N/A`, `NULL`, `null` or `unknown` | PLACEHOLDER |
  | VS-5 | C-06: an F1 event with neither an action nor a status is truncated; its last extracted value is INVALID | INVALID |
  | VS-6 | Field validator | VALID / INVALID |

- **Validators:** entity type (case, space/`_`/`-` insensitive); email (ASCII shape, no `..`); resource (relative,
  Windows, UNC, or known scheme with non-empty authority); timestamp (9 data-driven shapes, calendar and clock checks,
  year 2026 for year-less dates, C-04); coordinates (decimal, hemisphere, DMS; range and axis letter); IP (exact Step
  3B-2 rule); status (HTTP 100–599 with standard reason, status vocabulary, `✓`); tool and action VALID when present.
- **Record validity:** BROKEN if truncated, INVALID if any field is INVALID, otherwise VALID.
- **Secondary values:** secondary keys, status reasons, duplicates, and IPv4 look-alikes inside the resource or tool.

### 3.7 Diagnostics and positions

`parsed_log.diagnostics` records `truncated`, `heuristic_truncation` (C-06), `unclosed_quote`, `unknown_key:…`,
`unrecognised_segment`, `duplicate_field:…`; `sub_format` records `pipe-delimited` or `tab-delimited`.
`parsed_field` records `start_pos`, `slot_id` (e.g. `F1.segment[1]`, `F1.key.outcome`, `F1.key.geo[2]`), `rule_id`
and `candidate_count`.

---

## 4. Results

Run on PostgreSQL 17.9; two parser runs (A and B) on identical input: 3.46 s and 3.33 s for all 5,000 rows.

### 4.1 Detection (all 5,000 rows)

| Answer-key format | Parser | Rule | Rows |
|---|---|---|---:|
| F1 | F1 | DET-F1 | 1,528 |
| NONE | NONE | DET-00 | 4 |
| F2 / F3 / F4 / F5 / NONE | deferred | DEFERRED | 992 / 985 / 986 / 500 / 5 |

F1: **1,528 true positives, 0 false positives, 0 false negatives.**

### 4.2 Output shape and positions

| Check | Result |
|---|---|
| `parsed_log` rows | 5,000 (one per raw row; 0 raw rows without a parsed row) |
| `parsed_field` rows | 15,320 = (1,528 F1 + 4 DET-00) × 10; 0 parsed logs without exactly 10 fields |
| Field values exactly at `start_pos` | 14,427 / 14,427 |
| Secondary values exactly at `start_pos` | 46 / 46 |

### 4.3 Accuracy on all F1 rows

| Field | Rows | Value match | Validity match | Both |
|---|---:|---:|---:|---:|
| entity_type | 1,528 | 1,528 | 1,528 | 100% |
| email_address | 1,528 | 1,528 | 1,528 | 100% |
| resource_url | 1,528 | 1,528 | 1,528 | 100% |
| event_timestamp | 1,528 | 1,528 | 1,528 | 100% |
| tool | 1,528 | 1,528 | 1,528 | 100% |
| latitude | 1,528 | 1,528 | 1,528 | 100% |
| longitude | 1,528 | 1,528 | 1,528 | 100% |
| ip_address | 1,528 | 1,528 | 1,528 | 100% |
| action_phrase | 1,528 | 1,528 | 1,528 | 100% |
| status | 1,528 | 1,528 | 1,528 | 100% |
| **All fields** | **15,280** | **15,280** | **15,280** | **100%** |

| Source | Logs | Field values | Match | Logs with a mismatch |
|---|---:|---:|---:|---:|
| Curated edge cases | 73 | 730 | 730 | 0 |
| Generated | 1,455 | 14,550 | 14,550 | 0 |

### 4.4 Validity distribution on F1 rows (answer key = parser)

| Field | VALID | INVALID | PLACEHOLDER | MISSING |
|---|---:|---:|---:|---:|
| entity_type | 1,416 | 6 | 17 | 89 |
| email_address | 1,387 | 24 | 15 | 102 |
| resource_url | 1,451 | 5 | 14 | 58 |
| event_timestamp | 1,504 | 23 | 0 | 1 |
| tool | 1,391 | 0 | 23 | 114 |
| latitude | 1,289 | 10 | 32 | 197 |
| longitude | 1,280 | 8 | 26 | 214 |
| ip_address | 1,515 | 11 | 0 | 2 |
| action_phrase | 1,526 | 0 | 0 | 2 |
| status | 1,435 | 3 | 16 | 74 |

Every count is identical between the answer key and the parser.

Record validity: VALID 1,443 · INVALID 84 · BROKEN 1 (EC-134) — identical to the answer key.

### 4.5 Examples

**EC-127** — shuffled keys, status with a reason: `… | outcome=BLOCKED (policy: geo-fence) | lat=64.1466 | lon=-21.9426`

| Field | Value | Validity | start_pos | slot_id | rule_id |
|---|---|---|---:|---|---|
| event_timestamp | `2026-05-10T09:00:00Z` | VALID | 1 | `F1.segment[1]` | VS-6 VAL-TS |
| entity_type | `ADMIN` | VALID | 31 | `F1.key.entity` | VS-6 VAL-ENT |
| email_address | `vikram.rao@corp.example.com` | VALID | 45 | `F1.key.email` | VS-6 VAL-EML |
| action_phrase | `Request blocked by policy` | VALID | 83 | `F1.key.action` | VS-6 VAL-ACT |
| resource_url | `https://admin.corp.example.com/iam/roles` | VALID | 121 | `F1.key.resource` | VS-6 VAL-RES |
| tool | `Edge/124.0.2478.67` | VALID | 169 | `F1.key.tool` | VS-6 VAL-TL |
| ip_address | `192.168.30.12` | VALID | 193 | `F1.key.ip` | VS-6 VAL-IP |
| status | `BLOCKED` | VALID | 217 | `F1.key.outcome` | VS-6 VAL-STS |
| latitude | `64.1466` | VALID | 251 | `F1.key.lat` | VS-6 VAL-GEO |
| longitude | `-21.9426` | VALID | 265 | `F1.key.lon` | VS-6 VAL-GEO |

Secondary: `status_reason=policy: geo-fence`.

**EC-134** — truncated (C-06): `2026-05-12T08:00:00Z | entity=USER | email=meera.nair@corp.exa`

| Field | Value | Validity | start_pos | rule_id |
|---|---|---|---:|---|
| event_timestamp | `2026-05-12T08:00:00Z` | VALID | 1 | VS-6 VAL-TS |
| entity_type | `USER` | VALID | 31 | VS-6 VAL-ENT |
| email_address | `meera.nair@corp.exa` | INVALID | 44 | VS-5 truncated (C-06) |
| other 7 fields | NULL | MISSING (absent) | — | VS-1 absent |

Diagnostics: `truncated`, `heuristic_truncation`; record validity BROKEN. These are the only diagnostics on any F1 row.
Sub-formats: 1,527 pipe-delimited, 1 tab-delimited (EC-146).

### 4.6 Secondary values (informational; not part of C-05)

1,524 of 1,528 F1 rows have exactly the answer key's set of secondary values. The 4 differences are expected:

| Case | Answer key | Parser | Reason |
|---|---|---|---|
| EC-002 | `date_in_resource=2026-01-06` | — | Date look-alike scan not implemented |
| EC-030 | `email_like_in_resource=s3cr3t@artifacts.example.internal` | — | Email look-alike scan not implemented |
| EC-100 | `ip_like_in_resource=fe80::1ff:fe23:4567:890a` | — | Look-alike scan covers IPv4 only |
| EC-143 | `path_in_trace=/var/log/secure`, `phrase_in_trace=Permission denied` | — | Stack-trace lines are outside the event scope (G-08) |

### 4.7 Determinism and integrity

| Check | Result |
|---|---|
| Run A vs run B: `parsed_log`, `parsed_field`, `parsed_secondary` rows that differ | 0 / 0 / 0 |
| `verify_raw_access_logs()` before and after each run, and after the report | 10 / 10 passed |
| Step 1 files (`python data/generate_raw_logs.py --check`) | identical |
| Answer-key file hash vs manifest | identical (`6fddcad6…`) |

---

## 5. Issues found and fixed during implementation

| # | Issue | Effect | Fix |
|---:|---|---|---|
| 1 | Check constraint required `record_validity` on insert, but record validity is computed at the end of the run | First run rolled back at its first insert (nothing stored) | Constraint now only forbids validity on deferred rows; `run_parser()` fails the run if any parsed row ends without one |
| 2 | Report query `ORDER BY 1 = 'ALL FIELDS'` compared an integer with text | Report stopped in section 6 | Ordered by an explicit column |
| 3 | **Segment pattern `(?:"[^"]*"?\|[^\|\t"])*` allowed an optional closing quote.** PostgreSQL returns the *longest* overall match, so a quoted action value was re-read as an unclosed quote that ran across later delimiters; the arc-seconds `"` in DMS coordinates did the same | First complete result: 8,370 / 15,280 (54.78%); 1,064 `unclosed_quote` diagnostics; 4 false truncations | Quoting limited to whole values after `key=` (closed, unclosed-to-end, or plain run; §3.4). Result: 15,280 / 15,280 |
| 4 | NBSP and DMS symbols were typed as invisible literal characters in patterns | None (correct characters), but fragile | Replaced by ARE escapes `\u00A0`, `\u00B0`, `\u2032`, `\u2033`; all SQL files are ASCII |

Issue 3 is a concrete case of the Step 3A §6.2 warning about PostgreSQL regex match preference: the extraction
patterns must be written so that the longest match is the intended one.

## 6. Relation to the Step 3A design

| Design item | Status |
|---|---|
| F1 extraction (§7.1), selection (§8.2), value state (§10.1), validators (§10.2), C-06 truncation (§10.3) | Implemented and verified for F1 |
| Output structure (§11, C-07): one row per field, MISSING = NULL, positions, slot and rule provenance, wide view | Implemented |
| IP validation (Step 3B-2 rule) | Implemented in `is_valid_ip()` |
| T-03, T-04 (F1), T-05, T-06/T-07/T-10 (F1 rows), T-09 | Passed |
| Detection DET-F2…DET-F5, DET-NONE and their precedence | Not yet (rows recorded as DEFERRED) |
| Look-alike secondary scan for dates, email-like tokens and IPv6 | Not yet (informational only) |
| Additions | `expected_fields` guard trigger (LR002); `parsed_log.format_family` NULL for deferred rows; `run_parser()` raw integrity checks before/after; `ref_timestamp_shape` holds all 9 shape families although only the F1 shapes are exercised by F1 rows |
