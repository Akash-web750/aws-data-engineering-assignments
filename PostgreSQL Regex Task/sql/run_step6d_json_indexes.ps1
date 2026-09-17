<#
.SYNOPSIS
    Step 6D - JSON vs JSONB index experiment: build the designed indexes, verify them and measure the relevant queries.

.DESCRIPTION
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.

    Order:
      1. static checks: sql/38-40 match scripts/step6d_json_index_experiment.py; sql/36-37 still match the Step 6C
         generator; sql/38 and sql/40 contain no write statement; sql/39 only creates or drops the designed index
         names on the two experiment tables and analyses them (no json-via-cast GIN index); files are ASCII
      2. Step 6C baseline preserved: SHA-256 manifest analysis/step6/step6d_baseline_step6c_sha256.txt (created on the
         first run, verified on every run and again at the end)
      3. state (read-only): 5,000 rows per table, only the primary keys (skipped with -AnalyzeOnly)
      4. digests (read-only): schema log_regex (objects and rows) and the log_regex_json tables (columns, constraints,
         comments, document rows; indexes excluded because this step adds them)
      5. gate: sql/34 and sql/38 phase I-0
      6. I-0 control: sql/40 in two read-only sessions
      7. I-1: sql/39 step I-1 (both tables); sql/38 I-1; sql/40 I-1 in two sessions
      8. I-2: sql/39 step I-2 (GIN jsonb_ops); sql/38 I-2; sql/40 I-2 in two sessions
      9. I-3: sql/39 step I-3 (jsonb_ops dropped, GIN jsonb_path_ops); sql/38 I-3; sql/40 I-3 in two sessions
     10. final: sql/39 step final (GIN jsonb_ops rebuilt); sql/38 final
     11. sql/34 again; digests again (must be unchanged); baseline manifest again
     12. analysis: scripts/step6d_json_index_experiment.py analyze

    Writes only indexes and planner statistics of schema log_regex_json. Never touches raw_access_logs,
    access_log_flat, parser objects or the JSON documents.

.PARAMETER AnalyzeOnly
    Skip every database step and only re-run the static checks, the baseline check and the analysis.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step6d_json_indexes.ps1"
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
$Manifest = 'analysis/step6/step6d_baseline_step6c_sha256.txt'
$BaselineFiles = @(
    'analysis/step6/step6c_batch1_explain.txt', 'analysis/step6/step6c_batch2_explain.txt',
    'analysis/step6/step6c_executions.csv', 'analysis/step6/step6c_summary.csv', 'analysis/step6/step6c_comparison.csv',
    'analysis/step6/step6c_summary.md', 'docs/Step6C_JSON_vs_JSONB_Query_Experiment.md',
    'sql/36_verify_json_query_results.sql', 'sql/37_measure_json_queries.sql', 'sql/run_step6c_json_queries.ps1',
    'scripts/step6c_json_query_experiment.py')
$DesignedIndexes = @(
    'access_log_json_i1a_record_validity', 'access_log_jsonb_i1a_record_validity',
    'access_log_json_i1b_entity_type_code', 'access_log_jsonb_i1b_entity_type_code',
    'access_log_json_i1c_status_code', 'access_log_jsonb_i1c_status_code',
    'access_log_json_i1d_latitude_degrees', 'access_log_jsonb_i1d_latitude_degrees',
    'access_log_json_i1e_event_timestamp_utc', 'access_log_jsonb_i1e_event_timestamp_utc',
    'access_log_jsonb_i2_gin_jsonb_ops', 'access_log_jsonb_i3_gin_jsonb_path_ops')

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

function Invoke-Native {
    param([scriptblock]$Command, [string]$What)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "$What exited with $code" }
}

function Invoke-Psql {
    param([string]$File, [string]$Variable, [string]$OutputFile, [switch]$ReadOnly)
    Write-Host ""
    Write-Host ("---- psql -d $Database -f $File $Variable" + $(if ($ReadOnly) { '   (read-only session)' } else { '' }))
    $previousOptions = $env:PGOPTIONS
    if ($ReadOnly) { $env:PGOPTIONS = $ReadOnlyOptions }
    try {
        $psqlArgs = @('-X', '-v', 'ON_ERROR_STOP=1', '-d', $Database, '-f', $File)
        if ($Variable) { $psqlArgs += @('-v', $Variable) }
        if ($OutputFile) { $psqlArgs += @('-q', '-o', $OutputFile) }
        Invoke-Native -What "psql $File $Variable" -Command { & $PsqlPath @psqlArgs }
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
    if ($code -ne 0) { throw "read-only query failed with $code" }
    return ("$out").Trim()
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

function Assert-Baseline {
    param([string]$When)
    $current = @($BaselineFiles | ForEach-Object { "$(Get-Sha256Hex -Path $_)  $_" })
    if (-not (Test-Path -LiteralPath $Manifest)) {
        [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $Manifest), (($current -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Step 6C baseline manifest created ($($current.Count) files): $Manifest"
        return
    }
    $recorded = @((Read-TextShared -Path $Manifest).Trim() -split "`n" | ForEach-Object { $_.Trim() })
    if (($recorded -join '|') -ne ($current -join '|')) { throw "Step 6C baseline files differ from $Manifest ($When)" }
    Write-Host "Step 6C baseline preserved ($When): $($current.Count) files match $Manifest"
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

Write-Host "==== 1. Static checks ===="
Invoke-Native -What "step6d generate --check" -Command { & $Python.Source 'scripts/step6d_json_index_experiment.py' 'generate' '--check' }
Invoke-Native -What "step6c generate --check" -Command { & $Python.Source 'scripts/step6c_json_query_experiment.py' 'generate' '--check' }

$writePattern = '(?im)^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|COPY|VACUUM|ANALYZE|COMMIT|GRANT|REVOKE|COMMENT|REINDEX|CLUSTER)\b'
foreach ($file in @('sql/38_verify_json_index_phase.sql', 'sql/40_measure_json_index_phase.sql')) {
    $bad = @([regex]::Matches((Read-TextShared -Path $file), $writePattern) | ForEach-Object { $_.Value.Trim() })
    if ($bad.Count -gt 0) { throw "$file contains write statements: $($bad[0])" }
}
$buildText = Read-TextShared -Path 'sql/39_build_json_experiment_indexes.sql'
$statements = @([regex]::Matches($buildText, '(?im)^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|COPY|VACUUM|ANALYZE|GRANT|REVOKE|COMMENT|REINDEX|CLUSTER)\b.*$') | ForEach-Object { $_.Value.Trim() })
foreach ($s in $statements) {
    $ok = $false
    if ($s -match '^CREATE INDEX (\S+) ON log_regex_json\.(access_log_jsonb?) (.+)$') {
        $ok = ($DesignedIndexes -contains $Matches[1]) -and $Matches[1].StartsWith($Matches[2] + '_')
        if ($Matches[3] -match '::jsonb|USING gin' -and $Matches[2] -eq 'access_log_json') { $ok = $false }
    } elseif ($s -match '^DROP INDEX log_regex_json\.(\S+);$') {
        $ok = $DesignedIndexes -contains $Matches[1]
    } elseif ($s -match '^ANALYZE log_regex_json\.access_log_jsonb?;$') {
        $ok = $true
    }
    if (-not $ok) { throw "sql/39 contains a statement outside the Step 6D design: $s" }
}
if ($buildText -match '\(\(doc::jsonb') { throw "sql/39 contains a json-via-cast index expression" }
Write-Host "sql/38-40 up to date; sql/38 and sql/40 read-only; sql/39: $($statements.Count) statements, all designed CREATE INDEX / DROP INDEX / ANALYZE on the experiment tables; no json-via-cast GIN index"

foreach ($file in @('sql/38_verify_json_index_phase.sql', 'sql/39_build_json_experiment_indexes.sql', 'sql/40_measure_json_index_phase.sql',
                    'sql/run_step6d_json_indexes.ps1', 'scripts/step6d_json_index_experiment.py', 'sql/34_verify_json_experiment_tables.sql')) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $file).ProviderPath)
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    if ($nonAscii -gt 0) { throw "$file contains $nonAscii non-ASCII bytes" }
}
Write-Host "Step 6D files are ASCII"

Write-Host ""
Write-Host "==== 2. Step 6C baseline ===="
Assert-Baseline -When 'start'

if (-not $AnalyzeOnly) {
    if (-not $env:PGPASSWORD) { throw "PGPASSWORD is not set. Set PGHOST, PGPORT, PGUSER and PGPASSWORD first." }
    if (-not (Test-Path $PsqlPath)) { throw "psql not found at $PsqlPath" }

    Write-Host ""
    Write-Host "==== 3. Database state (read-only) ===="
    $state = Invoke-ReadOnlyQuery -Sql ("SELECT (SELECT count(*) FROM log_regex_json.access_log_json) || '|' || (SELECT count(*) FROM log_regex_json.access_log_jsonb) || '|' || " +
        "(SELECT string_agg(ic.relname, ',' ORDER BY ic.relname) FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex_json'::regnamespace)")
    if ($state -ne '5000|5000|access_log_json_pkey,access_log_jsonb_pkey') { throw "unexpected experiment state (rows|rows|indexes): $state" }
    Write-Host "access_log_json 5000 rows, access_log_jsonb 5000 rows, primary keys only"

    Write-Host ""
    Write-Host "==== 4. Digests before (read-only) ===="
    $logRegexBefore = Invoke-ReadOnlyQuery -Sql $LogRegexDigestSql
    $jsonBefore = Invoke-ReadOnlyQuery -Sql $JsonDataDigestSql
    Write-Host "log_regex             before: $logRegexBefore"
    Write-Host "log_regex_json tables before: $jsonBefore"

    Write-Host ""
    Write-Host "==== 5. Gate ===="
    Invoke-Psql -File 'sql/34_verify_json_experiment_tables.sql' -ReadOnly
    Invoke-Psql -File 'sql/38_verify_json_index_phase.sql' -Variable 'phase=I-0' -ReadOnly

    $phases = @(
        @{ Phase = 'I-0'; Key = 'i0'; Build = $null },
        @{ Phase = 'I-1'; Key = 'i1'; Build = 'I-1' },
        @{ Phase = 'I-2'; Key = 'i2'; Build = 'I-2' },
        @{ Phase = 'I-3'; Key = 'i3'; Build = 'I-3' })
    $step = 5
    foreach ($p in $phases) {
        $step++
        Write-Host ""
        Write-Host "==== $step. Phase $($p.Phase) ===="
        if ($p.Build) {
            Invoke-Psql -File 'sql/39_build_json_experiment_indexes.sql' -Variable "step=$($p.Build)" -OutputFile "analysis/step6/step6d_build_$($p.Key).txt"
            Write-Host "builds recorded in analysis/step6/step6d_build_$($p.Key).txt"
            Invoke-Psql -File 'sql/38_verify_json_index_phase.sql' -Variable "phase=$($p.Phase)" -ReadOnly
        }
        foreach ($batch in 1, 2) {
            $started = Get-Date
            Invoke-Psql -File 'sql/40_measure_json_index_phase.sql' -Variable "phase=$($p.Phase)" -OutputFile "analysis/step6/step6d_$($p.Key)_batch${batch}_explain.txt" -ReadOnly
            Write-Host ("phase $($p.Phase) batch $batch finished in {0:N0} s" -f ((Get-Date) - $started).TotalSeconds)
        }
    }

    Write-Host ""
    Write-Host "==== 10. Final state ===="
    Invoke-Psql -File 'sql/39_build_json_experiment_indexes.sql' -Variable 'step=final' -OutputFile 'analysis/step6/step6d_build_final.txt'
    Invoke-Psql -File 'sql/38_verify_json_index_phase.sql' -Variable 'phase=final' -ReadOnly

    Write-Host ""
    Write-Host "==== 11. Unchanged data ===="
    Invoke-Psql -File 'sql/34_verify_json_experiment_tables.sql' -ReadOnly
    $logRegexAfter = Invoke-ReadOnlyQuery -Sql $LogRegexDigestSql
    $jsonAfter = Invoke-ReadOnlyQuery -Sql $JsonDataDigestSql
    Write-Host "log_regex             after : $logRegexAfter"
    Write-Host "log_regex_json tables after : $jsonAfter"
    if ($logRegexAfter -ne $logRegexBefore) { throw "schema log_regex changed" }
    if ($jsonAfter -ne $jsonBefore) { throw "log_regex_json tables, constraints or documents changed" }
    Write-Host "unchanged: schema log_regex (access_log_flat included) and the log_regex_json tables and documents"
}

Assert-Baseline -When 'end'

Write-Host ""
Write-Host "==== 12. Analysis ===="
Invoke-Native -What "analyze" -Command { & $Python.Source 'scripts/step6d_json_index_experiment.py' 'analyze' }

Write-Host ""
Write-Host "==== Step 6D completed: indexes built, verified and measured ===="
