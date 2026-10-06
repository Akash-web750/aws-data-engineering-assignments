# =============================================================================
# start_kafka.ps1
# Starts the single local Kafka broker (KRaft mode, no ZooKeeper).
#
#     .\scripts\start_kafka.ps1               # foreground: logs in this terminal, Ctrl+C stops it
#     .\scripts\start_kafka.ps1 -Background   # hidden process; returns once the broker accepts connections
#
# On the very first start it also formats the storage folder, which KRaft
# requires once per new data directory.
# =============================================================================

param(
    # Run the broker as a hidden background process instead of in this terminal.
    [switch]$Background
)

$ErrorActionPreference = 'Stop'

# Load the shared settings and helper functions.
. "$PSScriptRoot\kafka_common.ps1"
Assert-KafkaInstalled

# --- Step 1: do nothing if a broker is already running ------------------------
if (Test-BrokerPort) {
    Write-Host "A broker is already listening on $BootstrapServer."
    return
}

# --- Step 2: write the broker configuration -----------------------------------
# The configuration lives in this repository (scripts\kafka-server.properties)
# so it is version-controlled. It is copied into the install folder on every
# start, with the data-folder placeholder replaced. Kafka needs forward slashes
# in paths, hence the -replace.
$dataDirForKafka = $KafkaData -replace '\\', '/'
(Get-Content "$PSScriptRoot\kafka-server.properties") -replace '__KAFKA_DATA_DIR__', $dataDirForKafka |
    Set-Content -Path $KafkaConfig -Encoding ascii

# --- Step 3: Windows workaround for the missing "wmic" tool -------------------
# kafka-server-start.bat calls "wmic" to decide how much memory to give Java.
# Windows 11 no longer ships wmic. The .bat only makes that call when
# KAFKA_HEAP_OPTS is empty, so setting it here avoids the call altogether.
# 512 MB is plenty for a single demo topic.
$env:KAFKA_HEAP_OPTS = '-Xmx512M -Xms512M'

# --- Step 4: format the storage folder on first start -------------------------
# KRaft refuses to start on an unformatted folder. meta.properties is written
# by the format command, so its presence means formatting was already done.
if (-not (Test-Path (Join-Path $KafkaData 'meta.properties'))) {
    Write-Host 'First start: formatting Kafka storage ...'
    # A new cluster needs a unique id.
    $clusterId = (& "$KafkaBin\kafka-storage.bat" random-uuid | Select-Object -Last 1).Trim()
    # --standalone: this node is the only controller of a brand-new cluster.
    & "$KafkaBin\kafka-storage.bat" format --standalone -t $clusterId -c $KafkaConfig
    if ($LASTEXITCODE -ne 0) { throw "kafka-storage format failed with exit code $LASTEXITCODE" }
}

# --- Step 5: start the broker --------------------------------------------------
if (-not $Background) {
    # Foreground: the broker owns this terminal until Ctrl+C.
    Write-Host "Starting Kafka on $BootstrapServer (Ctrl+C to stop) ..."
    & "$KafkaBin\kafka-server-start.bat" $KafkaConfig
    return
}

# Background: start a hidden process and send its console output to files so
# start-up problems can still be read afterwards.
New-Item -ItemType Directory -Force -Path $KafkaRunLogs | Out-Null
$stdout = Join-Path $KafkaRunLogs 'broker.out.log'
$stderr = Join-Path $KafkaRunLogs 'broker.err.log'
Start-Process -FilePath "$KafkaBin\kafka-server-start.bat" -ArgumentList $KafkaConfig `
    -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr

# --- Step 6: wait until the broker accepts connections -------------------------
# Start-up takes a few seconds. Poll the port for up to 60 seconds.
Write-Host 'Waiting for the broker to accept connections ...'
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    if (Test-BrokerPort) {
        Write-Host "Kafka is running on $BootstrapServer. Output: $stdout"
        return
    }
    Start-Sleep -Seconds 1
}
throw "The broker did not start within 60 seconds. Check $stdout and $stderr."
