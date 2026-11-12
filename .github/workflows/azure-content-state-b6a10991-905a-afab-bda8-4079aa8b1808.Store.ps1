# Content deployment state script version: 1.0.0+af43c81018a634a394b32d954de5f242ced9f856

function Invoke-GitHubRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Put')]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [object] $Body,

        [switch] $AllowNotFound
    )

    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $env:GH_TOKEN"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $apiUrl = if ([string]::IsNullOrWhiteSpace($env:GITHUB_API_URL)) {
        'https://api.github.com'
    }
    else {
        $env:GITHUB_API_URL.TrimEnd('/')
    }
    $parameters = @{
        Uri = "$apiUrl/$Path"
        Method = $Method
        Headers = $headers
    }

    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    try {
        return Invoke-RestMethod @parameters
    }
    catch {
        $statusCode = [int] $_.Exception.Response.StatusCode
        if ($AllowNotFound -and $statusCode -eq 404) {
            return $null
        }

        throw
    }
}

function Get-DeploymentState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $StateBranch,

        [Parameter(Mandatory = $true)]
        [string] $StateFilePath
    )

    $encodedBranch = [Uri]::EscapeDataString($StateBranch)
    $response = Invoke-GitHubRequest `
        -Method Get `
        -Path "repos/$Repository/contents/$StateFilePath`?ref=$encodedBranch" `
        -AllowNotFound
    if ($null -eq $response) {
        return [pscustomobject]@{
            ContentSha = $null
            State = $null
        }
    }

    $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($response.content -replace '\s', '')))
    return [pscustomobject]@{
        ContentSha = [string] $response.sha
        State = $content | ConvertFrom-Json -Depth 20
    }
}

function Test-GitHubWriteConflict {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.ErrorRecord] $ErrorRecord
    )

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) {
        return $false
    }

    return [int] $responseProperty.Value.StatusCode -in @(409, 422)
}

function Set-DeploymentState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $StateBranch,

        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $true)]
        [object] $State
    )

    $json = $State | ConvertTo-Json -Depth 20
    $content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $readmeContent = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes((Get-DeploymentStateReadmeContent))
    )
    $encodedBranch = [Uri]::EscapeDataString($StateBranch)

    for ($attempt = 1; $attempt -le $script:MaxStateWriteAttempts; $attempt++) {
        try {
            $currentState = Get-DeploymentState `
                -Repository $Repository `
                -StateBranch $StateBranch `
                -StateFilePath $StateFilePath
            Assert-DeploymentStateIdentity `
                -State $currentState.State `
                -ConnectionId $State.sourceControlId `
                -Branch $State.trackedBranch `
                -StateUrl (Get-DeploymentStateUrl `
                    -Repository $Repository `
                    -StateBranch $StateBranch `
                    -StateFilePath $StateFilePath)
            $branchReference = Invoke-GitHubRequest `
                -Method Get `
                -Path "repos/$Repository/git/ref/heads/$encodedBranch" `
                -AllowNotFound

            if ($null -eq $branchReference) {
                $stateBlob = Invoke-GitHubRequest -Method Post -Path "repos/$Repository/git/blobs" -Body @{
                    content = $content
                    encoding = 'base64'
                }
                $readmeBlob = Invoke-GitHubRequest -Method Post -Path "repos/$Repository/git/blobs" -Body @{
                    content = $readmeContent
                    encoding = 'base64'
                }
                $tree = Invoke-GitHubRequest -Method Post -Path "repos/$Repository/git/trees" -Body @{
                    tree = @(
                        @{
                            path = $StateFilePath
                            mode = '100644'
                            type = 'blob'
                            sha = $stateBlob.sha
                        }
                        @{
                            path = $script:StateReadmePath
                            mode = '100644'
                            type = 'blob'
                            sha = $readmeBlob.sha
                        }
                    )
                }
                $commit = Invoke-GitHubRequest -Method Post -Path "repos/$Repository/git/commits" -Body @{
                    message = 'Initialize content deployment state'
                    tree = $tree.sha
                    parents = @()
                }
                $null = Invoke-GitHubRequest -Method Post -Path "repos/$Repository/git/refs" -Body @{
                    ref = "refs/heads/$StateBranch"
                    sha = $commit.sha
                }
                return
            }

            $readmeResponse = Invoke-GitHubRequest `
                -Method Get `
                -Path "repos/$Repository/contents/$script:StateReadmePath`?ref=$encodedBranch" `
                -AllowNotFound
            if ($null -eq $readmeResponse) {
                $readmeBody = @{
                    message = 'Document content deployment state'
                    content = $readmeContent
                    branch = $StateBranch
                }
                $null = Invoke-GitHubRequest `
                    -Method Put `
                    -Path "repos/$Repository/contents/$script:StateReadmePath" `
                    -Body $readmeBody
            }

            $body = @{
                message = "Update content deployment state for '$($State.trackedBranch)'"
                content = $content
                branch = $StateBranch
            }
            if (-not [string]::IsNullOrWhiteSpace($currentState.ContentSha)) {
                $body.sha = $currentState.ContentSha
            }

            $null = Invoke-GitHubRequest `
                -Method Put `
                -Path "repos/$Repository/contents/$StateFilePath" `
                -Body $body
            return
        }
        catch {
            if ($attempt -eq $script:MaxStateWriteAttempts -or -not (Test-GitHubWriteConflict -ErrorRecord $_)) {
                throw
            }

            Write-Warning "Deployment state changed concurrently. Retrying write (attempt $($attempt + 1) of $script:MaxStateWriteAttempts)."
            Start-Sleep -Seconds $attempt
        }
    }
}

function Assert-DeploymentStateIdentity {
    param(
        [object] $State,

        [Parameter(Mandatory = $true)]
        [string] $ConnectionId,

        [Parameter(Mandatory = $true)]
        [string] $Branch,

        [Parameter(Mandatory = $true)]
        [string] $StateUrl
    )

    if ($null -eq $State) {
        return
    }

    if ([string] $State.sourceControlId -cne $ConnectionId -or [string] $State.trackedBranch -cne $Branch) {
        throw "Deployment state identity at '$StateUrl' does not match source control '$ConnectionId' and branch '$Branch'."
    }
}

function Get-RemoteBranchHead {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Branch
    )

    $reference = @(git ls-remote --heads origin "refs/heads/$Branch")
    if ($LASTEXITCODE -ne 0 -or $reference.Count -ne 1) {
        throw "Failed to resolve the remote head for branch '$Branch'."
    }

    return [string] ($reference[0] -split '\s+', 2)[0]
}

function New-DeploymentState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConnectionId,

        [Parameter(Mandatory = $true)]
        [string] $Branch,

        [Parameter(Mandatory = $true)]
        [string] $Commit,

        [string] $LastSuccessfulRunId,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $PendingPaths
    )

    return [ordered]@{
        version = 1
        sourceControlId = $ConnectionId
        trackedBranch = $Branch
        lastObservedCommit = $Commit
        lastAttemptRunId = $env:GITHUB_RUN_ID
        lastSuccessfulRunId = $LastSuccessfulRunId
        pendingTemplates = @(
            $PendingPaths | ForEach-Object {
                [ordered]@{
                    path = $_
                    lastAttemptRunId = $env:GITHUB_RUN_ID
                }
            }
        )
    }
}
