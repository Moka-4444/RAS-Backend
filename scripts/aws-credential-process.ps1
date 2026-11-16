$ErrorActionPreference = 'Stop'
$env:AWS_CONFIG_FILE = Join-Path $env:USERPROFILE '.aws\config'
Remove-Item Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY, Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
$profile = if ($env:RAS_AWS_PROFILE) { $env:RAS_AWS_PROFILE } else { 'ras-backend-cloud' }
$credentialOutput = & aws configure export-credentials --profile $profile --format process
if ($LASTEXITCODE -ne 0) { throw 'Could not refresh the AWS login session for Terraform.' }
[Console]::Out.Write(($credentialOutput -join ''))
