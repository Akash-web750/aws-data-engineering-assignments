# =============================================================================
# start_connect.ps1
# Starts Kafka Connect in standalone mode with the Debezium PostgreSQL connector.
#
#     .\scripts\start_connect.ps1               # foreground: logs in this terminal, Ctrl+C stops it
#     .\scripts\start_connect.ps1 -Background   # hidden process; returns once Connect answers
#
# BEFORE THE FIRST START, all of these must be true:
#   1. PostgreSQL runs with wal_level = logical (set by an administrator; needs
#      a restart of the PostgreSQL service).
#   2. sql\postgres\02_cdc_setup.sql was run (creates the login and the publication).
#   3. POSTGRES_CDC_PASSWORD is set in the .env file.
#   4. .\scripts\install_debezium.ps1 was run.
#   5. The Kafka broker is running and .\scripts\create_topics.ps1 -IncludeCdc was run.
#
# What starts here is ONE extra Java process. The Kafka broker, the consumer
# and the producer are not touched.
#
# On its first start Debezium creates the replication slot in PostgreSQL and,
# because the connector uses snapshot.mode=no_data, publishes NONE of the rows
# already in the table. Check that before starting the bridge:
# the topic pgcdc.public.order_events must contain 0 messages.
# =============================================================================

param(
    # Run Kafka Connect as a hidden background process instead of in this terminal.
    [switch]$Background
)

$ErrorActionPreference = 'Stop'

# Load the shared Kafka settings and helper functions (read only).
. "$PSScriptRoot\kafka_common.ps1"
Assert-KafkaInstalled

# Project root = the folder above "scripts".
$ProjectRoot = Split-Path -Parent $PSScriptRoot

# Folders used by Kafka Connect, next to the Kafka installation (short paths,
# no spaces).
$ConnectPluginDir = Join-Path $KafkaHome 'connect-plugins'   # Debezium plugin
$ConnectDataDir   = Join-Path $KafkaHome 'connect-data'      # the worker's offsets file

# Rendered configuration files. They are written into the Kafka config folder
# because the project path contains a space, which the Kafka launchers cannot
# handle in their arguments.
$WorkerConfig    = Join-Path $KafkaHome 'config\cdc-connect-standalone.properties'
$ConnectorConfig = Join-Path $KafkaHome 'config\cdc-debezium-postgres.properties'

# Connect's REST interface (see cdc\connect-standalone.properties).
$RestPort      = 8083
$ConnectorName = 'order-events-postgres-cdc'

function Test-ConnectPort {
    # Returns $true when something accepts TCP connections on the REST port.
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.Connect('localhost', $RestPort); return $true }
    catch { return $false }
    finally { $client.Close() }
}

function Get-DotEnvValue([string]$Name) {
    # Reads one KEY=VALUE entry from the project's .env file. A real
    # environment variable of the same name wins, as in config\settings.py.
    $fromEnvironment = [Environment]::GetEnvironmentVariable($Name)
    if ($fromEnvironment) { return $fromEnvironment }
    $envFile = Join-Path $ProjectRoot '.env'
    if (-not (Test-Path $envFile)) { return $null }
    foreach ($line in Get-Content $envFile) {
        if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

# --- Step 1: do nothing if Kafka Connect is already running -------------------
if (Test-ConnectPort) {
    Write-Host "Kafka Connect is already listening on port $RestPort."
    return
}

# --- Step 2: check the prerequisites that can be checked from here ------------
if (-not (Test-BrokerPort)) {
    throw "No Kafka broker is listening on $BootstrapServer. Run scripts\start_kafka.ps1 first."
}
if (-not (Test-Path (Join-Path $ConnectPluginDir 'debezium-connector-postgres'))) {
    throw "The Debezium plugin was not found in $ConnectPluginDir. Run scripts\install_debezium.ps1 first."
}

# --- Step 3: hand the PostgreSQL login to Kafka Connect ------------------------
# The connector file refers to the login as ${env:POSTGRES_CDC_USER} and
# ${env:POSTGRES_CDC_PASSWORD}. The values are read from .env and set as
# environment variables of THIS process only; they are inherited by the Java
# process and are never written to any file.
$cdcUser = Get-DotEnvValue 'POSTGRES_CDC_USER'
if (-not $cdcUser) { $cdcUser = 'cdc_user' }
$cdcPassword = Get-DotEnvValue 'POSTGRES_CDC_PASSWORD'
if (-not $cdcPassword) {
    throw 'POSTGRES_CDC_PASSWORD is not set. Add it to the .env file in the project root (see .env.example).'
}
$env:POSTGRES_CDC_USER     = $cdcUser
$env:POSTGRES_CDC_PASSWORD = $cdcPassword

# --- Step 4: write the configuration files -------------------------------------
New-Item -ItemType Directory -Force -Path $ConnectDataDir | Out-Null
# The worker file has two placeholders. Kafka needs forward slashes in paths.
(Get-Content "$ProjectRoot\cdc\connect-standalone.properties") `
    -replace '__CONNECT_PLUGIN_DIR__', ($ConnectPluginDir -replace '\\', '/') `
    -replace '__CONNECT_DATA_DIR__',   ($ConnectDataDir   -replace '\\', '/') |
    Set-Content -Path $WorkerConfig -Encoding ascii
# The connector file is copied unchanged (it contains no password).
Copy-Item "$ProjectRoot\cdc\debezium-postgres.properties" $ConnectorConfig -Force

# --- Step 5: limit the memory Kafka Connect may use ----------------------------
# One connector reading one small table needs little memory. The launcher's
# own default would allow up to 2 GB.
$env:KAFKA_HEAP_OPTS = '-Xms128M -Xmx384M'

# --- Step 6: start Kafka Connect ------------------------------------------------
if (-not $Background) {
    # Foreground: Kafka Connect owns this terminal until Ctrl+C.
    Write-Host "Starting Kafka Connect with connector $ConnectorName (Ctrl+C to stop) ..."
    & "$KafkaBin\connect-standalone.bat" $WorkerConfig $ConnectorConfig
    return
}

# Background: hidden process, console output to files.
New-Item -ItemType Directory -Force -Path $KafkaRunLogs | Out-Null
$stdout = Join-Path $KafkaRunLogs 'connect.out.log'
$stderr = Join-Path $KafkaRunLogs 'connect.err.log'
Start-Process -FilePath "$KafkaBin\connect-standalone.bat" -ArgumentList $WorkerConfig, $ConnectorConfig `
    -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr

# --- Step 7: wait until Kafka Connect answers ------------------------------------
Write-Host 'Waiting for Kafka Connect to start ...'
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline -and -not (Test-ConnectPort)) { Start-Sleep -Seconds 1 }
if (-not (Test-ConnectPort)) {
    throw "Kafka Connect did not start within 120 seconds. Check $stdout and $stderr."
}

# --- Step 8: report the connector's state ----------------------------------------
# The connector is registered a moment after the REST interface comes up, so
# ask a few times. RUNNING means Debezium is connected to PostgreSQL.
$status = $null
for ($attempt = 0; $attempt -lt 30 -and -not $status; $attempt++) {
    try { $status = Invoke-RestMethod -Uri "http://localhost:$RestPort/connectors/$ConnectorName/status" }
    catch { Start-Sleep -Seconds 2 }
}
if ($status) {
    Write-Host "Connector state: $($status.connector.state). Task state: $(($status.tasks | ForEach-Object { $_.state }) -join ', ')."
    # A failed task carries the reason (for example: wal_level is not logical).
    $status.tasks | Where-Object { $_.trace } | ForEach-Object { Write-Host ($_.trace -split "`n")[0] }
} else {
    Write-Host "Kafka Connect is up, but the connector status could not be read yet. Check $stdout."
}
Write-Host "Kafka Connect is running. Output: $stdout"
Write-Host 'Before starting the bridge, confirm the CDC topic is empty (no snapshot was taken).'
