<#
.SYNOPSIS
    Step 3B-7 - install the F5 parser objects and test F1 - F5 against the answer key.

.DESCRIPTION
    Requires the Step 3B-6 objects in postgresql_regex_task (answer key table, reference data, output tables,
    validators, f1_candidates ... f4_candidates). Connection settings come from PGHOST, PGPORT, PGUSER and
    PGPASSWORD; PGDATABASE is ignored.

    sql/07 and sql/08 are NOT re-run: earlier runs stay in parser_run, and the latest {F1,F2,F3,F4} run (Step 3B-6)
    serves as the F1 - F4 regression baseline for sql/25.

    Order:
      1. check data/expected_fields.csv against data/dataset_manifest.json (SHA-256)
      2. check that the Step 3B-6 objects exist
      3. sql/23_parser_reference_data_f5.sql   re-runnable (F5 column map)
      4. sql/24_parser_f5.sql                  re-runnable (ten semicolon-positional columns)
      5. sql/15_parser_core.sql                re-runnable (detect_format with DET-F5, run_parser for F1-F5)
      6. sql/11_parser_evaluation_views.sql    re-runnable
      7. sql/25_test_f5_parser.sql             runs the parser twice and reports the results

    Never modifies raw_access_logs, its fingerprints, its load audit or the answer key.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b7_f5_parser.ps1"
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
Write-Host "==== 2. Step 3B-6 objects ===="
$check = "SELECT to_regclass('log_regex.expected_fields') IS NOT NULL AND to_regclass('log_regex.ref_key_alias') IS NOT NULL " +
         "AND to_regclass('log_regex.ref_timestamp_shape') IS NOT NULL AND to_regclass('log_regex.ref_sentinel_phrase') IS NOT NULL " +
         "AND to_regclass('log_regex.parsed_field') IS NOT NULL AND to_regclass('log_regex.parsed_secondary') IS NOT NULL " +
         "AND to_regprocedure('log_regex.f1_candidates(text)') IS NOT NULL " +
         "AND to_regprocedure('log_regex.f2_candidates(text)') IS NOT NULL " +
         "AND to_regprocedure('log_regex.f3_candidates(text)') IS NOT NULL " +
         "AND to_regprocedure('log_regex.f4_candidates(text)') IS NOT NULL " +
         "AND EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " +
         "WHERE n.nspname = 'log_regex' AND p.proname = 'field_validity')"
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$exists = & $PsqlPath -X -A -t -v ON_ERROR_STOP=1 -d $Database -c $check
$code = $LASTEXITCODE
$ErrorActionPreference = $previous
if ($code -ne 0) { throw "could not query $Database" }
if ("$exists".Trim() -ne 't') { throw "Step 3B-6 objects are missing; run sql\run_step3b6_f4_parser.ps1 first." }
Write-Host "answer key, reference data, output tables, validators, F1 - F4 extractors present"

Invoke-Psql -File 'sql/23_parser_reference_data_f5.sql'
Invoke-Psql -File 'sql/24_parser_f5.sql'
Invoke-Psql -File 'sql/15_parser_core.sql'
Invoke-Psql -File 'sql/11_parser_evaluation_views.sql'
Invoke-Psql -File 'sql/25_test_f5_parser.sql'

Write-Host ""
Write-Host "==== Step 3B-7 F5 parser install and test completed ===="
