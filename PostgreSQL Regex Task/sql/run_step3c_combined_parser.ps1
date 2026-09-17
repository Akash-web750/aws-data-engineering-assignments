<#
.SYNOPSIS
    Step 3C - install the complete parser from its source files and validate it on all 5,000 raw logs.

.DESCRIPTION
    Requires the Step 3B-7 database state (answer key, reference tables, output tables and the earlier parser runs
    that serve as regression baselines). Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD;
    PGDATABASE is ignored.

    sql/06, sql/07 and sql/08 are NOT re-run: the answer key stays read-only, the reference tables keep their
    constraints, and the earlier parser runs stay in parser_run.

    Order:
      1. check data/expected_fields.csv against data/dataset_manifest.json (SHA-256)
      2. Step 1 generator self-check (python data/generate_raw_logs.py --check), skipped if python is not found
      3. check that the required database objects exist
      4. re-install every parser object from source (all re-runnable, none touches raw data or runs):
           09 validators, 10 F1, 13 F2 reference data, 14 F2, 17 F3 key paths, 18 F3, 20 F4 keys, 21 F4,
           23 F5 column map, 24 F5, 15 core (detection F4 -> F3 -> F1 -> F5 -> F2 -> NONE, run_parser),
           11 evaluation views
      5. sql/26_test_combined_parser.sql      two complete runs, T-01 ... T-10 and the Step 3C checks

    Never modifies raw_access_logs, its fingerprints, its load audit or the answer key.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3c_combined_parser.ps1"
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
Write-Host "==== 2. Step 1 generator self-check ===="
$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $python.Source 'data/generate_raw_logs.py' '--check'
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw "data/generate_raw_logs.py --check failed with $code" }
} else {
    Write-Host "python not found; generator self-check skipped"
}

Write-Host ""
Write-Host "==== 3. Required database objects ===="
$check = "SELECT to_regclass('log_regex.raw_access_logs') IS NOT NULL AND to_regclass('log_regex.expected_fields') IS NOT NULL " +
         "AND to_regclass('log_regex.ref_key_alias') IS NOT NULL AND to_regclass('log_regex.ref_timestamp_shape') IS NOT NULL " +
         "AND to_regclass('log_regex.parser_run') IS NOT NULL AND to_regclass('log_regex.parsed_log') IS NOT NULL " +
         "AND to_regclass('log_regex.parsed_field') IS NOT NULL AND to_regclass('log_regex.parsed_secondary') IS NOT NULL " +
         "AND to_regprocedure('log_regex.verify_raw_access_logs()') IS NOT NULL"
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$exists = & $PsqlPath -X -A -t -v ON_ERROR_STOP=1 -d $Database -c $check
$code = $LASTEXITCODE
$ErrorActionPreference = $previous
if ($code -ne 0) { throw "could not query $Database" }
if ("$exists".Trim() -ne 't') { throw "required objects are missing; build the database with the Step 3B runners first." }
Write-Host "raw table, answer key, reference tables, output tables and integrity check present"

Write-Host ""
Write-Host "==== 4. Install the complete parser from source ===="
foreach ($file in @('sql/09_parser_validators.sql', 'sql/10_parser_f1.sql',
                    'sql/13_parser_reference_data_f2.sql', 'sql/14_parser_f2.sql',
                    'sql/17_parser_reference_data_f3.sql', 'sql/18_parser_f3.sql',
                    'sql/20_parser_reference_data_f4.sql', 'sql/21_parser_f4.sql',
                    'sql/23_parser_reference_data_f5.sql', 'sql/24_parser_f5.sql',
                    'sql/15_parser_core.sql', 'sql/11_parser_evaluation_views.sql')) {
    Invoke-Psql -File $file
}

Write-Host ""
Write-Host "==== 5. Combined validation ===="
Invoke-Psql -File 'sql/26_test_combined_parser.sql'

Write-Host ""
Write-Host "==== Step 3C combined parser validation completed ===="
