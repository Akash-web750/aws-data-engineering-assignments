#!/usr/bin/env python3
"""Step 7C - spatial index experiment: index builds, correctness matrix, EXPLAIN ANALYZE sessions, analysis.

Design: docs/Step7C_Spatial_Index_Experiment_Design.md (approved, all 8 decisions). Setup: Step 7B (317 PASS).

  python -B scripts/step7c_spatial_index_experiment.py generate [--check]   sql/49, sql/50, sql/51, sql/52
  python -B scripts/step7c_spatial_index_experiment.py harness OUT          1 build per index + ANALYZE + sql/50 after, ROLLBACK
  python -B scripts/step7c_spatial_index_experiment.py static-check
  python -B scripts/step7c_spatial_index_experiment.py analyze --session1 RAW --session2 RAW --build-log LOG [--out-dir DIR]

Imports the Step 7B definitions (tables, point expressions, the 10 index statements of sql/48) unchanged.
Standard library only.
"""
import argparse
import csv
import json
import math
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import step7_postgis_experiment as e7  # noqa: E402

ROOT = e7.ROOT
W = e7.W
ANALYSIS = ROOT / "analysis" / "step7"
SQL49 = ROOT / "sql" / "49_build_measure_gis_indexes.sql"
SQL50 = ROOT / "sql" / "50_verify_gis_index_phase.sql"
SQL51 = ROOT / "sql" / "51_measure_gis_queries.sql"
SQL52 = ROOT / "sql" / "52_drop_gis_indexes.sql"
WARMUP, MEASURED = 3, 15
EXPLAIN_MEASURE = "EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY, SUMMARY, FORMAT JSON)"
EXPLAIN_DETAIL = "EXPLAIN (ANALYZE, TIMING ON, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY, SUMMARY, FORMAT JSON)"
lit = e7.lit

# ---------------------------------------------------------------------------------------------------------------------
# indexes and configurations
# ---------------------------------------------------------------------------------------------------------------------
INDEX_STMT = dict(e7.INDEXES)
INDEX_NAME = {i: re.match(r"CREATE INDEX (\S+) ON", s).group(1) for i, s in e7.INDEXES}
INDEX_TABLE = {i: re.match(r"CREATE INDEX \S+ ON log_regex_gis\.(\S+) USING", s).group(1) for i, s in e7.INDEXES}
INDEX_METHOD = {i: re.match(r".* USING (\w+) ", s).group(1) for i, s in e7.INDEXES}
INDEX_OPCLASS = {"N-1": "numeric_ops", "G-1": "gist_geometry_ops_2d", "G-2": "spgist_geometry_ops_2d", "G-3": "brin_geometry_inclusion_ops_2d",
                 "Y-1": "gist_geography_ops", "Y-2": "spgist_geography_ops_nd", "J-1": "gist_geometry_ops_2d", "J-2": "gist_geography_ops",
                 "J-3": "gist_geometry_ops_2d", "J-4": "gist_geography_ops"}
INDEX_KEY = {"N-1": "latitude_degrees,longitude_degrees", "G-1": "geom", "G-2": "geom", "G-3": "geom", "Y-1": "geog", "Y-2": "geog",
             "J-1": "expr:true", "J-2": "expr:true", "J-3": "geom", "J-4": "geog"}
CONFIG_TABLE = {"N-0": "flat_numeric", "N-1": "flat_numeric_btree", "G-0": "flat_geom", "G-1": "flat_geom_gist", "G-2": "flat_geom_spgist",
                "G-3": "flat_geom_brin", "Y-0": "flat_geog", "Y-1": "flat_geog_gist", "Y-2": "flat_geog_spgist", "J-0g": "jsonb_doc",
                "J-1": "jsonb_doc_expr", "J-3c": "jsonb_geom", "J-3": "jsonb_geom_gist", "J-0y": "jsonb_doc", "J-2": "jsonb_doc_expr",
                "J-4c": "jsonb_geog", "J-4": "jsonb_geog_gist"}
CONFIG_INDEX = {c: INDEX_NAME[c] for c in INDEX_NAME}
CONTROL = {"N-1": "N-0", "G-1": "G-0", "G-2": "G-0", "G-3": "G-0", "Y-1": "Y-0", "Y-2": "Y-0", "J-1": "J-0g", "J-2": "J-0y", "J-3": "J-3c", "J-4": "J-4c"}
GEOM_POINT = {"G-0": "geom", "G-1": "geom", "G-2": "geom", "G-3": "geom", "J-0g": e7.E_JSONB_GEOM, "J-1": e7.E_JSONB_GEOM, "J-3c": "geom", "J-3": "geom"}
GEOG_POINT = {"Y-0": "geog", "Y-1": "geog", "Y-2": "geog", "J-0y": e7.E_JSONB_GEOG, "J-2": e7.E_JSONB_GEOG, "J-4c": "geog", "J-4": "geog"}
G_CFGS = list(GEOM_POINT)
Y_CFGS = list(GEOG_POINT)
B_CFGS = ["N-0", "N-1"] + G_CFGS
BOX = {b[0]: b for b in e7.BOXES}
DIST = {d[0]: d for d in e7.DISTANCES}
CENTRES = e7.CENTRES
KNN_GEOG = {"K1": ("Reykjavik", 10), "K2": ("Reykjavik", 100)}
KNN_GEOM = {"K3": ("NewYork", 10), "K1g": ("Reykjavik", 10)}
NO_ORDERING = {"G-2", "G-3", "Y-2"}   # operator class without an ordering operator (catalog, design section 1)
RECORDED = {"B1": "410:e8583952b4262fd551703878cdd64bb9", "B2": "416:7e9ec48ea506cadea7792531578fc2d3", "B3": "1580:e07244d99def3a9fc8fda8c9d49fe520",
            "B4": "3897:69112583f9543c5ac7502660e9d42e8c", "B5": "0:-", "B6": "1:743394beff4b1282ba735e5e3723ed74",
            "D1": "410:e8583952b4262fd551703878cdd64bb9", "D2": "1101:09f877d401cb13d4bdfffdb39a189388", "D3": "599:56123c817c3f641bcc4a779662e8fb2a",
            "D4": "2059:5231b94f79b1d93616a898709df2e865", "D5": "262:67d6fd7d52288b8729c205b8b7685a1e", "D6": "15:1425ecba1e7b5bdf0e0497024ed7ba2e",
            "D7": "1:743394beff4b1282ba735e5e3723ed74", "K1": "10:b8bcc3f1f5a82199a44fb1cdd495d6b4", "K2": "100:ff4ae07b829ad4de9fa92124f6df18f0"}
BOTH = "f.latitude_degrees IS NOT NULL AND f.longitude_degrees IS NOT NULL"


def geom_centre(name):
    lat, lon = CENTRES[name]
    return f"postgis.ST_SetSRID(postgis.ST_MakePoint({lon}, {lat}), 4326)"


def geog_centre(name):
    return f"postgis.geography({geom_centre(name)})"


def md_margins(did):
    _d, centre, radius, _n = DIST[did]
    lat = float(CENTRES[centre][0])
    dy = math.ceil(float(radius) / 110000.0 * 1e7) / 1e7
    dx = math.ceil(dy / math.cos(math.radians(abs(lat) + dy)) * 1e7) / 1e7
    return f"{dx:.7f}", f"{dy:.7f}"


def blocks():
    out = []
    for bid in BOX:
        out.append((bid, [(bid, c) for c in B_CFGS]))
    for did in DIST:
        series = [(did, c) for c in Y_CFGS]
        if did in ("D1", "D2", "D6"):
            series += [("MD" + did[1:], "G-0"), ("MD" + did[1:], "G-1")]
        out.append((did, series))
    for did in DIST:
        out.append((did + "-s", [(did + "-s", c) for c in Y_CFGS]))
    out.append(("K1", [("K1", c) for c in Y_CFGS] + [("K1g", "G-0"), ("K1g", "G-1")]))
    out.append(("K2", [("K2", c) for c in Y_CFGS]))
    out.append(("K3", [("K3", c) for c in G_CFGS]))
    out.append(("P", [("P1", "Y-0"), ("P2", "Y-0"), ("P3", "N-0"), ("P4", "J-0y")]))
    assert sum(len(s) for _b, s in out) == 192
    return out


def round_order(series, r):
    n = len(series)
    rot = series[r % n:] + series[:r % n]
    return list(reversed(rot)) if r % 2 else rot


def expected_rows(q):
    if q in BOX:
        return BOX[q][5]
    base = q[:-2] if q.endswith("-s") else q
    if base in DIST:
        return DIST[base][3]
    if q.startswith("MD"):
        return DIST["D" + q[2:]][3]
    if q in KNN_GEOG:
        return KNN_GEOG[q][1]
    if q in KNN_GEOM:
        return KNN_GEOM[q][1]
    return 5000


def query_sql(q, c):
    t = f"{W}.{CONFIG_TABLE[c]}"
    if q in BOX:
        _b, s, w, n, e, _x = BOX[q]
        if c in ("N-0", "N-1"):
            lon = f"longitude_degrees BETWEEN {w} AND {e}" if float(w) <= float(e) else f"(longitude_degrees >= {w} OR longitude_degrees <= {e})"
            return f"SELECT log_id FROM {t} WHERE latitude_degrees BETWEEN {s} AND {n} AND {lon}"
        p = GEOM_POINT[c]
        if float(w) <= float(e):
            return f"SELECT log_id FROM {t} WHERE postgis.ST_Intersects({p}, postgis.ST_MakeEnvelope({w}, {s}, {e}, {n}, 4326))"
        return (f"SELECT log_id FROM {t} WHERE postgis.ST_Intersects({p}, postgis.ST_MakeEnvelope({w}, {s}, 180, {n}, 4326)) "
                f"OR postgis.ST_Intersects({p}, postgis.ST_MakeEnvelope(-180, {s}, {e}, {n}, 4326))")
    base = q[:-2] if q.endswith("-s") else q
    if base in DIST:
        _d, centre, radius, _n = DIST[base]
        suffix = ", false" if q.endswith("-s") else ""
        return f"SELECT log_id FROM {t} WHERE postgis.ST_DWithin({GEOG_POINT[c]}, {geog_centre(centre)}, {radius}{suffix})"
    if q.startswith("MD"):
        did = "D" + q[2:]
        _d, centre, radius, _n = DIST[did]
        dx, dy = md_margins(did)
        return (f"SELECT log_id FROM {t} WHERE geom OPERATOR(postgis.&&) postgis.ST_Expand({geom_centre(centre)}, {dx}, {dy}) "
                f"AND postgis.ST_DistanceSphere(geom, {geom_centre(centre)}) <= {radius}")
    if q in KNN_GEOG:
        centre, k = KNN_GEOG[q]
        return f"SELECT log_id FROM {t} ORDER BY {GEOG_POINT[c]} OPERATOR(postgis.<->) {geog_centre(centre)} LIMIT {k}"
    if q in KNN_GEOM:
        centre, k = KNN_GEOM[q]
        return f"SELECT log_id FROM {t} ORDER BY {GEOM_POINT[c]} OPERATOR(postgis.<->) {geom_centre(centre)} LIMIT {k}"
    ry = geog_centre("Reykjavik")
    return {"P1": f"SELECT log_id, postgis.ST_Distance(geog, {ry}) FROM {W}.flat_geog",
            "P2": f"SELECT log_id, postgis.ST_Distance(geog, {ry}, false) FROM {W}.flat_geog",
            "P3": f"SELECT log_id, postgis.ST_Distance({e7.E_FLAT_GEOG}, {ry}) FROM {W}.flat_numeric",
            "P4": f"SELECT log_id, postgis.ST_Distance({e7.E_JSONB_GEOG}, {ry}) FROM {W}.jsonb_doc"}[q]


# ---------------------------------------------------------------------------------------------------------------------
# oracle and correctness SQL
# ---------------------------------------------------------------------------------------------------------------------
def set_checksum(inner):
    return f"SELECT count(*) || ':' || coalesce(md5(string_agg(q.log_id::text, ',' ORDER BY q.log_id)), '-') FROM ({inner}) q"


def planar(alias, centre):
    lat, lon = CENTRES[centre]
    return (f"(({alias}.longitude_degrees - ({lon})) * ({alias}.longitude_degrees - ({lon})) + "
            f"({alias}.latitude_degrees - ({lat})) * ({alias}.latitude_degrees - ({lat})))")


def haversine_f(centre):
    lat, lon = CENTRES[centre]
    return e7.haversine("f.latitude_degrees", "f.longitude_degrees", lat, lon)


def tie_free(centre, k):
    return (f"(SELECT count(*) FROM {W}.flat_numeric f WHERE {BOTH} AND {planar('f', centre)} <= "
            f"(SELECT {planar('g', centre)} FROM {W}.flat_numeric g WHERE g.latitude_degrees IS NOT NULL AND g.longitude_degrees IS NOT NULL "
            f"ORDER BY 1 LIMIT 1 OFFSET {k - 1})) = {k}")


def p_checksum(inner):
    return (f"SELECT count(*) || ':' || count(q.st_distance) || ':' || md5(string_agg(q.log_id || '=' || coalesce(q.st_distance::text, 'NULL'), "
            f"',' ORDER BY q.log_id)) FROM ({inner}) q")


def oracle_sql(q):
    if q in BOX:
        _b, s, w, n, e, _x = BOX[q]
        lon = f"f.longitude_degrees BETWEEN {w} AND {e}" if float(w) <= float(e) else f"(f.longitude_degrees >= {w} OR f.longitude_degrees <= {e})"
        return set_checksum(f"SELECT f.log_id FROM {W}.flat_numeric f WHERE f.latitude_degrees BETWEEN {s} AND {n} AND {lon}")
    base = q[:-2] if q.endswith("-s") else ("D" + q[2:] if q.startswith("MD") else q)
    if base in DIST:
        _d, centre, radius, _n = DIST[base]
        return set_checksum(f"SELECT f.log_id FROM {W}.flat_numeric f WHERE {BOTH} AND {haversine_f(centre)} <= {radius}")
    if q in KNN_GEOG:
        centre, k = KNN_GEOG[q]
        return set_checksum(f"SELECT f.log_id FROM {W}.flat_numeric f WHERE {BOTH} ORDER BY {haversine_f(centre)}, f.log_id LIMIT {k}")
    raise KeyError(q)


def correctness_rows():
    """(id, expected_sql, actual_sql) per series; K3/K1g give a multiset and a set-or-ties row."""
    rows = []
    for _b, series in blocks():
        for q, c in series:
            sql = query_sql(q, c)
            sid = f"{q}@{c}"
            if q in KNN_GEOM:
                centre, k = KNN_GEOM[q]
                rows.append((sid + ":multiset",
                             f"SELECT coalesce(string_agg(d::text, ',' ORDER BY d), '-') FROM (SELECT {planar('f', centre)} AS d FROM {W}.flat_numeric f "
                             f"WHERE {BOTH} ORDER BY d LIMIT {k}) s",
                             f"SELECT coalesce(string_agg(d::text, ',' ORDER BY d), '-') FROM (SELECT {planar('f', centre)} AS d FROM ({sql}) q "
                             f"JOIN {W}.flat_numeric f ON f.log_id = q.log_id) s"))
                oracle_set = (f"SELECT md5(string_agg(log_id::text, ',' ORDER BY log_id)) FROM (SELECT f.log_id FROM {W}.flat_numeric f WHERE {BOTH} "
                              f"ORDER BY {planar('f', centre)}, f.log_id LIMIT {k}) s")
                rows.append((sid + ":set", f"SELECT CASE WHEN {tie_free(centre, k)} THEN ({oracle_set}) ELSE 'tie-at-rank-{k}' END",
                             f"SELECT CASE WHEN {tie_free(centre, k)} THEN (SELECT md5(string_agg(q.log_id::text, ',' ORDER BY q.log_id)) FROM ({sql}) q) "
                             f"ELSE 'tie-at-rank-{k}' END"))
            elif q in ("P1", "P3", "P4"):
                rows.append((sid, p_checksum(query_sql("P3", "N-0")), p_checksum(sql)))
            elif q == "P2":
                rows.append((sid, "SELECT '5000:4161:true'",
                             f"SELECT count(*) || ':' || count(q.st_distance) || ':' || (max(abs(q.st_distance - {haversine_f('Reykjavik')})) <= 0.001)::text "
                             f"FROM ({sql}) q JOIN {W}.flat_numeric f ON f.log_id = q.log_id"))
            else:
                rows.append((sid, oracle_sql(q), set_checksum(sql)))
    assert len(rows) == 202, len(rows)
    return rows


def matrix_block(rows, fail_setting, count_setting):
    values = ",\n".join(f"            ({lit(i)}, {lit(e)}, {lit(a)})" for i, e, a in rows)
    return f"""DO $matrix$
DECLARE
    v_failed   integer := coalesce(nullif(current_setting('{fail_setting}', true), ''), '0')::integer;
    v_checks   integer := coalesce(nullif(current_setting('{count_setting}', true), ''), '0')::integer;
    chk        record;
    v_expected text;
    v_actual   text;
    v_mode     text;
BEGIN
    FOR chk IN
        SELECT m.id, m.expected_sql, m.actual_sql
        FROM (VALUES
{values}
        ) AS m (id, expected_sql, actual_sql)
    LOOP
        PERFORM set_config('enable_seqscan', 'on', true);
        PERFORM set_config('enable_indexscan', 'on', true);
        PERFORM set_config('enable_bitmapscan', 'on', true);
        EXECUTE chk.expected_sql INTO v_expected;
        FOREACH v_mode IN ARRAY ARRAY['default', 'index', 'seq'] LOOP
            PERFORM set_config('enable_seqscan', CASE WHEN v_mode = 'index' THEN 'off' ELSE 'on' END, true);
            PERFORM set_config('enable_indexscan', CASE WHEN v_mode = 'seq' THEN 'off' ELSE 'on' END, true);
            PERFORM set_config('enable_bitmapscan', CASE WHEN v_mode = 'seq' THEN 'off' ELSE 'on' END, true);
            EXECUTE chk.actual_sql INTO v_actual;
            v_checks := v_checks + 1;
            IF v_actual IS NOT DISTINCT FROM v_expected THEN
                RAISE NOTICE 'C-03:%/% PASS  result = plain-SQL oracle: %', chk.id, v_mode, v_actual;
            ELSE
                v_failed := v_failed + 1;
                RAISE WARNING 'C-03:%/% FAIL  result = plain-SQL oracle: expected %, actual %', chk.id, v_mode, v_expected, v_actual;
            END IF;
        END LOOP;
    END LOOP;
    PERFORM set_config('enable_seqscan', 'on', true);
    PERFORM set_config('enable_indexscan', 'on', true);
    PERFORM set_config('enable_bitmapscan', 'on', true);
    PERFORM set_config('{fail_setting}', v_failed::text, false);
    PERFORM set_config('{count_setting}', v_checks::text, false);
END
$matrix$;"""


def static_count_block(tag, rows, fail_setting, count_setting):
    block = e7.check_block(tag, rows, fail_setting)
    return block + f"\nSELECT set_config('{count_setting}', (coalesce(nullif(current_setting('{count_setting}', true), ''), '0')::integer + {len(rows)})::text, false) AS counted \\gset x_"


def index_state_rows():
    rows = []
    for iid, name in INDEX_NAME.items():
        rows.append((f"C-02:{iid}", f"index {name}: table|method|opclass|valid|ready|key",
                     lit(f"{INDEX_TABLE[iid]}|{INDEX_METHOD[iid]}|{INDEX_OPCLASS[iid]}|true|true|{INDEX_KEY[iid]}"),
                     f"(SELECT c.relname || '|' || am.amname || '|' || opc.opcname || '|' || i.indisvalid || '|' || i.indisready || '|' || "
                     f"CASE WHEN i.indexprs IS NULL THEN (SELECT string_agg(a.attname, ',' ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k (attnum, ord) "
                     f"JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum) "
                     f"ELSE 'expr:' || (lower(pg_get_expr(i.indexprs, i.indrelid)) LIKE '%st_makepoint(%' AND strpos(lower(pg_get_expr(i.indexprs, i.indrelid)), 'longitude') > 0 "
                     f"AND strpos(lower(pg_get_expr(i.indexprs, i.indrelid)), 'longitude') < strpos(lower(pg_get_expr(i.indexprs, i.indrelid)), 'latitude'))::text END "
                     f"FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid JOIN pg_am am ON am.oid = ic.relam "
                     f"JOIN pg_opclass opc ON opc.oid = i.indclass[0] WHERE ic.oid = to_regclass('{W}.{name}'))"))
    return rows


def inventory_row(with_indexes):
    names = e7.TABLE_NAMES
    items = sorted([("i", f"{n}_pkey") for n in names] + [("r", n) for n in names] + ([("i", n) for n in INDEX_NAME.values()] if with_indexes else []))
    label = "the 15 tables, 15 primary keys and exactly the 10 designed indexes" if with_indexes else "the 15 tables and 15 primary keys (no secondary index)"
    return ("A-03a", f"log_regex_gis relations = {label}", lit(" ".join(f"{k}:{n}" for k, n in items)),
            f"(SELECT string_agg(relkind::text || ':' || relname, ' ' ORDER BY relkind, relname COLLATE \"C\") FROM pg_class WHERE relnamespace = '{W}'::regnamespace)")


def recorded_rows():
    rows = []
    for q, value in RECORDED.items():
        rows.append((f"R-{q}", f"{q}: plain-SQL oracle = value recorded in Step 7B", lit(value), "(" + oracle_sql(q) + ")"))
    rows.append(("R-P3", "P3: rows and non-NULL distances", "'5000:4161'",
                 f"(SELECT count(*) || ':' || count(q.st_distance) FROM ({query_sql('P3', 'N-0')}) q)"))
    return rows


def fingerprint_block():
    tables = ", ".join(lit(n) for n in e7.TABLE_NAMES)
    return f"""DO $fp$
DECLARE
    t text;
    v text;
BEGIN
    FOREACH t IN ARRAY ARRAY[{tables}] LOOP
        EXECUTE format('SELECT md5(string_agg(x::text, chr(10) ORDER BY x.log_id)) FROM {W}.%I AS x', t) INTO v;
        RAISE NOTICE '@@FP %: %', t, v;
    END LOOP;
END
$fp$;"""


def sql50_body(phase):
    fail, count = "step7c.verify50", "step7c.checks50"
    iso = [r for r in e7.isolation_checks() if r[0] != "A-03a"]
    parts = [f"SELECT set_config('{fail}', '0', false) AS r1, set_config('{count}', '0', false) AS r2 \\gset x_",
             "SET search_path = pg_catalog, postgis;"]
    static = e7.extension_checks(with_gis_schema=True) + [inventory_row(phase == "after")] + iso
    if phase == "after":
        static += index_state_rows()
    static += e7.construction_checks()
    if phase == "after":
        static += recorded_rows()
    parts.append(static_count_block("static", static, fail, count))
    parts.append(fingerprint_block())
    if phase == "after":
        parts.append(matrix_block(correctness_rows(), fail, count))
        k1 = query_sql("K1", "Y-0")
        k1g = query_sql("K1g", "G-0")
        parts.append(f"""DO $info$
BEGIN
    RAISE NOTICE 'INFO K1 (geography, metres) vs K1g (geometry, degrees) at Reykjavik: common log_ids %', (SELECT count(*) FROM ({k1}) a JOIN ({k1g}) b ON b.log_id = a.log_id);
END
$info$;""")
    total = len(static) + (len(correctness_rows()) * 3 if phase == "after" else 0)
    parts.append(f"""DO $verdict$
BEGIN
    IF current_setting('{fail}')::integer > 0 THEN
        RAISE EXCEPTION 'sql/50 phase {phase} FAILED: % of % checks', current_setting('{fail}'), current_setting('{count}') USING ERRCODE = 'LR024';
    END IF;
    IF current_setting('{count}')::integer <> {total} THEN
        RAISE EXCEPTION 'sql/50 phase {phase}: % checks ran, {total} expected', current_setting('{count}') USING ERRCODE = 'LR024';
    END IF;
    RAISE NOTICE 'sql/50 phase {phase} PASSED: all {total} checks';
END
$verdict$;""")
    return "\n".join(parts)


HEADER = """-- =============================================================================
-- Step 7C / {title}
-- =============================================================================
-- GENERATED by scripts/step7c_spatial_index_experiment.py - do not edit by hand. Run by sql/run_step7c_spatial_indexes.ps1.
-- Design: docs/Step7C_Spatial_Index_Experiment_Design.md (approved).
{body}
-- =============================================================================
"""


def approved_guard(var, value, errcode, message):
    return ["\\set ON_ERROR_STOP on", f"\\if :{{?{var}}}", f"SELECT :'{var}' = '{value}' AS approved \\gset", "\\else", "\\set approved false", "\\endif",
            "\\if :approved", "\\else", f"DO $refuse$ BEGIN RAISE EXCEPTION '{message}' USING ERRCODE = '{errcode}'; END $refuse$;", "\\endif"]


def size_block(phase):
    return f"""DO $size$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT c.relname, pg_relation_size(c.oid) AS heap, pg_table_size(c.oid) AS tbl, pg_indexes_size(c.oid) AS idx,
                    pg_total_relation_size(c.oid) AS total, c.relpages, c.reltuples
             FROM pg_class c WHERE c.relnamespace = '{W}'::regnamespace AND c.relkind = 'r' ORDER BY c.relname LOOP
        RAISE NOTICE '@@TABLESIZE phase={phase} table=% heap=% table_size=% indexes=% total=% relpages=% reltuples=%',
            r.relname, r.heap, r.tbl, r.idx, r.total, r.relpages, r.reltuples;
    END LOOP;
    FOR r IN SELECT ic.relname AS idx, c.relname AS tbl, am.amname, pg_relation_size(ic.oid) AS bytes, ic.relpages, ic.reltuples,
                    coalesce(array_to_string(ic.reloptions, ','), '') AS opts
             FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid JOIN pg_am am ON am.oid = ic.relam
             WHERE c.relnamespace = '{W}'::regnamespace AND NOT i.indisprimary ORDER BY ic.relname LOOP
        RAISE NOTICE '@@INDEXSIZE phase={phase} index=% table=% method=% bytes=% relpages=% reltuples=% options=%',
            r.idx, r.tbl, r.amname, r.bytes, r.relpages, r.reltuples, r.opts;
    END LOOP;
END
$size$;"""


def generate_sql49():
    header = HEADER.format(title="49 - Build the 10 approved spatial indexes, 3 timed builds each", body=(
        "-- Refuses without -v approved_step=7C (LR023). Each build: DO block with clock_timestamp and WAL insert-LSN difference;\n"
        "-- builds 1 and 2 are dropped, build 3 is kept. Statements are byte-identical to sql/48. ANALYZE of all 15 tables at the end."))
    lines = [header] + approved_guard("approved_step", "7C", "LR023", "sql/49 is the Step 7C build; run it only with -v approved_step=7C")
    lines += [f"""DO $guard$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'postgis') IS DISTINCT FROM '3.6.2'
       OR (SELECT count(*) FROM pg_class WHERE relnamespace = '{W}'::regnamespace AND relkind = 'r') <> 15
       OR (SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = '{W}'::regnamespace AND NOT i.indisprimary) <> 0 THEN
        RAISE EXCEPTION 'sql/49 refused: not in the verified Step 7B state (postgis 3.6.2, 15 tables, no secondary index)' USING ERRCODE = 'LR023';
    END IF;
END
$guard$;""", "SET maintenance_work_mem = '64MB';", "SET max_parallel_maintenance_workers = 0;", size_block("before")]
    for iid, stmt in e7.INDEXES:
        name = INDEX_NAME[iid]
        for build in (1, 2, 3):
            drop = f"\n    EXECUTE {lit('DROP INDEX ' + W + '.' + name)};" if build < 3 else ""
            lines.append(f"""DO $build$
DECLARE
    v_t0  timestamptz;
    v_l0  pg_lsn;
    v_ms  numeric;
    v_wal numeric;
BEGIN
    v_l0 := pg_current_wal_insert_lsn();
    v_t0 := clock_timestamp();
    EXECUTE {lit(stmt.rstrip(';'))};
    v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
    v_wal := pg_wal_lsn_diff(pg_current_wal_insert_lsn(), v_l0);
    RAISE NOTICE '@@BUILD id={iid} index={name} build={build} ms=% wal=% bytes=% relpages=%', round(v_ms, 3), v_wal,
        pg_relation_size(to_regclass('{W}.{name}')), (SELECT relpages FROM pg_class WHERE oid = to_regclass('{W}.{name}'));{drop}
END
$build$;""")
    lines += [f"ANALYZE {W}.{n};" for n in e7.TABLE_NAMES]
    lines += [size_block("after"), ""]
    return "\n".join(lines)


def generate_sql50():
    header = HEADER.format(title="50 - Read-only verification of the index phase (-v phase=before|after)", body=(
        "-- before: extension, isolation, no secondary index, Step 7B construction/copy checks, table fingerprints.\n"
        "-- after: additionally the 10 index definitions, recorded oracle values and the 202-row correctness matrix in three plan\n"
        "-- modes (default; enable_seqscan off; enable_indexscan and enable_bitmapscan off). LR024 on any failure."))
    lines = [header, "\\set ON_ERROR_STOP on",
             "\\if :{?phase}", "\\else",
             "DO $refuse$ BEGIN RAISE EXCEPTION 'sql/50 requires -v phase=before or -v phase=after' USING ERRCODE = 'LR024'; END $refuse$;",
             "\\endif",
             "SELECT :'phase' = 'before' AS phase_before, :'phase' = 'after' AS phase_after \\gset",
             "\\if :phase_before", sql50_body("before"), "\\elif :phase_after", sql50_body("after"), "\\else",
             "DO $refuse$ BEGIN RAISE EXCEPTION 'sql/50 requires -v phase=before or -v phase=after' USING ERRCODE = 'LR024'; END $refuse$;",
             "\\endif", ""]
    return "\n".join(lines)


def generate_sql51():
    header = HEADER.format(title="51 - EXPLAIN ANALYZE measurement session (-v session=1|2), read-only", body=(
        "-- 23 query blocks, 192 series: 3 warm-up + 15 measured rounds (all configurations of the block in each round, order rotated\n"
        "-- and reversed on alternate rounds), 1 TIMING ON detail run and 1 forced diagnostic (enable_seqscan off) per series."))
    lines = [header, "\\set ON_ERROR_STOP on", "\\set QUIET on", "\\pset format unaligned", "\\pset tuples_only on", "\\pset footer off",
             "\\if :{?session}", "\\else",
             "DO $refuse$ BEGIN RAISE EXCEPTION 'sql/51 requires -v session=1 or -v session=2' USING ERRCODE = 'LR025'; END $refuse$;",
             "\\endif", "SELECT :'session' IN ('1', '2') AS session_ok \\gset", "\\if :session_ok", "\\else",
             "DO $refuse$ BEGIN RAISE EXCEPTION 'sql/51 requires -v session=1 or -v session=2' USING ERRCODE = 'LR025'; END $refuse$;", "\\endif",
             f"""DO $guard$
BEGIN
    IF current_setting('transaction_read_only') <> 'on'
       OR (SELECT extversion FROM pg_extension WHERE extname = 'postgis') IS DISTINCT FROM '3.6.2'
       OR (SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = '{W}'::regnamespace AND NOT i.indisprimary) <> 10 THEN
        RAISE EXCEPTION 'sql/51 refused: needs a read-only session, postgis 3.6.2 and the 10 built indexes' USING ERRCODE = 'LR025';
    END IF;
END
$guard$;""",
             "SET jit = off;", "SET max_parallel_workers_per_gather = 0;", "SET TimeZone = 'UTC';", "SET track_io_timing = on;",
             "SET search_path = pg_catalog, postgis;",
             "SELECT '@@ENV session=' || :'session' || ' pid=' || pg_backend_pid() || ' start=' || clock_timestamp() || ' ' || version();"]
    for bid, series in blocks():
        lines.append(f"SELECT '@@ACTIVE {bid} ' || count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() AND state IS DISTINCT FROM 'idle';")
        for r in range(WARMUP + MEASURED):
            kind, rnd = ("warmup", r + 1) if r < WARMUP else ("measured", r - WARMUP + 1)
            for q, c in round_order(series, r):
                lines += [f"\\qecho @@RUN {bid} {q} {c} {kind} {rnd}", f"{EXPLAIN_MEASURE} {query_sql(q, c)};", "\\qecho @@END"]
        for q, c in series:
            lines += [f"\\qecho @@RUN {bid} {q} {c} detail 1", f"{EXPLAIN_DETAIL} {query_sql(q, c)};", "\\qecho @@END"]
        lines.append("SET enable_seqscan = off;")
        for q, c in series:
            lines += [f"\\qecho @@RUN {bid} {q} {c} forced 1", f"{EXPLAIN_DETAIL} {query_sql(q, c)};", "\\qecho @@END"]
        lines.append("RESET enable_seqscan;")
    lines += ["SELECT '@@SESSION_END ' || clock_timestamp();", ""]
    return "\n".join(lines)


def generate_sql52():
    header = HEADER.format(title="52 - Cleanup: drop the 10 Step 7C indexes (back to the Step 7B state)", body=(
        "-- Run only on request or after a failed build, with -v confirm_cleanup=yes (LR026). Drops exactly the 10 designed names."))
    lines = [header] + approved_guard("confirm_cleanup", "yes", "LR026", "sql/52 drops the Step 7C indexes; run it only with -v confirm_cleanup=yes")
    lines += [f"DROP INDEX IF EXISTS {W}.{INDEX_NAME[i]};" for i, _s in e7.INDEXES]
    lines += [f"ANALYZE {W}.{t};" for t in sorted(set(INDEX_TABLE.values()))]
    return "\n".join(lines) + "\n"


def harness_text():
    lines = ["-- Step 7C rolled-back harness (generated): 1 build per index, ANALYZE, sql/50 phase after, then ROLLBACK.",
             "\\set ON_ERROR_STOP on", "BEGIN;", "SET LOCAL maintenance_work_mem = '64MB';", "SET LOCAL max_parallel_maintenance_workers = 0;"]
    lines += [s for _i, s in e7.INDEXES]
    lines += [f"ANALYZE {W}.{n};" for n in e7.TABLE_NAMES]
    lines.append(sql50_body("after"))
    lines += ["DO $harness$ BEGIN RAISE NOTICE 'Step 7C harness PASSED: 10 builds, ANALYZE, sql/50 phase after inside one transaction'; END $harness$;",
              "ROLLBACK;", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------------------------------
# static check
# ---------------------------------------------------------------------------------------------------------------------
STMT = re.compile(r"^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|COPY|VACUUM|ANALYZE|GRANT|REVOKE|COMMENT|REINDEX|CLUSTER|SET|RESET|"
                  r"BEGIN|COMMIT|ROLLBACK|DO|LOAD|SECURITY|CALL|MERGE|REFRESH|LOCK|DISCARD|IMPORT|EXPLAIN|EXECUTE)\b", re.IGNORECASE)
TNAMES = "(" + "|".join(e7.TABLE_NAMES) + ")"
INAMES = "(" + "|".join(INDEX_NAME.values()) + ")"


def static_check():
    problems, summary = [], {}
    stmts48 = [s.rstrip(";") for _i, s in e7.INDEXES]
    sql48 = e7.SQL48.read_text(encoding="ascii")
    for s in e7.INDEXES:
        if s[1] not in sql48:
            problems.append(f"sql/48 does not contain {s[1][:60]}")
    for key, path in {"49": SQL49, "50": SQL50, "51": SQL51, "52": SQL52}.items():
        text = path.read_text(encoding="ascii")
        code = [line for line in text.split("\n") if not line.lstrip().startswith("--")]
        stmts = [line.strip() for line in code if STMT.match(line)]
        bad = []
        creates = drops = 0
        for s in stmts:
            ok = False
            if re.match(r"^(BEGIN;?|DO \$(guard|build|size|static|fp|matrix|info|verdict|harness)\$)$", s) or re.match(r"^DO \$refuse\$ BEGIN RAISE EXCEPTION .* END \$refuse\$;$", s):
                ok = True
            elif key == "49":
                m = re.match(r"^EXECUTE '(.*)';$", s)
                if m:
                    inner = m.group(1).replace("''", "'")
                    if inner in stmts48:
                        ok, creates = True, creates + 1
                    elif re.match(r"^DROP INDEX log_regex_gis\." + INAMES + "$", inner):
                        ok, drops = True, drops + 1
                ok = ok or s in ("SET maintenance_work_mem = '64MB';", "SET max_parallel_maintenance_workers = 0;") \
                    or bool(re.match(r"^ANALYZE log_regex_gis\." + TNAMES + ";$", s))
            elif key == "50":
                ok = s in ("SET search_path = pg_catalog, postgis;", "EXECUTE chk.expected_sql INTO v_expected;", "EXECUTE chk.actual_sql INTO v_actual;") \
                    or s.startswith("EXECUTE format('SELECT md5(string_agg(x::text, chr(10) ORDER BY x.log_id)) FROM log_regex_gis.%I AS x', t) INTO v;")
            elif key == "51":
                ok = s in ("SET jit = off;", "SET max_parallel_workers_per_gather = 0;", "SET TimeZone = 'UTC';", "SET track_io_timing = on;",
                           "SET search_path = pg_catalog, postgis;", "SET enable_seqscan = off;", "RESET enable_seqscan;") \
                    or bool(re.match(r"^EXPLAIN \(ANALYZE, TIMING (OFF|ON), BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY, SUMMARY, FORMAT JSON\) SELECT log_id(, postgis\.ST_Distance\([^;]*\))? FROM log_regex_gis\." + TNAMES + r"[ ;]", s))
            elif key == "52":
                ok = bool(re.match(r"^DROP INDEX IF EXISTS log_regex_gis\." + INAMES + ";$", s) or re.match(r"^ANALYZE log_regex_gis\." + TNAMES + ";$", s))
            if not ok:
                bad.append(s[:160])
        refs = [line.strip()[:100] for line in code if re.search(r"\blog_regex(_json)?\.|\blog_regex_json_write\.", line)]
        writes_in_literals = [line.strip()[:100] for line in code if key in ("50", "51") and re.search(
            r"\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|VACUUM|ANALYZE|COPY|GRANT)\b", re.sub(r"^EXPLAIN \([A-Z ,]+\) ", "EXPLAIN ", line))]
        summary[key] = {"statement_lines": len(stmts), "outside_allowlist": len(bad), "existing_schema_refs": len(refs), "write_words_in_readonly": len(writes_in_literals)}
        if key == "49":
            summary[key].update({"create_executes": creates, "drop_executes": drops})
            if (creates, drops) != (30, 20):
                problems.append(f"sql/49: {creates} CREATE and {drops} DROP executions, expected 30 and 20")
        if bad:
            problems.append(f"sql/{key}: outside allowlist: {bad[0]}")
        if refs:
            problems.append(f"sql/{key}: reference to an existing schema: {refs[0]}")
        if writes_in_literals:
            problems.append(f"sql/{key}: write keyword in a read-only script: {writes_in_literals[0]}")
        if re.search(r"[^\x00-\x7f]", text):
            problems.append(f"sql/{key}: non-ASCII")
    explains = sum(1 for line in SQL51.read_text(encoding="ascii").split("\n") if line.startswith("EXPLAIN "))
    summary["51"]["explain_statements"] = explains
    if explains != 192 * (WARMUP + MEASURED + 2):
        problems.append(f"sql/51: {explains} EXPLAIN statements, expected {192 * (WARMUP + MEASURED + 2)}")
    print(json.dumps(summary, sort_keys=True))
    for p in problems:
        print("PROBLEM:", p)
    print("static check " + ("PASSED" if not problems else "FAILED"))
    return 0 if not problems else 1


# ==== analysis ====
def walk(node):
    yield node
    for kid in node.get("Plans", []):
        yield from walk(kid)


def shape(node):
    label = node["Node Type"]
    if node.get("Index Name"):
        label += " using " + node["Index Name"]
    elif node.get("Relation Name"):
        label += " on " + node["Relation Name"]
    kids = node.get("Plans", [])
    return label + (" [" + "; ".join(shape(k) for k in kids) + "]" if kids else "")


def parse_session(path, session):
    records, active, cur, buf, env = [], {}, None, [], ""
    for line in pathlib.Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("@@RUN "):
            _, block, q, c, kind, rnd = line.split()
            cur, buf = {"session": session, "block": block, "query": q, "config": c, "kind": kind, "round": int(rnd)}, []
        elif line == "@@END":
            plan = json.loads("\n".join(buf))[0]
            top = plan["Plan"]
            nodes = list(walk(top))
            scan = next((n for n in nodes if n.get("Relation Name") or n.get("Index Name")), {})
            used = sorted({n["Index Name"] for n in nodes if n.get("Index Name")})
            idx = CONFIG_INDEX.get(cur["config"])
            cur.update({
                "series": f"{cur['query']}@{cur['config']}", "planning_ms": plan.get("Planning Time"), "execution_ms": plan.get("Execution Time"),
                "serialization_ms": (plan.get("Serialization") or {}).get("Time"), "planning_hit": (plan.get("Planning") or {}).get("Shared Hit Blocks"),
                "planning_memory_kb": (plan.get("Planning") or {}).get("Memory Used"),
                "shared_hit": top.get("Shared Hit Blocks"), "shared_read": top.get("Shared Read Blocks"), "shared_dirtied": top.get("Shared Dirtied Blocks"),
                "temp_written": top.get("Temp Written Blocks"), "io_read_ms": top.get("I/O Read Time"),
                "top_rows": top.get("Actual Rows"), "top_plan_rows": top.get("Plan Rows"), "scan_plan_rows": scan.get("Plan Rows"),
                "scan_actual_rows": scan.get("Actual Rows"),
                "rows_removed_filter": sum(n.get("Rows Removed by Filter", 0) for n in nodes),
                "rows_removed_recheck": sum(n.get("Rows Removed by Index Recheck", 0) for n in nodes),
                "exact_heap_blocks": sum(n.get("Exact Heap Blocks", 0) for n in nodes), "lossy_heap_blocks": sum(n.get("Lossy Heap Blocks", 0) for n in nodes),
                "indexes_used": "|".join(used), "config_index": idx or "", "index_used": bool(idx and idx in used),
                "plan_shape": shape(top), "rows_ok": top.get("Actual Rows") == expected_rows(cur["query"]), "jit": "JIT" in plan})
            records.append(cur)
            cur = None
        elif line.startswith("@@ACTIVE "):
            parts = line.split()
            active[parts[1]] = int(parts[2])
        elif line.startswith("@@ENV "):
            env = line
        elif cur is not None:
            buf.append(line)
    return records, active, env


def nearest_rank(v, p):
    return v[max(1, math.ceil(p * len(v))) - 1]


def stats(values):
    v = sorted(values)
    return {"n": len(v), "min": v[0], "p25": nearest_rank(v, 0.25), "median": nearest_rank(v, 0.5), "p75": nearest_rank(v, 0.75), "max": v[-1]}


def rule(a, b):
    separated = a["p75"] < b["p25"] or b["p75"] < a["p25"]
    lo, hi = sorted([a["median"], b["median"]])
    return separated and hi > 0 and lo <= 0.9 * hi, ("A" if a["median"] < b["median"] else "B"), lo < 0.1


def summarise(records):
    out = {}
    for r in records:
        if r["kind"] != "measured":
            continue
        out.setdefault((r["session"], r["block"], r["series"]), []).append(r)
    summary = {}
    for key, rows in out.items():
        ex, pl = stats([r["execution_ms"] for r in rows]), stats([r["planning_ms"] for r in rows])
        summary[key] = {"session": key[0], "block": key[1], "series": key[2], "query": rows[0]["query"], "config": rows[0]["config"], "runs": len(rows),
                        "exec": ex, "plan": pl, "index_used_runs": sum(1 for r in rows if r["index_used"]), "indexes_used": "|".join(sorted({r["indexes_used"] for r in rows})),
                        "plan_shapes": " || ".join(sorted({r["plan_shape"] for r in rows})), "shared_hit": "|".join(sorted({str(r["shared_hit"]) for r in rows})),
                        "rows_ok": all(r["rows_ok"] for r in rows), "top_rows": rows[0]["top_rows"], "scan_plan_rows": rows[0]["scan_plan_rows"],
                        "rows_removed_filter": rows[0]["rows_removed_filter"], "rows_removed_recheck": rows[0]["rows_removed_recheck"],
                        "exact_heap_blocks": rows[0]["exact_heap_blocks"], "lossy_heap_blocks": rows[0]["lossy_heap_blocks"]}
    return summary


def compare(summary, block, a, b, klass, label, metric="exec"):
    sa, sb = summary.get(("1", block, a)), summary.get(("1", block, b))
    if not sa or not sb:
        return None
    ok, lower, small = rule(sa[metric], sb[metric])
    result = f"measurable: {a if lower == 'A' else b} faster" if ok else "not measurable"
    if small:
        s2a, s2b = summary.get(("2", block, a)), summary.get(("2", block, b))
        if s2a and s2b:
            ok2, lower2, _ = rule(s2a[metric], s2b[metric])
            same = ok2 == ok and (not ok or lower2 == lower)
            result += "; below 0.1 ms: " + ("confirmed in session 2" if same else "not confirmed in session 2")
            if not same:
                ok, result = False, "not measurable (session 2 does not confirm)"
    return {"class": klass, "label": label, "block": block, "a": a, "b": b, "metric": metric, "a_median": sa[metric]["median"], "a_p25": sa[metric]["p25"],
            "a_p75": sa[metric]["p75"], "b_median": sb[metric]["median"], "b_p25": sb[metric]["p25"], "b_p75": sb[metric]["p75"],
            "ratio_b_over_a": sb[metric]["median"] / sa[metric]["median"] if sa[metric]["median"] else None, "measurable": ok, "faster": (a if lower == "A" else b) if ok else "", "result": result,
            "a_index_used": f"{sa['index_used_runs']}/{sa['runs']}", "b_index_used": f"{sb['index_used_runs']}/{sb['runs']}"}


def verdicts(summary):
    rows = []
    for bid, series in blocks():
        present = {f"{q}@{c}" for q, c in series}
        for q, c in series:
            if c not in CONTROL:
                continue
            sid, cid = f"{q}@{c}", f"{q}@{CONTROL[c]}"
            if cid not in present:
                continue
            s = summary.get(("1", bid, sid))
            cmp = compare(summary, bid, sid, cid, "I", "index vs control")
            used_all = s["index_used_runs"] == s["runs"]
            used_any = s["index_used_runs"] > 0
            knn = q in KNN_GEOG or q in KNN_GEOM
            if knn and c in NO_ORDERING and not used_any:
                verdict = "not supported (operator class has no ordering operator)"
            elif not used_any:
                verdict = "index not used by the planner"
            elif not used_all:
                verdict = "index used in some runs only"
            elif cmp["measurable"] and cmp["faster"] == sid:
                verdict = "measurable benefit"
            elif cmp["measurable"]:
                verdict = "measurable regression"
            else:
                verdict = "index used, no measurable benefit"
            cmp.update({"verdict": verdict, "index": CONFIG_INDEX[c]})
            rows.append(cmp)
    return rows


def other_comparisons(summary):
    rows = []
    pairs_same_query = {"IM": [("G-1", "G-2"), ("G-1", "G-3"), ("G-2", "G-3"), ("Y-1", "Y-2")],
                        "F": [("G-1", "J-3"), ("G-0", "J-3c"), ("Y-1", "J-4"), ("Y-0", "J-4c")],
                        "J": [("J-1", "J-3"), ("J-2", "J-4"), ("J-0g", "J-3c"), ("J-0y", "J-4c")],
                        "NB": [("N-1", "G-1"), ("N-0", "G-0")]}
    for bid, series in blocks():
        present = {f"{q}@{c}" for q, c in series}
        queries = sorted({q for q, _c in series}, key=lambda x: (len(x), x))
        for klass, pairs in pairs_same_query.items():
            for q in queries:
                for a, b in pairs:
                    if f"{q}@{a}" in present and f"{q}@{b}" in present:
                        for metric in ("exec", "plan"):
                            r = compare(summary, bid, f"{q}@{a}", f"{q}@{b}", klass, {"IM": "index method", "F": "flat vs JSONB (same type and index)",
                                                                                       "J": "JSONB storage form", "NB": "numeric B-tree vs spatial"}[klass], metric)
                            if r:
                                rows.append(r)
        extra = []
        if bid in ("D1", "D2", "D6"):
            extra += [(f"{bid}@Y-1", f"MD{bid[1:]}@G-1"), (f"{bid}@Y-0", f"MD{bid[1:]}@G-0")]
        if bid == "K1":
            extra += [("K1@Y-1", "K1g@G-1"), ("K1@Y-0", "K1g@G-0")]
        if bid == "P":
            extra += [("P1@Y-0", "P2@Y-0")]
            for a, b in [("P4@J-0y", "P1@Y-0"), ("P4@J-0y", "P3@N-0"), ("P3@N-0", "P1@Y-0")]:
                for metric in ("exec", "plan"):
                    r = compare(summary, bid, a, b, "J", "construction cost", metric)
                    if r:
                        rows.append(r)
        for a, b in extra:
            for metric in ("exec", "plan"):
                r = compare(summary, bid, a, b, "GG", "geometry vs geography / method", metric)
                if r:
                    rows.append(r)
    return rows


def parse_builds(path):
    builds, sizes = [], []
    for line in pathlib.Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.search(r"@@BUILD id=(\S+) index=(\S+) build=(\d) ms=([\d.]+) wal=(\d+) bytes=(\d+) relpages=(\d+)", line)
        if m:
            builds.append({"id": m.group(1), "index": m.group(2), "build": int(m.group(3)), "ms": float(m.group(4)), "wal_bytes": int(m.group(5)),
                           "bytes": int(m.group(6)), "relpages": int(m.group(7))})
        m = re.search(r"@@INDEXSIZE phase=(\w+) index=(\S+) table=(\S+) method=(\S+) bytes=(\d+) relpages=(\d+) reltuples=(\S+) options=(.*)$", line)
        if m:
            sizes.append({"kind": "index", "phase": m.group(1), "name": m.group(2), "table": m.group(3), "method": m.group(4), "bytes": int(m.group(5)),
                          "relpages": int(m.group(6)), "reltuples": m.group(7), "options": m.group(8).strip()})
        m = re.search(r"@@TABLESIZE phase=(\w+) table=(\S+) heap=(\d+) table_size=(\d+) indexes=(\d+) total=(\d+) relpages=(\d+) reltuples=(\S+)", line)
        if m:
            sizes.append({"kind": "table", "phase": m.group(1), "name": m.group(2), "heap": int(m.group(3)), "table_size": int(m.group(4)),
                          "indexes": int(m.group(5)), "total": int(m.group(6)), "relpages": int(m.group(7)), "reltuples": m.group(8)})
    return builds, sizes


def write_csv(path, rows, fields=None):
    if not rows:
        return
    fields = fields or list(rows[0].keys())
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: (json.dumps(v) if isinstance(v, dict) else v) for k, v in r.items() if k in fields})


def fmt(v, d=3):
    return "" if v is None else (f"{v:.{d}f}" if isinstance(v, float) else str(v))


def analyze(args):
    out = pathlib.Path(args.out_dir)
    recs1, act1, env1 = parse_session(args.session1, "1")
    recs2, act2, env2 = parse_session(args.session2, "2")
    records = recs1 + recs2
    problems = []
    expected_exec = 192 * (WARMUP + MEASURED + 2)
    for sid, recs in (("1", recs1), ("2", recs2)):
        if len(recs) != expected_exec:
            problems.append(f"session {sid}: {len(recs)} executions, expected {expected_exec}")
    bad_rows = [r for r in records if not r["rows_ok"]]
    if bad_rows:
        problems.append(f"{len(bad_rows)} executions with an unexpected row count, first {bad_rows[0]['series']} {bad_rows[0]['kind']}")
    if any(r["jit"] for r in records):
        problems.append("JIT appeared in a plan")
    foreign = {k: v for k, v in list(act1.items()) + list(act2.items()) if v}
    summary = summarise(records)
    ver = verdicts(summary)
    other = other_comparisons(summary)
    builds, sizes = parse_builds(args.build_log)
    if len(builds) != 30:
        problems.append(f"{len(builds)} build records, expected 30")
    build_rows = []
    for iid, _s in e7.INDEXES:
        b = sorted((x for x in builds if x["id"] == iid), key=lambda x: x["build"])
        ms = sorted(x["ms"] for x in b)
        wal = sorted(x["wal_bytes"] for x in b)
        final = next((x for x in sizes if x["kind"] == "index" and x["phase"] == "after" and x["name"] == INDEX_NAME[iid]), {})
        table_after = next((x for x in sizes if x["kind"] == "table" and x["phase"] == "after" and x["name"] == INDEX_TABLE[iid]), {})
        build_rows.append({"id": iid, "index": INDEX_NAME[iid], "table": INDEX_TABLE[iid], "method": INDEX_METHOD[iid], "opclass": INDEX_OPCLASS[iid],
                           "build_ms_1": b[0]["ms"] if b else None, "build_ms_2": b[1]["ms"] if len(b) > 1 else None, "build_ms_3": b[2]["ms"] if len(b) > 2 else None,
                           "build_ms_median": ms[1] if len(ms) == 3 else None, "build_ms_min": ms[0] if ms else None, "build_ms_max": ms[-1] if ms else None,
                           "wal_bytes_median": wal[1] if len(wal) == 3 else None, "wal_bytes_min": wal[0] if wal else None, "wal_bytes_max": wal[-1] if wal else None,
                           "bytes_per_build": "|".join(str(x["bytes"]) for x in b), "size_bytes": final.get("bytes"), "relpages": final.get("relpages"),
                           "reltuples": final.get("reltuples"), "options": final.get("options"), "table_heap_bytes": table_after.get("heap"),
                           "table_relpages": table_after.get("relpages"), "table_total_after": table_after.get("total")})
    write_csv(out / "step7c_executions.csv", records)
    srows = []
    for key, s in sorted(summary.items()):
        srows.append({"session": s["session"], "block": s["block"], "series": s["series"], "query": s["query"], "config": s["config"], "runs": s["runs"],
                      "exec_median": s["exec"]["median"], "exec_p25": s["exec"]["p25"], "exec_p75": s["exec"]["p75"], "exec_min": s["exec"]["min"], "exec_max": s["exec"]["max"],
                      "plan_median": s["plan"]["median"], "plan_p25": s["plan"]["p25"], "plan_p75": s["plan"]["p75"], "index_used_runs": s["index_used_runs"],
                      "indexes_used": s["indexes_used"], "plan_shapes": s["plan_shapes"], "shared_hit": s["shared_hit"], "top_rows": s["top_rows"],
                      "scan_plan_rows": s["scan_plan_rows"], "rows_removed_filter": s["rows_removed_filter"], "rows_removed_recheck": s["rows_removed_recheck"],
                      "exact_heap_blocks": s["exact_heap_blocks"], "lossy_heap_blocks": s["lossy_heap_blocks"], "rows_ok": s["rows_ok"]})
    write_csv(out / "step7c_summary.csv", srows)
    write_csv(out / "step7c_verdicts.csv", ver)
    write_csv(out / "step7c_comparisons.csv", other)
    write_csv(out / "step7c_builds.csv", build_rows)
    write_csv(out / "step7c_sizes.csv", sizes, ["kind", "phase", "name", "table", "method", "bytes", "heap", "table_size", "indexes", "total", "relpages", "reltuples", "options"])
    # markdown
    L = ["# Step 7C - generated measurement summary", "", f"session 1: {env1}", f"session 2: {env2}",
         f"executions parsed: {len(recs1)} + {len(recs2)}; blocks with other active sessions: {foreign or 'none'}; problems: {problems or 'none'}", "",
         "## Index builds and sizes", "", "| ID | index | method | build ms median [min-max] | WAL bytes median | size bytes | pages | table heap bytes / pages |", "|---|---|---|---|---|---|---|---|"]
    for b in build_rows:
        L.append(f"| {b['id']} | {b['index']} | {b['method']} | {fmt(b['build_ms_median'])} [{fmt(b['build_ms_min'])}-{fmt(b['build_ms_max'])}] | {b['wal_bytes_median']} | "
                 f"{b['size_bytes']} | {b['relpages']} | {b['table_heap_bytes']} / {b['table_relpages']} |")
    L += ["", "## Class I - index vs control (session 1 medians ms [IQR]; verdict)", "", "| block | indexed | control | indexed ms | control ms | ratio idx/ctrl | index used | verdict |", "|---|---|---|---|---|---|---|---|"]
    for v in ver:
        L.append(f"| {v['block']} | {v['a']} | {v['b']} | {fmt(v['a_median'])} [{fmt(v['a_p25'])}-{fmt(v['a_p75'])}] | {fmt(v['b_median'])} [{fmt(v['b_p25'])}-{fmt(v['b_p75'])}] | "
                 f"{fmt(v['a_median'] / v['b_median'] if v['b_median'] else None)} | {v['a_index_used']} | {v['verdict']} |")
    for klass, title in [("IM", "Class IM - index methods"), ("F", "Class F - flat vs JSONB, same type and index"), ("J", "Class J - JSONB storage forms and construction"),
                         ("GG", "Class GG - geometry vs geography / method"), ("NB", "Class NB - numeric B-tree vs spatial")]:
        L += ["", f"## {title} (execution time, session 1)", "", "| block | A | B | A ms | B ms | B/A | result |", "|---|---|---|---|---|---|---|"]
        for r in other:
            if r["class"] == klass and r["metric"] == "exec":
                L.append(f"| {r['block']} | {r['a']} | {r['b']} | {fmt(r['a_median'])} | {fmt(r['b_median'])} | {fmt(r['ratio_b_over_a'])} | {r['result']} |")
    L += ["", "## Plan shapes (session 1, measured runs)", "", "| series | plan shape | shared hit |", "|---|---|---|"]
    for s in srows:
        if s["session"] == "1":
            L.append(f"| {s['series']} | {s['plan_shapes']} | {s['shared_hit']} |")
    (out / "step7c_summary.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    counts = {}
    for v in ver:
        counts[v["verdict"]] = counts.get(v["verdict"], 0) + 1
    print(f"executions {len(recs1)}+{len(recs2)}, series {len({k[2] for k in summary})}, class I verdicts {len(ver)}: {counts}, other comparisons {len(other)}, builds {len(builds)}")
    print("PROBLEMS: " + ("; ".join(problems) if problems else "none"))
    return 1 if problems else 0


def cmd_generate(check):
    targets = {SQL49: generate_sql49(), SQL50: generate_sql50(), SQL51: generate_sql51(), SQL52: generate_sql52()}
    stale = []
    for path, text in targets.items():
        data = text.encode("ascii")
        if check:
            if not path.exists() or path.read_bytes().replace(b"\r\n", b"\n") != data:
                stale.append(path.name)
        else:
            path.write_bytes(data)
            print(f"wrote {path.relative_to(ROOT)} ({len(data)} bytes)")
    if check:
        print("stale: " + ", ".join(stale) if stale else "generated SQL files are up to date: sql/49, sql/50, sql/51, sql/52")
        return 1 if stale else 0
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--check", action="store_true")
    h = sub.add_parser("harness")
    h.add_argument("out")
    sub.add_parser("static-check")
    a = sub.add_parser("analyze")
    a.add_argument("--session1", required=True)
    a.add_argument("--session2", required=True)
    a.add_argument("--build-log", required=True)
    a.add_argument("--out-dir", default=str(ANALYSIS))
    args = parser.parse_args()
    if args.command == "generate":
        return cmd_generate(args.check)
    if args.command == "harness":
        pathlib.Path(args.out).write_bytes(harness_text().encode("ascii"))
        print(f"harness written: {args.out}")
        return 0
    if args.command == "static-check":
        return static_check()
    return analyze(args)


if __name__ == "__main__":
    sys.exit(main())
