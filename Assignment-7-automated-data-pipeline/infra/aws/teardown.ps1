<#
.SYNOPSIS
  Remove ONLY the Assignment 7 AWS resources: empty the project bucket, then delete the stack.

.EXAMPLE
  $env:AWS_ACCOUNT_ID = "<your-aws-account-id>"
  .\infra\aws\teardown.ps1            # asks for confirmation
  .\infra\aws\teardown.ps1 -Force
#>
param(
    [string]$Region = "ap-south-1",
    [string]$StackName = "a7-orders-pipeline",
    [string]$ExpectedAccount = $env:AWS_ACCOUNT_ID,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
if (-not $ExpectedAccount) { throw "Set `$env:AWS_ACCOUNT_ID (or pass -ExpectedAccount) to the target AWS account ID" }

$account = aws sts get-caller-identity --query Account --output text
if ($LASTEXITCODE -ne 0 -or $account -ne $ExpectedAccount) { throw "Wrong or unknown AWS account: $account" }

$bucket = aws cloudformation describe-stacks --region $Region --stack-name $StackName `
    --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text
if ($LASTEXITCODE -ne 0 -or -not $bucket) { throw "Stack $StackName not found in $Region" }

if (-not $Force) {
    $answer = Read-Host "Delete stack '$StackName' and ALL objects in s3://$bucket ? Type the stack name to confirm"
    if ($answer -ne $StackName) { Write-Host "Aborted."; exit 1 }
}

Write-Host "Emptying s3://$bucket"
aws s3 rm "s3://$bucket" --recursive --region $Region
if ($LASTEXITCODE -ne 0) { throw "failed to empty bucket" }

Write-Host "Deleting stack $StackName"
aws cloudformation delete-stack --region $Region --stack-name $StackName
aws cloudformation wait stack-delete-complete --region $Region --stack-name $StackName
if ($LASTEXITCODE -ne 0) { throw "stack deletion did not complete" }

# The Snowflake read role is created with the AWS CLI (infra/aws/iam/), not by the stack.
$snowflakeRole = "a7-snowflake-s3-access-role"
aws iam get-role --role-name $snowflakeRole --query Role.RoleName --output text 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Deleting IAM role $snowflakeRole"
    aws iam delete-role-policy --role-name $snowflakeRole --policy-name a7-snowflake-read-landing
    aws iam delete-role --role-name $snowflakeRole
}
Write-Host "Teardown complete."
