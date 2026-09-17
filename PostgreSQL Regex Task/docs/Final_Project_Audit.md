# Final Project Audit — PostgreSQL Regex Task (Steps 1–7F)

**Date:** 13/09/2026. **Type:** read-only audit, repeated after a documentation-only correction pass.

**Nothing run or changed in the database:**
- no SQL, `EXPLAIN ANALYZE`, experiment, index build or database change
- no recorded measurement, manifest, raw data, parser output, experiment output, SQL file or script was modified

**Audit history:**

| Round | Result | What happened |
|---|---|---|
| 1. First audit | 3 ERROR · 26 WARNING · 21 PASS → status ERROR | The ERRORs were E-01 (§6.7 "only the B-tree helped"), E-02 (unscoped large-box conclusion) and E-03 ("0 shared reads" caveat) |
| 2. Correction pass | — | Documentation-only corrections in `docs/Final_Project_Conclusion.md` (below: **FPC**), `README.md` and four step reports that no manifest covers |
| 3. Re-audit | 0 ERROR · 9 WARNING · 20 PASS | Independent read-only review of the corrected files against the sources and recorded outputs |
| 4. Follow-up corrections | — | 8 of the 9 re-audit warnings were factual or wording issues and were corrected. The ninth was this audit file itself, updated here |
| 5. Final verification | see §4 | Read-only file checks and re-reading of the edited sections |

**Classification:**

| Class | Meaning |
|---|---|
| **ERROR** | A figure that does not match its source, or a statement contradicted by a recorded result. Also: a missing required artifact, a wrong current status, or a final-state mismatch |
| **WARNING** | Non-blocking: imprecise or historical wording, cosmetic issues, non-deliverable artifacts |
| **PASS** | Verified |

---

## 1. Resolution of the three ERRORs

| ID | Original error | Correction | Verification | Now |
|---|---|---|---|---|
| E-01 | FPC §6.7: *"at 32 % only the B-tree helped (1.65×)"*, contradicted by the recorded B3 benefits of J-1 and J-3 | FPC §6.7 now separates the flat-table indexes, where only the numeric B-tree helped (1.65×; geometry GiST / SP-GiST no benefit; BRIN not used), from the JSONB GiST indexes: J-1 2.82× (against a control that builds every point from the document) and J-3 1.36×. B4 is described separately: lowest medians from sequential scans (numeric 1.224 ms, geometry 1.612 ms), flat geometry GiST / SP-GiST regressed, J-1 1.14× | `analysis/step7/step7c_summary.md:38` (N-1 0.605), `:42` (J-1 0.354), `:43` (J-3 0.737), `:48` (J-1 0.876); matches the approved Step 7E qualifier "among the flat indexes" (`docs/Step7E_PostGIS_Final_Conclusion.md:265`) | **PASS** |
| E-02 | "Indexes did not pay off for boxes returning 32–78 %" in FPC §6.9, §8, §9.2, §14 and README | Every occurrence now names the scope: flat-table GiST, SP-GiST and BRIN (no benefit, not used, or regression on B4). The JSONB GiST benefits (J-1 on B3 and B4, J-3 on B3) are kept. FPC §6.9 also says benefits were smaller at larger result sizes (1.14–3.06× in 11 of 20 series), and adds a **scope-correction note**: the hash-locked Step 7D §7 and Step 7E §1 / §5 wording is superseded, not edited | Flat geometry indexes: 0 benefits in 6 series (`step7c_summary.md:39–41, 45–47`); JSONB benefits (`:42, :43, :48`). No unscoped occurrence remains in FPC or README (residual scan: 0 hits in files no manifest covers) | **PASS** |
| E-03 | FPC §11 caveat 1: *"Warm cache (0 shared reads in the measured runs)"*, contradicted by Step 6E per-run data | FPC §11 caveat 1 now says: 0 shared reads in the measured runs of Steps 6C, 6D and 7C; Step 6E recorded 48–53 shared reads in 257 of 605 measured runs, all in update series with secondary indexes; the 605 rows include 5 repeated attempts and 152 W1b loop rows without buffer data; 255 of the 600 used runs have shared reads; effect on the timing ratios not assessed; no explanation offered. The Step 6E report's own "(no shared reads)" wording carries a dated correction note with the same facts | `analysis/step6/step6e_attempts.csv`: 605 `measured` rows (600 used, 5 not used), 152 empty `shared_read` (all W1b), 257 non-zero (range 48–53), 255 of them in used rows, all in UA-1 / UA-2 / UA-3 with X-1 … X-4 and UB-R238 / UB-R5000 with X-1. Raw: 325 non-zero `Shared Read Blocks` in `step6e_session1_raw.txt`; 0 in the 6C (6,004 entries) and 6D (14,212 entries) EXPLAIN files; 0 in 7C measured runs (the only 2 non-zero entries are in the forced diagnostic run B4 on N-1, `step7c_session1_raw.txt:78906, 78938`) | **PASS** |

## 2. Status of the original warnings (W-01 … W-26) and the re-audit findings

| ID | Issue (first audit) | Status | Where corrected / why it remains |
|---|---|---|---|
| W-01 | "Verification scripts rerun before and after every writing step" | Fixed | FPC §10: table with the runners that actually ran each script (checked against `sql/run_step*.ps1`); heading says before / after / inside harness "as recorded per step" |
| W-02 | "`verify_raw_access_logs()` 10 / 10 in every check" | Fixed | FPC §3.6, §7, §8, §10: 10 / 10 in every run that called it (Steps 3B-1 … 3C, 5B, 6B via `sql/29`, 7A.2, 7B, 7C, 7F); Steps 6C–6E covered by the `log_regex` digest |
| W-03 | "Safe execution pattern (Steps 3–7)"; "every step has a runner" | Fixed | FPC §10: scope per step. Rolled-back harnesses in Steps 5B, 6B, 6D, 7B, 7C, 7F; generated SQL with allowlists from Step 6C; runner sentence lists the steps without a runner |
| W-04 | `v_parser_evaluation` | Fixed in FPC | FPC §3.1: `v_parsed_access_logs`, `v_parser_field_comparison`, `v_parser_mismatches`. The Step 3A design table still shows the design-time name (see WR-2) |
| W-05 | P3 omitted; "oracle for every later experiment" | Fixed | FPC §4.4 (P3, 14.413 ms); §14 item 2 (oracle for Step 6C / 6D and, through `flat_numeric`, Step 7C) |
| W-06 | "vs I-1" | Fixed | FPC §5.5: "W1 bulk insert vs X-1 (Step 6E)", "UA-1 238-row update vs X-1 (Step 6E)" |
| W-07 | "5–13×" without qualifier | Fixed | FPC §7, §9.2, §14 and README: "about 5–13× … without indexes (Q03 about 2×)". The quoted Step 6F conclusion (FPC §5.10, `README.md` Step 6F block) keeps the source wording, which says "without indexes" |
| W-08 | §5.10 condensed | Fixed | FPC §5.10: point 3 "because json paid text parsing for every index entry"; point 5 second sentence; the Step 6F "does not claim" paragraph |
| W-09 | GIN range; `jsonb_set` wording; §8 citation | Fixed | FPC §7: `jsonb_path_ops` 0.027–0.528 ms (both types 0.03–0.8 ms); `jsonb_set` weakness reworded; FPC §8 basis "Step 6F §4, §8, §11" |
| W-10 | §11 methodology generalisations | Fixed | FPC §11: order per step (6C / 6D alternating; 6E ABBA with the configuration order reversed; 7C rotated and reversed); second batch / session per step; correctness-first per step; `TIMING OFF` in 6C / 6D / 6E / 7C; sub-0.1 ms wording |
| W-11 | Battery cause stated as fact | Fixed | FPC §11 caveat 4, §13 item 4, README: "running on battery afterwards; the cause is not proven" (Step 6F wording) |
| W-12 | "First builds usually slowest" | Fixed | FPC §11 caveat 10: 9 of 10 Step 7C indexes; 6 of 12 Step 6D build series (`analysis/step6/step6d_builds.csv`) |
| W-13 | Q11b under "row estimates" | Fixed | FPC §11 caveat 7, §13 item 5: accurate estimate (3,086 vs 3,064), cost-model blind spot |
| W-14 | §12 lists incomplete | Fixed | FPC §12: added other document shapes / compression / page sizes, normal checkpoint timing, write planning comparison, Step 6E shared-reads effect, nearest-neighbour centres, geometry method for D3 / D4 / D5 / D7, causes of misestimates and heap size; source headers extended |
| W-15 | "all nearest-neighbour queries" | Fixed | FPC §6.3: "K1, K2 and K3 (K1g had no SP-GiST configuration)" |
| W-16 | "sphere is cheaper" unqualified; derived ranges | Fixed | FPC §6.8 (configurations named; J-0y / J-2 excluded), §6.9, §7, §9.3, §14: "measurably faster for computing the distance to every point", plus the Step 7E "wherever many rows reach the distance function" qualifier |
| W-17 | "B-tree faster for … B4" | Fixed | FPC §9.3: numeric B-tree table faster; on B4 its index was not used (sequential scan) |
| W-18 | "for reads" dropped | Fixed | FPC §14 item 4 and README: "for reads (write cost not measured)" |
| W-19 | "the flat tables have 39 heap pages" | Fixed | FPC §6.4: `flat_geom_brin`, like the other flat geometry / geography tables, has 39 heap pages |
| W-20 | "without effect on the results" | Fixed | FPC §13 item 8: no change to result sets, verdicts or integrity checks; index-size variation noted; runner fixes "before the affected database runs or between runs" |
| W-21 | Unlabelled PostGIS rows in §7; K3 / P1 / P2 undefined | Fixed | FPC §7: class labels (I / IM / GG / NB, Step 7B finding) and inline definitions of K3, P1, P2 |
| W-22 | Architecture vs retained objects | Fixed | FPC §8 "Experiment objects" row: retained json table and GIN `jsonb_ops`, no spatial GiST index, `log_regex_gis` tables are experiment copies — not the recommended architecture |
| W-23 | README obsolete status wording | Fixed | `README.md`: intro framed as "Source table (Step 5B, 12/09/2026)" / "Verification at that step"; "Step 1, sample data"; "in this step (they followed in Steps 6C–6E)"; "the conclusion followed in Step 6F" (6C, 6D); "none had been measured before this step" |
| W-24 | README "every index added planning time"; "5,000 points" | Fixed | `README.md`: "planned measurably slower in 97 of 109 series (never faster)"; "5,000 rows (4,161 points)" |
| W-25 | Superseded status lines in reports no manifest covers | Fixed | Step 6F (top, §13), Step 7F (status, §11.5, closing line), Step 3A (status): past tense with forward references. Hash-locked reports keep their dated status lines (see WR-1) |
| W-26 | `data/__pycache__/` | Remains | Not documentation; outside the scope of this pass (see WR-3) |

**Findings from the re-audit (round 3), and how they were handled:**

| ID | Finding | Status |
|---|---|---|
| R-03 | README "Indexes paid off up to about 22 % of rows" read as an upper limit (D4 at 41 % had benefits) | Fixed: README and FPC §6.9 / §14 now say "mainly" and that benefits were smaller at larger result sizes (D4 2.3–3.1×; 1.14–3.06× in 11 of 20 series) |
| R-05 | "257 of 605 measured runs" mixed attempts and runs | Fixed: FPC §11 and the Step 6E note state 5 repeated attempts, 152 W1b rows without buffer data, and 255 of 600 used runs |
| R-06 | Step 6E correction note merged the following sentence into its last bullet | Fixed: the sentence is a separate paragraph again |
| R-09 | §5.10 point 3 condensed | Fixed (see W-08) |
| R-15 | "before and after their writing stages" | Fixed (see W-01) |
| R-17 | Harness list missed Steps 6B and 6D | Fixed (`docs/Step6B_Build_JSON_Tables_and_Storage.md:246–247`; `docs/Step6D_JSON_vs_JSONB_Index_Experiment.md:134, 277`) |
| R-18 | Runner sentence named only Step 3B-2 as an exception | Fixed (see W-03) |
| R-20 | README battery wording | Fixed (see W-11) |
| R-22 | §12 header citations | Fixed (see W-14) |
| R-29 | This audit file still showed the old result | Fixed by this update |
| — | Pre-existing broken row in `docs/Step3A_Parser_Design.md` (table §10.3, row F1: 3 cells in a 4-column table) | Fixed: Signal and Effect cells separated, wording kept |

## 3. Files changed by the correction pass

| File | Manifest status | Nature of the changes |
|---|---|---|
| `docs/Final_Project_Conclusion.md` | none | E-01, E-02 (including the scope-correction note), E-03; W-01 … W-22; R-03, R-05, R-15, R-17, R-18, R-22; status line links this audit |
| `README.md` | none | E-02 (two lines); W-07, W-11, W-18, W-23, W-24; R-03; audit link in the status block |
| `docs/Step6E_JSON_vs_JSONB_Write_Update_Experiment.md` | none | Dated correction note for the "(no shared reads)" wording (E-03 origin); R-05, R-06 |
| `docs/Step6F_JSON_vs_JSONB_Final_Comparison_Report.md` | none | Status lines put in the past tense, with a forward reference (W-25) |
| `docs/Step7F_PostGIS_Cleanup_and_Final_State_Plan.md` | none | Status lines put in the past tense, with a forward reference (W-25) |
| `docs/Step3A_Parser_Design.md` | none | Status line put in the past tense (W-25); broken table row repaired |
| `docs/Final_Project_Audit.md` | none | This report |

**Not changed:**
- **Hash-locked reports:** Steps 6C, 6D, 7A, 7A.1, 7A.2, 7B, 7C design, 7C, 7D, 7E.
- **Other artifacts:** all SQL, scripts, `analysis/` outputs, manifests and `data/` files.
- **Measured numbers:** every original measured number and every experiment conclusion is preserved. E-02 narrows the scope of an over-general statement to what the recorded verdicts support.

## 4. Final verification (read-only)

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Every final conclusion supported by recorded results | PASS | E-01 … E-03 resolved (§1); re-audit R-01 … R-28 found no unsupported conclusion; follow-up fixes re-read |
| 2 | Important figures match their source reports | PASS | Unchanged figures re-verified in the re-audit (P-01 … P-05 of the first audit, R-07 … R-28); new figures (shared-read counts, runner coverage, harness steps, first-build counts) checked against `step6e_attempts.csv`, `sql/run_step*.ps1`, the Step 6B / 6D reports and `step6d_builds.csv` |
| 3 | No conclusion contradicts an earlier measured result | PASS | Residual scan of flagged wording: 0 hits in files no manifest covers. Remaining hits are only in hash-locked historical reports, superseded by FPC (WR-1) |
| 4 | Fair comparisons separated from JSONB-only / representation-specific findings | PASS | FPC §5.5, §5.8, §6.1 classes, §7 row labels, §9.3 |
| 5 | "Not measured" / "not tested" clearly identified | PASS | FPC §4.4, §6.6, §9.3, §11 caveat 1 (Step 6E effect not assessed), §12 (extended), §14 item 6 |
| 6 | Recommended architecture matches the implemented project | PASS | FPC §8 states that no object was built for it and names the retained experiment objects that differ from it |
| 7 | README status and links correct and current | PASS | `FINAL_CONCLUSION_REPORTED`; links to FPC, Step 7E, Step 7F and this audit |
| 8 | All referenced reports, files and scripts exist | PASS | 177 Markdown links outside code, 0 broken; `sql/00` … `sql/52` all present. Only documented planned / replaced names are absent (`sql/53_remove_postgis_objects.sql`, `sql/42_verify_json_write_state.sql`) |
| 9 | Manifests and recorded checks consistent | PASS | Manifests re-hashed: Step 6C 11 / 11, Step 6D 26 / 26, Step 7B 14 / 14, Step 7F 32 / 32, 0 mismatches. Check files unchanged: 6E preflight 63 / 0, 6E measurement 26 / 0, 7B 317 / 0, 7C harness 154 / 0, 7C 943 / 0 / 0, 7F harness 48 / 0, 7F 343 / 0; 0 FAIL rows |
| 10 | No obsolete project status remains | PASS with warning | Current documents corrected; dated status lines remain only in hash-locked reports (WR-1) |
| 11 | No TODO / FIXME / placeholder / accidental test artifact | PASS with warning | No work markers in the README or project reports (the words appear only in this audit's own check list); `data/__pycache__` remains (WR-3) |
| 12 | Documented final database state = verified Step 7F state | PASS | FPC closing table equals `analysis/step7/step7f_cleanup_checks.txt` Z-01, Z-02 (`15|15|0|`), Z-03 (49 / 30 / 16 / 8 / 6 / 0), ZP-04 (14 Step 6D indexes), Z-22 (292 after checks, 0 FAIL) |
| 13 | Encoding and obvious formatting | PASS | 35 Markdown files: valid UTF-8, no BOM, no CRLF, no tabs, no mojibake, balanced code fences (the U+FFFD in `docs/Step2_Raw_Log_Profile.md:44` is intentional data content). Table cell counts consistent in all edited files |
| 14 | Internally consistent and submission-ready | PASS with warnings | No ERROR remains; the warnings below are non-blocking |

**Database state (verified without running SQL):**
- **Last database verification:** the Step 7F after-checks (343 PASS / 0 FAIL, run 2026-09-13 05:53:45 UTC) are still the latest recorded verification.
- **No database access since then:** no SQL, psql session or database command was run afterwards (final conclusion, first audit, correction pass, re-audit).
- **No other file changed:** no SQL file, script, `analysis/` output or `data/` file was written after that run, apart from the run's own log at the same timestamp.
- **Live re-check:** a read-only live check is available (`sql/run_step7f_cleanup.ps1 -AfterOnly`) but was not run, because this pass excluded SQL.

**Git:** the project folder is untracked; nothing was committed.

## 5. Remaining warnings (non-blocking)

| ID | Warning | Why it remains | Mitigation |
|---|---|---|---|
| WR-1 | Hash-locked reports keep dated wording now superseded. Large-box wording: `docs/Step7D_PostGIS_Results_Analysis.md:332`, `docs/Step7E_PostGIS_Final_Conclusion.md:55–56, 171–172`. Other examples: "at lower cost" (`Step7E:316`), "first build usually slowest" (`Step7D:684`), "5–13×" and "before and after every writing step" (`Step7A:26, 254`), "has not been started" (`Step7C:408`, `Step7D:9`, `Step7E:6, 438`) | Editing them would break the Step 7B / Step 7F manifests, which must not change | The FPC scope-correction note (§6.9) and the corrected FPC / README wording supersede them; the dated status lines are clearly historical |
| WR-2 | `docs/Step3A_Parser_Design.md:521` design table lists the evaluation view as `v_parser_evaluation` | It is the design-time name inside the design record | The implemented names are recorded in `docs/Step3B3_F1_Parser.md` and FPC §3.1 |
| WR-3 | `data/__pycache__/` holds two Python bytecode files (dated 2026-09-11) | Not documentation; not referenced; not in any manifest. Removing files was outside this documentation-only pass | Harmless; can be deleted before packaging |

FINAL PROJECT AUDIT: PASS WITH WARNINGS
