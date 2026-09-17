# Step 6A — JSON vs JSONB Experiment Design

**Status:** design (12/09/2026); tables built and storage verified in
[Step 6B](Step6B_Build_JSON_Tables_and_Storage.md).

**Correction from Step 6B measurements:** the §0 estimate that documents would stay far below the TOAST threshold was
wrong. It counted value bytes only, not keys. Canonical documents average 1,683 bytes, and uncompressed `jsonb` averages
2,017 bytes. 2,880 `jsonb` documents are compressed inline and none is stored out of line; see Step 6B §6.4.

**Purpose:** compare PostgreSQL `json` and `jsonb` on the same 5,000 logical records, with evidence that is
repeatable, fair and checked for correctness. The design fixes the data, documents, tables, workload, measurements and
comparison rules **before** anything is measured. It states no expected winner.

**Source:** `log_regex.access_log_flat` (Step 5B): 5,000 rows from parser run 14. Re-verified read-only for this design:
- `sql/31` passes all 57 checks
- 1 index (the primary key)
- 0 foreign keys referencing it
- 8 internal triggers / 0 user triggers

**Not in scope:** PostGIS; any change to the flat table, the parser or the raw input; extensions; server
configuration changes.

---

## 0. Evidence used for the design (read-only)

The profile covers data characteristics and server capabilities only. It measured no JSON or JSONB size or timing:
those are the experiment's results.

| Topic | Observation | Design consequence |
|---|---|---|
| Server | PostgreSQL 17.9, UTF8, database collation and ctype **`C`**, block size 8 kB | text comparisons on fixed-format strings are byte-order: fixed-width ISO timestamps sort chronologically |
| Settings | `shared_buffers` 128 MB, `work_mem` 4 MB, `jit` on (`jit_above_cost` 100000), `max_parallel_workers_per_gather` 2, `default_toast_compression` pglz, `track_io_timing` off, `autovacuum` on | fix JIT, parallelism, TimeZone and I/O timing per session (§7.2); record everything |
| Extensions | `plpgsql` only | no `pg_stat_statements`, `pgstattuple` or `pg_prewarm`; measurements use core functions only |
| Source size | 5,000 rows; heap 6,283,264 bytes; TOAST 0 bytes | reference only |
| Stored text per row | the 10 extracted values: median 159 bytes, p99 282, max 2,231. Sources: median 128 bytes, max 182. **Only 1 row** has a URL over 500 bytes | documents will mostly be far below the ~2 kB TOAST threshold. TOAST and compression effects will be rare and must be counted separately (§5) |
| Escaping | of 47,374 stored values: 558 contain `"`, 100 contain `\`, 566 are non-ASCII, 0 control characters | the build must use PostgreSQL's JSON escaping, and the round trip must prove every value unchanged |
| Operators | `json`: only `->`, `->>`, `#>`, `#>>`. `jsonb`: additionally `=`, `<>`, ordering, `@>`, `<@`, `?`, `?\|`, `?&`, `@?`, `@@`, `\|\|`, `-`, `#-` | only extraction syntax is common to both. `json` has **no equality operator** (no `DISTINCT` / `GROUP BY` on a whole document) |
| Index operator classes | `json`: **none**. `jsonb`: btree `jsonb_ops`, hash `jsonb_ops`, GIN `jsonb_ops` (default), GIN `jsonb_path_ops` | on `json`, only expression indexes are possible |
| Volatility | `json_*` / `jsonb_*` extraction functions, `jsonb_contains`, `jsonb_path_exists`, `numeric_in`: IMMUTABLE. `timestamp_in`, `timestamptz_in`: STABLE | expression indexes may extract text, integer and numeric values, but not cast to `timestamp` / `timestamptz` |
| SQL/JSON | `JSON_VALUE(json, …)` and `JSON_EXISTS(json, …)` work in PostgreSQL 17; `jsonb_path_exists` has no `json` signature | `JSON_VALUE` / `JSON_EXISTS` are a second syntax common to both types |
| Serialisation | `json_build_object` writes `{"k" : v}` (spaces). `json` keeps the input text exactly (key order, whitespace, duplicate keys). `jsonb` output is `{"k": v}` with keys reordered and duplicates removed. Numeric scale is kept by both (`40.6862000`) | build one minified canonical text and feed the **same text** to both types (§2.3) |
| EXPLAIN | `ANALYZE, BUFFERS, SETTINGS, SERIALIZE, MEMORY, SUMMARY` available | serialisation cost of returned documents can be measured on the server (§7) |

## 1. What data is represented as JSON

One JSON document per `access_log_flat` row: **5,000 documents**. Each document carries exactly the logical record of
the flat row, **70 leaf values**: every column except `loaded_at`.

| Included | From `access_log_flat` |
|---|---|
| identity | `log_id`, `run_id` |
| record classification (7) | `format_family`, `detection_rule`, `sub_format`, `record_validity`, `is_truncated`, `event_end_pos`, `diagnostics` |
| per field × 10 (5 each) | exact `value`, `validity`, `start_pos`, `source`, `missing_reason` |
| typed values (11) | `entity_type_code`; `event_timestamp_shape`, `_local`, `_utc_offset`, `_utc`; `latitude_degrees`; `longitude_degrees`; `ip_address_inet`, `ip_address_zone_id`; `status_code`, `status_word` |

| Excluded | Reason |
|---|---|
| `loaded_at` | publication metadata of the flat table, not part of the logical record; it would differ between loads |
| `raw_log` | lives in `raw_access_logs`; the experiment compares storage of the parsed record, not the raw text |
| `parsed_secondary` values, `rule_id`, `candidate_count` | not in the Step 5B flat table (the stated source) |

## 2. Document structure and field names

### 2.1 Structure (document version 1)

```json
{
  "log_id": 6,
  "run_id": 14,
  "record": {
    "format_family": "F1",
    "detection_rule": "DET-F1",
    "sub_format": "…",
    "record_validity": "VALID",
    "is_truncated": false,
    "event_end_pos": 180,
    "diagnostics": []
  },
  "fields": {
    "entity_type":     { "value": "…", "validity": "VALID", "start_pos": 12, "source": "F1.key.entity", "missing_reason": null, "code": "USER" },
    "email_address":   { "value": "…", "validity": "…", "start_pos": 0, "source": "…", "missing_reason": null },
    "resource_url":    { "value": "…", "validity": "…", "start_pos": 0, "source": "…", "missing_reason": null },
    "event_timestamp": { "value": "2026-05-27T19:16:21Z", "validity": "VALID", "start_pos": 1, "source": "…", "missing_reason": null,
                         "shape": "iso8601", "local": "2026-05-27T19:16:21.000000", "utc_offset_minutes": 0,
                         "utc": "2026-05-27T19:16:21.000000Z" },
    "tool":            { "value": "…", "validity": "…", "start_pos": 0, "source": "…", "missing_reason": null },
    "latitude":        { "value": "51°33'05.8\"N", "validity": "VALID", "start_pos": 0, "source": "…", "missing_reason": null, "degrees": 51.5516111 },
    "longitude":       { "value": "…", "validity": "…", "start_pos": 0, "source": "…", "missing_reason": null, "degrees": -0.0915000 },
    "ip_address":      { "value": "fe80::1ff:fe23:4567:890a%eth0", "validity": "VALID", "start_pos": 0, "source": "…", "missing_reason": null,
                         "address": "fe80::1ff:fe23:4567:890a", "zone_id": "eth0" },
    "action_phrase":   { "value": "…", "validity": "…", "start_pos": 0, "source": "…", "missing_reason": null },
    "status":          { "value": "403", "validity": "VALID", "start_pos": 0, "source": "…", "missing_reason": null, "code": 403, "word": null }
  }
}
```

(Pretty-printed for reading; "…" and 0 stand for row values. The stored text is minified, §2.3.)

**Key count:**
- Top level: 4 keys (`log_id`, `run_id`, `record`, `fields`).
- `record`: 7 keys.
- `fields`: 10 keys, each an object with 5 common keys plus its typed keys (11 in total).
- Result: **82 keys in total, of which 70 are leaves**, identical in every document.

### 2.2 Value rules

| Rule | Decision |
|---|---|
| Key names | `snake_case`, equal to the flat column names within their object (`value` = `<field>`, `validity` = `<field>_validity`, …; typed: `code`, `shape`, `local`, `utc_offset_minutes`, `utc`, `degrees`, `address`, `zone_id`, `word`) |
| Key order | design order as above (top level; record; fields in `ref_field` order; common keys, then typed keys) |
| MISSING / SQL NULL | **key always present, value JSON `null`**. Every document has the same key set, so the comparison is about the storage format, not about sparse documents |
| Literal `NULL`/`null` placeholders | JSON strings `"NULL"` / `"null"` (136 values), never JSON `null` |
| Integers | JSON numbers: `log_id`, `run_id`, `start_pos`, `event_end_pos`, `utc_offset_minutes`, status `code` |
| Boolean | `is_truncated`: `true` / `false` |
| Array | `diagnostics`: array of strings (`[]` when empty) |
| Coordinates | JSON number written from `numeric(10,7)` with its 7-digit scale (`51.5516111`, `-0.0915000`) |
| Local time | string `YYYY-MM-DD"T"HH24:MI:SS.US`: fixed width, 6 fraction digits |
| UTC instant | string `YYYY-MM-DD"T"HH24:MI:SS.US"Z"` from `event_timestamp_utc AT TIME ZONE 'UTC'`: fixed width, so it sorts chronologically under collation `C` and can be indexed without a STABLE cast |
| UTC offset | integer minutes (`extract(epoch FROM offset) / 60`; e.g. `+05:30` → `330`) |
| IP address | `host(ip_address_inet)` (address without mask); `zone_id` string or `null` |
| Domains | validity and missing-reason domain values as plain strings |

### 2.3 Canonical document text (identical input for both types)

- The document is built **once** per row as a `text` value: **minified** (no insignificant whitespace), keys in design
  order. It is assembled by concatenation with `coalesce(to_json(<value>)::text, 'null')`, so PostgreSQL performs all
  string escaping.
- The **same text** is cast to `json` for the JSON table and to `jsonb` for the JSONB table.
- `json_build_object` is **not** used for the stored text: its `" : "` spacing would add whitespace bytes to the `json`
  side only and bias the storage comparison. Optional sensitivity figure: measure that formatting's size separately
  (§5, M-09).

## 3. Tables to be created later (Step 6B; sketch, not executed)

```sql
CREATE SCHEMA log_regex_json;

CREATE TABLE log_regex_json.access_log_json (
    log_id  integer NOT NULL,
    doc     json    NOT NULL,
    CONSTRAINT access_log_json_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);

CREATE TABLE log_regex_json.access_log_jsonb (
    log_id  integer NOT NULL,
    doc     jsonb   NOT NULL,
    CONSTRAINT access_log_jsonb_pkey PRIMARY KEY (log_id)
) WITH (autovacuum_enabled = false);
```

| Decision | Reason |
|---|---|
| **Identical except the `doc` type** | same column order, key column, primary key, fillfactor (default 100), column storage (`extended` for both), compression (server default `pglz`, recorded), reloptions |
| Separate schema `log_regex_json` | experiment objects are isolated: dropping the schema removes only them; existing digests of `log_regex` stay valid |
| **No foreign keys** | a foreign key to `access_log_flat` or `raw_access_logs` would add internal triggers to those tables and create a dependency. Equivalence is instead proven by verification (§8) |
| No CHECK on `doc` | a CHECK would add per-row evaluation work to the load only for its own validation. The load gate verifies instead (§8) |
| `log_id` as a column and inside `doc` | both tables have the same key access path (primary key); `doc->>'log_id' = log_id` is verified |
| `autovacuum_enabled = false` on both | no background vacuum/analyze during measurements; explicit `VACUUM (ANALYZE)` after every load |
| Separate load-timing tables | `access_log_json_load` / `access_log_jsonb_load` (same definitions) for repeated write measurements, so the measured query tables are never reloaded |
| Result storage | measurement outputs (EXPLAIN JSON, CSV summaries) are written to files under `analysis/step6/`, not into database tables |

## 4. Queries to test on both

All queries run against `T` = `access_log_json` and `T` = `access_log_jsonb` with **identical SQL text apart from the
table name**. Every query also has a flat-table oracle, used only to check the result. Expected row counts come from
the flat table.

### 4.1 Head-to-head workload (same syntax on both)

| ID | Pattern | SQL on `T` (identical for both) | Rows |
|---|---|---|---:|
| Q01 | point lookup, whole document | `SELECT doc FROM T WHERE log_id = 2835` | 1 |
| Q02 | all whole documents (output serialisation) | `SELECT doc FROM T` | 5,000 |
| Q03 | point lookup, one nested value | `SELECT doc->'fields'->'resource_url'->>'value' FROM T WHERE log_id = 2835` | 1 |
| Q04 | one nested scalar, all rows | `SELECT log_id, doc->'record'->>'record_validity' FROM T` | 5,000 |
| Q05 | ten nested scalars per row | `SELECT log_id, doc->'fields'->'entity_type'->>'value', …, doc->'fields'->'status'->>'value' FROM T` | 5,000 |
| Q06 | all 70 leaves per row (full reconstruction, with casts) | `SELECT (doc->>'log_id')::int, …, (doc->'fields'->'status'->>'code')::int, … FROM T` | 5,000 |
| Q07 | equality, very selective | `WHERE doc->'record'->>'record_validity' = 'BROKEN'` | 12 |
| Q08 | equality, medium | `WHERE doc->'fields'->'entity_type'->>'code' = 'BOT'` | 225 |
| Q09 | equality, broad | `WHERE doc->'record'->>'format_family' = 'F1'` | 1,528 |
| Q10 | integer equality | `WHERE (doc->'fields'->'status'->>'code')::int = 404` | 30 |
| Q11a | numeric range, medium | `WHERE (doc->'fields'->'latitude'->>'degrees')::numeric BETWEEN 50 AND 55` | 422 |
| Q11b | numeric range, broad | `… BETWEEN 0 AND 60` | 3,064 |
| Q12a | time window 1 day (string range) | `WHERE doc->'fields'->'event_timestamp'->>'utc' >= '2026-03-01T00:00:00.000000Z' AND … < '2026-03-02T00:00:00.000000Z'` | 13 |
| Q12b | time window 1 week | `… < '2026-03-08T00:00:00.000000Z'` | 108 |
| Q12c | time window 1 month | `… < '2026-04-01T00:00:00.000000Z'` | 498 |
| Q13a | pattern, suffix | `WHERE doc->'fields'->'email_address'->>'value' LIKE '%.org'` | 545 |
| Q13b | pattern, prefix | `WHERE doc->'fields'->'tool'->>'value' LIKE 'curl/%'` | 173 |
| Q14 | array membership | `WHERE EXISTS (SELECT 1 FROM <type>_array_elements_text(doc->'record'->'diagnostics') AS d (x) WHERE d.x = 'truncated')` | 3 |
| Q15 | JSON null test | `WHERE doc->'fields'->'event_timestamp'->>'utc' IS NOT NULL` | 2,941 |
| Q16 | conjunction | `WHERE doc->'record'->>'format_family' = 'F3' AND (doc->'fields'->'status'->>'code')::int = 403` | from oracle |
| Q17 | group by nested text | `SELECT doc->'fields'->'entity_type'->>'code', count(*) FROM T GROUP BY 1` | 8 groups |
| Q18 | group by two values | `SELECT doc->'fields'->'status'->>'code', doc->'fields'->'status'->>'word', count(*) … GROUP BY 1, 2` | from oracle |
| Q19 | numeric aggregates | `SELECT min/max/avg((doc->'fields'->'latitude'->>'degrees')::numeric) FROM T WHERE doc->'fields'->'latitude'->>'validity' = 'VALID'` | 1 |
| Q20 | SQL/JSON value | `SELECT JSON_VALUE(doc, '$.record.record_validity') FROM T` | 5,000 |
| Q21 | SQL/JSON exists | `WHERE JSON_EXISTS(doc, '$.fields.status.code ? (@ == 404)')` | 30 |

In Q14 the function name follows the type (`json_array_elements_text` / `jsonb_array_elements_text`). This is the only
text difference besides the table name, and it is the equivalent function. Q20 and Q21 on `json` convert the document
internally. That is part of what they measure, and it is recorded as such.

### 4.2 Type-specific capability queries (reported separately, not head-to-head)

| ID | Query | On `jsonb` | On `json` |
|---|---|---|---|
| C1 | containment `doc @> '{"record":{"record_validity":"BROKEN"}}'` (12) | native | not available; optionally `doc::jsonb @> …` (labelled "converted per row") |
| C2 | key/element existence `doc->'record'->'diagnostics' ? 'truncated'` (3) | native | not available |
| C3 | jsonpath `doc @? '$.fields.status.code ? (@ == 404)'` (30) | native | not available (Q21 is the common form) |
| C4 | whole-document equality / `DISTINCT doc` | available | **not available** (no `=` operator); recorded as a capability fact, not timed |

### 4.3 Write-side measurements (experiment load tables only)

| ID | Measurement |
|---|---|
| W1 | `INSERT … SELECT` of the 5,000 canonical texts into the empty load table (`::json` vs `::jsonb`), each in its own transaction, `EXPLAIN (ANALYZE, BUFFERS, WAL)`; `TRUNCATE` between repetitions |
| W2 (optional) | update one nested value in 238 documents: `jsonb_set` on `jsonb`; rebuild via `jsonb_set(doc::jsonb, …)::json` on `json`. Asymmetric by nature, so it is reported separately |

## 5. Storage measurements

Taken on the measured tables after a fresh load, then `VACUUM (ANALYZE)`, before any secondary index exists (and again
per index configuration, §6).

| ID | Measurement | How (core functions only) |
|---|---|---|
| M-01 | relation forks | `pg_relation_size(t, 'main' / 'fsm' / 'vm')` |
| M-02 | TOAST | `pg_relation_size(reltoastrelid)` and the size of the TOAST index |
| M-03 | totals | `pg_table_size`, `pg_indexes_size`, `pg_total_relation_size` |
| M-04 | pages and tuples | `relpages`, `reltuples` after `VACUUM (ANALYZE)`; rows per page; `n_dead_tup` = 0 |
| M-05 | stored size per document | `pg_column_size(doc)`: min, p25, p50, p75, p90, p99, max, avg, sum |
| M-06 | text size per document | `octet_length(doc::text)` for both, and `octet_length` of the canonical input text (identical for both). Keep separate: `json` output = input; `jsonb` output is re-spaced |
| M-07 | compression and out-of-line storage | count `pg_column_compression(doc) IS NOT NULL` and `pg_column_toast_chunk_id(doc) IS NOT NULL`; TOAST chunk count |
| M-08 | write cost | load time, WAL bytes and buffers from W1; for every index build: build time, index size (`pg_relation_size`), WAL bytes (`pg_current_wal_insert_lsn()` difference) |
| M-09 (optional) | formatting sensitivity | `octet_length` of the same documents built with `json_build_object` spacing (computed, not stored) |
| Reference | flat table | `access_log_flat` sizes (context only; not part of the JSON/JSONB comparison) |

## 6. Indexing experiments

At 5,000 rows the planner may choose sequential scans even when an index exists. Every configuration is measured under
default planner settings (primary result). A separately labelled diagnostic run adds `SET enable_seqscan = off` to
measure the index path itself.

| ID | Configuration | `json` | `jsonb` | Queries | Comparable? |
|---|---|---|---|---|---|
| I-0 | primary key only (baseline) | yes | yes | all | head-to-head |
| I-1 | the **same btree expression indexes** on both:<br>a `((doc->'record'->>'record_validity'))`<br>b `((doc->'fields'->'entity_type'->>'code'))`<br>c `(((doc->'fields'->'status'->>'code')::integer))`<br>d `(((doc->'fields'->'latitude'->>'degrees')::numeric))`<br>e `((doc->'fields'->'event_timestamp'->>'utc'))` | yes | yes | Q07, Q08, Q10, Q11, Q12, Q16, Q17 | head-to-head |
| I-2 | GIN `jsonb_ops` on `doc` | not possible | yes | C1, C2, C3, Q21 | capability (jsonb only) |
| I-3 | GIN `jsonb_path_ops` on `doc` | not possible | yes | C1, C3 | capability (jsonb only) |
| I-4 (to verify in 6B) | GIN on the expression `(doc::jsonb)` of the `json` table | only if PostgreSQL accepts the cast in an index expression | — | C1/C3 written as `doc::jsonb @> …` | separate: "json with a jsonb expression index" |

For each index: build time (median of 3 builds), size, WAL bytes, whether the default plan uses it, and the query
measurements of §7. I-1 is created as one set; each index's size is reported individually.

Not planned: btree or hash on the whole `jsonb` document (no workload query needs document ordering or equality),
indexes on the flat table, PostGIS indexes.

## 7. EXPLAIN ANALYZE measurements

### 7.1 Collected per execution

`EXPLAIN (ANALYZE, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY, SUMMARY, FORMAT JSON)`; `WAL` is added for W1.

| Metric | From |
|---|---|
| planning time; execution time | summary |
| serialisation time and output bytes | `SERIALIZE` (the cost of converting returned values to text: central for Q01, Q02, Q20) |
| plan shape: top node, scan type, index used, filter / recheck conditions | plan tree |
| estimated vs actual rows (per node), loops | plan tree |
| shared hit / read / dirtied / written; local and temp blocks; I/O timing | `BUFFERS` with `track_io_timing` on |
| planner memory | `MEMORY` |
| non-default settings in effect | `SETTINGS` (must be identical for a pair) |
| JIT and parallel workers | must be absent (§7.2) |

### 7.2 Protocol

| Item | Rule |
|---|---|
| Session settings (same for every run) | `TimeZone = 'UTC'`, `jit = off`, `max_parallel_workers_per_gather = 0`, `track_io_timing = on`; everything else at the recorded server defaults. Session-level `SET` only; no `ALTER SYSTEM` |
| Preparation | `VACUUM (ANALYZE)` on both tables after each load or index change; confirm no other sessions are active (`pg_stat_activity`) |
| Cache state | warm cache: 3 unmeasured warm-up executions per query and table (no `pg_prewarm`). Cold-cache behaviour is not measured |
| Repetitions | 15 measured executions per query × table × index configuration |
| Order | interleaved in balanced blocks (json, jsonb, jsonb, json, …) so drift affects both equally |
| Timing mode | the 15 timing runs use `TIMING OFF` (lower instrumentation overhead). One extra `TIMING ON` run per query and table records the per-node breakdown |
| Statistics reported | median, IQR, min, max for execution, planning and serialisation time; buffers (expected identical across repetitions) |
| Independent batch | the full I-0 workload is repeated in a second, fresh session to confirm reproducibility |
| Recorded environment | date, server version, all `pg_settings` in effect, OS (Windows 11), table and index sizes at the time |

## 8. Ensuring exactly the same 5,000 logical records

**Build (Step 6B, one transaction, `REPEATABLE READ`):**
1. Source gate. `sql/27`, `sql/29` and `sql/31` pass and `verify_raw_access_logs()` is 10 / 10. Record a digest of the
   flat table (md5 of all rows in `log_id` order).
2. Stage the canonical document text (§2.3) once per `log_id` from `access_log_flat`.
3. `INSERT INTO access_log_json SELECT log_id, doc_text::json … ORDER BY log_id`.
4. `INSERT INTO access_log_jsonb SELECT log_id, doc_text::jsonb … ORDER BY log_id` from the **same staged text**.
   Physical insertion order is identical.

**Equivalence checks** (gate before COMMIT, repeated by a read-only verification script):

| ID | Check |
|---|---|
| E1 | 5,000 rows in each table; the `log_id` sets of both tables equal the flat table's |
| E2 | `json` stores the canonical text byte for byte (`doc::text = doc_text`); md5 over the ordered documents recorded |
| E3 | `json_table.doc::jsonb = jsonb_table.doc` for all 5,000 `log_id` (semantic equality) |
| E4 | every canonical text is `IS JSON OBJECT WITH UNIQUE KEYS` (no duplicate keys that `jsonb` would silently drop) |
| E5 | every document in both tables has exactly the 82 designed keys (70 leaves) at the designed paths, with the designed JSON types |
| E6 | **round trip:** all 70 leaves extracted from each table and cast back (`::integer`, `::numeric`, `::timestamp`, `::timestamptz`, minutes → `interval`, `::inet`, `::text[]`) equal the flat columns (`IS NOT DISTINCT FROM`) for all 5,000 rows; coordinate text keeps its 7-digit scale |
| E7 | `doc->>'log_id'` = `log_id` and `doc->>'run_id'` = `14` in every document |
| E8 | per query: result checksum on `json` = on `jsonb` = flat-table oracle (md5 of the ordered result) |
| E9 | after all measurements: the flat-table digest is unchanged; the measured tables were never modified (row md5 re-checked) |

## 9. What counts as comparable

These rules are fixed before measuring:

1. **Correct first.** A timing pair counts only if E1–E8 pass and both results equal the flat-table oracle.
2. **Same conditions.**
   - identical session settings (`SETTINGS` output) and index configuration class (I-0 with I-0, I-1 with I-1)
   - same repetitions and interleaving
   - both tables vacuumed and analysed
   - same server run, no concurrent activity
3. **Same SQL.** Head-to-head results (Q01–Q21, W1) use identical SQL apart from the table name, plus the equivalent
   array function in Q14. Capability results (C1–C4, I-2, I-3, I-4, W2) are reported separately and are **never used as
   a head-to-head format verdict**.
4. **Plans.** If the two types get different default plans, the pair is still reported (end to end) with the plan
   difference stated. Forced-plan diagnostic runs are reported separately.
5. **Difference threshold.** A timing difference is called *measurable* only if all of these hold:
   - the IQRs of the two 15-run samples do not overlap
   - the medians differ by at least 10 %
   - for medians below 0.1 ms, the same direction reproduces in the independent batch

   Otherwise the result is "no measurable difference".
6. **Storage.** Compared on identical logical documents (E-checks), fresh load plus `VACUUM (ANALYZE)`, same storage
   settings. Report heap, TOAST, index and total sizes separately, and per-document distributions. The primary key index
   is reported but kept apart from document storage.
7. **Scope of conclusions.**
   - Covered: this dataset (5,000 documents of about the profiled size, almost none TOASTed) on PostgreSQL 17.9 on this
     Windows server, with warm cache.
   - Not covered: larger or TOAST-heavy documents, concurrency, cold cache.
8. **Not comparable:**
   - timings against the flat table (the flat table is the correctness oracle; its figures are context only)
   - runs with different settings, statistics or index sets
   - any run where an equivalence check failed

Questions the experiment answers (no expected answer is assumed):
- storage per document and per table
- cost of returning whole documents
- cost of extracting 1, 10 or 70 values
- filter and aggregate cost without indexes
- effect of identical expression indexes
- what `jsonb`-only operators and GIN indexes add
- load and index build cost

## 10. What must remain unchanged

| Object | Requirement | Verified by |
|---|---|---|
| `raw_access_logs`, fingerprints, load audit, guard triggers | unchanged | `verify_raw_access_logs()` 10 / 10 before and after |
| `expected_fields` (answer key) | unchanged, read-only | its guard trigger; row digest |
| parser functions, validators, reference tables, `parser_run`, `parsed_log`, `parsed_field`, `parsed_secondary`, views | unchanged (no new run) | the existing runner digest (160 items) before and after |
| `access_log_flat` | same 71 columns, 5,000 rows, 22 CHECKs, 4 foreign keys, comments. Its only index stays the primary key; no JSON column, no referencing foreign key (so still 8 internal / 0 user triggers). Read only as the build source | `sql/27`, `sql/29`, `sql/31` before and after; flat-table row digest (E9) |
| rebuild guards | `sql/07` / `sql/08` guards and the Step 3B-3 runner guard unchanged; the experiment adds no dependency on `log_regex` objects | static checks of the Step 5B runners |
| extensions and server | no extension (no PostGIS); no `ALTER SYSTEM` or configuration file change; session `SET` only | `pg_extension`; `pg_settings` recorded before and after |
| experiment isolation | all new objects live in `log_regex_json` and can be dropped without touching `log_regex` | dependency check (`pg_depend`) in 6B |

## 11. Proposed next steps (not started)

| Step | Content |
|---|---|
| 6B | create `log_regex_json` and the two tables; build from the canonical text; equivalence checks E1–E7; storage measurements M-01…M-09 at I-0; W1 load measurements |
| 6C | query workload Q01–Q21 and C1–C4 at I-0 (EXPLAIN protocol §7) |
| 6D | index experiments I-1…I-4: build cost, size, plans, query measurements |
| 6E | results report and conclusions under the rules of §9 |

## 12. Decisions for review

1. Document = the 70 logical leaves of the flat row (no `loaded_at`, raw log or secondary values), nested as
   `record` + `fields.<field>.<key>`.
2. MISSING as JSON `null` with every key present (dense documents); placeholders stay strings.
3. Typed values:
   - timestamps as fixed-width ISO strings (UTC with `Z`); offset as integer minutes
   - coordinates as 7-scale numbers
   - IP address via `host()` plus zone ID
4. One minified canonical text feeds both types; `json_build_object` spacing is only an optional sensitivity figure.
5. Separate schema `log_regex_json`; tables identical except the `doc` type; no foreign keys; autovacuum disabled on
   the experiment tables only.
6. Head-to-head uses identical SQL (extraction operators, `JSON_VALUE` / `JSON_EXISTS`); `jsonb`-only operators and GIN
   indexes are reported as capabilities.
7. Session settings for measurement: `jit = off`, `max_parallel_workers_per_gather = 0`, `TimeZone = 'UTC'`,
   `track_io_timing = on`.
8. 15 interleaved repetitions, `TIMING OFF`, median + IQR; measurable difference = non-overlapping IQRs and at least
   10 %, reproduced for sub-0.1 ms medians.
9. Optional items: W2 update test, M-09 formatting sensitivity, I-4 json expression GIN.
