"""
Connection and inspection helpers for the PostgreSQL source database.

Everything that talks to PostgreSQL goes through this module, so the login
details are read in exactly one place (``config/settings.py``, which takes the
password from the environment or the git-ignored ``.env`` file).

This module is independent of the Kafka consumer and the Snowflake loader:
importing it does not affect the existing pipeline.
"""

from __future__ import annotations

from typing import Any

import psycopg
from psycopg import sql

from config import settings


def connect(database: str | None = None, autocommit: bool = False) -> psycopg.Connection:
    """Open a connection to the PostgreSQL server.

    Args:
        database: Database to connect to. Defaults to the project database
            (``POSTGRES_DATABASE``).
        autocommit: True runs every statement in its own transaction. Needed
            for CREATE DATABASE, which PostgreSQL refuses inside a transaction.

    Returns:
        An open psycopg connection. Use it as a context manager so it is
        closed (and its transaction committed or rolled back) automatically.

    Raises:
        RuntimeError: if the password is not configured.
        psycopg.OperationalError: if the server cannot be reached or the
            login is refused.
    """
    return psycopg.connect(
        host=settings.POSTGRES_HOST,
        port=settings.POSTGRES_PORT,
        user=settings.POSTGRES_USER,
        password=settings.require_postgres_password(),
        dbname=database or settings.POSTGRES_DATABASE,
        # Fail quickly with a clear error if the server is not running.
        connect_timeout=10,
        # Names the session in pg_stat_activity, so it is easy to recognise.
        application_name="kafka_snowflake_source_db",
        autocommit=autocommit,
    )


def database_exists(database: str | None = None) -> bool:
    """Return True if the project database exists on the server.

    The check connects to the maintenance database and only READS the system
    catalogue; nothing is changed.
    """
    name = database or settings.POSTGRES_DATABASE
    with connect(settings.POSTGRES_MAINTENANCE_DATABASE, autocommit=True) as connection:
        row = connection.execute("SELECT 1 FROM pg_database WHERE datname = %s", (name,)).fetchone()
    return row is not None


def create_database_if_missing(database: str | None = None) -> bool:
    """Create the project database unless it already exists.

    Only the named database is created. No existing database is modified: the
    maintenance database is used merely as the place to send the command from.

    Returns:
        True if the database was created now, False if it was already there.
    """
    name = settings.validate_pg_identifier(database or settings.POSTGRES_DATABASE, "database")
    if database_exists(name):
        return False
    with connect(settings.POSTGRES_MAINTENANCE_DATABASE, autocommit=True) as connection:
        # The name cannot be a bind variable in CREATE DATABASE. sql.Identifier
        # quotes it safely, on top of the validation above. UTF8 matches the
        # JSON payloads; template0 allows choosing the encoding explicitly.
        connection.execute(
            sql.SQL("CREATE DATABASE {} ENCODING 'UTF8' TEMPLATE template0").format(sql.Identifier(name))
        )
    return True


def table_exists(connection: psycopg.Connection, table: str | None = None) -> bool:
    """Return True if the source table exists in the connected database."""
    row = connection.execute(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = %s",
        (table or settings.POSTGRES_TABLE,),
    ).fetchone()
    return row is not None


def table_columns(connection: psycopg.Connection, table: str | None = None) -> dict[str, str]:
    """Return the source table's columns as ``{column name: data type}``, in table order."""
    rows = connection.execute(
        "SELECT column_name, data_type FROM information_schema.columns "
        "WHERE table_schema = 'public' AND table_name = %s ORDER BY ordinal_position",
        (table or settings.POSTGRES_TABLE,),
    ).fetchall()
    return {name: data_type for name, data_type in rows}


def summarise_table(connection: psycopg.Connection) -> dict[str, Any]:
    """Count rows and duplicates in the source table.

    Returns:
        A dictionary with:
            total_rows            every row in the table
            backfill_rows         rows copied from the Project 3 demo
            distinct_event_ids    number of different event ids
            duplicate_event_ids   event ids that occur more than once (expect 0)
            duplicate_kafka_keys  (topic, partition, offset) triples that occur
                                  more than once among backfilled rows (expect 0)
    """
    # The table name comes from settings (a fixed constant), never from user input.
    table = sql.Identifier(settings.POSTGRES_TABLE)
    total, backfill, distinct_ids = connection.execute(
        sql.SQL(
            "SELECT COUNT(*), COUNT(*) FILTER (WHERE record_source = %s), COUNT(DISTINCT event_id) FROM {}"
        ).format(table),
        (settings.POSTGRES_BACKFILL_SOURCE,),
    ).fetchone()
    duplicate_ids = connection.execute(
        sql.SQL("SELECT COUNT(*) FROM (SELECT event_id FROM {} GROUP BY event_id HAVING COUNT(*) > 1) d").format(table)
    ).fetchone()[0]
    duplicate_kafka = connection.execute(
        sql.SQL(
            "SELECT COUNT(*) FROM (SELECT 1 FROM {} WHERE source_kafka_offset IS NOT NULL "
            "GROUP BY source_kafka_topic, source_kafka_partition, source_kafka_offset HAVING COUNT(*) > 1) d"
        ).format(table)
    ).fetchone()[0]
    return {
        "total_rows": total,
        "backfill_rows": backfill,
        "distinct_event_ids": distinct_ids,
        "duplicate_event_ids": duplicate_ids,
        "duplicate_kafka_keys": duplicate_kafka,
    }
