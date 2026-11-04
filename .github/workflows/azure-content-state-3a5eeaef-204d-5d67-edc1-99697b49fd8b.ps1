# Content deployment state script version: 1.0.0+22de67edbd2b8bfb0f792ed14fb78a16aa11bee6

param(
    [ValidateSet('Prepare', 'Complete')]
    [string] $Action,

    [string] $SourceControlId,

    [string] $TrackedBranch,

    [string] $ContentRoot,

    [string] $WorkspaceId,

    [string] $WorkflowPath,

    [string] $DeploymentScriptPath,

    [string] $StateScriptPath,

    [string] $CandidatesPath,

    [string] $ResultsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateScriptName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
foreach ($component in @('Paths', 'Candidates', 'Store')) {
    $componentPath = Join-Path $PSScriptRoot "$stateScriptName.$component.ps1"
    if (-not (Test-Path -LiteralPath $componentPath -PathType Leaf)) {
        throw "Deployment state component '$componentPath' was not found."
    }

    . $componentPath
}

function Assert-RequiredEnvironment {
    foreach ($name in @('GH_TOKEN', 'GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_REF_NAME', 'GITHUB_EVENT_NAME')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Environment variable '$name' is missing or empty."
        }
    }
}

function Invoke-PrepareDeploymentState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConnectionId,

        [Parameter(Mandatory = $true)]
        [string] $Branch,

        [Parameter(Mandatory = $true)]
        [string] $Root,

        [string] $WorkspaceId,

        [Parameter(Mandatory = $true)]
        [string[]] $ArtifactPaths,

        [Parameter(Mandatory = $true)]
        [string] $OutputPath
    )

    Assert-RequiredEnvironment
    if ($env:GITHUB_REF_NAME -cne $Branch) {
        throw "Workflow branch '$env:GITHUB_REF_NAME' does not match configured branch '$Branch'."
    }

    $remoteHead = Get-RemoteBranchHead -Branch $Branch
    if ($remoteHead -ne $env:GITHUB_SHA) {
        throw "Workflow commit '$env:GITHUB_SHA' is stale. Branch '$Branch' is now at '$remoteHead'."
    }

    $stateBranch = Get-DeploymentStateBranchName
    $stateFilePath = Get-DeploymentStateFilePath -ConnectionId $ConnectionId -Branch $Branch
    $stateUrl = Get-DeploymentStateUrl `
        -Repository $env:GITHUB_REPOSITORY `
        -StateBranch $stateBranch `
        -StateFilePath $stateFilePath
    Publish-DeploymentStateLocation `
        -StateBranch $stateBranch `
        -StateFilePath $stateFilePath `
        -StateUrl $stateUrl
    try {
        $stateRecord = Get-DeploymentState `
            -Repository $env:GITHUB_REPOSITORY `
            -StateBranch $stateBranch `
            -StateFilePath $stateFilePath
    }
    catch {
        throw "Failed to read deployment state at '$stateUrl'. $($_.Exception.Message)"
    }
    $state = $stateRecord.State
    Assert-DeploymentStateIdentity `
        -State $state `
        -ConnectionId $ConnectionId `
        -Branch $Branch `
        -StateUrl $stateUrl
    [string[]] $pendingPaths = @()
    if ($null -ne $state -and $null -ne $state.pendingTemplates) {
        $pendingPaths = @($state.pendingTemplates | ForEach-Object { [string] $_.path })
    }

    $deployAll = $env:GITHUB_EVENT_NAME -ne 'push' -or
        $null -eq $state -or
        [string] $state.trackedBranch -ne $Branch -or
        [string]::IsNullOrWhiteSpace([string] $state.lastObservedCommit)
    $changes = [pscustomobject]@{
        ChangedPaths = @()
        DeletedPaths = @()
    }

    if (-not $deployAll) {
        $baseline = [string] $state.lastObservedCommit
        git fetch --no-tags --depth=1 origin $baseline
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Commit '$baseline' is unavailable. All eligible content will be deployed."
            $deployAll = $true
            $global:LASTEXITCODE = 0
        }
        else {
            $diffLines = @(git diff --name-status $baseline $env:GITHUB_SHA)
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to compare commit '$baseline' with '$env:GITHUB_SHA'."
            }

            $changes = ConvertFrom-GitNameStatus -Lines $diffLines
            if (@($changes.ChangedPaths + $changes.DeletedPaths).Where({
                    $_ -in $ArtifactPaths -or $_ -eq 'sentinel-deployment.config'
                }).Count -gt 0) {
                $deployAll = $true
            }
        }
    }

    $candidateFiles = @(
        Get-DeploymentCandidates `
            -ChangedPaths $changes.ChangedPaths `
            -DeletedPaths $changes.DeletedPaths `
            -PendingPaths $pendingPaths `
            -Root $Root `
            -DeployAll $deployAll `
            -WorkspaceId $WorkspaceId
    )
    ConvertTo-Json -InputObject @($candidateFiles) | Set-Content -LiteralPath $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
        Add-Content -LiteralPath $env:GITHUB_ENV -Value "DEPLOYMENT_CANDIDATE_COUNT=$($candidateFiles.Count)"
    }

    $lastSuccessfulRunId = if ($null -ne $state -and
        $null -ne $state.PSObject.Properties['lastSuccessfulRunId']) {
        [string] $state.lastSuccessfulRunId
    }
    else {
        $null
    }
    $newState = New-DeploymentState `
        -ConnectionId $ConnectionId `
        -Branch $Branch `
        -Commit $env:GITHUB_SHA `
        -LastSuccessfulRunId $lastSuccessfulRunId `
        -PendingPaths $candidateFiles
    try {
        Set-DeploymentState `
            -Repository $env:GITHUB_REPOSITORY `
            -StateBranch $stateBranch `
            -StateFilePath $stateFilePath `
            -State $newState
    }
    catch {
        throw "Failed to persist deployment state at '$stateUrl'. $($_.Exception.Message)"
    }

    foreach ($deletedPath in $changes.DeletedPaths) {
        Write-Host "Deleted repository path '$deletedPath' will not remove an Azure resource."
    }

    Write-Host "Selected $($candidateFiles.Count) deployment template(s) from branch '$Branch'."
}

function Invoke-CompleteDeploymentState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConnectionId,

        [Parameter(Mandatory = $true)]
        [string] $Branch,

        [Parameter(Mandatory = $true)]
        [string] $ResultPath
    )

    Assert-RequiredEnvironment
    if (-not (Test-Path -LiteralPath $ResultPath)) {
        Write-Host 'No deployment result file exists. All prepared candidates remain pending.'
        return
    }

    $failedPaths = @(
        Get-Content -LiteralPath $ResultPath -Raw |
            ConvertFrom-Json |
            ForEach-Object { [string] $_ }
    )
    $stateBranch = Get-DeploymentStateBranchName
    $stateFilePath = Get-DeploymentStateFilePath -ConnectionId $ConnectionId -Branch $Branch
    $stateUrl = Get-DeploymentStateUrl `
        -Repository $env:GITHUB_REPOSITORY `
        -StateBranch $stateBranch `
        -StateFilePath $stateFilePath
    try {
        $stateRecord = Get-DeploymentState `
            -Repository $env:GITHUB_REPOSITORY `
            -StateBranch $stateBranch `
            -StateFilePath $stateFilePath
    }
    catch {
        throw "Failed to read deployment state at '$stateUrl'. $($_.Exception.Message)"
    }
    if ($null -eq $stateRecord.State) {
        throw "Deployment state was not found at '$stateUrl'."
    }
    Assert-DeploymentStateIdentity `
        -State $stateRecord.State `
        -ConnectionId $ConnectionId `
        -Branch $Branch `
        -StateUrl $stateUrl

    $lastSuccessfulRunId = if ($failedPaths.Count -eq 0) {
        $env:GITHUB_RUN_ID
    }
    elseif ($null -ne $stateRecord.State.PSObject.Properties['lastSuccessfulRunId']) {
        [string] $stateRecord.State.lastSuccessfulRunId
    }
    else {
        $null
    }
    $newState = New-DeploymentState `
        -ConnectionId $ConnectionId `
        -Branch $Branch `
        -Commit $env:GITHUB_SHA `
        -LastSuccessfulRunId $lastSuccessfulRunId `
        -PendingPaths $failedPaths
    try {
        Set-DeploymentState `
            -Repository $env:GITHUB_REPOSITORY `
            -StateBranch $stateBranch `
            -StateFilePath $stateFilePath `
            -State $newState
    }
    catch {
        throw "Failed to persist deployment state at '$stateUrl'. $($_.Exception.Message)"
    }

    Write-Host "$($failedPaths.Count) deployment template(s) remain pending."
}

function Invoke-GitHubDeploymentState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Prepare', 'Complete')]
        [string] $RequestedAction,

        [Parameter(Mandatory = $true)]
        [string] $ConnectionId,

        [Parameter(Mandatory = $true)]
        [string] $Branch,

        [Parameter(Mandatory = $true)]
        [string] $Root,

        [string] $WorkspaceId,

        [Parameter(Mandatory = $true)]
        [string[]] $ArtifactPaths,

        [Parameter(Mandatory = $true)]
        [string] $CandidateOutputPath,

        [Parameter(Mandatory = $true)]
        [string] $ResultPath
    )

    if ($RequestedAction -eq 'Prepare') {
        Invoke-PrepareDeploymentState `
            -ConnectionId $ConnectionId `
            -Branch $Branch `
            -Root $Root `
            -WorkspaceId $WorkspaceId `
            -ArtifactPaths $ArtifactPaths `
            -OutputPath $CandidateOutputPath
        return
    }

    Invoke-CompleteDeploymentState -ConnectionId $ConnectionId -Branch $Branch -ResultPath $ResultPath
}

if ($MyInvocation.InvocationName -ne '.') {
    $stateComponentPaths = @('Paths', 'Candidates', 'Store') | ForEach-Object {
        [IO.Path]::ChangeExtension($StateScriptPath, "$_.ps1")
    }
    Invoke-GitHubDeploymentState `
        -RequestedAction $Action `
        -ConnectionId $SourceControlId `
        -Branch $TrackedBranch `
        -Root $ContentRoot `
        -WorkspaceId $WorkspaceId `
        -ArtifactPaths (@($WorkflowPath, $DeploymentScriptPath, $StateScriptPath) + $stateComponentPaths) `
        -CandidateOutputPath $CandidatesPath `
        -ResultPath $ResultsPath
}
