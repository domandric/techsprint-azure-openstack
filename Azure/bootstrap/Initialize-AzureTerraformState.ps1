#requires -Version 7.4

[CmdletBinding(DefaultParameterSetName = 'Preflight', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$NameSeed,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$StateAdministratorObjectId,

    [string]$Location = 'westeurope',
    [ValidatePattern('^[a-z]{2,6}$')][string]$LocationShortName = 'weu',
    [Parameter(ParameterSetName = 'Preflight')][switch]$PreflightOnly,
    [Parameter(ParameterSetName = 'Apply', Mandatory)][switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:FailureCode = 'fail_closed'
$script:FailureDetail = ''

$ResourceGroupName = "rg-ts-state-testing-$LocationShortName"
$ContainerName = 'tfstate'
$RoleName = 'Storage Blob Data Contributor'
$BackendConfigPath = Join-Path $PSScriptRoot 'backend.hcl'
$Tags = @{
    project = 'techsprint'; environment = 'testing'; owner = 'shared'
    scope = 'state'; 'managed-by' = 'terraform'; cloud = 'azure'
}

function Stop-FailClosed {
    param([Parameter(Mandatory)][string]$Code)
    $script:FailureCode = $Code
    throw [System.InvalidOperationException]::new($Code)
}

function Get-SanitizedAzureFailureDetail {

    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $null
    }
    if ($Message -imatch 'RequestDisallowedByAzure') {
        return 'RequestDisallowedByAzure: the target region is currently disallowed for this subscription (commonly a management-group/subscription policy, or Azure regional capacity control). No provider was registered and no quota was requested by this script.'
    }
    if ($Message -imatch 'is currently not accepting new customers') {
        return 'location_not_accepting_new_customers: the target region is not currently accepting new customers for this subscription.'
    }
    if ($Message -imatch 'disallowed by policy|RequestDisallowedByPolicy|PolicyViolation') {
        return 'location_policy_denied: a subscription/management-group policy denied this request (for example an "Allowed locations" restriction).'
    }
    if ($Message -imatch 'QuotaExceeded|OverconstrainedAllocationRequest|AllocationFailed|SkuNotAvailable|NotAvailableForSubscription') {
        return 'sku_or_quota_unavailable: the requested SKU/quota is not available for this subscription/region.'
    }
    return $null
}

function Test-GuidValue {
    param([string]$Value)
    $guid = [guid]::Empty
    return -not [string]::IsNullOrWhiteSpace($Value) -and [guid]::TryParse($Value, [ref]$guid)
}

function Get-StateStorageAccountName {
    param([Parameter(Mandatory)][string]$Seed)
    $bytes = [Text.Encoding]::UTF8.GetBytes("${Seed}:state")
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return "sttsstateb$($hash.Substring(0, 4))"
}

function Test-CanonicalTags {

    param($ActualTags)
    if ($null -eq $ActualTags) { return $false }
    try {
        foreach ($tag in $Tags.GetEnumerator()) {
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
            elseif ($null -ne $ActualTags.PSObject.Properties[$tag.Key]) {
                $found = $true
                $value = $ActualTags.PSObject.Properties[$tag.Key].Value
            }
            if (-not $found -or [string]$value -cne [string]$tag.Value) { return $false }
        }
        return $true
    }
    catch {

        Stop-FailClosed 'canonical_tag_validation_error'
    }
}

function Test-CanonicalStorageAccount {
    param([Parameter(Mandatory)]$Account)
    if ($Account.Kind -ine 'StorageV2' -or $Account.Sku.Name -ine 'Standard_LRS' -or
        $Account.Location -ine $Location -or -not (Test-CanonicalTags $Account.Tags) -or
        $Account.MinimumTlsVersion -ine 'TLS1_2' -or $Account.EnableHttpsTrafficOnly -ne $true -or
        $Account.AllowBlobPublicAccess -ne $false -or $Account.AllowSharedKeyAccess -ne $false -or
        $Account.EnableLocalUser -ne $false -or $Account.EnableSftp -ne $false -or
        $Account.PublicNetworkAccess -ine 'Enabled' -or
        $Account.Encryption.RequireInfrastructureEncryption -ne $true) { return $false }

    $rules = $Account.NetworkRuleSet
    if ($null -eq $rules -or $rules.DefaultAction -ine 'Allow') { return $false }
    return $true
}

function Test-ProviderRegistered {

    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawProvider)

    $records = @($RawProvider)
    if ($records.Count -eq 0) {
        return $false
    }

    $states = @($records |
            ForEach-Object { [string]$_.RegistrationState } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)
    if ($states.Count -eq 0) {
        return $false
    }

    return (@($states | Where-Object { $_ -ine 'Registered' }).Count -eq 0)
}

function Get-MissingRoleAssignments {
    param([Parameter(Mandatory)][string]$Scope, [Parameter(Mandatory)][string[]]$ObjectIds)
    $missing = @()
    foreach ($objectId in $ObjectIds) {
        $assignment = Get-AzRoleAssignment -Scope $Scope -ObjectId $objectId -ErrorAction Stop |
            Where-Object { $_.RoleDefinitionName -ieq $RoleName -and $_.Scope -ieq $Scope } |
            Select-Object -First 1
        if ($null -eq $assignment) { $missing += $objectId }
    }
    return $missing
}

function Get-StorageContext {
    param([Parameter(Mandatory)][string]$AccountName)
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try { return New-AzStorageContext -StorageAccountName $AccountName -UseConnectedAccount -ErrorAction Stop }
        catch {
            if ($attempt -eq 6) { Stop-FailClosed 'storage_oauth_context_unavailable' }
            Start-Sleep -Seconds 10
        }
    }
}

function Get-PrivateContainer {
    param([Parameter(Mandatory)]$Context, [switch]$RequirePresent)
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $matches = @(Get-AzStorageContainer -Context $Context -ErrorAction Stop |
                Where-Object { $_.Name -ceq $ContainerName })
            if ($matches.Count -gt 0) { return $matches[0] }
            if (-not $RequirePresent) { return $null }
        }
        catch {
            if ($attempt -eq 6) { Stop-FailClosed 'storage_oauth_context_unavailable' }
        }
        if ($attempt -eq 6) { Stop-FailClosed 'state_container_post_apply_check_failed' }
        Start-Sleep -Seconds 10
    }
}

function Write-SafeResult {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'BLOCKED', 'WHATIF', 'FAIL')][string]$Status,
        [Parameter(Mandatory)][string]$AccountName,
        [string[]]$Issues = @(), [string]$FailureCode = '', [string]$FailureDetail = ''
    )
    $result = [ordered]@{
        status = $Status; resource_group_name = $ResourceGroupName
        storage_account_name = $AccountName; container_name = $ContainerName
        use_azuread_auth = $true; shared_key_enabled = $false
        location = $Location; location_short_name = $LocationShortName
    }
    if ($Issues.Count -gt 0) { $result.issues = @($Issues | Sort-Object -Unique) }
    if ($FailureCode) { $result.failure_code = $FailureCode }
    if ($FailureDetail) { $result.failure_detail = $FailureDetail }
    $result | ConvertTo-Json -Depth 4
}

if ($MyInvocation.InvocationName -ne '.') {
try {
    if (-not (Test-GuidValue $SubscriptionId)) { Stop-FailClosed 'invalid_subscription_id' }
    if (-not (Test-GuidValue $TenantId)) { Stop-FailClosed 'invalid_tenant_id' }
    if ([string]::IsNullOrWhiteSpace($NameSeed) -or $NameSeed -ne $NameSeed.Trim() -or $NameSeed.Length -lt 8 -or
        $NameSeed -eq 'change-me-with-a-non-secret-stable-seed') { Stop-FailClosed 'invalid_name_seed' }

    $administratorIds = @($StateAdministratorObjectId | ForEach-Object {
        if (-not (Test-GuidValue $_)) { Stop-FailClosed 'invalid_state_administrator_object_id' }
        ([guid]$_).ToString()
    } | Sort-Object -Unique)

    foreach ($command in @('Get-AzContext', 'Get-AzResourceGroup', 'Get-AzResourceProvider', 'Get-AzRoleAssignment', 'Get-AzStorageAccount', 'Get-AzStorageContainer', 'New-AzResourceGroup', 'New-AzRoleAssignment', 'New-AzStorageAccount', 'New-AzStorageContainer', 'New-AzStorageContext', 'Set-AzStorageContainerAcl')) {
        if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) { Stop-FailClosed 'required_az_module_missing' }
    }

    $context = Get-AzContext -ErrorAction Stop
    if ($null -eq $context -or $context.Subscription.Id -ine $SubscriptionId -or $context.Tenant.Id -ine $TenantId) {
        Stop-FailClosed 'az_context_mismatch'
    }
    foreach ($provider in @('Microsoft.Resources', 'Microsoft.Storage', 'Microsoft.Authorization')) {
        $rawProvider = @(Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop)
        if (-not (Test-ProviderRegistered -RawProvider $rawProvider)) {
            Stop-FailClosed 'provider_not_registered'
        }
    }

    $storageAccountName = Get-StateStorageAccountName $NameSeed
    $backendHcl = @(
        "resource_group_name  = `"$ResourceGroupName`""
        "storage_account_name = `"$storageAccountName`""
        "container_name       = `"$ContainerName`""
        'use_azuread_auth     = true'
    ) -join [Environment]::NewLine
    if (Test-Path -LiteralPath $BackendConfigPath) {
        if ((Get-Content -LiteralPath $BackendConfigPath -Raw -ErrorAction Stop) -cne $backendHcl) { Stop-FailClosed 'backend_hcl_conflict' }
    }

    $matchingResourceGroups = @(Get-AzResourceGroup -ErrorAction Stop | Where-Object { $_.ResourceGroupName -ieq $ResourceGroupName })
    $resourceGroup = if ($matchingResourceGroups.Count -eq 0) { $null } else { $matchingResourceGroups[0] }
    if ($null -eq $resourceGroup) {
        $account = $null
    }
    else {
        $matchingStorageAccounts = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Where-Object { $_.StorageAccountName -ieq $storageAccountName })
        $account = if ($matchingStorageAccounts.Count -eq 0) { $null } else { $matchingStorageAccounts[0] }
    }
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
    $issues = @()
    if ($null -eq $resourceGroup) { $issues += 'state_resource_group_missing' }
    elseif ($resourceGroup.Location -ine $Location -or -not (Test-CanonicalTags $resourceGroup.Tags)) { Stop-FailClosed 'resource_group_identity_conflict' }
    if ($null -eq $account) {
        $issues += 'state_storage_account_missing'; $issues += 'state_container_missing'
        $missingRoles = $administratorIds; $container = $null
    }
    elseif (-not (Test-CanonicalStorageAccount $account)) { Stop-FailClosed 'storage_account_identity_conflict' }
    else {
        $missingRoles = @(Get-MissingRoleAssignments $scope $administratorIds)
        $storageContext = Get-StorageContext $storageAccountName
        $container = Get-PrivateContainer $storageContext
        if ($null -eq $container) { $issues += 'state_container_missing' }
        elseif ([string]$container.PublicAccess -ine 'Off') { $issues += 'state_container_public_access_drift' }
    }
    if ($missingRoles.Count -gt 0) { $issues += 'state_admin_rbac_missing' }

    if ($PSCmdlet.ParameterSetName -ne 'Apply') {
        $status = if ($issues.Count -eq 0) { 'PASS' } else { 'BLOCKED' }
        Write-SafeResult -Status $status -AccountName $storageAccountName -Issues $issues
        exit $(if ($status -eq 'PASS') { 0 } else { 2 })
    }

    if ($WhatIfPreference) {
        if ($null -eq $resourceGroup) { [void]$PSCmdlet.ShouldProcess("resource group $ResourceGroupName", 'Create canonical state resource group') }
        if ($null -eq $account) { [void]$PSCmdlet.ShouldProcess("storage account $storageAccountName", 'Create hardened StorageV2 state account') }
        if ($missingRoles.Count -gt 0) { [void]$PSCmdlet.ShouldProcess("storage account $storageAccountName", "Grant $RoleName to requested administrators") }
        [void]$PSCmdlet.ShouldProcess("container $ContainerName", 'Create or set private access through Azure AD')
        if (-not (Test-Path -LiteralPath $BackendConfigPath)) { [void]$PSCmdlet.ShouldProcess($BackendConfigPath, 'Write non-secret backend.hcl') }
        Write-SafeResult -Status 'WHATIF' -AccountName $storageAccountName -Issues $issues
        exit 0
    }

    if ($null -eq $resourceGroup) {
        if (-not $PSCmdlet.ShouldProcess("resource group $ResourceGroupName", 'Create canonical state resource group')) { Stop-FailClosed 'operator_declined_change' }
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $Tags -ErrorAction Stop | Out-Null
    }
    if ($null -eq $account) {
        $networkRuleSet = @{ Bypass = 'AzureServices'; DefaultAction = 'Allow' }
        if (-not $PSCmdlet.ShouldProcess("storage account $storageAccountName", 'Create hardened StorageV2 state account')) { Stop-FailClosed 'operator_declined_change' }
        $account = New-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName -Location $Location -SkuName Standard_LRS -Kind StorageV2 -Tag $Tags -MinimumTlsVersion TLS1_2 -EnableHttpsTrafficOnly $true -RequireInfrastructureEncryption -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false -EnableLocalUser $false -EnableSftp $false -PublicNetworkAccess Enabled -NetworkRuleSet $networkRuleSet -ErrorAction Stop
        if (-not (Test-CanonicalStorageAccount $account)) { Stop-FailClosed 'storage_account_post_create_check_failed' }
    }
    foreach ($objectId in (Get-MissingRoleAssignments $scope $administratorIds)) {
        if (-not $PSCmdlet.ShouldProcess('one requested state administrator', "Grant $RoleName at the storage-account scope")) { Stop-FailClosed 'operator_declined_change' }
        New-AzRoleAssignment -ObjectId $objectId -RoleDefinitionName $RoleName -Scope $scope -ErrorAction Stop | Out-Null
    }

    $storageContext = Get-StorageContext $storageAccountName
    $container = Get-PrivateContainer $storageContext
    if ($null -eq $container) {
        if (-not $PSCmdlet.ShouldProcess("container $ContainerName", 'Create with private access through Azure AD')) { Stop-FailClosed 'operator_declined_change' }
        New-AzStorageContainer -Name $ContainerName -Permission Off -Context $storageContext -ErrorAction Stop | Out-Null
    }
    elseif ([string]$container.PublicAccess -ine 'Off') {
        if (-not $PSCmdlet.ShouldProcess("container $ContainerName", 'Set private access through Azure AD')) { Stop-FailClosed 'operator_declined_change' }
        Set-AzStorageContainerAcl -Name $ContainerName -Permission Off -Context $storageContext -ErrorAction Stop | Out-Null
    }
    $verifiedContainer = Get-PrivateContainer $storageContext -RequirePresent
    if ([string]$verifiedContainer.PublicAccess -ine 'Off') { Stop-FailClosed 'state_container_post_apply_check_failed' }
    if (@(Get-MissingRoleAssignments $scope $administratorIds).Count -gt 0) { Stop-FailClosed 'rbac_assignment_failed' }
    if (-not (Test-Path -LiteralPath $BackendConfigPath)) {
        if (-not $PSCmdlet.ShouldProcess($BackendConfigPath, 'Write non-secret backend.hcl')) { Stop-FailClosed 'operator_declined_change' }
        Set-Content -LiteralPath $BackendConfigPath -Value $backendHcl -Encoding utf8 -NoNewline -ErrorAction Stop
    }

    Write-SafeResult -Status 'PASS' -AccountName $storageAccountName
    exit 0
}
catch {
    $environmentBlockers = @(
        'required_az_module_missing',
        'az_context_mismatch',
        'provider_not_registered',
        'storage_oauth_context_unavailable'
    )

    if ($script:FailureCode -eq 'fail_closed' -and $null -ne $_.Exception -and $_.Exception -isnot [System.InvalidOperationException]) {
        $script:FailureDetail = Get-SanitizedAzureFailureDetail -Message ([string]$_.Exception.Message)
    }
    $status = if ($script:FailureCode -in $environmentBlockers) { 'BLOCKED' } else { 'FAIL' }
    Write-SafeResult -Status $status -AccountName 'not-derived' -FailureCode $script:FailureCode -FailureDetail ([string]$script:FailureDetail)
    exit $(if ($status -eq 'BLOCKED') { 2 } else { 1 })
}
}
