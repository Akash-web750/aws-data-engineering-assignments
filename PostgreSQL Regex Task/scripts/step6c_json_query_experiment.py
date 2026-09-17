#!/usr/bin/env python3
"""Step 6C - JSON vs JSONB head-to-head query experiment (docs/Step6C_JSON_vs_JSONB_Query_Experiment.md).

Single source of the head-to-head workload of Step 6A section 4.1: 21 query IDs, 25 statements (Q11, Q12 and Q13 have
variants). Every statement is identical for both tables except the table name; Q14 also uses the equivalent array
function (json_array_elements_text / jsonb_array_elements_text). No jsonb-only operator is used.

  python scripts/step6c_json_query_experiment.py generate [--check]
      writes (or with --check: compares) sql/36_verify_json_query_results.sql and sql/37_measure_json_queries.sql
  python scripts/step6c_json_query_experiment.py analyze
      reads analysis/step6/step6c_batch1_explain.txt and analysis/step6/step6c_batch2_explain.txt and writes
      analysis/step6/step6c_executions.csv, step6c_summary.csv, step6c_comparison.csv and step6c_summary.md

Standard library only.
"""
import argparse
import csv
import json
import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLES = {"json": "log_regex_json.access_log_json", "jsonb": "log_regex_json.access_log_jsonb"}
TYPES = ("json", "jsonb")
FLAT = "log_regex.access_log_flat"
FIELDS = ["entity_type", "email_address", "resource_url", "event_timestamp", "tool",
          "latitude", "longitude", "ip_address", "action_phrase", "status"]
WARMUP_ROUNDS = 3
MEASURED_ROUNDS = 15
EXPLAIN_MEASURE = "EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY, SUMMARY, FORMAT JSON)"
EXPLAIN_DETAIL = "EXPLAIN (ANALYZE, TIMING ON, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY, SUMMARY, FORMAT JSON)"
SMALL_MEDIAN_MS = 0.1
MIN_RELATIVE_DIFFERENCE = 0.10
SQL36 = ROOT / "sql" / "36_verify_json_query_results.sql"
SQL37 = ROOT / "sql" / "37_measure_json_queries.sql"
ANALYSIS = ROOT / "analysis" / "step6"


def q06_columns():
    """Q06: all 70 leaves, cast back to the flat column types, in flat column order."""
    cols = ["(doc->>'log_id')::integer AS log_id",
            "(doc->>'run_id')::bigint AS run_id",
            "doc->'record'->>'format_family' AS format_family",
            "doc->'record'->>'detection_rule' AS detection_rule",
            "doc->'record'->>'sub_format' AS sub_format",
            "doc->'record'->>'record_validity' AS record_validity",
            "(doc->'record'->>'is_truncated')::boolean AS is_truncated",
            "(doc->'record'->>'event_end_pos')::integer AS event_end_pos",
            "(doc->'record'->>'diagnostics')::jsonb AS diagnostics"]
    oracle = ["log_id", "run_id", "format_family", "detection_rule", "sub_format", "record_validity::text",
              "is_truncated", "event_end_pos", "to_jsonb(diagnostics) AS diagnostics"]
    typed = {
        "entity_type": [("doc->'fields'->'entity_type'->>'code' AS entity_type_code", "entity_type_code")],
        "event_timestamp": [
            ("doc->'fields'->'event_timestamp'->>'shape' AS event_timestamp_shape", "event_timestamp_shape"),
            ("(doc->'fields'->'event_timestamp'->>'local')::timestamp(6) AS event_timestamp_local", "event_timestamp_local"),
            ("(doc->'fields'->'event_timestamp'->>'utc_offset_minutes')::integer * interval '1 minute' AS event_timestamp_utc_offset",
             "event_timestamp_utc_offset"),
            ("(doc->'fields'->'event_timestamp'->>'utc')::timestamptz AS event_timestamp_utc", "event_timestamp_utc")],
        "latitude": [("(doc->'fields'->'latitude'->>'degrees')::numeric AS latitude_degrees", "latitude_degrees")],
        "longitude": [("(doc->'fields'->'longitude'->>'degrees')::numeric AS longitude_degrees", "longitude_degrees")],
        "ip_address": [("(doc->'fields'->'ip_address'->>'address')::inet AS ip_address_inet", "ip_address_inet"),
                       ("doc->'fields'->'ip_address'->>'zone_id' AS ip_address_zone_id", "ip_address_zone_id")],
        "status": [("(doc->'fields'->'status'->>'code')::smallint AS status_code", "status_code"),
                   ("doc->'fields'->'status'->>'word' AS status_word", "status_word")],
    }
    for f in FIELDS:
        cols += [f"doc->'fields'->'{f}'->>'value' AS {f}",
                 f"doc->'fields'->'{f}'->>'validity' AS {f}_validity",
                 f"(doc->'fields'->'{f}'->>'start_pos')::integer AS {f}_start_pos",
                 f"doc->'fields'->'{f}'->>'source' AS {f}_source",
                 f"doc->'fields'->'{f}'->>'missing_reason' AS {f}_missing_reason"]
        oracle += [f, f"{f}_validity::text", f"{f}_start_pos", f"{f}_source", f"{f}_missing_reason::text"]
        for json_expr, flat_col in typed.get(f, []):
            cols.append(json_expr)
            oracle.append(flat_col)
    assert len(cols) == 70 and len(oracle) == 70
    return ", ".join(cols), ", ".join(oracle)


Q06_COLUMNS, Q06_ORACLE = q06_columns()
UTC = "doc->'fields'->'event_timestamp'->>'utc'"

# id, group, pattern, statement ({T} = table, {P} = json | jsonb), flat-table oracle, expected rows (None = from oracle),
# normalise (True: whole documents are compared as jsonb, because json and jsonb print documents differently)
QUERIES = [
    ("Q01", "Q01", "point lookup, whole document", "SELECT doc FROM {T} WHERE log_id = 2835", None, 1, True),
    ("Q02", "Q02", "all whole documents (output serialisation)", "SELECT doc FROM {T}", None, 5000, True),
    ("Q03", "Q03", "point lookup, one nested value",
     "SELECT doc->'fields'->'resource_url'->>'value' AS resource_url FROM {T} WHERE log_id = 2835",
     f"SELECT resource_url FROM {FLAT} WHERE log_id = 2835", 1, False),
    ("Q04", "Q04", "one nested scalar, all rows",
     "SELECT log_id, doc->'record'->>'record_validity' AS record_validity FROM {T}",
     f"SELECT log_id, record_validity::text FROM {FLAT}", 5000, False),
    ("Q05", "Q05", "ten nested scalars per row",
     "SELECT log_id, " + ", ".join(f"doc->'fields'->'{f}'->>'value' AS {f}" for f in FIELDS) + " FROM {T}",
     f"SELECT log_id, {', '.join(FIELDS)} FROM {FLAT}", 5000, False),
    ("Q06", "Q06", "all 70 leaves per row, cast back to column types",
     f"SELECT {Q06_COLUMNS} FROM {{T}}", f"SELECT {Q06_ORACLE} FROM {FLAT}", 5000, False),
    ("Q07", "Q07", "equality, very selective",
     "SELECT log_id FROM {T} WHERE doc->'record'->>'record_validity' = 'BROKEN'",
     f"SELECT log_id FROM {FLAT} WHERE record_validity = 'BROKEN'", 12, False),
    ("Q08", "Q08", "equality, medium",
     "SELECT log_id FROM {T} WHERE doc->'fields'->'entity_type'->>'code' = 'BOT'",
     f"SELECT log_id FROM {FLAT} WHERE entity_type_code = 'BOT'", 225, False),
    ("Q09", "Q09", "equality, broad",
     "SELECT log_id FROM {T} WHERE doc->'record'->>'format_family' = 'F1'",
     f"SELECT log_id FROM {FLAT} WHERE format_family = 'F1'", 1528, False),
    ("Q10", "Q10", "integer equality",
     "SELECT log_id FROM {T} WHERE (doc->'fields'->'status'->>'code')::integer = 404",
     f"SELECT log_id FROM {FLAT} WHERE status_code = 404", 30, False),
    ("Q11a", "Q11", "numeric range, medium",
     "SELECT log_id FROM {T} WHERE (doc->'fields'->'latitude'->>'degrees')::numeric BETWEEN 50 AND 55",
     f"SELECT log_id FROM {FLAT} WHERE latitude_degrees BETWEEN 50 AND 55", 422, False),
    ("Q11b", "Q11", "numeric range, broad",
     "SELECT log_id FROM {T} WHERE (doc->'fields'->'latitude'->>'degrees')::numeric BETWEEN 0 AND 60",
     f"SELECT log_id FROM {FLAT} WHERE latitude_degrees BETWEEN 0 AND 60", 3064, False),
    ("Q12a", "Q12", "time window, 1 day (string range)",
     f"SELECT log_id FROM {{T}} WHERE {UTC} >= '2026-03-01T00:00:00.000000Z' AND {UTC} < '2026-03-02T00:00:00.000000Z'",
     f"SELECT log_id FROM {FLAT} WHERE event_timestamp_utc >= '2026-03-01 00:00:00+00' AND event_timestamp_utc < '2026-03-02 00:00:00+00'",
     13, False),
    ("Q12b", "Q12", "time window, 1 week (string range)",
     f"SELECT log_id FROM {{T}} WHERE {UTC} >= '2026-03-01T00:00:00.000000Z' AND {UTC} < '2026-03-08T00:00:00.000000Z'",
     f"SELECT log_id FROM {FLAT} WHERE event_timestamp_utc >= '2026-03-01 00:00:00+00' AND event_timestamp_utc < '2026-03-08 00:00:00+00'",
     108, False),
    ("Q12c", "Q12", "time window, 1 month (string range)",
     f"SELECT log_id FROM {{T}} WHERE {UTC} >= '2026-03-01T00:00:00.000000Z' AND {UTC} < '2026-04-01T00:00:00.000000Z'",
     f"SELECT log_id FROM {FLAT} WHERE event_timestamp_utc >= '2026-03-01 00:00:00+00' AND event_timestamp_utc < '2026-04-01 00:00:00+00'",
     498, False),
    ("Q13a", "Q13", "pattern, suffix",
     "SELECT log_id FROM {T} WHERE doc->'fields'->'email_address'->>'value' LIKE '%.org'",
     f"SELECT log_id FROM {FLAT} WHERE email_address LIKE '%.org'", 545, False),
    ("Q13b", "Q13", "pattern, prefix",
     "SELECT log_id FROM {T} WHERE doc->'fields'->'tool'->>'value' LIKE 'curl/%'",
     f"SELECT log_id FROM {FLAT} WHERE tool LIKE 'curl/%'", 173, False),
    ("Q14", "Q14", "array membership (equivalent array function per type)",
     "SELECT log_id FROM {T} WHERE EXISTS (SELECT 1 FROM {P}_array_elements_text(doc->'record'->'diagnostics') AS d (x) WHERE d.x = 'truncated')",
     f"SELECT log_id FROM {FLAT} WHERE diagnostics @> ARRAY['truncated']", 3, False),
    ("Q15", "Q15", "JSON null test",
     f"SELECT log_id FROM {{T}} WHERE {UTC} IS NOT NULL",
     f"SELECT log_id FROM {FLAT} WHERE event_timestamp_utc IS NOT NULL", 2941, False),
    ("Q16", "Q16", "conjunction",
     "SELECT log_id FROM {T} WHERE doc->'record'->>'format_family' = 'F3' AND (doc->'fields'->'status'->>'code')::integer = 403",
     f"SELECT log_id FROM {FLAT} WHERE format_family = 'F3' AND status_code = 403", None, False),
    ("Q17", "Q17", "group by nested text",
     "SELECT doc->'fields'->'entity_type'->>'code' AS code, count(*) AS n FROM {T} GROUP BY 1",
     f"SELECT entity_type_code AS code, count(*) AS n FROM {FLAT} GROUP BY 1", 8, False),
    ("Q18", "Q18", "group by two nested values",
     "SELECT doc->'fields'->'status'->>'code' AS code, doc->'fields'->'status'->>'word' AS word, count(*) AS n FROM {T} GROUP BY 1, 2",
     f"SELECT status_code::text AS code, status_word AS word, count(*) AS n FROM {FLAT} GROUP BY 1, 2", None, False),
    ("Q19", "Q19", "numeric aggregates",
     "SELECT min((doc->'fields'->'latitude'->>'degrees')::numeric) AS min_lat, max((doc->'fields'->'latitude'->>'degrees')::numeric) AS max_lat, "
     "avg((doc->'fields'->'latitude'->>'degrees')::numeric) AS avg_lat FROM {T} WHERE doc->'fields'->'latitude'->>'validity' = 'VALID'",
     f"SELECT min(latitude_degrees) AS min_lat, max(latitude_degrees) AS max_lat, avg(latitude_degrees) AS avg_lat FROM {FLAT} WHERE latitude_validity = 'VALID'",
     1, False),
    ("Q20", "Q20", "SQL/JSON JSON_VALUE",
     "SELECT log_id, JSON_VALUE(doc, '$.record.record_validity') AS record_validity FROM {T}",
     f"SELECT log_id, record_validity::text FROM {FLAT}", 5000, False),
    ("Q21", "Q21", "SQL/JSON JSON_EXISTS",
     "SELECT log_id FROM {T} WHERE JSON_EXISTS(doc, '$.fields.status.code ? (@ == 404)')",
     f"SELECT log_id FROM {FLAT} WHERE status_code = 404", 30, False),
]


def statement(sql, doc_type):
    return sql.replace("{T}", TABLES[doc_type]).replace("{P}", doc_type)


def checksum_expr(sql, normalise):
    inner = f"SELECT q.doc::jsonb AS doc FROM ({sql}) AS q" if normalise else sql
    return (f"(SELECT count(*) || ':' || coalesce(md5(string_agg(s.x, chr(10) ORDER BY s.x)), '-') "
            f"FROM (SELECT r::text AS x FROM ({inner}) AS r) AS s)")


def generate_sql36():
    rows = []
    gate = [
        ("G-01", "access_log_json rows", "'5000'", "(SELECT count(*)::text FROM log_regex_json.access_log_json)"),
        ("G-02", "access_log_jsonb rows", "'5000'", "(SELECT count(*)::text FROM log_regex_json.access_log_jsonb)"),
        ("G-03", "md5 of json document texts = canonical input md5 recorded at load (documents unchanged)",
         "(SELECT substring(obj_description('log_regex_json.access_log_json'::regclass, 'pg_class') FROM 'md5 ([0-9a-f]{32})'))",
         "(SELECT md5(string_agg(doc::text, chr(10) ORDER BY log_id)) FROM log_regex_json.access_log_json)"),
        ("G-04", "jsonb documents = json documents cast to jsonb (documents unchanged)", "'5000'",
         "(SELECT count(*)::text FROM log_regex_json.access_log_json j JOIN log_regex_json.access_log_jsonb b ON b.log_id = j.log_id WHERE j.doc::jsonb = b.doc)"),
        ("G-05", "indexes on the experiment tables (primary keys only)", "'access_log_json_pkey,access_log_jsonb_pkey'",
         "(SELECT string_agg(ic.relname, ',' ORDER BY ic.relname) FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid "
         "JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex_json'::regnamespace)"),
        ("G-06", "rows inserted / updated / deleted since creation (json, jsonb)", "'5000/0/0 5000/0/0'",
         "(SELECT string_agg(s.n_tup_ins || '/' || (s.n_tup_upd + s.n_tup_hot_upd) || '/' || s.n_tup_del, ' ' ORDER BY s.relname) "
         "FROM pg_stat_user_tables s WHERE s.schemaname = 'log_regex_json')"),
        ("G-07", "heap pages (json / jsonb) as measured in Step 6B", "'1250/981'",
         "(SELECT (SELECT relpages FROM pg_class WHERE oid = 'log_regex_json.access_log_json'::regclass) || '/' || "
         "(SELECT relpages FROM pg_class WHERE oid = 'log_regex_json.access_log_jsonb'::regclass))"),
    ]
    rows.extend(gate)
    for qid, _group, pattern, sql, oracle, expected, normalise in QUERIES:
        json_ck = checksum_expr(statement(sql, "json"), normalise)
        jsonb_ck = checksum_expr(statement(sql, "jsonb"), normalise)
        if normalise:
            rows.append((f"C-{qid}-a", f"{qid} json result = jsonb result (documents compared as jsonb)", jsonb_ck, json_ck))
        else:
            oracle_ck = checksum_expr(oracle, False)
            rows.append((f"C-{qid}-a", f"{qid} json result = access_log_flat oracle", oracle_ck, json_ck))
            rows.append((f"C-{qid}-b", f"{qid} jsonb result = access_log_flat oracle", oracle_ck, jsonb_ck))
        if expected is not None:
            rows.append((f"C-{qid}-n", f"{qid} rows = Step 6A expectation", f"'{expected}'",
                         f"(SELECT count(*)::text FROM ({statement(sql, 'json')}) AS q)"))
    values = ",\n".join(f"            ('{rid}', '{name.replace(chr(39), chr(39) * 2)}', {exp}, {act})" for rid, name, exp, act in rows)
    ids = ", ".join(q[0] for q in QUERIES)
    return f"""-- =============================================================================
-- Step 6C / 36 - JSON vs JSONB: unchanged-data gate and query result correctness (read-only)
-- =============================================================================
-- GENERATED by scripts/step6c_json_query_experiment.py - do not edit by hand.
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/36_verify_json_query_results.sql
--
-- READ ONLY transaction, rolled back; TimeZone UTC. Exits non-zero (SQLSTATE LR013) unless every check passes.
--   G-01 ... G-07  both tables 5,000 rows; json texts = canonical input md5; jsonb = json::jsonb; primary keys only;
--                  no row inserted, updated or deleted since the Step 6B load; heap pages as in Step 6B
--   C-<query>-a/b  result checksum (row count and md5 of the sorted row texts) of the json and the jsonb statement
--                  = the access_log_flat oracle; Q01 and Q02 return whole documents, compared json-as-jsonb = jsonb
--                  (the documents themselves are verified against access_log_flat by sql/34)
--   C-<query>-n    row count = the Step 6A expectation where one was stated
-- Statements: {ids}
-- =============================================================================

\\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN TRANSACTION READ ONLY;

SET LOCAL TimeZone = 'UTC';

DO $verify$
DECLARE
    v_failed text[] := '{{}}';
    v_checks integer := 0;
    chk      record;
BEGIN
    FOR chk IN
        SELECT c.id, c.name, c.expected, c.actual
        FROM (VALUES
{values}
        ) AS c (id, name, expected, actual)
    LOOP
        v_checks := v_checks + 1;
        IF chk.expected IS NOT DISTINCT FROM chk.actual THEN
            RAISE NOTICE '% PASS  %: %', chk.id, chk.name, chk.actual;
        ELSE
            v_failed := v_failed || chk.id;
            RAISE WARNING '% FAIL  %: expected %, actual %', chk.id, chk.name, chk.expected, chk.actual;
        END IF;
    END LOOP;

    IF cardinality(v_failed) > 0 THEN
        RAISE EXCEPTION 'JSON query result check FAILED: % of % checks: %', cardinality(v_failed), v_checks, array_to_string(v_failed, ', ')
            USING ERRCODE = 'LR013';
    END IF;
    RAISE NOTICE 'JSON query result check PASSED: all % checks', v_checks;
END
$verify$;

ROLLBACK;
"""


def generate_sql37():
    out = [f"""-- =============================================================================
-- Step 6C / 37 - JSON vs JSONB head-to-head query measurements (read-only)
-- =============================================================================
-- GENERATED by scripts/step6c_json_query_experiment.py - do not edit by hand.
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/37_measure_json_queries.sql -o <file>
--   (the runner uses a read-only session: PGOPTIONS=-c default_transaction_read_only=on)
--
-- One session. Session settings (Step 6A section 7.2): jit off, max_parallel_workers_per_gather 0, TimeZone UTC,
-- track_io_timing on. For each of the {len(QUERIES)} statements:
--   {WARMUP_ROUNDS} warm-up rounds (json, jsonb), not measured
--   {MEASURED_ROUNDS} measured rounds, order alternating: odd rounds json then jsonb, even rounds jsonb then json
--   1 detail round per type with per-node timing
-- Measured rounds: {EXPLAIN_MEASURE}
-- Detail rounds:   {EXPLAIN_DETAIL}
-- Output: one "##RUN <query> <type> <phase> <round>" marker line followed by the EXPLAIN JSON document; parsed by
-- scripts/step6c_json_query_experiment.py analyze. No statement writes; no index; no jsonb-only operator.
-- =============================================================================

\\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
SET jit = off;
SET max_parallel_workers_per_gather = 0;
SET TimeZone = 'UTC';
SET track_io_timing = on;
\\pset tuples_only on
\\pset format unaligned
\\pset pager off

\\qecho ##SESSION
SELECT json_build_object(
           'pid', pg_backend_pid(),
           'started', clock_timestamp(),
           'server_version', current_setting('server_version'),
           'read_only', current_setting('default_transaction_read_only'),
           'settings', (SELECT json_object_agg(name, setting ORDER BY name) FROM pg_settings
                        WHERE name IN ('jit', 'max_parallel_workers_per_gather', 'TimeZone', 'track_io_timing', 'work_mem',
                                       'shared_buffers', 'effective_cache_size', 'random_page_cost', 'default_toast_compression')),
           'other_active_sessions', (SELECT count(*) FROM pg_stat_activity
                                     WHERE pid <> pg_backend_pid() AND backend_type = 'client backend' AND state <> 'idle'))::text;
"""]
    for qid, _group, _pattern, sql, _oracle, _expected, _normalise in QUERIES:
        out.append(f"\n-- {qid} ---------------------------------------------------------------------------------------")
        for w in range(1, WARMUP_ROUNDS + 1):
            for t in TYPES:
                out.append(f"\\qecho ##RUN {qid} {t} warmup {w}")
                out.append(f"{EXPLAIN_MEASURE} {statement(sql, t)};")
        for r in range(1, MEASURED_ROUNDS + 1):
            order = TYPES if r % 2 == 1 else tuple(reversed(TYPES))
            for t in order:
                out.append(f"\\qecho ##RUN {qid} {t} measure {r}")
                out.append(f"{EXPLAIN_MEASURE} {statement(sql, t)};")
        for t in TYPES:
            out.append(f"\\qecho ##RUN {qid} {t} detail 1")
            out.append(f"{EXPLAIN_DETAIL} {statement(sql, t)};")
    out.append("\n\\qecho ##END")
    out.append("SELECT json_build_object('pid', pg_backend_pid(), 'finished', clock_timestamp())::text;\n")
    return "\n".join(out)


def cmd_generate(check):
    targets = {SQL36: generate_sql36(), SQL37: generate_sql37()}
    stale = []
    for path, text in targets.items():
        data = text.encode("ascii")
        if check:
            if not path.exists() or path.read_bytes().replace(b"\r\n", b"\n") != data:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.write_bytes(data)
            print(f"wrote {path.relative_to(ROOT)} ({len(data)} bytes)")
    if check:
        if stale:
            print("stale generated files: " + ", ".join(stale))
            return 1
        print("generated SQL files are up to date: " + ", ".join(str(p.relative_to(ROOT)) for p in targets))
    return 0


# ---------------------------------------------------------------------------------------------------------------------
# analysis
MARKER = re.compile(r"^##RUN (\S+) (json|jsonb) (warmup|measure|detail) (\d+)$")


def walk(node):
    yield node
    for child in node.get("Plans", []):
        yield from walk(child)


def shape(node):
    label = node["Node Type"]
    if node.get("Index Name"):
        label += " using " + node["Index Name"].replace("access_log_jsonb", "T").replace("access_log_json", "T")
    elif node.get("Relation Name"):
        label += " on T" if node["Relation Name"].startswith("access_log_json") else " on " + node["Relation Name"]
    elif node.get("Function Name"):
        label += " " + node["Function Name"].replace("jsonb_", "<type>_").replace("json_", "<type>_")
    kids = node.get("Plans", [])
    return label + (" [" + "; ".join(shape(k) for k in kids) + "]" if kids else "")


def record_from_plan(batch, marker, doc):
    qid, doc_type, phase, rnd = marker
    plan = doc[0]
    top = plan["Plan"]
    scan = next((n for n in walk(top) if str(n.get("Relation Name", "")).startswith("access_log_json")), {})
    planning = plan.get("Planning", {})
    ser = plan.get("Serialization", {})
    return {
        "batch": batch, "query": qid, "type": doc_type, "phase": phase, "round": int(rnd),
        "planning_ms": plan.get("Planning Time"), "execution_ms": plan.get("Execution Time"),
        "serialization_ms": ser.get("Time"), "output_kb": ser.get("Output Volume"),
        "top_node": top["Node Type"], "plan_shape": shape(top),
        "top_plan_rows": top.get("Plan Rows"), "top_actual_rows": top.get("Actual Rows"),
        "scan_plan_rows": scan.get("Plan Rows"), "scan_actual_rows": scan.get("Actual Rows"),
        "scan_rows_removed_by_filter": scan.get("Rows Removed by Filter"),
        "shared_hit_blocks": top.get("Shared Hit Blocks"), "shared_read_blocks": top.get("Shared Read Blocks"),
        "temp_written_blocks": top.get("Temp Written Blocks"), "io_read_ms": top.get("I/O Read Time"),
        "serialization_shared_hit_blocks": ser.get("Shared Hit Blocks"),
        "planning_shared_hit_blocks": planning.get("Shared Hit Blocks"), "planning_memory_used_kb": planning.get("Memory Used"),
        "jit": "JIT" in plan, "settings": json.dumps(plan.get("Settings", {}), sort_keys=True),
    }


def parse_batch(path, batch):
    runs, sessions, current, buf, section = [], [], None, [], None

    def flush():
        text = "\n".join(buf).strip()
        if section == "run" and current:
            runs.append(record_from_plan(batch, current, json.loads(text)))
        elif section in ("session", "end") and text:
            sessions.append(json.loads(text.splitlines()[-1]))

    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("##"):
            flush()
            buf = []
            m = MARKER.match(stripped)
            if m:
                section, current = "run", m.groups()
            elif stripped == "##SESSION":
                section, current = "session", None
            elif stripped == "##END":
                section, current = "end", None
            else:
                raise ValueError(f"unknown marker {stripped!r} in {path}")
        elif section:
            buf.append(line)
    flush()
    return runs, sessions


def nearest_rank(sorted_values, p):
    return sorted_values[max(1, math.ceil(p * len(sorted_values))) - 1]


def stats(values):
    v = sorted(values)
    return {"n": len(v), "min": v[0], "p25": nearest_rank(v, 0.25), "median": nearest_rank(v, 0.5),
            "p75": nearest_rank(v, 0.75), "max": v[-1]}


def distinct(values):
    return "|".join(sorted({str(x) for x in values}))


def summarise(runs):
    summary = {}
    for batch in sorted({r["batch"] for r in runs}):
        for qid, *_ in QUERIES:
            for t in TYPES:
                measured = [r for r in runs if r["batch"] == batch and r["query"] == qid and r["type"] == t and r["phase"] == "measure"]
                detail = [r for r in runs if r["batch"] == batch and r["query"] == qid and r["type"] == t and r["phase"] == "detail"]
                if not measured:
                    continue
                ex = stats([r["execution_ms"] for r in measured])
                pl = stats([r["planning_ms"] for r in measured])
                summary[(batch, qid, t)] = {
                    "batch": batch, "query": qid, "type": t, "runs": ex["n"],
                    **{f"exec_{k}": v for k, v in ex.items() if k != "n"},
                    **{f"plan_{k}": v for k, v in pl.items() if k != "n"},
                    "shared_hit_blocks": distinct(r["shared_hit_blocks"] for r in measured),
                    "shared_read_blocks": distinct(r["shared_read_blocks"] for r in measured),
                    "serialization_shared_hit_blocks": distinct(r["serialization_shared_hit_blocks"] for r in measured),
                    "planning_shared_hit_blocks": distinct(r["planning_shared_hit_blocks"] for r in measured),
                    "planning_memory_used_kb": distinct(r["planning_memory_used_kb"] for r in measured),
                    "output_kb": distinct(r["output_kb"] for r in measured),
                    "plan_shape": distinct(r["plan_shape"] for r in measured),
                    "top_plan_rows": distinct(r["top_plan_rows"] for r in measured),
                    "top_actual_rows": distinct(r["top_actual_rows"] for r in measured),
                    "scan_plan_rows": distinct(r["scan_plan_rows"] for r in measured),
                    "scan_actual_rows": distinct(r["scan_actual_rows"] for r in measured),
                    "scan_rows_removed_by_filter": distinct(r["scan_rows_removed_by_filter"] for r in measured),
                    "temp_written_blocks": distinct(r["temp_written_blocks"] for r in measured),
                    "jit_present": any(r["jit"] for r in measured + detail),
                    "settings": distinct(r["settings"] for r in measured),
                    "detail_execution_ms": detail[0]["execution_ms"] if detail else None,
                    "detail_serialization_ms": detail[0]["serialization_ms"] if detail else None,
                }
    return summary


def verdict(a, b):
    """a, b: summary rows of json and jsonb for one batch; returns (measurable, faster, ratio, overlap, rel_diff)."""
    ja, jb = a["exec_median"], b["exec_median"]
    overlap = not (a["exec_p75"] < b["exec_p25"] or b["exec_p75"] < a["exec_p25"])
    slower, faster_value = max(ja, jb), min(ja, jb)
    rel = (slower - faster_value) / slower if slower > 0 else 0.0
    faster = "json" if ja < jb else ("jsonb" if jb < ja else "tie")
    return (not overlap and rel >= MIN_RELATIVE_DIFFERENCE), faster, (jb / ja if ja else None), overlap, rel


def plan_verdict(a, b):
    ja, jb = a["plan_median"], b["plan_median"]
    overlap = not (a["plan_p75"] < b["plan_p25"] or b["plan_p75"] < a["plan_p25"])
    slower, faster_value = max(ja, jb), min(ja, jb)
    rel = (slower - faster_value) / slower if slower > 0 else 0.0
    faster = "json" if ja < jb else ("jsonb" if jb < ja else "tie")
    return (not overlap and rel >= MIN_RELATIVE_DIFFERENCE), faster, overlap, rel


def compare(summary):
    rows = []
    for qid, group, pattern, _sql, _oracle, expected, _norm in QUERIES:
        s1j, s1b = summary.get((1, qid, "json")), summary.get((1, qid, "jsonb"))
        s2j, s2b = summary.get((2, qid, "json")), summary.get((2, qid, "jsonb"))
        m1, f1, ratio1, ov1, rel1 = verdict(s1j, s1b)
        row = {"query": qid, "group": group, "pattern": pattern,
               "json_median_ms": s1j["exec_median"], "json_p25_ms": s1j["exec_p25"], "json_p75_ms": s1j["exec_p75"],
               "jsonb_median_ms": s1b["exec_median"], "jsonb_p25_ms": s1b["exec_p25"], "jsonb_p75_ms": s1b["exec_p75"],
               "jsonb_over_json": round(ratio1, 3) if ratio1 else None, "faster_median": f1,
               "iqr_overlap": ov1, "relative_difference": round(rel1, 3), "measurable_batch1": m1}
        small = min(s1j["exec_median"], s1b["exec_median"]) < SMALL_MEDIAN_MS
        if s2j and s2b:
            m2, f2, ratio2, ov2, rel2 = verdict(s2j, s2b)
            row.update({"json_median_ms_batch2": s2j["exec_median"], "jsonb_median_ms_batch2": s2b["exec_median"],
                        "jsonb_over_json_batch2": round(ratio2, 3) if ratio2 else None, "faster_median_batch2": f2,
                        "measurable_batch2": m2})
        else:
            m2, f2 = False, None
        if m1 and (not small or (m2 and f2 == f1)):
            result = f"measurable: {f1} faster"
        elif m1 and small:
            result = "not confirmed (below 0.1 ms; second session differs)"
        else:
            result = "no measurable difference"
        row["below_0_1_ms"] = small
        row["execution_result"] = result
        pm1, pf1, pov1, prel1 = plan_verdict(s1j, s1b)
        row.update({"json_plan_median_ms": s1j["plan_median"], "jsonb_plan_median_ms": s1b["plan_median"],
                    "planning_result": f"measurable: {pf1} faster" if pm1 else "no measurable difference"})
        row.update({"plan_shape_json": s1j["plan_shape"], "plan_shape_jsonb": s1b["plan_shape"],
                    "same_plan_shape": s1j["plan_shape"] == s1b["plan_shape"],
                    "scan_est_rows": s1j["scan_plan_rows"] + " / " + s1b["scan_plan_rows"],
                    "actual_rows_json": s1j["top_actual_rows"], "actual_rows_jsonb": s1b["top_actual_rows"],
                    "expected_rows": expected,
                    "rows_ok": s1j["top_actual_rows"] == s1b["top_actual_rows"]
                               and (expected is None or s1j["top_actual_rows"] == str(expected)),
                    "shared_hit_json": s1j["shared_hit_blocks"], "shared_hit_jsonb": s1b["shared_hit_blocks"],
                    "shared_read_json": s1j["shared_read_blocks"], "shared_read_jsonb": s1b["shared_read_blocks"],
                    "output_kb_json": s1j["output_kb"], "output_kb_jsonb": s1b["output_kb"],
                    "detail_serialization_ms_json": s1j["detail_serialization_ms"],
                    "detail_serialization_ms_jsonb": s1b["detail_serialization_ms"]})
        rows.append(row)
    return rows


def write_csv(path, rows):
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def fmt(x, digits=3):
    return "-" if x is None else f"{x:.{digits}f}"


def cmd_analyze():
    all_runs, sessions = [], {}
    for batch in (1, 2):
        path = ANALYSIS / f"step6c_batch{batch}_explain.txt"
        if not path.exists():
            print(f"missing {path.relative_to(ROOT)}")
            return 1
        runs, sess = parse_batch(path, batch)
        all_runs.extend(runs)
        sessions[batch] = sess
    expected_runs = len(QUERIES) * len(TYPES) * (WARMUP_ROUNDS + MEASURED_ROUNDS + 1)
    problems = []
    for batch in (1, 2):
        n = sum(1 for r in all_runs if r["batch"] == batch)
        if n != expected_runs:
            problems.append(f"batch {batch}: {n} executions parsed, expected {expected_runs}")
    if any(r["jit"] for r in all_runs):
        problems.append("JIT section present in at least one plan")
    settings = {r["settings"] for r in all_runs}
    if len(settings) != 1:
        problems.append(f"{len(settings)} different EXPLAIN SETTINGS outputs")
    summary = summarise(all_runs)
    comparison = compare(summary)
    for row in comparison:
        if not row["rows_ok"]:
            problems.append(f"{row['query']}: actual rows json {row['actual_rows_json']} / jsonb {row['actual_rows_jsonb']} / expected {row['expected_rows']}")

    write_csv(ANALYSIS / "step6c_executions.csv", all_runs)
    write_csv(ANALYSIS / "step6c_summary.csv", list(summary.values()))
    write_csv(ANALYSIS / "step6c_comparison.csv", comparison)

    md = ["# Step 6C measurement summary (generated)", "",
          f"Executions parsed: {len(all_runs)} ({expected_runs} per batch expected). Settings reported by EXPLAIN: {sorted(settings)[0]}.",
          f"Sessions: batch 1 {json.dumps(sessions[1])}; batch 2 {json.dumps(sessions[2])}.", "",
          "Execution time in ms (includes output serialisation, SERIALIZE TEXT); median [p25-p75] of 15 runs, batch 1; batch 2 median.", "",
          "| Query | Pattern | json median [IQR] | jsonb median [IQR] | jsonb/json | Batch 2 json / jsonb | Result |",
          "|---|---|---|---|---:|---|---|"]
    for r in comparison:
        md.append(f"| {r['query']} | {r['pattern']} | {fmt(r['json_median_ms'])} [{fmt(r['json_p25_ms'])}-{fmt(r['json_p75_ms'])}] | "
                  f"{fmt(r['jsonb_median_ms'])} [{fmt(r['jsonb_p25_ms'])}-{fmt(r['jsonb_p75_ms'])}] | {fmt(r['jsonb_over_json'], 2)} | "
                  f"{fmt(r.get('json_median_ms_batch2'))} / {fmt(r.get('jsonb_median_ms_batch2'))} | {r['execution_result']} |")
    md += ["", "| Query | Planning ms json / jsonb (median) | Planning result | Same plan shape | Plan shape (json) | Scan est. rows json / jsonb | Actual rows | Shared hit json / jsonb | Output kB json / jsonb | Serialisation ms json / jsonb (detail run) |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for r in comparison:
        md.append(f"| {r['query']} | {fmt(r['json_plan_median_ms'])} / {fmt(r['jsonb_plan_median_ms'])} | {r['planning_result']} | {r['same_plan_shape']} | "
                  f"{r['plan_shape_json']} | {r['scan_est_rows']} | {r['actual_rows_json']} | {r['shared_hit_json']} / {r['shared_hit_jsonb']} | "
                  f"{r['output_kb_json']} / {r['output_kb_jsonb']} | {fmt(r['detail_serialization_ms_json'])} / {fmt(r['detail_serialization_ms_jsonb'])} |")
    md += ["", "Problems: " + ("; ".join(problems) if problems else "none")]
    (ANALYSIS / "step6c_summary.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print(f"parsed {len(all_runs)} executions; wrote step6c_executions.csv, step6c_summary.csv, step6c_comparison.csv, step6c_summary.md")
    print("problems: " + ("; ".join(problems) if problems else "none"))
    return 1 if problems else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--check", action="store_true")
    sub.add_parser("analyze")
    args = parser.parse_args()
    return cmd_generate(args.check) if args.command == "generate" else cmd_analyze()


if __name__ == "__main__":
    sys.exit(main())
