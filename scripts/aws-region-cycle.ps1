<#
.SYNOPSIS
Create, deploy, smoke-check, and destroy an isolated RAS Backend AWS stack.
.DESCRIPTION
Uses the existing Terraform-backed development lifecycle without GitHub Actions.
The selected region has a region-specific state bucket and AWS resources; the
existing eu-west-3 stack is explicitly protected from accidental targeting.

Examples:
  .\scripts\aws-region-cycle.ps1 -Action up -Region eu-west-1
  .\scripts\aws-region-cycle.ps1 -Action down -Region eu-west-1
  .\scripts\aws-region-cycle.ps1 -Action cycle -Region eu-west-1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('up', 'down', 'cycle')]
    [string]$Action,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Region,
    [string]$Profile = 'ras-backend-cloud',
    [string]$ImageTag
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$lifecycle = Join-Path $PSScriptRoot 'aws-dev.ps1'
$cloudDeploy = Join-Path $PSScriptRoot 'aws-dev-codebuild.ps1'
$currentRegion = 'eu-west-3'

if ($Region -eq $currentRegion -and $Action -in @('down', 'cycle')) {
    throw "Refusing destructive action '$Action' in '$Region' because the existing eu-west-3 stack is the live environment. Use an isolated region for lifecycle teardown."
}
if (-not (Test-Path -LiteralPath $lifecycle) -or -not (Test-Path -LiteralPath $cloudDeploy)) {
    throw 'Required AWS lifecycle or CodeBuild deploy script is missing.'
}
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw 'AWS CLI is required.' }
if (-not (Get-Command terraform -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $repoRoot '.tools\terraform\terraform.exe'))) {
    throw 'Terraform is required. Install it or place terraform.exe under .tools\terraform.'
}
$who = & aws sts get-caller-identity --profile $Profile --region $Region --query Account --output text
if ($LASTEXITCODE -ne 0 -or -not $who -match '^\d{12}$') { throw "AWS credentials for '$Profile' cannot access region '$Region'." }
$env:RAS_AWS_BUILD_DIR = if ($env:RAS_AWS_BUILD_DIR) { $env:RAS_AWS_BUILD_DIR } else { 'D:\DevTools\terraform\ras-backend-codebuild' }
$env:TF_DATA_DIR = if ($env:RAS_TERRAFORM_DATA_DIR) { [System.IO.Path]::GetFullPath($env:RAS_TERRAFORM_DATA_DIR) } else { "D:\DevTools\terraform\ras-backend-$Region" }
New-Item -ItemType Directory -Path $env:TF_DATA_DIR -Force | Out-Null
$taskTemp = "D:\DevTools\temp\ras-cycle-$Region"
New-Item -ItemType Directory -Path $taskTemp -Force | Out-Null
$env:TEMP = $taskTemp
$env:TMP = $taskTemp

function Invoke-Lifecycle {
    param([string]$LifecycleAction, [switch]$DestroyAutomatically)
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $lifecycle, '-Action', $LifecycleAction, '-Profile', $Profile, '-Region', $Region)
    if ($DestroyAutomatically) { $arguments += '-AutoDestroy' }
    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "AWS lifecycle '$LifecycleAction' failed in $Region (exit $LASTEXITCODE)." }
}

function Start-Up {
    # Terraform provisions in the selected region; CodeBuild performs the Docker
    # build and SSM deploy remotely. Neither operation uses GitHub Actions.
    Invoke-Lifecycle -LifecycleAction 'provision'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cloudDeploy, '-Profile', $Profile, '-Region', $Region)
    if ($ImageTag) { $arguments += @('-ImageTag', $ImageTag) }
    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "AWS CodeBuild deployment failed in $Region (exit $LASTEXITCODE). Infrastructure remains for diagnosis; run this script with -Action down after review." }
    Write-Output "UP complete in $Region. Endpoint report: $(Join-Path $repoRoot 'docs\aws-cloud-deployment-report.md')"
}

function Start-Down {
    # Preserve the endpoint report locally, then remove the selected region's stack,
    # CodeBuild automation, IAM role, logs, ECR images, and versioned Terraform bucket.
    Invoke-Lifecycle -LifecycleAction 'down' -DestroyAutomatically
    $account = (& aws sts get-caller-identity --profile $Profile --region $Region --query Account --output text).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify AWS account for scoped cleanup.' }
    $project = "ras-backend-dev-cloud-deploy-$Region"
    $role = "ras-backend-dev-codebuild-$Region"
    try { & aws codebuild delete-project --name $project --profile $Profile --region $Region 2>$null } catch {}
    try { & aws logs delete-log-group --log-group-name "/aws/codebuild/$project" --profile $Profile --region $Region 2>$null } catch {}
    try { & aws iam delete-role-policy --role-name $role --policy-name ras-backend-dev-cloud-deploy --profile $Profile 2>$null } catch {}
    try { & aws iam delete-role --role-name $role --profile $Profile 2>$null } catch {}
    $bucket = "ras-backend-tfstate-$account-$Region"
    $exists = & aws s3api head-bucket --bucket $bucket --profile $Profile 2>$null
    if ($LASTEXITCODE -eq 0) {
        $listing = & aws s3api list-object-versions --bucket $bucket --profile $Profile --region $Region --output json | ConvertFrom-Json
        foreach ($item in @($listing.Versions) + @($listing.DeleteMarkers)) {
            if ($item.Key -and $item.VersionId) {
                $null = & aws s3api delete-object --bucket $bucket --key $item.Key --version-id $item.VersionId --profile $Profile --region $Region
                if ($LASTEXITCODE -ne 0) { throw "Failed removing versioned Terraform state object $($item.Key)." }
            }
        }
        $null = & aws s3api delete-bucket --bucket $bucket --profile $Profile --region $Region
        if ($LASTEXITCODE -ne 0) { throw "Failed removing isolated state bucket $bucket." }
    }
    Write-Output "DOWN complete in $Region. Stack, CodeBuild role/project/logs, ECR images, and versioned Terraform state bucket removed."
}

switch ($Action) {
    'up' { Start-Up }
    'down' { Start-Down }
    'cycle' {
        $upError = $null
        try { Start-Up }
        catch { $upError = $_.Exception.Message }
        finally {
            try { Start-Down }
            catch {
                $downError = $_.Exception.Message
                throw "Cycle cleanup failed in $Region. Original up error: $upError. Teardown error: $downError"
            }
        }
        if ($upError) { throw "Up/deploy failed in $Region; automated teardown completed. Cause: $upError" }
        Write-Output "CYCLE PASS: stack deployed, health checked, and destroyed in $Region."
    }
}
