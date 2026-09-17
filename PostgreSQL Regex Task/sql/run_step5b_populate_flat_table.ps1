<#
.SYNOPSIS
    Step 5B population - load log_regex.access_log_flat from the accepted parser run and verify it read-only.

.DESCRIPTION
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.

    Order:
      1. static checks: sql/07 and sql/08 refuse (LR003) before their first BEGIN and DROP; the Step 3B-3 runner refuses
         before any other database call; sql/30 inserts only into log_regex.access_log_flat (one INSERT), creates only
         its temporary staging table and contains no DROP, TRUNCATE, DELETE, UPDATE, ALTER, COPY or CREATE INDEX;
         the Step 5B population files are ASCII
      2. database state (read-only session): access_log_flat exists and is empty (populated with -VerifyOnly)
      3. digest of everything else in log_regex (read-only session): functions, views, columns, constraints, indexes,
         guard triggers and the rows of every table except access_log_flat
      4. sql/30_load_access_log_flat.sql                 the only write: one transaction (skipped with -VerifyOnly)
      5. sql/27_verify_access_log_flat_foreign_keys.sql  read-only session
      6. sql/29_verify_access_log_flat_structure.sql     read-only session
      7. sql/31_verify_access_log_flat_load.sql          read-only session
      8. digest again: must equal step 3

    Never modifies raw_access_logs, the answer key, reference data, parser output tables or parser functions. Creates no
    index, no JSON/JSONB and no PostGIS objects.

.PARAMETER SourceRunId
    Accepted parser run to publish (default 14).

.PARAMETER VerifyOnly
    Skip step 4 and verify the already loaded table.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step5b_populate_flat_table.ps1"
#>
param(
    [string]$PsqlPath = "C:\Program Files\PostgreSQL\17\bin\psql.exe",
    [int]$SourceRunId = 14,
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
    param([string]$File, [switch]$ReadOnly)
    Write-Host ""
    if ($ReadOnly) { Write-Host "---- psql -d $Database -f $File   (read-only session)" } else { Write-Host "---- psql -d $Database -f $File" }
    $previousOptions = $env:PGOPTIONS
    if ($ReadOnly) { $env:PGOPTIONS = $ReadOnlyOptions }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $PsqlPath -X -v ON_ERROR_STOP=1 -v "source_run_id=$SourceRunId" -d $Database -f $File
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

# No double quotes in inline SQL: Windows PowerShell 5.1 strips them from native arguments (hence ucs_basic).
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
    WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relkind = 'r' AND c.relname <> 'access_log_flat'
    GROUP BY c.relname
    UNION ALL
    SELECT 'constraint ' || c.relname || '.' || k.conname || ' ' || md5(pg_get_constraintdef(k.oid))
    FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
    WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relname <> 'access_log_flat'
    UNION ALL
    SELECT 'index ' || ic.relname || ' ' || md5(pg_get_indexdef(ic.oid))
    FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
    WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relname <> 'access_log_flat'
    UNION ALL
    SELECT 'trigger ' || c.relname || '.' || t.tgname || ' ' || t.tgenabled::text
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relnamespace = 'log_regex'::regnamespace AND NOT t.tgisinternal
    UNION ALL
    SELECT 'rows ' || c.relname || ' ' || query_to_xml(format('SELECT count(*) AS n, md5(string_agg(t::text, chr(10) ORDER BY t::text COLLATE ucs_basic)) AS h FROM %s AS t', c.oid::regclass), false, true, '')::text
    FROM pg_class c WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relkind = 'r' AND c.relname <> 'access_log_flat'
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
$guardAmp = $runner.IndexOf('& $PsqlPath', $guardCall)
$earlierCalls = @([regex]::Matches($runner, '& \$PsqlPath|Invoke-Psql -File') | Where-Object { $_.Index -gt $firstStep -and $_.Index -ne $guardAmp -and $_.Index -lt $refusal })
if ($earlierCalls.Count -gt 0) { throw "sql/run_step3b3_f1_parser.ps1 calls the database before its access_log_flat guard" }
Write-Host "sql/run_step3b3_f1_parser.ps1 : guard query and refusal come before any other database call"

$load = Read-TextShared -Path 'sql/30_load_access_log_flat.sql'
$forbidden = [regex]::Matches($load, '(?im)^\s*(DROP|TRUNCATE|DELETE|UPDATE|ALTER|COPY|CREATE\s+(UNIQUE\s+)?INDEX)\b')
if ($forbidden.Count -gt 0) { throw "sql/30_load_access_log_flat.sql contains $($forbidden.Count) forbidden statements" }
$inserts = [regex]::Matches($load, '(?im)^\s*INSERT\s+INTO\s+(\S+)')
if ($inserts.Count -ne 1 -or $inserts[0].Groups[1].Value -ne 'log_regex.access_log_flat') { throw "sql/30_load_access_log_flat.sql must contain exactly one INSERT, into log_regex.access_log_flat" }
$creates = @([regex]::Matches($load, '(?im)^\s*CREATE\b.*$') | Where-Object { $_.Value.Trim() -ne 'CREATE TEMP TABLE flat_stage ON COMMIT DROP AS' })
if ($creates.Count -gt 0) { throw "sql/30_load_access_log_flat.sql creates objects other than its temporary staging table" }
Write-Host "sql/30_load_access_log_flat.sql : one INSERT into log_regex.access_log_flat; only CREATE is the temporary staging table; no DROP, TRUNCATE, DELETE, UPDATE, ALTER, COPY or CREATE INDEX"

foreach ($file in @('sql/29_verify_access_log_flat_structure.sql', 'sql/30_load_access_log_flat.sql',
                    'sql/31_verify_access_log_flat_load.sql', 'sql/run_step5b_populate_flat_table.ps1')) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $file).ProviderPath)
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    if ($nonAscii -gt 0) { throw "$file contains $nonAscii non-ASCII bytes" }
}
Write-Host "Step 5B population SQL and PowerShell files are ASCII"

Write-Host ""
Write-Host "==== 2. Database state (read-only) ===="
$state = Invoke-ReadOnlyQuery -Sql ("SELECT (to_regclass('log_regex.access_log_flat') IS NOT NULL)::text || '|' || " +
    "CASE WHEN to_regclass('log_regex.access_log_flat') IS NULL THEN '-1' ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM log_regex.access_log_flat', false, true, '')))[1]::text END || '|' || " +
    "(SELECT count(*) FROM log_regex.raw_access_logs)::text")
$parts = $state.Split('|')
if ($parts[0] -ne 'true') { throw "log_regex.access_log_flat does not exist; run sql/run_step5b_create_flat_table.ps1 first" }
if ($VerifyOnly) {
    if ($parts[1] -ne $parts[2]) { throw "-VerifyOnly: access_log_flat holds $($parts[1]) rows, expected $($parts[2])" }
    Write-Host "access_log_flat holds $($parts[1]) rows for $($parts[2]) raw logs (verify only)"
} else {
    if ($parts[1] -ne '0') { throw "refused: log_regex.access_log_flat already holds $($parts[1]) rows; use -VerifyOnly to verify them" }
    Write-Host "access_log_flat exists and is empty; $($parts[2]) raw logs"
}

Write-Host ""
Write-Host "==== 3. Digest of all other log_regex objects and rows (read-only) ===="
$digestBefore = Invoke-ReadOnlyQuery -Sql $DigestSql
Write-Host "before: $digestBefore"

if (-not $VerifyOnly) {
    Write-Host ""
    Write-Host "==== 4. Load ===="
    Invoke-Psql -File 'sql/30_load_access_log_flat.sql'
}

Write-Host ""
Write-Host "==== 5. Foreign-key check ===="
Invoke-Psql -File 'sql/27_verify_access_log_flat_foreign_keys.sql' -ReadOnly

Write-Host ""
Write-Host "==== 6. Structural verification ===="
Invoke-Psql -File 'sql/29_verify_access_log_flat_structure.sql' -ReadOnly

Write-Host ""
Write-Host "==== 7. Load verification ===="
Invoke-Psql -File 'sql/31_verify_access_log_flat_load.sql' -ReadOnly

Write-Host ""
Write-Host "==== 8. Digest after (read-only) ===="
$digestAfter = Invoke-ReadOnlyQuery -Sql $DigestSql
Write-Host "after : $digestAfter"
if ($digestAfter -ne $digestBefore) { throw "objects or rows outside access_log_flat changed" }
Write-Host "unchanged: every other log_regex function, view, column, constraint, index, guard trigger and row"

Write-Host ""
Write-Host "==== Step 5B population completed: access_log_flat loaded and verified ===="
