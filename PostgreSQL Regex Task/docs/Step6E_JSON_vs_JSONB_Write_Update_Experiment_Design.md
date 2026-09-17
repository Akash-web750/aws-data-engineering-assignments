# Step 6E — JSON vs JSONB Write/Update Cost Experiment Design

**Status:** design approved with safeguards; setup and preflight done (12/09/2026); measured 12–13/09/2026, see
[Step6E_JSON_vs_JSONB_Write_Update_Experiment.md](Step6E_JSON_vs_JSONB_Write_Update_Experiment.md) (including the
deviations in its section 3).
`sql/41` created schema `log_regex_json_write` (four designed tables, staged input, expected updates);
`sql/run_step6e_setup_preflight.ps1` passed 63 / 63 checks (`analysis/step6/step6e_preflight_report.txt`), including
`sql/42` 41 / 41. Existing raw, flat, parser, Step 6B/6D objects and the 6C/6D outputs are unchanged.

**Purpose:** measure what it costs to **write** the same documents as `json` and as `jsonb`: inserts, updates, index
maintenance and WAL. The protocol keeps the result comparable and correct, and isolated from all existing data. It
states no expected winner and draws no conclusion.

**Numbering:** Step 6A §11 proposed "6E = results report". That report becomes **Step 6F**, after this experiment.

---

## 1. What was already planned (review of Step 6A–6D)

| Item | Where planned | Planned content | Status after Step 6D |
|---|---|---|---|
| W1 | 6A §4.3, §7.1, §9 rule 3 | `INSERT … SELECT` of the 5,000 canonical texts into an **empty load table**, `::json` vs `::jsonb`, own transaction, `EXPLAIN (ANALYZE, BUFFERS, WAL)`, `TRUNCATE` between repetitions; head-to-head | **not measured** (deferred in 6B §0) |
| W2 (optional) | 6A §4.3, §12 item 9 | update one nested value in **238 documents**: `jsonb_set` on jsonb vs `jsonb_set(doc::jsonb, …)::json` on json; asymmetric, reported separately | **not measured** |
| M-08 | 6A §5 | write cost: load time, WAL bytes and buffers from W1; build time, size and WAL of every index build | index builds **measured in 6D §3**; load part **not measured** |
| Load tables | 6A §3 | `access_log_json_load` / `access_log_jsonb_load`, same definitions, so the query tables are never reloaded | **not created** |
| Index maintenance on writes | 6D §10 item 8 (limit) | none planned | **gap**: insert/update cost with the btree and GIN indexes never measured |
| M-09 (optional) | 6A §5 | formatting sensitivity of `json_build_object` text (storage, not writes) | not measured; **out of scope for 6E** |

Step 6E covers W1, W2 (in a fairer, extended form), the load part of M-08, and the index-maintenance gap.

## 2. Evidence carried forward

| Fact | Source | Consequence for 6E |
|---|---|---|
| Canonical text: 5,000 docs, 8,416,033 bytes, md5 `aeaef323…`; stored json text is byte-identical | 6B §3–4 | the insert input is read once from the stored json text and verified against this md5 |
| jsonb binary is 174–366 bytes larger per document (uncompressed); 2,880 jsonb rows cross the ~2 kB TOAST threshold and are pglz-compressed inline; json rows stay below it | 6B §6 | compression happens during writes; the number of compressed documents is recorded before and after every write |
| Heap pages 1,250 (json) / 981 (jsonb); fillfactor 100 | 6B §5 | with the expression indexes on `doc` (X-1 … X-4) an update changes an indexed column, so HOT updates are impossible and every index gets a new entry. With the primary key only (X-0), a new version of about 1.7 kB rarely fits the free space left on its page. `n_tup_hot_upd` records what actually happens |
| Btree expression index builds: json 66–122 ms vs jsonb 16–21 ms, same size and WAL; GIN builds 554 / 244 ms | 6D §3 | index maintenance during inserts is expected to depend on both extraction cost and index type; measured, not assumed |
| Phase-to-phase drift up to about 7–15 % on identical plans | 6D §4, §9 | every json vs jsonb comparison and every index-effect comparison is interleaved within the same session |
| Server: `wal_level` replica, `full_page_writes` on, `wal_compression` off, `synchronous_commit` on, `fsync` on, `wal_sync_method` open_datasync, `max_wal_size` 1 GB, `checkpoint_timeout` 300 s, `track_wal_io_timing` off, `pg_stat_wal` / `pg_stat_checkpointer` / `pg_stat_io` available | read-only query, 12/09/2026 | full-page images depend on checkpoint timing and must be normalised (§7). WAL counters are cluster-wide, so other activity must be excluded (§8) |
| 4 other client sessions currently connected (idle at earlier checks) | same query | each measurement session records other active sessions and cluster WAL deltas, and flags runs with foreign activity |

## 3. Isolation from existing data

| Rule | Design |
|---|---|
| Separate schema | **`log_regex_json_write`**. This deviates from the 6A names inside `log_regex_json`, because `sql/34` B-10a and `sql/38` G-05 check the exact relation set of `log_regex_json`. A separate schema leaves those checks, and the Step 6D index state, untouched. Dropping the schema removes every write artefact |
| Objects (created in 6E) | `canonical_doc (log_id integer PRIMARY KEY, doc_text text NOT NULL)`, the staged input.<br>`expected_update (variant text, log_id integer, new_text text NOT NULL, PRIMARY KEY (variant, log_id))`, the expected documents after each update.<br>`access_log_json_w (log_id integer PRIMARY KEY, doc json NOT NULL)` and `access_log_jsonb_w (… doc jsonb …)`: the 6B definitions, including `autovacuum_enabled = false`, default storage and compression |
| Reads from existing data | exactly one statement: `SELECT log_id, doc::text FROM log_regex_json.access_log_json` to fill `canonical_doc`, verified against the md5. No other existing table is read (catalogs aside) |
| No coupling | no foreign keys, triggers, views or functions referencing `log_regex` or `log_regex_json`; own copies of the index definitions on the `_w` tables |
| Never written | `raw_access_logs`, `access_log_flat`, parser objects and runs, `expected_fields`, `log_regex_json.access_log_json` / `access_log_jsonb` and their 14 indexes |
| Proven by | before and after the experiment:<br>• `log_regex` digest (203 items)<br>• `log_regex_json` data digest (10 items)<br>• catalog digest of the 14 existing index definitions and sizes<br>• `sql/34` 38 / 38 and `sql/38 -v phase=final` 70 / 70<br>• the SHA-256 baseline manifests of Step 6C and Step 6D outputs (a 6D manifest is created before the first write) |
| Static checks | the runner confirms that every `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `CREATE`, `DROP`, `VACUUM` and `ANALYZE` targets `log_regex_json_write` only. `CHECKPOINT` is the only cluster-level command (no data change) |

## 4. Index configurations for writes

All definitions are copied from the Step 6D generator (same expressions, operator classes and methods); only the table
names change. A G-10-style check confirms the json and jsonb definitions are identical.

| ID | Indexes on the `_w` table | Types | Comparison |
|---|---|---|---|
| X-0 | primary key only | json, jsonb | head-to-head |
| X-1 | primary key + the five btree expression indexes of I-1 | json, jsonb | **head-to-head** (fair index-maintenance comparison) |
| X-2 | X-1 + GIN `jsonb_ops` | jsonb | capability (separate) |
| X-3 | X-1 + GIN `jsonb_path_ops` | jsonb | capability (separate) |
| X-4 | X-1 + both GIN indexes, i.e. the **current Step 6D index set** of `access_log_jsonb` | jsonb | capability; cost of the indexes as they exist now |

Index effect = X-0 vs X-1 per type, and X-1 vs X-2 / X-3 / X-4 for jsonb, always measured interleaved in the same
session.

## 5. INSERT experiments (head-to-head)

| ID | Statement (identical except table and cast) | Starting state |
|---|---|---|
| W1 bulk | `INSERT INTO log_regex_json_write.access_log_<type>_w (log_id, doc) SELECT log_id, doc_text::<type> FROM log_regex_json_write.canonical_doc ORDER BY log_id` (5,000 rows) | table truncated; the configuration's indexes exist (empty) |
| W1b row-at-a-time | 250 single-row inserts (`log_id % 20 = 0`), each `INSERT … VALUES ($1, $2::<type>)` executed by one server-side loop in one transaction; reported per row | table holds the other 4,750 rows; indexes built and analysed |

W1 runs in configurations X-0 … X-4; W1b in X-0, X-1 and X-4.

## 6. UPDATE experiments

Every update starts from a freshly loaded table. The configuration's indexes are rebuilt with `CREATE INDEX`, so they
match the compact state of Step 6D.

**Row sets:**
- **R-238:** the 238 records with `record_validity = INVALID` (as planned in 6A W2).
- **R-5000:** all documents.

**Changed paths:**
- **P-idx:** `record.record_validity` → `"REVIEWED"`, covered by index I-1a.
- **P-non:** `fields.action_phrase.source` → `"W-UPDATED"`, not indexed.

### 6.1 Head-to-head: full-document replacement (identical new text for both types)

`UPDATE log_regex_json_write.access_log_<type>_w t SET doc = e.new_text::<type> FROM log_regex_json_write.expected_update e
WHERE e.variant = '<variant>' AND t.log_id = e.log_id`

| ID | Rows | Path | Configurations |
|---|---|---|---|
| UA-1 | R-238 | P-idx | X-0, X-1, X-2, X-3, X-4 |
| UA-2 | R-238 | P-non | X-0, X-1, X-4 |
| UA-3 | R-5000 | P-idx | X-0, X-1, X-4 |

This models an application sending the complete new document. json and jsonb receive the same text and the same row
set, so the comparison is fair.

### 6.2 Type-native partial modification (reported separately, not head-to-head)

| ID | Type | Statement | Note |
|---|---|---|---|
| UB-jsonb | jsonb | `SET doc = jsonb_set(doc, '{record,record_validity}', '"REVIEWED"')` | server-side path update |
| UB-json-cast | json | `SET doc = jsonb_set(doc::jsonb, '{record,record_validity}', '"REVIEWED"')::json` | the 6A W2 form. The stored json text changes to jsonb formatting (reordered keys, extra spaces), so it is **no longer canonical**; the size change is recorded |
| UB-json-text | json | `SET doc = regexp_replace(doc::text, '"record_validity":"(VALID\|INVALID\|BROKEN)"', '"record_validity":"REVIEWED"')::json` | preserves the canonical minified text; staging asserts exactly one match per document (R-238 contains only `INVALID`, R-5000 all three values) |

Each runs on R-238 and R-5000 in X-1. These compare update **mechanisms** that exist only per type, so they are never
used as a json vs jsonb verdict.

## 7. Measurements

**Per measured statement** (executed inside `BEGIN … COMMIT`):

| Metric | How |
|---|---|
| execution and planning time | `EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, WAL, SETTINGS, SUMMARY, FORMAT JSON) <DML>` (EXPLAIN ANALYZE executes the DML); one extra `TIMING ON` detail run per series |
| WAL records, WAL bytes, full-page images | `WAL` option of EXPLAIN; covers heap, TOAST and index WAL of the statement |
| WAL including the commit record | `pg_wal_lsn_diff` of `pg_current_wal_insert_lsn()` before `BEGIN` and after `COMMIT`, same session |
| WAL writes, syncs and their time | `pg_stat_wal` deltas per run (`wal_records`, `wal_fpi`, `wal_bytes`, `wal_buffers_full`, `wal_write`, `wal_sync`, `wal_write_time`, `wal_sync_time`), with `track_wal_io_timing = on` in the session |
| relation I/O by the backend | `pg_stat_io` deltas (client backend: writes, extends, fsyncs) |
| buffers | shared hit / read / dirtied / written, temp blocks, I/O timing |
| client-observed transaction time | psql `\timing` for `BEGIN`…`COMMIT` (secondary; includes the localhost round trip and the commit flush) |
| W1b per row | server-side `clock_timestamp()` and LSN difference around the 250-row loop, divided by 250 |
| checkpoint interference | `pg_stat_checkpointer` counters before and after; a run with a checkpoint inside it is flagged and repeated |

**After each measured statement** (outside the timing):
- heap, TOAST and each index size
- `n_live_tup`, `n_dead_tup`, `n_tup_ins` / `n_tup_upd` / `n_tup_hot_upd`
- heap pages
- documents compressed or out of line (`pg_column_compression`, `pg_column_toast_chunk_id`)

**Normalisation of full-page images:** before every measured statement the table is reset, then
`VACUUM (ANALYZE)` runs on the `_w` table, followed by `CHECKPOINT`. Every run therefore starts right after a
checkpoint, so the first change to each page writes a full-page image in every run, for both types alike. This is
reported as part of the measured cost, not hidden.

## 8. Fair comparison methodology

| Aspect | Rule |
|---|---|
| Same data | identical input text (`canonical_doc`), identical row sets, identical expected new text; the same statement text apart from table name and cast |
| Same structures | identical table definitions and index definitions per configuration (catalog-checked) |
| Same starting state | per measured statement:<br>1. `TRUNCATE`<br>2. bulk load in `log_id` order<br>3. index (re)build as defined for the experiment<br>4. `VACUUM (ANALYZE)`<br>5. `CHECKPOINT`<br><br>Reset time is not measured |
| Session settings | `jit = off`, `max_parallel_workers_per_gather = 0`, `max_parallel_maintenance_workers = 0`, `maintenance_work_mem = 64MB`, `TimeZone = 'UTC'`, `track_io_timing = on`, `track_wal_io_timing = on`. `synchronous_commit`, `full_page_writes` and `wal_compression` stay at the server values and are recorded (no `ALTER SYSTEM`) |
| Repetitions and order | 3 warm-up + 15 measured runs per statement × type × configuration. json/jsonb order alternates by round (ABBA), and the configurations of a statement are interleaved within each round |
| Second session | repeated only for series whose median is below 0.1 ms, as the Step 6A rule requires |
| Rule | the Step 6A rule on execution time (non-overlapping IQRs **and** at least 10 % difference; below 0.1 ms confirmed in the second session). WAL records, bytes and full-page images are near-deterministic: medians and min–max are reported, and a difference counts as consistent when the min–max ranges do not overlap |
| Head-to-head vs separate | **head-to-head:** W1, W1b, UA-1 … UA-3 in X-0 and X-1.<br>**separate:** GIN write cost (X-2 … X-4, jsonb only), UB update mechanisms |
| Validity of cluster-wide counters | other active client sessions must be 0 (recorded per run); a run whose `pg_stat_wal` delta differs from its EXPLAIN WAL bytes plus commit record by more than 1 % is flagged |
| Scope of results | 5,000 documents of about 1.7 kB, single client, local disk, current durability settings. Not covered: concurrency, group commit, replication, larger or TOAST-out-of-line documents |

## 9. Correctness verification

| When | Checks |
|---|---|
| Staging | `canonical_doc` holds 5,000 rows with md5 `aeaef323…` and 8,416,033 bytes; every `doc_text` is a JSON object with unique keys. Every `expected_update.new_text` has exactly one substitution, and `new_text::jsonb = jsonb_set(doc_text::jsonb, path, value)` (two independent derivations agree); row counts 238 / 238 / 5,000 per variant |
| After every INSERT | 5,000 rows; json: md5 of the stored texts = canonical md5; jsonb: `doc = doc_text::jsonb` for all rows; `json::jsonb = jsonb` between the two `_w` tables |
| After every UPDATE | updated row count = expected. Updated rows equal the expected document:<br>• UA and UB-json-text: json text exact<br>• UB-json-cast: semantic `doc::jsonb = new_text::jsonb` (the text difference is recorded)<br>• jsonb: equality<br>Untouched rows are unchanged; still 5,000 rows, unique `log_id` |
| Index correctness after writes | all indexes valid and ready. With `enable_seqscan = off`: `record_validity = 'REVIEWED'` returns exactly the updated rows and `'INVALID'` the expected remainder; the same for GIN containment in X-2 … X-4 |
| End of experiment | the isolation proofs of §3: digests, `sql/34`, `sql/38 final`, and the 6C / 6D manifests unchanged |

Every check runs after every measured round, outside the timed statement. A failed check stops the runner.

## 10. Planned implementation (not started)

| Artefact | Content |
|---|---|
| `scripts/step6e_json_write_experiment.py` | definitions (configurations, statements, variants) imported from the 6C/6D generators; `generate` and `analyze` |
| `sql/41_create_json_write_experiment.sql` | schema, staging, `_w` tables, expected updates, staging checks (the only reads of existing data) |
| `sql/42_preflight_json_write_experiment.sql` (implemented, replaces the planned `sql/42_verify_json_write_state.sql`) | preflight: fingerprint, sessions, schema objects, X-0 … X-4 definitions (index creation inside a rolled-back transaction); per-round correctness checks move to the measurement files |
| `sql/run_step6e_setup_preflight.ps1` (implemented) | static checks, manifests, digests, `sql/34` / `sql/38`, setup (`sql/41`) and preflight (`sql/42`) only; no measurement |
| `sql/43_measure_json_writes.sql` | resets and measured writes, confined to `log_regex_json_write` |
| `sql/run_step6e_json_writes.ps1` | static checks, manifests, digests, sessions, verification, analysis |
| `analysis/step6/step6e_*` | raw EXPLAIN output, WAL/IO deltas, CSV summaries |
| `docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment.md` | results report (no final conclusion; that is Step 6F) |

**Estimated cost:** about 40 series × 19 runs, each preceded by a reset of about 1–2 s, so roughly 20–40 minutes for
one session. WAL generated is several GB in total; it is recycled with `max_wal_size` 1 GB, and the explicit
checkpoints keep it bounded.

## 11. Decisions for review

1. Separate schema `log_regex_json_write` instead of the 6A load tables inside `log_regex_json` (§3).
2. Configurations X-0 … X-4, including a replica of the current Step 6D index set (X-4) (§4).
3. W1b as 250 row-at-a-time inserts by a server-side loop (§5).
4. Head-to-head updates as full-document replacement with identical new text (UA); type-native partial updates (UB,
   including the 6A W2 form) reported separately (§6).
5. Reset + `VACUUM (ANALYZE)` + `CHECKPOINT` before every measured statement to normalise full-page images (§7).
6. Cluster-wide WAL/IO counters used only with no other active sessions; the 4 currently connected sessions must be
   idle during measurement (§2, §8).
7. Second session only for series with a median below 0.1 ms (§8).
8. Results report renamed Step 6F.
