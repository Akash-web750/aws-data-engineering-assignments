<#
.SYNOPSIS
    Step 3B-3 - install the F1 parser objects and test them against the answer key.

.DESCRIPTION
    Requires the Step 3B-1 database (postgresql_regex_task with log_regex.raw_access_logs).
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.

    Order:
      1. check data/expected_fields.csv against data/dataset_manifest.json (SHA-256)
         rebuild guard (Step 5A review): refuse before any database work while log_regex.access_log_flat exists,
         because sql/07 and sql/08 drop with CASCADE (both scripts also refuse on their own, SQLSTATE LR003)
      2. sql/06_load_answer_key.sql            only if log_regex.expected_fields does not exist yet
      3. sql/07_parser_reference_data.sql      re-runnable
      4. sql/08_parser_output_tables.sql       re-runnable (drops previous parser runs)
      5. sql/09_parser_validators.sql          re-runnable
      6. sql/10_parser_f1.sql                  re-runnable (f1_candidates)
      7. sql/13_parser_reference_data_f2.sql   re-runnable (added in Step 3B-4)
      8. sql/14_parser_f2.sql                  re-runnable (added in Step 3B-4)
      9. sql/17_parser_reference_data_f3.sql   re-runnable (added in Step 3B-5)
     10. sql/18_parser_f3.sql                  re-runnable (added in Step 3B-5)
     11. sql/20_parser_reference_data_f4.sql   re-runnable (added in Step 3B-6)
     12. sql/21_parser_f4.sql                  re-runnable (added in Step 3B-6)
     13. sql/23_parser_reference_data_f5.sql   re-runnable (added in Step 3B-7)
     14. sql/24_parser_f5.sql                  re-runnable (added in Step 3B-7)
     15. sql/15_parser_core.sql                re-runnable (line_event_end, detect_format, run_parser; Step 3B-4..7)
     16. sql/11_parser_evaluation_views.sql    re-runnable
     17. sql/12_test_f1_parser.sql             runs the parser twice and reports the F1 results

    Since Step 3C run_parser() classifies every row (F1 - F5 and NONE), so the runs created here have formats
    {F1,F2,F3,F4,F5,NONE}.
    Re-running this script drops earlier runs (sql/08), including the baselines used by sql/16, sql/19,
    sql/22 and sql/25_test_f5_parser.sql.

    Never modifies raw_access_logs, its fingerprints or its load audit.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b3_f1_parser.ps1"
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
Remove-Item Env:PGDATABASE -ErrorAction SilentlyContinue
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
Write-Host "==== 2. Rebuild guard (sql/07 and sql/08 drop with CASCADE) ===="
# Step 5A review: refuse before any database work while the published flat table exists. Any answer other than
# 'f' (table absent) is treated as a refusal.
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$flatExists = & $PsqlPath -X -A -t -v ON_ERROR_STOP=1 -d $Database -c "SELECT to_regclass('log_regex.access_log_flat') IS NOT NULL"
$code = $LASTEXITCODE
$ErrorActionPreference = $previous
if ($code -ne 0) { throw "could not query $Database" }
if ("$flatExists".Trim() -ne 'f') {
    throw "refused: log_regex.access_log_flat exists. sql/07 and sql/08 rebuild the reference and parser output tables with DROP ... CASCADE, which would silently remove its foreign keys and the parser runs it references."
}
Write-Host "log_regex.access_log_flat does not exist; reference and parser output tables may be rebuilt"

Write-Host ""
Write-Host "==== 3. Answer key table ===="
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$exists = & $PsqlPath -X -A -t -v ON_ERROR_STOP=1 -d $Database -c "SELECT to_regclass('log_regex.expected_fields') IS NOT NULL"
$code = $LASTEXITCODE
$ErrorActionPreference = $previous
if ($code -ne 0) { throw "could not query $Database" }
if ("$exists".Trim() -eq 't') {
    Write-Host "log_regex.expected_fields already loaded (read-only); skipping sql/06_load_answer_key.sql"
} else {
    Invoke-Psql -File 'sql/06_load_answer_key.sql'
}

Invoke-Psql -File 'sql/07_parser_reference_data.sql'
Invoke-Psql -File 'sql/08_parser_output_tables.sql'
Invoke-Psql -File 'sql/09_parser_validators.sql'
Invoke-Psql -File 'sql/10_parser_f1.sql'
Invoke-Psql -File 'sql/13_parser_reference_data_f2.sql'
Invoke-Psql -File 'sql/14_parser_f2.sql'
Invoke-Psql -File 'sql/17_parser_reference_data_f3.sql'
Invoke-Psql -File 'sql/18_parser_f3.sql'
Invoke-Psql -File 'sql/20_parser_reference_data_f4.sql'
Invoke-Psql -File 'sql/21_parser_f4.sql'
Invoke-Psql -File 'sql/23_parser_reference_data_f5.sql'
Invoke-Psql -File 'sql/24_parser_f5.sql'
Invoke-Psql -File 'sql/15_parser_core.sql'
Invoke-Psql -File 'sql/11_parser_evaluation_views.sql'
Invoke-Psql -File 'sql/12_test_f1_parser.sql'

Write-Host ""
Write-Host "==== Step 3B-3 F1 parser install and test completed ===="
