# Content deployment script version: 1.0.0+af43c81018a634a394b32d954de5f242ced9f856

param(
    [Parameter(Mandatory = $true)]
    [string]$TemplateFile,

    [string]$TemplateParameterFile,

    [Parameter(Mandatory = $true)]
    [string]$DeploymentName,

    [Parameter(Mandatory = $true)]
    [string]$DeploymentScopeId,

    [string]$WorkspaceId,

    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('CustomDetection', 'DefenderWorkbook')]
    [string[]]$ContentTypes,

    [string]$SkippedPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SupportedContentTypes = @{
    CustomDetection = @('Microsoft.Security/detectionRules')
    DefenderWorkbook = @('Microsoft.Security/workbooks')
}

function Get-CompiledTemplate {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::GetExtension($Path) -ieq '.bicep') {
        $compiledPath = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString('n')).json"
        try {
            az bicep build --file $Path --outfile $compiledPath
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to compile Bicep template '$Path'."
            }

            return @{
                Path = $Path
                CompiledPath = $compiledPath
                Temporary = $true
            }
        }
        catch {
            Remove-Item -LiteralPath $compiledPath -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    return @{
        Path = $Path
        CompiledPath = $Path
        Temporary = $false
    }
}

function Test-SupportedContentType {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [object]$Template
    )

    if ($null -eq $Template) {
        $Template = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
    }
    $resourceProperty = $Template.PSObject.Properties['resources']
    if ($null -eq $resourceProperty -or $null -eq $resourceProperty.Value) {
        Write-Warning "Skipping '$TemplatePath': no supported content resources found."
        return $false
    }

    $languageVersion = $Template.PSObject.Properties['languageVersion']
    $resources = @(
        if ($null -ne $languageVersion -and $languageVersion.Value -eq '2.0') {
            $resourceProperty.Value.PSObject.Properties.Value
        }
        else {
            $resourceProperty.Value
        }
    )

    if ($resources.Count -eq 0) {
        Write-Warning "Skipping '$TemplatePath': no supported content resources found."
        return $false
    }

    $supportedResourceTypes = @($ContentTypes | ForEach-Object { $script:SupportedContentTypes[$_] })
    foreach ($resource in $resources) {
        $typeProperty = if ($null -eq $resource) { $null } else { $resource.PSObject.Properties['type'] }
        $resourceType = if ($null -eq $typeProperty) { '' } else { ([string]$typeProperty.Value).Split('@')[0] }
        if ($resourceType -notin $supportedResourceTypes) {
            Write-Warning "Skipping '$TemplatePath': resource type '$resourceType' is not in the supported content types ($($script:SupportedContentTypes.Keys -join ', '))."
            return $false
        }
    }

    return $true
}

function Get-CompiledParameterFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::GetExtension($Path) -ine '.bicepparam') {
        return @{
            Path = $Path
            Temporary = $false
        }
    }

    $compiledPath = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString('n')).parameters.json"
    try {
        az bicep build-params --file $Path --outfile $compiledPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to compile Bicep parameter file '$Path'."
        }

        return @{
            Path = $compiledPath
            Temporary = $true
        }
    }
    catch {
        Remove-Item -LiteralPath $compiledPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-ConfiguredDeploymentScope {
    param(
        [Parameter(Mandatory = $true)][string]$ScopeId,
        [string]$WorkspaceId
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse($WorkspaceId, [ref]$parsedId) -or $parsedId -eq [guid]::Empty) {
            throw "Workspace ID '$WorkspaceId' must be a non-empty GUID."
        }
    }

    if (
        $ScopeId -match
        '^/providers/Microsoft\.Management/managementGroups/[^/]+$'
    ) {
        if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
            throw 'A workspace ID requires a resource-group deployment scope.'
        }
        return 'ManagementGroup'
    }

    if (
        $ScopeId -match
        '^/subscriptions/[^/]+/resourceGroups/[^/]+$'
    ) {
        if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
            throw 'A resource-group deployment scope requires a workspace ID.'
        }
        return 'ResourceGroup'
    }

    throw "Deployment scope '$ScopeId' must be a resource-group or management-group resource ID."
}

function Get-ManagementGroupName {
    param([Parameter(Mandatory = $true)][string]$ScopeId)

    $match = [regex]::Match(
        $ScopeId,
        '^/providers/Microsoft\.Management/managementGroups/(?<name>[^/]+)$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) {
        throw "Deployment scope '$ScopeId' is not a valid management-group resource ID."
    }

    return $match.Groups['name'].Value
}

function Get-ResourceGroupTarget {
    param([Parameter(Mandatory = $true)][string]$ScopeId)

    $match = [regex]::Match(
        $ScopeId,
        '^/subscriptions/(?<subscription>[^/]+)/resourceGroups/(?<resourceGroup>[^/]+)$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) {
        throw "Deployment scope '$ScopeId' is not a valid resource-group resource ID."
    }

    return @{
        SubscriptionId = $match.Groups['subscription'].Value
        ResourceGroupName = $match.Groups['resourceGroup'].Value
    }
}

function Add-TemplateParameterFile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Parameters,
        [string]$ParameterFile
    )

    if (-not [string]::IsNullOrWhiteSpace($ParameterFile)) {
        $Parameters.TemplateParameterFile = $ParameterFile
    }
}

function Get-DeploymentErrorText {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )

    $messages = [Collections.Generic.List[string]]::new()
    if (
        $null -ne $ErrorRecord.ErrorDetails -and
        -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)
    ) {
        $messages.Add($ErrorRecord.ErrorDetails.Message)
    }

    $exception = $ErrorRecord.Exception
    $azureErrors = [Collections.Generic.Queue[object]]::new()
    while ($null -ne $exception) {
        if (-not [string]::IsNullOrWhiteSpace($exception.Message)) {
            $messages.Add($exception.Message)
        }

        $bodyProperty = $exception.PSObject.Properties['Body']
        if ($null -ne $bodyProperty -and $null -ne $bodyProperty.Value) {
            $azureErrors.Enqueue($bodyProperty.Value)
        }

        $exception = $exception.InnerException
    }

    while ($azureErrors.Count -gt 0) {
        $azureError = $azureErrors.Dequeue()
        $codeProperty = $azureError.PSObject.Properties['Code']
        $messageProperty = $azureError.PSObject.Properties['Message']
        $code = if ($null -eq $codeProperty) { '' } else { [string]$codeProperty.Value }
        $message = if ($null -eq $messageProperty) { '' } else { [string]$messageProperty.Value }
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $messages.Add($(if ([string]::IsNullOrWhiteSpace($code)) { $message } else { "$code - $message" }))
        }

        $detailsProperty = $azureError.PSObject.Properties['Details']
        if ($null -ne $detailsProperty) {
            foreach ($detail in @($detailsProperty.Value)) {
                if ($null -ne $detail) {
                    $azureErrors.Enqueue($detail)
                }
            }
        }
    }

    return @($messages.Where({ -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Unique) -join "`n"
}

function New-ContentDeployment {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ManagementGroup', 'ResourceGroup')]
        [string]$Scope,
        [Parameter(Mandatory = $true)][string]$ScopeId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [string]$ParameterFile,
        [Parameter(Mandatory = $true)][string]$DeploymentLocation,
        [string]$WorkspaceName,
        [bool]$TemplateDeclaresWorkspace
    )

    if ($Scope -eq 'ManagementGroup') {
        $parameters = @{
            Name = $Name
            ManagementGroupId = Get-ManagementGroupName $ScopeId
            Location = $DeploymentLocation
            TemplateFile = $TemplatePath
        }
        Add-TemplateParameterFile $parameters $ParameterFile
        New-AzManagementGroupDeployment @parameters
        return
    }

    $target = Get-ResourceGroupTarget $ScopeId
    Set-AzContext -SubscriptionId $target.SubscriptionId | Out-Null
    $parameters = @{
        Name = $Name
        ResourceGroupName = $target.ResourceGroupName
        TemplateFile = $TemplatePath
    }
    Add-TemplateParameterFile $parameters $ParameterFile
    if ($TemplateDeclaresWorkspace -and -not [string]::IsNullOrWhiteSpace($WorkspaceName)) {
        $parameters.workspace = $WorkspaceName
    }
    New-AzResourceGroupDeployment @parameters
}

function Test-RetryableDeploymentFailure {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ManagementGroup', 'ResourceGroup')]
        [string]$Scope,
        [Parameter(Mandatory = $true)][string]$ScopeId,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $retryableStatusCodes = @('Conflict', 'TooManyRequests', 'InternalServerError', 'DeploymentActive')
    try {
        if ($Scope -eq 'ManagementGroup') {
            $operations = Get-AzManagementGroupDeploymentOperation `
                -ManagementGroupId (Get-ManagementGroupName $ScopeId) `
                -DeploymentName $Name `
                -ErrorAction Stop
        }
        else {
            $target = Get-ResourceGroupTarget $ScopeId
            $operations = Get-AzResourceGroupDeploymentOperation `
                -ResourceGroupName $target.ResourceGroupName `
                -DeploymentName $Name `
                -ErrorAction Stop
        }

        return @($operations).Where({ $_.StatusCode -in $retryableStatusCodes }).Count -gt 0
    }
    catch {
        return $false
    }
}

function Invoke-ContentDeploymentWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ManagementGroup', 'ResourceGroup')]
        [string]$Scope,
        [Parameter(Mandatory = $true)][string]$ScopeId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [string]$ParameterFile,
        [Parameter(Mandatory = $true)][string]$DeploymentLocation,
        [string]$WorkspaceName,
        [bool]$TemplateDeclaresWorkspace
    )

    $maximumAttempts = 3
    $secondsBetweenAttempts = 5
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            New-ContentDeployment `
                -Scope $Scope `
                -ScopeId $ScopeId `
                -Name $Name `
                -TemplatePath $TemplatePath `
                -ParameterFile $ParameterFile `
                -DeploymentLocation $DeploymentLocation `
                -WorkspaceName $WorkspaceName `
                -TemplateDeclaresWorkspace $TemplateDeclaresWorkspace
            return
        }
        catch {
            if ($attempt -eq $maximumAttempts -or -not (Test-RetryableDeploymentFailure $Scope $ScopeId $Name)) {
                throw
            }

            Write-Warning "Deployment '$Name' failed with a transient Azure status. Retrying in $secondsBetweenAttempts seconds (attempt $($attempt + 1) of $maximumAttempts)."
            Start-Sleep -Seconds $secondsBetweenAttempts
        }
    }
}

function Invoke-ContentDeployment {
    $compiledTemplate = $null
    $compiledParameters = $null
    try {
        $scope = Get-ConfiguredDeploymentScope -ScopeId $DeploymentScopeId -WorkspaceId $WorkspaceId
        $compiledTemplate = Get-CompiledTemplate -Path $TemplateFile
        $template = Get-Content -LiteralPath $compiledTemplate.CompiledPath -Raw | ConvertFrom-Json -Depth 100
        if (-not (Test-SupportedContentType -Path $compiledTemplate.CompiledPath -TemplatePath $TemplateFile -Template $template)) {
            if (-not [string]::IsNullOrWhiteSpace($SkippedPath)) {
                Set-Content -LiteralPath $SkippedPath -Value 'Skipped'
            }
            return
        }
        $templateParameters = $template.PSObject.Properties['parameters']
        $declaresWorkspace = $null -ne $templateParameters -and
            $null -ne $templateParameters.Value -and
            $null -ne $templateParameters.Value.PSObject.Properties['workspace']
        $compiledParameters = Get-CompiledParameterFile $TemplateParameterFile

        Invoke-ContentDeploymentWithRetry `
            -Scope $scope `
            -ScopeId $DeploymentScopeId `
            -Name $DeploymentName `
            -TemplatePath $compiledTemplate.Path `
            -ParameterFile $compiledParameters.Path `
            -DeploymentLocation $Location `
            -WorkspaceName $WorkspaceName `
            -TemplateDeclaresWorkspace $declaresWorkspace
    }
    catch {
        $errorText = Get-DeploymentErrorText $_
        throw [InvalidOperationException]::new($errorText, $_.Exception)
    }
    finally {
        if ($null -ne $compiledTemplate -and $compiledTemplate.Temporary) {
            Remove-Item -LiteralPath $compiledTemplate.CompiledPath -Force -ErrorAction SilentlyContinue
        }

        if ($null -ne $compiledParameters -and $compiledParameters.Temporary) {
            Remove-Item -LiteralPath $compiledParameters.Path -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ContentDeployment
}
