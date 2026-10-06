<#
.SYNOPSIS
  Deploy the Assignment 7 AWS stack and upload the Lambda code.

.DESCRIPTION
  1. Verifies the AWS account.
  2. Validates and deploys infra/aws/template.yaml (stack a7-orders-pipeline).
  3. Packages lambda/order_generator/ and uploads it only if the code changed.
  The hourly schedule state is passed explicitly every time (default DISABLED).

  No account-specific values are hard-coded. The target AWS account comes from
  $env:AWS_ACCOUNT_ID (or -ExpectedAccount). The bucket name is derived from it:
  a7-orders-pipeline-<AWS_ACCOUNT_ID> (override with -BucketName).

.EXAMPLE
  $env:AWS_ACCOUNT_ID = "<your-aws-account-id>"
  .\infra\aws\deploy.ps1
  .\infra\aws\deploy.ps1 -ScheduleState ENABLED
#>
param(
    [string]$Region = "ap-south-1",
    [string]$StackName = "a7-orders-pipeline",
    [string]$ExpectedAccount = $env:AWS_ACCOUNT_ID,
    [string]$BucketName,
    [ValidateSet("DISABLED", "ENABLED")]
    [string]$ScheduleState = "DISABLED",
    # Statement[0].Principal.AWS from SYSTEM$GET_AWS_SNS_IAM_POLICY. When omitted, the stack keeps its current value.
    [string]$SnowflakeSnsPrincipalArn
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Template = Join-Path $PSScriptRoot "template.yaml"
$ZipPath = Join-Path $ProjectRoot "build\order_generator.zip"

function Invoke-Aws {
    $output = & aws @args
    if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed (exit $LASTEXITCODE)" }
    return $output
}

Write-Host "== 1. Verify AWS identity"
if (-not $ExpectedAccount) { throw "Set `$env:AWS_ACCOUNT_ID (or pass -ExpectedAccount) to the target AWS account ID" }
$account = Invoke-Aws sts get-caller-identity --query Account --output text
if ($account -ne $ExpectedAccount) { throw "Wrong AWS account: $account (expected $ExpectedAccount)" }
if (-not $BucketName) { $BucketName = "a7-orders-pipeline-$ExpectedAccount" }
Write-Host "   account $account, region $Region, bucket $BucketName"

Write-Host "== 2. Validate template"
Invoke-Aws cloudformation validate-template --region $Region --template-body "file://$Template" | Out-Null

Write-Host "== 3. Deploy stack $StackName (ScheduleState=$ScheduleState)"
$overrides = @("ScheduleState=$ScheduleState", "BucketName=$BucketName")
if ($SnowflakeSnsPrincipalArn) { $overrides += "SnowflakeSnsPrincipalArn=$SnowflakeSnsPrincipalArn" }
Invoke-Aws cloudformation deploy --region $Region --stack-name $StackName `
    --template-file $Template --capabilities CAPABILITY_NAMED_IAM `
    --no-fail-on-empty-changeset `
    --parameter-overrides @overrides `
    --tags Project=assignment-7-automated-data-pipeline

$outputs = Invoke-Aws cloudformation describe-stacks --region $Region --stack-name $StackName `
    --query "Stacks[0].Outputs" --output json | ConvertFrom-Json
$functionName = ($outputs | Where-Object OutputKey -eq "FunctionName").OutputValue

Write-Host "== 4. Package Lambda code"
& python (Join-Path $ProjectRoot "scripts\package_lambda.py") $ZipPath
if ($LASTEXITCODE -ne 0) { throw "packaging failed" }
$sha = [Convert]::ToBase64String(
    [Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($ZipPath)))
$deployedSha = Invoke-Aws lambda get-function-configuration --region $Region `
    --function-name $functionName --query CodeSha256 --output text

if ($deployedSha -eq $sha) {
    Write-Host "== 5. Lambda code unchanged ($sha), skipping upload"
} else {
    Write-Host "== 5. Uploading Lambda code ($sha)"
    Invoke-Aws lambda update-function-code --region $Region --function-name $functionName `
        --zip-file "fileb://$ZipPath" --query "CodeSha256" --output text | Out-Null
    Invoke-Aws lambda wait function-updated-v2 --region $Region --function-name $functionName
}

Write-Host "== Done. Stack outputs:"
$outputs | Format-Table OutputKey, OutputValue -AutoSize
