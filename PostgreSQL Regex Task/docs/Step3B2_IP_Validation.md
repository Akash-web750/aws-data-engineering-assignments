# Step 3B-2 — PostgreSQL IP Validation Behaviour

**Status:** verified (11/09/2026). Stopped for review.

No parser code was written and the raw table was not changed: the check uses TEMP tables only, and
`log_regex.verify_raw_access_logs()` still passes 10 / 10 after the run.

---

## 1. Question and method

**Question:** can PostgreSQL 17's `inet` type decide IP validity for the parser (Step 2 VAL-IP, Step 3A §10.2),
in particular for IPv4 addresses with leading zeros and IPv6 addresses with zone IDs?

| Item | Detail |
|---|---|
| Server / database | PostgreSQL 17.9 (x86_64-windows), `postgresql_regex_task` (UTF8) |
| Script | [sql/05_verify_ip_validation.sql](../sql/05_verify_ip_validation.sql) |
| Run | `psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/05_verify_ip_validation.sql` (from the project folder) |
| Functions tested | `pg_input_is_valid(text, 'inet')` and `pg_input_error_info(text, 'inet')` (PostgreSQL 16+, never raise an error); `value::inet`, `family()`, `masklen()` only for values already known to be valid |
| Inputs | 43 targeted probes (forms in the data plus nearby traps) and all 4,986 answer-key IP values labelled VALID or INVALID, loaded into a TEMP table from `data/expected_fields.csv` |
| Pass condition | The proposed rule must match every answer-key label and every probe expectation; the script exits non-zero otherwise |

Result line from the run: `Step 3B-2 PASSED: proposed VAL-IP rule matches all labelled answer-key values and all 43 probes; raw input unchanged`.

---

## 2. Findings

### 2.1 `inet` behaviour by form

| Form | Example | Step 2 VAL-IP | PostgreSQL `inet` | Same verdict? |
|---|---|---|---|---|
| IPv4 dotted quad | `192.0.2.115`, `0.0.0.0`, `255.255.255.255` | VALID | accepted | yes |
| **IPv4 with leading zeros** | `192.168.001.010`, `010.0.0.1`, `1.2.3.04` | INVALID | **accepted**, read as **decimal** and normalised (`192.168.1.10/32`, `10.0.0.1/32`) | **no** |
| IPv4 octet > 255 | `198.51.100.781`, `256.10.1.300` | INVALID | rejected | yes |
| IPv4-like, 2 / 3 / 5 groups | `10.1`, `192.168.1`, `1.2.3.4.5` | INVALID | rejected | yes |
| **IPv4 with prefix length** | `192.0.2.1/24`, `192.0.2.1/32` | INVALID (not a bare address) | **accepted** (mask 24 / 32) | **no** (not in data) |
| IPv4 with port, or leading space | `192.0.2.1:80`, `␠192.0.2.1` | INVALID | rejected | yes |
| IPv6 compressed / short / full / uppercase | `2001:db8:d09:e59e::3b83`, `2001:0db8:0000:0000:0000:ff00:0042:8329`, `2001:DB8::1` | VALID | accepted | yes |
| IPv6 loopback / unspecified | `::1`, `::` | VALID | accepted | yes |
| IPv6 IPv4-mapped | `::ffff:192.0.2.10` | VALID | accepted | yes |
| IPv4-mapped with bad tail | `::ffff:192.0.2.999`, `::ffff:192.0.2.010` | INVALID | rejected (a leading zero is rejected here, although plain IPv4 accepts it) | yes |
| **IPv6 with zone ID** | `fe80::1ff:fe23:4567:890a%eth0`, `fe80::1%1`, `2001:db8::1%eth0` | VALID | **rejected** — `inet` has no zone ID support | **no** |
| IPv6 with empty zone ID | `fe80::1%` | INVALID | rejected | yes |
| Brackets, brackets + port | `[2001:db8::1]`, `[2001:db8::1]:443` | INVALID (stripped before validation) | rejected | yes |
| Malformed IPv6 | two `::`, `gggg`, 5-digit group, 9 groups, 7 groups without `::`, 8 groups plus `::`, single leading/trailing colon | INVALID | rejected | yes |
| **IPv6 with prefix length** | `2001:db8::/32` | INVALID | **accepted** | **no** (not in data) |
| Empty string | `''` | INVALID | rejected | yes |

Every rejection returns the same message, `invalid input syntax for type inet: "<value>"`, with no detail about which
part is wrong.

### 2.2 Against the answer key (4,986 labelled values)

| Form | Label | Rows | `inet` accepts | `inet` rejects | `inet` agrees | Proposed rule agrees |
|---|---|---:|---:|---:|---:|---:|
| IPv4 dotted quad | VALID | 3,905 | 3,905 | 0 | 3,905 | 3,905 |
| IPv6 compressed | VALID | 727 | 727 | 0 | 727 | 727 |
| IPv6 full 8 groups | VALID | 203 | 203 | 0 | 203 | 203 |
| IPv6 IPv4-mapped | VALID | 112 | 112 | 0 | 112 | 112 |
| **IPv6 with zone ID** | VALID | 1 | 0 | **1** | **0** | 1 |
| IPv6-like, non-hex characters | INVALID | 8 | 0 | 8 | 8 | 8 |
| IPv4 octet > 255 | INVALID | 8 | 0 | 8 | 8 | 8 |
| IPv4-like, 5 groups | INVALID | 6 | 0 | 6 | 6 | 6 |
| IPv4-like, 3 groups | INVALID | 6 | 0 | 6 | 6 | 6 |
| IPv6-like, two `::` | INVALID | 6 | 0 | 6 | 6 | 6 |
| **IPv4 leading zeros** | INVALID | 4 | **4** | 0 | **0** | 4 |

| Method | Labelled values | Agree | Disagree |
|---|---:|---:|---:|
| Plain `inet` input (`pg_input_is_valid`) | 4,986 | 4,981 | **5** |
| Proposed VAL-IP rule (§4) | 4,986 | **4,986** | **0** |

The 5 disagreements of plain `inet`:

| Case | Value | Answer key | `inet` |
|---|---|---|---|
| EC-094 | `192.168.001.010` | INVALID | accepted as `192.168.1.10/32` |
| GEN-00190 | `192.168.037.068` | INVALID | accepted as `192.168.37.68/32` |
| GEN-01246 | `192.168.088.084` | INVALID | accepted as `192.168.88.84/32` |
| GEN-04210 | `192.168.026.094` | INVALID | accepted as `192.168.26.94/32` |
| EC-100 | `fe80::1ff:fe23:4567:890a%eth0` | VALID | rejected |

All 4,986 labelled values occur verbatim in their own `raw_log` (TEMP-table join, read-only).

### 2.3 `inet` rewrites the values it accepts

| Input | `value::inet::text` | Same text? |
|---|---|---|
| `192.0.2.115` | `192.0.2.115/32` | no |
| `2001:db8:d09:e59e::3b83` | `2001:db8:d09:e59e::3b83/128` | no |
| `2001:0db8:0000:0000:0000:ff00:0042:8329` | `2001:db8::ff00:42:8329/128` | no |
| `2001:DB8::1` | `2001:db8::1/128` | no |
| `::ffff:192.0.2.10` | `::ffff:192.0.2.10/128` | no |
| `192.168.001.010` | `192.168.1.10/32` | no |
| `192.0.2.1/24` | `192.0.2.1/24` | yes |

A cast adds the prefix length, compresses and lowercases IPv6, and removes leading zeros. It therefore can neither be
stored as the extracted value (exact substring rule, G-02) nor used after the fact to detect leading zeros.

### 2.4 Conclusion

Plain `inet` is **not** a correct VAL-IP rule for this dataset:

1. It accepts IPv4 leading zeros (4 answer-key rows would become VALID).
2. It rejects IPv6 zone IDs (EC-100 would become INVALID).
3. It accepts prefix lengths (`/24`, `/32`, `/128`), which are not bare addresses.
4. It normalises the text.

It **is** reliable for the structure of IPv6 addresses: group count, group length, a single `::`, stray colons and
the dotted IPv4 tail. The rule below uses it only for that, on text that has already passed a strict shape check.

---

## 3. Correction to earlier documentation

- Step 2 VAL-IP says "IPv6 per RFC 4291 (single `::`, full, IPv4-mapped, zone id)". RFC 4291 defines the address text
  forms; zone IDs come from RFC 4007 / RFC 6874. §4 below is now the authoritative definition.
- Step 3A §10.2 said an `inet` cast is not authoritative for VAL-IP and needed confirmation — confirmed, and replaced by
  §4.

---

## 4. Exact VAL-IP rule for the Step 3B parser

### 4.1 Where it applies

Applied in stage S7 to the extracted `ip_address` value **after** S4 clean-up (brackets and `:port` already removed)
and only when the value state is not MISSING or PLACEHOLDER. The value is validated exactly as stored; nothing is
trimmed or normalised.

### 4.2 Rule

A value is **VALID** if either condition holds; otherwise it is **INVALID**.

**A — IPv4.** The whole value matches:

```text
^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$
```

**B — IPv6.** The whole value matches:

```text
^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3})?(%[0-9A-Za-z._~-]+)?$
```

**and** `pg_input_is_valid(split_part(value, '%', 1), 'inet')` is true.

In SQL form (as verified in `sql/05_verify_ip_validation.sql`):

```sql
CASE
    WHEN value ~ '<pattern A>'                                                    THEN 'VALID'
    WHEN value ~ '<pattern B>' AND pg_input_is_valid(split_part(value, '%', 1), 'inet') THEN 'VALID'
    ELSE 'INVALID'
END
```

### 4.3 What each part guarantees

| Part | Guarantees | Rejects (examples) |
|---|---|---|
| Pattern A | Exactly 4 decimal octets, each 0–255, no leading zeros; nothing else in the value | `192.168.001.010`, `198.51.100.781`, `192.168.1`, `1.2.3.4.5`, `192.0.2.1/24`, `192.0.2.1:80` |
| Pattern B | Only hex digits and colons, at least one colon; an optional dotted IPv4 tail at the end with the same strict octets as A; an optional non-empty zone ID of `[0-9A-Za-z._~-]` (RFC 6874 unreserved characters); no brackets, port, prefix length or whitespace | `[2001:db8::1]`, `2001:db8::/32`, `2001:db8:gggg::1`, `::ffff:192.0.2.010`, `fe80::1%` |
| `inet` on the address without the zone ID | Valid IPv6 structure: at most 8 groups, at most 4 hex digits per group, at most one `::`, no single leading or trailing colon, valid tail | `2001:db8::85a3::7334`, `2001:db8:12345::1`, `1:2:3:4:5:6:7:8:9`, `1:2:3:4:5:6:7`, `1:2:3:4:5:6:7::8`, `2001:db8::1:`, `:2001:db8::1` |

The zone ID's syntax is checked but its meaning is not (no check against real interface names or link-local scope),
which matches the answer key (`fe80::1ff:fe23:4567:890a%eth0` VALID).

### 4.4 Implementation notes

- Use the case-sensitive `~` operator; hex classes already include `A-F` and `a-f`.
- Never validate with a `value::inet` cast: it raises an error on bad input, and on good input it returns rewritten
  text. `pg_input_is_valid` is error-free and returns only a boolean.
- Never store `inet` output as the extracted value.
- Patterns contain no backslashes (`[.]` for a literal dot), so they behave the same in standard strings, psql and
  PL/pgSQL.

---

## 5. Probe results (all 43)

`inet` column: accepted / rejected by `pg_input_is_valid(value, 'inet')`. Rule column: result of §4.2.

| # | Form | Value | Step 2 | `inet` | `inet` text | Rule |
|---:|---|---|---|---|---|---|
| 1 | IPv4 dotted quad (documentation range) | `192.0.2.115` | VALID | accepted | `192.0.2.115/32` | VALID |
| 2 | IPv4 dotted quad (private) | `10.40.3.8` | VALID | accepted | `10.40.3.8/32` | VALID |
| 3 | IPv4 loopback | `127.0.0.1` | VALID | accepted | `127.0.0.1/32` | VALID |
| 4 | IPv4 all-zero octets | `0.0.0.0` | VALID | accepted | `0.0.0.0/32` | VALID |
| 5 | IPv4 all-255 octets | `255.255.255.255` | VALID | accepted | `255.255.255.255/32` | VALID |
| 6 | IPv4 leading zeros (EC-094) | `192.168.001.010` | INVALID | **accepted** | `192.168.1.10/32` | INVALID |
| 7 | IPv4 leading zeros (GEN-00190) | `192.168.037.068` | INVALID | **accepted** | `192.168.37.68/32` | INVALID |
| 8 | IPv4 leading zero, first octet | `010.0.0.1` | INVALID | **accepted** | `10.0.0.1/32` | INVALID |
| 9 | IPv4 one leading zero | `1.2.3.04` | INVALID | **accepted** | `1.2.3.4/32` | INVALID |
| 10 | IPv4 octet > 255 | `198.51.100.781` | INVALID | rejected | — | INVALID |
| 11 | IPv4 octet > 255 (EC-091) | `256.10.1.300` | INVALID | rejected | — | INVALID |
| 12 | IPv4-like, 3 octets (EC-092) | `192.168.1` | INVALID | rejected | — | INVALID |
| 13 | IPv4-like, 2 octets | `10.1` | INVALID | rejected | — | INVALID |
| 14 | IPv4-like, 5 octets (EC-093) | `1.2.3.4.5` | INVALID | rejected | — | INVALID |
| 15 | IPv4 with prefix /24 | `192.0.2.1/24` | INVALID | **accepted** | `192.0.2.1/24` | INVALID |
| 16 | IPv4 with prefix /32 | `192.0.2.1/32` | INVALID | **accepted** | `192.0.2.1/32` | INVALID |
| 17 | IPv4 with port | `192.0.2.1:80` | INVALID | rejected | — | INVALID |
| 18 | IPv4 with leading space | `␠192.0.2.1` | INVALID | rejected | — | INVALID |
| 19 | IPv6 compressed | `2001:db8:d09:e59e::3b83` | VALID | accepted | `2001:db8:d09:e59e::3b83/128` | VALID |
| 20 | IPv6 compressed, short (EC-097) | `2001:db8::1` | VALID | accepted | `2001:db8::1/128` | VALID |
| 21 | IPv6 full 8 groups (EC-096) | `2001:0db8:0000:0000:0000:ff00:0042:8329` | VALID | accepted | `2001:db8::ff00:42:8329/128` | VALID |
| 22 | IPv6 uppercase hex | `2001:DB8::1` | VALID | accepted | `2001:db8::1/128` | VALID |
| 23 | IPv6 loopback (EC-098) | `::1` | VALID | accepted | `::1/128` | VALID |
| 24 | IPv6 unspecified | `::` | VALID | accepted | `::/128` | VALID |
| 25 | IPv6 IPv4-mapped (EC-099) | `::ffff:192.0.2.10` | VALID | accepted | `::ffff:192.0.2.10/128` | VALID |
| 26 | IPv4-mapped, octet > 255 | `::ffff:192.0.2.999` | INVALID | rejected | — | INVALID |
| 27 | IPv4-mapped, leading zero | `::ffff:192.0.2.010` | INVALID | rejected | — | INVALID |
| 28 | IPv6 link-local with zone ID (EC-100) | `fe80::1ff:fe23:4567:890a%eth0` | VALID | **rejected** | — | VALID |
| 29 | IPv6 with numeric zone ID | `fe80::1%1` | VALID | **rejected** | — | VALID |
| 30 | IPv6 global with zone ID | `2001:db8::1%eth0` | VALID | **rejected** | — | VALID |
| 31 | IPv6 with empty zone ID | `fe80::1%` | INVALID | rejected | — | INVALID |
| 32 | IPv6 in brackets | `[2001:db8::1]` | INVALID | rejected | — | INVALID |
| 33 | IPv6 in brackets with port | `[2001:db8::1]:443` | INVALID | rejected | — | INVALID |
| 34 | IPv6-like, two `::` (EC-101) | `2001:db8::85a3::7334` | INVALID | rejected | — | INVALID |
| 35 | IPv6-like, non-hex group (EC-102) | `2001:db8:gggg::1` | INVALID | rejected | — | INVALID |
| 36 | IPv6-like, 5-digit group | `2001:db8:12345::1` | INVALID | rejected | — | INVALID |
| 37 | IPv6-like, 9 groups | `1:2:3:4:5:6:7:8:9` | INVALID | rejected | — | INVALID |
| 38 | IPv6-like, 7 groups without `::` | `1:2:3:4:5:6:7` | INVALID | rejected | — | INVALID |
| 39 | IPv6-like, 8 groups plus `::` | `1:2:3:4:5:6:7::8` | INVALID | rejected | — | INVALID |
| 40 | IPv6 with prefix length | `2001:db8::/32` | INVALID | **accepted** | `2001:db8::/32` | INVALID |
| 41 | IPv6-like, trailing single colon | `2001:db8::1:` | INVALID | rejected | — | INVALID |
| 42 | IPv6-like, leading single colon | `:2001:db8::1` | INVALID | rejected | — | INVALID |
| 43 | Empty string | `''` | INVALID | rejected | — | INVALID |

Bold `inet` results are the forms where plain `inet` gives a different verdict from Step 2 VAL-IP. The rule matches
the Step 2 expectation in all 43 rows.

---

## 6. Raw input and data files

| Check | Result |
|---|---|
| `log_regex.verify_raw_access_logs()` after the run | 10 / 10 passed |
| Objects written by the script | TEMP tables only (`ip_probe`, `answer_key`, `key_ip`, `ip_eval`, `key_ip_form`) |
| `data/` files | Read only (`data/expected_fields.csv` via `\copy … FROM`) |
