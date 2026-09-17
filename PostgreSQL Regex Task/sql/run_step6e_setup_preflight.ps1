<#
.SYNOPSIS
    Step 6E - JSON vs JSONB write/update experiment: setup/staging (sql/41) and preflight verification (sql/42) only.

.DESCRIPTION
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.
    Runs NO measurement. Every check is reported as PASS or FAIL and written to analysis/step6/step6e_preflight_report.txt.

    Order:
      1. static checks (R-01 .. R-06): sql/41-42 match scripts/step6e_json_write_experiment.py; sql/36-40 still match the
         Step 6C/6D generators; sql/41 writes only schema log_regex_json_write and reads existing table data in exactly
         one statement; sql/42 has no top-level write, ends with ROLLBACK, and its dynamic statements are only the
         designed CREATE INDEX statements on the _w tables and DROP INDEX in log_regex_json_write; files are ASCII
      2. manifests (M-01, M-02): Step 6C manifest analysis/step6/step6d_baseline_step6c_sha256.txt verified; Step 6D
         manifest analysis/step6/step6e_baseline_step6d_sha256.txt created on the first run, verified on every run
      3. before (G-01 .. G-03, V-01, V-02, read-only sessions): log_regex digest, log_regex_json data digest, digest of
         the 14 Step 6D index definitions and sizes; sql/34 (38 checks) and sql/38 -v phase=final (70 checks)
      4. setup (U-01): sql/41 when schema log_regex_json_write does not exist yet (skipped if it exists)
      5. preflight: sql/42 (every check reported individually) and Q-01 (all checks reported, exit code 0)
      6. after (G-04 .. G-06, V-03, V-04, M-03, M-04): the same digests, verifications and manifests again
    If a check of steps 1-3 fails, setup and preflight are not run.

    Writes only schema log_regex_json_write (sql/41) and the report/log files analysis/step6/step6e_preflight_*.txt,
    plus the Step 6D manifest on its first run.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step6e_setup_preflight.ps1"
#>
param(
    [string]$PsqlPath = "C:\Program Files\PostgreSQL\17\bin\psql.exe"
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$env:PGCLIENTENCODING = 'UTF8'
$env:PYTHONDONTWRITEBYTECODE = '1'
[Environment]::SetEnvironmentVariable('PGDATABASE', $null, 'Process')
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$Database = 'postgresql_regex_task'
$ReadOnlyOptions = '-c default_transaction_read_only=on'
$Python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $Python) { throw "python not found" }
if (-not $env:PGPASSWORD) { throw "PGPASSWORD is not set. Set PGHOST, PGPORT, PGUSER and PGPASSWORD first." }
if (-not (Test-Path $PsqlPath)) { throw "psql not found at $PsqlPath" }

$Sql41 = 'sql/41_create_json_write_experiment.sql'
$Sql42 = 'sql/42_preflight_json_write_experiment.sql'
$Sql42Checks = 41
$ReportFile = 'analysis/step6/step6e_preflight_report.txt'
$LogFile = 'analysis/step6/step6e_preflight_log.txt'
$Manifest6C = 'analysis/step6/step6d_baseline_step6c_sha256.txt'
$Manifest6CFiles = 11
$Manifest6D = 'analysis/step6/step6e_baseline_step6d_sha256.txt'
$Step6DFiles = @(
    'analysis/step6/step6d_baseline_step6c_sha256.txt',
    'analysis/step6/step6d_i0_batch1_explain.txt', 'analysis/step6/step6d_i0_batch2_explain.txt',
    'analysis/step6/step6d_build_i1.txt', 'analysis/step6/step6d_i1_batch1_explain.txt', 'analysis/step6/step6d_i1_batch2_explain.txt',
    'analysis/step6/step6d_build_i2.txt', 'analysis/step6/step6d_i2_batch1_explain.txt', 'analysis/step6/step6d_i2_batch2_explain.txt',
    'analysis/step6/step6d_build_i3.txt', 'analysis/step6/step6d_i3_batch1_explain.txt', 'analysis/step6/step6d_i3_batch2_explain.txt',
    'analysis/step6/step6d_build_final.txt', 'analysis/step6/step6d_executions.csv', 'analysis/step6/step6d_summary.csv',
    'analysis/step6/step6d_builds.csv', 'analysis/step6/step6d_comparisons.csv', 'analysis/step6/step6d_indexes.csv',
    'analysis/step6/step6d_summary.md', 'docs/Step6D_JSON_vs_JSONB_Index_Experiment.md',
    'sql/34_verify_json_experiment_tables.sql', 'sql/38_verify_json_index_phase.sql', 'sql/39_build_json_experiment_indexes.sql',
    'sql/40_measure_json_index_phase.sql', 'sql/run_step6d_json_indexes.ps1', 'scripts/step6d_json_index_experiment.py')
# recorded after Step 6B (log_regex), Step 6D (log_regex_json tables) and at the start of Step 6E (indexes, 12/09/2026)
$ExpectedLogRegex = 'f8042db0318656b5929c86ea1f7888d4 over 203 items'
$ExpectedJsonData = '9e6f883112c4a01781bdce5cf9bf3a28 over 10 items'
$ExpectedIndexes = 'e20752ca02d09e89281503569650d0ce over 14 indexes, 9510912 bytes'

$Results = New-Object System.Collections.Generic.List[object]
$Log = New-Object System.Collections.Generic.List[string]

function Add-Check {
    param([string]$Id, [string]$Name, [bool]$Pass, [string]$Detail)
    $result = if ($Pass) { 'PASS' } else { 'FAIL' }
    $Results.Add([pscustomobject]@{ Id = $Id; Result = $result; Name = $Name; Detail = $Detail })
    Write-Host ("{0,-6} {1}  {2}: {3}" -f $Id, $result, $Name, $Detail)
}

function Read-TextShared {
    param([string]$Path)
    $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-Sha256Hex {
    param([string]$Path)
    $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Invoke-Capture {
    param([scriptblock]$Command, [string]$Title)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $Command 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    $Log.Add("==== $Title (exit $code)")
    foreach ($line in $lines) { $Log.Add($line) }
    return @{ Lines = $lines; Code = $code }
}

function Invoke-PsqlFile {
    param([string]$File, [string]$Variable, [switch]$ReadOnly)
    $previousOptions = $env:PGOPTIONS
    $env:PGOPTIONS = if ($ReadOnly) { $ReadOnlyOptions } else { $null }
    try {
        $psqlArgs = @('-X', '-v', 'ON_ERROR_STOP=1', '-d', $Database, '-f', $File)
        if ($Variable) { $psqlArgs += @('-v', $Variable) }
        $title = "psql -f $File $Variable" + $(if ($ReadOnly) { ' (read-only session)' } else { '' })
        Write-Host "---- $title"
        return (Invoke-Capture -Title $title -Command { & $PsqlPath @psqlArgs })
    }
    finally { $env:PGOPTIONS = $previousOptions }
}

function Invoke-ReadOnlyQuery {
    param([string]$Sql)
    $previousOptions = $env:PGOPTIONS
    $env:PGOPTIONS = $ReadOnlyOptions
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $PsqlPath -X -A -t -v ON_ERROR_STOP=1 -d $Database -c $Sql
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
        $env:PGOPTIONS = $previousOptions
    }
    if ($code -ne 0) { return "query failed with exit code $code" }
    return ("$out").Trim()
}

function Test-Manifest {
    param([string]$Id, [string]$Name, [string]$Path, [int]$ExpectedFiles)
    if (-not (Test-Path -LiteralPath $Path)) { Add-Check $Id $Name $false "manifest $Path missing"; return }
    $lines = @((Read-TextShared -Path $Path).Trim() -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $problems = @()
    foreach ($line in $lines) {
        if ($line -notmatch '^([0-9a-f]{64})  (\S+)$') { $problems += "malformed line"; continue }
        $hash = $Matches[1]; $file = $Matches[2]
        if (-not (Test-Path -LiteralPath $file)) { $problems += "missing $file"; continue }
        if ((Get-Sha256Hex -Path $file) -ne $hash) { $problems += "changed $file" }
    }
    if ($lines.Count -ne $ExpectedFiles) { $problems += "$($lines.Count) entries instead of $ExpectedFiles" }
    $detail = if ($problems.Count -eq 0) { "$($lines.Count) files match $Path" } else { $problems -join '; ' }
    Add-Check $Id $Name ($problems.Count -eq 0) $detail
}

function Test-Verification {
    param([string]$Id, [string]$Name, [string]$File, [string]$Variable, [string]$PassedPattern)
    $r = Invoke-PsqlFile -File $File -Variable $Variable -ReadOnly
    $passed = @($r.Lines | Where-Object { $_ -match $PassedPattern })
    $failed = @($r.Lines | Where-Object { $_ -match 'WARNING:\s+\S+\s+FAIL\b' })
    $ok = ($r.Code -eq 0) -and ($passed.Count -eq 1) -and ($failed.Count -eq 0)
    $detail = "exit $($r.Code); " + $(if ($passed.Count -eq 1) { $passed[0] -replace '^.*NOTICE:\s+', '' } else { 'no PASSED line' }) + $(if ($failed.Count) { "; $($failed.Count) FAIL lines" } else { '' })
    Add-Check $Id $Name $ok $detail
}

# No double quotes in inline SQL: Windows PowerShell 5.1 strips them from native arguments (hence ucs_basic).
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

function Test-Digests {
    param([string[]]$Ids, [string]$When)
    $d = Invoke-ReadOnlyQuery -Sql $LogRegexDigestSql
    Add-Check $Ids[0] "log_regex digest (raw, parser, flat, answer key) $When" ($d -eq $ExpectedLogRegex) $d
    $d = Invoke-ReadOnlyQuery -Sql $JsonDataDigestSql
    Add-Check $Ids[1] "log_regex_json data digest (Step 6B tables, constraints, comments, documents) $When" ($d -eq $ExpectedJsonData) $d
    $d = Invoke-ReadOnlyQuery -Sql $IndexDigestSql
    Add-Check $Ids[2] "Step 6D index definitions and sizes digest $When" ($d -eq $ExpectedIndexes) $d
}

$started = Get-Date
Write-Host "==== 1. Static checks ===="
$r = Invoke-Capture -Title 'step6e generate --check' -Command { & $Python.Source -B 'scripts/step6e_json_write_experiment.py' 'generate' '--check' }
Add-Check 'R-01' 'sql/41 and sql/42 match scripts/step6e_json_write_experiment.py' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
$r6c = Invoke-Capture -Title 'step6c generate --check' -Command { & $Python.Source -B 'scripts/step6c_json_query_experiment.py' 'generate' '--check' }
$r6d = Invoke-Capture -Title 'step6d generate --check' -Command { & $Python.Source -B 'scripts/step6d_json_index_experiment.py' 'generate' '--check' }
Add-Check 'R-02' 'sql/36-40 still match the Step 6C and Step 6D generators' (($r6c.Code -eq 0) -and ($r6d.Code -eq 0)) ("6C exit $($r6c.Code), 6D exit $($r6d.Code)")

$text41 = (Read-TextShared -Path $Sql41) -replace "`r", ''
$code41 = @($text41 -split "`n" | Where-Object { $_ -notmatch '^\s*--' })
$statements41 = @($code41 | Where-Object { $_ -match '^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|COPY|VACUUM|ANALYZE|GRANT|REVOKE|COMMENT|REINDEX|CLUSTER|CHECKPOINT|SECURITY|LOCK)\b' } | ForEach-Object { $_.Trim() })
$allowed41 = @(
    '^CREATE SCHEMA log_regex_json_write;$',
    '^CREATE TABLE log_regex_json_write\.(canonical_doc|expected_update|access_log_json_w|access_log_jsonb_w) \($',
    '^INSERT INTO log_regex_json_write\.canonical_doc \(log_id, doc_text\)$',
    '^INSERT INTO log_regex_json_write\.expected_update \(variant, log_id, new_text\)$',
    '^COMMENT ON (SCHEMA log_regex_json_write|TABLE log_regex_json_write\.(canonical_doc|expected_update|access_log_json_w|access_log_jsonb_w)) IS$')
$bad41 = @($statements41 | Where-Object { $s = $_; @($allowed41 | Where-Object { $s -match $_ }).Count -eq 0 })
$readLines41 = @($code41 | Where-Object { $_ -match 'log_regex_json\.' -and $_ -match '\bFROM\b' })
$refs41 = @($code41 | Where-Object { $_ -match 'log_regex_json\.|log_regex\.|raw_access_logs|expected_fields' -and $_ -notmatch "^\s*('|RAISE\b)" } | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne 'SELECT log_id, doc::text FROM log_regex_json.access_log_json ORDER BY log_id;' -and
                   $_ -notmatch "^IF to_regclass\('log_regex_json\.access_log_json'\) IS NULL$" -and
                   $_ -notmatch "^OR obj_description\('log_regex_json\.access_log_json'::regclass, 'pg_class'\) NOT LIKE " })
$commits41 = @($code41 | Where-Object { $_ -match '^\s*(COMMIT|ROLLBACK|END)\s*;' }).Count
$ok41 = ($bad41.Count -eq 0) -and ($statements41.Count -eq 12) -and ($readLines41.Count -eq 1) -and
        ($readLines41[0].Trim() -eq 'SELECT log_id, doc::text FROM log_regex_json.access_log_json ORDER BY log_id;') -and ($refs41.Count -eq 0) -and ($commits41 -eq 1)
Add-Check 'R-03' 'sql/41 writes only log_regex_json_write; exactly one read of existing table data' $ok41 `
    ("$($statements41.Count) write statements, $($bad41.Count) outside the design; $($readLines41.Count) data read(s); $($refs41.Count) other references to existing schemas; $commits41 COMMIT" + $(if ($bad41.Count) { "; first: $($bad41[0])" } else { '' }))

$text42 = (Read-TextShared -Path $Sql42) -replace "`r", ''
$code42 = @($text42 -split "`n" | Where-Object { $_ -notmatch '^\s*--' })
$top42 = @($code42 | Where-Object { $_ -match '^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|COPY|VACUUM|ANALYZE|GRANT|REVOKE|COMMENT|REINDEX|CLUSTER|CHECKPOINT|COMMIT|SECURITY|LOCK)\b' })
$executes42 = @([regex]::Matches(($code42 -join "`n"), '\bEXECUTE\b[^;]*;') | ForEach-Object { $_.Value })
$badExec42 = @($executes42 | Where-Object { $_ -ne 'EXECUTE ixd.ddl;' -and $_ -ne "EXECUTE format('DROP INDEX log_regex_json_write.%I', ixd.index_name);" })
$ddlLiterals42 = @([regex]::Matches(($code42 -join "`n"), "'(CREATE INDEX (?:[^']|'')*)'") | ForEach-Object { $_.Groups[1].Value -replace "''", "'" })
# the D-02 form check builds the expected prefix from the bare fragment 'CREATE INDEX ' (exactly once); every other literal is a statement
$fragments42 = @($ddlLiterals42 | Where-Object { $_ -eq 'CREATE INDEX ' }).Count
$ddl42 = @($ddlLiterals42 | Where-Object { $_ -ne 'CREATE INDEX ' } | Sort-Object -Unique)
$badDdl42 = @($ddl42 | Where-Object {
    -not ($_ -match '^CREATE INDEX access_log_(jsonb?)_w_\w+ ON log_regex_json_write\.access_log_(jsonb?)_w (\(\(.+\)\)|USING gin \(doc jsonb(_path)?_ops\))$' -and
          $Matches[1] -eq $Matches[2] -and -not ($Matches[3] -like 'USING gin*' -and $Matches[1] -eq 'json') -and $_ -notmatch '::jsonb?\b') })
$lastLine42 = @($code42 | Where-Object { $_.Trim() }) | Select-Object -Last 1
$refs42 = @($code42 | Where-Object { $_ -match 'log_regex\.|raw_access_logs|expected_fields' })
$ok42 = ($top42.Count -eq 0) -and ($badExec42.Count -eq 0) -and ($executes42.Count -eq 2) -and ($ddl42.Count -eq 12) -and ($fragments42 -eq 1) -and ($badDdl42.Count -eq 0) -and ($lastLine42 -eq 'ROLLBACK;') -and ($refs42.Count -eq 0)
Add-Check 'R-04' 'sql/42: no top-level write, ends with ROLLBACK, dynamic SQL only designed CREATE INDEX on _w tables / DROP INDEX in the write schema' $ok42 `
    ("$($top42.Count) top-level writes; $($executes42.Count) EXECUTE ($($badExec42.Count) other); $($ddl42.Count) distinct CREATE INDEX statements ($($badDdl42.Count) outside the design) + $fragments42 D-02 prefix fragment; last statement $lastLine42; $($refs42.Count) references to log_regex/raw data")

$nonAscii = @()
foreach ($file in @($Sql41, $Sql42, 'scripts/step6e_json_write_experiment.py', 'sql/run_step6e_setup_preflight.ps1')) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $file).ProviderPath)
    $count = @($bytes | Where-Object { $_ -gt 127 }).Count
    if ($count -gt 0) { $nonAscii += "$file ($count)" }
}
Add-Check 'R-05' 'Step 6E files are ASCII' ($nonAscii.Count -eq 0) $(if ($nonAscii.Count) { $nonAscii -join ', ' } else { '4 files' })
$measure = @(Get-ChildItem -Path 'sql' -Filter '43_*' -ErrorAction SilentlyContinue)
Add-Check 'R-06' 'no measurement script present or run (preflight only)' ($measure.Count -eq 0) "$($measure.Count) sql/43_* files"

Write-Host ""
Write-Host "==== 2. Manifests ===="
Test-Manifest -Id 'M-01' -Name 'Step 6C outputs preserved (Step 6D baseline manifest)' -Path $Manifest6C -ExpectedFiles $Manifest6CFiles
if (-not (Test-Path -LiteralPath $Manifest6D)) {
    $missing = @($Step6DFiles | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -eq 0) {
        $entries = @($Step6DFiles | ForEach-Object { "$(Get-Sha256Hex -Path $_)  $_" })
        [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $Manifest6D), (($entries -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Step 6D manifest created ($($entries.Count) files): $Manifest6D"
    }
}
Test-Manifest -Id 'M-02' -Name 'Step 6D outputs preserved (Step 6E baseline manifest)' -Path $Manifest6D -ExpectedFiles $Step6DFiles.Count

Write-Host ""
Write-Host "==== 3. Before: digests and verification state (read-only) ===="
Test-Digests -Ids @('G-01', 'G-02', 'G-03') -When 'before'
Test-Verification -Id 'V-01' -Name 'sql/34 Step 6B verification before' -File 'sql/34_verify_json_experiment_tables.sql' -PassedPattern 'JSON experiment check PASSED: all 38 checks'
Test-Verification -Id 'V-02' -Name 'sql/38 phase final verification before' -File 'sql/38_verify_json_index_phase.sql' -Variable 'phase=final' -PassedPattern 'JSON index phase final check PASSED: all 70 checks'

$gateOk = @($Results | Where-Object { $_.Result -ne 'PASS' }).Count -eq 0
if ($gateOk) {
    Write-Host ""
    Write-Host "==== 4. Setup (sql/41) ===="
    $exists = Invoke-ReadOnlyQuery -Sql "SELECT (to_regnamespace('log_regex_json_write') IS NOT NULL)::text"
    if ($exists -eq 'false') {
        $r = Invoke-PsqlFile -File $Sql41
        $gate = @($r.Lines | Where-Object { $_ -match 'sql/41 setup gate PASSED' })
        Add-Check 'U-01' 'sql/41 setup and staging committed after its gate' (($r.Code -eq 0) -and ($gate.Count -eq 1)) ("exit $($r.Code); " + $(if ($gate.Count) { $gate[0] -replace '^.*NOTICE:\s+', '' } else { ($r.Lines | Select-Object -Last 3) -join ' ' }))
    } elseif ($exists -eq 'true') {
        Add-Check 'U-01' 'sql/41 setup' $true 'schema log_regex_json_write already exists: setup skipped, content verified by sql/42'
    } else {
        Add-Check 'U-01' 'sql/41 setup' $false $exists
    }

    Write-Host ""
    Write-Host "==== 5. Preflight (sql/42) ===="
    $r = Invoke-PsqlFile -File $Sql42
    $reported = 0
    foreach ($line in $r.Lines) {
        if ($line -match '(NOTICE|WARNING):\s+([A-Z]+-[A-Z0-9]+)\s+(PASS|FAIL)\s\s(.*)$') {
            $reported++
            $text = $Matches[4]
            $split = $text.IndexOf(': ')
            if ($split -gt 0) { $name = $text.Substring(0, $split); $detail = $text.Substring($split + 2) } else { $name = $text; $detail = '' }
            Add-Check $Matches[2] $name ($Matches[3] -eq 'PASS') $detail
        }
    }
    $verdict = @($r.Lines | Where-Object { $_ -match 'Step 6E preflight (PASSED|FAILED)' }) | Select-Object -First 1
    Add-Check 'Q-01' "sql/42 reported all $Sql42Checks checks and exited 0" (($reported -eq $Sql42Checks) -and ($r.Code -eq 0)) ("$reported checks reported, exit $($r.Code); " + ($verdict -replace '^.*(NOTICE|ERROR):\s+', ''))
} else {
    Write-Host "A check before setup failed: setup and preflight not run."
}

Write-Host ""
Write-Host "==== 6. After: digests, verification state and manifests ===="
Test-Digests -Ids @('G-04', 'G-05', 'G-06') -When 'after'
Test-Verification -Id 'V-03' -Name 'sql/34 Step 6B verification after' -File 'sql/34_verify_json_experiment_tables.sql' -PassedPattern 'JSON experiment check PASSED: all 38 checks'
Test-Verification -Id 'V-04' -Name 'sql/38 phase final verification after' -File 'sql/38_verify_json_index_phase.sql' -Variable 'phase=final' -PassedPattern 'JSON index phase final check PASSED: all 70 checks'
Test-Manifest -Id 'M-03' -Name 'Step 6C outputs preserved (end)' -Path $Manifest6C -ExpectedFiles $Manifest6CFiles
Test-Manifest -Id 'M-04' -Name 'Step 6D outputs preserved (end)' -Path $Manifest6D -ExpectedFiles $Step6DFiles.Count

$failed = @($Results | Where-Object { $_.Result -ne 'PASS' })
$report = New-Object System.Collections.Generic.List[string]
$report.Add("Step 6E setup/staging and preflight report (no measurement)")
$report.Add("run at $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC, $([int]((Get-Date) - $started).TotalSeconds) s")
$report.Add("result: $($Results.Count - $failed.Count) PASS, $($failed.Count) FAIL of $($Results.Count) checks")
$report.Add("")
foreach ($c in $Results) { $report.Add(("{0,-6} {1}  {2}: {3}" -f $c.Id, $c.Result, $c.Name, $c.Detail)) }
[System.IO.File]::WriteAllText((Join-Path $ProjectRoot $ReportFile), (($report -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $ProjectRoot $LogFile), (($Log -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "==== Step 6E preflight: $($Results.Count - $failed.Count) PASS, $($failed.Count) FAIL of $($Results.Count) checks ===="
Write-Host "report: $ReportFile; log: $LogFile"
if ($failed.Count -gt 0) { exit 1 }
exit 0
