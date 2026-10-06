# =============================================================================
# stop_kafka.ps1
# Stops the local Kafka broker.
#
#     .\scripts\stop_kafka.ps1
#
# Kafka's own kafka-server-stop.bat cannot be used: it relies on "wmic", which
# Windows 11 no longer ships. This script finds the broker's Java process
# itself and ends it.
#
# Note: Windows has no gentle "please shut down" signal for a console Java
# process, so the broker is terminated. Kafka recovers from this on the next
# start (it re-checks its log files), and committed messages are not lost.
# If the broker runs in the foreground, pressing Ctrl+C in its terminal is the
# cleaner way to stop it.
# =============================================================================

$ErrorActionPreference = 'Stop'

# Load the shared settings and helper functions.
. "$PSScriptRoot\kafka_common.ps1"

# Find the broker by its main class on the Java command line.
$brokers = @(Get-KafkaProcess)
if ($brokers.Count -eq 0) {
    Write-Host 'No Kafka broker process is running.'
    return
}

# End each broker process found (normally exactly one).
foreach ($broker in $brokers) {
    Write-Host "Stopping Kafka broker (process id $($broker.ProcessId)) ..."
    Stop-Process -Id $broker.ProcessId -Force
}

# Wait until the port is free, so a following start does not collide.
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline -and (Test-BrokerPort)) {
    Start-Sleep -Seconds 1
}
Write-Host 'Kafka stopped.'
