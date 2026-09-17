# Step 3C — Combined All-Format Parser Validation

**Status:** completed (12/09/2026). Stopped for review.

**Result:** the complete parser, run twice over all 5,000 raw logs with the detection priority
**F4 → F3 → F1 → F5 → F2 → NONE**, meets every acceptance check of Step 3A §12 (T-01 … T-10) and all eight Step 3C
requirements on its first run.

| Requirement | Result |
|---|---|
| 1. Exactly one final format per row | 5,000 / 5,000 rows classified; each has exactly one detection rule; 0 conflicts; 5,000 / 5,000 equal the answer key |
| 2. NONE rows | the 5 DET-NONE rows (EC-130, EC-137–140) are NONE, as are the 4 DET-00 rows; all 9 BROKEN with 10 MISSING fields |
| 3. All 10 fields vs the answer key | 50,000 / 50,000 values and 50,000 / 50,000 validity labels |
| 4. 100% acceptance (C-05) | **50,000 / 50,000 (100.00%)** across the complete dataset |
| 5. Record validity and diagnostics | record validity 5,000 / 5,000 (VALID 4,750 · INVALID 238 · BROKEN 12); diagnostics exactly equal the register (10 codes) |
| 6. Values at their recorded positions | 47,374 / 47,374 field values and 1,113 / 1,113 secondary values |
| 7. F1–F5 regression and raw integrity | 4,995 rows identical to Step 3B-7; F1–F5 each identical to the run in which it was first accepted; raw input 10 / 10 checks before and after |
| 8. Determinism | the two complete runs are identical (0 differing rows in all three output tables) |

**Not included:** JSON/JSONB, PostGIS, indexes and performance experiments. The raw input table was not modified.

---

## 1. What changed in this step

| File | Change |
|---|---|
| [sql/15_parser_core.sql](../sql/15_parser_core.sql) | **DET-NONE** (Step 3A §4.2, order 6): a non-blank row that matches no rule is NONE with diagnostic `no_format_detected`, all fields MISSING (`rule_id` `DET-NONE no format`), record BROKEN. `format_candidates` = `{DET-NONE}`. Runs record `formats_implemented = {F1,F2,F3,F4,F5,NONE}`. New run invariant: no row may be left without a final format. Applied as an asserted text patch |
| [sql/26_test_combined_parser.sql](../sql/26_test_combined_parser.sql) | new: two complete runs; T-01 … T-10; the eight Step 3C requirements; diagnostics register; secondary-value register; regression against Step 3B-7 and against each format's first accepted run; verdict |
| [sql/run_step3c_combined_parser.ps1](../sql/run_step3c_combined_parser.ps1) | new: answer-key hash check, Step 1 generator self-check, object check, re-install of every parser object from source, then sql/26 |

No extractor, validator, reference table, output table or view changed. The runner re-installs them from their
source files so that the validated parser is exactly what is in `sql/`:

- 09 validators
- 10 F1
- 13 and 14 F2
- 17 and 18 F3
- 20 and 21 F4
- 23 and 24 F5
- 15 core
- 11 views

It does **not** run 06 (answer key), 07 (reference tables) or 08 (output tables), so the answer key stays read-only
and all earlier runs stay available as regression baselines.

```powershell
# PGHOST, PGPORT, PGUSER, PGPASSWORD set in the environment
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3c_combined_parser.ps1"
```

## 2. The complete parser

| Order | Rule | Condition | Format | Rows |
|---:|---|---|---|---:|
| 0 | DET-00 | `raw_log` NULL, empty or whitespace only | NONE | 4 |
| 1 | DET-F4 | 3 tokens, `[…]`, quoted `"METHOD target HTTP/n.n"` or `"-"` | F4 | 986 |
| 2 | DET-F3 | `{` followed by `"` | F3 | 985 |
| 3 | DET-F1 | ≥ 2 `key=` segments after line start, `\|` or TAB | F1 | 1,528 |
| 4 | DET-F5 | exactly 9 semicolons and a timestamp shape in column 1 | F5 | 500 |
| 5 | DET-F2 | fallback: ≥ 2 sentence cues | F2 | 992 |
| 6 | DET-NONE | none of the above | NONE | 5 |

Each format has its own extractor:

| Format | Extractor | Method |
|---|---|---|
| F1 | `f1_candidates` | quote-aware `key=value` segments |
| F2 | `f2_candidates` | left-to-right sentence grammar |
| F3 | `f3_candidates` | syslog header + regex-only JSON scanner |
| F4 | `f4_candidates` | fixed positions, quoted fields, known-key extras |
| F5 | `f5_candidates` | ten semicolon columns |

`run_parser()` applies selection, the value-state flow, the validators, record validity, secondary values and the
run invariants to all five.

---

## 3. Results

PostgreSQL 17.9. Runs 13 (A) and 14 (B), parser version `3C combined v1`, reference data `3B-7.1`: 23.16 s and
19.30 s for all 5,000 rows (timing recorded only; no performance work in this step). Both runs:
`fingerprint_check_before` and `fingerprint_check_after` true.

### 3.1 T-01 / T-02 — raw input integrity (requirement 7)

`verify_raw_access_logs()` before the runs and after both runs:

| # | Check | Expected = actual |
|---:|---|---|
| 1 | row count equals load audit | 5,000 |
| 2 | log_id range | 1..5000 |
| 3 | log_ids distinct and contiguous | 5,000 |
| 4 | NULL `raw_log` rows | 1 |
| 5 | empty-string `raw_log` rows | 1 |
| 6 | total characters | 1,194,267 |
| 7 | total UTF-8 bytes | 1,194,874 |
| 8 | rows differing from their fingerprint | 0 |
| 9 | dataset digest | `1bcff42a6cd6634bd722064b629a0088dbbd7c67ac5276d013c505ac3fb06275` |
| 10 | read-only guard triggers enabled | 3 |

Outside the database:

- `generate_raw_logs.py --check` reports `raw_access_logs.csv`, `expected_fields.csv` and `dataset_manifest.json`
  identical.
- `raw_csv_digest.py` recomputes CSV SHA-256 `a94fc3cc…e661e`, 5,000 rows, NULL log_id 4240, empty string 4387, and
  the same dataset digest.

### 3.2 T-03 — output shape

| Check | Result |
|---|---|
| `parsed_log` rows / distinct log_ids / raw rows without a `parsed_log` row | 5,000 / 5,000 / 0 |
| `parsed_field` rows | 50,000 |
| Logs without exactly 10 distinct fields | 0 |
| Stored empty strings / MISSING ⇔ NULL inconsistencies | 0 / 0 |

### 3.3 Requirement 1 / T-04 — one final classification per row

| Check | Result |
|---|---|
| Rows without a format / with an unknown family | 0 / 0 |
| Rows whose `format_candidates` is not exactly one rule, or not equal to `{detection_rule}` | 0 / 0 |
| Rule inconsistent with the family (`DET-Fx` ⇒ Fx; `DET-00`/`DET-NONE` ⇒ NONE) | 0 |
| `format_conflict` | 0 |
| Format equal to the answer key | **5,000 / 5,000** |

| Answer key | Parsed | Rule | Rows |
|---|---|---|---:|
| F1 | F1 | DET-F1 | 1,528 |
| F2 | F2 | DET-F2 | 992 |
| F3 | F3 | DET-F3 | 985 |
| F4 | F4 | DET-F4 | 986 |
| F5 | F5 | DET-F5 | 500 |
| NONE | NONE | DET-00 | 4 |
| NONE | NONE | DET-NONE | 5 |

### 3.4 Requirement 2 — NONE rows

| Case | Rule | Raw text | Record | Diagnostics | Fields |
|---|---|---|---|---|---|
| EC-129 | DET-00 | SQL NULL | BROKEN | — | 10 MISSING (`DET-00 no event`) |
| EC-131 | DET-00 | empty string | BROKEN | — | 10 MISSING |
| EC-132 | DET-00 | spaces | BROKEN | — | 10 MISSING |
| EC-133 | DET-00 | TAB, space, CR LF | BROKEN | — | 10 MISSING |
| EC-130 | DET-NONE | literal `NULL` | BROKEN | `no_format_detected` | 10 MISSING (`DET-NONE no format`) |
| EC-137 | DET-NONE | pipe header `timestamp \| entity \| …` | BROKEN | `no_format_detected` | 10 MISSING |
| EC-138 | DET-NONE | 9-semicolon header `TIMESTAMP;ENTITY_TYPE;…` | BROKEN | `no_format_detected` | 10 MISSING |
| EC-139 | DET-NONE | `##########` | BROKEN | `no_format_detected` | 10 MISSING |
| EC-140 | DET-NONE | ANSI escapes and mojibake | BROKEN | `no_format_detected` | 10 MISSING |

9 NONE rows = 9 in the answer key; none has a secondary value. In the Step 3B-7 run the 5 DET-NONE rows were deferred
(no field rows); they are the only rows whose output changed in this step (§3.12).

### 3.5 Requirements 3 and 4 / T-07 / C-05 — all fields, all rows

| Field | Rows | Value match | Validity match | Both |
|---|---:|---:|---:|---:|
| entity_type | 5,000 | 5,000 | 5,000 | 5,000 |
| email_address | 5,000 | 5,000 | 5,000 | 5,000 |
| resource_url | 5,000 | 5,000 | 5,000 | 5,000 |
| event_timestamp | 5,000 | 5,000 | 5,000 | 5,000 |
| tool | 5,000 | 5,000 | 5,000 | 5,000 |
| latitude | 5,000 | 5,000 | 5,000 | 5,000 |
| longitude | 5,000 | 5,000 | 5,000 | 5,000 |
| ip_address | 5,000 | 5,000 | 5,000 | 5,000 |
| action_phrase | 5,000 | 5,000 | 5,000 | 5,000 |
| status | 5,000 | 5,000 | 5,000 | 5,000 |
| **All fields** | **50,000** | **50,000** | **50,000** | **50,000 (100.00%)** |

| Format | Logs | Field values | Both match (every field column = logs) |
|---|---:|---:|---:|
| F1 | 1,528 | 15,280 | 15,280 |
| F2 | 992 | 9,920 | 9,920 |
| F3 | 985 | 9,850 | 9,850 |
| F4 | 986 | 9,860 | 9,860 |
| F5 | 500 | 5,000 | 5,000 |
| NONE | 9 | 90 | 90 |
| **Total** | **5,000** | **50,000** | **50,000** |

Mismatches: none.

**T-06 curated fixtures:** EC-001 … EC-150 give 1,500 / 1,500 field values and 0 cases with a mismatch. By format:
F1 73, F2 22, F3 15, F4 16, F5 15, NONE 9.

### 3.6 Requirement 5 / T-10 — validity distribution and record validity

Parser = answer key = Step 3A §10.1 target in all 40 cells:

| Field | VALID | INVALID | PLACEHOLDER | MISSING |
|---|---:|---:|---:|---:|
| entity_type | 4,634 | 18 | 42 | 306 |
| email_address | 4,544 | 58 | 109 | 289 |
| resource_url | 4,756 | 15 | 78 | 151 |
| event_timestamp | 4,928 | 62 | 0 | 10 |
| tool | 4,507 | 1 | 160 | 332 |
| latitude | 4,249 | 24 | 66 | 661 |
| longitude | 4,252 | 27 | 67 | 654 |
| ip_address | 4,948 | 38 | 1 | 13 |
| action_phrase | 4,987 | 0 | 0 | 13 |
| status | 4,701 | 12 | 90 | 197 |

Record validity (parser = answer key = Step 3A §10.4 target; 5,000 / 5,000 rows equal):

| Format | VALID | INVALID | BROKEN |
|---|---:|---:|---:|
| F1 | 1,443 | 84 | 1 (EC-134) |
| F2 | 947 | 45 | 0 |
| F3 | 947 | 37 | 1 (EC-135) |
| F4 | 939 | 46 | 1 (EC-136) |
| F5 | 474 | 26 | 0 |
| NONE | 0 | 0 | 9 |
| **Total** | **4,750** | **238** | **12** |

### 3.7 Requirement 5 — diagnostics

Every diagnostic in run B, compared with the register built from Step 3A (§4.5, §8.2, §10.3):

| Code | Logs | Cases | Reason |
|---|---:|---|---|
| `truncated` | 3 | EC-134, EC-135, EC-136 | F1 C-06; F3 unclosed JSON string; F4 unclosed user-agent quote |
| `heuristic_truncation` | 1 | EC-134 | the F1 rule is content-based |
| `duplicate_field:status` | 1 | EC-128 | F3 `"status":401` before `"result":"FAILED"` (C-01) |
| `no_format_detected` | 5 | EC-130, EC-137–140 | DET-NONE |

| Check | Result |
|---|---|
| Codes in run B / in the register | 10 / 10 |
| Unexpected codes / missing codes | 0 / 0 |
| `is_truncated` without `truncated`, or the reverse | 0 |
| BROKEN ⇔ (NONE or truncated) violations | 0 |
| `format_conflict`, `unrecognised_text`, `timestamp_not_found`, `column_count_not_10`, … | none |

### 3.8 Requirement 6 / T-05 — exact positions

| Format | Stored field values | Equal to `substr(raw_log, start_pos, length)` |
|---|---:|---:|
| F1 | 14,427 | 14,427 |
| F2 | 9,272 | 9,272 |
| F3 | 9,414 | 9,414 |
| F4 | 9,491 | 9,491 |
| F5 | 4,770 | 4,770 |
| NONE | 0 | 0 |
| **Total** | **47,374** | **47,374** |

- Secondary values: 1,113 / 1,113 exact.
- Values with a NULL position, or positions without a value: 0.
- The other 2,626 field rows are MISSING, stored as NULL value and NULL position.

### 3.9 T-08 — look-alike traps

| Check (all formats) | Result |
|---|---:|
| Field values whose spans overlap another field's span (one token read for both axes allowed) | 0 |
| Secondary values stored at the same field and position as the primary value | 0 |
| IP values starting inside the resource or the tool | 0 |
| Latitude / longitude starting inside the timestamp or the tool | 0 |
| Timestamps starting inside the resource | 0 |
| IPv4 look-alikes kept as secondary (`ip_like_in_resource`, `ip_like_in_tool`) | 450 |
| Referer URLs kept as secondary | 191 |

### 3.10 Secondary values (informational; not part of C-05)

4,990 / 5,000 logs have exactly the answer key's secondary set:

| Format | Logs | Same set | Different |
|---|---:|---:|---:|
| F1 | 1,528 | 1,524 | 4 |
| F2 | 992 | 991 | 1 |
| F3 | 985 | 983 | 2 |
| F4 | 986 | 983 | 3 |
| F5 | 500 | 500 | 0 |
| NONE | 9 | 9 | 0 |

The 10 differences are exactly the register of answer-key annotation differences documented in Steps 3B-3 … 3B-6
(0 unregistered, 0 registered but now equal):

| Case | Answer key | Parser | Reason |
|---|---|---|---|
| EC-002 | `date_in_resource=2026-01-06` | — | annotation of a date inside the resource |
| EC-030 | `email_like_in_resource=…` | — | annotation of an e-mail-like token inside the resource |
| EC-100 | `ip_like_in_resource=fe80::…` | — | IPv6 look-alike annotation (the parser rule covers IPv4 look-alikes) |
| EC-143 | `path_in_trace=…;phrase_in_trace=…` | — | stack-trace text outside the event scope |
| EC-110 | `keyword_in_resource=denied` | — | outcome word inside the resource |
| EC-005 | `status_word_in_resource=status=open` | — | status word inside the resource |
| EC-036 | `date_in_resource=2026-02-07` | — | date inside the resource |
| EC-063 | — | `ip_like_in_tool=124.0.0.0` | curated row omits the annotation that generated rows with `Chrome/124.0.0.0` carry |
| EC-085, EC-142 | `client_port=51544` | `client_port=51544;ip_like_in_tool=124.0.0.0` | same as EC-063 |

### 3.11 Requirement 8 / T-09 — determinism

| Comparison of run A and run B | Rows |
|---|---:|
| `parsed_log` A∖B / B∖A | 0 / 0 |
| `parsed_field` A∖B / B∖A | 0 / 0 |
| `parsed_secondary` A∖B / B∖A | 0 / 0 |
| Row-count differences (`parsed_field`, `parsed_secondary`) | 0 / 0 |

### 3.12 Requirement 7 — F1–F5 regression

**Against the Step 3B-7 run (run 12, formats `{F1,F2,F3,F4,F5}`)**, every row except the 5 formerly deferred
DET-NONE rows:

| 4,995 logs compared | Rows only in run 12 | Rows only in run B |
|---|---:|---:|
| `parsed_log` | 0 | 0 |
| `parsed_field` | 0 | 0 |
| `parsed_secondary` | 0 | 0 |

The 5 DET-NONE rows changed exactly as intended:

| | Before (run 12) | After (run B) |
|---|---|---|
| Format and rule | deferred | NONE, `DET-NONE` |
| Record validity | none | BROKEN |
| Diagnostics | `format_not_implemented_in_this_step` | `no_format_detected` |
| Field rows | 0 | 10 MISSING |

**Each format against the run in which it was first accepted:**

| Format | Baseline run | Logs | `parsed_log` diff | `parsed_field` diff (both directions) | `parsed_secondary` diff (both directions) |
|---|---|---:|---:|---:|---:|
| F1 | 2 (Step 3B-3, `{F1}`) | 1,528 | 0 | 0 / 0 | 0 / 0 |
| F2 | 6 (Step 3B-4, `{F1,F2}`) | 992 | 0 | 0 / 0 | 0 / 0 |
| F3 | 8 (Step 3B-5, `{F1,F2,F3}`) | 985 | 0 | 0 / 0 | 0 / 0 |
| F4 | 10 (Step 3B-6, `{F1,F2,F3,F4}`) | 986 | 0 | 0 / 0 | 0 / 0 |
| F5 | 12 (Step 3B-7, `{F1,…,F5}`) | 500 | 0 | 0 / 0 | 0 / 0 |

Every format's output is byte-for-byte the output that was reviewed when that format was accepted, now produced by
the complete parser.

---

## 4. Acceptance summary (Step 3A §12)

| Test | Status | Evidence |
|---|---|---|
| T-01 Load fidelity | PASS | §3.1: 5,000 rows, 1 NULL, 1 empty, digest and fingerprints |
| T-02 Preservation | PASS | §3.1: 10 / 10 before and after; guard triggers enabled; run fingerprints true |
| T-03 Output shape | PASS | §3.2: 5,000 / 50,000 rows; no orphans; no empty strings |
| T-04 Detection | PASS | §3.3: 5,000 / 5,000; 0 conflicts |
| T-05 Offsets | PASS | §3.8: 47,374 + 1,113 values exact |
| T-06 Curated fixtures | PASS | §3.5: 1,500 / 1,500 |
| T-07 Full accuracy (C-05) | PASS | §3.5: 50,000 / 50,000 |
| T-08 Look-alike regressions | PASS | §3.9: 0 traps taken |
| T-09 Determinism | PASS | §3.11: 0 differences |
| T-10 Distribution | PASS | §3.6: 40 / 40 cells and record validity equal the targets |

`parser_run` now holds runs 1–14 (14 is the latest and is used by the evaluation views).

## 5. Choices made in this step (for review)

1. **DET-NONE output:** diagnostic `no_format_detected`, `format_candidates = {DET-NONE}`, field `rule_id`
   `DET-NONE no format`, record BROKEN. DET-00 rows keep their Step 3B output (no diagnostic, `DET-00 no event`), so
   they stay identical to earlier runs.
2. **`formats_implemented = {F1,F2,F3,F4,F5,NONE}`** marks combined runs, so each earlier format set remains a
   distinct regression baseline.
3. **Diagnostics register** (§3.7) and **secondary-difference register** (§3.10) are fixed lists in the test. A new
   diagnostic or a new secondary difference fails the test instead of passing silently.
4. **The runner re-installs every parser object from source** before validating, but never re-runs 06/07/08. A
   database rebuilt from scratch still needs the Step 3B-1 and 3B-3 runners first.
5. **Per-step test files** (sql/12, 16, 19, 22, 25) were not re-run. With DET-NONE in place, their "deferred"
   sections would now report 0 rows; their invariants are unaffected.
