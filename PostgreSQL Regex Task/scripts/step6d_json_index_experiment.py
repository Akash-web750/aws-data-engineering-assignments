#!/usr/bin/env python3
"""Step 6D - JSON vs JSONB index experiment (docs/Step6D_JSON_vs_JSONB_Index_Experiment.md).

Index configurations of Step 6A section 6 (I-4, the json-via-cast GIN index, is not part of Step 6D):
  I-0  no secondary index: control measurements immediately before any index is built
  I-1  the same five btree expression indexes on access_log_json and access_log_jsonb   (head-to-head)
  I-2  I-1 + GIN jsonb_ops on access_log_jsonb                                          (jsonb-only capability)
  I-3  I-1 + GIN jsonb_path_ops on access_log_jsonb, jsonb_ops dropped                  (jsonb-only capability)
  final  I-1 + both GIN indexes (end state; verification only)

Head-to-head statements are the Step 6C definitions (scripts/step6c_json_query_experiment.py, imported unchanged).

  python scripts/step6d_json_index_experiment.py generate [--check]
      writes sql/38_verify_json_index_phase.sql, sql/39_build_json_experiment_indexes.sql, sql/40_measure_json_index_phase.sql
  python scripts/step6d_json_index_experiment.py analyze
      reads analysis/step6/step6d_*.txt and analysis/step6/step6c_summary.csv; writes step6d_builds.csv,
      step6d_executions.csv, step6d_summary.csv, step6d_comparisons.csv and step6d_summary.md

Standard library only.
"""
import argparse
import csv
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import step6c_json_query_experiment as c6  # noqa: E402

ROOT = c6.ROOT
ANALYSIS = c6.ANALYSIS
TABLES = c6.TABLES
TYPES = c6.TYPES
FLAT = c6.FLAT
SQL38 = ROOT / "sql" / "38_verify_json_index_phase.sql"
SQL39 = ROOT / "sql" / "39_build_json_experiment_indexes.sql"
SQL40 = ROOT / "sql" / "40_measure_json_index_phase.sql"
BUILD_ROUNDS = 3

# concept, name suffix, indexed expression (as in CREATE INDEX ... ((expr))), path description, btree opclass, statements
EXPRESSION_INDEXES = [
    ("I-1a", "i1a_record_validity", "doc->'record'->>'record_validity'",
     "record.record_validity (text)", "text_ops", ["Q07"]),
    ("I-1b", "i1b_entity_type_code", "doc->'fields'->'entity_type'->>'code'",
     "fields.entity_type.code (text)", "text_ops", ["Q08", "Q17"]),
    ("I-1c", "i1c_status_code", "(doc->'fields'->'status'->>'code')::integer",
     "fields.status.code, cast to integer", "int4_ops", ["Q10", "Q16"]),
    ("I-1d", "i1d_latitude_degrees", "(doc->'fields'->'latitude'->>'degrees')::numeric",
     "fields.latitude.degrees, cast to numeric", "numeric_ops", ["Q11a", "Q11b"]),
    ("I-1e", "i1e_event_timestamp_utc", "doc->'fields'->'event_timestamp'->>'utc'",
     "fields.event_timestamp.utc (text, fixed-width ISO UTC)", "text_ops", ["Q12a", "Q12b", "Q12c"]),
]
# concept, index name, opclass, description
GIN_INDEXES = [
    ("I-2", "access_log_jsonb_i2_gin_jsonb_ops", "jsonb_ops", "whole document: every key and every value (default GIN opclass)"),
    ("I-3", "access_log_jsonb_i3_gin_jsonb_path_ops", "jsonb_path_ops", "whole document: hash of each path to a value"),
]
PKS = ["access_log_json_pkey", "access_log_jsonb_pkey"]
I2_NAME, I3_NAME = GIN_INDEXES[0][1], GIN_INDEXES[1][1]


def index_name(doc_type, suffix):
    return f"access_log_{doc_type}_{suffix}"


def create_expression_index(doc_type, suffix, expr):
    return f"CREATE INDEX {index_name(doc_type, suffix)} ON {TABLES[doc_type]} (({expr}))"


def create_gin_index(name, opclass):
    return f"CREATE INDEX {name} ON {TABLES['jsonb']} USING gin (doc {opclass})"


I1_NAMES = sorted(index_name(t, suffix) for _c, suffix, *_ in EXPRESSION_INDEXES for t in TYPES)

# head-to-head statements (both types): the indexed Step 6C statements plus Q09 as an unindexed control
HEAD = ["Q07", "Q08", "Q10", "Q11a", "Q11b", "Q12a", "Q12b", "Q12c", "Q16", "Q17", "Q09"]
C6 = {q[0]: q for q in c6.QUERIES}
INDEX_FOR = {q: concept for concept, _s, _e, _d, _o, qs in EXPRESSION_INDEXES for q in qs}

# jsonb-only capability statements: id, pattern, statement, oracle, expected rows
CAPABILITY = [
    ("C1", "containment: record_validity BROKEN",
     "SELECT log_id FROM {T} WHERE doc @> '{\"record\":{\"record_validity\":\"BROKEN\"}}'",
     f"SELECT log_id FROM {FLAT} WHERE record_validity = 'BROKEN'", 12),
    ("C1b", "containment: status code 404 (number)",
     "SELECT log_id FROM {T} WHERE doc @> '{\"fields\":{\"status\":{\"code\":404}}}'",
     f"SELECT log_id FROM {FLAT} WHERE status_code = 404", 30),
    ("C1c", "containment: diagnostics array contains truncated",
     "SELECT log_id FROM {T} WHERE doc @> '{\"record\":{\"diagnostics\":[\"truncated\"]}}'",
     f"SELECT log_id FROM {FLAT} WHERE diagnostics @> ARRAY['truncated']", 3),
    ("C1d", "containment: entity type code BOT",
     "SELECT log_id FROM {T} WHERE doc @> '{\"fields\":{\"entity_type\":{\"code\":\"BOT\"}}}'",
     f"SELECT log_id FROM {FLAT} WHERE entity_type_code = 'BOT'", 225),
    ("C2", "existence operator on a nested value",
     "SELECT log_id FROM {T} WHERE doc->'record'->'diagnostics' ? 'truncated'",
     f"SELECT log_id FROM {FLAT} WHERE diagnostics @> ARRAY['truncated']", 3),
    ("C3", "jsonpath exists (@?)",
     "SELECT log_id FROM {T} WHERE doc @? '$.fields.status.code ? (@ == 404)'",
     f"SELECT log_id FROM {FLAT} WHERE status_code = 404", 30),
    ("C3b", "jsonpath predicate (@@)",
     "SELECT log_id FROM {T} WHERE doc @@ '$.record.record_validity == \"BROKEN\"'",
     f"SELECT log_id FROM {FLAT} WHERE record_validity = 'BROKEN'", 12),
    ("Q21", "SQL/JSON JSON_EXISTS (function form)", C6["Q21"][3], C6["Q21"][4], 30),
]
CAP = {c[0]: c for c in CAPABILITY}
CAP_IDS = [c[0] for c in CAPABILITY]

PHASES = {
    "I-0": {"key": "i0", "title": "no secondary index (control, before any index)", "head": HEAD, "cap": CAP_IDS,
            "forced": False, "measure": True, "indexes": PKS},
    "I-1": {"key": "i1", "title": "identical btree expression indexes on both tables", "head": HEAD, "cap": [],
            "forced": True, "measure": True, "indexes": PKS + I1_NAMES},
    "I-2": {"key": "i2", "title": "I-1 + GIN jsonb_ops on access_log_jsonb", "head": [], "cap": CAP_IDS,
            "forced": True, "measure": True, "indexes": PKS + I1_NAMES + [I2_NAME]},
    "I-3": {"key": "i3", "title": "I-1 + GIN jsonb_path_ops on access_log_jsonb (jsonb_ops dropped)", "head": [], "cap": CAP_IDS,
            "forced": True, "measure": True, "indexes": PKS + I1_NAMES + [I3_NAME]},
    "final": {"key": "final", "title": "end state: I-1 + both GIN indexes", "head": HEAD, "cap": CAP_IDS,
              "forced": True, "measure": False, "indexes": PKS + I1_NAMES + [I2_NAME, I3_NAME]},
}
BUILD_STEPS = {"I-1": "I-0", "I-2": "I-1", "I-3": "I-2", "final": "I-3"}   # step -> required state before the step


def stmt(sql, doc_type):
    return c6.statement(sql, doc_type)


def expected_opclasses(names):
    out = []
    for name in sorted(names):
        for _c, suffix, _e, _d, opc, _q in EXPRESSION_INDEXES:
            for t in TYPES:
                if name == index_name(t, suffix):
                    out.append(f"{name}:btree:{opc}")
        for _c, gname, opc, _d in GIN_INDEXES:
            if name == gname:
                out.append(f"{name}:gin:{opc}")
    return ",".join(out)


def sql_literal(text):
    return "'" + text.replace("'", "''") + "'"


# ---------------------------------------------------------------------------------------------------------------------
# sql/38 - verification per phase
def check_rows(phase, spec):
    idx = spec["indexes"]
    non_pk = [n for n in idx if n not in PKS]
    rows = [
        ("G-01", "access_log_json rows", "'5000'", "(SELECT count(*)::text FROM log_regex_json.access_log_json)"),
        ("G-02", "access_log_jsonb rows", "'5000'", "(SELECT count(*)::text FROM log_regex_json.access_log_jsonb)"),
        ("G-03", "md5 of json document texts = canonical input md5 recorded at load (documents unchanged)",
         "(SELECT substring(obj_description('log_regex_json.access_log_json'::regclass, 'pg_class') FROM 'md5 ([0-9a-f]{32})'))",
         "(SELECT md5(string_agg(doc::text, chr(10) ORDER BY log_id)) FROM log_regex_json.access_log_json)"),
        ("G-04", "jsonb documents = json documents cast to jsonb (documents unchanged)", "'5000'",
         "(SELECT count(*)::text FROM log_regex_json.access_log_json j JOIN log_regex_json.access_log_jsonb b ON b.log_id = j.log_id WHERE j.doc::jsonb = b.doc)"),
        ("G-05", f"indexes on the experiment tables = phase {phase} design", sql_literal(",".join(sorted(idx))),
         "(SELECT string_agg(ic.relname, ',' ORDER BY ic.relname) FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid "
         "JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex_json'::regnamespace)"),
        ("G-06", "indexes that are not valid, not ready or not live", "'0'",
         "(SELECT count(*)::text FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid "
         "WHERE c.relnamespace = 'log_regex_json'::regnamespace AND NOT (i.indisvalid AND i.indisready AND i.indislive))"),
        ("G-07", "rows inserted / updated / deleted since creation (json, jsonb)", "'5000/0/0 5000/0/0'",
         "(SELECT string_agg(s.n_tup_ins || '/' || (s.n_tup_upd + s.n_tup_hot_upd) || '/' || s.n_tup_del, ' ' ORDER BY s.relname) "
         "FROM pg_stat_user_tables s WHERE s.schemaname = 'log_regex_json')"),
        ("G-08", "heap pages (json / jsonb) as measured in Step 6B", "'1250/981'",
         "(SELECT (SELECT relpages FROM pg_class WHERE oid = 'log_regex_json.access_log_json'::regclass) || '/' || "
         "(SELECT relpages FROM pg_class WHERE oid = 'log_regex_json.access_log_jsonb'::regclass))"),
    ]
    if non_pk:
        rows.append(("G-09", "access method and operator class of every experiment index",
                     sql_literal(expected_opclasses(non_pk)),
                     "(SELECT string_agg(ic.relname || ':' || am.amname || ':' || opc.opcname, ',' ORDER BY ic.relname) "
                     "FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid "
                     "JOIN pg_am am ON am.oid = ic.relam JOIN pg_opclass opc ON opc.oid = i.indclass[0] "
                     "WHERE c.relnamespace = 'log_regex_json'::regnamespace AND NOT i.indisprimary)"))
    if any(n in idx for n in I1_NAMES):
        suffixes = ", ".join(f"('{s}')" for _c, s, *_ in EXPRESSION_INDEXES)
        rows.append(("G-10", "btree expression index definitions identical on json and jsonb (table names normalised)", "'5'",
                     f"(SELECT count(*)::text FROM (VALUES {suffixes}) AS s (suffix) "
                     "WHERE regexp_replace(pg_get_indexdef(to_regclass('log_regex_json.access_log_json_' || s.suffix)), 'access_log_jsonb?', 'T', 'g') "
                     "= regexp_replace(pg_get_indexdef(to_regclass('log_regex_json.access_log_jsonb_' || s.suffix)), 'access_log_jsonb?', 'T', 'g'))"))
    return rows


def result_rows(spec):
    rows = []
    for qid in spec["head"]:
        _id, _g, _pattern, sql, oracle, expected, _n = C6[qid]
        oracle_ck = c6.checksum_expr(oracle, False)
        rows.append((f"R-{qid}-json", f"{qid} json result = access_log_flat oracle", oracle_ck, c6.checksum_expr(stmt(sql, "json"), False)))
        rows.append((f"R-{qid}-jsonb", f"{qid} jsonb result = access_log_flat oracle", oracle_ck, c6.checksum_expr(stmt(sql, "jsonb"), False)))
    for cid in spec["cap"]:
        _id, _pattern, sql, oracle, expected = CAP[cid]
        rows.append((f"R-{cid}-jsonb", f"{cid} jsonb result = access_log_flat oracle", c6.checksum_expr(oracle, False),
                     c6.checksum_expr(stmt(sql, "jsonb"), False)))
    return rows


def values_block(rows):
    return ",\n".join(f"                ({sql_literal(rid)}, {sql_literal(name)}, {exp}, {act})" for rid, name, exp, act in rows)


def do_block(phase, spec):
    gate = values_block(check_rows(phase, spec))
    results = values_block(result_rows(spec))
    forced = ""
    if spec["forced"]:
        forced = """
    -- the same result checks with sequential scans disabled, so the index paths produce the results
    PERFORM set_config('enable_seqscan', 'off', true);
    FOR chk IN
        SELECT c.id || '-forced' AS id, c.name || ' (enable_seqscan off)' AS name, c.expected, c.actual
        FROM (VALUES
@@RESULTS@@
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
    PERFORM set_config('enable_seqscan', 'on', true);
""".replace("@@RESULTS@@", results)
    body = """DO $verify$
DECLARE
    v_failed text[] := '{}';
    v_checks integer := 0;
    chk      record;
BEGIN
    FOR chk IN
        SELECT c.id, c.name, c.expected, c.actual
        FROM (VALUES
@@GATE@@,
@@RESULTS@@
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
@@FORCED@@
    IF cardinality(v_failed) > 0 THEN
        RAISE EXCEPTION 'JSON index phase @@PHASE@@ check FAILED: % of % checks: %', cardinality(v_failed), v_checks, array_to_string(v_failed, ', ')
            USING ERRCODE = 'LR015';
    END IF;
    RAISE NOTICE 'JSON index phase @@PHASE@@ check PASSED: all % checks', v_checks;
END
$verify$;"""
    return body.replace("@@GATE@@", gate).replace("@@RESULTS@@", results).replace("@@FORCED@@", forced).replace("@@PHASE@@", phase)


def phase_flags():
    names = list(PHASES)
    select = ", ".join(f":'phase' = '{p}' AS is_{PHASES[p]['key']}" for p in names)
    return f"SELECT {select} \\gset"


def generate_sql38():
    parts = ["""-- =============================================================================
-- Step 6D / 38 - JSON index experiment: state and result verification for one phase (read-only)
-- =============================================================================
-- GENERATED by scripts/step6d_json_index_experiment.py - do not edit by hand.
--   psql -X -v ON_ERROR_STOP=1 -v phase=<I-0|I-1|I-2|I-3|final> -d postgresql_regex_task -f sql/38_verify_json_index_phase.sql
--
-- READ ONLY transaction, rolled back. Exits non-zero (SQLSTATE LR015) unless every check passes:
--   G-01 .. G-08  both tables 5,000 rows; documents unchanged (canonical md5, json::jsonb = jsonb); index set = the
--                 phase design; every index valid, ready and live; no row inserted, updated or deleted; heap pages
--   G-09          access method and operator class of every experiment index
--   G-10          the five btree expression index definitions are identical on json and jsonb (table names normalised)
--   R-...         result checksum of every phase statement = access_log_flat oracle, with default settings and again
--                 with enable_seqscan off (phases with indexes)
-- =============================================================================

\\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\\pset footer off

\\if :{?phase}
\\else
    \\echo 'pass -v phase=I-0|I-1|I-2|I-3|final'
    DO $$ BEGIN RAISE EXCEPTION 'missing or unknown psql variable; see the header of this file'; END $$;
\\endif
""", phase_flags(), """
BEGIN TRANSACTION READ ONLY;

SET LOCAL TimeZone = 'UTC';

\\echo '== Indexes on the experiment tables'
SELECT c.relname AS table_name, ic.relname AS index_name, am.amname AS method, i.indisvalid AS valid, i.indisready AS ready,
       i.indislive AS live, pg_relation_size(ic.oid) AS size_bytes, ic.relpages AS pages, ic.reltuples::bigint AS reltuples,
       pg_get_indexdef(ic.oid) AS definition
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class c  ON c.oid = i.indrelid
JOIN pg_am am    ON am.oid = ic.relam
WHERE c.relnamespace = 'log_regex_json'::regnamespace
ORDER BY c.relname, ic.relname;
"""]
    first = True
    for phase, spec in PHASES.items():
        parts.append(("\\if" if first else "\\elif") + f" :is_{spec['key']}")
        parts.append(f"\\echo '== Phase {phase}: {spec['title']}'")
        parts.append(do_block(phase, spec))
        first = False
    parts.append("\\else\n    \\echo 'unknown phase'\n    DO $$ BEGIN RAISE EXCEPTION 'missing or unknown psql variable; see the header of this file'; END $$;\n\\endif\n\nROLLBACK;\n")
    return "\n".join(parts)


# ---------------------------------------------------------------------------------------------------------------------
# sql/39 - index builds
def state_guard(label, required_phase):
    expected = sql_literal(",".join(sorted(PHASES[required_phase]["indexes"])))
    return f"""DO $guard$
DECLARE
    v_actual text;
BEGIN
    SELECT string_agg(ic.relname, ',' ORDER BY ic.relname) INTO v_actual
    FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
    WHERE c.relnamespace = 'log_regex_json'::regnamespace;
    IF v_actual IS DISTINCT FROM {expected} THEN
        RAISE EXCEPTION 'sql/39 {label} refused: index set is %, expected the phase {required_phase} set', v_actual
            USING ERRCODE = 'LR014';
    END IF;
    IF (SELECT count(*) FROM log_regex_json.access_log_json) <> 5000 OR (SELECT count(*) FROM log_regex_json.access_log_jsonb) <> 5000 THEN
        RAISE EXCEPTION 'sql/39 {label} refused: experiment tables do not hold 5,000 rows each' USING ERRCODE = 'LR014';
    END IF;
END
$guard$;"""


def build_block(step, concept, doc_type, rnd, name, create_sql, table):
    return f"""\\qecho ##BUILD {step} {concept} {doc_type} {rnd}
DO $build$
DECLARE
    t0 timestamptz;
    l0 pg_lsn;
BEGIN
    t0 := clock_timestamp();
    l0 := pg_current_wal_insert_lsn();
    {create_sql};
    PERFORM set_config('step6d.last_build',
        json_build_object('index', '{name}', 'table', '{table}',
                          'ms', round((extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric, 3),
                          'wal_bytes', pg_wal_lsn_diff(pg_current_wal_insert_lsn(), l0),
                          'size_bytes', pg_relation_size('log_regex_json.{name}'))::text, false);
END
$build$;
SELECT current_setting('step6d.last_build');"""


def generate_sql39():
    parts = ["""-- =============================================================================
-- Step 6D / 39 - Build the JSON experiment indexes for one step (writes indexes and statistics only)
-- =============================================================================
-- GENERATED by scripts/step6d_json_index_experiment.py - do not edit by hand.
--   psql -X -v ON_ERROR_STOP=1 -v step=<I-1|I-2|I-3|final> -d postgresql_regex_task -f sql/39_build_json_experiment_indexes.sql -o <file>
--
-- Each step refuses (SQLSTATE LR014) unless the index set is the one of the previous phase. Every index is built
-- 3 times (dropped between builds, the third build is kept); each build reports server-side build time, WAL bytes and
-- index size. Session: max_parallel_maintenance_workers 0, maintenance_work_mem 64MB.
--   I-1    the five btree expression indexes on access_log_json and access_log_jsonb (order alternates per round);
--          ANALYZE both tables (expression statistics)
--   I-2    GIN jsonb_ops on access_log_jsonb; ANALYZE access_log_jsonb
--   I-3    DROP the jsonb_ops index; GIN jsonb_path_ops on access_log_jsonb; ANALYZE access_log_jsonb
--   final  GIN jsonb_ops again (single build), so every Step 6D index exists; ANALYZE access_log_jsonb
-- Touches only indexes and planner statistics of schema log_regex_json. No document, no other schema.
-- =============================================================================

\\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
SET max_parallel_maintenance_workers = 0;
SET maintenance_work_mem = '64MB';
\\pset tuples_only on
\\pset format unaligned
\\pset pager off

\\if :{?step}
\\else
    \\echo 'pass -v step=I-1|I-2|I-3|final'
    DO $$ BEGIN RAISE EXCEPTION 'missing or unknown psql variable; see the header of this file'; END $$;
\\endif
SELECT :'step' = 'I-1' AS is_i1, :'step' = 'I-2' AS is_i2, :'step' = 'I-3' AS is_i3, :'step' = 'final' AS is_final \\gset

\\qecho ##BUILDSESSION
SELECT json_build_object('pid', pg_backend_pid(), 'step', :'step', 'started', clock_timestamp(),
                         'settings', (SELECT json_object_agg(name, setting ORDER BY name) FROM pg_settings
                                      WHERE name IN ('maintenance_work_mem', 'max_parallel_maintenance_workers', 'wal_level', 'server_version')))::text;
"""]
    # I-1
    i1 = ["\\if :is_i1", state_guard("step I-1", "I-0")]
    for concept, suffix, expr, _d, _o, _q in EXPRESSION_INDEXES:
        for rnd in range(1, BUILD_ROUNDS + 1):
            order = TYPES if rnd % 2 == 1 else tuple(reversed(TYPES))
            for t in order:
                name = index_name(t, suffix)
                i1.append(build_block("I-1", concept, t, rnd, name, create_expression_index(t, suffix, expr), TABLES[t]))
                if rnd < BUILD_ROUNDS:
                    i1.append(f"DROP INDEX log_regex_json.{name};")
    i1 += ["ANALYZE log_regex_json.access_log_json;", "ANALYZE log_regex_json.access_log_jsonb;"]
    parts.append("\n".join(i1))
    # I-2, I-3
    for step, (concept, name, opclass, _d), required in (("I-2", GIN_INDEXES[0], "I-1"), ("I-3", GIN_INDEXES[1], "I-2")):
        block = [f"\\elif :is_{PHASES[step]['key']}", state_guard(f"step {step}", required)]
        if step == "I-3":
            block.append(f"DROP INDEX log_regex_json.{I2_NAME};")
        for rnd in range(1, BUILD_ROUNDS + 1):
            block.append(build_block(step, concept, "jsonb", rnd, name, create_gin_index(name, opclass), TABLES["jsonb"]))
            if rnd < BUILD_ROUNDS:
                block.append(f"DROP INDEX log_regex_json.{name};")
        block.append("ANALYZE log_regex_json.access_log_jsonb;")
        parts.append("\n".join(block))
    # final
    concept, name, opclass, _d = GIN_INDEXES[0]
    parts.append("\n".join(["\\elif :is_final", state_guard("step final", "I-3"),
                            build_block("final", concept, "jsonb", 1, name, create_gin_index(name, opclass), TABLES["jsonb"]),
                            "ANALYZE log_regex_json.access_log_jsonb;"]))
    parts.append("\\else\n    \\echo 'unknown step'\n    DO $$ BEGIN RAISE EXCEPTION 'missing or unknown psql variable; see the header of this file'; END $$;\n\\endif\n\n\\qecho ##END\nSELECT json_build_object('finished', clock_timestamp())::text;\n")
    return "\n".join(parts)


# ---------------------------------------------------------------------------------------------------------------------
# sql/40 - measurements per phase
SESSION_HEADER = """\\qecho ##SESSION
SELECT json_build_object(
           'pid', pg_backend_pid(),
           'phase', :'phase',
           'started', clock_timestamp(),
           'server_version', current_setting('server_version'),
           'read_only', current_setting('default_transaction_read_only'),
           'settings', (SELECT json_object_agg(name, setting ORDER BY name) FROM pg_settings
                        WHERE name IN ('jit', 'max_parallel_workers_per_gather', 'TimeZone', 'track_io_timing', 'work_mem',
                                       'shared_buffers', 'effective_cache_size', 'random_page_cost', 'enable_seqscan')),
           'indexes', (SELECT json_agg(json_build_object('index', ic.relname, 'table', c.relname, 'method', am.amname,
                                                         'valid', i.indisvalid, 'ready', i.indisready, 'size_bytes', pg_relation_size(ic.oid),
                                                         'reltuples', ic.reltuples, 'definition', pg_get_indexdef(ic.oid)) ORDER BY ic.relname)
                       FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
                       JOIN pg_am am ON am.oid = ic.relam WHERE c.relnamespace = 'log_regex_json'::regnamespace),
           'other_active_sessions', (SELECT count(*) FROM pg_stat_activity
                                     WHERE pid <> pg_backend_pid() AND backend_type = 'client backend' AND state <> 'idle'))::text;"""


def measure_block(phase, mode, spec):
    out = []
    for qid in spec["head"]:
        sql = C6[qid][3]
        for w in range(1, c6.WARMUP_ROUNDS + 1):
            for t in TYPES:
                out += [f"\\qecho ##RUN {phase} {mode} {qid} {t} warmup {w}", f"{c6.EXPLAIN_MEASURE} {stmt(sql, t)};"]
        for r in range(1, c6.MEASURED_ROUNDS + 1):
            for t in (TYPES if r % 2 == 1 else tuple(reversed(TYPES))):
                out += [f"\\qecho ##RUN {phase} {mode} {qid} {t} measure {r}", f"{c6.EXPLAIN_MEASURE} {stmt(sql, t)};"]
        for t in TYPES:
            out += [f"\\qecho ##RUN {phase} {mode} {qid} {t} detail 1", f"{c6.EXPLAIN_DETAIL} {stmt(sql, t)};"]
    for cid in spec["cap"]:
        sql = CAP[cid][2]
        for w in range(1, c6.WARMUP_ROUNDS + 1):
            out += [f"\\qecho ##RUN {phase} {mode} {cid} jsonb warmup {w}", f"{c6.EXPLAIN_MEASURE} {stmt(sql, 'jsonb')};"]
        for r in range(1, c6.MEASURED_ROUNDS + 1):
            out += [f"\\qecho ##RUN {phase} {mode} {cid} jsonb measure {r}", f"{c6.EXPLAIN_MEASURE} {stmt(sql, 'jsonb')};"]
        out += [f"\\qecho ##RUN {phase} {mode} {cid} jsonb detail 1", f"{c6.EXPLAIN_DETAIL} {stmt(sql, 'jsonb')};"]
    return out


def generate_sql40():
    parts = [f"""-- =============================================================================
-- Step 6D / 40 - JSON index experiment: measurements for one phase (read-only)
-- =============================================================================
-- GENERATED by scripts/step6d_json_index_experiment.py - do not edit by hand.
--   psql -X -v ON_ERROR_STOP=1 -v phase=<I-0|I-1|I-2|I-3> -d postgresql_regex_task -f sql/40_measure_json_index_phase.sql -o <file>
--   (the runner uses a read-only session: PGOPTIONS=-c default_transaction_read_only=on)
--
-- Same protocol as Step 6C: jit off, max_parallel_workers_per_gather 0, TimeZone UTC, track_io_timing on;
-- {c6.WARMUP_ROUNDS} warm-up rounds, {c6.MEASURED_ROUNDS} measured rounds (order alternating json/jsonb for head-to-head statements), 1 detail round.
-- Measured: {c6.EXPLAIN_MEASURE}
-- Detail:   {c6.EXPLAIN_DETAIL}
-- Mode "default": planner defaults. Mode "forced" (phases with indexes): enable_seqscan off, a diagnostic that makes
-- the index path visible; reported separately from default plans.
--   I-0  head-to-head {', '.join(HEAD)} on both types; capability {', '.join(CAP_IDS)} on jsonb
--   I-1  head-to-head statements on both types, default and forced
--   I-2  capability statements on jsonb, default and forced
--   I-3  capability statements on jsonb, default and forced
-- Output markers: "##RUN <phase> <mode> <statement> <type> <warmup|measure|detail> <round>" followed by EXPLAIN JSON.
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

\\if :{{?phase}}
\\else
    \\echo 'pass -v phase=I-0|I-1|I-2|I-3'
    DO $$ BEGIN RAISE EXCEPTION 'missing or unknown psql variable; see the header of this file'; END $$;
\\endif
""", phase_flags(), SESSION_HEADER]
    first = True
    for phase, spec in PHASES.items():
        if not spec["measure"]:
            continue
        parts.append(("\\if" if first else "\\elif") + f" :is_{spec['key']}")
        parts.append(f"\n-- ==== phase {phase}, default plans")
        parts += measure_block(phase, "default", spec)
        if spec["forced"]:
            parts += [f"\n-- ==== phase {phase}, forced index paths (diagnostic)", "SET enable_seqscan = off;"]
            parts += measure_block(phase, "forced", spec)
            parts.append("RESET enable_seqscan;")
        first = False
    parts.append("\\else\n    \\echo 'no measurements for this phase'\n    DO $$ BEGIN RAISE EXCEPTION 'missing or unknown psql variable; see the header of this file'; END $$;\n\\endif\n\n\\qecho ##END\nSELECT json_build_object('pid', pg_backend_pid(), 'finished', clock_timestamp())::text;\n")
    return "\n".join(parts)


def cmd_generate(check):
    targets = {SQL38: generate_sql38(), SQL39: generate_sql39(), SQL40: generate_sql40()}
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
RUN = re.compile(r"^##RUN (\S+) (default|forced) (\S+) (json|jsonb) (warmup|measure|detail) (\d+)$")
BUILD = re.compile(r"^##BUILD (\S+) (\S+) (json|jsonb) (\d+)$")


def normalise_index(name):
    return name.replace("access_log_jsonb", "T").replace("access_log_json", "T")


def parse_file(path, handler):
    """Split a psql output file at ## marker lines; handler(marker, text) receives each section."""
    marker, buf = None, []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("##"):
            if marker:
                handler(marker, "\n".join(buf).strip())
            marker, buf = line.strip(), []
        elif marker:
            buf.append(line)
    if marker:
        handler(marker, "\n".join(buf).strip())


def parse_measurements(path, batch, runs, sessions):
    def handler(marker, text):
        m = RUN.match(marker)
        if m:
            phase, mode, qid, doc_type, kind, rnd = m.groups()
            doc = json.loads(text)
            base = c6.record_from_plan(batch, (qid, doc_type, kind, rnd), doc)
            base["kind"] = base.pop("phase")
            nodes = list(c6.walk(doc[0]["Plan"]))
            runs.append({
                "phase": phase, "mode": mode, **base,
                "indexes_used": "|".join(sorted({normalise_index(n["Index Name"]) for n in nodes if n.get("Index Name")})) or "-",
                "exact_heap_blocks": next((n["Exact Heap Blocks"] for n in nodes if "Exact Heap Blocks" in n), None),
                "lossy_heap_blocks": next((n["Lossy Heap Blocks"] for n in nodes if "Lossy Heap Blocks" in n), None),
                "rows_removed_by_index_recheck": next((n["Rows Removed by Index Recheck"] for n in nodes
                                                       if "Rows Removed by Index Recheck" in n), None),
            })
        elif marker in ("##SESSION", "##END"):
            if text:
                sessions.append(json.loads(text.splitlines()[-1]))
        else:
            raise ValueError(f"unexpected marker {marker!r} in {path}")
    parse_file(path, handler)


def parse_builds(path, builds, sessions):
    def handler(marker, text):
        m = BUILD.match(marker)
        if m:
            step, concept, doc_type, rnd = m.groups()
            builds.append({"step": step, "concept": concept, "type": doc_type, "round": int(rnd), **json.loads(text.splitlines()[-1])})
        elif marker in ("##BUILDSESSION", "##END"):
            if text:
                sessions.append(json.loads(text.splitlines()[-1]))
        else:
            raise ValueError(f"unexpected marker {marker!r} in {path}")
    parse_file(path, handler)


def summarise(runs):
    groups = {}
    for r in runs:
        groups.setdefault((r["phase"], r["mode"], r["batch"], r["query"], r["type"]), []).append(r)
    out = {}
    for key, rs in groups.items():
        measured = [r for r in rs if r["kind"] == "measure"]
        detail = [r for r in rs if r["kind"] == "detail"]
        if not measured:
            continue
        ex = c6.stats([r["execution_ms"] for r in measured])
        pl = c6.stats([r["planning_ms"] for r in measured])
        out[key] = {
            "phase": key[0], "mode": key[1], "batch": key[2], "query": key[3], "type": key[4], "runs": ex["n"],
            **{f"exec_{k}": v for k, v in ex.items() if k != "n"},
            **{f"plan_{k}": v for k, v in pl.items() if k != "n"},
            "plan_shape": c6.distinct(r["plan_shape"] for r in measured),
            "indexes_used": c6.distinct(r["indexes_used"] for r in measured),
            "top_plan_rows": c6.distinct(r["top_plan_rows"] for r in measured),
            "top_actual_rows": c6.distinct(r["top_actual_rows"] for r in measured),
            "scan_plan_rows": c6.distinct(r["scan_plan_rows"] for r in measured),
            "scan_actual_rows": c6.distinct(r["scan_actual_rows"] for r in measured),
            "shared_hit_blocks": c6.distinct(r["shared_hit_blocks"] for r in measured),
            "shared_read_blocks": c6.distinct(r["shared_read_blocks"] for r in measured),
            "exact_heap_blocks": c6.distinct(r["exact_heap_blocks"] for r in measured),
            "lossy_heap_blocks": c6.distinct(r["lossy_heap_blocks"] for r in measured),
            "rows_removed_by_index_recheck": c6.distinct(r["rows_removed_by_index_recheck"] for r in measured),
            "planning_shared_hit_blocks": c6.distinct(r["planning_shared_hit_blocks"] for r in measured),
            "jit_present": any(r["jit"] for r in rs),
            "settings": c6.distinct(r["settings"] for r in measured),
            "detail_execution_ms": detail[0]["execution_ms"] if detail else None,
        }
    return out


def rule(a1, b1, a2, b2, label_a, label_b):
    """Step 6A rule on execution time: batch 1 decides; below 0.1 ms the same faster side must be measurable in batch 2."""
    def one(a, b):
        ma, mb = a["exec_median"], b["exec_median"]
        overlap = not (a["exec_p75"] < b["exec_p25"] or b["exec_p75"] < a["exec_p25"])
        slower, faster_value = max(ma, mb), min(ma, mb)
        rel = (slower - faster_value) / slower if slower > 0 else 0.0
        faster = label_a if ma < mb else (label_b if mb < ma else "tie")
        return (not overlap and rel >= c6.MIN_RELATIVE_DIFFERENCE), faster, rel, overlap

    m1, f1, rel1, ov1 = one(a1, b1)
    small = min(a1["exec_median"], b1["exec_median"]) < c6.SMALL_MEDIAN_MS
    m2, f2 = (one(a2, b2)[:2] if a2 and b2 else (False, None))
    if m1 and (not small or (m2 and f2 == f1)):
        result = f"measurable: {f1} faster"
    elif m1 and small:
        result = "not confirmed (below 0.1 ms; second session differs)"
    else:
        result = "no measurable difference"
    pa, pb = a1["plan_median"], b1["plan_median"]
    p_overlap = not (a1["plan_p75"] < b1["plan_p25"] or b1["plan_p75"] < a1["plan_p25"])
    p_rel = (max(pa, pb) - min(pa, pb)) / max(pa, pb) if max(pa, pb) > 0 else 0.0
    p_result = (f"measurable: {label_a if pa < pb else label_b} faster"
                if (not p_overlap and p_rel >= c6.MIN_RELATIVE_DIFFERENCE) else "no measurable difference")
    return {"result": result, "relative_difference": round(rel1, 3), "iqr_overlap": ov1, "below_0_1_ms": small,
            "batch2_faster": f2, "batch2_measurable": m2, "planning_result": p_result}


def comparison_row(kind, statement, pattern, index, label_a, label_b, summary, key_a, key_b):
    a1, b1, a2, b2 = summary.get(key_a(1)), summary.get(key_b(1)), summary.get(key_a(2)), summary.get(key_b(2))
    if not a1 or not b1:
        return None
    return {"comparison": kind, "statement": statement, "pattern": pattern, "index": index, "a": label_a, "b": label_b,
            "a_median_ms": a1["exec_median"], "a_p25_ms": a1["exec_p25"], "a_p75_ms": a1["exec_p75"],
            "b_median_ms": b1["exec_median"], "b_p25_ms": b1["exec_p25"], "b_p75_ms": b1["exec_p75"],
            "b_over_a": round(b1["exec_median"] / a1["exec_median"], 4) if a1["exec_median"] else None,
            "a_median_ms_batch2": a2["exec_median"] if a2 else None, "b_median_ms_batch2": b2["exec_median"] if b2 else None,
            **rule(a1, b1, a2, b2, label_a, label_b),
            "a_plan_median_ms": a1["plan_median"], "b_plan_median_ms": b1["plan_median"],
            "a_plan_shape": a1["plan_shape"], "b_plan_shape": b1["plan_shape"],
            "a_indexes_used": a1["indexes_used"], "b_indexes_used": b1["indexes_used"],
            "a_shared_hit": a1["shared_hit_blocks"], "b_shared_hit": b1["shared_hit_blocks"],
            "a_scan_est_rows": a1["scan_plan_rows"], "b_scan_est_rows": b1["scan_plan_rows"],
            "a_actual_rows": a1["top_actual_rows"], "b_actual_rows": b1["top_actual_rows"],
            "a_exact_heap_blocks": a1["exact_heap_blocks"], "b_exact_heap_blocks": b1["exact_heap_blocks"]}


def write_csv(path, rows):
    keys = []
    for r in rows:
        keys += [k for k in r if k not in keys]
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=keys)
        writer.writeheader()
        writer.writerows(rows)


def fmt(x, digits=3):
    return "-" if x is None or x == "" else f"{float(x):,.{digits}f}"


def expected_rows(qid):
    return CAP[qid][4] if qid in CAP else C6[qid][5]


def cmd_analyze():
    runs, problems, sessions = [], [], {}
    per_statement = c6.WARMUP_ROUNDS + c6.MEASURED_ROUNDS + 1
    index_rows = []
    for phase, spec in PHASES.items():
        if not spec["measure"]:
            continue
        for batch in (1, 2):
            path = ANALYSIS / f"step6d_{spec['key']}_batch{batch}_explain.txt"
            if not path.exists():
                problems.append(f"missing {path.name}")
                continue
            before, sess = len(runs), []
            parse_measurements(path, batch, runs, sess)
            sessions[(phase, batch)] = sess
            expected = (len(spec["head"]) * 2 * per_statement + len(spec["cap"]) * per_statement) * (2 if spec["forced"] else 1)
            if len(runs) - before != expected:
                problems.append(f"{path.name}: {len(runs) - before} executions, expected {expected}")
            header = sess[0] if sess else {}
            indexes = header.get("indexes") or []
            if sorted(ix["index"] for ix in indexes) != sorted(spec["indexes"]):
                problems.append(f"{path.name}: index set {[ix['index'] for ix in indexes]}")
            if any(not (ix["valid"] and ix["ready"]) for ix in indexes):
                problems.append(f"{path.name}: an index is not valid or not ready")
            if header.get("other_active_sessions"):
                problems.append(f"{path.name}: {header['other_active_sessions']} other active sessions")
            if batch == 1:
                for ix in indexes:
                    index_rows.append({"phase": phase, **ix})

    builds, build_sessions = [], []
    for step in BUILD_STEPS:
        path = ANALYSIS / f"step6d_build_{PHASES[step]['key']}.txt"
        if path.exists():
            parse_builds(path, builds, build_sessions)
        else:
            problems.append(f"missing {path.name}")

    if any(r["jit"] for r in runs):
        problems.append("JIT section present in at least one plan")
    for mode in ("default", "forced"):
        settings = {r["settings"] for r in runs if r["mode"] == mode}
        if len(settings) > 1:
            problems.append(f"{mode}: {len(settings)} different EXPLAIN SETTINGS outputs: {sorted(settings)}")

    summary = summarise(runs)
    for key, s in summary.items():
        exp = expected_rows(key[3])
        if "|" in s["top_actual_rows"] or (exp is not None and s["top_actual_rows"] != str(exp)):
            problems.append(f"{key}: actual rows {s['top_actual_rows']}, expected {exp}")
        if key[4] == "json":
            other = summary.get(key[:4] + ("jsonb",))
            if other and other["top_actual_rows"] != s["top_actual_rows"]:
                problems.append(f"{key}: json rows {s['top_actual_rows']} differ from jsonb rows {other['top_actual_rows']}")

    build_rows, groups = [], {}
    for b in builds:
        groups.setdefault((b["step"], b["concept"], b["type"], b["index"]), []).append(b)
    for (step, concept, doc_type, name), bs in groups.items():
        bs = sorted(bs, key=lambda x: x["round"])
        build_rows.append({"step": step, "concept": concept, "type": doc_type, "index": name, "builds": len(bs),
                           "ms_each": "|".join(str(x["ms"]) for x in bs),
                           "median_ms": c6.nearest_rank(sorted(float(x["ms"]) for x in bs), 0.5),
                           "wal_bytes_each": "|".join(str(x["wal_bytes"]) for x in bs),
                           "median_wal_bytes": c6.nearest_rank(sorted(float(x["wal_bytes"]) for x in bs), 0.5),
                           "size_bytes": bs[-1]["size_bytes"], "same_size_every_build": len({x["size_bytes"] for x in bs}) == 1})

    baseline_6c = {}
    baseline_path = ANALYSIS / "step6c_summary.csv"
    if baseline_path.exists():
        with baseline_path.open(encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                if row["batch"] == "1":
                    baseline_6c[(row["query"], row["type"])] = float(row["exec_median"])
    else:
        problems.append("missing step6c_summary.csv (Step 6C baseline)")

    cmp_rows = []

    def add(kind, statement, pattern, index, label_a, label_b, key_a, key_b, extra=None):
        row = comparison_row(kind, statement, pattern, index, label_a, label_b, summary, key_a, key_b)
        if row:
            row.update(extra or {})
            cmp_rows.append(row)

    for q in HEAD:
        pattern, idx = C6[q][2], INDEX_FOR.get(q, "none (control)")
        for phase, mode, kind in (("I-0", "default", "head-to-head I-0 (control, no index)"),
                                  ("I-1", "default", "head-to-head I-1 (identical btree expression indexes)"),
                                  ("I-1", "forced", "head-to-head I-1, enable_seqscan off (diagnostic)")):
            add(kind, q, pattern, idx, "json", "jsonb",
                lambda b, p=phase, m=mode, q=q: (p, m, b, q, "json"), lambda b, p=phase, m=mode, q=q: (p, m, b, q, "jsonb"))
        for t in TYPES:
            add(f"index effect on {t}: I-0 vs I-1", q, pattern, idx, "I-0", "I-1",
                lambda b, q=q, t=t: ("I-0", "default", b, q, t), lambda b, q=q, t=t: ("I-1", "default", b, q, t),
                {"type": t, "step6c_baseline_median_ms": baseline_6c.get((q, t))})
    for cid in CAP_IDS:
        pattern = CAP[cid][1]
        for la, lb, mode, kind in (("I-0", "I-2", "default", "capability jsonb: I-0 vs I-2 (GIN jsonb_ops)"),
                                   ("I-0", "I-3", "default", "capability jsonb: I-0 vs I-3 (GIN jsonb_path_ops)"),
                                   ("I-2", "I-3", "default", "capability jsonb: I-2 vs I-3"),
                                   ("I-2", "I-3", "forced", "capability jsonb: I-2 vs I-3, enable_seqscan off (diagnostic)")):
            add(kind, cid, pattern, "GIN", la, lb,
                lambda b, p=la, m=mode, c=cid: (p, m if p != "I-0" else "default", b, c, "jsonb"),
                lambda b, p=lb, m=mode, c=cid: (p, m, b, c, "jsonb"))

    write_csv(ANALYSIS / "step6d_executions.csv", runs)
    write_csv(ANALYSIS / "step6d_summary.csv", list(summary.values()))
    write_csv(ANALYSIS / "step6d_comparisons.csv", cmp_rows)
    write_csv(ANALYSIS / "step6d_builds.csv", build_rows)
    write_csv(ANALYSIS / "step6d_indexes.csv", index_rows)

    md = ["# Step 6D measurement summary (generated)", "",
          f"Executions parsed: {len(runs)}. Builds parsed: {len(builds)}. Problems: " + ("; ".join(problems) if problems else "none") + ".", "",
          "Sessions: " + "; ".join(f"{p} batch {b}: pid {s[0].get('pid')} {s[0].get('started')} - {s[-1].get('finished')}, other active {s[0].get('other_active_sessions')}"
                                   for (p, b), s in sessions.items() if s), "",
          "## Indexes (catalog at the start of each phase's first session)", "",
          "| Phase | Index | Table | Method | Valid / ready | Size bytes | Definition |", "|---|---|---|---|---|---:|---|"]
    for ix in index_rows:
        if ix["index"] in PKS and ix["phase"] != "I-0":
            continue
        md.append(f"| {ix['phase']} | {ix['index']} | {ix['table']} | {ix['method']} | {ix['valid']} / {ix['ready']} | {ix['size_bytes']:,} | `{ix['definition']}` |")
    md += ["", "## Builds (3 builds per index, the last one kept; server-side time)", "",
           "| Step | Concept | Type | Index | ms per build | Median ms | Median WAL bytes | Size bytes | Same size every build |",
           "|---|---|---|---|---|---:|---:|---:|---|"]
    for b in build_rows:
        md.append(f"| {b['step']} | {b['concept']} | {b['type']} | {b['index']} | {b['ms_each']} | {fmt(b['median_ms'])} | {b['median_wal_bytes']:,.0f} | {b['size_bytes']:,} | {b['same_size_every_build']} |")

    def table(kind, extra_header="", extra=None):
        rows = [r for r in cmp_rows if r["comparison"] == kind]
        if not rows:
            return
        la, lb = rows[0]["a"], rows[0]["b"]
        md.extend(["", f"## {kind}", "",
                   f"| Statement | Index | {la} median [IQR] ms | {lb} median [IQR] ms | {lb}/{la} | Batch 2 {la} / {lb} | Result | Planning ms {la} / {lb} | Planning result | {la} plan (indexes) | {lb} plan (indexes) | Shared hit {la} / {lb} | Scan est. rows {la} / {lb} | Actual rows |{extra_header}",
                   "|---|---|---|---|---:|---|---|---|---|---|---|---|---|---|" + ("---|" if extra_header else "")])
        for r in rows:
            md.append(f"| {r['statement']}{' ' + r['type'] if 'type' in r else ''} | {r['index']} | {fmt(r['a_median_ms'])} [{fmt(r['a_p25_ms'])}-{fmt(r['a_p75_ms'])}] | "
                      f"{fmt(r['b_median_ms'])} [{fmt(r['b_p25_ms'])}-{fmt(r['b_p75_ms'])}] | {fmt(r['b_over_a'], 3)} | "
                      f"{fmt(r['a_median_ms_batch2'])} / {fmt(r['b_median_ms_batch2'])} | {r['result']} | {fmt(r['a_plan_median_ms'])} / {fmt(r['b_plan_median_ms'])} | "
                      f"{r['planning_result']} | {r['a_plan_shape']} ({r['a_indexes_used']}) | {r['b_plan_shape']} ({r['b_indexes_used']}) | "
                      f"{r['a_shared_hit']} / {r['b_shared_hit']} | {r['a_scan_est_rows']} / {r['b_scan_est_rows']} | {r['a_actual_rows']} |"
                      + (f" {extra(r)} |" if extra else ""))

    table("head-to-head I-1 (identical btree expression indexes)")
    table("head-to-head I-0 (control, no index)")
    table("head-to-head I-1, enable_seqscan off (diagnostic)")
    for t in TYPES:
        table(f"index effect on {t}: I-0 vs I-1", " Step 6C I-0 median ms |", lambda r: fmt(r.get("step6c_baseline_median_ms")))
    table("capability jsonb: I-0 vs I-2 (GIN jsonb_ops)")
    table("capability jsonb: I-0 vs I-3 (GIN jsonb_path_ops)")
    table("capability jsonb: I-2 vs I-3")
    table("capability jsonb: I-2 vs I-3, enable_seqscan off (diagnostic)")
    md += ["", "Problems: " + ("; ".join(problems) if problems else "none")]
    (ANALYSIS / "step6d_summary.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print(f"parsed {len(runs)} executions and {len(builds)} builds; wrote step6d_executions.csv, step6d_summary.csv, "
          "step6d_comparisons.csv, step6d_builds.csv, step6d_indexes.csv, step6d_summary.md")
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
