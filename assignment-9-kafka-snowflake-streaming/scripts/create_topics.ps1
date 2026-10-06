# =============================================================================
# create_topics.ps1
# Creates the Kafka topics used by the pipeline, if they do not exist yet.
#
#     .\scripts\create_topics.ps1
#
# Run once after the first start, and again after reset_kafka.ps1.
# Safe to re-run: existing topics are left untouched.
# =============================================================================

param(
    # Main topic: the producer writes order events here, the consumer reads them.
    [string]$Topic = 'order_events',
    # Dead-letter topic: messages the consumer cannot parse are copied here.
    [string]$DlqTopic = 'order_events_dlq'
)

$ErrorActionPreference = 'Stop'

# Load the shared settings and helper functions.
. "$PSScriptRoot\kafka_common.ps1"
Assert-KafkaInstalled

if (-not (Test-BrokerPort)) {
    throw "No broker is listening on $BootstrapServer. Run scripts\start_kafka.ps1 first."
}

function New-Topic([string]$Name, [int]$Partitions) {
    # Creates one topic. --if-not-exists makes the call harmless when the
    # topic is already there. Replication factor is 1 because the cluster has
    # a single broker.
    & "$KafkaBin\kafka-topics.bat" --bootstrap-server $BootstrapServer `
        --create --if-not-exists --topic $Name `
        --partitions $Partitions --replication-factor 1
    if ($LASTEXITCODE -ne 0) { throw "Creating topic $Name failed with exit code $LASTEXITCODE" }
}

# 3 partitions: enough to show that ordering is kept per order (the message key
# is the order id) while messages are spread over several partitions.
New-Topic -Name $Topic -Partitions 3

# 1 partition: the dead-letter topic is low-volume and read by people.
New-Topic -Name $DlqTopic -Partitions 1

# Show the result as confirmation.
& "$KafkaBin\kafka-topics.bat" --bootstrap-server $BootstrapServer --list
