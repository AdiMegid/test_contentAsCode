# Content deployment state script version: 1.0.0+af43c81018a634a394b32d954de5f242ced9f856

function Test-ContentRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $normalizedRoot = $Root.Replace('\', '/').Trim('/')
    return $normalizedRoot -in @('', '.') -or
        $Path.Replace('\', '/').StartsWith("$normalizedRoot/", [StringComparison]::Ordinal)
}

function Test-ArmTemplateJson {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    try {
        $template = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
    }
    catch {
        Write-Warning "Skipping '$Path' because it is not valid JSON."
        return $false
    }

    if ($null -eq $template) {
        return $false
    }

    $schema = $template.PSObject.Properties['$schema']
    return $null -ne $schema -and [string] $schema.Value -match '/(managementGroupDeploymentTemplate|deploymentTemplate)\.json#$'
}

function ConvertFrom-GitNameStatus {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    $changedPaths = [Collections.Generic.List[string]]::new()
    $deletedPaths = [Collections.Generic.List[string]]::new()

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split "`t"
        $status = $parts[0]
        if ($status -match '^[RC]' -and $parts.Count -ge 3) {
            if ($status.StartsWith('R', [StringComparison]::Ordinal)) {
                $deletedPaths.Add($parts[1])
            }

            $changedPaths.Add($parts[2])
            continue
        }

        if ($parts.Count -lt 2) {
            throw "Unexpected git diff entry '$line'."
        }

        if ($status.StartsWith('D', [StringComparison]::Ordinal)) {
            $deletedPaths.Add($parts[1])
        }
        else {
            $changedPaths.Add($parts[1])
        }
    }

    return [pscustomobject]@{
        ChangedPaths = @($changedPaths)
        DeletedPaths = @($deletedPaths)
    }
}

function Get-DeploymentConfig {
    if (Test-Path -LiteralPath 'sentinel-deployment.config' -PathType Leaf) {
        return Get-Content -LiteralPath 'sentinel-deployment.config' -Raw | ConvertFrom-Json
    }

    return $null
}

function Get-ParameterFileMapping {
    param(
        [string] $WorkspaceId,
        [object] $Config
    )

    $mappings = @{}
    if (-not $PSBoundParameters.ContainsKey('Config')) {
        $Config = Get-DeploymentConfig
    }
    if ($null -eq $Config) {
        return $mappings
    }

    $mappingProperty = $Config.PSObject.Properties['parameterfilemappings']
    if ($null -ne $mappingProperty -and $null -ne $mappingProperty.Value) {
        $mappingGroups = @($mappingProperty.Value.PSObject.Properties['default'])
        if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
            $mappingGroups += $mappingProperty.Value.PSObject.Properties[$WorkspaceId]
        }
        foreach ($group in $mappingGroups) {
            if ($null -ne $group -and $null -ne $group.Value) {
                foreach ($entry in $group.Value.PSObject.Properties) {
                    $templatePath = $entry.Name.Replace('\', '/')
                    $parameterPath = ([string] $entry.Value).Replace('\', '/')
                    if ($mappings.ContainsKey($templatePath)) {
                        $mappings[$templatePath] = @($parameterPath, $mappings[$templatePath])
                    }
                    else {
                        $mappings[$templatePath] = $parameterPath
                    }
                }
            }
        }
    }

    return $mappings
}

function Get-DeploymentParameterFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TemplatePath,

        [string] $WorkspaceId,

        [hashtable] $ParameterMappings = @{}
    )

    if ($ParameterMappings.ContainsKey($TemplatePath)) {
        foreach ($mappedPath in @($ParameterMappings[$TemplatePath])) {
            if (Test-Path -LiteralPath $mappedPath -PathType Leaf) {
                return $mappedPath
            }
        }
    }

    $extension = [IO.Path]::GetExtension($TemplatePath)
    $prefix = $TemplatePath.Substring(0, $TemplatePath.Length - $extension.Length)
    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
        if ($extension -ieq '.bicep') {
            $candidates.Add("$prefix-$WorkspaceId.bicepparam")
        }
        $candidates.Add("$prefix.parameters-$WorkspaceId.json")
    }

    if ($extension -ieq '.bicep') {
        $candidates.Add("$prefix.bicepparam")
    }
    $candidates.Add("$prefix.parameters.json")

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Get-ParameterTemplatePaths {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $WorkspaceId,
        [hashtable] $ParameterMappings = @{}
    )

    $templates = [Collections.Generic.List[string]]::new()
    foreach ($template in $ParameterMappings.Keys) {
        if ($Path -in @($ParameterMappings[$template])) {
            $templates.Add($template)
        }
    }

    $prefix = $null
    if ($Path.EndsWith('.bicepparam', [StringComparison]::OrdinalIgnoreCase)) {
        $prefix = $Path.Substring(0, $Path.Length - '.bicepparam'.Length)
        if (-not [string]::IsNullOrWhiteSpace($WorkspaceId) -and
            $prefix.EndsWith("-$WorkspaceId", [StringComparison]::OrdinalIgnoreCase)) {
            $prefix = $prefix.Substring(0, $prefix.Length - $WorkspaceId.Length - 1)
        }
        $templates.Add("$prefix.bicep")
    }
    elseif ($Path -match '^(?<prefix>.+)\.parameters(?:-(?<workspace>[^/]+))?\.json$') {
        if (-not $Matches.ContainsKey('workspace') -or
            $Matches['workspace'] -eq $WorkspaceId) {
            $prefix = $Matches.prefix
            $templates.Add("$prefix.bicep")
            $templates.Add("$prefix.json")
        }
    }

    return $templates.ToArray()
}

function Get-EligibleTemplateFiles {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Paths,

        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        if ((Test-ContentRoot -Path $path -Root $Root) -and
            (Test-Path -LiteralPath $path -PathType Leaf) -and
            ([IO.Path]::GetExtension($path) -ieq '.bicep' -or
            (Test-ArmTemplateJson -Path $path)) -and
            $seen.Add($path)) {
            $path
        }
    }
}

function Get-DeploymentCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ChangedPaths,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $DeletedPaths,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $PendingPaths,

        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [bool] $DeployAll,

        [string] $WorkspaceId
    )

    $config = Get-DeploymentConfig
    $prioritizedPaths = @()
    $excludedPaths = @()
    if ($null -ne $config) {
        $priorityProperty = $config.PSObject.Properties['prioritizedcontentfiles']
        $exclusionProperty = $config.PSObject.Properties['excludecontentfiles']
        if ($null -ne $priorityProperty -and $null -ne $priorityProperty.Value) {
            $prioritizedPaths = @($priorityProperty.Value | ForEach-Object { ([string] $_).Replace('\', '/') })
        }
        if ($null -ne $exclusionProperty -and $null -ne $exclusionProperty.Value) {
            $excludedPaths = @($exclusionProperty.Value | ForEach-Object { ([string] $_).Replace('\', '/') })
        }
    }

    $candidatePaths = [Collections.Generic.List[string]]::new()
    if ($DeployAll) {
        $trackedFiles = @(git ls-files -- '*.bicep' '*.json')
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to enumerate deployment templates.'
        }

        $candidatePaths.AddRange([string[]] $trackedFiles)
    }
    else {
        $parameterMappings = Get-ParameterFileMapping -WorkspaceId $WorkspaceId -Config $config
        foreach ($path in @($ChangedPaths) + @($DeletedPaths)) {
            $parameterTemplates = @(Get-ParameterTemplatePaths `
                -Path $path -WorkspaceId $WorkspaceId -ParameterMappings $parameterMappings)
            if ($parameterTemplates.Count -gt 0) {
                foreach ($template in $parameterTemplates) {
                    $candidatePaths.Add($template)
                }
                continue
            }

            if ($ChangedPaths -contains $path) {
                $candidatePaths.Add($path)
            }
        }

        foreach ($path in $PendingPaths) {
            $candidatePaths.Add($path)
        }
    }

    $orderedPaths = [Collections.Generic.List[string]]::new()
    foreach ($path in $prioritizedPaths) {
        if ($candidatePaths.Contains($path)) {
            $orderedPaths.Add($path)
        }
    }
    foreach ($path in @($candidatePaths | Sort-Object -Unique)) {
        if ($path -notin $excludedPaths -or $path -in $prioritizedPaths) {
            $orderedPaths.Add($path)
        }
    }

    return Get-EligibleTemplateFiles -Paths $orderedPaths.ToArray() -Root $Root
}
