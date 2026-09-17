# Step 3B-6 — F4 Parser (web-server access log)

**Status:** implemented and tested (12/09/2026). Stopped for review.

**Result:** all **9,860 / 9,860** F4 field values (986 rows × 10 fields) match the answer key in **value and
validity** — the C-05 target for F4.

- Detection is exact: 986 true positives, 0 false positives, 0 format conflicts.
- The fixed positions are parsed first and in order; every quoted value is delimited by its own quotes.
- Entity values with spaces are complete, and extras are cut only at known-key boundaries.
- Every value is the exact substring at its recorded position.
- The IP rule, X-Forwarded-For precedence and `POINT(lon lat)` order follow the finalized rules.
- Runs are deterministic, and the raw input is unchanged.

**F1, F2 and F3 unchanged:** the 3,505 F1–F3 rows of the new run are identical to the Step 3B-5 run in `parsed_log`,
`parsed_field` and `parsed_secondary` (0 differing rows). F1 stays at 15,280 / 15,280, F2 at 9,920 / 9,920 and F3 at
9,850 / 9,850.

**Not included:** F5 parsing, JSON/JSONB, PostGIS. The raw input table was not modified.

---

## 1. What was built

All objects are in database `postgresql_regex_task`, schema `log_regex`.

| Layer (Step 3A §2) | Object | Change in this step |
|---|---|---|
| L1 reference | `ref_key_alias` | 10 F4 extras keys (8 primary, 2 coordinate pairs); `ref_data_version` = `3B-6.1` |
| L2 parser, F4 | `f4_candidates` | new: fixed positions, quoted fields, known-key extras, precedence rules |
| L2 parser, shared | `detect_format` (+ DET-F4), `run_parser` (F4 candidates, F4 sub-format, truncation) | patched in `sql/15` |
| L2 parser, F1–F3 | `f1_candidates`, `f2_candidates`, `f2_ip_candidates`, `f3_candidates` | unchanged (`f2_ip_candidates` is reused for the IPv4:port split) |
| L3 output / L4 evaluation | tables and views | unchanged; earlier runs kept |

## 2. Files and how to run

| File | Purpose | Re-runnable |
|---|---|---|
| [sql/20_parser_reference_data_f4.sql](../sql/20_parser_reference_data_f4.sql) | F4 extras keys (also the boundary list), reference-data version | yes (replaces the F4 rows) |
| [sql/21_parser_f4.sql](../sql/21_parser_f4.sql) | `f4_candidates()` | yes |
| [sql/15_parser_core.sql](../sql/15_parser_core.sql) | `detect_format()` with DET-F4, `run_parser()` for F1–F4 (changed by an asserted text patch, not a rewrite; extended for F5 in Step 3B-7, see [Step3B7_F5_Parser.md](Step3B7_F5_Parser.md)) | yes |
| [sql/22_test_f4_parser.sql](../sql/22_test_f4_parser.sql) | Two parser runs, the F4 report, F1–F3 regression, invariants and verdict | yes (adds two runs) |
| [sql/run_step3b6_f4_parser.ps1](../sql/run_step3b6_f4_parser.ps1) | Answer-key hash check, Step 3B-5 object check, then 20, 21, 15, 11, 22 | yes |
| [sql/run_step3b3_f1_parser.ps1](../sql/run_step3b3_f1_parser.ps1), [run_step3b4](../sql/run_step3b4_f2_parser.ps1), [run_step3b5](../sql/run_step3b5_f3_parser.ps1) | Changed: also install 20 and 21 before 15, because `run_parser()` now calls `f4_candidates()` | yes |

```powershell
# PGHOST, PGPORT, PGUSER, PGPASSWORD set in the environment
powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b6_f4_parser.ps1"
```

The 3B-6 runner does not re-run `sql/07` or `sql/08`. The Step 3B-5 run (formats `{F1,F2,F3}`) therefore stays in
`parser_run` as the regression baseline. The three older runners were updated but not re-run in this step.

A parser run on its own: `SELECT log_regex.run_parser('3B-6 F1-F4 v1');` (returns the `run_id`).

---

## 3. How the F4 parser works

### 3.1 Detection (S0/S1)

| Order | Rule | Condition on the event line | Result |
|---:|---|---|---|
| 0 | DET-00 | `raw_log` NULL, empty or whitespace only | NONE |
| 1 | DET-F4 | Three space-separated tokens (IP field, ident, remote user), a `[…]` bracket, then a quoted request field that is `"METHOD target HTTP/n.n"` or `"-"` | F4 |
| 2 | DET-F3 | `{` followed by `"` | F3 (unchanged) |
| 3 | DET-F1 | Two `key=` segments | F1 (unchanged) |
| 5 | DET-F2 | Fallback sentence cues | F2 (unchanged) |
| — | DEFERRED | F5 and DET-NONE not implemented yet | no field rows |

DET-F4 has the highest priority, as in Step 3A §4.2. It does not validate the IP token, so the malformed leading
addresses (`192.168.222`, `203.0.113.167.65`) are still F4. The 8 F2 sentences that contain `[…] "` start with the
bracket, not with three tokens, so they do not match. `format_candidates` lists every structural match; there are
no conflicts.

### 3.2 Fixed positions first (S3, Step 3A §7.4 slots 1–9)

One cursor moves left to right; each slot is matched by a pattern anchored at the cursor:

| # | Slot | Pattern idea | Field (slot_id) |
|---:|---|---|---|
| 1 | IP field | first token | ip_address (`F4.ip_field`) |
| 2 | ident | second token (`-`) | — |
| 3 | remote user | third token | email_address candidate (`F4.remote_user`) |
| 4 | `[timestamp]` | `[` … `]` (spaces allowed inside) | event_timestamp (`F4.timestamp`), brackets excluded |
| 5 | `"request"` | `"METHOD target HTTP/n.n"`: the target ends before the last ` HTTP/n.n` in front of the closing quote; or `"-"` | resource_url (`F4.request.target`, or `F4.request` for `-`) |
| 6 | status | the token after the request (lenient: `20O`, `-`) | status (`F4.status`) |
| 7 | bytes | next token | — (never status or timestamp) |
| 8 | `"referer"` | `"` … `"` | secondary `referer_url` unless `-` (never the resource) |
| 9 | `"user agent"` | `"` … `"`; not closed before the end of the event ⇒ truncated | tool (`F4.user_agent`); a URL inside ⇒ secondary `url_in_tool` |

### 3.3 Quoted values

A quoted field ends at its own closing double quote and the quotes are not part of the value. This covers the request
line, referer, user agent, `msg="…"` and `xff="…"`. Text inside a quoted field is never read as another slot or key.
EC-029's target `/login?user=admin'--&pass=x` stays the resource, and its `user=` is not an email. A user agent with
no closing quote is extracted up to the end of the event and marks the row as truncated (EC-136).

### 3.4 Extras: known-key boundaries (slot 10)

After the user agent, the rest of the line is split where each known key starts:

| Key (`ref_key_alias`, F4) | Field | Value handling |
|---|---|---|
| `type=`, `entity=`, `role=` | entity_type | runs to the next known key: `Service Account`, `API Client` keep their spaces |
| `user=` | email_address | `<` `>` excluded |
| `lat=`, `lon=` | latitude, longitude | labelled |
| `loc=` | longitude, latitude | `POINT(lon lat)` — **longitude first** (C-03) |
| `geo=` | latitude, longitude | `lat,lon` — latitude first (C-03); a token without a comma applies to both axes |
| `xff=` | ip_address | quoted list; the first entry is the original client (D-03) |
| `msg=` | action_phrase | quoted; quotes excluded |

An unquoted value ends where ` <known key>=` starts (the key list comes from the reference table). A value that
starts with `"` ends at its closing quote. Text that does not start with a known key gives the diagnostic
`unrecognised_text` (none in the data).

### 3.5 Precedence and secondary values (Step 3A §7.4, §8.2)

| Field | Rule |
|---|---|
| email_address | `user=<…>` when present; otherwise the remote-user slot. A remote-user `-` without `user=` is PLACEHOLDER (AMB-10) |
| ip_address | first `xff` entry when present, with the IP field as secondary `proxy_ip`; otherwise the IP field |
| IP field forms | IPv4 · IPv4`:port` · bare IPv6 (no port parsing) · `[IPv6]:port`; the port is secondary `client_port` |

Other secondary values: `referer_url`, `url_in_tool`, and the shared IPv4 look-alike rule for the resource and user
agent (`ip_like_in_resource`, `ip_like_in_tool`).

### 3.6 Value state, truncation and validation (S5–S7)

| Order | Rule | F4 result |
|---:|---|---|
| VS-1 | Key or slot absent | MISSING, `missing_reason` absent |
| VS-4 | `-` in the remote-user, request, status or user-agent slot | PLACEHOLDER |
| VS-5 | Truncated row: the last extracted value | INVALID, `rule_id` `VS-5 truncated (unclosed quote)` |
| VS-6 | Field validators unchanged; exact Step 3B-2 IP rule | VALID / INVALID |

Truncation (Step 3A §10.3): the value cut off inside its quote is INVALID; the fields after it are MISSING;
`record_validity` = BROKEN. `sub_format` records the IP-field form: `ipv4`, `ipv4-port`, `ipv6`, `ipv6-bracket-port`.

---

## 4. Results

PostgreSQL 17.9; two parser runs (A = run 9, B = run 10) on identical input: 17.62 s and 18.92 s for all 5,000 rows
(Step 3B-5 with F1–F3: about 12.8 s).

### 4.1 Detection (all 5,000 rows)

| Answer key | Parsed | Rule | Rows |
|---|---|---|---:|
| F1 / F2 / F3 | same | DET-F1 / DET-F2 / DET-F3 | 1,528 / 992 / 985 |
| F4 | F4 | DET-F4 | 986 |
| F5 | deferred | — | 500 |
| NONE | deferred / NONE | — / DET-00 | 5 / 4 |

F4: 986 true positives, **0 false positives**, 0 false negatives. F1–F3 detection unchanged (0 errors).
`format_conflict`: 0.

### 4.2 Output shape and positions (run B)

| Check | Result |
|---|---|
| `parsed_log` rows / raw rows without one | 5,000 / 0 |
| F1 / F2 / F3 / F4 / DET-00 / deferred logs | 1,528 / 992 / 985 / 986 / 4 / 505 |
| `parsed_field` rows; parsed logs without exactly 10 fields | 44,950; 0 |
| Field values equal to `substr(raw_log, start_pos, length)` | 42,604 / 42,604 |
| Secondary values equal to their substring | 1,098 / 1,098 |
| Overlapping value spans in one F4 log | 0 |

### 4.3 Per-field accuracy on all F4 rows

| Field | Rows | Value match | Validity match | Both |
|---|---:|---:|---:|---:|
| entity_type | 986 | 986 | 986 | 986 |
| email_address | 986 | 986 | 986 | 986 |
| resource_url | 986 | 986 | 986 | 986 |
| event_timestamp | 986 | 986 | 986 | 986 |
| tool | 986 | 986 | 986 | 986 |
| latitude | 986 | 986 | 986 | 986 |
| longitude | 986 | 986 | 986 | 986 |
| ip_address | 986 | 986 | 986 | 986 |
| action_phrase | 986 | 986 | 986 | 986 |
| status | 986 | 986 | 986 | 986 |
| **All fields** | **9,860** | **9,860** | **9,860** | **9,860 (100.00%)** |

Mismatches: none.

### 4.4 Validity distribution on F4 rows (answer key = parser in every cell)

| Field | VALID | INVALID | PLACEHOLDER (`-`) | MISSING (absent) |
|---|---:|---:|---:|---:|
| entity_type | 918 | 3 | 0 | 65 |
| email_address | 908 | 7 | 71 | 0 |
| resource_url | 933 | 5 | 48 | 0 |
| event_timestamp | 974 | 12 | 0 | 0 |
| tool | 885 | 1 (truncated, EC-136) | 100 | 0 |
| latitude | 825 | 6 | 0 | 155 |
| longitude | 834 | 4 | 0 | 148 |
| ip_address | 979 | 7 | 0 | 0 |
| action_phrase | 985 | 0 | 0 | 1 (EC-136) |
| status | 921 | 5 | 60 | 0 |

### 4.5 By IP-field form and source

| Group | Logs | Field values | Both match | IP INVALID | Client ports |
|---|---:|---:|---:|---:|---:|
| `ipv4` | 457 | 4,570 | 4,570 | 6 | 0 |
| `ipv4-port` | 321 | 3,210 | 3,210 | 0 | 321 |
| `ipv6` | 128 | 1,280 | 1,280 | 1 | 0 |
| `ipv6-bracket-port` | 80 | 800 | 800 | 0 | 80 |
| curated | 16 | 160 | 160 | — | — |
| generated | 970 | 9,700 | 9,700 | — | — |

**Record validity:** BROKEN 1 = 1 (EC-136, `is_truncated`), INVALID 46 = 46, VALID 939 = 939.

### 4.6 Fixed positions, quoted values, entity spaces and key boundaries

| Check | Result |
|---|---|
| F4 logs with all four positional slots (timestamp, request, status, user agent) | 986 / 986 |
| Logs where timestamp < request < status < user agent does not hold | 0 |
| Logs with an extras value starting before the end of the user agent | 0 |
| Quoted values (request `-` 48, user agent 986, `msg` 985) delimited by their own quotes | 2,019 / 2,019 |
| Extracted quoted values containing a double quote | 0 |
| Request targets not followed by ` HTTP/` | 0 |
| Entity `Service Account` / `API Client` (with spaces) | 81 / 81, 48 / 48 |
| Rows whose request target or user agent contains a key-like `name=` (e.g. EC-029 `?user=admin`) | 29 rows; 290 / 290 field values correct |

Slot usage (run B):
- email: `user=` 564, remote-user slot 422
- entity: `type=` 459, `entity=` 262, `role=` 200
- IP: IP field 985, `xff` 1
- resource: request target 938, `"-"` 48
- coordinates: `loc` 334, `geo` 284, `lat=` 213, `lon=` 220

### 4.7 Coordinate order by container (C-03)

| Container | Latitude (both match) | Longitude (both match) |
|---|---:|---:|
| `loc=POINT(lon lat)` | 334 / 334 | 334 / 334 |
| `geo=lat,lon` | 284 / 284 | 284 / 284 |
| `lat=` / `lon=` | 213 / 213 | 220 / 220 |
| absent | 155 / 155 | 148 / 148 |

In the 334 POINT rows the first number never equals the answer-key latitude (0 / 334). The parser reads `POINT(lon lat)`
and is correct in 334 / 334.

### 4.8 Truncated, long and multi-address lines

| Case | Parsed |
|---|---|
| EC-136 — line ends inside the user agent | IP, timestamp, resource `/reports/q2`, status `200` VALID; email `-` PLACEHOLDER; tool `Mozilla/5.0 (Windows NT 10.0; Win` INVALID (VS-5 unclosed quote); entity, coordinates, action MISSING; `is_truncated`, diagnostic `truncated`, BROKEN |
| EC-145 — 2,289-character line | request target of 2,107 characters VALID; user agent at 2,186, `user=` at 2,216, `type=` at 2,259, `msg` at 2,275 — all exact |
| EC-103 — `xff="203.0.113.5, 10.0.0.1"` | ip `203.0.113.5` (`F4.extras.xff[1]`, position 158); secondary `proxy_ip=10.0.0.1` (position 1) |
| EC-097 — `[2001:db8::1]:443` | ip `2001:db8::1` (position 2, brackets excluded); secondary `client_port=443` |
| EC-029 — `?user=admin'--` in the target, URL in the agent | email `-` PLACEHOLDER from the remote-user slot; resource `/login?user=admin'--&pass=x`; secondary `url_in_tool=https://sqlmap.org` |

### 4.9 Whole-line first-match probes vs the positional grammar (informational)

| Field | Whole-line probe | Probe correct | Parser correct | Example failure |
|---|---|---:|---:|---|
| email_address | value after the first `user=` | 564 | 986 | EC-029 takes `admin'--` from the request target |
| ip_address | first dotted quad | 774 | 986 | EC-097 `[2001:db8::1]:443` has none |
| resource_url | first `http(s)://` URL | 508 | 986 | EC-006 relative target `/catalog/items/5521` |
| status | first stand-alone 3-digit number | 902 | 986 | EC-126 `20O` |
| entity_type | single word after `type=`/`entity=`/`role=` | 857 | 986 | GEN-00130 `API` instead of `API Client` |
| latitude | first number after `POINT(` / `geo=` / `lat=` | 652 | 986 | EC-064 takes the POINT longitude `3.3792` |

### 4.10 Secondary values (informational; not part of C-05)

983 / 986 F4 logs have exactly the answer key's secondary set:

| Kind | Values |
|---|---:|
| `client_port` | 401 |
| `referer_url` | 191 |
| `ip_like_in_tool` | 253 |
| `ip_like_in_resource` | 74 |
| `url_in_tool` | 1 (EC-029) |
| `proxy_ip` | 1 (EC-103) |

The three differences are EC-063, EC-085 and EC-142 (EC-142 is the exact duplicate of EC-085). In each, the parser
also reports `ip_like_in_tool=124.0.0.0` from the `Chrome/124.0.0.0` user agent. Generated rows with the same user
agent carry this annotation in the answer key, but these hand-written curated rows do not: 253 parsed − 3 = the 250
expected. Diagnostics on F4 rows: `truncated` (EC-136) only.

### 4.11 F1 + F2 + F3 regression (run B vs Step 3B-5 run 8)

| Comparison on the 3,505 F1–F3 logs | Rows only in baseline | Rows only in run B |
|---|---:|---:|
| `parsed_log` | 0 | 0 |
| `parsed_field` (35,050 rows each) | 0 | 0 |
| `parsed_secondary` | 0 | 0 |

Accuracy in the new run: F1 15,280 / 15,280, F2 9,920 / 9,920, F3 9,850 / 9,850.

### 4.12 Determinism and integrity

- Run A vs run B: 0 differing rows in all three output tables; equal row counts.
- `verify_raw_access_logs()`: 10 / 10 before and after both runs.
- Step 1 files: `generate_raw_logs.py --check` reports all three files identical; dataset digest
  `1bcff42a6cd6634bd722064b629a0088dbbd7c67ac5276d013c505ac3fb06275` unchanged.
- All new and changed SQL / PowerShell files are ASCII.

`parser_run` now holds runs 1–2 (`{F1}`), 3–6 (`{F1,F2}`), 7–8 (`{F1,F2,F3}`) and 9–10 (`{F1,F2,F3,F4}`). The
evaluation views use run 10. The test passed on its first run.

---

## 5. Choices made in this step (for review)

1. **DET-F4 shape:** three tokens, a `[…]` bracket and a quoted request field (`METHOD target HTTP/n.n` or `-`) on the
   event line. It is evaluated first; the IP token is not validated during detection.
2. **Boundary list = reference data:** the extras keys in `ref_key_alias` are both the field aliases and the cut
   points. A new key only needs a new row.
3. **X-Forwarded-For:** only the first entry is used (the original client). The IP field becomes `proxy_ip`; later
   entries are not stored (in EC-103 the second entry repeats the IP field).
4. **Both email sources present** (not in the data): `user=<…>` wins, and a non-`-` remote-user token is kept as
   secondary `remote_user_email`.
5. **IP token helper:** the IPv4:port split reuses `f2_ip_candidates()` from Step 3B-4. Bare IPv6 is never split. A
   two-group all-digit IPv6 such as `1234:5678` would be read as IPv4:port (not in the data). A neutral name for the
   shared helper could be a later clean-up.
6. **`url_in_tool`** is produced by the F4 extractor only: the first `http(s)://` URL inside the user agent.
7. **Truncation label:** `VS-5 truncated (unclosed quote)` for F4; the F1 (`C-06`) and F3 (`unclosed JSON`) labels
   are unchanged.
8. **Not stored:** the ident and bytes slots, and the HTTP method and version.
9. **Runtime:** about 12.8 s → 18 s for 5,000 rows with four PL/pgSQL extractors; performance is a later part of the
   project.
