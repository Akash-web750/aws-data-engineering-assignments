<#
.SYNOPSIS
    Step 3B-4 - install the F2 parser objects and test F1 + F2 against the answer key.

.DESCRIPTION
    Requires the Step 3B-3 objects in postgresql_regex_task (answer key table, reference data, output tables,
    validators). Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.

    sql/07 and sql/08 are NOT re-run: the Step 3B-3 runs (formats {F1}) stay in parser_run and serve as the
    F1 regression baseline for sql/16.

    Order:
      1. check data/expected_fields.csv against data/dataset_manifest.json (SHA-256)
      2. check that the Step 3B-3 objects exist
      3. sql/13_parser_reference_data_f2.sql   re-runnable (log levels, sentinel phrases)
      4. sql/10_parser_f1.sql                  re-runnable (f1_candidates only; body unchanged)
      5. sql/14_parser_f2.sql                  re-runnable (F2 grammar)
      6. sql/17_parser_reference_data_f3.sql   re-runnable (added in Step 3B-5; run_parser needs F3)
      7. sql/18_parser_f3.sql                  re-runnable (added in Step 3B-5)
      8. sql/20_parser_reference_data_f4.sql   re-runnable (added in Step 3B-6)
      9. sql/21_parser_f4.sql                  re-runnable (added in Step 3B-6)
     10. sql/23_parser_reference_data_f5.sql   re-runnable (added in Step 3B-7)
     11. sql/24_parser_f5.sql                  re-runnable (added in Step 3B-7)
     12. sql/15_parser_core.sql                re-runnable (line_event_end, detect_format, run_parser)
     13. sql/11_parser_evaluation_views.sql    re-runnable
     14. sql/16_test_f2_parser.sql             runs the parser twice and reports the results

    Never modifies raw_access_logs, its fingerprints, its load audit or the answer key.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b4_f2_parser.ps1"
#>
param(
    [string]$PsqlPath = "C:\Program Files\PostgreSQL\17\bin\psql.exe"
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

if (-not (Test-Path $PsqlPath)) { throw "psql not found at $PsqlPath" }
if (-not $env:PGPASSWORD)       { throw "PGPASSWORD is not set. Set PGHOST, PGPORT, PGUSER and PGPASSWORD first." }
$env:PGCLIENTENCODING = 'UTF8'
[Environment]::SetEnvironmentVariable('PGDATABASE', $null, 'Process')
$Database = 'postgresql_regex_task'

function Open-SharedRead {
    param([string]$Path)
    $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    return [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
}

function Get-Sha256Hex {
    param([string]$Path)
    $stream = Open-SharedRead -Path $Path
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })) }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Read-TextShared {
    param([string]$Path)
    $stream = Open-SharedRead -Path $Path
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Invoke-Psql {
    param([string]$File)
    Write-Host ""
    Write-Host "---- psql -d $Database -f $File"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $PsqlPath -X -v ON_ERROR_STOP=1 -d $Database -f $File
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw "psql exited with $code while running $File" }
}

Write-Host "==== 1. Answer key file check ===="
$manifest = (Read-TextShared -Path 'data/dataset_manifest.json') | ConvertFrom-Json
$expectedHash = $manifest.files.'expected_fields.csv'.sha256
$actualHash = Get-Sha256Hex -Path 'data/expected_fields.csv'
Write-Host "manifest SHA-256 : $expectedHash"
Write-Host "file SHA-256     : $actualHash"
if ($expectedHash -ne $actualHash) { throw "data/expected_fields.csv does not match data/dataset_manifest.json" }

Write-Host ""
Write-Host "==== 2. Step 3B-3 objects ===="
$check = "SELECT to_regclass('log_regex.expected_fields') IS NOT NULL AND to_regclass('log_regex.ref_field') IS NOT NULL " +
         "AND to_regclass('log_regex.parsed_field') IS NOT NULL AND to_regclass('log_regex.parsed_secondary') IS NOT NULL " +
         "AND EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " +
         "WHERE n.nspname = 'log_regex' AND p.proname = 'field_validity')"
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$exists = & $PsqlPath -X -A -t -v ON_ERROR_STOP=1 -d $Database -c $check
$code = $LASTEXITCODE
$ErrorActionPreference = $previous
if ($code -ne 0) { throw "could not query $Database" }
if ("$exists".Trim() -ne 't') { throw "Step 3B-3 objects are missing; run sql\run_step3b3_f1_parser.ps1 first." }
Write-Host "answer key, reference data, output tables and validators present"

Invoke-Psql -File 'sql/13_parser_reference_data_f2.sql'
Invoke-Psql -File 'sql/10_parser_f1.sql'
Invoke-Psql -File 'sql/14_parser_f2.sql'
Invoke-Psql -File 'sql/17_parser_reference_data_f3.sql'
Invoke-Psql -File 'sql/18_parser_f3.sql'
Invoke-Psql -File 'sql/20_parser_reference_data_f4.sql'
Invoke-Psql -File 'sql/21_parser_f4.sql'
Invoke-Psql -File 'sql/23_parser_reference_data_f5.sql'
Invoke-Psql -File 'sql/24_parser_f5.sql'
Invoke-Psql -File 'sql/15_parser_core.sql'
Invoke-Psql -File 'sql/11_parser_evaluation_views.sql'
Invoke-Psql -File 'sql/16_test_f2_parser.sql'

Write-Host ""
Write-Host "==== Step 3B-4 F2 parser install and test completed ===="
