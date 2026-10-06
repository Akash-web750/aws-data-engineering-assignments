# =============================================================================
# pipeline_common.ps1
# Shared settings and helper functions for start_pipeline.ps1 and
# stop_pipeline.ps1.
#
# This file is not run on its own. The two scripts load it with
#     . "$PSScriptRoot\pipeline_common.ps1"
#
# It only ORCHESTRATES processes: it decides whether a service is running,
# starts it in the background, and stops it. It contains no pipeline logic.
# The services themselves are started with exactly the commands documented in
# the README:
#     Kafka broker            scripts\start_kafka.ps1 -Background
#     Kafka Connect/Debezium  scripts\start_connect.ps1 -Background
#     CDC bridge              python -m cdc.bridge
#     Snowflake consumer      python -m consumer.consumer
#
# HOW A PROCESS IS RECOGNISED AS BELONGING TO THIS PROJECT
#   Never by its image name alone (there may be other java.exe and python.exe
#   processes on the machine). A process counts as ours only if
#     * its command line names the service (the Kafka main class, the Kafka
#       Connect main class, or "-m cdc.bridge" / "-m consumer.consumer"), or
#     * its process id is recorded in the PID file this project wrote when it
#       started the service, and that process is still a Python process.
# =============================================================================

# Reuse the Kafka settings and helpers ($KafkaHome, $KafkaBin, $KafkaRunLogs,
# Test-BrokerPort, Get-KafkaProcess, Assert-KafkaInstalled). Read only.
. "$PSScriptRoot\kafka_common.ps1"

# Project root = the folder above "scripts". The Python services must be
# started from here so that "python -m cdc.bridge" finds the packages and
# config\settings.py finds the .env file.
$ProjectRoot = Split-Path -Parent $PSScriptRoot

# All runtime output goes to the existing run-logs folder next to the Kafka
# installation (C:\kafka\run-logs). It is outside the repository, so log and
# PID files can never be committed by accident.
$PipelineLogDir = $KafkaRunLogs
# One line per orchestration action, appended on every start and stop.
$PipelineLog = Join-Path $PipelineLogDir 'pipeline.log'

# Kafka Connect's REST port and the connector name (see
# cdc\connect-standalone.properties and cdc\debezium-postgres.properties).
$ConnectRestPort = 8083
$ConnectorName   = 'order-events-postgres-cdc'

function Get-DotEnvValue([string]$Name, [string]$Default = $null) {
    # Reads one KEY=VALUE entry from the project's .env file. A real
    # environment variable of the same name wins, exactly as in
    # config\settings.py. Returns $Default when the key is not set.
    $fromEnvironment = [Environment]::GetEnvironmentVariable($Name)
    if ($fromEnvironment) { return $fromEnvironment }
    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*(.+)$") { return $Matches[1].Trim() }
        }
    }
    return $Default
}

# The two Python services. For each:
#   Name       text shown in the summary
#   Module     what follows "python -m"; also how the process is recognised
#   Group      its Kafka consumer group (the default from config\settings.py,
#              unless .env overrides it). Used ONLY to notice a service that is
#              running but invisible to this session; nothing is changed in it.
#   LogBase    base name of its log and PID files in the run-logs folder
#   ReadyText  the line the service logs once its main loop is running
#   StopSeconds  how long to wait for an orderly shutdown before giving up
$BridgeService = @{
    Name = 'CDC Bridge'; Module = 'cdc.bridge'; LogBase = 'cdc-bridge'; ReadyText = 'Bridging'
    Group = (Get-DotEnvValue 'CDC_BRIDGE_GROUP_ID' 'cdc-bridge'); StopSeconds = 45
}
$ConsumerService = @{
    Name = 'Snowflake Consumer'; Module = 'consumer.consumer'; LogBase = 'consumer'; ReadyText = 'Consuming'
    Group = (Get-DotEnvValue 'KAFKA_GROUP_ID' 'snowflake-loader')
    # The consumer may have to finish a COPY INTO before it can exit.
    StopSeconds = 90
}

function Write-PipelineLog([string]$Message) {
    # Appends one timestamped line to the orchestration log.
    New-Item -ItemType Directory -Force -Path $PipelineLogDir | Out-Null
    Add-Content -Path $PipelineLog -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Get-ServiceLogPath([hashtable]$Service) {
    # Log file of a Python service. Python's logging writes to the error
    # stream, so this file holds the service's actual log lines.
    return Join-Path $PipelineLogDir "$($Service.LogBase).log"
}

function Get-ServicePidPath([hashtable]$Service) {
    # File holding the process id this project started the service with.
    return Join-Path $PipelineLogDir "$($Service.LogBase).pid"
}

function Test-ConnectPort {
    # Returns $true when something accepts TCP connections on Kafka Connect's REST port.
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.Connect('localhost', $ConnectRestPort); return $true }
    catch { return $false }
    finally { $client.Close() }
}

function Get-ConnectProcess {
    # Returns the Java process(es) running Kafka Connect in standalone mode.
    # Its main class "ConnectStandalone" on the command line tells it apart
    # from the Kafka broker and from any other Java program.
    Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" |
        Where-Object { $_.CommandLine -like '*ConnectStandalone*' }
}

function Get-ServiceProcess([hashtable]$Service) {
    # Returns the process(es) of one Python service that belong to this
    # project, or nothing.
    $found = @()

    # 1. By command line: "python ... -m cdc.bridge" (module name as a whole word).
    $pattern = '-m\s+' + [regex]::Escape($Service.Module) + '(\s|"|$)'
    $found += @(Get-CimInstance Win32_Process -Filter "Name LIKE 'python%'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern })

    # 2. By PID file: covers a process this project started but whose command
    #    line this session may not read (for example one started from an
    #    Administrator window). The recorded id must still be a Python
    #    process, and, if its command line IS readable, it must be the right
    #    service; otherwise the id has been reused by something else.
    $pidPath = Get-ServicePidPath $Service
    if (Test-Path $pidPath) {
        $recorded = (Get-Content $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($recorded -match '^\d+$' -and -not ($found | Where-Object { $_.ProcessId -eq [int]$recorded })) {
            $candidate = Get-CimInstance Win32_Process -Filter "ProcessId = $recorded"
            if ($candidate -and $candidate.Name -like 'python*' -and
                (-not $candidate.CommandLine -or $candidate.CommandLine -match $pattern)) {
                $found += $candidate
            }
        }
    }
    return $found
}

function Invoke-KafkaTool([string]$Tool, [string[]]$Arguments) {
    # Runs one of Kafka's command-line tools and returns its standard output
    # as lines. Used for read-only questions (list topics, describe a group).
    #
    # Two details matter on Windows PowerShell 5.1:
    #   * Kafka's tools always print a harmless logging message on the error
    #     stream. With $ErrorActionPreference = 'Stop' (which the calling
    #     scripts use) PowerShell would treat that message as a failure, so
    #     the preference is relaxed for this one call.
    #   * A small heap: this is a short-lived tool, not a server.
    $ErrorActionPreference = 'Continue'
    $previousHeap = $env:KAFKA_HEAP_OPTS
    $env:KAFKA_HEAP_OPTS = '-Xmx256M'
    try {
        return @(& "$KafkaBin\$Tool" @Arguments 2>$null)
    } finally {
        $env:KAFKA_HEAP_OPTS = $previousHeap
    }
}

function Test-ConsumerGroupActive([string]$Group) {
    # Asks Kafka whether a consumer group currently has a connected member.
    # Read only. This is how a service is noticed that runs but cannot be seen
    # by this session at all (started by another user or as Administrator),
    # so that it is not started a second time.
    if (-not (Test-BrokerPort)) { return $false }
    $lines = Invoke-KafkaTool 'kafka-consumer-groups.bat' @(
        '--bootstrap-server', $BootstrapServer, '--describe', '--group', $Group, '--members')
    # A member row starts with the group name; the header row starts with "GROUP".
    return [bool]($lines | Where-Object { $_ -match ('^' + [regex]::Escape($Group) + '\s+\S') })
}

function Get-ServiceState([hashtable]$Service) {
    # Returns one of:
    #   'running'  a process of this project is running the service
    #   'foreign'  no such process is visible, but the service's consumer
    #              group has a connected member: it runs somewhere this
    #              session cannot see (another user, an Administrator window)
    #   'stopped'  the service is not running
    if (@(Get-ServiceProcess $Service).Count -gt 0) { return 'running' }
    if (Test-ConsumerGroupActive $Service.Group) { return 'foreign' }
    return 'stopped'
}

function Start-PythonService([hashtable]$Service) {
    # Starts one Python service as a hidden background process and waits
    # until it reports that its main loop is running.
    # Returns $true on success. On failure it returns $false; the reason is
    # in the service's log file.
    New-Item -ItemType Directory -Force -Path $PipelineLogDir | Out-Null
    $logPath    = Get-ServiceLogPath $Service
    $stdoutPath = Join-Path $PipelineLogDir "$($Service.LogBase).stdout.log"

    # Keep the log of the previous run under another name instead of losing it.
    if (Test-Path $logPath) { Move-Item -Path $logPath -Destination "$logPath.previous" -Force }

    # The same interpreter that "python" resolves to in this session.
    $python = (Get-Command python -ErrorAction Stop).Source

    # -WindowStyle Hidden: no console window appears, but the process still
    #   HAS its own console, which is what lets stop_pipeline.ps1 deliver
    #   Ctrl+C to it for an orderly shutdown.
    # -WorkingDirectory: the project root (see the comment at $ProjectRoot).
    # Python's logging goes to the error stream, hence the log file there.
    $process = Start-Process -FilePath $python -ArgumentList '-m', $Service.Module `
        -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardError $logPath -RedirectStandardOutput $stdoutPath

    # Record the process id: this is how the process is recognised later.
    Set-Content -Path (Get-ServicePidPath $Service) -Value $process.Id -Encoding ascii
    Write-PipelineLog "Started $($Service.Name): python -m $($Service.Module) (pid $($process.Id)), log $logPath"

    # Wait for the line the service logs when its main loop starts. If the
    # process ends before that, it failed to start (bad configuration, broker
    # unreachable, ...).
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { break }
        if ((Test-Path $logPath) -and (Select-String -Path $logPath -Pattern $Service.ReadyText -SimpleMatch -Quiet)) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    Write-PipelineLog "$($Service.Name) did not become ready (exited: $($process.HasExited)). See $logPath"
    return $false
}

function Request-GracefulStop([int]$ProcessId, [string]$StopEvent = 'ctrl-c') {
    # Delivers Ctrl+C or Ctrl+Break to one background process (see
    # request_graceful_stop.py for how, why, and which event suits which
    # service). Returns $true if the request was delivered. It never
    # terminates anything.
    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $python) { return $false }
    # The helper runs in its own hidden process: it has to let go of its own
    # console to attach to the target's, which must not happen to the console
    # this script is writing to.
    $helper = Start-Process -FilePath $python `
        -ArgumentList "`"$PSScriptRoot\request_graceful_stop.py`"", $ProcessId, $StopEvent `
        -WindowStyle Hidden -Wait -PassThru
    return ($helper.ExitCode -eq 0)
}

function Wait-ProcessExit([int]$ProcessId, [int]$Seconds) {
    # Waits until the process is gone. Returns $true if it ended in time.
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

function Stop-ProjectProcess([int]$ProcessId, [string]$Label, [int]$Seconds, [string]$StopEvent = 'ctrl-c') {
    # Stops ONE specific process, identified by its id, in two steps:
    #   1. ask it to shut down in an orderly way and wait. $StopEvent is
    #      'ctrl-c' for the Java services and 'ctrl-break' for the Python ones;
    #   2. only if it is still running after that, end it.
    # Returns 'graceful', 'forced' or 'failed'.
    #
    # Step 2 is safe for this pipeline: every service commits its position
    # only after its work is confirmed, so a process that is ended abruptly
    # repeats its last piece of work after a restart instead of losing it.
    if (Request-GracefulStop $ProcessId $StopEvent) {
        if (Wait-ProcessExit $ProcessId $Seconds) {
            Write-PipelineLog "$Label (pid $ProcessId) shut down in an orderly way"
            return 'graceful'
        }
        Write-PipelineLog "$Label (pid $ProcessId) did not exit within $Seconds s after the stop request"
    } else {
        Write-PipelineLog "$Label (pid $ProcessId): the orderly stop request could not be delivered"
    }
    try {
        # By process id only: never by image name.
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    } catch {
        Write-PipelineLog "$Label (pid $ProcessId) could not be ended: $($_.Exception.Message)"
        return 'failed'
    }
    if (Wait-ProcessExit $ProcessId 15) {
        Write-PipelineLog "$Label (pid $ProcessId) was ended"
        return 'forced'
    }
    return 'failed'
}

function Stop-PythonService([hashtable]$Service) {
    # Stops one Python service of this project.
    # Returns 'already stopped', 'graceful', 'forced', 'failed' or 'foreign'.
    $processes = @(Get-ServiceProcess $Service)
    if ($processes.Count -eq 0) {
        # Nothing of ours is running. Is it running somewhere we cannot see?
        if (Test-ConsumerGroupActive $Service.Group) { return 'foreign' }
        Remove-Item (Get-ServicePidPath $Service) -ErrorAction SilentlyContinue
        return 'already stopped'
    }
    $result = 'graceful'
    foreach ($process in $processes) {
        # Ctrl+Break: handled by both Python services like Ctrl+C, and it
        # cannot be switched off by the shell the service was started from.
        $outcome = Stop-ProjectProcess -ProcessId $process.ProcessId -Label $Service.Name `
            -Seconds $Service.StopSeconds -StopEvent 'ctrl-break'
        # Report the worst outcome if there was more than one process.
        if ($outcome -eq 'failed') { $result = 'failed' }
        elseif ($outcome -eq 'forced' -and $result -ne 'failed') { $result = 'forced' }
    }
    if ($result -ne 'failed') { Remove-Item (Get-ServicePidPath $Service) -ErrorAction SilentlyContinue }
    return $result
}

function Get-ConnectorState {
    # Asks Kafka Connect for the state of the Debezium connector. Read only.
    # Returns for example 'RUNNING', 'FAILED', or $null if Connect does not answer.
    try {
        $status = Invoke-RestMethod -Uri "http://localhost:$ConnectRestPort/connectors/$ConnectorName/status" -TimeoutSec 10
    } catch {
        return $null
    }
    $taskStates = @($status.tasks | ForEach-Object { $_.state })
    # The connector is only useful if its task is running as well.
    if ($status.connector.state -eq 'RUNNING' -and $taskStates.Count -gt 0 -and
        -not ($taskStates | Where-Object { $_ -ne 'RUNNING' })) {
        return 'RUNNING'
    }
    if ($taskStates -contains 'FAILED' -or $status.connector.state -eq 'FAILED') { return 'FAILED' }
    return $status.connector.state
}

function Get-PostgresState {
    # PostgreSQL is NOT managed by these scripts. This only looks whether it
    # accepts connections, because the pipeline cannot work without it.
    $postgresHost = Get-DotEnvValue 'POSTGRES_HOST' 'localhost'
    $postgresPort = [int](Get-DotEnvValue 'POSTGRES_PORT' '5432')
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.Connect($postgresHost, $postgresPort); return 'RUNNING' }
    catch { return 'NOT REACHABLE' }
    finally { $client.Close() }
}

function Write-StatusLine([string]$Name, [string]$Status) {
    # Prints one aligned line of the summary, for example
    #   Kafka Connect      : RUNNING
    Write-Host ("{0,-18} : {1}" -f $Name, $Status)
}
