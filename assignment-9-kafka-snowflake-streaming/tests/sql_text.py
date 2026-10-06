"""
Helpers that read object definitions out of sql/01_create_objects.sql.

Tests use these instead of repeating the table definition, so there is one
source of truth: the SQL script that actually creates the objects. If the
script changes, the tests (including the live end-to-end test, which builds
its test table from the same definition) follow automatically.
"""

from __future__ import annotations

import re
from pathlib import Path

# The script that creates the pipeline objects.
CREATE_OBJECTS_SQL = Path(__file__).resolve().parent.parent / "sql" / "01_create_objects.sql"


def _sql_without_comment_lines() -> str:
    """Return the script text with full-line ``--`` comments removed."""
    lines = CREATE_OBJECTS_SQL.read_text(encoding="utf-8").splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("--"))


def order_events_columns() -> list[tuple[str, str]]:
    """Return ``(column name, data type)`` for every column DECLARED for ORDER_EVENTS.

    These are the columns in the CREATE TABLE statement, in order. Columns
    that schema evolution adds later are, by definition, not in this list.
    """
    sql = _sql_without_comment_lines()
    body = re.search(
        r"CREATE TABLE IF NOT EXISTS ORDER_EVENTS \((.*?)\n\)\s*ENABLE_SCHEMA_EVOLUTION = TRUE", sql, re.DOTALL
    )
    assert body, "CREATE TABLE ORDER_EVENTS with ENABLE_SCHEMA_EVOLUTION = TRUE not found in the SQL script"
    # Each column line looks like:  NAME   TYPE   COMMENT '...'
    return re.findall(r"^\s+(\w+)\s+([A-Z_]+(?:\(\d+,\s*\d+\))?)\s+COMMENT", body.group(1), re.MULTILINE)


def order_events_ddl(table_name: str) -> str:
    """Build a CREATE OR REPLACE TABLE statement with the production column list.

    Used by the live test to create its own table with exactly the declared
    shape of ORDER_EVENTS, schema evolution switched on.
    """
    columns = ", ".join(f"{name} {data_type}" for name, data_type in order_events_columns())
    return f"CREATE OR REPLACE TABLE {table_name} ({columns}) ENABLE_SCHEMA_EVOLUTION = TRUE"


def latest_view_sql() -> str:
    """Return the full CREATE VIEW statement of ORDER_EVENTS_LATEST (comments removed)."""
    sql = _sql_without_comment_lines()
    view = re.search(r"CREATE OR REPLACE VIEW ORDER_EVENTS_LATEST.*?= 1;", sql, re.DOTALL)
    assert view, "CREATE VIEW ORDER_EVENTS_LATEST not found in the SQL script"
    return view.group(0)


def latest_view_columns() -> list[str]:
    """Return the column names ORDER_EVENTS_LATEST selects, in order."""
    select_list = re.search(r"\bAS\s+SELECT(.*?)\bFROM ORDER_EVENTS\b", latest_view_sql(), re.DOTALL)
    assert select_list, "SELECT list of ORDER_EVENTS_LATEST not found"
    return [name.strip() for name in select_list.group(1).split(",") if name.strip()]
