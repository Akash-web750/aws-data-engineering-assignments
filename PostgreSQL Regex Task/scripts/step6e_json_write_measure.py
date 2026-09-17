#!/usr/bin/env python3
"""Step 6E - JSON vs JSONB write/update experiment: measurement SQL, session execution and analysis.

Design: docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md; setup and preflight: scripts/step6e_json_write_experiment.py.

  python -B scripts/step6e_json_write_measure.py generate [--check]      sql/43_measure_json_writes.sql (session 1)
  python -B scripts/step6e_json_write_measure.py generate-session2 --blocks B [B ...]
                                                                          sql/44_measure_json_writes_session2.sql
  python -B scripts/step6e_json_write_measure.py generate-smoke OUT       1 measured round per series, no warm-up/detail
  python -B scripts/step6e_json_write_measure.py run-session SQL STDOUT STDERR [--psql PATH]
  python -B scripts/step6e_json_write_measure.py analyze [--session1 RAW] [--session2 RAW] [--out-dir DIR]

Every measured attempt: reset (drop the table's secondary indexes, TRUNCATE, load, CREATE INDEX of the configuration,
VACUUM (ANALYZE), CHECKPOINT) -> snapshot -> BEGIN; measured statement; COMMIT (psql \\timing) -> snapshot -> correctness
checks (a failure stops the session with SQLSTATE LR018). An attempt flagged in-session (checkpoint, other active
session or autovacuum worker, cluster WAL counters inconsistent with the LSN difference beyond page-header/alignment
tolerance) is repeated once. The analysis additionally applies the design rule (pg_stat_wal bytes vs the statement's own
WAL more than 1 % apart) and excludes such runs.
All writes target schema log_regex_json_write. Standard library only.
"""
import argparse
import csv
import json
import math
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import step6e_json_write_experiment as e6  # noqa: E402

ROOT = e6.ROOT
ANALYSIS = ROOT / "analysis" / "step6"
SQL43 = ROOT / "sql" / "43_measure_json_writes.sql"
SQL44 = ROOT / "sql" / "44_measure_json_writes_session2.sql"
DATABASE = "postgresql_regex_task"
W = e6.W
TYPES = ("json", "jsonb")
TABLE = {t: f"{W}.access_log_{t}_w" for t in TYPES}
PKEY = {t: f"access_log_{t}_w_pkey" for t in TYPES}
CANONICAL_MD5 = e6.CANONICAL_MD5
WARMUP_ROUNDS = 3
MEASURED_ROUNDS = 15
EXPLAIN_MEASURE = "EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, WAL, SETTINGS, SUMMARY, FORMAT JSON)"
EXPLAIN_DETAIL = "EXPLAIN (ANALYZE, TIMING ON, BUFFERS, WAL, SETTINGS, SUMMARY, FORMAT JSON)"
CONFIGS = ["X-0", "X-1", "X-2", "X-3", "X-4"]
DEFS = e6.definition_rows()
ALL_SECONDARY = {t: sorted({r[3] for r in DEFS if r[1] == t}) for t in TYPES}
SETTINGS = ["server_version", "jit", "max_parallel_workers_per_gather", "max_parallel_maintenance_workers", "maintenance_work_mem",
            "work_mem", "TimeZone", "track_io_timing", "track_wal_io_timing", "synchronous_commit", "full_page_writes",
            "wal_compression", "wal_level", "fsync", "wal_sync_method", "wal_buffers", "shared_buffers", "max_wal_size",
            "checkpoint_timeout", "data_checksums", "wal_log_hints", "default_toast_compression", "gin_pending_list_limit",
            "autovacuum", "enable_seqscan"]

# block, statement, json configurations, jsonb configurations (design sections 4-6)
SERIES_SPEC = [
    ("W1", "W1", ["X-0", "X-1"], CONFIGS),
    ("W1b", "W1b", ["X-0", "X-1"], ["X-0", "X-1", "X-4"]),
    ("UA-1", "UA-1", ["X-0", "X-1"], CONFIGS),
    ("UA-2", "UA-2", ["X-0", "X-1"], ["X-0", "X-1", "X-4"]),
    ("UA-3", "UA-3", ["X-0", "X-1"], ["X-0", "X-1", "X-4"]),
]
UPDATE_VARIANT = {"UA-1": ("UA-1", 238), "UA-2": ("UA-2", 238), "UA-3": ("UA-3", 5000)}
UB_MECHANISMS = [("UB-jsonb", "jsonb"), ("UB-json-cast", "json"), ("UB-json-text", "json")]
UB_BLOCKS = [("UB-R238", "R-238", "UA-1", 238), ("UB-R5000", "R-5000", "UA-3", 5000)]
BLOCK_ORDER = ["W1", "W1b", "UA-1", "UA-2", "UA-3", "UB-R238", "UB-R5000"]
TYPE_ORDER = [("json", "jsonb"), ("jsonb", "json"), ("jsonb", "json"), ("json", "jsonb")]   # ABBA by round


def make_series(block, stmt, label, doc_type, config, variant, n_updated, rowset):
    insert = stmt in ("W1", "W1b")
    if block.startswith("UB"):
        group = "separate: update mechanism"
    elif config in ("X-0", "X-1"):
        group = "head-to-head"
    else:
        group = "separate: GIN (jsonb only)"
    return {
        "id": f"{block}/{label}/{config}", "block": block, "stmt": stmt, "label": label, "type": doc_type, "config": config,
        "variant": variant, "n_updated": 0 if insert else n_updated, "n_inserted": {"W1": 5000, "W1b": 250}.get(stmt, 0),
        "reset": {"W1": "empty", "W1b": "4750"}.get(stmt, "full"), "mode": "semantic" if stmt == "UB-json-cast" else "exact",
        "rowset": rowset, "group": group, "insert": insert,
    }


def all_series():
    out = []
    for block, stmt, json_cfgs, jsonb_cfgs in SERIES_SPEC:
        variant, n = UPDATE_VARIANT.get(stmt, ("", 0))
        rowset = {238: "R-238", 5000: "R-5000"}.get(n, "")
        for t, cfgs in (("json", json_cfgs), ("jsonb", jsonb_cfgs)):
            for c in cfgs:
                out.append(make_series(block, stmt, t, t, c, variant, n, rowset))
    for block, rowset, variant, n in UB_BLOCKS:
        for mech, t in UB_MECHANISMS:
            out.append(make_series(block, mech, mech, t, "X-1", variant, n, rowset))
    assert len(out) == 35 and len({s["id"] for s in out}) == 35
    return out


def expected_answers(s):
    if s["insert"]:
        return {"reviewed": 0, "invalid": 238, "w_updated": 0}
    return {"UA-1": {"reviewed": 238, "invalid": 0, "w_updated": 0},
            "UA-2": {"reviewed": 0, "invalid": 238, "w_updated": 238},
            "UA-3": {"reviewed": 5000, "invalid": 0, "w_updated": 0}}[s["variant"]]


def index_ddls(config, doc_type):
    return sorted((r[3], r[6]) for r in DEFS if r[0] == config and r[1] == doc_type)


def block_round(block_series, k):
    if block_series[0]["block"].startswith("UB"):
        return list(block_series) if k % 2 == 0 else list(reversed(block_series))
    configs = [c for c in CONFIGS if any(s["config"] == c for s in block_series)]
    if k % 2:
        configs.reverse()
    out = []
    for c in configs:
        for t in TYPE_ORDER[k % 4]:
            out += [s for s in block_series if s["config"] == c and s["type"] == t]
    return out


def plan_runs(series_list, warmup=WARMUP_ROUNDS, measured=MEASURED_ROUNDS, detail=True):
    runs = []
    for block in BLOCK_ORDER:
        bs = [s for s in series_list if s["block"] == block]
        if not bs:
            continue
        for k in range(warmup + measured):
            kind, rnd = ("warmup", k + 1) if k < warmup else ("measured", k - warmup + 1)
            runs += [{"series": s, "kind": kind, "round": rnd} for s in block_round(bs, k)]
        if detail:
            runs += [{"series": s, "kind": "detail", "round": 1} for s in bs if s["stmt"] != "W1b"]
    return runs


def run_id(run):
    return f"{run['series']['id']}/{run['kind'][0]}{run['round']:02d}"


# ----------------------------------------------------------------------------------------------------------------------
# SQL
# ----------------------------------------------------------------------------------------------------------------------
def measured_statement(s, explain):
    t, table = s["type"], TABLE[s["type"]]
    join = f" FROM {W}.expected_update AS e WHERE e.variant = '{s['variant']}' AND w.log_id = e.log_id;"
    stmt = s["stmt"]
    if stmt == "W1":
        return f"{explain} INSERT INTO {table} (log_id, doc) SELECT log_id, doc_text::{t} FROM {W}.canonical_doc ORDER BY log_id;"
    if stmt in UPDATE_VARIANT:
        return f"{explain} UPDATE {table} AS w SET doc = e.new_text::{t}" + join
    if stmt == "UB-jsonb":
        return f"{explain} UPDATE {table} AS w SET doc = jsonb_set(w.doc, '{{record,record_validity}}', '\"REVIEWED\"')" + join
    if stmt == "UB-json-cast":
        return f"{explain} UPDATE {table} AS w SET doc = jsonb_set(w.doc::jsonb, '{{record,record_validity}}', '\"REVIEWED\"')::json" + join
    if stmt == "UB-json-text":
        return (f"{explain} UPDATE {table} AS w SET doc = regexp_replace(w.doc::text, '\"record_validity\":\"(VALID|INVALID|BROKEN)\"', "
                f"'\"record_validity\":\"REVIEWED\"')::json" + join)
    assert stmt == "W1b"
    return f"""DO $w1b$
DECLARE
    v_ids    integer[];
    v_texts  text[];
    v_t0     timestamptz;
    v_t1     timestamptz;
    v_l0     pg_lsn;
    v_l1     pg_lsn;
BEGIN
    SELECT array_agg(log_id ORDER BY log_id), array_agg(doc_text ORDER BY log_id) INTO v_ids, v_texts
      FROM {W}.canonical_doc WHERE log_id % 20 = 0;
    v_l0 := pg_current_wal_insert_lsn();
    v_t0 := clock_timestamp();
    FOR i IN 1 .. cardinality(v_ids) LOOP
        INSERT INTO {table} (log_id, doc) VALUES (v_ids[i], v_texts[i]::{t});
    END LOOP;
    v_t1 := clock_timestamp();
    v_l1 := pg_current_wal_insert_lsn();
    PERFORM set_config('step6e.w1b', jsonb_build_object('rows', cardinality(v_ids), 'loop_ms', extract(epoch FROM v_t1 - v_t0) * 1000,
                                                        'loop_wal_bytes', pg_wal_lsn_diff(v_l1, v_l0))::text, false);
END
$w1b$;"""


SNAP_TEMPLATE = """PREPARE snap_@TYPE@(jsonb) AS
WITH s AS (
    SELECT jsonb_build_object(
        'ts', clock_timestamp(), 'lsn', pg_current_wal_insert_lsn(), 'redo', (SELECT redo_lsn FROM pg_control_checkpoint()),
        'ckpt_timed', c.num_timed, 'ckpt_requested', c.num_requested, 'ckpt_buffers_written', c.buffers_written,
        'wal_records', w.wal_records, 'wal_fpi', w.wal_fpi, 'wal_bytes', w.wal_bytes, 'wal_buffers_full', w.wal_buffers_full,
        'wal_write', w.wal_write, 'wal_sync', w.wal_sync, 'wal_write_time', w.wal_write_time, 'wal_sync_time', w.wal_sync_time,
        'io_hits', io.hits, 'io_reads', io.reads, 'io_writes', io.writes, 'io_extends', io.extends, 'io_fsyncs', io.fsyncs,
        'io_read_time', io.read_time, 'io_write_time', io.write_time, 'io_extend_time', io.extend_time, 'io_fsync_time', io.fsync_time,
        'others', a.others, 'others_active', a.others_active, 'autovacuum_workers', a.autovacuum_workers,
        'n_tup_ins', t.n_tup_ins, 'n_tup_upd', t.n_tup_upd, 'n_tup_hot_upd', t.n_tup_hot_upd,
        'n_tup_newpage_upd', t.n_tup_newpage_upd, 'n_tup_del', t.n_tup_del, 'n_live_tup', t.n_live_tup, 'n_dead_tup', t.n_dead_tup,
        'heap_bytes', pg_relation_size(r.oid), 'fsm_bytes', pg_relation_size(r.oid, 'fsm'), 'vm_bytes', pg_relation_size(r.oid, 'vm'),
        'toast_bytes', pg_relation_size(r.reltoastrelid), 'toast_index_bytes', pg_indexes_size(r.reltoastrelid),
        'indexes', (SELECT coalesce(jsonb_object_agg(ic.relname, jsonb_build_object('bytes', pg_relation_size(ic.oid),
                        'valid', i.indisvalid AND i.indisready AND i.indislive, 'scans', pg_stat_get_numscans(ic.oid))), '{}'::jsonb)
                    FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid WHERE i.indrelid = r.oid),
        'docs', d.docs, 'docs_compressed', d.compressed, 'docs_external', d.external, 'doc_stored_bytes', d.stored,
        'w1b', nullif(current_setting('step6e.w1b', true), '')::jsonb) AS snap
    FROM pg_class r
    JOIN pg_stat_user_tables t ON t.relid = r.oid
    CROSS JOIN pg_stat_wal w
    CROSS JOIN pg_stat_checkpointer c
    CROSS JOIN (SELECT sum(hits) AS hits, sum(reads) AS reads, sum(writes) AS writes, sum(extends) AS extends, sum(fsyncs) AS fsyncs,
                       sum(read_time) AS read_time, sum(write_time) AS write_time, sum(extend_time) AS extend_time,
                       sum(fsync_time) AS fsync_time
                  FROM pg_stat_io WHERE backend_type = 'client backend' AND object = 'relation') AS io
    CROSS JOIN (SELECT count(*) FILTER (WHERE backend_type = 'client backend') AS others,
                       count(*) FILTER (WHERE backend_type = 'client backend' AND state IS DISTINCT FROM 'idle') AS others_active,
                       count(*) FILTER (WHERE backend_type = 'autovacuum worker') AS autovacuum_workers
                  FROM pg_stat_activity WHERE pid <> pg_backend_pid()) AS a
    CROSS JOIN (SELECT count(*) AS docs, count(*) FILTER (WHERE pg_column_compression(doc) IS NOT NULL) AS compressed,
                       count(*) FILTER (WHERE pg_column_toast_chunk_id(doc) IS NOT NULL) AS external,
                       coalesce(sum(pg_column_size(doc)), 0) AS stored
                  FROM @TABLE@) AS d
    WHERE r.oid = '@TABLE@'::regclass
)
SELECT snap::text AS snap,
       (CASE WHEN $1 IS NULL THEN false
             ELSE snap->>'redo' <> $1->>'redo'
                  OR (snap->>'others_active')::int > 0 OR ($1->>'others_active')::int > 0
                  OR (snap->>'autovacuum_workers')::int > 0 OR ($1->>'autovacuum_workers')::int > 0
                  OR (snap->>'wal_bytes')::numeric - ($1->>'wal_bytes')::numeric
                     - pg_wal_lsn_diff((snap->>'lsn')::pg_lsn, ($1->>'lsn')::pg_lsn)
                     > 0.01 * pg_wal_lsn_diff((snap->>'lsn')::pg_lsn, ($1->>'lsn')::pg_lsn) + 16384
                  OR pg_wal_lsn_diff((snap->>'lsn')::pg_lsn, ($1->>'lsn')::pg_lsn)
                     - ((snap->>'wal_bytes')::numeric - ($1->>'wal_bytes')::numeric)
                     > 0.01 * pg_wal_lsn_diff((snap->>'lsn')::pg_lsn, ($1->>'lsn')::pg_lsn)
                       + 8 * ((snap->>'wal_records')::numeric - ($1->>'wal_records')::numeric) + 16384
        END)::text AS retry
FROM s;"""

CONTENT_TEMPLATE = {
    "json": """PREPARE content_json(text, text) AS
SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM @TABLE@), 'distinct', (SELECT count(DISTINCT log_id) FROM @TABLE@), 'matched', count(*),
    'updated_expected', count(e.log_id),
    'updated_ok', count(*) FILTER (WHERE e.log_id IS NOT NULL
                                     AND CASE $2 WHEN 'semantic' THEN w.doc::jsonb = e.new_text::jsonb ELSE w.doc::text = e.new_text END),
    'untouched_ok', count(*) FILTER (WHERE e.log_id IS NULL AND w.doc::text = c.doc_text),
    'updated_text_differs', count(*) FILTER (WHERE e.log_id IS NOT NULL AND w.doc::text <> e.new_text),
    'updated_stored_text_bytes', coalesce(sum(octet_length(w.doc::text)) FILTER (WHERE e.log_id IS NOT NULL), 0),
    'updated_expected_text_bytes', coalesce(sum(octet_length(e.new_text)) FILTER (WHERE e.log_id IS NOT NULL), 0),
    'md5', md5(string_agg(w.doc::text, chr(10) ORDER BY w.log_id)))::text AS json
FROM @TABLE@ AS w
JOIN @W@.canonical_doc AS c ON c.log_id = w.log_id
LEFT JOIN @W@.expected_update AS e ON e.variant = $1 AND e.log_id = w.log_id;""",
    "jsonb": """PREPARE content_jsonb(text, text) AS
SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM @TABLE@), 'distinct', (SELECT count(DISTINCT log_id) FROM @TABLE@), 'matched', count(*),
    'updated_expected', count(e.log_id),
    'updated_ok', count(*) FILTER (WHERE e.log_id IS NOT NULL AND $2 IS NOT NULL AND w.doc = e.new_text::jsonb),
    'untouched_ok', count(*) FILTER (WHERE e.log_id IS NULL AND w.doc = c.doc_text::jsonb))::text AS json
FROM @TABLE@ AS w
JOIN @W@.canonical_doc AS c ON c.log_id = w.log_id
LEFT JOIN @W@.expected_update AS e ON e.variant = $1 AND e.log_id = w.log_id;""",
}

ANSWERS_TEMPLATE = """PREPARE answers_@TYPE@ AS
SELECT jsonb_build_object(
    'reviewed', (SELECT count(*) FROM @TABLE@ WHERE doc->'record'->>'record_validity' = 'REVIEWED'),
    'invalid', (SELECT count(*) FROM @TABLE@ WHERE doc->'record'->>'record_validity' = 'INVALID'),
    'w_updated', (SELECT count(*) FROM @TABLE@ WHERE doc->'fields'->'action_phrase'->>'source' = 'W-UPDATED')@GIN@)::text AS json;"""
GIN_ANSWERS = """,
    'gin_reviewed', (SELECT count(*) FROM @TABLE@ WHERE doc @> '{"record":{"record_validity":"REVIEWED"}}'),
    'gin_invalid', (SELECT count(*) FROM @TABLE@ WHERE doc @> '{"record":{"record_validity":"INVALID"}}'),
    'gin_w_updated', (SELECT count(*) FROM @TABLE@ WHERE doc @> '{"fields":{"action_phrase":{"source":"W-UPDATED"}}}')"""


def fill(template, doc_type):
    return (template.replace("@GIN@", GIN_ANSWERS if doc_type == "jsonb" else "").replace("@TABLE@", TABLE[doc_type])
            .replace("@TYPE@", doc_type).replace("@W@", W))


def verdict_sql(s, cross):
    t, config, n = s["type"], s["config"], s["n_updated"]
    names = sorted([name for name, _ in index_ddls(config, t)] + [PKEY[t]])
    ans = expected_answers(s)
    conds = ["(c->>'total')::int = 5000", "(c->>'distinct')::int = 5000", "(c->>'matched')::int = 5000",
             f"(c->>'updated_expected')::int = {n}", f"(c->>'updated_ok')::int = {n}", f"(c->>'untouched_ok')::int = {5000 - n}",
             f"(q->>'reviewed')::int = {ans['reviewed']}", f"(q->>'invalid')::int = {ans['invalid']}",
             f"(q->>'w_updated')::int = {ans['w_updated']}",
             "(SELECT string_agg(k, ',' ORDER BY k COLLATE \"C\") FROM jsonb_object_keys(a->'indexes') AS k) = " + e6.lit(",".join(names)),
             "NOT EXISTS (SELECT 1 FROM jsonb_each(a->'indexes') AS x WHERE NOT (x.value->>'valid')::boolean)"]
    if s["insert"]:
        conds.append(f"(a->>'n_tup_ins')::bigint - (b->>'n_tup_ins')::bigint = {s['n_inserted']}")
        if t == "json":
            conds.append(f"c->>'md5' = '{CANONICAL_MD5}'")
    else:
        conds.append(f"(a->>'n_tup_upd')::bigint - (b->>'n_tup_upd')::bigint = {n}")
    if t == "jsonb":
        conds += [f"(q->>'gin_reviewed')::int = {ans['reviewed']}", f"(q->>'gin_invalid')::int = {ans['invalid']}",
                  f"(q->>'gin_w_updated')::int = {ans['w_updated']}"]
    if config != "X-0":
        i1a = f"access_log_{t}_w_i1a_record_validity"
        conds.append(f"(s->>'{i1a}')::bigint - (a->'indexes'->'{i1a}'->>'scans')::bigint >= 2")
    gins = [name for name in names if "_gin_" in name]
    if gins:
        conds.append("(" + " + ".join(f"(s->>'{g}')::bigint - (a->'indexes'->'{g}'->>'scans')::bigint" for g in gins) + ") >= 3")
    if cross:
        conds += ["(k->>'pairs')::int = 5000", "(k->>'equal')::int = 5000"]
    source = ("SELECT :'c_json'::jsonb AS c, :'q_json'::jsonb AS q, :'b_snap'::jsonb AS b, :'a_snap'::jsonb AS a, :'s_json'::jsonb AS s"
              + (", :'k_json'::jsonb AS k" if cross else ""))
    return "SELECT (" + "\n    AND ".join(conds) + f")::text AS ok FROM ({source}) AS v \\gset v_"


def attempt_sql(run, attempt, state, cross):
    s = run["series"]
    t, table = s["type"], TABLE[s["type"]]
    explain = EXPLAIN_DETAIL if run["kind"] == "detail" else EXPLAIN_MEASURE
    meta = json.dumps({"run": run_id(run), "series": s["id"], "block": s["block"], "stmt": s["stmt"], "label": s["label"],
                       "type": t, "config": s["config"], "kind": run["kind"], "round": run["round"], "attempt": attempt},
                      separators=(",", ":"))
    lines = [f"\\qecho @@ATTEMPT {run_id(run)} {attempt}", "EXECUTE reset_probe;"]
    lines += [f"DROP INDEX {W}.{name};" for name in state[t]["indexes"]]
    lines.append(f"TRUNCATE {table};")
    if s["reset"] == "full":
        lines.append(f"INSERT INTO {table} (log_id, doc) SELECT log_id, doc_text::{t} FROM {W}.canonical_doc ORDER BY log_id;")
    elif s["reset"] == "4750":
        lines.append(f"INSERT INTO {table} (log_id, doc) SELECT log_id, doc_text::{t} FROM {W}.canonical_doc WHERE log_id % 20 <> 0 ORDER BY log_id;")
    lines += [ddl + ";" for _name, ddl in index_ddls(s["config"], t)]
    lines += [f"VACUUM (ANALYZE) {table};", "CHECKPOINT;",
              "SELECT set_config('step6e.w1b', '', false) AS w1b \\gset x_",
              "SELECT pg_stat_force_next_flush() \\gset x_",
              f"EXECUTE snap_{t}(NULL) \\gset b_",
              "\\qecho @@TIMED_BEGIN", "\\timing on", "BEGIN;", "\\qecho @@STATEMENT_BEGIN",
              measured_statement(s, explain),
              "\\qecho @@STATEMENT_END", "COMMIT;", "\\timing off", "\\qecho @@TIMED_END",
              "SELECT pg_stat_force_next_flush() \\gset x_",
              f"EXECUTE snap_{t}(:'b_snap') \\gset a_",
              f"EXECUTE content_{t}('{s['variant']}', '{s['mode']}') \\gset c_",
              "SET enable_seqscan = off;", f"EXECUTE answers_{t} \\gset q_", "RESET enable_seqscan;",
              "SELECT pg_stat_force_next_flush() \\gset x_", f"EXECUTE idx_{t} \\gset s_"]
    if cross:
        lines.append("EXECUTE cross_check \\gset k_")
    lines.append(verdict_sql(s, cross))
    lines.append("SELECT '@@RECORD ' || jsonb_build_object('meta', " + e6.lit(meta) + "::jsonb, 'before', :'b_snap'::jsonb, "
                 "'after', :'a_snap'::jsonb, 'content', :'c_json'::jsonb, 'answers', :'q_json'::jsonb, 'idx_scans_after_checks', "
                 ":'s_json'::jsonb, 'cross', " + (":'k_json'::jsonb" if cross else "NULL::jsonb")
                 + ", 'ok', :'v_ok'::boolean, 'retry', :'a_retry'::boolean)::text AS record;")
    lines += ["\\if :v_ok", "\\else", "\\qecho @@CHECK_FAILED",
              "DO $fail$ BEGIN RAISE EXCEPTION 'Step 6E correctness check failed; see the last @@RECORD line' USING ERRCODE = 'LR018'; END $fail$;",
              "\\endif", f"\\qecho @@ATTEMPT_END {run_id(run)} {attempt}"]
    return lines


def session_sql(runs, title):
    names = sorted(ALL_SECONDARY["json"] + ALL_SECONDARY["jsonb"])
    allowed = ", ".join(e6.lit(n) for n in names + [PKEY["json"], PKEY["jsonb"], "canonical_doc_pkey", "expected_update_pkey"])
    head = [
        "-- =============================================================================",
        f"-- Step 6E / {title}",
        "-- =============================================================================",
        "-- GENERATED by scripts/step6e_json_write_measure.py - do not edit by hand. Run by sql/run_step6e_json_writes.ps1:",
        "--   psql -X -q -v ON_ERROR_STOP=1 -d postgresql_regex_task -f <this file>   (stdout = raw measurement output)",
        "-- Writes only schema log_regex_json_write: DROP/CREATE INDEX of the designed configurations, TRUNCATE, INSERT, UPDATE",
        "-- (inside EXPLAIN ANALYZE) and VACUUM (ANALYZE) of access_log_json_w / access_log_jsonb_w; CHECKPOINT (cluster level).",
        f"-- {len(runs)} runs. Ends with both write tables empty and only their primary keys (the preflight state).",
        "-- =============================================================================",
        "\\set ON_ERROR_STOP on", "\\set QUIET on", "\\pset format unaligned", "\\pset tuples_only on", "\\pset footer off",
        "SET client_encoding = 'UTF8';", "SET jit = off;", "SET max_parallel_workers_per_gather = 0;",
        "SET max_parallel_maintenance_workers = 0;", "SET maintenance_work_mem = '64MB';", "SET TimeZone = 'UTC';",
        "SET track_io_timing = on;", "SET track_wal_io_timing = on;",
        "DO $guard$",
        "BEGIN",
        f"    IF (SELECT md5(string_agg(doc_text, chr(10) ORDER BY log_id)) FROM {W}.canonical_doc) IS DISTINCT FROM '{CANONICAL_MD5}'",
        f"       OR (SELECT string_agg(variant || ':' || n, ' ' ORDER BY variant) FROM (SELECT variant, count(*) AS n FROM {W}.expected_update GROUP BY variant) AS s) IS DISTINCT FROM '{e6.VARIANT_COUNTS}'",
        f"       OR (SELECT string_agg(relname, ',' ORDER BY relname COLLATE \"C\") FROM pg_class WHERE relnamespace = '{W}'::regnamespace AND relkind = 'r') IS DISTINCT FROM 'access_log_json_w,access_log_jsonb_w,canonical_doc,expected_update'",
        f"       OR EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = '{W}'::regnamespace AND relkind <> 'r' AND relname NOT IN ({allowed}))",
        "       OR NOT current_setting('is_superuser')::boolean THEN",
        "        RAISE EXCEPTION 'Step 6E measurement refused: staged input or write schema differs from the verified preflight state' USING ERRCODE = 'LR018';",
        "    END IF;",
        "END",
        "$guard$;",
        "SELECT '@@SETTINGS ' || jsonb_object_agg(name, setting || coalesce(' ' || unit, ''))::text FROM pg_settings WHERE name IN ("
        + ", ".join(e6.lit(n) for n in SETTINGS) + ");",
        "PREPARE reset_probe AS SELECT '@@RESET ' || jsonb_build_object('ts', clock_timestamp(), 'lsn', pg_current_wal_insert_lsn(), "
        "'redo', (SELECT redo_lsn FROM pg_control_checkpoint()), 'ckpt_timed', num_timed, 'ckpt_requested', num_requested)::text "
        "FROM pg_stat_checkpointer;",
    ]
    for t in TYPES:
        head += [fill(SNAP_TEMPLATE, t), fill(CONTENT_TEMPLATE[t], t), fill(ANSWERS_TEMPLATE, t),
                 f"PREPARE idx_{t} AS SELECT coalesce(jsonb_object_agg(indexrelname, idx_scan), '{{}}'::jsonb)::text AS json "
                 f"FROM pg_stat_user_indexes WHERE relid = '{TABLE[t]}'::regclass;"]
    head.append(f"PREPARE cross_check AS SELECT jsonb_build_object('pairs', count(*), 'equal', count(*) FILTER (WHERE j.doc::jsonb = b.doc))::text AS json "
                f"FROM {TABLE['json']} AS j FULL JOIN {TABLE['jsonb']} AS b ON b.log_id = j.log_id;")
    cleanup = [f"DROP INDEX IF EXISTS {W}.{n};" for n in names] + [f"TRUNCATE {TABLE['json']}, {TABLE['jsonb']};"]
    body = ["\\qecho @@SESSION_BEGIN"] + cleanup
    state = {t: {"indexes": [], "content": "empty"} for t in TYPES}
    for run in runs:
        s = run["series"]
        t = s["type"]
        other = "jsonb" if t == "json" else "json"
        cross = s["insert"] and state[other]["content"] == "canonical"
        body += attempt_sql(run, 1, state, cross)
        body.append("\\if :a_retry")
        body += attempt_sql(run, 2, {t: {"indexes": [n for n, _ in index_ddls(s["config"], t)]}}, cross)
        body.append("\\endif")
        state[t] = {"indexes": [n for n, _ in index_ddls(s["config"], t)], "content": "canonical" if s["insert"] else s["stmt"]}
    tail = cleanup + ["DEALLOCATE ALL;", "\\qecho @@SESSION_END"]
    return "\n".join(head + body + tail) + "\n"


def write_or_check(path, text, check):
    data = text.encode("ascii")
    if check:
        ok = path.exists() and path.read_bytes().replace(b"\r\n", b"\n") == data
        print(f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}: {'up to date' if ok else 'STALE'}")
        return 0 if ok else 1
    path.write_bytes(data)
    print(f"wrote {path} ({len(data)} bytes)")
    return 0


def run_session(sql_path, stdout_path, stderr_path, psql):
    """Run psql with stdout/stderr captured as bytes (keeps \\timing lines in order); keep the machine awake meanwhile."""
    awake = None
    try:
        import ctypes
        awake = ctypes.windll.kernel32.SetThreadExecutionState
        awake(0x80000000 | 0x00000001)   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    except Exception:
        awake = None
    try:
        with open(stdout_path, "wb") as out, open(stderr_path, "wb") as err:
            code = subprocess.run([psql, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", DATABASE, "-f", str(sql_path)],
                                  stdout=out, stderr=err).returncode
    finally:
        if awake:
            awake(0x80000000)
    print(f"psql exit {code}")
    return code


# ==== analysis ====
TIME_RE = re.compile(r"^Time: ([0-9]+(?:\.[0-9]+)?) ms")
TS_RE = re.compile(r"^(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)(?:\.(\d+))?([+-]\d\d(?::?\d\d)?)$")
TIMING_METRICS = ["exec_ms", "per_row_ms", "planning_ms", "client_total_ms", "client_commit_ms"]
SUMMARY_METRICS = TIMING_METRICS + [
    "explain_wal_records", "explain_wal_bytes", "explain_wal_fpi", "loop_wal_bytes", "lsn_diff_bytes", "commit_and_page_overhead_bytes",
    "stat_wal_records", "stat_wal_fpi", "stat_wal_bytes", "stat_wal_buffers_full", "stat_wal_write", "stat_wal_sync", "stat_wal_sync_ms",
    "shared_hit", "shared_read", "shared_dirtied", "shared_written", "io_writes", "io_extends", "io_fsyncs",
    "rows_inserted", "rows_updated", "hot_updates", "newpage_updates", "live_after", "dead_after",
    "heap_bytes_before", "heap_bytes_after", "heap_growth", "heap_pages_after", "toast_bytes_after", "toast_growth", "toast_index_growth",
    "pkey_growth", "secondary_index_bytes_before", "secondary_index_bytes_after", "secondary_index_growth",
    "docs_compressed_before", "docs_compressed_after", "docs_external_after", "doc_stored_bytes_after",
    "updated_text_differs", "updated_stored_text_bytes", "updated_expected_text_bytes"]
RANGE_COMPARE = ["explain_wal_bytes", "loop_wal_bytes", "lsn_diff_bytes", "stat_wal_records", "stat_wal_fpi", "shared_dirtied",
                 "io_extends", "heap_growth", "toast_growth", "secondary_index_growth", "dead_after", "hot_updates", "docs_compressed_after"]


def lsn_value(text):
    hi, lo = text.split("/")
    return (int(hi, 16) << 32) + int(lo, 16)


def ts_ms(text):
    import datetime
    m = TS_RE.match(text)
    if not m:
        raise ValueError(f"unexpected timestamp {text!r}")
    zone = m.group(4) if ":" in m.group(4) else (m.group(4) + ":00" if len(m.group(4)) == 3 else m.group(4)[:3] + ":" + m.group(4)[3:])
    frac = (m.group(3) or "0").ljust(6, "0")[:6]
    return datetime.datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}.{frac}{zone}").timestamp() * 1000.0


def nearest_rank(sorted_values, p):
    return sorted_values[max(1, math.ceil(p * len(sorted_values))) - 1]


def stats(values):
    v = sorted(values)
    return {"n": len(v), "min": v[0], "p25": nearest_rank(v, 0.25), "median": nearest_rank(v, 0.5),
            "p75": nearest_rank(v, 0.75), "max": v[-1]}


def plan_shape(node):
    label = node["Node Type"]
    if node.get("Index Name"):
        label += " using " + node["Index Name"]
    elif node.get("Relation Name"):
        label += " on " + node["Relation Name"]
    kids = node.get("Plans", [])
    return label + (" [" + "; ".join(plan_shape(k) for k in kids) + "]" if kids else "")


def parse_session(path, session):
    attempts, settings, complete = [], None, False
    cur, section, explain = None, None, []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.rstrip("\r")
        if line.startswith("@@SETTINGS "):
            settings = json.loads(line[len("@@SETTINGS "):])
        elif line == "@@SESSION_END":
            complete = True
        elif line.startswith("@@ATTEMPT_END"):
            attempts.append(cur)
            cur, section = None, None
        elif line.startswith("@@ATTEMPT "):
            _, rid, att = line.split()
            cur = {"session": session, "run": rid, "attempt": int(att), "times": {}, "explain": None, "reset": None, "record": None}
            section = None
        elif cur is None:
            continue
        elif line.startswith("@@RESET "):
            cur["reset"] = json.loads(line[len("@@RESET "):])
        elif line == "@@TIMED_BEGIN":
            section = "begin"
        elif line == "@@STATEMENT_BEGIN":
            section, explain = "stmt", []
        elif line == "@@STATEMENT_END":
            if explain:
                cur["explain"] = json.loads("\n".join(explain))[0]
            section = "commit"
        elif line == "@@TIMED_END":
            section = None
        elif line.startswith("@@RECORD "):
            cur["record"] = json.loads(line[len("@@RECORD "):])
        elif TIME_RE.match(line) and section:
            cur["times"][section] = float(TIME_RE.match(line).group(1))
        elif section == "stmt":
            explain.append(line)
    return attempts, settings, complete


def attempt_rows(attempts, session):
    by_id = {s["id"]: s for s in all_series()}
    rows = []
    for i, a in enumerate(attempts):
        rec = a["record"]
        if rec is None:
            raise SystemExit(f"session {session}: attempt {a['run']} #{a['attempt']} has no @@RECORD line")
        meta, b, af, ex = rec["meta"], rec["before"], rec["after"], a["explain"]
        s = by_id[meta["series"]]
        nxt = attempts[i + 1]["reset"] if i + 1 < len(attempts) else None

        def delta(key):
            return float(af[key]) - float(b[key])

        lsn_diff = lsn_value(af["lsn"]) - lsn_value(b["lsn"])
        top = ex["Plan"] if ex else {}
        w1b = af.get("w1b") or {}
        exec_ms = ex["Execution Time"] if ex else w1b.get("loop_ms")
        times = a["times"]
        client_total = sum(times[k] for k in ("begin", "stmt", "commit")) if len(times) == 3 else None
        gap = ts_ms(af["ts"]) - ts_ms(b["ts"])
        pk = PKEY[s["type"]]
        sec_before = sum(v["bytes"] for k, v in b["indexes"].items() if k != pk)
        sec_after = sum(v["bytes"] for k, v in af["indexes"].items() if k != pk)
        explain_wal = top.get("WAL Bytes")
        flags = []
        if af["redo"] != b["redo"]:
            flags.append("checkpoint-in-run")
        if nxt and nxt["redo"] != af["redo"] and lsn_value(nxt["redo"]) <= lsn_value(af["lsn"]):
            flags.append("checkpoint-started-before-run-end")
        if int(af["others_active"]) > 0 or int(b["others_active"]) > 0:
            flags.append("other-active-session")
        if int(af["autovacuum_workers"]) > 0 or int(b["autovacuum_workers"]) > 0:
            flags.append("autovacuum-worker")
        # in-session form (repeat trigger): cluster WAL counters vs LSN difference, allowing WAL page headers (~0.3 %),
        # record alignment (<= 7 bytes per record) and 2 pages of unrelated background records
        if (delta("wal_bytes") - lsn_diff > 0.01 * lsn_diff + 16384
                or lsn_diff - delta("wal_bytes") > 0.01 * lsn_diff + 8 * delta("wal_records") + 16384):
            flags.append("wal-counter-inconsistent")
        # design rule (section 8): pg_stat_wal delta vs the statement's own WAL (EXPLAIN WAL bytes; W1b: loop LSN difference)
        # plus the commit record; more than 1 % apart means WAL from other activity inside the window
        own_wal = explain_wal if explain_wal is not None else w1b.get("loop_wal_bytes")
        if own_wal and abs(delta("wal_bytes") - float(own_wal)) > 0.01 * float(own_wal):
            flags.append("wal-foreign-activity")
        if client_total is not None and gap - client_total > 2000:
            flags.append("pause")
        content = rec.get("content") or {}
        rows.append({
            "session": session, "run": a["run"], "series": s["id"], "block": s["block"], "stmt": s["stmt"], "label": s["label"],
            "type": s["type"], "config": s["config"], "group": s["group"], "kind": meta["kind"], "round": meta["round"],
            "attempt": a["attempt"], "used": False, "retry_requested": rec["retry"], "flags": "|".join(flags), "check_ok": rec["ok"],
            "exec_ms": exec_ms, "per_row_ms": (exec_ms / 250.0) if s["stmt"] == "W1b" and exec_ms is not None else None,
            "planning_ms": ex.get("Planning Time") if ex else None,
            "client_begin_ms": times.get("begin"), "client_stmt_ms": times.get("stmt"), "client_commit_ms": times.get("commit"),
            "client_total_ms": client_total, "snapshot_gap_ms": round(gap, 3),
            "explain_wal_records": top.get("WAL Records"), "explain_wal_bytes": explain_wal, "explain_wal_fpi": top.get("WAL FPI"),
            "loop_wal_bytes": w1b.get("loop_wal_bytes"), "lsn_diff_bytes": lsn_diff,
            "commit_and_page_overhead_bytes": lsn_diff - (explain_wal if explain_wal is not None else float(w1b.get("loop_wal_bytes", 0))),
            "stat_wal_records": delta("wal_records"), "stat_wal_fpi": delta("wal_fpi"), "stat_wal_bytes": delta("wal_bytes"),
            "stat_wal_buffers_full": delta("wal_buffers_full"), "stat_wal_write": delta("wal_write"), "stat_wal_sync": delta("wal_sync"),
            "stat_wal_write_ms": delta("wal_write_time"), "stat_wal_sync_ms": delta("wal_sync_time"),
            "shared_hit": top.get("Shared Hit Blocks"), "shared_read": top.get("Shared Read Blocks"),
            "shared_dirtied": top.get("Shared Dirtied Blocks"), "shared_written": top.get("Shared Written Blocks"),
            "temp_written": top.get("Temp Written Blocks"), "planning_shared_hit": (ex or {}).get("Planning", {}).get("Shared Hit Blocks"),
            "io_hits": delta("io_hits"), "io_reads": delta("io_reads"), "io_writes": delta("io_writes"), "io_extends": delta("io_extends"),
            "io_fsyncs": delta("io_fsyncs"), "io_write_ms": delta("io_write_time"), "io_extend_ms": delta("io_extend_time"),
            "io_fsync_ms": delta("io_fsync_time"),
            "rows_inserted": delta("n_tup_ins"), "rows_updated": delta("n_tup_upd"), "hot_updates": delta("n_tup_hot_upd"),
            "newpage_updates": delta("n_tup_newpage_upd"), "live_after": af["n_live_tup"], "dead_after": af["n_dead_tup"],
            "heap_bytes_before": b["heap_bytes"], "heap_bytes_after": af["heap_bytes"], "heap_growth": delta("heap_bytes"),
            "heap_pages_after": af["heap_bytes"] // 8192, "fsm_bytes_after": af["fsm_bytes"], "vm_bytes_after": af["vm_bytes"],
            "toast_bytes_before": b["toast_bytes"], "toast_bytes_after": af["toast_bytes"], "toast_growth": delta("toast_bytes"),
            "toast_index_growth": delta("toast_index_bytes"),
            "pkey_growth": af["indexes"][pk]["bytes"] - b["indexes"][pk]["bytes"],
            "secondary_index_bytes_before": sec_before, "secondary_index_bytes_after": sec_after, "secondary_index_growth": sec_after - sec_before,
            "index_bytes_after": json.dumps({k: v["bytes"] for k, v in sorted(af["indexes"].items())}, separators=(",", ":")),
            "docs_compressed_before": b["docs_compressed"], "docs_compressed_after": af["docs_compressed"],
            "docs_external_before": b["docs_external"], "docs_external_after": af["docs_external"],
            "doc_stored_bytes_before": b["doc_stored_bytes"], "doc_stored_bytes_after": af["doc_stored_bytes"],
            "updated_text_differs": content.get("updated_text_differs"), "updated_stored_text_bytes": content.get("updated_stored_text_bytes"),
            "updated_expected_text_bytes": content.get("updated_expected_text_bytes"),
            "extra_checkpoints_in_cycle": (int(nxt["ckpt_timed"]) + int(nxt["ckpt_requested"]) - int(a["reset"]["ckpt_timed"])
                                           - int(a["reset"]["ckpt_requested"]) - 1) if nxt else None,
            "others_connected": af["others"], "plan_shape": plan_shape(top) if ex else "DO loop (250 single-row INSERT)",
        })
    last = {}
    for r in rows:
        last[(r["session"], r["run"])] = r
    for r in last.values():
        r["used"] = True
    return rows


def summarise(rows):
    out = {}
    for sid in sorted({r["session"] for r in rows}):
        for s in all_series():
            mine = [r for r in rows if r["session"] == sid and r["series"] == s["id"]]
            used = [r for r in mine if r["kind"] == "measured" and r["used"]]
            if not used:
                continue
            clean = [r for r in used if not r["flags"]]
            entry = {"session": sid, "series": s["id"], "block": s["block"], "stmt": s["stmt"], "label": s["label"], "type": s["type"],
                     "config": s["config"], "group": s["group"], "measured_runs": len(used), "clean_runs": len(clean),
                     "excluded_flagged": len(used) - len(clean),
                     "repeated_attempts": sum(1 for r in mine if r["attempt"] == 2),
                     "flagged_attempts_all_kinds": sum(1 for r in mine if r["flags"]),
                     "checks_ok": all(r["check_ok"] for r in mine), "attempts_checked": len(mine),
                     "plan_shapes": "|".join(sorted({r["plan_shape"] for r in used})), "_stats": {}}
            for m in SUMMARY_METRICS:
                vals = [float(r[m]) for r in clean if r[m] not in (None, "")]
                if not vals:
                    continue
                st = stats(vals)
                entry["_stats"][m] = st
                for k in (("median", "p25", "p75", "min", "max") if m in TIMING_METRICS else ("median", "min", "max")):
                    entry[f"{m}_{k}"] = st[k]
            out[(sid, s["id"])] = entry
    return out


def comparison_pairs():
    pairs = []
    for block, _stmt, json_cfgs, jsonb_cfgs in SERIES_SPEC:
        for c in ("X-0", "X-1"):
            pairs.append(("head-to-head json vs jsonb", block, f"{block}/json/{c}", f"{block}/jsonb/{c}"))
    for block, _stmt, json_cfgs, jsonb_cfgs in SERIES_SPEC:
        for t in TYPES:
            pairs.append((f"index effect {t}: X-0 vs X-1", block, f"{block}/{t}/X-0", f"{block}/{t}/X-1"))
        for c in jsonb_cfgs:
            if c in ("X-2", "X-3", "X-4"):
                pairs.append((f"GIN effect jsonb only: X-1 vs {c}", block, f"{block}/jsonb/X-1", f"{block}/jsonb/{c}"))
    for block, *_ in UB_BLOCKS:
        pairs.append(("update mechanism json (separate): text regexp vs jsonb_set cast", block,
                      f"{block}/UB-json-text/X-1", f"{block}/UB-json-cast/X-1"))
        pairs.append(("update mechanism (separate, not a type verdict): json text regexp vs jsonb jsonb_set", block,
                      f"{block}/UB-json-text/X-1", f"{block}/UB-jsonb/X-1"))
    return pairs


def time_rule(a, b):
    separated = a["p75"] < b["p25"] or b["p75"] < a["p25"]
    lo, hi = sorted([a["median"], b["median"]])
    return separated and hi > 0 and lo <= 0.9 * hi, ("A" if a["median"] < b["median"] else "B")


def compare(summary):
    out = []
    sessions = sorted({k[0] for k in summary})
    for kind, block, a_id, b_id in comparison_pairs():
        if ("1", a_id) not in summary or ("1", b_id) not in summary:
            continue
        a_lab, b_lab = a_id.split("/", 1)[1], b_id.split("/", 1)[1]
        for metric in ["exec_ms", "client_total_ms"] + RANGE_COMPARE:
            sa, sb = summary[("1", a_id)]["_stats"].get(metric), summary[("1", b_id)]["_stats"].get(metric)
            if not sa or not sb:
                continue
            row = {"comparison": kind, "block": block, "a": a_id, "b": b_id, "metric": metric,
                   "a_median": sa["median"], "a_p25": sa["p25"], "a_p75": sa["p75"], "a_min": sa["min"], "a_max": sa["max"],
                   "b_median": sb["median"], "b_p25": sb["p25"], "b_p75": sb["p75"], "b_min": sb["min"], "b_max": sb["max"],
                   "ratio_b_over_a": (sb["median"] / sa["median"]) if sa["median"] else None}
            if metric in ("exec_ms", "client_total_ms"):
                ok, lower = time_rule(sa, sb)
                per_row = [summary[("1", x)]["_stats"].get("per_row_ms") for x in (a_id, b_id)]
                small = min(sa["median"], sb["median"]) < 0.1 or any(p and p["median"] < 0.1 for p in per_row)
                result = f"measurable: {a_lab if lower == 'A' else b_lab} faster" if ok else "not measurable"
                row["rule"] = "Step 6A: IQR non-overlap and >= 10 % median difference"
                if small:
                    if "2" in sessions and ("2", a_id) in summary and ("2", b_id) in summary:
                        ok2, lower2 = time_rule(summary[("2", a_id)]["_stats"][metric], summary[("2", b_id)]["_stats"][metric])
                        same = (ok2 == ok) and (not ok or lower2 == lower)
                        result += "; below 0.1 ms: " + ("same result in session 2" if same else "NOT confirmed in session 2 -> not measurable")
                        if not same:
                            result = "not measurable (session 1 and session 2 disagree)"
                    else:
                        result += "; below 0.1 ms: session 2 required"
            else:
                row["rule"] = "min-max ranges non-overlapping"
                if sa["max"] < sb["min"]:
                    result = f"consistent: {a_lab} lower"
                elif sb["max"] < sa["min"]:
                    result = f"consistent: {b_lab} lower"
                elif sa["min"] == sa["max"] == sb["min"] == sb["max"]:
                    result = "identical"
                else:
                    result = "overlapping"
            row["result"] = result
            out.append(row)
    return out


def fmt(v, digits=3):
    if v is None or v == "":
        return ""
    if isinstance(v, float) and not v.is_integer():
        return f"{v:.{digits}f}"
    return f"{int(v):,}" if isinstance(v, (int, float)) else str(v)


def write_csv(path, rows, fields=None):
    fields = fields or [k for k in rows[0] if not k.startswith("_")]
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k) for k in fields})


def markdown(rows, summary, comps, settings):
    L = ["# Step 6E - write/update measurement summary (generated)", "",
         "Generated by `scripts/step6e_json_write_measure.py analyze`. Medians of clean measured runs; IQR = nearest-rank p25-p75.", ""]
    for sid in sorted(settings):
        used = [r for r in rows if r["session"] == sid and r["used"]]
        L += [f"## Session {sid}: accounting", "",
              f"- attempts: {sum(1 for r in rows if r['session'] == sid)}; runs: {len(used)}; repeated attempts: "
              f"{sum(1 for r in rows if r['session'] == sid and r['attempt'] == 2)}; correctness checks failed: "
              f"{sum(1 for r in rows if r['session'] == sid and not r['check_ok'])}",
              f"- used runs still flagged (excluded from statistics): {sum(1 for r in used if r['flags'])}"
              + "".join(f"\n  - {r['run']}: {r['flags']}" for r in used if r["flags"]), ""]
    L += ["## Series (session 1)", "",
          "| series | group | clean/measured | exec ms median [IQR] | client total ms | EXPLAIN/loop WAL bytes | WAL FPI (stat) | dirtied | heap growth | TOAST growth | sec. index growth | dead after | HOT | compressed docs after |",
          "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for (sid, sidx), e in sorted(summary.items(), key=lambda kv: (kv[0][0], [s["id"] for s in all_series()].index(kv[0][1]))):
        if sid != "1":
            continue
        g = lambda m, k="median": fmt(e.get(f"{m}_{k}"))
        wal = g("explain_wal_bytes") or g("loop_wal_bytes")
        L.append(f"| {sidx} | {e['group']} | {e['clean_runs']}/{e['measured_runs']} | {g('exec_ms')} [{g('exec_ms', 'p25')}-{g('exec_ms', 'p75')}]"
                 + (f" ({g('per_row_ms')} per row)" if e.get("per_row_ms_median") is not None else "")
                 + f" | {g('client_total_ms')} | {wal} | {g('stat_wal_fpi')} | {g('shared_dirtied')} | {g('heap_growth')} | {g('toast_growth')}"
                 f" | {g('secondary_index_growth')} | {g('dead_after')} | {g('hot_updates')} | {g('docs_compressed_after')} |")
    for title, prefix in [("Head-to-head json vs jsonb", "head-to-head"), ("Index effect", "index effect"), ("GIN effect (jsonb only)", "GIN effect"),
                          ("Update mechanisms (separate)", "update mechanism")]:
        L += ["", f"## {title}", "", "| block | A | B | metric | A median | B median | B/A | result |", "|---|---|---|---|---|---|---|---|"]
        for c in comps:
            if c["comparison"].startswith(prefix):
                L.append(f"| {c['block']} | {c['a']} | {c['b']} | {c['metric']} | {fmt(c['a_median'])} | {fmt(c['b_median'])} | "
                         f"{fmt(c['ratio_b_over_a'])} | {c['result']} |")
    L += ["", "## Settings", ""]
    for sid, st in sorted(settings.items()):
        L.append(f"- session {sid}: " + ", ".join(f"{k}={v}" for k, v in sorted(st.items())))
    return "\n".join(L) + "\n"


def analyze(args):
    out_dir = pathlib.Path(args.out_dir)
    sessions = [("1", pathlib.Path(args.session1))] + ([("2", pathlib.Path(args.session2))] if args.session2 else [])
    rows, settings = [], {}
    for sid, path in sessions:
        attempts, st, complete = parse_session(path, sid)
        if not complete:
            raise SystemExit(f"session {sid}: @@SESSION_END missing in {path} (incomplete session)")
        settings[sid] = st
        rows += attempt_rows(attempts, sid)
    failed = [r["run"] for r in rows if not r["check_ok"]]
    if failed:
        raise SystemExit(f"correctness check failed: {failed[:5]}")
    summary = summarise(rows)
    comps = compare(summary)
    p = args.prefix
    write_csv(out_dir / f"{p}_attempts.csv", rows)
    srows = list(summary.values())
    fields = ["session", "series", "block", "stmt", "label", "type", "config", "group", "measured_runs", "clean_runs", "excluded_flagged",
              "repeated_attempts", "flagged_attempts_all_kinds", "checks_ok", "attempts_checked", "plan_shapes"]
    fields += [f"{m}_{k}" for m in SUMMARY_METRICS for k in (("median", "p25", "p75", "min", "max") if m in TIMING_METRICS else ("median", "min", "max"))]
    write_csv(out_dir / f"{p}_summary.csv", srows, fields)
    write_csv(out_dir / f"{p}_comparisons.csv", comps)
    (out_dir / f"{p}_summary.md").write_text(markdown(rows, summary, comps, settings), encoding="utf-8")
    below = sorted({e["block"] for (sid, _), e in summary.items() if sid == "1" and (
        e["_stats"].get("exec_ms", {}).get("median", 1) < 0.1 or e["_stats"].get("per_row_ms", {}).get("median", 1) < 0.1)},
        key=BLOCK_ORDER.index)
    (out_dir / f"{p}_session2_blocks.txt").write_text(" ".join(below) + "\n", encoding="ascii")
    used = [r for r in rows if r["used"]]
    print(f"attempts {len(rows)}, runs {len(used)}, repeated {sum(1 for r in rows if r['attempt'] == 2)}, "
          f"used runs flagged {sum(1 for r in used if r['flags'])}, checks failed 0, series {len(summary)}, comparisons {len(comps)}")
    print("SESSION2_BLOCKS: " + (" ".join(below) if below else "none"))
    return 0


STATIC_PATTERNS = [re.compile(p) for p in (
    r"^DROP INDEX (IF EXISTS )?log_regex_json_write\.access_log_jsonb?_w_i[0-9a-z_]+;$",
    r"^TRUNCATE log_regex_json_write\.access_log_jsonb?_w(, log_regex_json_write\.access_log_jsonb?_w)?;$",
    r"^INSERT INTO log_regex_json_write\.access_log_(jsonb?)_w \(log_id, doc\) SELECT log_id, doc_text::\1 FROM log_regex_json_write\.canonical_doc( WHERE log_id % 20 <> 0)? ORDER BY log_id;$",
    r"^INSERT INTO log_regex_json_write\.access_log_(jsonb?)_w \(log_id, doc\) VALUES \(v_ids\[i\], v_texts\[i\]::\1\);$",
    r"^VACUUM \(ANALYZE\) log_regex_json_write\.access_log_jsonb?_w;$",
    r"^CHECKPOINT;$",
    r"^EXPLAIN \(ANALYZE, TIMING (OFF|ON), BUFFERS, WAL, SETTINGS, SUMMARY, FORMAT JSON\) INSERT INTO log_regex_json_write\.access_log_(jsonb?)_w \(log_id, doc\) SELECT log_id, doc_text::\2 FROM log_regex_json_write\.canonical_doc ORDER BY log_id;$",
    r"^EXPLAIN \(ANALYZE, TIMING (OFF|ON), BUFFERS, WAL, SETTINGS, SUMMARY, FORMAT JSON\) UPDATE log_regex_json_write\.access_log_jsonb?_w AS w SET doc = [^;]+ FROM log_regex_json_write\.expected_update AS e WHERE e\.variant = 'UA-[123]' AND w\.log_id = e\.log_id;$",
    r"^SET (client_encoding = 'UTF8'|jit = off|max_parallel_workers_per_gather = 0|max_parallel_maintenance_workers = 0|maintenance_work_mem = '64MB'|TimeZone = 'UTC'|track_io_timing = on|track_wal_io_timing = on|enable_seqscan = off);$",
    r"^RESET enable_seqscan;$",
    r"^EXECUTE (reset_probe;|(snap_jsonb?\((NULL|:'b_snap')\)|content_jsonb?\('(UA-[123])?', '(exact|semantic)'\)|answers_jsonb?|idx_jsonb?|cross_check) \\gset [a-z]_)$",
    r"^PREPARE (reset_probe|snap_jsonb?|content_jsonb?|answers_jsonb?|idx_jsonb?|cross_check)\b",
    r"^DO \$(guard|w1b)\$$",
    r"^DO \$fail\$ BEGIN RAISE EXCEPTION 'Step 6E correctness check failed; see the last @@RECORD line' USING ERRCODE = 'LR018'; END \$fail\$;$",
    r"^(BEGIN;?|COMMIT;|DEALLOCATE ALL;)$",
)]
STATEMENT_KEYWORDS = re.compile(r"^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|COPY|VACUUM|ANALYZE|GRANT|REVOKE|COMMENT|REINDEX|CLUSTER|"
                                r"CHECKPOINT|EXPLAIN|MERGE|LOCK|SECURITY|REFRESH|IMPORT|CALL|DO|SET|RESET|EXECUTE|PREPARE|DEALLOCATE|BEGIN|"
                                r"COMMIT|ROLLBACK|START|SAVEPOINT|RELEASE|DISCARD|LISTEN|NOTIFY|LOAD)\b", re.IGNORECASE)


def static_check(path):
    """Every statement line of a generated session file must be one of the designed forms; no reference to other schemas."""
    text = pathlib.Path(path).read_text(encoding="ascii")
    code = [line for line in text.split("\n") if not line.lstrip().startswith("--")]
    designed = {r[6] + ";" for r in DEFS}
    counts, bad = {}, []
    for line in code:
        m = STATEMENT_KEYWORDS.match(line)
        if not m:
            continue
        s = line.strip()
        key = m.group(1).upper()
        counts[key] = counts.get(key, 0) + 1
        if s not in designed and not any(p.match(s) for p in STATIC_PATTERNS):
            bad.append(s[:160])
    refs = [line[:160] for line in code if re.search(r"\blog_regex\.|\blog_regex_json\.|raw_access_logs|expected_fields|access_log_flat", line)]
    creates = sorted({line.strip() for line in code if line.strip().startswith("CREATE ")})
    ok = not bad and not refs and set(creates) <= designed and counts.get("DELETE", 0) == 0 and counts.get("ALTER", 0) == 0
    print(json.dumps({"file": str(path), "ok": ok, "statement_lines": sum(counts.values()), "by_keyword": counts,
                      "outside_design": len(bad), "first_outside_design": bad[:3], "references_to_other_schemas": len(refs),
                      "distinct_create_index": len(creates)}, sort_keys=True))
    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--check", action="store_true")
    g2 = sub.add_parser("generate-session2")
    g2.add_argument("--blocks", nargs="+", required=True, choices=BLOCK_ORDER)
    g2.add_argument("--check", action="store_true")
    sm = sub.add_parser("generate-smoke")
    sm.add_argument("out")
    sc = sub.add_parser("static-check")
    sc.add_argument("sql")
    rs = sub.add_parser("run-session")
    rs.add_argument("sql")
    rs.add_argument("stdout")
    rs.add_argument("stderr")
    rs.add_argument("--psql", default=r"C:\Program Files\PostgreSQL\17\bin\psql.exe")
    an = sub.add_parser("analyze")
    an.add_argument("--session1", default=str(ANALYSIS / "step6e_session1_raw.txt"))
    an.add_argument("--session2", default=None)
    an.add_argument("--out-dir", default=str(ANALYSIS))
    an.add_argument("--prefix", default="step6e")
    args = parser.parse_args()
    series = all_series()
    if args.command == "generate":
        return write_or_check(SQL43, session_sql(plan_runs(series), "43 - measurement session 1 (all 35 series)"), args.check)
    if args.command == "generate-session2":
        chosen = [s for s in series if s["block"] in args.blocks]
        return write_or_check(SQL44, session_sql(plan_runs(chosen, detail=False),
                                                 "44 - measurement session 2 (blocks " + ", ".join(args.blocks) + ")"), args.check)
    if args.command == "generate-smoke":
        return write_or_check(pathlib.Path(args.out), session_sql(plan_runs(series, warmup=0, measured=1, detail=False), "smoke test"), False)
    if args.command == "static-check":
        return static_check(args.sql)
    if args.command == "run-session":
        return 0 if run_session(args.sql, args.stdout, args.stderr, args.psql) == 0 else 1
    return analyze(args)


if __name__ == "__main__":
    sys.exit(main())
