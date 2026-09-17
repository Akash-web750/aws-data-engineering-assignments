<#
.SYNOPSIS
    Step 6B - build the JSON and JSONB experiment tables from access_log_flat and verify them and their storage.

.DESCRIPTION
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.

    Order:
      1. static checks: sql/07 and sql/08 guards; the Step 3B-3 runner guard; sql/32 creates only the schema and the
         two tables; sql/33 inserts only into the two tables, creates only its temporary stage and vacuums only the two
         tables; sql/34 and sql/35 contain no write statement; no DROP, TRUNCATE, DELETE, UPDATE, ALTER, COPY,
         CREATE INDEX or EXPLAIN anywhere; the Step 6B files are ASCII
      2. database state (read-only): schema log_regex_json absent (present and loaded with -VerifyOnly)
      3. digest of schema log_regex (read-only): functions, views, columns, constraints, indexes, guard triggers,
         internal trigger counts and the rows of every table, access_log_flat included
      4. source gate (read-only): sql/27, sql/29, sql/31
      5. sql/32_create_json_experiment_tables.sql      write (skipped with -VerifyOnly)
      6. sql/33_load_json_experiment_tables.sql        write + VACUUM (ANALYZE) of the two tables (skipped with -VerifyOnly)
      7. sql/34_verify_json_experiment_tables.sql      read-only
      8. sql/35_measure_json_experiment_storage.sql    read-only; output saved to analysis/step6/step6b_storage_measurements.txt
      9. sql/27, sql/29, sql/31 again (read-only)
     10. digest again: must equal step 3

    Creates no query index, runs no EXPLAIN and no benchmark. Never modifies schema log_regex.

.PARAMETER VerifyOnly
    Skip steps 5 and 6 and verify the existing experiment tables.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step6b_build_json_tables.ps1"
#>
param(
    [string]$PsqlPath = "C:\Program Files\PostgreSQL\17\bin\psql.exe",
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

if (-not (Test-Path $PsqlPath)) { throw "psql not found at $PsqlPath" }
if (-not $env:PGPASSWORD)       { throw "PGPASSWORD is not set. Set PGHOST, PGPORT, PGUSER and PGPASSWORD first." }
$env:PGCLIENTENCODING = 'UTF8'
[Environment]::SetEnvironmentVariable('PGDATABASE', $null, 'Process')
$Database = 'postgresql_regex_task'
$ReadOnlyOptions = '-c default_transaction_read_only=on'
$MeasurementFile = 'analysis/step6/step6b_storage_measurements.txt'

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

function Invoke-Psql {
    param([string]$File, [switch]$ReadOnly, [string]$OutputFile)
    Write-Host ""
    if ($ReadOnly) { Write-Host "---- psql -d $Database -f $File   (read-only session)" } else { Write-Host "---- psql -d $Database -f $File" }
    $previousOptions = $env:PGOPTIONS
    if ($ReadOnly) { $env:PGOPTIONS = $ReadOnlyOptions }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($OutputFile) {
            & $PsqlPath -X -v ON_ERROR_STOP=1 -d $Database -f $File -o $OutputFile
        } else {
            & $PsqlPath -X -v ON_ERROR_STOP=1 -d $Database -f $File
        }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
        $env:PGOPTIONS = $previousOptions
    }
    if ($code -ne 0) { throw "psql exited with $code while running $File" }
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

function Assert-ScriptGuard {
    param([string]$File)
    $text = Read-TextShared -Path $File
    $start = $text.IndexOf('-- BEGIN access_log_flat guard')
    $end = $text.IndexOf('-- END access_log_flat guard')
    if ($start -lt 0 -or $end -lt $start) { throw "$File has no access_log_flat guard block" }
    $block = $text.Substring($start, $end - $start)
    if (-not $block.Contains("to_regclass('log_regex.access_log_flat') IS NOT NULL") -or -not $block.Contains("ERRCODE = 'LR003'")) {
        throw "$File guard block does not refuse with LR003 while log_regex.access_log_flat exists"
    }
    $begin = [regex]::Match($text, '(?m)^BEGIN;')
    $drop = [regex]::Match($text, '(?m)^DROP ')
    if (-not $begin.Success -or -not $drop.Success -or $end -gt $begin.Index -or $end -gt $drop.Index) {
        throw "$File guard block does not end before the first BEGIN and the first DROP"
    }
    Write-Host "$File : LR003 guard ends before BEGIN and DROP"
}

function Get-Statements {
    param([string]$Text, [string]$Pattern)
    return @([regex]::Matches($Text, $Pattern) | ForEach-Object { $_.Value.Trim() })
}

# Schema log_regex, access_log_flat included. No double quotes: Windows PowerShell 5.1 strips them from native arguments.
$DigestSql = @'
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

Write-Host "==== 1. Static checks ===="
Assert-ScriptGuard -File 'sql/07_parser_reference_data.sql'
Assert-ScriptGuard -File 'sql/08_parser_output_tables.sql'

$runner = Read-TextShared -Path 'sql/run_step3b3_f1_parser.ps1'
$firstStep = $runner.IndexOf('==== 1.')
$guardCall = $runner.IndexOf('$flatExists = & $PsqlPath')
$refusal = $runner.IndexOf('if ("$flatExists".Trim() -ne ''f'')')
$step3 = $runner.IndexOf('==== 3.')
if ($firstStep -lt 0 -or $guardCall -lt $firstStep -or $refusal -lt $guardCall -or $step3 -lt $refusal) {
    throw "sql/run_step3b3_f1_parser.ps1 does not refuse before its step 3 while access_log_flat exists"
}
Write-Host "sql/run_step3b3_f1_parser.ps1 : access_log_flat guard present before its step 3"

$forbiddenPattern = '(?im)^\s*(DROP|TRUNCATE|DELETE|UPDATE|ALTER|COPY|EXPLAIN|CREATE\s+(UNIQUE\s+)?INDEX)\b'
$create = Read-TextShared -Path 'sql/32_create_json_experiment_tables.sql'
$load = Read-TextShared -Path 'sql/33_load_json_experiment_tables.sql'
foreach ($item in @(@{ Name = 'sql/32'; Text = $create }, @{ Name = 'sql/33'; Text = $load })) {
    $bad = Get-Statements -Text $item.Text -Pattern $forbiddenPattern
    if ($bad.Count -gt 0) { throw "$($item.Name) contains forbidden statements: $($bad -join '; ')" }
}
$creates32 = Get-Statements -Text $create -Pattern '(?im)^\s*CREATE\b.*$'
$expected32 = @('CREATE SCHEMA log_regex_json;', 'CREATE TABLE log_regex_json.access_log_json (', 'CREATE TABLE log_regex_json.access_log_jsonb (')
if (($creates32 -join '|') -ne ($expected32 -join '|')) { throw "sql/32 CREATE statements differ from the design: $($creates32 -join '; ')" }
if ((Get-Statements -Text $create -Pattern '(?im)^\s*(INSERT|VACUUM)\b').Count -gt 0) { throw "sql/32 must not insert or vacuum" }
$inserts33 = Get-Statements -Text $load -Pattern '(?im)^\s*INSERT\s+INTO\s+\S+'
if (($inserts33 -join '|') -ne 'INSERT INTO log_regex_json.access_log_json|INSERT INTO log_regex_json.access_log_jsonb') { throw "sql/33 inserts differ from the design: $($inserts33 -join '; ')" }
$creates33 = Get-Statements -Text $load -Pattern '(?im)^\s*CREATE\b.*$'
if (($creates33 -join '|') -ne 'CREATE TEMP TABLE json_stage ON COMMIT DROP AS') { throw "sql/33 creates objects other than its temporary stage: $($creates33 -join '; ')" }
$vacuums33 = Get-Statements -Text $load -Pattern '(?im)^\s*VACUUM\b.*$'
if (($vacuums33 -join '|') -ne 'VACUUM (ANALYZE) log_regex_json.access_log_json;|VACUUM (ANALYZE) log_regex_json.access_log_jsonb;') { throw "sql/33 vacuums other tables: $($vacuums33 -join '; ')" }
foreach ($file in @('sql/34_verify_json_experiment_tables.sql', 'sql/35_measure_json_experiment_storage.sql')) {
    $bad = Get-Statements -Text (Read-TextShared -Path $file) -Pattern '(?im)^\s*(INSERT|UPDATE|DELETE|DROP|TRUNCATE|ALTER|CREATE|COPY|VACUUM|EXPLAIN|COMMIT)\b'
    if ($bad.Count -gt 0) { throw "$file contains write or EXPLAIN statements: $($bad -join '; ')" }
}
Write-Host "sql/32 creates only log_regex_json and the two tables; sql/33 inserts only into them, creates only its temporary stage, vacuums only them; sql/34 and sql/35 are read-only; no index, EXPLAIN or destructive statement"

foreach ($file in @('sql/32_create_json_experiment_tables.sql', 'sql/33_load_json_experiment_tables.sql', 'sql/34_verify_json_experiment_tables.sql',
                    'sql/35_measure_json_experiment_storage.sql', 'sql/run_step6b_build_json_tables.ps1')) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $file).ProviderPath)
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    if ($nonAscii -gt 0) { throw "$file contains $nonAscii non-ASCII bytes" }
}
Write-Host "Step 6B SQL and PowerShell files are ASCII"

Write-Host ""
Write-Host "==== 2. Database state (read-only) ===="
$state = Invoke-ReadOnlyQuery -Sql ("SELECT (to_regnamespace('log_regex_json') IS NOT NULL)::text || '|' || " +
    "CASE WHEN to_regclass('log_regex_json.access_log_json') IS NULL THEN '-1' ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM log_regex_json.access_log_json', false, true, '')))[1]::text END || '|' || " +
    "CASE WHEN to_regclass('log_regex_json.access_log_jsonb') IS NULL THEN '-1' ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM log_regex_json.access_log_jsonb', false, true, '')))[1]::text END || '|' || " +
    "(SELECT count(*) FROM log_regex.access_log_flat)::text")
$parts = $state.Split('|')
if ($VerifyOnly) {
    if ($parts[0] -ne 'true' -or $parts[1] -ne $parts[3] -or $parts[2] -ne $parts[3]) { throw "-VerifyOnly: experiment tables missing or not loaded (json $($parts[1]), jsonb $($parts[2]), flat $($parts[3]))" }
    Write-Host "log_regex_json exists: json $($parts[1]) rows, jsonb $($parts[2]) rows, access_log_flat $($parts[3]) rows (verify only)"
} else {
    if ($parts[0] -ne 'false') { throw "refused: schema log_regex_json already exists; use -VerifyOnly to verify it" }
    Write-Host "log_regex_json does not exist; access_log_flat $($parts[3]) rows"
}

Write-Host ""
Write-Host "==== 3. Digest of schema log_regex, access_log_flat included (read-only) ===="
$digestBefore = Invoke-ReadOnlyQuery -Sql $DigestSql
Write-Host "before: $digestBefore"

Write-Host ""
Write-Host "==== 4. Source gate ===="
Invoke-Psql -File 'sql/27_verify_access_log_flat_foreign_keys.sql' -ReadOnly
Invoke-Psql -File 'sql/29_verify_access_log_flat_structure.sql' -ReadOnly
Invoke-Psql -File 'sql/31_verify_access_log_flat_load.sql' -ReadOnly

if (-not $VerifyOnly) {
    Write-Host ""
    Write-Host "==== 5. Create the experiment tables ===="
    Invoke-Psql -File 'sql/32_create_json_experiment_tables.sql'
    Write-Host ""
    Write-Host "==== 6. Load both tables from the same canonical text ===="
    Invoke-Psql -File 'sql/33_load_json_experiment_tables.sql'
}

Write-Host ""
Write-Host "==== 7. Verify the experiment tables ===="
Invoke-Psql -File 'sql/34_verify_json_experiment_tables.sql' -ReadOnly

Write-Host ""
Write-Host "==== 8. Storage measurements ===="
New-Item -ItemType Directory -Force -Path 'analysis/step6' | Out-Null
Invoke-Psql -File 'sql/35_measure_json_experiment_storage.sql' -ReadOnly -OutputFile $MeasurementFile
Write-Host "measurements written to $MeasurementFile"
Get-Content -LiteralPath $MeasurementFile -Encoding UTF8 | ForEach-Object { Write-Host $_ }

Write-Host ""
Write-Host "==== 9. Source unchanged ===="
Invoke-Psql -File 'sql/27_verify_access_log_flat_foreign_keys.sql' -ReadOnly
Invoke-Psql -File 'sql/29_verify_access_log_flat_structure.sql' -ReadOnly
Invoke-Psql -File 'sql/31_verify_access_log_flat_load.sql' -ReadOnly

Write-Host ""
Write-Host "==== 10. Digest after (read-only) ===="
$digestAfter = Invoke-ReadOnlyQuery -Sql $DigestSql
Write-Host "after : $digestAfter"
if ($digestAfter -ne $digestBefore) { throw "objects or rows in schema log_regex changed" }
Write-Host "unchanged: every log_regex function, view, column, constraint, index, trigger and row (access_log_flat included)"

Write-Host ""
Write-Host "==== Step 6B completed: JSON and JSONB tables built, verified and measured (no indexes, no benchmarks) ===="
