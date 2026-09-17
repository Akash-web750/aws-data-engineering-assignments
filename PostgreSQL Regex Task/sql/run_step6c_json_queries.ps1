<#
.SYNOPSIS
    Step 6C - JSON vs JSONB head-to-head query experiment (no indexes, read-only measurements).

.DESCRIPTION
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.

    Order:
      1. static checks: sql/36 and sql/37 match scripts/step6c_json_query_experiment.py (generate --check); no write
         statement in either; no jsonb-only operator (@>, <@, ?, ?|, ?&, @?, @@, ||, #-, document equality) outside
         string literals in the measured statements; Step 6C files are ASCII
      2. database state (read-only): both experiment tables hold 5,000 rows; only the two primary key indexes exist
      3. digests (read-only): schema log_regex (objects and rows, access_log_flat included) and schema log_regex_json
         (relations, indexes, constraints, comments, document rows)
      4. gate before timing (read-only): sql/34 (38 checks) and sql/36 (documents unchanged, results = flat oracle)
      5. batch 1: sql/37 in one read-only session  -> analysis/step6/step6c_batch1_explain.txt
      6. batch 2: sql/37 in a second read-only session -> analysis/step6/step6c_batch2_explain.txt
      7. gate after timing (read-only): sql/36 and sql/34
      8. digests again: both must equal step 3
      9. analysis: scripts/step6c_json_query_experiment.py analyze -> analysis/step6/step6c_*.csv and step6c_summary.md

    Creates no index, changes no data, uses no PostGIS.

.PARAMETER AnalyzeOnly
    Skip steps 2-8 and only re-run the analysis of the existing batch files.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step6c_json_queries.ps1"
#>
param(
    [string]$PsqlPath = "C:\Program Files\PostgreSQL\17\bin\psql.exe",
    [switch]$AnalyzeOnly
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$env:PGCLIENTENCODING = 'UTF8'
[Environment]::SetEnvironmentVariable('PGDATABASE', $null, 'Process')
$Database = 'postgresql_regex_task'
$ReadOnlyOptions = '-c default_transaction_read_only=on'
$Python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $Python) { throw "python not found" }

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

function Invoke-ReadOnlyPsql {
    param([string]$File, [string]$OutputFile)
    Write-Host ""
    Write-Host "---- psql -d $Database -f $File   (read-only session)"
    $previousOptions = $env:PGOPTIONS
    $env:PGOPTIONS = $ReadOnlyOptions
    try {
        if ($OutputFile) {
            Invoke-Native -What "psql $File" -Command { & $PsqlPath -X -q -v ON_ERROR_STOP=1 -d $Database -f $File -o $OutputFile }
        } else {
            Invoke-Native -What "psql $File" -Command { & $PsqlPath -X -v ON_ERROR_STOP=1 -d $Database -f $File }
        }
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

$JsonDigestSql = @'
SELECT md5(string_agg(item, chr(10) ORDER BY item COLLATE ucs_basic)) || ' over ' || count(*) || ' items'
FROM (
    SELECT 'relation ' || c.relkind::text || ' ' || c.relname || ' ' || coalesce(array_to_string(c.reloptions, ','), '') AS item
    FROM pg_class c WHERE c.relnamespace = 'log_regex_json'::regnamespace
    UNION ALL
    SELECT 'columns ' || c.relname || ' ' || md5(string_agg(a.attnum || ':' || a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull || ':' || a.attstorage::text, ',' ORDER BY a.attnum))
    FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
    GROUP BY c.relname
    UNION ALL
    SELECT 'index ' || ic.relname || ' ' || md5(pg_get_indexdef(ic.oid))
    FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
    WHERE c.relnamespace = 'log_regex_json'::regnamespace
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
Invoke-Native -What "generate --check" -Command { & $Python.Source 'scripts/step6c_json_query_experiment.py' 'generate' '--check' }

$writePattern = '(?im)^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|COPY|VACUUM|ANALYZE|COMMIT|GRANT|REVOKE|COMMENT|SELECT\s+.*\bINTO\b)'
foreach ($file in @('sql/36_verify_json_query_results.sql', 'sql/37_measure_json_queries.sql')) {
    $bad = @([regex]::Matches((Read-TextShared -Path $file), $writePattern) | ForEach-Object { $_.Value.Trim() })
    if ($bad.Count -gt 0) { throw "$file contains write statements: $($bad[0..([Math]::Min(4, $bad.Count - 1))] -join '; ')" }
}

$measured = @((Read-TextShared -Path 'sql/37_measure_json_queries.sql') -split "`n" | Where-Object { $_ -match '^EXPLAIN ' })
$jsonbOnly = 0
foreach ($line in $measured) {
    $withoutLiterals = $line -replace "'[^']*'", "''"
    if ($withoutLiterals -match '@>|<@|\?\||\?&|@\?|@@|#-|\?|\|\||\bdoc\s*(=|<>|!=)') { $jsonbOnly++ }
}
if ($jsonbOnly -gt 0) { throw "sql/37 contains $jsonbOnly measured statements with jsonb-only operators" }
Write-Host "sql/36 and sql/37 are up to date, contain no write statement; $($measured.Count) measured EXPLAIN statements use no jsonb-only operator"

foreach ($file in @('sql/36_verify_json_query_results.sql', 'sql/37_measure_json_queries.sql', 'sql/run_step6c_json_queries.ps1',
                    'scripts/step6c_json_query_experiment.py')) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $file).ProviderPath)
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    if ($nonAscii -gt 0) { throw "$file contains $nonAscii non-ASCII bytes" }
}
Write-Host "Step 6C files are ASCII"

if (-not $AnalyzeOnly) {
    if (-not $env:PGPASSWORD) { throw "PGPASSWORD is not set. Set PGHOST, PGPORT, PGUSER and PGPASSWORD first." }
    if (-not (Test-Path $PsqlPath)) { throw "psql not found at $PsqlPath" }

    Write-Host ""
    Write-Host "==== 2. Database state (read-only) ===="
    $state = Invoke-ReadOnlyQuery -Sql ("SELECT (SELECT count(*) FROM log_regex_json.access_log_json) || '|' || (SELECT count(*) FROM log_regex_json.access_log_jsonb) || '|' || " +
        "(SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex_json'::regnamespace)")
    if ($state -ne '5000|5000|2') { throw "unexpected experiment state (json rows|jsonb rows|indexes): $state" }
    Write-Host "access_log_json 5000 rows, access_log_jsonb 5000 rows, 2 indexes (primary keys)"

    Write-Host ""
    Write-Host "==== 3. Digests before (read-only) ===="
    $logRegexBefore = Invoke-ReadOnlyQuery -Sql $LogRegexDigestSql
    $jsonBefore = Invoke-ReadOnlyQuery -Sql $JsonDigestSql
    Write-Host "log_regex      before: $logRegexBefore"
    Write-Host "log_regex_json before: $jsonBefore"

    Write-Host ""
    Write-Host "==== 4. Gate before timing ===="
    Invoke-ReadOnlyPsql -File 'sql/34_verify_json_experiment_tables.sql'
    Invoke-ReadOnlyPsql -File 'sql/36_verify_json_query_results.sql'

    New-Item -ItemType Directory -Force -Path 'analysis/step6' | Out-Null
    foreach ($batch in 1, 2) {
        Write-Host ""
        Write-Host "==== $(4 + $batch). Measurement batch $batch (separate read-only session) ===="
        $started = Get-Date
        Invoke-ReadOnlyPsql -File 'sql/37_measure_json_queries.sql' -OutputFile "analysis/step6/step6c_batch${batch}_explain.txt"
        Write-Host ("batch $batch finished in {0:N0} s -> analysis/step6/step6c_batch${batch}_explain.txt" -f ((Get-Date) - $started).TotalSeconds)
    }

    Write-Host ""
    Write-Host "==== 7. Gate after timing ===="
    Invoke-ReadOnlyPsql -File 'sql/36_verify_json_query_results.sql'
    Invoke-ReadOnlyPsql -File 'sql/34_verify_json_experiment_tables.sql'

    Write-Host ""
    Write-Host "==== 8. Digests after (read-only) ===="
    $logRegexAfter = Invoke-ReadOnlyQuery -Sql $LogRegexDigestSql
    $jsonAfter = Invoke-ReadOnlyQuery -Sql $JsonDigestSql
    Write-Host "log_regex      after : $logRegexAfter"
    Write-Host "log_regex_json after : $jsonAfter"
    if ($logRegexAfter -ne $logRegexBefore) { throw "schema log_regex changed" }
    if ($jsonAfter -ne $jsonBefore) { throw "schema log_regex_json changed" }
    Write-Host "unchanged: schema log_regex (access_log_flat included) and schema log_regex_json (documents, indexes, constraints)"
}

Write-Host ""
Write-Host "==== 9. Analysis ===="
Invoke-Native -What "analyze" -Command { & $Python.Source 'scripts/step6c_json_query_experiment.py' 'analyze' }

Write-Host ""
Write-Host "==== Step 6C completed: head-to-head query measurements recorded (no indexes, no data changes) ===="
