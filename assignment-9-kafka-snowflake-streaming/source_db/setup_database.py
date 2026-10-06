"""
Creates the PostgreSQL source database and its table.

Run from the project root:

    python -m source_db.setup_database

What it does, in order:
    1. checks that the PostgreSQL server can be reached with the configured login;
    2. creates the project database (default ``kafka_source_db``) if it is missing;
    3. runs ``sql/postgres/01_create_source_table.sql`` inside that database.

It is safe to run again: an existing database and table are left as they are.
It loads no data (see ``backfill_from_snowflake.py``) and never touches Kafka,
Snowflake or any other PostgreSQL database.
"""

from __future__ import annotations

import logging

from config import settings
from source_db import postgres

logger = logging.getLogger("source_db.setup_database")

# DDL for the source table; kept as a .sql file so it can be read and reviewed on its own.
CREATE_TABLE_SQL = settings.PROJECT_ROOT / "sql" / "postgres" / "01_create_source_table.sql"


def check_server() -> str:
    """Connect to the server and return its version string.

    Uses the maintenance database because the project database may not exist
    yet. Only reads; changes nothing.
    """
    with postgres.connect(settings.POSTGRES_MAINTENANCE_DATABASE, autocommit=True) as connection:
        return connection.execute("SELECT version()").fetchone()[0]


def create_table() -> None:
    """Run the table DDL inside the project database (one transaction)."""
    ddl = CREATE_TABLE_SQL.read_text(encoding="utf-8")
    with postgres.connect() as connection:
        # The file holds several statements and no bind variables, so it can
        # be sent as one script. Leaving the "with" block commits it.
        connection.execute(ddl)


def main() -> None:
    """Entry point: check the server, create database and table, report the result."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    version = check_server()
    logger.info(
        "Connected to PostgreSQL at %s:%d as %s (%s).",
        settings.POSTGRES_HOST, settings.POSTGRES_PORT, settings.POSTGRES_USER, version.split(",")[0],
    )

    if postgres.create_database_if_missing():
        logger.info("Created database %s.", settings.POSTGRES_DATABASE)
    else:
        logger.info("Database %s already exists; left unchanged.", settings.POSTGRES_DATABASE)

    create_table()
    with postgres.connect() as connection:
        columns = postgres.table_columns(connection)
        summary = postgres.summarise_table(connection)
    logger.info("Table %s is ready: %d columns, %d rows.", settings.POSTGRES_TABLE, len(columns), summary["total_rows"])


if __name__ == "__main__":
    main()
