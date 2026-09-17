# Step 6F — Final JSON vs JSONB Comparison and Results Report

**Status:** consolidated report (13/09/2026). **No new experiment was run for this step.** Every figure comes from
the completed Step 6B–6E reports and their analysis files. PostGIS had not been started at the time of this report (it
followed in Steps 7A–7F).

**Sources:**

| Step | Report | Measured |
|---|---|---|
| 6B | [Step6B_Build_JSON_Tables_and_Storage.md](Step6B_Build_JSON_Tables_and_Storage.md) | storage, TOAST and compression of the two tables; 38 equivalence checks |
| 6C | [Step6C_JSON_vs_JSONB_Query_Experiment.md](Step6C_JSON_vs_JSONB_Query_Experiment.md) | 25 read statements without secondary indexes, 2 sessions, 1,900 executions |
| 6D | [Step6D_JSON_vs_JSONB_Index_Experiment.md](Step6D_JSON_vs_JSONB_Index_Experiment.md) | identical btree expression indexes (fair), GIN indexes (jsonb only), 4,028 executions, 37 builds |
| 6E | [Step6E_JSON_vs_JSONB_Write_Update_Experiment.md](Step6E_JSON_vs_JSONB_Write_Update_Experiment.md) | inserts, updates, WAL and index maintenance in 5 index configurations, 756 attempts |

Design and rules: [Step6A_JSON_vs_JSONB_Experiment_Design.md](Step6A_JSON_vs_JSONB_Experiment_Design.md) and
[Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md](Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md).

---

## 1. What was compared, and under which conditions

**Data.**
- 5,000 access-log records from parser run 14.
- Each record is one JSON document with 82 keys and 70 leaf values; MISSING values are JSON `null` with the key
  present.
- One canonical minified text was used for both types: 8,416,033 bytes, md5 `aeaef323…`, about 1,683 bytes per
  document.
- `json` stores that text byte for byte. `jsonb` stores the same logical documents (`json::jsonb = jsonb` for 5,000 /
  5,000).
- All 70 values round-trip to the source table on both types.

**Environment.**
- PostgreSQL 17.9 on a Windows 11 laptop (Intel i7-9850H), 8 kB pages, `default_toast_compression` pglz.
- `shared_buffers` 128 MB, `work_mem` 4 MB.
- `synchronous_commit` on, `full_page_writes` on, `wal_compression` off, `data_checksums` off.
- Sessions: `jit` off, no parallel workers.
- Every measurement used a warm cache and a single client.

**Correctness.** Every timing counted only after its result was verified:
- 6C / 6D: every query result on both types equals the `access_log_flat` oracle, with default and forced plans.
- 6E: every inserted or updated document equals the expected document, index answers are checked, and 756 / 756
  attempts passed.

The source data (`log_regex` digest `f8042db0…`) and the Step 6B documents were never modified.

**Rule for timing differences (Step 6A §9).**
- A difference is *measurable* only if the interquartile ranges of 15 runs do not overlap **and** the medians differ by
  at least 10 %. Below 0.1 ms, the same direction must repeat in a second session.
- Otherwise it is reported as *no measurable difference*.
- WAL, buffers and growth figures are near-deterministic; they are reported as medians, and a difference counts as
  consistent when the min–max ranges do not overlap.

**Separation.** Sections 2–7 and 9 hold the fair **json vs jsonb** comparisons: identical SQL, identical indexes,
interleaved runs. Section 8 holds **jsonb-only capabilities**, which have no json counterpart. They are never used as a
json vs jsonb verdict.

## 2. Storage (Step 6B; indexes Step 6D)

| Measure | json | jsonb | Difference |
|---|---:|---:|---|
| Uncompressed document size (sum) | 8,436,033 | 10,084,876 | jsonb +19.5 %; +174 to +366 bytes for **every** document |
| Stored document bytes (`pg_column_size`, sum) | 8,434,066 | 7,219,683 | jsonb −14.4 % |
| Documents compressed inline (pglz) | 1 | 2,880 (57.6 %) | — |
| Documents stored out of line (TOAST) | 0 | 0 | TOAST tables empty |
| Heap | 10,240,000 (1,250 pages, 4.00 rows / page) | 8,036,352 (981 pages, 5.10 rows / page) | jsonb −21.5 % |
| Total with primary key only | 10,412,032 | 8,208,384 | jsonb −21.2 % |
| Output text (`doc::text`, sum) | 8,416,033 (= canonical input) | 9,171,034 | jsonb re-spaced, +151–152 bytes per document |
| Key order and spacing on output | preserved exactly | reordered by jsonb rules, re-spaced | — |
| Five btree expression indexes (I-1) | 499,712 | 499,712 | identical |
| Total with all designed indexes | 10,911,744 (primary key + I-1) | 16,957,440 (primary key + I-1 + both GIN indexes) | GIN is jsonb only (section 8) |

**Why the stored sizes invert.**
- PostgreSQL compresses a row inline once it exceeds about 2,032 bytes. Almost all json rows (about 1,711 bytes) stay
  below that and are stored uncompressed.
- 2,880 jsonb rows exceed it (about 2,053 bytes uncompressed) and are compressed to about 1,058 bytes.
- This is a **threshold effect of this dataset**. Documents slightly smaller or larger, another compression method or
  another page size could change the result. Only this state was measured.

## 3. Document extraction and query performance without secondary indexes (Step 6C)

Both types got the same plan shape and the same row estimates for all 25 statements (one exception: the Q17/Q18
group-count estimate), and returned identical results.

| Access pattern (batch 1 medians, ms) | json | jsonb | Result |
|---|---:|---:|---|
| Q01 one whole document by primary key | 0.012 | 0.030 | measurable: **json faster** (confirmed in batch 2) |
| Q02 all 5,000 whole documents | 2.956 | 68.709 | measurable: **json faster** (jsonb detail run: 67.4 ms of serialisation to text) |
| Q03 one nested value by primary key | 0.035 | 0.017 | measurable: **jsonb faster** (confirmed in batch 2) |
| Q04 one `record` value, all rows | 57.8 | 11.1 | measurable: **jsonb faster** |
| Q05 ten values per row | 1,069.9 | 81.9 | measurable: **jsonb faster** |
| Q06 all 70 values, cast back to column types | 7,413.2 | 592.2 | measurable: **jsonb faster** |
| Q07–Q16 filters (equality, integer, numeric and time ranges, `LIKE`, array membership, null test, conjunction) | 56.7–184.4 | 10.3–20.1 | measurable: **jsonb faster** for all 14 statements |
| Q17–Q19 group-bys and aggregates | 105.0–393.8 | 11.6–39.5 | measurable: **jsonb faster** |
| Q20 `JSON_VALUE` / Q21 `JSON_EXISTS` | 126.5 / 160.3 | 12.8 / 14.9 | measurable: **jsonb faster** |

**Counts.**
- json is measurably faster in 2 statements, both returning whole documents.
- jsonb is measurably faster in 23 statements, all extracting values; the ratio is 0.08–0.21 except Q03 (0.49).
- No statement shows "no measurable difference".
- Batch 2 reproduced every direction.
- Planning time showed no measurable difference for any statement.

**Shape of the cost.**
- **json:** extraction time grew by about 50 ms per `->` step over 5,000 documents. This is consistent with the text
  being re-read at every step.
- **jsonb:** a floor of about 10 ms, then about 7–8 ms per additional extracted value.
- **Whole documents:** returning them costs jsonb a conversion from its binary form to text; json returns its stored
  text.

## 4. Fair B-tree index comparison (Step 6D, configuration I-1)

The same five btree expression indexes (`text_ops`, `int4_ops`, `numeric_ops`) were built on both tables; the catalog
definitions are identical after name normalisation. Plans and estimates were identical on both types.

| Situation | Statements | json vs jsonb |
|---|---|---|
| The index answers the predicate; no document is read | Q07, Q08, Q10, Q11a, Q12a, Q12b, Q12c (0.015–0.237 ms) | **no measurable difference** in all 7 (sub-0.1 ms cases also in batch 2) |
| The index narrows the rows, a heap filter still reads documents | Q16 | measurable: **jsonb faster** (5.735 vs 1.420 ms) |
| The planner keeps a sequential scan despite the index | Q11b (184.0 vs 21.6 ms), Q17 (104.3 vs 11.6 ms) | measurable: **jsonb faster** |
| No index involved (control) | Q09 (60.3 vs 12.5 ms) | measurable: **jsonb faster** |

| Index build and storage | json | jsonb |
|---|---|---|
| Build time per index (median of 3) | 66.3–122.4 ms | 16.3–20.6 ms |
| Index size | identical (57,344–180,224 bytes per index) | identical |
| Build WAL | identical within 48 bytes | identical within 48 bytes |

**Index effect per type (same-step control → I-1):** the 8 selective statements became about 14× (Q16) to 9,600×
(Q12a) faster on json, and about 8.5× to 860× faster on jsonb.

**Planner observation (both types).**
- For Q11b the planner costed the sequential scan and the bitmap index path as nearly equal (json 1,450 vs 1,453).
- The forced index path actually took 1.236 ms on json against 184.0 ms, and 1.137 ms on jsonb against 21.6 ms.
- The cost model does not reflect the per-row extraction cost, and the consequence is much larger for json.

## 5. INSERT cost (Step 6E)

Server execution time, median [IQR]. Every result was also measurable in the same direction on client-observed
transaction time.

| Statement | Config | json | jsonb | jsonb / json | Result |
|---|---|---|---|---:|---|
| W1: `INSERT … SELECT` of 5,000 documents into an empty table | X-0 (primary key) | 165.7 [150.1–191.1] ms | 301.8 [291.7–361.1] ms | 1.82 | measurable: **json faster** |
| W1 | X-1 (+ 5 btree expression indexes) | 731.5 [670.8–861.4] ms | 371.3 [339.8–440.7] ms | 0.51 | measurable: **jsonb faster** |
| W1b: 250 single-row inserts into 4,750 rows | X-0 | 5.13 ms (0.021 ms / row) | 12.94 ms (0.052 ms / row) | 2.52 (session 2: 2.31) | measurable, confirmed: **json faster** |
| W1b | X-1 | 33.62 ms (0.134 ms / row) | 18.16 ms (0.073 ms / row) | 0.54 (session 2: 0.59) | measurable, confirmed: **jsonb faster** |

## 6. UPDATE cost — full-document replacement (Step 6E)

Both types received the identical new document text for the identical rows.

| Statement | Config | json (ms) | jsonb (ms) | jsonb / json | Result |
|---|---|---:|---:|---:|---|
| UA-1: 238 rows, indexed path changed | X-0 | 19.5 | 42.0 | 2.15 | measurable: **json faster** |
| UA-1 | X-1 | 93.4 | 51.2 | 0.55 | measurable: **jsonb faster** |
| UA-2: 238 rows, non-indexed path changed | X-0 | 19.5 | 39.2 | 2.01 | measurable: **json faster** |
| UA-2 | X-1 | 88.9 | 48.4 | 0.55 | measurable: **jsonb faster** |
| UA-3: 5,000 rows | X-0 | 760.3 | 983.3 | 1.29 | measurable: **json faster** |
| UA-3 | X-1 | 1,912.1 | 1,120.8 | 0.59 | measurable: **jsonb faster** |

**Row-version behaviour (identical on both types).**
- Every updated row left a dead tuple: 238 or 5,000.
- HOT updates happened only without secondary indexes: 4 of 5,000 in UA-3, 0–1 of 238 in UA-1/UA-2. With the
  expression indexes on `doc` there were none.
- Nearly every new version went to another page (237–238 and 4,996 new-page updates). UA-3 doubled the heap:
  json 1,250 → 2,498 pages, jsonb 981 → 1,962.
- With X-1, changing a non-indexed path (UA-2) cost the same as changing an indexed one (UA-1): zero HOT updates, the
  same index growth, WAL within 0.2 %. Every change to `doc` updates all the expression indexes.

**Where the time goes.** The UA-1 detail runs (single runs with `TIMING ON`) show:
- json X-1 spends about 150 of 172 ms maintaining the indexes after the join.
- jsonb spends 27–33 ms converting the input text (`::jsonb`) and about 58 ms in total, with or without the indexes.

## 7. WAL and index/write overhead (Step 6E; builds Step 6D)

**WAL per statement** (EXPLAIN WAL bytes; W1b: LSN difference around the loop; medians):

| Statement | X-0 json / jsonb (ratio) | X-1 json / jsonb (ratio) | Full-page images X-0 / X-1 (json, jsonb) |
|---|---|---|---|
| W1 | 9,059,086 / 7,844,703 (0.866) | 10,955,870 / 9,741,849 (0.889) | 0 (new pages) |
| W1b | 558,376 / 500,608 (0.897) | 957,016 / 876,992 (0.916) | 15 / 14; 62 / 58 |
| UA-1 | 2,098,202 / 2,225,158 (1.061) | 2,484,878 / 2,626,690 (1.057) | 239 / 240; 284 / 286 |
| UA-2 | 2,103,892 / 2,227,253 (1.059) | 2,488,362 / 2,626,625 (1.056) | 240 / 240; 285 / 286 |
| UA-3 | 18,232,798 / 15,788,614 (0.866) | 20,498,141 / 18,046,214 (0.880) | 1,265 / 996; 1,319 / 1,048 |

- **Whole-table writes** (W1, UA-3) and **single-row inserts:** jsonb wrote 8–13 % less WAL. For W1 and UA-3 it also
  dirtied about 20 % fewer blocks; W1b has no EXPLAIN buffer counts. This follows the smaller stored documents.
- **238-row updates:** jsonb wrote 5.6–6.1 % more WAL with almost equal full-page image counts. The cause was not
  isolated; larger full-page images of fuller jsonb pages are a plausible, unverified explanation.

**Overhead of the five btree expression indexes (X-0 → X-1, same type):**

| Statement | json time | jsonb time | WAL bytes json / jsonb | WAL records | Index growth |
|---|---|---|---|---|---|
| W1 | ×4.42 | ×1.23 (not measurable) | ×1.21 / ×1.24 | ×3.52 | 540,672 |
| W1b | ×6.55 | ×1.40 | ×1.71 / ×1.75 | ×3.50 | 16,384 |
| UA-1 | ×4.78 | ×1.22 | ×1.18 / ×1.18 | ×2.70 | 8,192 |
| UA-2 | ×4.56 | ×1.24 (not measurable) | ×1.18 / ×1.18 | ×2.69 | 8,192 |
| UA-3 | ×2.52 | ×1.14 | ×1.12 / ×1.14 | ×2.69 | 442,368 |

- **The same on both types:** WAL, index growth and index sizes — just as the Step 6D builds had identical sizes and
  WAL.
- **Different:** the **time** to maintain the indexes, 2.5–6.6× for json and 1.1–1.4× for jsonb. This matches the
  Step 6D build times (json 66–122 ms, jsonb 16–21 ms per index).
- Planning time for writes was 0.05 ms (bulk insert) and 0.31–0.44 ms (updates) on both types; it was not formally
  compared.

## 8. JSONB-only capabilities (separate — not a json vs jsonb comparison)

**Existence.** json has no `@>`, `?`, `?|`, `?&`, `@?` or `@@` operator, no GIN operator class and no `jsonb_set`.
These rows therefore describe what jsonb adds, and at what measured cost.

**Read benefit** (Step 6D; batch 1 medians on `access_log_jsonb`):

| Statement (rows) | No GIN | GIN `jsonb_ops` | GIN `jsonb_path_ops` |
|---|---:|---:|---:|
| C1 `@>` record_validity BROKEN (12) | 10.230 ms | 0.112 ms | 0.027 ms |
| C1b `@>` status code 404 (30) | 11.042 | 0.273 | 0.125 |
| C1c `@>` array element (3) | 10.616 | 0.093 | 0.030 |
| C1d `@>` entity_type BOT (225) | 10.947 | 0.803 | 0.528 |
| C3 `@?` jsonpath (30) | 11.644 | 0.215 | 0.104 |
| C3b `@@` jsonpath (12) | 10.831 | 0.093 | 0.029 |
| C2 `?` on a nested expression (3) | 10.846 | not indexable (Seq Scan) | not indexable |
| Q21 `JSON_EXISTS` (30) | 10.982 | not indexable (Seq Scan) | not indexable |

**GIN index cost:**

| | `jsonb_ops` | `jsonb_path_ops` |
|---|---|---|
| Size after `CREATE INDEX` | 4,521,984 bytes (56 % of the jsonb heap) | 3,727,360 bytes (46 %) |
| Build (median) / build WAL | 554.4 ms / 2,413,808 bytes | 243.7 ms / 1,958,528 bytes |
| W1 bulk insert vs X-1 (6E) | ×3.49 time, ×2.82 WAL, index growth +8,142,848 | ×2.22 time, ×2.09 WAL, +6,873,088 |
| UA-1 238-row update vs X-1 (6E) | ×1.96 time, ×1.18 WAL, +647,168 | ×1.51 time, ×1.11 WAL, +401,408 |
| Both GIN indexes (X-4, the current Step 6D set) vs X-1 (6E) | W1 ×4.33 time, ×3.90 WAL; W1b ×2.43; UA-1 ×2.43; UA-2 ×2.29; UA-3 ×3.05 time, ×2.65 WAL | — |

- `jsonb_path_ops` was smaller, faster to build, faster to query, and cheaper to maintain in every measured statement.
- `jsonb_ops` additionally supports the key-existence operators; no statement here could use them.
- GIN indexes grown by inserts (with `fastupdate`) were about 1.7× the size of a `CREATE INDEX` build. The pending-list
  state was not inspected.

**Not measured:** whole-document equality (C4), and a GIN index on `doc::jsonb` of the json table (I-4).

## 9. Partial-update observations (Step 6E; separate, mechanism-specific)

A partial update has no identical form on both types, so these results are not a type verdict (X-1; the same rows as
the full replacements).

| | `jsonb_set` on jsonb | text `regexp_replace` on json | `jsonb_set(doc::jsonb)::json` on json |
|---|---|---|---|
| 238 rows | 39.2 ms; WAL 2,626,690 | 106.8 ms; WAL 2,484,878 | 131.6 ms (×1.23 of the text form, measurable); WAL 2,520,817 |
| 5,000 rows | 932.8 ms; WAL 18,045,847 | 1,933.7 ms; WAL 20,497,306 | 2,496.2 ms (×1.29, measurable); WAL 21,247,117 |
| Stored result | expected document | canonical text preserved exactly | semantically equal; every text differs from canonical (jsonb formatting), +9.0 % text bytes; compressed json documents 1 → 4 (5,000 rows) |

- `jsonb_set` on jsonb and the text rewrite on json produce the same documents as the full replacements of the same
  type. Their WAL was identical to it for 238 rows and within 0.01 % for 5,000 rows. The cast form produces a different
  text.
- Round-tripping json through jsonb loses the canonical text form, and it was the slowest mechanism measured.

## 10. Consolidated comparison

**Fair json vs jsonb comparisons** (measured results only; "=" means no measurable difference or identical):

| Area | Result in this experiment | Favours |
|---|---|---|
| Uncompressed format size | jsonb +19.5 % | json |
| Stored size / heap (TOAST threshold effect of this dataset) | jsonb −14.4 % stored bytes, −21.5 % heap | jsonb |
| Exact text preservation (key order, spacing) | json byte-identical; jsonb normalised | json |
| Returning whole documents | Q01 ×2.5, Q02 ×23 faster on json | json |
| Extracting values, filters, aggregates, SQL/JSON functions without indexes | 23 / 23 statements faster on jsonb (ratios 0.08–0.49) | jsonb |
| Planning time (reads) | no measurable difference | = |
| Queries answered by identical btree expression indexes | no measurable difference in 7 / 7 | = |
| Indexed plans that still read documents | jsonb faster (Q16 0.25; sequential scans 0.11–0.21) | jsonb |
| Btree index size and build WAL | identical | = |
| Btree index build time | json 66–122 ms vs jsonb 16–21 ms | jsonb |
| Inserts without secondary indexes (bulk and single-row) | json faster (×1.82, ×2.52) | json |
| Inserts with the 5 btree expression indexes | jsonb faster (0.51, 0.54) | jsonb |
| Full-replacement updates without secondary indexes | json faster (×1.29–2.15) | json |
| Full-replacement updates with the 5 btree expression indexes | jsonb faster (0.55–0.59) | jsonb |
| Time cost of maintaining the btree indexes | json ×2.5–6.6, jsonb ×1.1–1.4 | jsonb |
| WAL of whole-table writes and single-row inserts | jsonb 8–13 % less | jsonb |
| WAL of 238-row updates | json 5.6–6.1 % less | json |
| Dead tuples, HOT updates, new-page updates | same on both types | = |
| TOAST growth / out-of-line documents during writes | none on either type | = |

**JSONB-only (no json counterpart):**
- GIN `@>` / `@?` / `@@` queries: 10–12 ms → 0.03–0.8 ms.
- Measured costs:
  - GIN index size 46–56 % of the heap
  - write time ×1.5–4.3 and WAL up to ×3.9
  - `jsonb_path_ops` cheaper than `jsonb_ops` throughout
- Not indexable by GIN on `doc`: `?` on nested expressions, `JSON_EXISTS`.
- `jsonb_set` partial update: the fastest measured partial-update mechanism.

## 11. Final comparison, scoped to what was measured

Within this dataset, this PostgreSQL 17.9 environment and the tested single-client, warm-cache workload, **neither
type was better across the board.** The measured results split by access pattern:

1. **Storing and returning documents unchanged, without secondary indexes on document paths.** json was measurably
   faster:
   - writes: bulk and single-row inserts, full-document updates
   - whole-document reads
   - it preserved the input text exactly

   jsonb stored the same documents in 14 % fewer bytes and wrote less WAL for whole-table writes, but only because this
   dataset sits just above the inline compression threshold.
2. **Reading values out of documents.** jsonb was measurably and consistently faster for every extraction, filter,
   aggregate and SQL/JSON function tested without indexes, by about 5–13×.
3. **Identical btree expression indexes on document paths.**
   - Index-answered queries showed no difference.
   - Every plan that still read documents was faster on jsonb.
   - Writes were measurably faster on jsonb, because json paid text parsing for every index entry. Index sizes and WAL
     were identical.
4. **Containment and jsonpath search.** Only jsonb could use GIN indexes. The query speedups were large, and so were
   the measured write, WAL and storage costs.
5. **Partial updates.** Only jsonb has a native path update (`jsonb_set`), the fastest mechanism measured. On json,
   keeping the canonical text required a text rewrite; the jsonb round trip changed the stored text.

What this report does **not** claim: that these ratios hold for other document sizes, compression settings, index
sets, data volumes, concurrency, cold caches, hardware or PostgreSQL versions.

## 12. Measurement caveats

1. **Dataset.** 5,000 documents of about 1.7 kB with 82 keys.
   - The storage and WAL differences depend on the TOAST inline compression threshold: 2,880 jsonb documents
     compressed, 1 json document compressed, none out of line.
   - Larger documents, out-of-line TOAST, `lz4` or other document shapes were not tested.
2. **Environment.**
   - One Windows laptop, PostgreSQL 17.9, default page size.
   - `synchronous_commit` on, `wal_compression` off, `data_checksums` off, fillfactor 100.
   - Warm cache (0 shared reads in all 1,500 measured 6C executions), a single client, no concurrency, no
     replication.
3. **Timings are session- and machine-specific; only ratios within a session are compared.**
   - 6C: batch 2 medians up to 10–50 % higher than batch 1, with the same directions.
   - 6D: phase-to-phase drift of 7–15 % (up to 40 % in single batches) on identical plans, so index effects below that
     size were not attributed to indexes.
   - 6E: CPU speed dropped about 3× partway through session 1 (laptop running on battery afterwards; the cause is not
     proven). Absolute 6E times are comparable only within a statement block; the json/jsonb ratios reproduced at the
     slower speed (W1b session 2).
   - Absolute milliseconds from different steps (for example 6C reads vs 6E writes) are **not** compared anywhere in
     this report.
4. **Write protocol (6E).**
   - A `CHECKPOINT` preceded every measured write, so every first change to a page produced a full-page image. This
     is a normalised, near worst-case full-page-image share; under normal checkpoint timing the share differs.
   - The write tables were reset for every run, so accumulated bloat, `VACUUM` cost after updates and reads on updated
     tables were not measured.
5. **Excluded and repeated runs (6E).**
   - 4 of 525 measured session-1 runs were excluded by the WAL contamination rule, leaving 14 clean runs in 4 series.
   - 6 attempts were repeated because an autovacuum worker was present; every repeat was clean.
6. **W1b** was a server-side loop: no EXPLAIN buffers; its WAL is the LSN difference around the loop.
7. **Serialisation.** 6C execution times include conversion of results to text (`SERIALIZE TEXT`), not network
   transfer. Decompression of compressed jsonb documents was not measured separately.
8. **Planner facts** (default row estimates without expression statistics, the constant GIN estimate of 50, the Q11b
   cost blind spot) apply to this data and these statistics.
9. **Unexplained or unverified:** the higher jsonb WAL for 238-row updates (§7), and the GIN pending-list state after
   inserts (§8).
10. **Never measured:**
    - whole-document equality (C4)
    - a GIN index on `doc::jsonb` of the json table (I-4)
    - formatting sensitivity of the json text (M-09)
    - concurrency, cold cache, larger data volumes
    - any PostGIS-related workload

## 13. Status and next step

Step 6 (JSON vs JSONB) is complete. The experiment objects remain:
- `log_regex_json`: the tables with the Step 6D index set.
- `log_regex_json_write`: staged input, write tables empty.

PostGIS had not been started at the time of this report; it followed in Steps 7A–7F (final state:
[Final_Project_Conclusion.md](Final_Project_Conclusion.md)).
