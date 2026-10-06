# =============================================================================
# stop_pipeline.ps1
# Stops the whole pipeline with one command:
#
#     .\scripts\stop_pipeline.ps1               # stops all four services
#     .\scripts\stop_pipeline.ps1 -KeepBroker   # leaves the Kafka broker running
#
# Order (the reverse of start_pipeline.ps1, so nothing is cut off from the
# thing it depends on):
#     1. CDC bridge
#     2. Snowflake consumer
#     3. Kafka Connect with Debezium
#     4. Kafka broker
#
# HOW A SERVICE IS STOPPED
#   Each one is first ASKED to shut down, the way Ctrl+C would (see
#   request_graceful_stop.py), and given time to do so: the consumer finishes
#   and commits its batch, the bridge commits its position, Kafka Connect
#   saves how far Debezium has read, the broker closes its log files cleanly.
#   Only a service that has not exited after that is ended. Nothing is lost
#   in that case either: each service repeats its last uncommitted piece of
#   work after the next start (at-least-once).
#
# WHAT IT NEVER DOES
#   * It never stops PostgreSQL.
#   * It never stops a process by image name. Only processes that belong to
#     this project are touched, each by its own process id (see
#     pipeline_common.ps1 for how they are recognised).
#   * It never deletes a topic, Kafka data, a consumer group, Debezium's
#     offsets or the replication slot, and it does not run the CDC teardown.
#
# A service that is already stopped counts as success.
#
# NOTE ON THE REPLICATION SLOT
#   While Kafka Connect is stopped, PostgreSQL keeps its log for the
#   replication slot (up to max_slot_wal_keep_size). That is intended for a
#   normal stop: rows inserted meanwhile are delivered after the next start.
# =============================================================================

param(
    # Leave the Kafka broker running (stop only the three services using it).
    [switch]$KeepBroker
)

$ErrorActionPreference = 'Stop'

# Shared settings and helper functions (this also loads kafka_common.ps1).
. "$PSScriptRoot\pipeline_common.ps1"

Write-PipelineLog '===== stop_pipeline.ps1 ====='

# Result per component: the text for the summary and whether it is stopped.
$results = [ordered]@{}
function Set-Result([string]$Name, [string]$Status, [bool]$Stopped) {
    # Remembers the outcome of one component and writes it to the log.
    $results[$Name] = @{ Status = $Status; Stopped = $Stopped }
    Write-PipelineLog "${Name}: $Status"
}

function Get-StopText([string]$Outcome) {
    # Turns the outcome of a stop attempt into the text shown in the summary.
    switch ($Outcome) {
        'already stopped' { return 'STOPPED (was not running)' }
        'graceful'        { return 'STOPPED' }
        'forced'          { return 'STOPPED (did not exit when asked, so it was ended)' }
        'foreign'         { return 'STILL RUNNING (started from another session, for example an Administrator window; stop it there)' }
        default           { return 'STILL RUNNING (could not be stopped; try from an Administrator PowerShell)' }
    }
}

# -----------------------------------------------------------------------------
# 1 and 2. The two Python services: bridge first, then the consumer.
# -----------------------------------------------------------------------------
foreach ($service in @($BridgeService, $ConsumerService)) {
    Write-Host "Stopping $($service.Name) ..."
    $outcome = Stop-PythonService $service
    Set-Result $service.Name (Get-StopText $outcome) ($outcome -in 'already stopped', 'graceful', 'forced')
}

# -----------------------------------------------------------------------------
# 3. Kafka Connect with Debezium
# -----------------------------------------------------------------------------
Write-Host 'Stopping Kafka Connect ...'
$connectProcesses = @(Get-ConnectProcess)
if ($connectProcesses.Count -eq 0) {
    if (Test-ConnectPort) {
        # Something answers on Connect's port, but it is not a process this
        # session can identify as Kafka Connect.
        Set-Result 'Kafka Connect' (Get-StopText 'foreign') $false
    } else {
        Set-Result 'Kafka Connect' (Get-StopText 'already stopped') $true
    }
} else {
    $outcome = 'graceful'
    foreach ($process in $connectProcesses) {
        # Connect saves Debezium's position during an orderly shutdown.
        $one = Stop-ProjectProcess -ProcessId $process.ProcessId -Label 'Kafka Connect' -Seconds 60
        if ($one -eq 'failed') { $outcome = 'failed' }
        elseif ($one -eq 'forced' -and $outcome -ne 'failed') { $outcome = 'forced' }
    }
    # Wait until the REST port is free, so a following start does not collide.
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and (Test-ConnectPort)) { Start-Sleep -Milliseconds 500 }
    Set-Result 'Kafka Connect' (Get-StopText $outcome) ($outcome -ne 'failed')
}

# -----------------------------------------------------------------------------
# 4. Kafka broker
# -----------------------------------------------------------------------------
$dependentsRunning = @($results.Keys | Where-Object { -not $results[$_].Stopped })
if ($KeepBroker) {
    $state = if (Test-BrokerPort) { 'RUNNING' } else { 'STOPPED' }
    Set-Result 'Kafka Broker' "$state (left as it was: -KeepBroker)" $true
} elseif ($dependentsRunning.Count -gt 0) {
    # Something that uses the broker is still running and could not be
    # stopped from here. Taking the broker away from it would only make it
    # log connection errors, so the broker is left running.
    Set-Result 'Kafka Broker' "STILL RUNNING (left running because $($dependentsRunning -join ', ') still uses it)" $false
} else {
    Write-Host 'Stopping Kafka broker ...'
    $brokerProcesses = @(Get-KafkaProcess)
    if ($brokerProcesses.Count -eq 0) {
        if (Test-BrokerPort) { Set-Result 'Kafka Broker' (Get-StopText 'foreign') $false }
        else { Set-Result 'Kafka Broker' (Get-StopText 'already stopped') $true }
    } else {
        $outcome = 'graceful'
        foreach ($process in $brokerProcesses) {
            # An orderly broker shutdown closes its log files cleanly, so the
            # next start does not have to check and recover them.
            $one = Stop-ProjectProcess -ProcessId $process.ProcessId -Label 'Kafka Broker' -Seconds 90
            if ($one -eq 'failed') { $outcome = 'failed' }
            elseif ($one -eq 'forced' -and $outcome -ne 'failed') { $outcome = 'forced' }
        }
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and (Test-BrokerPort)) { Start-Sleep -Milliseconds 500 }
        Set-Result 'Kafka Broker' (Get-StopText $outcome) ($outcome -ne 'failed')
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ''
foreach ($name in $results.Keys) { Write-StatusLine $name $results[$name].Status }
Write-StatusLine 'PostgreSQL' "$(Get-PostgresState) (not managed by this script; left untouched)"
Write-Host ''

$stillRunning = @($results.Keys | Where-Object { -not $results[$_].Stopped })
if ($stillRunning.Count -eq 0) {
    if ($KeepBroker) { Write-Host 'Pipeline Status: STOPPED (Kafka broker left running)' }
    else { Write-Host 'Pipeline Status: STOPPED' }
    Write-PipelineLog 'Pipeline Status: STOPPED'
    exit 0
}

Write-Host "Pipeline Status: PARTLY STOPPED (still running: $($stillRunning -join ', '))"
Write-Host "Orchestration log: $PipelineLog"
Write-PipelineLog "Pipeline Status: PARTLY STOPPED ($($stillRunning -join ', '))"
exit 1
