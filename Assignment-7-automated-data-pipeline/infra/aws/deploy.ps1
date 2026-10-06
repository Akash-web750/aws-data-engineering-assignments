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

  Why parameterized: the repository is public, so the production account ID must
  not be stored in it. Requiring the account explicitly and comparing it with the
  signed-in identity also prevents deploying into the wrong AWS account.

  Prerequisites: AWS CLI v2 signed in (e.g. `aws login`) as an IAM user with
  CloudFormation/IAM/S3/Lambda/SNS/Scheduler rights; Python 3 on PATH (packaging).

  Safety: the stack is changed only through CloudFormation (no console edits),
  parameters that are not passed keep their current stack values, and the
  schedule state is always passed so a re-deploy never silently enables it.
  Preview production changes with a change set before running this script.

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

# Stop on the first PowerShell error instead of continuing with a half-deployed stack.
$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Template = Join-Path $PSScriptRoot "template.yaml"
# build/ is git-ignored; the zip is regenerated on every run.
$ZipPath = Join-Path $ProjectRoot "build\order_generator.zip"

# The AWS CLI is a native executable: its failures do not raise PowerShell errors,
# so every call goes through this wrapper, which turns a non-zero exit into an exception.
function Invoke-Aws {
    $output = & aws @args
    if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed (exit $LASTEXITCODE)" }
    return $output
}

# Step 1 - guard against the wrong account: require an explicit target account and
# compare it with the identity the CLI is actually signed in as.
Write-Host "== 1. Verify AWS identity"
if (-not $ExpectedAccount) { throw "Set `$env:AWS_ACCOUNT_ID (or pass -ExpectedAccount) to the target AWS account ID" }
$account = Invoke-Aws sts get-caller-identity --query Account --output text
if ($account -ne $ExpectedAccount) { throw "Wrong AWS account: $account (expected $ExpectedAccount)" }
# S3 bucket names are global; suffixing the account ID makes the name unique and
# environment-specific without storing it in the repository.
if (-not $BucketName) { $BucketName = "a7-orders-pipeline-$ExpectedAccount" }
Write-Host "   account $account, region $Region, bucket $BucketName"

Write-Host "== 2. Validate template"
Invoke-Aws cloudformation validate-template --region $Region --template-body "file://$Template" | Out-Null

# Step 3 - create or update the stack through a change set (`cloudformation deploy`).
#   CAPABILITY_NAMED_IAM: the template creates named IAM roles.
#   --no-fail-on-empty-changeset: re-running with no changes is a success, not an error.
#   Parameters not listed in --parameter-overrides keep their previous stack values
#   (e.g. SnowflakeSnsPrincipalArn when -SnowflakeSnsPrincipalArn is omitted).
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

# Steps 4-5 - the stack creates the function with placeholder code; the real code is
# uploaded here. The deterministic zip (scripts/package_lambda.py) means an unchanged
# source tree produces the same CodeSha256, so the upload is skipped. Any byte change,
# comments included, triggers a re-upload.
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
