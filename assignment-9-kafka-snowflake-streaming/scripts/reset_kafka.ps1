# =============================================================================
# reset_kafka.ps1
# Deletes ALL local Kafka data: every topic, message and committed offset.
#
#     .\scripts\reset_kafka.ps1          # asks for confirmation
#     .\scripts\reset_kafka.ps1 -Force   # no question (for scripted use)
#
# Use it to start a demo from an empty broker. Afterwards run start_kafka.ps1
# and create_topics.ps1 again. Snowflake is not touched.
# =============================================================================

param(
    # Skip the confirmation question.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Load the shared settings and helper functions.
. "$PSScriptRoot\kafka_common.ps1"

# The data folder cannot be removed while the broker has its files open.
if (@(Get-KafkaProcess).Count -gt 0) {
    throw 'The Kafka broker is running. Run scripts\stop_kafka.ps1 first.'
}

if (-not (Test-Path $KafkaData)) {
    Write-Host "Nothing to delete: $KafkaData does not exist."
    return
}

# This is destructive, so ask first unless -Force was given.
if (-not $Force) {
    $answer = Read-Host "Delete ALL Kafka data in $KafkaData ? Type YES to confirm"
    if ($answer -ne 'YES') {
        Write-Host 'Cancelled. Nothing was deleted.'
        return
    }
}

Remove-Item -Recurse -Force $KafkaData
Write-Host "Deleted $KafkaData. Next: start_kafka.ps1, then create_topics.ps1."
