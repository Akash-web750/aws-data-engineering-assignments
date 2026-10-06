# =============================================================================
# start_pipeline.ps1
# Starts the whole pipeline with one command, in the background:
#
#     .\scripts\start_pipeline.ps1
#
#   PostgreSQL -> Debezium (Kafka Connect) -> Kafka -> CDC bridge -> Kafka -> consumer -> Snowflake
#
# It starts, in this order and only if not already running:
#     1. Kafka broker                       (scripts\start_kafka.ps1 -Background)
#     2. Kafka Connect with Debezium        (scripts\start_connect.ps1 -Background)
#     3. Snowflake consumer                 (python -m consumer.consumer)
#     4. CDC bridge                         (python -m cdc.bridge)
#
# The consumer is started before the bridge, so that whatever the bridge
# forwards finds its reader already waiting.
#
# WHAT IT NEVER DOES
#   * It never starts the producer. The producer generates demo data and is
#     run by hand when wanted (python -m producer.producer ...).
#   * It never starts, stops or reconfigures PostgreSQL. It only looks whether
#     PostgreSQL answers, because the pipeline needs it.
#   * It never starts a second copy of a service that is already running.
#   * It never deletes or alters a topic, a consumer group, an offset or the
#     replication slot. The only Kafka change it can make is to CREATE a
#     missing topic, through the existing scripts\create_topics.ps1.
#
# SAFE TO RUN AGAIN
#   A second run finds everything running and starts nothing.
#
# LOGS (all outside the repository, in <KAFKA_HOME>\run-logs)
#     pipeline.log        what this script and stop_pipeline.ps1 did
#     broker.out.log      Kafka broker
#     connect.out.log     Kafka Connect / Debezium
#     consumer.log        Snowflake consumer
#     cdc-bridge.log      CDC bridge
#
# Stop everything with:  .\scripts\stop_pipeline.ps1
# =============================================================================

$ErrorActionPreference = 'Stop'

# Shared settings and helper functions (this also loads kafka_common.ps1).
. "$PSScriptRoot\pipeline_common.ps1"
Assert-KafkaInstalled

Write-PipelineLog '===== start_pipeline.ps1 ====='

# Result per component, filled in below: what is shown in the summary, whether
# the component is usable, and where to look if it is not.
$results = [ordered]@{}
function Set-Result([string]$Name, [string]$Status, [bool]$Ok, [string]$Log = $null) {
    # Remembers the outcome of one component and writes it to the log.
    $results[$Name] = @{ Status = $Status; Ok = $Ok; Log = $Log }
    Write-PipelineLog "${Name}: $Status"
}

# -----------------------------------------------------------------------------
# 0. PostgreSQL: looked at, never managed.
# -----------------------------------------------------------------------------
$postgresState = Get-PostgresState
if ($postgresState -ne 'RUNNING') {
    Write-Host 'Warning: PostgreSQL does not answer. It is not started by this script; start its Windows service first.'
    Write-PipelineLog 'PostgreSQL does not answer (not managed by this script)'
}

# -----------------------------------------------------------------------------
# 1. Kafka broker
# -----------------------------------------------------------------------------
$brokerLog = Join-Path $PipelineLogDir 'broker.out.log'
if (Test-BrokerPort) {
    Set-Result 'Kafka Broker' 'RUNNING (already running)' $true
} else {
    Write-Host 'Starting Kafka broker ...'
    try {
        # The existing start script: formats the storage on first use, starts
        # the broker hidden, and waits until it accepts connections.
        & "$PSScriptRoot\start_kafka.ps1" -Background | Out-Null
    } catch {
        Write-PipelineLog "start_kafka.ps1 failed: $($_.Exception.Message)"
    }
    if (Test-BrokerPort) { Set-Result 'Kafka Broker' 'RUNNING (started)' $true }
    else { Set-Result 'Kafka Broker' 'FAILED' $false $brokerLog }
}
$brokerUp = $results['Kafka Broker'].Ok

# -----------------------------------------------------------------------------
# 1b. Topics. Only looked at; created only if one is missing (for example on a
#     freshly reset broker). Existing topics are never touched.
# -----------------------------------------------------------------------------
if ($brokerUp) {
    $required = @(
        (Get-DotEnvValue 'KAFKA_TOPIC' 'order_events'),
        (Get-DotEnvValue 'KAFKA_DLQ_TOPIC' 'order_events_dlq'),
        ((Get-DotEnvValue 'CDC_TOPIC_PREFIX' 'pgcdc') + '.public.order_events')
    )
    $existing = Invoke-KafkaTool 'kafka-topics.bat' @('--bootstrap-server', $BootstrapServer, '--list')
    $missing = @($required | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -gt 0) {
        Write-Host "Creating missing topic(s): $($missing -join ', ') ..."
        Write-PipelineLog "Missing topics: $($missing -join ', '); running create_topics.ps1 -IncludeCdc"
        try {
            # The existing script; --if-not-exists makes it harmless for the
            # topics that are already there. Its error stream is deliberately
            # NOT redirected: Kafka's tools print a harmless logging message
            # there, which PowerShell would turn into a failure if captured.
            & "$PSScriptRoot\create_topics.ps1" -IncludeCdc | Out-Null
        } catch {
            Write-PipelineLog "create_topics.ps1 failed: $($_.Exception.Message)"
        }
    }
}

# -----------------------------------------------------------------------------
# 2. Kafka Connect with the Debezium connector
# -----------------------------------------------------------------------------
$connectLog = Join-Path $PipelineLogDir 'connect.out.log'
if (-not $brokerUp) {
    Set-Result 'Kafka Connect' 'NOT STARTED (Kafka broker is not running)' $false $brokerLog
} else {
    $startedNow = $false
    # Why Kafka Connect could not be started, if the start script said so.
    $connectFailure = $null
    if (-not (Test-ConnectPort)) {
        Write-Host 'Starting Kafka Connect with Debezium ...'
        try {
            # The existing start script: reads the CDC login from .env, writes
            # the configuration, starts Connect hidden and waits for it.
            & "$PSScriptRoot\start_connect.ps1" -Background | Out-Null
            $startedNow = $true
        } catch {
            # For example: POSTGRES_CDC_PASSWORD is not set in .env.
            $connectFailure = $_.Exception.Message
            Write-PipelineLog "start_connect.ps1 failed: $connectFailure"
        }
    }
    if (-not (Test-ConnectPort)) {
        if ($connectFailure) {
            # The start script refused before starting anything, so there is
            # no log to point to: show its reason instead.
            Set-Result 'Kafka Connect' "FAILED ($connectFailure)" $false
        } else {
            Set-Result 'Kafka Connect' 'FAILED' $false $connectLog
        }
    } else {
        # Connect answers; the connector inside it must be RUNNING too. Right
        # after a start it needs a moment to connect to PostgreSQL.
        $connectorState = $null
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $connectorState = Get-ConnectorState
            if ($connectorState -eq 'RUNNING' -or $connectorState -eq 'FAILED') { break }
            Start-Sleep -Seconds 2
        }
        $how = if ($startedNow) { 'started' } else { 'already running' }
        if ($connectorState -eq 'RUNNING') {
            Set-Result 'Kafka Connect' "RUNNING ($how)" $true
        } else {
            Set-Result 'Kafka Connect' "RUNNING, but the Debezium connector is $connectorState" $false $connectLog
        }
    }
}

# -----------------------------------------------------------------------------
# 3 and 4. The two Python services: consumer first, then the bridge.
# -----------------------------------------------------------------------------
foreach ($service in @($ConsumerService, $BridgeService)) {
    $log = Get-ServiceLogPath $service
    if (-not $brokerUp) {
        Set-Result $service.Name 'NOT STARTED (Kafka broker is not running)' $false $brokerLog
        continue
    }
    # Duplicate protection: look for our own process first, then ask Kafka
    # whether the service is connected from somewhere this session cannot see.
    $state = Get-ServiceState $service
    if ($state -eq 'running') {
        Set-Result $service.Name 'RUNNING (already running)' $true
        continue
    }
    if ($state -eq 'foreign') {
        Set-Result $service.Name 'RUNNING (already running; started from another session)' $true
        continue
    }
    Write-Host "Starting $($service.Name) ..."
    if (Start-PythonService $service) {
        Set-Result $service.Name 'RUNNING (started)' $true
    } else {
        Set-Result $service.Name 'FAILED' $false $log
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ''
foreach ($name in $results.Keys) { Write-StatusLine $name $results[$name].Status }
Write-StatusLine 'PostgreSQL' "$postgresState (not managed by this script)"
Write-Host ''

$failed = @($results.Keys | Where-Object { -not $results[$_].Ok })
if ($failed.Count -eq 0 -and $postgresState -eq 'RUNNING') {
    Write-Host 'Pipeline Status: READY'
    Write-Host "Logs: $PipelineLogDir"
    Write-PipelineLog 'Pipeline Status: READY'
    exit 0
}

Write-Host 'Pipeline Status: NOT READY'
foreach ($name in $failed) {
    # Say which component failed and where its log is.
    Write-Host ("  {0}: {1}" -f $name, $results[$name].Status)
    if ($results[$name].Log) { Write-Host "    see $($results[$name].Log)" }
}
if ($postgresState -ne 'RUNNING') { Write-Host '  PostgreSQL does not answer; start its Windows service.' }
Write-Host "Orchestration log: $PipelineLog"
Write-PipelineLog "Pipeline Status: NOT READY ($($failed -join ', '))"
exit 1
