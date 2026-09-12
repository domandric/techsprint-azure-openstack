#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DeployRegionShortNameMap {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return [ordered]@{
        westeurope    = 'weu'
        swedencentral = 'swc'
    }
}

function Get-DeployCandidateRegions {

    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @('swedencentral')
}

function Get-DeployCandidateVmSkus {

    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @('Standard_B2s', 'Standard_B2als_v2', 'Standard_D2als_v6')
}

function Get-DeployRequiredProviderNamespaces {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.DBforMySQL')
}

function ConvertTo-DeployNormalizedRegionName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return ($Value -replace '\s', '').ToLowerInvariant()
}

function Resolve-DeployRegionShortName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [AllowEmptyString()][string]$Override
    )
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override
    }
    $map = Get-DeployRegionShortNameMap
    $normalized = ConvertTo-DeployNormalizedRegionName -Value $Location
    foreach ($key in $map.Keys) {
        if ((ConvertTo-DeployNormalizedRegionName -Value $key) -eq $normalized) {
            return [string]$map[$key]
        }
    }
    throw "No known short location suffix for location '$Location' (known: $(($map.Keys) -join ', ')). Supply -LocationShortName explicitly (advanced usage), or add it to Get-DeployRegionShortNameMap in scripts/Resolve-AzureDeploymentProfile.ps1 (and the matching entry in infra/azure/modules/naming/main.tf)."
}

function ConvertTo-DeploySkuCapabilityHashtable {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Capabilities)
    $result = @{}
    foreach ($capability in @($Capabilities)) {
        $name = [string]$capability.Name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $result[$name] = [string]$capability.Value
        }
    }
    return $result
}

function ConvertTo-DeploySkuInfo {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RawSku,
        [Parameter(Mandatory)][string]$Location
    )

    $normalizedLocation = ConvertTo-DeployNormalizedRegionName -Value $Location
    $locationInfo = @(@($RawSku.LocationInfo) | Where-Object { (ConvertTo-DeployNormalizedRegionName -Value ([string]$_.Location)) -eq $normalizedLocation })

    $zones = @(if ($locationInfo.Count -gt 0) { @($locationInfo[0].Zones | ForEach-Object { [string]$_ }) } else { @() })
    $capabilities = ConvertTo-DeploySkuCapabilityHashtable -Capabilities $RawSku.Capabilities

    $restrictions = [Collections.Generic.List[string]]::new()
    foreach ($restriction in @($RawSku.Restrictions)) {
        $restrictionLocations = @(@($restriction.RestrictionInfo.Locations) | ForEach-Object { ConvertTo-DeployNormalizedRegionName -Value ([string]$_) })
        if ($restrictionLocations.Count -eq 0 -or $restrictionLocations -contains $normalizedLocation) {
            $reasonCode = [string]$restriction.ReasonCode
            if (-not [string]::IsNullOrWhiteSpace($reasonCode)) {
                $restrictions.Add($reasonCode)
            }
        }
    }

    $vCpus = 0
    [void][int]::TryParse(($capabilities['vCPUs']), [ref]$vCpus)
    $memoryGb = 0.0
    [void][double]::TryParse(($capabilities['MemoryGB']), [ref]$memoryGb)

    $familyProperty = $RawSku.PSObject.Properties['Family']
    $family = if ($null -ne $familyProperty -and $null -ne $familyProperty.Value) { [string]$familyProperty.Value } else { '' }

    return [pscustomobject]@{
        Name         = [string]$RawSku.Name
        Location     = $Location
        VCpus        = $vCpus
        MemoryGb     = $memoryGb
        Zones        = @($zones)
        Restrictions = @($restrictions)
        Family       = $family
    }
}

function Test-DeploySkuMeetsHardwareRequirements {

    [CmdletBinding()]
    param([Parameter(Mandatory)]$SkuInfo)

    if ([string]$SkuInfo.Name -ieq 'Standard_B2ats_v2') {
        return $false
    }
    if ([int]$SkuInfo.VCpus -lt 2) {
        return $false
    }
    if ([double]$SkuInfo.MemoryGb -lt 4) {
        return $false
    }
    $zones = @($SkuInfo.Zones)
    if (-not ($zones -contains '1') -or -not ($zones -contains '2')) {
        return $false
    }
    $blockingRestrictions = @($SkuInfo.Restrictions | Where-Object {
            $_ -imatch 'NotAvailableForSubscription|NotAvailableForSubscription_DueToCapacityRestrictions|NotAvailableForSubscription_DueToRegistration'
        })
    if ($blockingRestrictions.Count -gt 0) {
        return $false
    }
    return $true
}

function Get-DeployRequiredFleetVCpus {

    [CmdletBinding()]
    [OutputType([int])]
    param()
    return 12
}

function Get-DeployRegionalCoresUsageName {

    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'cores'
}

function Get-DeployVmUsage {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Location)
    return @(Get-AzVMUsage -Location $Location -ErrorAction Stop)
}

function Find-DeployVmUsageEntry {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawUsage,
        [Parameter(Mandatory)][string]$Name
    )
    foreach ($entry in @($RawUsage)) {
        if ($null -eq $entry) {
            continue
        }
        $nameProperty = $entry.PSObject.Properties['Name']
        if ($null -eq $nameProperty -or $null -eq $nameProperty.Value) {
            continue
        }
        $valueProperty = $nameProperty.Value.PSObject.Properties['Value']
        if ($null -eq $valueProperty) {
            continue
        }
        if ([string]$valueProperty.Value -ieq $Name) {
            return $entry
        }
    }
    return $null
}

function Get-DeployAvailableQuota {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawUsage,
        [Parameter(Mandatory)][string]$Name
    )
    $entry = Find-DeployVmUsageEntry -RawUsage $RawUsage -Name $Name
    if ($null -eq $entry) {
        return $null
    }
    $limit = 0
    $current = 0
    $limitOk = [int]::TryParse([string]$entry.Limit, [ref]$limit)
    $currentOk = [int]::TryParse([string]$entry.CurrentValue, [ref]$current)
    if (-not $limitOk -or -not $currentOk) {
        return $null
    }
    return [int]($limit - $current)
}

function Test-DeploySkuQuotaSufficient {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawUsage,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SkuFamily,
        [Parameter(Mandatory)][int]$RequiredVCpus
    )

    if ([string]::IsNullOrWhiteSpace($SkuFamily)) {
        return [pscustomobject]@{
            Sufficient = $false
            Reason     = 'SKU family name could not be determined from Get-AzComputeResourceSku (missing .Family); quota cannot be safely verified'
        }
    }

    $regionalAvailable = Get-DeployAvailableQuota -RawUsage $RawUsage -Name (Get-DeployRegionalCoresUsageName)
    if ($null -eq $regionalAvailable) {
        return [pscustomobject]@{
            Sufficient = $false
            Reason     = "regional 'Total Regional vCPUs' (cores) quota usage could not be determined"
        }
    }
    if ($regionalAvailable -lt $RequiredVCpus) {
        return [pscustomobject]@{
            Sufficient = $false
            Reason     = "regional vCPU quota has only $regionalAvailable available, need $RequiredVCpus for the 6-VM fleet"
        }
    }

    $familyAvailable = Get-DeployAvailableQuota -RawUsage $RawUsage -Name $SkuFamily
    if ($null -eq $familyAvailable) {
        return [pscustomobject]@{
            Sufficient = $false
            Reason     = "SKU family '$SkuFamily' quota usage could not be determined"
        }
    }
    if ($familyAvailable -lt $RequiredVCpus) {
        return [pscustomobject]@{
            Sufficient = $false
            Reason     = "SKU family '$SkuFamily' quota has only $familyAvailable available, need $RequiredVCpus for the 6-VM fleet"
        }
    }

    return [pscustomobject]@{ Sufficient = $true; Reason = $null }
}

function Find-DeployApprovedSkuForRegion {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawSkus,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string[]]$CandidateVmSkus,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawVmUsage,
        [Parameter(Mandatory)][int]$RequiredVCpus,
        [Parameter()][ref]$RejectionReasons
    )
    foreach ($skuName in $CandidateVmSkus) {
        if ($skuName -ieq 'Standard_B2ats_v2') {
            continue
        }
        $matches = @($RawSkus | Where-Object {
                [string]$_.Name -ieq $skuName -and (
                    [string]::IsNullOrWhiteSpace([string]$_.ResourceType) -or [string]$_.ResourceType -ieq 'virtualMachines'
                )
            })
        if ($matches.Count -eq 0) {
            if ($null -ne $RejectionReasons) { $RejectionReasons.Value += "${skuName}: not offered in this region" }
            continue
        }
        $info = ConvertTo-DeploySkuInfo -RawSku $matches[0] -Location $Location
        if (-not (Test-DeploySkuMeetsHardwareRequirements -SkuInfo $info)) {
            if ($null -ne $RejectionReasons) { $RejectionReasons.Value += "${skuName}: does not meet the 2 vCPU / 4 GiB / zone 1+2 / no-restriction hardware requirement" }
            continue
        }
        $quota = Test-DeploySkuQuotaSufficient -RawUsage $RawVmUsage -SkuFamily $info.Family -RequiredVCpus $RequiredVCpus
        if (-not $quota.Sufficient) {
            if ($null -ne $RejectionReasons) { $RejectionReasons.Value += "${skuName}: $($quota.Reason)" }
            continue
        }
        return $info
    }
    return $null
}

function Resolve-DeployPolicyRuleValue {
    [CmdletBinding()]
    param(
        [Parameter()]$Value,
        [Parameter()][AllowNull()][hashtable]$ParameterValues
    )
    if ($Value -is [string] -and $Value -match "^\[parameters\('([^']+)'\)\]$") {
        $name = $Matches[1]
        if ($null -ne $ParameterValues -and $ParameterValues.ContainsKey($name)) {
            return $ParameterValues[$name]
        }
    }
    return $Value
}

function Test-DeployPolicyConditionDeniesLocation {

    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Condition,
        [Parameter(Mandatory)][string]$NormalizedLocation,
        [Parameter()][AllowNull()][hashtable]$ParameterValues
    )
    if ($null -eq $Condition) {
        return $false
    }

    foreach ($combinatorName in @('allOf', 'anyOf')) {
        $property = $Condition.PSObject.Properties[$combinatorName]
        if ($null -ne $property -and $null -ne $property.Value) {
            $results = @(@($property.Value) | ForEach-Object {
                    Test-DeployPolicyConditionDeniesLocation -Condition $_ -NormalizedLocation $NormalizedLocation -ParameterValues $ParameterValues
                })
            if ($combinatorName -eq 'allOf') {
                return ($results.Count -gt 0) -and (@($results | Where-Object { -not $_ }).Count -eq 0)
            }
            return @($results | Where-Object { $_ }).Count -gt 0
        }
    }

    $notProperty = $Condition.PSObject.Properties['not']
    if ($null -ne $notProperty -and $null -ne $notProperty.Value) {
        return -not (Test-DeployPolicyConditionDeniesLocation -Condition $notProperty.Value -NormalizedLocation $NormalizedLocation -ParameterValues $ParameterValues)
    }

    $fieldProperty = $Condition.PSObject.Properties['field']
    if ($null -eq $fieldProperty -or [string]$fieldProperty.Value -ine 'location') {
        return $false
    }

    $equalsProperty = $Condition.PSObject.Properties['equals']
    if ($null -ne $equalsProperty) {
        $value = ConvertTo-DeployNormalizedRegionName -Value ([string](Resolve-DeployPolicyRuleValue -Value $equalsProperty.Value -ParameterValues $ParameterValues))
        return $value -eq $NormalizedLocation
    }
    $notEqualsProperty = $Condition.PSObject.Properties['notEquals']
    if ($null -ne $notEqualsProperty) {
        $value = ConvertTo-DeployNormalizedRegionName -Value ([string](Resolve-DeployPolicyRuleValue -Value $notEqualsProperty.Value -ParameterValues $ParameterValues))
        return $value -ne $NormalizedLocation
    }
    $inProperty = $Condition.PSObject.Properties['in']
    if ($null -ne $inProperty) {
        $resolved = Resolve-DeployPolicyRuleValue -Value $inProperty.Value -ParameterValues $ParameterValues
        $values = @(@($resolved) | ForEach-Object { ConvertTo-DeployNormalizedRegionName -Value ([string]$_) })
        return $values -contains $NormalizedLocation
    }
    $notInProperty = $Condition.PSObject.Properties['notIn']
    if ($null -ne $notInProperty) {
        $resolved = Resolve-DeployPolicyRuleValue -Value $notInProperty.Value -ParameterValues $ParameterValues
        $values = @(@($resolved) | ForEach-Object { ConvertTo-DeployNormalizedRegionName -Value ([string]$_) })
        return -not ($values -contains $NormalizedLocation)
    }
    return $false
}

function Test-DeployPolicyRuleDeniesLocation {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$PolicyRule,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][AllowNull()][hashtable]$ParameterValues
    )
    if ($null -eq $PolicyRule) {
        return $false
    }
    $thenProperty = $PolicyRule.PSObject.Properties['then']
    if ($null -eq $thenProperty -or $null -eq $thenProperty.Value) {
        return $false
    }
    $effect = [string](Resolve-DeployPolicyRuleValue -Value $thenProperty.Value.effect -ParameterValues $ParameterValues)
    if ($effect -ine 'deny') {
        return $false
    }
    $ifProperty = $PolicyRule.PSObject.Properties['if']
    if ($null -eq $ifProperty) {
        return $false
    }
    $normalizedLocation = ConvertTo-DeployNormalizedRegionName -Value $Location
    return Test-DeployPolicyConditionDeniesLocation -Condition $ifProperty.Value -NormalizedLocation $normalizedLocation -ParameterValues $ParameterValues
}

function Get-DeployPolicyAssignments {

    [CmdletBinding()]
    param()
    try {
        return @(Get-AzPolicyAssignment -ErrorAction Stop)
    }
    catch {
        return @()
    }
}

function Get-DeployPolicyDefinitionRule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PolicyDefinitionId)
    try {
        $definition = Get-AzPolicyDefinition -Id $PolicyDefinitionId -ErrorAction Stop
        return $definition.Properties.PolicyRule
    }
    catch {
        return $null
    }
}

function Test-DeployRegionBlockedByPolicy {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Location)

    $assignments = @(Get-DeployPolicyAssignments)
    foreach ($assignment in $assignments) {
        try {
            $enforcementMode = [string]$assignment.Properties.EnforcementMode
            if (-not [string]::IsNullOrWhiteSpace($enforcementMode) -and $enforcementMode -ieq 'DoNotEnforce') {
                continue
            }
            $definitionId = [string]$assignment.Properties.PolicyDefinitionId
            if ([string]::IsNullOrWhiteSpace($definitionId)) {
                continue
            }
            $rule = Get-DeployPolicyDefinitionRule -PolicyDefinitionId $definitionId
            if ($null -eq $rule) {
                continue
            }
            $parameterValues = @{}
            $parametersProperty = $assignment.Properties.PSObject.Properties['Parameters']
            if ($null -ne $parametersProperty -and $null -ne $parametersProperty.Value) {
                foreach ($parameter in $parametersProperty.Value.PSObject.Properties) {
                    $parameterValues[$parameter.Name] = $parameter.Value.value
                }
            }
            if (Test-DeployPolicyRuleDeniesLocation -PolicyRule $rule -Location $Location -ParameterValues $parameterValues) {
                return [pscustomobject]@{
                    Blocked        = $true
                    AssignmentName = [string]$assignment.Name
                    DisplayName    = [string]$assignment.Properties.DisplayName
                }
            }
        }
        catch {
            continue
        }
    }
    return [pscustomobject]@{ Blocked = $false; AssignmentName = $null; DisplayName = $null }
}

function Get-DeployComputeResourceSkus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Location)
    return @(Get-AzComputeResourceSku -Location $Location -ErrorAction Stop)
}

function Get-DeployResourceProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Namespace)
    return @(Get-AzResourceProvider -ProviderNamespace $Namespace -ErrorAction Stop)
}

function Get-DeployRequiredResourceTypeNamesForNamespace {

    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Namespace)
    switch ($Namespace) {
        'Microsoft.Compute' { return @('virtualMachines') }
        'Microsoft.Network' { return @('virtualNetworks', 'publicIPAddresses', 'applicationGateways', 'privateEndpoints', 'networkInterfaces') }
        'Microsoft.Storage' { return @('storageAccounts', 'storageAccounts/fileServices') }
        'Microsoft.DBforMySQL' { return @('flexibleServers') }
        default { return @() }
    }
}

function ConvertTo-DeployProviderResourceTypeRecords {

    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawProvider)

    $records = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($RawProvider)) {
        if ($null -eq $entry) {
            continue
        }
        $entryRegistrationState = [string]$entry.RegistrationState

        $resourceTypesProperty = $entry.PSObject.Properties['ResourceTypes']

        $nestedTypes = @(if ($null -ne $resourceTypesProperty -and $null -ne $resourceTypesProperty.Value) { @($resourceTypesProperty.Value) } else { @() })

        if ($nestedTypes.Count -gt 0) {
            foreach ($type in $nestedTypes) {
                $typeName = [string]$type.ResourceTypeName
                if ([string]::IsNullOrWhiteSpace($typeName)) {
                    $altNameProperty = $type.PSObject.Properties['ResourceType']
                    if ($null -ne $altNameProperty) { $typeName = [string]$altNameProperty.Value }
                }
                $records.Add([pscustomobject]@{
                        ResourceTypeName  = $typeName
                        RegistrationState = $entryRegistrationState
                        Locations         = @(@($type.Locations) | ForEach-Object { [string]$_ })
                    })
            }
            continue
        }

        $typeName = [string]$entry.ResourceTypeName
        if ([string]::IsNullOrWhiteSpace($typeName)) {
            $altNameProperty = $entry.PSObject.Properties['ResourceType']
            if ($null -ne $altNameProperty) { $typeName = [string]$altNameProperty.Value }
        }
        $locationsProperty = $entry.PSObject.Properties['Locations']

        $locations = @(if ($null -ne $locationsProperty -and $null -ne $locationsProperty.Value) { @(@($locationsProperty.Value) | ForEach-Object { [string]$_ }) } else { @() })
        $records.Add([pscustomobject]@{
                ResourceTypeName  = $typeName
                RegistrationState = $entryRegistrationState
                Locations         = $locations
            })
    }

    return $records.ToArray()
}

function Test-DeployProviderSupportsRegion {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)][string]$Location,
        [AllowEmptyCollection()][string[]]$RequiredResourceTypeNames = @()
    )
    $normalizedLocation = ConvertTo-DeployNormalizedRegionName -Value $Location
    $records = @(ConvertTo-DeployProviderResourceTypeRecords -RawProvider @($Provider))
    if ($records.Count -eq 0) {
        return $false
    }

    if ($RequiredResourceTypeNames.Count -gt 0) {
        $matchedRequired = @($records | Where-Object { $RequiredResourceTypeNames -icontains [string]$_.ResourceTypeName })
        if ($matchedRequired.Count -gt 0) {
            foreach ($requiredName in $RequiredResourceTypeNames) {
                $typeRecords = @($matchedRequired | Where-Object { [string]$_.ResourceTypeName -ieq $requiredName })
                if ($typeRecords.Count -eq 0) {

                    continue
                }
                $locations = @($typeRecords | ForEach-Object { @($_.Locations) } | ForEach-Object { ConvertTo-DeployNormalizedRegionName -Value $_ })
                if ($locations.Count -eq 0) {
                    continue
                }
                if (-not ($locations -contains $normalizedLocation)) {
                    return $false
                }
            }
            return $true
        }

    }

    foreach ($record in $records) {
        $locations = @(@($record.Locations) | ForEach-Object { ConvertTo-DeployNormalizedRegionName -Value $_ })
        if ($locations -contains $normalizedLocation) {
            return $true
        }
    }
    return $false
}

function Test-DeployRegionProvidersReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string[]]$Namespaces
    )
    foreach ($namespace in $Namespaces) {
        try {
            $provider = Get-DeployResourceProvider -Namespace $namespace
        }
        catch {
            return $false
        }

        $records = @(ConvertTo-DeployProviderResourceTypeRecords -RawProvider @($provider))
        if ($records.Count -eq 0) {

            return $false
        }

        $registrationStates = @($records |
                ForEach-Object { [string]$_.RegistrationState } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique)
        if ($registrationStates.Count -eq 0) {
            return $false
        }
        if (@($registrationStates | Where-Object { $_ -ine 'Registered' }).Count -gt 0) {
            return $false
        }

        $requiredTypeNames = Get-DeployRequiredResourceTypeNamesForNamespace -Namespace $namespace
        if (-not (Test-DeployProviderSupportsRegion -Provider $provider -Location $Location -RequiredResourceTypeNames $requiredTypeNames)) {
            return $false
        }
    }
    return $true
}

function Resolve-DeployAutoDeploymentProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$CandidateRegions,
        [Parameter(Mandatory)][string[]]$CandidateVmSkus,
        [Parameter(Mandatory)][string]$RockyImagePublisher,
        [Parameter(Mandatory)][string]$RockyImageOffer,
        [Parameter(Mandatory)][string]$RockyImageSku
    )

    $attempts = [Collections.Generic.List[string]]::new()
    foreach ($region in $CandidateRegions) {
        try {
            $shortName = Resolve-DeployRegionShortName -Location $region -Override ''
        }
        catch {
            $attempts.Add("${region}: no known short location suffix")
            continue
        }

        $policyCheck = Test-DeployRegionBlockedByPolicy -Location $region
        if ($policyCheck.Blocked) {
            $attempts.Add("${region}: blocked by policy assignment '$($policyCheck.DisplayName)' ($($policyCheck.AssignmentName))")
            continue
        }

        if (-not (Test-DeployRegionProvidersReady -Location $region -Namespaces (Get-DeployRequiredProviderNamespaces))) {
            $attempts.Add("${region}: a required resource provider is not registered on this subscription, or does not support this region")
            continue
        }

        $rawSkus = $null
        try {
            $rawSkus = @(Get-DeployComputeResourceSkus -Location $region)
        }
        catch {
            $attempts.Add("${region}: could not list compute SKUs ($($_.Exception.Message))")
            continue
        }

        $rawVmUsage = $null
        try {
            $rawVmUsage = @(Get-DeployVmUsage -Location $region)
        }
        catch {
            $attempts.Add("${region}: could not list VM usage/quota ($($_.Exception.Message)); quota cannot be safely verified")
            continue
        }

        $rejectionReasons = @()
        $approvedSku = Find-DeployApprovedSkuForRegion -RawSkus $rawSkus -Location $region -CandidateVmSkus $CandidateVmSkus `
            -RawVmUsage $rawVmUsage -RequiredVCpus (Get-DeployRequiredFleetVCpus) -RejectionReasons ([ref]$rejectionReasons)
        if ($null -eq $approvedSku) {
            $detail = if ($rejectionReasons.Count -gt 0) { $rejectionReasons -join '; ' } else { "no candidate VM SKU ($($CandidateVmSkus -join ', ')) meets the 2 vCPU / 4 GiB / zone 1+2 / no-restriction / quota requirement for this subscription" }
            $attempts.Add("${region}: $detail")
            continue
        }

        try {
            $imageResolution = Resolve-DeployRockyImageVersion -RockyImageVersion '' -Location $region -Publisher $RockyImagePublisher -Offer $RockyImageOffer -Sku $RockyImageSku
        }
        catch {
            $attempts.Add("${region}: $($_.Exception.Message)")
            continue
        }

        return [pscustomobject]@{
            Location          = $region
            LocationShortName = $shortName
            VmSku             = $approvedSku.Name
            RockyImageVersion = $imageResolution.Version
            Attempts          = @($attempts)
        }
    }

    throw "Could not auto-resolve a deployment region/VM SKU: every candidate region was rejected by this subscription's own read-only checks. Details: $($attempts -join '; '). This command never registers providers, accepts Marketplace terms, or requests quota on your behalf -- request access to a suitable region/SKU/quota for this subscription, then rerun."
}

function Get-DeployDeploymentProfilePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    return Join-Path (Get-DeployRuntimeStateDirectory -RepositoryRoot $RepositoryRoot) 'deployment-profile.json'
}

function Read-DeployDeploymentProfileRecord {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Persisted deployment-profile record at '$Path' is invalid or corrupt (not valid JSON: $($_.Exception.Message)). Restore the correct record, or remove it only after confirming no deployment still depends on it; the next run will resolve and persist a fresh profile."
    }

    $getValue = {
        param($name)
        $property = $parsed.PSObject.Properties[$name]
        if ($null -ne $property) { return [string]$property.Value }
        return ''
    }
    $subscriptionId = & $getValue 'subscription_id'
    $tenantId = & $getValue 'tenant_id'
    $location = & $getValue 'location'
    $locationShortName = & $getValue 'location_short_name'
    $vmSku = & $getValue 'vm_sku'

    if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($tenantId) -or
        [string]::IsNullOrWhiteSpace($location) -or [string]::IsNullOrWhiteSpace($locationShortName) -or
        [string]::IsNullOrWhiteSpace($vmSku)) {
        throw "Persisted deployment-profile record at '$Path' is invalid or corrupt (missing subscription_id, tenant_id, location, location_short_name, or vm_sku). Restore the correct record, or remove it only after confirming no deployment still depends on it; the next run will resolve and persist a fresh profile."
    }

    return [pscustomobject]@{
        SubscriptionId    = ConvertTo-DeployNormalizedContextId -Value $subscriptionId
        TenantId          = ConvertTo-DeployNormalizedContextId -Value $tenantId
        Location          = $location
        LocationShortName = $locationShortName
        VmSku             = $vmSku
        RockyPublisher    = & $getValue 'rocky_publisher'
        RockyOffer        = & $getValue 'rocky_offer'
        RockySku          = & $getValue 'rocky_sku'
        RockyImageVersion = & $getValue 'rocky_image_version'
    }
}

function Write-DeployDeploymentProfileRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$LocationShortName,
        [Parameter(Mandatory)][string]$VmSku,
        [AllowEmptyString()][string]$RockyPublisher = '',
        [AllowEmptyString()][string]$RockyOffer = '',
        [AllowEmptyString()][string]$RockySku = '',
        [AllowEmptyString()][string]$RockyImageVersion = ''
    )
    $record = [ordered]@{
        subscription_id     = ConvertTo-DeployNormalizedContextId -Value $SubscriptionId
        tenant_id           = ConvertTo-DeployNormalizedContextId -Value $TenantId
        location            = $Location
        location_short_name = $LocationShortName
        vm_sku              = $VmSku
        rocky_publisher     = $RockyPublisher
        rocky_offer         = $RockyOffer
        rocky_sku           = $RockySku
        rocky_image_version = $RockyImageVersion
    }
    ($record | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $Path -Encoding utf8 -NoNewline
    Set-DeployContextUnixPermissions -Path $Path -Mode '600'
}

function Remove-DeployDeploymentProfileRecord {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
        return $true
    }
    return $false
}

function Resolve-DeployDeploymentProfile {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [AllowEmptyString()][string]$LocationOverride,
        [AllowEmptyString()][string]$LocationShortNameOverride,
        [AllowEmptyString()][string]$VmSkuOverride,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RockyImagePublisher,
        [Parameter(Mandatory)][string]$RockyImageOffer,
        [Parameter(Mandatory)][string]$RockyImageSku
    )

    $stateDirectory = Get-DeployRuntimeStateDirectory -RepositoryRoot $RepositoryRoot
    Initialize-DeployRuntimeStateDirectory -Path $stateDirectory
    $recordPath = Get-DeployDeploymentProfilePath -RepositoryRoot $RepositoryRoot
    $normalizedSubscriptionId = ConvertTo-DeployNormalizedContextId -Value $SubscriptionId
    $normalizedTenantId = ConvertTo-DeployNormalizedContextId -Value $TenantId
    $record = Read-DeployDeploymentProfileRecord -Path $recordPath

    $hasExplicitLocationOverride = -not [string]::IsNullOrWhiteSpace($LocationOverride)

    if ($hasExplicitLocationOverride) {
        if ([string]::IsNullOrWhiteSpace($VmSkuOverride)) {
            throw "An explicit -Location override requires -VmSku to also be supplied explicitly (advanced usage): once -Location is overridden, auto-selection is skipped entirely, so the VM SKU can no longer be safely auto-derived for it."
        }
        if ($VmSkuOverride -ieq 'Standard_B2ats_v2') {
            throw "VmSku 'Standard_B2ats_v2' has only 1 GiB RAM and never meets this project's 2 vCPU / 4 GiB requirement; supply a different -VmSku."
        }
        $locationShortName = Resolve-DeployRegionShortName -Location $LocationOverride -Override $LocationShortNameOverride
        $imageResolution = Resolve-DeployRockyImageVersion -RockyImageVersion '' -Location $LocationOverride -Publisher $RockyImagePublisher -Offer $RockyImageOffer -Sku $RockyImageSku

        if ($null -ne $record) {
            if (($record.SubscriptionId -cne $normalizedSubscriptionId) -or ($record.TenantId -cne $normalizedTenantId)) {
                throw "Persisted deployment-profile record at '$recordPath' belongs to a different Azure context (persisted subscription '$($record.SubscriptionId)' / tenant '$($record.TenantId)'; current subscription '$normalizedSubscriptionId' / tenant '$normalizedTenantId'). Refusing to overwrite it with an explicit override for a different context; remove or rename '$recordPath' first only after independently confirming the old context's own resources are no longer needed under that recorded profile."
            }
            if (($record.Location -cne $LocationOverride) -or ($record.LocationShortName -cne $locationShortName) -or ($record.VmSku -cne $VmSkuOverride)) {
                throw "Persisted deployment-profile record at '$recordPath' already records a different location/short-name/VM SKU ('$($record.Location)'/'$($record.LocationShortName)'/'$($record.VmSku)') for this exact subscription/tenant context than the one just supplied explicitly ('$LocationOverride'/'$locationShortName'/'$VmSkuOverride'). Refusing to silently drift: a later run that omits these overrides (including -DestroyAll) reads this persisted record to find the already-deployed resources. To intentionally switch, first fully destroy everything created under the recorded profile (-DestroyAll), then remove '$recordPath' and rerun with the new override."
            }
        }
        else {
            Write-DeployDeploymentProfileRecord -Path $recordPath -SubscriptionId $SubscriptionId -TenantId $TenantId -Location $LocationOverride `
                -LocationShortName $locationShortName -VmSku $VmSkuOverride -RockyPublisher $RockyImagePublisher -RockyOffer $RockyImageOffer `
                -RockySku $RockyImageSku -RockyImageVersion $imageResolution.Version
        }
        return [pscustomobject]@{
            Location          = $LocationOverride
            LocationShortName = $locationShortName
            VmSku             = $VmSkuOverride
            RockyImageVersion = $imageResolution.Version
            AutoDerived       = $false
            PersistedPath     = $recordPath
        }
    }

    if ($null -ne $record) {
        if (($record.SubscriptionId -ceq $normalizedSubscriptionId) -and ($record.TenantId -ceq $normalizedTenantId)) {
            Set-DeployContextUnixPermissions -Path $recordPath -Mode '600'
            return [pscustomobject]@{
                Location          = $record.Location
                LocationShortName = $record.LocationShortName
                VmSku             = $record.VmSku
                RockyImageVersion = $record.RockyImageVersion
                AutoDerived       = $true
                PersistedPath     = $recordPath
            }
        }
        throw "Persisted deployment-profile record at '$recordPath' belongs to a different Azure context (persisted subscription '$($record.SubscriptionId)' / tenant '$($record.TenantId)'; current subscription '$normalizedSubscriptionId' / tenant '$normalizedTenantId'). Refusing to silently reuse a profile resolved for a different subscription/tenant. If you switched context by mistake, run \`Select-AzSubscription\` back to the persisted subscription/tenant; if you intend to permanently move to this new context, remove or rename '$recordPath' (a fresh profile will then be resolved and persisted for it)."
    }

    $resolved = Resolve-DeployAutoDeploymentProfile -CandidateRegions (Get-DeployCandidateRegions) -CandidateVmSkus (Get-DeployCandidateVmSkus) `
        -RockyImagePublisher $RockyImagePublisher -RockyImageOffer $RockyImageOffer -RockyImageSku $RockyImageSku
    Write-DeployDeploymentProfileRecord -Path $recordPath -SubscriptionId $SubscriptionId -TenantId $TenantId -Location $resolved.Location `
        -LocationShortName $resolved.LocationShortName -VmSku $resolved.VmSku -RockyPublisher $RockyImagePublisher -RockyOffer $RockyImageOffer `
        -RockySku $RockyImageSku -RockyImageVersion $resolved.RockyImageVersion
    return [pscustomobject]@{
        Location          = $resolved.Location
        LocationShortName = $resolved.LocationShortName
        VmSku             = $resolved.VmSku
        RockyImageVersion = $resolved.RockyImageVersion
        AutoDerived       = $true
        PersistedPath     = $recordPath
    }
}

function Get-DeployStateResourceGroupName {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LocationShortName)
    return "rg-ts-state-testing-$LocationShortName"
}

function Get-DeployResourceGroupByName {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    try {
        return Get-AzResourceGroup -Name $Name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-DeployResourceGroupResourceCount {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceGroupName)
    return @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop).Count
}

function Test-DeployLegacyEmptyStateResourceGroup {

    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$ResourceGroup,
        [Parameter(Mandatory)][int]$ResourceCount,
        [Parameter(Mandatory)][string]$ResolvedStateResourceGroupName
    )
    if ($null -eq $ResourceGroup) {
        return $false
    }
    if ([string]$ResourceGroup.ResourceGroupName -ieq $ResolvedStateResourceGroupName) {
        return $false
    }
    if (-not (Test-DeployCanonicalStateTags -ActualTags $ResourceGroup.Tags)) {
        return $false
    }
    return $ResourceCount -eq 0
}

function Test-DeployCanonicalStateTags {

    [CmdletBinding()]
    param([Parameter()][AllowNull()]$ActualTags)
    if ($null -eq $ActualTags) {
        return $false
    }
    $required = [ordered]@{
        project      = 'techsprint'
        environment  = 'testing'
        owner        = 'shared'
        scope        = 'state'
        'managed-by' = 'terraform'
        cloud        = 'azure'
    }
    foreach ($tag in $required.GetEnumerator()) {
        $found = $false
        $value = $null
        $containsKeyMethod = $ActualTags.PSObject.Methods['ContainsKey']
        if ($null -ne $containsKeyMethod) {
            $found = [bool]$ActualTags.ContainsKey($tag.Key)
            if ($found) { $value = $ActualTags[$tag.Key] }
        }
        elseif ($ActualTags -is [System.Collections.IDictionary]) {
            $asDictionary = [System.Collections.IDictionary]$ActualTags
            $found = $asDictionary.Contains($tag.Key)
            if ($found) { $value = $asDictionary[$tag.Key] }
        }
        else {
            $property = $ActualTags.PSObject.Properties[$tag.Key]
            if ($null -ne $property) { $found = $true; $value = $property.Value }
        }
        if (-not $found -or [string]$value -cne $tag.Value) { return $false }
    }
    return $true
}

function Get-DeployLegacyStateResourceGroupAdvisory {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResolvedStateResourceGroupName)

    $legacyName = 'rg-ts-state-testing-weu'
    if ($legacyName -ieq $ResolvedStateResourceGroupName) {
        return $null
    }
    try {
        $group = Get-DeployResourceGroupByName -Name $legacyName
        if ($null -eq $group) {
            return $null
        }
        $resourceCount = Get-DeployResourceGroupResourceCount -ResourceGroupName $legacyName
        if (-not (Test-DeployLegacyEmptyStateResourceGroup -ResourceGroup $group -ResourceCount $resourceCount -ResolvedStateResourceGroupName $ResolvedStateResourceGroupName)) {
            return $null
        }
    }
    catch {
        return $null
    }

    return "NOTICE (non-blocking): an empty, canonical-tagged Terraform state resource group '$legacyName' already exists in this subscription (left over from an earlier attempt in West Europe, before it was found to be blocked for this subscription -- see docs/architecture/README.md's 'Regional adaptation' section). It contains no storage account and is not used by this run (the resolved backend is '$ResolvedStateResourceGroupName'). This command never deletes it automatically. Once you have independently confirmed it is not needed, remove it by hand, for example: Remove-AzResourceGroup -Name '$legacyName' -Force"
}
