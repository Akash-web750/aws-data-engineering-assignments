# Step 6E — JSON vs JSONB Write/Update Cost Experiment (results)

**Status:** measured (12–13/09/2026). The consolidated JSON vs JSONB comparison is in
[Step6F_JSON_vs_JSONB_Final_Comparison_Report.md](Step6F_JSON_vs_JSONB_Final_Comparison_Report.md).

Design: [Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md](Step6E_JSON_vs_JSONB_Write_Update_Experiment_Design.md).
Setup and preflight: `sql/41`, `sql/42`, `analysis/step6/step6e_preflight_report.txt` (63 / 63 PASS).

## 1. What was run

| Artefact | Content |
|---|---|
| `scripts/step6e_json_write_measure.py` | run plan, session SQL generation, static statement check, session execution, analysis |
| `sql/43_measure_json_writes.sql` | session 1: 35 series, 3 warm-up + 15 measured rounds each, 30 `TIMING ON` detail runs (660 runs) |
| `sql/44_measure_json_writes_session2.sql` | session 2 for the blocks with a median below 0.1 ms (Step 6A rule) |
| `sql/run_step6e_json_writes.ps1` | static checks, manifests, digests, `sql/34` / `sql/38 final` / `sql/42` before and after, sessions, analysis |
| `analysis/step6/step6e_session{1,2}_raw.txt` | raw psql output: reset probes, snapshots, EXPLAIN JSON, `\timing` lines, check records |
| `analysis/step6/step6e_attempts.csv` | one row per attempt (including repeated attempts and warm-up/detail runs) |
| `analysis/step6/step6e_summary.csv`, `step6e_comparisons.csv`, `step6e_summary.md` | series statistics, comparisons with the rule applied, generated tables |
| `analysis/step6/step6e_measurement_checks.txt` | PASS/FAIL of every runner check |

## 2. Protocol as executed

**Series (35).**
- W1 bulk `INSERT … SELECT` of the 5,000 canonical texts: json X-0, X-1; jsonb X-0 … X-4.
- W1b, 250 single-row inserts (`log_id % 20 = 0`) in one server-side loop into a table holding the other 4,750
  rows: json X-0, X-1; jsonb X-0, X-1, X-4.
- UA-1 (238 rows, indexed path), UA-2 (238 rows, non-indexed path), UA-3 (5,000 rows, indexed path): full-document
  replacement with the identical expected text; UA-1 in X-0 … X-4, UA-2 and UA-3 in X-0, X-1, X-4 (X-2 … X-4 jsonb only).
- UB, separate: `jsonb_set` on jsonb, `jsonb_set(doc::jsonb, …)::json` and the text `regexp_replace` on json, each in
  X-1 on R-238 and R-5000.

**Order.** Blocks W1, W1b, UA-1, UA-2, UA-3, UB-R238, UB-R5000. Within a block every round runs all its series;
json/jsonb order alternates ABBA by round and the configuration order reverses every round.

**Every attempt (outside the timing unless stated).**
1. Reset probe (checkpoint redo LSN and checkpointer counters).
2. Reset of the target `_w` table:
   - drop its secondary indexes and `TRUNCATE`
   - load in `log_id` order (none for W1; 4,750 rows for W1b)
   - `CREATE INDEX` of the configuration, from the Step 6D definitions
   - `VACUUM (ANALYZE)`, then `CHECKPOINT`
3. Forced statistics flush, then the "before" snapshot:
   - WAL insert LSN and checkpoint redo LSN
   - `pg_stat_wal`, `pg_stat_io` (client backends), `pg_stat_checkpointer`
   - other client sessions and autovacuum workers
   - table counters (`n_tup_*`, live/dead rows)
   - heap/FSM/VM/TOAST/index sizes
   - compressed and out-of-line documents (`pg_column_compression`, `pg_column_toast_chunk_id`), stored document bytes
4. **Timed:** psql `\timing` around `BEGIN;`, the measured statement, and `COMMIT;`. The statement runs as
   `EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, WAL, SETTINGS, SUMMARY, FORMAT JSON)` (`TIMING ON` for detail runs); W1b
   runs as a `DO` loop timed with `clock_timestamp()`, with its WAL taken as the LSN difference around the loop.
5. Forced flush, then the "after" snapshot with the same fields.
6. Correctness checks; a failure stops the session (SQLSTATE LR018):
   - 5,000 rows, unique `log_id`, all matched to the staged input
   - inserts: json md5 = canonical md5; jsonb `doc = doc_text::jsonb`
   - updates: updated rows equal the expected document (json text exact, UB json cast semantic, jsonb equality),
     untouched rows unchanged, updated-row counter = expected
   - with `enable_seqscan = off`: counts for `REVIEWED` / `INVALID` / `W-UPDATED`, and GIN containment on jsonb,
     equal the expected values; `idx_scan` deltas prove that the btree (I-1a) and GIN indexes answered
   - index set and validity equal the configuration
   - after inserts, when both tables hold canonical documents: `json::jsonb = jsonb` for all 5,000 pairs

**Contamination flags.**

| Flag | Meaning | Handling |
|---|---|---|
| `checkpoint-in-run` | redo LSN changed between the snapshots | in-session: attempt repeated once |
| `other-active-session`, `autovacuum-worker` | another client backend not idle, or an autovacuum worker, at either snapshot | in-session: repeated once |
| `wal-counter-inconsistent` | cluster WAL counters vs LSN difference outside page-header/alignment tolerance | in-session: repeated once |
| `checkpoint-started-before-run-end` | the next reset probe shows a checkpoint whose redo LSN lies before the end of this attempt | analysis: run excluded |
| `wal-foreign-activity` | design rule: `pg_stat_wal` bytes vs the statement's own WAL (EXPLAIN WAL bytes; W1b loop WAL) plus commit more than 1 % apart | analysis: run excluded |
| `pause` | snapshot gap exceeds the client-observed transaction time by more than 2 s | analysis: run excluded |

The runner kept the machine from sleeping while psql ran (`SetThreadExecutionState`).

**Rules.**
- **Execution time:** the Step 6A rule (IQR non-overlap and at least a 10 % median difference) on server execution
  time (W1b: the 250-row loop). Client-observed transaction time uses the same rule as a secondary metric.
- **Second session:** blocks where a series has a median below 0.1 ms, applied to the reported unit (W1b per row), are
  repeated; a result counts only if both sessions agree.
- **Near-deterministic metrics** (WAL, buffers, growth, dead rows, HOT): medians with min–max; "consistent" means the
  min–max ranges do not overlap.

## 3. Deviations from and clarifications of the design

1. **WAL contamination check split.** The smoke test showed that the LSN difference exceeds `pg_stat_wal` bytes by
   1.05–1.16 % for GIN-heavy writes on every repeat: the LSN also counts WAL page headers and record alignment. A 1 %
   LSN-based trigger would therefore repeat clean runs. The in-session trigger now allows 1 % plus 8 bytes per record
   plus 2 pages. The design's own rule (stat bytes vs EXPLAIN WAL bytes plus commit, at most 0.33 % in the smoke test)
   is applied in the analysis.
2. **W1b has no EXPLAIN.** A `DO` loop cannot be explained, so W1b has no per-statement buffer counts or EXPLAIN WAL
   fields. Its WAL comes from the LSN difference around the loop and from `pg_stat_wal`, and its I/O from `pg_stat_io`.
3. **UB row selection.** UB statements select their rows with the same `expected_update` join as UA (variant UA-1 for
   R-238, UA-3 for R-5000), so the only difference from UA is the `SET` expression.
4. **Correctness checks run after every attempt**, which is stricter than after every round.
5. **Preflight runner.** Check R-06 of `sql/run_step6e_setup_preflight.ps1` ("no `sql/43_*` present") belonged to the
   preflight-only phase and fails now that `sql/43` exists; the measurement runner re-runs `sql/42` itself.

## 4. Validity of the run

**Isolation and correctness.** `sql/run_step6e_json_writes.ps1` passed 26 / 26 checks
(`analysis/step6/step6e_measurement_checks.txt`):
- static checks: 32,191 statement lines of `sql/43` and 4,689 of `sql/44`, all designed forms on `log_regex_json_write`
- Step 6C and Step 6D manifests (11 and 26 files) unchanged
- `log_regex` digest `f8042db0…`, `log_regex_json` data digest `9e6f8831…` and the Step 6D index digest `e20752ca…`
  identical before and after
- `sql/34` 38 / 38, `sql/38 final` 70 / 70 and `sql/42` 41 / 41 before and after; the write tables are empty again
  after the sessions

All **756 attempts passed their correctness checks**, and there was no out-of-line document or TOAST growth in any
attempt.

| Session | Content | Attempts / runs | Duration | Repeated in-session | Used runs flagged afterwards |
|---|---|---|---|---|---|
| 1 (`sql/43`) | 35 series × 18 rounds + 30 detail runs | 664 / 660 | 1,919 s | 4, all `autovacuum-worker` (two also WAL flags); every repeat was clean | 5, all `wal-foreign-activity` (1.04–3.65 %); 1 warm-up, 4 measured: W1/jsonb/X-1 m14, UA-3/json/X-0 m11, UB-R5000 json-cast m08, UB-R5000 jsonb m12, so these 4 series have 14 / 15 clean runs |
| 2 (`sql/44`, W1b only) | 5 series × 18 rounds | 92 / 90 | 281 s | 2, `autovacuum-worker`; both repeats clean | 0 |

No attempt was flagged for a checkpoint, another active session or a pause.

**Machine speed changed during session 1.** Plans, buffer counts, WAL and growth were identical to the smoke test, but
execution times were not.

*Correction (final audit, 13/09/2026):*
- **Earlier wording:** this sentence also said "no shared reads".
- **Recorded per-run data:** 48–53 shared reads in 257 of 605 measured runs, all in update series with secondary indexes
  (`analysis/step6/step6e_attempts.csv`).
  - The 605 measured attempt rows include 5 repeated attempts and 152 W1b loop rows without buffer data.
  - 255 of the 600 runs used for the statistics have shared reads.
- **Not assessed:** their effect on the timing ratios.

The table shows each attempt's execution time relative to the smoke-test run of the same series:

| Time (UTC) | Blocks | Median ratio to the smoke run |
|---|---|---|
| 18:10–18:15 | W1, W1b | 1.01 |
| 18:15–18:45 | UA-1, UA-2, UA-3, UB | 2.0–3.1 |
| 18:40–18:50 (session 2) | W1b | 3.1–3.2 |

After the run the laptop was on battery (discharging, 19 %, *Balanced* plan) with the CPU at 1,495 of 2,592 MHz. The
System log shows no power-source event in the window, so CPU power limiting is the likely but unproven cause.

Consequences:
- Absolute times are comparable only within a block; no block straddles the change.
- All time comparisons below are interleaved within the same rounds.
- Session 2 reproduced the W1b ratios at the ~3× slower speed (json vs jsonb X-0 2.31×, session 1 2.52×; X-1 0.59,
  session 1 0.54).
- WAL, buffers, growth, dead rows and HOT do not depend on CPU speed.

## 5. Results — head-to-head json vs jsonb (X-0 and X-1)

Execution time: median [IQR] in ms (W1b: the 250-row loop). "Rule" is the Step 6A rule; every result below was also
measurable, in the same direction, on client-observed transaction time. W1b is confirmed in session 2.

| Statement | Config | json | jsonb | jsonb / json | Rule |
|---|---|---|---|---|---|
| W1 bulk insert 5,000 | X-0 | 165.7 [150.1–191.1] | 301.8 [291.7–361.1] | 1.82 | measurable: **json faster** |
| W1 | X-1 | 731.5 [670.8–861.4] | 371.3 [339.8–440.7] | 0.51 | measurable: **jsonb faster** |
| W1b 250 single-row inserts | X-0 | 5.13 [4.71–5.76] (0.021 / row) | 12.94 [12.24–14.01] (0.052 / row) | 2.52 (session 2: 2.31) | measurable, confirmed: **json faster** |
| W1b | X-1 | 33.62 [32.50–34.43] (0.134 / row) | 18.16 [17.72–18.68] (0.073 / row) | 0.54 (session 2: 0.59) | measurable, confirmed: **jsonb faster** |
| UA-1 238 rows, indexed path | X-0 | 19.5 [19.3–20.9] | 42.0 [40.0–44.8] | 2.15 | measurable: **json faster** |
| UA-1 | X-1 | 93.4 [87.5–101.2] | 51.2 [50.5–61.8] | 0.55 | measurable: **jsonb faster** |
| UA-2 238 rows, non-indexed path | X-0 | 19.5 [15.6–25.7] | 39.2 [35.5–48.5] | 2.01 | measurable: **json faster** |
| UA-2 | X-1 | 88.9 [85.5–105.6] | 48.4 [44.5–73.2] | 0.55 | measurable: **jsonb faster** |
| UA-3 5,000 rows | X-0 | 760.3 [704.0–846.3] | 983.3 [948.9–1,027.3] | 1.29 | measurable: **json faster** |
| UA-3 | X-1 | 1,912.1 [1,800.7–2,011.5] | 1,120.8 [1,051.6–1,268.3] | 0.59 | measurable: **jsonb faster** |

WAL and storage (medians; every WAL/buffer/growth difference listed is consistent, i.e. non-overlapping min–max, unless
marked "same"):

| Statement | Config | WAL bytes json / jsonb (ratio) | FPI json / jsonb | Dirtied blocks | Heap growth json / jsonb | Secondary index growth | Dead / HOT (json, jsonb) |
|---|---|---|---|---|---|---|---|
| W1 | X-0 | 9,059,086 / 7,844,703 (0.866) | 0 / 0 | 1,267 / 998 | 10,240,000 / 8,036,352 | — | 0 / 0 |
| W1 | X-1 | 10,955,870 / 9,741,849 (0.889) | 0 / 0 | 1,338 / 1,069 | same as X-0 | 540,672 (same) | 0 / 0 |
| W1b | X-0 | 558,376 / 500,608 (0.897) | 15 / 14 | — | 507,904 / 409,600 | — | 0 / 0 |
| W1b | X-1 | 957,016 / 876,992 (0.916) | 62 / 58 | — | same as X-0 | 16,384 (same) | 0 / 0 |
| UA-1 | X-0 | 2,098,202 / 2,225,158 (1.061) | 239 / 240 (overlap) | 303 / 294 | 491,520 / 409,600 | — | 238 / 0, 238 / 1 |
| UA-1 | X-1 | 2,484,878 / 2,626,690 (1.057) | 284 / 286 (overlap) | 348 / 341 | same as X-0 | 8,192 (same) | 238 / 0 both |
| UA-2 | X-0 | 2,103,892 / 2,227,253 (1.059) | 240 / 240 (overlap) | 303 / 294 | 483,328 / 409,600 | — | 238 / 0, 238 / 1 |
| UA-2 | X-1 | 2,488,362 / 2,626,625 (1.056) | 285 / 286 | 348 / 341 | same as X-0 | 8,192 (same) | 238 / 0 both |
| UA-3 | X-0 | 18,232,798 / 15,788,614 (0.866) | 1,265 / 996 | 2,531 / 1,995 | 10,223,616 / 8,036,352 | — | 5,000 / 4 both |
| UA-3 | X-1 | 20,498,141 / 18,046,214 (0.880) | 1,319 / 1,048 | 2,638 / 2,101 | same as X-0 | 442,368 (same) | 5,000 / 0 both |

Observations (not conclusions):
- **Opposite direction with and without indexes.** Without secondary indexes json writes are faster (1.3–2.5×); with
  the five identical btree expression indexes jsonb writes are faster (0.51–0.59). The `TIMING ON` detail runs of UA-1
  locate the difference:
  - json X-1 spends about 150 of 172 ms inside ModifyTable, after the join (json X-0: about 10 of 20 ms)
  - jsonb spends 27–33 ms in the join, where `new_text::jsonb` is evaluated, and about 58 ms in total with or without
    the indexes

  This is consistent with the Step 6D build times: json expression extraction re-parses the text for every index,
  while jsonb pays once at input conversion.
- **WAL follows stored size for whole-table writes.** jsonb writes 11–13 % less WAL for W1 and UA-3 and dirties
  about 20 % fewer blocks. The heap grows by 981 instead of 1,250 pages, because 2,880 jsonb documents are
  pglz-compressed inline versus 1 json document.
- **Small updates are the exception.** For the 238-row updates jsonb writes 5.6–6.1 % more WAL, although the FPI
  counts are almost equal and jsonb dirties fewer blocks. The measurements do not isolate the cause; fuller jsonb pages
  giving larger full-page images is a plausible but unverified explanation.
- **Updates move almost every row.**
  - Every updated row becomes a dead tuple: 238 or 5,000.
  - HOT updates occur only without secondary indexes: 4 of 5,000 in UA-3 X-0, and 0 / 1 of 238 in UA-1 and UA-2
    X-0. With X-1 there are none.
  - Nearly every new version goes to another page: `n_tup_newpage_upd` is 237–238 and 4,996.
  - UA-3 roughly doubles the heap: json 1,250 → 2,498 pages, jsonb 981 → 1,962 pages.
- **Indexed vs non-indexed path makes no difference.** UA-2 changes a non-indexed path, yet in X-1 it has the same
  zero HOT updates, the same index growth and WAL within 0.2 % of UA-1: the expression indexes are on `doc`, so any
  document change updates them.
- **Other timing components are small and similar.** Planning takes 0.05 ms (W1) and 0.31–0.44 ms (updates), about
  the same for both types. Client-observed COMMIT medians are 0.9–15 ms. `pg_stat_wal` shows no separate WAL syncs
  (`wal_sync_method = open_datasync`), and client backends performed no relation fsyncs.

## 6. Results — index effect (X-0 → X-1, same type)

| Statement | json time ratio (rule) | jsonb time ratio (rule) | WAL bytes ratio json / jsonb | WAL records ratio | Index growth |
|---|---|---|---|---|---|
| W1 | 4.42 (measurable) | 1.23 (not measurable) | 1.21 / 1.24 | 3.52 | 540,672 |
| W1b | 6.55 (measurable, confirmed) | 1.40 (measurable, confirmed) | 1.71 / 1.75 | 3.50 | 16,384 |
| UA-1 | 4.78 (measurable) | 1.22 (measurable) | 1.18 / 1.18 | 2.70 | 8,192 |
| UA-2 | 4.56 (measurable) | 1.24 (not measurable) | 1.18 / 1.18 | 2.69 | 8,192 |
| UA-3 | 2.52 (measurable) | 1.14 (measurable) | 1.12 / 1.14 | 2.69 | 442,368 |

With the btree expression indexes, WAL records, WAL bytes, index growth and the FPI increase are about the same for
both types. The time cost of maintaining them is 2.5–6.6× for json and 1.1–1.4× for jsonb.

## 7. Results — GIN write cost (jsonb only, compared with jsonb X-1; separate)

| Statement | X-2 `jsonb_ops`: time, WAL, index growth | X-3 `jsonb_path_ops`: time, WAL, index growth | X-4 both (current Step 6D set): time, WAL, index growth |
|---|---|---|---|
| W1 | 3.49× (1,296 ms), 2.82× (27.4 MB), +8,142,848 | 2.22× (824 ms), 2.09× (20.3 MB), +6,873,088 | 4.33× (1,606 ms), 3.90× (38.0 MB), +14,475,264 |
| W1b | — | — | 2.43× (44.2 ms; session 2 2.16×), 1.91×, +1,081,344 |
| UA-1 | 1.96× (100.6 ms), 1.18×, +647,168 | 1.51× (77.3 ms), 1.11×, +401,408 | 2.43× (124.4 ms), 1.29×, +1,040,384 |
| UA-2 | — | — | 2.29× (110.8 ms), 1.29×, +1,015,808 |
| UA-3 | — | — | 3.05× (3,423 ms), 2.65× (47.8 MB), +10,330,112 |

All time ratios are measurable. GIN adds full-page images where the btree-only configuration had none:
- W1: 743 (X-2), 470 (X-3) and 1,213 (X-4)
- UA-3 X-4: 2,255, against 1,048

After W1 the GIN indexes built by inserts (with `fastupdate`) are about 1.7× the size of the Step 6D `CREATE INDEX`
builds: roughly 7.6 MB vs 4.5 MB for `jsonb_ops` and 6.3 MB vs 3.7 MB for `jsonb_path_ops`. The state of the pending
list was not inspected. `jsonb_path_ops` is cheaper to maintain than `jsonb_ops` in every statement measured.

## 8. Results — update mechanisms (X-1; separate, not a type verdict)

| Row set | `jsonb_set` on jsonb | text `regexp_replace` on json | `jsonb_set(doc::jsonb)::json` on json |
|---|---|---|---|
| R-238 time | 39.2 ms | 106.8 ms | 131.6 ms (1.23× the text form, measurable) |
| R-238 WAL | 2,626,690 (= UA-1 jsonb X-1) | 2,484,878 (= UA-1 json X-1) | 2,520,817 (+1.4 % vs text) |
| R-238 stored text of updated rows | — | 397,664 (canonical) | 433,602 (+9.0 %; all 238 texts differ from canonical, semantically equal) |
| R-5000 time | 932.8 ms | 1,933.7 ms | 2,496.2 ms (1.29× the text form, measurable) |
| R-5000 WAL | 18,045,847 | 20,497,306 | 21,247,117 (+3.7 % vs text) |
| R-5000 stored text | — | 8,430,545 | 9,185,546 (+9.0 %); compressed documents 1 → 4 |

The WAL of each type-native partial update equals the full-replacement WAL of the same type (identical resulting
documents). Times of UB and UA are not compared: they ran in different blocks, and the machine speed changed.

## 9. TOAST-related observations

- **Nothing moved out of line:** no attempt produced an out-of-line document or TOAST growth.
- **Compression counts were stable:**
  - json: 1 compressed document in every series; UB json cast R-5000 raises it to 4.
  - jsonb: 2,880 after every canonical load and after UA-1 / UA-3; UA-2 leaves 2,878, because changing
    `action_phrase.source` alters the compression outcome of 2 documents.
  - W1b jsonb: the 250 inserted rows add 137 compressed documents (2,743 → 2,880).
- **Stored document bytes:** 8,434,066 for json vs 7,219,683 for jsonb (−14.4 %), and they stay nearly unchanged
  after full-replacement updates.

## 10. What is not concluded here

No overall JSON vs JSONB verdict. Limits of these results:
- single client, local disk, the current durability settings
- one laptop whose CPU speed changed during the session
- documents of about 1.7 kB, none TOASTed out of line

Step 6F combines 6B–6E.
