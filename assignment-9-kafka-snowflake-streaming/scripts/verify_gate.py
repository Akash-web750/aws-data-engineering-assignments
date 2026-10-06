"""
Verification gate (spec.md section 18) for the Snowflake side of the pipeline.

The design depends on several Snowflake behaviours. This script checks each one
on the real account BEFORE the consumer code relies on it, and prints what it
observed. It proves nothing by itself being present: read its output.

What it checks, using hand-made NDJSON files and a throw-away table:
    0. a new top-level field makes Snowflake create the column;
    1. the new column's values are loaded by the SAME COPY that created it;
    2. which data types Snowflake infers for new columns;
    3. how many new columns a single COPY may add;
    4. the exact result columns COPY INTO returns;
    6. PUT from a Windows path, with and without a space in it;
    plus: a type-conflict row with ON_ERROR = CONTINUE, and whether a
    SELECT * view survives a column being added;
    plus (``--check numeric``): what happens when a numeric column that
    schema evolution created with a narrow type later receives a larger value.

    plus (``--check limit``): the exact number of new columns one COPY may
    add, found by trying different counts;
    plus (``--check shape``): a copy of the production table and of the
    production view ORDER_EVENTS_LATEST, queried before and after schema
    evolution, and the explicitly typed DISCOUNT_PCT column;
    plus (``--check split``): the pipeline's own SnowflakeLoader loading a
    normal batch and a batch that must be split into several COPYs.

Everything it creates is named GATE_* and is dropped at the end.

Run from the project root:
    python -m scripts.verify_gate --warehouse <warehouse>
    python -m scripts.verify_gate --check numeric     # only the numeric check
    python -m scripts.verify_gate --check limit       # only the column-limit check
    python -m scripts.verify_gate --check shape       # production table shape, view, DISCOUNT_PCT
    python -m scripts.verify_gate --check split       # the real loader, including batch splitting
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any

import snowflake.connector

from config import settings
from consumer.batching import BatchBuffer
from consumer.snowflake_loader import BatchInfo, SnowflakeLoader

# Throw-away objects used only by this script.
GATE_TABLE = "GATE_CHECK"
GATE_VIEW = "GATE_CHECK_STAR_V"
GATE_STAGE_PREFIX = "gate_check"
# Throw-away table for the numeric-widening check only.
NUMERIC_TABLE = "GATE_NUMERIC"
# Throw-away table for the column-limit check only.
LIMIT_TABLE = "GATE_LIMIT"
# Throw-away copy of the production table and view for the shape check.
SHAPE_TABLE = "GATE_EVENTS"
SHAPE_VIEW = "GATE_EVENTS_LATEST"
# Throw-away table the real loader writes to in the split check.
SPLIT_TABLE = "GATE_SPLIT"


def write_ndjson(folder: Path, name: str, rows: list[dict[str, Any]]) -> Path:
    """Write ``rows`` as newline-delimited JSON to ``folder/name`` and return the path."""
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")
    return path


def run(cursor: Any, sql: str, title: str | None = None) -> list[tuple]:
    """Execute ``sql``, print its column names and rows, and return the rows.

    A failing statement is printed, not raised, because for some checks the
    failure itself is the observation we want to record.
    """
    if title:
        print(f"\n--- {title}")
    print(f"SQL> {' '.join(sql.split())}")
    try:
        cursor.execute(sql)
    except snowflake.connector.Error as exc:
        print(f"ERROR> {exc}")
        return []
    columns = [column[0] for column in cursor.description or []]
    rows = cursor.fetchall()
    print(f"COLS> {columns}")
    for row in rows:
        print(f"ROW > {row}")
    return rows


def put_and_copy(cursor: Any, path: Path, title: str, table: str = GATE_TABLE) -> None:
    """PUT one local file to the stage and COPY it into ``table`` (default: the gate table)."""
    stage = f"@{settings.SNOWFLAKE_STAGE}/{GATE_STAGE_PREFIX}"
    # as_posix() turns C:\a\b into C:/a/b. The whole URI is quoted so that a
    # space in the path does not end the file name early.
    run(
        cursor,
        f"PUT 'file://{path.as_posix()}' {stage} AUTO_COMPRESS = TRUE OVERWRITE = TRUE",
        f"{title}: PUT",
    )
    # The trailing "/" matters: Snowflake joins the FROM path and each FILES
    # name as plain text, so without it the file would be looked up as
    # "gate_check<name>" instead of "gate_check/<name>".
    run(
        cursor,
        f"""COPY INTO {table}
            FROM {stage}/
            FILES = ('{path.name}.gz')
            FILE_FORMAT = (FORMAT_NAME = {settings.SNOWFLAKE_FILE_FORMAT})
            MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
            ON_ERROR = CONTINUE
            PURGE = TRUE""",
        f"{title}: COPY",
    )


def describe_numeric_columns(cursor: Any, title: str) -> None:
    """Print name and type of every column of the numeric gate table."""
    print(f"\n--- {title}")
    cursor.execute(f"DESCRIBE TABLE {NUMERIC_TABLE}")
    for row in cursor.fetchall():
        # row[0] is the column name, row[1] its data type.
        print(f"TYPE> {row[0]:<14} {row[1]}")


def run_numeric_check(cursor: Any, folder: Path) -> None:
    """Check what a narrow, evolution-created numeric column does with larger values.

    Earlier gate runs showed that schema evolution sizes a new numeric column
    to the first value it sees: 7 gave NUMBER(1,0) and 12.5 gave NUMBER(3,1).
    This check creates such columns the same way and then loads later files
    whose values do not fit those types. Each later file holds two rows: one
    value that fits and one that does not, so a partial load is visible.

    Steps, each followed by the column types and the table contents:
        A. first file: NEW_INTEGER = 7, NEW_DECIMAL = 12.5   (creates the columns)
        B. larger integer:            NEW_INTEGER = 123456
        C. larger / more precise decimal: NEW_DECIMAL = 98765.4321
        D. fractional value into the integer column: NEW_INTEGER = 7.25
    """
    run(
        cursor,
        f"CREATE OR REPLACE TABLE {NUMERIC_TABLE} (EVENT_ID VARCHAR) ENABLE_SCHEMA_EVOLUTION = TRUE",
        "Numeric check: setup",
    )
    try:
        describe_numeric_columns(cursor, "Numeric check: column types BEFORE any load")

        # A. The first values decide the column types.
        first = write_ndjson(folder, "numeric_a_first.json", [{"EVENT_ID": "n1", "NEW_INTEGER": 7, "NEW_DECIMAL": 12.5}])
        put_and_copy(cursor, first, "Numeric A: first values 7 and 12.5 create the columns", NUMERIC_TABLE)
        describe_numeric_columns(cursor, "Numeric A: column types after the first load")

        # B. An integer far too large for NUMBER(1,0), next to one that fits.
        larger_int = write_ndjson(
            folder,
            "numeric_b_larger_integer.json",
            [
                {"EVENT_ID": "n2-fits", "NEW_INTEGER": 8, "NEW_DECIMAL": 12.5},
                {"EVENT_ID": "n3-larger-integer", "NEW_INTEGER": 123456, "NEW_DECIMAL": 12.5},
            ],
        )
        put_and_copy(cursor, larger_int, "Numeric B: larger integer 123456 into the evolved column", NUMERIC_TABLE)
        describe_numeric_columns(cursor, "Numeric B: column types after the larger integer")

        # C. A decimal with more digits before AND after the point than NUMBER(3,1) holds.
        larger_dec = write_ndjson(
            folder,
            "numeric_c_larger_decimal.json",
            [
                {"EVENT_ID": "n4-fits", "NEW_INTEGER": 7, "NEW_DECIMAL": 15.0},
                {"EVENT_ID": "n5-larger-decimal", "NEW_INTEGER": 7, "NEW_DECIMAL": 98765.4321},
            ],
        )
        put_and_copy(cursor, larger_dec, "Numeric C: larger decimal 98765.4321 into the evolved column", NUMERIC_TABLE)
        describe_numeric_columns(cursor, "Numeric C: column types after the larger decimal")

        # D. A fractional value into the column that was created as an integer.
        fraction = write_ndjson(
            folder,
            "numeric_d_fraction.json",
            [{"EVENT_ID": "n6-fraction-into-integer", "NEW_INTEGER": 7.25, "NEW_DECIMAL": 12.5}],
        )
        put_and_copy(cursor, fraction, "Numeric D: fractional 7.25 into the integer column", NUMERIC_TABLE)
        describe_numeric_columns(cursor, "Numeric D: column types after the fractional value")

        run(
            cursor,
            f"SELECT EVENT_ID, NEW_INTEGER, NEW_DECIMAL FROM {NUMERIC_TABLE} ORDER BY EVENT_ID",
            "Numeric check: rows that are in the table at the end",
        )
    finally:
        run(cursor, f"DROP TABLE IF EXISTS {NUMERIC_TABLE}", "Numeric check: cleanup")


def copy_new_columns(cursor: Any, folder: Path, count: int, prefix: str, fresh_table: bool) -> tuple[int, str]:
    """Load one row that carries ``count`` never-seen fields and report what happened.

    Uses exactly the COPY options of the pipeline (via ``put_and_copy``'s SQL
    text), so the limit measured here is the one the consumer will meet.

    Args:
        cursor: Open Snowflake cursor.
        folder: Local folder for the temporary file.
        count: Number of new top-level fields in the row.
        prefix: Prefix of the field names, so two loads can use different names.
        fresh_table: Recreate the limit table first (start from zero columns added).

    Returns:
        (number of columns the table gained, short text describing the COPY outcome).
    """
    if fresh_table:
        cursor.execute(f"CREATE OR REPLACE TABLE {LIMIT_TABLE} (EVENT_ID VARCHAR) ENABLE_SCHEMA_EVOLUTION = TRUE")
    cursor.execute(f"DESCRIBE TABLE {LIMIT_TABLE}")
    columns_before = len(cursor.fetchall())

    row: dict[str, Any] = {"EVENT_ID": f"{prefix}-{count}"}
    row.update({f"{prefix}_{index:03d}": index for index in range(count)})
    path = write_ndjson(folder, f"limit_{prefix}_{count}.json", [row])
    stage = f"@{settings.SNOWFLAKE_STAGE}/{GATE_STAGE_PREFIX}"
    cursor.execute(f"PUT 'file://{path.as_posix()}' {stage} AUTO_COMPRESS = TRUE OVERWRITE = TRUE")
    try:
        cursor.execute(
            f"COPY INTO {LIMIT_TABLE} FROM {stage}/ FILES = ('{path.name}.gz') "
            f"FILE_FORMAT = (FORMAT_NAME = {settings.SNOWFLAKE_FILE_FORMAT}) "
            "MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE ON_ERROR = CONTINUE PURGE = TRUE"
        )
        result = cursor.fetchone()
        # Result columns: file, status, rows_parsed, rows_loaded, ...
        outcome = f"status {result[1]}, rows_parsed {result[2]}, rows_loaded {result[3]}"
    except snowflake.connector.Error as exc:
        outcome = "ERROR " + " ".join(str(exc).split())

    cursor.execute(f"DESCRIBE TABLE {LIMIT_TABLE}")
    added = len(cursor.fetchall()) - columns_before
    print(f"PROBE> {count:>3} new fields in one COPY -> columns added: {added:>3} | {outcome}")
    return added, outcome


def run_limit_check(cursor: Any, folder: Path) -> None:
    """Measure how many new columns ONE COPY may add through schema evolution.

    Earlier gate runs showed that 8 new columns work and 150 fail. This check
    narrows that down to the exact boundary by halving the range (binary
    search), each probe on a freshly created table. It then confirms the
    boundary directly, and finally checks that a SECOND COPY can add the same
    number of further columns to the same table, which is what batch
    splitting in the loader relies on.
    """
    print("\n--- Limit check: how many new columns can one COPY add?")
    try:
        works, fails = 1, 150
        # Confirm both ends of the range before searching between them.
        if copy_new_columns(cursor, folder, works, "C", fresh_table=True)[0] != works:
            print("RESULT> even a single new column was not added; cannot measure a limit")
            return
        if copy_new_columns(cursor, folder, fails, "C", fresh_table=True)[0] == fails:
            print(f"RESULT> {fails} new columns were added in one COPY; the limit is above the tested range")
            return
        # Invariant: `works` columns can be added, `fails` cannot.
        while fails - works > 1:
            middle = (works + fails) // 2
            if copy_new_columns(cursor, folder, middle, "C", fresh_table=True)[0] == middle:
                works = middle
            else:
                fails = middle

        print("\n--- Limit check: confirming the boundary")
        copy_new_columns(cursor, folder, works, "C", fresh_table=True)
        copy_new_columns(cursor, folder, fails, "C", fresh_table=True)
        print(f"RESULT> largest number of new columns one COPY added: {works}; smallest that failed: {fails}")

        print("\n--- Limit check: can a second COPY add the same number again to the same table?")
        copy_new_columns(cursor, folder, works, "C", fresh_table=True)
        copy_new_columns(cursor, folder, works, "D", fresh_table=False)
        run(cursor, f"SELECT COUNT(*) AS ROWS_LOADED FROM {LIMIT_TABLE}", "Limit check: rows in the table after both COPYs")
    finally:
        run(cursor, f"DROP TABLE IF EXISTS {LIMIT_TABLE}", "Limit check: cleanup")


def describe_types(cursor: Any, table: str, title: str) -> None:
    """Print name and data type of every column of ``table``."""
    print(f"\n--- {title}")
    cursor.execute(f"DESCRIBE TABLE {table}")
    for row in cursor.fetchall():
        # row[0] is the column name, row[1] its data type.
        print(f"TYPE> {row[0]:<18} {row[1]}")


def run_shape_check(cursor: Any, folder: Path) -> None:
    """Check the production table shape and the production view against schema evolution.

    Works on copies, so ORDER_EVENTS itself is not touched:
        * GATE_EVENTS        = CREATE TABLE ... LIKE ORDER_EVENTS (same columns and types)
        * GATE_EVENTS_LATEST = the real definition of ORDER_EVENTS_LATEST, read
                               back from Snowflake with GET_DDL, pointed at the copy

    It then verifies, in order:
        1. the view answers BEFORE any column is added, and removes a duplicate
           Kafka message (same partition and offset loaded twice);
        2. new fields are added as columns while DISCOUNT_PCT keeps NUMBER(5,2);
        3. discount values, including a fractional one (7.25) and a large one
           (100.0), are stored exactly: nothing rejected, nothing rounded;
        4. the SAME view still answers AFTER the columns were added.
    """
    run(cursor, f"CREATE OR REPLACE TABLE {SHAPE_TABLE} LIKE {settings.SNOWFLAKE_TABLE}", "Shape check: copy of the production table")
    # LIKE copies columns and types; switch schema evolution on explicitly so
    # the copy behaves like the original whatever LIKE does with that flag.
    run(cursor, f"ALTER TABLE {SHAPE_TABLE} SET ENABLE_SCHEMA_EVOLUTION = TRUE")
    try:
        # The view definition as Snowflake stores it, re-pointed at the copy.
        cursor.execute(f"SELECT GET_DDL('VIEW', '{settings.SNOWFLAKE_TABLE}_LATEST')")
        ddl = cursor.fetchone()[0]
        ddl = re.sub(rf"\b{settings.SNOWFLAKE_TABLE}_LATEST\b", SHAPE_VIEW, ddl)
        ddl = re.sub(rf"\b{settings.SNOWFLAKE_TABLE}\b", SHAPE_TABLE, ddl)
        run(cursor, ddl, "Shape check: copy of the production view definition")
        describe_types(cursor, SHAPE_TABLE, "Shape check: column types BEFORE schema evolution")

        def event(offset: int, ingested: str, **fields: Any) -> dict[str, Any]:
            """One row in the version-1 shape plus any extra fields."""
            return {
                "EVENT_ID": f"e{offset}", "EVENT_TIME": "2026-10-06T10:00:00.000Z", "ORDER_ID": f"ORD-{offset}",
                "CUSTOMER_ID": 1, "PRODUCT": "Webcam", "QUANTITY": 1, "UNIT_PRICE": 2499.0, "STATUS": "PAID",
                "_KAFKA_TOPIC": "order_events", "_KAFKA_PARTITION": 0, "_KAFKA_OFFSET": offset,
                "_KAFKA_TIMESTAMP": "2026-10-06 10:00:00.000", "_INGESTED_AT": ingested, **fields,
            }

        # ---- 1. Version-1 rows, one Kafka message (offset 1) loaded twice.
        before = write_ndjson(
            folder,
            "shape_v1.json",
            [
                event(0, "2026-10-06 10:00:05.000"),
                event(1, "2026-10-06 10:00:05.000"),
                event(1, "2026-10-06 10:00:09.000"),      # duplicate of offset 1, ingested later
            ],
        )
        put_and_copy(cursor, before, "Shape check 1: version-1 rows incl. one duplicate message", SHAPE_TABLE)
        run(cursor, f"SELECT COUNT(*) AS ROWS_IN_TABLE FROM {SHAPE_TABLE}", "Shape check 1: rows in the table (duplicate included)")
        run(
            cursor,
            f"SELECT _KAFKA_PARTITION, _KAFKA_OFFSET, _INGESTED_AT FROM {SHAPE_VIEW} ORDER BY _KAFKA_OFFSET",
            "Shape check 1: view BEFORE schema evolution (duplicate removed, earliest copy kept)",
        )

        # ---- 2 + 3. New fields and a range of discount values.
        discounts = [0.0, 5.0, 7.5, 12.5, 100.0, 7.25]
        after = write_ndjson(
            folder,
            "shape_evolved.json",
            [
                event(
                    offset, "2026-10-06 10:00:15.000", DISCOUNT_PCT=discount, PAYMENT_METHOD="UPI",
                    LOYALTY_TIER="GOLD", IS_GIFT=False, SHIPPING_ADDRESS={"city": "Pune", "pincode": "411001"},
                    CAMPAIGN="diwali",
                )
                for offset, discount in enumerate(discounts, start=2)
            ],
        )
        put_and_copy(cursor, after, "Shape check 2: rows with new fields and DISCOUNT_PCT values", SHAPE_TABLE)
        describe_types(cursor, SHAPE_TABLE, "Shape check 2: column types AFTER schema evolution")
        run(
            cursor,
            f"SELECT _KAFKA_OFFSET, DISCOUNT_PCT, PAYMENT_METHOD, LOYALTY_TIER, IS_GIFT, CAMPAIGN, SHIPPING_ADDRESS:city::STRING AS CITY "
            f"FROM {SHAPE_TABLE} WHERE _KAFKA_OFFSET >= 2 ORDER BY _KAFKA_OFFSET",
            f"Shape check 3: stored values (discounts sent: {discounts})",
        )

        # ---- 4. The same view, after the table gained columns.
        run(
            cursor,
            f"SELECT _KAFKA_OFFSET, DISCOUNT_PCT FROM {SHAPE_VIEW} ORDER BY _KAFKA_OFFSET",
            "Shape check 4: view AFTER schema evolution",
        )
        run(
            cursor,
            f"SELECT (SELECT COUNT(*) FROM {SHAPE_TABLE}) AS ROWS_IN_TABLE, (SELECT COUNT(*) FROM {SHAPE_VIEW}) AS ROWS_IN_VIEW",
            "Shape check 4: table has 9 rows (one duplicate), view should have 8",
        )
    finally:
        run(cursor, f"DROP VIEW IF EXISTS {SHAPE_VIEW}", "Shape check: cleanup")
        run(cursor, f"DROP TABLE IF EXISTS {SHAPE_TABLE}")


def run_split_check(cursor: Any, folder: Path) -> None:
    """Run the pipeline's own SnowflakeLoader against the real account.

    Earlier checks sent hand-written COPY statements. This one uses the
    production loader class, pointed at a throw-away table, for two batches:

        A. a normal batch (3 records, 2 new fields): one PUT, one COPY;
        B. a batch of 5 records that each introduce 50 different new fields
           (250 new columns). One COPY may add 100, so the loader must split
           it into 3 COPY operations (100 + 100 + 50 columns).

    For each it prints what the loader returned, then reads back from
    Snowflake: rows, distinct Kafka offsets, column count and the audit rows.
    """
    run(
        cursor,
        f"CREATE OR REPLACE TABLE {SPLIT_TABLE} (EVENT_ID VARCHAR, _KAFKA_PARTITION NUMBER, _KAFKA_OFFSET NUMBER) "
        "ENABLE_SCHEMA_EVOLUTION = TRUE",
        "Split check: setup",
    )
    loader = SnowflakeLoader(table=SPLIT_TABLE)

    def load(title: str, records: list[dict[str, Any]]) -> None:
        """Buffer ``records`` like the consumer does, load them with the real loader, print the result."""
        buffer = BatchBuffer(max_records=1000, max_seconds=5.0)
        for record in records:
            buffer.track(record["_KAFKA_PARTITION"], record["_KAFKA_OFFSET"], now=0.0)
            buffer.add(record, record["_KAFKA_PARTITION"], record["_KAFKA_OFFSET"])
        path = folder / buffer.file_name("gate_split")
        buffer.write_file(path)
        print(f"\n--- {title}")
        try:
            result = loader.load_batch(
                path,
                BatchInfo(
                    topic="gate_split", record_count=len(records), column_names=buffer.column_names(),
                    first_seen=dict(buffer.first_seen), offset_ranges_text=buffer.offset_ranges_text(),
                ),
            )
        except Exception as exc:  # noqa: BLE001 - the failure itself is the observation
            print(f"ERROR> {type(exc).__name__}: {' '.join(str(exc).split())}")
            return
        print(
            f"LOADER> file={result.file_name} status={result.status} copies={result.copies} "
            f"rows_parsed={result.rows_parsed} rows_loaded={result.rows_loaded} errors_seen={result.errors_seen} "
            f"new_columns={len(result.new_columns)}"
        )

    try:
        # ---- A. Normal batch: the loader's ordinary single-COPY path.
        load(
            "Split check A: normal batch through the real loader (expect copies=1)",
            [{"EVENT_ID": f"a{offset}", "_KAFKA_PARTITION": 0, "_KAFKA_OFFSET": offset, "NOTE": "x", "SCORE": 12.5}
             for offset in range(3)],
        )
        # ---- B. 5 records x 50 distinct new fields = 250 new columns.
        wide_records = []
        for offset in range(3, 8):
            record: dict[str, Any] = {"EVENT_ID": f"w{offset}", "_KAFKA_PARTITION": 0, "_KAFKA_OFFSET": offset}
            record.update({f"W{offset}_{index:02d}": f"v{index}" for index in range(50)})
            wide_records.append(record)
        load("Split check B: 250 new columns in one batch through the real loader (expect copies=3)", wide_records)

        run(
            cursor,
            f"SELECT COUNT(*) AS ROWS_IN_TABLE, COUNT(DISTINCT _KAFKA_PARTITION, _KAFKA_OFFSET) AS DISTINCT_MESSAGES FROM {SPLIT_TABLE}",
            "Split check: rows in the table (expect 8 and 8: nothing lost, nothing duplicated)",
        )
        cursor.execute(f"DESCRIBE TABLE {SPLIT_TABLE}")
        print(f"\n--- Split check: column count\nCOLUMNS> {len(cursor.fetchall())} (3 original + 2 from batch A + 250 from batch B = 255 expected)")
        run(
            cursor,
            f"SELECT FILE_NAME, RECORD_COUNT, ROWS_LOADED, ERRORS_SEEN, COPY_STATUS, OFFSET_RANGES, "
            f"ARRAY_SIZE(SPLIT(NEW_COLUMNS, ',')) AS NEW_COLUMN_COUNT "
            f"FROM {settings.SNOWFLAKE_BATCH_LOG_TABLE} WHERE TARGET_TABLE = '{SPLIT_TABLE}' ORDER BY LOGGED_AT",
            "Split check: INGEST_BATCH_LOG rows (one per COPY)",
        )
        run(
            cursor,
            f"SELECT COUNT(*) AS COLUMNS_AUDITED FROM {settings.SNOWFLAKE_SCHEMA_LOG_TABLE} WHERE TARGET_TABLE = '{SPLIT_TABLE}'",
            "Split check: SCHEMA_EVOLUTION_LOG rows (expect 252)",
        )
        run(cursor, f"LIST @{settings.SNOWFLAKE_STAGE}", "Split check: files left in the stage (expect none)")
    finally:
        loader.close()
        run(cursor, f"DROP TABLE IF EXISTS {SPLIT_TABLE}", "Split check: cleanup")
        # Remove only the audit rows this check wrote.
        run(cursor, f"DELETE FROM {settings.SNOWFLAKE_BATCH_LOG_TABLE} WHERE TARGET_TABLE = '{SPLIT_TABLE}'")
        run(cursor, f"DELETE FROM {settings.SNOWFLAKE_SCHEMA_LOG_TABLE} WHERE TARGET_TABLE = '{SPLIT_TABLE}'")


# Checks that can be run on their own with --check <name>.
SINGLE_CHECKS = {
    "numeric": run_numeric_check,
    "limit": run_limit_check,
    "shape": run_shape_check,
    "split": run_split_check,
}


def main() -> None:
    """Run every gate check in order and print the observations."""
    parser = argparse.ArgumentParser(description="Verify Snowflake behaviours the pipeline relies on.")
    parser.add_argument(
        "--warehouse",
        default=settings.SNOWFLAKE_WAREHOUSE,
        help="Warehouse to run the checks on (default: the pipeline warehouse).",
    )
    parser.add_argument(
        "--check",
        choices=("all", *SINGLE_CHECKS),
        default="all",
        help="Run one named check only, or 'all' for the original gate plus the numeric check.",
    )
    args = parser.parse_args()
    warehouse = settings.validate_identifier(args.warehouse, "--warehouse")

    # One folder without a space in its path and one with, to check PUT on both.
    plain_dir = Path(tempfile.mkdtemp(prefix="gate_"))
    spaced_dir = plain_dir / "folder with space"

    connection = snowflake.connector.connect(
        connection_name=settings.require_snowflake_connection_name(),
        role=settings.SNOWFLAKE_ROLE,
        warehouse=warehouse,
        database=settings.SNOWFLAKE_DATABASE,
        schema=settings.SNOWFLAKE_SCHEMA,
        session_parameters={"QUERY_TAG": settings.SNOWFLAKE_QUERY_TAG},
    )
    cursor = connection.cursor()
    if args.check in SINGLE_CHECKS:
        # One named check only: cheaper than repeating the whole gate.
        try:
            SINGLE_CHECKS[args.check](cursor, plain_dir)
        finally:
            run(cursor, f"REMOVE @{settings.SNOWFLAKE_STAGE}/{GATE_STAGE_PREFIX}", "Cleanup: staged files")
            cursor.close()
            connection.close()
            shutil.rmtree(plain_dir, ignore_errors=True)
        return
    try:
        # A small version-1 style table with schema evolution switched on.
        run(
            cursor,
            f"""CREATE OR REPLACE TABLE {GATE_TABLE} (
                    EVENT_ID VARCHAR, QUANTITY NUMBER, UNIT_PRICE NUMBER(12,2),
                    EVENT_TIME TIMESTAMP_NTZ, _KAFKA_OFFSET NUMBER
                ) ENABLE_SCHEMA_EVOLUTION = TRUE""",
            "Setup: gate table",
        )
        run(cursor, f"CREATE OR REPLACE VIEW {GATE_VIEW} AS SELECT * FROM {GATE_TABLE}", "Setup: SELECT * view")

        # ---- Baseline load: only known columns; also shows the COPY result columns (item 4).
        base = write_ndjson(
            plain_dir,
            "base.json",
            [
                {"EVENT_ID": "a1", "QUANTITY": 1, "UNIT_PRICE": 10.5, "EVENT_TIME": "2026-10-06T10:00:00Z", "_KAFKA_OFFSET": 0},
                {"EVENT_ID": "a2", "QUANTITY": 2, "UNIT_PRICE": 20.0, "EVENT_TIME": "2026-10-06T10:00:01Z", "_KAFKA_OFFSET": 1},
            ],
        )
        put_and_copy(cursor, base, "Item 4 + 6: baseline load from a path without spaces")

        # ---- New fields of several JSON types (items 0, 1, 2); file is in a path WITH a space (item 6).
        evolved = write_ndjson(
            spaced_dir,
            "evolved.json",
            [
                {
                    "EVENT_ID": "b1", "QUANTITY": 3, "UNIT_PRICE": 30.25,
                    "EVENT_TIME": "2026-10-06T10:00:02Z", "_KAFKA_OFFSET": 2,
                    "NEW_TEXT": "upi", "NEW_DECIMAL": 12.5, "NEW_INTEGER": 7,
                    "NEW_BOOLEAN": True, "NEW_TIMESTAMP_TEXT": "2026-10-06T10:00:02Z",
                    "NEW_DATE_TEXT": "2026-10-06",
                    "NEW_OBJECT": {"city": "Pune", "pincode": "411001"},
                    "NEW_ARRAY": ["a", "b"],
                },
                # Second row omits most new fields: they should load as NULL.
                {"EVENT_ID": "b2", "QUANTITY": 4, "UNIT_PRICE": 40.0,
                 "EVENT_TIME": "2026-10-06T10:00:03Z", "_KAFKA_OFFSET": 3, "NEW_TEXT": "card"},
            ],
        )
        put_and_copy(cursor, evolved, "Items 0, 1, 6: new fields, path with a space")
        run(cursor, f"DESCRIBE TABLE {GATE_TABLE}", "Item 2: columns and inferred types after evolution")
        run(cursor, f"SELECT * FROM {GATE_TABLE} ORDER BY _KAFKA_OFFSET", "Item 1: were the new values loaded by the same COPY?")
        run(cursor, f"SELECT * FROM {GATE_VIEW} ORDER BY _KAFKA_OFFSET", "Extra: does a SELECT * view survive the new columns?")

        # ---- Type conflict: valid row, text in a NUMBER column, valid row.
        conflict = write_ndjson(
            plain_dir,
            "conflict.json",
            [
                {"EVENT_ID": "c1", "QUANTITY": 5, "UNIT_PRICE": 1.0, "EVENT_TIME": "2026-10-06T10:00:04Z", "_KAFKA_OFFSET": 4},
                {"EVENT_ID": "c2", "QUANTITY": "not-a-number", "UNIT_PRICE": 1.0, "EVENT_TIME": "2026-10-06T10:00:05Z", "_KAFKA_OFFSET": 5},
                {"EVENT_ID": "c3", "QUANTITY": 6, "UNIT_PRICE": 1.0, "EVENT_TIME": "2026-10-06T10:00:06Z", "_KAFKA_OFFSET": 6},
            ],
        )
        put_and_copy(cursor, conflict, "Extra: type conflict with ON_ERROR = CONTINUE")
        run(cursor, f"SELECT EVENT_ID, QUANTITY FROM {GATE_TABLE} WHERE EVENT_ID LIKE 'c%' ORDER BY 1", "Extra: which conflict rows loaded?")

        # ---- Many new columns in one file (item 3): 150 fields the table has never seen.
        wide_row: dict[str, Any] = {"EVENT_ID": "d1", "_KAFKA_OFFSET": 7}
        wide_row.update({f"WIDE_{index:03d}": index for index in range(150)})
        wide = write_ndjson(plain_dir, "wide.json", [wide_row])
        put_and_copy(cursor, wide, "Item 3: 150 new fields in one COPY")
        run(
            cursor,
            f"""SELECT COUNT(*) AS WIDE_COLUMNS_CREATED
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = '{settings.SNOWFLAKE_SCHEMA}'
                  AND TABLE_NAME = '{GATE_TABLE}' AND COLUMN_NAME LIKE 'WIDE\\\\_%' ESCAPE '\\\\'""",
            "Item 3: how many of the 150 columns exist now?",
        )
        run(cursor, f"SELECT COUNT(*) AS ROWS_D1 FROM {GATE_TABLE} WHERE EVENT_ID = 'd1'", "Item 3: was the wide row loaded?")

        # ---- Narrow numeric columns receiving larger values.
        run_numeric_check(cursor, plain_dir)
    finally:
        # Remove everything this script created, including any staged files
        # that a failed COPY left behind.
        run(cursor, f"DROP VIEW IF EXISTS {GATE_VIEW}", "Cleanup")
        run(cursor, f"DROP TABLE IF EXISTS {GATE_TABLE}")
        run(cursor, f"REMOVE @{settings.SNOWFLAKE_STAGE}/{GATE_STAGE_PREFIX}")
        cursor.close()
        connection.close()
        shutil.rmtree(plain_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
