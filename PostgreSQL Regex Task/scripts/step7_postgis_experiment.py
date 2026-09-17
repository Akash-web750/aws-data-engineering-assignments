#!/usr/bin/env python3
"""Step 7B - PostGIS experiment setup: generated SQL and the rolled-back harness.

Plan: docs/Step7B_PostGIS_Setup_Preflight.md (approved). Design: docs/Step7A_PostGIS_Experiment_Design.md.

  python -B scripts/step7_postgis_experiment.py generate [--check]   sql/45, sql/46, sql/47, sql/48
  python -B scripts/step7_postgis_experiment.py harness OUT          sql/45 + sql/46 + ANALYZE + sql/47 + E4, then ROLLBACK
  python -B scripts/step7_postgis_experiment.py static-check         statement allowlist of the generated files

Single source of the schema, the 15 tables, the 4 point expressions, the 10 Step 7C index statements and every check.
Points are always postgis.ST_MakePoint(longitude, latitude) with SRID 4326. Standard library only.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SQL45 = ROOT / "sql" / "45_create_postgis_extension.sql"
SQL46 = ROOT / "sql" / "46_create_gis_tables.sql"
SQL47 = ROOT / "sql" / "47_verify_gis_setup.sql"
SQL48 = ROOT / "sql" / "48_build_gis_indexes.sql"
W = "log_regex_gis"
POSTGIS_VERSION = "3.6.2"
FLAT_FINGERPRINT = "f562354dbf6c155f3ed0a93da433e79c"
JSONB_FINGERPRINT = "fb3bc16318e6a81c7930aed2217986ea"
BOTH_VALID = 4161
LON_BEYOND_90 = 856
BOUNDARY = "2122=0.0000000,0.0000000;2272=90.0000000,180.0000000;2280=-90.0000000,-180.0000000"
EARTH_RADIUS_SPHERE = "6371008.7714"
EXISTING_SCHEMAS = ["log_regex", "log_regex_json", "log_regex_json_write", "public"]
OPCLASSES = ["brin_geometry_inclusion_ops_2d", "gist_geography_ops", "gist_geometry_ops_2d", "spgist_geography_ops_nd",
             "spgist_geometry_ops_2d"]

E_FLAT_GEOM = "postgis.ST_SetSRID(postgis.ST_MakePoint(longitude_degrees::float8, latitude_degrees::float8), 4326)"
E_FLAT_GEOG = "postgis.geography(" + E_FLAT_GEOM + ")"
E_JSONB_GEOM = ("postgis.ST_SetSRID(postgis.ST_MakePoint((doc->'fields'->'longitude'->>'degrees')::float8, "
                "(doc->'fields'->'latitude'->>'degrees')::float8), 4326)")
E_JSONB_GEOG = "postgis.geography(" + E_JSONB_GEOM + ")"

# id, table, kind, loaded from
TABLES = [
    ("N-0", "flat_numeric", "numeric", "log_regex.access_log_flat"),
    ("N-1", "flat_numeric_btree", "numeric", W + ".flat_numeric"),
    ("G-0", "flat_geom", "flat_geom", W + ".flat_numeric"),
    ("G-1", "flat_geom_gist", "flat_geom", W + ".flat_numeric"),
    ("G-2", "flat_geom_spgist", "flat_geom", W + ".flat_numeric"),
    ("G-3", "flat_geom_brin", "flat_geom", W + ".flat_numeric"),
    ("Y-0", "flat_geog", "flat_geog", W + ".flat_numeric"),
    ("Y-1", "flat_geog_gist", "flat_geog", W + ".flat_numeric"),
    ("Y-2", "flat_geog_spgist", "flat_geog", W + ".flat_numeric"),
    ("J-0", "jsonb_doc", "doc", "log_regex_json.access_log_jsonb"),
    ("J-X", "jsonb_doc_expr", "doc", W + ".jsonb_doc"),
    ("J-3c", "jsonb_geom", "jsonb_geom", W + ".jsonb_doc"),
    ("J-3", "jsonb_geom_gist", "jsonb_geom", W + ".jsonb_doc"),
    ("J-4c", "jsonb_geog", "jsonb_geog", W + ".jsonb_doc"),
    ("J-4", "jsonb_geog_gist", "jsonb_geog", W + ".jsonb_doc"),
]
TABLE_NAMES = [t[1] for t in TABLES]

INDEXES = [
    ("N-1", "CREATE INDEX flat_numeric_btree_lat_lon_idx ON log_regex_gis.flat_numeric_btree USING btree (latitude_degrees, longitude_degrees);"),
    ("G-1", "CREATE INDEX flat_geom_gist_idx ON log_regex_gis.flat_geom_gist USING gist (geom postgis.gist_geometry_ops_2d);"),
    ("G-2", "CREATE INDEX flat_geom_spgist_idx ON log_regex_gis.flat_geom_spgist USING spgist (geom postgis.spgist_geometry_ops_2d);"),
    ("G-3", "CREATE INDEX flat_geom_brin_idx ON log_regex_gis.flat_geom_brin USING brin (geom postgis.brin_geometry_inclusion_ops_2d);"),
    ("Y-1", "CREATE INDEX flat_geog_gist_idx ON log_regex_gis.flat_geog_gist USING gist (geog postgis.gist_geography_ops);"),
    ("Y-2", "CREATE INDEX flat_geog_spgist_idx ON log_regex_gis.flat_geog_spgist USING spgist (geog postgis.spgist_geography_ops_nd);"),
    ("J-1", "CREATE INDEX jsonb_doc_expr_geom_gist_idx ON log_regex_gis.jsonb_doc_expr USING gist ((" + E_JSONB_GEOM + ") postgis.gist_geometry_ops_2d);"),
    ("J-2", "CREATE INDEX jsonb_doc_expr_geog_gist_idx ON log_regex_gis.jsonb_doc_expr USING gist ((" + E_JSONB_GEOG + ") postgis.gist_geography_ops);"),
    ("J-3", "CREATE INDEX jsonb_geom_gist_idx ON log_regex_gis.jsonb_geom_gist USING gist (geom postgis.gist_geometry_ops_2d);"),
    ("J-4", "CREATE INDEX jsonb_geog_gist_idx ON log_regex_gis.jsonb_geog_gist USING gist (geog postgis.gist_geography_ops);"),
]

CENTRES = {"NewYork": ("40.7128", "-74.0060"), "Mumbai": ("19.0760", "72.8777"), "Reykjavik": ("64.1466", "-21.9426"),
           "London": ("51.5074", "-0.1278"), "Antimeridian": ("0.0", "180.0"), "NorthPole": ("90.0", "0.0")}
# id, s, w, n, e, expected rows
BOXES = [("B1", "40.4", "-74.3", "41.0", "-73.6", 410), ("B2", "35", "-10", "60", "30", 416), ("B3", "8", "68", "23", "80", 1580),
         ("B4", "-60", "-130", "70", "150", 3897), ("B5", "-60", "170", "70", "-170", 0), ("B6", "80", "-180", "90", "180", 1)]
# id, centre, radius metres, expected rows (sphere oracle)
DISTANCES = [("D1", "NewYork", "10000", 410), ("D2", "Mumbai", "500000", 1101), ("D3", "Reykjavik", "2000000", 599),
             ("D4", "Mumbai", "5000000", 2059), ("D5", "Antimeridian", "5000000", 262), ("D6", "London", "1000", 15),
             ("D7", "NorthPole", "100000", 1)]
KNN_EXPECTED = "772.7:1|3273.8:1"


def lit(text):
    return "'" + str(text).replace("'", "''") + "'"


def table_ddl(name, kind):
    cols = {
        "numeric": ["latitude_degrees  numeric(10,7)", "longitude_degrees numeric(10,7)"],
        "flat_geom": ["geom   postgis.geometry(Point, 4326)"],
        "flat_geog": ["geog   postgis.geography(Point, 4326)"],
        "doc": ["doc    jsonb   NOT NULL"],
        "jsonb_geom": ["doc    jsonb   NOT NULL", "geom   postgis.geometry(Point, 4326) GENERATED ALWAYS AS (" + E_JSONB_GEOM + ") STORED"],
        "jsonb_geog": ["doc    jsonb   NOT NULL", "geog   postgis.geography(Point, 4326) GENERATED ALWAYS AS (" + E_JSONB_GEOG + ") STORED"],
    }[kind]
    lines = [f"CREATE TABLE {W}.{name} (", "    log_id integer NOT NULL,"] + [f"    {c}," for c in cols]
    lines += [f"    CONSTRAINT {name}_pkey PRIMARY KEY (log_id)", ") WITH (autovacuum_enabled = false);"]
    return "\n".join(lines)


def table_load(name, kind, source):
    if kind == "numeric":
        return (f"INSERT INTO {W}.{name} (log_id, latitude_degrees, longitude_degrees)\n"
                f"SELECT log_id, latitude_degrees, longitude_degrees FROM {source} ORDER BY log_id;")
    if kind == "flat_geom":
        return f"INSERT INTO {W}.{name} (log_id, geom)\nSELECT log_id, {E_FLAT_GEOM} FROM {source} ORDER BY log_id;"
    if kind == "flat_geog":
        return f"INSERT INTO {W}.{name} (log_id, geog)\nSELECT log_id, {E_FLAT_GEOG} FROM {source} ORDER BY log_id;"
    return f"INSERT INTO {W}.{name} (log_id, doc)\nSELECT log_id, doc FROM {source} ORDER BY log_id;"


# ----------------------------------------------------------------------------------------------------------------------
# checks: (id, name, expected SQL expression, actual SQL expression); both must yield text
# ----------------------------------------------------------------------------------------------------------------------
def alias_doc(expr):
    return expr.replace("(doc->", "(t.doc->")


POINT_SOURCES = []   # (label, table, point expression on alias t, is_geography)
for _n in ["flat_geom", "flat_geom_gist", "flat_geom_spgist", "flat_geom_brin", "jsonb_geom", "jsonb_geom_gist"]:
    POINT_SOURCES.append((_n, _n, "t.geom", False))
POINT_SOURCES.append(("jsonb_doc_expr:geom", "jsonb_doc_expr", alias_doc(E_JSONB_GEOM), False))
for _n in ["flat_geog", "flat_geog_gist", "flat_geog_spgist", "jsonb_geog", "jsonb_geog_gist"]:
    POINT_SOURCES.append((_n, _n, "t.geog", True))
POINT_SOURCES.append(("jsonb_doc_expr:geog", "jsonb_doc_expr", alias_doc(E_JSONB_GEOG), True))


def construction_checks():
    rows = []
    for name in TABLE_NAMES:
        rows.append((f"O-1a:{name}", f"{name}: 5,000 rows, log_id set = flat_numeric (rows/unmatched)", "'5000/0'",
                     f"(SELECT count(*) || '/' || count(*) FILTER (WHERE t.log_id IS NULL OR f.log_id IS NULL) "
                     f"FROM {W}.{name} t FULL JOIN {W}.flat_numeric f ON f.log_id = t.log_id)"))
    for label, table, p, geog in POINT_SOURCES:
        g = f"({p})::postgis.geometry" if geog else p
        base = f"FROM {W}.{table} t JOIN {W}.flat_numeric f ON f.log_id = t.log_id"
        rows.append((f"O-1b:{label}", f"{label}: non-NULL points / NULL where the flat pair is not both VALID (mismatches)",
                     f"'{BOTH_VALID}/0'",
                     f"(SELECT count(*) FILTER (WHERE {p} IS NOT NULL) || '/' || count(*) FILTER (WHERE ({p} IS NULL) <> "
                     f"(f.latitude_degrees IS NULL OR f.longitude_degrees IS NULL)) {base})"))
        rows.append((f"O-1c:{label}", f"{label}: exact coordinates, round(ST_X,7) = longitude and round(ST_Y,7) = latitude",
                     f"'{BOTH_VALID}'",
                     f"(SELECT count(*) FILTER (WHERE round(postgis.ST_X({g})::numeric, 7) = f.longitude_degrees "
                     f"AND round(postgis.ST_Y({g})::numeric, 7) = f.latitude_degrees)::text {base})"))
        rows.append((f"O-1d:{label}", f"{label}: SRID 4326, GeometryType POINT, ST_IsValid", f"'{BOTH_VALID}'",
                     f"(SELECT count(*) FILTER (WHERE postgis.ST_SRID({p}) = 4326 AND postgis.GeometryType({g}) = 'POINT' "
                     f"AND postgis.ST_IsValid({g}))::text {base})"))
        ident = f"postgis.ST_AsEWKB({g}) IS NOT DISTINCT FROM postgis.ST_AsEWKB(r.geom)"
        if geog:
            ident += f" AND postgis.ST_AsBinary({p}) IS NOT DISTINCT FROM postgis.ST_AsBinary(postgis.geography(r.geom))"
        rows.append((f"O-1e:{label}", f"{label}: byte-identical to flat_geom (EWKB{'; geography binary = geography(flat_geom)' if geog else ''})",
                     "'5000'",
                     f"(SELECT count(*) FILTER (WHERE {ident})::text FROM {W}.{table} t JOIN {W}.flat_geom r ON r.log_id = t.log_id)"))
        rows.append((f"O-1f:{label}", f"{label}: axis order (|longitude| > 90 points with ST_X = longitude, |ST_Y| <= 90) | boundary rows",
                     lit(f"{LON_BEYOND_90}|{BOUNDARY}"),
                     f"(SELECT count(*) FILTER (WHERE abs(f.longitude_degrees) > 90 AND round(postgis.ST_X({g})::numeric, 7) = f.longitude_degrees "
                     f"AND abs(postgis.ST_Y({g})) <= 90) || '|' || string_agg(t.log_id || '=' || round(postgis.ST_Y({g})::numeric, 7) || ',' "
                     f"|| round(postgis.ST_X({g})::numeric, 7), ';' ORDER BY t.log_id) FILTER (WHERE t.log_id IN (2122, 2272, 2280)) {base})"))
    for name, col, typ in [("flat_geom", "geom", "geometry"), ("flat_geom_gist", "geom", "geometry"), ("flat_geom_spgist", "geom", "geometry"),
                           ("flat_geom_brin", "geom", "geometry"), ("jsonb_geom", "geom", "geometry"), ("jsonb_geom_gist", "geom", "geometry"),
                           ("flat_geog", "geog", "geography"), ("flat_geog_gist", "geog", "geography"), ("flat_geog_spgist", "geog", "geography"),
                           ("jsonb_geog", "geog", "geography"), ("jsonb_geog_gist", "geog", "geography")]:
        rows.append((f"O-1d-type:{name}", f"{name}.{col} column type is {typ}(Point,4326)", "'true'",
                     f"(SELECT (format_type(a.atttypid, a.atttypmod) ~ '^(postgis[.])?{typ}[(]Point,4326[)]$')::text "
                     f"FROM pg_attribute a WHERE a.attrelid = '{W}.{name}'::regclass AND a.attname = '{col}')"))
    for name, col, geog in [("jsonb_geom", "geom", False), ("jsonb_geom_gist", "geom", False), ("jsonb_geog", "geog", True), ("jsonb_geog_gist", "geog", True)]:
        cond = ("e LIKE '%st_setsrid(%' AND e LIKE '%st_makepoint(%' AND e LIKE '%4326%' AND strpos(e, 'longitude') > 0 "
                "AND strpos(e, 'longitude') < strpos(e, 'latitude')")
        if geog:
            cond += " AND (e LIKE '%geography(%' OR e LIKE '%::postgis.geography%' OR e LIKE '%::geography%')"
        rows.append((f"O-1g:{name}", f"{name}.{col} is a stored generated column built with ST_MakePoint(longitude, latitude), SRID 4326",
                     "'s/true'",
                     f"(SELECT a.attgenerated::text || '/' || ({cond})::text FROM pg_attribute a JOIN pg_attrdef d ON d.adrelid = a.attrelid "
                     f"AND d.adnum = a.attnum CROSS JOIN LATERAL (SELECT lower(pg_get_expr(d.adbin, d.adrelid)) AS e) x "
                     f"WHERE a.attrelid = '{W}.{name}'::regclass AND a.attname = '{col}')"))
    rows.append(("O-7a", "flat_numeric fingerprint = source access_log_flat fingerprint", lit(FLAT_FINGERPRINT),
                 f"(SELECT md5(string_agg(log_id || ':' || coalesce(latitude_degrees::text, 'NULL') || ':' || coalesce(longitude_degrees::text, 'NULL'), "
                 f"chr(10) ORDER BY log_id)) FROM {W}.flat_numeric)"))
    rows.append(("O-7b:jsonb_doc", "jsonb_doc fingerprint = source access_log_jsonb fingerprint", lit(JSONB_FINGERPRINT),
                 f"(SELECT md5(string_agg(log_id || ':' || doc::text, chr(10) ORDER BY log_id)) FROM {W}.jsonb_doc)"))
    for name in ["jsonb_doc_expr", "jsonb_geom", "jsonb_geom_gist", "jsonb_geog", "jsonb_geog_gist"]:
        rows.append((f"O-7b:{name}", f"{name}.doc = jsonb_doc.doc", "'5000'",
                     f"(SELECT count(*) FILTER (WHERE t.doc = j.doc)::text FROM {W}.{name} t JOIN {W}.jsonb_doc j ON j.log_id = t.log_id)"))
    rows.append(("O-7c", "flat_numeric_btree = flat_numeric (IS NOT DISTINCT FROM on both columns)", "'5000'",
                 f"(SELECT count(*) FILTER (WHERE t.latitude_degrees IS NOT DISTINCT FROM f.latitude_degrees "
                 f"AND t.longitude_degrees IS NOT DISTINCT FROM f.longitude_degrees)::text "
                 f"FROM {W}.flat_numeric_btree t JOIN {W}.flat_numeric f ON f.log_id = t.log_id)"))
    return rows


def extension_checks(with_gis_schema):
    schemas = sorted(EXISTING_SCHEMAS + ["postgis"] + ([W] if with_gis_schema else []))
    return [
        ("X-01", "installed extensions", "'plpgsql 1.0 pg_catalog, postgis 3.6.2 postgis'",
         "(SELECT string_agg(extname || ' ' || extversion || ' ' || extnamespace::regnamespace::text, ', ' ORDER BY extname) FROM pg_extension)"),
        ("X-02", "postgis_lib_version()", lit(POSTGIS_VERSION), "(SELECT postgis.postgis_lib_version())"),
        ("X-03", "spatial_ref_sys SRID 4326 authority", "'EPSG/4326'",
         "(SELECT auth_name || '/' || auth_srid FROM postgis.spatial_ref_sys WHERE srid = 4326)"),
        ("X-04", "operator classes of the design in schema postgis", lit(",".join(OPCLASSES)),
         "(SELECT string_agg(opcname, ',' ORDER BY opcname COLLATE \"C\") FROM pg_opclass WHERE opcnamespace = 'postgis'::regnamespace AND opcname IN ("
         + ", ".join(lit(o) for o in OPCLASSES) + "))"),
        ("X-05", "IMMUTABLE: ST_MakePoint(float8, float8) / ST_SetSRID(geometry, integer) / geography(geometry)", "'i/i/i'",
         "((SELECT provolatile::text FROM pg_proc WHERE oid = 'postgis.st_makepoint(double precision, double precision)'::regprocedure) || '/' || "
         "(SELECT provolatile::text FROM pg_proc WHERE oid = 'postgis.st_setsrid(postgis.geometry, integer)'::regprocedure) || '/' || "
         "(SELECT provolatile::text FROM pg_proc WHERE oid = 'postgis.geography(postgis.geometry)'::regprocedure))"),
        ("X-06", "schemas | public relations/functions/types | event triggers", lit(",".join(schemas) + "|0/0/0|0"),
         "((SELECT string_agg(nspname, ',' ORDER BY nspname COLLATE \"C\") FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema') "
         "|| '|' || (SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace) || '/' || (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace) "
         "|| '/' || (SELECT count(*) FROM pg_type WHERE typnamespace = 'public'::regnamespace) || '|' || (SELECT count(*) FROM pg_event_trigger))"),
    ]


def isolation_checks():
    inventory = sorted([("i", f"{n}_pkey") for n in TABLE_NAMES] + [("r", n) for n in TABLE_NAMES])
    return [
        ("A-03a", "log_regex_gis relations = the 15 tables and their 15 primary keys (no secondary index)",
         lit(" ".join(f"{k}:{n}" for k, n in inventory)),
         f"(SELECT string_agg(relkind::text || ':' || relname, ' ' ORDER BY relkind, relname COLLATE \"C\") FROM pg_class WHERE relnamespace = '{W}'::regnamespace)"),
        ("A-03b", "other objects in log_regex_gis (functions, triggers, policies, rules, non-PK constraints, standalone types)", "'0'",
         f"((SELECT count(*) FROM pg_proc WHERE pronamespace = '{W}'::regnamespace)"
         f" + (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE c.relnamespace = '{W}'::regnamespace)"
         f" + (SELECT count(*) FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid WHERE c.relnamespace = '{W}'::regnamespace)"
         f" + (SELECT count(*) FROM pg_rewrite r JOIN pg_class c ON c.oid = r.ev_class WHERE c.relnamespace = '{W}'::regnamespace)"
         f" + (SELECT count(*) FROM pg_constraint k WHERE k.connamespace = '{W}'::regnamespace AND k.contype <> 'p')"
         f" + (SELECT count(*) FROM pg_type ty WHERE ty.typnamespace = '{W}'::regnamespace AND ty.typrelid = 0 AND ty.typelem = 0))::text"),
        ("A-04a", "pg_depend relation edges between log_regex_gis/postgis and log_regex/log_regex_json/log_regex_json_write", "'0'",
         "(SELECT count(*)::text FROM pg_depend d JOIN pg_class c1 ON d.classid = 'pg_class'::regclass AND c1.oid = d.objid "
         "JOIN pg_class c2 ON d.refclassid = 'pg_class'::regclass AND c2.oid = d.refobjid "
         f"WHERE (c1.relnamespace IN ('{W}'::regnamespace, 'postgis'::regnamespace) AND c2.relnamespace IN ('log_regex'::regnamespace, 'log_regex_json'::regnamespace, 'log_regex_json_write'::regnamespace)) "
         f"OR (c2.relnamespace IN ('{W}'::regnamespace, 'postgis'::regnamespace) AND c1.relnamespace IN ('log_regex'::regnamespace, 'log_regex_json'::regnamespace, 'log_regex_json_write'::regnamespace)))"),
        ("A-04b", "objects of log_regex/log_regex_json/log_regex_json_write depending on PostGIS types or functions", "'0'",
         "(SELECT count(*)::text FROM pg_depend d JOIN pg_class c ON d.classid = 'pg_class'::regclass AND c.oid = d.objid "
         "LEFT JOIN pg_type ty ON d.refclassid = 'pg_type'::regclass AND ty.oid = d.refobjid "
         "LEFT JOIN pg_proc pr ON d.refclassid = 'pg_proc'::regclass AND pr.oid = d.refobjid "
         "WHERE c.relnamespace IN ('log_regex'::regnamespace, 'log_regex_json'::regnamespace, 'log_regex_json_write'::regnamespace) "
         "AND (ty.typnamespace = 'postgis'::regnamespace OR pr.pronamespace = 'postgis'::regnamespace))"),
    ]


def centre_geog(name):
    lat, lon = CENTRES[name]
    return f"postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint({lon}, {lat}), 4326))"


def haversine(lat_col, lon_col, clat, clon):
    return (f"(2 * {EARTH_RADIUS_SPHERE} * asin(least(1, sqrt(power(sin((radians({lat_col}::float8) - radians({clat})) / 2), 2) "
            f"+ cos(radians({lat_col}::float8)) * cos(radians({clat})) * power(sin((radians({lon_col}::float8) - radians({clon})) / 2), 2)))))")


def checksum(select_from_where, id_col):
    return f"(SELECT count(*) || ':' || coalesce(md5(string_agg({id_col}::text, ',' ORDER BY {id_col})), '-') {select_from_where})"


def oracle_checks():
    rows = []
    both = "f.latitude_degrees IS NOT NULL AND f.longitude_degrees IS NOT NULL"
    for bid, s, w, n, e, expected in BOXES:
        if float(w) <= float(e):
            lon = f"f.longitude_degrees BETWEEN {w} AND {e}"
            pg = f"postgis.ST_Intersects(t.geom, postgis.ST_MakeEnvelope({w}, {s}, {e}, {n}, 4326))"
        else:
            lon = f"(f.longitude_degrees >= {w} OR f.longitude_degrees <= {e})"
            pg = (f"(postgis.ST_Intersects(t.geom, postgis.ST_MakeEnvelope({w}, {s}, 180, {n}, 4326)) "
                  f"OR postgis.ST_Intersects(t.geom, postgis.ST_MakeEnvelope(-180, {s}, {e}, {n}, 4326)))")
        oracle_where = f"FROM {W}.flat_numeric f WHERE f.latitude_degrees BETWEEN {s} AND {n} AND {lon}"
        rows.append((f"O-2:{bid}", f"box {bid} (s {s}, w {w}, n {n}, e {e}): ST_Intersects on flat_geom = BETWEEN oracle (count:md5)",
                     checksum(oracle_where, "f.log_id"), checksum(f"FROM {W}.flat_geom t WHERE {pg}", "t.log_id")))
        rows.append((f"O-2n:{bid}", f"box {bid}: oracle row count", lit(expected), f"(SELECT count(*)::text {oracle_where})"))
    centre_values = ", ".join(f"({lat}::float8, {lon}::float8)" for lat, lon in CENTRES.values())
    rows.append(("O-3a", "sphere: max |ST_Distance(geog, centre, false) - haversine R=6371008.7714| over all points and 6 centres <= 0.001 m", "'true'",
                 f"(SELECT (max(abs(postgis.ST_Distance(g.geog, postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(c.lon, c.lat), 4326)), false) "
                 f"- {haversine('f.latitude_degrees', 'f.longitude_degrees', 'c.lat', 'c.lon')})) <= 0.001)::text "
                 f"FROM {W}.flat_geog g JOIN {W}.flat_numeric f ON f.log_id = g.log_id CROSS JOIN (VALUES {centre_values}) AS c (lat, lon) WHERE g.geog IS NOT NULL)"))
    rows.append(("O-4a", "spheroid vs sphere: max relative difference over all points and 6 centres < 0.6 %", "'true'",
                 f"(SELECT (max(abs(x.sph - x.sphere) / x.sphere) < 0.006)::text FROM (SELECT "
                 f"postgis.ST_Distance(g.geog, postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(c.lon, c.lat), 4326)), true) AS sph, "
                 f"postgis.ST_Distance(g.geog, postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(c.lon, c.lat), 4326)), false) AS sphere "
                 f"FROM {W}.flat_geog g CROSS JOIN (VALUES {centre_values}) AS c (lat, lon) WHERE g.geog IS NOT NULL) x WHERE x.sphere > 0)"))
    band_values = ", ".join(f"({CENTRES[c][0]}::float8, {CENTRES[c][1]}::float8, {r}::float8)" for _d, c, r, _n in DISTANCES)
    rows.append(("O-4b", "points within +-0.6 % of any timed radius D1-D7 (sphere/spheroid ambiguity band)", "'0'",
                 f"(SELECT count(*)::text FROM {W}.flat_numeric f CROSS JOIN (VALUES {band_values}) AS d (lat, lon, r) "
                 f"WHERE {both} AND abs({haversine('f.latitude_degrees', 'f.longitude_degrees', 'd.lat', 'd.lon')} - d.r) <= 0.006 * d.r)"))
    for did, centre, radius, expected in DISTANCES:
        clat, clon = CENTRES[centre]
        oracle_where = f"FROM {W}.flat_numeric f WHERE {both} AND {haversine('f.latitude_degrees', 'f.longitude_degrees', clat, clon)} <= {radius}"
        rows.append((f"O-3:{did}", f"{did} {centre} {radius} m: sphere ST_DWithin on flat_geog = haversine oracle (count:md5)",
                     checksum(oracle_where, "f.log_id"),
                     checksum(f"FROM {W}.flat_geog t WHERE postgis.ST_DWithin(t.geog, {centre_geog(centre)}, {radius}, false)", "t.log_id")))
        rows.append((f"O-4:{did}", f"{did} {centre} {radius} m: spheroid ST_DWithin on flat_geog = haversine oracle (count:md5)",
                     checksum(oracle_where, "f.log_id"),
                     checksum(f"FROM {W}.flat_geog t WHERE postgis.ST_DWithin(t.geog, {centre_geog(centre)}, {radius})", "t.log_id")))
        rows.append((f"O-3n:{did}", f"{did}: oracle row count", lit(expected), f"(SELECT count(*)::text {oracle_where})"))
    clat, clon = CENTRES["Reykjavik"]
    hv = haversine("f.latitude_degrees", "f.longitude_degrees", clat, clon)
    rows.append(("O-5a", "Reykjavik oracle: rank-10 distance:ties | rank-100 distance:ties", lit(KNN_EXPECTED),
                 f"(WITH d AS (SELECT {hv} AS m FROM {W}.flat_numeric f WHERE {both}), k AS (SELECT m, row_number() OVER (ORDER BY m) AS rn FROM d) "
                 f"SELECT round((SELECT m FROM k WHERE rn = 10)::numeric, 1) || ':' || (SELECT count(*) FROM d WHERE m = (SELECT m FROM k WHERE rn = 10)) "
                 f"|| '|' || round((SELECT m FROM k WHERE rn = 100)::numeric, 1) || ':' || (SELECT count(*) FROM d WHERE m = (SELECT m FROM k WHERE rn = 100)))"))
    for k in (10, 100):
        rows.append((f"O-5b:{k}", f"{k} nearest to Reykjavik: geography <-> set = haversine oracle set",
                     f"(SELECT md5(string_agg(log_id::text, ',' ORDER BY log_id)) FROM (SELECT f.log_id FROM {W}.flat_numeric f WHERE {both} ORDER BY {hv}, f.log_id LIMIT {k}) s)",
                     f"(SELECT md5(string_agg(log_id::text, ',' ORDER BY log_id)) FROM (SELECT t.log_id FROM {W}.flat_geog t WHERE t.geog IS NOT NULL "
                     f"ORDER BY t.geog OPERATOR(postgis.<->) {centre_geog('Reykjavik')}, t.log_id LIMIT {k}) s)"))
    p180 = "postgis.ST_SetSRID(postgis.ST_MakePoint(180, 0), 4326)"
    m180 = "postgis.ST_SetSRID(postgis.ST_MakePoint(-180, 0), 4326)"
    rows.append(("E1", "distance (0,180)-(0,-180): geography metres (3 dp) / geometry degrees", "'0.000/360'",
                 f"(SELECT round(postgis.ST_Distance(postgis.geography({p180}), postgis.geography({m180}))::numeric, 3) || '/' || postgis.ST_Distance({p180}, {m180}))"))
    rows.append(("E2", "distance between pole points (90,180) and (90,0), geography metres (3 dp)", "'0.000'",
                 "(SELECT round(postgis.ST_Distance(postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(180, 90), 4326)), "
                 "postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(0, 90), 4326)))::numeric, 3)::text)"))
    rows.append(("E3", "B6 edge point log_id 2272 (90,180): ST_Within / ST_Intersects with envelope (-180 80, 180 90)", "'false/true'",
                 f"(SELECT postgis.ST_Within(geom, postgis.ST_MakeEnvelope(-180, 80, 180, 90, 4326))::text || '/' || "
                 f"postgis.ST_Intersects(geom, postgis.ST_MakeEnvelope(-180, 80, 180, 90, 4326))::text FROM {W}.flat_geog_dummy)"))
    return rows


def info_rows():
    clat, clon = CENTRES["Reykjavik"]
    c = centre_geog("Reykjavik")
    centre_values = ", ".join(f"({lat}::float8, {lon}::float8)" for lat, lon in CENTRES.values())
    return [
        ("INFO postgis_full_version", "(SELECT postgis.postgis_full_version())"),
        ("INFO O-3a max |sphere - haversine| metres",
         f"(SELECT max(abs(postgis.ST_Distance(g.geog, postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(c.lon, c.lat), 4326)), false) "
         f"- {haversine('f.latitude_degrees', 'f.longitude_degrees', 'c.lat', 'c.lon')}))::text "
         f"FROM {W}.flat_geog g JOIN {W}.flat_numeric f ON f.log_id = g.log_id CROSS JOIN (VALUES {centre_values}) AS c (lat, lon) WHERE g.geog IS NOT NULL)"),
        ("INFO O-4a max relative |spheroid - sphere| / sphere",
         f"(SELECT max(abs(x.sph - x.sphere) / x.sphere)::text FROM (SELECT "
         f"postgis.ST_Distance(g.geog, postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(c.lon, c.lat), 4326)), true) AS sph, "
         f"postgis.ST_Distance(g.geog, postgis.geography(postgis.ST_SetSRID(postgis.ST_MakePoint(c.lon, c.lat), 4326)), false) AS sphere "
         f"FROM {W}.flat_geog g CROSS JOIN (VALUES {centre_values}) AS c (lat, lon) WHERE g.geog IS NOT NULL) x WHERE x.sphere > 0)"),
        ("INFO O-5 geography <-> semantics (100 nearest to Reykjavik): max |<-> - sphere| / max |<-> - spheroid| metres",
         f"(SELECT max(abs(x.op - x.sphere)) || ' / ' || max(abs(x.op - x.spheroid)) FROM (SELECT t.geog OPERATOR(postgis.<->) {c} AS op, "
         f"postgis.ST_Distance(t.geog, {c}, false) AS sphere, postgis.ST_Distance(t.geog, {c}, true) AS spheroid FROM {W}.flat_geog t "
         f"WHERE t.geog IS NOT NULL ORDER BY t.geog OPERATOR(postgis.<->) {c} LIMIT 100) x)"),
    ]


def check_block(tag, rows, failure_counter_setting):
    values = ",\n".join(f"            ({lit(i)}, {lit(n)}, {e}, {a})" for i, n, e, a in rows)
    return f"""DO ${tag}$
DECLARE
    v_failed integer := coalesce(nullif(current_setting('{failure_counter_setting}', true), ''), '0')::integer;
    chk      record;
BEGIN
    FOR chk IN
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
    PERFORM set_config('{failure_counter_setting}', v_failed::text, false);
END
${tag}$;"""


def verdict_block(tag, setting, errcode, label, total):
    return f"""DO ${tag}$
BEGIN
    IF current_setting('{setting}')::integer > 0 THEN
        RAISE EXCEPTION '{label} FAILED: % of {total} checks', current_setting('{setting}') USING ERRCODE = '{errcode}';
    END IF;
    RAISE NOTICE '{label} PASSED: all {total} checks';
END
${tag}$;"""


HEADER = """-- =============================================================================
-- Step 7B / {title}
-- =============================================================================
-- GENERATED by scripts/step7_postgis_experiment.py - do not edit by hand. Run by sql/run_step7b_postgis_setup.ps1.
-- Plan: docs/Step7B_PostGIS_Setup_Preflight.md (approved).
{body}
-- =============================================================================
"""


def generate_sql45():
    checks = extension_checks(with_gis_schema=False)
    header = HEADER.format(title="45 - Create the PostGIS 3.6.2 extension in schema postgis", body=(
        "-- One transaction. Guard (LR019): postgis 3.6.2 available and not installed; pg_extension = {plpgsql}; schemas postgis\n"
        "-- and log_regex_gis absent; no geometry/geography type; superuser. Gate X-01 .. X-06 before COMMIT (LR019)."))
    guard = f"""DO $guard$
BEGIN
    IF (SELECT default_version FROM pg_available_extensions WHERE name = 'postgis') IS DISTINCT FROM '{POSTGIS_VERSION}'
       OR (SELECT installed_version FROM pg_available_extensions WHERE name = 'postgis') IS NOT NULL
       OR (SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension) IS DISTINCT FROM 'plpgsql'
       OR to_regnamespace('postgis') IS NOT NULL OR to_regnamespace('{W}') IS NOT NULL
       OR EXISTS (SELECT 1 FROM pg_type WHERE typname IN ('geometry', 'geography'))
       OR NOT current_setting('is_superuser')::boolean THEN
        RAISE EXCEPTION 'sql/45 refused: PostGIS {POSTGIS_VERSION} not available, already installed, or the database is not in the verified pre-setup state'
            USING ERRCODE = 'LR019';
    END IF;
END
$guard$;"""
    return "\n".join([
        header, "\\set ON_ERROR_STOP on", "SET client_encoding = 'UTF8';", "", "BEGIN;", "SET LOCAL lock_timeout = '10s';", "", guard, "",
        "CREATE SCHEMA postgis;", f"CREATE EXTENSION postgis WITH SCHEMA postgis VERSION '{POSTGIS_VERSION}';", "",
        "SELECT set_config('step7b.gate45', '0', false) AS reset \\gset x_",
        check_block("gate", checks, "step7b.gate45"),
        verdict_block("verdict", "step7b.gate45", "LR019", "sql/45 extension gate", len(checks)), "", "COMMIT;", ""])


def generate_sql46():
    checks = construction_checks()
    header = HEADER.format(title="46 - Create schema log_regex_gis and the 15 experiment tables", body=(
        "-- One transaction. Guard (LR020): log_regex_gis absent; postgis 3.6.2 installed in schema postgis; sources present.\n"
        "-- Each source is read exactly once (access_log_flat -> flat_numeric, access_log_jsonb -> jsonb_doc); all other tables\n"
        "-- load from these copies. Points: postgis.ST_MakePoint(longitude, latitude), SRID 4326. No secondary index.\n"
        "-- Gate O-1 / O-7 before COMMIT (LR020); VACUUM (ANALYZE) of the 15 tables after COMMIT."))
    guard = f"""DO $guard$
BEGIN
    IF to_regnamespace('{W}') IS NOT NULL
       OR (SELECT extversion || ' ' || extnamespace::regnamespace::text FROM pg_extension WHERE extname = 'postgis') IS DISTINCT FROM '{POSTGIS_VERSION} postgis'
       OR to_regclass('log_regex.access_log_flat') IS NULL OR to_regclass('log_regex_json.access_log_jsonb') IS NULL THEN
        RAISE EXCEPTION 'sql/46 refused: schema {W} exists, PostGIS {POSTGIS_VERSION} is not installed in schema postgis, or a source table is missing'
            USING ERRCODE = 'LR020';
    END IF;
END
$guard$;"""
    parts = [header, "\\set ON_ERROR_STOP on", "SET client_encoding = 'UTF8';", "", "BEGIN;", "SET LOCAL lock_timeout = '10s';",
             f"SET LOCAL search_path = {W}, postgis;", "", guard, "", f"CREATE SCHEMA {W};", ""]
    parts += [table_ddl(name, kind) + "\n" for _i, name, kind, _s in TABLES]
    parts += ["-- loads: the two source reads first, then the copies"]
    parts += [table_load(name, kind, source) + "\n" for _i, name, kind, source in TABLES]
    parts += ["SELECT set_config('step7b.gate46', '0', false) AS reset \\gset x_",
              check_block("gate", checks, "step7b.gate46"),
              verdict_block("verdict", "step7b.gate46", "LR020", "sql/46 setup gate", len(checks)), "", "COMMIT;", ""]
    parts += [f"VACUUM (ANALYZE) {W}.{name};" for name in TABLE_NAMES]
    return "\n".join(parts) + "\n"


def sql47_rows():
    oracle = [r for r in oracle_checks()]
    oracle = [(i, n, e, a.replace(f"FROM {W}.flat_geog_dummy", f"FROM {W}.flat_geom WHERE log_id = 2272")) for i, n, e, a in oracle]
    return extension_checks(with_gis_schema=True) + isolation_checks() + construction_checks() + oracle


def generate_sql47():
    rows = sql47_rows()
    info = info_rows()
    header = HEADER.format(title="47 - Read-only verification of the PostGIS setup", body=(
        "-- No write statement. Every check prints '<id> PASS' or '<id> FAIL'; LR021 at the end if any failed.\n"
        "-- X extension, A isolation, O-1 construction, O-7 copies, O-2 .. O-5 oracle readiness (plain-SQL oracle on flat_numeric), E1 .. E3."))
    info_values = ",\n".join(f"            ({lit(i)}, {a})" for i, a in info)
    info_block = f"""DO $info$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT i.label, i.value FROM (VALUES
{info_values}
        ) AS i (label, value)
    LOOP
        RAISE NOTICE '%: %', r.label, r.value;
    END LOOP;
END
$info$;"""
    return "\n".join([header, "\\set ON_ERROR_STOP on", "SET client_encoding = 'UTF8';", "SET search_path = pg_catalog, postgis;", "",
                      "SELECT set_config('step7b.verify47', '0', false) AS reset \\gset x_",
                      check_block("verify", rows, "step7b.verify47"), info_block,
                      verdict_block("verdict", "step7b.verify47", "LR021", "sql/47 PostGIS setup verification", len(rows)), ""])


def generate_sql48():
    header = HEADER.format(title="48 - Step 7C spatial index builds (generated in 7B, NOT run in 7B)", body=(
        "-- Refuses unless run with -v approved_step=7C (LR022). Exactly the 10 index statements of the Step 7B plan section 5."))
    guard = ["\\set ON_ERROR_STOP on", "\\if :{?approved_step}", "SELECT :'approved_step' = '7C' AS approved \\gset", "\\else",
             "\\set approved false", "\\endif", "\\if :approved", "\\else",
             "DO $refuse$ BEGIN RAISE EXCEPTION 'sql/48 is a Step 7C script; run it only after Step 7C approval with -v approved_step=7C' USING ERRCODE = 'LR022'; END $refuse$;",
             "\\endif"]
    return "\n".join([header] + guard + [""] + [stmt for _i, stmt in INDEXES] + [""])


def harness_text():
    def body(text, end):
        lines = text.split("\n")
        assert lines.count("BEGIN;") == 1 and lines.count(end) == 1, (lines.count("BEGIN;"), lines.count(end))
        cut = lines.index(end)
        return [line for line in lines[:cut] if line != "BEGIN;"]
    e4 = """DO $e4$
DECLARE
    v_state text;
BEGIN
    BEGIN
        PERFORM postgis.ST_Intersects(postgis.ST_SetSRID(postgis.ST_MakePoint(0, 0), 4326), postgis.ST_SetSRID(postgis.ST_MakePoint(0, 0), 3857));
        v_state := 'no error';
    EXCEPTION WHEN OTHERS THEN
        v_state := 'error ' || SQLSTATE || ': ' || SQLERRM;
    END;
    IF v_state NOT LIKE 'error%' THEN
        RAISE EXCEPTION 'E4 FAIL  mixing SRID 4326 and 3857 did not raise an error' USING ERRCODE = 'LR021';
    END IF;
    RAISE NOTICE 'E4 PASS  mixing SRID 4326 and 3857 raises an error: %', v_state;
END
$e4$;"""
    lines = ["-- Step 7B rolled-back harness (generated): sql/45 + sql/46 + ANALYZE + sql/47 + E4 in ONE transaction, then ROLLBACK.",
             "\\set ON_ERROR_STOP on", "BEGIN;"]
    lines += body(generate_sql45(), "COMMIT;") + body(generate_sql46(), "COMMIT;")
    lines += [f"ANALYZE {W}.{name};" for name in TABLE_NAMES]
    lines += [line for line in generate_sql47().split("\n")]
    lines += [e4, "DO $harness$ BEGIN RAISE NOTICE 'Step 7B harness PASSED: sql/45 gate, sql/46 gate, sql/47 verification and E4 inside one transaction'; END $harness$;",
              "ROLLBACK;", ""]
    return "\n".join(lines)


# ----------------------------------------------------------------------------------------------------------------------
# static allowlist
# ----------------------------------------------------------------------------------------------------------------------
KEYWORDS = re.compile(r"^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|COPY|VACUUM|ANALYZE|GRANT|REVOKE|COMMENT|REINDEX|CLUSTER|"
                      r"SET|RESET|BEGIN|COMMIT|ROLLBACK|DO|LOAD|SECURITY|CALL|MERGE|REFRESH|LOCK|DISCARD|IMPORT|SAVEPOINT|RELEASE)\b", re.IGNORECASE)
NAMES = "(" + "|".join(TABLE_NAMES) + ")"
ALLOW = {
    "45": [r"^SET client_encoding = 'UTF8';$", r"^BEGIN;?$", r"^SET LOCAL lock_timeout = '10s';$", r"^CREATE SCHEMA postgis;$",
           r"^CREATE EXTENSION postgis WITH SCHEMA postgis VERSION '3\.6\.2';$", r"^DO \$(guard|gate|verdict)\$$", r"^COMMIT;$"],
    "46": [r"^SET client_encoding = 'UTF8';$", r"^BEGIN;?$", r"^SET LOCAL lock_timeout = '10s';$", r"^SET LOCAL search_path = log_regex_gis, postgis;$",
           r"^CREATE SCHEMA log_regex_gis;$", r"^CREATE TABLE log_regex_gis\." + NAMES + r" \($", r"^INSERT INTO log_regex_gis\." + NAMES + r" \(",
           r"^DO \$(guard|gate|verdict)\$$", r"^COMMIT;$", r"^VACUUM \(ANALYZE\) log_regex_gis\." + NAMES + r";$"],
    "47": [r"^SET client_encoding = 'UTF8';$", r"^SET search_path = pg_catalog, postgis;$", r"^DO \$(verify|info|verdict)\$$", r"^BEGIN;?$"],
    "48": [r"^DO \$refuse\$ BEGIN RAISE EXCEPTION .* END \$refuse\$;$"] + [re.escape(s) + "$" for _i, s in INDEXES],
}


def static_check():
    files = {"45": SQL45, "46": SQL46, "47": SQL47, "48": SQL48}
    problems, summary = [], {}
    for key, path in files.items():
        text = path.read_text(encoding="ascii")
        code = [line for line in text.split("\n") if not line.lstrip().startswith("--")]
        stmts = [line.strip() for line in code if KEYWORDS.match(line)]
        allow = [re.compile(p) for p in ALLOW[key]]
        bad = [s for s in stmts if not any(a.match(s) for a in allow)]
        flat_reads = sum(1 for line in code if re.search(r"\bFROM log_regex\.access_log_flat\b", line))
        jsonb_reads = sum(1 for line in code if re.search(r"\bFROM log_regex_json\.access_log_jsonb\b", line))
        other_refs = [line.strip()[:120] for line in code if re.search(r"\blog_regex(_json)?\.", line)
                      and not re.search(r"\bFROM log_regex\.access_log_flat ORDER BY log_id;$|\bFROM log_regex_json\.access_log_jsonb ORDER BY log_id;$", line)
                      and "to_regclass('log_regex.access_log_flat')" not in line]
        expected_reads = (1, 1) if key == "46" else (0, 0)
        creates_index = sum(1 for s in stmts if s.startswith("CREATE INDEX"))
        summary[key] = {"statements": len(stmts), "outside_allowlist": len(bad), "flat_reads": flat_reads, "jsonb_reads": jsonb_reads,
                        "other_source_references": len(other_refs), "create_index": creates_index}
        if bad:
            problems.append(f"sql/{key}: statement outside allowlist: {bad[0][:160]}")
        if (flat_reads, jsonb_reads) != expected_reads:
            problems.append(f"sql/{key}: source reads {flat_reads}/{jsonb_reads}, expected {expected_reads}")
        if other_refs:
            problems.append(f"sql/{key}: other reference to an existing schema: {other_refs[0]}")
        if key != "48" and creates_index:
            problems.append(f"sql/{key}: CREATE INDEX present")
        if key == "48" and creates_index != 10:
            problems.append(f"sql/48: {creates_index} CREATE INDEX statements, expected 10")
        if key == "47" and any(re.match(r"^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|VACUUM|ANALYZE|COPY)\b", line, re.I) for line in code):
            problems.append("sql/47: write statement present")
        if re.search(r"[^\x00-\x7f]", text):
            problems.append(f"sql/{key}: non-ASCII characters")
    print(summary)
    for p in problems:
        print("PROBLEM:", p)
    print("static check " + ("PASSED" if not problems else "FAILED"))
    return 0 if not problems else 1


def cmd_generate(check):
    targets = {SQL45: generate_sql45(), SQL46: generate_sql46(), SQL47: generate_sql47(), SQL48: generate_sql48()}
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
        print("stale: " + ", ".join(stale) if stale else "generated SQL files are up to date: sql/45, sql/46, sql/47, sql/48")
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
    args = parser.parse_args()
    if args.command == "generate":
        return cmd_generate(args.check)
    if args.command == "harness":
        pathlib.Path(args.out).write_bytes(harness_text().encode("ascii"))
        print(f"harness written: {args.out}")
        return 0
    return static_check()


if __name__ == "__main__":
    sys.exit(main())
