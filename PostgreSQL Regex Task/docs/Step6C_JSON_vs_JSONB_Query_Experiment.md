# Step 6C — JSON vs JSONB Head-to-Head Query Experiment

**Status:** head-to-head query measurements recorded (12/09/2026). Stopped for review. This report describes measurements
and observations only; **it is not the final JSON vs JSONB conclusion.**

**Scope:**
- the 21 common query IDs of the Step 6A design (§4.1), run as 25 statements because Q11, Q12 and Q13 have variants
- against `log_regex_json.access_log_json` and `log_regex_json.access_log_jsonb`
- no secondary index (configuration I-0: primary keys only)

**Not done:**
- indexes
- jsonb-only feature tests (`@>`, `?`, `@?`, document equality; Step 6A C1–C4); they stay separate and were not run here
- write-side measurements
- PostGIS
- the final conclusion

**Unchanged:** documents, tables and indexes. The `log_regex_json` digest is `a21ed54a3028d56639deeac732cd0473` (14 items)
before and after. The `log_regex` digest, `access_log_flat` rows included, is `f8042db0318656b5929c86ea1f7888d4` (203
items) before and after. `sql/34` passes 38 / 38 before and after timing.

---

## 1. Files

| File | Role |
|---|---|
| `scripts/step6c_json_query_experiment.py` | **new**: the single definition of the 25 statements and their flat-table oracles; `generate` writes `sql/36` and `sql/37`; `analyze` parses the EXPLAIN output and applies the measurability rule (standard library only) |
| `sql/36_verify_json_query_results.sql` | **new, generated**: read-only gate (documents unchanged) and result correctness, 78 checks (`LR013`) |
| `sql/37_measure_json_queries.sql` | **new, generated**: read-only measurement session, 950 `EXPLAIN ANALYZE` executions per session |
| `sql/run_step6c_json_queries.ps1` | **new** runner: static checks, digests, gate, batch 1, batch 2, gate, digests, analysis; `-AnalyzeOnly` |
| `analysis/step6/step6c_batch1_explain.txt`, `step6c_batch2_explain.txt` | raw EXPLAIN (JSON) output of the two sessions (about 2.6 MB each) |
| `analysis/step6/step6c_executions.csv` | one row per execution (1,900): phase, round, planning / execution / serialisation time, buffers, rows, plan shape |
| `analysis/step6/step6c_summary.csv` | per batch × statement × type: median, p25, p75, min, max, buffers, plan and row facts |
| `analysis/step6/step6c_comparison.csv`, `step6c_summary.md` | per statement: json vs jsonb comparison and the rule result |
| `docs/Step6C_JSON_vs_JSONB_Query_Experiment.md` | this report |
| `README.md` | status and Step 6C summary |

The runner's static checks verify that:
- `sql/36` and `sql/37` equal the generator output
- neither contains a write statement
- none of the 950 measured statements contains a jsonb-only operator (`@>`, `<@`, `?`, `?|`, `?&`, `@?`, `@@`, `||`,
  `#-`, document equality) outside string literals
- all Step 6C files are ASCII

## 2. Query list (head-to-head)

`T` is the table. The SQL is identical for both types. Q14 is the only exception: it uses the equivalent function
`json_array_elements_text` / `jsonb_array_elements_text`. Filter statements return `log_id` so the exact result set can be
checked. Expected rows come from `access_log_flat`.

| ID | Pattern | Statement | Rows |
|---|---|---|---:|
| Q01 | point lookup, whole document | `SELECT doc FROM T WHERE log_id = 2835` | 1 |
| Q02 | all whole documents | `SELECT doc FROM T` | 5,000 |
| Q03 | point lookup, one nested value | `SELECT doc->'fields'->'resource_url'->>'value' FROM T WHERE log_id = 2835` | 1 |
| Q04 | one nested scalar, all rows | `SELECT log_id, doc->'record'->>'record_validity' FROM T` | 5,000 |
| Q05 | ten nested scalars per row | `SELECT log_id, doc->'fields'->'<field>'->>'value'` × 10 `FROM T` | 5,000 |
| Q06 | all 70 leaves, cast back to column types | 70 expressions such as `(doc->'fields'->'latitude'->>'degrees')::numeric`, `(… 'utc')::timestamptz`, `(… 'address')::inet`, `(doc->'record'->>'diagnostics')::jsonb` | 5,000 |
| Q07 | equality, very selective | `… WHERE doc->'record'->>'record_validity' = 'BROKEN'` | 12 |
| Q08 | equality, medium | `… WHERE doc->'fields'->'entity_type'->>'code' = 'BOT'` | 225 |
| Q09 | equality, broad | `… WHERE doc->'record'->>'format_family' = 'F1'` | 1,528 |
| Q10 | integer equality | `… WHERE (doc->'fields'->'status'->>'code')::integer = 404` | 30 |
| Q11a | numeric range, medium | `… WHERE (doc->'fields'->'latitude'->>'degrees')::numeric BETWEEN 50 AND 55` | 422 |
| Q11b | numeric range, broad | `… BETWEEN 0 AND 60` | 3,064 |
| Q12a | time window, 1 day | `… WHERE doc->'fields'->'event_timestamp'->>'utc' >= '2026-03-01T00:00:00.000000Z' AND … < '2026-03-02T00:00:00.000000Z'` | 13 |
| Q12b | time window, 1 week | `… < '2026-03-08T00:00:00.000000Z'` | 108 |
| Q12c | time window, 1 month | `… < '2026-04-01T00:00:00.000000Z'` | 498 |
| Q13a | pattern, suffix | `… WHERE doc->'fields'->'email_address'->>'value' LIKE '%.org'` | 545 |
| Q13b | pattern, prefix | `… WHERE doc->'fields'->'tool'->>'value' LIKE 'curl/%'` | 173 |
| Q14 | array membership | `… WHERE EXISTS (SELECT 1 FROM <type>_array_elements_text(doc->'record'->'diagnostics') AS d (x) WHERE d.x = 'truncated')` | 3 |
| Q15 | JSON null test | `… WHERE doc->'fields'->'event_timestamp'->>'utc' IS NOT NULL` | 2,941 |
| Q16 | conjunction | `… WHERE doc->'record'->>'format_family' = 'F3' AND (doc->'fields'->'status'->>'code')::integer = 403` | 78 |
| Q17 | group by nested text | `SELECT doc->'fields'->'entity_type'->>'code', count(*) FROM T GROUP BY 1` | 8 groups |
| Q18 | group by two nested values | `SELECT …->'status'->>'code', …->'status'->>'word', count(*) FROM T GROUP BY 1, 2` | 32 groups |
| Q19 | numeric aggregates | `SELECT min/max/avg((doc->'fields'->'latitude'->>'degrees')::numeric) FROM T WHERE doc->'fields'->'latitude'->>'validity' = 'VALID'` | 1 |
| Q20 | SQL/JSON value | `SELECT log_id, JSON_VALUE(doc, '$.record.record_validity') FROM T` | 5,000 |
| Q21 | SQL/JSON exists | `SELECT log_id FROM T WHERE JSON_EXISTS(doc, '$.fields.status.code ? (@ == 404)')` | 30 |

Details fixed while implementing the design:
- Filter statements select `log_id`.
- Q20 adds `log_id`.
- Q06 returns `diagnostics` as `(…->>'diagnostics')::jsonb` so both types return the same value. It is the same SQL for
  both and adds one jsonb input conversion per row on both sides.

## 3. Methodology

### 3.1 Gate before timing
- **`sql/34`:** 38 checks, including all 70 values round-tripping to `access_log_flat`.
- **`sql/36` gate part:**

| Check | Result |
|---|---|
| G-01 / G-02 | 5,000 rows in each table |
| G-03 | md5 of the stored `json` texts = the canonical input md5 recorded at load (`aeaef323…`) |
| G-04 | `jsonb = json::jsonb` for all 5,000 |
| G-05 | primary key indexes only |
| G-06 | 5,000 rows inserted, 0 updated, 0 deleted per table since creation |
| G-07 | heap pages 1,250 / 981, as measured in Step 6B |

### 3.2 Sessions and settings

| Item | Value |
|---|---|
| Sessions | two separate read-only sessions (`default_transaction_read_only = on`): batch 1 (pid 14612, 09:46:08–09:50:02 UTC) and batch 2 (pid 52540, 09:50:03–09:54:20 UTC); other active client sessions: 0 in both |
| Session settings | `jit = off`, `max_parallel_workers_per_gather = 0`, `TimeZone = 'UTC'`, `track_io_timing = on`; EXPLAIN `SETTINGS` reported the same non-default settings for all 1,900 executions |
| Server | PostgreSQL 17.9, `shared_buffers` 128 MB, `work_mem` 4 MB, `random_page_cost` 4, `default_toast_compression` pglz |
| Statistics | tables as analysed at the end of Step 6B; autovacuum disabled on both tables; nothing modified since |

### 3.3 Execution plan

Per statement, in each session:
1. **Warm-up:** 3 unmeasured rounds (json, jsonb).
2. **Measurement:** 15 measured rounds with alternating order: odd rounds json → jsonb, even rounds jsonb → json.
3. **Detail:** 1 detail round per type.

| Round type | Command |
|---|---|
| Measured | `EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SETTINGS, SERIALIZE TEXT, MEMORY, SUMMARY, FORMAT JSON)` |
| Detail | the same with `TIMING ON`: per-node timing and the separate serialisation time |

**Total:** 25 statements × 2 types × 19 executions = 950 per session, 1,900 overall.

### 3.4 Metrics
- **Execution time:** includes output serialisation (`SERIALIZE TEXT`), i.e. converting every returned value to text as it
  would be sent to a client; network transfer is excluded. The detail runs show serialisation inside execution time
  (e.g. Q02 jsonb: 68.9 ms execution, of which 67.4 ms is serialisation).
- **Also collected:**
  - planning time and planning buffers / memory
  - shared hit / read blocks, temp blocks, I/O read time
  - output volume
  - plan shape (node tree with the table name normalised)
  - estimated vs actual rows of the top node and the scan node

### 3.5 Statistics and rule (fixed in Step 6A §9)
- **Statistics:** for 15 values, median = 8th, p25 = 4th, p75 = 12th value (nearest rank). The timing spread is the IQR
  [p25, p75].
- **Measurable:** the IQRs of json and jsonb do not overlap **and** the faster median is at most 90 % of the slower
  median, i.e. the medians differ by at least 10 % of the slower one.
- **Below 0.1 ms:** if either median is under 0.1 ms, the same result, with the same faster type, must also hold in
  batch 2.
- **Primary metric:** batch 1 execution time. Batch 2 is reported for reproducibility. Planning time gets the same rule
  as a secondary metric.

## 4. Correctness results

| Check | Result |
|---|---|
| `sql/36` before timing | **78 / 78 PASS**: the 7 gate checks, plus for every statement the result checksum (row count and md5 of the sorted row texts) of the json and the jsonb statement = the `access_log_flat` oracle. Q01 and Q02 return whole documents, compared as jsonb, json = jsonb. Row counts = the Step 6A expectations |
| `sql/36` after timing | 78 / 78 PASS |
| `sql/34` before / after timing | 38 / 38 PASS both times |
| EXPLAIN actual rows | identical for json and jsonb in all 1,900 executions, and equal to the expected row count for every statement |
| Digests | `log_regex` and `log_regex_json` unchanged |

**JSON and JSONB return the same logical results for all 25 statements.**

## 5. Median timings and measurable differences

Execution time in ms (serialisation included). Batch 1: median [p25–p75] of 15 runs. Batch 2: median. Ratio =
jsonb median / json median (below 1 = jsonb faster).

| ID | Pattern | json (batch 1) | jsonb (batch 1) | jsonb/json | Batch 2 json / jsonb | Result |
|---|---|---|---|---:|---|---|
| Q01 | point lookup, whole document | 0.012 [0.011–0.014] | 0.030 [0.028–0.032] | 2.50 | 0.011 / 0.028 | **measurable: json faster** (below 0.1 ms, confirmed in batch 2) |
| Q02 | all whole documents | 2.956 [2.798–3.120] | 68.709 [66.592–70.051] | 23.24 | 3.180 / 71.790 | **measurable: json faster** |
| Q03 | point lookup, one nested value | 0.035 [0.033–0.037] | 0.017 [0.016–0.018] | 0.49 | 0.040 / 0.019 | **measurable: jsonb faster** (below 0.1 ms, confirmed in batch 2) |
| Q04 | one nested scalar, all rows | 57.813 [56.075–61.155] | 11.134 [10.974–11.593] | 0.19 | 63.515 / 12.072 | measurable: jsonb faster |
| Q05 | ten nested scalars per row | 1,069.889 [1,046.866–1,077.830] | 81.888 [80.127–85.197] | 0.08 | 1,107.349 / 94.473 | measurable: jsonb faster |
| Q06 | all 70 leaves | 7,413.235 [7,280.983–7,906.262] | 592.191 [578.843–623.463] | 0.08 | 7,494.955 / 613.074 | measurable: jsonb faster |
| Q07 | equality, very selective | 56.655 [55.694–60.711] | 10.253 [10.167–10.489] | 0.18 | 85.785 / 17.583 | measurable: jsonb faster |
| Q08 | equality, medium | 104.752 [102.436–106.343] | 10.700 [10.568–11.320] | 0.10 | 144.373 / 16.226 | measurable: jsonb faster |
| Q09 | equality, broad | 57.653 [56.925–59.753] | 10.671 [10.434–10.878] | 0.18 | 75.506 / 13.917 | measurable: jsonb faster |
| Q10 | integer equality | 110.982 [105.504–122.113] | 11.341 [10.963–12.475] | 0.10 | 118.120 / 12.193 | measurable: jsonb faster |
| Q11a | numeric range, medium | 119.987 [117.569–132.124] | 13.669 [13.433–13.868] | 0.11 | 176.349 / 20.899 | measurable: jsonb faster |
| Q11b | numeric range, broad | 184.372 [174.735–187.566] | 20.101 [19.649–21.969] | 0.11 | 195.531 / 21.446 | measurable: jsonb faster |
| Q12a | time window, 1 day | 155.207 [150.885–159.728] | 15.660 [14.982–16.372] | 0.10 | 161.201 / 16.592 | measurable: jsonb faster |
| Q12b | time window, 1 week | 154.690 [149.117–157.772] | 15.280 [14.984–16.731] | 0.10 | 163.746 / 16.371 | measurable: jsonb faster |
| Q12c | time window, 1 month | 156.042 [148.874–166.100] | 14.975 [14.730–15.340] | 0.10 | 161.267 / 16.544 | measurable: jsonb faster |
| Q13a | pattern, suffix | 106.807 [101.007–109.243] | 11.548 [11.305–12.336] | 0.11 | 127.487 / 12.879 | measurable: jsonb faster |
| Q13b | pattern, prefix | 104.854 [103.949–107.177] | 11.415 [10.914–13.261] | 0.11 | 113.373 / 12.395 | measurable: jsonb faster |
| Q14 | array membership | 64.069 [63.260–66.275] | 13.242 [12.962–13.519] | 0.21 | 67.298 / 14.120 | measurable: jsonb faster |
| Q15 | JSON null test | 106.269 [105.584–112.348] | 11.869 [11.388–13.291] | 0.11 | 121.574 / 12.618 | measurable: jsonb faster |
| Q16 | conjunction | 76.968 [75.502–82.114] | 12.145 [11.845–12.551] | 0.16 | 83.156 / 13.053 | measurable: jsonb faster |
| Q17 | group by nested text | 105.029 [102.136–117.410] | 11.596 [11.385–12.499] | 0.11 | 112.962 / 13.422 | measurable: jsonb faster |
| Q18 | group by two nested values | 220.851 [213.230–226.248] | 20.256 [19.882–21.548] | 0.09 | 225.855 / 21.206 | measurable: jsonb faster |
| Q19 | numeric aggregates | 393.824 [381.609–400.682] | 39.501 [37.487–42.049] | 0.10 | 398.281 / 41.471 | measurable: jsonb faster |
| Q20 | SQL/JSON JSON_VALUE | 126.457 [123.956–137.051] | 12.837 [11.949–13.481] | 0.10 | 131.761 / 12.816 | measurable: jsonb faster |
| Q21 | SQL/JSON JSON_EXISTS | 160.325 [141.116–175.472] | 14.897 [12.512–17.856] | 0.09 | 132.799 / 13.425 | measurable: jsonb faster |

**Summary of the rule results:**

| Direction | Statements |
|---|---|
| json faster, measurable | 2: Q01 (confirmed in batch 2), Q02 |
| jsonb faster, measurable | 23: Q03 (confirmed in batch 2), Q04–Q21 including all variants |
| no measurable difference | 0 |

- In both batches the IQRs of json and jsonb never overlap, and the relative difference is 51–96 % in batch 1.
- Batch 2 gives the same faster type for all 25 statements, and each difference is measurable there too.
- **Planning time:** no measurable difference for any statement. Across both batches the medians are 0.023–0.068 ms,
  except Q06 at 0.151–0.153 ms on both types.

## 6. Raw measurement summary (batch 1 unless noted)

| ID | Plan shape (both types) | Scan est. / actual rows | Shared hit json / jsonb | Output kB json / jsonb | Serialisation ms json / jsonb (detail run) | Exec min–max json | Exec min–max jsonb |
|---|---|---|---|---|---|---|---|
| Q01 | Index Scan using T_pkey | 1 / 1 | 3 / 3 | 2 / 2 | 0.001 / 0.017 | 0.011–0.019 | 0.027–0.045 |
| Q02 | Seq Scan on T | 5,000 / 5,000 | 1,250 / 981 | 8,249 / 8,986 | 1.870 / 67.379 | 2.581–3.243 | 60.963–72.310 |
| Q03 | Index Scan using T_pkey | 1 / 1 | 3 / 3 | 1 / 1 | 0.001 / 0.001 | 0.032–0.042 | 0.015–0.019 |
| Q04 | Seq Scan on T | 5,000 / 5,000 | 1,250 / 981 | 93 / 93 | 0.550 / 0.474 | 55.4–61.8 | 10.5–12.8 |
| Q05 | Seq Scan on T | 5,000 / 5,000 | 1,250 / 981 | 1,047 / 1,047 | 3.720 / 2.987 | 1,023.8–1,091.0 | 78.8–92.2 |
| Q06 | Seq Scan on T | 5,000 / 5,000 | 1,250 / 981 | 3,796 / 3,796 | 27.340 / 21.295 | 7,088.6–9,112.9 | 574.0–763.3 |
| Q07 | Seq Scan on T | 25 / 12 | 1,250 / 981 | 1 / 1 | 0.004 / 0.002 | 54.6–80.3 | 10.0–12.3 |
| Q08 | Seq Scan on T | 25 / 225 | 1,250 / 981 | 3 / 3 | 0.030 / 0.017 | 99.7–116.5 | 10.3–12.4 |
| Q09 | Seq Scan on T | 25 / 1,528 | 1,250 / 981 | 15 / 15 | 0.118 / 0.115 | 55.6–75.6 | 10.0–11.4 |
| Q10 | Seq Scan on T | 25 / 30 | 1,250 / 981 | 1 / 1 | 0.008 / 0.003 | 99.2–205.0 | 10.6–16.8 |
| Q11a | Seq Scan on T | 25 / 422 | 1,250 / 981 | 5 / 5 | 0.068 / 0.028 | 110.7–135.2 | 12.8–19.5 |
| Q11b | Seq Scan on T | 25 / 3,064 | 1,250 / 981 | 30 / 30 | 0.531 / 0.271 | 170.8–199.8 | 19.2–26.4 |
| Q12a | Seq Scan on T | 25 / 13 | 1,250 / 981 | 1 / 1 | 0.010 / 0.002 | 147.0–187.6 | 14.7–24.1 |
| Q12b | Seq Scan on T | 25 / 108 | 1,250 / 981 | 2 / 2 | 0.024 / 0.010 | 145.5–176.6 | 14.3–18.6 |
| Q12c | Seq Scan on T | 25 / 498 | 1,250 / 981 | 5 / 5 | 0.077 / 0.038 | 144.9–173.4 | 14.5–17.4 |
| Q13a | Seq Scan on T | 8 / 545 | 1,250 / 981 | 6 / 6 | 0.055 / 0.037 | 98.9–121.6 | 11.0–13.0 |
| Q13b | Seq Scan on T | 25 / 173 | 1,250 / 981 | 2 / 2 | 0.023 / 0.015 | 101.3–109.1 | 10.7–15.3 |
| Q14 | Seq Scan on T, SubPlan Function Scan `<type>_array_elements_text` | 2,500 / 3 | 1,250 / 981 | 1 / 1 | 0.002 / 0.001 | 61.4–75.8 | 12.5–15.1 |
| Q15 | Seq Scan on T | 4,975 / 2,941 | 1,250 / 981 | 29 / 29 | 0.370 / 0.244 | 98.7–119.3 | 10.5–20.3 |
| Q16 | Seq Scan on T | 1 / 78 | 1,250 / 981 | 1 / 1 | 0.016 / 0.008 | 71.8–95.6 | 11.3–17.7 |
| Q17 | Aggregate, Seq Scan on T | 5,000 / 5,000 (8 groups) | 1,250 / 981 | 1 / 1 | 0.004 / 0.004 | 98.0–123.0 | 11.2–13.1 |
| Q18 | Aggregate, Seq Scan on T | 5,000 / 5,000 (32 groups) | 1,250 / 981 | 1 / 1 | 0.008 / 0.007 | 203.8–241.0 | 19.5–23.5 |
| Q19 | Aggregate, Seq Scan on T | 25 / 4,249 | 1,250 / 981 | 1 / 1 | 0.005 / 0.004 | 362.2–412.8 | 35.7–55.2 |
| Q20 | Seq Scan on T | 5,000 / 5,000 | 1,250 / 981 | 93 / 93 | 0.981 / 0.715 | 117.4–147.4 | 11.5–16.2 |
| Q21 | Seq Scan on T | 2,500 / 30 | 1,250 / 981 | 1 / 1 | 0.013 / 0.005 | 121.8–212.0 | 11.8–21.4 |

Across all 1,500 measured executions:
- 0 shared blocks read from disk (all cache hits); 0 temp blocks; 0 ms I/O read time
- no JIT
- constant buffer counts per statement and type across all 15 rounds

The complete per-execution data is in `analysis/step6/step6c_executions.csv`.

## 7. Observations (not a conclusion)

1. **Same plans, different work.** Every statement gets the same plan shape on both types, and the scan-node estimates and
   actual rows are identical. The only estimate difference is the number of groups in Q17 and Q18 (Aggregate node: 200
   on json, 5,000 on jsonb; actual 8 and 32), which did not change the plan shape. The timing differences therefore come
   from how values are read and produced, not from different plans.
   - A scan reads 1,250 heap pages for json and 981 for jsonb, matching the table sizes from Step 6B.
   - Both types get identical default selectivity estimates for expressions on the document, without statistics: 25 rows
     for an equality, 2,500 for `EXISTS` / `JSON_EXISTS`, 1 for Q16. The estimates are far from the actual row counts
     for broad predicates (e.g. Q09: 25 estimated, 1,528 actual) on both types.
2. **Returning whole documents favours json.** Q02: 2.96 ms vs 68.7 ms. The detail runs attribute almost all of the jsonb
   time to serialisation (67.4 ms). json returns its stored text (1.87 ms); jsonb converts its binary form to text. Many
   jsonb documents are also pglz-compressed inline (Step 6B §6), which adds decompression on read; it was not measured
   separately. The jsonb output is also larger (8,986 kB vs 8,249 kB) because of its re-spacing. Q01 shows the same
   direction for one document (0.012 vs 0.030 ms).
3. **Extracting values favours jsonb, increasingly with more extractions.** Batch 1 medians:

   | Extraction | json | jsonb |
   |---|---:|---:|
   | one `record` value (2 steps: Q04, Q07, Q09) | about 57 ms | 10–11 ms |
   | one `fields` value (3 steps: Q08, Q10, Q13, Q15, Q17) | about 105 ms | 10–12 ms |
   | 10 values (Q05) | 1,070 ms | 82 ms |
   | 70 values (Q06) | 7,413 ms | 592 ms |

   - **json:** time grows roughly in proportion to the number of `->` steps, about 50 ms per step over 5,000
     documents. This is consistent with each step re-reading the text of the value it is applied to.
   - **jsonb:** a floor of about 10 ms (scan and value access, including decompression of compressed documents), then
     about 7–8 ms per additional extracted value.
4. **Casts and comparisons add little compared with extraction.** The numeric range Q11 costs slightly more than the
   text equality Q08 on both types. Q12's second comparison on the same key adds about 50 ms on json (a second
   extraction for every row) and about 5 ms on jsonb.
5. **SQL/JSON functions.** `JSON_VALUE` (Q20) and `JSON_EXISTS` (Q21) accept json by converting each document internally.
   They cost 126 / 160 ms on json against 13 / 15 ms on jsonb, similar to a 3-step operator extraction on each type.
6. **Point lookups by primary key** read 3 blocks on both types and stay below 0.1 ms. Extracting one value favours jsonb
   (0.017 vs 0.035 ms, Q03); returning the whole document favours json (0.012 vs 0.030 ms, Q01). Both directions are
   confirmed in the second session.
7. **Reproducibility.** Batch 2 reproduces every direction and every measurable difference, but with more noise.
   - Several batch 2 medians are 10–50 % higher on both types (e.g. Q07 json 85.8 vs 56.7 ms, jsonb 17.6 vs 10.3 ms).
   - The widest max/min ratio is 3.5 (Q13a jsonb, batch 2).
   - One batch 2 detail run of Q06 json took 21.7 s against 7.3 s in batch 1. Detail runs are not part of the timing
     statistics.

   Absolute milliseconds should be read as this machine under these conditions; the json/jsonb ratios are the more
   stable figure (e.g. Q05: 0.08 in batch 1, 0.085 in batch 2).
8. **Limits of these observations.**
   - Configuration: warm cache, a single client, no indexes, 5,000 documents of about 1.7 kB.
   - Storage: the Step 6B TOAST state (58 % of jsonb documents compressed inline).
   - Not covered: index effects (Step 6D), jsonb-only operators, writes, concurrency, cold cache, other document sizes.

## 8. Run log

| Step | Result |
|---|---|
| Calibration probe (not part of the results) | one execution each of Q01, Q02, Q05, Q06 per type. It confirmed the EXPLAIN JSON keys and that serialisation time is inside execution time, and estimated about 4–5 minutes per session |
| Runner, static checks and state | generated files up to date; no write statements; 950 measured statements without jsonb-only operators; ASCII; 5,000 / 5,000 rows, 2 indexes |
| Gate before timing | `sql/34` 38 / 38, `sql/36` 78 / 78 |
| Batch 1 | 235 s (15:16:08–15:20:02 local) |
| Batch 2 | 257 s (15:20:02–15:24:20 local) |
| Gate after timing, digests, analysis | `sql/36` 78 / 78, `sql/34` 38 / 38, both digests unchanged; 1,900 executions parsed, no problems |
| Wall clock | the runner reported 22,288 s in total. The two measurement sessions account for 492 s, and both completed back to back. The remaining time falls after batch 2: the Windows system log shows sleep / Modern Standby, with the last resume at 21:25 local, and the analysis files were written at 21:26:50. The measurement sessions were not interrupted |

## 9. Next step (not started)

Step 6D per the design: index experiments.
- I-1: identical btree expression indexes on both types, head-to-head.
- I-2 / I-3: GIN `jsonb_ops` / `jsonb_path_ops`, jsonb only, reported as capability.
- I-4: whether a json table can have a GIN index on `doc::jsonb`.

Separately: the jsonb-only capability queries C1–C4.
