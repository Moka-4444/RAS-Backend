param(
    [string]$Profile = 'ras-backend-cloud',
    [string]$Region = 'eu-west-3',
    [string]$ImageTag,
    [switch]$ReuseImages
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectName = "ras-backend-dev-cloud-deploy-$Region"
$roleName = "ras-backend-dev-codebuild-$Region"
$logGroup = "/aws/codebuild/$projectName"
$buildRoot = if ($env:RAS_AWS_BUILD_DIR) { [System.IO.Path]::GetFullPath($env:RAS_AWS_BUILD_DIR) } else { 'D:\DevTools\terraform\ras-backend-codebuild' }
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$sourceCommit = (git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Could not determine the committed CodeBuild source revision.' }

function Invoke-AwsText {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $result = & aws @Arguments --profile $Profile --region $Region
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: aws $($Arguments -join ' ')" }
    return ($result | Out-String).Trim()
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

$accountId = Invoke-AwsText sts get-caller-identity --query Account --output text
if ($ImageTag) {
    if ($ImageTag -notmatch '^[a-fA-F0-9]{7,64}$') { throw 'ImageTag must be a Git commit SHA.' }
} else {
    $ImageTag = $sourceCommit
}
$ImageTag = $ImageTag.ToLowerInvariant()
$stateBucket = "ras-backend-tfstate-$accountId-$Region"
$bucketCheck = & aws s3api head-bucket --bucket $stateBucket --profile $Profile 2>$null
if ($LASTEXITCODE -ne 0) { throw "Expected Terraform state bucket is missing: $stateBucket" }

$instanceId = Invoke-AwsText ec2 describe-instances --filters 'Name=tag:Name,Values=ras-backend-dev-app-host' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text
if (-not $instanceId -or $instanceId -eq 'None') { throw 'The running AWS development host was not found.' }
$databaseEndpoint = Invoke-AwsText rds describe-db-instances --db-instance-identifier ras-backend-dev --query 'DBInstances[0].Endpoint.Address' --output text
if (-not $databaseEndpoint -or $databaseEndpoint -eq 'None') { throw 'The AWS development database is not available.' }

$archivePath = Join-Path $buildRoot "ras-backend-$sourceCommit.zip"
if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
git -C $repoRoot archive --format=zip --output=$archivePath $sourceCommit
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath)) { throw 'Could not package the committed source for AWS CodeBuild.' }

$sourceKey = "ras-backend/dev/aws-codebuild/source/$sourceCommit.zip"
$null = Invoke-AwsText s3 cp $archivePath "s3://$stateBucket/$sourceKey" --sse AES256

$trustPath = Join-Path $buildRoot 'codebuild-trust.json'
$policyPath = Join-Path $buildRoot 'codebuild-policy.json'
$requestPath = Join-Path $buildRoot 'codebuild-project.json'
$trustPolicy = @{
    Version = '2012-10-17'
    Statement = @(@{ Effect = 'Allow'; Principal = @{ Service = 'codebuild.amazonaws.com' }; Action = 'sts:AssumeRole' })
}
Write-JsonFile $trustPath $trustPolicy
$repositories = @('ras-auth-api', 'ras-branch-api', 'ras-attendance-api', 'ras-menu-api', 'ras-central-kitchen-api', 'ras-inventory-api', 'ras-cost-api', 'ras-sales-api', 'ras-transfer-api', 'ras-reports-api', 'ras-db-migrations')
$repositoryArns = @($repositories | ForEach-Object { "arn:aws:ecr:${Region}:${accountId}:repository/$_" })
if ($ReuseImages) {
    foreach ($repository in $repositories) {
        $digest = Invoke-AwsText ecr describe-images --repository-name $repository --image-ids "imageTag=$ImageTag" --query 'imageDetails[0].imageDigest' --output text
        if (-not $digest -or $digest -eq 'None') { throw "Cannot reuse missing image ${repository}:$ImageTag." }
    }
}
$instanceArn = "arn:aws:ec2:${Region}:${accountId}:instance/${instanceId}"
$documentArn = "arn:aws:ssm:${Region}::document/AWS-RunShellScript"
$bucketArn = "arn:aws:s3:::$stateBucket"
$objectPrefixArn = "arn:aws:s3:::${stateBucket}/ras-backend/dev/aws-codebuild/*"
$reportPrefixArn = "arn:aws:s3:::${stateBucket}/ras-backend/dev/reports/*"
$policy = @{
    Version = '2012-10-17'
    Statement = @(
        @{ Effect = 'Allow'; Action = @('logs:CreateLogStream', 'logs:PutLogEvents'); Resource = "arn:aws:logs:${Region}:${accountId}:log-group:${logGroup}:*" },
        @{ Effect = 'Allow'; Action = @('logs:CreateLogGroup'); Resource = "arn:aws:logs:${Region}:${accountId}:log-group:${logGroup}" },
        @{ Effect = 'Allow'; Action = @('ecr:GetAuthorizationToken'); Resource = '*' },
        @{ Effect = 'Allow'; Action = @('ecr:BatchCheckLayerAvailability', 'ecr:BatchGetImage', 'ecr:CompleteLayerUpload', 'ecr:InitiateLayerUpload', 'ecr:PutImage', 'ecr:UploadLayerPart'); Resource = $repositoryArns },
        @{ Effect = 'Allow'; Action = @('ec2:DescribeInstances', 'rds:DescribeDBInstances', 'ssm:DescribeInstanceInformation'); Resource = '*' },
        @{ Effect = 'Allow'; Action = @('ssm:SendCommand'); Resource = @($documentArn, $instanceArn) },
        @{ Effect = 'Allow'; Action = @('ssm:GetCommandInvocation'); Resource = '*' },
        @{ Effect = 'Allow'; Action = @('s3:GetBucketAcl', 's3:GetBucketLocation', 's3:ListBucket'); Resource = $bucketArn },
        @{ Effect = 'Allow'; Action = @('s3:GetObject', 's3:GetObjectVersion', 's3:PutObject'); Resource = $objectPrefixArn },
        @{ Effect = 'Allow'; Action = @('s3:PutObject'); Resource = $reportPrefixArn }
    )
}
Write-JsonFile $policyPath $policy
$roleArn = "arn:aws:iam::${accountId}:role/$roleName"
$existingRole = $null
try { $existingRole = & aws iam get-role --role-name $roleName --profile $Profile --region $Region --query Role.Arn --output text 2>$null; $roleLookupSucceeded = ($LASTEXITCODE -eq 0) }
catch { $roleLookupSucceeded = $false }
if ($roleLookupSucceeded) {
    $null = Invoke-AwsText iam update-assume-role-policy --role-name $roleName --policy-document "file://$trustPath"
} else {
    $null = Invoke-AwsText iam create-role --role-name $roleName --assume-role-policy-document "file://$trustPath" --description 'AWS-native RAS Backend build and development deployment role' --query Role.Arn --output text
}
$null = Invoke-AwsText iam put-role-policy --role-name $roleName --policy-name ras-backend-dev-cloud-deploy --policy-document "file://$policyPath"
Start-Sleep -Seconds 10

$publishImages = if ($ReuseImages) { 'false' } else { 'true' }
$environmentVariables = @(
    @{ name = 'AWS_REGION'; value = $Region; type = 'PLAINTEXT' },
    @{ name = 'AWS_ACCOUNT_ID'; value = $accountId; type = 'PLAINTEXT' },
    @{ name = 'API_GATEWAY_BASE_URL'; value = "https://$(Invoke-AwsText apigatewayv2 get-apis --query "Items[?Name=='ras-backend-dev'].ApiId | [0]" --output text).execute-api.$Region.amazonaws.com/dev"; type = 'PLAINTEXT' },
    @{ name = 'INSTANCE_ID'; value = $instanceId; type = 'PLAINTEXT' },
    @{ name = 'DATABASE_ENDPOINT'; value = $databaseEndpoint; type = 'PLAINTEXT' },
    @{ name = 'DATABASE_MASTER_USERNAME'; value = 'migration_admin'; type = 'PLAINTEXT' },
    @{ name = 'STATE_BUCKET'; value = $stateBucket; type = 'PLAINTEXT' },
    @{ name = 'IMAGE_TAG'; value = $ImageTag; type = 'PLAINTEXT' },
    @{ name = 'SOURCE_COMMIT'; value = $sourceCommit; type = 'PLAINTEXT' },
    @{ name = 'PUBLISH_IMAGES'; value = $publishImages; type = 'PLAINTEXT' }
)
$project = @{
    name = $projectName
    description = 'Build all RAS Backend images in AWS, publish to ECR, deploy with SSM, and verify health endpoints.'
    serviceRole = $roleArn
    source = @{ type = 'S3'; location = "$stateBucket/$sourceKey"; buildspec = 'buildspec-aws-cloud.yml' }
    artifacts = @{ type = 'NO_ARTIFACTS' }
    environment = @{ type = 'LINUX_CONTAINER'; image = 'aws/codebuild/standard:7.0'; computeType = 'BUILD_GENERAL1_MEDIUM'; privilegedMode = $true; imagePullCredentialsType = 'CODEBUILD'; environmentVariables = $environmentVariables }
    timeoutInMinutes = 60
    queuedTimeoutInMinutes = 30
    logsConfig = @{ cloudWatchLogs = @{ status = 'ENABLED'; groupName = $logGroup }; s3Logs = @{ status = 'DISABLED' } }
    tags = @(@{ key = 'Project'; value = 'RAS-backend' }, @{ key = 'Environment'; value = 'development' }, @{ key = 'ManagedBy'; value = 'aws-dev-codebuild.ps1' })
}
Write-JsonFile $requestPath $project
$projectExists = $null
try { $projectExists = & aws codebuild batch-get-projects --names $projectName --profile $Profile --region $Region --query 'projects[0].name' --output text 2>$null; $projectLookupSucceeded = ($LASTEXITCODE -eq 0) }
catch { $projectLookupSucceeded = $false }
if ($projectLookupSucceeded -and $projectExists -eq $projectName) {
    $null = Invoke-AwsText codebuild update-project --cli-input-json "file://$requestPath" --query project.name --output text
} else {
    $null = Invoke-AwsText codebuild create-project --cli-input-json "file://$requestPath" --query project.name --output text
}

$buildJson = Invoke-AwsText codebuild start-build --project-name $projectName --query build --output json
$build = $buildJson | ConvertFrom-Json
$buildId = $build.id
if (-not $buildId) { throw 'AWS CodeBuild did not return a build ID.' }
Write-Output "AWS CodeBuild started: $buildId"
$deadline = [DateTime]::UtcNow.AddMinutes(60)
do {
    Start-Sleep -Seconds 15
    $status = Invoke-AwsText codebuild batch-get-builds --ids $buildId --query 'builds[0].buildStatus' --output text
    Write-Output "AWS CodeBuild status: $status"
} while ($status -in @('IN_PROGRESS', 'QUEUED') -and [DateTime]::UtcNow -lt $deadline)
if ($status -ne 'SUCCEEDED') {
    & aws logs tail $logGroup --since 1h --format short --profile $Profile --region $Region
    throw "AWS CodeBuild $status. Inspect CloudWatch log group $logGroup; AWS stack was left running."
}

$reportKey = "ras-backend/dev/reports/aws-cloud-deployment-$ImageTag.md"
$reportPath = Join-Path $repoRoot 'docs\aws-cloud-deployment-report.md'
$null = Invoke-AwsText s3 cp "s3://$stateBucket/$reportKey" $reportPath
Write-Output "Cloud deployment and endpoint report saved to $reportPath"
Write-Output "All AWS resources remain running. Build ID: $buildId"
