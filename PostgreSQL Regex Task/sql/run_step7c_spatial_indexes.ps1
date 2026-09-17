<#
.SYNOPSIS
    Step 7C - spatial index experiment: before checks, rolled-back harness, 3 builds per index, correctness gates,
    two read-only EXPLAIN ANALYZE sessions, after checks, analysis.

.DESCRIPTION
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.
    Design: docs/Step7C_Spatial_Index_Experiment_Design.md (approved, all 8 decisions). Report: analysis/step7/step7c_checks.txt.

      1. static (R-01 .. R-04): sql/45-48 and sql/49-52 up to date; statement allowlist; ASCII
      2. manifest (M-01, M-02): SHA-256 of the Step 7B outputs, created once and verified
      3. before (B-*, read-only): PostGIS state, 0 secondary indexes, project digests, sql/27, sql/34, sql/38 final,
         manifests 6C/6D, sql/47 155/155, sql/50 phase before (fingerprints), statistics digest, AC power
      4. harness (H-01 .. H-06): 1 build per index + ANALYZE + sql/50 phase after in one transaction, ROLLBACK;
         afterwards exactly the Step 7B state
      5. build (S-49, A-49): sql/49 -v approved_step=7C; on failure sql/52 cleanup back to the Step 7B state
      6. gates (G-50a/b/c, read-only): sql/50 phase after before session 1, before session 2, after session 2
      7. sessions (E-1*, E-2*): sql/51 read-only, AC power polled every 2 s (abort on battery), machine kept awake
      8. after (Z-*): as in 3 plus the 10-index inventory and the Step 7B manifest
      9. analysis (N-01): step7c_*.csv and step7c_summary.md

.PARAMETER HarnessOnly
    Stop after the harness and the rollback verification (no committed change).
#>
param(
    [string]$PsqlPath = "C:\Program Files\PostgreSQL\17\bin\psql.exe",
    [switch]$HarnessOnly
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
if (-not $env:PGPASSWORD) { throw "PGPASSWORD is not set." }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Step7cPower {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
'@
$Gen7B = 'scripts/step7_postgis_experiment.py'
$Gen = 'scripts/step7c_spatial_index_experiment.py'
$OutDir = 'analysis/step7'
$ReportFile = "$OutDir/step7c_checks.txt"
$LogFile = "$OutDir/step7c_run_log.txt"
$HarnessFile = "$OutDir/step7c_harness.sql"
$BuildLog = "$OutDir/step7c_build_log.txt"
$ManifestFile = "$OutDir/step7c_baseline_step7b_sha256.txt"
$Results = New-Object System.Collections.Generic.List[object]
$Log = New-Object System.Collections.Generic.List[string]
$IndexNames = 'flat_geog_gist_idx,flat_geog_spgist_idx,flat_geom_brin_idx,flat_geom_gist_idx,flat_geom_spgist_idx,flat_numeric_btree_lat_lon_idx,jsonb_doc_expr_geog_gist_idx,jsonb_doc_expr_geom_gist_idx,jsonb_geog_gist_idx,jsonb_geom_gist_idx'
$Expected = @{
    LogRegex = 'f8042db0318656b5929c86ea1f7888d4 over 203 items'
    JsonData = '9e6f883112c4a01781bdce5cf9bf3a28 over 10 items'
    Indexes  = 'e20752ca02d09e89281503569650d0ce over 14 indexes, 9510912 bytes'
    Sources  = 'f562354dbf6c155f3ed0a93da433e79c|fb3bc16318e6a81c7930aed2217986ea'
    Relations = 'log_regex=49,log_regex_json=16,log_regex_json_write=8'
    WriteSchema = 'i:access_log_json_w_pkey i:access_log_jsonb_w_pkey i:canonical_doc_pkey i:expected_update_pkey r:access_log_json_w r:access_log_jsonb_w r:canonical_doc r:expected_update|aeaef32371fa8143c088d4fdce9f6e0d|UA-1:238 UA-2:238 UA-3:5000|0/0'
    PostgisState = 'plpgsql 1.0 pg_catalog, postgis 3.6.2 postgis|log_regex,log_regex_gis,log_regex_json,log_regex_json_write,postgis,public|0/0/0|0|0|'
    InventoryBefore = '15|15|0|'
    InventoryAfter = "15|15|10|$IndexNames"
}
$Step7bFiles = @('scripts/step7_postgis_experiment.py', 'sql/45_create_postgis_extension.sql', 'sql/46_create_gis_tables.sql', 'sql/47_verify_gis_setup.sql',
    'sql/48_build_gis_indexes.sql', 'sql/run_step7b_postgis_setup.ps1', 'analysis/step7/step7b_harness.sql', 'analysis/step7/step7b_setup_checks.txt',
    'analysis/step7/step7b_setup_log.txt', 'docs/Step7A_PostGIS_Experiment_Design.md', 'docs/Step7A1_PostGIS_Installation_Preflight.md',
    'docs/Step7A2_PostGIS_Post_Installation_Verification.md', 'docs/Step7B_PostGIS_Setup_Preflight.md', 'docs/Step7C_Spatial_Index_Experiment_Design.md')

function Add-Check {
    param([string]$Id, [string]$Name, [bool]$Pass, [string]$Detail)
    $result = if ($Pass) { 'PASS' } else { 'FAIL' }
    $Results.Add([pscustomobject]@{ Id = $Id; Result = $result; Name = $Name; Detail = $Detail })
    Write-Host ("{0,-34} {1}  {2}: {3}" -f $Id, $result, $Name, $Detail)
}

function Add-Flag {
    param([string]$Id, [string]$Name, [bool]$Clean, [string]$Detail)
    $result = if ($Clean) { 'PASS' } else { 'FLAG' }
    $Results.Add([pscustomobject]@{ Id = $Id; Result = $result; Name = $Name; Detail = $Detail })
    Write-Host ("{0,-34} {1}  {2}: {3}" -f $Id, $result, $Name, $Detail)
}

function Add-Info {
    param([string]$Id, [string]$Detail)
    $Results.Add([pscustomobject]@{ Id = $Id; Result = 'INFO'; Name = 'recorded'; Detail = $Detail })
    Write-Host ("{0,-34} INFO  {1}" -f $Id, $Detail)
}

function Invoke-Capture {
    param([scriptblock]$Command, [string]$Title)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& $Command 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $previous }
    $Log.Add("==== $Title (exit $code)"); foreach ($l in $lines) { $Log.Add($l) }
    return @{ Lines = $lines; Code = $code }
}

function Invoke-PsqlFile {
    param([string]$File, [string]$Variable, [switch]$ReadOnly)
    $previousOptions = $env:PGOPTIONS
    $env:PGOPTIONS = if ($ReadOnly) { $ReadOnlyOptions } else { $null }
    try {
        $psqlArgs = @('-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', $Database, '-f', $File)
        if ($Variable) { $psqlArgs += @('-v', $Variable) }
        Write-Host "---- psql -f $File $Variable $(if ($ReadOnly) { '(read-only)' })"
        return (Invoke-Capture -Title "psql -f $File $Variable $(if ($ReadOnly) { '(read-only)' })" -Command { & $PsqlPath @psqlArgs })
    }
    finally { $env:PGOPTIONS = $previousOptions }
}

function Invoke-ReadOnlySql {
    param([string]$Sql, [string]$Title)
    $previousOptions = $env:PGOPTIONS
    $env:PGOPTIONS = $ReadOnlyOptions
    try { $r = Invoke-Capture -Title $Title -Command { $Sql | & $PsqlPath -X -A -t -v ON_ERROR_STOP=1 -d $Database -f - } } finally { $env:PGOPTIONS = $previousOptions }
    if ($r.Code -ne 0) { return "query failed with exit code $($r.Code): $(($r.Lines | Select-Object -Last 2) -join ' ')" }
    return (($r.Lines | Where-Object { $_ -ne '' }) -join "`n").Trim()
}

function Get-Sha256Hex {
    param([string]$Path)
    $stream = [System.IO.File]::Open((Resolve-Path -LiteralPath $Path).ProviderPath, 'Open', 'Read', 'ReadWrite')
    try { $sha = [System.Security.Cryptography.SHA256]::Create(); try { return (-join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() } }
    finally { $stream.Dispose() }
}

function Test-Manifest {
    param([string]$Id, [string]$Path, [int]$ExpectedFiles)
    $lines = @(([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)).Trim() -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $bad = 0
    foreach ($line in $lines) {
        if ($line -notmatch '^([0-9a-f]{64})  (\S+)$') { $bad++; continue }
        $h = $Matches[1]; $f = $Matches[2]
        if (-not (Test-Path -LiteralPath $f) -or (Get-Sha256Hex -Path $f) -ne $h) { $bad++ }
    }
    Add-Check $Id "manifest $Path" (($bad -eq 0) -and ($lines.Count -eq $ExpectedFiles)) "$($lines.Count) entries (expected $ExpectedFiles), $bad mismatches"
}

function Test-ScriptPassed {
    param([string]$Id, [string]$Name, [string]$File, [string]$Variable, [string]$Pattern, [switch]$ReadOnly)
    $r = Invoke-PsqlFile -File $File -Variable $Variable -ReadOnly:$ReadOnly
    $passed = @($r.Lines | Where-Object { $_ -match $Pattern })
    $failed = @($r.Lines | Where-Object { $_ -cmatch 'WARNING:\s+\S+\s+FAIL\b|ERROR:\s' })
    $detail = "exit $($r.Code); " + $(if ($passed.Count) { $passed[-1] -replace '^.*NOTICE:\s+', '' } else { (($r.Lines | Select-Object -Last 2) -join ' ') })
    Add-Check $Id $Name (($r.Code -eq 0) -and ($passed.Count -ge 1) -and ($failed.Count -eq 0)) $detail
    return $r
}

function Add-NoticeChecks {
    param([string]$Prefix, [object]$Run)
    foreach ($line in $Run.Lines) {
        if ($line -match '(NOTICE|WARNING):\s+(\S+) (PASS|FAIL)\s\s(.*)$') {
            $text = $Matches[4]; $sep = $text.LastIndexOf(': ')
            $name = if ($sep -gt 0) { $text.Substring(0, $sep) } else { $text }
            $detail = if ($sep -gt 0) { $text.Substring($sep + 2) } else { '' }
            Add-Check "$Prefix$($Matches[2])" $name ($Matches[3] -eq 'PASS') $detail
        }
    }
}

function Get-Fingerprints {
    param([object]$Run)
    $fp = @($Run.Lines | Where-Object { $_ -match 'NOTICE:\s+@@FP (\S+): ([0-9a-f]{32})$' } | ForEach-Object { $_ -replace '^.*@@FP ', '' })
    return ($fp -join '; ')
}

function Get-PowerState {
    $p = [System.Windows.Forms.SystemInformation]::PowerStatus
    $perf = try { [math]::Round((Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue, 1) } catch { 'n/a' }
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    return [pscustomobject]@{
        Online = ("$($p.PowerLineStatus)" -eq 'Online')
        Text   = "power=$($p.PowerLineStatus) battery=$([int]($p.BatteryLifePercent * 100))% ($($p.BatteryChargeStatus)); cpu $($cpu.CurrentClockSpeed)/$($cpu.MaxClockSpeed) MHz, processor performance $perf %, load $($cpu.LoadPercentage) %"
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# read-only state queries (stdin, so double quotes are safe)
# ---------------------------------------------------------------------------------------------------------------------
$PostgisStateSql = @'
SELECT (SELECT string_agg(extname || ' ' || extversion || ' ' || extnamespace::regnamespace::text, ', ' ORDER BY extname) FROM pg_extension)
    || '|' || (SELECT string_agg(nspname, ',' ORDER BY nspname COLLATE "C") FROM pg_namespace WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema')
    || '|' || (SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace) || '/' || (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace)
    || '/' || (SELECT count(*) FROM pg_type WHERE typnamespace = 'public'::regnamespace) || '|' || (SELECT count(*) FROM pg_event_trigger)
    || '|' || (SELECT count(*) FROM pg_db_role_setting) || '|' || current_setting('shared_preload_libraries');
'@
$InventorySql = @'
SELECT (SELECT count(*) FROM pg_class WHERE relnamespace = 'log_regex_gis'::regnamespace AND relkind = 'r')
    || '|' || (SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex_gis'::regnamespace AND i.indisprimary)
    || '|' || (SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex_gis'::regnamespace AND NOT i.indisprimary)
    || '|' || coalesce((SELECT string_agg(ic.relname, ',' ORDER BY ic.relname COLLATE "C") FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
                        JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex_gis'::regnamespace AND NOT i.indisprimary), '');
'@
$StatsSql = @'
SELECT md5(string_agg(c.relname || ':' || c.relkind::text || ':' || c.relpages || ':' || c.reltuples || ':' || c.relhasindex || ':' || c.relfilenode, chr(10) ORDER BY c.relname COLLATE "C")) || ' over ' || count(*) || ' relations'
FROM pg_class c WHERE c.relnamespace = 'log_regex_gis'::regnamespace;
SELECT count(*) || ' pg_statistic rows ' || coalesce(md5(string_agg(c.relname || ':' || s::text, chr(10) ORDER BY c.relname COLLATE "C", s.staattnum, s.stainherit)), '-')
FROM pg_statistic s JOIN pg_class c ON c.oid = s.starelid WHERE c.relnamespace = 'log_regex_gis'::regnamespace;
'@
$ActiveSql = @'
SELECT count(*) FILTER (WHERE state IS DISTINCT FROM 'idle') || ' non-idle of ' || count(*) || ' other client sessions'
FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid();
'@
$DigestSql = @'
SELECT md5(string_agg(item, chr(10) ORDER BY item COLLATE ucs_basic)) || ' over ' || count(*) || ' items'
FROM (
    SELECT 'function ' || p.oid::regprocedure::text || ' ' || md5(pg_get_functiondef(p.oid)) AS item FROM pg_proc p WHERE p.pronamespace = 'log_regex'::regnamespace AND p.prokind IN ('f', 'p')
    UNION ALL SELECT 'view ' || c.relname || ' ' || md5(pg_get_viewdef(c.oid)) FROM pg_class c WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relkind IN ('v', 'm')
    UNION ALL SELECT 'columns ' || c.relname || ' ' || md5(string_agg(a.attnum || ':' || a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum))
        FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relkind = 'r' GROUP BY c.relname
    UNION ALL SELECT 'constraint ' || c.relname || '.' || k.conname || ' ' || md5(pg_get_constraintdef(k.oid)) FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid WHERE c.relnamespace = 'log_regex'::regnamespace
    UNION ALL SELECT 'index ' || ic.relname || ' ' || md5(pg_get_indexdef(ic.oid)) FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex'::regnamespace
    UNION ALL SELECT 'trigger ' || c.relname || '.' || t.tgname || ' ' || t.tgenabled::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE c.relnamespace = 'log_regex'::regnamespace AND NOT t.tgisinternal
    UNION ALL SELECT 'internal triggers ' || c.relname || ' ' || count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE c.relnamespace = 'log_regex'::regnamespace AND t.tgisinternal GROUP BY c.relname
    UNION ALL SELECT 'rows ' || c.relname || ' ' || query_to_xml(format('SELECT count(*) AS n, md5(string_agg(t::text, chr(10) ORDER BY t::text COLLATE ucs_basic)) AS h FROM %s AS t', c.oid::regclass), false, true, '')::text
        FROM pg_class c WHERE c.relnamespace = 'log_regex'::regnamespace AND c.relkind = 'r'
) AS items;
SELECT md5(string_agg(item, chr(10) ORDER BY item COLLATE ucs_basic)) || ' over ' || count(*) || ' items'
FROM (
    SELECT 'table ' || c.relname || ' ' || coalesce(array_to_string(c.reloptions, ','), '') AS item FROM pg_class c WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
    UNION ALL SELECT 'columns ' || c.relname || ' ' || md5(string_agg(a.attnum || ':' || a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull || ':' || a.attstorage::text, ',' ORDER BY a.attnum))
        FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r' GROUP BY c.relname
    UNION ALL SELECT 'constraint ' || k.conname || ' ' || md5(pg_get_constraintdef(k.oid)) FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid WHERE c.relnamespace = 'log_regex_json'::regnamespace
    UNION ALL SELECT 'comment ' || c.relname || ' ' || md5(coalesce(obj_description(c.oid, 'pg_class'), '')) FROM pg_class c WHERE c.relnamespace = 'log_regex_json'::regnamespace AND c.relkind = 'r'
    UNION ALL SELECT 'rows access_log_json ' || count(*) || ' ' || md5(string_agg(log_id || ':' || doc::text, chr(10) ORDER BY log_id)) FROM log_regex_json.access_log_json
    UNION ALL SELECT 'rows access_log_jsonb ' || count(*) || ' ' || md5(string_agg(log_id || ':' || doc::text, chr(10) ORDER BY log_id)) FROM log_regex_json.access_log_jsonb
) AS items;
SELECT md5(string_agg(ic.relname || ' ' || pg_get_indexdef(ic.oid) || ' ' || pg_relation_size(ic.oid), chr(10) ORDER BY ic.relname)) || ' over ' || count(*) || ' indexes, ' || sum(pg_relation_size(ic.oid)) || ' bytes'
FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid WHERE c.relnamespace = 'log_regex_json'::regnamespace;
SELECT (SELECT md5(string_agg(log_id || ':' || coalesce(latitude_degrees::text, 'NULL') || ':' || coalesce(longitude_degrees::text, 'NULL'), chr(10) ORDER BY log_id)) FROM log_regex.access_log_flat)
    || '|' || (SELECT md5(string_agg(log_id || ':' || doc::text, chr(10) ORDER BY log_id)) FROM log_regex_json.access_log_jsonb);
SELECT string_agg(nspname || '=' || n, ',' ORDER BY nspname) FROM (SELECT n.nspname, count(c.oid) AS n FROM pg_namespace n LEFT JOIN pg_class c ON c.relnamespace = n.oid WHERE n.nspname IN ('log_regex', 'log_regex_json', 'log_regex_json_write') GROUP BY 1) s;
SELECT (SELECT string_agg(relkind::text || ':' || relname, ' ' ORDER BY relkind, relname) FROM pg_class WHERE relnamespace = 'log_regex_json_write'::regnamespace)
    || '|' || (SELECT md5(string_agg(doc_text, chr(10) ORDER BY log_id)) FROM log_regex_json_write.canonical_doc)
    || '|' || (SELECT string_agg(variant || ':' || n, ' ' ORDER BY variant) FROM (SELECT variant, count(*) AS n FROM log_regex_json_write.expected_update GROUP BY variant) s)
    || '|' || (SELECT count(*) FROM log_regex_json_write.access_log_json_w) || '/' || (SELECT count(*) FROM log_regex_json_write.access_log_jsonb_w);
SELECT count(*) || '/' || count(*) FILTER (WHERE passed) FROM log_regex.verify_raw_access_logs();
'@

function Test-ProjectState {
    param([string]$Prefix, [string]$When, [switch]$Full)
    $lines = @((Invoke-ReadOnlySql -Sql $DigestSql -Title "digests $When") -split "`n")
    if ($lines.Count -lt 7) { Add-Check "${Prefix}-02" "project state queries $When" $false ($lines -join ' '); return }
    Add-Check "${Prefix}-02" "log_regex digest (raw, parser, flat, answer key) $When" ($lines[0] -eq $Expected.LogRegex) $lines[0]
    Add-Check "${Prefix}-03" "log_regex_json data digest $When" ($lines[1] -eq $Expected.JsonData) $lines[1]
    Add-Check "${Prefix}-04" "Step 6D index digest $When" ($lines[2] -eq $Expected.Indexes) $lines[2]
    Add-Check "${Prefix}-05" "raw_access_logs integrity (verify_raw_access_logs checks/passed) $When" ($lines[6] -eq '10/10') $lines[6]
    Add-Check "${Prefix}-09" "Step 6E write schema state $When" ($lines[5] -eq $Expected.WriteSchema) $lines[5]
    Add-Check "${Prefix}-11" "source fingerprints flat|jsonb $When" ($lines[3] -eq $Expected.Sources) $lines[3]
    Add-Check "${Prefix}-12" "relations per existing schema $When" ($lines[4] -eq $Expected.Relations) $lines[4]
    if ($Full) {
        Test-ScriptPassed -Id "${Prefix}-06" -Name "sql/27 flat foreign keys $When" -File 'sql/27_verify_access_log_flat_foreign_keys.sql' -Pattern 'foreign-key check PASSED' -ReadOnly | Out-Null
        Test-ScriptPassed -Id "${Prefix}-07" -Name "sql/34 Step 6B verification $When" -File 'sql/34_verify_json_experiment_tables.sql' -Pattern 'JSON experiment check PASSED: all 38 checks' -ReadOnly | Out-Null
        Test-ScriptPassed -Id "${Prefix}-08" -Name "sql/38 phase final verification $When" -File 'sql/38_verify_json_index_phase.sql' -Variable 'phase=final' -Pattern 'JSON index phase final check PASSED: all 70 checks' -ReadOnly | Out-Null
        Test-Manifest -Id "${Prefix}-10a" -Path 'analysis/step6/step6d_baseline_step6c_sha256.txt' -ExpectedFiles 11
        Test-Manifest -Id "${Prefix}-10b" -Path 'analysis/step6/step6e_baseline_step6d_sha256.txt' -ExpectedFiles 26
    }
}

function Test-GisState {
    param([string]$Prefix, [string]$When, [string]$Inventory)
    $state = Invoke-ReadOnlySql -Sql $PostgisStateSql -Title "PostGIS state $When"
    Add-Check "${Prefix}-01" "PostGIS state $When (extensions|schemas|public|event triggers|role settings|preload)" ($state -eq $Expected.PostgisState) $state
    $inv = Invoke-ReadOnlySql -Sql $InventorySql -Title "log_regex_gis inventory $When"
    Add-Check "${Prefix}-13" "log_regex_gis tables|primary keys|secondary indexes|names $When" ($inv -eq $Inventory) $inv
}

function Write-Report {
    $failed = @($Results | Where-Object { $_.Result -eq 'FAIL' })
    $flags = @($Results | Where-Object { $_.Result -eq 'FLAG' })
    $passed = @($Results | Where-Object { $_.Result -eq 'PASS' })
    $lines = @("Step 7C spatial index experiment checks", "run at $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC" + $(if ($HarnessOnly) { ' (harness only)' }),
               "result: $($passed.Count) PASS, $($failed.Count) FAIL, $($flags.Count) FLAG", "")
    $lines += @($Results | ForEach-Object { "{0,-34} {1}  {2}: {3}" -f $_.Id, $_.Result, $_.Name, $_.Detail })
    [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $ReportFile), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $LogFile), (($Log -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "==== $($passed.Count) PASS, $($failed.Count) FAIL, $($flags.Count) FLAG; $ReportFile ===="
    return $failed.Count
}

function Stop-IfFailed {
    param([string]$Stage)
    if (@($Results | Where-Object { $_.Result -eq 'FAIL' }).Count -gt 0) {
        Write-Host "A check failed before '$Stage': stopping."
        Write-Report | Out-Null
        exit 1
    }
}

function Test-Gate {
    param([string]$Id, [string]$When, [string]$FingerprintsBefore, [switch]$Detailed)
    $g = Test-ScriptPassed -Id $Id -Name "sql/50 phase after (read-only) $When" -File 'sql/50_verify_gis_index_phase.sql' -Variable 'phase=after' -Pattern 'sql/50 phase after PASSED: all 745 checks' -ReadOnly
    $c03 = @($g.Lines | Where-Object { $_ -match 'NOTICE:\s+C-03:\S+ PASS  ' }).Count
    Add-Check "$Id-C03" "correctness matrix ${When}: 202 rows x 3 plan modes = plain-SQL oracle" ($c03 -eq 606) "$c03 of 606 PASS"
    $fp = Get-Fingerprints -Run $g
    Add-Check "$Id-FP" "data fingerprints of the 15 tables = before-build values ($When)" ($fp -eq $FingerprintsBefore) $fp
    if ($Detailed) {
        Add-NoticeChecks -Prefix "${Id}:" -Run $g
        foreach ($line in $g.Lines) { if ($line -match 'NOTICE:\s+(INFO .*)$') { Add-Info "$Id-INFO" $Matches[1] } }
    }
}

function Invoke-MeasureSession {
    param([int]$N)
    $raw = "$OutDir/step7c_session${N}_raw.txt"
    $err = Join-Path $ProjectRoot "$OutDir/step7c_session${N}_stderr.txt"
    $std = Join-Path $ProjectRoot "$OutDir/step7c_session${N}_stdout.txt"
    $active = Invoke-ReadOnlySql -Sql $ActiveSql -Title "sessions before measurement session $N"
    Add-Flag "E-$N-sessions" "other client sessions before session $N" ($active -match '^0 non-idle') $active
    $pw = Get-PowerState
    Add-Check "E-$N-power-before" "AC power before session $N" $pw.Online $pw.Text
    if (-not $pw.Online) { return }
    $previousOptions = $env:PGOPTIONS
    $env:PGOPTIONS = $ReadOnlyOptions
    $aborted = ''
    $t0 = Get-Date
    [Step7cPower]::SetThreadExecutionState([uint32]2147483649) | Out-Null   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    try {
        Write-Host "---- measurement session $N (read-only): psql -f sql/51_measure_gis_queries.sql -v session=$N -o $raw"
        $proc = Start-Process -FilePath $PsqlPath -ArgumentList "-X -q -v ON_ERROR_STOP=1 -d $Database -f sql/51_measure_gis_queries.sql -v session=$N -o $raw" `
            -WorkingDirectory $ProjectRoot -NoNewWindow -PassThru -RedirectStandardError $err -RedirectStandardOutput $std
        $null = $proc.Handle
        while (-not $proc.WaitForExit(2000)) {
            if ("$([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus)" -ne 'Online') {
                $aborted = "on battery at $((Get-Date).ToString('HH:mm:ss')), session aborted"
                Stop-Process -Id $proc.Id -Force
                break
            }
        }
        $proc.WaitForExit()
        $code = $proc.ExitCode
    }
    finally {
        [Step7cPower]::SetThreadExecutionState([uint32]2147483648) | Out-Null   # ES_CONTINUOUS
        $env:PGOPTIONS = $previousOptions
    }
    $seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $errLines = @(Get-Content -LiteralPath $err)
    $Log.Add("==== measurement session $N (exit $code, $seconds s) stderr"); foreach ($l in $errLines) { $Log.Add($l) }
    Add-Check "E-$N-run" "session ${N}: sql/51 exit code, no error, not aborted" (($code -eq 0) -and (-not $aborted) -and (@($errLines | Where-Object { $_ -cmatch 'ERROR:' }).Count -eq 0)) "exit $code; $seconds s; $(if ($aborted) { $aborted } else { 'completed' })"
    $lines = [System.IO.File]::ReadAllLines((Join-Path $ProjectRoot $raw))
    $runs = @($lines | Where-Object { $_.StartsWith('@@RUN ') }).Count
    $ends = @($lines | Where-Object { $_ -eq '@@END' }).Count
    $envLine = @($lines | Where-Object { $_.StartsWith('@@ENV ') }) -join ' '
    $endLine = @($lines | Where-Object { $_.StartsWith('@@SESSION_END ') }) -join ' '
    Add-Check "E-$N-count" "session ${N}: 192 series x (3 warm-up + 15 measured + detail + forced) executions" (($runs -eq 3840) -and ($ends -eq 3840) -and $endLine) "$runs runs, $ends plans; $endLine"
    Add-Info "E-$N-env" $envLine
    $busy = @($lines | Where-Object { $_ -match '^@@ACTIVE (\S+) (\d+)$' -and [int]$Matches[2] -gt 0 })
    Add-Flag "E-$N-active" "session ${N}: 0 other active client sessions before each of the 23 query blocks" ($busy.Count -eq 0) $(if ($busy.Count) { $busy -join '; ' } else { '23 blocks, all 0' })
    $pw = Get-PowerState
    Add-Check "E-$N-power-after" "AC power after session $N" $pw.Online $pw.Text
}

# ---------------------------------------------------------------------------------------------------------------------
Write-Host "==== 1. Static checks ===="
$r = Invoke-Capture -Title 'Step 7B generate --check' -Command { & $Python.Source -B $Gen7B 'generate' '--check' }
Add-Check 'R-01' 'sql/45-48 match the unchanged Step 7B generator' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
$r = Invoke-Capture -Title 'Step 7C generate --check' -Command { & $Python.Source -B $Gen 'generate' '--check' }
Add-Check 'R-02' 'sql/49-52 match the Step 7C generator' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
$r = Invoke-Capture -Title 'Step 7C static-check' -Command { & $Python.Source -B $Gen 'static-check' }
Add-Check 'R-03' 'allowlist: sql/49 = the 10 sql/48 statements x 3 + 20 drops + ANALYZE; sql/50-51 no write; no existing schema' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
$nonAscii = @(foreach ($f in @($Gen, 'sql/49_build_measure_gis_indexes.sql', 'sql/50_verify_gis_index_phase.sql', 'sql/51_measure_gis_queries.sql', 'sql/52_drop_gis_indexes.sql', 'sql/run_step7c_spatial_indexes.ps1')) {
    if ([regex]::IsMatch([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $f).ProviderPath), '[^\x00-\x7F]')) { $f } })
Add-Check 'R-04' 'Step 7C files are ASCII' ($nonAscii.Count -eq 0) $(if ($nonAscii.Count) { $nonAscii -join ', ' } else { '6 files' })
Stop-IfFailed 'manifest'

Write-Host "==== 2. Step 7B manifest ===="
if (-not (Test-Path -LiteralPath $ManifestFile)) {
    $entries = @(foreach ($f in $Step7bFiles) { "$(Get-Sha256Hex -Path $f)  $f" })
    [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $ManifestFile), (($entries -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Add-Check 'M-01' 'Step 7B baseline manifest created' ($entries.Count -eq $Step7bFiles.Count) "$($entries.Count) files -> $ManifestFile"
} else {
    Add-Check 'M-01' 'Step 7B baseline manifest present (created by an earlier run)' $true $ManifestFile
}
Test-Manifest -Id 'M-02' -Path $ManifestFile -ExpectedFiles $Step7bFiles.Count
Stop-IfFailed 'before checks'

Write-Host "==== 3. Before-integrity checks (read-only) ===="
Test-GisState -Prefix 'B' -When 'before' -Inventory $Expected.InventoryBefore
$active = Invoke-ReadOnlySql -Sql $ActiveSql -Title 'sessions before'
Add-Flag 'B-14' 'other client sessions before' ($active -match '^0 non-idle') $active
Test-ProjectState -Prefix 'B' -When 'before' -Full
Test-ScriptPassed -Id 'B-15' -Name 'sql/47 Step 7B verification (read-only) before' -File 'sql/47_verify_gis_setup.sql' -Pattern 'sql/47 PostGIS setup verification PASSED: all 155 checks' -ReadOnly | Out-Null
$b50 = Test-ScriptPassed -Id 'B-16' -Name 'sql/50 phase before (read-only): extension, isolation, no secondary index, construction checks' -File 'sql/50_verify_gis_index_phase.sql' -Variable 'phase=before' -Pattern 'sql/50 phase before PASSED: all 113 checks' -ReadOnly
Add-NoticeChecks -Prefix 'B50:' -Run $b50
$FingerprintsBefore = Get-Fingerprints -Run $b50
Add-Check 'B-17' 'data fingerprints of the 15 tables recorded' (([regex]::Matches($FingerprintsBefore, '[0-9a-f]{32}')).Count -eq 15) $FingerprintsBefore
$StatsBefore = Invoke-ReadOnlySql -Sql $StatsSql -Title 'statistics before'
Add-Info 'B-18' "pg_class and pg_statistic digests of log_regex_gis before: $($StatsBefore -replace "`n", ' | ')"
$pw = Get-PowerState
Add-Check 'B-19' 'AC power before the harness and builds' $pw.Online $pw.Text
Stop-IfFailed 'harness'

Write-Host "==== 4. Rolled-back harness ===="
$r = Invoke-Capture -Title 'harness generation' -Command { & $Python.Source -B $Gen 'harness' $HarnessFile }
$h = Invoke-PsqlFile -File $HarnessFile
$hPass = @($h.Lines | Where-Object { $_ -match 'Step 7C harness PASSED' })
$hGate = @($h.Lines | Where-Object { $_ -match 'sql/50 phase after PASSED: all 745 checks' })
$hFail = @($h.Lines | Where-Object { $_ -cmatch 'WARNING:\s+\S+\s+FAIL\b|ERROR:\s' })
$hC03 = @($h.Lines | Where-Object { $_ -match 'NOTICE:\s+C-03:\S+ PASS  ' }).Count
$hChecks = @($h.Lines | Where-Object { $_ -match '(NOTICE|WARNING):\s+\S+ (PASS|FAIL)\s\s' }).Count
Add-Check 'H-01' 'harness: 10 builds + ANALYZE 15 + sql/50 phase after (C-01..C-04) in one transaction, then ROLLBACK' (($h.Code -eq 0) -and ($hPass.Count -eq 1) -and ($hGate.Count -eq 1) -and ($hFail.Count -eq 0) -and ($hC03 -eq 606)) ("exit $($h.Code); $hChecks check lines, C-03 $hC03 of 606; " + $(if ($hFail.Count) { ($hFail | Select-Object -First 3) -join ' / ' } else { 'no FAIL' }))
$hFp = Get-Fingerprints -Run $h
Add-Check 'H-02' 'harness: data fingerprints inside the transaction = before' ($hFp -eq $FingerprintsBefore) $hFp
foreach ($line in $h.Lines) { if ($line -match 'NOTICE:\s+(INFO .*)$') { Add-Info 'H-INFO' $Matches[1] } }
Test-GisState -Prefix 'HR' -When 'after ROLLBACK' -Inventory $Expected.InventoryBefore
Test-ScriptPassed -Id 'H-03' -Name 'sql/47 Step 7B verification (read-only) after ROLLBACK' -File 'sql/47_verify_gis_setup.sql' -Pattern 'sql/47 PostGIS setup verification PASSED: all 155 checks' -ReadOnly | Out-Null
$h50 = Test-ScriptPassed -Id 'H-04' -Name 'sql/50 phase before (read-only) after ROLLBACK' -File 'sql/50_verify_gis_index_phase.sql' -Variable 'phase=before' -Pattern 'sql/50 phase before PASSED: all 113 checks' -ReadOnly
$fp = Get-Fingerprints -Run $h50
Add-Check 'H-05' 'data fingerprints after ROLLBACK = before' ($fp -eq $FingerprintsBefore) $fp
$stats = Invoke-ReadOnlySql -Sql $StatsSql -Title 'statistics after harness'
Add-Check 'H-06' 'pg_class (pages, tuples, relhasindex, filenode) and pg_statistic of log_regex_gis after ROLLBACK = before' ($stats -eq $StatsBefore) ($stats -replace "`n", ' | ')
Test-ProjectState -Prefix 'HB' -When 'after harness'
Test-Manifest -Id 'H-07' -Path $ManifestFile -ExpectedFiles $Step7bFiles.Count
Stop-IfFailed 'real builds'
if ($HarnessOnly) { exit ([Math]::Min(1, (Write-Report))) }

Write-Host "==== 5. sql/49: 3 builds per index, ANALYZE ===="
$b = Test-ScriptPassed -Id 'S-49' -Name 'sql/49 -v approved_step=7C: 10 indexes x 3 timed builds, third kept, ANALYZE 15 tables' -File 'sql/49_build_measure_gis_indexes.sql' -Variable 'approved_step=7C' -Pattern '@@INDEXSIZE phase=after index=jsonb_geom_gist_idx'
[System.IO.File]::WriteAllText((Join-Path $ProjectRoot $BuildLog), (($b.Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
$builds = @($b.Lines | Where-Object { $_ -match '@@BUILD id=' }).Count
$sizes = @($b.Lines | Where-Object { $_ -match '@@INDEXSIZE phase=after' }).Count
Add-Check 'S-49b' 'build records and index sizes' (($builds -eq 30) -and ($sizes -eq 10)) "$builds @@BUILD lines (expected 30), $sizes index sizes after (expected 10); $BuildLog"
$pw = Get-PowerState
Add-Check 'S-49c' 'AC power after the builds' $pw.Online $pw.Text
Test-GisState -Prefix 'A49' -When 'after sql/49' -Inventory $Expected.InventoryAfter
if (@($Results | Where-Object { $_.Result -eq 'FAIL' }).Count -gt 0) {
    Write-Host "Build phase failed: cleanup with sql/52 back to the Step 7B state."
    Test-ScriptPassed -Id 'X-52' -Name 'sql/52 cleanup -v confirm_cleanup=yes' -File 'sql/52_drop_gis_indexes.sql' -Variable 'confirm_cleanup=yes' -Pattern '.' | Out-Null
    Test-GisState -Prefix 'X' -When 'after cleanup' -Inventory $Expected.InventoryBefore
    Test-ScriptPassed -Id 'X-47' -Name 'sql/47 (read-only) after cleanup' -File 'sql/47_verify_gis_setup.sql' -Pattern 'sql/47 PostGIS setup verification PASSED: all 155 checks' -ReadOnly | Out-Null
    Write-Report | Out-Null
    exit 1
}
$StatsAfterBuild = Invoke-ReadOnlySql -Sql $StatsSql -Title 'statistics after build'
Add-Info 'A49-stats' "pg_class and pg_statistic digests after build and ANALYZE: $($StatsAfterBuild -replace "`n", ' | ')"

Write-Host "==== 6. Gate before session 1 ===="
Test-Gate -Id 'G-50a' -When 'before session 1' -FingerprintsBefore $FingerprintsBefore -Detailed
Stop-IfFailed 'session 1'

Write-Host "==== 7. Measurement session 1 ===="
Invoke-MeasureSession -N 1
Stop-IfFailed 'gate before session 2'

Write-Host "==== 8. Gate before session 2 ===="
Test-Gate -Id 'G-50b' -When 'before session 2' -FingerprintsBefore $FingerprintsBefore
Stop-IfFailed 'session 2'

Write-Host "==== 9. Measurement session 2 ===="
Invoke-MeasureSession -N 2
Stop-IfFailed 'gate after session 2'

Write-Host "==== 10. Gate after session 2 ===="
Test-Gate -Id 'G-50c' -When 'after session 2' -FingerprintsBefore $FingerprintsBefore

Write-Host "==== 11. After-integrity checks ===="
Test-GisState -Prefix 'Z' -When 'after' -Inventory $Expected.InventoryAfter
$stats = Invoke-ReadOnlySql -Sql $StatsSql -Title 'statistics after sessions'
Add-Check 'Z-14' 'pg_class and pg_statistic of log_regex_gis unchanged by the read-only sessions' ($stats -eq $StatsAfterBuild) ($stats -replace "`n", ' | ')
Test-ProjectState -Prefix 'Z' -When 'after' -Full
Test-Manifest -Id 'Z-15' -Path $ManifestFile -ExpectedFiles $Step7bFiles.Count
$r = Invoke-Capture -Title 'Step 7B generate --check after' -Command { & $Python.Source -B $Gen7B 'generate' '--check' }
Add-Check 'Z-16' 'sql/45-48 still match the Step 7B generator' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())

Write-Host "==== 12. Analysis ===="
$r = Invoke-Capture -Title 'analyze' -Command { & $Python.Source -B $Gen 'analyze' '--session1' "$OutDir/step7c_session1_raw.txt" '--session2' "$OutDir/step7c_session2_raw.txt" '--build-log' $BuildLog }
Add-Check 'N-01' 'analysis: 7,680 executions parsed, row counts, no JIT, 30 builds; CSVs and step7c_summary.md written' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
exit ([Math]::Min(1, (Write-Report)))
