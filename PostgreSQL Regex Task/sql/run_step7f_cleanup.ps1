<#
.SYNOPSIS
    Step 7F - PostGIS cleanup, Option A: drop exactly the 10 Step 7C indexes with sql/52; keep the 15 log_regex_gis tables
    and PostGIS 3.6.2. Before checks, rolled-back harness, single-transaction cleanup, final-state checks.

.DESCRIPTION
    Connection settings come from PGHOST, PGPORT, PGUSER and PGPASSWORD; PGDATABASE is ignored.
    Plan: docs/Step7F_PostGIS_Cleanup_and_Final_State_Plan.md (approved, Option A only).

      1. static (R-01 .. R-04), manifests (M-01 .. M-03; the 32-file Step 7F manifest is created once)
      2. before, read-only (F-01 .. F-08, B-02 .. B-12): Step 7C state with the 10 indexes, sql/50 phase after 745/745
      3. harness (H-01 .. H-07): sql/52 + sql/47 + sql/50 phase before in one transaction, ROLLBACK; Step 7C state restored
      4. cleanup (S-52, S-52b): psql --single-transaction -v confirm_cleanup=yes -f sql/52, lock_timeout 5s
      5. after, read-only (Z-01 .. Z-22, ZP-*): the approved final state of plan section 8

.PARAMETER HarnessOnly
    Stop after the harness and its rollback verification (no committed change).

.PARAMETER AfterOnly
    Static checks, manifest verification and the after checks only (read-only re-verification of the final state).
#>
param(
    [string]$PsqlPath = "C:\Program Files\PostgreSQL\17\bin\psql.exe",
    [switch]$HarnessOnly,
    [switch]$AfterOnly
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
if ($HarnessOnly -and $AfterOnly) { throw "use either -HarnessOnly or -AfterOnly" }
$Gen7B = 'scripts/step7_postgis_experiment.py'
$Gen7C = 'scripts/step7c_spatial_index_experiment.py'
$OutDir = 'analysis/step7'
$Mode = if ($HarnessOnly) { 'harness only' } elseif ($AfterOnly) { 'after checks only' } else { 'full cleanup' }
$ReportFile = if ($HarnessOnly) { "$OutDir/step7f_harness_only_checks.txt" } elseif ($AfterOnly) { "$OutDir/step7f_final_state_recheck.txt" } else { "$OutDir/step7f_cleanup_checks.txt" }
$LogFile = $ReportFile -replace '_checks\.txt$|\.txt$', '_log.txt'
$HarnessFile = "$OutDir/step7f_harness.sql"
$Manifest7B = "$OutDir/step7c_baseline_step7b_sha256.txt"
$Manifest7F = "$OutDir/step7f_baseline_step7c_step7e_sha256.txt"
$Results = New-Object System.Collections.Generic.List[object]
$Log = New-Object System.Collections.Generic.List[string]

$IndexNames = 'flat_geog_gist_idx,flat_geog_spgist_idx,flat_geom_brin_idx,flat_geom_gist_idx,flat_geom_spgist_idx,flat_numeric_btree_lat_lon_idx,jsonb_doc_expr_geog_gist_idx,jsonb_doc_expr_geom_gist_idx,jsonb_geog_gist_idx,jsonb_geom_gist_idx'
$TableNames = @('flat_numeric', 'flat_numeric_btree', 'flat_geom', 'flat_geom_gist', 'flat_geom_spgist', 'flat_geom_brin', 'flat_geog', 'flat_geog_gist',
    'flat_geog_spgist', 'jsonb_doc', 'jsonb_doc_expr', 'jsonb_geom', 'jsonb_geom_gist', 'jsonb_geog', 'jsonb_geog_gist')
$FpNumeric = 'aa8e40226347b042954cb74662f2c990'; $FpPoint = '9f32c783e7ea53beefdf1efee8be7aa5'; $FpDoc = '66e5ca3a787032464c934cd2336366f1'; $FpDocPoint = '01db45d3dfeffa423eb79f85e07a9a13'
$FpByTable = @{ flat_numeric = $FpNumeric; flat_numeric_btree = $FpNumeric; flat_geom = $FpPoint; flat_geom_gist = $FpPoint; flat_geom_spgist = $FpPoint;
    flat_geom_brin = $FpPoint; flat_geog = $FpPoint; flat_geog_gist = $FpPoint; flat_geog_spgist = $FpPoint; jsonb_doc = $FpDoc; jsonb_doc_expr = $FpDoc;
    jsonb_geom = $FpDocPoint; jsonb_geom_gist = $FpDocPoint; jsonb_geog = $FpDocPoint; jsonb_geog_gist = $FpDocPoint }
$SortedTables = [string[]]$TableNames.Clone(); [Array]::Sort($SortedTables, [System.StringComparer]::Ordinal)
$SortedPkeys = [string[]]($TableNames | ForEach-Object { "${_}_pkey" }); [Array]::Sort($SortedPkeys, [System.StringComparer]::Ordinal)
$Expected = @{
    LogRegex     = 'f8042db0318656b5929c86ea1f7888d4 over 203 items'
    JsonData     = '9e6f883112c4a01781bdce5cf9bf3a28 over 10 items'
    Indexes      = 'e20752ca02d09e89281503569650d0ce over 14 indexes, 9510912 bytes'
    Sources      = 'f562354dbf6c155f3ed0a93da433e79c|fb3bc16318e6a81c7930aed2217986ea'
    Relations    = 'log_regex=49,log_regex_json=16,log_regex_json_write=8'
    WriteSchema  = 'i:access_log_json_w_pkey i:access_log_jsonb_w_pkey i:canonical_doc_pkey i:expected_update_pkey r:access_log_json_w r:access_log_jsonb_w r:canonical_doc r:expected_update|aeaef32371fa8143c088d4fdce9f6e0d|UA-1:238 UA-2:238 UA-3:5000|0/0'
    PostgisState = 'plpgsql 1.0 pg_catalog, postgis 3.6.2 postgis|log_regex,log_regex_gis,log_regex_json,log_regex_json_write,postgis,public|0/0/0|0|0|'
    Inventory7C  = "15|15|10|$IndexNames"
    InventoryEnd = '15|15|0|'
    Schemas7C    = 'log_regex=49,log_regex_gis=40,log_regex_json=16,log_regex_json_write=8,postgis=6,public=0'
    SchemasEnd   = 'log_regex=49,log_regex_gis=30,log_regex_json=16,log_regex_json_write=8,postgis=6,public=0'
    Dependencies = '0|0'
    Fingerprints = (($TableNames | ForEach-Object { "${_}: $($FpByTable[$_])" }) -join '; ')
    Stats7C      = "559fc36d84e7c2b0d06f2cde4888dd86 over 40 relations`n38 pg_statistic rows add136862deffe6f7eaf5252229ac2ed"
    TablesEnd    = (($SortedTables | ForEach-Object { "${_}=5000" }) -join ',') + '|' + ($SortedPkeys -join ',')
}
$Step7fFiles = @('scripts/step7c_spatial_index_experiment.py', 'sql/49_build_measure_gis_indexes.sql', 'sql/50_verify_gis_index_phase.sql',
    'sql/51_measure_gis_queries.sql', 'sql/52_drop_gis_indexes.sql', 'sql/run_step7c_spatial_indexes.ps1',
    'analysis/step7/step7c_baseline_step7b_sha256.txt', 'analysis/step7/step7c_build_log.txt', 'analysis/step7/step7c_builds.csv',
    'analysis/step7/step7c_sizes.csv', 'analysis/step7/step7c_checks.txt', 'analysis/step7/step7c_run_log.txt', 'analysis/step7/step7c_harness.sql',
    'analysis/step7/step7c_harness_only_checks.txt', 'analysis/step7/step7c_harness_only_log.txt', 'analysis/step7/step7c_session1_raw.txt',
    'analysis/step7/step7c_session1_stderr.txt', 'analysis/step7/step7c_session1_stdout.txt', 'analysis/step7/step7c_session2_raw.txt',
    'analysis/step7/step7c_session2_stderr.txt', 'analysis/step7/step7c_session2_stdout.txt', 'analysis/step7/step7c_executions.csv',
    'analysis/step7/step7c_summary.csv', 'analysis/step7/step7c_summary.md', 'analysis/step7/step7c_verdicts.csv', 'analysis/step7/step7c_comparisons.csv',
    'docs/Step7C_Spatial_Index_Experiment.md', 'docs/Step7D_PostGIS_Results_Analysis.md', 'docs/Step7E_PostGIS_Final_Conclusion.md',
    'data/raw_access_logs.csv', 'data/expected_fields.csv', 'data/dataset_manifest.json')

function Add-Check {
    param([string]$Id, [string]$Name, [bool]$Pass, [string]$Detail)
    $result = if ($Pass) { 'PASS' } else { 'FAIL' }
    $Results.Add([pscustomobject]@{ Id = $Id; Result = $result; Name = $Name; Detail = $Detail })
    Write-Host ("{0,-24} {1}  {2}: {3}" -f $Id, $result, $Name, $Detail)
}

function Add-Info {
    param([string]$Id, [string]$Detail)
    $Results.Add([pscustomobject]@{ Id = $Id; Result = 'INFO'; Name = 'recorded'; Detail = $Detail })
    Write-Host ("{0,-24} INFO  {1}" -f $Id, $Detail)
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
    param([string]$File, [string]$Variable, [switch]$ReadOnly, [switch]$SingleTransaction, [string]$Options)
    $previousOptions = $env:PGOPTIONS
    $env:PGOPTIONS = if ($ReadOnly) { $ReadOnlyOptions } elseif ($Options) { $Options } else { $null }
    try {
        $psqlArgs = @('-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', $Database)
        if ($SingleTransaction) { $psqlArgs += '--single-transaction' }
        if ($Variable) { $psqlArgs += @('-v', $Variable) }
        $psqlArgs += @('-f', $File)
        $label = "psql -f $File $Variable$(if ($SingleTransaction) { ' --single-transaction' })$(if ($ReadOnly) { ' (read-only)' })$(if ($Options) { " PGOPTIONS=$Options" })"
        Write-Host "---- $label"
        return (Invoke-Capture -Title $label -Command { & $PsqlPath @psqlArgs })
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
    if (-not (Test-Path -LiteralPath $Path)) { Add-Check $Id "manifest $Path" $false 'missing'; return }
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
$SchemaRelationsSql = @'
SELECT string_agg(nspname || '=' || n, ',' ORDER BY nspname COLLATE "C") FROM (SELECT n.nspname, count(c.oid) AS n FROM pg_namespace n LEFT JOIN pg_class c ON c.relnamespace = n.oid
WHERE n.nspname IN ('log_regex', 'log_regex_gis', 'log_regex_json', 'log_regex_json_write', 'postgis', 'public') GROUP BY 1) s;
'@
$DependencySql = @'
SELECT (SELECT count(*) FROM pg_depend d
          JOIN pg_depend e ON e.classid = d.refclassid AND e.objid = d.refobjid AND e.deptype = 'e' AND e.refclassid = 'pg_extension'::regclass
               AND e.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'postgis')
          LEFT JOIN pg_class c ON d.classid = 'pg_class'::regclass AND c.oid = d.objid
          LEFT JOIN pg_attrdef ad ON d.classid = 'pg_attrdef'::regclass AND ad.oid = d.objid LEFT JOIN pg_class c2 ON c2.oid = ad.adrelid
          LEFT JOIN pg_type t ON d.classid = 'pg_type'::regclass AND t.oid = d.objid
          LEFT JOIN pg_proc p ON d.classid = 'pg_proc'::regclass AND p.oid = d.objid
          WHERE d.deptype <> 'e' AND coalesce(c.relnamespace, c2.relnamespace, t.typnamespace, p.pronamespace) IS NOT NULL
            AND coalesce(c.relnamespace, c2.relnamespace, t.typnamespace, p.pronamespace) NOT IN ('postgis'::regnamespace, 'log_regex_gis'::regnamespace, 'pg_toast'::regnamespace))
    || '|' || (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_type t ON t.oid = a.atttypid
               WHERE t.typnamespace = 'postgis'::regnamespace AND c.relnamespace NOT IN ('postgis'::regnamespace, 'log_regex_gis'::regnamespace) AND a.attnum > 0 AND NOT a.attisdropped);
'@
$TablesSql = @'
SELECT (SELECT string_agg(c.relname || '=' || (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM log_regex_gis.%I', c.relname), false, true, '')))[1]::text, ',' ORDER BY c.relname COLLATE "C")
        FROM pg_class c WHERE c.relnamespace = 'log_regex_gis'::regnamespace AND c.relkind = 'r')
    || '|' || (SELECT string_agg(ic.relname, ',' ORDER BY ic.relname COLLATE "C") FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
               WHERE c.relnamespace = 'log_regex_gis'::regnamespace AND i.indisprimary);
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
$SizeSql = @'
SELECT 'log_regex_gis total bytes ' || sum(pg_total_relation_size(oid)) || ' (heap+toast ' || sum(pg_table_size(oid)) || ', indexes ' || sum(pg_indexes_size(oid)) || '); database bytes ' || pg_database_size(current_database())
FROM pg_class WHERE relnamespace = 'log_regex_gis'::regnamespace AND relkind = 'r';
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
    Add-Check "${Prefix}-02" "log_regex digest (raw_access_logs, access_log_flat, parser, answer key) $When" ($lines[0] -eq $Expected.LogRegex) $lines[0]
    Add-Check "${Prefix}-03" "log_regex_json data digest (Step 6B JSON/JSONB tables) $When" ($lines[1] -eq $Expected.JsonData) $lines[1]
    Add-Check "${Prefix}-04" "Step 6D index digest $When" ($lines[2] -eq $Expected.Indexes) $lines[2]
    Add-Check "${Prefix}-05" "raw_access_logs integrity (verify_raw_access_logs checks/passed) $When" ($lines[6] -eq '10/10') $lines[6]
    Add-Check "${Prefix}-09" "Step 6E write schema state $When" ($lines[5] -eq $Expected.WriteSchema) $lines[5]
    Add-Check "${Prefix}-11" "source fingerprints access_log_flat|access_log_jsonb $When" ($lines[3] -eq $Expected.Sources) $lines[3]
    Add-Check "${Prefix}-12" "relations per existing schema $When" ($lines[4] -eq $Expected.Relations) $lines[4]
    if ($Full) {
        Test-ScriptPassed -Id "${Prefix}-06" -Name "sql/27 access_log_flat foreign keys $When" -File 'sql/27_verify_access_log_flat_foreign_keys.sql' -Pattern 'foreign-key check PASSED' -ReadOnly | Out-Null
        Test-ScriptPassed -Id "${Prefix}-07" -Name "sql/34 Step 6B verification $When" -File 'sql/34_verify_json_experiment_tables.sql' -Pattern 'JSON experiment check PASSED: all 38 checks' -ReadOnly | Out-Null
        Test-ScriptPassed -Id "${Prefix}-08" -Name "sql/38 phase final (Step 6D indexes) $When" -File 'sql/38_verify_json_index_phase.sql' -Variable 'phase=final' -Pattern 'JSON index phase final check PASSED: all 70 checks' -ReadOnly | Out-Null
        Test-Manifest -Id "${Prefix}-10a" -Path 'analysis/step6/step6d_baseline_step6c_sha256.txt' -ExpectedFiles 11
        Test-Manifest -Id "${Prefix}-10b" -Path 'analysis/step6/step6e_baseline_step6d_sha256.txt' -ExpectedFiles 26
    }
}

function Test-GisState {
    param([string]$Prefix, [string]$When, [string]$Inventory, [string]$Schemas)
    $state = Invoke-ReadOnlySql -Sql $PostgisStateSql -Title "PostGIS state $When"
    Add-Check "${Prefix}-01" "PostGIS installed, extensions|schemas|public|event triggers|role settings|preload $When" ($state -eq $Expected.PostgisState) $state
    $inv = Invoke-ReadOnlySql -Sql $InventorySql -Title "log_regex_gis inventory $When"
    Add-Check "${Prefix}-02" "log_regex_gis tables|primary keys|secondary indexes|names $When" ($inv -eq $Inventory) $inv
    $rel = Invoke-ReadOnlySql -Sql $SchemaRelationsSql -Title "relations per schema $When"
    Add-Check "${Prefix}-03" "relations per schema $When" ($rel -eq $Schemas) $rel
    $dep = Invoke-ReadOnlySql -Sql $DependencySql -Title "PostGIS dependencies $When"
    Add-Check "${Prefix}-04" "objects outside postgis/log_regex_gis depending on PostGIS | PostGIS-type columns outside $When" ($dep -eq $Expected.Dependencies) $dep
}

function Write-Report {
    $failed = @($Results | Where-Object { $_.Result -eq 'FAIL' })
    $passed = @($Results | Where-Object { $_.Result -eq 'PASS' })
    $lines = @("Step 7F PostGIS cleanup (Option A) checks", "run at $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC ($Mode)",
               "result: $($passed.Count) PASS, $($failed.Count) FAIL", "")
    $lines += @($Results | ForEach-Object { "{0,-24} {1}  {2}: {3}" -f $_.Id, $_.Result, $_.Name, $_.Detail })
    [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $ReportFile), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $LogFile), (($Log -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "==== $($passed.Count) PASS, $($failed.Count) FAIL; $ReportFile ===="
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

function Test-FinalState {
    Write-Host "==== After checks: approved final state (read-only) ===="
    Test-GisState -Prefix 'Z' -When 'after cleanup' -Inventory $Expected.InventoryEnd -Schemas $Expected.SchemasEnd
    $tables = Invoke-ReadOnlySql -Sql $TablesSql -Title 'GIS tables and primary keys after'
    Add-Check 'Z-05' 'the 15 GIS tables with 5,000 rows each | their 15 primary keys' ($tables -eq $Expected.TablesEnd) $tables
    $z47 = Test-ScriptPassed -Id 'Z-06' -Name 'sql/47 Step 7B verification (read-only): extension, isolation, no secondary index, construction, oracles' -File 'sql/47_verify_gis_setup.sql' -Pattern 'sql/47 PostGIS setup verification PASSED: all 155 checks' -ReadOnly
    Add-NoticeChecks -Prefix 'Z47:' -Run $z47
    $z50 = Test-ScriptPassed -Id 'Z-07' -Name 'sql/50 phase before (read-only)' -File 'sql/50_verify_gis_index_phase.sql' -Variable 'phase=before' -Pattern 'sql/50 phase before PASSED: all 113 checks' -ReadOnly
    Add-NoticeChecks -Prefix 'Z50:' -Run $z50
    $fp = Get-Fingerprints -Run $z50
    Add-Check 'Z-08' 'data fingerprints of the 15 GIS tables = Step 7C values' ($fp -eq $Expected.Fingerprints) $fp
    Test-ProjectState -Prefix 'ZP' -When 'after cleanup' -Full
    Test-Manifest -Id 'Z-09' -Path $Manifest7B -ExpectedFiles 14
    Test-Manifest -Id 'Z-10' -Path $Manifest7F -ExpectedFiles $Step7fFiles.Count
    $r = Invoke-Capture -Title 'Step 7B generate --check after' -Command { & $Python.Source -B $Gen7B 'generate' '--check' }
    Add-Check 'Z-11' 'sql/45-48 still match the Step 7B generator' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
    $r = Invoke-Capture -Title 'Step 7C generate --check after' -Command { & $Python.Source -B $Gen7C 'generate' '--check' }
    Add-Check 'Z-12' 'sql/49-52 still match the Step 7C generator' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
    $stats = Invoke-ReadOnlySql -Sql $StatsSql -Title 'statistics after'
    Add-Info 'Z-INFO-stats' "pg_class | pg_statistic digests of log_regex_gis after cleanup: $($stats -replace "`n", ' | ') (expected 36 statistic rows)"
    Add-Info 'Z-INFO-size' (Invoke-ReadOnlySql -Sql $SizeSql -Title 'sizes after')
    Add-Info 'Z-INFO-sessions' (Invoke-ReadOnlySql -Sql $ActiveSql -Title 'sessions after')
    $zFailed = @($Results | Where-Object { $_.Id -match '^(Z|ZP|Z47:|Z50:)' -and $_.Result -eq 'FAIL' }).Count
    $zCount = @($Results | Where-Object { $_.Id -match '^(Z|ZP|Z47:|Z50:)' -and $_.Result -ne 'INFO' }).Count
    Add-Check 'Z-22' 'final database state = approved Step 7F plan section 8 (all after checks)' ($zFailed -eq 0) "$zCount after checks, $zFailed FAIL"
}

# ---------------------------------------------------------------------------------------------------------------------
Write-Host "==== 1. Static checks and manifests ===="
$r = Invoke-Capture -Title 'Step 7B generate --check' -Command { & $Python.Source -B $Gen7B 'generate' '--check' }
Add-Check 'R-01' 'sql/45-48 match the Step 7B generator' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
$r = Invoke-Capture -Title 'Step 7C generate --check' -Command { & $Python.Source -B $Gen7C 'generate' '--check' }
Add-Check 'R-02' 'sql/49-52 match the Step 7C generator (sql/52 unchanged)' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
$r = Invoke-Capture -Title 'Step 7C static-check' -Command { & $Python.Source -B $Gen7C 'static-check' }
Add-Check 'R-03' 'allowlist: sql/52 = 10 DROP INDEX IF EXISTS of the designed names + ANALYZE of the affected tables' ($r.Code -eq 0) (($r.Lines -join ' ').Trim())
$drops = @((Get-Content -LiteralPath 'sql/52_drop_gis_indexes.sql') | Where-Object { $_ -match '^DROP INDEX IF EXISTS log_regex_gis\.(\S+);$' } | ForEach-Object { $_ -replace '^DROP INDEX IF EXISTS log_regex_gis\.|;$', '' })
$sortedDrops = [string[]]$drops; [Array]::Sort($sortedDrops, [System.StringComparer]::Ordinal)
$writes = @((Get-Content -LiteralPath 'sql/52_drop_gis_indexes.sql') | Where-Object { $_ -match '^\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|VACUUM|ANALYZE|GRANT|REVOKE|COMMENT)\b' })
Add-Check 'R-03b' 'sql/52 drops exactly the 10 Step 7C index names; its only other statements are ANALYZE of 9 log_regex_gis tables' ((($sortedDrops -join ',') -eq $IndexNames) -and ($writes.Count -eq 19) -and (@($writes | Where-Object { $_ -match '^ANALYZE log_regex_gis\.\w+;$' }).Count -eq 9)) "drops: $($sortedDrops -join ','); $($writes.Count) statements"
$harnessText = @(
    '-- Step 7F rolled-back harness (written by sql/run_step7f_cleanup.ps1): sql/52 + sql/47 + sql/50 phase before in one transaction, then ROLLBACK.',
    '\set ON_ERROR_STOP on',
    'BEGIN;',
    "SET LOCAL lock_timeout = '5s';",
    '\set confirm_cleanup yes',
    '\i sql/52_drop_gis_indexes.sql',
    '\i sql/47_verify_gis_setup.sql',
    '\set phase before',
    '\i sql/50_verify_gis_index_phase.sql',
    "DO `$h`$ BEGIN RAISE NOTICE 'Step 7F harness PASSED: 10 drops, ANALYZE, sql/47 and sql/50 before inside one transaction'; END `$h`$;",
    'ROLLBACK;', '') -join "`n"
if (-not $AfterOnly) { [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $HarnessFile), $harnessText, (New-Object System.Text.UTF8Encoding($false))) }
$nonAscii = @(foreach ($f in @('sql/run_step7f_cleanup.ps1', $HarnessFile, 'docs/Step7F_PostGIS_Cleanup_and_Final_State_Plan.md')) {
    if ((Test-Path -LiteralPath $f) -and [regex]::IsMatch([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $f).ProviderPath), '[^\x00-\x7F]') -and $f -notlike 'docs/*') { $f } })
Add-Check 'R-04' 'Step 7F runner and harness are ASCII' ($nonAscii.Count -eq 0) $(if ($nonAscii.Count) { $nonAscii -join ', ' } else { 'runner, harness' })
Test-Manifest -Id 'M-01a' -Path 'analysis/step6/step6d_baseline_step6c_sha256.txt' -ExpectedFiles 11
Test-Manifest -Id 'M-01b' -Path 'analysis/step6/step6e_baseline_step6d_sha256.txt' -ExpectedFiles 26
Test-Manifest -Id 'M-01c' -Path $Manifest7B -ExpectedFiles 14
if (-not (Test-Path -LiteralPath $Manifest7F)) {
    if ($AfterOnly) {
        Add-Check 'M-02' 'Step 7F manifest present' $false "$Manifest7F missing"
    } else {
        $missing = @($Step7fFiles | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($missing.Count) {
            Add-Check 'M-02' 'Step 7F manifest created' $false "missing files: $($missing -join ', ')"
        } else {
            $entries = @(foreach ($f in $Step7fFiles) { "$(Get-Sha256Hex -Path $f)  $f" })
            [System.IO.File]::WriteAllText((Join-Path $ProjectRoot $Manifest7F), (($entries -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
            Add-Check 'M-02' 'Step 7F manifest created (Step 7C outputs, Step 7C-7E reports, sample data)' ($entries.Count -eq 32) "$($entries.Count) files -> $Manifest7F"
        }
    }
} else {
    Add-Check 'M-02' 'Step 7F manifest present (created by an earlier run)' $true $Manifest7F
}
Test-Manifest -Id 'M-03' -Path $Manifest7F -ExpectedFiles $Step7fFiles.Count
Stop-IfFailed 'before checks'

if ($AfterOnly) {
    Test-FinalState
    exit ([Math]::Min(1, (Write-Report)))
}

Write-Host "==== 2. Before-cleanup integrity checks (read-only) ===="
Test-GisState -Prefix 'F' -When 'before cleanup' -Inventory $Expected.Inventory7C -Schemas $Expected.Schemas7C
$active = Invoke-ReadOnlySql -Sql $ActiveSql -Title 'sessions before'
Add-Check 'F-05' 'no other non-idle client session (idle in transaction included)' ($active -match '^0 non-idle') $active
Test-ProjectState -Prefix 'B' -When 'before cleanup' -Full
$f50 = Test-ScriptPassed -Id 'F-06' -Name 'sql/50 phase after (read-only): the 10 index definitions, oracles, 202-row matrix in 3 plan modes' -File 'sql/50_verify_gis_index_phase.sql' -Variable 'phase=after' -Pattern 'sql/50 phase after PASSED: all 745 checks' -ReadOnly
$c03 = @($f50.Lines | Where-Object { $_ -match 'NOTICE:\s+C-03:\S+ PASS  ' }).Count
Add-Check 'F-06b' 'correctness matrix before cleanup' ($c03 -eq 606) "$c03 of 606 PASS"
$fp = Get-Fingerprints -Run $f50
Add-Check 'F-07' 'data fingerprints of the 15 GIS tables = Step 7C values' ($fp -eq $Expected.Fingerprints) $fp
$StatsBefore = Invoke-ReadOnlySql -Sql $StatsSql -Title 'statistics before'
Add-Check 'F-08' 'pg_class | pg_statistic digests of log_regex_gis = Step 7C after-state' ($StatsBefore -eq $Expected.Stats7C) ($StatsBefore -replace "`n", ' | ')
Add-Info 'F-INFO-size' (Invoke-ReadOnlySql -Sql $SizeSql -Title 'sizes before')
Stop-IfFailed 'harness'

Write-Host "==== 3. Rolled-back harness ===="
$h = Invoke-PsqlFile -File $HarnessFile
$hPass = @($h.Lines | Where-Object { $_ -match 'Step 7F harness PASSED' }).Count
$h47 = @($h.Lines | Where-Object { $_ -match 'sql/47 PostGIS setup verification PASSED: all 155 checks' }).Count
$h50 = @($h.Lines | Where-Object { $_ -match 'sql/50 phase before PASSED: all 113 checks' }).Count
$hFail = @($h.Lines | Where-Object { $_ -cmatch 'WARNING:\s+\S+\s+FAIL\b|ERROR:\s' })
$hChecks = @($h.Lines | Where-Object { $_ -match '(NOTICE|WARNING):\s+\S+ (PASS|FAIL)\s\s' }).Count
Add-Check 'H-01' 'harness: sql/52 (10 drops, ANALYZE) + sql/47 155/155 + sql/50 before 113/113 in one transaction, then ROLLBACK' (($h.Code -eq 0) -and ($hPass -eq 1) -and ($h47 -eq 1) -and ($h50 -eq 1) -and ($hFail.Count -eq 0)) ("exit $($h.Code); $hChecks check lines; " + $(if ($hFail.Count) { ($hFail | Select-Object -First 3) -join ' / ' } else { 'no FAIL' }))
$hFp = Get-Fingerprints -Run $h
Add-Check 'H-02' 'harness: data fingerprints inside the transaction = Step 7C values' ($hFp -eq $Expected.Fingerprints) $hFp
Test-GisState -Prefix 'HR' -When 'after ROLLBACK' -Inventory $Expected.Inventory7C -Schemas $Expected.Schemas7C
$h4 = Test-ScriptPassed -Id 'H-04' -Name 'after ROLLBACK: sql/50 phase after (read-only), all 10 indexes and the exact Step 7C state' -File 'sql/50_verify_gis_index_phase.sql' -Variable 'phase=after' -Pattern 'sql/50 phase after PASSED: all 745 checks' -ReadOnly
$c03 = @($h4.Lines | Where-Object { $_ -match 'NOTICE:\s+C-03:\S+ PASS  ' }).Count
$fp = Get-Fingerprints -Run $h4
Add-Check 'H-04b' 'after ROLLBACK: correctness matrix and fingerprints' (($c03 -eq 606) -and ($fp -eq $Expected.Fingerprints)) "C-03 $c03 of 606; fingerprints $(if ($fp -eq $Expected.Fingerprints) { 'equal' } else { $fp })"
$stats = Invoke-ReadOnlySql -Sql $StatsSql -Title 'statistics after harness'
Add-Check 'H-05' 'after ROLLBACK: pg_class | pg_statistic digests = before (Step 7C after-state)' ($stats -eq $StatsBefore) ($stats -replace "`n", ' | ')
Test-ProjectState -Prefix 'HB' -When 'after harness'
$active = Invoke-ReadOnlySql -Sql $ActiveSql -Title 'sessions after harness'
Add-Check 'H-07' 'no other non-idle client session before the real cleanup' ($active -match '^0 non-idle') $active
Stop-IfFailed 'real cleanup'
if ($HarnessOnly) { exit ([Math]::Min(1, (Write-Report))) }

Write-Host "==== 4. Real cleanup: sql/52 as one transaction ===="
$s = Invoke-PsqlFile -File 'sql/52_drop_gis_indexes.sql' -Variable 'confirm_cleanup=yes' -SingleTransaction -Options '-c lock_timeout=5s'
$sErr = @($s.Lines | Where-Object { $_ -cmatch 'ERROR:\s|FATAL:\s' })
Add-Check 'S-52' 'sql/52 -v confirm_cleanup=yes --single-transaction (lock_timeout 5s): 10 DROP INDEX + ANALYZE of 9 tables committed' (($s.Code -eq 0) -and ($sErr.Count -eq 0)) ("exit $($s.Code); " + $(if ($sErr.Count) { $sErr -join ' / ' } else { "no error; output lines $($s.Lines.Count)" }))
$inv = Invoke-ReadOnlySql -Sql $InventorySql -Title 'inventory immediately after cleanup'
Add-Check 'S-52b' 'immediately after commit: 15 tables | 15 primary keys | 0 secondary indexes' ($inv -eq $Expected.InventoryEnd) $inv
Stop-IfFailed 'after checks'

Test-FinalState
exit ([Math]::Min(1, (Write-Report)))
