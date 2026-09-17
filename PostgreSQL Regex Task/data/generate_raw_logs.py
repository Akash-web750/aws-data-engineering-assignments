#!/usr/bin/env python3
"""
Step 1 - reproducible RAW LOG sample data for the PostgreSQL Regex Task.

Writes (next to this script by default):
  raw_access_logs.csv    log_id, raw_log   <- the RAW LOGS; never edited after generation
  expected_fields.csv    answer key, joined to the RAW LOGS on log_id
  dataset_manifest.json  seed, counts, distributions and SHA-256 checksums

Standard library only. The same seed and row count always give byte-identical files.

Usage:
  python generate_raw_logs.py              # write the default 5,000-row dataset
  python generate_raw_logs.py --check      # regenerate in memory and compare with the files on disk
  python generate_raw_logs.py --rows 20000 --out-dir some/other/dir
"""

import argparse
import csv
import hashlib
import io
import ipaddress
import json
import random
import re
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from curated_edge_cases import CASES, FIELDS, INVALID, MISSING, PLACEHOLDER, VALID  # noqa: E402

GENERATOR_VERSION = "1.0.0"
DEFAULT_SEED = 20260911
DEFAULT_ROWS = 5000

EVENT_START = datetime(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
EVENT_END = datetime(2026, 6, 30, 23, 59, 59, tzinfo=timezone.utc)
SPAN_SECONDS = int((EVENT_END - EVENT_START).total_seconds())

# Exact shares for generated rows (largest-remainder allocation, then a seeded shuffle).
FORMAT_SHARES = (("F1", 30), ("F2", 20), ("F3", 20), ("F4", 20), ("F5", 10))
OUTCOME_SHARES = (("SUCCESS", 55), ("DECLINED", 35), ("NEUTRAL", 10))

# Per-row probabilities for generated rows.
MISSING_RATES = (("entity_type", 0.07), ("email_address", 0.08), ("resource_url", 0.05),
                 ("tool", 0.10), ("status", 0.06))
COORDINATES_MISSING_RATE = 0.15
INVALID_VALUE_RATE = 0.05
STATUS_CONFLICT_RATE = 0.01
INVALID_FIELD_WEIGHTS = (("email_address", 25), ("event_timestamp", 20), ("ip_address", 20),
                         ("coordinates", 15), ("entity_type", 8), ("resource_url", 7), ("status", 5))

# --------------------------------------------------------------------------- #
# Value pools (fictional people, reserved/placeholder domains, documentation IP ranges)
# --------------------------------------------------------------------------- #
FIRST_NAMES = ("Priya", "Rahul", "Anita", "Meera", "Arjun", "Kavya", "Vikram", "Sneha", "Rohan", "Aisha",
               "Daniel", "Sofia", "Liam", "Emma", "Kenji", "Yuki", "Amara", "Kwame", "Lucas", "Isabela",
               "Olivia", "Noah", "Chen", "Wei", "Fatima", "Omar", "Elena", "Mateo", "Zara", "Ethan",
               "Nadia", "Hiro", "Ingrid", "Sipho", "Grace")
LAST_NAMES = ("Sharma", "Kulkarni", "Desai", "Iyer", "Patel", "Nair", "Menon", "Rao", "Joshi", "Khan",
              "Smith", "Garcia", "Tanaka", "Sato", "Okafor", "Mensah", "Silva", "Santos", "Brown", "Wilson",
              "Li", "Zhang", "Haddad", "Ivanova", "Rossi", "Novak", "Andersen", "Dlamini", "Murphy", "Fernandes")

# (city, latitude, longitude, UTC offset in minutes), weight
CITIES = ((("Mumbai", 19.0760, 72.8777, 330), 14), (("Pune", 18.5204, 73.8567, 330), 12),
          (("Bengaluru", 12.9716, 77.5946, 330), 12), (("London", 51.5074, -0.1278, 0), 10),
          (("New York", 40.7128, -74.0060, -300), 10), (("Sao Paulo", -23.5505, -46.6333, -180), 7),
          (("Rio de Janeiro", -22.9068, -43.1729, -180), 5), (("Sydney", -33.8688, 151.2093, 600), 7),
          (("Tokyo", 35.6762, 139.6503, 540), 7), (("Nairobi", -1.2921, 36.8219, 180), 5),
          (("Reykjavik", 64.1466, -21.9426, 0), 4), (("Singapore", 1.3521, 103.8198, 480), 7))
PRECISION_WEIGHTS = ((2, 5), (3, 10), (4, 50), (5, 15), (6, 12), (7, 8))

ENTITY_WEIGHTS = (("USER", 40), ("CUSTOMER", 15), ("ADMIN", 10), ("SERVICE_ACCOUNT", 12),
                  ("API_CLIENT", 10), ("GUEST", 8), ("BOT", 5))
HUMAN_ENTITIES = ("USER", "CUSTOMER", "ADMIN", "GUEST")
ENTITY_SPELLINGS = {
    "USER": {"upper": "USER", "lower": "user", "title": "User"},
    "CUSTOMER": {"upper": "CUSTOMER", "lower": "customer", "title": "Customer"},
    "ADMIN": {"upper": "ADMIN", "lower": "admin", "title": "Admin"},
    "SERVICE_ACCOUNT": {"upper": "SERVICE_ACCOUNT", "lower": "service_account", "title": "Service Account",
                        "hyphen": "service-account"},
    "API_CLIENT": {"upper": "API_CLIENT", "lower": "api_client", "title": "API Client", "hyphen": "api-client"},
    "GUEST": {"upper": "GUEST", "lower": "guest", "title": "Guest"},
    "BOT": {"upper": "BOT", "lower": "bot", "title": "Bot"},
}
ENTITY_STYLE_WEIGHTS = {
    "F1": (("upper", 60), ("lower", 25), ("title", 10), ("hyphen", 5)),
    "F2": (("title", 1),),
    "F3": (("lower", 70), ("hyphen", 30)),
    "F4": (("upper", 40), ("title", 60)),
    "F5": (("upper", 1),),
}
INVALID_ENTITIES = ("contractor", "VENDOR", "superuser", "intern")

HUMAN_DOMAINS = {
    "USER": (("corp.example.com", 45), ("eu.corp.example.com", 10), ("example.com", 10), ("mail.example.org", 10),
             ("example.co.uk", 10), ("example.gov.in", 5), ("example.com.au", 5), ("hq.example.net", 5)),
    "ADMIN": (("corp.example.com", 80), ("hq.example.net", 20)),
    "CUSTOMER": (("shop.example.org", 40), ("example.com", 25), ("mail.example.co.uk", 20),
                 ("customers.example.net", 15)),
}
EMAIL_PATTERNS = (("dot", 35), ("dot_digits", 10), ("initial", 10), ("underscore", 8), ("hyphen", 7),
                  ("plus", 12), ("upper", 8), ("middle", 5), ("digits", 5))
PLUS_TAGS = ("alerts", "test", "ops", "2026", "billing")
SERVICE_NAMES = ("backup", "etl", "reporting", "deploy", "monitoring", "billing-sync")
PARTNERS = ("bluefin", "redwood", "orbit", "lumen", "cobalt")
BOT_EMAILS = ("bot-monitor@infra.example.internal", "uptime-checker@infra.example.internal",
              "synthetic-probe@infra.example.internal")
ACCENTS = {"e": "é", "o": "ö", "a": "ä", "u": "ü", "i": "ï"}

# (short tool token, full browser user agent)
BROWSERS = (
    ("Chrome/124.0.6367.91", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"),
    ("Chrome/123.0.6312.122", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"),
    ("Firefox/125.0", "Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0"),
    ("Firefox/124.0.2", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) Gecko/20100101 Firefox/124.0"),
    ("Safari/17.4.1", "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"),
    ("Edge/124.0.2478.67", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.2478.67"),
    ("MobileSafari/17.4.1", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Mobile/15E148 Safari/604.1"),
)
CLI_TOOLS = {
    "SERVICE_ACCOUNT": ("aws-cli/2.15.0", "Boto3/1.34.69", "python-requests/2.31.0", "terraform/1.7.2",
                        "Ansible 2.16.4", "kubectl/v1.29.3", "psql/16.2", "OpenSSH_9.6p1"),
    "API_CLIENT": ("python-requests/2.31.0", "okhttp/4.12.0", "Go-http-client/1.1", "PostmanRuntime/7.37.0",
                   "insomnia/8.6.1", "curl/8.4.0"),
    "BOT": ("curl/8.4.0", "Wget/1.21.4", "Go-http-client/1.1", "kube-probe/1.29", "Prometheus/2.51.1"),
    "ADMIN": ("Postman/10.24.3", "curl/8.4.0", "OpenSSH_9.6p1", "psql/16.2", "Insomnia/8.6.1"),
}

PORTAL_PATHS = ("dashboard", "reports/q1", "reports/q2", "reports/weekly", "timesheets", "leave/apply", "payslips",
                "projects/alpha", "wiki/Onboarding", "calendar", "home", "profile/settings", "documents/policies")
FRAGMENTS = ("timeline", "section-3", "summary")
ADMIN_PATHS = ("admin/users?page={k}", "admin/billing/export", "admin/audit", "admin/roles/{n}",
               "admin/payroll/export", "iam/roles")
API_PATHS = ("api/v2/orders/{n}?expand=items", "api/v1/users/{n}/roles", "api/v2/invoices?status=open&page={k}",
             "api/v2/search?q=annual%20report%202025", "api/v2/shipments?status=in_transit")
SHOP_PATHS = ("account", "cart", "checkout", "orders/{n}", "wishlist", "returns/{n}")
PUBLIC_PATHS = ("members/downloads", "catalog/items/{n}", "public/brochure.pdf", "events/2026/registration")
WINDOWS_PATHS = ("C:\\Share\\Finance\\Budget 2026.xlsx", "D:\\Backups\\SQL\\prod_{date}.bak",
                 "C:\\Users\\Public\\Documents\\handover.docx", "E:\\HR\\Contracts\\2026\\offer_{n}.pdf")
UNC_PATHS = ("\\\\fileserver01\\hr$\\contracts\\2026\\", "\\\\nas02\\finance\\reports\\Q{q}\\",
             "\\\\fileserver01\\it$\\scripts\\rotate_keys.ps1")
LINUX_PATHS = ("/var/log/secure", "/etc/ssh/sshd_config", "/opt/app/config/settings.yaml",
               "/home/deploy/.ssh/authorized_keys", "/srv/data/exports/customers_{date}.csv")
DB_RESOURCES = ("db://prod/customers", "db://prod/payments", "postgres://reporting.example.internal:5432/sales",
                "postgres://billing.example.internal:5432/ledger?sslmode=require")
S3_RESOURCES = ("s3://prod-backups/daily/{date}/", "s3://analytics-raw/events/dt={date}/part-{n5}.snappy.parquet",
                "s3://tf-state/prod/network.tfstate")
REFERERS = ("https://portal.corp.example.com/login", "https://sso.example.com/login",
            "https://admin.corp.example.com/users/{n}/edit")

WEB_KINDS = {"https_portal", "relative_portal", "https_shop", "relative_shop", "relative_public", "relative_admin",
             "https_admin", "https_internal", "relative_api", "https_api", "http_health_ip", "relative_health",
             "https_status"}
ENTITY_RESOURCES = {
    "USER": (("https_portal", 50), ("relative_portal", 45), ("windows", 5)),
    "CUSTOMER": (("https_shop", 55), ("relative_shop", 45)),
    "GUEST": (("https_portal", 40), ("relative_public", 60)),
    "ADMIN": (("relative_admin", 35), ("https_admin", 30), ("windows", 10), ("unc", 5), ("linux", 10), ("db", 10)),
    "SERVICE_ACCOUNT": (("s3", 35), ("db", 25), ("linux", 15), ("unc", 10), ("https_internal", 15)),
    "API_CLIENT": (("relative_api", 45), ("https_api", 45), ("ftp", 10)),
    "BOT": (("http_health_ip", 50), ("relative_health", 30), ("https_status", 20)),
}

HTTP_REASONS = {200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 302: "Found", 401: "Unauthorized",
                403: "Forbidden", 404: "Not Found", 429: "Too Many Requests", 500: "Internal Server Error",
                502: "Bad Gateway", 503: "Service Unavailable"}
INVALID_STATUS_WORDS = ("SUCCES", "DENEID", "FAILD", "OKK")
INVALID_STATUS_CODES = ("999", "20O", "4O3", "600")


def _event(F1, F2, F3, F4, F5, words, http):
    return {"F1": F1, "F2": F2, "F3": F3, "F4": F4, "F5": F5, "words": words, "http": http}


EVENTS = {
    "SUCCESS": (
        _event(("Access granted", "ACCESS GRANTED", "access granted"), ("was granted access to", "was allowed to access"),
               ("access granted", "request permitted"), ("Access granted", "Authorized"),
               ("Access granted", "ACCESS PERMITTED"), ("SUCCESS", "success", "OK", "ALLOWED"), (200, 200, 201, 204)),
        _event(("Login successful", "Authenticated successfully"), ("logged in to", "authenticated successfully to"),
               ("authentication succeeded", "login successful"), ("Login successful", "Session started"),
               ("Login successful", "LOGIN OK"), ("SUCCESS", "OK", "ok"), (200, 302)),
        _event(("Permission granted", "Request allowed"), ("was permitted to access", "successfully accessed"),
               ("permitted", "allowed"), ("Request allowed",), ("Permitted",), ("ALLOWED", "SUCCESS", "PASS"), (200,)),
    ),
    "DECLINED": (
        _event(("Access denied", "ACCESS DENIED", "access denied"), ("was denied access to", "was refused access to"),
               ("access denied", "permission denied"), ("Access denied: insufficient privileges", "Forbidden"),
               ("ACCESS DENIED", "Access declined"), ("DENIED", "FAILED", "BLOCKED"), (403,)),
        _event(("Login failed", "Authentication failed"), ("failed to authenticate to", "failed to log in to"),
               ("authentication failed", "login failed"), ("Login failed", "Unauthorized"),
               ("Login attempt rejected", "LOGIN FAILED"), ("FAILED", "fail", "FAIL"), (401,)),
        _event(("Request blocked by policy", "Unauthorized attempt"),
               ("was blocked from accessing", "attempted unauthorized access to"),
               ("blocked by policy", "forbidden"), ("Blocked by WAF policy",), ("Request blocked", "Declined by policy"),
               ("BLOCKED", "DENIED", "REJECTED"), (403,)),
    ),
    "NEUTRAL": (
        _event(("Logout", "User logged out"), ("logged out of",), ("logout",), ("Logout",), ("Logout",),
               ("SUCCESS", "OK"), (200, 302)),
        _event(("MFA challenge issued",), ("was sent an MFA challenge for",), ("mfa challenge issued",),
               ("MFA challenge",), ("MFA challenge",), ("PENDING", "CHALLENGE"), (401,)),
        _event(("Password reset requested",), ("requested a password reset for",), ("password reset requested",),
               ("Password reset requested",), ("Password reset requested",), ("PENDING", "OK"), (202,)),
        _event(("Token expired", "Session timeout"), ("had an expired session token for",), ("token expired",),
               ("Token expired",), ("Session timeout",), ("EXPIRED", "TIMEOUT"), (401,)),
        _event(("Rate limited",), ("was rate limited on",), ("rate limited",), ("Rate limit exceeded",),
               ("Rate limited",), ("THROTTLED", "RATE_LIMITED"), (429,)),
        _event(("Resource not found",), ("requested a missing resource",), ("resource not found",), ("Not found",),
               ("Resource not found",), ("NOT_FOUND",), (404,)),
        _event(("Upstream error",), ("hit a server error on",), ("upstream error",), ("Internal server error",),
               ("Server error",), ("ERROR",), (500, 502, 503)),
    ),
}

MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
UTC_STYLES = {"iso_z", "iso_ms_z", "space", "space_ms", "epoch_s", "epoch_ms"}
NAMED_MONTH_STYLES = {"apache", "syslog"}
DAY_MONTH_AMBIGUOUS_STYLES = {"us_12h", "us_12h_short", "dmy_hm", "dmy_hms"}
NO_TIMEZONE_STYLES = {"space", "space_ms", "us_12h", "us_12h_short", "syslog", "dmy_hm", "dmy_hms", "ymd_slash",
                      "compact"}
F1_TS_STYLES = (("iso_z", 30), ("iso_ms_z", 15), ("iso_offset", 20), ("iso_ms_offset", 10), ("space", 10),
                ("epoch_s", 8), ("epoch_ms", 7))
F4_TS_STYLES = (("space_ms", 45), ("apache", 40), ("iso_offset", 15))
F5_TS_STYLES = (("dmy_hm", 35), ("dmy_hms", 20), ("ymd_slash", 15), ("us_12h_short", 15), ("compact", 15))


# --------------------------------------------------------------------------- #
# Generic helpers
# --------------------------------------------------------------------------- #
def wchoice(rng, pairs):
    """Weighted choice over ((item, weight), ...) using one rng.random() draw."""
    total = sum(weight for _, weight in pairs)
    point = rng.random() * total
    running = 0
    for item, weight in pairs:
        running += weight
        if point < running:
            return item
    return pairs[-1][0]


def expand_quota(total, shares):
    """Exact label counts by largest remainder; ties resolved by share order."""
    weight_sum = sum(weight for _, weight in shares)
    exact = [(label, total * weight / weight_sum) for label, weight in shares]
    counts = {label: int(value) for label, value in exact}
    shortfall = total - sum(counts.values())
    by_remainder = sorted(range(len(exact)), key=lambda i: (-(exact[i][1] - int(exact[i][1])), i))
    for i in by_remainder[:shortfall]:
        counts[exact[i][0]] += 1
    return [label for label, _ in shares for _ in range(counts[label])]


def fill(rng, template):
    """Fill {n} {n5} {k} {q} {date} placeholders in a resource template."""
    return (template
            .replace("{n5}", f"{rng.randint(0, 99999):05d}")
            .replace("{n}", str(rng.randint(1000, 99999)))
            .replace("{k}", str(rng.randint(1, 20)))
            .replace("{q}", str(rng.randint(1, 4)))
            .replace("{date}", f"2026-{rng.randint(1, 6):02d}-{rng.randint(1, 28):02d}"))


class Rec:
    """Answer-key values collected while one RAW LOG line is rendered."""

    def __init__(self):
        self.fields = {}
        self.tags = set()
        self.secondary = []

    def put(self, name, value, state=VALID):
        self.fields[name] = (value, state)


# --------------------------------------------------------------------------- #
# Format-independent event plan
# --------------------------------------------------------------------------- #
def make_email(rng, entity, first, last):
    f, l = first.lower(), last.lower()
    if entity == "GUEST":
        if rng.random() < 0.6:
            return f"guest_{rng.randint(1000, 9999)}@example.com", set()
        return f"visitor.{rng.randint(1000, 9999)}@guest.example.org", set()
    if entity in HUMAN_DOMAINS:
        domain = wchoice(rng, HUMAN_DOMAINS[entity])
        pattern = wchoice(rng, EMAIL_PATTERNS)
        tags = set()
        if pattern == "dot":
            local = f"{f}.{l}"
        elif pattern == "dot_digits":
            local = f"{f}.{l}{rng.randint(1, 99)}"
        elif pattern == "initial":
            local = f"{f[0]}{l}"
        elif pattern == "underscore":
            local = f"{f}_{l}"
        elif pattern == "hyphen":
            local = f"{f}-{l}"
        elif pattern == "plus":
            local = f"{f}.{l}+{'audit' if entity == 'ADMIN' else rng.choice(PLUS_TAGS)}"
            tags.add("email_plus_tag")
        elif pattern == "upper":
            local = f"{f}.{l}".upper()
            domain = domain.upper()
            tags.add("email_uppercase")
        elif pattern == "middle":
            local = f"{f}.{rng.choice('abcdefghjkmnprstvw')}.{l}"
        else:
            local = f"{f}{rng.randint(1000, 9999)}"
        if domain.lower().endswith((".co.uk", ".gov.in", ".com.au")):
            tags.add("email_multi_part_tld")
        return f"{local}@{domain}", tags
    if entity == "SERVICE_ACCOUNT":
        if rng.random() < 0.7:
            return f"svc-{rng.choice(SERVICE_NAMES)}@infra.example.internal", set()
        return f"ci-runner-{rng.randint(1, 20):02d}@build.example.internal", set()
    if entity == "API_CLIENT":
        if rng.random() < 0.5:
            return f"api-client-{rng.randint(1, 9999):04d}@partners.example.net", set()
        return f"integration.{rng.choice(PARTNERS)}@partners.example.net", set()
    return rng.choice(BOT_EMAILS), set()


def make_tool(rng, entity):
    if entity in ("USER", "CUSTOMER", "GUEST") or (entity == "ADMIN" and rng.random() < 0.75):
        short, full = BROWSERS[rng.randrange(len(BROWSERS))]
        return short, full, "browser"
    tool = rng.choice(CLI_TOOLS[entity])
    return tool, tool, "cli"


def make_ip(rng, entity):
    if entity in ("SERVICE_ACCOUNT", "BOT"):
        kind = wchoice(rng, (("ipv4_private", 80), ("ipv6", 20)))
    elif entity == "API_CLIENT":
        kind = wchoice(rng, (("ipv4_public", 70), ("ipv6", 30)))
    else:
        kind = wchoice(rng, (("ipv4_public", 45), ("ipv4_private", 35), ("ipv6", 20)))
    if kind == "ipv4_public":
        return f"{rng.choice(('192.0.2', '198.51.100', '203.0.113'))}.{rng.randint(1, 254)}", kind
    if kind == "ipv4_private":
        block = rng.choice(("10", "172", "192.168"))
        if block == "10":
            return f"10.{rng.randint(0, 255)}.{rng.randint(0, 255)}.{rng.randint(1, 254)}", kind
        if block == "172":
            return f"172.{rng.randint(16, 31)}.{rng.randint(0, 255)}.{rng.randint(1, 254)}", kind
        return f"192.168.{rng.randint(0, 255)}.{rng.randint(1, 254)}", kind

    def hextet():
        return f"{rng.randint(1, 0xFFFF):x}"

    style = wchoice(rng, (("ipv6_compressed", 50), ("ipv6_short", 20), ("ipv6_full", 20), ("ipv6_ipv4_mapped", 10)))
    if style == "ipv6_compressed":
        return f"2001:db8:{hextet()}:{hextet()}::{hextet()}", style
    if style == "ipv6_short":
        return f"2001:db8::{hextet()}", style
    if style == "ipv6_full":
        return "2001:0db8:" + ":".join(f"{rng.randint(0, 0xFFFF):04x}" for _ in range(6)), style
    return f"::ffff:192.0.2.{rng.randint(1, 254)}", style


class Plan:
    """Facts about one generated event, decided before choosing how the line is written."""

    def __init__(self, rng, fmt, outcome):
        self.fmt = fmt
        self.outcome = outcome
        self.entity = wchoice(rng, ENTITY_WEIGHTS)
        self.first = rng.choice(FIRST_NAMES)
        self.last = rng.choice(LAST_NAMES)
        self.email, self.email_tags = make_email(rng, self.entity, self.first, self.last)
        _, city_lat, city_lon, self.offset_minutes = wchoice(rng, CITIES)
        self.precision = wchoice(rng, PRECISION_WEIGHTS)
        self.lat = round(city_lat + rng.uniform(-0.05, 0.05), self.precision)
        self.lon = round(city_lon + rng.uniform(-0.05, 0.05), self.precision)
        self.dt_utc = EVENT_START + timedelta(seconds=rng.randrange(SPAN_SECONDS + 1))
        self.millis = rng.randrange(1000)
        self.tool_short, self.tool_full, self.tool_kind = make_tool(rng, self.entity)
        self.ip, self.ip_kind = make_ip(rng, self.entity)
        self.event = rng.choice(EVENTS[outcome])

        self.missing = set()
        for name, rate in MISSING_RATES:
            if rng.random() < rate:
                self.missing.add(name)
        self.coords_missing = None
        if rng.random() < COORDINATES_MISSING_RATE:
            self.coords_missing = "both" if rng.random() < 0.8 else rng.choice(("latitude", "longitude"))

        self.invalid = None
        if rng.random() < INVALID_VALUE_RATE:
            options = tuple((name, weight) for name, weight in INVALID_FIELD_WEIGHTS
                            if name not in self.missing
                            and not (name == "coordinates" and self.coords_missing == "both"))
            self.invalid = wchoice(rng, options)

        self.status_event = self.event
        self.conflict = False
        if (outcome in ("SUCCESS", "DECLINED") and "status" not in self.missing and self.invalid != "status"
                and rng.random() < STATUS_CONFLICT_RATE):
            opposite = "DECLINED" if outcome == "SUCCESS" else "SUCCESS"
            self.status_event = rng.choice(EVENTS[opposite])
            self.conflict = True


# --------------------------------------------------------------------------- #
# Field tokens
# --------------------------------------------------------------------------- #
def _components(dt, millis, offset_minutes):
    return {"Y": dt.year, "M": dt.month, "D": dt.day, "h": dt.hour, "m": dt.minute, "s": dt.second,
            "ms": millis, "off": offset_minutes}


def format_timestamp(style, c, epoch_seconds):
    Y, M, D, h, m, s, ms, off = c["Y"], c["M"], c["D"], c["h"], c["m"], c["s"], c["ms"], c["off"]
    mon = MONTHS[M - 1] if 1 <= M <= 12 else f"{M:02d}"
    sign = "+" if off >= 0 else "-"
    off_h, off_m = divmod(abs(off), 60)
    ampm = "AM" if h < 12 else "PM"
    h12 = (h % 12 or 12) if h < 24 else h
    date = f"{Y:04d}-{M:02d}-{D:02d}"
    clock = f"{h:02d}:{m:02d}:{s:02d}"
    if style == "iso_z":
        return f"{date}T{clock}Z"
    if style == "iso_ms_z":
        return f"{date}T{clock}.{ms:03d}Z"
    if style == "iso_offset":
        return f"{date}T{clock}{sign}{off_h:02d}:{off_m:02d}"
    if style == "iso_ms_offset":
        return f"{date}T{clock}.{ms:03d}{sign}{off_h:02d}:{off_m:02d}"
    if style == "space":
        return f"{date} {clock}"
    if style == "space_ms":
        return f"{date} {clock}.{ms:03d}"
    if style == "epoch_s":
        return str(epoch_seconds)
    if style == "epoch_ms":
        return str(epoch_seconds * 1000 + ms)
    if style == "apache":
        return f"{D:02d}/{mon}/{Y:04d}:{clock} {sign}{off_h:02d}{off_m:02d}"
    if style == "us_12h":
        return f"{M:02d}/{D:02d}/{Y:04d} {h12:02d}:{m:02d}:{s:02d} {ampm}"
    if style == "us_12h_short":
        return f"{M}/{D}/{Y:04d} {h12}:{m:02d} {ampm}"
    if style == "syslog":
        return f"{mon} {D:>2} {clock}"
    if style == "dmy_hm":
        return f"{D:02d}-{M:02d}-{Y:04d} {h:02d}:{m:02d}"
    if style == "dmy_hms":
        return f"{D:02d}-{M:02d}-{Y:04d} {clock}"
    if style == "ymd_slash":
        return f"{Y:04d}/{M:02d}/{D:02d} {clock}"
    if style == "compact":
        return f"{Y:04d}{M:02d}{D:02d}T{h:02d}{m:02d}{s:02d}"
    raise ValueError(style)


def timestamp_token(rng, plan, rec, styles):
    style = wchoice(rng, styles)
    invalid = plan.invalid == "event_timestamp"
    if invalid and style.startswith("epoch"):
        style = "space"
    local_dt = plan.dt_utc + timedelta(minutes=plan.offset_minutes)
    if style in UTC_STYLES:
        c = _components(plan.dt_utc, plan.millis, 0)
    else:
        c = _components(local_dt, plan.millis, plan.offset_minutes)
    state = VALID
    if invalid:
        kinds = ["feb30", "apr31", "feb29", "hour25"] + ([] if style in NAMED_MONTH_STYLES else ["month13"])
        kind = rng.choice(kinds)
        if kind == "feb30":
            c["M"], c["D"] = 2, 30
        elif kind == "apr31":
            c["M"], c["D"] = 4, 31
        elif kind == "feb29":
            c["M"], c["D"] = 2, 29
        elif kind == "month13":
            c["M"] = 13
        else:
            c["h"], c["m"] = 25, 61
        state = INVALID
        rec.tags.add(f"timestamp_invalid_{kind}")
    token = format_timestamp(style, c, int(plan.dt_utc.timestamp()))
    rec.put("event_timestamp", token, state)
    rec.tags.add(f"timestamp_style_{style}")
    if style == "syslog":
        rec.tags.add("timestamp_no_year")
        if c["D"] < 10:
            rec.tags.add("syslog_space_padded_day")
    if style in NO_TIMEZONE_STYLES:
        rec.tags.add("timestamp_no_timezone")
    if state == VALID and style in DAY_MONTH_AMBIGUOUS_STYLES and c["D"] <= 12 and c["D"] != c["M"]:
        rec.tags.add("ambiguous_day_month_order")
    return token, style


def entity_token(rng, plan, rec, fmt):
    if plan.invalid == "entity_type":
        rec.tags.add("entity_unknown_value")
        return rng.choice(INVALID_ENTITIES), INVALID
    spellings = ENTITY_SPELLINGS[plan.entity]
    style = wchoice(rng, ENTITY_STYLE_WEIGHTS[fmt])
    value = spellings.get(style, spellings["lower"])
    if style == "hyphen" and "hyphen" in spellings:
        rec.tags.add("entity_hyphenated")
    if " " in value:
        rec.tags.add("entity_multi_word")
    return value, VALID


def invalid_email(rng, plan, rec, allow_spaces):
    local, domain = plan.email.split("@", 1)
    kinds = ["consecutive_dots", "double_at", "no_tld", "missing_local_part", "missing_at", "trailing_dot",
             "leading_dot", "non_ascii"] + (["obfuscated", "space_inside"] if allow_spaces else [])
    kind = rng.choice(kinds)
    if kind == "consecutive_dots":
        value = (local.replace(".", "..", 1) if "." in local else f"{local[:3]}..{local[3:]}") + f"@{domain}"
    elif kind == "double_at":
        value = f"{local}@@{domain}"
    elif kind == "no_tld":
        value = f"{local}@localhost"
    elif kind == "missing_local_part":
        value = f"@{domain}"
    elif kind == "missing_at":
        value = f"{local}.{domain}"
    elif kind == "trailing_dot":
        value = f"{local}@{domain}."
    elif kind == "leading_dot":
        value = f".{local}@{domain}"
    elif kind == "non_ascii":
        position = next((i for i, ch in enumerate(local) if ch.lower() in ACCENTS), None)
        if position is None:
            accented = local + "ñ"
        else:
            mark = ACCENTS[local[position].lower()]
            accented = local[:position] + (mark.upper() if local[position].isupper() else mark) + local[position + 1:]
        value = f"{accented}@{domain}"
    elif kind == "obfuscated":
        host, tld = domain.rsplit(".", 1)
        value = f"{local} [at] {host} [dot] {tld}"
    else:
        value = (local.replace(".", " ", 1) if "." in local else f"{local[:3]} {local[3:]}") + f"@{domain}"
    rec.tags.add(f"email_invalid_{kind}")
    return value


def email_token(rng, plan, rec, fmt):
    if plan.invalid == "email_address":
        return invalid_email(rng, plan, rec, allow_spaces=fmt in ("F1", "F3", "F5")), INVALID
    value = plan.email
    rec.tags.update(plan.email_tags)
    if fmt == "F5" and value != value.upper() and rng.random() < 0.35:
        value = value.upper()
        rec.tags.add("email_uppercase")
    return value, VALID


def resource_token(rng, plan, rec, fmt):
    if plan.invalid == "resource_url":
        path = rng.choice(PORTAL_PATHS)
        kind = rng.choice(("scheme_typo", "missing_colon", "empty_host", "single_slash"))
        value = {"scheme_typo": f"htps://portal.corp.example.com/{path}",
                 "missing_colon": f"http//portal.corp.example.com/{path}",
                 "empty_host": f"https:///{path}",
                 "single_slash": f"ftp:/files.example.net/export/{path}"}[kind]
        rec.tags.add(f"resource_invalid_{kind}")
        return value, INVALID
    kinds = ENTITY_RESOURCES[plan.entity]
    if fmt == "F4":
        kinds = tuple(pair for pair in kinds if pair[0] in WEB_KINDS)
    elif fmt in ("F2", "F3"):
        kinds = tuple(pair for pair in kinds if pair[0] not in ("windows", "unc"))
    kind = wchoice(rng, kinds) if kinds else "relative_portal"

    if kind in ("https_portal", "relative_portal"):
        base = "https://portal.corp.example.com" if kind == "https_portal" else ""
        port = ":8443" if base and rng.random() < 0.10 else ""
        query = f"?id={rng.randint(1000, 9999)}" if rng.random() < 0.30 else ""
        fragment = f"#{rng.choice(FRAGMENTS)}" if base and rng.random() < 0.05 else ""
        value = f"{base}{port}/{rng.choice(PORTAL_PATHS)}{query}{fragment}"
    elif kind in ("https_shop", "relative_shop"):
        value = ("https://shop.example.org/" if kind == "https_shop" else "/") + fill(rng, rng.choice(SHOP_PATHS))
    elif kind == "relative_public":
        value = "/" + fill(rng, rng.choice(PUBLIC_PATHS))
    elif kind == "relative_admin":
        value = "/" + fill(rng, rng.choice(ADMIN_PATHS))
    elif kind == "https_admin":
        port = ":8443" if rng.random() < 0.4 else ""
        value = f"https://admin.corp.example.com{port}/" + fill(rng, rng.choice(ADMIN_PATHS))
    elif kind == "https_internal":
        if rng.random() < 0.5:
            value = f"https://vault.corp.example.com/secrets/{rng.choice(('prod', 'staging', 'dev'))}"
        else:
            version = f"{rng.randint(1, 9)}.{rng.randint(0, 20)}.{rng.randint(0, 9)}.{rng.randint(0, 99)}"
            value = f"https://artifacts.example.internal/releases/{version}/app-{version}.zip"
    elif kind in ("relative_api", "https_api"):
        value = ("https://api.example.com/" if kind == "https_api" else "/") + fill(rng, rng.choice(API_PATHS))
    elif kind == "http_health_ip":
        value = f"http://10.20.0.{rng.randint(2, 250)}:8080/actuator/health"
    elif kind == "relative_health":
        value = rng.choice(("/healthz", "/readyz", "/metrics"))
    elif kind == "https_status":
        value = "https://status.example.com/api/ping"
    elif kind == "windows":
        value = fill(rng, rng.choice(WINDOWS_PATHS))
    elif kind == "unc":
        value = fill(rng, rng.choice(UNC_PATHS))
    elif kind == "linux":
        value = fill(rng, rng.choice(LINUX_PATHS))
    elif kind == "db":
        value = rng.choice(DB_RESOURCES)
    elif kind == "s3":
        value = fill(rng, rng.choice(S3_RESOURCES))
    else:  # ftp
        value = rng.choice((f"ftp://files.example.net/export/q{rng.randint(1, 4)}%20final.csv",
                            f"ftp://files.example.net/outbound/batch_{rng.randint(100, 999)}.zip"))
    rec.tags.add(f"resource_{kind}")
    if " " in value:
        rec.tags.add("resource_contains_space")
    if "%20" in value:
        rec.tags.add("resource_percent_encoded")
    return value, VALID


def ip_token(rng, plan, rec):
    if plan.invalid == "ip_address":
        a, b, c, d, e = (rng.randint(1, 254) for _ in range(5))
        kind = rng.choice(("octet_out_of_range", "too_few_octets", "too_many_octets", "leading_zeros",
                           "ipv6_double_compression", "ipv6_invalid_hex"))
        # Built on documentation/private prefixes so no invalid token contains a routable public address.
        value = {"octet_out_of_range": f"198.51.100.{rng.randint(256, 999)}",
                 "too_few_octets": f"192.168.{c}",
                 "too_many_octets": f"203.0.113.{d}.{e}",
                 "leading_zeros": f"192.168.{rng.randint(1, 99):03d}.{rng.randint(1, 99):03d}",
                 "ipv6_double_compression": f"2001:db8::{a:x}::{b:x}",
                 "ipv6_invalid_hex": f"2001:db8:{rng.choice(('gggg', 'zz12', '12xy'))}::{c:x}"}[kind]
        rec.tags.add(f"ip_invalid_{kind}")
        return value, INVALID
    if plan.ip_kind.startswith("ipv6"):
        rec.tags.add(plan.ip_kind)
    return plan.ip, VALID


def _hemisphere(value, is_lat):
    if is_lat:
        return "N" if value >= 0 else "S"
    return "E" if value >= 0 else "W"


def dms_token(value, is_lat):
    tenths = round(abs(value) * 36000)  # tenths of an arc-second
    degrees, rest = divmod(tenths, 36000)
    minutes, rest = divmod(rest, 600)
    return f"{degrees}°{minutes:02d}'{rest // 10:02d}.{rest % 10}\"{_hemisphere(value, is_lat)}"


def coordinate_tokens(rng, plan, rec, style, allow_decimal_comma=False):
    """Return ({axis: token or None}, {axis: state}); None/MISSING marks an absent axis."""
    if plan.invalid == "coordinates":
        style = "decimal"
    p = plan.precision
    tokens = {}
    for axis, value, is_lat in (("latitude", plan.lat, True), ("longitude", plan.lon, False)):
        if style == "decimal":
            tokens[axis] = f"{value:.{p}f}"
        elif style == "hemi_suffix":
            tokens[axis] = f"{abs(value):.{p}f} {_hemisphere(value, is_lat)}"
        elif style == "hemi_prefix":
            tokens[axis] = f"{_hemisphere(value, is_lat)}{abs(value):.{p}f}"
        else:
            tokens[axis] = dms_token(value, is_lat)
    states = {"latitude": VALID, "longitude": VALID}

    if plan.invalid == "coordinates":
        present = [axis for axis in ("latitude", "longitude") if plan.coords_missing != axis]
        kinds = ["out_of_range", "nan"] + (["decimal_comma"] if allow_decimal_comma and len(present) == 2 else [])
        kind = rng.choice(kinds)
        if kind == "decimal_comma":
            targets = present
        elif len(present) == 2 and rng.random() < 0.7:
            targets = [rng.choice(present)]
        else:
            targets = present
        for axis in targets:
            if kind == "decimal_comma":
                tokens[axis] = tokens[axis].replace(".", ",")
            elif kind == "nan":
                tokens[axis] = "NaN"
            else:
                limit = 90 if axis == "latitude" else 180
                tokens[axis] = f"{rng.uniform(limit + 0.5, limit * 1.4) * rng.choice((1, -1)):.4f}"
            states[axis] = INVALID
        rec.tags.add(f"coordinates_invalid_{kind}")

    for axis in ("latitude", "longitude"):
        if plan.coords_missing in ("both", axis):
            tokens[axis] = None
            states[axis] = MISSING
    if plan.coords_missing in ("latitude", "longitude"):
        rec.tags.add("coordinates_partial")
    if plan.coords_missing != "both":
        rec.tags.add(f"coordinates_{style}")
    return tokens, states


def status_word(rng, plan):
    if plan.invalid == "status":
        return rng.choice(INVALID_STATUS_WORDS), INVALID
    return rng.choice(plan.status_event["words"]), VALID


def status_code(rng, plan):
    if plan.invalid == "status":
        return rng.choice(INVALID_STATUS_CODES), INVALID
    return str(rng.choice(plan.status_event["http"])), VALID


def absent_value(rng, rec, name, placeholders, p_placeholder, p_empty=0.0):
    """Record an absent value. Returns None (omit it), "" (write an empty value) or a placeholder token."""
    roll = rng.random()
    if roll < p_placeholder:
        token = rng.choice(placeholders)
        rec.put(name, token, PLACEHOLDER)
        return token
    rec.put(name, "", MISSING)
    if roll < p_placeholder + p_empty:
        rec.tags.add("empty_value")
        return ""
    return None


# --------------------------------------------------------------------------- #
# F1 - pipe-separated key=value
# --------------------------------------------------------------------------- #
F1_KEYS = {
    "entity_type": (("entity", 70), ("entity_type", 20), ("type", 10)),
    "email_address": (("email", 70), ("user", 20), ("principal", 10)),
    "action_phrase": (("action", 80), ("event", 20)),
    "resource_url": (("resource", 70), ("url", 20), ("path", 10)),
    "tool": (("tool", 70), ("client", 20), ("agent", 10)),
    "ip_address": (("ip", 70), ("src_ip", 20), ("client_ip", 10)),
    "status": (("status", 70), ("result", 20), ("outcome", 10)),
}
F1_PLACEHOLDERS = {"entity_type": ("N/A", "-"), "email_address": ("-", "unknown"), "resource_url": ("-",),
                   "tool": ("unknown", "-"), "status": ("-", "N/A"), "latitude": ("N/A", "-"),
                   "longitude": ("N/A", "-")}
F1_COORD_KEYS = {"lat_lon": ("lat", "lon"), "latitude_longitude": ("latitude", "longitude"),
                 "lat_lng": ("lat", "lng"), "dms": ("lat", "lon"), "geo": ("lat", "lon")}


def render_f1(rng, plan, rec):
    sep = " | " if rng.random() < 0.9 else "|"
    if sep == "|":
        rec.tags.add("compact_delimiters")
    ts, _ = timestamp_token(rng, plan, rec, F1_TS_STYLES)
    segments = []

    def segment(name, key, value=None, state=None, rendered=None):
        if state is None:
            token = absent_value(rng, rec, name, F1_PLACEHOLDERS[name], 0.15, 0.15)
            if token is not None:
                segments.append(f"{key}={token}")
            return
        rec.put(name, value, state)
        segments.append(f"{key}={value if rendered is None else rendered}")

    key = wchoice(rng, F1_KEYS["entity_type"])
    if "entity_type" in plan.missing:
        segment("entity_type", key)
    else:
        segment("entity_type", key, *entity_token(rng, plan, rec, "F1"))

    key = wchoice(rng, F1_KEYS["email_address"])
    if "email_address" in plan.missing:
        segment("email_address", key)
    else:
        value, state = email_token(rng, plan, rec, "F1")
        wrap = wchoice(rng, (("plain", 85), ("angle", 10), ("mailto", 5)))
        if state == INVALID:
            wrap = "plain"
        if wrap != "plain":
            rec.tags.add(f"email_{wrap}_wrapper")
        rendered = {"plain": value, "angle": f"<{value}>", "mailto": f"mailto:{value}"}[wrap]
        segment("email_address", key, value, state, rendered)

    key = wchoice(rng, F1_KEYS["action_phrase"])
    phrase = rng.choice(plan.event["F1"])
    segment("action_phrase", key, phrase, VALID, f'"{phrase}"' if rng.random() < 0.7 else phrase)

    key = wchoice(rng, F1_KEYS["resource_url"])
    if "resource_url" in plan.missing:
        segment("resource_url", key)
    else:
        segment("resource_url", key, *resource_token(rng, plan, rec, "F1"))

    key = wchoice(rng, F1_KEYS["tool"])
    if "tool" in plan.missing:
        segment("tool", key)
    else:
        segment("tool", key, plan.tool_short, VALID)

    key = wchoice(rng, F1_KEYS["ip_address"])
    segment("ip_address", key, *ip_token(rng, plan, rec))

    layout = wchoice(rng, (("lat_lon", 55), ("latitude_longitude", 15), ("lat_lng", 15), ("geo", 10), ("dms", 5)))
    tokens, states = coordinate_tokens(rng, plan, rec, "dms" if layout == "dms" else "decimal",
                                       allow_decimal_comma=layout != "geo")
    if layout == "geo" and plan.coords_missing is None:
        rec.put("latitude", tokens["latitude"], states["latitude"])
        rec.put("longitude", tokens["longitude"], states["longitude"])
        segments.append(f"geo={tokens['latitude']},{tokens['longitude']}")
        rec.tags.add("coordinates_combined_field")
    elif layout == "geo" and plan.coords_missing == "both":
        token = absent_value(rng, rec, "latitude", F1_PLACEHOLDERS["latitude"], 0.15, 0.15)
        rec.put("longitude", *rec.fields["latitude"])
        if token is not None:
            segments.append(f"geo={token}")
    else:
        for axis, axis_key in zip(("latitude", "longitude"), F1_COORD_KEYS[layout]):
            if tokens[axis] is None:
                segment(axis, axis_key)
            else:
                segment(axis, axis_key, tokens[axis], states[axis])

    key = wchoice(rng, F1_KEYS["status"])
    if "status" in plan.missing:
        segment("status", key)
    elif rng.random() < 0.75:
        segment("status", key, *status_word(rng, plan))
    else:
        segment("status", key, *status_code(rng, plan))

    if rng.random() < 0.10:
        rng.shuffle(segments)
        rec.tags.add("field_order_varied")
    return sep.join([ts] + segments)


# --------------------------------------------------------------------------- #
# F2 - natural-language sentence
# --------------------------------------------------------------------------- #
def render_f2(rng, plan, rec):
    template = wchoice(rng, (("A", 50), ("B", 30), ("C", 20)))
    rec.tags.add(f"sentence_template_{template}")
    ts, ts_style = timestamp_token(rng, plan, rec, (("apache", 50), ("iso_z", 20), ("us_12h", 30)))
    ts_text = {"apache": f"[{ts}]", "iso_z": ts, "us_12h": f"{ts} -"}[ts_style]

    entity_text = None
    if "entity_type" in plan.missing:
        rec.put("entity_type", "", MISSING)
    elif plan.invalid != "entity_type" and rng.random() < 0.15:
        value = ENTITY_SPELLINGS[plan.entity]["upper"]
        rec.put("entity_type", value)
        entity_text = f"[{value}]"
        rec.tags.add("entity_bracket_prefix")
    else:
        value, state = entity_token(rng, plan, rec, "F2")
        rec.put("entity_type", value, state)
        entity_text = value

    if "email_address" in plan.missing:
        rec.put("email_address", "", MISSING)
        email_text = "anonymous"
        rec.tags.add("email_absent_anonymous")
    else:
        value, state = email_token(rng, plan, rec, "F2")
        wrap = wchoice(rng, (("plain", 70), ("angle", 20), ("display_name", 10)))
        if state == INVALID:
            wrap = "plain"
        elif wrap == "display_name" and plan.entity not in ("USER", "CUSTOMER", "ADMIN"):
            wrap = "angle"
        if wrap != "plain":
            rec.tags.add(f"email_{wrap}_wrapper")
        email_text = {"plain": value, "angle": f"<{value}>",
                      "display_name": f'"{plan.first} {plan.last}" <{value}>'}[wrap]
        rec.put("email_address", value, state)

    phrase = rng.choice(plan.event["F2"])
    rec.put("action_phrase", phrase)

    if "resource_url" in plan.missing:
        rec.put("resource_url", "", MISSING)
        resource_text = "an unspecified resource"
    else:
        value, state = resource_token(rng, plan, rec, "F2")
        rec.put("resource_url", value, state)
        resource_text = value

    tool = None
    if "tool" in plan.missing:
        rec.put("tool", "", MISSING)
    else:
        tool = plan.tool_short
        rec.put("tool", tool)

    value, state = ip_token(rng, plan, rec)
    rec.put("ip_address", value, state)
    ip_text = value
    if state == VALID and ":" not in value and rng.random() < 0.10:
        port = rng.randint(1024, 65535)
        ip_text = f"{value}:{port}"
        rec.secondary.append(f"client_port={port}")
        rec.tags.add("ip_with_port")

    layout = wchoice(rng, (("paren", 35), ("paren_loc", 20), ("at_lat_lon", 15), ("dms", 15), ("hemi_bracket", 15)))
    tokens, states = coordinate_tokens(rng, plan, rec, {"dms": "dms", "hemi_bracket": "hemi_prefix"}.get(layout, "decimal"))
    for axis in ("latitude", "longitude"):
        rec.put(axis, tokens[axis] or "", states[axis])
    lat, lon = tokens["latitude"], tokens["longitude"]
    if lat is None and lon is None:
        coord_text = None
    elif lat is None:
        coord_text = f"at lon {lon}"
    elif lon is None:
        coord_text = f"at lat {lat}"
    else:
        coord_text = {"paren": f"({lat}, {lon})", "paren_loc": f"(loc: {lat}, {lon})",
                      "at_lat_lon": f"at lat {lat} lon {lon}", "dms": f"at {lat} {lon}",
                      "hemi_bracket": f"[{lat} {lon}]"}[layout]

    status_text = bracket_status = None
    if "status" in plan.missing:
        rec.put("status", "", MISSING)
    else:
        style = "bracket" if template == "C" else wchoice(rng, (("code_reason", 50), ("word", 30), ("bracket", 20)))
        if style == "code_reason" and plan.invalid == "status":
            style = "word"
        if style == "code_reason":
            code, state = status_code(rng, plan)
            value = f"{code} {HTTP_REASONS[int(code)]}"
        else:
            value, state = status_word(rng, plan)
        rec.put("status", value, state)
        if style == "bracket":
            bracket_status = f"[{value}]"
        elif template == "A":
            status_text = f"- status: {value}" if style == "word" else f"- {value}"
        else:
            status_text = f"result {value}"

    tool_verb = {"A": "via", "B": "using", "C": "with"}[template]
    tool_text = f"{tool_verb} {tool}" if tool else None
    from_text = f"from {ip_text}"
    if template == "A":
        parts = (ts_text, entity_text, email_text, phrase, resource_text, tool_text, from_text, coord_text,
                 status_text or bracket_status)
        return " ".join(p for p in parts if p)
    if template == "B":
        line = " ".join(p for p in (ts_text, entity_text, email_text, phrase, resource_text, from_text, tool_text) if p)
        if coord_text:
            line += f", location {coord_text}"
        if status_text:
            line += f", {status_text}"
        elif bracket_status:
            line += f" {bracket_status}"
        return line
    rec.tags.add("resource_trailing_punctuation")
    parts = (ts_text, bracket_status, entity_text, email_text, f"connecting {from_text}", tool_text,
             f"located {coord_text}" if coord_text else None, phrase, resource_text)
    return " ".join(p for p in parts if p) + "."


# --------------------------------------------------------------------------- #
# F3 - syslog header + JSON payload
# --------------------------------------------------------------------------- #
F3_HOSTS = ("auth-gw01", "auth-gw02", "sso01", "sso02", "api-gw01", "api-gw02", "vpn01", "lb01", "fw01", "k8s-api01")
F3_PROCS = ("gatekeeper", "authd", "haproxy", "guard", "audit", "openvpn")
F3_PRIORITIES = (134, 38, 86, 110)
F3_MSGIDS = ("AUTH", "ACCESS", "AUDIT")


def render_f3(rng, plan, rec):
    host, proc, pid = rng.choice(F3_HOSTS), rng.choice(F3_PROCS), rng.randint(100, 9999)
    if rng.random() < 0.65:
        ts, _ = timestamp_token(rng, plan, rec, (("syslog", 1),))
        prefix = f"{ts} {host} {proc}[{pid}]: "
        rec.tags.add("syslog_rfc3164")
    else:
        ts, _ = timestamp_token(rng, plan, rec, (("iso_ms_z", 1),))
        prefix = f"<{rng.choice(F3_PRIORITIES)}>1 {ts} {host} {proc} {pid} {rng.choice(F3_MSGIDS)} - "
        rec.tags.add("syslog_rfc5424")
    spaced = rng.random() < 0.3
    colon, comma = (": ", ", ") if spaced else (":", ",")
    if spaced:
        rec.tags.add("json_spaced")
    items = []

    def q(value):
        return json.dumps(value, ensure_ascii=False)

    def obj(pairs):
        return "{" + comma.join(f"{q(k)}{colon}{v}" for k, v in pairs) + "}"

    def string_field(name, key_weights, value_state):
        key = wchoice(rng, key_weights)
        if value_state is None:
            if rng.random() < 0.25:
                items.append((key, "null"))
                rec.put(name, "null", PLACEHOLDER)
            else:
                rec.put(name, "", MISSING)
            return
        items.append((key, q(value_state[0])))
        rec.put(name, *value_state)

    if rng.random() < 0.2:
        items.append(("level", q(rng.choice(("info", "notice", "warn")))))
    string_field("entity_type", (("entity_type", 50), ("entity", 30), ("principal_type", 20)),
                 None if "entity_type" in plan.missing else entity_token(rng, plan, rec, "F3"))
    string_field("email_address", (("user", 40), ("principal", 40), ("email", 20)),
                 None if "email_address" in plan.missing else email_token(rng, plan, rec, "F3"))
    string_field("resource_url", (("resource", 60), ("res", 20), ("target", 20)),
                 None if "resource_url" in plan.missing else resource_token(rng, plan, rec, "F3"))
    string_field("tool", (("tool", 50), ("user_agent", 30), ("client", 20)),
                 None if "tool" in plan.missing else (plan.tool_short, VALID))
    string_field("ip_address", (("src_ip", 50), ("ip", 25), ("remote_addr", 25)), ip_token(rng, plan, rec))

    layout = wchoice(rng, (("geo", 40), ("lat_long_keys", 25), ("location_string", 20), ("geojson", 15)))
    tokens, states = coordinate_tokens(rng, plan, rec, "decimal")
    lat, lon = tokens["latitude"], tokens["longitude"]
    if lat is None and lon is None:
        if rng.random() < 0.25:
            items.append(("geo", "null"))
            rec.put("latitude", "null", PLACEHOLDER)
            rec.put("longitude", "null", PLACEHOLDER)
        else:
            rec.put("latitude", "", MISSING)
            rec.put("longitude", "", MISSING)
    else:
        for axis in ("latitude", "longitude"):
            rec.put(axis, tokens[axis] or "", states[axis])
        if lat is None or lon is None:
            items.append(("geo", obj([("lat", lat)] if lon is None else [("lng", lon)])))
        elif layout == "geo":
            items.append(("geo", obj([("lat", lat), ("lng", lon)])))
            rec.tags.add("coordinates_json_object")
        elif layout == "lat_long_keys":
            items.extend((("latitude", lat), ("longitude", lon)))
        elif layout == "location_string":
            items.append(("location", q(f"{lat},{lon}")))
            rec.tags.add("coordinates_combined_string")
        else:
            items.append(("geometry", obj([("type", q("Point")), ("coordinates", f"[{lon}{comma}{lat}]")])))
            rec.tags.add("coordinates_geojson_lon_lat_order")

    phrase = rng.choice(plan.event["F3"])
    items.append((wchoice(rng, (("msg", 60), ("event", 25), ("action", 15))), q(phrase)))
    rec.put("action_phrase", phrase)

    status_keys = (("result", 50), ("status", 30), ("outcome", 20))
    if "status" in plan.missing:
        string_field("status", status_keys, None)
    elif rng.random() < 0.4:
        code, state = status_code(rng, plan)
        items.append((wchoice(rng, (("status", 60), ("http_status", 40))), code if state == VALID else q(code)))
        rec.put("status", code, state)
        rec.tags.add("status_numeric_json")
    else:
        string_field("status", status_keys, status_word(rng, plan))
    return prefix + obj(items)


# --------------------------------------------------------------------------- #
# F4 - web access log (combined format + key=value extras)
# --------------------------------------------------------------------------- #
F4_METHODS = (("GET", 70), ("POST", 20), ("PUT", 5), ("DELETE", 5))


def render_f4(rng, plan, rec):
    ip, ip_state = ip_token(rng, plan, rec)
    rec.put("ip_address", ip, ip_state)
    ip_field = ip
    if ip_state == VALID and rng.random() < 0.4:
        port = rng.randint(1024, 65535)
        ip_field = f"[{ip}]:{port}" if ":" in ip else f"{ip}:{port}"
        rec.secondary.append(f"client_port={port}")
        rec.tags.add("ip_with_port")

    remote_user, user_extra = "-", None
    if "email_address" in plan.missing:
        rec.put("email_address", "-", PLACEHOLDER)
    else:
        value, state = email_token(rng, plan, rec, "F4")
        rec.put("email_address", value, state)
        if rng.random() < 0.4:
            remote_user = value
            rec.tags.add("email_in_remote_user_slot")
        else:
            user_extra = f"user=<{value}>"
            rec.tags.add("email_angle_wrapper")

    ts, _ = timestamp_token(rng, plan, rec, F4_TS_STYLES)

    method = wchoice(rng, F4_METHODS)
    version = "1.1" if rng.random() < 0.8 else "2.0"
    if "resource_url" in plan.missing:
        rec.put("resource_url", "-", PLACEHOLDER)
        request = "-"
    else:
        value, state = resource_token(rng, plan, rec, "F4")
        rec.put("resource_url", value, state)
        request = f"{method} {value} HTTP/{version}"

    if "status" in plan.missing:
        rec.put("status", "-", PLACEHOLDER)
        status = "-"
    else:
        status, state = status_code(rng, plan)
        rec.put("status", status, state)
    size = "-" if rng.random() < 0.1 else str(rng.randint(0, 50000))

    referer = "-"
    if rng.random() < 0.2:
        referer = fill(rng, rng.choice(REFERERS))
        rec.secondary.append(f"referer_url={referer}")
        rec.tags.add("referer_url_present")

    if "tool" in plan.missing:
        rec.put("tool", "-", PLACEHOLDER)
        agent = "-"
    else:
        agent = plan.tool_full if plan.tool_kind == "browser" else plan.tool_short
        if plan.tool_kind == "browser":
            rec.tags.add("user_agent_full")
        rec.put("tool", agent)

    extras = []
    if "entity_type" in plan.missing:
        rec.put("entity_type", "", MISSING)
    else:
        value, state = entity_token(rng, plan, rec, "F4")
        extras.append(f"{wchoice(rng, (('type', 50), ('entity', 30), ('role', 20)))}={value}")
        rec.put("entity_type", value, state)
    if user_extra:
        extras.append(user_extra)

    layout = wchoice(rng, (("point", 40), ("geo", 35), ("lat_lon", 25)))
    tokens, states = coordinate_tokens(rng, plan, rec, "decimal")
    for axis in ("latitude", "longitude"):
        rec.put(axis, tokens[axis] or "", states[axis])
    lat, lon = tokens["latitude"], tokens["longitude"]
    if lat is not None and lon is not None:
        if layout == "point":
            extras.append(f"loc=POINT({lon} {lat})")
            rec.tags.add("coordinates_wkt_lon_lat_order")
        elif layout == "geo":
            extras.append(f"geo={lat},{lon}")
            rec.tags.add("coordinates_combined_field")
        else:
            extras.append(f"lat={lat} lon={lon}")
    elif lat is not None:
        extras.append(f"lat={lat}")
    elif lon is not None:
        extras.append(f"lon={lon}")

    phrase = rng.choice(plan.event["F4"])
    rec.put("action_phrase", phrase)
    extras.append(f'msg="{phrase}"')
    return (f'{ip_field} - {remote_user} [{ts}] "{request}" {status} {size} "{referer}" "{agent}" '
            + " ".join(extras))


# --------------------------------------------------------------------------- #
# F5 - legacy semicolon-positional export
# --------------------------------------------------------------------------- #
def render_f5(rng, plan, rec):
    def column(name, value_state):
        if value_state is None:
            if rng.random() < 0.3:
                token = rng.choice(("N/A", "NULL", "-"))
                rec.put(name, token, PLACEHOLDER)
                return token
            rec.put(name, "", MISSING)
            return ""
        rec.put(name, *value_state)
        return value_state[0]

    ts, _ = timestamp_token(rng, plan, rec, F5_TS_STYLES)
    entity = column("entity_type", None if "entity_type" in plan.missing else entity_token(rng, plan, rec, "F5"))
    email = column("email_address", None if "email_address" in plan.missing else email_token(rng, plan, rec, "F5"))
    tool = column("tool", None if "tool" in plan.missing else (plan.tool_short, VALID))
    resource = column("resource_url",
                      None if "resource_url" in plan.missing else resource_token(rng, plan, rec, "F5"))
    style = wchoice(rng, (("decimal", 45), ("hemi_suffix", 25), ("hemi_prefix", 10), ("dms", 20)))
    tokens, states = coordinate_tokens(rng, plan, rec, style)
    lat = column("latitude", None if tokens["latitude"] is None else (tokens["latitude"], states["latitude"]))
    lon = column("longitude", None if tokens["longitude"] is None else (tokens["longitude"], states["longitude"]))
    ip = column("ip_address", ip_token(rng, plan, rec))
    phrase = rng.choice(plan.event["F5"])
    rec.put("action_phrase", phrase)
    if "status" in plan.missing:
        status = column("status", None)
    else:
        status, state = status_word(rng, plan)
        if state == VALID and status != status.lower() and rng.random() < 0.25:
            status = status.lower()
            rec.tags.add("status_lowercase")
        rec.put("status", status, state)
    return ";".join((ts, entity, email, tool, resource, lat, lon, ip, phrase, status))


RENDERERS = {"F1": render_f1, "F2": render_f2, "F3": render_f3, "F4": render_f4, "F5": render_f5}

# --------------------------------------------------------------------------- #
# Dataset assembly
# --------------------------------------------------------------------------- #
IPV4_LIKE = re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])")
ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def generate_rows(rng, count):
    formats = expand_quota(count, FORMAT_SHARES)
    rng.shuffle(formats)
    outcomes = expand_quota(count, OUTCOME_SHARES)
    rng.shuffle(outcomes)
    rows = []
    for number, (fmt, outcome) in enumerate(zip(formats, outcomes), start=1):
        plan = Plan(rng, fmt, outcome)
        rec = Rec()
        raw = RENDERERS[fmt](rng, plan, rec)
        for name, label in (("resource_url", "resource"), ("tool", "tool")):
            match = IPV4_LIKE.search(rec.fields.get(name, ("", MISSING))[0])
            if match:
                rec.tags.add(f"ip_like_in_{label}")
                rec.secondary.append(f"ip_like_in_{label}={match.group(0)}")
        resource = rec.fields.get("resource_url", ("", MISSING))[0]
        if ISO_DATE.search(resource):
            rec.tags.add("date_in_resource")
        if plan.conflict:
            rec.tags.add("status_action_conflict")
        rows.append({"case_id": f"GEN-{number:05d}", "source": "generated", "format_family": fmt, "raw_log": raw,
                     "outcome": outcome, "fields": rec.fields, "tags": rec.tags, "secondary": rec.secondary,
                     "notes": "", "broken": False})
    return rows


def curated_rows():
    return [{"case_id": c.case_id, "source": "curated", "format_family": c.format_family, "raw_log": c.raw_log,
             "outcome": c.outcome, "fields": dict(c.fields), "tags": {t for t in c.tags.split(";") if t},
             "secondary": [s for s in c.secondary.split(";") if s], "notes": c.notes, "broken": c.broken}
            for c in CASES]


def build_dataset(seed, total_rows):
    curated = curated_rows()
    if total_rows < len(curated):
        raise SystemExit(f"--rows must be at least {len(curated)} (the number of curated edge cases)")
    rng = random.Random(seed)
    generated = generate_rows(rng, total_rows - len(curated))
    curated_positions = set(rng.sample(range(total_rows), len(curated)))
    curated_iter, generated_iter = iter(curated), iter(generated)
    rows = []
    for position in range(total_rows):
        row = next(curated_iter) if position in curated_positions else next(generated_iter)
        row["log_id"] = position + 1
        for name in FIELDS:
            row["fields"].setdefault(name, ("", MISSING))
        if row["broken"]:
            row["record_validity"] = "BROKEN"
        elif any(state == INVALID for _, state in row["fields"].values()):
            row["record_validity"] = "INVALID"
        else:
            row["record_validity"] = "VALID"
        rows.append(row)
    return rows


# --------------------------------------------------------------------------- #
# Answer-key self-check (fails the run instead of writing an inconsistent dataset)
# --------------------------------------------------------------------------- #
EMAIL_SHAPE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._%+-]*[A-Za-z0-9_%+-])?"
                         r"@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+")
DECIMAL_NUMBER = re.compile(r"-?\d+(?:\.\d+)?")


def _ip_parses(value):
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def verify(rows):
    problems = []
    for row in rows:
        where = f"{row['case_id']} (log_id {row['log_id']})"
        raw = row["raw_log"]
        for name in FIELDS:
            value, state = row["fields"][name]
            if state not in (VALID, INVALID, PLACEHOLDER, MISSING):
                problems.append(f"{where}: {name} has unknown validity {state!r}")
            if (state == MISSING) == bool(value):
                problems.append(f"{where}: {name} value {value!r} does not match validity {state}")
            if value and (raw is None or value not in raw):
                problems.append(f"{where}: {name} value {value!r} is not a substring of raw_log")
            if state in (VALID, INVALID) and not row["broken"]:
                looks_valid = None
                if name == "ip_address":
                    looks_valid = _ip_parses(value)
                elif name == "email_address":
                    looks_valid = EMAIL_SHAPE.fullmatch(value) is not None and ".." not in value
                elif name in ("latitude", "longitude") and DECIMAL_NUMBER.fullmatch(value):
                    looks_valid = abs(float(value)) <= (90 if name == "latitude" else 180)
                if looks_valid is not None and looks_valid != (state == VALID):
                    problems.append(f"{where}: {name} value {value!r} labelled {state} but checks as "
                                    f"{'valid' if looks_valid else 'invalid'}")
        if (row["fields"]["action_phrase"][1] == MISSING) != (row["outcome"] == "NONE"):
            problems.append(f"{where}: outcome_class {row['outcome']} disagrees with action_phrase presence")
    if problems:
        raise SystemExit("Answer-key self-check failed:\n  " + "\n  ".join(problems[:60])
                         + (f"\n  ... and {len(problems) - 60} more" if len(problems) > 60 else ""))


# --------------------------------------------------------------------------- #
# Output files
# --------------------------------------------------------------------------- #
ANSWER_KEY_COLUMNS = (["log_id", "case_id", "source", "format_family", "outcome_class", "record_validity"]
                      + [column for name in FIELDS for column in (name, f"{name}_validity")]
                      + ["secondary_values", "scenario_tags", "notes"])
FORMAT_ORDER = ("F1", "F2", "F3", "F4", "F5", "NONE")
OUTCOME_ORDER = ("SUCCESS", "DECLINED", "NEUTRAL", "NONE")
RECORD_VALIDITY_ORDER = ("VALID", "INVALID", "BROKEN")
FIELD_VALIDITY_ORDER = (VALID, INVALID, PLACEHOLDER, MISSING)


def raw_csv_bytes(rows):
    """log_id,raw_log - raw_log always quoted; unquoted empty = SQL NULL (PostgreSQL CSV semantics)."""
    lines = ["log_id,raw_log"]
    for row in rows:
        raw = row["raw_log"]
        lines.append(f"{row['log_id']}," + ("" if raw is None else '"' + raw.replace('"', '""') + '"'))
    return ("\n".join(lines) + "\n").encode("utf-8")


def answer_key_bytes(rows):
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(ANSWER_KEY_COLUMNS)
    for row in rows:
        values = [row["log_id"], row["case_id"], row["source"], row["format_family"], row["outcome"],
                  row["record_validity"]]
        for name in FIELDS:
            values.extend(row["fields"][name])
        values.extend([";".join(row["secondary"]), ";".join(sorted(row["tags"])), row["notes"]])
        writer.writerow(values)
    return buffer.getvalue().encode("utf-8")


def _counts(values, order=None):
    counter = Counter(values)
    keys = order if order is not None else sorted(counter)
    return {key: counter.get(key, 0) for key in keys}


def manifest_bytes(rows, seed, files):
    subsets = {"all": rows,
               "curated": [r for r in rows if r["source"] == "curated"],
               "generated": [r for r in rows if r["source"] == "generated"]}
    manifest = {
        "dataset": "PostgreSQL Regex Task - RAW access logs (Step 1 sample data)",
        "generator": "data/generate_raw_logs.py",
        "generator_version": GENERATOR_VERSION,
        "seed": seed,
        "random_source": "one random.Random(seed) instance; Python standard library only",
        "python_requirement": ">=3.9.5",
        "event_time_range_utc": {"start": EVENT_START.strftime("%Y-%m-%dT%H:%M:%SZ"),
                                 "end": EVENT_END.strftime("%Y-%m-%dT%H:%M:%SZ")},
        "row_counts": {"total": len(rows), "curated_edge_cases": len(subsets["curated"]),
                       "generated": len(subsets["generated"])},
        "generation_settings": {
            "format_shares_percent": dict(FORMAT_SHARES),
            "outcome_shares_percent": dict(OUTCOME_SHARES),
            "missing_rates": dict(MISSING_RATES),
            "coordinates_missing_rate": COORDINATES_MISSING_RATE,
            "invalid_value_rate": INVALID_VALUE_RATE,
            "status_action_conflict_rate": STATUS_CONFLICT_RATE,
        },
        "csv_conventions": {
            "encoding": "UTF-8 without BOM",
            "line_ending": "LF",
            "raw_access_logs.csv": "Columns log_id, raw_log. raw_log is always double-quoted; an unquoted empty "
                                   "value is SQL NULL and \"\" is an empty string (PostgreSQL COPY ... CSV HEADER "
                                   "semantics). Quoted values may contain CR, LF and tabs.",
            "expected_fields.csv": "Minimal RFC 4180 quoting. Join to raw_access_logs.csv on log_id. Field values "
                                   "are exact substrings of raw_log; validity is VALID, INVALID, PLACEHOLDER or "
                                   "MISSING.",
        },
        "distributions": {
            "format_family": {k: _counts((r["format_family"] for r in v), FORMAT_ORDER) for k, v in subsets.items()},
            "outcome_class": {k: _counts((r["outcome"] for r in v), OUTCOME_ORDER) for k, v in subsets.items()},
            "record_validity": {k: _counts((r["record_validity"] for r in v), RECORD_VALIDITY_ORDER)
                                for k, v in subsets.items()},
            "field_validity": {name: _counts((r["fields"][name][1] for r in rows), FIELD_VALIDITY_ORDER)
                               for name in FIELDS},
            "scenario_tags": _counts(tag for r in rows for tag in r["tags"]),
        },
        "files": {name: {"rows": len(rows), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                  for name, data in files.items()},
    }
    return (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def main(argv=None):
    if sys.version_info < (3, 9, 5):
        raise SystemExit("Python 3.9.5 or newer is required (strict IPv4 parsing in the ipaddress module).")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--rows", type=int, default=DEFAULT_ROWS)
    parser.add_argument("--out-dir", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--check", action="store_true",
                        help="regenerate in memory and compare byte-for-byte with the files in --out-dir")
    args = parser.parse_args(argv)

    rows = build_dataset(args.seed, args.rows)
    verify(rows)
    outputs = {"raw_access_logs.csv": raw_csv_bytes(rows), "expected_fields.csv": answer_key_bytes(rows)}
    outputs["dataset_manifest.json"] = manifest_bytes(rows, args.seed, dict(outputs))

    if args.check:
        mismatched = [name for name, data in outputs.items()
                      if not (args.out_dir / name).exists() or (args.out_dir / name).read_bytes() != data]
        for name, data in outputs.items():
            print(f"{'MISMATCH' if name in mismatched else 'identical'}  {name:<22} "
                  f"sha256={hashlib.sha256(data).hexdigest()}")
        return 1 if mismatched else 0

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, data in outputs.items():
        (args.out_dir / name).write_bytes(data)
        print(f"wrote {name:<22} {len(data):>9,} bytes  sha256={hashlib.sha256(data).hexdigest()}")
    print(f"rows={len(rows)} seed={args.seed} self-check=passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
