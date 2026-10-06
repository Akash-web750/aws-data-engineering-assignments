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
