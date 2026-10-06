# Assignment 3 (Portfolio Assignment 9) — Kafka-to-Snowflake Streaming Pipeline

A real-time pipeline that moves JSON order events from a local Kafka broker into a Snowflake table, and lets **Snowflake add new columns automatically** when Kafka starts sending new fields.

```
Local Kafka 4.x -> Python consumer -> local NDJSON batch -> Snowflake internal stage -> COPY INTO -> ORDER_EVENTS
                                                                                        (Snowflake-native schema evolution)
```

The full design is in [spec.md](spec.md).

---

## 1. Current status

> **Last updated: 2026-10-06.** This section states only what has been run on the actual machine and account.

**Production demo: completed and passed.** 300 messages were produced to Kafka and 300 rows were loaded into the production table `ORDER_EVENTS`, with 0 rejected and 0 duplicates, while Snowflake added 4 columns automatically (section 7.7).

| Area | Status |
|---|---|
| Local Kafka 4.3.1 on Windows (install, start, topics, stop, restart) | **VERIFIED** |
| Producer (schema v1/v2/v3, extra fields, malformed messages) | **VERIFIED** |
| Unit tests | **108 passed** (6 live tests skipped in that run) |
| Live end-to-end test `tests/test_e2e.py` | **6 of 6 passed**, on the dedicated table `ORDER_EVENTS_E2E` (section 7.6) |
| Production demo: Kafka → consumer → `ORDER_EVENTS` | **VERIFIED**: 300 produced, 300 loaded, 0 rejected, 0 duplicates, 9 successful `COPY` operations (section 7.7) |
| Schema evolution on the production table | **VERIFIED**: 14 → 18 columns, added by Snowflake during `COPY` |
| `DISCOUNT_PCT NUMBER(5,2)` on the production table | **VERIFIED**: type unchanged, not schema-evolved, values stored exactly |
| `ORDER_EVENTS_LATEST` after evolution, on the production table | **VERIFIED**: 300 rows, 300 distinct messages |
| Latency within about 15 s (acceptance criterion 2) | **VERIFIED**: all 300 messages observed within the target; maximum 14.17 s. The margin is thin (see limitations) |
| Warehouse auto-resume and auto-suspend | **VERIFIED**: resumed from `SUSPENDED` on the first load; suspended again about 75 s after the last query, with the consumer still running idle |
| Dead-letter topic | **VERIFIED in the end-to-end test**; no malformed message was sent in the production demo |
| Consumer restart without loss | **VERIFIED in the end-to-end test**; not exercised in the production demo |
| Type conflict (valid → invalid → valid) | **VERIFIED in the end-to-end test**; none was sent in the production demo |
| `--extra-field` (arbitrary new field) | **VERIFIED in the end-to-end test**; not used in the production demo |
| Batch splitting at the 100-column limit | **VERIFIED by the gate** with the production loader class (section 6) |
| PostgreSQL source database `kafka_source_db.order_events` (enhancement) | **Created and loaded**: 300 backfilled rows, equal to Snowflake field by field; it is now the source of CDC (sections 11 and 12) |
| Change data capture from PostgreSQL (enhancement) | **VERIFIED live**: PostgreSQL → Debezium → Kafka → CDC bridge → existing consumer → Snowflake. Two rows inserted in PostgreSQL arrived in Snowflake exactly once each; the 300 existing rows were not republished. INSERT only (section 12) |
| Retry after a Snowflake failure | Unit-tested; **NOT YET VERIFIED** live |
| A part failing midway through a split batch | Unit-tested; **NOT YET VERIFIED** live |

Nothing is **BLOCKED**.

**State left after the production demo.**

- `ORDER_EVENTS` holds the 300 demo rows.
- `INGEST_BATCH_LOG` and `SCHEMA_EVOLUTION_LOG` hold the rows of this run plus the rows of the earlier end-to-end run (`TARGET_TABLE = 'ORDER_EVENTS_E2E'`).
- The Kafka broker is running on `localhost:9092`.
- The consumer was stopped after the verification was complete.

**Remaining limitations.**

| Limitation | Detail |
|---|---|
| Latency margin | The consumer does not poll Kafka while a load and its audit inserts are running, so batches landed every 7–9 s instead of every 5 s. The slowest message took 14.17 s against a target of about 15 s; a slower load could push the worst case past it |
| Unknown numeric-field sizing | Snowflake sizes an evolved numeric column to its first values and never widens it. Larger values are then rejected, and a fraction sent to an integer-sized column is dropped without an error. `DISCOUNT_PCT` is protected by its explicit `NUMBER(5,2)` type; any other numeric business field must be declared before it is produced (section 5) |
| Retry after a Snowflake failure | Covered by unit tests only (`tests/test_consumer_commit.py`); not exercised against the real account |
| A part failing midway through a split batch | Covered by unit tests only (`tests/test_batch_splitting.py`); not exercised against the real account |
| Deleting a Kafka topic on Windows | Crashes the local broker, which then cannot restart until `scripts/reset_kafka.ps1` clears its data (section 7.1). The pipeline never deletes topics; the end-to-end test no longer does so on Windows |
| `--extra-field` | Verified in the end-to-end test; not used in the production demo |
| One message with more than 100 new fields | Cannot be loaded by any `COPY`; goes to the dead-letter topic |
| Delivery is at-least-once | A crash between a successful `COPY` and the offset commit can load a batch twice; `ORDER_EVENTS_LATEST` removes such duplicates |

**Risks found by the gate, and what was done.**

| Risk | Finding on this account | Resolution |
|---|---|---|
| Too many new fields in one batch | One `COPY` adds at most **100** columns; 101 fail the whole `COPY` (error `000691`) | **Fixed:** the loader splits such a batch into several `COPY` operations (section 5). Verified live with a 250-column batch |
| Evolved numeric columns never widen | `7` → `NUMBER(1,0)`, `12.5` → `NUMBER(3,1)`; larger values are then rejected; `7.25` into the integer column is stored as `7` with no error | **Fixed for the known field:** `DISCOUNT_PCT` is declared `NUMBER(5,2)`. **Remaining limitation** for numeric fields not known in advance |
| `SELECT *` view breaks when a column is added | Error `002057` | **Fixed:** `ORDER_EVENTS_LATEST` selects the declared columns by name. Verified before and after evolution |
| File-level `LOAD_FAILED` looked like a finished batch | `COPY` returns it as a normal result row | **Fixed:** the loader raises, nothing is committed |

---

## 2. What is in this folder

| Path | Purpose |
|---|---|
| [spec.md](spec.md) | Technical specification |
| [config/settings.py](config/settings.py) | Every setting and object name |
| [producer/](producer/) | `event_factory.py` builds events; `producer.py` sends them to Kafka |
| [consumer/](consumer/) | `consumer.py` (main loop), `transform.py`, `batching.py`, `snowflake_loader.py`, `dead_letter.py` |
| [sql/](sql/) | `00_admin_setup.sql` (administrator), `01_create_objects.sql`, `02_validate.sql`, `99_teardown.sql` |
| [scripts/](scripts/) | Kafka install/start/stop/topics/reset (PowerShell) and `verify_gate.py` |
| [tests/](tests/) | Unit tests and the live end-to-end test |
| [source_db/](source_db/) | Enhancement: PostgreSQL source database, its setup and one-time backfill (section 11) |
| [cdc/](cdc/) | Enhancement: CDC bridge and Debezium / Kafka Connect configuration; live and verified (section 12) |
| `scripts/start_pipeline.ps1`, `scripts/stop_pipeline.ps1` | Start and stop the whole pipeline with one command each (section 13) |

---

## 3. Setup (one time)

Prerequisites: Windows 11, Java 17+, Python 3.10+, the Snowflake CLI with a working connection.

```powershell
# 1. Administrator, once, in Snowsight: run sql/00_admin_setup.sql
#    (creates the X-Small warehouse KAFKA_STREAMING_WH and grants it to CLAUDE_AI_ROLE)

# 2. Create the Snowflake objects
snow sql -c <connection> --role CLAUDE_AI_ROLE -f sql/01_create_objects.sql

# 3. Tell the pipeline which Snowflake connection to use
Copy-Item .env.example .env        # then set SNOWFLAKE_CONNECTION_NAME in .env

# 4. Python packages
pip install -r requirements-dev.txt

# 5. Kafka (downloads to C:\kafka, verifies the SHA-512 checksum)
.\scripts\install_kafka.ps1
```

No credentials are stored in this project. The consumer logs in through the named connection in the Snowflake `config.toml`.

**Using your own database and role.** The provided files use the database `AI_OPERATOR_DB` and the role `CLAUDE_AI_ROLE` by default. The role must be able to create a schema in that database, because it has to own the target table for schema evolution to work. If your names differ, change them in these places:

| Value | Where it is used |
|---|---|
| Database `AI_OPERATOR_DB` | `USE DATABASE` at the top of `sql/01_create_objects.sql`, `sql/02_validate.sql` and `sql/99_teardown.sql`; `SNOWFLAKE_DATABASE` in `.env` (default in `config/settings.py`) |
| Role `CLAUDE_AI_ROLE` | The `GRANT … TO ROLE` line in `sql/00_admin_setup.sql`; `SNOWFLAKE_ROLE` in `.env` (default in `config/settings.py`); the `--role` option in the `snow sql` commands of this README |

The schema, table, stage and warehouse names can stay as they are.

---

## 4. Run

```powershell
# Terminal 1 - broker
.\scripts\start_kafka.ps1                 # or: .\scripts\start_kafka.ps1 -Background
.\scripts\create_topics.ps1               # once per fresh Kafka data folder

# Terminal 2 - consumer (runs until Ctrl+C)
python -m consumer.consumer

# Terminal 3 - producer
python -m producer.producer --rate 5                        # schema v1, until Ctrl+C
python -m producer.producer --rate 5 --evolve-every 300     # v1 -> v2 -> v3 every 300 messages
python -m producer.producer --schema-version 2 --count 100  # 100 messages of v2
python -m producer.producer --extra-field campaign=diwali   # any new field, at any time
python -m producer.producer --type-conflict-demo            # valid, invalid type, valid
python -m producer.producer --bad-every 20                  # a malformed message every 20

# Check
snow sql -c <connection> --role CLAUDE_AI_ROLE --warehouse KAFKA_STREAMING_WH -f sql/02_validate.sql

# Stop
.\scripts\stop_kafka.ps1
```

---

## 5. How schema evolution works here

1. The table `ORDER_EVENTS` is created with `ENABLE_SCHEMA_EVOLUTION = TRUE` and only the version-1 columns.
2. The consumer writes each micro-batch as newline-delimited JSON and loads it with `COPY INTO … MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE`.
3. When a batch contains a top-level field with no matching column, **Snowflake adds the column** during that `COPY`.

**The consumer never issues `ALTER TABLE`.** `SCHEMA_EVOLUTION_LOG` is an *application-level audit table*: after a `COPY`, the consumer only detects columns that Snowflake has already created and records one row for each. If that audit insert fails, the column still exists and the data is still loaded.

### Numeric fields

- **The known numeric business field `DISCOUNT_PCT` is explicitly typed** as `NUMBER(5,2)` in [sql/01_create_objects.sql](sql/01_create_objects.sql). It is not left to schema evolution.
- **Unknown and new fields still use Snowflake schema evolution:** `PAYMENT_METHOD`, `LOYALTY_TIER`, `IS_GIFT`, `SHIPPING_ADDRESS`, and anything sent with `--extra-field`.
- **Snowflake does not automatically widen an evolved numeric column.** It sizes the column to the first values it sees and keeps that type. A later, larger value is rejected.
- **Fractional values must not silently lose precision.** A fraction sent to a column that schema evolution created from whole numbers is stored without its fraction and without any error. A numeric business field must therefore be declared with an explicit type before it is produced, as was done for `DISCOUNT_PCT`.
- **Remaining limitation:** a numeric field nobody declared in advance still gets a column sized to its first values. Text, boolean, date, timestamp and nested fields are not affected.

### More than 100 new fields in one batch

One `COPY` can add at most 100 columns (measured, section 6). When a batch introduces more:

1. The loader cuts the batch file, in record order, into part files that each add at most 100 columns. Columns added by an earlier part count as existing for the later ones.
2. Each part gets its own `PUT`, `COPY` and `INGEST_BATCH_LOG` row; the parts share one `BATCH_ID`.
3. Kafka offsets are committed only after **every** part is loaded. If a part fails, nothing is committed and the batch is retried.
4. The retry reuses the same parts and skips the ones already loaded, so they are not loaded twice.

A single message that alone introduces more than 100 new fields cannot be loaded by any `COPY`; the consumer sends it to the dead-letter topic.

### The de-duplicated view

`ORDER_EVENTS_LATEST` keeps one row per Kafka message (topic, partition, offset). It names the 14 declared columns instead of using `SELECT *`, because a `SELECT *` view stops working when schema evolution adds a column. Columns added later are read from `ORDER_EVENTS` directly.

---

## 6. Verification gate (spec.md section 18)

Each behaviour the design depends on must be checked on the real environment before it is described as working. Results below are from `python -m scripts.verify_gate` (and its `--check numeric | limit | shape | split` variants), run on `KAFKA_STREAMING_WH` on 2026-10-06 against throw-away `GATE_*` tables that were dropped afterwards. `ORDER_EVENTS` was not touched.

| # | Behaviour | Status | Observed |
|---|---|---|---|
| 0 | New field → Snowflake creates the column | **VERIFIED** | 8 new fields → 8 new columns; `DESCRIBE TABLE` shows `"evolutionType":"ADD_COLUMN","evolutionMode":"COPY"` for each |
| 1 | New column's values are loaded by the same `COPY` | **VERIFIED** | Row `b1` holds all 8 new values straight after the one `COPY`; no second load was needed |
| 2 | Data types Snowflake infers for new columns | **VERIFIED** (table below) | Numeric types are sized to the first values |
| 2a | A narrow evolved numeric column later receives a larger value | **VERIFIED: the row is rejected, the column does not widen** | `PARTIALLY_LOADED`; see "Numeric widening check" below |
| 2b | A fractional value arrives in an evolved integer column | **VERIFIED: loaded with the fraction silently dropped** | `7.25` stored as `7`, status `LOADED`, 0 errors |
| 3 | Maximum columns one `COPY` may add | **VERIFIED: exactly 100** | 100 columns added in one `COPY`; 101 fail the whole `COPY` with error `000691`; a second `COPY` adds 100 more to the same table |
| 3a | The loader splits a batch that introduces more than 100 new fields | **VERIFIED** | 250 new columns → 3 `COPY` operations (100 + 100 + 50); 5 of 5 rows loaded, no duplicates |
| 4 | Result columns returned by `COPY INTO` | **VERIFIED** | `file, status, rows_parsed, rows_loaded, error_limit, errors_seen, first_error, first_error_line, first_error_character, first_error_column_name` |
| 5 | Kafka 4.x runs natively on Windows 11 | **VERIFIED** | Kafka 4.3.1, Java 17.0.20 (section 7.1) |
| 6 | `PUT` from a Windows path | **VERIFIED** | `UPLOADED`, with and without a space in the path |
| + | Type-conflict row with `ON_ERROR = CONTINUE` | **VERIFIED** | valid, invalid, valid → `PARTIALLY_LOADED`, 3 parsed, 2 loaded, 1 error; rows `c1` and `c3` present |
| + | Rows that lack the new fields | **VERIFIED** | Earlier rows `a1`, `a2` and row `b2` show `NULL` in the columns they did not carry |
| + | Does a `SELECT *` view survive an added column? | **VERIFIED: it does not** | Error `002057`; this is why `ORDER_EVENTS_LATEST` lists its columns explicitly |
| + | Explicit `DISCOUNT_PCT NUMBER(5,2)` stores discounts exactly | **VERIFIED** | 0.0, 5.0, 7.5, 12.5, 100.0 and 7.25 stored as sent; type unchanged after evolution |
| + | `ORDER_EVENTS_LATEST` before and after schema evolution | **VERIFIED** | Same view definition answers before and after 5 columns were added; duplicate message removed (9 rows in table, 8 in view) |
| + | The production loader's own `PUT` + `COPY` (no stage prefix) and audit rows | **VERIFIED** on a throw-away table | `status=LOADED copies=1`, 3 of 3 rows; stage empty afterwards |
| + | Real Kafka → consumer → `ORDER_EVENTS` | **VERIFIED** in the production demo | 300 messages produced, 300 rows loaded, 0 rejected, 0 duplicates (section 7.7) |

Nothing is currently **BLOCKED**.

**Inferred types (gate item 2).**

| JSON value in the file | Column type Snowflake created |
|---|---|
| `"upi"` | `VARCHAR(16777216)` |
| `7` | `NUMBER(1,0)` |
| `12.5` | `NUMBER(3,1)` |
| `true` | `BOOLEAN` |
| `"2026-10-06T10:00:02Z"` | `TIMESTAMP_NTZ(9)` |
| `"2026-10-06"` | `DATE` |
| `{"city": "Pune", "pincode": "411001"}` | `VARIANT` |
| `["a", "b"]` | `ARRAY` |

**Key output** (object and array values shortened to one line).

```
COPY INTO GATE_CHECK FROM @ORDER_EVENTS_STAGE/gate_check/ FILES = ('evolved.json.gz') FILE_FORMAT = (FORMAT_NAME = NDJSON_FF) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE ON_ERROR = CONTINUE PURGE = TRUE
ROW > ('order_events_stage/gate_check/evolved.json.gz', 'LOADED', 2, 2, 2, 0, None, None, None, None)

SELECT * FROM GATE_CHECK ORDER BY _KAFKA_OFFSET
COLS> ['EVENT_ID', 'QUANTITY', 'UNIT_PRICE', 'EVENT_TIME', '_KAFKA_OFFSET', 'NEW_OBJECT', 'NEW_ARRAY', 'NEW_INTEGER', 'NEW_DATE_TEXT', 'NEW_DECIMAL', 'NEW_BOOLEAN', 'NEW_TEXT', 'NEW_TIMESTAMP_TEXT']
ROW > ('a1', 1, Decimal('10.50'), datetime.datetime(2026, 10, 6, 10, 0), 0, None, None, None, None, None, None, None, None)
ROW > ('a2', 2, Decimal('20.00'), datetime.datetime(2026, 10, 6, 10, 0, 1), 1, None, None, None, None, None, None, None, None)
ROW > ('b1', 3, Decimal('30.25'), datetime.datetime(2026, 10, 6, 10, 0, 2), 2, '{"city": "Pune", "pincode": "411001"}', '["a", "b"]', 7, datetime.date(2026, 10, 6), Decimal('12.5'), True, 'upi', datetime.datetime(2026, 10, 6, 10, 0, 2))
ROW > ('b2', 4, Decimal('40.00'), datetime.datetime(2026, 10, 6, 10, 0, 3), 3, None, None, None, None, None, None, 'card', None)
```

Type conflict (valid, text in `QUANTITY`, valid):

```
ROW > ('order_events_stage/gate_check/conflict.json.gz', 'PARTIALLY_LOADED', 3, 2, 3, 1, 'Failed to cast variant value "not-a-number" to FIXED', 2, None, None)
SELECT EVENT_ID, QUANTITY FROM GATE_CHECK WHERE EVENT_ID LIKE 'c%' ORDER BY 1
ROW > ('c1', 5)
ROW > ('c3', 6)
```

150 new fields in one file:

```
ERROR> 000691 (22000): Error in Schema Evolution:
adding too many columns
```

`SELECT *` view after the columns were added:

```
ERROR> 002057 (42601): SQL compilation error:
View definition for 'AI_OPERATOR_DB.KAFKA_STREAMING.GATE_CHECK_STAR_V' declared 5 column(s), but view query produces 13 column(s).
```

**Numeric widening check** (`python -m scripts.verify_gate --check numeric`, throw-away table `GATE_NUMERIC`, dropped afterwards).

| Step | File contents | Column types before | `COPY` result | Column types after |
|---|---|---|---|---|
| A | `NEW_INTEGER` 7, `NEW_DECIMAL` 12.5 | columns do not exist | `LOADED`, 1 parsed, 1 loaded | `NUMBER(1,0)`, `NUMBER(3,1)` |
| B | row 1: integer 8 (fits); row 2: integer **123456** | `NUMBER(1,0)` | `PARTIALLY_LOADED`, 2 parsed, 1 loaded, 1 error: `Number out of representable range: type FIXED, value 123456` | `NUMBER(1,0)` (unchanged) |
| C | row 1: decimal 15.0 (fits); row 2: decimal **98765.4321** | `NUMBER(3,1)` | `PARTIALLY_LOADED`, 2 parsed, 1 loaded, 1 error: `Number out of representable range: type FIXED, value 98765.4` | `NUMBER(3,1)` (unchanged) |
| D | integer column receives **7.25** | `NUMBER(1,0)` | `LOADED`, 1 parsed, 1 loaded, 0 errors | `NUMBER(1,0)` (unchanged) |

Rows in the table at the end:

```
ROW > ('n1', 7, Decimal('12.5'))
ROW > ('n2-fits', 8, Decimal('12.5'))
ROW > ('n4-fits', 7, Decimal('15.0'))
ROW > ('n6-fraction-into-integer', 7, Decimal('12.5'))
```

The rows carrying 123456 and 98765.4321 are absent. The row that carried 7.25 is present with 7.

Not tested: how Snowflake sizes a new numeric column when the first file contains several rows with different values.

**Column limit check** (`python -m scripts.verify_gate --check limit`). Each probe loads one row carrying N never-seen fields into a freshly created table, with the pipeline's exact `COPY` options.

```
PROBE>   1 new fields in one COPY -> columns added:   1 | status LOADED, rows_parsed 1, rows_loaded 1
PROBE> 150 new fields in one COPY -> columns added:   0 | ERROR 000691 (22000): Error in Schema Evolution: adding too many columns
PROBE>  75 new fields in one COPY -> columns added:  75 | status LOADED, rows_parsed 1, rows_loaded 1
PROBE> 112 new fields in one COPY -> columns added:   0 | ERROR 000691 (22000): Error in Schema Evolution: adding too many columns
PROBE>  93 new fields in one COPY -> columns added:  93 | status LOADED, rows_parsed 1, rows_loaded 1
PROBE> 102 new fields in one COPY -> columns added:   0 | ERROR 000691 (22000): Error in Schema Evolution: adding too many columns
PROBE>  97 new fields in one COPY -> columns added:  97 | status LOADED, rows_parsed 1, rows_loaded 1
PROBE>  99 new fields in one COPY -> columns added:  99 | status LOADED, rows_parsed 1, rows_loaded 1
PROBE> 100 new fields in one COPY -> columns added: 100 | status LOADED, rows_parsed 1, rows_loaded 1
PROBE> 101 new fields in one COPY -> columns added:   0 | ERROR 000691 (22000): Error in Schema Evolution: adding too many columns
RESULT> largest number of new columns one COPY added: 100; smallest that failed: 101
```

A second `COPY` then added another 100 columns to the same table (2 rows loaded in total).

**Shape check** (`--check shape`): a copy of the production table (`CREATE TABLE … LIKE ORDER_EVENTS`) and the real definition of `ORDER_EVENTS_LATEST`, read back with `GET_DDL` and pointed at the copy.

View **before** schema evolution; offset 1 was loaded twice and appears once, with the earlier `_INGESTED_AT`:

```
SELECT COUNT(*) AS ROWS_IN_TABLE FROM GATE_EVENTS
ROW > (3,)
SELECT _KAFKA_PARTITION, _KAFKA_OFFSET, _INGESTED_AT FROM GATE_EVENTS_LATEST ORDER BY _KAFKA_OFFSET
ROW > (0, 0, datetime.datetime(2026, 10, 6, 10, 0, 5))
ROW > (0, 1, datetime.datetime(2026, 10, 6, 10, 0, 5))
```

Column types after loading rows with new fields. `DISCOUNT_PCT` keeps its declared type; the five below it were added by Snowflake:

```
TYPE> DISCOUNT_PCT       NUMBER(5,2)
TYPE> LOYALTY_TIER       VARCHAR(16777216)
TYPE> IS_GIFT            BOOLEAN
TYPE> SHIPPING_ADDRESS   VARIANT
TYPE> PAYMENT_METHOD     VARCHAR(16777216)
TYPE> CAMPAIGN           VARCHAR(16777216)
```

Stored values (discounts sent: 0.0, 5.0, 7.5, 12.5, 100.0, 7.25); `COPY` reported `LOADED`, 6 parsed, 6 loaded, 0 errors:

```
ROW > (2, Decimal('0.00'), 'UPI', 'GOLD', False, 'diwali', 'Pune')
ROW > (3, Decimal('5.00'), 'UPI', 'GOLD', False, 'diwali', 'Pune')
ROW > (4, Decimal('7.50'), 'UPI', 'GOLD', False, 'diwali', 'Pune')
ROW > (5, Decimal('12.50'), 'UPI', 'GOLD', False, 'diwali', 'Pune')
ROW > (6, Decimal('100.00'), 'UPI', 'GOLD', False, 'diwali', 'Pune')
ROW > (7, Decimal('7.25'), 'UPI', 'GOLD', False, 'diwali', 'Pune')
```

The same view **after** schema evolution:

```
SELECT (SELECT COUNT(*) FROM GATE_EVENTS) AS ROWS_IN_TABLE, (SELECT COUNT(*) FROM GATE_EVENTS_LATEST) AS ROWS_IN_VIEW
ROW > (9, 8)
```

**Split check** (`--check split`): the production `SnowflakeLoader` class against a throw-away table.

```
LOADER> file=gate_split_p0-0_o0-2_771f0091.json status=LOADED copies=1 rows_parsed=3 rows_loaded=3 errors_seen=0 new_columns=2
Batch gate_split_p0-0_o3-7_83d77046.json introduces 250 new columns (limit 100 per COPY): split into 3 parts.
LOADER> file=gate_split_p0-0_o3-7_83d77046.json status=LOADED copies=3 rows_parsed=5 rows_loaded=5 errors_seen=0 new_columns=250

SELECT COUNT(*) AS ROWS_IN_TABLE, COUNT(DISTINCT _KAFKA_PARTITION, _KAFKA_OFFSET) AS DISTINCT_MESSAGES FROM GATE_SPLIT
ROW > (8, 8)
COLUMNS> 255 (3 original + 2 from batch A + 250 from batch B = 255 expected)

INGEST_BATCH_LOG (FILE_NAME, RECORD_COUNT, ROWS_LOADED, ERRORS_SEEN, COPY_STATUS, OFFSET_RANGES, NEW_COLUMN_COUNT)
ROW > ('gate_split_p0-0_o0-2_771f0091.json', 3, 3, 0, 'LOADED', '{"0": [0, 2]}', 2)
ROW > ('gate_split_p0-0_o3-7_83d77046_part01of03.json', 2, 2, 0, 'LOADED', '{"0": [3, 4]}', 100)
ROW > ('gate_split_p0-0_o3-7_83d77046_part02of03.json', 2, 2, 0, 'LOADED', '{"0": [5, 6]}', 100)
ROW > ('gate_split_p0-0_o3-7_83d77046_part03of03.json', 1, 1, 0, 'LOADED', '{"0": [7, 7]}', 50)

SCHEMA_EVOLUTION_LOG rows for the table: 252
Files left in the stage: none
```

Not exercised live: a part failing midway through a split batch. That path (no commit, retry skips the loaded parts) is covered by unit tests in `tests/test_batch_splitting.py`.

**First gate run (before the fix).** The script's `COPY` read `FROM @ORDER_EVENTS_STAGE/gate_check` without a trailing slash, so Snowflake looked for `gate_checkbase.json.gz` and returned `LOAD_FAILED` with "Remote file … was not found" as an ordinary result row. Two changes followed: the slash was added to the script, and the loader now raises `BatchNotLoadedError` when `COPY` reports 0 rows parsed for a non-empty batch, so Kafka offsets are not committed (`tests/test_snowflake_loader.py`).

---

## 7. Evidence collected so far

### 7.1 Kafka 4.3.1 on Windows 11 (gate item 5)

Install, with checksum verification:

```
Downloading kafka_2.13-4.3.1.tgz ...
Checksum verified.
Kafka 4.3.1 installed in C:\kafka.
```

First start (storage formatted, broker up):

```
Formatting dynamic metadata voter directory C:/kafka/data with metadata.version 4.3-IV0.
Kafka is running on localhost:9092.
[2026-10-06 16:42:13,309] INFO Kafka version: 4.3.1 (org.apache.kafka.common.utils.AppInfoParser)
[2026-10-06 16:42:13,313] INFO [KafkaRaftServer nodeId=1] Kafka Server started (kafka.server.KafkaRaftServer)
```

Topics:

```
Created topic order_events.
Created topic order_events_dlq.
```

What was observed on Windows, and how the scripts deal with it:

| Observation | Handling |
|---|---|
| `kafka-server-start.bat` and `kafka-server-stop.bat` rely on `wmic`, which is absent on this Windows 11 build | `start_kafka.ps1` sets `KAFKA_HEAP_OPTS` so the start script skips the call; `stop_kafka.ps1` finds and ends the broker process itself |
| The project path contains a space | Kafka is installed in `C:\kafka` |
| Kafka command-line tools print `main ERROR Reconfiguration failed: No configuration found …` | Harmless logging message from the tools; the command still succeeds |
| `localhost` is tried over IPv6 first, and each client connection waited about 2 s | Clients set `broker.address.family = v4` |
| After `stop_kafka.ps1` (which terminates the process) the next start logs `DUPLICATE_BROKER_REGISTRATION` for a few seconds | The broker registers by itself once the old session expires; topics and committed offsets were intact afterwards |

**Deleting a topic crashes the broker on Windows (observed 2026-10-06).** The first end-to-end run deleted its two test topics during cleanup. The broker tried to rename each topic's data folder, Windows refused because the broker still had files in it open, and the broker shut itself down:

```
java.nio.file.AccessDeniedException: C:\kafka\data\order_events_e2e_ac769e19-1 -> C:\kafka\data\order_events_e2e_ac769e19-1.b88b3d129e5c48a19fb650bced407573-delete
ERROR Error while renaming dir for order_events_e2e_ac769e19-1 in log dir C:\kafka\data
ERROR Shutdown broker because all log dirs in C:\kafka\data have failed
```

It could not be started again either (`KafkaStorageException: The log dir C:\kafka\data is already offline`, `Encountered fatal fault: Error starting LogManager`). Recovery was `scripts\reset_kafka.ps1`, then `start_kafka.ps1` and `create_topics.ps1`; only test data was lost.

What follows from this:

- The pipeline itself never deletes topics, so normal running is not affected.
- **Do not delete topics on this broker.** To remove them, stop the broker and run `scripts\reset_kafka.ps1`.
- The end-to-end test now leaves its topics in place on Windows (`topic_deletion_is_safe` in `tests/test_e2e.py`, covered by `tests/test_e2e_cleanup.py`). Each run therefore leaves two small, uniquely named topics behind until the next reset. After the second run the broker was still up (section 7.6).

The same file-locking problem is expected when the broker deletes old log segments at the end of the retention period. That was not observed: retention is 7 days.

### 7.2 `PUT` from Windows paths (gate item 6)

Output of `scripts/verify_gate.py`:

```
SQL> PUT 'file://C:/Users/AKASHM~1/AppData/Local/Temp/gate_r6ts2fif/base.json' @ORDER_EVENTS_STAGE/gate_check AUTO_COMPRESS = TRUE OVERWRITE = TRUE
ROW > ('base.json', 'base.json.gz', 224, 160, 'NONE', 'GZIP', 'UPLOADED', '')

SQL> PUT 'file://C:/Users/AKASHM~1/AppData/Local/Temp/gate_r6ts2fif/folder with space/evolved.json' @ORDER_EVENTS_STAGE/gate_check AUTO_COMPRESS = TRUE OVERWRITE = TRUE
ROW > ('evolved.json', 'evolved.json.gz', 479, 288, 'NONE', 'GZIP', 'UPLOADED', '')
```

The `COPY` statements in the same run failed with:

```
090073 (22000): Warehouse 'CLAUDE_AI_WH' cannot be resumed because resource monitor 'CLAUDE_AI_RESOURCE_MONITOR' has exceeded its quota.
```

### 7.3 Producer → Kafka

`python -m producer.producer --rate 20 --count 12 --evolve-every 4 --bad-every 6 --extra-field campaign=diwali`, read back with the Kafka console consumer (shortened):

```
Partition:2 Offset:0 {"event_id": "3c0505b1-…", "event_time": "2026-10-06T11:13:31.308Z", "order_id": "ORD-100001", "customer_id": 283, "product": "Wireless Mouse", "quantity": 1, "unit_price": 799.0, "status": "DELIVERED", "campaign": "diwali"}
Partition:1 Offset:1 {"event_id": "broken", "quantity":
Partition:0 Offset:0 {… "status": "CANCELLED", "payment_method": "COD", "discount_pct": 0.0, "campaign": "diwali"}
Partition:0 Offset:2 {… "payment_method": "DEBIT_CARD", "discount_pct": 0.0, "loyalty_tier": "GOLD", "is_gift": false, "shipping_address": {"city": "Hyderabad", "state": "Telangana", "pincode": "500001"}, "campaign": "diwali"}
```

12 messages delivered: v1, v2 and v3 events, the extra field, and 2 malformed messages.

### 7.4 Consumer, Kafka side

The real consumer loop and dead-letter publisher were run against the broker, with the Snowflake loader replaced by a stand-in that only reads the batch file:

```
WARNING consumer.dead_letter: Rejected message order_events[1]@1 sent to order_events_dlq: Message is not valid JSON: Expecting value: line 1 column 36 (char 35)
WARNING consumer.dead_letter: Rejected message order_events[1]@3 sent to order_events_dlq: Message is not valid JSON: Expecting value: line 1 column 36 (char 35)
INFO consumer: Batch order_events_p0-2_o0-3_112c5b3b.json: 10 records -> LOADED, loaded 10, rejected 0, 0.00 s
FIRST RUN rows: 10 dead letters: 2
SECOND RUN (same group, nothing new) rows: 0 dead letters: 0
```

Committed offsets, read from Kafka after a broker restart:

```
GROUP           TOPIC         PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
scratch-101f8e  order_events  0          4               4               0
scratch-101f8e  order_events  1          4               4               0
scratch-101f8e  order_events  2          4               4               0
```

This shows batching, the dead-letter path, the offset commit (including past the malformed messages) and resuming after a restart. It does **not** show anything about Snowflake.

### 7.5 Unit tests

`python -m pytest tests -q`

```
108 passed, 6 skipped in 2.55s
```

(The 6 skipped tests are `tests/test_e2e.py`; they need `KAFKA_SF_LIVE=1`, the broker and the warehouse.)

### 7.6 End-to-end test: Kafka → consumer → Snowflake

`$env:KAFKA_SF_LIVE = "1"; python -m pytest tests/test_e2e.py -v` (second run, 2026-10-06, after the cleanup change; the first run earlier the same day also passed 6 of 6).

```
tests/test_e2e.py::test_1_v1_messages_are_loaded_automatically PASSED
tests/test_e2e.py::test_2_new_fields_create_columns_and_old_rows_stay PASSED
tests/test_e2e.py::test_3_v3_and_adhoc_fields_are_added_too PASSED
tests/test_e2e.py::test_4_type_conflict_row_is_rejected_and_pipeline_keeps_running PASSED
tests/test_e2e.py::test_5_malformed_message_goes_to_dead_letter_topic PASSED
tests/test_e2e.py::test_6_restart_loses_nothing_and_view_logic_finds_no_duplicates PASSED
E2E cleanup: leaving Kafka topics order_events_e2e_fdb14264 and order_events_e2e_fdb14264_dlq in place (deleting a topic crashes the local Kafka broker on Windows).
======================= 6 passed, 5 warnings in 59.49s ========================
```

The test uses its own topics (`order_events_e2e_fdb14264`, `…_dlq`), its own consumer group and its own table `ORDER_EVENTS_E2E`, created from the column list in `sql/01_create_objects.sql`. It runs the real producer functions, the real `StreamingConsumer`, the real `SnowflakeLoader` and the real dead-letter publisher.

**What the consumer loaded** — its own `INGEST_BATCH_LOG` rows for `ORDER_EVENTS_E2E`, one per `COPY`:

| Time (UTC) | Records | Parsed | Loaded | Rejected | Status | Columns Snowflake added | Seconds |
|---|---|---|---|---|---|---|---|
| 12:18:28 | 20 | 20 | 20 | 0 | `LOADED` | — | 1.74 |
| 12:18:33 | 10 | 10 | 10 | 0 | `LOADED` | `PAYMENT_METHOD` | 2.02 |
| 12:18:39 | 5 | 5 | 5 | 0 | `LOADED` | `CAMPAIGN`, `IS_GIFT`, `SHIPPING_ADDRESS`, `LOYALTY_TIER` | 2.05 |
| 12:18:45 | 3 | 3 | 2 | 1 | `PARTIALLY_LOADED` | — | 2.02 |
| 12:18:51 | 1 | 1 | 1 | 0 | `LOADED` | — | 1.52 |
| 12:18:55 | 1 | 1 | 1 | 0 | `LOADED` | — | 1.25 |
| 12:19:09 | 15 | 15 | 15 | 0 | `LOADED` | — | 1.70 |

Totals: 7 `COPY` operations, 55 records sent to Snowflake, **54 loaded, 1 rejected** (the deliberate type conflict: `Failed to cast variant value "not-a-number" to FIXED`). Average `PUT` + `COPY` time 1.75 s. A 56th message, the malformed one, went to the dead-letter topic and was never sent to Snowflake.

**Schema evolution through the real pipeline** — `SCHEMA_EVOLUTION_LOG` rows for `ORDER_EVENTS_E2E` (application-level audit of columns Snowflake created):

| Column | Type Snowflake inferred | First seen at (partition, offset) |
|---|---|---|
| `PAYMENT_METHOD` | `VARCHAR(16777216)` | 0, 10 |
| `CAMPAIGN` | `VARCHAR(16777216)` | 1, 7 |
| `IS_GIFT` | `BOOLEAN` | 1, 7 |
| `SHIPPING_ADDRESS` | `VARIANT` | 1, 7 |
| `LOYALTY_TIER` | `VARCHAR(16777216)` | 1, 7 |

Checked by the test's assertions:

- Before any new field: the table had exactly the 14 declared columns and 20 rows.
- After 10 version-2 messages: `PAYMENT_METHOD` exists; the 20 earlier rows are still there with `NULL` in it; the 10 new rows have values, loaded by the same `COPY` that added the column.
- `DISCOUNT_PCT` kept `NUMBER(5,2)`, is not in the schema audit log, and every stored value is one the producer sent.
- Evolved columns are queryable: `CAMPAIGN = 'diwali'` returned 5 rows and `SHIPPING_ADDRESS:city` returned 5 non-null values.
- A query on an original column (`COUNT(DISTINCT EVENT_ID)`) still ran after the columns were added and returned all 30 rows loaded so far.

**Dead-letter topic.** The malformed message arrived in `order_events_e2e_fdb14264_dlq` with its original bytes, an `error` header containing "not valid JSON" and the correct `source_topic` header; the consumer was still running and loaded the next message.

**Restart and offsets.** The consumer was stopped, 15 messages were produced while it was down (the row count stayed at 39), and after a restart with the same consumer group all 15 were loaded in one batch. Final check: 54 rows and 54 distinct (partition, offset) pairs. Committed offsets read from Kafka afterwards:

```
GROUP               TOPIC                         PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
e2e-fdb14264        order_events_e2e_fdb14264     0          25              25              0
e2e-fdb14264        order_events_e2e_fdb14264     1          18              18              0
e2e-fdb14264        order_events_e2e_fdb14264     2          13              13              0
dlq-reader-59a85db8 order_events_e2e_fdb14264_dlq 0          1               1               0
```

25 + 18 + 13 = 56 messages consumed and committed: the 54 loaded, the 1 rejected by Snowflake and the 1 sent to the dead-letter topic. Lag is 0 on every partition.

**Production table untouched.** After the run: `ORDER_EVENTS` has 0 rows and its 14 declared columns; there are no `INGEST_BATCH_LOG` or `SCHEMA_EVOLUTION_LOG` rows for it; the stage is empty.

**Broker after cleanup.** Still running, port 9092 open, both project topics and both test topics listed.

**Warehouse.** `KAFKA_STREAMING_WH` was suspended before the first run, resumed by itself at the first query (`resumed_on` 12:01:02 UTC), and showed `SUSPENDED` again when checked a little over a minute after the last query.

**Not covered by this test.**

- The warehouse suspending while the consumer keeps running with no messages (criterion 9 as written): the suspension above was observed after the test's consumer had stopped. It was observed with the consumer still running in the production demo (section 7.7).
- Latency from produce to queryable (criterion 2): the test waits for rows but does not measure the time. It was measured in the production demo (section 7.7).
- A Snowflake failure followed by a retry: unit tests only (`tests/test_consumer_commit.py`).
- A part failing midway through a split batch: unit tests only (`tests/test_batch_splitting.py`).
- The view: verified by the gate's shape check (section 6), not here.

### 7.7 Production demo evidence

Run on 2026-10-06 against the production table `AI_OPERATOR_DB.KAFKA_STREAMING.ORDER_EVENTS`, using the implementation as it stood after the end-to-end test. No code, SQL or configuration was changed for the demo.

**Commands.**

```powershell
python -m consumer.consumer                                           # left running
python -m producer.producer --rate 5 --count 300 --evolve-every 100
snow sql -c <connection> --role CLAUDE_AI_ROLE --warehouse KAFKA_STREAMING_WH -f sql/02_validate.sql
```

**Before the run.** `ORDER_EVENTS` had 0 rows and its 14 declared columns, both audit tables had no rows for it, the topic `order_events` was empty, and the warehouse was `SUSPENDED`.

**Producer.** It ran from 12:23:49 to 12:24:51 UTC: schema v1 for messages 1–100, v2 for 101–200, v3 for 201–300.

```
INFO producer: Producing to order_events at 5.0 msg/s, schema v1. Ctrl+C to stop.
INFO producer: After 100 messages: now producing schema v2 (new fields added).
INFO producer: After 200 messages: now producing schema v3 (new fields added).
INFO producer: Done. Delivered 300, failed 0.
```

**Result.**

| Measure | Result |
|---|---|
| Messages produced | 300 |
| Rows loaded into `ORDER_EVENTS` | 300 |
| Rows rejected | 0 |
| Duplicate Kafka messages (topic, partition, offset) | 0 |
| `COPY` operations | 9, all `LOADED` |
| Offsets not loaded, per partition | 0, 0, 0 |
| Files in the stage after the loads | 0 |
| Local batch files left | 0 |
| Messages in the dead-letter topic | 0 (no malformed message was sent) |

**Rows arrived automatically.** The row count of `ORDER_EVENTS`, sampled while the producer ran, with nobody doing anything:

```
SAMPLE 12:23:51.688 UTC rows=0
SAMPLE 12:23:58.308 UTC rows=27
SAMPLE 12:24:04.931 UTC rows=61
SAMPLE 12:24:11.460 UTC rows=98
SAMPLE 12:24:20.143 UTC rows=132
SAMPLE 12:24:26.650 UTC rows=173
SAMPLE 12:24:37.580 UTC rows=206
SAMPLE 12:24:46.320 UTC rows=257
SAMPLE 12:24:52.866 UTC rows=294
SAMPLE 12:24:59.356 UTC rows=300
```

**Consumer log.**

```
INFO consumer: Consuming order_events (batch: 500 records or 5.0 s). Ctrl+C to stop.
INFO consumer.snowflake_loader: Table ORDER_EVENTS currently has 14 columns.
INFO consumer: Batch order_events_p0-2_o0-13_ce2ad9b2.json: 27 records -> LOADED, loaded 27, rejected 0, 1.62 s
INFO consumer: Batch order_events_p0-2_o6-27_a0e2f5a6.json: 34 records -> LOADED, loaded 34, rejected 0, 2.36 s
INFO consumer: Batch order_events_p0-2_o15-43_6510b593.json: 37 records -> LOADED, loaded 37, rejected 0, 1.70 s
INFO consumer.snowflake_loader: Schema evolution: Snowflake added column PAYMENT_METHOD VARCHAR(16777216) to ORDER_EVENTS.
INFO consumer: Batch order_events_p0-2_o27-54_47ffbeee.json: 34 records -> LOADED, loaded 34, rejected 0, 2.38 s, new columns: ['PAYMENT_METHOD']
INFO consumer: Batch order_events_p0-2_o38-66_18899623.json: 41 records -> LOADED, loaded 41, rejected 0, 1.56 s
INFO consumer.snowflake_loader: Schema evolution: Snowflake added column LOYALTY_TIER VARCHAR(16777216) to ORDER_EVENTS.
INFO consumer.snowflake_loader: Schema evolution: Snowflake added column IS_GIFT BOOLEAN to ORDER_EVENTS.
INFO consumer.snowflake_loader: Schema evolution: Snowflake added column SHIPPING_ADDRESS VARIANT to ORDER_EVENTS.
INFO consumer: Batch order_events_p0-2_o52-78_d5f98bc8.json: 33 records -> LOADED, loaded 33, rejected 0, 3.84 s, new columns: ['LOYALTY_TIER', 'IS_GIFT', 'SHIPPING_ADDRESS']
INFO consumer: Batch order_events_p0-2_o62-90_b7e7365e.json: 51 records -> LOADED, loaded 51, rejected 0, 2.33 s
INFO consumer: Batch order_events_p0-2_o82-100_b42ff0cb.json: 37 records -> LOADED, loaded 37, rejected 0, 1.53 s
INFO consumer: Batch order_events_p0-1_o100-103_9e56280f.json: 6 records -> LOADED, loaded 6, rejected 0, 1.50 s
```

**Schema evolution on the production table.** The table grew from 14 to 18 columns. `DESCRIBE TABLE` marks exactly these four as added by schema evolution, and `SCHEMA_EVOLUTION_LOG` has one row for each (4 rows):

| Column | Type Snowflake inferred | First seen at (partition, offset) | Batch file |
|---|---|---|---|
| `PAYMENT_METHOD` | `VARCHAR(16777216)` | 1, 27 | `order_events_p0-2_o27-54_47ffbeee.json` |
| `LOYALTY_TIER` | `VARCHAR(16777216)` | 0, 77 | `order_events_p0-2_o52-78_d5f98bc8.json` |
| `IS_GIFT` | `BOOLEAN` | 0, 77 | `order_events_p0-2_o52-78_d5f98bc8.json` |
| `SHIPPING_ADDRESS` | `VARIANT` | 0, 77 | `order_events_p0-2_o52-78_d5f98bc8.json` |

**Earlier rows were retained, with `NULL` in the columns added later.** Number of rows with a value in each column, by the schema version that produced the row:

| Version | Rows | `EVENT_ID` | `QUANTITY` | `DISCOUNT_PCT` | `PAYMENT_METHOD` | `LOYALTY_TIER` | `IS_GIFT` | `SHIPPING_ADDRESS` | `SHIPPING_ADDRESS:city` |
|---|---|---|---|---|---|---|---|---|---|
| v1 | 100 | 100 | 100 | 0 | 0 | 0 | 0 | 0 | 0 |
| v2 | 100 | 100 | 100 | 100 | 100 | 0 | 0 | 0 | 0 |
| v3 | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |

**`DISCOUNT_PCT`.** Still `NUMBER(5,2)` after the run and **not** schema-evolved: `DESCRIBE TABLE` shows no schema evolution record for it and `SCHEMA_EVOLUTION_LOG` has no row for it. The stored values are exactly the six the producer sends:

| `DISCOUNT_PCT` | Rows |
|---|---|
| 0.00 | 27 |
| 5.00 | 31 |
| 7.50 | 36 |
| 10.00 | 41 |
| 12.50 | 41 |
| 15.00 | 24 |
| `NULL` (v1 rows) | 100 |

**`ORDER_EVENTS_LATEST`.** Queried after the four columns were added: 300 rows, 300 distinct Kafka messages, `DISCOUNT_PCT` filled on 200 rows.

**Audit results (`INGEST_BATCH_LOG` for `ORDER_EVENTS`).** 9 rows, one per `COPY`: 300 records, 300 parsed, 300 loaded, 0 errors. `PUT` + `COPY` took 2.09 s on average and 3.84 s at most (the batch in which Snowflake added three columns).

**`sql/02_validate.sql` output (shortened).**

```
query 1  TOTAL_ROWS=300 | DISTINCT_MESSAGES=300 | BATCHES_LOADED=9 | ROWS_REJECTED=0 | COLUMNS_ADDED=4
query 5  (no rows)                                   -- duplicates
query 6  partition 0: offsets 0-103, loaded 104, not loaded 0
         partition 1: offsets 0-102, loaded 103, not loaded 0
         partition 2: offsets 0-92,  loaded 93,  not loaded 0
query 8  ROWS_IN_DEDUP_VIEW=300
```

**Kafka offsets committed by the consumer** (104 + 103 + 93 = 300, lag 0):

```
GROUP            TOPIC           PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
snowflake-loader order_events    0          104             104             0
snowflake-loader order_events    1          103             103             0
snowflake-loader order_events    2          93              93              0
```

**Latency: produce → queryable in Snowflake.** Measured for all 300 messages as the time from the message's Kafka timestamp to the first polling query in which the row was visible, both on the local clock:

| Minimum | Average | 95th percentile | Maximum | Messages over 15 s |
|---|---|---|---|---|
| 1.58 s | 7.05 s | 11.70 s | 14.17 s | 0 |

**All 300 messages were observed within the acceptance target of about 15 s.** A second measurement, Kafka timestamp to the time the batch was logged after its `COPY` (Snowflake clock), gave an average of 5.53 s and a maximum of 12.15 s.

Notes on these figures:

- The polling method can overstate each value by the gap between two samples.
- The second method compares the local clock with Snowflake's clock and therefore includes any difference between them.
- Query 7 of `sql/02_validate.sql` reported 0.67 s on average and 5.50 s at most. That query measures Kafka → consumer pickup only, not the time until the row is queryable, so it is not the latency figure for the acceptance criterion.
- **Limitation:** the consumer does not poll Kafka while a load and its audit inserts are running. Batches therefore landed every 7–9 s rather than every 5 s, and the margin to the 15 s target is relatively thin (14.17 s at worst).

**Warehouse.** `KAFKA_STREAMING_WH` was `SUSPENDED` before the run and resumed automatically on the first load. After the producer had finished, the consumer was left running idle. The last query ran at about 12:25:20 UTC; the state was then read with a metadata-only command that does not use the warehouse:

```
WAREHOUSE 12:25:35 UTC +    0s state=STARTED running=0 queued=0
WAREHOUSE 12:25:50 UTC +   16s state=STARTED running=0 queued=0
WAREHOUSE 12:26:05 UTC +   31s state=STARTED running=0 queued=0
WAREHOUSE 12:26:20 UTC +   46s state=STARTED running=0 queued=0
WAREHOUSE 12:26:35 UTC +   61s state=SUSPENDED running=0 queued=0
```

It suspended approximately 75 seconds after the last query, while the consumer process was still running.

**Not exercised in the production demo** (each is covered elsewhere, as noted in section 8): a malformed message, a type-conflict row, a consumer restart, and `--extra-field`.

**State left after the demo.** `ORDER_EVENTS` holds the 300 demo rows. The audit tables hold this run's rows plus the rows of the earlier end-to-end run. The Kafka broker is running. The consumer was stopped after the verification was complete; it was idle with nothing buffered and all offsets committed.

---

## 8. Acceptance criteria and evidence

Numbers refer to spec.md section 17. A criterion without evidence is "not verified", not passed. "Production demo" means the run against `ORDER_EVENTS` in section 7.7; "end-to-end test" means `tests/test_e2e.py` on the dedicated table `ORDER_EVENTS_E2E` in section 7.6.

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Row count rises with no manual action | **VERIFIED** (production demo) | Section 7.7: row count sampled 0 → 300 while the producer ran |
| 2 | Message queryable within about 15 s | **VERIFIED** (production demo) | Section 7.7: all 300 messages within the target; average 7.05 s, 95th percentile 11.70 s, maximum 14.17 s. Thin margin |
| 3 | New field → new column, no consumer change, no manual SQL | **VERIFIED** (production demo) | Section 7.7: `PAYMENT_METHOD`, `LOYALTY_TIER`, `IS_GIFT`, `SHIPPING_ADDRESS` added by Snowflake; 14 → 18 columns |
| 4 | Earlier rows remain, `NULL` in the new column | **VERIFIED** (production demo) | Section 7.7: rows-by-version table |
| 5 | Queries on original columns unaffected | **VERIFIED** (production demo) | Section 7.7: original columns filled on all 300 rows; `ORDER_EVENTS_LATEST` returns 300 rows after evolution |
| 6 | Each added column has a `SCHEMA_EVOLUTION_LOG` row | **VERIFIED** (production demo) | Section 7.7: 4 of 4 |
| 7 | Malformed message → dead-letter topic, pipeline continues | **VERIFIED in the end-to-end test.** Not exercised in the production demo: no malformed message was sent | Section 7.6; `test_e2e.py::test_5` |
| 8 | Consumer restart loses nothing; no duplicates | **No duplicates: VERIFIED** (production demo). **Restart: VERIFIED in the end-to-end test**, not exercised in the production demo | Section 7.7: 300 rows, 300 distinct messages. Section 7.6; `test_e2e.py::test_6` |
| 9 | Warehouse suspends when the producer stops | **VERIFIED** (production demo) | Section 7.7: `SUSPENDED` about 75 s after the last query, with the consumer still running idle |
| 10 | Every file has a header comment, every function a docstring | Met by inspection | All files in `config/`, `producer/`, `consumer/`, `scripts/`, `sql/`, `tests/` |
| 11 | Type-conflict row rejected, valid rows load, pipeline keeps running | **VERIFIED in the end-to-end test and by unit tests.** Not exercised in the production demo: no such row was sent | Section 7.6; `test_e2e.py::test_4`; `tests/test_consumer_commit.py` |

---

## 9. Steps remaining

The build, the verification gate, the end-to-end test and the production demo are complete. The evidence in this README is command and query output captured from the real environment.

What is still open: two failure paths are covered by unit tests only and have not been exercised against the real account, namely a retry after a Snowflake failure and a part failing midway through a split batch.

---

## 10. Cost notes

- The warehouse is X-Small with 60 s auto-suspend. With no Kafka messages the consumer sends no queries, so the warehouse suspends.
- While data flows, a load every few seconds keeps the warehouse running. Use `--count` on the producer for a bounded run.
- `PUT`, `REMOVE` and `DESCRIBE TABLE` need no running warehouse.
- This project creates no AWS resources.

---

## 11. PostgreSQL source database (enhancement)

> **Status (2026-10-06): source database created and loaded. CDC from this table is live (section 12).**
> The existing Kafka → consumer → Snowflake pipeline is unchanged by this step.

### Why

Until now the order events were born in the Python producer. The enhancement gives them a proper home: a PostgreSQL table that is the source of the pipeline. Change data capture (CDC) between PostgreSQL and Kafka was added in a second step (section 12); everything from Kafka onwards is reused as it is.

```
PostgreSQL source DB        kafka_source_db.order_events        <- done in this step
        |
        v
      CDC                    Debezium + CDC bridge               <- added afterwards (section 12)
        |
        v
      Kafka                  topic of order events               <- existing
        |
        v
Existing Python consumer     micro-batch, PUT, COPY INTO         <- existing, unchanged
        |
        v
    Snowflake                ORDER_EVENTS (schema evolution)     <- existing, unchanged
```

### What was added

| Path | Purpose |
|---|---|
| `source_db/postgres.py` | Connection and inspection helpers; the only place that opens PostgreSQL connections |
| `source_db/setup_database.py` | Creates the database (if missing) and the table |
| `source_db/backfill_from_snowflake.py` | One-time copy of the existing events from Snowflake into PostgreSQL |
| `sql/postgres/01_create_source_table.sql` | Definition of the source table `order_events` |
| `tests/test_source_db_mapping.py` | Unit tests: row mapping, settings, table definition (no database needed) |
| `tests/test_source_db_live.py` | Live, read-only verification against the real server |

Changed, additively: `config/settings.py` (PostgreSQL settings), `.env.example` (the new keys), `requirements.txt` (`psycopg[binary]`). No file of the producer, the consumer or the Snowflake SQL was modified.

### Credentials

The PostgreSQL password is **not** in the source code. `config/settings.py` reads `POSTGRES_PASSWORD` from the environment or from the git-ignored `.env` file and has no default for it. `.env.example` lists the keys with the password left empty:

```
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_USER=postgres
POSTGRES_PASSWORD=
POSTGRES_DATABASE=kafka_source_db
```

### The source table

Database `kafka_source_db`, table `order_events`. Only this database was created; no existing database on the server was used or changed.

| Column | Type | Notes |
|---|---|---|
| `event_id` | `UUID` | **Primary key.** Same value as `EVENT_ID` in Snowflake and `event_id` in the Kafka message |
| `event_time` | `TIMESTAMPTZ` | Not null |
| `order_id` | `VARCHAR(50)` | Not null; not unique (one order has several events) |
| `customer_id` | `INTEGER` | Not null |
| `product` | `VARCHAR(200)` | Not null |
| `quantity` | `INTEGER` | Not null, greater than 0 |
| `unit_price` | `NUMERIC(12,2)` | Not null; same precision as Snowflake |
| `status` | `VARCHAR(30)` | Not null |
| `payment_method` | `VARCHAR(30)` | Schema version 2 field; null on earlier events |
| `discount_pct` | `NUMERIC(5,2)` | Schema version 2 field; same type as Snowflake |
| `loyalty_tier` | `VARCHAR(30)` | Schema version 3 field |
| `is_gift` | `BOOLEAN` | Schema version 3 field |
| `shipping_address` | `JSONB` | Schema version 3 field (nested object) |
| `record_source` | `VARCHAR(30)` | `project3_backfill` for the copied rows, `application` (default) for rows created later |
| `source_kafka_topic`, `source_kafka_partition`, `source_kafka_offset`, `source_kafka_timestamp` | | Original Kafka position of a copied row; null for rows created later. Unique together |
| `created_at`, `updated_at` | `TIMESTAMPTZ` | Bookkeeping |

### Setup and load

```powershell
pip install -r requirements.txt                 # installs the PostgreSQL driver
# put POSTGRES_PASSWORD (and other values, if different) into .env
python -m source_db.setup_database              # creates kafka_source_db and order_events
python -m source_db.backfill_from_snowflake     # copies the existing events, once
```

**Where the 300 records came from.** They existed in the local Kafka topic and in Snowflake `ORDER_EVENTS`. The backfill reads them from Snowflake, the verified end result of the pipeline, so PostgreSQL matches Snowflake row for row. It only reads from Snowflake and only writes to PostgreSQL; nothing is sent to Kafka or inserted into Snowflake, so no duplicate can appear in `ORDER_EVENTS`.

**Loaded only once.** A second run stops before writing when the rows are already there; every insert also uses `ON CONFLICT (event_id) DO NOTHING`; and the load is a single transaction.

### Evidence (2026-10-06)

```
INFO source_db.setup_database: Connected to PostgreSQL at localhost:5432 as postgres (PostgreSQL 17.9 on x86_64-windows).
INFO source_db.setup_database: Created database kafka_source_db.
INFO source_db.setup_database: Table order_events is ready: 20 columns, 0 rows.

INFO source_db.backfill_from_snowflake: Snowflake ORDER_EVENTS holds 300 order events.
INFO source_db.backfill_from_snowflake: Inserted 300 rows into PostgreSQL kafka_source_db.order_events.
INFO source_db.backfill_from_snowflake: PostgreSQL now: 300 rows (300 backfilled), 300 distinct event ids, 0 duplicate event ids, 0 duplicate Kafka keys.
INFO source_db.backfill_from_snowflake: Verified: PostgreSQL backfilled rows = Snowflake rows = 300.
```

Second run of the backfill:

```
INFO source_db.backfill_from_snowflake: PostgreSQL already holds 300 backfilled rows; nothing to load. The backfill runs only once.
```

State after the load:

| System | Rows |
|---|---|
| PostgreSQL `kafka_source_db.order_events` | 300 |
| Snowflake `ORDER_EVENTS` | 300 (unchanged) |
| Kafka topic `order_events` | 300 messages (unchanged) |

These are the counts right after the backfill. With CDC live, both sides have grown since (section 12).

### Verification

```powershell
python -m pytest tests -q                                   # unit tests; live tests are skipped

$env:PG_SOURCE_LIVE = "1"                                   # read-only checks on the real server
$env:PG_SOURCE_COMPARE_SNOWFLAKE = "1"                      # optional: also compare with Snowflake
python -m pytest tests/test_source_db_live.py -v
```

Result on 2026-10-06: unit suite **136 passed** (17 live tests skipped); live verification **11 passed**:

| Check | Result |
|---|---|
| PostgreSQL connectivity with the configured login | Passed |
| Database `kafka_source_db` exists | Passed |
| Table `order_events` exists with the expected columns | Passed |
| `event_id` is the primary key | Passed |
| Backfilled record count = 300 | Passed |
| No duplicate event ids | Passed (0) |
| No duplicate Kafka messages (topic, partition, offset) | Passed (0) |
| 100 v1, 100 v2 and 100 v3 rows, as in Snowflake | Passed |
| Every backfilled row equals its Snowflake row, field by field | Passed (300 of 300) |

### What CDC had to take into account

These points were identified when the source table was created. Section 12 describes how each was handled.

| Point | How it was handled |
|---|---|
| The 300 copied rows are already in Snowflake; publishing them again would duplicate them | Four protection layers: no snapshot, a filtered publication, the bridge, and a gate |
| PostgreSQL ran with `wal_level = replica` | Changed to `logical`, with a restart of the PostgreSQL service |
| CDC messages have a different shape from the producer's messages | The CDC bridge converts them into the existing format |
| The source table has columns Snowflake does not (`record_source`, `source_kafka_*`, `created_at`, `updated_at`) | The bridge removes them |
| Updates and deletes have no defined meaning in the append-only Snowflake table | Version 1 captures INSERTs only |

---

## 12. Change data capture from PostgreSQL (live)

> **Status (2026-10-06): LIVE and verified end to end.** A row inserted into PostgreSQL reaches Snowflake with no manual step. Version 1 captures **INSERTs only**; updates and deletes are deliberately not propagated.

### Architecture

```
PostgreSQL 17 (local Windows)     kafka_source_db.order_events
   |  logical replication (pgoutput), publication = INSERTs of non-backfill rows only
   v
Debezium 3.7.0 on Kafka Connect   standalone mode, local, one Java process
   |  raw change events
   v
Kafka CDC topic                   pgcdc.public.order_events        (local Kafka 4.3.1)
   v
Python CDC bridge                 python -m cdc.bridge             (local)
   |  messages in the existing producer format
   v
Existing Kafka topic              order_events                     (local Kafka 4.3.1)
   v
Existing Python consumer          python -m consumer.consumer      (local, unchanged)
   v
Snowflake                         ORDER_EVENTS                     (cloud, unchanged)
```

**Where each part runs.**

| Component | Location |
|---|---|
| PostgreSQL 17.9 | Local Windows service `postgresql-x64-17` |
| Kafka 4.3.1 broker (KRaft) | Local, `C:\kafka` |
| Kafka Connect + Debezium PostgreSQL connector 3.7.0.Final | Local, standalone mode, plugin in `C:\kafka\connect-plugins` |
| CDC bridge | Local Python process |
| Existing consumer | Local Python process |
| Snowflake (`ORDER_EVENTS`, warehouse `KAFKA_STREAMING_WH`) | Cloud |

No Docker and no AWS resource is used. `consumer/`, `producer/`, the Snowflake loader and the table `ORDER_EVENTS` are not modified by this enhancement.

### CDC configuration

| Setting | Value | Purpose |
|---|---|---|
| PostgreSQL `wal_level` | `logical` | Lets PostgreSQL's log be decoded into row changes. Server-wide; needed a service restart |
| PostgreSQL `max_slot_wal_keep_size` | `2GB` | Upper limit on the log PostgreSQL keeps for an unread replication slot |
| Login | `cdc_user` | Dedicated login with `REPLICATION` and `SELECT` on the one table; not a superuser |
| Publication | `order_events_cdc_pub` | `FOR TABLE public.order_events WHERE (record_source <> 'project3_backfill') WITH (publish = 'insert')` |
| What the publication releases | INSERTs only | Updates, deletes and truncates never leave PostgreSQL |
| Row filter | `record_source <> 'project3_backfill'` | The 300 copied rows never leave PostgreSQL |
| Replication slot | `order_events_cdc_slot` (`pgoutput`) | PostgreSQL's record of how far Debezium has read; created by Debezium |
| CDC topic | `pgcdc.public.order_events` | Raw Debezium change events; 1 partition; no automatic deletion |
| Heartbeat topic | `__debezium-heartbeat.pgcdc` | One small message every 5 minutes so the slot keeps advancing on a quiet table |
| Debezium `snapshot.mode` | `no_data` | No initial snapshot: rows that existed before CDC started are not read |
| Debezium `publication.autocreate.mode` | `disabled` | Debezium must use the hand-made publication and may not create or alter one |
| Debezium `skipped.operations` | `u,d,t` | A second guard against updates, deletes and truncates |
| Debezium `decimal.handling.mode` | `double` | `NUMERIC` arrives as a JSON number, as the producer sends it |
| Bridge consumer group | `cdc-bridge` | The bridge's position in the CDC topic |
| Bridge `max.poll.interval.ms` | `600000` (10 minutes) | How long the bridge may go without polling before Kafka removes it from its group. Kafka's default is 5 minutes |
| Bridge `max.poll.records` | `100` | Upper limit on the records one poll hands over; equal to one checkpoint batch |

Files: `cdc/debezium-postgres.properties`, `cdc/connect-standalone.properties`, `sql/postgres/02_cdc_setup.sql`.

**Credentials.** No password is in any committed file. The connector file refers to `${env:POSTGRES_CDC_USER}` and `${env:POSTGRES_CDC_PASSWORD}`; `scripts/start_connect.ps1` reads them from the environment or from the git-ignored `.env`. The setup SQL receives the password as a `psql` variable.

### What flows and what does not

**Version 1 is INSERT-only.** `ORDER_EVENTS` is an append-only event table, so an update or delete has no defined meaning there yet. **A row that is later updated or deleted in PostgreSQL is not changed in Snowflake.** This is a deliberate limitation, not an omission.

The 300 rows copied from the Project 3 demo were already in Snowflake. Four independent layers keep them from being published again:

| Layer | Where | What it does | Verified |
|---|---|---|---|
| 1 | Debezium `snapshot.mode=no_data` | No initial snapshot | Live: after Debezium's first start the CDC topic was empty |
| 2 | PostgreSQL publication | Row filter and insert-only | Live: a row inserted with `record_source = 'project3_backfill'` produced no message |
| 3 | CDC bridge | Forwards only operation `c`; drops snapshot reads, updates, deletes and backfill-marked rows | Unit tests (300 backfill events in, 0 forwarded) |
| 4 | Gate before the bridge starts | CDC topic holds no snapshot read and no backfill row | Live: `test_enabled_cdc_topic_contains_no_snapshot_of_existing_rows` |

### Transformation into the existing message format

Done by `cdc/transform.py`, a pure module with no Kafka or database access.

| Outgoing field | From the Debezium `after` image | Conversion |
|---|---|---|
| `event_id` | `event_id` | Validated as a UUID; canonical lower-case text |
| `event_time` | `event_time` | ISO-8601 with microseconds and any zone → UTC, milliseconds, trailing `Z` (the producer's format) |
| `order_id`, `product`, `status`, `payment_method`, `loyalty_tier` | same names | Unchanged |
| `customer_id`, `quantity` | same names | Must be whole numbers |
| `unit_price`, `discount_pct` | same names | JSON numbers; numeric text is accepted too |
| `is_gift` | `is_gift` | Unchanged (`false` is kept; only null is omitted) |
| `shipping_address` | `shipping_address` | Debezium sends JSONB as JSON text; parsed into a nested object |
| message key | `order_id` | Same key as the producer |

- **Removed:** `record_source`, `source_kafka_topic`, `source_kafka_partition`, `source_kafka_offset`, `source_kafka_timestamp`, `created_at`, `updated_at`. These PostgreSQL bookkeeping columns never become Snowflake columns.
- **Null columns are omitted**, as the producer omits fields a schema version does not have.
- **Any other column is forwarded unchanged**, so a genuinely new business column added to PostgreSQL later reaches Snowflake and becomes a new column there through schema evolution.
- **A message that cannot be converted** is copied to the existing dead-letter topic `order_events_dlq` with the reason; the bridge continues.

A real change event as Debezium wrote it (shortened), and what the bridge sent on:

```
CDC topic:    {"before":null,"after":{"event_id":"569a105f-9418-4099-bb45-d879bd7448a7","event_time":"2026-10-06T15:40:14.355000Z",
               "order_id":"ORD-100976","customer_id":312,"product":"Noise Cancelling Headphones","quantity":4,"unit_price":8999.0,
               "status":"PAID","payment_method":"NET_BANKING","discount_pct":15.0,"loyalty_tier":"PLATINUM","is_gift":false,
               "shipping_address":"{\"city\": \"Pune\", \"state\": \"Maharashtra\", \"pincode\": \"411001\"}",
               "record_source":"application","source_kafka_topic":null, ... ,"created_at":"2026-10-06T15:40:14.485955Z", ...},
               "source":{"version":"3.7.0.Final","connector":"postgresql","snapshot":"false","table":"order_events", ...},"op":"c", ...}

Snowflake:    EVENT_ID 569a105f-..., ORDER_ID ORD-100976, QUANTITY 4, UNIT_PRICE 8999.00, DISCOUNT_PCT 15.00,
              PAYMENT_METHOD NET_BANKING, LOYALTY_TIER PLATINUM, IS_GIFT FALSE, SHIPPING_ADDRESS (OBJECT) city = Pune
```

### Delivery and checkpoints

The whole chain is at-least-once.

| Stage | Where the position is kept | Committed when |
|---|---|---|
| PostgreSQL → Debezium | Replication slot `order_events_cdc_slot` | After Kafka Connect has saved its offsets |
| Debezium → CDC topic | Kafka Connect offsets file (local disk) | Every 10 s |
| CDC topic → bridge | Consumer group `cdc-bridge` | After the forwarded message and any dead letter are confirmed by Kafka |
| `order_events` → consumer | Consumer group `snowflake-loader` (existing) | After `COPY` succeeds (existing behaviour) |

A restart of Debezium or of the bridge can send an event a second time. The repeat is a new Kafka message with a new offset, so `ORDER_EVENTS_LATEST` (one row per Kafka message) does not recognise it. The view **`ORDER_EVENTS_UNIQUE`** keeps one row per `EVENT_ID` and does. No repeat has occurred so far: both views and the table hold the same number of rows.

### End-to-end proof (2026-10-06)

| Step | PostgreSQL | CDC topic | `order_events` topic | Snowflake `ORDER_EVENTS` |
|---|---|---|---|---|
| Baseline, after Debezium's first start | 300 | 0 messages | 300 | 300 |
| One row inserted in PostgreSQL (first live run) | 301 | 1 | 301 | 301 |
| One more row inserted (final verification run) | 302 | 2 | 302 | 302 |

The two rows that travelled through CDC, as stored in Snowflake:

| `EVENT_ID` | Order | Qty | Unit price | Discount | Address city | Copies in Snowflake | Kafka position |
|---|---|---|---|---|---|---|---|
| `569a105f-9418-4099-bb45-d879bd7448a7` | `ORD-100976` | 4 | 8999.00 | 15.00 | Pune | 1 | `order_events` partition 1, offset 103 |
| `f8ff4fef-5643-46e5-b8dd-cc66dd369097` | `ORD-103601` | 1 | 6499.00 | 0.00 | Pune | 1 | `order_events` partition 1, offset 104 |

State after the final run:

| Check | Result |
|---|---|
| PostgreSQL `order_events` | 302 rows: 300 `project3_backfill`, 2 `application`; 0 duplicate event ids |
| Snowflake `ORDER_EVENTS` | 302 rows, 302 distinct `EVENT_ID`, 302 distinct Kafka messages |
| `ORDER_EVENTS_LATEST` / `ORDER_EVENTS_UNIQUE` | 302 / 302 |
| The original 300 rows in Snowflake | Still 300, 300 distinct ids; all 300 backfilled PostgreSQL rows equal their Snowflake rows field by field |
| Columns of `ORDER_EVENTS` | Still 18; no PostgreSQL technical column present; `SCHEMA_EVOLUTION_LOG` still has 4 rows |
| `INGEST_BATCH_LOG` for `ORDER_EVENTS` | 11 `COPY` operations, 302 records, 302 loaded, 0 rejected |
| Bridge position (`cdc-bridge`) | Committed offset 2 of 2 |
| Consumer position (`snowflake-loader`) | Committed 104 / 105 / 93 of 104 / 105 / 93 |
| Dead-letter topic | Empty |
| Connector | `RUNNING`, task `RUNNING`; replication slot active |

### Verification results (2026-10-06)

| Suite | Command | Result |
|---|---|---|
| Whole unit suite | `python -m pytest tests -q` | 286 passed, 35 live skipped |
| Original Project 3 tests | the test files of commit `b3f5847` | 108 passed, 6 live skipped |
| CDC unit tests | `tests/test_cdc_transform.py`, `tests/test_cdc_bridge.py` | 147 passed |
| CDC live gate (read-only) | `$env:CDC_LIVE = "1"` | 9 passed, 9 skipped |
| CDC end to end | `$env:CDC_LIVE = "1"; $env:CDC_LIVE_E2E = "1"` | 10 passed, 8 skipped |
| PostgreSQL source checks | `$env:PG_SOURCE_LIVE = "1"; $env:PG_SOURCE_COMPARE_SNOWFLAKE = "1"` | 11 passed |
| Existing Kafka → Snowflake end to end | `$env:KAFKA_SF_LIVE = "1"` | 6 passed (own topics, own table `ORDER_EVENTS_E2E`) |

The CDC live gate and the CDC end-to-end test were run twice with the same result: once in the first live run and once in the final verification run. Each end-to-end run inserts one row, which is why there are two CDC rows.

**What was checked, and how.**

| Behaviour | How it was verified | Result |
|---|---|---|
| INSERT is captured and reaches Snowflake | Live, two inserts | Each present exactly once, with the inserted values |
| UPDATE is not published | Live: `UPDATE` of an `application` row; CDC topic checked 20 s later | No message |
| Backfill-marked INSERT is not published | Live: temporary row inserted with `record_source = 'project3_backfill'` | No message |
| DELETE is not published | Live: that temporary row deleted again (it was also excluded by the row filter). The publication reports `pubdelete = false`; the bridge's own handling of a delete event is unit-tested | No message |
| No snapshot of the existing 300 rows | Live gate test; the CDC topic contains only the two inserts, both with `"snapshot":"false"` | Passed |
| Technical PostgreSQL columns are not forwarded | Live: `ORDER_EVENTS` still has its 18 columns; unit tests | Passed |
| `shipping_address` JSONB | Live: stored as an `OBJECT`, `SHIPPING_ADDRESS:city` = `Pune` | Passed |
| Numeric fields | Live: `8999.00`, `6499.00`, `15.00` and `0.00` stored exactly | Passed |
| NULL optional fields | Unit tests only: both live rows had every field filled | Passed (unit) |
| New business column stays compatible with schema evolution | Unit tests only: no column was added to the PostgreSQL table | Passed (unit) |
| Invalid CDC payload goes to `order_events_dlq` | Unit tests only: no invalid message was put into the live CDC topic | Passed (unit) |
| Bridge restart | Live: the bridge was started and stopped gracefully twice with nothing pending; nothing was forwarded again and the committed position did not move | Passed |
| Kafka Connect stays healthy | Live: `RUNNING` before and after every step. It was not restarted | Passed |

### An incident in the first live run, and the fix

In the first live run the bridge forwarded its event correctly, and the event reached Snowflake, but the bridge **never committed its position**. The process stayed alive and connected to the broker, yet after five minutes Kafka had removed it from its consumer group, and the group had no committed offset.

- **Most likely cause.** The bridge ran in a Windows console window. A Windows console suspends a program at its next write to the window while text is selected in it ("QuickEdit" mode). The bridge's next write was its own "Forwarded …" log line, which sat between forwarding an event and committing the position. This matches everything observed (a live, idle process; one forwarded message; no commit; no re-forward), but the window itself could not be inspected, so it is an explanation, not a proven fact.
- **Why it mattered.** With no committed position, a restarted bridge would have read the same change event again and sent it to Snowflake a second time.
- **What was done.** The position was recorded by hand (offset 1 for the group `cdc-bridge`), after confirming that the topic held exactly one message and that this message was already in `order_events` and in Snowflake. No duplicate was created.
- **The fix.** The bridge now sends its log output through a queue (`configure_logging` in `cdc/bridge.py`). The main loop only puts the log record into memory and carries on to the commit; a separate thread writes to the console. A regression test (`test_a_blocked_console_does_not_block_the_bridge`) proves a log call returns at once even when the console accepts no output. In the final verification run the bridge committed its position immediately after forwarding.

The existing consumer was not changed. It writes its log lines directly to the console, so a suspended console would pause it as well; it commits before it logs, so nothing would be lost or duplicated, only delayed.

### Follow-up: "maximum poll interval exceeded"

A bridge process that was still running from the first live run (started before the logging fix, so still on the earlier code) later reported:

```
Application maximum poll interval (300000ms) exceeded by 95ms
Checkpoint during rebalance failed
KafkaError{code=UNKNOWN_MEMBER_ID,val=25,str="Commit failed: Broker: Unknown member"}
```

- **Root cause.** Kafka expects a consumer to ask for the next message at least every `max.poll.interval.ms` (default 5 minutes). The bridge's main loop had been held up for longer than that (see the incident above), so Kafka removed it from its consumer group. Its later attempt to commit was then refused, because it was no longer a member. The bridge's own work never takes that long: its slowest loop pass is about two minutes (two flushes of up to 30 s and one retry pause of up to 60 s).
- **Was data lost?** No. The position had not been committed, so the bridge read from its last checkpoint again after rejoining. That process went on to forward later inserts correctly.
- **Change 1: more headroom.** The bridge's consumer now sets `max.poll.interval.ms = 600000` (10 minutes) and `max.poll.records = 100`. Both are settings in `config/settings.py` (`CDC_BRIDGE_MAX_POLL_INTERVAL_MS`, `CDC_BRIDGE_MAX_POLL_RECORDS`).
- **Change 2: a lost partition is handled as what it is.** Kafka tells a consumer separately when its partition was *lost* (it has already been removed) rather than *revoked* (it is about to hand over). The bridge now registers for both. On a normal revoke it still confirms and commits first, as before. On a loss it does not attempt a commit that can only be refused; it logs one clear warning and re-reads from its last checkpoint.
- **What did not change.** Manual commits after confirmed delivery, the consumer group, rebalancing, at-least-once delivery, INSERT-only forwarding and dead-letter handling are all as they were. `consumer/` and `producer/` were not touched.

Verification (2026-10-06):

| Check | Result |
|---|---|
| Unit tests for the settings, the revoke path, the lost path, the refused commit and the error event | 13 new tests; CDC unit tests 147 passed; whole suite 286 passed |
| A consumer with the bridge's real settings stays silent for 320 s (longer than the old limit), in a scratch group | No poll-interval error; still assigned its partition |
| The same consumer with a deliberately short interval, in a scratch group | Kafka reported the exceeded interval, called the *lost* callback (not *revoke*), and the consumer rejoined by itself |
| Live CDC test with a bridge running the new code | 10 passed, 8 skipped. One row inserted in PostgreSQL (`69ab9bd5-0d8f-44e0-86a1-46afbb5e6cfe`) was captured by Debezium (CDC offset 4, operation `c`), forwarded once by the bridge, and is in Snowflake exactly once |
| Poll-interval warnings in that bridge's output | None |
| State afterwards | PostgreSQL 305 rows (300 backfill + 5 application); Snowflake 305 rows, 305 distinct `EVENT_ID`; both views 305; still 18 columns |

Two notes on these settings:

- `max.poll.interval.ms` is a margin, not a cure. A bridge that is held up for longer than 10 minutes is still removed from its group; it then recovers as described above. Raising the limit also means a bridge that is truly stuck is noticed after 10 minutes instead of 5.
- `max.poll.records` is accepted by the Kafka client used here (confluent-kafka 2.15.1). This bridge takes one change event per poll and checkpoints every 100 events, so no effect of the setting was observed; it documents the intended limit. `requirements.txt` now asks for that client version, because an older client may not know the setting.

### Running it

```powershell
.\scripts\start_kafka.ps1 -Background          # Kafka broker
.\scripts\start_connect.ps1 -Background        # Kafka Connect + Debezium
python -m consumer.consumer                    # existing consumer   (terminal 1)
python -m cdc.bridge                           # CDC bridge          (terminal 2)

python -m source_db.insert_order_event         # insert one new order event into PostgreSQL

# Checks
Invoke-RestMethod http://localhost:8083/connectors/order-events-postgres-cdc/status
$env:CDC_LIVE = "1"; python -m pytest tests/test_cdc_live.py -v
```

One-time setup, in order: `ALTER SYSTEM SET wal_level = 'logical'` and a restart of the PostgreSQL service (as Administrator); `POSTGRES_CDC_PASSWORD` in `.env`; `sql/postgres/02_cdc_setup.sql`; `.\scripts\install_debezium.ps1`; `.\scripts\create_topics.ps1 -IncludeCdc`.

### Files of this enhancement

| Path | Purpose |
|---|---|
| `cdc/transform.py` | Debezium change event → existing order-event message (pure) |
| `cdc/bridge.py` | Reads the CDC topic, forwards inserts to `order_events`, checkpoints |
| `cdc/connect-standalone.properties` | Kafka Connect worker configuration (standalone, local offsets file) |
| `cdc/debezium-postgres.properties` | Debezium connector configuration |
| `sql/postgres/02_cdc_setup.sql` | Creates the login and the filtered publication. Stops unless `wal_level = logical` |
| `sql/postgres/99_cdc_teardown.sql` | Rollback: drops slot, publication and login; keeps the table and its data |
| `scripts/install_debezium.ps1` | Downloads, verifies and unpacks the Debezium plugin |
| `scripts/start_connect.ps1`, `scripts/stop_connect.ps1` | Start and stop Kafka Connect; the broker is not touched |
| `source_db/insert_order_event.py` | Inserts new order events into PostgreSQL |
| `tests/test_cdc_transform.py`, `tests/test_cdc_bridge.py` | Unit tests |
| `tests/test_cdc_live.py` | Live checks: preflight, enabled state, end to end (all skipped by default) |

Changed, additively: `config/settings.py`, `.env.example`, `scripts/create_topics.ps1` (`-IncludeCdc` switch), `sql/01_create_objects.sql` (the view `ORDER_EVENTS_UNIQUE`).

### Limitations

| Limitation | Detail |
|---|---|
| **INSERT-only (version 1)** | Only new rows are captured |
| **UPDATE and DELETE are intentionally excluded** | A row updated or deleted in PostgreSQL is not changed in Snowflake. Supporting them needs a design for the append-only Snowflake table first |
| **Debezium / Kafka Connect must be running for CDC** | While Kafka Connect is stopped nothing flows. Rows inserted meanwhile are not lost: PostgreSQL keeps them for the replication slot and they are delivered when Connect starts again. The bridge and the consumer must run as well for rows to reach Snowflake |
| **Replication slot and PostgreSQL's log** | A slot nobody reads makes PostgreSQL keep its log files, for the whole server. `max_slot_wal_keep_size = 2GB` limits this; if Connect stays down long enough to exceed it, the slot is invalidated and the changes in that window must be reconciled by hand. If CDC is to stay off, remove the slot with `sql/postgres/99_cdc_teardown.sql` |
| **`wal_level = logical` is server-wide** | It applies to every database on this PostgreSQL server and slightly increases log volume |
| **At-least-once delivery** | A restart of Debezium or the bridge can send an event twice. `ORDER_EVENTS_UNIQUE` removes such repeats; `ORDER_EVENTS` itself would hold both copies |
| **A bridge held up for more than 10 minutes** | Kafka removes it from its consumer group (`max.poll.interval.ms`). It rejoins by itself and re-reads from its last checkpoint; an event forwarded but not yet committed is then sent a second time |
| **Console output can pause the existing consumer** | See the incident above. The bridge is protected; the consumer was deliberately left unchanged |
| **Windows: do not delete Kafka topics** | Topic deletion crashes this broker (section 7.1). No script of this enhancement deletes a topic, and the CDC topics are created without automatic deletion |
| **New JSONB, date or time columns** | A column of one of these types added to PostgreSQL later needs an entry in `cdc/transform.py`; other new columns are forwarded as they are |
| **Numeric sizing in Snowflake** | A new numeric column still gets a Snowflake column sized to its first values (section 5) |
| **Not exercised live** | A Kafka Connect restart; an invalid message in the CDC topic; a row with NULL optional fields; a new PostgreSQL column; a failed checkpoint and its retry. Each is covered by unit tests, except the Kafka Connect restart |
| **Kafka's `connect-plugin-path.bat` fails on Windows** | The offline plugin-listing tool stops with a path error. Kafka Connect itself runs correctly; only that tool is affected |

### Rollback

1. Stop the bridge (Ctrl+C) and Kafka Connect (`.\scripts\stop_connect.ps1`). The existing pipeline keeps working as before.
2. Run `sql/postgres/99_cdc_teardown.sql` to drop the replication slot, the publication and the login.
3. Optionally `ALTER SYSTEM RESET wal_level;` and restart PostgreSQL. Leaving it at `logical` is harmless.
4. Leave the Kafka topics in place.
5. Remove `C:\kafka\connect-plugins` and `C:\kafka\connect-data`.

---

## 13. Starting and stopping the whole pipeline

Two scripts replace the separate terminals and commands of section 12.

```powershell
.\scripts\start_pipeline.ps1               # start everything that is not running yet
.\scripts\stop_pipeline.ps1                # stop everything, in an orderly way
.\scripts\stop_pipeline.ps1 -KeepBroker    # stop the three services, leave the Kafka broker running
```

They only orchestrate processes. No pipeline logic, configuration, topic, consumer group or SQL was changed for them; `consumer/`, `producer/` and `cdc/` are untouched.

### What is managed

| Service | Started with (unchanged, existing command) | Runs as | Log in `C:\kafka\run-logs` |
|---|---|---|---|
| Kafka broker | `scripts\start_kafka.ps1 -Background` | hidden Java process | `broker.out.log` |
| Kafka Connect + Debezium | `scripts\start_connect.ps1 -Background` | hidden Java process | `connect.out.log` |
| Snowflake consumer | `python -m consumer.consumer` | hidden Python process | `consumer.log` |
| CDC bridge | `python -m cdc.bridge` | hidden Python process | `cdc-bridge.log` |

`pipeline.log` in the same folder records what the two scripts did. When a service is started again, its previous log is kept as `<name>.log.previous`. The folder is outside the repository, so runtime files cannot be committed.

**Not managed, on purpose.**

- **The producer.** It generates demo data and is only ever run by hand.
- **PostgreSQL.** It runs as a Windows service. The scripts only look whether it answers and show that in the summary; they never start, stop or reconfigure it.

### Starting

Order: Kafka broker → (missing topics, if any) → Kafka Connect → consumer → CDC bridge. Each step is skipped if the service is already running.

```
Kafka Broker       : RUNNING (started)
Kafka Connect      : RUNNING (started)
Snowflake Consumer : RUNNING (started)
CDC Bridge         : RUNNING (started)
PostgreSQL         : RUNNING (not managed by this script)

Pipeline Status: READY
```

If a service does not come up, the summary says `Pipeline Status: NOT READY`, names the service and gives the path of its log; the script ends with exit code 1.

**No duplicates.** Before starting a service the script checks, in this order:

1. Is one of this project's processes already running it? A process counts as ours only if its command line names the service (`kafka.Kafka`, `ConnectStandalone`, `-m cdc.bridge`, `-m consumer.consumer`) or its process id is the one recorded in the PID file written at start.
2. For the two Python services: does Kafka report a connected member in the service's consumer group? This catches a service that runs but cannot be seen from the current session, for example one started from an Administrator window.

Running `start_pipeline.ps1` a second time therefore starts nothing and reports `RUNNING (already running)`.

**Topics.** If one of the required topics is missing (for example on a freshly reset broker), the existing `create_topics.ps1 -IncludeCdc` is run. Existing topics are never altered or deleted.

### Stopping

Order: CDC bridge → consumer → Kafka Connect → Kafka broker, the reverse of starting.

Each service is first **asked** to shut down, the way Ctrl+C would, and given time to do it: the consumer finishes and commits its batch, the bridge commits its position, Kafka Connect saves how far Debezium has read, the broker closes its files cleanly. Only a service that has not exited after that is ended, by its own process id. Nothing is lost in that case either: every service repeats its last uncommitted piece of work after the next start.

- Windows has no signal one process can send another. `scripts/request_graceful_stop.py` therefore attaches to the hidden console of the target and generates the key event there, so only that service receives it.
- The Python services are sent Ctrl+Break, which both handle exactly like Ctrl+C and which a shell cannot switch off. The Java services are sent Ctrl+C, because on Ctrl+Break a Java program only prints a thread dump.
- A service that is already stopped counts as success.
- The broker is left running if a service that uses it could not be stopped, and with `-KeepBroker`.

**Never done by these scripts:** stopping a process by image name (`taskkill /IM java.exe` and the like), stopping PostgreSQL, deleting a topic, Kafka data, a consumer group, Debezium's offsets or the replication slot, or running the CDC teardown.

### Requirements

- `POSTGRES_CDC_PASSWORD` must be in `.env`, because `start_connect.ps1` reads the CDC login from there. Without it Kafka Connect is reported as `FAILED` with that reason.
- Run both scripts from the same kind of session. A service started from an Administrator window cannot be stopped from a normal one; `stop_pipeline.ps1` then reports it as `STILL RUNNING (started from another session …)` and leaves it alone.
- `python` must resolve to the interpreter that has the project's packages installed.

### Verification (2026-10-06)

| Check | Result |
|---|---|
| Orchestration tests (`tests/test_pipeline_scripts.py`) | 69 passed: the safety rules, the helper, and a real orderly stop of a hidden background process |
| `start_pipeline.ps1` while all four services were already running | Reported all four as running, `Pipeline Status: READY`; **0 new processes** were created |
| The same, for the two Python services that were running in an Administrator session | Recognised through their consumer groups; not started a second time |
| `stop_pipeline.ps1` against services owned by an Administrator session | Stopped nothing it could not identify, reported each as still running, and left the broker running because they still used it |
| Start, duplicate check, orderly stop and restart of a Python service through the scripts' own functions | Verified with a stand-in service: started hidden, recognised by command line and PID file, not started twice, shut down in an orderly way on Ctrl+Break, PID file removed, previous log kept |
| Orderly stop of a process started through a `.bat` wrapper, as Kafka and Kafka Connect are | Verified with a stand-in: the child shut down on Ctrl+C and the wrapper ended by itself |
| A shell that ignores Ctrl+C (Git Bash) | Found and handled: the Python services are stopped with Ctrl+Break, which worked from both PowerShell and Git Bash |
| Starting all four real services from a fully stopped state with `start_pipeline.ps1` | **Verified:** all four `RUNNING (started)`, `Pipeline Status: READY`, exit code 0, in 56 s |
| A second run with the real services running | **Verified:** all four `RUNNING (already running)`; 0 new processes; still exactly one `cdc.bridge` and one `consumer.consumer` |
| A missing prerequisite | **Verified:** without `POSTGRES_CDC_PASSWORD` in `.env`, Kafka Connect was reported as `FAILED` with that reason, the other three services started, and the result was `NOT READY` with exit code 1. After the password was added, the next run started only Kafka Connect and reported `READY` |
| One PostgreSQL insert reaching Snowflake with the pipeline started only by the script | **Verified:** CDC live gate and end-to-end test, 10 passed and 8 skipped. Event `271fe9b6-2f44-4fad-97f6-a76ea73595b2` is in Snowflake exactly once; PostgreSQL and Snowflake both went from 307 to 308 rows |
| Stopping the four real services with `stop_pipeline.ps1` | **Verified three times** (once from an Administrator session, twice from a normal one): each service "shut down in an orderly way", `Pipeline Status: STOPPED`, exit code 0, in 14 s. The consumer and the bridge logged their own shutdown (`Stop requested (signal 21)`, `Stopped.`) |
| The broker's shutdown was clean | **Verified:** the following start showed no log recovery and no error in the broker log |
| Nothing was re-published after every service had been restarted | **Verified:** CDC topic still 8 messages, 308 rows on both sides, no duplicate; the live gate passed again (9 passed) |
| PostgreSQL after stopping | **Verified:** service `Running`; 308 rows; replication slot, publication and `cdc_user` all still present |
| Kafka after stopping | **Verified:** all 9 topic data folders present, none marked for deletion; Debezium's offsets file unchanged; no PID file left behind |
| Unrelated processes | **Verified:** pgAdmin (a Python program) kept running through every stop. Two other shell processes ended during the stop, which matches the two `.bat` launcher shells of the broker and Kafka Connect |
| The producer | **Verified:** never started by the scripts |

The stop from a normal session could only be tested after the services that had been started from an Administrator window were stopped there; the scripts cannot stop those from a normal session, and say so.

### Limitations

| Limitation | Detail |
|---|---|
| Not a Windows service | Nothing is started at boot or restarted after a crash. After a reboot, run `start_pipeline.ps1` again |
| One session type | See "Requirements": services started as Administrator are not stopped from a normal session |
| Orderly stop depends on the service | If a Java service was started from a shell that ignores Ctrl+C, it does not receive the request and is ended after the waiting time (60 s for Kafka Connect, 90 s for the broker). This is safe, only slower and not clean |
| Recognition by command line | Another project that also runs `python -m cdc.bridge` or `python -m consumer.consumer` on this machine would be taken for this one |
| While the pipeline is stopped | PostgreSQL keeps its log for the replication slot (up to `max_slot_wal_keep_size`); rows inserted meanwhile are delivered after the next start |
