# Step 1 — RAW LOG Sample Data

Reproducible sample data for the PostgreSQL Regex Task. This step only **creates** the data:
it does not load anything into PostgreSQL and does not contain any extraction SQL.

---

## 1. Files

| File | Purpose |
|---|---|
| `data/raw_access_logs.csv` | **The RAW LOGS.** Two columns: `log_id`, `raw_log`. Never edited after generation. |
| `data/expected_fields.csv` | Answer key: the expected value and validity of each of the 10 target fields, per `log_id`. |
| `data/dataset_manifest.json` | Seed, settings, row counts, distributions and SHA-256 checksums. |
| `data/generate_raw_logs.py` | Seeded generator (Python standard library only). Writes the three files above. |
| `data/curated_edge_cases.py` | The 150 fixed, hand-written edge cases (`EC-001` … `EC-150`). |

### Regenerate / verify

```bash
cd "PostgreSQL Regex Task/data"
python generate_raw_logs.py            # writes the 3 data files (Python >= 3.9.5)
python generate_raw_logs.py --check    # regenerates in memory; exit 0 only if all 3 files are byte-identical
```

Every run also executes an answer-key self-check (below) and refuses to write files if it fails.

---

## 2. RAW LOG file format

```text
log_id,raw_log
1,"2026-05-20T13:05:51Z | entity=USER | user=emma.zhang@example.com.au | ..."
```

- UTF-8 without BOM, LF record separators.
- `raw_log` is **always double-quoted**; embedded quotes are doubled.
- An **unquoted empty** value means SQL `NULL`; `""` means an empty string. This matches
  PostgreSQL `COPY … CSV HEADER` semantics, so a later load step keeps the distinction.
- Quoted values may contain LF, CR, tabs, non-breaking spaces, ANSI escapes and non-ASCII text.
  No value contains a NUL byte (PostgreSQL `TEXT` cannot store `0x00`).

---

## 3. Answer key (`expected_fields.csv`)

| Column | Meaning |
|---|---|
| `log_id` | Join key to `raw_access_logs.csv`. |
| `case_id` | `EC-###` for curated edge cases, `GEN-#####` for generated rows. |
| `source` | `curated` or `generated`. |
| `format_family` | `F1`–`F5` (section 5), or `NONE` for rows with no recognisable format. |
| `outcome_class` | Outcome expressed by the action phrase: `SUCCESS`, `DECLINED`, `NEUTRAL`, or `NONE` when no phrase exists. |
| `record_validity` | `VALID`, `INVALID` (at least one field is `INVALID`) or `BROKEN` (null, empty, junk, header, truncated). |
| `<field>` + `<field>_validity` | One pair per target field (below). |
| `secondary_values` | Other candidates for a field, e.g. `proxy_ip=…`, `referer_url=…`, `ip_like_in_resource=…`. |
| `scenario_tags` | `;`-separated variant/edge-case tags. |
| `notes` | Explanation for curated edge cases. |

**Target fields:** `entity_type`, `email_address`, `resource_url`, `event_timestamp`, `tool`,
`latitude`, `longitude`, `ip_address`, `action_phrase`, `status`.

### Rules (no normalization)

- The expected value is the **exact substring of `raw_log`** as written — original case, units,
  hemisphere letters, offsets and formats are kept. Surrounding delimiters are not part of the
  value: quotes, `[ ]`, `< >`, `key=` labels, `mailto:`, `:port` suffixes, a sentence-ending `.`.
- Validity states:

  | State | Meaning | Example |
  |---|---|---|
  | `VALID` | Present and well-formed | `192.168.10.45` |
  | `INVALID` | Present but malformed or out of range | `256.10.1.300`, `2026-02-30 10:15:00`, `lat=91.2500` |
  | `PLACEHOLDER` | A token standing in for "no value" | `-`, `N/A`, `unknown`, `NULL`, JSON `null` |
  | `MISSING` | Not in the log, or an empty value (`status=`) | value column is empty |

- When a log contains several candidates for one field, the key holds the primary one
  and lists the rest in `secondary_values`. Confirmed rules: the acting person's email, the event
  timestamp (not an ingestion timestamp), and the original client IP (first X-Forwarded-For entry).
  See `docs/Step2_Requirements_and_Variants.md` §1.
- Nothing is converted: no UTC timestamps, no status mapping, no lat/lon reordering.
  `outcome_class` is a scenario label, not a normalized `status`.

### Self-check performed on every generation

- Every non-empty expected value is a substring of its `raw_log`.
- `MISSING` ⇔ empty value.
- `VALID`/`INVALID` labels agree with independent checks for IPs (`ipaddress` module),
  decimal coordinates (range ±90/±180) and email shape (ASCII, no `..`).
- `outcome_class = NONE` ⇔ `action_phrase` is `MISSING`.

---

## 4. Dataset composition (seed 20260911, 5,000 rows)

| | Rows |
|---|---:|
| Curated hand-written edge cases | 150 |
| Generated rows | 4,850 |
| **Total** | **5,000** |

Curated rows are interleaved at seeded positions (not grouped at the top).

### Format distribution

| Format | Generated | Curated | All | % of all |
|---|---:|---:|---:|---:|
| F1 pipe `key=value` | 1,455 | 73 | 1,528 | 30.6% |
| F2 sentence | 970 | 22 | 992 | 19.8% |
| F3 syslog + JSON | 970 | 15 | 985 | 19.7% |
| F4 web access log | 970 | 16 | 986 | 19.7% |
| F5 semicolon legacy | 485 | 15 | 500 | 10.0% |
| NONE (null/empty/junk/header) | 0 | 9 | 9 | 0.2% |

Generated formats are exact quotas (30/20/20/20/10%).

### Outcome distribution

| outcome_class | Generated | Curated | All | % of all |
|---|---:|---:|---:|---:|
| SUCCESS | 2,668 | 85 | 2,753 | 55.1% |
| DECLINED | 1,697 | 43 | 1,740 | 34.8% |
| NEUTRAL | 485 | 9 | 494 | 9.9% |
| NONE | 0 | 13 | 13 | 0.3% |

Generated outcomes are exact quotas (55/35/10%). 42 rows (39 generated + 3 curated) carry a
status that contradicts the action phrase (`status_action_conflict`).

### Record validity

| record_validity | Generated | Curated | All |
|---|---:|---:|---:|
| VALID | 4,644 | 106 | 4,750 |
| INVALID | 206 | 32 | 238 |
| BROKEN | 0 | 12 | 12 |

### Field validity (all rows)

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

Generation settings: absent (missing or placeholder) probability entity 7%, email 8%, resource 5%,
tool 10%, status 6%, coordinates 15% (80% both axes, 20% one axis); one injected invalid value in
5% of rows (206 rows = 4.2% in this seed); status/phrase conflict 1% of success/declined rows.

---

## 5. Log formats

**F1 — pipe-separated `key=value`** (key names, quoting, separators and field order vary)
```text
2026-05-20T13:05:51Z | entity=USER | user=emma.zhang@example.com.au | action=access granted | resource=/reports/weekly?id=7059 | tool=Edge/124.0.2478.67 | ip=2001:db8:9e6b:efca::3ffa | lat=-23.54065 | lng=-46.63302 | outcome=success
```

**F2 — natural-language sentence** (three sentence templates)
```text
[25/Feb/2026:22:56:16 +1000] [CUSTOMER] "Meera Iyer" <meera.iyer@customers.example.net> was permitted to access https://shop.example.org/wishlist via Chrome/124.0.6367.91 from 203.0.113.52 (-33.8443, 151.1608) - 200 OK
```

**F3 — syslog header (RFC 3164 or RFC 5424) + JSON payload**
```text
<110>1 2026-01-28T10:22:31.460Z auth-gw01 authd 9155 AUDIT - {"entity_type":"user","principal":"olivia.rao@corp.example.com","target":"/timesheets?id=2679","user_agent":"MobileSafari/17.4.1","src_ip":"192.168.58.66","latitude":35.7068,"longitude":139.6152,"event":"access granted","result":"success"}
```

**F4 — web access log (combined format + `key=value` extras)**
```text
192.0.2.115 - - [02/Jan/2026:07:53:34 +0530] "PUT /profile/settings?id=5669 HTTP/1.1" 302 26434 "-" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36" type=User user=<kenji.silva+alerts@example.com.au> loc=POINT(72.895837 19.107710) msg="Session started"
```

**F5 — semicolon-positional legacy export**
`timestamp;entity;email;tool;resource;latitude;longitude;ip;action;status`
```text
6/28/2026 9:29 PM;USER;;;https://portal.corp.example.com/dashboard#summary;12°58'41.5"N;77°35'46.7"E;198.51.100.14;Access declined;DENIED
```

---

## 6. Field variant catalog

| Field | Valid variants | Missing / invalid / trap variants |
|---|---|---|
| **Entity Type** | USER, CUSTOMER, ADMIN, SERVICE_ACCOUNT, API_CLIENT, GUEST, BOT; upper/lower/title case; `service_account` / `service-account` / `Service Account`; keys `entity=`, `entity_type=`, `type=`, `role=`, JSON keys; `[ADMIN]` prefix | Absent; `N/A`, `-`; unknown values (`contractor`, `VENDOR`, `superuser`, `intern`) |
| **Email** | dots, digits, `_`, `-`, `+tag`, middle initials, subdomains, `.co.uk`/`.gov.in`/`.com.au`, UPPERCASE; wrapped in `<>`, `mailto:`, `"Display Name" <…>`, combined-log remote-user slot | Absent (`anonymous`); `-`, `unknown`; `..`, `@@`, no TLD, no local part, no `@`, leading/trailing dot, space inside, `[at]`/`[dot]` obfuscation, non-ASCII; two emails in one line |
| **Resource / URL** | https/http with port, query, fragment; relative paths; `ftp://`, `s3://`, `db://`, `postgres://`, custom `vpn://`; Windows and UNC paths (with spaces), Linux paths; `%20` encoding; absolute URLs in request lines | Absent; `-`; `htps://`, `http//`, `https:///`, `ftp:/`; truncated; trailing sentence `.`; wrapped in `( ),`; SQL injection; embedded credentials; IP host; dates and IP-like versions inside paths; referer URL next to resource |
| **Timestamp** | ISO 8601 `Z`/offset/ms/µs, lowercase `t`/`z`; `YYYY-MM-DD HH:MM:SS[.mmm]`; Apache `DD/Mon/YYYY:HH:MM:SS ±HHMM`; `MM/DD/YYYY hh:mm:ss AM`; `M/D/YYYY h:mm PM`; syslog `Mon dd` with space-padded day and no year; RFC 5424; `DD-MM-YYYY HH:MM[:SS]`; `YYYY/MM/DD`; compact `YYYYMMDDTHHMMSS`; epoch seconds and milliseconds; `IST` abbreviation | Absent; Feb 30, Apr 31, Feb 29 (2026), month 13, `25:61`, `13:05 PM`; ambiguous day/month order (231 rows tagged); two timestamps in one line |
| **Tool** | Short browser tokens, full user-agent strings (Chrome, Firefox, Safari, Edge, iPhone), curl, Wget, aws-cli (short and compound UA), Boto3, python-requests, okhttp, Go-http-client, Postman, PostmanRuntime, Insomnia, Terraform, Ansible, kubectl, psql, OpenSSH, kube-probe, Prometheus, smbclient, sqlmap | Absent; `-`, `unknown`; truncated UA; IP-looking versions (`agent/1.2.3.4`, `Chrome/124.0.0.0`); URL inside the tool string |
| **Latitude / Longitude** | Signed decimals (2–7 dp); `lat/lon`, `lat/lng`, `latitude/longitude`; `geo=lat,lon`; `(lat, lon)`; JSON object; JSON `"lat,lon"` string; hemisphere suffix `51.5074 N` and prefix `N51.5074`; DMS `19°04'33.6"N`, DMS with Unicode primes; WKT `POINT(lon lat)`; GeoJSON `[lon, lat]`; boundaries ±90/±180; `0,0` | Absent (both or one axis); `N/A`, `-`, `NULL`, JSON `null`; out of range; `NaN`; decimal comma `48,8566`; swapped values; negative sign plus `S` |
| **IP Address** | Private and documentation IPv4; IPv4 `:port`; IPv6 full, compressed, short, IPv4-mapped, loopback, link-local with zone `%eth0`, `[v6]:port` | Absent; `-`; octet > 255, 3 or 5 octets, leading zeros, double `::`, non-hex; X-Forwarded-For chain; proxy IP next to client IP |
| **Action / Access Phrase** | Success (granted, allowed, permitted, authenticated, login successful, session started); declined (denied, refused, rejected, declined, blocked by policy/WAF, forbidden, unauthorized attempt, failed to authenticate); neutral (logout, MFA challenge, password reset, token expired, session timeout, rate limited, not found, server error) | Absent; negation `NOT granted`; double negation `not denied`; `granted after 2 failed attempts`; mixed case; delimiter inside the quoted phrase; a second phrase in a stack trace or retry field; outcome words inside resource names |
| **Status** | SUCCESS/FAILED/DENIED/BLOCKED/ALLOWED/REJECTED/PASS/PENDING/EXPIRED/THROTTLED…, lowercase variants; HTTP codes, `403 Forbidden`, `status: X`, `[OK]`; JSON string or number; keys `status`, `result`, `outcome`, `http_status`; `✓` | Absent; `status=`; `-`, `N/A`; typos `SUCCES`, `FAILD`; invalid codes `999`, `20O`, `4O3`, `600`; two status values; status contradicting the phrase |

### Whole-record edge cases (curated)

SQL `NULL`; literal text `NULL`; empty string; whitespace only; whitespace with CR/LF; three
truncated lines (F1, F3, F4); two header rows; two junk rows (`#####`, ANSI escapes + mojibake);
two exact duplicates; multi-line stack trace; multi-line pretty-printed JSON; a 2,289-character
line; tab-delimited fields; non-breaking spaces around delimiters; CRLF line ending; leading and
trailing spaces; `|` inside a quoted value.

### Curated edge-case index

| Range | Focus | Count |
|---|---|---:|
| EC-001 – EC-010 | Entity Type | 10 |
| EC-011 – EC-026 | Email Address | 16 |
| EC-027 – EC-042 | Resource / URL | 16 |
| EC-043 – EC-060 | Timestamp | 18 |
| EC-061 – EC-070 | Tool | 10 |
| EC-071 – EC-090 | Latitude / Longitude | 20 |
| EC-091 – EC-106 | IP Address | 16 |
| EC-107 – EC-118 | Action / Access Phrase | 12 |
| EC-119 – EC-128 | Status | 10 |
| EC-129 – EC-150 | Whole-record | 22 |

Each curated row's `notes` column explains what makes it an edge case.

---

## 7. Reproducibility

- One `random.Random(20260911)` instance drives every generated value, quota shuffle and the
  curated-row positions. No `hash()`, set ordering, clock or environment input is used.
- Standard library only (no Faker or other package whose output changes between versions).
- Event times are drawn from a fixed UTC window, 2026-01-01T00:00:00Z – 2026-06-30T23:59:59Z
  (local-time renderings with offsets can fall a few hours outside it).
- Files are written as bytes with explicit UTF-8 encoding, quoting and `\n` line endings, so the
  output does not depend on the operating system's newline or locale settings.
- `dataset_manifest.json` stores the SHA-256 of both CSV files; `--check` recomputes everything and
  compares byte-for-byte. Changing `--seed` produces a different dataset.

## 8. Data safety

- People are fictional name combinations.
- Domains use `example.*`, `.example`, `.internal` placeholders.
- Every IP address field value is private (RFC 1918), loopback/link-local, or a documentation
  range (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32). Invalid IP tokens are built
  on the same prefixes.
- Version strings that merely look like IPv4 addresses (`Chrome/124.0.0.0`, `releases/2.16.0.68`)
  are deliberate extraction traps and are tagged `ip_like_in_tool` / `ip_like_in_resource`.
