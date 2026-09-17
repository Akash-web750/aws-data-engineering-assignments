<#
.SYNOPSIS
    Step 6E - JSON vs JSONB write/update measurement experiment (after the approved setup and preflight).

.DESCRIPTION
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.

    Order (every check reported PASS/FAIL in analysis/step6/step6e_measurement_checks.txt):
      1. static (R-01 .. R-05): sql/41-42 unchanged; sql/43 matches scripts/step6e_json_write_measure.py; sql/36-40 match the
         Step 6C/6D generators; every statement of sql/43 is a designed form confined to log_regex_json_write; ASCII
      2. manifests (M-01, M-02): Step 6C and Step 6D outputs unchanged
      3. before (G-01 .. G-03, V-01 .. V-03): log_regex, log_regex_json and Step 6D index digests; sql/34 38/38, sql/38 final
         70/70 (read-only sessions); sql/42 preflight 41/41 (other sessions idle, staged input, write schema, X-0 .. X-4)
      4. session 1 (S-01): sql/43 via scripts/step6e_json_write_measure.py run-session -> step6e_session1_raw.txt
      5. analysis (A-01): all correctness checks passed; CSV/markdown outputs; blocks with a median below 0.1 ms
      6. session 2 (S-02, A-02), only for those blocks: sql/44 -> step6e_session2_raw.txt; analysis again with both sessions
      7. after (G-04 .. G-06, V-04 .. V-06, M-03, M-04): same digests and verifications; sql/42 41/41 again (write tables
         empty again), manifests
    A failed check in steps 1-3 stops before any measurement; a failed session stops the runner.

.PARAMETER AnalyzeOnly
    Re-run only the analysis of existing raw session files.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step6e_json_writes.ps1"
#>
param(
    [string]$PsqlPath = "C:\Program Files\PostgreSQL\17\bin\psql.exe",
    [switch]$AnalyzeOnly
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot
$env:PGCLIENTENCODING = 'UTF8'
$env:PYTHONDONTWRITEBYTECODE = '1'
[Environment]::SetEnvironmentVariable('PGDATABASE', $null, 'Process')
$Database = 'postgresql_regex_task'
$ReadOnlyOptions = '-c default_transaction_read_only=on'
$Python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $Python) { throw "python not found" }
$Measure = 'scripts/step6e_json_write_measure.py'
$Raw1 = 'analysis/step6/step6e_session1_raw.txt'
$Err1 = 'analysis/step6/step6e_session1_stderr.txt'
$Raw2 = 'analysis/step6/step6e_session2_raw.txt'
$Err2 = 'analysis/step6/step6e_session2_stderr.txt'
$ReportFile = 'analysis/step6/step6e_measurement_checks.txt'
$Manifest6C = 'analysis/step6/step6d_baseline_step6c_sha256.txt'
$Manifest6D = 'analysis/step6/step6e_baseline_step6d_sha256.txt'
$ExpectedLogRegex = 'f8042db0318656b5929c86ea1f7888d4 over 203 items'
$ExpectedJsonData = '9e6f883112c4a01781bdce5cf9bf3a28 over 10 items'
$ExpectedIndexes = 'e20752ca02d09e89281503569650d0ce over 14 indexes, 9510912 bytes'
$Results = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string]$Id, [string]$Name, [bool]$Pass, [string]$Detail)
    $result = if ($Pass) { 'PASS' } else { 'FAIL' }
    $Results.Add([pscustomobject]@{ Id = $Id; Result = $result; Name = $Name; Detail = $Detail })
    Write-Host ("{0,-5} {1}  {2}: {3}" -f $Id, $result, $Name, $Detail)
}

function Get-Sha256Hex {
    param([string]$Path)
    $stream = [System.IO.File]::Open((Resolve-Path -LiteralPath $Path).ProviderPath, 'Open', 'Read', 'ReadWrite')
    try { $sha = [System.Security.Cryptography.SHA256]::Create(); try { return (-join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() } }
    finally { $stream.Dispose() }
}

function Invoke-Capture {
    param([scriptblock]$Command)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& $Command 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $previous }
    return @{ Lines = $lines; Code = $code }
}

function Invoke-PsqlFile {
    param([string]$File, [string]$Variable, [switch]$ReadOnly)
    $previousOptions = $env:PGOPTIONS
    $env:PGOPTIONS = if ($ReadOnly) { $ReadOnlyOptions } else { $null }
    try {
        $psqlArgs = @('-X', '-v', 'ON_ERROR_STOP=1', '-d', $Database, '-f', $File)
        if ($Variable) { $psqlArgs += @('-v', $Variable) }
        Write-Host "---- psql -f $File $Variable"
        return (Invoke-Capture -Command { & $PsqlPath @psqlArgs })
    }
    finally { $env:PGOPTIONS = $previousOptions }
}

function Invoke-ReadOnlyQuery {
    param([string]$Sql)
    $previousOptions = $env:PGOPTIONS
    $env:PGOPTIONS = $ReadOnlyOptions
    try { $r = Invoke-Capture -Command { & $PsqlPath -X -A -t -v ON_ERROR_STOP=1 -d $Database -c $Sql } } finally { $env:PGOPTIONS = $previousOptions }
    if ($r.Code -ne 0) { return "query failed with exit code $($r.Code)" }
    return (($r.Lines -join ' ').Trim())
}

function Test-Manifest {
    param([string]$Id, [string]$Name, [string]$Path, [int]$ExpectedFiles)
    if (-not (Test-Path -LiteralPath $Path)) { Add-Check $Id $Name $false "manifest $Path missing"; return }
    $lines = @(([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)).Trim() -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $problems = @()
    foreach ($line in $lines) {
        if ($line -notmatch '^([0-9a-f]{64})  (\S+)$') { $problems += 'malformed line'; continue }
        $hash = $Matches[1]; $file = $Matches[2]
        if (-not (Test-Path -LiteralPath $file)) { $problems += "missing $file" } elseif ((Get-Sha256Hex -Path $file) -ne $hash) { $problems += "changed $file" }
    }
    if ($lines.Count -ne $ExpectedFiles) { $problems += "$($lines.Count) entries instead of $ExpectedFiles" }
    Add-Check $Id $Name ($problems.Count -eq 0) $(if ($problems.Count) { $problems -join '; ' } else { "$($lines.Count) files match $Path" })
}

function Test-Verification {
    param([string]$Id, [string]$Name, [string]$File, [string]$Variable, [string]$PassedPattern, [switch]$ReadOnly)
    $r = Invoke-PsqlFile -File $File -Variable $Variable -ReadOnly:$ReadOnly
    $passed = @($r.Lines | Where-Object { $_ -match $PassedPattern })
    $failed = @($r.Lines | Where-Object { $_ -match 'WARNING:\s+\S+\s+FAIL\b' })
    $detail = "exit $($r.Code); " + $(if ($passed.Count -eq 1) { $passed[0] -replace '^.*NOTICE:\s+', '' } else { 'no PASSED line' })
    if ($failed.Count) { $detail += '; ' + (($failed | Select-Object -First 3 | ForEach-Object { $_ -replace '^.*WARNING:\s+', '' }) -join ' / ') }
    Add-Check $Id $Name (($r.Code -eq 0) -and ($passed.Count -eq 1) -and ($failed.Count -eq 0)) $detail
}

# No double quotes in inline SQL (Windows PowerShell 5.1 strips them from native arguments).
$LogRegexDigestSql = @'
SELECT md5(string_agg(item, chr(10) ORDER BY item COLLATE ucs_basic)) || ' over ' || count(*) || ' items'
FROM (
    SELECT 'function ' || p.oid::regprocedure::text || ' ' || md5(pg_get_functiondef(p.oid)) AS item
    FROM pg_proc p WHERE p.pronamespace = 'log_regex'::regnamespace AND p.prokind IN ('f', 'p')
    UNION ALL
    SELECT 'view ' || c.relname || ' ' || md5(pg_get_viewdef(c.oid))
    FROM pg_class c WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relkind IN ('v', 'm')
    UNION ALL
    SELECT 'columns ' || c.relname || ' ' || md5(string_agg(a.attnum || ':' || a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum))
    FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relkind = 'r'
    GROUP BY c.relname
    UNION ALL
    SELECT 'constraint ' || c.relname || '.' || k.conname || ' ' || md5(pg_get_constraintdef(k.oid))
    FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
    WHERE c.relnamespace = 'log_regex'::regnamespace
    UNION ALL
    SELECT 'index ' || ic.relname || ' ' || md5(pg_get_indexdef(ic.oid))
    FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
    WHERE c.relnamespace = 'log_regex'::regnamespace
    UNION ALL
    SELECT 'trigger ' || c.relname || '.' || t.tgname || ' ' || t.tgenabled::text
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relnamespace = 'log_regex'::regnamespace AND NOT t.tgisinternal
    UNION ALL
    SELECT 'internal triggers ' || c.relname || ' ' || count(*)
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relnamespace = 'log_regex'::regnamespace AND t.tgisinternal
    GROUP BY c.relname
    UNION ALL
    SELECT 'rows ' || c.relname || ' ' || query_to_xml(format('SELECT count(*) AS n, md5(string_agg(t::text, chr(10) ORDER BY t::text COLLATE ucs_basic)) AS h FROM %s AS t', c.oid::regclass), false, true, '')::text
    FROM pg_class c WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relkind = 'r'
) AS items
'@

$JsonDataDigestSql = @'
SELECT md5(string_agg(item, chr(10) ORDER BY item COLLATE ucs_basic)) || ' over ' || count(*) || ' items'
FROM (
    SELECT 'table ' || c.relname || ' ' || coalesce(array_to_string(c.reloptions, ','), '') AS item
    FROM pg_class c WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
    UNION ALL
    SELECT 'columns ' || c.relname || ' ' || md5(string_agg(a.attnum || ':' || a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull || ':' || a.attstorage::text, ',' ORDER BY a.attnum))
    FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
    GROUP BY c.relname
    UNION ALL
    SELECT 'constraint ' || k.conname || ' ' || md5(pg_get_constraintdef(k.oid))
    FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
    WHERE c.relnamespace = 'log_regex_json'::regnamespace
    UNION ALL
    SELECT 'comment ' || c.relname || ' ' || md5(coalesce(obj_description(c.oid, 'pg_class'), ''))
    FROM pg_class c WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
    UNION ALL
    SELECT 'rows access_log_json ' || count(*) || ' ' || md5(string_agg(log_id || ':' || doc::text, chr(10) ORDER BY log_id))
    FROM log_regex_json.access_log_json
    UNION ALL
    SELECT 'rows access_log_jsonb ' || count(*) || ' ' || md5(string_agg(log_id || ':' || doc::text, chr(10) ORDER BY log_id))
    FROM log_regex_json.access_log_jsonb
) AS items
'@

$IndexDigestSql = @'
SELECT md5(string_agg(ic.relname || ' ' || pg_get_indexdef(ic.oid) || ' ' || pg_relation_size(ic.oid), chr(10) ORDER BY ic.relname)) || ' over ' || count(*) || ' indexes, ' || sum(pg_relation_size(ic.oid)) || ' bytes'
FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
WHERE c.relnamespace = 'log_regex_json'::regnamespace
'@

function Test-State {
    param([string[]]$Ids, [string]$When)
    $d = Invoke-ReadOnlyQuery -Sql $LogRegexDigestSql
    Add-Check $Ids[0] "log_regex digest (raw, parser, flat, answer key) $When" ($d -eq $ExpectedLogRegex) $d
    $d = Invoke-ReadOnlyQuery -Sql $JsonDataDigestSql
    Add-Check $Ids[1] "log_regex_json data digest (Step 6B tables and documents) $When" ($d -eq $ExpectedJsonData) $d
    $d = Invoke-ReadOnlyQuery -Sql $IndexDigestSql
    Add-Check $Ids[2] "Step 6D index definitions and sizes digest $When" ($d -eq $ExpectedIndexes) $d
    Test-Verification -Id $Ids[3] -Name "sql/34 Step 6B verification $When" -File 'sql/34_verify_json_experiment_tables.sql' -PassedPattern 'JSON experiment check PASSED: all 38 checks' -ReadOnly
    Test-Verification -Id $Ids[4] -Name "sql/38 phase final verification $When" -File 'sql/38_verify_json_index_phase.sql' -Variable 'phase=final' -PassedPattern 'JSON index phase final check PASSED: all 70 checks' -ReadOnly
    Test-Verification -Id $Ids[5] -Name "sql/42 preflight (sessions idle, staged input, write schema, X-0 .. X-4) $When" -File 'sql/42_preflight_json_write_experiment.sql' -PassedPattern 'Step 6E preflight PASSED: all 41 checks'
}

function Write-Report {
    $failed = @($Results | Where-Object { $_.Result -ne 'PASS' })
    $lines = @("Step 6E measurement runner checks", "run at $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC",
               "result: $($Results.Count - $failed.Count) PASS, $($failed.Count) FAIL of $($Results.Count) checks", "")
    $lines += @($Results | ForEach-Object { "{0,-5} {1}  {2}: {3}" -f $_.Id, $_.Result, $_.Name, $_.Detail })
    [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $ReportFile), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "==== $($Results.Count - $failed.Count) PASS, $($failed.Count) FAIL of $($Results.Count) checks; report $ReportFile ===="
    return $failed.Count
}

function Invoke-Analysis {
    param([string]$Id, [switch]$WithSession2)
    $analyzeArgs = @('-B', $Measure, 'analyze', '--session1', $Raw1)
    if ($WithSession2) { $analyzeArgs += @('--session2', $Raw2) }
    $r = Invoke-Capture -Command { & $Python.Source @analyzeArgs }
    $r.Lines | ForEach-Object { Write-Host $_ }
    Add-Check $Id ("analysis" + $(if ($WithSession2) { ' (sessions 1 and 2)' } else { ' (session 1)' }) + ": correctness checks, CSV and markdown outputs") ($r.Code -eq 0) (($r.Lines | Select-Object -Last 2) -join '; ')
    return $r
}

if (-not $AnalyzeOnly) {
    if (-not $env:PGPASSWORD) { throw "PGPASSWORD is not set." }
    Write-Host "==== 1. Static checks ===="
    $r = Invoke-Capture -Command { & $Python.Source -B 'scripts/step6e_json_write_experiment.py' 'generate' '--check' }
    Add-Check 'R-01' 'approved sql/41 and sql/42 unchanged' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
    $r = Invoke-Capture -Command { & $Python.Source -B $Measure 'generate' '--check' }
    Add-Check 'R-02' 'sql/43 matches scripts/step6e_json_write_measure.py' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
    $r6c = Invoke-Capture -Command { & $Python.Source -B 'scripts/step6c_json_query_experiment.py' 'generate' '--check' }
    $r6d = Invoke-Capture -Command { & $Python.Source -B 'scripts/step6d_json_index_experiment.py' 'generate' '--check' }
    Add-Check 'R-03' 'sql/36-40 still match the Step 6C and Step 6D generators' (($r6c.Code -eq 0) -and ($r6d.Code -eq 0)) "6C exit $($r6c.Code), 6D exit $($r6d.Code)"
    $r = Invoke-Capture -Command { & $Python.Source -B $Measure 'static-check' 'sql/43_measure_json_writes.sql' }
    Add-Check 'R-04' 'sql/43: every statement a designed form on log_regex_json_write; no other schema referenced' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
    $nonAscii = @()
    foreach ($file in @('sql/43_measure_json_writes.sql', $Measure, 'sql/run_step6e_json_writes.ps1')) {
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $file).ProviderPath)
        if (@($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1).Count) { $nonAscii += $file }
    }
    Add-Check 'R-05' 'Step 6E measurement files are ASCII' ($nonAscii.Count -eq 0) $(if ($nonAscii.Count) { $nonAscii -join ', ' } else { '3 files' })

    Write-Host "==== 2. Manifests ===="
    Test-Manifest -Id 'M-01' -Name 'Step 6C outputs preserved (start)' -Path $Manifest6C -ExpectedFiles 11
    Test-Manifest -Id 'M-02' -Name 'Step 6D outputs preserved (start)' -Path $Manifest6D -ExpectedFiles 26

    Write-Host "==== 3. State before ===="
    Test-State -Ids @('G-01', 'G-02', 'G-03', 'V-01', 'V-02', 'V-03') -When 'before'
    if (@($Results | Where-Object { $_.Result -ne 'PASS' }).Count -gt 0) {
        Write-Host "A check before the measurement failed: no measurement run."
        exit ([Math]::Min(1, (Write-Report)))
    }

    Write-Host "==== 4. Session 1 ===="
    $started = Get-Date
    $previousOptions = $env:PGOPTIONS; $env:PGOPTIONS = $null
    $r = Invoke-Capture -Command { & $Python.Source -B $Measure 'run-session' 'sql/43_measure_json_writes.sql' $Raw1 $Err1 '--psql' $PsqlPath }
    $env:PGOPTIONS = $previousOptions
    $tail = @(Get-Content -LiteralPath $Err1 -Tail 3 -ErrorAction SilentlyContinue) -join ' '
    Add-Check 'S-01' 'measurement session 1 (sql/43) completed' ($r.Code -eq 0) ("exit $($r.Code) after $([int]((Get-Date) - $started).TotalSeconds) s; stderr tail: $tail")
    if ($r.Code -ne 0) { Write-Report | Out-Null; exit 1 }
}

Write-Host "==== 5. Analysis ===="
$a = Invoke-Analysis -Id 'A-01'
$blocksLine = @($a.Lines | Where-Object { $_ -match '^SESSION2_BLOCKS: ' }) | Select-Object -Last 1
$blocks = if ($blocksLine) { ($blocksLine -replace '^SESSION2_BLOCKS: ', '').Trim() } else { 'unknown' }
if ($blocks -ne 'none' -and $blocks -ne 'unknown') {
    $blockList = @($blocks -split ' ')
    if (-not $AnalyzeOnly) {
        Write-Host "==== 6. Session 2 for blocks with a median below 0.1 ms: $blocks ===="
        $genArgs = @('-B', $Measure, 'generate-session2', '--blocks') + $blockList
        $r = Invoke-Capture -Command { & $Python.Source @genArgs }
        $r2 = Invoke-Capture -Command { & $Python.Source -B $Measure 'static-check' 'sql/44_measure_json_writes_session2.sql' }
        Add-Check 'R-06' "sql/44 generated for blocks $blocks and every statement a designed form" (($r.Code -eq 0) -and ($r2.Code -eq 0)) (($r2.Lines -join ' ').Trim())
        $started = Get-Date
        $previousOptions = $env:PGOPTIONS; $env:PGOPTIONS = $null
        $r = Invoke-Capture -Command { & $Python.Source -B $Measure 'run-session' 'sql/44_measure_json_writes_session2.sql' $Raw2 $Err2 '--psql' $PsqlPath }
        $env:PGOPTIONS = $previousOptions
        Add-Check 'S-02' "measurement session 2 (sql/44, blocks $blocks) completed" ($r.Code -eq 0) ("exit $($r.Code) after $([int]((Get-Date) - $started).TotalSeconds) s")
        if ($r.Code -ne 0) { Write-Report | Out-Null; exit 1 }
    }
    Invoke-Analysis -Id 'A-02' -WithSession2 | Out-Null
} else {
    Add-Check 'A-02' 'second session (Step 6A rule: only for medians below 0.1 ms)' ($blocks -eq 'none') "blocks below 0.1 ms: $blocks"
}

if (-not $AnalyzeOnly) {
    Write-Host "==== 7. State after ===="
    Test-State -Ids @('G-04', 'G-05', 'G-06', 'V-04', 'V-05', 'V-06') -When 'after'
    Test-Manifest -Id 'M-03' -Name 'Step 6C outputs preserved (end)' -Path $Manifest6C -ExpectedFiles 11
    Test-Manifest -Id 'M-04' -Name 'Step 6D outputs preserved (end)' -Path $Manifest6D -ExpectedFiles 26
}
exit ([Math]::Min(1, (Write-Report)))
