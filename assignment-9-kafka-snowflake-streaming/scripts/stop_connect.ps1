# =============================================================================
# stop_connect.ps1
# Stops Kafka Connect (and with it the Debezium connector).
#
#     .\scripts\stop_connect.ps1
#
# The Kafka broker, the consumer, the producer and PostgreSQL are not touched.
#
# WHAT STOPPING MEANS FOR THE DATA
#   Nothing is lost. PostgreSQL remembers in the replication slot how far
#   Debezium has read; rows inserted while Connect is stopped are delivered
#   when it starts again.
#
#   Like the broker stop script, this ends the Java process, because Windows
#   has no gentle shutdown signal for it. Connect saves its position every 10
#   seconds, so after a restart Debezium may send the last few change events
#   again (at-least-once). The pipeline is built to tolerate that.
#
# IMPORTANT WHEN CONNECT STAYS STOPPED
#   While nobody reads the replication slot, PostgreSQL keeps its log files
#   for it, for the whole server. If CDC is to stay off, remove the slot with
#   sql\postgres\99_cdc_teardown.sql instead of leaving it unused.
# =============================================================================

$ErrorActionPreference = 'Stop'

# Load the shared Kafka settings (read only).
. "$PSScriptRoot\kafka_common.ps1"

# Connect's REST port (see cdc\connect-standalone.properties).
$RestPort = 8083

function Test-ConnectPort {
    # Returns $true when something accepts TCP connections on the REST port.
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.Connect('localhost', $RestPort); return $true }
    catch { return $false }
    finally { $client.Close() }
}

# Kafka Connect's main class in standalone mode is "ConnectStandalone"; it
# appears on the Java command line. This tells it apart from the Kafka broker
# (main class kafka.Kafka), which must keep running.
$workers = @(Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" |
    Where-Object { $_.CommandLine -like '*ConnectStandalone*' })

if ($workers.Count -eq 0) {
    Write-Host 'No Kafka Connect process is running.'
    return
}

# End each Kafka Connect process found (normally exactly one).
foreach ($worker in $workers) {
    Write-Host "Stopping Kafka Connect (process id $($worker.ProcessId)) ..."
    Stop-Process -Id $worker.ProcessId -Force
}

# Wait until the REST port is free, so a following start does not collide.
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline -and (Test-ConnectPort)) { Start-Sleep -Seconds 1 }

Write-Host 'Kafka Connect stopped. The Kafka broker is still running.'
Write-Host 'The replication slot stays in PostgreSQL; see the note in this script if CDC is to stay off.'
