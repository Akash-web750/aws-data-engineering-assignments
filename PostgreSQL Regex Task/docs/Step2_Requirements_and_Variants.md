# Step 2 — Requirements and String Variants

**Scope:** understand and document what the extraction must handle. This step does **not** build
the regex parser. Every count below is measured from the unchanged RAW LOGS against the Step 1
answer key by [`analysis/profile_raw_logs.py`](../analysis/profile_raw_logs.py); the full tables are in
[Step2_Raw_Log_Profile.md](Step2_Raw_Log_Profile.md) (referred to as *Profile §n*).

```bash
python analysis/profile_raw_logs.py   # regenerates analysis/raw_log_profile.json and docs/Step2_Raw_Log_Profile.md
```

Requirement IDs: `G` general · `FMT` formats · `ENT` entity · `EML` email · `RES` resource ·
`TS` timestamp · `TL` tool · `GEO` latitude/longitude · `IP` IP address · `ACT` action phrase ·
`STS` status · `VAL` validity · `AMB` ambiguity rules.

---

## 1. Confirmed decisions

| ID | Decision | Answer-key compliance (Profile §12) |
|---|---|---|
| D-01 | **Email:** extract the acting person's email. Delegated, notified or URL-embedded addresses are secondary. | 3 / 3 rows (EC-021, EC-022, EC-030) |
| D-02 | **Timestamp:** extract the event timestamp, not an ingestion timestamp or a date inside another field. | 136 / 136 rows (EC-056 `ingested_at`; 135 rows with dates inside the resource) |
| D-03 | **Proxy chain:** extract the original client IP — the first X-Forwarded-For entry (or the address introduced as `client` before `via`). | 2 / 2 rows (EC-103, EC-047) |
| D-04 | Other candidate values are preserved in `secondary_values`. | 18 secondary kinds, e.g. `client_port` 463, `ip_like_in_tool` 252, `referer_url` 191 |

Carried over from Step 1 (unchanged):

- Extracted values are **exact substrings** of `raw_log`; no normalization (case, units, order, time zone).
- Surrounding delimiters are not part of a value: quotes, `[ ]`, `< >`, `key=`, JSON keys, `mailto:`,
  `:port`, a sentence-final `.`.
- Each field gets one validity: `VALID`, `INVALID`, `PLACEHOLDER`, `MISSING`.

---

## 2. Extraction contract (what Step 3 must produce)

| ID | Requirement |
|---|---|
| G-01 | For every `log_id`, produce the 10 fields (`entity_type`, `email_address`, `resource_url`, `event_timestamp`, `tool`, `latitude`, `longitude`, `ip_address`, `action_phrase`, `status`), each as *value* + *validity*. |
| G-02 | The value is the exact substring of `raw_log` (original case and spacing, including the double space in `Jan  9`). `MISSING` ⇒ empty value. `PLACEHOLDER` ⇒ the placeholder token itself. |
| G-03 | Never modify `raw_log`; extraction reads it only. |
| G-04 | A SQL `NULL`, empty or whitespace-only `raw_log` yields all 10 fields `MISSING` without error (EC-129, EC-131–133). |
| G-05 | Exactly one primary value per field (rules D-01…D-03, AMB section); other candidates go to `secondary_values`. |
| G-06 | Extraction must not depend on field order except where the format is positional (F5) or fixed (F4 skeleton). F1 alone has 193 distinct field orders (Profile §4). |
| G-07 | Handle non-ASCII text (294 rows), multi-line logs (EC-143, EC-144), CR/LF (EC-133, EC-148), TAB delimiters (EC-146), NBSP around delimiters (EC-147), leading/trailing spaces (EC-149), ANSI/BEL control characters (EC-140) and a 2,289-character line (EC-145). |
| G-08 | For a multi-line log, the fields come from the event itself: line 1 for a stack trace (EC-143), the JSON body across lines for pretty-printed JSON (EC-144). Text after the event (trace lines) is not a field source. |
| G-09 | Results are deterministic and verifiable against `data/expected_fields.csv` (see §9). |

---

## 3. Input characteristics (Profile §1)

| Characteristic | Rows |
|---|---:|
| Total rows | 5,000 |
| SQL NULL / empty string / whitespace only | 1 / 1 / 2 |
| Contains non-ASCII characters | 294 (degree sign 286, `ä` `ü` `é` `ë` `Ï`, primes `′ ″`, `✓`, mojibake, U+FFFD) |
| Multi-line (LF inside the event) | 2 |
| Ends with CR LF | 2 |
| TAB inside / NBSP / leading-trailing whitespace | 1 / 1 / 2 |
| Control characters BEL, ESC | 1 row each |
| Length (non-blank): median / P95 / max | 234 / 336 / 2,289 characters |

---

## 4. Supported formats

### 4.1 Structural features by format (Profile §2)

Share of non-blank logs showing each feature (descriptive, not a detector):

| Feature | F1 (1,528) | F2 (992) | F3 (985) | F4 (986) | F5 (500) | NONE (5) |
|---|---:|---:|---:|---:|---:|---:|
| starts with a digit | 99.9% | 48.7% | 0% | 89.5% | 100% | 0% |
| starts with `[` | 0% | 51.3% | 0% | 8.1% | 0% | 0% |
| starts with syslog `Mon dd HH:` | 0% | 0% | 63.7% | 0% | 0% | 0% |
| starts with `<PRI>VERSION ` | 0% | 0% | 36.3% | 0% | 0% | 0% |
| starts with IP[:port] then ` - ` | 0% | 0% | 0% | 99.7% | 0% | 0% |
| contains `\|` | 99.9% | 0% | 0% | 0% | 0% | 20% |
| 3+ `key=` labels | 99.9% | 0% | 0% | 93.8% | 0% | 0% |
| contains JSON object `{"` | 0% | 0% | 100% | 0% | 0% | 0% |
| quoted HTTP request line | 0% | 0% | 0% | 100% | 0% | 0% |
| 9+ semicolons | 0% | 0% | 0% | 0% | 100% | 20% |
| sentence verb (was/logged/failed/…) | 20.6% | 99.9% | 12.0% | 8.8% | 3.8% | 0% |

| ID | Requirement |
|---|---|
| FMT-01 | Recognise five formats (F1–F5) plus `NONE`. Each has exactly one distinguishing structure: F1 pipe-separated `key=value`, F2 sentence, F3 syslog header + JSON, F4 quoted HTTP request line, F5 ten semicolon-positional columns. |
| FMT-02 | Header rows are `NONE` even though they look like F1 (pipes, EC-137) or F5 (9 semicolons, EC-138): they contain no `key=` labels / no data values. |
| FMT-03 | F1 with TAB delimiters (EC-146) or unspaced `\|` (144 rows) is still F1. |
| FMT-04 | Known outliers: EC-047 is a sentence (F2) that starts with an epoch and contains `status=200`; 3 F4 rows start with a malformed IP (`192.168.222`, `203.0.113.167.65`); truncated rows keep their format (EC-134 F1, EC-135 F3, EC-136 F4). |
| FMT-05 | Sentence verbs are not exclusive to F2 (they occur inside phrases such as `User logged out`, `Authentication failed`). |

### 4.2 F1 — pipe-separated `key=value` (1,528 rows)

```text
<timestamp> | entity=… | email=… | action="…" | resource=… | tool=… | ip=… | lat=… | lon=… | status=…
```

- **Delimiter:** ` | ` (1,381 rows after the timestamp), `|` without spaces (144), TAB (EC-146), NBSP (EC-147).
- **Timestamp:** always the first token when present (1,527 / 1,527); it has no key.
- **Order of the other fields is not fixed:** 193 distinct orders; 156 rows are shuffled.
- **Key aliases:**

  | Field | Keys (rows) |
  |---|---|
  | entity | `entity=` 1,005 · `entity_type=` 261 · `type=` 155 |
  | email | `email=` · `user=` · `principal=` (1,213 plain, 132 `<…>`, 66 `mailto:`) |
  | action | `action=` 1,215 · `event=` 311 — quoted `"…"` 1,072, unquoted 454 |
  | resource | `resource=` 1,031 · `url=` 283 · `path=` 142 |
  | tool | `tool=` 996 · `client=` 274 · `agent=` 121 |
  | ip | `ip=` 1,102 · `src_ip=` 294 · `client_ip=` 130 |
  | latitude / longitude | `lat=`/`lon=`, `lat=`/`lng=`, `latitude=`/`longitude=`, combined `geo=<lat>,<lon>` (129) |
  | status | `status=` 1,015 · `result=` 277 · `outcome=` 146 |

- **Values may contain spaces** (action phrases, `Ansible 2.16.4`, `C:\Share\Finance\Budget 2026.xlsx`,
  `18° 31′ 13.4″ N`, `2026-03-22 14:30:00 IST`). A value ends at the next field delimiter, not at whitespace.
- **Quoted values may contain the delimiter** (EC-150 `action="Access denied | escalated to SOC"`).
- **Extra non-target keys** exist: `ingested_at=` (EC-056), `retry_action=` (EC-117). `outcome=BLOCKED (policy: geo-fence)`
  carries a reason after the status (EC-127).
- **Absent value forms:** key omitted; key with empty value (`status=`); placeholder (`-`, `N/A`, `unknown`).

### 4.3 F2 — natural-language sentence (992 rows)

Three sentence templates (generated rows: A 495, B 288, C 187):

```text
A  <ts> <Entity> <email> <phrase> <resource> via <tool> from <ip> <coords> - <status>
B  <ts> <Entity> <email> <phrase> <resource> from <ip> using <tool>, location <coords>, result <status>
C  <ts> [<STATUS>] <Entity> <email> connecting from <ip> with <tool> located <coords> <phrase> <resource>.
```

- **Timestamp:** `[DD/Mon/YYYY:HH:MM:SS ±HHMM]` (509), bare ISO `…Z`, or `MM/DD/YYYY hh:mm:ss AM -` (together 483).
- **Entity:** a bare word (`User`, `Service Account`, `API Client`) or bracketed `[ADMIN]` (136). Absent in 69 rows.
- **Email:** plain, `<email>`, `"First Last" <email>` (display name). If the email is absent the sentence says `anonymous` (80).
- **Action phrase:** open-vocabulary verb phrase (21 distinct F2 phrases). The resource **always** follows it
  immediately (946 / 946 located resources).
- **Resource:** ends before ` via` (436), ` from` (331), or the sentence-final `.` (177). If absent the
  sentence says `an unspecified resource` (45).
- **Tool:** introduced by `via` 461 · `using` 261 · `with` 170 (`tool:` once, EC-047).
- **IP:** introduced by `from` (990) or `client` (EC-047); 62 carry `:port`.
- **Coordinates:** `(lat, lon)`, `(loc: lat, lon)`, `at lat X lon Y`, `at <DMS> <DMS>`, `[N51.5 W0.12]`,
  `location (…)`, `located (…)`; partial `at lat X` / `at lon Y`.
- **Status:** `- 200 OK` / `- status: DENIED` (A), `result 403 Forbidden` (B), `[OK]` (C and some A/B).

### 4.4 F3 — syslog header + JSON payload (985 rows)

```text
Mon dd HH:MM:SS host proc[pid]: {"entity_type":"…","user":"…","resource":"…",…}        RFC 3164 (627)
<PRI>1 YYYY-MM-DDTHH:MM:SS.mmmZ host app pid MSGID - {…}                                RFC 5424 (358)
```

| Field | JSON keys (rows) |
|---|---|
| entity | `entity_type` 457 · `entity` 291 · `principal_type` 165 |
| email | `user` 375 · `principal` 371 · `email` 160 |
| resource | `resource` 575 · `target` 191 · `res` 187 |
| tool | `tool` 434 · `user_agent` 257 · `client` 194 |
| ip | `src_ip` 498 · `ip` 255 · `remote_addr` 231 |
| coordinates | `"geo":{"lat":…,"lng":…}` · `"latitude":…,"longitude":…` (219) · `"location":"lat,lon"` (152) · GeoJSON `"geometry":{"type":"Point","coordinates":[lon,lat]}` (132) |
| action | `msg` 575 · `event` 258 · `action` 151 |
| status | string `result` 302 · `status` 169 · `outcome` 146; numeric `status` 203 · `http_status` 128 |

- Compact (`{"a":"b"}`) and spaced (`{"a": "b"}`, 312 rows) JSON; extra keys (`level`, `notify`).
- Numbers are unquoted (coordinates, numeric status, bare `NaN`); invalid codes appear quoted.
- Absent values: key omitted, or JSON `null` (placeholder, including `"geo":null` for both axes).
- Pretty-printed multi-line JSON (EC-144); truncated JSON (EC-135).

### 4.5 F4 — web access log, combined format + extras (986 rows)

```text
<ip>[:port] - <remote_user> [<ts>] "<METHOD> <resource> HTTP/<v>" <status> <bytes> "<referer>" "<user_agent>" <extras>
extras: type=|entity=|role=<entity>  user=<email>  loc=POINT(<lon> <lat>) | geo=<lat>,<lon> | lat=<lat> lon=<lon>  [xff="…"]  msg="<phrase>"
```

- **IP** is the first token (905); IPv6 with port is bracketed `[v6]:port` (80); `:port` on IPv4 (321).
- **Email** in the remote-user slot (351) or in `user=<…>` (564). When absent the slot is `-` (71 placeholders).
- **Timestamp** always in `[ ]`: `YYYY-MM-DD HH:MM:SS.mmm`, Apache CLF, ISO with offset.
- **Resource** is the request target (methods GET 640 · POST 205 · DELETE 47 · PUT 44 · CONNECT 1 · HEAD 1);
  it ends before ` HTTP/` (938). Request line `"-"` ⇒ resource placeholder (48).
- **Status** is the token after the request line (placeholder `-` 60); it is followed by the byte count.
- **Tool** is the quoted user-agent field: full browser UA (620) or CLI token; `"-"` placeholder (100).
- **Referer** is a quoted URL in 191 rows — never the resource.
- **Coordinates:** `loc=POINT(lon lat)` 334 (longitude first) · `geo=lat,lon` 284 · `lat= lon=` 213.

### 4.6 F5 — semicolon-positional legacy export (500 rows)

```text
timestamp;entity;email;tool;resource;latitude;longitude;ip;action;status
```

- Always 10 columns / 9 semicolons (100%); no value contains `;`.
- Empty column ⇒ `MISSING`; `N/A`, `NULL`, `-` ⇒ `PLACEHOLDER`.
- Uppercase emails and entities are common; statuses may be lowercase (104).
- Coordinates as signed decimals, `51.5074 N`, `N51.5074`, or DMS `51°30'26.6"N` (contains `'` and `"`).
- Timestamps `DD-MM-YYYY HH:MM[:SS]`, `YYYY/MM/DD`, `M/D/YYYY h:mm PM`, compact `YYYYMMDDTHHMMSS`.

### 4.7 NONE — no extractable event (9 rows)

SQL NULL (EC-129), literal `NULL` (EC-130), empty string (EC-131), whitespace (EC-132, EC-133),
header rows (EC-137, EC-138), junk (EC-139 `##########`, EC-140 ANSI escapes + mojibake). All fields `MISSING`.

---

## 5. Field requirements and variants

### 5.1 Entity Type

Totals: VALID 4,634 · INVALID 18 · PLACEHOLDER 42 · MISSING 306.

| Aspect | Observed variants |
|---|---|
| Spellings (27 distinct) | USER `USER` 773 `User` 593 `user` 523 · CUSTOMER 252/193/216 · SERVICE_ACCOUNT `SERVICE_ACCOUNT` 207 `Service Account` 195 `service_account` 103 `service-account` 41 · API_CLIENT `API_CLIENT` 180 `API Client` 141 `api_client` 110 `api-client` 36 · ADMIN 175/167/132 · GUEST 138/121/113 · BOT `Bot` 80 `BOT` 76 `bot` 69 |
| Unknown values (INVALID) | `contractor` 8 · `intern` 4 · `VENDOR` 3 · `superuser` 3 |
| Location | F1 `entity=`/`entity_type=`/`type=` · F2 bare word or `[UPPER]` before the email · F3 JSON key · F4 `type=`/`entity=`/`role=` · F5 column 2 |
| Placeholders | F3 `null` 19 · F1 `N/A` 10, `-` 7 · F5 `-` 4, `N/A` 1, `NULL` 1 |
| Missing | key absent / clause omitted / empty column (297) · F1 empty value (9) |

| ID | Requirement |
|---|---|
| ENT-01 | Extract the spelling exactly as written, including multi-word forms (`Service Account`, `API Client`). |
| ENT-02 | In F2 the entity is the word(s) or `[BRACKET]` immediately before the email/`anonymous`; a log level (`WARN user`, EC-047) is not part of it. |
| ENT-03 | Do not take entity words from other fields: JSON key `"user"`, email local parts (`guest_4471@…`), paths (`/admin/`, `/users/`), phrases (`User logged out`). The value occurs more than once in its own log in 335 rows. |

### 5.2 Email Address

Totals: VALID 4,544 · INVALID 58 · PLACEHOLDER 109 · MISSING 289.

| Aspect | Observed variants (VALID rows) |
|---|---|
| Local part | dots, digits (1,271), hyphen (1,157), underscore (472), `+tag` (351), middle initials |
| Domain | subdomains (3,613), `.internal` (737), multi-part suffix `.co.uk` `.gov.in` `.com.au` (482), UPPERCASE address (402) |
| Wrappers | `<…>` (F1 132, F2, F4 `user=<…>` 564), `mailto:` (66), `"Display Name" <…>` (53), bare in F4 remote-user slot (351) |
| INVALID (58) | space inside 10 (incl. 3 `[at]`/`[dot]`) · `..` 9 · leading `.` 9 · trailing `.` 7 · empty local part 6 · `@@` 5 · no `@` 5 · non-ASCII 5 · no dot in domain (`@localhost`) 4 · truncated 1 (EC-134) |
| Placeholders | F4 `-` 71 · F3 `null` 16 · F1 `-` 11, `unknown` 4 · F5 `-` 4, `N/A` 2, `NULL` 1 |
| Missing | F2 `anonymous` 80 · key absent/empty column 187 · F1 empty value 13 |

| ID | Requirement |
|---|---|
| EML-01 | Extract the address without wrappers (`<`, `>`, `mailto:`, display name, quotes). |
| EML-02 | D-01: the acting person's email. Delegated (`on behalf of …`), notification recipients (`"notify"`) and `user:pass@host` inside URLs are secondary. |
| EML-03 | Extract the whole delimited value even when it is malformed, then mark it INVALID. In all 37 rows with an invalid email, an e-mail-shaped sub-token still exists (e.g. `synthetic-probe@infra.example.internal.`), so matching only a valid shape would silently return a wrong VALID value (Profile §11). |
| EML-04 | Obfuscated (`name [at] domain [dot] com`) and space-containing values are emails for extraction purposes (INVALID), not MISSING. |
| EML-05 | `anonymous` in F2 and `-` in the F4 remote-user slot mean no email: `MISSING` and `PLACEHOLDER` respectively. A `-` slot does **not** mean missing when `user=<…>` is present (564 rows). |

Probe evidence: the first e-mail-shaped token is the correct VALID email in 4,544 / 4,544 rows.

### 5.3 Resource / URL

Totals: VALID 4,756 · INVALID 15 · PLACEHOLDER 78 · MISSING 151.

| Class (VALID) | Rows | Example |
|---|---:|---|
| `https://` | 2,207 | `https://portal.corp.example.com:8443/projects/alpha#timeline` |
| relative web path | 1,890 | `/api/v2/orders/88213?expand=items` |
| `s3://` | 139 | `s3://analytics-raw/events/dt=2026-02-07/part-00017.snappy.parquet` |
| unix filesystem path | 108 | `/etc/ssh/sshd_config` |
| `http://` | 107 | `http://10.20.0.15:8080/actuator/health` |
| `postgres://` | 91 | `postgres://billing.example.internal:5432/ledger?sslmode=require` |
| `db://` | 76 | `db://prod/customers` |
| Windows drive path | 60 | `C:\Share\Finance\Budget 2026.xlsx` |
| UNC path | 40 | `\\fileserver01\hr$\contracts\2026\` |
| `ftp://` | 37 | `ftp://files.example.net/export/q1%20final.csv` |
| custom scheme `vpn://` | 1 | EC-051 |

Features: query string 1,069 · explicit port 384 · date inside 135 · IPv4 host 105 · percent-encoding 105 ·
backslashes 100 · IP-like version number 90 · trailing slash 70 · fragment 61 · spaces 12 ·
embedded credentials 1 · IPv6 host 1 · SQL-injection characters 1.

INVALID (15): scheme typo `htps://` 5 · missing colon `http//` 4 · single slash `ftp:/` 3 · empty host `https:///` 2 · truncated 1.
Placeholders: F4 `-` 48 · F1 `-` 14 · F3 `null` 9 · F5 `NULL` 3, `-` 2, `N/A` 2.

| ID | Requirement |
|---|---|
| RES-01 | Extract the requested resource in any class above, including spaces (F1/F5 Windows paths) and backslashes. |
| RES-02 | F4: the resource is the request target between the method and ` HTTP/`; the quoted referer URL (191 rows) is secondary. |
| RES-03 | F2: strip a sentence-final `.` (189 rows) and wrapping `( ),` (EC-028); the value never includes them. |
| RES-04 | A URL inside the tool (`sqlmap/1.8.3#stable (https://sqlmap.org)`, EC-029) is not the resource. |
| RES-05 | Credentials, IP hosts, dates and dotted version numbers inside a resource belong to the resource and must not be taken as email, IP or timestamp. |
| RES-06 | `an unspecified resource` (F2) ⇒ MISSING; `-` / `null` / `N/A` / `NULL` ⇒ PLACEHOLDER. |

### 5.4 Timestamp

Totals: VALID 4,928 · INVALID 62 · PLACEHOLDER 0 · MISSING 10. 19 shapes (VALID rows):

| Shape | Rows | Example | Formats |
|---|---:|---|---|
| Apache CLF `DD/Mon/YYYY:HH:MM:SS ±HHMM` | 880 | `12/Mar/2026:13:49:32 +0800` | F2, F4 |
| ISO `YYYY-MM-DDTHH:MM:SSZ` | 661 | `2026-05-27T19:16:21Z` | F1, F2 |
| syslog RFC 3164 `Mon dd HH:MM:SS` (no year) | 621 | `Jan  9 14:02:11` | F3 |
| ISO with ms `…SS.mmmZ` | 586 | `2026-01-13T08:27:01.337Z` | F1, F3 (RFC 5424) |
| `YYYY-MM-DD HH:MM:SS.mmm` | 438 | `2026-05-05 17:36:16.709` | F4 |
| ISO with offset `…SS±HH:MM` | 425 | `2026-01-26T12:02:43+00:00` | F1, F4 |
| US `MM/DD/YYYY hh:mm:ss AM` | 280 | `02/18/2026 12:25:54 PM` | F2 |
| `DD-MM-YYYY HH:MM` | 192 | `23-01-2026 12:02` | F5 |
| `YYYY-MM-DD HH:MM:SS` | 152 | `2026-05-21 15:07:49` | F1 |
| ISO ms + offset | 147 | `2026-01-19T13:22:41.470+05:30` | F1 |
| epoch seconds (10 digits) | 132 | `1773480137` | F1, F2 |
| epoch milliseconds (13 digits) | 108 | `1778283322860` | F1 |
| `DD-MM-YYYY HH:MM:SS` | 100 | `04-02-2026 10:50:54` | F5 |
| `YYYY/MM/DD HH:MM:SS` | 76 | `2026/05/14 01:26:02` | F5 |
| US short `M/D/YYYY h:mm PM` | 65 | `3/15/2026 3:32 PM` | F5 |
| compact `YYYYMMDDTHHMMSS` | 62 | `20260209T173435` | F5 |
| microseconds + offset | 1 | `2026-03-15T08:01:02.123456+05:30` | EC-049 |
| lowercase `t`/`z` | 1 | `2026-03-16t10:20:30z` | EC-050 |
| with zone abbreviation | 1 | `2026-03-22 14:30:00 IST` | EC-060 |

INVALID (62): Feb 29 in 2026 16 · hour 25 / minute 61 13 · Feb 30 12 · Apr 31 11 · month 13 9 · `13:05 PM` 1.

| ID | Requirement |
|---|---|
| TS-01 | Extract the timestamp exactly as written: no conversion to UTC, no year insertion, keep the double space in `Jan  9` (196 padded days), keep `[ ]` outside the value. |
| TS-02 | D-02: the event timestamp is the leading timestamp of the event (F1/F2/F3/F5 start, F4 `[ ]` after the remote user). `ingested_at=` (EC-056) and dates inside resources are secondary. In 75 rows the first `YYYY-MM-DD` in the log lies inside the resource (Profile §11). |
| TS-03 | Day/month order is not interpreted: 231 VALID rows (`03/04/2026`, `05-02-2026`) are ambiguous and are extracted as-is. |
| TS-04 | Epoch values are only timestamps in the timestamp position; other digit runs (F4 byte counts, syslog PIDs, ports, IDs in paths) are not timestamps. |
| TS-05 | Extraction is by shape; calendar and clock validity is a separate check (VAL-TS). Invalid timestamps keep their exact text. |

### 5.5 Tool

Totals: VALID 4,507 · INVALID 1 · PLACEHOLDER 160 · MISSING 332. 40 distinct values.

| Class (VALID) | Rows | Examples |
|---|---:|---|
| `product/version` | 3,742 | `Chrome/124.0.6367.91`, `aws-cli/2.15.0`, `kubectl/v1.29.3`, `kube-probe/1.29` |
| full browser user agent (F4) | 620 | `Mozilla/5.0 (Windows NT 10.0; Win64; x64) … Chrome/124.0.0.0 Safari/537.36 Edg/124.0.2478.67` (7 variants) |
| `product_version` | 90 | `OpenSSH_9.6p1` |
| `product version` | 53 | `Ansible 2.16.4` |
| compound user agent | 2 | `aws-cli/2.15.0 Python/3.11.6 Linux/6.5.0-1017-aws exe/x86_64.ubuntu.22` (EC-065), `sqlmap/1.8.3#stable (https://sqlmap.org)` (EC-029) |

Placeholders: F4 `-` 100 · F3 `null` 26 · F1 `-` 18, `unknown` 5 · F5 `-` 5, `N/A` 3, `NULL` 3.

| ID | Requirement |
|---|---|
| TL-01 | Extract the whole tool value, including spaces, parentheses and semicolons inside a user agent. Do not reduce a UA to a browser name (an Edge UA also contains `Chrome/` and `Safari/`). |
| TL-02 | Version numbers that look like IPv4 (`Chrome/124.0.0.0`, `sensor-agent/10.0.0.1`, `agent/1.2.3.4`; 252 rows) are part of the tool, never the IP. |
| TL-03 | A truncated user agent (EC-136) is extracted as far as it goes and is INVALID. |

### 5.6 Latitude / Longitude

Totals: latitude VALID 4,249 · INVALID 24 · PLACEHOLDER 66 · MISSING 661 — longitude VALID 4,252 · INVALID 27 · PLACEHOLDER 67 · MISSING 654.

| Shape (VALID) | Latitude | Longitude | Example |
|---|---:|---:|---|
| signed decimal (1–7 dp) | 3,696 | 3,699 | `-33.8503848`, `151.1772048` |
| DMS `D°MM'SS.s"H` | 281 | 277 | `19°04'33.6"N` |
| hemisphere prefix | 181 | 181 | `N1.30563`, `E103.77876` |
| hemisphere suffix | 90 | 94 | `35.68571 N` |
| DMS with Unicode primes | 1 | 1 | `18° 31′ 13.4″ N` (EC-084) |

| Container | Order | Rows |
|---|---|---:|
| F4 `loc=POINT(lon lat)` | **longitude first** | 334 |
| F3 GeoJSON `"coordinates":[lon,lat]` | **longitude first** | 132 |
| F1 keys in shuffled order | longitude first | 59 |
| F1 `geo=lat,lon` · F4 `geo=lat,lon` · F3 `"location":"lat,lon"` · F2 `(lat, lon)` · F5 columns 6–7 | latitude first | all others |

INVALID: out of range (lat 13, lon 16) · `NaN` (lat 8, lon 9) · decimal comma `48,8566` (2 each) · negative sign plus hemisphere `-33.8688 S` (lat 1).
Placeholders: `null`, `N/A`, `-`, `NULL`. Partial pairs (one axis only): 158 rows.

| ID | Requirement |
|---|---|
| GEO-01 | Extract each axis separately with its original notation (sign, hemisphere letter, DMS symbols, precision). |
| GEO-02 | Assign axes by label when labelled (`lat`/`latitude`, `lon`/`lng`/`longitude`); by container convention when not: WKT and GeoJSON are longitude-first; every other unlabelled pair in the data is latitude-first. |
| GEO-03 | Never swap values to make them valid: EC-087 (`lat=151.2093 lon=-33.8688`) stays as written (latitude INVALID). |
| GEO-04 | A decimal comma inside a single labelled value (`lat=48,8566`) is one INVALID value, not a pair. |
| GEO-05 | Decimal numbers elsewhere are not coordinates: fractional seconds (`…:01.337Z`), user-agent versions (`537.36`) and the other axis. The first 2+ dp decimal in a log is not the latitude in 951 / 3,696 rows (timestamp 499, longitude 308, tool 143). |
| GEO-06 | One axis may be present without the other (158 rows); the missing axis is MISSING. |

### 5.7 IP Address

Totals: VALID 4,948 · INVALID 38 · PLACEHOLDER 1 · MISSING 13.

| Class (VALID) | Rows | Example |
|---|---:|---|
| IPv4 dotted quad | 3,905 | `192.0.2.115` |
| IPv6 compressed | 727 | `2001:db8:d09:e59e::3b83`, `::1` |
| IPv6 full 8 groups | 203 | `2001:0db8:103e:81dd:7f43:9227:bf56:457f` |
| IPv4-mapped IPv6 | 112 | `::ffff:192.0.2.127` |
| link-local with zone id | 1 | `fe80::1ff:fe23:4567:890a%eth0` (EC-100) |

Ranges (VALID): documentation 3,010 · private RFC 1918 1,935 · loopback 2 · link-local 1.
INVALID (38): octet > 255 8 · IPv6 non-hex 8 · 3 octets 6 · 5 octets 6 · IPv6 with two `::` 6 · leading zeros 4.

| ID | Requirement |
|---|---|
| IP-01 | Extract the address without port or brackets (`198.51.100.23:51544` → `198.51.100.23`, `[2001:db8::1]:443` → `2001:db8::1`); the port is secondary (463 rows). |
| IP-02 | D-03: with a proxy chain, the original client — first X-Forwarded-For entry (EC-103), or `client` before `via` (EC-047). |
| IP-03 | Dotted quads in resources (`http://10.20.0.15:8080/…`, `releases/4.10.2.1/`) and tools are not the IP: the first dotted quad in the log is wrong in 91 / 3,905 IPv4 rows, 89 of them in the resource. |
| IP-04 | IPv4-mapped IPv6 is extracted whole (`::ffff:192.0.2.127`), not as its embedded IPv4. |
| IP-05 | F4: a bracketed IPv6 at the start (`[2001:db8::1]:443`) and the bracketed timestamp are different fields. |
| IP-06 | Malformed dotted/colon values in the IP position are extracted and marked INVALID (5-octet `1.2.3.4.5` must not become `1.2.3.4`). |

### 5.8 Action / Access Phrase

Totals: VALID 4,987 · MISSING 13 (EC-114, 3 truncated rows, 9 NONE rows). 86 distinct phrases.

| Outcome class | Phrase families (exact spellings in Profile §8) |
|---|---|
| SUCCESS | Access granted / ACCESS GRANTED / access granted · Request allowed · Login successful · Permission granted · Authenticated successfully · authentication succeeded · request permitted · permitted · allowed · Session started · Authorized · Permitted · ACCESS PERMITTED · LOGIN OK · was granted/allowed/permitted access to · successfully accessed · logged in to · authenticated successfully to |
| DECLINED | Access denied (all cases) · Access denied: insufficient privileges · permission denied · Login failed / login failed / LOGIN FAILED · Authentication failed · Unauthorized attempt · Unauthorized · Forbidden / forbidden · Request blocked (by policy) · Blocked by WAF policy · blocked by policy · Access declined · Declined by policy · Login attempt rejected · was denied/refused access to · was blocked from accessing · failed to authenticate/log in to · attempted unauthorized access to |
| NEUTRAL | Logout / logout / User logged out / logged out of · MFA challenge (issued) · was sent an MFA challenge for · Password reset requested · requested a password reset for · Token expired · Session timeout · had an expired session token for · Rate limited / Rate limit exceeded · was rate limited on · Resource not found / Not found · requested a missing resource · Upstream error · Internal server error · Server error · hit a server error on |
| Edge wording | `access NOT granted to` (EC-047) · `was not granted access to` (EC-107) · `Access was not denied` (EC-108) · `Access granted after 2 failed attempts` (EC-109) · `AcCeSs DeNiEd` (EC-111) · `Access denied \| escalated to SOC` (EC-150) |

| ID | Requirement |
|---|---|
| ACT-01 | Extract the complete phrase as written (all words, original case, punctuation such as `: insufficient privileges`). |
| ACT-02 | F1 `action=`/`event=` (quoted or unquoted) · F3 `msg`/`event`/`action` · F4 `msg="…"` · F5 column 9. |
| ACT-03 | F2: the phrase is the verb phrase between the actor (email / `anonymous`, or the coordinates/tool clause in template C) and the resource. |
| ACT-04 | Negation and mixed wording are part of the phrase; extraction does not decide the outcome. |
| ACT-05 | Outcome words outside the action field are not the phrase: resource names (EC-110 `access-denied-summary`), `retry_action=` (EC-117), a second status key (EC-128), stack-trace text (EC-143). Only these 4 rows have outcome keywords outside both action and status (Profile §11). |
| ACT-06 | The status value must not be used to locate or infer the phrase: 42 rows have a status that contradicts the phrase. |

### 5.9 Status

Totals: VALID 4,701 · INVALID 12 · PLACEHOLDER 90 · MISSING 197. 63 distinct values.

| Class (VALID) | Rows | Values |
|---|---:|---|
| word, uppercase | 2,233 | SUCCESS, OK, ALLOWED, DENIED, FAILED, FAIL, BLOCKED, PASS, REJECTED, PENDING, NOT_FOUND, ERROR, RATE_LIMITED, THROTTLED, EXPIRED, TIMEOUT, CHALLENGE, DECLINED |
| HTTP code | 1,633 | 200, 201, 202, 204, 302, 401, 403, 404, 429, 500, 502, 503 |
| word, lowercase | 432 | ok, success, fail, blocked, allowed, failed, denied, pass, rejected, expired, not_found, pending, throttled |
| HTTP code + reason phrase (F2) | 402 | `200 OK`, `403 Forbidden`, `429 Too Many Requests`, `500 Internal Server Error`, … |
| symbol | 1 | `✓` (EC-123) |

INVALID (12): typos `SUCCES` 3 · `FAILD` 3 · `DENEID` 1 · letter O in code `4O3` 2 · `20O` 1 · out-of-range code `600` 1 · `999` 1.
Placeholders: F4 `-` 60 · F1 `N/A` 9, `-` 7 · F3 `null` 9 · F5 `-` 2, `N/A` 2, `NULL` 1.

| ID | Requirement |
|---|---|
| STS-01 | F1 `status=`/`result=`/`outcome=` · F2 `- X`, `- status: X`, `result X`, `[X]` · F3 string or numeric `result`/`status`/`outcome`/`http_status` · F4 the token after the request line · F5 column 10. |
| STS-02 | F2 HTTP codes keep their reason phrase (`403 Forbidden`); F1 reason text after the status (`BLOCKED (policy: geo-fence)`, EC-127) is secondary. |
| STS-03 | F4: the byte count after the status and 3-digit numbers elsewhere (ports, PIDs, IDs) are not the status. |
| STS-04 | A status that also occurs inside another field is still the status field's own token (`LOGIN OK;OK`; 42 rows repeat the status text). |
| STS-05 | Do not include line endings (`status=SUCCESS\r\n`, EC-148) or trace lines (EC-143). |

---

## 6. Ambiguity rules

| ID | Situation | Rule | Evidence |
|---|---|---|---|
| AMB-01 | Several emails | Acting person (D-01) | EC-021, EC-022, EC-030 |
| AMB-02 | Several timestamps / dates | Event timestamp (D-02) | EC-056; 75 rows with an earlier date inside the resource |
| AMB-03 | Several IPs | Original client (D-03); ports, IP hosts in URLs, IP-like versions are not the IP | EC-047, EC-103; 91 + 214 probe rows |
| AMB-04 | Several URLs | Requested resource; referer and URLs inside tools are secondary | 191 referer rows; EC-029 |
| AMB-05 | Unlabelled coordinate pair | WKT/GeoJSON lon-first; all other unlabelled pairs lat-first; never swap | 334 + 132 lon-first rows; EC-087 |
| AMB-06 | Decimal-looking numbers | Only values in a coordinate position/label are coordinates | 951 probe rows |
| AMB-07 | Several action phrases | *Proposed:* the phrase of the event itself — first line / primary action key | EC-117, EC-143 (Q-02) |
| AMB-08 | Several status tokens | *Proposed:* the first status token of the event; later ones secondary | EC-128 (Q-01) |
| AMB-09 | Status vs phrase conflict | Extract both independently; no inference | 42 rows |
| AMB-10 | `-` in F4 remote-user slot | PLACEHOLDER only when no `user=<…>` exists | 71 vs 564 rows |
| AMB-11 | Day/month order | Extract as written; no interpretation | 231 rows |
| AMB-12 | Delimiters inside values | F1 quoted values may contain `\|`; F4 quoted UA contains `;` and `()`; F5 DMS contains `'` and `"` | EC-150; 620 UA rows; 188 DMS columns |
| AMB-13 | Entity words elsewhere | Only the entity position/key | 335 rows with repeated entity text |
| AMB-14 | Sentinel phrases | F2 `anonymous` ⇒ email MISSING; `an unspecified resource` ⇒ resource MISSING | 80 + 45 rows |
| AMB-15 | Truncated logs | Extract what is present; the value cut off by truncation is INVALID; later fields MISSING | EC-134, EC-135, EC-136 |

---

## 7. Validity rules

Validity is decided on the extracted value. Checked against the answer key, these rules reproduce
46,758 of the 46,761 VALID/INVALID labels. The 3 exceptions are the truncated logs EC-134, EC-135 and
EC-136: their cut-off values look syntactically valid and are INVALID only because of AMB-15.

| ID | Field | VALID | INVALID |
|---|---|---|---|
| VAL-ENT | entity | One of USER, CUSTOMER, ADMIN, SERVICE_ACCOUNT, API_CLIENT, GUEST, BOT, compared ignoring case and treating space/`_`/`-` as equal | Any other word (`contractor`, `intern`, `VENDOR`, `superuser`) |
| VAL-EML | email | ASCII; one `@`; non-empty local part without leading/trailing/consecutive dots; domain with at least one dot; no spaces | Anything else, incl. non-ASCII, `[at]`, truncated (EC-134) |
| VAL-RES | resource | Relative path; filesystem/UNC path; or scheme in {http, https, ftp, s3, db, postgres, vpn} followed by `://` and a non-empty host/bucket | Unknown scheme (`htps`), `http//`, `ftp:/`, `https:///`, truncated (EC-135) |
| VAL-TS | timestamp | Real calendar date and clock time: month 1–12, day valid for the month (2026 is not a leap year; year-less syslog dates use 2026), hour 0–23 (1–12 with AM/PM), minute/second 0–59; any 10-digit epoch seconds / 13-digit epoch ms | Feb 29/30, Apr 31, month 13, hour 25, minute 61, `13:05 PM` |
| VAL-TL | tool | Any non-placeholder value | Truncated user agent (EC-136) |
| VAL-GEO | lat / lon | Decimal within ±90 / ±180 (boundaries included, `0,0` included); unsigned value + matching hemisphere letter (N/S latitude, E/W longitude); DMS with degrees in range and minutes/seconds < 60 | Out of range, `NaN`, decimal comma, sign combined with hemisphere letter |
| VAL-IP | ip | IPv4 dotted quad, octets 0–255, no leading zeros; IPv6 per RFC 4291 (single `::`, full, IPv4-mapped, zone id) | Octet > 255, 3 or 5 octets, leading zeros, two `::`, non-hex |
| VAL-ACT | action | Any present phrase | — (none in the data) |
| VAL-STS | status | HTTP code 100–599 (with or without a standard reason phrase); a word in the status vocabulary of §5.9 (any case); `✓` | Word outside the vocabulary (`SUCCES`, `FAILD`, `DENEID`); code outside 100–599; letters in a code |
| VAL-PH | all | Placeholder tokens: `-`, `N/A`, `NULL`, `null`, `unknown` (in a field position) ⇒ PLACEHOLDER | — |
| VAL-MS | all | Absent key/clause, empty value, empty F5 column, F2 sentinel phrase ⇒ MISSING | — |

---

## 8. Edge-case register

| Cases | What they exercise | Requirements |
|---|---|---|
| EC-001–010 | Entity casing, hyphen, multi-word, `[ADMIN]`, `role=`, unknown value, absent, `N/A` | ENT-01…03, VAL-ENT |
| EC-011–026 | Malformed emails, obfuscation, non-ASCII, uppercase, display name, `mailto:`, two emails, anonymous | EML-01…05, AMB-01, VAL-EML |
| EC-027–042 | Trailing `.`, `( ),`, SQL injection, credentials, IP host, `%20`, Windows/UNC/Linux paths, s3/ftp/db, absolute request URL, referer, `-`, scheme typo | RES-01…06, AMB-04 |
| EC-043–060 | Impossible dates/times, ambiguous order, epoch s/ms, µs, lowercase `t`/`z`, padded syslog day, RFC 5424, 12-hour, compact, two timestamps, absent, `IST` | TS-01…05, AMB-02, VAL-TS |
| EC-061–070 | IP-like versions, Edge/mobile UA, compound UA, `unknown`/`-`, `using`, lowercase tool, absent | TL-01…03, IP-03 |
| EC-071–090 | 0,0, boundaries, out of range, NaN, N/A, partial, decimal comma, `geo=`, DMS (ASCII/Unicode), WKT, GeoJSON, swapped, hemisphere prefix, precision, sign + hemisphere | GEO-01…06, AMB-05, VAL-GEO |
| EC-091–106 | Octets, leading zeros, ports, IPv6 full/compressed/loopback/mapped/zone, invalid IPv6, XFF chain, absent, `-`, IP-like version in path | IP-01…06, AMB-03, VAL-IP |
| EC-107–118 | Negation, double negation, mixed outcome, keyword in resource, mixed case, declined, absent phrase, MFA, rate limit, retry phrase, token expired | ACT-01…06, AMB-07 |
| EC-119–128 | Status/phrase conflicts, absent, empty value, `✓`, typo, invalid codes, `outcome=` with reason, two status tokens | STS-01…05, AMB-08/09, VAL-STS |
| EC-129–150 | NULL, `NULL` text, empty, whitespace, truncation, headers, junk, duplicates, stack trace, pretty JSON, long line, TAB, NBSP, CRLF, padding spaces, `\|` inside quotes | G-04, G-07, G-08, FMT-02/03, AMB-12, AMB-15 |

---

## 9. Acceptance criteria for Step 3 (proposed)

1. Output one row per `log_id` (5,000) with the 10 value/validity pairs.
2. Compare with `data/expected_fields.csv` field by field; report value accuracy and validity accuracy
   per field, per format and for curated vs generated rows.
3. Proposed target: 100% exact match on value **and** validity for all 5,000 rows — the data is synthetic and
   every label follows the rules above. Any mismatch is either a parser defect or a documented rule change.
4. The RAW LOG checksum (`a94fc3cc…e661e`) is unchanged after the run.

---

## 10. Open questions (decisions needed before Step 3)

| ID | Question | Recommendation (current answer key) |
|---|---|---|
| Q-01 | Two status tokens in one event (EC-128 `"status":401,"result":"FAILED"`): which is primary? | First status token of the event (`401`); the other is secondary. |
| Q-02 | Two action phrases (EC-117 `retry_action=`, EC-143 stack trace): which is primary? | The event's own action field / first line (`Access denied`). |
| Q-03 | Should the unlabelled-pair convention in GEO-02 (WKT/GeoJSON lon-first, everything else lat-first) be adopted as a fixed rule? | Yes — it matches all 4,197 rows that contain both axes. |
| Q-04 | Scope of validity checking in Step 3: implement VAL-* rules (including calendar checks and the 2026 year assumption for year-less syslog dates) inside PostgreSQL, or extract values only? | Implement VAL-* so results are comparable with the answer key. |
| Q-05 | Acceptance target and outputs: 100% match on value + validity? Should the parser also emit `format_family`, `outcome_class` and `record_validity`? | 100% target; emit `format_family` (useful for debugging); treat `outcome_class`/`record_validity` as optional. |
