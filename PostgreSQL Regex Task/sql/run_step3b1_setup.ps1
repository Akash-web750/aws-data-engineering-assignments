<#
.SYNOPSIS
    Step 3B-1 - PostgreSQL setup: create postgresql_regex_task, load the Step 1 RAW LOGS into
    log_regex.raw_access_logs, protect them and verify them.

.DESCRIPTION
    Connection settings come from the standard PostgreSQL environment variables
    (PGHOST, PGPORT, PGUSER, PGPASSWORD). Nothing secret is stored in this project.
    PGDATABASE is ignored: every psql call names its database explicitly.

    Order:
      1. scripts/raw_csv_digest.py         expected values from the CSV (no database)
      2. sql/00_create_database.sql        (database postgres)
      3. sql/01_create_schema_and_raw_table.sql
      4. sql/02_load_raw_access_logs.sql
      5. sql/03_protect_raw_input.sql
      6. sql/04_verify_raw_access_logs.sql
      7. round trip: export the table to CSV and compare its SHA-256 with the Step 1 file

    The script stops at the first failure. Step 2 fails if the database already exists.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "sql\run_step3b1_setup.ps1"
#>
param(
    [string]$PsqlPath = "C:\Program Files\PostgreSQL\17\bin\psql.exe",
    [string]$Python   = "python"
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

if (-not (Test-Path $PsqlPath)) { throw "psql not found at $PsqlPath" }
if (-not $env:PGPASSWORD)       { throw "PGPASSWORD is not set. Set PGHOST, PGPORT, PGUSER and PGPASSWORD first." }
$env:PGCLIENTENCODING = 'UTF8'
Remove-Item Env:PGDATABASE -ErrorAction SilentlyContinue

$Database = 'postgresql_regex_task'
$CsvPath  = 'data/raw_access_logs.csv'

function Get-Sha256Hex {
    # Opens the file with FileShare.ReadWrite so an editor holding the CSV open does not block hashing
    # (Get-FileHash requires exclusive read access).
    param([string]$Path)
    $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })) }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Invoke-Psql {
    param([string]$Db, [string]$File, [string[]]$Vars = @())
    Write-Host ""
    Write-Host "---- psql -d $Db -f $File"
    $psqlArgs = @('-X', '-v', 'ON_ERROR_STOP=1', '-d', $Db)
    foreach ($v in $Vars) { $psqlArgs += @('-v', $v) }
    $psqlArgs += @('-f', $File)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $PsqlPath @psqlArgs
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw "psql exited with $code while running $File" }
}

Write-Host "==== 1. Expected values from the CSV (scripts/raw_csv_digest.py) ===="
$summaryJson = & $Python scripts/raw_csv_digest.py --json
if ($LASTEXITCODE -ne 0) { throw "scripts/raw_csv_digest.py failed" }
$s = $summaryJson | ConvertFrom-Json
$fileHash = Get-Sha256Hex -Path $CsvPath
if ($fileHash -ne $s.file_sha256) { throw "SHA-256 of $CsvPath differs between PowerShell and Python" }
Write-Host ("rows={0} file_sha256={1} dataset_digest={2}" -f $s.row_count, $fileHash, $s.dataset_digest)

Invoke-Psql -Db 'postgres' -File 'sql/00_create_database.sql'
Invoke-Psql -Db $Database  -File 'sql/01_create_schema_and_raw_table.sql'
Invoke-Psql -Db $Database  -File 'sql/02_load_raw_access_logs.sql'
Invoke-Psql -Db $Database  -File 'sql/03_protect_raw_input.sql' -Vars @("source_file_sha256=$fileHash")

$verifyVars = @(
    "expected_file_sha256=$fileHash",
    "expected_digest=$($s.dataset_digest)",
    "expected_row_count=$($s.row_count)",
    "expected_null_ids=$(($s.null_log_ids) -join ',')",
    "expected_empty_ids=$(($s.empty_string_log_ids) -join ',')",
    "expected_whitespace_only=$($s.whitespace_only_rows)",
    "expected_lf_rows=$($s.rows_containing_lf)",
    "expected_cr_rows=$($s.rows_containing_cr)",
    "expected_tab_rows=$($s.rows_containing_tab)",
    "expected_nbsp_rows=$($s.rows_containing_nbsp)",
    "expected_non_ascii_rows=$($s.rows_containing_non_ascii)",
    "expected_max_chars=$($s.max_char_length)",
    "expected_total_chars=$($s.total_char_length)",
    "expected_total_octets=$($s.total_utf8_octets)"
)
Invoke-Psql -Db $Database -File 'sql/04_verify_raw_access_logs.sql' -Vars $verifyVars

Write-Host ""
Write-Host "==== 7. Round trip: export log_regex.raw_access_logs and compare with $CsvPath ===="
$exportPath = Join-Path ([IO.Path]::GetTempPath()) 'postgresql_regex_task_raw_access_logs_export.csv'
$exportSql  = $exportPath -replace '\\', '/'
$copyCmd = "\copy (SELECT log_id, raw_log FROM log_regex.raw_access_logs ORDER BY log_id) TO '$exportSql' WITH (FORMAT csv, HEADER true, FORCE_QUOTE (raw_log), ENCODING 'UTF8')"
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $PsqlPath -X -v ON_ERROR_STOP=1 -d $Database -c $copyCmd
$code = $LASTEXITCODE
$ErrorActionPreference = $previous
if ($code -ne 0) { throw "export failed with $code" }
$exportHash = Get-Sha256Hex -Path $exportPath
Write-Host "Step 1 file SHA-256 : $fileHash"
Write-Host "Export SHA-256      : $exportHash"
if ($exportHash -ne $fileHash) {
    throw "Round trip FAILED: the exported CSV is not byte-identical to $CsvPath (export kept at $exportPath)"
}
Remove-Item $exportPath
Write-Host "Round trip PASSED: the exported table is byte-identical to $CsvPath"
Write-Host ""
Write-Host "==== Step 3B-1 setup and verification completed ===="
