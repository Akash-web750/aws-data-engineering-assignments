# Parser Validation Report — Final (Step 4A)

**Status:** final (12/09/2026). Stopped for review.
**Verdict:** the PostgreSQL regex parser **meets the acceptance target C-05** — 100% value and validity match for all
10 fields of all 5,000 raw logs — and passes all 10 acceptance tests T-01 … T-10.

| Item | Source |
|---|---|
| Validated runs | Step 3C runs **13** (A) and **14** (B), parser `3C combined v1`, reference data `3B-7.1`, formats `{F1,F2,F3,F4,F5,NONE}` |
| Full evidence | [Step3C_Combined_Parser_Validation.md](Step3C_Combined_Parser_Validation.md), produced by `sql/26_test_combined_parser.sql` |
| Confirmation for this report | read-only queries (`READ ONLY` transaction, rolled back) on 12/09/2026: run 14 is still the latest of 14 runs, and format counts, field totals, record validity, positions and raw checks are unchanged |
| Changes in Step 4A | documentation only — no parser logic, database objects or data changed |

---

## Part A — Primary acceptance results

### 1. Final format distribution (5,000 rows)

Detection priority: **F4 → F3 → F1 → F5 → F2 → NONE**.

| Format | Description | Rule | Rows | Equal to answer key |
|---|---|---|---:|---:|
| F1 | pipe / TAB `key=value` | DET-F1 | 1,528 | 1,528 |
| F2 | natural-language sentence | DET-F2 | 992 | 992 |
| F3 | syslog header + JSON | DET-F3 | 985 | 985 |
| F4 | web-server access log | DET-F4 | 986 | 986 |
| F5 | semicolon-positional export | DET-F5 | 500 | 500 |
| NONE | blank input | DET-00 | 4 | 4 |
| NONE | no recognised format | DET-NONE | 5 | 5 |
| **Total** | | | **5,000** | **5,000** |

- Every row has exactly one final format and exactly one detection rule.
- Format conflicts: 0. Unclassified rows: 0.

### 2. Final 50,000-field accuracy

| Format | Rows | Field values | Value and validity match |
|---|---:|---:|---:|
| F1 | 1,528 | 15,280 | 15,280 |
| F2 | 992 | 9,920 | 9,920 |
| F3 | 985 | 9,850 | 9,850 |
| F4 | 986 | 9,860 | 9,860 |
| F5 | 500 | 5,000 | 5,000 |
| NONE | 9 | 90 | 90 |
| **Total** | **5,000** | **50,000** | **50,000 (100.00%)** |

Mismatches: **0**. The 150 curated edge cases give 1,500 / 1,500 field values.

### 3. Value and validity match

| Field | Value match | Validity match | VALID | INVALID | PLACEHOLDER | MISSING |
|---|---:|---:|---:|---:|---:|---:|
| entity_type | 5,000 | 5,000 | 4,634 | 18 | 42 | 306 |
| email_address | 5,000 | 5,000 | 4,544 | 58 | 109 | 289 |
| resource_url | 5,000 | 5,000 | 4,756 | 15 | 78 | 151 |
| event_timestamp | 5,000 | 5,000 | 4,928 | 62 | 0 | 10 |
| tool | 5,000 | 5,000 | 4,507 | 1 | 160 | 332 |
| latitude | 5,000 | 5,000 | 4,249 | 24 | 66 | 661 |
| longitude | 5,000 | 5,000 | 4,252 | 27 | 67 | 654 |
| ip_address | 5,000 | 5,000 | 4,948 | 38 | 1 | 13 |
| action_phrase | 5,000 | 5,000 | 4,987 | 0 | 0 | 13 |
| status | 5,000 | 5,000 | 4,701 | 12 | 90 | 197 |
| **All fields** | **50,000** | **50,000** | **46,506** | **255** | **613** | **2,626** |

- **Value match:** the value is compared with `IS NOT DISTINCT FROM`, so MISSING (SQL NULL) matches MISSING.
- **Validity counts:** in all 40 cells, the parser's count equals the answer key and the Step 3A §10.1 target.

### 4. Record validity

| Format | VALID | INVALID | BROKEN | Total |
|---|---:|---:|---:|---:|
| F1 | 1,443 | 84 | 1 | 1,528 |
| F2 | 947 | 45 | 0 | 992 |
| F3 | 947 | 37 | 1 | 985 |
| F4 | 939 | 46 | 1 | 986 |
| F5 | 474 | 26 | 0 | 500 |
| NONE | 0 | 0 | 9 | 9 |
| **Total** | **4,750** | **238** | **12** | **5,000** |

- 5,000 / 5,000 rows equal the answer key; the totals equal the Step 3A §10.4 target.
- Rule: BROKEN = NONE or truncated; INVALID = at least one INVALID field; otherwise VALID.

### 5. NONE and BROKEN cases

All 12 BROKEN rows: 9 NONE rows + 3 truncated rows.

| Case | Format | Cause | Parser result | Diagnostics |
|---|---|---|---|---|
| EC-129 | NONE (DET-00) | SQL NULL | 10 MISSING | — |
| EC-131 | NONE (DET-00) | empty string | 10 MISSING | — |
| EC-132 | NONE (DET-00) | spaces only | 10 MISSING | — |
| EC-133 | NONE (DET-00) | TAB, space, CR LF | 10 MISSING | — |
| EC-130 | NONE (DET-NONE) | literal `NULL` text | 10 MISSING | `no_format_detected` |
| EC-137 | NONE (DET-NONE) | pipe header row | 10 MISSING | `no_format_detected` |
| EC-138 | NONE (DET-NONE) | 9-semicolon header row | 10 MISSING | `no_format_detected` |
| EC-139 | NONE (DET-NONE) | `##########` | 10 MISSING | `no_format_detected` |
| EC-140 | NONE (DET-NONE) | ANSI escapes and mojibake | 10 MISSING | `no_format_detected` |
| EC-134 | F1 | pipe log with neither action nor status (C-06) | last value INVALID | `truncated`, `heuristic_truncation` |
| EC-135 | F3 | JSON cut off inside the resource string | resource `https://sso.exam` INVALID; later fields MISSING | `truncated` |
| EC-136 | F4 | line cut off inside the user agent | tool `Mozilla/5.0 (Windows NT 10.0; Win` INVALID; extras MISSING | `truncated` |

The only other diagnostic in the dataset is `duplicate_field:status` (EC-128, a VALID row). The diagnostics equal the
expected register exactly: 10 codes, 0 unexpected, 0 missing.

### 6. Exact-position verification

| Format | Stored field values | Equal to `substr(raw_log, start_pos, length)` |
|---|---:|---:|
| F1 | 14,427 | 14,427 |
| F2 | 9,272 | 9,272 |
| F3 | 9,414 | 9,414 |
| F4 | 9,491 | 9,491 |
| F5 | 4,770 | 4,770 |
| NONE | 0 | 0 |
| **Total** | **47,374** | **47,374** |

- Secondary values: **1,113 / 1,113** exact.
- The remaining 2,626 field rows are MISSING, stored as NULL value and NULL position; 0 inconsistencies.
- Look-alike traps (T-08): no value overlaps another field's text. No IP, coordinate or timestamp is taken from inside
  another field, and no secondary value sits at a primary value's position.

### 7. Determinism

Runs 13 and 14, over identical input, are identical in both directions:

| Output table | Rows only in run 13 | Rows only in run 14 |
|---|---:|---:|
| `parsed_log` | 0 | 0 |
| `parsed_field` | 0 | 0 |
| `parsed_secondary` | 0 | 0 |

Row counts are equal. Supporting regression evidence:

- 4,995 rows are identical to the Step 3B-7 run. The only changed rows are the 5 DET-NONE rows, which were deferred
  before Step 3C.
- F1–F5 are each identical to the run in which that format was first accepted (runs 2, 6, 8, 10, 12).

### 8. Raw-input integrity

| Check | Result |
|---|---|
| `verify_raw_access_logs()` before and after both runs (row count, log_id range and contiguity, 1 NULL, 1 empty string, 1,194,267 characters, 1,194,874 UTF-8 bytes, 0 fingerprint differences, dataset digest, 3 read-only guard triggers) | **10 / 10** |
| Run fingerprint checks (`fingerprint_check_before`, `fingerprint_check_after`) for runs 13 and 14 | all true |
| Dataset digest | `1bcff42a6cd6634bd722064b629a0088dbbd7c67ac5276d013c505ac3fb06275` (unchanged) |
| Step 1 files (`generate_raw_logs.py --check`) | `raw_access_logs.csv`, `expected_fields.csv`, `dataset_manifest.json` identical |
| Independent CSV digest (`raw_csv_digest.py`) | SHA-256 `a94fc3cc…e661e`, 5,000 rows, same dataset digest |

The raw input table was never modified.

### 9. Acceptance tests (Step 3A §12)

| Test | Requirement | Final status | Evidence |
|---|---|---|---|
| T-01 | Load fidelity | **PASS** | 5,000 rows; 1 NULL; 1 empty string; digest and fingerprints (§8) |
| T-02 | Preservation | **PASS** | 10 / 10 integrity checks before and after; guard triggers enabled (§8) |
| T-03 | Output shape | **PASS** | 5,000 `parsed_log` and 50,000 `parsed_field` rows; 10 fields per log; no orphans; no stored empty strings |
| T-04 | Detection | **PASS** | 5,000 / 5,000 formats equal the answer key; 0 conflicts (§1) |
| T-05 | Offsets | **PASS** | 47,374 / 47,374 field values and 1,113 / 1,113 secondary values exact (§6) |
| T-06 | Curated fixtures | **PASS** | EC-001 … EC-150: 1,500 / 1,500 field values |
| T-07 | Full accuracy (C-05) | **PASS** | 50,000 / 50,000 value and validity (§2, §3) |
| T-08 | Look-alike regressions | **PASS** | 0 overlapping spans; 0 traps taken as primary values (§6) |
| T-09 | Determinism | **PASS** | 0 differences between runs 13 and 14 (§7) |
| T-10 | Distribution | **PASS** | 40 / 40 validity cells and record validity equal the targets (§3, §4) |

**10 / 10 acceptance tests passed.**

---

## Part B — Secondary values (informational; not part of the acceptance target)

Secondary values are extra candidates the parser keeps next to a primary value, for example:

- ports, proxy IPs and referer URLs
- IP look-alikes inside a resource or tool
- a later duplicate status

The answer key's `secondary_values` column is an annotation. C-05 and T-01 … T-10 do not include it.

**Result:** 4,990 / 5,000 logs have exactly the answer key's secondary set. The 10 differences are all in the register
of known answer-key annotation differences, fixed in `sql/26`: 0 unregistered differences, 0 registered cases now
equal.

| Case | Format | Answer key has | Parser has | Nature of the difference |
|---|---|---|---|---|
| EC-002 | F1 | `date_in_resource=2026-01-06` | — | annotation of a date inside the resource; the parser does not extract dates from resources |
| EC-030 | F1 | `email_like_in_resource=s3cr3t@artifacts.example.internal` | — | annotation of an e-mail-like token inside the resource |
| EC-100 | F1 | `ip_like_in_resource=fe80::1ff:fe23:4567:890a` | — | IPv6 look-alike; the parser's look-alike rule covers IPv4 |
| EC-143 | F1 | `path_in_trace=/var/log/secure;phrase_in_trace=Permission denied` | — | stack-trace text after the event line, outside the event scope |
| EC-110 | F2 | `keyword_in_resource=denied` | — | outcome word inside the resource |
| EC-005 | F3 | `status_word_in_resource=status=open` | — | status word inside the resource |
| EC-036 | F3 | `date_in_resource=2026-02-07` | — | date inside the resource |
| EC-063 | F4 | — | `ip_like_in_tool=124.0.0.0` | curated answer-key row omits the annotation that generated rows with `Chrome/124.0.0.0` carry |
| EC-085 | F4 | `client_port=51544` | `client_port=51544;ip_like_in_tool=124.0.0.0` | same as EC-063 |
| EC-142 | F4 | `client_port=51544` | `client_port=51544;ip_like_in_tool=124.0.0.0` | same as EC-063 (exact duplicate of EC-085) |

| Format | Logs | Same secondary set | Different |
|---|---:|---:|---:|
| F1 | 1,528 | 1,524 | 4 |
| F2 | 992 | 991 | 1 |
| F3 | 985 | 983 | 2 |
| F4 | 986 | 983 | 3 |
| F5 | 500 | 500 | 0 |
| NONE | 9 | 9 | 0 |
| **Total** | **5,000** | **4,990** | **10** |

None of these differences affects a primary field value, a validity label, a record-validity result or any of T-01 …
T-10.

---

## Scope and reproduction

- **Not implemented** (by design at this stage): JSON/JSONB storage, PostGIS, indexes, performance experiments.
- **Reproduce the validation:**

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3c_combined_parser.ps1"
  ```

  The runner checks the answer-key file hash and the Step 1 generator, re-installs the parser from `sql/`, performs two
  complete runs and exits non-zero if any check fails. Each execution adds two runs to `parser_run`.
- Per-format implementation and design details: Step 3A design, Step 3B-3 … 3B-7 parser reports, Step 3C evidence
  report.
