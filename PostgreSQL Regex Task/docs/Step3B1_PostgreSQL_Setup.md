# Step 3B-1 — PostgreSQL Setup

**Status:** complete and verified (11/09/2026). Stopped for review.

Scope of this step: database, schema, RAW LOG input table, load, verification and protection of the raw input.
**Not included:** regex extraction, parser functions, JSON/JSONB, PostGIS, the answer-key table and the reference
tables (later steps).

---

## 1. What was built

| Object | Type | Purpose |
|---|---|---|
| `postgresql_regex_task` | database | UTF-8, PostgreSQL 17 builtin locale `C.UTF-8` |
| `log_regex` | schema | All task objects |
| `log_regex.raw_access_logs` | table | The Step 1 RAW LOGS: `log_id`, `raw_log` — 5,000 rows |
| `log_regex.raw_log_fingerprint` | table | Per-row baseline: NULL flag, character length, UTF-8 byte length, SHA-256 |
| `log_regex.raw_load_audit` | table | One-row load record: source file SHA-256, counts, dataset digest, who/when |
| `log_regex.raw_access_logs_digest()` | function | Dataset digest, identical definition to `scripts/raw_csv_digest.py` |
| `log_regex.block_raw_input_modification()` | trigger function | Rejects any write with SQLSTATE `LR001` |
| `raw_access_logs_read_only`, `raw_log_fingerprint_read_only`, `raw_load_audit_read_only` | triggers | Statement-level guards for INSERT, UPDATE, DELETE, TRUNCATE (also MERGE and COPY FROM) |
| `log_regex.verify_raw_access_logs()` | function | Repeatable 10-point integrity check against the baseline |

The functions above protect and check the raw input only; none of them parses logs.

## 2. Files

| File | Purpose |
|---|---|
| [sql/00_create_database.sql](../sql/00_create_database.sql) | Create `postgresql_regex_task` (run on database `postgres`) |
| [sql/01_create_schema_and_raw_table.sql](../sql/01_create_schema_and_raw_table.sql) | Schema `log_regex` and `raw_access_logs` |
| [sql/02_load_raw_access_logs.sql](../sql/02_load_raw_access_logs.sql) | Client-side `\copy` of `data/raw_access_logs.csv` |
| [sql/03_protect_raw_input.sql](../sql/03_protect_raw_input.sql) | Fingerprints, load audit, digest, guard triggers, integrity check |
| [sql/04_verify_raw_access_logs.sql](../sql/04_verify_raw_access_logs.sql) | Integrity checks, CSV comparison, special rows, protection tests; fails on any problem |
| [sql/run_step3b1_setup.ps1](../sql/run_step3b1_setup.ps1) | Runs everything in order, then the export round trip |
| [scripts/raw_csv_digest.py](../scripts/raw_csv_digest.py) | Expected values computed from the CSV alone (no database) |

## 3. How to run

```powershell
# Connection: standard PostgreSQL variables (nothing secret is stored in this project)
$env:PGHOST = '127.0.0.1'; $env:PGPORT = '5432'; $env:PGUSER = 'postgres'; $env:PGPASSWORD = '<password>'

powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b1_setup.ps1"
```

- The runner ignores `PGDATABASE`; every `psql` call names its database.
- It stops at the first failure and exits non-zero.
- **Rebuild:** `00_create_database.sql` and `01_…sql` use plain `CREATE` on purpose, so a second run fails instead of
  replacing the raw input. To rebuild, drop the database deliberately (`DROP DATABASE postgresql_regex_task;` on
  database `postgres`) and run the runner again.
- For this run the connection variables (host, port, user, password) were loaded into the PowerShell process from the
  local `.env` already used for this server by `packers_movers_synthetic_data`. They were not written to this project.
- Just the integrity check, at any time:
  `psql -d postgresql_regex_task -c "SELECT * FROM log_regex.verify_raw_access_logs();"`

## 4. Database settings

| Setting | Value | Why |
|---|---|---|
| Server | PostgreSQL 17.9 on x86_64-windows | Local service `postgresql-x64-17` |
| Encoding | `UTF8` | Byte-exact storage; 294 RAW LOGS contain non-ASCII characters |
| Locale provider | `builtin` | PostgreSQL 17 provider, independent of the Windows locale (the other databases on this server use `English_India.1252`) |
| Builtin locale | `C.UTF-8` | Regex character classes and case mapping follow Unicode, so later regex behaviour is reproducible |
| `LC_COLLATE` / `LC_CTYPE` | `C` / `C` | Keeps the libc side locale-neutral |

Environment check on the new database (resolves Step 3A §15 items "UTF-8 encoding" and "NBSP behaviour"):

| Check | Result |
|---|---|
| NBSP `U&'\00A0'` matches `[[:space:]]` (same class as `\s`) | true |
| `é` matches `[[:alpha:]]` | true |
| `upper('é') = 'É'` | true |
| `°` length: characters / UTF-8 bytes | 1 / 2 |

## 5. Raw input table

| Column | Type | Rules |
|---|---|---|
| `log_id` | integer | NOT NULL, primary key, `log_id > 0` |
| `raw_log` | text | Nullable. SQL NULL (1 row) and empty string (1 row) are distinct values |

Both the table and its columns carry comments describing these rules.

## 6. Load method

`\copy log_regex.raw_access_logs (log_id, raw_log) FROM 'data/raw_access_logs.csv' WITH (FORMAT csv, HEADER MATCH, ENCODING 'UTF8')`

| Choice | Effect |
|---|---|
| Client-side `\copy` | `psql` reads the file; no server file permissions needed |
| `FORMAT csv` | Unquoted empty ⇒ SQL NULL; `""` ⇒ empty string; quoted CR, LF, TAB and NBSP kept |
| `HEADER MATCH` | Load fails unless the header is exactly `log_id,raw_log` |
| `ENCODING 'UTF8'` | File decoded as UTF-8 regardless of the client encoding |
| No expressions | Columns map 1:1; no trimming, defaults or conversions |
| Transaction + emptiness check | The load refuses to run if the table already has rows |

Result: `COPY 5000`, `log_id` 1–5,000.

## 7. Protection of the raw input

| Layer | What it does |
|---|---|
| Guard triggers | Statement-level `BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE` on all three input tables. Fires even when no row would be affected (`UPDATE … WHERE false`), for `MERGE`, and for `COPY FROM`. Error `LR001` with a rebuild hint |
| Foreign key | `raw_log_fingerprint.log_id → raw_access_logs.log_id` also stops a plain `TRUNCATE` of the raw table and a `DROP TABLE` without `CASCADE` |
| Fingerprints | SHA-256, lengths and NULL flag of every row, taken right after the load and themselves guarded |
| Load audit | Source file SHA-256 (`a94fc3cc…`), counts and dataset digest, guarded |
| Integrity check | `verify_raw_access_logs()` recomputes everything and compares with the baseline; also checks that all 3 guards are enabled |
| Privileges | `REVOKE ALL … FROM PUBLIC` on the three tables |

**Limits (by design):** the guards prevent accidental modification. A superuser or table owner can still deliberately
disable triggers (`ALTER TABLE … DISABLE TRIGGER`, `session_replication_role = replica`) or drop objects; DDL is not
blocked. Any such change is detected by `verify_raw_access_logs()` (checks 8–10). A SELECT-only parser role
(Step 3A §3.2) is deferred until parser runs exist.

## 8. Verification results

### 8.1 Expected values computed from the CSV (no database)

`scripts/raw_csv_digest.py`: file SHA-256 `a94fc3cc1a11a779480cd8dedbe949b1bddcb267910c366ff933b3df076e661e` ·
5,000 rows · 5,000 distinct `log_id`s, contiguous 1–5,000 · dataset digest
`1bcff42a6cd6634bd722064b629a0088dbbd7c67ac5276d013c505ac3fb06275`.

Dataset digest definition (used in Python and SQL): SHA-256 of the lines `<log_id>:<hex SHA-256 of UTF-8 raw_log>`
(`<log_id>:NULL` for SQL NULL), joined with LF, in `log_id` order.

### 8.2 Integrity against the load baseline — 10 / 10 passed

| # | Check | Expected | Actual |
|---:|---|---|---|
| 1 | Row count equals load audit | 5000 | 5000 |
| 2 | `log_id` range equals load audit | 1..5000 | 1..5000 |
| 3 | `log_id`s distinct and contiguous | 5000 | 5000 |
| 4 | NULL `raw_log` rows | 1 | 1 |
| 5 | Empty-string `raw_log` rows | 1 | 1 |
| 6 | Total characters | 1194267 | 1194267 |
| 7 | Total UTF-8 bytes | 1194874 | 1194874 |
| 8 | Rows differing from their fingerprint | 0 | 0 |
| 9 | Dataset digest equals load audit | `1bcff42a…06275` | `1bcff42a…06275` |
| 10 | Read-only guard triggers enabled | 3 | 3 |

### 8.3 Independent comparison with the CSV — 14 / 14 matched

| # | Check | CSV (Python) | Database |
|---:|---|---|---|
| 1 | Dataset digest (per-row SHA-256) | `1bcff42a…06275` | `1bcff42a…06275` |
| 2 | Source file SHA-256 recorded at load | `a94fc3cc…e661e` | `a94fc3cc…e661e` |
| 3 | Row count | 5000 | 5000 |
| 4 | `log_id` of SQL NULL `raw_log` | 4240 | 4240 |
| 5 | `log_id` of empty-string `raw_log` | 4387 | 4387 |
| 6 | Whitespace-only rows | 2 | 2 |
| 7 | Rows containing LF | 4 | 4 |
| 8 | Rows containing CR | 2 | 2 |
| 9 | Rows containing TAB | 2 | 2 |
| 10 | Rows containing NBSP (U+00A0) | 1 | 1 |
| 11 | Rows containing non-ASCII characters | 294 | 294 |
| 12 | Longest `raw_log` (characters) | 2289 | 2289 |
| 13 | Total characters | 1194267 | 1194267 |
| 14 | Total UTF-8 bytes | 1194874 | 1194874 |

Because check 1 compares a SHA-256 of every row, it proves each of the 5,000 values is unchanged, not only the totals.

### 8.4 Special rows stored exactly

| `log_id` | Case | NULL | Characters | UTF-8 bytes | First characters (`<CR>`/`<LF>`/`<TAB>` shown as markers) |
|---:|---|---|---:|---:|---|
| 1 | GEN-00001 | no | 333 | 333 | `May 17 22:00:20 lb01 gatekeeper[2671]: {"level": "notice", "…` |
| 4240 | EC-129 | **yes** | — | — | SQL NULL |
| 4387 | EC-131 | no | 0 | 0 | empty string |
| 4399 | EC-132 | no | 5 | 5 | five spaces |
| 4406 | EC-133 | no | 4 | 4 | `<TAB> <CR><LF>` |
| 4834 | EC-143 | no | 349 | 349 | `2026-05-13T11:05:44Z \| entity=SERVICE_ACCOUNT \| …` (stack trace on later lines) |
| 4859 | EC-144 | no | 344 | 344 | `May 14 06:00:00 api-gw02 gatekeeper[3310]: {<LF>  "entity": …` |
| 4864 | EC-145 | no | 2289 | 2289 | `198.51.100.88 - - [15/May/2026:10:10:10 +0000] "GET /search?…` |
| 4940 | EC-148 | no | 210 | 210 | `2026-05-18T09:00:00Z \| entity=USER \| …` (ends with CR LF) |
| 5000 | GEN row | no | 270 | 270 | `<38>1 2026-04-06T16:55:06.247Z k8s-api01 openvpn 7578 ACCESS…` |

### 8.5 Protection tests — 11 / 11 rejected

Each statement ran in a sub-transaction that is always rolled back, so nothing could persist even if a guard failed.

| # | Statement | Rejected | SQLSTATE | Message |
|---:|---|---|---|---|
| 1 | `INSERT INTO raw_access_logs … VALUES (5001, 'injected')` | yes | LR001 | INSERT … is blocked: the RAW LOG input is read-only |
| 2 | `UPDATE raw_access_logs SET raw_log = raw_log WHERE log_id = 1` | yes | LR001 | UPDATE … is blocked |
| 3 | `UPDATE raw_access_logs SET raw_log = 'changed' WHERE false` | yes | LR001 | UPDATE … is blocked |
| 4 | `DELETE FROM raw_access_logs WHERE log_id = 5000` | yes | LR001 | DELETE … is blocked |
| 5 | `TRUNCATE raw_access_logs` | yes | 0A000 | cannot truncate a table referenced in a foreign key constraint |
| 6 | `TRUNCATE raw_access_logs CASCADE` | yes | LR001 | TRUNCATE … is blocked |
| 7 | `MERGE INTO raw_access_logs … WHEN MATCHED THEN UPDATE` | yes | LR001 | UPDATE … is blocked |
| 8 | `UPDATE raw_log_fingerprint SET sha256 = NULL …` | yes | LR001 | UPDATE on raw_log_fingerprint is blocked |
| 9 | `DELETE FROM raw_log_fingerprint WHERE log_id = 1` | yes | LR001 | DELETE on raw_log_fingerprint is blocked |
| 10 | `UPDATE raw_load_audit SET dataset_digest = repeat('0', 64)` | yes | LR001 | UPDATE on raw_load_audit is blocked |
| 11 | `TRUNCATE raw_load_audit` | yes | LR001 | TRUNCATE on raw_load_audit is blocked |

Test 5 is rejected by the foreign key before the trigger fires; with `CASCADE` (test 6) the guard trigger rejects it.

After the tests, `verify_raw_access_logs()` again returned 10 / 10 passed.

### 8.6 Export round trip — byte-identical

The table was exported with
`\copy (SELECT log_id, raw_log FROM log_regex.raw_access_logs ORDER BY log_id) TO … WITH (FORMAT csv, HEADER true, FORCE_QUOTE (raw_log), ENCODING 'UTF8')`.

| File | SHA-256 |
|---|---|
| `data/raw_access_logs.csv` (Step 1) | `a94fc3cc1a11a779480cd8dedbe949b1bddcb267910c366ff933b3df076e661e` |
| Export of `log_regex.raw_access_logs` | `a94fc3cc1a11a779480cd8dedbe949b1bddcb267910c366ff933b3df076e661e` |

This also resolves the Step 3A §15 item on Windows COPY line endings: the client-side export writes LF and reproduces
the Step 1 file exactly (header, quoting, NULL vs empty string, embedded CR/LF).

### 8.7 Other confirmations

- `verify_raw_access_logs()` run again separately after setup: 10 / 10 passed.
- Load audit: `loaded_by` postgres, `loaded_at` 2026-09-11 17:33:20+05:30.
- Step 1 files unchanged: `python data/generate_raw_logs.py --check` reports all three files identical.

## 9. Issues found during setup

| Issue | Effect | Fix |
|---|---|---|
| First runner attempt: `Get-FileHash` could not open `data/raw_access_logs.csv` because another process had it open (it needs exclusive read access) | Runner stopped at step 1, before any database command; confirmed afterwards that `postgresql_regex_task` did not exist | Runner now hashes files with a shared-read stream (`Get-Sha256Hex`) |
| Pre-run review: `verify_raw_access_logs()` used `CROSS JOIN LATERAL` after a comma list, which cannot reference the earlier items | Would have failed at function creation | Rewritten as a comma-list `LATERAL` item before the first run |
| Pre-run review: the NBSP constant in `raw_csv_digest.py` was an invisible literal character | None (count was correct) | Replaced with the explicit escape `\u00a0` |

## 10. Relation to the Step 3A design

| Step 3A item | Status |
|---|---|
| C-08 database `postgresql_regex_task`, schema `log_regex` | Done |
| §3.1 input `raw_access_logs(log_id, raw_log)` loaded with CSV semantics | Done |
| §3.2 load fidelity, per-row fingerprint, `log_id` identity, read-only raw table | Done (guard triggers; SELECT-only parser role deferred) |
| T-01 load fidelity (5,000 rows, 1 NULL, 1 empty, re-export SHA-256, fingerprints) | Passed |
| T-02 preservation | Baseline, guards and check in place; before/after comparison per parser run comes with the parser |
| §15 items: UTF-8 encoding · NBSP behaviour · COPY re-export hash on Windows | Resolved (§4, §8.6) |
| §15 item: `inet` behaviour | Resolved in Step 3B-2 ([Step3B2_IP_Validation.md](Step3B2_IP_Validation.md)) |
| Additions not in the design | `raw_load_audit`, `raw_access_logs_digest()`, `verify_raw_access_logs()`, builtin `C.UTF-8` locale |
| Not in this step | Answer-key table, reference tables, token library, format detection, parser output tables |
