# =============================================================================
# create_topics.ps1
# Creates the Kafka topics used by the pipeline, if they do not exist yet.
#
#     .\scripts\create_topics.ps1
#
# Run once after the first start, and again after reset_kafka.ps1.
# Safe to re-run: existing topics are left untouched.
#
#     .\scripts\create_topics.ps1 -IncludeCdc
#
# -IncludeCdc ADDITIONALLY creates the two topics used by change data capture
# from PostgreSQL (Debezium). Without the switch the script creates exactly the
# two original topics, as it always did. No topic is ever deleted or altered.
# =============================================================================

param(
    # Main topic: the producer writes order events here, the consumer reads them.
    [string]$Topic = 'order_events',
    # Dead-letter topic: messages the consumer cannot parse are copied here.
    [string]$DlqTopic = 'order_events_dlq',
    # Also create the topics for change data capture (off by default).
    [switch]$IncludeCdc,
    # CDC topic: Debezium writes the raw change events of the PostgreSQL table
    # here (<prefix>.<schema>.<table>); the CDC bridge reads it.
    [string]$CdcTopic = 'pgcdc.public.order_events',
    # Debezium's heartbeat topic (see heartbeat.interval.ms in
    # cdc\debezium-postgres.properties). Nothing reads it.
    [string]$CdcHeartbeatTopic = '__debezium-heartbeat.pgcdc'
)

$ErrorActionPreference = 'Stop'

# Load the shared settings and helper functions.
. "$PSScriptRoot\kafka_common.ps1"
Assert-KafkaInstalled

if (-not (Test-BrokerPort)) {
    throw "No broker is listening on $BootstrapServer. Run scripts\start_kafka.ps1 first."
}

function New-Topic([string]$Name, [int]$Partitions, [string[]]$Config = @()) {
    # Creates one topic. --if-not-exists makes the call harmless when the
    # topic is already there. Replication factor is 1 because the cluster has
    # a single broker. $Config holds optional "name=value" topic settings.
    $configArguments = @($Config | ForEach-Object { '--config'; $_ })
    & "$KafkaBin\kafka-topics.bat" --bootstrap-server $BootstrapServer `
        --create --if-not-exists --topic $Name `
        --partitions $Partitions --replication-factor 1 @configArguments
    if ($LASTEXITCODE -ne 0) { throw "Creating topic $Name failed with exit code $LASTEXITCODE" }
}

# 3 partitions: enough to show that ordering is kept per order (the message key
# is the order id) while messages are spread over several partitions.
New-Topic -Name $Topic -Partitions 3

# 1 partition: the dead-letter topic is low-volume and read by people.
New-Topic -Name $DlqTopic -Partitions 1

if ($IncludeCdc) {
    # 1 partition: all change events of the table stay in the order in which
    # PostgreSQL committed them.
    # retention.ms=-1: never delete old data automatically. On Windows the
    # broker can fail when it deletes log files, so these topics are created
    # in a way that never asks it to.
    New-Topic -Name $CdcTopic          -Partitions 1 -Config 'retention.ms=-1'
    New-Topic -Name $CdcHeartbeatTopic -Partitions 1 -Config 'retention.ms=-1'
}

# Show the result as confirmation.
& "$KafkaBin\kafka-topics.bat" --bootstrap-server $BootstrapServer --list
