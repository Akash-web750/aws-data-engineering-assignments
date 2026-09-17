# Step 6B — Build the JSON and JSONB Tables and Verify Storage

**Status:** built, verified and measured (12/09/2026). Stopped for review.

`log_regex_json.access_log_json` and `log_regex_json.access_log_jsonb` hold the same 5,000 logical records, loaded from
the same minified canonical text. All 38 verification checks pass. Storage figures are in §5 and §6.

**Not done (as instructed):**
- query indexes (only the designed primary keys exist)
- `EXPLAIN ANALYZE`
- benchmarks or timings
- PostGIS

The Step 6A items that need timing (W1 load time, M-08 write cost, M-09 formatting sensitivity) are deferred to the
measurement steps.

**Unchanged:** the digest of schema `log_regex` covers every function, view, column, constraint, index, trigger, internal
trigger count, and the rows of every table (`access_log_flat` included). It is `f8042db0318656b5929c86ea1f7888d4` over
203 items before and after. `sql/27`, `sql/29` (S-01 … S-15) and `sql/31` (57 checks) pass before and after.

---

## 1. Files

| File | Role |
|---|---|
| `sql/32_create_json_experiment_tables.sql` | **new**: schema `log_regex_json` and the two tables (design §3); refuses (`LR010`) if the schema exists or the source is not complete |
| `sql/33_load_json_experiment_tables.sql` | **new**: one `REPEATABLE READ` transaction. It stages the canonical text, gates the stage, inserts the same text as `json` and as `jsonb`, gates the load, and records the input fingerprint in both table comments. Then COMMIT and `VACUUM (ANALYZE)` of the two tables (`LR011` on refusal or gate failure) |
| `sql/34_verify_json_experiment_tables.sql` | **new**: read-only verification, 38 checks (`LR012`) |
| `sql/35_measure_json_experiment_storage.sql` | **new**: read-only storage and TOAST/compression measurements |
| `sql/run_step6b_build_json_tables.ps1` | **new** runner (`-VerifyOnly`), in this order:<br>1. static checks<br>2. `log_regex` digest<br>3. source gate (`sql/27`/`29`/`31`)<br>4. `sql/32`, `sql/33`<br>5. `sql/34`, `sql/35`<br>6. source gate again<br>7. digest again |
| `analysis/step6/step6b_storage_measurements.txt` | **new**: output of `sql/35` from the final run |
| `docs/Step6B_Build_JSON_Tables_and_Storage.md` | this document |
| `docs/Step6A_JSON_vs_JSONB_Experiment_Design.md` | status line (TOAST estimate corrected, §6.4) |
| `README.md` | status and Step 6B summary |

Static checks in the runner:
- `sql/32` creates exactly the schema and the two tables.
- `sql/33` inserts only into the two tables, creates only its temporary stage and vacuums only the two tables.
- `sql/34` and `sql/35` contain no write statement.
- No script contains `DROP`, `TRUNCATE`, `DELETE`, `UPDATE`, `ALTER`, `COPY`, `CREATE INDEX` or `EXPLAIN`.
- The rebuild guards in `sql/07`/`sql/08` and the Step 3B-3 runner are still present.
- All Step 6B files are ASCII.

## 2. What was created

| Object | Details |
|---|---|
| Schema | `log_regex_json` (comment: experiment objects, no dependency on or from `log_regex`) |
| `access_log_json` | `log_id integer NOT NULL`, `doc json NOT NULL`, `PRIMARY KEY (log_id)`, `autovacuum_enabled = false` |
| `access_log_jsonb` | `log_id integer NOT NULL`, `doc jsonb NOT NULL`, `PRIMARY KEY (log_id)`, `autovacuum_enabled = false` |
| Identical settings | column storage `x` (extended) for both, compression = server default (`pglz`), default fillfactor |
| Indexes | the two primary keys only (`access_log_json_pkey`, `access_log_jsonb_pkey`) |
| Automatic | one TOAST table per table (PostgreSQL creates them for variable-length columns); both remain empty |
| Not created | foreign keys, CHECKs, triggers, functions, views, sequences, query indexes |
| Table comments | the canonical input fingerprint: 5,000 documents from run 14, 8,416,033 bytes, md5 `aeaef32371fa8143c088d4fdce9f6e0d` (texts in `log_id` order joined by LF) |

## 3. How the tables were loaded (`sql/33`)

1. **Guard:** both tables exist and are empty; `access_log_flat` holds one row per raw log from one run.
2. **Stage:** one canonical text per `access_log_flat` row.
   - Minified, keys in design order, 82 keys / 70 leaves, every key present.
   - SQL NULL becomes JSON `null`.
   - Strings are escaped by `to_json()`.
   - Timestamps are fixed-width ISO (`YYYY-MM-DDTHH24:MI:SS.US`, UTC with `Z`); offsets are integer minutes; coordinates
     are `numeric(10,7)` text; the IP address uses `host()`.
3. **Stage gate:** 5,000 texts for 5,000 flat rows. Every text `IS JSON OBJECT WITH UNIQUE KEYS`. All UTC offsets are
   whole minutes.
4. **Load:** `INSERT … SELECT log_id, doc_text::json` and `INSERT … SELECT log_id, doc_text::jsonb` from the **same**
   staged text, `ORDER BY log_id`.
5. **Load gate:**
   - 5,000 rows each
   - `log_id` sets equal to the flat table
   - stored `json` text byte-identical to the staged text for all 5,000 rows
   - `jsonb` = `staged text::jsonb` = `json::jsonb` for all 5,000 rows
6. **Commit and maintenance:** the input fingerprint is recorded in both comments, then COMMIT, then
   `VACUUM (ANALYZE)` on both tables.

## 4. Verification results (`sql/34`, 38 checks, all PASS)

| # | Requested | Checks | Result |
|---:|---|---|---|
| 1 | exactly 5,000 rows in each table | B-01a–c | `access_log_flat` 5,000 = raw logs; `access_log_json` 5,000; `access_log_jsonb` 5,000 |
| 2 | identical `log_id` sets | B-02a–c | 0 differences json vs flat, jsonb vs flat, json vs jsonb |
| 3 | exact input JSON text before conversion | load gate, B-03a–e | See the list below |
| 4 | JSON and JSONB semantically equivalent | load gate, B-04 | `json::jsonb = jsonb` for 5,000 / 5,000 |
| 5 | all 70 values round-trip to `access_log_flat` | B-05, B-05a–c (each table) | See the list below |
| 6 | no duplicate JSON keys | stage gate, B-06a–b | 5,000 / 5,000 texts `IS JSON OBJECT WITH UNIQUE KEYS`; 0 objects with a repeated key (13 objects per document checked with `json_object_keys`, which returns duplicates) |
| 7 | expected key count / structure | B-07a–e | See the list below |
| 8 | escaping of quotes, backslashes, non-ASCII | B-08a–d | See the list below |
| — | MISSING = JSON null with key present | B-09 (each table) | 71,219 JSON null leaves with their key present = 71,219 SQL NULL cells in the 70 flat columns, in both tables |
| — | isolation | B-10a–f | See the list below |

Details for the multi-part checks:

**Item 3: exact input text**
- Stored `json` text = staged text for all 5,000 rows (load gate).
- md5 of the stored `json` texts = the recorded input md5 `aeaef323…`; bytes = 8,416,033. Both comments record the same
  input.
- 5,000 / 5,000 `json` texts reduce to the designed minified skeleton. Keys become `<key>`, strings `<>`, scalars and
  arrays `#`, and the result must equal the design string exactly. That proves key names, key order, nesting, no
  whitespace and no extra keys.
- `doc.log_id` / `doc.run_id` match the row: 0 differences.

**Item 5: round trip of all 70 values** (checked for `json` and `jsonb` separately, 350,000 leaf values each)
- Key present with the designed JSON type, `null` exactly where the flat value is SQL NULL: 0 mismatches.
- 69 scalar leaves equal their exact text form: 0 mismatches.
- All 70 leaves cast back (`integer`, `bigint`, `boolean`, `text[]`, `timestamp(6)`, `timestamptz`, minutes →
  `interval`, `numeric`, `inet`, `smallint`) `IS NOT DISTINCT FROM` the flat column: 0 mismatches.

**Item 7: key count and structure**
- The design has 82 keys in 13 objects.
- 5,000 / 5,000 `json` and 5,000 / 5,000 `jsonb` documents have exactly 82 keys.
- Keys per object equal the design: in design order for `json`, as sets for `jsonb` (which reorders keys by design).

**Item 8: escaping**
- 558 values with `"`, 100 with `\` and 566 with non-ASCII characters: the escaped form is present in the `json` text,
  and `->>` returns the exact flat value in both `json` and `jsonb`.
- The same holds for all 47,374 stored values.

**Isolation (B-10)**
- `log_regex_json` holds exactly `access_log_json`, `access_log_jsonb` and their two primary key indexes.
- No other constraints, foreign keys, triggers, functions, views or sequences.
- 0 dependencies between `log_regex` and `log_regex_json`.

Escaping examples (shortest value of each kind):

| Kind | log_id | Field | Flat value | In the `json` text | `->>` equal (json / jsonb) |
|---|---:|---|---|---|---|
| backslash | 534 | resource_url | `\\nas02\finance\reports\Q4\` | `"\\\\nas02\\finance\\reports\\Q4\\"` | t / t |
| double quote | 6 | longitude | `0°05'29.4"W` | `"0°05'29.4\"W"` | t / t |
| non-ASCII | 4047 | status | `✓` | `"✓"` (kept as UTF-8, not `\u` escaped) | t / t |

## 5. Storage measurements (item 9)

All figures come from `analysis/step6/step6b_storage_measurements.txt`, taken after `VACUUM (ANALYZE)`, with no
secondary index and no dead tuples (`n_dead_tup` = 0). PostgreSQL 17.9, 8 kB pages, `default_toast_compression` = pglz.

### 5.1 Relations (bytes)

| | `access_log_json` | `access_log_jsonb` |
|---|---:|---:|
| heap (main fork) | 10,240,000 (1,250 pages) | 8,036,352 (981 pages) |
| free space map / visibility map | 24,576 / 8,192 | 24,576 / 8,192 |
| TOAST table / TOAST index | 0 / 8,192 | 0 / 8,192 |
| table (`pg_table_size`) | 10,280,960 | 8,077,312 |
| primary key index | 131,072 | 131,072 |
| **total** | **10,412,032** (10,168 kB) | **8,208,384** (8,016 kB) |
| rows per heap page | 4.00 | 5.10 |
| heap bytes per row | 2,048.0 | 1,607.3 |
| heap minus row bytes (page and free-space overhead) | 1,665,934 | 676,669 |

Reference only, not part of the comparison: `access_log_flat` heap 6,283,264 bytes (767 pages), total 6,586,368.

### 5.2 Per document (bytes)

| Measure | Type | min | p25 | p50 | p75 | p90 | p99 | max | avg | sum |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| stored datum (`pg_column_size`) | json | 1,426 | 1,657 | 1,683 | 1,714 | 1,746 | 1,808 | 1,883 | 1,686.8 | 8,434,066 |
| stored datum (`pg_column_size`) | jsonb | 974 | 1,042 | 1,108 | 1,968 | 1,992 | 2,004 | 2,004 | 1,443.9 | 7,219,683 |
| uncompressed datum | json | 1,426 | 1,657 | 1,683 | 1,714 | — | 1,808 | 3,744 | 1,687.2 | 8,436,033 |
| uncompressed datum | jsonb | 1,600 | 1,980 | 2,016 | 2,052 | — | 2,152 | 4,056 | 2,017.0 | 10,084,876 |
| whole row | json | 1,454 | 1,685 | 1,711 | 1,742 | 1,774 | 1,836 | 1,911 | 1,714.8 | 8,574,066 |
| whole row | jsonb | 1,002 | 1,070 | 1,136 | 1,996 | 2,020 | 2,032 | 2,032 | 1,471.9 | 7,359,683 |
| output text (`doc::text`) | json | 1,422 | 1,653 | 1,679 | 1,710 | 1,742 | 1,804 | 3,740 | 1,683.2 | 8,416,033 |
| output text (`doc::text`) | jsonb | 1,573 | 1,804 | 1,830 | 1,861 | 1,893 | 1,955 | 3,891 | 1,834.2 | 9,171,034 |

How to read these:
- **Canonical input:** 8,416,033 bytes (8,415,454 characters) for both types. The `json` output text equals it exactly.
  The `jsonb` output text is re-spaced (`": "`, `", "`), 151–152 bytes longer per document.
- **Uncompressed datum:** `pg_column_size` of the value rebuilt in memory from its text (never compressed). It isolates
  the format size from TOAST compression.
- **Per document, `jsonb` stored minus `json` stored:** min −720, median −633, max +362 bytes, total −1,214,383.
  `jsonb` is larger for 2,121 documents and smaller for 2,879.
- **Per document, `jsonb` uncompressed minus `json` uncompressed:** +174 to +366 bytes for every document.

Stored-size distribution (documents per 100-byte bucket):

| Bytes | json | jsonb |
|---|---:|---:|
| 900–999 | 0 | 114 |
| 1,000–1,099 | 0 | 2,299 |
| 1,100–1,199 | 0 | 458 |
| 1,200–1,299 | 0 | 8 |
| 1,400–1,499 | 9 | 0 |
| 1,500–1,599 | 59 | 0 |
| 1,600–1,699 | 3,196 | 9 |
| 1,700–1,799 | 1,662 | 0 |
| 1,800–1,899 | 74 | 39 |
| 1,900–1,999 | 0 | 1,784 |
| 2,000–2,099 | 0 | 289 |

## 6. TOAST, compression and out-of-line storage (item 10)

### 6.1 Observations

| | json | jsonb |
|---|---:|---:|
| documents compressed inline (`pg_column_compression`) | **1** (pglz) | **2,880** (pglz) |
| documents stored out of line (`pg_column_toast_chunk_id`) | 0 | 0 |
| TOAST table chunks / values / chunk bytes | 0 / 0 / 0 | 0 / 0 / 0 |
| documents with at least 2,000 bytes of text | 1 | 4 |
| rows of at least 2,032 bytes as stored | 0 (largest 1,911) | 138 (largest 2,032) |

### 6.2 The two `jsonb` groups

| jsonb group | Docs | avg json uncompressed | avg jsonb uncompressed | avg json stored | avg jsonb stored | jsonb row range | stored sum json / jsonb |
|---|---:|---:|---:|---:|---:|---|---|
| compressed | 2,880 | 1,715.7 | 2,053.0 | 1,715.1 | 1,058.2 | 1,002–2,004 | 4,939,374 / 3,047,535 |
| not compressed | 2,120 | 1,648.4 | 1,968.0 | 1,648.4 | 1,968.0 | 1,628–2,032 | 3,494,692 / 4,172,148 |

The one compressed `json` document is `log_id` 4864, the row with the 2,107-byte URL and the only document with more
than 2,000 bytes of text (3,740 bytes). It is stored as 1,777 bytes in `json` and 1,976 bytes in `jsonb`, both
pglz-compressed.

### 6.3 What the figures show (descriptive, not a conclusion)

- **Uncompressed, `jsonb` is larger** for every document (+174 to +366 bytes; total +19.5 %: 10,084,876 vs 8,436,033).
- **Why stored sizes flip:** PostgreSQL tries to compress a row inline once it exceeds the TOAST threshold of about
  2,032 bytes on 8 kB pages. Nearly all `json` rows (about 1,711 bytes) stay below it and are stored uncompressed. The
  `jsonb` rows of 2,880 documents exceed it (average uncompressed 2,053 bytes) and are pglz-compressed inline to about
  1,058 bytes. 138 `jsonb` rows sit exactly at 2,032 bytes, just below the point where compression is attempted.
- **Result:** `jsonb` stores 14.4 % fewer document bytes (7,219,683 vs 8,434,066), and its heap is 21.5 % smaller
  (8,036,352 vs 10,240,000). Page packing adds to this: `json` fits exactly 4 rows per page, and its heap holds 1,665,934 bytes
  beyond the row bytes (page headers, line pointers and free space; `jsonb`: 676,669 at 5.10 rows per page).
- **This is a threshold effect of this dataset,** not a general property of either type. A small change in document
  size, TOAST threshold or compression setting would move documents across the boundary. Compressed documents must be
  decompressed when read; any effect on query cost belongs to the later measurement steps and was not measured here.
- **No document is stored out of line** in either table; both TOAST tables are empty.

### 6.4 Correction to the Step 6A estimate

Step 6A §0 expected documents to stay "mostly far below the ~2 kB TOAST threshold". That estimate counted only the
extracted value bytes (median 159) and source bytes (median 128), not the 82 key names and JSON syntax. Measured:
- canonical text averages 1,683 bytes
- uncompressed `jsonb` averages 2,017 bytes
- 2,880 `jsonb` documents (57.6 %) are compressed inline; none is stored out of line

The scope statement of Step 6A §9 rule 7 therefore reads, for later steps: *documents near the TOAST threshold; about 58
% of the `jsonb` documents compressed inline, `json` documents almost all uncompressed; none out of line.*

## 7. Run log

| Run | Result |
|---|---|
| Rolled-back harness, 1st attempt | `sql/32` created the tables; the `sql/33` stage and load gates passed (8,416,033 bytes, md5 `aeaef323…`). `sql/34` stopped with `operator is not unique: "char" \|\| unknown` (`relkind` concatenation); fixed with `::text`. Nothing persisted |
| Rolled-back harness, 2nd attempt | exit 0 in 29 s: create, load, gates, 38 checks and measurements inside one transaction, then `ROLLBACK`; schema still absent |
| Runner (build) | exit 0 in 52 s: static checks, digest, source gate, `sql/32`, `sql/33` (with VACUUM ANALYZE), `sql/34` 38 / 38, `sql/35`, source gate, digest unchanged |
| Measurement script refinement | the first `sql/35` listing printed every document with at least 1,500 bytes of text (768 kB of output). It now lists only compressed or out-of-line documents (count plus the first 20). Two read-only sections were added: uncompressed datum size and the `jsonb` compressed/uncompressed split. No data or objects changed |
| Runner `-VerifyOnly` (final) | exit 0 in 38 s: static checks, digest `f8042db0…` (203 items) unchanged, source gate, 38 / 38 checks, measurements rewritten (10,765 bytes) |

## 8. Next step (not started)

Step 6C per the design: query workload Q01–Q21 and C1–C4 without secondary indexes, using the EXPLAIN protocol of Step 6A
§7. The TOAST observation above (§6.4) is part of the context for interpreting those results.
