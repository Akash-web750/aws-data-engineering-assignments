# =============================================================================
# install_kafka.ps1
# Downloads Apache Kafka, verifies the download and extracts it to C:\kafka.
#
# Run once:
#     .\scripts\install_kafka.ps1
#
# Nothing is installed system-wide: Kafka is just a folder. Removing the folder
# uninstalls it. Java 17 or later must already be installed.
# =============================================================================

param(
    # Kafka release to install. Must be a 4.x release (KRaft only, Java 17+).
    [string]$KafkaVersion = '4.3.1',
    # Scala build of the release. 2.13 is the only one published for Kafka 4.x.
    [string]$ScalaVersion = '2.13'
)

# Stop at the first error instead of continuing with a half-finished install.
$ErrorActionPreference = 'Stop'

# Load the shared settings ($KafkaHome and friends).
. "$PSScriptRoot\kafka_common.ps1"

# --- Step 1: refuse to overwrite an existing install -------------------------
if (Test-Path (Join-Path $KafkaBin 'kafka-server-start.bat')) {
    Write-Host "Kafka is already installed in $KafkaHome. Nothing to do."
    return
}

# --- Step 2: check that Java is available ------------------------------------
# Kafka is a Java program; without Java the launchers fail with a vague error.
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw 'Java was not found on PATH. Install Java 17 or later first.'
}

# --- Step 3: work out the download locations ---------------------------------
$archiveName = "kafka_$ScalaVersion-$KafkaVersion.tgz"
# downloads.apache.org holds the current releases and their checksum files.
$baseUrl     = "https://downloads.apache.org/kafka/$KafkaVersion"
$archivePath = Join-Path $env:TEMP $archiveName
$hashPath    = "$archivePath.sha512"

# --- Step 4: download the archive and its SHA-512 checksum -------------------
# The progress bar makes Invoke-WebRequest very slow in Windows PowerShell 5.1,
# so it is switched off for the download.
$ProgressPreference = 'SilentlyContinue'
Write-Host "Downloading $archiveName ..."
Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$archiveName"        -OutFile $archivePath
Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$archiveName.sha512" -OutFile $hashPath

# --- Step 5: verify the download ---------------------------------------------
# The .sha512 file looks like "kafka_x.tgz: ABCD 1234 ..." spread over several
# lines. Everything after the colon, minus spaces and line breaks, is the hash.
$expected = ((Get-Content $hashPath -Raw) -replace '^[^:]*:', '') -replace '[^0-9A-Fa-f]', ''
$actual   = (Get-FileHash -Algorithm SHA512 -Path $archivePath).Hash
if ($expected.ToUpper() -ne $actual.ToUpper()) {
    # A mismatch means a corrupted or tampered download: do not extract it.
    throw "Checksum mismatch for $archiveName. Delete $archivePath and run again."
}
Write-Host 'Checksum verified.'

# --- Step 6: extract into the install folder ---------------------------------
New-Item -ItemType Directory -Force -Path $KafkaHome | Out-Null
# tar.exe ships with Windows 10/11. --strip-components=1 drops the archive's
# top folder ("kafka_2.13-x.y.z") so the files land directly in $KafkaHome,
# keeping every path as short as possible.
tar -xzf $archivePath -C $KafkaHome --strip-components=1
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

# --- Step 7: tidy up ----------------------------------------------------------
Remove-Item $archivePath, $hashPath -Force
Write-Host "Kafka $KafkaVersion installed in $KafkaHome."
Write-Host 'Next: .\scripts\start_kafka.ps1'
