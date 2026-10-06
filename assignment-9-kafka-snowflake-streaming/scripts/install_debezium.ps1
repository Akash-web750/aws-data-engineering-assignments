# =============================================================================
# install_debezium.ps1
# Downloads the Debezium PostgreSQL connector, verifies it and unpacks it into
# a plugin folder next to the Kafka installation.
#
# Run once:
#     .\scripts\install_debezium.ps1
#
# WHAT THIS DOES AND DOES NOT DO
#   It only places files in <KAFKA_HOME>\connect-plugins. Nothing is started
#   and nothing running is touched: the Kafka broker never reads that folder.
#   Only Kafka Connect does, and only when scripts\start_connect.ps1 starts it.
#   Removing the folder uninstalls the plugin.
#
# Debezium is the change-data-capture connector that reads PostgreSQL's log.
# It runs inside Kafka Connect, which already ships with Apache Kafka.
# =============================================================================

param(
    # Debezium release to install. 3.x needs Java 17 or later.
    [string]$DebeziumVersion = '3.7.0.Final'
)

# Stop at the first error instead of continuing with a half-finished install.
$ErrorActionPreference = 'Stop'

# Load the shared Kafka settings ($KafkaHome and helper functions). The file
# is only read, not changed.
. "$PSScriptRoot\kafka_common.ps1"
Assert-KafkaInstalled

# Folder Kafka Connect will search for plugins. Like the Kafka folder itself
# it is short and has no spaces. Each plugin lives in its own sub-folder.
$ConnectPluginDir = Join-Path $KafkaHome 'connect-plugins'
$PluginFolder     = Join-Path $ConnectPluginDir 'debezium-connector-postgres'

# --- Step 1: refuse to overwrite an existing install -------------------------
if (Test-Path $PluginFolder) {
    Write-Host "The Debezium PostgreSQL connector is already installed in $PluginFolder. Nothing to do."
    return
}

# --- Step 2: work out the download locations ---------------------------------
# Debezium publishes each connector as a "plugin" archive on Maven Central,
# together with a SHA-512 checksum file.
$archiveName = "debezium-connector-postgres-$DebeziumVersion-plugin.tar.gz"
$baseUrl     = "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/$DebeziumVersion"
$archivePath = Join-Path $env:TEMP $archiveName
$hashPath    = "$archivePath.sha512"

# --- Step 3: download the archive and its checksum ---------------------------
# The progress bar makes Invoke-WebRequest very slow in Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'
Write-Host "Downloading $archiveName ..."
Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$archiveName"        -OutFile $archivePath
Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$archiveName.sha512" -OutFile $hashPath

# --- Step 4: verify the download ---------------------------------------------
# The checksum file holds the hash as hexadecimal text. Keeping only the hex
# characters also copes with a trailing file name or line break.
$expected = ((Get-Content $hashPath -Raw) -split '\s+')[0] -replace '[^0-9A-Fa-f]', ''
$actual   = (Get-FileHash -Algorithm SHA512 -Path $archivePath).Hash
if ($expected.ToUpper() -ne $actual.ToUpper()) {
    # A mismatch means a corrupted or tampered download: do not extract it.
    throw "Checksum mismatch for $archiveName. Delete $archivePath and run again."
}
Write-Host 'Checksum verified.'

# --- Step 5: extract into the plugin folder ----------------------------------
New-Item -ItemType Directory -Force -Path $ConnectPluginDir | Out-Null
# The archive contains one top-level folder, "debezium-connector-postgres",
# which becomes the plugin's own sub-folder. tar.exe ships with Windows 10/11.
# It is called by its full path on purpose: when this script is started from
# a Git Bash session, plain "tar" resolves to GNU tar, which misreads a path
# starting with "C:" as a remote host and fails.
$windowsTar = Join-Path $env:SystemRoot 'System32\tar.exe'
& $windowsTar -xzf $archivePath -C $ConnectPluginDir
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
if (-not (Test-Path $PluginFolder)) {
    throw "The archive did not contain the expected folder 'debezium-connector-postgres'."
}

# --- Step 6: tidy up and report ----------------------------------------------
Remove-Item $archivePath, $hashPath -Force
$jarCount = @(Get-ChildItem $PluginFolder -Filter *.jar).Count
Write-Host "Debezium PostgreSQL connector $DebeziumVersion installed in $PluginFolder ($jarCount jar files)."
Write-Host 'Nothing was started. Next (only after CDC is enabled in PostgreSQL): .\scripts\start_connect.ps1'
