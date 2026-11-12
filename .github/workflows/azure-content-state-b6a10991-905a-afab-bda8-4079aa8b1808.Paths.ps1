# Content deployment state script version: 1.0.0+af43c81018a634a394b32d954de5f242ced9f856

$script:StateBranchName = 'content-deployment-state'
$script:StateReadmePath = 'README.md'
$script:MaxStateWriteAttempts = 3

function Get-DeploymentStateBranchName {
    return $script:StateBranchName
}

function Get-DeploymentStateFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConnectionId,

        [Parameter(Mandatory = $true)]
        [string] $Branch
    )

    $fileName = [regex]::Replace($Branch, '[\\/:*?"<>|]', '-')
    return ".deployment-state/$ConnectionId/$fileName.json"
}

function Get-DeploymentStateUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $StateBranch,

        [Parameter(Mandatory = $true)]
        [string] $StateFilePath
    )

    $serverUrl = if ([string]::IsNullOrWhiteSpace($env:GITHUB_SERVER_URL)) {
        'https://github.com'
    }
    else {
        $env:GITHUB_SERVER_URL.TrimEnd('/')
    }

    return "$serverUrl/$Repository/blob/$StateBranch/$StateFilePath"
}

function Publish-DeploymentStateLocation {
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateBranch,

        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $true)]
        [string] $StateUrl
    )

    Write-Host "Deployment state: $StateUrl"
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
        return
    }

    Add-Content -LiteralPath $env:GITHUB_ENV -Value "DEPLOYMENT_STATE_BRANCH=$StateBranch"
    Add-Content -LiteralPath $env:GITHUB_ENV -Value "DEPLOYMENT_STATE_PATH=$StateFilePath"
    Add-Content -LiteralPath $env:GITHUB_ENV -Value "DEPLOYMENT_STATE_URL=$StateUrl"
}

function Get-DeploymentStateReadmeContent {
    return @'
# Content deployment state

This orphan branch is managed by generated Content as Code GitHub Actions workflows.
Do not edit state files manually.

## File layout

```text
.deployment-state/{sourceControlId}/{sanitizedBranch}.json
```

- `sourceControlId` is the unique source-control deployment connection ID supplied by the service.
  It prevents separate deployment configurations using the same repository branch from colliding.
- `sanitizedBranch` is the tracked branch name with path-unsafe characters replaced by `-`
  (for example, `scenario/one` becomes `scenario-one.json`). The JSON also stores the full
  `trackedBranch` and `sourceControlId`. If two names map to the same filename, the workflow
  rejects the mismatched identity rather than overwriting another branch's state.

Each JSON file stores the last observed source commit, the latest attempted and successful workflow
run IDs, and templates that still require deployment.
The Prepare step saves all selected candidates before Azure login. The Complete step replaces that
list with only failed templates. Deleted repository templates are removed from state, but their
Azure resources are not deleted.

State writes retry GitHub conflicts caused by deployments updating different files concurrently.
Disconnect attempts to remove only the tracking file for that connection and full tracked branch.
The shared state branch, README, and other connections' files remain.
An active workflow can recreate its state after disconnect; the service reports incomplete or
unconfirmed cleanup as a warning and does not cancel workflow runs.
Renamed or deleted source branches are not automatically offboarded.
'@
}
