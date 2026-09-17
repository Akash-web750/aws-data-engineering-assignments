# Step 3B-4 — F2 Parser (natural-language sentence logs)

**Status:** implemented and tested (11/09/2026). Stopped for review.

**Result:** all **9,920 / 9,920** F2 field values (992 rows × 10 fields) match the answer key in **value and
validity** — the C-05 target for F2. Detection is exact (992 true positives, 0 false positives on F1/F3/F4/F5/NONE
rows), every value is the exact substring at its recorded position, no `from` inside an action phrase became an IP
clause, runs are deterministic, and the raw input is unchanged.

**F1 unchanged:** the F1 rows of the new run are identical to the Step 3B-3 run in `parsed_log`, `parsed_field` and
`parsed_secondary` (0 differing rows); F1 accuracy stays at 15,280 / 15,280.

**Not included:** F3, F4, F5 parsing, JSON/JSONB, PostGIS. The raw input table was not modified.

---

## 1. What was built

All objects are in database `postgresql_regex_task`, schema `log_regex`.

| Layer (Step 3A §2) | Object | Change in this step |
|---|---|---|
| L1 reference | `ref_log_level` (8 words), `ref_sentinel_phrase` (F2: `anonymous` → email, `an unspecified resource` → resource) | new; `ref_data_version` = `3B-4.1` |
| L2 parser, F1 | `f1_candidates` | unchanged body; now the only function in `sql/10` |
| L2 parser, F2 | `f2_candidates`, `f2_match_coordinates`, `f2_ip_candidates` | new |
| L2 parser, shared | `line_event_end` (unchanged), `detect_format` (+ DET-F2), `run_parser` (F1 + F2, VS-3 sentinel) | moved to `sql/15` |
| L3 output / L4 evaluation | `parser_run`, `parsed_log`, `parsed_field`, `parsed_secondary`, views | unchanged; earlier runs kept |

## 2. Files and how to run

| File | Purpose | Re-runnable |
|---|---|---|
| [sql/13_parser_reference_data_f2.sql](../sql/13_parser_reference_data_f2.sql) | Log levels, sentinel phrases, reference-data version | yes |
| [sql/10_parser_f1.sql](../sql/10_parser_f1.sql) | `f1_candidates()` only (body byte-identical to Step 3B-3; checked by the split script) | yes |
| [sql/14_parser_f2.sql](../sql/14_parser_f2.sql) | F2 grammar: coordinate containers, IP/port token, `f2_candidates()` | yes |
| [sql/15_parser_core.sql](../sql/15_parser_core.sql) | `line_event_end()`, `detect_format()`, `run_parser()` for F1 + F2 (extended for F3 in Step 3B-5, see [Step3B5_F3_Parser.md](Step3B5_F3_Parser.md)) | yes |
| [sql/16_test_f2_parser.sql](../sql/16_test_f2_parser.sql) | Two parser runs, the full F2 report, F1 regression, invariants and verdict | yes (adds two runs) |
| [sql/run_step3b4_f2_parser.ps1](../sql/run_step3b4_f2_parser.ps1) | Answer-key hash check, Step 3B-3 object check, then 13, 10, 14, 15, 11, 16 | yes |
| [sql/run_step3b3_f1_parser.ps1](../sql/run_step3b3_f1_parser.ps1) | Changed: also runs 13, 14, 15 after 10, so a fresh install still works | yes |

```powershell
# PGHOST, PGPORT, PGUSER, PGPASSWORD set in the environment
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b4_f2_parser.ps1"
```

The 3B-4 runner does **not** re-run `sql/07` or `sql/08`, so the Step 3B-3 runs (formats `{F1}`) stay in `parser_run`
as the F1 regression baseline. Re-running the 3B-3 runner drops all runs, including that baseline; `sql/16` then
reports the regression as skipped instead of failing.

A parser run on its own: `SELECT log_regex.run_parser('3B-4 F1+F2 v1');` (returns the `run_id`).

---

## 3. How the F2 parser works

### 3.1 Detection (S0/S1)

| Rule | Condition | Result |
|---|---|---|
| DET-00 | `raw_log` NULL, empty or whitespace only | NONE (unchanged) |
| DET-F1 | At least two `key=` segments after the line start, `\|` or TAB | F1 (unchanged) |
| DET-F2 | Evaluated only when no structural rule matched; at least **two** of: (a) leading timestamp — `[dd/Mon/yyyy:hh:mm:ss ±zzzz]`, ISO date-time, `MM/DD/YYYY hh:mm:ss AM`, 10/13-digit epoch; (b) actor token — a token containing `@`, ` [at] `, or the word `anonymous`; (c) `from`/`client` followed by an IP-like token | F2 |
| DEFERRED | Anything else (F3, F4, F5 and the 5 DET-NONE rows until those rules exist) | no field rows |

DET-F2 is the fallback rule of Step 3A §4.2 (order 5, "defined by the absence of the other structures plus sentence
cues"). This matters: an F1 line such as EC-016 (`2026-01-18T13:22:41Z | entity=CUSTOMER | email=josé…@…`) also has
cues (a) and (b). Because DET-F2 is not evaluated when DET-F1 matched, F1 rows keep `format_candidates = {DET-F1}`
exactly as in Step 3B-3.

### 3.2 Left-to-right clause grammar (S3)

`f2_candidates()` keeps one cursor that only moves forward. Every pattern is anchored with `^` at the cursor, and a
clause consumes its text before the next one is tried. No field is found by searching the whole line.

| Step | Clause | Recognition at the cursor | Fields (slot_id) |
|---:|---|---|---|
| 1 | Prefix | Leading blanks; timestamp `[CLF]`, ISO, `MM/DD/YYYY hh:mm:ss AM`, or epoch, followed by a space; optional ` -`; optional log level from `ref_log_level` | event_timestamp (`F2.prefix.timestamp`) |
| 2 | Brackets after the prefix | Up to two `[word]`. Template A/B: the entity. Template C: a word in `ref_entity_type` is the entity, otherwise the first one is the template-C status | entity_type, status (`F2.prefix.bracket`) |
| 3 | Actor and entity | First actor token within the next 3 tokens: `"Name" <addr>`, `<addr>`, `local [at] host [dot] tld`, a token containing `@`, or the sentinel `anonymous`. Entity = the words between the prefix and the actor. `(on behalf of <addr>)` directly after the actor ⇒ secondary `delegated_email` | email_address (`F2.actor`, `.angle`, `.display_name`), entity_type (`F2.entity`) |
| 4 | Template-C clauses | Repeated: `connecting from <IP-like>`, `with <product>`, a coordinate container (`located …`) | ip_address, tool, latitude, longitude (`F2.clause.*`) |
| 5 | Resource | First of the next 12 tokens that is the sentinel `an unspecified resource`, `(<resource>)`, or starts like a resource (`/`, `\\`, `X:\`, `scheme:/`, `scheme//`). Template C: a final `.` at the event end is not part of it | resource_url (`F2.resource`, `.parenthesised`) |
| 6 | Action phrase | The text between the end of step 3/4 and the resource, right-trimmed | action_phrase (`F2.phrase`) |
| 7 | Trailing clauses, any order | Separators space `,` `;`; `(` `)` skipped. Coordinates; `[word]` ⇒ status; `from`/`client` + IP-like ⇒ IP; `via` + IP-like ⇒ secondary `proxy_ip`; `via`/`using`/`with`/`tool:` + product ⇒ tool; `- status: X`, `status=X`; `- CODE Reason` or `result X` ending the event ⇒ status; anything else ⇒ diagnostic `unrecognised_text` | tool, ip_address, latitude, longitude, status (`F2.trailing.*`) |
| 8 | Sentence end | Template C stops at the final `.` | — |

Token shapes used by the clauses:

| Token | Pattern idea | Examples |
|---|---|---|
| Product (TK-PRODUCT) | `name/version`, `name_version`, or `name` + space + dotted version | `Chrome/124.0.6367.91`, `OpenSSH_9.6p1`, `Ansible 2.16.4`, `kubectl/v1.29.3` |
| IP-like | Starts with a hex digit or `:`, only letters/digits/`.`/`:`/`%`, and contains `.` or `:` | `10.40.3.8`, `1.2.3.4.5`, `192.168.40.8:52814`, `2001:db8::5` — not `agent/1.2.3.4` or `accessing` |
| Coordinate | Decimal with optional hemisphere prefix, `NaN`, or DMS (`°`, `'`/`′`, `"`/`″`) | `-0.1278`, `N51.5074`, `19°04'33.6"N` |

Coordinate containers (`f2_match_coordinates`), all latitude-first (C-03), optionally introduced by `location ` or
`located `: `(lat, lon)`, `(loc: lat, lon)`, `[lat lon]`, `at lat X lon Y`, `at lat X`, `at lon Y`, `at X Y`.

### 3.3 Why the `from` in `was blocked from accessing` is never an IP clause

The action phrase is consumed by step 5/6 before the trailing clauses of step 7 are tried, so the cursor is already
past the phrase when `from <ip>` is recognised. In template C the clauses allowed before the phrase start with
`connecting from <IP-like>`, `with <product>` or a coordinate container, and `was blocked from accessing` starts with
none of them. In addition, `from` starts an IP clause only when the next token is IP-like, and
`accessing` is not. The test checks it on all 45 rows (§4.7).

### 3.4 Clean-up and positions (S4)

Values are exact substrings; clean-up only moves `start_pos` or shortens the span:

| Rule | Example |
|---|---|
| Brackets around the timestamp, bracketed entity and status excluded | `[07/Jan/2026:03:15:09 +0000]`, `[ADMIN]`, `[OK]` |
| Email `<…>` and display name excluded | `"Daniel Wilson" <daniel.wilson@example.co.uk>` (EC-019) |
| Resource parentheses and the following `,` excluded | `(https://vault.corp.example.com/secrets/prod),` (EC-028) |
| Template-C final full stop excluded | `…/reports/q1.` → `…/reports/q1` (EC-027) |
| IPv4 `:port` split; the port is secondary `client_port` | `192.168.40.8:52814` (EC-095) |
| Leading and trailing blanks outside the event | EC-149 |

### 3.5 Selection, value state and validation (S5–S7)

- **Selection:** the first primary candidate per field in document order (`doc_order` is the position), as for F1.
- **Value state:** Step 3A §10.1, with the sentinel step now active:

  | Order | Rule | F2 result |
  |---:|---|---|
  | VS-1 | No clause for the field | MISSING, `missing_reason` absent |
  | VS-3 | Sentinel phrase in the slot (`anonymous`, `an unspecified resource`) | MISSING, `missing_reason` sentinel |
  | VS-4 | Placeholder token | none in F2 |
  | VS-6 | Field validator (unchanged Step 3B-3 validators, exact Step 3B-2 IP rule) | VALID / INVALID |

  C-06 truncation stays F1-only. **Record validity:** INVALID if any field is INVALID, otherwise VALID.
- **Secondary values:** `delegated_email`, `proxy_ip`, `client_port`, and the existing IPv4 look-alike rule for the
  resource and tool (`ip_like_in_resource`, `ip_like_in_tool`).

### 3.6 Diagnostics and sub-format

Diagnostics: `timestamp_not_found`, `actor_not_found`, `extra_entity_text`, `resource_not_found`,
`action_phrase_not_found`, `unrecognised_text`, `duplicate_field:…`. `sub_format` follows Step 3A §4.4: `template-C`
when ` connecting from ` appears, `template-B` when `, result ` or ` using ` appears, otherwise `template-A`. The
sub-format is recorded only; the grammar does not branch on A versus B.

### 3.7 How F1 was kept unchanged

- `line_event_end`, `detect_format` and `run_parser` were moved out of `sql/10` by a script that aborts unless the
  `f1_candidates()` text is identical before and after.
- `run_parser()` runs the F1 statements unchanged; F2 adds a second candidate source (`UNION ALL`), the sentinel state,
  and `F2` in the format filters. Duplicates are recorded for primary candidates only, and selection has a
  `start_pos` tie-break; neither changes F1 output (F1 has no sentinel candidates and no two candidates of one field with
  the same `doc_order`).
- `sql/16` compares every F1 row of the new run with the latest `{F1}` run and fails on any difference.

---

## 4. Results

PostgreSQL 17.9; two parser runs (A = run 5, B = run 6) on identical input: 5.98 s and 6.30 s for all 5,000 rows
(Step 3B-3 F1 only: about 3.4 s).

### 4.1 Detection (all 5,000 rows)

| Answer key | Parsed | Rule | Rows |
|---|---|---|---:|
| F1 | F1 | DET-F1 | 1,528 |
| F2 | F2 | DET-F2 | 992 |
| F3 / F4 / F5 | deferred | — | 985 / 986 / 500 |
| NONE | deferred | — | 5 |
| NONE | NONE | DET-00 | 4 |

F1: 1,528 true positives, 0 false positives, 0 false negatives. F2: 992 true positives, **0 false positives**,
0 false negatives. No F3, F4, F5 or NONE row satisfies DET-F2.

### 4.2 Output shape and positions (run B)

| Check | Result |
|---|---|
| `parsed_log` rows / raw rows without one | 5,000 / 0 |
| F1 / F2 / DET-00 / deferred logs | 1,528 / 992 / 4 / 2,476 |
| `parsed_field` rows; parsed logs without exactly 10 fields | 25,240; 0 |
| Field values equal to `substr(raw_log, start_pos, length)` | 23,699 / 23,699 |
| Secondary values equal to their substring | 143 / 143 |
| Overlapping value spans between two fields of one F2 log | 0 |

### 4.3 Per-field accuracy on all F2 rows

| Field | Rows | Value match | Validity match | Both |
|---|---:|---:|---:|---:|
| entity_type | 992 | 992 | 992 | 992 |
| email_address | 992 | 992 | 992 | 992 |
| resource_url | 992 | 992 | 992 | 992 |
| event_timestamp | 992 | 992 | 992 | 992 |
| tool | 992 | 992 | 992 | 992 |
| latitude | 992 | 992 | 992 | 992 |
| longitude | 992 | 992 | 992 | 992 |
| ip_address | 992 | 992 | 992 | 992 |
| action_phrase | 992 | 992 | 992 | 992 |
| status | 992 | 992 | 992 | 992 |
| **All fields** | **9,920** | **9,920** | **9,920** | **9,920 (100.00%)** |

Mismatches: none.

### 4.4 Validity distribution on F2 rows (answer key = parser in every cell)

| Field | VALID | INVALID | PLACEHOLDER | MISSING |
|---|---:|---:|---:|---:|
| entity_type | 919 | 4 | 0 | 69 (absent) |
| email_address | 906 | 6 | 0 | 80 (sentinel `anonymous`) |
| resource_url | 946 | 1 | 0 | 45 (sentinel `an unspecified resource`) |
| event_timestamp | 979 | 13 | 0 | 0 |
| tool | 893 | 0 | 0 | 99 (absent) |
| latitude | 845 | 4 | 0 | 143 (absent) |
| longitude | 836 | 8 | 0 | 148 (absent) |
| ip_address | 980 | 11 | 0 | 1 (absent, EC-062) |
| action_phrase | 992 | 0 | 0 | 0 |
| status | 928 | 1 | 0 | 63 (absent) |

### 4.5 By template and source

| Group | Logs | Field values | Both match | Logs with a mismatch |
|---|---:|---:|---:|---:|
| template-A | 522 | 5,220 | 5,220 | 0 |
| template-B | 282 | 2,820 | 2,820 | 0 |
| template-C | 188 | 1,880 | 1,880 | 0 |
| curated | 22 | 220 | 220 | 0 |
| generated | 970 | 9,700 | 9,700 | 0 |

Template-C matches the Step 3A count (188). The generator tagged 288 rows as template B; 7 of them contain neither
`, result ` nor ` using ` (no tool, bracket or no status) and are labelled template-A by the §4.4 rule. This affects
the label only.

**Record validity:** INVALID 45 = 45, VALID 947 = 947.

**Clause usage (run B):** tool via `via` 461, `using` 261, `with` 170, `tool:` 1; IP via `from` 802,
`connecting from` 188, `client` 1; status via `- CODE Reason` 255, `result` 222, template-C bracket 174, trailing
bracket 152, `- status:` 125, `status=` 1; coordinates in template-C clauses 159 latitudes / 159 longitudes, in trailing
clauses 690 latitudes / 685 longitudes; resource in parentheses 1; email in `<…>` 217, with display name 53.

### 4.6 Secondary values (informational; not part of C-05)

991 / 992 F2 logs have exactly the answer key's secondary set: `client_port` 62, `ip_like_in_resource` 32,
`delegated_email` 1 (EC-021), `proxy_ip` 1 (EC-047), `ip_like_in_tool` 1 (EC-062). The one difference is EC-110,
where the answer key annotates `keyword_in_resource=denied` (an outcome word inside `/reports/access-denied-summary`);
that is a dataset annotation, not a value the parser extracts. Diagnostics on F2 rows: none.

### 4.7 `from` inside action phrases

| Answer-key phrase | Rows | Phrase exact | IP exact | IP position inside the phrase | Token after the first `from` is `accessing` |
|---|---:|---:|---:|---:|---:|
| `was blocked from accessing` | 45 | 45 | 45 | **0** | 37 |

A search for "the token after the first `from`" would return `accessing` in 37 of these rows; the grammar returns the
real address (e.g. GEN-00124: phrase `was blocked from accessing`, IP `10.49.0.125` from `F2.trailing.from`).

### 4.8 Whole-line first-match probes vs the grammar (informational)

Deliberately simple searches over the whole line, compared with the answer key on the 992 F2 rows:

| Field | Whole-line probe | Probe correct | Grammar correct | Example failure |
|---|---|---:|---:|---|
| email_address | first token containing `@` | 991 | 992 | EC-015 obfuscated address has no `@` |
| ip_address | first dotted quad | 769 | 992 | EC-062 takes `1.2.3.4` from `agent/1.2.3.4` |
| ip_address | token after the first `from` | 896 | 992 | EC-047 has `client 10.0.0.5`, no `from` |
| resource_url | first `http(s)://` URL | 411 | 992 | EC-003 `db://prod/customers` |
| event_timestamp | first ISO date-time | 199 | 992 | EC-003 Apache CLF timestamp |
| latitude | first number with 2+ decimals | 73 | 992 | EC-003 takes `2.31` from `python-requests/2.31.0` |

### 4.9 F1 regression (run B vs Step 3B-3 run 2)

| Comparison on the 1,528 F1 logs | Rows only in baseline | Rows only in run B |
|---|---:|---:|
| `parsed_log` | 0 | 0 |
| `parsed_field` (15,280 rows each) | 0 | 0 |
| `parsed_secondary` | 0 | 0 |

F1 accuracy in the new run: 15,280 / 15,280 in value and validity.

### 4.10 Determinism and integrity

- Run A vs run B: 0 differing `parsed_log`, `parsed_field` and `parsed_secondary` rows; equal row counts.
- `verify_raw_access_logs()`: 10 / 10 before and after both runs (also recorded in `parser_run`).
- Step 1 files: `generate_raw_logs.py --check` reports all three files identical;
  `raw_csv_digest.py` dataset digest `1bcff42a6cd6634bd722064b629a0088dbbd7c67ac5276d013c505ac3fb06275` unchanged.
- All new and changed SQL / PowerShell files are ASCII; NBSP, degree and prime characters are written as `\u00A0`,
  `\u00B0`, `\u2032`, `\u2033` escapes.

### 4.11 Example: EC-047 (epoch, log level, lower-case entity, trailing clauses in parentheses)

`1773480137 WARN user guest_4471@example.com access NOT granted to https://intranet.example.com/hr/payroll (tool: curl/8.4.0; client 10.0.0.5, via 203.0.113.9) status=200`

| Field | Value | Pos | Slot | Rule |
|---|---|---:|---|---|
| event_timestamp | `1773480137` | 1 | F2.prefix.timestamp | VS-6 VAL-TS |
| entity_type | `user` | 17 | F2.entity | VS-6 VAL-ENT |
| email_address | `guest_4471@example.com` | 22 | F2.actor | VS-6 VAL-EML |
| action_phrase | `access NOT granted to` | 45 | F2.phrase | VS-6 VAL-ACT |
| resource_url | `https://intranet.example.com/hr/payroll` | 67 | F2.resource | VS-6 VAL-RES |
| tool | `curl/8.4.0` | 114 | F2.trailing.tool | VS-6 VAL-TL |
| ip_address | `10.0.0.5` | 133 | F2.trailing.client | VS-6 VAL-IP |
| status | `200` | 167 | F2.trailing.status_key | VS-6 VAL-STS |
| latitude, longitude | MISSING | — | — | VS-1 absent |
| secondary `proxy_ip` | `203.0.113.9` | 147 | F2.trailing.via | — |

`WARN` is consumed as a log level, so it is neither the entity nor part of it.

---

## 5. Issues found while implementing

| Issue | Fix |
|---|---|
| `detect_format` character classes were typed with literal NBSP characters | Replaced by `\u00A0` escapes; files re-scanned for non-ASCII (0) |
| The verdict block of `sql/16` used the variable name `overlaps`, a reserved word | Renamed. The first test run (parser runs 3 and 4) printed all report sections and then stopped at the verdict; the re-run (runs 5 and 6) passed. Both reports are identical apart from run ids and timings |

`parser_run` now holds runs 1–2 (Step 3B-3, `{F1}`, regression baseline), 3–4 (first Step 3B-4 test run) and 5–6
(final). The evaluation views use the latest successful run (6).

## 6. Choices made in this step (for review)

1. **DET-F2 is a fallback:** it is evaluated only when DET-F1 did not match (Step 3A §4.2 order). Once DET-F3/F4/F5
   exist, they will be evaluated before it in the same way.
2. **Template-C brackets are classified by content:** a known entity type is the entity; otherwise the first bracket is
   the status. This covers `[OK] [USER] …`, `[USER] …` and `[OK] User …`.
3. **Bounded scans:** the actor must be within 3 tokens of the prefix, the resource within 12 tokens of the actor or
   the last template-C clause, and the trailing scanner stops after 50 clauses.
4. **Sentence-end status forms:** `- CODE Reason` and `result X` are recognised only when they end the event; `[word]`,
   `- status: X` and `status=X` anywhere in the trailing part. The first status wins (C-01).
5. **Ports:** an IPv4 `:port` is split for client and proxy addresses; a proxy port would be `proxy_port` (none in the
   data).
6. **EC-110 `keyword_in_resource`** is left as an informational secondary-value difference, like the four F1
   differences reported in Step 3B-3.
