"""
Unit tests for how consumer/snowflake_loader.py reads the result of COPY INTO.

Snowflake reports a file-level failure as a normal result row with status
LOAD_FAILED, not as an SQL error. These tests make sure the loader turns that
into an exception (so Kafka offsets are not committed), while a normal load
and a load with rejected rows keep working.

Snowflake is replaced by a fake connection that answers each statement type
with a prepared result. No account is needed.
"""

from __future__ import annotations

import pytest

from consumer.snowflake_loader import BatchInfo, BatchNotLoadedError, SnowflakeLoader

# Column names COPY INTO returns on this account (verified by scripts/verify_gate.py).
COPY_COLUMNS = (
    "file", "status", "rows_parsed", "rows_loaded", "error_limit", "errors_seen",
    "first_error", "first_error_line", "first_error_character", "first_error_column_name",
)


class FakeCursor:
    """Answers PUT, COPY, DESCRIBE, REMOVE and INSERT with prepared results."""

    def __init__(self, connection: "FakeConnection") -> None:
        """Remember the connection that holds the prepared COPY result."""
        self.connection = connection
        self.description: list[tuple] = []
        self.rows: list[tuple] = []
        self.sfqid = "query-id-1"

    def execute(self, sql: str, params: tuple | None = None) -> None:
        """Record the statement and prepare the matching result."""
        self.connection.statements.append(sql)
        keyword = sql.split()[0].upper()
        if keyword == "DESCRIBE":
            self.description = [("name",), ("type",)]
            self.rows = [("EVENT_ID", "VARCHAR(16777216)"), ("QUANTITY", "NUMBER(38,0)")]
        elif keyword == "PUT":
            self.rows = [("f.json", "f.json.gz", 10, 10, "NONE", "GZIP", "UPLOADED", "")]
        elif keyword == "COPY":
            self.description = [(name,) for name in COPY_COLUMNS]
            self.rows = [self.connection.copy_row]
        else:
            # REMOVE and INSERT: the loader does not read their results.
            self.rows = []

    def fetchone(self):
        """Return the first prepared row, or None."""
        return self.rows[0] if self.rows else None

    def fetchall(self) -> list[tuple]:
        """Return every prepared row."""
        return list(self.rows)

    def close(self) -> None:
        """Nothing to release in the fake."""


class FakeConnection:
    """Stands in for a Snowflake connection."""

    def __init__(self, copy_row: tuple) -> None:
        """
        Args:
            copy_row: The single result row the pretend COPY INTO returns.
        """
        self.copy_row = copy_row
        self.statements: list[str] = []

    def cursor(self) -> FakeCursor:
        """Hand out a new fake cursor."""
        return FakeCursor(self)

    def is_closed(self) -> bool:
        """The fake connection is always open."""
        return False

    def close(self) -> None:
        """Nothing to release in the fake."""


def copy_row(status: str, parsed: int, loaded: int, errors: int = 0, first_error: str | None = None) -> tuple:
    """Build a COPY INTO result row in the real column order."""
    return ("order_events_stage/f.json.gz", status, parsed, loaded, 1, errors, first_error, None, None, None)


def load(tmp_path, row: tuple, record_count: int = 3):
    """Run load_batch against a fake connection; return (result, connection)."""
    connection = FakeConnection(row)
    loader = SnowflakeLoader(table="ORDER_EVENTS", connection_factory=lambda: connection)
    file_path = tmp_path / "order_events_p0-0_o0-2_abcd1234.json"
    file_path.write_text('{"EVENT_ID": "e1"}\n', encoding="utf-8")
    info = BatchInfo(
        topic="order_events", record_count=record_count, column_names={"EVENT_ID"},
        first_seen={"EVENT_ID": (0, 0)}, offset_ranges_text='{"0": [0, 2]}',
    )
    return loader, connection, file_path, info


def statement_kinds(connection: FakeConnection) -> list[str]:
    """First keyword of every statement the loader sent, in order."""
    return [sql.split()[0].upper() for sql in connection.statements]


def test_file_level_load_failure_raises_so_offsets_are_not_committed(tmp_path):
    """LOAD_FAILED with 0 rows parsed for a non-empty batch must raise, not look like success."""
    row = copy_row("LOAD_FAILED", parsed=0, loaded=0, errors=1, first_error="Remote file 'x' was not found.")
    loader, connection, file_path, info = load(tmp_path, row)
    with pytest.raises(BatchNotLoadedError, match="was not found"):
        loader.load_batch(file_path, info)
    # No audit row was written for a batch that did not load.
    assert "INSERT" not in statement_kinds(connection)


def test_successful_copy_still_returns_the_result(tmp_path):
    """The normal path is unchanged: the result is returned and the audit row is written."""
    loader, connection, file_path, info = load(tmp_path, copy_row("LOADED", parsed=3, loaded=3))
    result = loader.load_batch(file_path, info)
    assert (result.status, result.rows_parsed, result.rows_loaded, result.errors_seen) == ("LOADED", 3, 3, 0)
    assert result.query_id == "query-id-1"
    assert statement_kinds(connection) == ["DESCRIBE", "PUT", "COPY", "REMOVE", "INSERT"]


def test_rejected_rows_are_not_a_file_level_failure(tmp_path):
    """Rows that were parsed but rejected (type conflict) complete the batch; no exception."""
    row = copy_row("PARTIALLY_LOADED", parsed=3, loaded=2, errors=1, first_error="Numeric value 'x' is not recognized")
    loader, _, file_path, info = load(tmp_path, row)
    result = loader.load_batch(file_path, info)
    assert (result.rows_loaded, result.errors_seen) == (2, 1)


def test_every_row_rejected_is_still_a_completed_batch(tmp_path):
    """All rows parsed and all rejected: the file WAS read, so the batch is complete."""
    row = copy_row("LOAD_FAILED", parsed=3, loaded=0, errors=3, first_error="Numeric value 'x' is not recognized")
    loader, _, file_path, info = load(tmp_path, row)
    result = loader.load_batch(file_path, info)
    assert (result.rows_parsed, result.rows_loaded, result.errors_seen) == (3, 0, 3)
