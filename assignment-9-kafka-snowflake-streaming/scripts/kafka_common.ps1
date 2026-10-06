# =============================================================================
# kafka_common.ps1
# Shared settings and helper functions for the Kafka control scripts.
#
# This file is not run on its own. The other scripts load it with
#     . "$PSScriptRoot\kafka_common.ps1"
# so that the install folder, ports and helper logic are defined in one place.
# =============================================================================

# Folder Kafka is installed in. It must be SHORT and contain NO SPACES: the
# Kafka .bat launchers build a very long Java classpath from this path and
# fail with "The input line is too long" or split the path at a space
# otherwise. That is why Kafka is not installed inside the project folder
# ("C:\AKASH MAIN\..." contains a space). Override with the KAFKA_HOME
# environment variable if needed.
$KafkaHome = if ($env:KAFKA_HOME) { $env:KAFKA_HOME } else { 'C:\kafka' }

# Folder with the Windows launchers (.bat files) shipped with Kafka.
$KafkaBin = Join-Path $KafkaHome 'bin\windows'

# Folder where the broker keeps topic data and its KRaft metadata.
$KafkaData = Join-Path $KafkaHome 'data'

# Folder for the broker's console output when it runs in the background.
$KafkaRunLogs = Join-Path $KafkaHome 'run-logs'

# Broker configuration file: copied from this repository into the install
# folder by start_kafka.ps1 (see scripts\kafka-server.properties).
$KafkaConfig = Join-Path $KafkaHome 'config\local-kraft.properties'

# Address clients use to reach the broker.
$BootstrapHost = 'localhost'
$BootstrapPort = 9092
$BootstrapServer = "${BootstrapHost}:${BootstrapPort}"

function Assert-KafkaInstalled {
    # Stops the calling script with a clear message if Kafka is not installed.
    if (-not (Test-Path (Join-Path $KafkaBin 'kafka-server-start.bat'))) {
        throw "Kafka was not found in $KafkaHome. Run scripts\install_kafka.ps1 first."
    }
}

function Test-BrokerPort {
    # Returns $true when something accepts TCP connections on the broker port.
    # Used to tell whether the broker is up without calling any Kafka tool.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect($BootstrapHost, $BootstrapPort)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-KafkaProcess {
    # Returns the Java process(es) running the Kafka broker, if any.
    # The broker's main class is "kafka.Kafka", which appears on its command
    # line; this distinguishes it from other Java programs on the machine.
    Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" |
        Where-Object { $_.CommandLine -like '*kafka.Kafka*' }
}
