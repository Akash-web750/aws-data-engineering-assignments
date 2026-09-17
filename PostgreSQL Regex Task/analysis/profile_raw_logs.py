#!/usr/bin/env python3
"""
Step 2 - RAW LOG profiling (analysis only; this is NOT the regex extraction parser).

Reads the Step 1 files and measures, using the answer key as ground truth:
  * input characteristics and structural features per format
  * field presence by format, field order, and where each value sits (left anchor / right terminator)
  * value shape classes, exact inventories, placeholder tokens, missing forms and invalid values
  * "first match" probes: how often a naive first-match pattern would pick the wrong candidate
  * compliance of the answer key with the confirmed primary-value rules

Writes:
  analysis/raw_log_profile.json     machine-readable profile
  docs/Step2_Raw_Log_Profile.md     generated tables

The RAW LOGS are only read. Output is deterministic.
"""

import csv
import io
import ipaddress
import json
import re
import statistics
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW_CSV = ROOT / "data" / "raw_access_logs.csv"
KEY_CSV = ROOT / "data" / "expected_fields.csv"
OUT_JSON = ROOT / "analysis" / "raw_log_profile.json"
OUT_MD = ROOT / "docs" / "Step2_Raw_Log_Profile.md"

FIELDS = ("entity_type", "email_address", "resource_url", "event_timestamp", "tool", "latitude", "longitude",
          "ip_address", "action_phrase", "status")
SHORT = {"entity_type": "entity", "email_address": "email", "resource_url": "resource", "event_timestamp": "timestamp",
         "tool": "tool", "latitude": "lat", "longitude": "lon", "ip_address": "ip", "action_phrase": "action",
         "status": "status"}
FORMATS = ("F1", "F2", "F3", "F4", "F5", "NONE")
STATES = ("VALID", "INVALID", "PLACEHOLDER", "MISSING")
DOC_NETS = tuple(ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "2001:db8::/32"))
CHAR_NAMES = {"\n": "LF", "\r": "CR", "\t": "TAB", " ": "SPACE", "\xa0": "NBSP", "\x07": "BEL", "\x1b": "ESC"}


def ranked(counter, limit=None):
    items = sorted(counter.items(), key=lambda kv: (-kv[1], str(kv[0])))
    return items if limit is None else items[:limit]


def visible(text):
    return "".join({" ": "␠", "\t": "⇥", "\xa0": "⍽", "\n": "⏎", "\r": "␍"}.get(ch, ch) for ch in text)


# --------------------------------------------------------------------------- #
# Loading
# --------------------------------------------------------------------------- #
def load_rows():
    text = RAW_CSV.read_bytes().decode("utf-8")
    null_ids = {int(x) for x in re.findall(r"(?m)^(\d+),$", text)}
    reader = csv.reader(io.StringIO(text, newline=""))
    next(reader)
    raw_by_id = {int(log_id): (None if int(log_id) in null_ids else value) for log_id, value in reader}
    with open(KEY_CSV, newline="", encoding="utf-8") as fh:
        key_rows = list(csv.DictReader(fh))
    rows = []
    for k in key_rows:
        log_id = int(k["log_id"])
        rows.append({"log_id": log_id, "case_id": k["case_id"], "format": k["format_family"], "raw": raw_by_id[log_id],
                     "key": k, "tags": {t for t in k["scenario_tags"].split(";") if t},
                     "secondary": [s for s in k["secondary_values"].split(";") if s]})
    return rows


# --------------------------------------------------------------------------- #
# Locating answer-key values inside the RAW LOG
# --------------------------------------------------------------------------- #
def occurrence_pattern(value):
    left = r"(?<![A-Za-z0-9_])(?<!\d\.)" if value[0].isalnum() else ""
    right = r"(?![A-Za-z0-9_])(?!\.\d)" if value[-1].isalnum() else ""
    return re.compile(left + re.escape(value) + right)


def locate(row):
    """Assign each present (VALID/INVALID) value a non-overlapping span; unique values are placed first."""
    raw, k = row["raw"], row["key"]
    if not raw:
        return {}, {}
    candidates = {}
    for f in FIELDS:
        value = k[f]
        if k[f + "_validity"] in ("VALID", "INVALID") and value:
            candidates[f] = [m.start() for m in occurrence_pattern(value).finditer(raw)] or [raw.find(value)]
    spans, taken = {}, []
    for f in sorted(candidates, key=lambda name: (len(candidates[name]), FIELDS.index(name))):
        length = len(k[f])
        chosen = next((s for s in candidates[f] if all(s + length <= a or s >= b for a, b in taken)),
                      candidates[f][0])
        spans[f] = (chosen, chosen + length)
        taken.append(spans[f])
    return spans, {f: len(c) for f, c in candidates.items()}


RFC5424_HEADER = re.compile(r"<\d{1,3}>\d $")
ANCHOR_PATTERNS = (
    ("json", re.compile(r'"([A-Za-z_]+)"\s*:\s*([\"\[{]?)$')),
    ("wkt", re.compile(r"(?<![\w.])([A-Za-z_]+)=([A-Z]+)\($")),
    ("kv", re.compile(r'(?<![\w.])([A-Za-z_]+)=(<|"|mailto:)?$')),
    ("word", re.compile(r"(?<![\w.@/:%-])([A-Za-z]+:?) +([<\[(\"]?)$")),
    ("punct", re.compile(r"([\[\]()<>\";|,{}-])\s*$")),
)
SHORT_GAP = re.compile(r"[\s\]),>]{1,3}")


def left_anchor(raw, start, spans, field):
    line_start = raw.rfind("\n", 0, start) + 1
    left = raw[line_start:start]
    if not left:
        return "^ start of log" if line_start == 0 else "^ start of a later line"
    if not left.strip():
        return "^ after leading whitespace"
    if RFC5424_HEADER.fullmatch(left):
        return "after <PRI>VERSION␠ (RFC 5424 header)"
    previous = [(end, f) for f, (s, end) in spans.items() if f != field and line_start <= end <= start]
    if previous:
        end, prev_field = max(previous)
        if SHORT_GAP.fullmatch(raw[end:start]):
            return f"after {prev_field} {visible(raw[end:start])}"
    tail = left[-60:]
    for kind, pattern in ANCHOR_PATTERNS:
        m = pattern.search(tail)
        if not m:
            continue
        if kind == "json":
            return f'"{m.group(1)}":{m.group(2)}'
        if kind == "wkt":
            return f"{m.group(1)}={m.group(2)}("
        if kind == "kv":
            return f"{m.group(1)}={m.group(2) or ''}"
        if kind == "word":
            return f"{m.group(1)}␠{m.group(2)}"
        return visible(m.group(0))
    return "other: " + visible(re.sub(r"\d", "9", tail[-6:]))


def right_terminator(raw, end):
    if end >= len(raw):
        return "EOL"
    ch, nxt = raw[end], raw[end + 1:end + 2]
    if ch == ":" and nxt.isdigit():
        return ":port"
    if ch == "]" and nxt == ":":
        return "]:port"
    if ch == "." and end + 1 >= len(raw):
        return ". EOL"
    if ch == " ":
        word = re.match(r"[A-Za-z]+", raw[end + 1:end + 20])
        return "SPACE " + (word.group(0) if word else CHAR_NAMES.get(nxt, nxt) if nxt else "EOL")
    return CHAR_NAMES.get(ch, ch)


# --------------------------------------------------------------------------- #
# Structural features (descriptive; not a format detector)
# --------------------------------------------------------------------------- #
FEATURES = (
    ("starts with a digit", lambda r: bool(re.match(r"\d", r))),
    ("starts with `[`", lambda r: r.startswith("[")),
    ("starts with syslog `Mon dd HH:`", lambda r: bool(re.match(r"[A-Z][a-z]{2} [ \d]\d \d\d:", r))),
    ("starts with `<PRI>VERSION `", lambda r: bool(re.match(r"<\d{1,3}>\d ", r))),
    ("starts with IP[:port] then ` - `", lambda r: bool(re.match(
        r"(?:\d{1,3}(?:\.\d{1,3}){3}|\[?[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*\]?)(?::\d+)? - ", r))),
    ("contains `|`", lambda r: "|" in r),
    ("3+ `key=` labels", lambda r: len(re.findall(r"(?<![\w.])[A-Za-z_]+=", r)) >= 3),
    ("contains JSON object `{\"`", lambda r: bool(re.search(r"\{\s*\"", r))),
    ("quoted HTTP request line", lambda r: bool(re.search(r"\"(?:[A-Z]+ \S+ HTTP/\d\.\d|-)\" ", r))),
    ("9+ semicolons", lambda r: r.count(";") >= 9),
    ("sentence verb (was/logged/failed/…)", lambda r: bool(re.search(
        r"\b(?:was|logged|failed|successfully|authenticated|attempted|requested|had|hit|connecting)\b", r))),
)


# --------------------------------------------------------------------------- #
# Shape classifiers (describe values that are already known; they do not extract)
# --------------------------------------------------------------------------- #
TS_SHAPES = tuple((name, re.compile(pattern)) for name, pattern in (
    ("epoch_milliseconds", r"\d{13}"),
    ("epoch_seconds", r"\d{10}"),
    ("iso8601_T_microseconds_offset", r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{2}:\d{2}"),
    ("iso8601_T_ms_Z", r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"),
    ("iso8601_T_ms_offset", r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}"),
    ("iso8601_T_Z", r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"),
    ("iso8601_lowercase_t_z", r"\d{4}-\d{2}-\d{2}t\d{2}:\d{2}:\d{2}z"),
    ("iso8601_T_offset", r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}"),
    ("date_space_time_ms", r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}"),
    ("date_space_time_tz_abbrev", r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [A-Z]{2,5}"),
    ("date_space_time", r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"),
    ("apache_clf", r"\d{2}/[A-Z][a-z]{2}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4}"),
    ("us_mdy_12h", r"\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2} [AP]M"),
    ("us_mdy_12h_short", r"\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2} [AP]M"),
    ("syslog_rfc3164_no_year", r"[A-Z][a-z]{2} [ \d]\d \d{2}:\d{2}:\d{2}"),
    ("dmy_dash_hms", r"\d{2}-\d{2}-\d{4} \d{2}:\d{2}:\d{2}"),
    ("dmy_dash_hm", r"\d{2}-\d{2}-\d{4} \d{2}:\d{2}"),
    ("ymd_slash_hms", r"\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}"),
    ("compact_basic_iso", r"\d{8}T\d{6}"),
))


def timestamp_shape(v):
    return next((name for name, pattern in TS_SHAPES if pattern.fullmatch(v)), "other")


def email_flags(v):
    local, _, domain = v.partition("@")
    multi_suffix = bool(re.search(r"\.(co\.uk|gov\.in|com\.au)$", domain, re.I))
    checks = (
        ("non_ascii", not v.isascii()),
        ("obfuscated_[at]_[dot]", "[at]" in v),
        ("contains_space", " " in v),
        ("no_at_sign", "@" not in v),
        ("multiple_at_signs", v.count("@") > 1),
        ("empty_local_part", "@" in v and not local),
        ("consecutive_dots", ".." in v),
        ("leading_dot", local.startswith(".")),
        ("trailing_dot", v.endswith(".")),
        ("domain_without_dot", "@" in v and bool(domain) and "." not in domain.strip("@")),
        ("plus_tag", "+" in local),
        ("all_uppercase", any(c.isalpha() for c in v) and v == v.upper()),
        ("multi_part_public_suffix", multi_suffix),
        ("subdomain", domain.count(".") >= (3 if multi_suffix else 2)),
        ("digits_in_local", bool(re.search(r"\d", local))),
        ("underscore_in_local", "_" in local),
        ("hyphen_in_local", "-" in local),
        ("internal_domain", domain.lower().endswith(".internal")),
    )
    return [name for name, hit in checks if hit] or ["simple"]


def resource_class(v):
    m = re.match(r"([A-Za-z][A-Za-z0-9+.-]*)://", v)
    if m:
        return f"{m.group(1).lower()}://"
    if re.match(r"[A-Za-z]+:/[^/]", v):
        return "malformed: scheme with single slash"
    if re.match(r"[A-Za-z]+//", v):
        return "malformed: scheme missing colon"
    if re.match(r"[A-Za-z]:\\", v):
        return "windows drive path"
    if v.startswith("\\\\"):
        return "UNC path"
    if re.match(r"/(etc|var|opt|home|srv)/", v):
        return "unix filesystem path"
    if v.startswith("/"):
        return "relative web path"
    return "other"


def resource_flags(v):
    checks = (
        ("query_string", "?" in v),
        ("fragment", "#" in v),
        ("explicit_port", bool(re.search(r"://[^/]*:\d+", v))),
        ("percent_encoding", bool(re.search(r"%[0-9A-Fa-f]{2}", v))),
        ("contains_space", " " in v),
        ("embedded_credentials", bool(re.search(r"://[^/@]+:[^/@]+@", v))),
        ("ipv4_host", bool(re.search(r"://\d{1,3}(\.\d{1,3}){3}", v))),
        ("ipv6_host", "://[" in v),
        ("backslashes", "\\" in v),
        ("date_inside", bool(re.search(r"\d{4}-\d{2}-\d{2}", v))),
        ("ipv4_like_version_inside", bool(re.search(r"/\d{1,3}(\.\d{1,3}){3}/", v))),
        ("sql_injection_characters", "'--" in v),
        ("trailing_slash", v.endswith(("/", "\\"))),
    )
    return [name for name, hit in checks if hit]


def tool_class(v):
    if v.startswith("Mozilla/5.0"):
        return "browser user agent (full)"
    if re.fullmatch(r"[A-Za-z][\w.-]*/v?\d[\w.]*", v):
        return "product/version"
    if re.fullmatch(r"[A-Za-z]+_\d[\w.]*", v):
        return "product_version (underscore)"
    if re.fullmatch(r"[A-Za-z]+ \d[\d.]*", v):
        return "product version (space)"
    if " " in v and "/" in v:
        return "compound user agent"
    return "other"


def tool_product(v):
    if v.startswith("Mozilla/5.0"):
        for marker, name in (("Edg/", "Edge (UA)"), ("Firefox/", "Firefox (UA)"), ("Mobile/", "Mobile Safari (UA)"),
                             ("Chrome/", "Chrome (UA)"), ("Safari/", "Safari (UA)")):
            if marker in v:
                return name
        return "unknown browser (UA)"
    return re.split(r"[/_ ]", v, maxsplit=1)[0]


COORD_SHAPES = tuple((name, re.compile(pattern)) for name, pattern in (
    ("signed decimal", r"-?\d{1,3}\.\d+"),
    ("decimal + space + hemisphere", r"\d{1,3}\.\d+ [NSEW]"),
    ("hemisphere + decimal", r"[NSEW]\d{1,3}\.\d+"),
    ("negative decimal + hemisphere", r"-\d{1,3}\.\d+ [NSEW]"),
    ("DMS ascii  D°MM'SS.s\"H", r"\d{1,3}°\d{2}'\d{2}\.\d\"[NSEW]"),
    ("DMS unicode primes with spaces", r"\d{1,3}° \d{2}′ \d{2}\.\d″ [NSEW]"),
    ("NaN", r"NaN"),
    ("decimal comma", r"-?\d{1,3},\d+"),
))


def coordinate_shape(v):
    return next((name for name, pattern in COORD_SHAPES if pattern.fullmatch(v)), "other")


def ip_class(v):
    if ":" in v:
        address = v.split("%")[0]
        if re.search(r"[^0-9A-Fa-f:.]", address):
            return "ipv6: non-hex characters"
        if v.count("::") > 1:
            return "ipv6: more than one ::"
        if "%" in v:
            return "ipv6: zone id"
        if "." in v:
            return "ipv6: ipv4-mapped"
        if "::" in v:
            return "ipv6: compressed"
        return "ipv6: full 8 groups" if v.count(":") == 7 else "ipv6: other"
    parts = v.split(".")
    if not all(p.isdigit() for p in parts):
        return "other"
    if len(parts) != 4:
        return f"ipv4: {len(parts)} octets"
    if any(int(p) > 255 for p in parts):
        return "ipv4: octet > 255"
    if any(len(p) > 1 and p.startswith("0") for p in parts):
        return "ipv4: leading zeros"
    return "ipv4: dotted quad"


def ip_range(v):
    try:
        address = ipaddress.ip_address(v)
    except ValueError:
        return None
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    if any(address in net for net in DOC_NETS if net.version == address.version):
        return "documentation range"
    if address.is_loopback:
        return "loopback"
    if address.is_link_local:
        return "link-local"
    if address.is_private:
        return "private (RFC 1918)"
    return "other"


def status_class(v):
    if re.fullmatch(r"\d{3}", v):
        return "HTTP code"
    if re.fullmatch(r"\d{3} [A-Za-z][A-Za-z ]*", v):
        return "HTTP code + reason phrase"
    if re.fullmatch(r"[A-Z_]+", v):
        return "word, uppercase"
    if re.fullmatch(r"[a-z_]+", v):
        return "word, lowercase"
    if re.fullmatch(r"[A-Za-z_]+", v):
        return "word, mixed case"
    if re.fullmatch(r"[0-9A-Za-z]{3}", v):
        return "code containing letters"
    return "symbol / other"


# --------------------------------------------------------------------------- #
# Naive first-match probes (measurement only)
# --------------------------------------------------------------------------- #
EMAIL_PROBE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
IPV4_PROBE = re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])")
ISO_DATE_PROBE = re.compile(r"\d{4}-\d{2}-\d{2}")
URL_PROBE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>|;,)]+")
OUTCOME_WORD_PROBE = re.compile(r"(?i)\b(?:grant\w*|denied|deny|allow\w*|block\w*|reject\w*|declin\w*|forbidden|"
                                r"fail\w*|success\w*|permit\w*|unauthori[sz]ed)\b")
DECIMAL_PROBE = re.compile(r"(?<![\w.])-?\d{1,3}\.\d{2,}(?![\w.])")


def field_at(spans, position):
    return next((f for f, (a, b) in spans.items() if a <= position < b), "outside any field")


def run_probes(rows, located):
    def new(pattern, question):
        return {"pattern": pattern, "question": question, "rows_evaluated": 0, "rows_first_match_wrong": 0,
                "wrong_by_format": Counter(), "wrong_first_match_location": Counter(), "examples": []}

    probes = {
        "email": new(EMAIL_PROBE.pattern, "Is the first e-mail-shaped token the expected VALID email?"),
        "email_false_positive": new(EMAIL_PROBE.pattern, "Rows whose email is not VALID but an e-mail-shaped token exists"),
        "ipv4": new(IPV4_PROBE.pattern, "Is the first dotted quad the expected VALID IPv4?"),
        "ipv4_false_positive": new(IPV4_PROBE.pattern, "Rows whose IP is not a VALID IPv4 but a dotted quad exists"),
        "iso_date": new(ISO_DATE_PROBE.pattern, "Is the first YYYY-MM-DD token inside the event timestamp?"),
        "url": new(URL_PROBE.pattern, "Is the first scheme://… token exactly the expected resource?"),
        "outcome_keyword": new(OUTCOME_WORD_PROBE.pattern,
                               "Rows with outcome keywords outside both the action phrase and the status"),
        "decimal_latitude": new(DECIMAL_PROBE.pattern, "Is the first 2+ dp decimal the expected decimal latitude?"),
    }

    def record(name, row, location):
        probe = probes[name]
        probe["rows_first_match_wrong"] += 1
        probe["wrong_by_format"][row["format"]] += 1
        probe["wrong_first_match_location"][location] += 1
        if len(probe["examples"]) < 6:
            probe["examples"].append(row["case_id"])

    for row in rows:
        raw, k = row["raw"], row["key"]
        if not raw:
            continue
        spans = located[row["log_id"]]

        matches = list(EMAIL_PROBE.finditer(raw))
        if k["email_address_validity"] == "VALID":
            probes["email"]["rows_evaluated"] += 1
            if not matches or (matches[0].start(), matches[0].end()) != spans.get("email_address"):
                record("email", row, field_at(spans, matches[0].start()) if matches else "no match")
        elif matches:
            probes["email_false_positive"]["rows_evaluated"] += 1
            record("email_false_positive", row, field_at(spans, matches[0].start()))

        matches = list(IPV4_PROBE.finditer(raw))
        if k["ip_address_validity"] == "VALID" and ip_class(k["ip_address"]) == "ipv4: dotted quad":
            probes["ipv4"]["rows_evaluated"] += 1
            if not matches or matches[0].group(0) != k["ip_address"]:
                record("ipv4", row, field_at(spans, matches[0].start()) if matches else "no match")
        elif matches:
            probes["ipv4_false_positive"]["rows_evaluated"] += 1
            record("ipv4_false_positive", row, field_at(spans, matches[0].start()))

        matches = list(ISO_DATE_PROBE.finditer(raw))
        if matches:
            probes["iso_date"]["rows_evaluated"] += 1
            span = spans.get("event_timestamp")
            if not span or not span[0] <= matches[0].start() < span[1]:
                record("iso_date", row, field_at(spans, matches[0].start()))

        matches = list(URL_PROBE.finditer(raw))
        if matches:
            probes["url"]["rows_evaluated"] += 1
            if matches[0].group(0) != k["resource_url"]:
                location = field_at(spans, matches[0].start())
                record("url", row, location + (" (token boundary differs)" if location == "resource_url" else ""))

        excluded = [spans[f] for f in ("action_phrase", "status") if f in spans]
        outside = [m for m in OUTCOME_WORD_PROBE.finditer(raw) if not any(a <= m.start() < b for a, b in excluded)]
        if outside:
            probes["outcome_keyword"]["rows_evaluated"] += 1
            record("outcome_keyword", row, field_at(spans, outside[0].start()))

        matches = list(DECIMAL_PROBE.finditer(raw))
        if k["latitude_validity"] == "VALID" and coordinate_shape(k["latitude"]) == "signed decimal":
            probes["decimal_latitude"]["rows_evaluated"] += 1
            if not matches or (matches[0].start(), matches[0].end()) != spans.get("latitude"):
                record("decimal_latitude", row, field_at(spans, matches[0].start()) if matches else "no match")
    return probes


# --------------------------------------------------------------------------- #
# Primary-value rule compliance (confirmed decisions)
# --------------------------------------------------------------------------- #
def primary_rule_checks(rows, located):
    checks = []
    for row in rows:
        raw, k, spans = row["raw"], row["key"], located[row["log_id"]]
        if not raw:
            continue
        for item in row["secondary"]:
            name, _, value = item.partition("=")
            if name in ("delegated_email", "notify_email", "email_like_in_resource"):
                rule, field = "email = acting person", "email_address"
                ok = k[field] != value
            elif name == "ingested_at":
                rule, field = "timestamp = event time", "event_timestamp"
                ok = k[field] != value
            elif name == "proxy_ip":
                rule, field = "ip = original client (first X-Forwarded-For entry)", "ip_address"
                xff = re.search(r'xff="([^"]+)"', raw)
                ok = (xff.group(1).split(",")[0].strip() == k[field]) if xff else raw.find(k[field]) < raw.find(value)
            else:
                continue
            checks.append({"case_id": row["case_id"], "rule": rule, "primary": k[field], "secondary": item,
                           "satisfied": ok})
        if "date_in_resource" in row["tags"] and "event_timestamp" in spans and "resource_url" in spans:
            date = ISO_DATE_PROBE.search(k["resource_url"]).group(0)
            ts_start = spans["event_timestamp"][0]
            res_start, res_end = spans["resource_url"]
            checks.append({"case_id": row["case_id"], "rule": "timestamp = event time",
                           "primary": k["event_timestamp"], "secondary": f"date_in_resource={date}",
                           "satisfied": not res_start <= ts_start < res_end})
    return checks


# --------------------------------------------------------------------------- #
# Profile assembly
# --------------------------------------------------------------------------- #
F1_KEYS = {"entity_type": ("entity", "entity_type", "type"), "email_address": ("email", "user", "principal"),
           "resource_url": ("resource", "url", "path"), "tool": ("tool", "client", "agent"),
           "latitude": ("lat", "latitude", "geo"), "longitude": ("lon", "lng", "longitude", "geo"),
           "status": ("status", "result", "outcome")}


def missing_form(row, field):
    raw, fmt = row["raw"], row["format"]
    if fmt == "F1":
        keys = F1_KEYS.get(field, ())
        if keys and re.search(r"(?:^|[|\t]\s*)(?:%s)=\s*(?=\||$)" % "|".join(keys), raw):
            return "key present, empty value"
        return "key absent"
    if fmt == "F2":
        if field == "email_address" and "email_absent_anonymous" in row["tags"]:
            return "sentence says 'anonymous'"
        if field == "resource_url" and "an unspecified resource" in raw:
            return "sentence says 'an unspecified resource'"
        return "clause omitted"
    if fmt == "F3":
        return "JSON key absent"
    if fmt == "F4":
        return "key=value extra absent"
    if fmt == "F5":
        return "empty positional column"
    return "absent"


def build_profile(rows):
    located, occurrences = {}, {}
    for row in rows:
        located[row["log_id"]], occurrences[row["log_id"]] = locate(row)

    chars, non_ascii, controls = Counter(), Counter(), Counter()
    lengths = defaultdict(list)
    features = {fmt: Counter() for fmt in FORMATS}
    blank_or_null = Counter()
    for row in rows:
        raw = row["raw"]
        if raw is None:
            chars["SQL NULL"] += 1
            continue
        if raw == "":
            chars["empty string"] += 1
        elif not raw.strip():
            chars["whitespace only"] += 1
        if "\n" in raw.rstrip("\r\n"):
            chars["multi-line (LF inside the log)"] += 1
        if raw.endswith("\r\n"):
            chars["ends with CR LF"] += 1
        if "\t" in raw.strip():
            chars["tab inside the log"] += 1
        if "\xa0" in raw:
            chars["non-breaking space"] += 1
        if raw.strip() and raw != raw.strip():
            chars["leading/trailing whitespace"] += 1
        if not raw.isascii():
            chars["contains non-ASCII"] += 1
        for ch in set(raw):
            if ord(ch) > 127:
                non_ascii[ch] += 1
            elif ord(ch) < 32 or ord(ch) == 127:
                controls[ch] += 1
        if raw.strip():
            lengths[row["format"]].append(len(raw))
            lengths["ALL"].append(len(raw))
            stripped = raw.lstrip()
            for name, test in FEATURES:
                if test(stripped):
                    features[row["format"]][name] += 1
        else:
            blank_or_null[row["format"]] += 1

    def length_stats(values):
        values = sorted(values)
        return {"rows": len(values), "min": values[0], "median": int(statistics.median(values)),
                "p95": values[int(0.95 * (len(values) - 1))], "max": values[-1]}

    profile = {
        "row_count": len(rows),
        "input_characteristics": dict(ranked(chars)),
        "non_ascii_characters": [{"char": ch, "codepoint": f"U+{ord(ch):04X}",
                                  "name": unicodedata.name(ch, "UNKNOWN"), "rows": n} for ch, n in ranked(non_ascii)],
        "control_characters": [{"codepoint": f"U+{ord(ch):04X}", "name": CHAR_NAMES.get(ch, "CONTROL"), "rows": n}
                               for ch, n in ranked(controls)],
        "length_by_format": {fmt: length_stats(lengths[fmt]) for fmt in ("ALL",) + FORMATS if lengths[fmt]},
        "structural_features_by_format": {
            fmt: {"non_blank_rows": len(lengths[fmt]), **{name: features[fmt][name] for name, _ in FEATURES}}
            for fmt in FORMATS if lengths[fmt]},
    }

    presence = {fmt: {f: Counter() for f in FIELDS} for fmt in FORMATS}
    for row in rows:
        for f in FIELDS:
            presence[row["format"]][f][row["key"][f + "_validity"]] += 1
    profile["presence_by_format"] = {fmt: {f: {s: presence[fmt][f][s] for s in STATES} for f in FIELDS}
                                     for fmt in FORMATS}

    orders = {fmt: Counter() for fmt in FORMATS}
    anchors = {f: {fmt: Counter() for fmt in FORMATS} for f in FIELDS}
    terminators = {f: {fmt: Counter() for fmt in FORMATS} for f in FIELDS}
    repeated = Counter()
    for row in rows:
        spans = located[row["log_id"]]
        if not spans:
            continue
        order = tuple(SHORT[f] for f, _ in sorted(spans.items(), key=lambda item: item[1][0]))
        orders[row["format"]][" > ".join(order)] += 1
        for f, (start, end) in spans.items():
            anchors[f][row["format"]][left_anchor(row["raw"], start, spans, f)] += 1
            terminators[f][row["format"]][right_terminator(row["raw"], end)] += 1
            if occurrences[row["log_id"]].get(f, 1) > 1:
                repeated[f] += 1
    profile["field_order_by_format"] = {fmt: ranked(orders[fmt], 8) for fmt in FORMATS if orders[fmt]}
    profile["distinct_field_orders"] = {fmt: len(orders[fmt]) for fmt in FORMATS if orders[fmt]}
    profile["left_anchors"] = {f: {fmt: ranked(anchors[f][fmt]) for fmt in FORMATS if anchors[f][fmt]} for f in FIELDS}
    profile["right_terminators"] = {f: {fmt: ranked(terminators[f][fmt]) for fmt in FORMATS if terminators[f][fmt]}
                                    for f in FIELDS}
    profile["values_occurring_more_than_once_in_their_log"] = dict(ranked(repeated))

    coord_order = Counter()
    for row in rows:
        spans = located[row["log_id"]]
        if "latitude" in spans and "longitude" in spans:
            lat_first = spans["latitude"][0] < spans["longitude"][0]
            first_field = "latitude" if lat_first else "longitude"
            container = left_anchor(row["raw"], spans[first_field][0], spans, first_field)
            coord_order[(row["format"], container, "latitude first" if lat_first else "longitude first")] += 1
    profile["coordinate_pair_order"] = [{"format": fmt, "container_anchor": c, "order": o, "rows": n}
                                        for (fmt, c, o), n in ranked(coord_order)]

    shapes, examples = {}, defaultdict(dict)

    def shape_counter(field, classifier, by_format=False, states=("VALID", "INVALID")):
        counter = Counter()
        for row in rows:
            value, state = row["key"][field], row["key"][field + "_validity"]
            if state not in states:
                continue
            labels = classifier(value)
            for label in labels if isinstance(labels, list) else [labels]:
                counter[(row["format"], label, state) if by_format else (label, state)] += 1
                examples[field].setdefault(f"{label}|{state}", (row["case_id"], value))
        return counter

    shapes["event_timestamp"] = shape_counter("event_timestamp", timestamp_shape, by_format=True)
    shapes["email_address"] = shape_counter("email_address", email_flags)
    shapes["resource_url"] = shape_counter("resource_url", resource_class, by_format=True)
    shapes["resource_url_features"] = shape_counter("resource_url", resource_flags)
    shapes["tool"] = shape_counter("tool", tool_class, by_format=True)
    shapes["tool_product"] = shape_counter("tool", tool_product)
    shapes["latitude"] = shape_counter("latitude", coordinate_shape, by_format=True)
    shapes["longitude"] = shape_counter("longitude", coordinate_shape, by_format=True)
    shapes["ip_address"] = shape_counter("ip_address", ip_class, by_format=True)
    shapes["ip_address_range"] = shape_counter("ip_address", lambda v: ip_range(v) or "not parseable",
                                               states=("VALID",))
    shapes["status"] = shape_counter("status", status_class, by_format=True)
    profile["shapes"] = {name: [{"key": list(k), "rows": n} for k, n in ranked(c)] for name, c in shapes.items()}
    profile["shape_examples"] = {f: {label: {"case_id": cid, "value": v} for label, (cid, v) in sorted(ex.items())}
                                 for f, ex in examples.items()}

    precision = Counter()
    for row in rows:
        for f in ("latitude", "longitude"):
            v = row["key"][f]
            if row["key"][f + "_validity"] == "VALID" and coordinate_shape(v) in (
                    "signed decimal", "decimal + space + hemisphere", "hemisphere + decimal"):
                precision[len(re.search(r"\.(\d+)", v).group(1))] += 1
    profile["coordinate_decimal_places"] = dict(sorted(precision.items()))

    inventories = {}
    for f in ("entity_type", "action_phrase", "status", "tool"):
        counter, outcome_map, fmt_map = Counter(), defaultdict(Counter), defaultdict(Counter)
        for row in rows:
            if row["key"][f + "_validity"] in ("VALID", "INVALID"):
                value = row["key"][f]
                counter[value] += 1
                outcome_map[value][row["key"]["outcome_class"]] += 1
                fmt_map[value][row["format"]] += 1
        inventories[f] = [{"value": v, "rows": n, "formats": dict(sorted(fmt_map[v].items())),
                           "outcome_class": dict(ranked(outcome_map[v]))} for v, n in ranked(counter)]
    entity_groups = defaultdict(Counter)
    for item in inventories["entity_type"]:
        entity_groups[re.sub(r"[\s_-]+", "_", item["value"]).upper()][item["value"]] += item["rows"]
    profile["inventories"] = inventories
    profile["entity_spelling_groups_analysis_only"] = {g: dict(ranked(c)) for g, c in sorted(entity_groups.items())}

    placeholders = {f: Counter() for f in FIELDS}
    invalid = {f: [] for f in FIELDS}
    missing_forms = {f: Counter() for f in FIELDS}
    for row in rows:
        for f in FIELDS:
            state = row["key"][f + "_validity"]
            if state == "PLACEHOLDER":
                placeholders[f][(row["format"], row["key"][f])] += 1
            elif state == "INVALID":
                invalid[f].append({"case_id": row["case_id"], "format": row["format"], "value": row["key"][f],
                                   "tags": sorted(t for t in row["tags"] if "invalid" in t or t.startswith(SHORT[f]))})
            elif state == "MISSING" and row["format"] != "NONE" and row["raw"]:
                missing_forms[f][(row["format"], missing_form(row, f))] += 1
    profile["placeholders"] = {f: [{"format": fmt, "token": tok, "rows": n} for (fmt, tok), n in ranked(c)]
                               for f, c in placeholders.items() if c}
    profile["invalid_values"] = {f: v for f, v in invalid.items() if v}
    profile["missing_forms"] = {f: [{"format": fmt, "form": form, "rows": n} for (fmt, form), n in ranked(c)]
                                for f, c in missing_forms.items() if c}

    profile["secondary_value_kinds"] = dict(ranked(Counter(item.partition("=")[0]
                                                           for row in rows for item in row["secondary"])))
    profile["probes"] = run_probes(rows, located)
    profile["primary_rule_checks"] = primary_rule_checks(rows, located)

    multiline = []
    for row in rows:
        raw = row["raw"]
        if raw and "\n" in raw.rstrip("\r\n"):
            spans = located[row["log_id"]]
            multiline.append({"case_id": row["case_id"], "lines": raw.count("\n") + 1,
                              "field_lines": {SHORT[f]: raw.count("\n", 0, s) + 1
                                              for f, (s, _) in sorted(spans.items(), key=lambda i: i[1][0])}})
    profile["multi_line_logs"] = multiline
    profile["broken_or_blank_rows_by_format"] = dict(blank_or_null)
    return profile


# --------------------------------------------------------------------------- #
# Markdown
# --------------------------------------------------------------------------- #
def code(value, limit=80):
    text = str(value)
    if len(text) > limit:
        text = text[:limit] + "…"
    text = text.replace("\r", "␍").replace("\n", "⏎").replace("\t", "⇥").replace("\xa0", "⍽").replace("\x1b", "␛")
    text = text.replace("|", "\\|")
    return f"`{text}`" if text.strip() else f"`{text}` (whitespace)"


def table(headers, rows):
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    lines += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(lines)


def compact(items, limit=8):
    shown = [f"{code(k, 45)} {n:,}" for k, n in items[:limit]]
    if len(items) > limit:
        shown.append(f"+{len(items) - limit} more")
    return " · ".join(shown)


def render_markdown(p):
    out = ["# Step 2 — RAW LOG Profile (generated)", "",
           "> Generated by `analysis/profile_raw_logs.py` from `data/raw_access_logs.csv` and "
           "`data/expected_fields.csv`. Do not edit by hand — rerun the script.",
           "> Measurement only; no extraction parser is involved. The requirements built on these numbers are in "
           "`docs/Step2_Requirements_and_Variants.md`.", "",
           "Visible markers: `␠` space, `⏎` LF, `␍` CR, `⇥` TAB, `⍽` NBSP, `␛` ESC.", ""]

    out += ["## 1. Input characteristics", "", table(["Characteristic", "Rows"],
                                                      [(k, f"{v:,}") for k, v in p["input_characteristics"].items()]), ""]
    out += ["### Non-ASCII characters", "", table(["Char", "Code point", "Name", "Rows"],
            [(code(c["char"]), c["codepoint"], c["name"], c["rows"]) for c in p["non_ascii_characters"]]), ""]
    out += ["### Control characters", "", table(["Code point", "Name", "Rows"],
            [(c["codepoint"], c["name"], c["rows"]) for c in p["control_characters"]]), ""]
    out += ["### Length (characters, non-blank logs)", "", table(["Format", "Rows", "Min", "Median", "P95", "Max"],
            [(f, s["rows"], s["min"], s["median"], s["p95"], s["max"]) for f, s in p["length_by_format"].items()]), ""]

    out += ["## 2. Structural features by format", "",
            "Share of non-blank logs (leading whitespace ignored) that show each feature. Descriptive only.", ""]
    feats = p["structural_features_by_format"]
    fmts = list(feats)
    body = []
    for name, _ in FEATURES:
        body.append([name] + [f"{100 * feats[f][name] / feats[f]['non_blank_rows']:.1f}%" for f in fmts])
    out += [table(["Feature"] + [f"{f} (n={feats[f]['non_blank_rows']})" for f in fmts], body), ""]

    out += ["## 3. Field presence by format", "", "Cells: VALID / INVALID / PLACEHOLDER / MISSING.", ""]
    body = []
    for f in FIELDS:
        cells = [f]
        for fmt in FORMATS:
            c = p["presence_by_format"][fmt][f]
            cells.append(f"{c['VALID']} / {c['INVALID']} / {c['PLACEHOLDER']} / {c['MISSING']}")
        body.append(cells)
    out += [table(["Field"] + list(FORMATS), body), ""]

    out += ["## 4. Field order by format (top orders)", ""]
    for fmt, orders in p["field_order_by_format"].items():
        out += [f"**{fmt}** — {p['distinct_field_orders'][fmt]} distinct orders", "",
                table(["Order of located fields", "Rows"], [(o, n) for o, n in orders]), ""]

    out += ["## 5. Left anchors (text immediately before each value)", "",
            "`key=` key/value label · `\"key\":` JSON key · `word␠` preceding word · punctuation · "
            "`after <field>` value directly follows another field · `^` start of log.", ""]
    for f in FIELDS:
        out += [f"### {f}", "", table(["Format", "Anchors (rows)"],
                [(fmt, compact(items)) for fmt, items in p["left_anchors"][f].items()]), ""]

    out += ["## 6. Right terminators (character after each value)", ""]
    for f in FIELDS:
        out += [f"### {f}", "", table(["Format", "Terminators (rows)"],
                [(fmt, compact(items)) for fmt, items in p["right_terminators"][f].items()]), ""]
    out += ["Values that occur more than once inside their own log (position chosen by the profiler): "
            + ", ".join(f"{k} {v}" for k, v in p["values_occurring_more_than_once_in_their_log"].items()), ""]

    out += ["## 7. Value shapes", ""]
    ex = p["shape_examples"]

    def shape_table(name, field, by_format):
        rows_out = []
        for item in p["shapes"][name]:
            key = item["key"]
            fmt, label, state = key if by_format else (None, key[0], key[1])
            sample = ex.get(field, {}).get(f"{label}|{state}")
            rows_out.append(([fmt] if by_format else []) + [label, state, item["rows"],
                            f"{sample['case_id']} {code(sample['value'], 60)}" if sample else ""])
        return table((["Format"] if by_format else []) + ["Shape", "Validity", "Rows", "First example"], rows_out)

    for title, name, field, by_format in (
            ("Timestamp", "event_timestamp", "event_timestamp", True),
            ("Email address (feature flags; one value may have several)", "email_address", "email_address", False),
            ("Resource / URL class", "resource_url", "resource_url", True),
            ("Resource / URL features", "resource_url_features", "resource_url", False),
            ("Tool class", "tool", "tool", True),
            ("Tool product", "tool_product", "tool", False),
            ("Latitude", "latitude", "latitude", True),
            ("Longitude", "longitude", "longitude", True),
            ("IP address class", "ip_address", "ip_address", True),
            ("IP address range (VALID only)", "ip_address_range", "ip_address", False),
            ("Status class", "status", "status", True)):
        out += [f"### {title}", "", shape_table(name, field, by_format), ""]
    out += ["### Coordinate decimal places (VALID decimal-style values)", "",
            table(["Decimal places", "Values"], list(p["coordinate_decimal_places"].items())), ""]
    out += ["### Coordinate pair order", "", table(["Format", "Anchor of the first coordinate", "Order", "Rows"],
            [(c["format"], code(c["container_anchor"]), c["order"], c["rows"]) for c in p["coordinate_pair_order"]]), ""]

    out += ["## 8. Inventories (exact values, VALID + INVALID)", ""]
    for f, limit in (("entity_type", None), ("action_phrase", None), ("status", None), ("tool", None)):
        items = p["inventories"][f]
        out += [f"### {f} — {len(items)} distinct values", "",
                table(["Value", "Rows", "Formats", "outcome_class"],
                      [(code(i["value"], 70), i["rows"], ", ".join(f"{k} {v}" for k, v in i["formats"].items()),
                        ", ".join(f"{k} {v}" for k, v in i["outcome_class"].items())) for i in items]), ""]
    out += ["### Entity spelling groups (analysis grouping only — not a normalization decision)", "",
            table(["Group", "Spellings (rows)"], [(g, " · ".join(f"{code(s)} {n}" for s, n in c.items()))
                                                  for g, c in p["entity_spelling_groups_analysis_only"].items()]), ""]

    out += ["## 9. Placeholders and missing forms", ""]
    for f, items in p["placeholders"].items():
        out += [f"**{f}** — " + " · ".join(f"{i['format']} {code(i['token'])} {i['rows']}" for i in items), ""]
    out += ["### How MISSING values appear", ""]
    for f, items in p["missing_forms"].items():
        out += [f"**{f}** — " + " · ".join(f"{i['format']}: {i['form']} {i['rows']}" for i in items), ""]

    out += ["## 10. INVALID values", ""]
    for f, items in p["invalid_values"].items():
        out += [f"### {f} — {len(items)} rows", "", table(["Case", "Format", "Value", "Tags"],
                [(i["case_id"], i["format"], code(i["value"], 60), ", ".join(i["tags"])) for i in items]), ""]

    out += ["## 11. Naive first-match probes", "",
            "Each probe is a deliberately simple pattern. `Wrong` counts rows where taking its first match would "
            "not return the answer-key value; the location column says which field that first match belongs to.", ""]
    out += [table(["Probe", "Pattern", "Question", "Evaluated", "Wrong", "Wrong first match located in", "By format",
                   "Examples"],
                  [(name, code(pr["pattern"], 60), pr["question"], pr["rows_evaluated"], pr["rows_first_match_wrong"],
                    ", ".join(f"{k} {v}" for k, v in ranked(pr["wrong_first_match_location"])),
                    ", ".join(f"{k} {v}" for k, v in ranked(pr["wrong_by_format"])), ", ".join(pr["examples"]))
                   for name, pr in p["probes"].items()]), ""]

    out += ["## 12. Secondary values and confirmed primary-value rules", "",
            table(["Secondary kind", "Rows"], list(p["secondary_value_kinds"].items())), ""]
    checks = p["primary_rule_checks"]
    rules = sorted({c["rule"] for c in checks})
    out += [table(["Rule", "Rows checked", "Satisfied"],
                  [(r, sum(c["rule"] == r for c in checks), sum(c["rule"] == r and c["satisfied"] for c in checks))
                   for r in rules]), ""]
    out += [table(["Case", "Rule", "Primary (answer key)", "Secondary", "Satisfied"],
                  [(c["case_id"], c["rule"], code(c["primary"]), code(c["secondary"]), c["satisfied"])
                   for c in checks if not c["secondary"].startswith("date_in_resource") or c["case_id"].startswith("EC")
                   or not c["satisfied"]]), ""]

    out += ["## 13. Multi-line logs", "", table(["Case", "Lines", "Line of each located field"],
            [(m["case_id"], m["lines"], ", ".join(f"{k}:{v}" for k, v in m["field_lines"].items()))
             for m in p["multi_line_logs"]]), ""]
    return "\n".join(out) + "\n"


def to_jsonable(obj):
    if isinstance(obj, Counter):
        return {str(k): v for k, v in ranked(obj)}
    if isinstance(obj, dict):
        return {str(k): to_jsonable(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [to_jsonable(v) for v in obj]
    return obj


def main():
    rows = load_rows()
    profile = build_profile(rows)
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_bytes((json.dumps(to_jsonable(profile), indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
    OUT_MD.write_bytes(render_markdown(profile).encode("utf-8"))
    print(f"profiled {profile['row_count']} rows -> {OUT_JSON.relative_to(ROOT)}, {OUT_MD.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
