#!/usr/bin/env python3
"""Step 6E - JSON vs JSONB write/update experiment: setup/staging SQL and preflight verification SQL.

Design: docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md (approved with safeguards).

  python -B scripts/step6e_json_write_experiment.py generate [--check]
      writes (or compares) sql/41_create_json_write_experiment.sql and sql/42_preflight_json_write_experiment.sql

The index configurations X-1 ... X-4 are derived from the Step 6D generator (imported unchanged); every generated
CREATE INDEX statement is asserted to be the Step 6D statement with only the table and index names changed.
The measurement SQL (resets, measured writes) is not part of this file yet. Standard library only.
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import step6d_json_index_experiment as d6  # noqa: E402

ROOT = d6.ROOT
SQL41 = ROOT / "sql" / "41_create_json_write_experiment.sql"
SQL42 = ROOT / "sql" / "42_preflight_json_write_experiment.sql"
W = "log_regex_json_write"
TYPES = ("json", "jsonb")
WTABLES = {t: f"{W}.access_log_{t}_w" for t in TYPES}
CANONICAL_MD5 = "aeaef32371fa8143c088d4fdce9f6e0d"   # Step 6B canonical input (table comments, docs/Step6B)
CANONICAL_BYTES = 8416033
CANONICAL_CHARS = 8415454
INVALID_ROWS = 238
OTHER_CLIENT_SESSIONS = 4
WRITE_RELATIONS = ("i:access_log_json_w_pkey i:access_log_jsonb_w_pkey i:canonical_doc_pkey i:expected_update_pkey "
                   "r:access_log_json_w r:access_log_jsonb_w r:canonical_doc r:expected_update")
SOURCE_INDEXES = sorted(d6.PHASES["final"]["indexes"])
CONFIG_COUNTS = "X-1/json:5 X-1/jsonb:5 X-2/jsonb:6 X-3/jsonb:6 X-4/jsonb:7"
VARIANT_COUNTS = f"UA-1:{INVALID_ROWS} UA-2:{INVALID_ROWS} UA-3:5000"
BS = object()   # a backslash, emitted as chr(92) so the SQL files contain none

assert d6.TABLES == {"json": "log_regex_json.access_log_json", "jsonb": "log_regex_json.access_log_jsonb"}
assert tuple(d6.TYPES) == TYPES


def lit(text):
    return "'" + text.replace("'", "''") + "'"


def concat(*parts):
    return " || ".join("chr(92)" if p is BS else lit(p) for p in parts)


def norm(expr):
    """Index/constraint definition with schema-qualified experiment table names -> TABLE and index name prefixes -> IDX_."""
    return (f"regexp_replace(regexp_replace({expr}, 'log_regex_json(_write)?[.]access_log_jsonb?(_w)?', 'TABLE', 'g'), "
            "'access_log_jsonb?(_w)?_', 'IDX_', 'g')")


# ----------------------------------------------------------------------------------------------------------------------
# design: index configurations (section 4) and update variants (section 6)
# ----------------------------------------------------------------------------------------------------------------------
def definition_rows():
    """(config_id, doc_type, concept, index_name, method, opclass, ddl, source_index); X-0 = primary key only (no rows)."""
    rows = []

    def btree(config, t):
        for concept, suffix, expr, _desc, opclass, _stmts in d6.EXPRESSION_INDEXES:
            source = d6.index_name(t, suffix)
            name = f"access_log_{t}_w_{suffix}"
            ddl = f"CREATE INDEX {name} ON {WTABLES[t]} (({expr}))"
            assert ddl.replace(WTABLES[t], d6.TABLES[t]).replace(name, source) == d6.create_expression_index(t, suffix, expr)
            rows.append((config, t, concept, name, "btree", opclass, ddl, source))

    def gin(config, position):
        concept, source, opclass, _desc = d6.GIN_INDEXES[position]
        name = source.replace("access_log_jsonb_", "access_log_jsonb_w_", 1)
        ddl = f"CREATE INDEX {name} ON {WTABLES['jsonb']} USING gin (doc {opclass})"
        assert ddl.replace(WTABLES["jsonb"], d6.TABLES["jsonb"]).replace(name, source) == d6.create_gin_index(source, opclass)
        rows.append((config, "jsonb", concept, name, "gin", opclass, ddl, source))

    btree("X-1", "json")
    btree("X-1", "jsonb")
    btree("X-2", "jsonb")
    gin("X-2", 0)
    btree("X-3", "jsonb")
    gin("X-3", 1)
    btree("X-4", "jsonb")
    gin("X-4", 0)
    gin("X-4", 1)
    # X-4 is the current Step 6D index set of access_log_jsonb; X-1 json is that of access_log_json
    final = [n for n in d6.PHASES["final"]["indexes"] if n not in d6.PKS]
    assert sorted(r[7] for r in rows if r[0] == "X-4") == sorted(n for n in final if n.startswith("access_log_jsonb_"))
    assert sorted(r[7] for r in rows if r[0] == "X-1" and r[1] == "json") == sorted(n for n in final if n.startswith("access_log_json_"))
    assert len(rows) == 29
    return rows


JSTR = ("(?:null|", '"(?:[^"', BS, BS, "]|", BS, BS, '.)*"', ")")   # JSON string (escapes allowed) or null
# variant, row set, path, new value, pattern parts, replacement parts
VARIANTS = [
    ("UA-1", "R-238", "{record,record_validity}", '"REVIEWED"',
     ('"record_validity":"INVALID"',), ('"record_validity":"REVIEWED"',)),
    ("UA-2", "R-238", "{fields,action_phrase,source}", '"W-UPDATED"',
     ('("action_phrase":[{]"value":',) + JSTR + (',"validity":"[A-Z_]+","start_pos":(?:null|[0-9]+),"source":)',) + JSTR,
     (BS, '1"W-UPDATED"')),
    ("UA-3", "R-5000", "{record,record_validity}", '"REVIEWED"',
     ('"record_validity":"(VALID|INVALID|BROKEN)"',), ('"record_validity":"REVIEWED"',)),
]
VARIANT_SUMMARY = ('UA-1:R-238:record.record_validity="REVIEWED" UA-2:R-238:fields.action_phrase.source="W-UPDATED" '
                   'UA-3:R-5000:record.record_validity="REVIEWED"')


def design_index_cte():
    rows = ",\n".join("        (" + ", ".join(lit(v) for v in r) + ")" for r in definition_rows())
    return ("design_index (config_id, doc_type, concept, index_name, method, opclass, ddl, source_index) AS (VALUES\n"
            f"{rows}\n    )")


def design_variant_cte():
    rows = ",\n".join(
        f"        ({lit(v)}, {lit(rs)}, {lit(path)}::text[], {lit(value)}::jsonb, {concat(*pattern)}, {concat(*replacement)})"
        for v, rs, path, value, pattern, replacement in VARIANTS)
    return f"design_variant (variant, row_set, path, new_value, pattern, replacement) AS (VALUES\n{rows}\n    )"


def sql(text):
    return text.replace("@W@", W)


# ----------------------------------------------------------------------------------------------------------------------
# sql/41 - setup and staging
# ----------------------------------------------------------------------------------------------------------------------
def generate_sql41():
    return sql(f"""-- =============================================================================
-- Step 6E / 41 - Write/update experiment: isolated schema, staged input and expected update documents
-- =============================================================================
-- GENERATED by scripts/step6e_json_write_experiment.py - do not edit by hand.
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/41_create_json_write_experiment.sql
--
-- One transaction, confined to schema @W@ (docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md section 3).
-- Creates exactly the four designed objects:
--   canonical_doc        the 5,000 canonical texts, read once from log_regex_json.access_log_json (doc::text)
--   expected_update      expected document text after UA-1, UA-2 and UA-3 (one regexp substitution per document)
--   access_log_json_w    empty copy of the Step 6B json table definition (loaded only by the measurement resets)
--   access_log_jsonb_w   empty copy of the Step 6B jsonb table definition
-- No secondary index: X-0 is the primary key only; X-1 ... X-4 are created by the measurement resets from the
-- definitions in the generator (verified by sql/42).
--
-- Safety:
--   * refuses (SQLSTATE LR016) if schema @W@ exists, or if the Step 6B table comment does not record the
--     canonical md5 {CANONICAL_MD5}
--   * the only read of existing table data is the single SELECT of log_regex_json.access_log_json into canonical_doc
--   * gate before COMMIT (LR016): 5,000 staged texts, md5 {CANONICAL_MD5}, {CANONICAL_BYTES} bytes, {CANONICAL_CHARS} characters, JSON
--     objects with unique keys; expected updates {VARIANT_COUNTS}, each source document with exactly one pattern match,
--     each expected document a unique-key JSON object equal to jsonb_set of the source (two independent derivations)
--   * never writes log_regex, log_regex_json, raw data, parser data or the Step 6B/6D tables and indexes
-- =============================================================================

\\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

SET LOCAL lock_timeout = '10s';

-- BEGIN setup guard (catalog only)
DO $guard$
BEGIN
    IF to_regnamespace('@W@') IS NOT NULL THEN
        RAISE EXCEPTION 'sql/41 refused: schema @W@ already exists; this script never replaces objects'
            USING ERRCODE = 'LR016', HINT = 'Verify the existing objects with sql/42_preflight_json_write_experiment.sql.';
    END IF;
    IF to_regclass('log_regex_json.access_log_json') IS NULL
       OR obj_description('log_regex_json.access_log_json'::regclass, 'pg_class') NOT LIKE '%md5 {CANONICAL_MD5} %' THEN
        RAISE EXCEPTION 'sql/41 refused: the Step 6B json table is missing or does not record the canonical md5'
            USING ERRCODE = 'LR016';
    END IF;
END
$guard$;
-- END setup guard

CREATE SCHEMA @W@;

CREATE TABLE @W@.canonical_doc (
    log_id    integer NOT NULL,
    doc_text  text    NOT NULL,
    CONSTRAINT canonical_doc_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);

CREATE TABLE @W@.expected_update (
    variant   text    NOT NULL,
    log_id    integer NOT NULL,
    new_text  text    NOT NULL,
    CONSTRAINT expected_update_pkey PRIMARY KEY (variant, log_id)
) WITH (autovacuum_enabled = false);

CREATE TABLE @W@.access_log_json_w (
    log_id  integer NOT NULL,
    doc     json    NOT NULL,
    CONSTRAINT access_log_json_w_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);

CREATE TABLE @W@.access_log_jsonb_w (
    log_id  integer NOT NULL,
    doc     jsonb   NOT NULL,
    CONSTRAINT access_log_jsonb_w_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);

-- the only read of existing table data
INSERT INTO @W@.canonical_doc (log_id, doc_text)
SELECT log_id, doc::text FROM log_regex_json.access_log_json ORDER BY log_id;

INSERT INTO @W@.expected_update (variant, log_id, new_text)
WITH {design_variant_cte()}
SELECT v.variant, c.log_id, regexp_replace(c.doc_text, v.pattern, v.replacement)
FROM design_variant v
JOIN @W@.canonical_doc c
  ON v.row_set = 'R-5000' OR (v.row_set = 'R-238' AND c.doc_text::jsonb #>> '{{record,record_validity}}' = 'INVALID')
ORDER BY v.variant, c.log_id;

-- BEGIN setup gate (before COMMIT)
DO $gate$
DECLARE
    v_rows      bigint;
    v_md5       text;
    v_size      text;
    v_not_json  bigint;
    v_counts    text;
    v_bad       bigint;
BEGIN
    SELECT count(*), md5(string_agg(doc_text, chr(10) ORDER BY log_id)),
           sum(octet_length(doc_text)) || '/' || sum(char_length(doc_text)),
           count(*) FILTER (WHERE NOT (doc_text IS JSON OBJECT WITH UNIQUE KEYS))
      INTO v_rows, v_md5, v_size, v_not_json
      FROM @W@.canonical_doc;
    SELECT string_agg(variant || ':' || n, ' ' ORDER BY variant) INTO v_counts
      FROM (SELECT variant, count(*) AS n FROM @W@.expected_update GROUP BY variant) AS s;
    WITH {design_variant_cte()}
    SELECT count(*) INTO v_bad
      FROM @W@.expected_update e
      JOIN design_variant v      ON v.variant = e.variant
      JOIN @W@.canonical_doc c ON c.log_id = e.log_id
     WHERE regexp_count(c.doc_text, v.pattern) <> 1
        OR e.new_text = c.doc_text
        OR NOT (e.new_text IS JSON OBJECT WITH UNIQUE KEYS)
        OR e.new_text::jsonb IS DISTINCT FROM jsonb_set(c.doc_text::jsonb, v.path, v.new_value);
    IF v_rows <> 5000 OR v_md5 IS DISTINCT FROM '{CANONICAL_MD5}' OR v_size IS DISTINCT FROM '{CANONICAL_BYTES}/{CANONICAL_CHARS}'
       OR v_not_json <> 0 OR v_counts IS DISTINCT FROM '{VARIANT_COUNTS}' OR v_bad <> 0 THEN
        RAISE EXCEPTION 'sql/41 setup gate FAILED, rolled back: staged % rows, md5 %, bytes/chars %, % not unique-key JSON objects; expected updates %, % bad',
            v_rows, v_md5, v_size, v_not_json, v_counts, v_bad
            USING ERRCODE = 'LR016';
    END IF;
    RAISE NOTICE 'sql/41 setup gate PASSED: % staged texts, md5 %, bytes/chars %; expected updates %, 0 bad', v_rows, v_md5, v_size, v_counts;
END
$gate$;
-- END setup gate

COMMENT ON SCHEMA @W@ IS
    'Step 6E JSON vs JSONB write/update experiment (docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md). Isolated experiment objects only; no dependency on the log_regex or log_regex_json schemas.';
COMMENT ON TABLE @W@.canonical_doc IS
    'Step 6E staged input: the 5000 canonical texts of the Step 6B json table, {CANONICAL_BYTES} bytes, md5 {CANONICAL_MD5} (texts in log_id order joined by LF).';
COMMENT ON TABLE @W@.expected_update IS
    'Step 6E expected document text after UA-1, UA-2 and UA-3 (one substitution per document, equal to jsonb_set of the source).';
COMMENT ON TABLE @W@.access_log_json_w IS
    'Step 6E write table (json), Step 6B definition; configurations X-0 and X-1.';
COMMENT ON TABLE @W@.access_log_jsonb_w IS
    'Step 6E write table (jsonb), Step 6B definition; configurations X-0 ... X-4.';

COMMIT;

SELECT c.relkind, c.relname, pg_relation_size(c.oid) AS bytes
FROM pg_class c
WHERE c.relnamespace = '@W@'::regnamespace
ORDER BY c.relkind, c.relname;
""")


# ----------------------------------------------------------------------------------------------------------------------
# sql/42 - preflight verification
# ----------------------------------------------------------------------------------------------------------------------
def table_signature(regclass):
    r = lit(regclass)
    return (f"(SELECT c.relpersistence::text || ' ' || coalesce(array_to_string(c.reloptions, ','), '') FROM pg_class c WHERE c.oid = {r}::regclass) "
            f"|| ' | ' || (SELECT string_agg(a.attnum || ':' || a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull || ':' "
            f"|| a.attstorage::text || ':' || coalesce(nullif(a.attcompression::text, ''), '-'), ',' ORDER BY a.attnum) "
            f"FROM pg_attribute a WHERE a.attrelid = {r}::regclass AND a.attnum > 0 AND NOT a.attisdropped) "
            f"|| ' | ' || (SELECT string_agg(k.contype::text || ' ' || {norm('pg_get_constraintdef(k.oid)')}, ',' ORDER BY k.conname) "
            f"FROM pg_constraint k WHERE k.conrelid = {r}::regclass)")


def check_rows():
    invalid = "c.doc_text::jsonb #>> '{record,record_validity}' = 'INVALID'"
    per_variant = ("(SELECT string_agg(variant || ':' || n, ' ' ORDER BY variant) FROM (SELECT e.variant, count(*) AS n "
                   "FROM @W@.expected_update e JOIN design_variant v ON v.variant = e.variant JOIN @W@.canonical_doc c ON c.log_id = e.log_id "
                   "WHERE {cond} GROUP BY e.variant) s)")
    source_set = ("(SELECT string_agg(ic.relname::text, ',' ORDER BY ic.relname::text COLLATE \"C\") FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid "
                  "WHERE i.indrelid = '{table}'::regclass AND NOT i.indisprimary)")
    design_set = "(SELECT string_agg(source_index, ',' ORDER BY source_index COLLATE \"C\") FROM design_index WHERE config_id = '{config}' AND doc_type = '{t}')"
    rows = [
        # P - Step 6B/6D source state and other sessions
        ("P-01", "Step 6B access_log_json rows", "'5000'", "(SELECT count(*)::text FROM log_regex_json.access_log_json)"),
        ("P-02", "Step 6B access_log_jsonb rows", "'5000'", "(SELECT count(*)::text FROM log_regex_json.access_log_jsonb)"),
        ("P-03", "canonical fingerprint recorded in both Step 6B table comments", lit(f"{CANONICAL_MD5}/{CANONICAL_MD5}"),
         "(SELECT substring(obj_description('log_regex_json.access_log_json'::regclass, 'pg_class') FROM 'md5 ([0-9a-f]{32})') || '/' "
         "|| substring(obj_description('log_regex_json.access_log_jsonb'::regclass, 'pg_class') FROM 'md5 ([0-9a-f]{32})'))"),
        ("P-04", "indexes of schema log_regex_json = the 14 indexes of the Step 6D end state", lit(",".join(SOURCE_INDEXES)),
         "(SELECT string_agg(ic.relname::text, ',' ORDER BY ic.relname::text COLLATE \"C\") FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid "
         "JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex_json'::regnamespace)"),
        ("P-05", "Step 6D indexes valid, ready and live", "'14'",
         "(SELECT count(*)::text FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid "
         "WHERE c.relnamespace = 'log_regex_json'::regnamespace AND i.indisvalid AND i.indisready AND i.indislive)"),
        ("P-06", "Step 6B tables rows inserted / updated / deleted (json, jsonb), as sql/38 G-07", "'5000/0/0 5000/0/0'",
         "(SELECT string_agg(s.n_tup_ins || '/' || (s.n_tup_upd + s.n_tup_hot_upd) || '/' || s.n_tup_del, ' ' ORDER BY s.relname) "
         "FROM pg_stat_user_tables s WHERE s.schemaname = 'log_regex_json')"),
        ("P-07", "other PostgreSQL client sessions connected (all databases)", f"'{OTHER_CLIENT_SESSIONS}'",
         "(SELECT count(*)::text FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid())"),
        ("P-08", "other client sessions not idle (active, idle in transaction, fastpath, disabled)", "'0'",
         "(SELECT count(*)::text FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() "
         "AND state IS DISTINCT FROM 'idle')"),
        # S - staged input
        ("S-01", "canonical_doc rows / distinct log_id", "'5000/5000'",
         "(SELECT count(*) || '/' || count(DISTINCT log_id) FROM @W@.canonical_doc)"),
        ("S-02", "md5 of staged texts (log_id order, LF) = Step 6B canonical fingerprint", lit(CANONICAL_MD5),
         "(SELECT md5(string_agg(doc_text, chr(10) ORDER BY log_id)) FROM @W@.canonical_doc)"),
        ("S-03", "staged bytes / characters = Step 6B canonical input", lit(f"{CANONICAL_BYTES}/{CANONICAL_CHARS}"),
         "(SELECT sum(octet_length(doc_text)) || '/' || sum(char_length(doc_text)) FROM @W@.canonical_doc)"),
        ("S-04", "staged texts byte-identical to the stored Step 6B json text (same log_id)", "'5000'",
         "(SELECT count(*)::text FROM @W@.canonical_doc c JOIN log_regex_json.access_log_json j ON j.log_id = c.log_id WHERE j.doc::text = c.doc_text)"),
        ("S-05", "staged texts cast to jsonb = the Step 6B jsonb documents (same log_id)", "'5000'",
         "(SELECT count(*)::text FROM @W@.canonical_doc c JOIN log_regex_json.access_log_jsonb b ON b.log_id = c.log_id WHERE b.doc = c.doc_text::jsonb)"),
        ("S-06", "staged texts that are JSON objects with unique keys", "'5000'",
         "(SELECT count(*)::text FROM @W@.canonical_doc WHERE doc_text IS JSON OBJECT WITH UNIQUE KEYS)"),
        # E - expected update documents
        ("E-01", "designed update variants: row set, path, new value", lit(VARIANT_SUMMARY),
         "(SELECT string_agg(variant || ':' || row_set || ':' || array_to_string(path, '.') || '=' || new_value::text, ' ' ORDER BY variant) FROM design_variant)"),
        ("E-02", "staged documents with record_validity INVALID (row set R-238)", f"'{INVALID_ROWS}'",
         f"(SELECT count(*)::text FROM @W@.canonical_doc c WHERE {invalid})"),
        ("E-03", "expected_update rows per variant", lit(VARIANT_COUNTS),
         "(SELECT string_agg(variant || ':' || n, ' ' ORDER BY variant) FROM (SELECT variant, count(*) AS n FROM @W@.expected_update GROUP BY variant) s)"),
        ("E-04", "expected_update (variant, log_id) = designed row sets exactly (differences)", "'0'",
         "(SELECT count(*)::text FROM (SELECT variant, log_id FROM @W@.expected_update) e FULL JOIN "
         f"(SELECT v.variant, c.log_id FROM design_variant v JOIN @W@.canonical_doc c ON v.row_set = 'R-5000' OR (v.row_set = 'R-238' AND {invalid})) d "
         "ON d.variant = e.variant AND d.log_id = e.log_id WHERE e.log_id IS NULL OR d.log_id IS NULL)"),
        ("E-05", "source documents with exactly one pattern match, per variant", lit(VARIANT_COUNTS),
         per_variant.format(cond="regexp_count(c.doc_text, v.pattern) = 1")),
        ("E-06", "expected text = jsonb_set of the staged document (independent derivation), per variant", lit(VARIANT_COUNTS),
         per_variant.format(cond="e.new_text::jsonb = jsonb_set(c.doc_text::jsonb, v.path, v.new_value)")),
        ("E-07", "expected text = the substitution, a unique-key JSON object, different from the source, per variant", lit(VARIANT_COUNTS),
         per_variant.format(cond="e.new_text = regexp_replace(c.doc_text, v.pattern, v.replacement) AND e.new_text IS JSON OBJECT WITH UNIQUE KEYS AND e.new_text <> c.doc_text")),
        # O - objects of the write schema
        ("O-01", "relations in log_regex_json_write = the four designed tables and their primary keys only", lit(WRITE_RELATIONS),
         "(SELECT string_agg(c.relkind::text || ':' || c.relname, ' ' ORDER BY c.relkind, c.relname::text COLLATE \"C\") FROM pg_class c WHERE c.relnamespace = '@W@'::regnamespace)"),
        ("O-02", "other objects in log_regex_json_write (functions, sequences, views, triggers, policies, rules, non-PK constraints, types)", "'0'",
         "((SELECT count(*) FROM pg_proc WHERE pronamespace = '@W@'::regnamespace)"
         " + (SELECT count(*) FROM pg_class WHERE relnamespace = '@W@'::regnamespace AND relkind NOT IN ('r', 'i'))"
         " + (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE c.relnamespace = '@W@'::regnamespace)"
         " + (SELECT count(*) FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid WHERE c.relnamespace = '@W@'::regnamespace)"
         " + (SELECT count(*) FROM pg_rewrite r JOIN pg_class c ON c.oid = r.ev_class WHERE c.relnamespace = '@W@'::regnamespace)"
         " + (SELECT count(*) FROM pg_constraint k WHERE k.connamespace = '@W@'::regnamespace AND k.contype <> 'p')"
         " + (SELECT count(*) FROM pg_type ty WHERE ty.typnamespace = '@W@'::regnamespace AND ty.typrelid = 0 AND ty.typelem = 0))::text"),
        ("O-03", "dependencies between log_regex_json_write and log_regex / log_regex_json relations", "'0'",
         "(SELECT count(*)::text FROM pg_depend d JOIN pg_class c1 ON d.classid = 'pg_class'::regclass AND c1.oid = d.objid "
         "JOIN pg_class c2 ON d.refclassid = 'pg_class'::regclass AND c2.oid = d.refobjid "
         "WHERE (c1.relnamespace = '@W@'::regnamespace AND c2.relnamespace IN ('log_regex'::regnamespace, 'log_regex_json'::regnamespace)) "
         "OR (c2.relnamespace = '@W@'::regnamespace AND c1.relnamespace IN ('log_regex'::regnamespace, 'log_regex_json'::regnamespace)))"),
        ("O-04", "write tables empty before measurement (json_w / jsonb_w)", "'0/0'",
         "(SELECT (SELECT count(*) FROM @W@.access_log_json_w) || '/' || (SELECT count(*) FROM @W@.access_log_jsonb_w))"),
        ("O-05", "access_log_json_w = Step 6B access_log_json definition (persistence, reloptions, columns, storage, compression, constraints)", "'same'",
         f"(SELECT CASE WHEN {table_signature('log_regex_json.access_log_json')} = {table_signature(W + '.access_log_json_w')} THEN 'same' ELSE 'different' END)"),
        ("O-06", "access_log_jsonb_w = Step 6B access_log_jsonb definition (persistence, reloptions, columns, storage, compression, constraints)", "'same'",
         f"(SELECT CASE WHEN {table_signature('log_regex_json.access_log_jsonb')} = {table_signature(W + '.access_log_jsonb_w')} THEN 'same' ELSE 'different' END)"),
        ("O-07", "write-schema tables with autovacuum disabled", "'4'",
         "(SELECT count(*)::text FROM pg_class WHERE relnamespace = '@W@'::regnamespace AND relkind = 'r' AND reloptions @> ARRAY['autovacuum_enabled=false'])"),
        # D - designed index configurations (static)
        ("D-01", "designed indexes per configuration and type (X-0: none; X-2 ... X-4: jsonb only)", lit(CONFIG_COUNTS),
         "(SELECT string_agg(config_id || '/' || doc_type || ':' || n, ' ' ORDER BY config_id, doc_type) FROM (SELECT config_id, doc_type, count(*) AS n FROM design_index GROUP BY 1, 2) s)"),
        ("D-02", "designed statements not in the designed form (name, _w table of the same type, method, GIN only on jsonb, no cast)", "'0'",
         "(SELECT count(*)::text FROM design_index x WHERE NOT starts_with(x.ddl, 'CREATE INDEX ' || x.index_name || ' ON @W@.access_log_' || x.doc_type || '_w ') "
         "OR NOT starts_with(x.index_name, 'access_log_' || x.doc_type || '_w_') OR NOT starts_with(x.source_index, 'access_log_' || x.doc_type || '_') "
         "OR x.index_name <> replace(x.source_index, 'access_log_' || x.doc_type || '_', 'access_log_' || x.doc_type || '_w_') "
         "OR x.method NOT IN ('btree', 'gin') OR (x.method = 'gin') <> (strpos(x.ddl, ' USING gin (doc ' || x.opclass || ')') > 0) "
         "OR (x.method = 'gin' AND x.doc_type <> 'jsonb') OR strpos(x.ddl, '::json') > 0)"),
        ("D-03", "designed method and operator class = those of the live Step 6D source index", "'29'",
         "(SELECT count(*)::text FROM design_index x JOIN pg_class si ON si.oid = to_regclass('log_regex_json.' || x.source_index) "
         "JOIN pg_index i ON i.indexrelid = si.oid JOIN pg_am am ON am.oid = si.relam JOIN pg_opclass opc ON opc.oid = i.indclass[0] "
         "WHERE am.amname = x.method AND opc.opcname = x.opclass AND i.indnatts = 1)"),
        ("D-04", "X-1 json and jsonb statements identical apart from table and index names (5 concepts)", "'5'",
         "(SELECT count(*)::text FROM design_index a JOIN design_index b ON b.config_id = a.config_id AND b.concept = a.concept "
         "WHERE a.config_id = 'X-1' AND a.doc_type = 'json' AND b.doc_type = 'jsonb' AND a.method = b.method AND a.opclass = b.opclass "
         "AND replace(a.ddl, 'access_log_json_w', 'T') = replace(b.ddl, 'access_log_jsonb_w', 'T'))"),
        ("D-05", "X-2 / X-3 / X-4 btree statements = the X-1 jsonb statements", "'15'",
         "(SELECT count(*)::text FROM design_index a JOIN design_index x ON x.config_id = 'X-1' AND x.doc_type = 'jsonb' "
         "AND x.index_name = a.index_name AND x.ddl = a.ddl WHERE a.config_id IN ('X-2', 'X-3', 'X-4') AND a.method = 'btree')"),
        ("D-06", "X-1 json = the live secondary indexes of access_log_json; X-4 = those of access_log_jsonb (current Step 6D set)", "'same/same'",
         "(SELECT CASE WHEN " + design_set.format(config="X-1", t="json") + " = " + source_set.format(table="log_regex_json.access_log_json")
         + " THEN 'same' ELSE 'different' END || '/' || CASE WHEN " + design_set.format(config="X-4", t="jsonb") + " = "
         + source_set.format(table="log_regex_json.access_log_jsonb") + " THEN 'same' ELSE 'different' END)"),
        ("D-07", "GIN operator classes per configuration", "'X-2:jsonb_ops X-3:jsonb_path_ops X-4:jsonb_ops,jsonb_path_ops'",
         "(SELECT string_agg(config_id || ':' || ops, ' ' ORDER BY config_id) FROM (SELECT config_id, string_agg(opclass, ',' ORDER BY opclass) AS ops "
         "FROM design_index WHERE method = 'gin' GROUP BY config_id) s)"),
    ]
    return rows


INDEX_CHECKS = ["I-X0", "I-X1", "I-X2", "I-X3", "I-X4", "I-END"]


def generate_sql42():
    checks = check_rows()
    n_checks = len(checks) + len(INDEX_CHECKS)
    values = ",\n".join(f"            ({lit(i)}, {lit(n)}, {e}, {a})" for i, n, e, a in checks)
    created = norm("pg_get_indexdef(ic.oid)")
    return sql(f"""-- =============================================================================
-- Step 6E / 42 - Preflight verification of the write/update experiment (nothing persists)
-- =============================================================================
-- GENERATED by scripts/step6e_json_write_experiment.py - do not edit by hand.
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/42_preflight_json_write_experiment.sql
--
-- One transaction that always ends with ROLLBACK. Every check prints "<id> PASS" or "<id> FAIL"; after all checks the
-- script raises SQLSTATE LR017 (non-zero exit) if any failed. {n_checks} checks:
--   P-01 .. P-08  Step 6B tables and the 14 Step 6D indexes unchanged; {OTHER_CLIENT_SESSIONS} other client sessions, all idle
--   S-01 .. S-06  staged input = the Step 6B canonical fingerprint (md5 {CANONICAL_MD5}, bytes, characters, byte-identical)
--   E-01 .. E-07  expected update documents: variants, row sets, one match each, equal to jsonb_set, valid JSON
--   O-01 .. O-07  log_regex_json_write holds only the four designed tables; no coupling; write tables empty and equal to
--                 the Step 6B table definitions
--   D-01 .. D-07  index configurations X-0 ... X-4 in the designed form and derived from the live Step 6D indexes
--   I-X0 .. I-X4  each configuration is created on the empty write tables INSIDE THIS TRANSACTION; name, method,
--                 operator class, validity and the normalised pg_get_indexdef are compared with the live Step 6D
--                 index; json and jsonb identical in X-1; indexes dropped before the next configuration
--   I-END         only the primary keys remain (the transaction is then rolled back)
-- The only temporary changes are the index creations of I-X1 .. I-X4 on the empty _w tables of log_regex_json_write,
-- all rolled back. Nothing outside log_regex_json_write is written. No measurement.
-- =============================================================================

\\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
\\pset footer off

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL TimeZone = 'UTC';

DO $guard$
BEGIN
    IF to_regclass('@W@.canonical_doc') IS NULL OR to_regclass('@W@.expected_update') IS NULL
       OR to_regclass('@W@.access_log_json_w') IS NULL OR to_regclass('@W@.access_log_jsonb_w') IS NULL THEN
        RAISE EXCEPTION 'Step 6E preflight cannot run: the objects of sql/41 are missing' USING ERRCODE = 'LR017';
    END IF;
    PERFORM set_config('step6e.preflight_failures', '0', true);
END
$guard$;

\\echo '== Other client sessions (no query text)'
SELECT pid, datname, usename, application_name, backend_start, state, state_change, xact_start IS NOT NULL AS in_transaction
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
ORDER BY pid;

\\echo '== Relations in @W@'
SELECT c.relkind, c.relname, pg_relation_size(c.oid) AS bytes, c.reloptions
FROM pg_class c WHERE c.relnamespace = '@W@'::regnamespace
ORDER BY c.relkind, c.relname;

\\echo '== Designed index configurations (X-0 = primary key only)'
WITH {design_index_cte()}
SELECT config_id, doc_type, concept, method, opclass, source_index, ddl
FROM design_index
ORDER BY config_id, doc_type, index_name;

\\echo '== Preflight checks'
DO $static$
DECLARE
    v_failed integer := 0;
    chk      record;
BEGIN
    FOR chk IN
        WITH {design_index_cte()},
        {design_variant_cte()}
        SELECT c.id, c.name, c.expected, c.actual
        FROM (VALUES
{values}
        ) AS c (id, name, expected, actual)
    LOOP
        IF chk.expected IS NOT DISTINCT FROM chk.actual THEN
            RAISE NOTICE '% PASS  %: %', chk.id, chk.name, chk.actual;
        ELSE
            v_failed := v_failed + 1;
            RAISE WARNING '% FAIL  %: expected %, actual %', chk.id, chk.name, chk.expected, chk.actual;
        END IF;
    END LOOP;
    PERFORM set_config('step6e.preflight_failures', v_failed::text, true);
END
$static$;

DO $indexes$
DECLARE
    v_failed   integer := current_setting('step6e.preflight_failures')::integer;
    v_config   text;
    v_expected text;
    v_actual   text;
    v_count    bigint;
    ixd        record;
BEGIN
    -- I-X0: primary keys only, equal to the Step 6B primary keys
    WITH {design_index_cte()}
    SELECT count(*) INTO v_count FROM design_index WHERE config_id = 'X-0';
    SELECT string_agg(ic.relname::text || ' ' || {created}, '; ' ORDER BY ic.relname::text COLLATE "C")
           || CASE WHEN bool_and(i.indisprimary AND i.indisvalid) THEN '' ELSE ' (NOT PRIMARY OR NOT VALID)' END
      INTO v_actual
      FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
     WHERE i.indrelid IN ('@W@.access_log_json_w'::regclass, '@W@.access_log_jsonb_w'::regclass);
    SELECT string_agg(replace(ic.relname::text, '_pkey', '_w_pkey') || ' ' || {created}, '; ' ORDER BY ic.relname::text COLLATE "C")
      INTO v_expected
      FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
     WHERE i.indrelid IN ('log_regex_json.access_log_json'::regclass, 'log_regex_json.access_log_jsonb'::regclass) AND i.indisprimary;
    IF v_count = 0 AND v_actual IS NOT DISTINCT FROM v_expected THEN
        RAISE NOTICE 'I-X0 PASS  X-0 = primary keys only, equal to the Step 6B primary keys; %', v_actual;
    ELSE
        v_failed := v_failed + 1;
        RAISE WARNING 'I-X0 FAIL  X-0; expected 0 designed indexes and %, actual % designed indexes and %', v_expected, v_count, v_actual;
    END IF;

    FOREACH v_config IN ARRAY ARRAY['X-1', 'X-2', 'X-3', 'X-4'] LOOP
        FOR ixd IN
            WITH {design_index_cte()}
            SELECT ddl FROM design_index WHERE config_id = v_config ORDER BY doc_type, index_name
        LOOP
            EXECUTE ixd.ddl;
        END LOOP;

        WITH {design_index_cte()}
        SELECT string_agg(x.doc_type || ' ' || x.index_name || ' ' || x.method || ' ' || x.opclass || ' ' || {norm('pg_get_indexdef(si.oid)')},
                          ' | ' ORDER BY x.doc_type COLLATE "C", x.index_name COLLATE "C")
          INTO v_expected
          FROM design_index x
          LEFT JOIN pg_class si ON si.oid = to_regclass('log_regex_json.' || x.source_index)
         WHERE x.config_id = v_config;

        SELECT string_agg(CASE c.relname WHEN 'access_log_json_w' THEN 'json' ELSE 'jsonb' END || ' ' || ic.relname::text || ' ' || am.amname::text
                          || ' ' || opc.opcname::text || ' ' || {created},
                          ' | ' ORDER BY CASE c.relname WHEN 'access_log_json_w' THEN 'json' ELSE 'jsonb' END COLLATE "C", ic.relname::text COLLATE "C")
               || CASE WHEN bool_and(i.indisvalid AND i.indisready AND i.indislive AND i.indnatts = 1) THEN '' ELSE ' (NOT VALID)' END
          INTO v_actual
          FROM pg_index i
          JOIN pg_class ic    ON ic.oid = i.indexrelid
          JOIN pg_class c     ON c.oid = i.indrelid
          JOIN pg_am am       ON am.oid = ic.relam
          JOIN pg_opclass opc ON opc.oid = i.indclass[0]
         WHERE c.relnamespace = '@W@'::regnamespace AND NOT i.indisprimary;

        v_count := NULL;
        IF v_config = 'X-1' THEN
            SELECT count(*) INTO v_count
              FROM pg_index ij JOIN pg_class icj ON icj.oid = ij.indexrelid
              JOIN pg_index ib ON ib.indrelid = '@W@.access_log_jsonb_w'::regclass AND NOT ib.indisprimary
              JOIN pg_class icb ON icb.oid = ib.indexrelid
             WHERE ij.indrelid = '@W@.access_log_json_w'::regclass AND NOT ij.indisprimary
               AND replace(icj.relname::text, 'access_log_json_w_', '') = replace(icb.relname::text, 'access_log_jsonb_w_', '')
               AND {norm('pg_get_indexdef(icj.oid)')} = {norm('pg_get_indexdef(icb.oid)')}
               AND ij.indclass[0] = ib.indclass[0];
        END IF;

        IF v_expected IS NOT NULL AND v_actual IS NOT DISTINCT FROM v_expected AND (v_config <> 'X-1' OR v_count = 5) THEN
            RAISE NOTICE 'I-% PASS  % created = design = live Step 6D definitions (name, method, opclass, normalised definition, valid)%; %',
                replace(v_config, '-', ''), v_config,
                CASE WHEN v_config = 'X-1' THEN ', json and jsonb identical (5 pairs)' ELSE ', jsonb only' END, v_actual;
        ELSE
            v_failed := v_failed + 1;
            RAISE WARNING 'I-% FAIL  %; expected %, actual %, identical json/jsonb pairs %',
                replace(v_config, '-', ''), v_config, v_expected, v_actual, v_count;
        END IF;

        FOR ixd IN
            SELECT ic.relname::text AS index_name
              FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
             WHERE c.relnamespace = '@W@'::regnamespace AND NOT i.indisprimary
        LOOP
            EXECUTE format('DROP INDEX @W@.%I', ixd.index_name);
        END LOOP;
    END LOOP;

    SELECT count(*) INTO v_count
      FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid
     WHERE c.relnamespace = '@W@'::regnamespace AND NOT i.indisprimary;
    IF v_count = 0 THEN
        RAISE NOTICE 'I-END PASS  secondary indexes left in @W@ after the configuration checks: 0';
    ELSE
        v_failed := v_failed + 1;
        RAISE WARNING 'I-END FAIL  secondary indexes left in @W@ after the configuration checks: %', v_count;
    END IF;

    PERFORM set_config('step6e.preflight_failures', v_failed::text, true);
END
$indexes$;

DO $verdict$
BEGIN
    IF current_setting('step6e.preflight_failures')::integer > 0 THEN
        RAISE EXCEPTION 'Step 6E preflight FAILED: % of {n_checks} checks', current_setting('step6e.preflight_failures')
            USING ERRCODE = 'LR017';
    END IF;
    RAISE NOTICE 'Step 6E preflight PASSED: all {n_checks} checks';
END
$verdict$;

ROLLBACK;
""")


def cmd_generate(check):
    targets = {SQL41: generate_sql41(), SQL42: generate_sql42()}
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--check", action="store_true")
    args = parser.parse_args()
    return cmd_generate(args.check)


if __name__ == "__main__":
    sys.exit(main())
