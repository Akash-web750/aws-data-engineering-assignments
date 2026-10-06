"""
Central configuration for the Kafka-to-Snowflake streaming pipeline.

Every tunable value and every Kafka/Snowflake object name used by the producer,
the consumer and the tests is defined here, once. Other modules import from
this file instead of hard-coding names.

How a value is resolved (first match wins):
    1. an environment variable of the same name,
    2. the same key in a local ``.env`` file in the project root (git-ignored),
    3. the default written in this file.

No credentials live here. The Snowflake login is taken from the Snowflake
``config.toml`` connection named by ``SNOWFLAKE_CONNECTION_NAME``.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from dotenv import load_dotenv

# Project root = the folder that contains this "config" package.
PROJECT_ROOT: Path = Path(__file__).resolve().parent.parent

# Read .env from the project root if it exists. override=False means a real
# environment variable always beats the file, which is what tests rely on.
load_dotenv(PROJECT_ROOT / ".env", override=False)

# A Snowflake identifier we are willing to place directly into SQL text.
# Object names cannot be sent as bind variables, so they are validated against
# this strict pattern instead; anything else is refused before it reaches SQL.
_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")


def _get(name: str, default: str) -> str:
    """Return setting ``name`` from the environment, or ``default`` if unset/blank."""
    value = os.environ.get(name, "").strip()
    return value if value else default


def _get_int(name: str, default: int) -> int:
    """Return setting ``name`` as a positive integer.

    Raises:
        ValueError: if the value is not a whole number greater than zero.
    """
    raw = _get(name, str(default))
    try:
        number = int(raw)
    except ValueError as exc:
        raise ValueError(f"Setting {name} must be a whole number, got {raw!r}") from exc
    if number <= 0:
        raise ValueError(f"Setting {name} must be greater than zero, got {number}")
    return number


def _get_float(name: str, default: float) -> float:
    """Return setting ``name`` as a positive number.

    Raises:
        ValueError: if the value is not a number greater than zero.
    """
    raw = _get(name, str(default))
    try:
        number = float(raw)
    except ValueError as exc:
        raise ValueError(f"Setting {name} must be a number, got {raw!r}") from exc
    if number <= 0:
        raise ValueError(f"Setting {name} must be greater than zero, got {number}")
    return number


def validate_identifier(value: str, setting_name: str = "identifier") -> str:
    """Return ``value`` upper-cased if it is a safe Snowflake identifier.

    Args:
        value: The object name to check (for example a table name).
        setting_name: Name shown in the error message.

    Returns:
        The identifier in upper case.

    Raises:
        ValueError: if the value contains anything other than letters, digits,
            ``_`` and ``$``, or does not start with a letter or ``_``.
    """
    if not _IDENTIFIER_PATTERN.match(value):
        raise ValueError(
            f"{setting_name} must be a plain Snowflake identifier "
            f"(letters, digits, _ and $), got {value!r}"
        )
    return value.upper()


# ----------------------------------------------------------------------------
# Kafka
# ----------------------------------------------------------------------------

# Address of the local broker started by scripts/start_kafka.ps1.
KAFKA_BOOTSTRAP_SERVERS: str = _get("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")

# Topic the producer writes order events to and the consumer reads from.
KAFKA_TOPIC: str = _get("KAFKA_TOPIC", "order_events")

# Dead-letter topic: messages the consumer cannot parse are copied here.
KAFKA_DLQ_TOPIC: str = _get("KAFKA_DLQ_TOPIC", "order_events_dlq")

# Consumer group. Kafka stores the committed offsets under this name, which is
# how a restarted consumer resumes where the previous one stopped.
KAFKA_GROUP_ID: str = _get("KAFKA_GROUP_ID", "snowflake-loader")

# ----------------------------------------------------------------------------
# Micro-batching (consumer)
# ----------------------------------------------------------------------------

# Flush the buffer to Snowflake once it holds this many records ...
BATCH_MAX_RECORDS: int = _get_int("BATCH_MAX_RECORDS", 500)

# ... or once this many seconds have passed since the first buffered record,
# whichever happens first. This is the main latency setting of the pipeline.
BATCH_MAX_SECONDS: float = _get_float("BATCH_MAX_SECONDS", 5.0)

# Retry back-off for Snowflake errors, in seconds: start value and upper limit.
RETRY_INITIAL_SECONDS: float = _get_float("RETRY_INITIAL_SECONDS", 1.0)
RETRY_MAX_SECONDS: float = _get_float("RETRY_MAX_SECONDS", 60.0)

# Most new columns a single COPY INTO may add through schema evolution.
# Measured on this account with scripts/verify_gate.py --check limit: a COPY
# that adds 100 columns succeeds, one that adds 101 fails entirely with
# "000691 Error in Schema Evolution: adding too many columns". A batch that
# introduces more new fields than this is split into several COPY operations.
MAX_NEW_COLUMNS_PER_COPY: int = _get_int("MAX_NEW_COLUMNS_PER_COPY", 100)

# Folder for the temporary NDJSON batch files. It is kept outside the
# repository so batch files are never committed. Each file is deleted after a
# successful load.
BATCH_DIR: Path = Path(
    _get(
        "BATCH_DIR",
        str(Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "kafka_snowflake_batches"),
    )
)

# ----------------------------------------------------------------------------
# Snowflake
# ----------------------------------------------------------------------------

# Name of the connection in the Snowflake config.toml (the same file the
# Snowflake CLI uses). Deliberately has NO default: silently falling back to
# some other connection could load data with the wrong user.
SNOWFLAKE_CONNECTION_NAME: str = _get("SNOWFLAKE_CONNECTION_NAME", "")

# Role that owns the schema and the target table. Ownership is what allows
# COPY INTO to add columns through schema evolution.
SNOWFLAKE_ROLE: str = validate_identifier(_get("SNOWFLAKE_ROLE", "CLAUDE_AI_ROLE"), "SNOWFLAKE_ROLE")

# Warehouse that runs COPY INTO (X-Small, auto-suspend 60 s).
SNOWFLAKE_WAREHOUSE: str = validate_identifier(
    _get("SNOWFLAKE_WAREHOUSE", "KAFKA_STREAMING_WH"), "SNOWFLAKE_WAREHOUSE"
)

# Where the pipeline objects live.
SNOWFLAKE_DATABASE: str = validate_identifier(
    _get("SNOWFLAKE_DATABASE", "AI_OPERATOR_DB"), "SNOWFLAKE_DATABASE"
)
SNOWFLAKE_SCHEMA: str = validate_identifier(
    _get("SNOWFLAKE_SCHEMA", "KAFKA_STREAMING"), "SNOWFLAKE_SCHEMA"
)

# Target table (schema evolution enabled) and the objects around it.
SNOWFLAKE_TABLE: str = validate_identifier(_get("SNOWFLAKE_TABLE", "ORDER_EVENTS"), "SNOWFLAKE_TABLE")
SNOWFLAKE_STAGE: str = validate_identifier(
    _get("SNOWFLAKE_STAGE", "ORDER_EVENTS_STAGE"), "SNOWFLAKE_STAGE"
)
SNOWFLAKE_FILE_FORMAT: str = validate_identifier(
    _get("SNOWFLAKE_FILE_FORMAT", "NDJSON_FF"), "SNOWFLAKE_FILE_FORMAT"
)

# Application-level audit tables written by the consumer.
SNOWFLAKE_BATCH_LOG_TABLE: str = "INGEST_BATCH_LOG"
SNOWFLAKE_SCHEMA_LOG_TABLE: str = "SCHEMA_EVOLUTION_LOG"

# Tag attached to every query this pipeline runs, so its activity can be found
# in Snowflake query history.
SNOWFLAKE_QUERY_TAG: str = "kafka_snowflake_streaming"


def require_snowflake_connection_name() -> str:
    """Return the configured Snowflake connection name.

    Raises:
        RuntimeError: if ``SNOWFLAKE_CONNECTION_NAME`` is not set. Failing here
            gives a clear message instead of an obscure login error later.
    """
    if not SNOWFLAKE_CONNECTION_NAME:
        raise RuntimeError(
            "SNOWFLAKE_CONNECTION_NAME is not set. Copy .env.example to .env and "
            "set it to the name of your connection in the Snowflake config.toml."
        )
    return SNOWFLAKE_CONNECTION_NAME


# ----------------------------------------------------------------------------
# PostgreSQL source database (enhancement: future source of the order events)
# ----------------------------------------------------------------------------
# These settings are used only by the ``source_db`` package. The existing
# producer, consumer and Snowflake loader do not read them.

# A PostgreSQL identifier we are willing to place directly into SQL text
# (CREATE DATABASE cannot take the name as a bind variable). Lower case only,
# which is how PostgreSQL stores unquoted names.
_PG_IDENTIFIER_PATTERN = re.compile(r"^[a-z_][a-z0-9_]*$")


def validate_pg_identifier(value: str, setting_name: str = "identifier") -> str:
    """Return ``value`` if it is a safe, lower-case PostgreSQL identifier.

    Raises:
        ValueError: if the value contains anything other than lower-case
            letters, digits and ``_``, or starts with a digit.
    """
    if not _PG_IDENTIFIER_PATTERN.match(value):
        raise ValueError(
            f"{setting_name} must be a plain lower-case PostgreSQL identifier "
            f"(letters, digits and _), got {value!r}"
        )
    return value


# Where the PostgreSQL server listens.
POSTGRES_HOST: str = _get("POSTGRES_HOST", "localhost")
POSTGRES_PORT: int = _get_int("POSTGRES_PORT", 5432)

# Login name. The PASSWORD deliberately has no default and must come from the
# environment or the git-ignored .env file; it is never written in the code.
POSTGRES_USER: str = _get("POSTGRES_USER", "postgres")
POSTGRES_PASSWORD: str = _get("POSTGRES_PASSWORD", "")

# Database created for this project. No other database is created or changed.
POSTGRES_DATABASE: str = validate_pg_identifier(_get("POSTGRES_DATABASE", "kafka_source_db"), "POSTGRES_DATABASE")

# Existing database used ONLY as the place to connect to when issuing
# CREATE DATABASE (a database cannot be created from inside itself).
# Nothing is created or changed in it.
POSTGRES_MAINTENANCE_DATABASE: str = validate_pg_identifier(
    _get("POSTGRES_MAINTENANCE_DATABASE", "postgres"), "POSTGRES_MAINTENANCE_DATABASE"
)

# Source table inside POSTGRES_DATABASE (defined in sql/postgres/01_create_source_table.sql).
POSTGRES_TABLE: str = "order_events"

# Value of order_events.record_source for the rows copied once from the
# Project 3 production demo. Future CDC uses it to tell these rows, which are
# ALREADY in Snowflake, from rows created later in PostgreSQL.
POSTGRES_BACKFILL_SOURCE: str = "project3_backfill"


def require_postgres_password() -> str:
    """Return the configured PostgreSQL password.

    Raises:
        RuntimeError: if ``POSTGRES_PASSWORD`` is not set, with a message that
            says where to put it, instead of an obscure login failure later.
    """
    if not POSTGRES_PASSWORD:
        raise RuntimeError(
            "POSTGRES_PASSWORD is not set. Add it to the .env file in the project root "
            "(see .env.example). The password is never stored in the source code."
        )
    return POSTGRES_PASSWORD


# ----------------------------------------------------------------------------
# Change data capture (CDC): PostgreSQL -> Debezium -> Kafka -> CDC bridge
# ----------------------------------------------------------------------------
# Used only by the ``cdc`` package and its scripts. The existing producer,
# consumer and Snowflake loader do not read these settings.

# Prefix Debezium puts in front of its topic names. Debezium names a table's
# topic "<prefix>.<schema>.<table>", which gives CDC_SOURCE_TOPIC below.
CDC_TOPIC_PREFIX: str = _get("CDC_TOPIC_PREFIX", "pgcdc")

# Topic Debezium writes the raw change events to; the bridge reads it.
CDC_SOURCE_TOPIC: str = _get("CDC_SOURCE_TOPIC", f"{CDC_TOPIC_PREFIX}.public.{POSTGRES_TABLE}")

# Topic the bridge writes to: the EXISTING order-events topic, so the existing
# consumer picks the messages up without any change.
CDC_TARGET_TOPIC: str = _get("CDC_TARGET_TOPIC", KAFKA_TOPIC)

# Consumer group of the bridge. Kafka stores the bridge's position in the CDC
# topic under this name, which is how a restarted bridge resumes.
CDC_BRIDGE_GROUP_ID: str = _get("CDC_BRIDGE_GROUP_ID", "cdc-bridge")

# The bridge confirms its work (flush to Kafka, then commit its position)
# after this many forwarded change events, or sooner when the topic is quiet.
CDC_BRIDGE_COMMIT_EVERY: int = _get_int("CDC_BRIDGE_COMMIT_EVERY", 100)

# Longest time the bridge's main loop may go without asking Kafka for the next
# change event (milliseconds) before Kafka decides the bridge is stuck, removes
# it from its consumer group and hands its partition to someone else.
# The Kafka default is 300000 (5 minutes). The bridge's slowest normal loop
# pass is far shorter (two flushes of up to 30 s each plus one retry pause of
# up to RETRY_MAX_SECONDS), so 10 minutes leaves a wide margin for a slow
# machine or a short stall, while a bridge that is really stuck is still
# detected. Must stay above that slowest loop pass; a unit test checks it.
CDC_BRIDGE_MAX_POLL_INTERVAL_MS: int = _get_int("CDC_BRIDGE_MAX_POLL_INTERVAL_MS", 600000)

# Upper limit on the records one poll hands to the application. The bridge
# takes one change event per poll and checkpoints every CDC_BRIDGE_COMMIT_EVERY
# events, so the work between two polls is already small; this caps it
# explicitly at the same size as one checkpoint batch.
CDC_BRIDGE_MAX_POLL_RECORDS: int = _get_int("CDC_BRIDGE_MAX_POLL_RECORDS", 100)

# PostgreSQL columns that exist for bookkeeping only. The bridge removes them
# from every message, so they never reach Kafka's order-events topic and never
# become columns in Snowflake through schema evolution. Any OTHER column,
# including one added to the table later, is forwarded.
CDC_TECHNICAL_COLUMNS: frozenset[str] = frozenset(
    {
        "record_source",
        "source_kafka_topic",
        "source_kafka_partition",
        "source_kafka_offset",
        "source_kafka_timestamp",
        "created_at",
        "updated_at",
    }
)

# Dedicated PostgreSQL login for Debezium (created by sql/postgres/02_cdc_setup.sql).
# Like every password in this project, POSTGRES_CDC_PASSWORD has no default
# and lives only in the git-ignored .env file.
POSTGRES_CDC_USER: str = validate_pg_identifier(_get("POSTGRES_CDC_USER", "cdc_user"), "POSTGRES_CDC_USER")
POSTGRES_CDC_PASSWORD: str = _get("POSTGRES_CDC_PASSWORD", "")

# Names of the PostgreSQL objects CDC uses. They must match
# sql/postgres/02_cdc_setup.sql and cdc/debezium-postgres.properties.
POSTGRES_CDC_PUBLICATION: str = "order_events_cdc_pub"
POSTGRES_CDC_SLOT: str = "order_events_cdc_slot"

# Address of the Kafka Connect REST interface (local only); used to read the
# connector's status.
CONNECT_REST_URL: str = _get("CONNECT_REST_URL", "http://localhost:8083")

# Name of the Debezium connector inside Kafka Connect (see cdc/debezium-postgres.properties).
CONNECT_CONNECTOR_NAME: str = "order-events-postgres-cdc"
