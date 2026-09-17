<#
.SYNOPSIS
    Step 7B - PostGIS setup: before-integrity checks, rolled-back harness, extension, 15 tables, verification, after checks.

.DESCRIPTION
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.
    Plan: docs/Step7B_PostGIS_Setup_Preflight.md (approved). Every check is PASS/FAIL in analysis/step7/step7b_setup_checks.txt.

      1. static (R-01 .. R-03): generated sql/45-48 up to date; statement allowlist; ASCII
      2. before (B-01 .. B-12, read-only): pre-setup state, digests, raw integrity 10/10, sql/27, sql/34, sql/38 final,
         Step 6E write schema, manifests, source fingerprints, relations per schema
      3. harness (H-01, H-02): sql/45 + sql/46 + sql/47 + E4 in one transaction, ROLLBACK; the database is unchanged afterwards
      4. sql/45 (S-45, A-45): extension postgis 3.6.2 in schema postgis
      5. sql/46 (S-46): schema log_regex_gis, 15 tables, gate, VACUUM (ANALYZE)
      6. sql/47 (V-47, read-only): every check reported individually
      7. after (A-01 .. A-02, B-02 .. B-12 again)
    A failed check stops before the next writing stage. No Step 7C index is created; sql/48 is never run here.

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
$Gen = 'scripts/step7_postgis_experiment.py'
$OutDir = 'analysis/step7'
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$ReportFile = "$OutDir/step7b_setup_checks.txt"
$LogFile = "$OutDir/step7b_setup_log.txt"
$HarnessFile = "$OutDir/step7b_harness.sql"
$Results = New-Object System.Collections.Generic.List[object]
$Log = New-Object System.Collections.Generic.List[string]
$Expected = @{
    LogRegex = 'f8042db0318656b5929c86ea1f7888d4 over 203 items'
    JsonData = '9e6f883112c4a01781bdce5cf9bf3a28 over 10 items'
    Indexes  = 'e20752ca02d09e89281503569650d0ce over 14 indexes, 9510912 bytes'
    PreState = '3.6.2|none|plpgsql|true|true|0|0/0/0|0||0'
    Sources  = 'f562354dbf6c155f3ed0a93da433e79c|fb3bc16318e6a81c7930aed2217986ea'
    Relations = 'log_regex=49,log_regex_json=16,log_regex_json_write=8'
    WriteSchema = 'i:access_log_json_w_pkey i:access_log_jsonb_w_pkey i:canonical_doc_pkey i:expected_update_pkey r:access_log_json_w r:access_log_jsonb_w r:canonical_doc r:expected_update|aeaef32371fa8143c088d4fdce9f6e0d|UA-1:238 UA-2:238 UA-3:5000|0/0'
}

function Add-Check {
    param([string]$Id, [string]$Name, [bool]$Pass, [string]$Detail)
    $result = if ($Pass) { 'PASS' } else { 'FAIL' }
    $Results.Add([pscustomobject]@{ Id = $Id; Result = $result; Name = $Name; Detail = $Detail })
    Write-Host ("{0,-28} {1}  {2}: {3}" -f $Id, $result, $Name, $Detail)
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
        return (Invoke-Capture -Title "psql -f $File $Variable" -Command { & $PsqlPath @psqlArgs })
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
    $failed = @($r.Lines | Where-Object { $_ -match 'WARNING:\s+\S+\s+FAIL\b' })
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

# ---------------------------------------------------------------------------------------------------------------------
# read-only state queries (stdin, so double quotes are safe)
# ---------------------------------------------------------------------------------------------------------------------
$PreStateSql = @'
SELECT coalesce((SELECT default_version FROM pg_available_extensions WHERE name = 'postgis'), 'none') || '|' || coalesce((SELECT installed_version FROM pg_available_extensions WHERE name = 'postgis'), 'none')
    || '|' || (SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension) || '|' || (to_regnamespace('postgis') IS NULL) || '|' || (to_regnamespace('log_regex_gis') IS NULL)
    || '|' || (SELECT count(*) FROM pg_type WHERE typname IN ('geometry', 'geography')) || '|' || (SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace)
    || '/' || (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace) || '/' || (SELECT count(*) FROM pg_type WHERE typnamespace = 'public'::regnamespace)
    || '|' || (SELECT count(*) FROM pg_event_trigger) || '|' || current_setting('shared_preload_libraries')
    || '|' || (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() AND state IS DISTINCT FROM 'idle');
'@
$InfoSql = @'
SELECT 'postmaster start ' || pg_postmaster_start_time() || '; pg_db_role_setting rows ' || (SELECT count(*) FROM pg_db_role_setting) || '; other client sessions ' || (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid());
'@
$AfterStateSql = @'
SELECT (SELECT string_agg(extname || ' ' || extversion || ' ' || extnamespace::regnamespace::text, ', ' ORDER BY extname) FROM pg_extension)
    || '|' || (SELECT string_agg(nspname, ',' ORDER BY nspname COLLATE "C") FROM pg_namespace WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema')
    || '|' || (SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace) || '/' || (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace)
    || '/' || (SELECT count(*) FROM pg_type WHERE typnamespace = 'public'::regnamespace) || '|' || (SELECT count(*) FROM pg_event_trigger)
    || '|' || (SELECT count(*) FROM pg_db_role_setting) || '|' || current_setting('shared_preload_libraries');
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

function Write-Report {
    $failed = @($Results | Where-Object { $_.Result -ne 'PASS' })
    $lines = @("Step 7B PostGIS setup checks", "run at $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC" + $(if ($HarnessOnly) { ' (harness only)' }),
               "result: $($Results.Count - $failed.Count) PASS, $($failed.Count) FAIL of $($Results.Count) checks", "")
    $lines += @($Results | ForEach-Object { "{0,-28} {1}  {2}: {3}" -f $_.Id, $_.Result, $_.Name, $_.Detail })
    [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $ReportFile), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $LogFile), (($Log -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "==== $($Results.Count - $failed.Count) PASS, $($failed.Count) FAIL of $($Results.Count) checks; $ReportFile ===="
    return $failed.Count
}

function Stop-IfFailed {
    param([string]$Stage)
    if (@($Results | Where-Object { $_.Result -ne 'PASS' }).Count -gt 0) {
        Write-Host "A check failed before '$Stage': stopping."
        Write-Report | Out-Null
        exit 1
    }
}

# ---------------------------------------------------------------------------------------------------------------------
Write-Host "==== 1. Static checks ===="
$r = Invoke-Capture -Title 'generate --check' -Command { & $Python.Source -B $Gen 'generate' '--check' }
Add-Check 'R-01' 'sql/45-48 match the generator' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
$r = Invoke-Capture -Title 'static-check' -Command { & $Python.Source -B $Gen 'static-check' }
Add-Check 'R-02' 'statement allowlist: writes only postgis/log_regex_gis, one read per source, sql/47 read-only, sql/48 = 10 indexes' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
$nonAscii = @(foreach ($f in @('sql/45_create_postgis_extension.sql', 'sql/46_create_gis_tables.sql', 'sql/47_verify_gis_setup.sql', 'sql/48_build_gis_indexes.sql', $Gen, 'sql/run_step7b_postgis_setup.ps1')) {
    if ([regex]::IsMatch([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $f).ProviderPath), '[^\x00-\x7F]')) { $f } })
Add-Check 'R-03' 'Step 7B files are ASCII' ($nonAscii.Count -eq 0) $(if ($nonAscii.Count) { $nonAscii -join ', ' } else { '6 files' })
Stop-IfFailed 'before checks'

Write-Host "==== 2. Before-integrity checks (read-only) ===="
$state = Invoke-ReadOnlySql -Sql $PreStateSql -Title 'pre-setup state'
Add-Check 'B-01' 'pre-setup state (postgis available|installed|extensions|postgis absent|log_regex_gis absent|types|public|event triggers|preload|non-idle sessions)' ($state -eq $Expected.PreState) $state
$info = Invoke-ReadOnlySql -Sql $InfoSql -Title 'info'
Write-Host "info: $info"; $Log.Add("INFO before: $info")
$roleSettingsBefore = if ($info -match 'pg_db_role_setting rows (\d+)') { $Matches[1] } else { '?' }
Test-ProjectState -Prefix 'B' -When 'before' -Full
Stop-IfFailed 'harness'

Write-Host "==== 3. Rolled-back harness ===="
$r = Invoke-Capture -Title 'harness generation' -Command { & $Python.Source -B $Gen 'harness' $HarnessFile }
$h = Invoke-PsqlFile -File $HarnessFile
$hPass = @($h.Lines | Where-Object { $_ -match 'Step 7B harness PASSED' })
$hFail = @($h.Lines | Where-Object { $_ -cmatch 'WARNING:\s+\S+\s+FAIL\b|ERROR:\s' })
$hChecks = @($h.Lines | Where-Object { $_ -match '(NOTICE|WARNING):\s+\S+ (PASS|FAIL)\s\s' }).Count
Add-Check 'H-01' 'harness: sql/45 + sql/46 + sql/47 + E4 in one transaction, then ROLLBACK' (($h.Code -eq 0) -and ($hPass.Count -eq 1) -and ($hFail.Count -eq 0)) ("exit $($h.Code); $hChecks check lines; " + $(if ($hFail.Count) { ($hFail | Select-Object -First 3) -join ' / ' } else { 'no FAIL' }))
$state = Invoke-ReadOnlySql -Sql $PreStateSql -Title 'state after harness'
Add-Check 'H-02' 'after ROLLBACK the database is in the pre-setup state (no extension, no schemas)' ($state -eq $Expected.PreState) $state
Test-ProjectState -Prefix 'HB' -When 'after harness'
Stop-IfFailed 'real setup'
if ($HarnessOnly) { exit ([Math]::Min(1, (Write-Report))) }

Write-Host "==== 4. sql/45: extension ===="
$s45 = Test-ScriptPassed -Id 'S-45' -Name 'sql/45 extension postgis 3.6.2 in schema postgis (gate X-01 .. X-06)' -File 'sql/45_create_postgis_extension.sql' -Pattern 'sql/45 extension gate PASSED'
Add-NoticeChecks -Prefix 'sql45:' -Run $s45
$after = Invoke-ReadOnlySql -Sql $AfterStateSql -Title 'state after sql/45'
Add-Check 'A-45' 'after sql/45: extensions|schemas|public|event triggers|role settings|preload' ($after -eq "plpgsql 1.0 pg_catalog, postgis 3.6.2 postgis|log_regex,log_regex_json,log_regex_json_write,postgis,public|0/0/0|0|$roleSettingsBefore|") $after
Test-ProjectState -Prefix 'A45' -When 'after sql/45'
Stop-IfFailed 'sql/46'

Write-Host "==== 5. sql/46: tables ===="
$s46 = Test-ScriptPassed -Id 'S-46' -Name 'sql/46 schema log_regex_gis, 15 tables, gate O-1/O-7, VACUUM (ANALYZE)' -File 'sql/46_create_gis_tables.sql' -Pattern 'sql/46 setup gate PASSED'
Add-NoticeChecks -Prefix 'sql46:' -Run $s46
Stop-IfFailed 'sql/47'

Write-Host "==== 6. sql/47: verification (read-only) ===="
$v47 = Test-ScriptPassed -Id 'V-47' -Name 'sql/47 read-only verification (X, A, O-1, O-7, O-2 .. O-5, E1 .. E3)' -File 'sql/47_verify_gis_setup.sql' -Pattern 'sql/47 PostGIS setup verification PASSED' -ReadOnly
Add-NoticeChecks -Prefix 'sql47:' -Run $v47
foreach ($line in $v47.Lines) { if ($line -match 'NOTICE:\s+(INFO .*)$') { Add-Check 'INFO' 'recorded' $true $Matches[1] } }

Write-Host "==== 7. After-integrity checks ===="
$after = Invoke-ReadOnlySql -Sql $AfterStateSql -Title 'state after setup'
Add-Check 'A-01/A-02' 'after setup: extensions|schemas|public|event triggers|role settings|preload' ($after -eq "plpgsql 1.0 pg_catalog, postgis 3.6.2 postgis|log_regex,log_regex_gis,log_regex_json,log_regex_json_write,postgis,public|0/0/0|0|$roleSettingsBefore|") $after
Test-ProjectState -Prefix 'Z' -When 'after setup' -Full
exit ([Math]::Min(1, (Write-Report)))
