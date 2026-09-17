"""
Fixed, hand-written edge-case RAW LOG records (EC-001 .. EC-150).

These records are literals: they never depend on the random seed, so they are
byte-identical on every run. Each case declares the RAW LOG text exactly as it
must be stored, plus the answer-key values for the ten target fields.

Answer-key conventions (shared with generate_raw_logs.py):
  * A field value is the exact substring as it appears in the RAW LOG, without
    surrounding delimiters (quotes, brackets, "key=" labels, <>, mailto:).
  * plain string  -> VALID
  * bad("...")    -> INVALID      (present, but malformed / out of range)
  * ph("...")     -> PLACEHOLDER  (a token that stands for "no value": -, N/A, unknown, null)
  * field omitted -> MISSING      (not present in the log at all, or an empty value)
  * When a log holds several candidates for one field, the answer key holds the
    primary one and the others are listed in `secondary`.
"""

from dataclasses import dataclass, field
from typing import Dict, Optional, Tuple

VALID = "VALID"
INVALID = "INVALID"
PLACEHOLDER = "PLACEHOLDER"
MISSING = "MISSING"

FIELDS = (
    "entity_type",
    "email_address",
    "resource_url",
    "event_timestamp",
    "tool",
    "latitude",
    "longitude",
    "ip_address",
    "action_phrase",
    "status",
)


def bad(value: str) -> Tuple[str, str]:
    return (value, INVALID)


def ph(value: str) -> Tuple[str, str]:
    return (value, PLACEHOLDER)


@dataclass
class Case:
    case_id: str
    format_family: str
    raw_log: Optional[str]
    outcome: str = "NONE"
    tags: str = ""
    secondary: str = ""
    notes: str = ""
    broken: bool = False
    fields: Dict[str, Tuple[str, str]] = field(default_factory=dict)


CASES = []


def case(case_id, format_family, raw_log, *, outcome="NONE", tags="", secondary="",
         notes="", broken=False, **values):
    unknown = set(values) - set(FIELDS)
    if unknown:
        raise ValueError(f"{case_id}: unknown field(s) {sorted(unknown)}")
    fields = {}
    for name, value in values.items():
        fields[name] = value if isinstance(value, tuple) else (value, VALID)
    CASES.append(Case(case_id, format_family, raw_log, outcome, tags, secondary,
                      notes, broken, fields))


# --------------------------------------------------------------------------- #
# Entity Type (EC-001 .. EC-010)
# --------------------------------------------------------------------------- #
case("EC-001", "F1",
     '2026-01-05T08:12:44Z | entity=user | email=kavya.iyer@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/dashboard | tool=Firefox/125.0 | ip=192.168.4.21 | lat=12.9716 | lon=77.5946 | status=SUCCESS',
     outcome="SUCCESS", tags="entity_lowercase",
     entity_type="user", email_address="kavya.iyer@corp.example.com",
     resource_url="https://portal.corp.example.com/dashboard", event_timestamp="2026-01-05T08:12:44Z",
     tool="Firefox/125.0", ip_address="192.168.4.21", latitude="12.9716", longitude="77.5946",
     action_phrase="Access granted", status="SUCCESS")

case("EC-002", "F1",
     '2026-01-06T02:00:03Z | entity_type=service-account | email=svc-backup@infra.example.internal | action="Access granted" | resource=s3://prod-backups/daily/2026-01-06/ | tool=aws-cli/2.15.0 | ip=10.40.2.15 | status=SUCCESS',
     outcome="SUCCESS", tags="entity_hyphenated;coordinates_absent;date_in_resource",
     secondary="date_in_resource=2026-01-06",
     entity_type="service-account", email_address="svc-backup@infra.example.internal",
     resource_url="s3://prod-backups/daily/2026-01-06/", event_timestamp="2026-01-06T02:00:03Z",
     tool="aws-cli/2.15.0", ip_address="10.40.2.15", action_phrase="Access granted", status="SUCCESS")

case("EC-003", "F2",
     '[07/Jan/2026:03:15:09 +0000] Service Account svc-etl@infra.example.internal was denied access to db://prod/customers via python-requests/2.31.0 from 10.40.3.8 - 403 Forbidden',
     outcome="DECLINED", tags="entity_multi_word",
     entity_type="Service Account", email_address="svc-etl@infra.example.internal",
     resource_url="db://prod/customers", event_timestamp="07/Jan/2026:03:15:09 +0000",
     tool="python-requests/2.31.0", ip_address="10.40.3.8", action_phrase="was denied access to",
     status="403 Forbidden")

case("EC-004", "F2",
     '2026-01-08T10:45:30Z [ADMIN] rahul.kulkarni+audit@corp.example.com was granted access to /admin/users?page=2 via Chrome/124.0.6367.91 from 203.0.113.45 (18.5204, 73.8567) - 200 OK',
     outcome="SUCCESS", tags="entity_bracket_prefix;email_plus_tag",
     entity_type="ADMIN", email_address="rahul.kulkarni+audit@corp.example.com",
     resource_url="/admin/users?page=2", event_timestamp="2026-01-08T10:45:30Z",
     tool="Chrome/124.0.6367.91", ip_address="203.0.113.45", latitude="18.5204", longitude="73.8567",
     action_phrase="was granted access to", status="200 OK")

case("EC-005", "F3",
     'Jan  9 14:02:11 api-gw02 gatekeeper[3310]: {"entity":"API Client","principal":"integration.bluefin@partners.example.net","resource":"https://api.example.com/v2/invoices?status=open","tool":"okhttp/4.12.0","src_ip":"198.51.100.61","msg":"request permitted","status":"ALLOWED"}',
     outcome="SUCCESS", tags="entity_multi_word;syslog_space_padded_day;timestamp_no_year;keyword_status_in_resource",
     secondary="status_word_in_resource=status=open",
     entity_type="API Client", email_address="integration.bluefin@partners.example.net",
     resource_url="https://api.example.com/v2/invoices?status=open", event_timestamp="Jan  9 14:02:11",
     tool="okhttp/4.12.0", ip_address="198.51.100.61", action_phrase="request permitted", status="ALLOWED")

case("EC-006", "F4",
     '203.0.113.88 - - [10/Jan/2026:19:20:05 +0000] "GET /catalog/items/5521 HTTP/1.1" 403 512 "-" "Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0" role=Guest user=<guest_4471@example.com> msg="Access denied"',
     outcome="DECLINED", tags="entity_key_role;email_angle_brackets;user_agent_full",
     entity_type="Guest", email_address="guest_4471@example.com",
     resource_url="/catalog/items/5521", event_timestamp="10/Jan/2026:19:20:05 +0000",
     tool="Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0",
     ip_address="203.0.113.88", action_phrase="Access denied", status="403")

case("EC-007", "F5",
     '11-01-2026 00:00;BOT;;kube-probe/1.29;http://10.20.0.15:8080/actuator/health;;;10.20.0.3;Request allowed;OK',
     outcome="SUCCESS", tags="email_absent;coordinates_absent;ip_in_resource;ambiguous_day_month_order",
     secondary="ip_like_in_resource=10.20.0.15",
     entity_type="BOT", resource_url="http://10.20.0.15:8080/actuator/health",
     event_timestamp="11-01-2026 00:00", tool="kube-probe/1.29", ip_address="10.20.0.3",
     action_phrase="Request allowed", status="OK")

case("EC-008", "F1",
     '2026-01-12T09:30:00Z | entity=contractor | email=lucas.silva@vendor.example.net | action="Access denied" | resource=https://portal.corp.example.com/finance/ledger | tool=Edge/124.0.2478.67 | ip=198.51.100.140 | lat=-23.5505 | lon=-46.6333 | status=DENIED',
     outcome="DECLINED", tags="entity_unknown_value",
     notes="'contractor' is not one of the known entity types.",
     entity_type=bad("contractor"), email_address="lucas.silva@vendor.example.net",
     resource_url="https://portal.corp.example.com/finance/ledger", event_timestamp="2026-01-12T09:30:00Z",
     tool="Edge/124.0.2478.67", ip_address="198.51.100.140", latitude="-23.5505", longitude="-46.6333",
     action_phrase="Access denied", status="DENIED")

case("EC-009", "F1",
     '2026-01-13T11:11:11Z | email=sofia.garcia@mail.example.org | action="Login successful" | resource=https://mail.example.org/inbox | tool=Safari/17.4.1 | ip=192.0.2.44 | lat=40.7128 | lon=-74.0060 | status=OK',
     outcome="SUCCESS", tags="entity_absent",
     email_address="sofia.garcia@mail.example.org", resource_url="https://mail.example.org/inbox",
     event_timestamp="2026-01-13T11:11:11Z", tool="Safari/17.4.1", ip_address="192.0.2.44",
     latitude="40.7128", longitude="-74.0060", action_phrase="Login successful", status="OK")

case("EC-010", "F1",
     '2026-01-14T16:40:27Z | type=N/A | email=olivia.brown@shop.example.org | action="Access granted" | resource=/account/orders | tool=Chrome/124.0.6367.91 | ip=198.51.100.9 | status=SUCCESS',
     outcome="SUCCESS", tags="entity_placeholder;entity_key_type;coordinates_absent",
     entity_type=ph("N/A"), email_address="olivia.brown@shop.example.org", resource_url="/account/orders",
     event_timestamp="2026-01-14T16:40:27Z", tool="Chrome/124.0.6367.91", ip_address="198.51.100.9",
     action_phrase="Access granted", status="SUCCESS")

# --------------------------------------------------------------------------- #
# Email Address (EC-011 .. EC-026)
# --------------------------------------------------------------------------- #
case("EC-011", "F1",
     '2026-01-15T07:05:55Z | entity=USER | email=john..doe@corp.example.com | action="Login failed" | resource=https://portal.corp.example.com/login | tool=Chrome/124.0.6367.91 | ip=192.168.10.77 | status=FAILED',
     outcome="DECLINED", tags="email_consecutive_dots",
     entity_type="USER", email_address=bad("john..doe@corp.example.com"),
     resource_url="https://portal.corp.example.com/login", event_timestamp="2026-01-15T07:05:55Z",
     tool="Chrome/124.0.6367.91", ip_address="192.168.10.77", action_phrase="Login failed", status="FAILED")

case("EC-012", "F1",
     '2026-01-15T07:06:12Z | entity=USER | email=meera.nair@@corp.example.com | action="Login failed" | resource=https://portal.corp.example.com/login | tool=Firefox/125.0 | ip=192.168.10.78 | status=FAILED',
     outcome="DECLINED", tags="email_double_at",
     entity_type="USER", email_address=bad("meera.nair@@corp.example.com"),
     resource_url="https://portal.corp.example.com/login", event_timestamp="2026-01-15T07:06:12Z",
     tool="Firefox/125.0", ip_address="192.168.10.78", action_phrase="Login failed", status="FAILED")

case("EC-013", "F1",
     '2026-01-16T12:00:00Z | entity=ADMIN | email=root@localhost | action="Access granted" | resource=/etc/ssh/sshd_config | tool=OpenSSH_9.6p1 | ip=127.0.0.1 | status=SUCCESS',
     outcome="SUCCESS", tags="email_no_tld;resource_linux_path;ip_loopback",
     notes="root@localhost has no TLD; accepted by some local mail systems but treated as invalid here.",
     entity_type="ADMIN", email_address=bad("root@localhost"), resource_url="/etc/ssh/sshd_config",
     event_timestamp="2026-01-16T12:00:00Z", tool="OpenSSH_9.6p1", ip_address="127.0.0.1",
     action_phrase="Access granted", status="SUCCESS")

case("EC-014", "F1",
     '2026-01-16T12:05:10Z | entity=USER | email=@example.com | action="Access denied" | resource=https://portal.corp.example.com/reports | tool=curl/8.4.0 | ip=203.0.113.19 | status=DENIED',
     outcome="DECLINED", tags="email_missing_local_part",
     entity_type="USER", email_address=bad("@example.com"),
     resource_url="https://portal.corp.example.com/reports", event_timestamp="2026-01-16T12:05:10Z",
     tool="curl/8.4.0", ip_address="203.0.113.19", action_phrase="Access denied", status="DENIED")

case("EC-015", "F2",
     '[17/Jan/2026:09:14:22 +0530] User arjun.menon [at] corp.example [dot] com was denied access to /reports/q4 via Chrome/124.0.6367.91 from 192.168.20.14 - 403 Forbidden',
     outcome="DECLINED", tags="email_obfuscated",
     notes="Address is written with [at]/[dot] and contains spaces.",
     entity_type="User", email_address=bad("arjun.menon [at] corp.example [dot] com"),
     resource_url="/reports/q4", event_timestamp="17/Jan/2026:09:14:22 +0530",
     tool="Chrome/124.0.6367.91", ip_address="192.168.20.14", action_phrase="was denied access to",
     status="403 Forbidden")

case("EC-016", "F1",
     '2026-01-18T13:22:41Z | entity=CUSTOMER | email=josé.fernandes@exämple.com | action="Login successful" | resource=https://shop.example.org/account | tool=Safari/17.4.1 | ip=198.51.100.200 | lat=-22.9068 | lon=-43.1729 | status=SUCCESS',
     outcome="SUCCESS", tags="email_non_ascii",
     notes="Non-ASCII local part and domain: allowed by RFC 6531/IDN, invalid under ASCII-only rules.",
     entity_type="CUSTOMER", email_address=bad("josé.fernandes@exämple.com"),
     resource_url="https://shop.example.org/account", event_timestamp="2026-01-18T13:22:41Z",
     tool="Safari/17.4.1", ip_address="198.51.100.200", latitude="-22.9068", longitude="-43.1729",
     action_phrase="Login successful", status="SUCCESS")

case("EC-017", "F3",
     'Jan 19 08:30:12 sso01 authd[882]: {"entity_type":"user","user":"zoë.müller@corp.example.com","resource":"https://sso.example.com/saml/acs","tool":"Firefox/125.0","src_ip":"2001:db8:4f1a::21","msg":"authentication succeeded","result":"SUCCESS"}',
     outcome="SUCCESS", tags="email_non_ascii;ipv6_compressed;timestamp_no_year",
     notes="Non-ASCII local part: allowed by RFC 6531, invalid under ASCII-only rules.",
     entity_type="user", email_address=bad("zoë.müller@corp.example.com"),
     resource_url="https://sso.example.com/saml/acs", event_timestamp="Jan 19 08:30:12",
     tool="Firefox/125.0", ip_address="2001:db8:4f1a::21", action_phrase="authentication succeeded",
     status="SUCCESS")

case("EC-018", "F5",
     '19-01-2026 17:45;USER;PRIYA.SHARMA@CORP.EXAMPLE.COM;Chrome/124.0.6367.91;https://portal.corp.example.com/reports/q1?id=4471;19.0760;72.8777;192.168.10.45;Access granted;SUCCESS',
     outcome="SUCCESS", tags="email_uppercase",
     entity_type="USER", email_address="PRIYA.SHARMA@CORP.EXAMPLE.COM",
     resource_url="https://portal.corp.example.com/reports/q1?id=4471", event_timestamp="19-01-2026 17:45",
     tool="Chrome/124.0.6367.91", ip_address="192.168.10.45", latitude="19.0760", longitude="72.8777",
     action_phrase="Access granted", status="SUCCESS")

case("EC-019", "F2",
     '[20/Jan/2026:10:02:33 +0000] User "Daniel Wilson" <daniel.wilson@example.co.uk> was granted access to https://intranet.example.com/wiki/Onboarding via Edge/124.0.2478.67 from 198.51.100.77 (51.5074, -0.1278) - 200 OK',
     outcome="SUCCESS", tags="email_display_name;email_angle_brackets;email_multi_part_tld",
     entity_type="User", email_address="daniel.wilson@example.co.uk",
     resource_url="https://intranet.example.com/wiki/Onboarding", event_timestamp="20/Jan/2026:10:02:33 +0000",
     tool="Edge/124.0.2478.67", ip_address="198.51.100.77", latitude="51.5074", longitude="-0.1278",
     action_phrase="was granted access to", status="200 OK")

case("EC-020", "F1",
     '2026-01-21T15:15:15Z | entity=USER | email=mailto:aisha.khan@example.gov.in | action="Access granted" | resource=https://portal.example.gov.in/services | tool=Chrome/124.0.6367.91 | ip=192.0.2.150 | lat=28.6139 | lon=77.2090 | status=SUCCESS',
     outcome="SUCCESS", tags="email_mailto_prefix;email_multi_part_tld",
     entity_type="USER", email_address="aisha.khan@example.gov.in",
     resource_url="https://portal.example.gov.in/services", event_timestamp="2026-01-21T15:15:15Z",
     tool="Chrome/124.0.6367.91", ip_address="192.0.2.150", latitude="28.6139", longitude="77.2090",
     action_phrase="Access granted", status="SUCCESS")

case("EC-021", "F2",
     '[22/Jan/2026:11:47:03 +0530] Admin vikram.rao@corp.example.com (on behalf of sneha.joshi@corp.example.com) was granted access to /admin/payroll/export via Postman/10.24.3 from 192.168.30.12 - 200 OK',
     outcome="SUCCESS", tags="multiple_emails",
     secondary="delegated_email=sneha.joshi@corp.example.com",
     notes="First email is the acting principal; the second is the delegated identity.",
     entity_type="Admin", email_address="vikram.rao@corp.example.com",
     resource_url="/admin/payroll/export", event_timestamp="22/Jan/2026:11:47:03 +0530",
     tool="Postman/10.24.3", ip_address="192.168.30.12", action_phrase="was granted access to",
     status="200 OK")

case("EC-022", "F3",
     'Jan 23 06:10:55 alerts01 notifier[4410]: {"entity_type":"service_account","principal":"svc-monitoring@infra.example.internal","notify":"oncall+db@corp.example.com","resource":"postgres://reporting.example.internal:5432/sales","tool":"psql/16.2","src_ip":"10.40.5.30","msg":"authentication failed","result":"FAILED"}',
     outcome="DECLINED", tags="multiple_emails;resource_database_uri;timestamp_no_year",
     secondary="notify_email=oncall+db@corp.example.com",
     notes="'principal' is the acting identity; 'notify' is a notification recipient.",
     entity_type="service_account", email_address="svc-monitoring@infra.example.internal",
     resource_url="postgres://reporting.example.internal:5432/sales", event_timestamp="Jan 23 06:10:55",
     tool="psql/16.2", ip_address="10.40.5.30", action_phrase="authentication failed", status="FAILED")

case("EC-023", "F1",
     '2026-01-24T20:20:20Z | entity=GUEST | email=visitor.2291@guest.example.org. | action="Access denied" | resource=https://portal.corp.example.com/private | tool=Safari/17.4.1 | ip=203.0.113.201 | status=DENIED',
     outcome="DECLINED", tags="email_trailing_dot",
     entity_type="GUEST", email_address=bad("visitor.2291@guest.example.org."),
     resource_url="https://portal.corp.example.com/private", event_timestamp="2026-01-24T20:20:20Z",
     tool="Safari/17.4.1", ip_address="203.0.113.201", action_phrase="Access denied", status="DENIED")

case("EC-024", "F5",
     '25-01-2026 08:08;USER;ethan.murphy.example.com;Firefox/125.0;https://portal.corp.example.com/login;40.7128;-74.0060;198.51.100.33;Login attempt rejected;FAILED',
     outcome="DECLINED", tags="email_missing_at",
     notes="The email position holds a hostname-like value with no @.",
     entity_type="USER", email_address=bad("ethan.murphy.example.com"),
     resource_url="https://portal.corp.example.com/login", event_timestamp="25-01-2026 08:08",
     tool="Firefox/125.0", ip_address="198.51.100.33", latitude="40.7128", longitude="-74.0060",
     action_phrase="Login attempt rejected", status="FAILED")

case("EC-025", "F1",
     '2026-01-26T09:41:07.113+09:00 | entity=USER | email=kenji-tanaka99@eu.corp.example.com | action="Access granted" | resource=https://portal.corp.example.com:8443/projects/alpha#timeline | tool=Chrome/124.0.6367.91 | ip=192.0.2.18 | lat=35.6762 | lon=139.6503 | status=SUCCESS',
     outcome="SUCCESS", tags="email_subdomain;email_hyphen_digits;resource_port;resource_fragment;timestamp_ms_offset",
     entity_type="USER", email_address="kenji-tanaka99@eu.corp.example.com",
     resource_url="https://portal.corp.example.com:8443/projects/alpha#timeline",
     event_timestamp="2026-01-26T09:41:07.113+09:00", tool="Chrome/124.0.6367.91", ip_address="192.0.2.18",
     latitude="35.6762", longitude="139.6503", action_phrase="Access granted", status="SUCCESS")

case("EC-026", "F2",
     '[26/Jan/2026:23:59:59 +0000] Guest anonymous was denied access to /members/downloads via curl/8.4.0 from 203.0.113.250 - 401 Unauthorized',
     outcome="DECLINED", tags="email_absent_anonymous",
     notes="The word 'anonymous' is not an email address.",
     entity_type="Guest", resource_url="/members/downloads", event_timestamp="26/Jan/2026:23:59:59 +0000",
     tool="curl/8.4.0", ip_address="203.0.113.250", action_phrase="was denied access to",
     status="401 Unauthorized")

# --------------------------------------------------------------------------- #
# Resource / URL (EC-027 .. EC-042)
# --------------------------------------------------------------------------- #
case("EC-027", "F2",
     '2026-02-01T10:00:00Z [OK] User grace.andersen@corp.example.com connecting from 192.0.2.61 with Firefox/125.0 was granted access to https://portal.corp.example.com/reports/q1.',
     outcome="SUCCESS", tags="resource_trailing_punctuation",
     notes="The final '.' ends the sentence and is not part of the URL.",
     entity_type="User", email_address="grace.andersen@corp.example.com",
     resource_url="https://portal.corp.example.com/reports/q1", event_timestamp="2026-02-01T10:00:00Z",
     tool="Firefox/125.0", ip_address="192.0.2.61", action_phrase="was granted access to", status="OK")

case("EC-028", "F2",
     '[02/Feb/2026:12:30:45 +0530] Admin nadia.haddad@corp.example.com was denied access to (https://vault.corp.example.com/secrets/prod), via Chrome/124.0.6367.91 from 192.168.50.9 - 403 Forbidden',
     outcome="DECLINED", tags="resource_wrapped_in_parentheses;resource_trailing_punctuation",
     entity_type="Admin", email_address="nadia.haddad@corp.example.com",
     resource_url="https://vault.corp.example.com/secrets/prod", event_timestamp="02/Feb/2026:12:30:45 +0530",
     tool="Chrome/124.0.6367.91", ip_address="192.168.50.9", action_phrase="was denied access to",
     status="403 Forbidden")

case("EC-029", "F4",
     '203.0.113.66 - - [03/Feb/2026:02:14:09 +0000] "GET /login?user=admin\'--&pass=x HTTP/1.1" 403 128 "-" "sqlmap/1.8.3#stable (https://sqlmap.org)" msg="Request blocked by policy"',
     outcome="DECLINED", tags="resource_sql_injection;url_in_tool;email_placeholder;entity_absent",
     secondary="url_in_tool=https://sqlmap.org",
     notes="Email comes from the combined-log remote_user slot, which holds '-'.",
     email_address=ph("-"), resource_url="/login?user=admin'--&pass=x",
     event_timestamp="03/Feb/2026:02:14:09 +0000", tool="sqlmap/1.8.3#stable (https://sqlmap.org)",
     ip_address="203.0.113.66", action_phrase="Request blocked by policy", status="403")

case("EC-030", "F1",
     '2026-02-04T05:05:05Z | entity=SERVICE_ACCOUNT | email=svc-deploy@infra.example.internal | action="Access granted" | resource=https://deploy:s3cr3t@artifacts.example.internal/releases/v2.3.1.tar.gz | tool=Wget/1.21.4 | ip=10.40.8.2 | status=SUCCESS',
     outcome="SUCCESS", tags="resource_embedded_credentials;email_like_in_resource",
     secondary="email_like_in_resource=s3cr3t@artifacts.example.internal",
     entity_type="SERVICE_ACCOUNT", email_address="svc-deploy@infra.example.internal",
     resource_url="https://deploy:s3cr3t@artifacts.example.internal/releases/v2.3.1.tar.gz",
     event_timestamp="2026-02-04T05:05:05Z", tool="Wget/1.21.4", ip_address="10.40.8.2",
     action_phrase="Access granted", status="SUCCESS")

case("EC-031", "F1",
     '2026-02-05T00:00:30Z | entity=BOT | action="Request allowed" | resource=http://10.20.0.15:8080/actuator/health | tool=kube-probe/1.29 | ip=10.20.0.3 | status=200',
     outcome="SUCCESS", tags="ip_in_resource;email_absent;status_http_code",
     secondary="ip_like_in_resource=10.20.0.15",
     entity_type="BOT", resource_url="http://10.20.0.15:8080/actuator/health",
     event_timestamp="2026-02-05T00:00:30Z", tool="kube-probe/1.29", ip_address="10.20.0.3",
     action_phrase="Request allowed", status="200")

case("EC-032", "F5",
     '05-02-2026 14:20:11;API_CLIENT;api-client-0042@partners.example.net;python-requests/2.31.0;https://api.example.com/v2/search?q=annual%20report%202025&lang=en-GB;51.5074 N;0.1278 W;198.51.100.52;Access granted;SUCCESS',
     outcome="SUCCESS", tags="resource_percent_encoded;coordinates_hemisphere_letters;ambiguous_day_month_order",
     entity_type="API_CLIENT", email_address="api-client-0042@partners.example.net",
     resource_url="https://api.example.com/v2/search?q=annual%20report%202025&lang=en-GB",
     event_timestamp="05-02-2026 14:20:11", tool="python-requests/2.31.0", ip_address="198.51.100.52",
     latitude="51.5074 N", longitude="0.1278 W", action_phrase="Access granted", status="SUCCESS")

case("EC-033", "F1",
     r'2026-02-06T09:15:00Z | entity=ADMIN | email=elena.ivanova@corp.example.com | action="Access denied" | resource=C:\Share\Finance\Budget 2026.xlsx | tool=Explorer/10.0.22631 | ip=192.168.60.21 | status=DENIED',
     outcome="DECLINED", tags="resource_windows_path;resource_contains_space",
     entity_type="ADMIN", email_address="elena.ivanova@corp.example.com",
     resource_url=r"C:\Share\Finance\Budget 2026.xlsx", event_timestamp="2026-02-06T09:15:00Z",
     tool="Explorer/10.0.22631", ip_address="192.168.60.21", action_phrase="Access denied", status="DENIED")

case("EC-034", "F5",
     r'06-02-2026 23:10;SERVICE_ACCOUNT;svc-reporting@infra.example.internal;smbclient/4.19.5;\\fileserver01\hr$\contracts\2026\;;;10.40.9.14;Permission denied;DENIED',
     outcome="DECLINED", tags="resource_unc_path;coordinates_absent;ambiguous_day_month_order",
     entity_type="SERVICE_ACCOUNT", email_address="svc-reporting@infra.example.internal",
     resource_url="\\\\fileserver01\\hr$\\contracts\\2026\\", event_timestamp="06-02-2026 23:10",
     tool="smbclient/4.19.5", ip_address="10.40.9.14", action_phrase="Permission denied", status="DENIED")

case("EC-035", "F2",
     '[07/Feb/2026:04:44:44 +0000] Service Account svc-etl@infra.example.internal was denied access to /var/log/secure via OpenSSH_9.6p1 from 10.40.3.8 - status: DENIED',
     outcome="DECLINED", tags="resource_linux_path;entity_multi_word",
     entity_type="Service Account", email_address="svc-etl@infra.example.internal",
     resource_url="/var/log/secure", event_timestamp="07/Feb/2026:04:44:44 +0000", tool="OpenSSH_9.6p1",
     ip_address="10.40.3.8", action_phrase="was denied access to", status="DENIED")

case("EC-036", "F3",
     'Feb  8 01:00:02 backup01 gatekeeper[1201]: {"entity_type":"service_account","principal":"svc-backup@infra.example.internal","resource":"s3://analytics-raw/events/dt=2026-02-07/part-00017.snappy.parquet","tool":"Boto3/1.34.69","src_ip":"10.40.2.15","msg":"access granted","result":"SUCCESS"}',
     outcome="SUCCESS", tags="resource_s3_uri;syslog_space_padded_day;timestamp_no_year;date_in_resource",
     secondary="date_in_resource=2026-02-07",
     entity_type="service_account", email_address="svc-backup@infra.example.internal",
     resource_url="s3://analytics-raw/events/dt=2026-02-07/part-00017.snappy.parquet",
     event_timestamp="Feb  8 01:00:02", tool="Boto3/1.34.69", ip_address="10.40.2.15",
     action_phrase="access granted", status="SUCCESS")

case("EC-037", "F1",
     '2026-02-09T18:00:00Z | entity=API_CLIENT | email=integration.redwood@partners.example.net | action="Access granted" | resource=ftp://files.example.net/export/q1%20final.csv | tool=curl/8.4.0 | ip=198.51.100.99 | status=SUCCESS',
     outcome="SUCCESS", tags="resource_ftp;resource_percent_encoded",
     entity_type="API_CLIENT", email_address="integration.redwood@partners.example.net",
     resource_url="ftp://files.example.net/export/q1%20final.csv", event_timestamp="2026-02-09T18:00:00Z",
     tool="curl/8.4.0", ip_address="198.51.100.99", action_phrase="Access granted", status="SUCCESS")

case("EC-038", "F4",
     '198.51.100.23:51544 - liam.smith@corp.example.com [2026-02-10 08:30:01.004] "CONNECT https://updates.example.com:443/stable/manifest.json HTTP/1.1" 200 0 "-" "Go-http-client/1.1" type=USER msg="Request allowed"',
     outcome="SUCCESS", tags="resource_absolute_url_in_request;ip_with_port;email_in_remote_user_slot",
     secondary="client_port=51544",
     entity_type="USER", email_address="liam.smith@corp.example.com",
     resource_url="https://updates.example.com:443/stable/manifest.json",
     event_timestamp="2026-02-10 08:30:01.004", tool="Go-http-client/1.1", ip_address="198.51.100.23",
     action_phrase="Request allowed", status="200")

case("EC-039", "F4",
     '192.0.2.77 - - [11/Feb/2026:13:13:13 +0000] "POST /api/v1/users/1042/roles HTTP/1.1" 403 87 "https://admin.corp.example.com/users/1042/edit" "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15" user=<omar.haddad@corp.example.com> type=Admin msg="Access denied: insufficient privileges"',
     outcome="DECLINED", tags="referer_url_present;user_agent_full",
     secondary="referer_url=https://admin.corp.example.com/users/1042/edit",
     notes="The quoted referer URL is not the requested resource.",
     entity_type="Admin", email_address="omar.haddad@corp.example.com",
     resource_url="/api/v1/users/1042/roles", event_timestamp="11/Feb/2026:13:13:13 +0000",
     tool="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
     ip_address="192.0.2.77", action_phrase="Access denied: insufficient privileges", status="403")

case("EC-040", "F1",
     '2026-02-12T03:03:03Z | entity=service_account | email=svc-billing-sync@infra.example.internal | action="Authentication failed" | resource=postgres://billing.example.internal:5432/ledger?sslmode=require | tool=psql/16.2 | ip=10.40.11.4 | status=FAILED',
     outcome="DECLINED", tags="resource_database_uri",
     entity_type="service_account", email_address="svc-billing-sync@infra.example.internal",
     resource_url="postgres://billing.example.internal:5432/ledger?sslmode=require",
     event_timestamp="2026-02-12T03:03:03Z", tool="psql/16.2", ip_address="10.40.11.4",
     action_phrase="Authentication failed", status="FAILED")

case("EC-041", "F1",
     '2026-02-13T22:22:22Z | entity=USER | email=hiro.sato@corp.example.com | action="Logout" | resource=- | tool=Chrome/124.0.6367.91 | ip=192.168.10.90 | status=SUCCESS',
     outcome="NEUTRAL", tags="resource_placeholder",
     entity_type="USER", email_address="hiro.sato@corp.example.com", resource_url=ph("-"),
     event_timestamp="2026-02-13T22:22:22Z", tool="Chrome/124.0.6367.91", ip_address="192.168.10.90",
     action_phrase="Logout", status="SUCCESS")

case("EC-042", "F5",
     '14-02-2026 10:10;USER;ingrid.andersen@example.com;Firefox/125.0;htps://portal.corp.example.com/login;64.1466;-21.9426;192.0.2.230;Login successful;SUCCESS',
     outcome="SUCCESS", tags="resource_invalid_scheme",
     entity_type="USER", email_address="ingrid.andersen@example.com",
     resource_url=bad("htps://portal.corp.example.com/login"), event_timestamp="14-02-2026 10:10",
     tool="Firefox/125.0", ip_address="192.0.2.230", latitude="64.1466", longitude="-21.9426",
     action_phrase="Login successful", status="SUCCESS")

# --------------------------------------------------------------------------- #
# Timestamp (EC-043 .. EC-060)
# --------------------------------------------------------------------------- #
case("EC-043", "F1",
     '2026-02-30 10:15:00 | entity=USER | email=noah.wilson@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Chrome/124.0.6367.91 | ip=192.168.10.101 | status=SUCCESS',
     outcome="SUCCESS", tags="timestamp_impossible_date",
     entity_type="USER", email_address="noah.wilson@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp=bad("2026-02-30 10:15:00"),
     tool="Chrome/124.0.6367.91", ip_address="192.168.10.101", action_phrase="Access granted", status="SUCCESS")

case("EC-044", "F1",
     '2026-13-01T08:00:00Z | entity=USER | email=emma.brown@corp.example.com | action="Login successful" | resource=https://portal.corp.example.com/home | tool=Safari/17.4.1 | ip=192.168.10.102 | status=OK',
     outcome="SUCCESS", tags="timestamp_invalid_month",
     entity_type="USER", email_address="emma.brown@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp=bad("2026-13-01T08:00:00Z"),
     tool="Safari/17.4.1", ip_address="192.168.10.102", action_phrase="Login successful", status="OK")

case("EC-045", "F1",
     '2026-03-14T25:61:00Z | entity=ADMIN | email=rahul.kulkarni@corp.example.com | action="Access denied" | resource=/admin/audit | tool=Edge/124.0.2478.67 | ip=192.168.10.103 | status=DENIED',
     outcome="DECLINED", tags="timestamp_invalid_time",
     entity_type="ADMIN", email_address="rahul.kulkarni@corp.example.com", resource_url="/admin/audit",
     event_timestamp=bad("2026-03-14T25:61:00Z"), tool="Edge/124.0.2478.67", ip_address="192.168.10.103",
     action_phrase="Access denied", status="DENIED")

case("EC-046", "F1",
     '03/04/2026 09:30:00 AM | entity=USER | email=chen.li@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/calendar | tool=Chrome/124.0.6367.91 | ip=192.168.10.104 | status=SUCCESS',
     outcome="SUCCESS", tags="ambiguous_day_month_order;timestamp_12_hour",
     notes="Could be 3 April (DD/MM) or March 4 (MM/DD).",
     entity_type="USER", email_address="chen.li@corp.example.com",
     resource_url="https://portal.corp.example.com/calendar", event_timestamp="03/04/2026 09:30:00 AM",
     tool="Chrome/124.0.6367.91", ip_address="192.168.10.104", action_phrase="Access granted", status="SUCCESS")

case("EC-047", "F2",
     '1773480137 WARN user guest_4471@example.com access NOT granted to https://intranet.example.com/hr/payroll (tool: curl/8.4.0; client 10.0.0.5, via 203.0.113.9) status=200',
     outcome="DECLINED", tags="timestamp_epoch_seconds;action_negation;status_action_conflict;multiple_ips",
     secondary="proxy_ip=203.0.113.9",
     notes="Epoch 1773480137 = 2026-03-14 09:22:17 UTC. Phrase says NOT granted while status is 200.",
     entity_type="user", email_address="guest_4471@example.com",
     resource_url="https://intranet.example.com/hr/payroll", event_timestamp="1773480137",
     tool="curl/8.4.0", ip_address="10.0.0.5", action_phrase="access NOT granted to", status="200")

case("EC-048", "F1",
     '1773480137482 | entity=USER | email=sofia.santos@example.com | action="Access granted" | resource=https://portal.corp.example.com/reports/weekly | tool=Firefox/125.0 | ip=198.51.100.18 | lat=-23.5505 | lon=-46.6333 | status=SUCCESS',
     outcome="SUCCESS", tags="timestamp_epoch_milliseconds",
     entity_type="USER", email_address="sofia.santos@example.com",
     resource_url="https://portal.corp.example.com/reports/weekly", event_timestamp="1773480137482",
     tool="Firefox/125.0", ip_address="198.51.100.18", latitude="-23.5505", longitude="-46.6333",
     action_phrase="Access granted", status="SUCCESS")

case("EC-049", "F1",
     '2026-03-15T08:01:02.123456+05:30 | entity=USER | email=sneha.joshi@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/leave/apply | tool=Chrome/124.0.6367.91 | ip=192.168.30.15 | lat=18.5204 | lon=73.8567 | status=SUCCESS',
     outcome="SUCCESS", tags="timestamp_microseconds;timestamp_offset",
     entity_type="USER", email_address="sneha.joshi@corp.example.com",
     resource_url="https://portal.corp.example.com/leave/apply", event_timestamp="2026-03-15T08:01:02.123456+05:30",
     tool="Chrome/124.0.6367.91", ip_address="192.168.30.15", latitude="18.5204", longitude="73.8567",
     action_phrase="Access granted", status="SUCCESS")

case("EC-050", "F1",
     '2026-03-16t10:20:30z | entity=USER | email=arjun.menon@corp.example.com | action="Logout" | resource=https://portal.corp.example.com/logout | tool=Firefox/125.0 | ip=192.168.20.14 | status=OK',
     outcome="NEUTRAL", tags="timestamp_lowercase_separators",
     notes="RFC 3339 permits lowercase 't' and 'z'.",
     entity_type="USER", email_address="arjun.menon@corp.example.com",
     resource_url="https://portal.corp.example.com/logout", event_timestamp="2026-03-16t10:20:30z",
     tool="Firefox/125.0", ip_address="192.168.20.14", action_phrase="Logout", status="OK")

case("EC-051", "F3",
     'Mar  4 07:07:07 vpn01 openvpn[7781]: {"entity_type":"user","user":"kwame.mensah@corp.example.com","resource":"vpn://corp-gateway/eu-west","tool":"OpenVPN/2.6.10","src_ip":"203.0.113.140","geo":{"lat":-1.2921,"lng":36.8219},"msg":"authentication failed","result":"FAILED"}',
     outcome="DECLINED", tags="syslog_space_padded_day;timestamp_no_year;resource_custom_scheme;coordinates_json_object",
     entity_type="user", email_address="kwame.mensah@corp.example.com", resource_url="vpn://corp-gateway/eu-west",
     event_timestamp="Mar  4 07:07:07", tool="OpenVPN/2.6.10", ip_address="203.0.113.140",
     latitude="-1.2921", longitude="36.8219", action_phrase="authentication failed", status="FAILED")

case("EC-052", "F3",
     '<134>1 2026-03-17T11:12:13.456Z sso02 authd 882 AUTH - {"entity":"customer","user":"isabela.santos@shop.example.org","resource":"https://shop.example.org/checkout","tool":"Safari/17.4.1","ip":"198.51.100.201","location":"-22.9068,-43.1729","msg":"login successful","status":"success"}',
     outcome="SUCCESS", tags="syslog_rfc5424;coordinates_combined_string",
     entity_type="customer", email_address="isabela.santos@shop.example.org",
     resource_url="https://shop.example.org/checkout", event_timestamp="2026-03-17T11:12:13.456Z",
     tool="Safari/17.4.1", ip_address="198.51.100.201", latitude="-22.9068", longitude="-43.1729",
     action_phrase="login successful", status="success")

case("EC-053", "F5",
     '3/18/2026 9:05 PM;CUSTOMER;olivia.brown@shop.example.org;Chrome/124.0.6367.91;https://shop.example.org/orders/77120;40.7128;-74.0060;198.51.100.9;Access granted;SUCCESS',
     outcome="SUCCESS", tags="timestamp_12_hour;timestamp_unpadded",
     entity_type="CUSTOMER", email_address="olivia.brown@shop.example.org",
     resource_url="https://shop.example.org/orders/77120", event_timestamp="3/18/2026 9:05 PM",
     tool="Chrome/124.0.6367.91", ip_address="198.51.100.9", latitude="40.7128", longitude="-74.0060",
     action_phrase="Access granted", status="SUCCESS")

case("EC-054", "F1",
     '03/19/2026 13:05:00 PM | entity=USER | email=daniel.wilson@example.co.uk | action="Access granted" | resource=https://intranet.example.com/wiki | tool=Edge/124.0.2478.67 | ip=198.51.100.77 | status=SUCCESS',
     outcome="SUCCESS", tags="timestamp_invalid_12_hour",
     notes="Hour 13 cannot be combined with PM.",
     entity_type="USER", email_address="daniel.wilson@example.co.uk",
     resource_url="https://intranet.example.com/wiki", event_timestamp=bad("03/19/2026 13:05:00 PM"),
     tool="Edge/124.0.2478.67", ip_address="198.51.100.77", action_phrase="Access granted", status="SUCCESS")

case("EC-055", "F5",
     '20260320T101010;API_CLIENT;api-client-0042@partners.example.net;python-requests/2.31.0;https://api.example.com/v2/orders?limit=100;;;198.51.100.52;Rate limited;THROTTLED',
     outcome="NEUTRAL", tags="timestamp_compact;coordinates_absent",
     entity_type="API_CLIENT", email_address="api-client-0042@partners.example.net",
     resource_url="https://api.example.com/v2/orders?limit=100", event_timestamp="20260320T101010",
     tool="python-requests/2.31.0", ip_address="198.51.100.52", action_phrase="Rate limited", status="THROTTLED")

case("EC-056", "F1",
     '2026-03-21T06:00:00Z | ingested_at=2026-03-21T06:00:09Z | entity=USER | email=zara.patel@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/timesheets | tool=Chrome/124.0.6367.91 | ip=192.168.40.8 | status=SUCCESS',
     outcome="SUCCESS", tags="multiple_timestamps",
     secondary="ingested_at=2026-03-21T06:00:09Z",
     notes="The leading timestamp is the event time; ingested_at is pipeline metadata.",
     entity_type="USER", email_address="zara.patel@corp.example.com",
     resource_url="https://portal.corp.example.com/timesheets", event_timestamp="2026-03-21T06:00:00Z",
     tool="Chrome/124.0.6367.91", ip_address="192.168.40.8", action_phrase="Access granted", status="SUCCESS")

case("EC-057", "F1",
     'entity=USER | email=mateo.rossi@corp.example.com | action="Access denied" | resource=https://portal.corp.example.com/admin | tool=Firefox/125.0 | ip=192.168.40.9 | status=DENIED',
     outcome="DECLINED", tags="timestamp_absent",
     entity_type="USER", email_address="mateo.rossi@corp.example.com",
     resource_url="https://portal.corp.example.com/admin", tool="Firefox/125.0", ip_address="192.168.40.9",
     action_phrase="Access denied", status="DENIED")

case("EC-058", "F2",
     '[31/Apr/2026:10:00:00 +0000] User wei.zhang@corp.example.com was granted access to /reports/april via Chrome/124.0.6367.91 from 192.168.40.10 - 200 OK',
     outcome="SUCCESS", tags="timestamp_impossible_date",
     notes="April has 30 days.",
     entity_type="User", email_address="wei.zhang@corp.example.com", resource_url="/reports/april",
     event_timestamp=bad("31/Apr/2026:10:00:00 +0000"), tool="Chrome/124.0.6367.91",
     ip_address="192.168.40.10", action_phrase="was granted access to", status="200 OK")

case("EC-059", "F5",
     '29-02-2026 12:00;USER;fatima.khan@corp.example.com;Firefox/125.0;https://portal.corp.example.com/home;24.8607;67.0011;192.0.2.99;Login successful;SUCCESS',
     outcome="SUCCESS", tags="timestamp_non_leap_year_feb_29",
     notes="2026 is not a leap year.",
     entity_type="USER", email_address="fatima.khan@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp=bad("29-02-2026 12:00"),
     tool="Firefox/125.0", ip_address="192.0.2.99", latitude="24.8607", longitude="67.0011",
     action_phrase="Login successful", status="SUCCESS")

case("EC-060", "F1",
     '2026-03-22 14:30:00 IST | entity=USER | email=kavya.iyer@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/payslips | tool=Chrome/124.0.6367.91 | ip=192.168.4.21 | lat=12.9716 | lon=77.5946 | status=SUCCESS',
     outcome="SUCCESS", tags="timestamp_timezone_abbreviation",
     notes="'IST' is ambiguous (India, Israel or Ireland Standard Time).",
     entity_type="USER", email_address="kavya.iyer@corp.example.com",
     resource_url="https://portal.corp.example.com/payslips", event_timestamp="2026-03-22 14:30:00 IST",
     tool="Chrome/124.0.6367.91", ip_address="192.168.4.21", latitude="12.9716", longitude="77.5946",
     action_phrase="Access granted", status="SUCCESS")

# --------------------------------------------------------------------------- #
# Tool (EC-061 .. EC-070)
# --------------------------------------------------------------------------- #
case("EC-061", "F1",
     '2026-03-23T09:00:00Z | entity=BOT | email=bot-monitor@infra.example.internal | action="Request allowed" | resource=https://status.example.com/api/ping | tool=sensor-agent/10.0.0.1 | ip=10.20.0.9 | status=OK',
     outcome="SUCCESS", tags="ip_like_in_tool",
     secondary="ip_like_in_tool=10.0.0.1",
     entity_type="BOT", email_address="bot-monitor@infra.example.internal",
     resource_url="https://status.example.com/api/ping", event_timestamp="2026-03-23T09:00:00Z",
     tool="sensor-agent/10.0.0.1", ip_address="10.20.0.9", action_phrase="Request allowed", status="OK")

case("EC-062", "F2",
     '[24/Mar/2026:15:45:00 +0000] Bot uptime-checker@infra.example.internal was granted access to /healthz via agent/1.2.3.4 - 200 OK',
     outcome="SUCCESS", tags="ip_like_in_tool;ip_absent",
     secondary="ip_like_in_tool=1.2.3.4",
     notes="The only IP-looking value is the tool version; the client IP is absent.",
     entity_type="Bot", email_address="uptime-checker@infra.example.internal", resource_url="/healthz",
     event_timestamp="24/Mar/2026:15:45:00 +0000", tool="agent/1.2.3.4",
     action_phrase="was granted access to", status="200 OK")

case("EC-063", "F4",
     '192.0.2.140 - - [25/Mar/2026:10:10:10 +0000] "GET /dashboard HTTP/2.0" 200 18423 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.2478.67" user=<grace.andersen@corp.example.com> type=User msg="Login successful"',
     outcome="SUCCESS", tags="user_agent_multiple_browser_tokens;user_agent_full",
     notes="Edge user agent also contains Chrome and Safari tokens.",
     entity_type="User", email_address="grace.andersen@corp.example.com", resource_url="/dashboard",
     event_timestamp="25/Mar/2026:10:10:10 +0000",
     tool="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.2478.67",
     ip_address="192.0.2.140", action_phrase="Login successful", status="200")

case("EC-064", "F4",
     '198.51.100.211 - - [26/Mar/2026:07:31:44 +0000] "GET /m/account HTTP/1.1" 302 0 "-" "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Mobile/15E148 Safari/604.1" user=<amara.okafor@shop.example.org> type=Customer loc=POINT(3.3792 6.5244) msg="Login successful"',
     outcome="SUCCESS", tags="user_agent_mobile;user_agent_full;coordinates_wkt_lon_lat_order",
     notes="WKT POINT is (longitude latitude).",
     entity_type="Customer", email_address="amara.okafor@shop.example.org", resource_url="/m/account",
     event_timestamp="26/Mar/2026:07:31:44 +0000",
     tool="Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Mobile/15E148 Safari/604.1",
     ip_address="198.51.100.211", latitude="6.5244", longitude="3.3792",
     action_phrase="Login successful", status="302")

case("EC-065", "F3",
     'Mar 27 02:15:30 cloudtrail-fwd forwarder[5120]: {"entity_type":"service-account","principal":"svc-deploy@infra.example.internal","resource":"s3://prod-artifacts/releases/","tool":"aws-cli/2.15.0 Python/3.11.6 Linux/6.5.0-1017-aws exe/x86_64.ubuntu.22","src_ip":"10.40.8.2","msg":"access denied","result":"DENIED"}',
     outcome="DECLINED", tags="tool_compound_user_agent;timestamp_no_year",
     entity_type="service-account", email_address="svc-deploy@infra.example.internal",
     resource_url="s3://prod-artifacts/releases/", event_timestamp="Mar 27 02:15:30",
     tool="aws-cli/2.15.0 Python/3.11.6 Linux/6.5.0-1017-aws exe/x86_64.ubuntu.22",
     ip_address="10.40.8.2", action_phrase="access denied", status="DENIED")

case("EC-066", "F1",
     '2026-03-28T12:12:12Z | entity=USER | email=rohan.desai@corp.example.com | action="Login failed" | resource=https://portal.corp.example.com/login | tool=unknown | ip=203.0.113.37 | status=FAILED',
     outcome="DECLINED", tags="tool_placeholder",
     entity_type="USER", email_address="rohan.desai@corp.example.com",
     resource_url="https://portal.corp.example.com/login", event_timestamp="2026-03-28T12:12:12Z",
     tool=ph("unknown"), ip_address="203.0.113.37", action_phrase="Login failed", status="FAILED")

case("EC-067", "F4",
     '203.0.113.99 - - [29/Mar/2026:03:33:33 +0000] "HEAD /wp-login.php HTTP/1.0" 404 0 "-" "-" msg="Resource not found"',
     outcome="NEUTRAL", tags="tool_placeholder;email_placeholder;entity_absent;scanner_probe",
     notes="User agent field is '-'; remote_user slot is '-'.",
     email_address=ph("-"), resource_url="/wp-login.php", event_timestamp="29/Mar/2026:03:33:33 +0000",
     tool=ph("-"), ip_address="203.0.113.99", action_phrase="Resource not found", status="404")

case("EC-068", "F2",
     '03/30/2026 04:20:00 PM - API Client integration.orbit@partners.example.net was granted access to https://api.example.com/v2/shipments?status=in_transit using PostmanRuntime/7.37.0 from 198.51.100.130 [OK]',
     outcome="SUCCESS", tags="tool_keyword_using;timestamp_12_hour;entity_multi_word",
     entity_type="API Client", email_address="integration.orbit@partners.example.net",
     resource_url="https://api.example.com/v2/shipments?status=in_transit",
     event_timestamp="03/30/2026 04:20:00 PM", tool="PostmanRuntime/7.37.0", ip_address="198.51.100.130",
     action_phrase="was granted access to", status="OK")

case("EC-069", "F5",
     '31-03-2026 22:00:05;SERVICE_ACCOUNT;ci-runner-07@build.example.internal;terraform/1.7.2;s3://tf-state/prod/network.tfstate;;;10.40.12.7;Access granted;SUCCESS',
     outcome="SUCCESS", tags="tool_lowercase;coordinates_absent",
     entity_type="SERVICE_ACCOUNT", email_address="ci-runner-07@build.example.internal",
     resource_url="s3://tf-state/prod/network.tfstate", event_timestamp="31-03-2026 22:00:05",
     tool="terraform/1.7.2", ip_address="10.40.12.7", action_phrase="Access granted", status="SUCCESS")

case("EC-070", "F3",
     'Apr  1 08:00:00 k8s-api01 audit[1]: {"entity":"user","user":"liam.smith@corp.example.com","resource":"https://k8s.example.internal:6443/api/v1/namespaces/prod/secrets","src_ip":"192.168.70.5","msg":"forbidden","status":403}',
     outcome="DECLINED", tags="tool_absent;status_numeric_json;syslog_space_padded_day;timestamp_no_year",
     entity_type="user", email_address="liam.smith@corp.example.com",
     resource_url="https://k8s.example.internal:6443/api/v1/namespaces/prod/secrets",
     event_timestamp="Apr  1 08:00:00", ip_address="192.168.70.5", action_phrase="forbidden", status="403")

# --------------------------------------------------------------------------- #
# Latitude / Longitude (EC-071 .. EC-090)
# --------------------------------------------------------------------------- #
case("EC-071", "F1",
     '2026-04-02T10:00:00Z | entity=USER | email=noah.wilson@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Chrome/124.0.6367.91 | ip=198.51.100.44 | lat=0.0000 | lon=0.0000 | status=SUCCESS',
     outcome="SUCCESS", tags="coordinates_null_island",
     notes="Numerically valid, but 0,0 is often a default for an unknown location.",
     entity_type="USER", email_address="noah.wilson@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-04-02T10:00:00Z",
     tool="Chrome/124.0.6367.91", ip_address="198.51.100.44", latitude="0.0000", longitude="0.0000",
     action_phrase="Access granted", status="SUCCESS")

case("EC-072", "F1",
     '2026-04-03T10:00:00Z | entity=BOT | email=bot-monitor@infra.example.internal | action="Request allowed" | resource=https://status.example.com/api/ping | tool=curl/8.4.0 | ip=10.20.0.9 | lat=90.0 | lon=180.0 | status=OK',
     outcome="SUCCESS", tags="coordinates_boundary",
     entity_type="BOT", email_address="bot-monitor@infra.example.internal",
     resource_url="https://status.example.com/api/ping", event_timestamp="2026-04-03T10:00:00Z",
     tool="curl/8.4.0", ip_address="10.20.0.9", latitude="90.0", longitude="180.0",
     action_phrase="Request allowed", status="OK")

case("EC-073", "F1",
     '2026-04-03T10:05:00Z | entity=BOT | email=bot-monitor@infra.example.internal | action="Request allowed" | resource=https://status.example.com/api/ping | tool=curl/8.4.0 | ip=10.20.0.9 | latitude=-90.000000 | longitude=-180.000000 | status=OK',
     outcome="SUCCESS", tags="coordinates_boundary;coordinates_long_key_names",
     entity_type="BOT", email_address="bot-monitor@infra.example.internal",
     resource_url="https://status.example.com/api/ping", event_timestamp="2026-04-03T10:05:00Z",
     tool="curl/8.4.0", ip_address="10.20.0.9", latitude="-90.000000", longitude="-180.000000",
     action_phrase="Request allowed", status="OK")

case("EC-074", "F1",
     '2026-04-04T11:11:00Z | entity=USER | email=elena.ivanova@corp.example.com | action="Access denied" | resource=https://portal.corp.example.com/finance | tool=Firefox/125.0 | ip=192.168.60.21 | lat=91.2500 | lon=37.6173 | status=DENIED',
     outcome="DECLINED", tags="coordinates_out_of_range",
     entity_type="USER", email_address="elena.ivanova@corp.example.com",
     resource_url="https://portal.corp.example.com/finance", event_timestamp="2026-04-04T11:11:00Z",
     tool="Firefox/125.0", ip_address="192.168.60.21", latitude=bad("91.2500"), longitude="37.6173",
     action_phrase="Access denied", status="DENIED")

case("EC-075", "F1",
     '2026-04-04T11:12:00Z | entity=USER | email=elena.ivanova@corp.example.com | action="Access denied" | resource=https://portal.corp.example.com/finance | tool=Firefox/125.0 | ip=192.168.60.21 | lat=55.7558 | lon=-181.0000 | status=DENIED',
     outcome="DECLINED", tags="coordinates_out_of_range",
     entity_type="USER", email_address="elena.ivanova@corp.example.com",
     resource_url="https://portal.corp.example.com/finance", event_timestamp="2026-04-04T11:12:00Z",
     tool="Firefox/125.0", ip_address="192.168.60.21", latitude="55.7558", longitude=bad("-181.0000"),
     action_phrase="Access denied", status="DENIED")

case("EC-076", "F1",
     '2026-04-05T09:09:09Z | entity=USER | email=chen.li@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/calendar | tool=Chrome/124.0.6367.91 | ip=192.168.10.104 | lat=NaN | lon=NaN | status=SUCCESS',
     outcome="SUCCESS", tags="coordinates_nan",
     entity_type="USER", email_address="chen.li@corp.example.com",
     resource_url="https://portal.corp.example.com/calendar", event_timestamp="2026-04-05T09:09:09Z",
     tool="Chrome/124.0.6367.91", ip_address="192.168.10.104", latitude=bad("NaN"), longitude=bad("NaN"),
     action_phrase="Access granted", status="SUCCESS")

case("EC-077", "F1",
     '2026-04-05T09:10:00Z | entity=USER | email=chen.li@corp.example.com | action="Logout" | resource=https://portal.corp.example.com/logout | tool=Chrome/124.0.6367.91 | ip=192.168.10.104 | lat=N/A | lon=N/A | status=OK',
     outcome="NEUTRAL", tags="coordinates_placeholder",
     entity_type="USER", email_address="chen.li@corp.example.com",
     resource_url="https://portal.corp.example.com/logout", event_timestamp="2026-04-05T09:10:00Z",
     tool="Chrome/124.0.6367.91", ip_address="192.168.10.104", latitude=ph("N/A"), longitude=ph("N/A"),
     action_phrase="Logout", status="OK")

case("EC-078", "F1",
     '2026-04-06T14:00:00Z | entity=USER | email=sipho.dlamini@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Firefox/125.0 | ip=198.51.100.160 | lat=-26.2041 | status=SUCCESS',
     outcome="SUCCESS", tags="coordinates_partial",
     entity_type="USER", email_address="sipho.dlamini@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-04-06T14:00:00Z",
     tool="Firefox/125.0", ip_address="198.51.100.160", latitude="-26.2041",
     action_phrase="Access granted", status="SUCCESS")

case("EC-079", "F3",
     'Apr  6 14:05:00 geo01 locator[300]: {"entity_type":"user","user":"sipho.dlamini@corp.example.com","resource":"https://portal.corp.example.com/maps","tool":"Firefox/125.0","src_ip":"198.51.100.160","geo":{"lng":28.0473},"msg":"access granted","result":"SUCCESS"}',
     outcome="SUCCESS", tags="coordinates_partial;syslog_space_padded_day;timestamp_no_year",
     entity_type="user", email_address="sipho.dlamini@corp.example.com",
     resource_url="https://portal.corp.example.com/maps", event_timestamp="Apr  6 14:05:00",
     tool="Firefox/125.0", ip_address="198.51.100.160", longitude="28.0473",
     action_phrase="access granted", status="SUCCESS")

case("EC-080", "F1",
     '2026-04-07T08:30:00Z | entity=USER | email=lucas.silva@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Firefox/125.0 | ip=192.0.2.88 | lat=48,8566 | lon=2,3522 | status=SUCCESS',
     outcome="SUCCESS", tags="coordinates_decimal_comma",
     notes="European decimal comma; ambiguous with a lat,lon pair separator.",
     entity_type="USER", email_address="lucas.silva@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-04-07T08:30:00Z",
     tool="Firefox/125.0", ip_address="192.0.2.88", latitude=bad("48,8566"), longitude=bad("2,3522"),
     action_phrase="Access granted", status="SUCCESS")

case("EC-081", "F1",
     '2026-04-08T12:00:00Z | entity=USER | email=emma.brown@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Safari/17.4.1 | ip=192.0.2.12 | geo=40.7128,-74.0060 | status=SUCCESS',
     outcome="SUCCESS", tags="coordinates_combined_field",
     entity_type="USER", email_address="emma.brown@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-04-08T12:00:00Z",
     tool="Safari/17.4.1", ip_address="192.0.2.12", latitude="40.7128", longitude="-74.0060",
     action_phrase="Access granted", status="SUCCESS")

case("EC-082", "F2",
     '[09/Apr/2026:16:20:00 +0530] User priya.sharma@corp.example.com was granted access to /reports/q1 via Chrome/124.0.6367.91 from 192.168.10.45 at 19°04\'33.6"N 72°52\'39.7"E - 200 OK',
     outcome="SUCCESS", tags="coordinates_dms",
     notes="DMS of 19.0760, 72.8777.",
     entity_type="User", email_address="priya.sharma@corp.example.com", resource_url="/reports/q1",
     event_timestamp="09/Apr/2026:16:20:00 +0530", tool="Chrome/124.0.6367.91", ip_address="192.168.10.45",
     latitude='19°04\'33.6"N', longitude='72°52\'39.7"E', action_phrase="was granted access to",
     status="200 OK")

case("EC-083", "F5",
     '10-04-2026 06:45;USER;isabela.santos@corp.example.com;Firefox/125.0;https://portal.corp.example.com/home;23°33\'01.8"S;46°37\'59.9"W;198.51.100.203;Login successful;SUCCESS',
     outcome="SUCCESS", tags="coordinates_dms;coordinates_hemisphere_letters;ambiguous_day_month_order",
     notes="DMS of -23.5505, -46.6333.",
     entity_type="USER", email_address="isabela.santos@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="10-04-2026 06:45",
     tool="Firefox/125.0", ip_address="198.51.100.203", latitude='23°33\'01.8"S', longitude='46°37\'59.9"W',
     action_phrase="Login successful", status="SUCCESS")

case("EC-084", "F1",
     '2026-04-11T07:00:00Z | entity=USER | email=rahul.kulkarni@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Chrome/124.0.6367.91 | ip=192.168.10.46 | lat=18° 31′ 13.4″ N | lon=73° 51′ 24.1″ E | status=SUCCESS',
     outcome="SUCCESS", tags="coordinates_dms;coordinates_dms_unicode_primes",
     notes="DMS of 18.5204, 73.8567 written with Unicode prime/double-prime and spaces.",
     entity_type="USER", email_address="rahul.kulkarni@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-04-11T07:00:00Z",
     tool="Chrome/124.0.6367.91", ip_address="192.168.10.46", latitude="18° 31′ 13.4″ N",
     longitude="73° 51′ 24.1″ E", action_phrase="Access granted", status="SUCCESS")

case("EC-085", "F4",
     '198.51.100.23:51544 - - [2026-04-12 09:22:17.482] "GET /api/v2/orders/88213?expand=items HTTP/1.1" 200 2048 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" user=<anita.desai@shop.example.org> type=Customer loc=POINT(-43.1729 -22.9068) msg="Login successful"',
     outcome="SUCCESS", tags="coordinates_wkt_lon_lat_order;ip_with_port;user_agent_full",
     secondary="client_port=51544",
     notes="WKT POINT is (longitude latitude).",
     entity_type="Customer", email_address="anita.desai@shop.example.org",
     resource_url="/api/v2/orders/88213?expand=items", event_timestamp="2026-04-12 09:22:17.482",
     tool="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
     ip_address="198.51.100.23", latitude="-22.9068", longitude="-43.1729",
     action_phrase="Login successful", status="200")

case("EC-086", "F3",
     'Apr 13 18:18:18 geo02 locator[301]: {"entity_type":"user","user":"kenji-tanaka99@eu.corp.example.com","resource":"https://portal.corp.example.com/home","tool":"Chrome/124.0.6367.91","src_ip":"192.0.2.18","geometry":{"type":"Point","coordinates":[139.6503,35.6762]},"msg":"access granted","result":"SUCCESS"}',
     outcome="SUCCESS", tags="coordinates_geojson_lon_lat_order;timestamp_no_year",
     notes="GeoJSON coordinates are [longitude, latitude].",
     entity_type="user", email_address="kenji-tanaka99@eu.corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="Apr 13 18:18:18",
     tool="Chrome/124.0.6367.91", ip_address="192.0.2.18", latitude="35.6762", longitude="139.6503",
     action_phrase="access granted", status="SUCCESS")

case("EC-087", "F1",
     '2026-04-14T05:05:05Z | entity=USER | email=chen.li@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Chrome/124.0.6367.91 | ip=192.0.2.66 | lat=151.2093 | lon=-33.8688 | status=SUCCESS',
     outcome="SUCCESS", tags="coordinates_swapped;coordinates_out_of_range",
     notes="Values appear swapped (Sydney is -33.8688, 151.2093); the lat value is out of range.",
     entity_type="USER", email_address="chen.li@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-04-14T05:05:05Z",
     tool="Chrome/124.0.6367.91", ip_address="192.0.2.66", latitude=bad("151.2093"), longitude="-33.8688",
     action_phrase="Access granted", status="SUCCESS")

case("EC-088", "F2",
     '[15/Apr/2026:11:00:00 +0100] User daniel.wilson@example.co.uk was granted access to /wiki/Policies via Edge/124.0.2478.67 from 198.51.100.77 [N51.5074 W0.1278] - 200 OK',
     outcome="SUCCESS", tags="coordinates_hemisphere_prefix",
     entity_type="User", email_address="daniel.wilson@example.co.uk", resource_url="/wiki/Policies",
     event_timestamp="15/Apr/2026:11:00:00 +0100", tool="Edge/124.0.2478.67", ip_address="198.51.100.77",
     latitude="N51.5074", longitude="W0.1278", action_phrase="was granted access to", status="200 OK")

case("EC-089", "F1",
     '2026-04-16T19:45:12Z | entity=CUSTOMER | email=amara.okafor@shop.example.org | action="Access granted" | resource=https://shop.example.org/cart | tool=Chrome/124.0.6367.91 | ip=203.0.113.71 | lat=6.5243793 | lon=3.38 | status=SUCCESS',
     outcome="SUCCESS", tags="coordinates_mixed_precision",
     entity_type="CUSTOMER", email_address="amara.okafor@shop.example.org",
     resource_url="https://shop.example.org/cart", event_timestamp="2026-04-16T19:45:12Z",
     tool="Chrome/124.0.6367.91", ip_address="203.0.113.71", latitude="6.5243793", longitude="3.38",
     action_phrase="Access granted", status="SUCCESS")

case("EC-090", "F5",
     '17-04-2026 08:00;USER;grace.andersen@corp.example.com;Safari/17.4.1;https://portal.corp.example.com/home;-33.8688 S;151.2093 E;203.0.113.144;Access granted;SUCCESS',
     outcome="SUCCESS", tags="coordinates_sign_hemisphere_conflict",
     notes="A negative sign combined with 'S' is contradictory.",
     entity_type="USER", email_address="grace.andersen@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="17-04-2026 08:00",
     tool="Safari/17.4.1", ip_address="203.0.113.144", latitude=bad("-33.8688 S"), longitude="151.2093 E",
     action_phrase="Access granted", status="SUCCESS")

# --------------------------------------------------------------------------- #
# IP Address (EC-091 .. EC-106)
# --------------------------------------------------------------------------- #
_IP_BASE = ' | entity=USER | email=rohan.desai@corp.example.com | action="Login failed" | resource=https://portal.corp.example.com/login | tool=Chrome/124.0.6367.91 | ip='
_IP_FIELDS = dict(entity_type="USER", email_address="rohan.desai@corp.example.com",
                  resource_url="https://portal.corp.example.com/login", tool="Chrome/124.0.6367.91",
                  action_phrase="Login failed", status="FAILED")

case("EC-091", "F1", '2026-04-18T10:00:00Z' + _IP_BASE + '256.10.1.300 | status=FAILED',
     outcome="DECLINED", tags="ip_octet_out_of_range",
     event_timestamp="2026-04-18T10:00:00Z", ip_address=bad("256.10.1.300"), **_IP_FIELDS)

case("EC-092", "F1", '2026-04-18T10:01:00Z' + _IP_BASE + '192.168.1 | status=FAILED',
     outcome="DECLINED", tags="ip_too_few_octets",
     event_timestamp="2026-04-18T10:01:00Z", ip_address=bad("192.168.1"), **_IP_FIELDS)

case("EC-093", "F2",
     '[18/Apr/2026:10:02:00 +0000] User rohan.desai@corp.example.com failed to authenticate to /login via Chrome/124.0.6367.91 from 1.2.3.4.5 - 401 Unauthorized',
     outcome="DECLINED", tags="ip_too_many_octets",
     notes="Contains the valid-looking substring 1.2.3.4.",
     entity_type="User", email_address="rohan.desai@corp.example.com", resource_url="/login",
     event_timestamp="18/Apr/2026:10:02:00 +0000", tool="Chrome/124.0.6367.91", ip_address=bad("1.2.3.4.5"),
     action_phrase="failed to authenticate to", status="401 Unauthorized")

case("EC-094", "F1",
     '2026-04-19T09:00:00Z | entity=USER | email=zara.patel@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Firefox/125.0 | ip=192.168.001.010 | status=SUCCESS',
     outcome="SUCCESS", tags="ip_leading_zeros",
     notes="Rejected by strict parsers; some legacy parsers read leading-zero octets as octal.",
     entity_type="USER", email_address="zara.patel@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-04-19T09:00:00Z",
     tool="Firefox/125.0", ip_address=bad("192.168.001.010"), action_phrase="Access granted", status="SUCCESS")

case("EC-095", "F2",
     '[19/Apr/2026:09:30:00 +0000] User zara.patel@corp.example.com logged in to /home via Firefox/125.0 from 192.168.40.8:52814 - 302 Found',
     outcome="SUCCESS", tags="ip_with_port",
     secondary="client_port=52814",
     entity_type="User", email_address="zara.patel@corp.example.com", resource_url="/home",
     event_timestamp="19/Apr/2026:09:30:00 +0000", tool="Firefox/125.0", ip_address="192.168.40.8",
     action_phrase="logged in to", status="302 Found")

case("EC-096", "F1",
     '2026-04-20T13:00:00Z | entity=API_CLIENT | email=api-client-0042@partners.example.net | action="Access granted" | resource=https://api.example.com/v2/invoices | tool=python-requests/2.31.0 | ip=2001:0db8:0000:0000:0000:ff00:0042:8329 | status=SUCCESS',
     outcome="SUCCESS", tags="ipv6_full",
     entity_type="API_CLIENT", email_address="api-client-0042@partners.example.net",
     resource_url="https://api.example.com/v2/invoices", event_timestamp="2026-04-20T13:00:00Z",
     tool="python-requests/2.31.0", ip_address="2001:0db8:0000:0000:0000:ff00:0042:8329",
     action_phrase="Access granted", status="SUCCESS")

case("EC-097", "F4",
     '[2001:db8::1]:443 - - [2026-04-20 13:05:00.000] "GET /api/v2/invoices/99812 HTTP/1.1" 200 734 "-" "okhttp/4.12.0" user=<integration.lumen@partners.example.net> type=API_CLIENT msg="Access granted"',
     outcome="SUCCESS", tags="ipv6_with_port;ipv6_compressed",
     secondary="client_port=443",
     notes="Both the IPv6 address and the timestamp are wrapped in square brackets.",
     entity_type="API_CLIENT", email_address="integration.lumen@partners.example.net",
     resource_url="/api/v2/invoices/99812", event_timestamp="2026-04-20 13:05:00.000", tool="okhttp/4.12.0",
     ip_address="2001:db8::1", action_phrase="Access granted", status="200")

case("EC-098", "F1",
     '2026-04-21T00:00:00Z | entity=BOT | action="Request allowed" | resource=http://localhost:9090/metrics | tool=Prometheus/2.51.1 | ip=::1 | status=200',
     outcome="SUCCESS", tags="ipv6_loopback;email_absent",
     entity_type="BOT", resource_url="http://localhost:9090/metrics", event_timestamp="2026-04-21T00:00:00Z",
     tool="Prometheus/2.51.1", ip_address="::1", action_phrase="Request allowed", status="200")

case("EC-099", "F3",
     'Apr 21 06:30:00 lb01 haproxy[2020]: {"entity":"user","user":"mateo.rossi@corp.example.com","resource":"https://portal.corp.example.com/home","tool":"Firefox/125.0","remote_addr":"::ffff:192.0.2.10","msg":"access granted","status":"OK"}',
     outcome="SUCCESS", tags="ipv6_ipv4_mapped;timestamp_no_year",
     entity_type="user", email_address="mateo.rossi@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="Apr 21 06:30:00",
     tool="Firefox/125.0", ip_address="::ffff:192.0.2.10", action_phrase="access granted", status="OK")

case("EC-100", "F1",
     '2026-04-22T08:00:00Z | entity=SERVICE_ACCOUNT | email=svc-monitoring@infra.example.internal | action="Access granted" | resource=http://[fe80::1ff:fe23:4567:890a]:8080/status | tool=curl/8.4.0 | ip=fe80::1ff:fe23:4567:890a%eth0 | status=SUCCESS',
     outcome="SUCCESS", tags="ipv6_zone_id;ipv6_link_local;ip_in_resource",
     secondary="ip_like_in_resource=fe80::1ff:fe23:4567:890a",
     notes="Link-local address with an interface zone id (%eth0).",
     entity_type="SERVICE_ACCOUNT", email_address="svc-monitoring@infra.example.internal",
     resource_url="http://[fe80::1ff:fe23:4567:890a]:8080/status", event_timestamp="2026-04-22T08:00:00Z",
     tool="curl/8.4.0", ip_address="fe80::1ff:fe23:4567:890a%eth0", action_phrase="Access granted",
     status="SUCCESS")

_V6_BASE = ' | entity=SERVICE_ACCOUNT | email=svc-monitoring@infra.example.internal | action="Access denied" | resource=https://vault.corp.example.com/secrets/prod | tool=curl/8.4.0 | ip='
_V6_FIELDS = dict(entity_type="SERVICE_ACCOUNT", email_address="svc-monitoring@infra.example.internal",
                  resource_url="https://vault.corp.example.com/secrets/prod", tool="curl/8.4.0",
                  action_phrase="Access denied", status="DENIED")

case("EC-101", "F1", '2026-04-22T08:05:00Z' + _V6_BASE + '2001:db8::85a3::7334 | status=DENIED',
     outcome="DECLINED", tags="ipv6_invalid_double_compression",
     event_timestamp="2026-04-22T08:05:00Z", ip_address=bad("2001:db8::85a3::7334"), **_V6_FIELDS)

case("EC-102", "F1", '2026-04-22T08:06:00Z' + _V6_BASE + '2001:db8:gggg::1 | status=DENIED',
     outcome="DECLINED", tags="ipv6_invalid_hex",
     event_timestamp="2026-04-22T08:06:00Z", ip_address=bad("2001:db8:gggg::1"), **_V6_FIELDS)

case("EC-103", "F4",
     '10.0.0.1 - - [23/Apr/2026:17:00:00 +0000] "GET /account HTTP/1.1" 200 5120 "-" "Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0" xff="203.0.113.5, 10.0.0.1" user=<ethan.murphy@corp.example.com> type=User msg="Access granted"',
     outcome="SUCCESS", tags="multiple_ips;x_forwarded_for_chain;user_agent_full",
     secondary="proxy_ip=10.0.0.1",
     notes="Original client is the first X-Forwarded-For entry; the leading address is the load balancer.",
     entity_type="User", email_address="ethan.murphy@corp.example.com", resource_url="/account",
     event_timestamp="23/Apr/2026:17:00:00 +0000",
     tool="Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0",
     ip_address="203.0.113.5", action_phrase="Access granted", status="200")

case("EC-104", "F1",
     '2026-04-24T12:00:00Z | entity=USER | email=ingrid.andersen@example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Firefox/125.0 | lat=64.1466 | lon=-21.9426 | status=SUCCESS',
     outcome="SUCCESS", tags="ip_absent",
     entity_type="USER", email_address="ingrid.andersen@example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-04-24T12:00:00Z",
     tool="Firefox/125.0", latitude="64.1466", longitude="-21.9426", action_phrase="Access granted",
     status="SUCCESS")

case("EC-105", "F5",
     '24-04-2026 12:30;USER;ingrid.andersen@example.com;Firefox/125.0;https://portal.corp.example.com/home;64.1466;-21.9426;-;Logout;OK',
     outcome="NEUTRAL", tags="ip_placeholder",
     entity_type="USER", email_address="ingrid.andersen@example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="24-04-2026 12:30",
     tool="Firefox/125.0", latitude="64.1466", longitude="-21.9426", ip_address=ph("-"),
     action_phrase="Logout", status="OK")

case("EC-106", "F1",
     '2026-04-25T01:00:00Z | entity=SERVICE_ACCOUNT | email=ci-runner-07@build.example.internal | action="Access granted" | resource=https://artifacts.example.internal/releases/4.10.2.1/app-4.10.2.1.zip | tool=Wget/1.21.4 | ip=10.250.3.7 | status=SUCCESS',
     outcome="SUCCESS", tags="ip_like_in_resource",
     secondary="ip_like_in_resource=4.10.2.1",
     notes="An IP-looking version number appears in the resource before the real IP.",
     entity_type="SERVICE_ACCOUNT", email_address="ci-runner-07@build.example.internal",
     resource_url="https://artifacts.example.internal/releases/4.10.2.1/app-4.10.2.1.zip",
     event_timestamp="2026-04-25T01:00:00Z", tool="Wget/1.21.4", ip_address="10.250.3.7",
     action_phrase="Access granted", status="SUCCESS")

# --------------------------------------------------------------------------- #
# Action / Access Phrase (EC-107 .. EC-118)
# --------------------------------------------------------------------------- #
case("EC-107", "F2",
     '[26/Apr/2026:10:00:00 +0000] User wei.zhang@corp.example.com was not granted access to /finance/ledger via Chrome/124.0.6367.91 from 192.168.40.10 - 403 Forbidden',
     outcome="DECLINED", tags="action_negation",
     notes="Contains the word 'granted' but the outcome is declined.",
     entity_type="User", email_address="wei.zhang@corp.example.com", resource_url="/finance/ledger",
     event_timestamp="26/Apr/2026:10:00:00 +0000", tool="Chrome/124.0.6367.91", ip_address="192.168.40.10",
     action_phrase="was not granted access to", status="403 Forbidden")

case("EC-108", "F1",
     '2026-04-26T10:05:00Z | entity=USER | email=wei.zhang@corp.example.com | action="Access was not denied" | resource=/finance/summary | tool=Chrome/124.0.6367.91 | ip=192.168.40.10 | status=SUCCESS',
     outcome="SUCCESS", tags="action_double_negation",
     notes="Contains the word 'denied' but the outcome is success.",
     entity_type="USER", email_address="wei.zhang@corp.example.com", resource_url="/finance/summary",
     event_timestamp="2026-04-26T10:05:00Z", tool="Chrome/124.0.6367.91", ip_address="192.168.40.10",
     action_phrase="Access was not denied", status="SUCCESS")

case("EC-109", "F1",
     '2026-04-27T08:15:00Z | entity=USER | email=nadia.haddad@corp.example.com | action="Access granted after 2 failed attempts" | resource=https://vault.corp.example.com/secrets/dev | tool=Firefox/125.0 | ip=192.168.50.9 | status=SUCCESS',
     outcome="SUCCESS", tags="action_mixed_outcome_wording",
     entity_type="USER", email_address="nadia.haddad@corp.example.com",
     resource_url="https://vault.corp.example.com/secrets/dev", event_timestamp="2026-04-27T08:15:00Z",
     tool="Firefox/125.0", ip_address="192.168.50.9", action_phrase="Access granted after 2 failed attempts",
     status="SUCCESS")

case("EC-110", "F2",
     '[28/Apr/2026:14:00:00 +0000] Admin omar.haddad@corp.example.com was granted access to /reports/access-denied-summary via Chrome/124.0.6367.91 from 192.0.2.77 - 200 OK',
     outcome="SUCCESS", tags="outcome_keyword_in_resource",
     secondary="keyword_in_resource=denied",
     entity_type="Admin", email_address="omar.haddad@corp.example.com",
     resource_url="/reports/access-denied-summary", event_timestamp="28/Apr/2026:14:00:00 +0000",
     tool="Chrome/124.0.6367.91", ip_address="192.0.2.77", action_phrase="was granted access to",
     status="200 OK")

case("EC-111", "F1",
     '2026-04-29T21:00:00Z | entity=GUEST | email=guest_9012@example.com | action="AcCeSs DeNiEd" | resource=https://portal.corp.example.com/private | tool=curl/8.4.0 | ip=203.0.113.212 | status=denied',
     outcome="DECLINED", tags="action_mixed_case;status_lowercase",
     entity_type="GUEST", email_address="guest_9012@example.com",
     resource_url="https://portal.corp.example.com/private", event_timestamp="2026-04-29T21:00:00Z",
     tool="curl/8.4.0", ip_address="203.0.113.212", action_phrase="AcCeSs DeNiEd", status="denied")

case("EC-112", "F5",
     '30-04-2026 07:30;CUSTOMER;olivia.brown@shop.example.org;Chrome/124.0.6367.91;https://shop.example.org/admin;40.7128;-74.0060;198.51.100.9;Access declined;DECLINED',
     outcome="DECLINED", tags="action_declined_wording",
     entity_type="CUSTOMER", email_address="olivia.brown@shop.example.org",
     resource_url="https://shop.example.org/admin", event_timestamp="30-04-2026 07:30",
     tool="Chrome/124.0.6367.91", ip_address="198.51.100.9", latitude="40.7128", longitude="-74.0060",
     action_phrase="Access declined", status="DECLINED")

case("EC-113", "F3",
     'May  1 02:02:02 fw01 guard[66]: {"level":"warn","entity_type":"guest","user":"visitor.2291@guest.example.org","resource":"https://portal.corp.example.com/admin","tool":"Wget/1.21.4","src_ip":"203.0.113.201","msg":"unauthorized attempt","result":"BLOCKED"}',
     outcome="DECLINED", tags="action_unauthorized_wording;syslog_space_padded_day;timestamp_no_year",
     entity_type="guest", email_address="visitor.2291@guest.example.org",
     resource_url="https://portal.corp.example.com/admin", event_timestamp="May  1 02:02:02",
     tool="Wget/1.21.4", ip_address="203.0.113.201", action_phrase="unauthorized attempt", status="BLOCKED")

case("EC-114", "F1",
     '2026-05-02T10:00:00Z | entity=USER | email=kavya.iyer@corp.example.com | resource=https://portal.corp.example.com/dashboard | tool=Firefox/125.0 | ip=192.168.4.21 | status=SUCCESS',
     tags="action_absent",
     entity_type="USER", email_address="kavya.iyer@corp.example.com",
     resource_url="https://portal.corp.example.com/dashboard", event_timestamp="2026-05-02T10:00:00Z",
     tool="Firefox/125.0", ip_address="192.168.4.21", status="SUCCESS")

case("EC-115", "F4",
     '192.0.2.61 - grace.andersen@corp.example.com [03/May/2026:09:00:00 +0000] "POST /sso/mfa/verify HTTP/1.1" 401 64 "https://sso.example.com/login" "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15" type=USER msg="MFA challenge"',
     outcome="NEUTRAL", tags="action_neutral;referer_url_present;email_in_remote_user_slot;user_agent_full",
     secondary="referer_url=https://sso.example.com/login",
     entity_type="USER", email_address="grace.andersen@corp.example.com", resource_url="/sso/mfa/verify",
     event_timestamp="03/May/2026:09:00:00 +0000",
     tool="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
     ip_address="192.0.2.61", action_phrase="MFA challenge", status="401")

case("EC-116", "F2",
     '[04/May/2026:12:00:00 +0000] API Client api-client-0042@partners.example.net was rate limited on /api/v2/search via python-requests/2.31.0 from 198.51.100.52 - 429 Too Many Requests',
     outcome="NEUTRAL", tags="action_neutral;entity_multi_word",
     entity_type="API Client", email_address="api-client-0042@partners.example.net",
     resource_url="/api/v2/search", event_timestamp="04/May/2026:12:00:00 +0000",
     tool="python-requests/2.31.0", ip_address="198.51.100.52", action_phrase="was rate limited on",
     status="429 Too Many Requests")

case("EC-117", "F1",
     '2026-05-05T08:00:00Z | entity=USER | email=sofia.garcia@mail.example.org | action="Access denied" | retry_action="Access granted" | resource=https://mail.example.org/admin | tool=Safari/17.4.1 | ip=192.0.2.44 | status=DENIED',
     outcome="DECLINED", tags="multiple_action_phrases",
     secondary="retry_action=Access granted",
     entity_type="USER", email_address="sofia.garcia@mail.example.org",
     resource_url="https://mail.example.org/admin", event_timestamp="2026-05-05T08:00:00Z",
     tool="Safari/17.4.1", ip_address="192.0.2.44", action_phrase="Access denied", status="DENIED")

case("EC-118", "F5",
     '05-05-2026 23:59:59;USER;noah.wilson@corp.example.com;Chrome/124.0.6367.91;https://portal.corp.example.com/home;40.7128;-74.0060;192.168.10.101;Token expired;EXPIRED',
     outcome="NEUTRAL", tags="action_neutral",
     entity_type="USER", email_address="noah.wilson@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="05-05-2026 23:59:59",
     tool="Chrome/124.0.6367.91", ip_address="192.168.10.101", latitude="40.7128", longitude="-74.0060",
     action_phrase="Token expired", status="EXPIRED")

# --------------------------------------------------------------------------- #
# Status (EC-119 .. EC-128)
# --------------------------------------------------------------------------- #
case("EC-119", "F2",
     '[06/May/2026:10:00:00 +0000] User liam.smith@corp.example.com was granted access to /finance/ledger via Chrome/124.0.6367.91 from 192.168.70.5 - 403 Forbidden',
     outcome="SUCCESS", tags="status_action_conflict",
     notes="Phrase says granted while status is 403.",
     entity_type="User", email_address="liam.smith@corp.example.com", resource_url="/finance/ledger",
     event_timestamp="06/May/2026:10:00:00 +0000", tool="Chrome/124.0.6367.91", ip_address="192.168.70.5",
     action_phrase="was granted access to", status="403 Forbidden")

case("EC-120", "F1",
     '2026-05-06T10:05:00Z | entity=USER | email=liam.smith@corp.example.com | action="Access denied" | resource=/finance/ledger | tool=Chrome/124.0.6367.91 | ip=192.168.70.5 | status=SUCCESS',
     outcome="DECLINED", tags="status_action_conflict",
     notes="Phrase says denied while status is SUCCESS.",
     entity_type="USER", email_address="liam.smith@corp.example.com", resource_url="/finance/ledger",
     event_timestamp="2026-05-06T10:05:00Z", tool="Chrome/124.0.6367.91", ip_address="192.168.70.5",
     action_phrase="Access denied", status="SUCCESS")

case("EC-121", "F1",
     '2026-05-07T07:07:07Z | entity=USER | email=emma.brown@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Safari/17.4.1 | ip=192.0.2.12',
     outcome="SUCCESS", tags="status_absent",
     entity_type="USER", email_address="emma.brown@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-05-07T07:07:07Z",
     tool="Safari/17.4.1", ip_address="192.0.2.12", action_phrase="Access granted")

case("EC-122", "F1",
     '2026-05-07T07:08:00Z | entity=USER | email=emma.brown@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Safari/17.4.1 | ip=192.0.2.12 | status=',
     outcome="SUCCESS", tags="status_empty_value",
     entity_type="USER", email_address="emma.brown@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-05-07T07:08:00Z",
     tool="Safari/17.4.1", ip_address="192.0.2.12", action_phrase="Access granted")

case("EC-123", "F1",
     '2026-05-08T12:00:00Z | entity=USER | email=kwame.mensah@corp.example.com | action="Login successful" | resource=https://portal.corp.example.com/home | tool=Chrome/124.0.6367.91 | ip=203.0.113.140 | status=✓',
     outcome="SUCCESS", tags="status_symbol",
     notes="Status is the Unicode check mark U+2713.",
     entity_type="USER", email_address="kwame.mensah@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-05-08T12:00:00Z",
     tool="Chrome/124.0.6367.91", ip_address="203.0.113.140", action_phrase="Login successful", status="✓")

case("EC-124", "F1",
     '2026-05-08T12:01:00Z | entity=USER | email=kwame.mensah@corp.example.com | action="Login successful" | resource=https://portal.corp.example.com/home | tool=Chrome/124.0.6367.91 | ip=203.0.113.140 | status=SUCCES',
     outcome="SUCCESS", tags="status_typo",
     entity_type="USER", email_address="kwame.mensah@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-05-08T12:01:00Z",
     tool="Chrome/124.0.6367.91", ip_address="203.0.113.140", action_phrase="Login successful",
     status=bad("SUCCES"))

case("EC-125", "F4",
     '203.0.113.140 - - [09/May/2026:15:00:00 +0000] "GET /home HTTP/1.1" 999 0 "-" "curl/8.4.0" msg="Access granted"',
     outcome="SUCCESS", tags="status_invalid_http_code;email_placeholder;entity_absent",
     email_address=ph("-"), resource_url="/home", event_timestamp="09/May/2026:15:00:00 +0000",
     tool="curl/8.4.0", ip_address="203.0.113.140", action_phrase="Access granted", status=bad("999"))

case("EC-126", "F4",
     '203.0.113.141 - - [09/May/2026:15:00:05 +0000] "GET /home HTTP/1.1" 20O 0 "-" "curl/8.4.0" msg="Access granted"',
     outcome="SUCCESS", tags="status_letter_o_in_code;email_placeholder;entity_absent",
     notes="Third character is the letter O, not zero.",
     email_address=ph("-"), resource_url="/home", event_timestamp="09/May/2026:15:00:05 +0000",
     tool="curl/8.4.0", ip_address="203.0.113.141", action_phrase="Access granted", status=bad("20O"))

case("EC-127", "F1",
     '2026-05-10T09:00:00Z | entity=ADMIN | email=vikram.rao@corp.example.com | action="Request blocked by policy" | resource=https://admin.corp.example.com/iam/roles | tool=Edge/124.0.2478.67 | ip=192.168.30.12 | outcome=BLOCKED (policy: geo-fence) | lat=64.1466 | lon=-21.9426',
     outcome="DECLINED", tags="status_key_outcome;status_with_reason;field_order_varied",
     secondary="status_reason=policy: geo-fence",
     entity_type="ADMIN", email_address="vikram.rao@corp.example.com",
     resource_url="https://admin.corp.example.com/iam/roles", event_timestamp="2026-05-10T09:00:00Z",
     tool="Edge/124.0.2478.67", ip_address="192.168.30.12", latitude="64.1466", longitude="-21.9426",
     action_phrase="Request blocked by policy", status="BLOCKED")

case("EC-128", "F3",
     'May 11 04:04:04 sso01 authd[882]: {"entity_type":"user","user":"arjun.menon@corp.example.com","resource":"https://sso.example.com/login","tool":"Chrome/124.0.6367.91","src_ip":"192.168.20.14","msg":"authentication failed","status":401,"result":"FAILED"}',
     outcome="DECLINED", tags="multiple_status_values;status_numeric_json;timestamp_no_year",
     secondary="result=FAILED",
     notes="Two status tokens; the answer key uses the first one.",
     entity_type="user", email_address="arjun.menon@corp.example.com",
     resource_url="https://sso.example.com/login", event_timestamp="May 11 04:04:04",
     tool="Chrome/124.0.6367.91", ip_address="192.168.20.14", action_phrase="authentication failed",
     status="401")

# --------------------------------------------------------------------------- #
# Whole-record edge cases (EC-129 .. EC-150)
# --------------------------------------------------------------------------- #
case("EC-129", "NONE", None, tags="null_record", broken=True,
     notes="SQL NULL (unquoted empty value in the CSV).")

case("EC-130", "NONE", "NULL", tags="literal_null_text", broken=True,
     notes="The four characters N-U-L-L, not SQL NULL.")

case("EC-131", "NONE", "", tags="empty_string", broken=True,
     notes='Empty string (quoted "" in the CSV), not SQL NULL.')

case("EC-132", "NONE", "     ", tags="whitespace_only", broken=True)

case("EC-133", "NONE", "\t \r\n", tags="whitespace_only;control_characters", broken=True)

case("EC-134", "F1",
     '2026-05-12T08:00:00Z | entity=USER | email=meera.nair@corp.exa',
     tags="truncated", broken=True,
     notes="Line cut off inside the email value.",
     entity_type="USER", event_timestamp="2026-05-12T08:00:00Z",
     email_address=bad("meera.nair@corp.exa"))

case("EC-135", "F3",
     'May 12 08:00:01 sso01 authd[882]: {"entity_type":"user","user":"meera.nair@corp.example.com","resource":"https://sso.exam',
     tags="truncated;timestamp_no_year", broken=True,
     notes="JSON payload cut off inside the resource value.",
     entity_type="user", email_address="meera.nair@corp.example.com", event_timestamp="May 12 08:00:01",
     resource_url=bad("https://sso.exam"))

case("EC-136", "F4",
     '198.51.100.23 - - [12/May/2026:08:00:02 +0000] "GET /reports/q2 HTTP/1.1" 200 1532 "-" "Mozilla/5.0 (Windows NT 10.0; Win',
     tags="truncated;email_placeholder", broken=True,
     notes="Line cut off inside the user agent.",
     email_address=ph("-"), resource_url="/reports/q2", event_timestamp="12/May/2026:08:00:02 +0000",
     tool=bad("Mozilla/5.0 (Windows NT 10.0; Win"), ip_address="198.51.100.23", status="200")

case("EC-137", "NONE",
     'timestamp | entity | email | action | resource | tool | ip | lat | lon | status',
     tags="header_row", broken=True, notes="Pipe-format header line ingested as data.")

case("EC-138", "NONE",
     'TIMESTAMP;ENTITY_TYPE;EMAIL;TOOL;RESOURCE;LATITUDE;LONGITUDE;IP_ADDRESS;ACTION;STATUS',
     tags="header_row", broken=True, notes="Semicolon-format header line ingested as data.")

case("EC-139", "NONE", "##########", tags="junk", broken=True)

case("EC-140", "NONE",
     "\x1b[31mERROR\x1b[0m Ã¢â‚¬â„¢ �� ÿþ ~~~ \x07",
     tags="junk;mojibake;control_characters", broken=True,
     notes="ANSI escape codes, mojibake, replacement characters and a BEL control char. No NUL bytes "
           "(PostgreSQL TEXT cannot store 0x00).")

# EC-141 and EC-142 are exact duplicates; they are filled in from their source cases below.
case("EC-141", "F1", "__DUPLICATE_OF__EC-001", tags="exact_duplicate", notes="Exact duplicate of EC-001.")
case("EC-142", "F4", "__DUPLICATE_OF__EC-085", tags="exact_duplicate", notes="Exact duplicate of EC-085.")

case("EC-143", "F1",
     '2026-05-13T11:05:44Z | entity=SERVICE_ACCOUNT | email=svc-etl@infra.example.internal | action="Access denied" | resource=db://prod/customers | tool=python-requests/2.31.0 | ip=10.40.3.8 | status=FAILED\n'
     'Traceback (most recent call last):\n'
     '  File "/opt/etl/load.py", line 88, in <module>\n'
     "PermissionError: [Errno 13] Permission denied: '/var/log/secure'",
     outcome="DECLINED", tags="multiline;stack_trace;multiple_action_phrases",
     secondary="phrase_in_trace=Permission denied;path_in_trace=/var/log/secure",
     notes="Answer key uses the first line; the stack trace repeats a denial phrase and another path.",
     entity_type="SERVICE_ACCOUNT", email_address="svc-etl@infra.example.internal",
     resource_url="db://prod/customers", event_timestamp="2026-05-13T11:05:44Z",
     tool="python-requests/2.31.0", ip_address="10.40.3.8", action_phrase="Access denied", status="FAILED")

case("EC-144", "F3",
     'May 14 06:00:00 api-gw02 gatekeeper[3310]: {\n'
     '  "entity": "api_client",\n'
     '  "principal": "integration.bluefin@partners.example.net",\n'
     '  "resource": "https://api.example.com/v2/invoices/INV-2026-0042",\n'
     '  "tool": "okhttp/4.12.0",\n'
     '  "src_ip": "198.51.100.61",\n'
     '  "geo": {"lat": 51.5074, "lng": -0.1278},\n'
     '  "msg": "access denied",\n'
     '  "result": "DENIED"\n'
     '}',
     outcome="DECLINED", tags="multiline;json_pretty_printed;timestamp_no_year",
     entity_type="api_client", email_address="integration.bluefin@partners.example.net",
     resource_url="https://api.example.com/v2/invoices/INV-2026-0042", event_timestamp="May 14 06:00:00",
     tool="okhttp/4.12.0", ip_address="198.51.100.61", latitude="51.5074", longitude="-0.1278",
     action_phrase="access denied", status="DENIED")

_LONG_RESOURCE = "/search?" + "&".join(f"f{i:03d}=value{i:03d}" for i in range(150))
case("EC-145", "F4",
     '198.51.100.88 - - [15/May/2026:10:10:10 +0000] "GET ' + _LONG_RESOURCE
     + ' HTTP/1.1" 200 90211 "-" "python-requests/2.31.0" user=<api-client-0042@partners.example.net> type=API_CLIENT msg="Access granted"',
     outcome="SUCCESS", tags="long_line",
     notes="Line longer than 2 KB because of a 150-parameter query string.",
     entity_type="API_CLIENT", email_address="api-client-0042@partners.example.net",
     resource_url=_LONG_RESOURCE, event_timestamp="15/May/2026:10:10:10 +0000",
     tool="python-requests/2.31.0", ip_address="198.51.100.88", action_phrase="Access granted", status="200")

case("EC-146", "F1",
     '2026-05-16T09:00:00Z\tentity=USER\temail=sneha.joshi@corp.example.com\taction="Access granted"\tresource=https://portal.corp.example.com/home\ttool=Chrome/124.0.6367.91\tip=192.168.30.15\tlat=18.5204\tlon=73.8567\tstatus=SUCCESS',
     outcome="SUCCESS", tags="tab_delimited",
     entity_type="USER", email_address="sneha.joshi@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-05-16T09:00:00Z",
     tool="Chrome/124.0.6367.91", ip_address="192.168.30.15", latitude="18.5204", longitude="73.8567",
     action_phrase="Access granted", status="SUCCESS")

case("EC-147", "F1",
     '\u00a0|\u00a0'.join([
         '2026-05-17T09:00:00Z',
         'entity=USER',
         'email=kavya.iyer@corp.example.com',
         'action="Access granted"',
         'resource=https://portal.corp.example.com/home',
         'tool=Firefox/125.0',
         'ip=192.168.4.21',
         'status=SUCCESS',
     ]),
     outcome="SUCCESS", tags="non_breaking_spaces",
     notes="Delimiters are surrounded by U+00A0 non-breaking spaces.",
     entity_type="USER", email_address="kavya.iyer@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-05-17T09:00:00Z",
     tool="Firefox/125.0", ip_address="192.168.4.21", action_phrase="Access granted", status="SUCCESS")

case("EC-148", "F1",
     '2026-05-18T09:00:00Z | entity=USER | email=rohan.desai@corp.example.com | action="Access granted" | resource=https://portal.corp.example.com/home | tool=Chrome/124.0.6367.91 | ip=203.0.113.37 | status=SUCCESS\r\n',
     outcome="SUCCESS", tags="crlf_line_ending",
     notes="RAW LOG ends with CR LF; the status value does not include them.",
     entity_type="USER", email_address="rohan.desai@corp.example.com",
     resource_url="https://portal.corp.example.com/home", event_timestamp="2026-05-18T09:00:00Z",
     tool="Chrome/124.0.6367.91", ip_address="203.0.113.37", action_phrase="Access granted", status="SUCCESS")

case("EC-149", "F2",
     '   [19/May/2026:08:00:00 +0000] User chen.li@corp.example.com logged in to /home via Chrome/124.0.6367.91 from 192.168.10.104 - 200 OK   ',
     outcome="SUCCESS", tags="leading_trailing_whitespace",
     entity_type="User", email_address="chen.li@corp.example.com", resource_url="/home",
     event_timestamp="19/May/2026:08:00:00 +0000", tool="Chrome/124.0.6367.91", ip_address="192.168.10.104",
     action_phrase="logged in to", status="200 OK")

case("EC-150", "F1",
     '2026-05-20T10:00:00Z|entity=USER|email=mateo.rossi@corp.example.com|action="Access denied | escalated to SOC"|resource=https://portal.corp.example.com/admin|tool=Firefox/125.0|ip=192.168.40.9|status=DENIED',
     outcome="DECLINED", tags="delimiter_inside_quoted_value;compact_delimiters",
     notes="The quoted action value contains the '|' delimiter.",
     entity_type="USER", email_address="mateo.rossi@corp.example.com",
     resource_url="https://portal.corp.example.com/admin", event_timestamp="2026-05-20T10:00:00Z",
     tool="Firefox/125.0", ip_address="192.168.40.9", action_phrase="Access denied | escalated to SOC",
     status="DENIED")


def _resolve_duplicates():
    by_id = {c.case_id: c for c in CASES}
    for c in CASES:
        if isinstance(c.raw_log, str) and c.raw_log.startswith("__DUPLICATE_OF__"):
            source = by_id[c.raw_log[len("__DUPLICATE_OF__"):]]
            c.raw_log = source.raw_log
            c.outcome = source.outcome
            c.format_family = source.format_family
            c.secondary = source.secondary
            c.fields = dict(source.fields)
            c.tags = ";".join(t for t in (c.tags, source.tags) if t)


_resolve_duplicates()

if len(CASES) != 150 or len({c.case_id for c in CASES}) != 150:
    raise RuntimeError(f"Expected 150 unique curated cases, found {len(CASES)}")
