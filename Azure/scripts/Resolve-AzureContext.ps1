#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-DeployContextUnixPermissions {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Mode
    )
    if ($IsWindows) {
        return
    }
    & chmod $Mode $Path
    if ($LASTEXITCODE -ne 0) {
        throw "chmod $Mode failed for '$Path' (exit $LASTEXITCODE); refusing to continue with unverified permissions."
    }
}

function Get-DeployRuntimeStateDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    return Join-Path $RepositoryRoot 'runtime/state'
}

function Initialize-DeployRuntimeStateDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-DeployContextUnixPermissions -Path $Path -Mode '700'
}

function Get-DeployActiveAzureContext {

    [CmdletBinding()]
    param()
    return Get-AzContext -ErrorAction SilentlyContinue
}

function Assert-DeployAzureContextUsable {
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Context)
    if ($null -eq $Context -or $null -eq $Context.Subscription -or $null -eq $Context.Tenant -or
        [string]::IsNullOrWhiteSpace([string]$Context.Subscription.Id) -or
        [string]::IsNullOrWhiteSpace([string]$Context.Tenant.Id)) {
        throw 'No active Azure PowerShell session was found. Run `Connect-AzAccount` (and, if your account has access to more than one subscription, `Select-AzSubscription -SubscriptionId <id>`) in this shell, then rerun `./deploy.ps1 -UsersCsv ...`. This command never signs in and never guesses among subscriptions on your behalf.'
    }
}

function Resolve-DeploySubscriptionAndTenant {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$SubscriptionId,
        [AllowEmptyString()][string]$TenantId
    )
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId) -and -not [string]::IsNullOrWhiteSpace($TenantId)) {
        return [pscustomobject]@{ SubscriptionId = $SubscriptionId; TenantId = $TenantId; AutoDerived = $false }
    }
    $context = Get-DeployActiveAzureContext
    Assert-DeployAzureContextUsable -Context $context
    return [pscustomobject]@{
        SubscriptionId = [string]$context.Subscription.Id
        TenantId       = [string]$context.Tenant.Id
        AutoDerived    = $true
    }
}

function Resolve-DeployStateAdministratorObjectId {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$StateAdministratorObjectId)

    if ($null -ne $StateAdministratorObjectId -and $StateAdministratorObjectId.Count -gt 0) {
        return [pscustomobject]@{ ObjectIds = @($StateAdministratorObjectId); AutoDerived = $false }
    }
    try {
        $signedIn = Get-AzADUser -SignedIn -ErrorAction Stop
    }
    catch {
        throw "Could not resolve the signed-in operator's object ID via ``Get-AzADUser -SignedIn`` ($($_.Exception.Message)). This usually means there is no active Az PowerShell session, or the signed-in principal is a service principal (not a user) or lacks Microsoft Entra directory-read permission. Supply -StateAdministratorObjectId explicitly (advanced usage) to bypass this lookup."
    }
    if ($null -eq $signedIn -or [string]::IsNullOrWhiteSpace([string]$signedIn.Id)) {
        throw 'Could not resolve the signed-in operator object ID (empty result from Get-AzADUser -SignedIn). Supply -StateAdministratorObjectId explicitly (advanced usage) to bypass this lookup.'
    }
    return [pscustomobject]@{ ObjectIds = @([string]$signedIn.Id); AutoDerived = $true }
}

function Select-DeployInitialUpnDomain {
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Tenant)

    if ($null -eq $Tenant) {
        return $null
    }
    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$Tenant.DefaultDomain)) {
        $candidates.Add([string]$Tenant.DefaultDomain)
    }
    foreach ($domain in @($Tenant.Domains)) {
        $value = [string]$domain
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $candidates.Add($value)
        }
    }

    $onmicrosoft = @($candidates | Where-Object { $_ -imatch '\.onmicrosoft\.com$' } | Sort-Object -Unique)
    if ($onmicrosoft.Count -gt 0) {

        return @($onmicrosoft | Sort-Object Length)[0]
    }
    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }
    return $null
}

function Resolve-DeployUpnDomain {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$UpnDomain,
        [Parameter(Mandatory)][string]$TenantId
    )
    if (-not [string]::IsNullOrWhiteSpace($UpnDomain)) {
        if ($UpnDomain -match '[@\s]') {
            throw "UpnDomain must not contain '@' or whitespace."
        }
        return [pscustomobject]@{ UpnDomain = $UpnDomain; AutoDerived = $false }
    }
    try {
        $tenant = Get-AzTenant -TenantId $TenantId -ErrorAction Stop
    }
    catch {
        throw "Could not resolve the tenant's UPN domain via ``Get-AzTenant`` ($($_.Exception.Message)). Supply -UpnDomain explicitly (advanced usage) to bypass this lookup."
    }
    $domain = Select-DeployInitialUpnDomain -Tenant $tenant
    if ([string]::IsNullOrWhiteSpace($domain)) {
        throw "Could not derive a UPN domain from tenant '$TenantId' (no *.onmicrosoft.com domain was reported by Get-AzTenant). Supply -UpnDomain explicitly (advanced usage)."
    }
    return [pscustomobject]@{ UpnDomain = $domain; AutoDerived = $true }
}

function Test-DeployNameSeedValue {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -eq $Value.Trim()) -and
    ($Value.Length -ge 8) -and ($Value -cne 'change-me-with-a-non-secret-stable-seed')
}

function Get-DeployDerivedNameSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes("$($SubscriptionId.ToLowerInvariant()):$($TenantId.ToLowerInvariant()):name-seed")
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return "ts-$($hash.Substring(0, 12))"
}

function ConvertTo-DeployNormalizedContextId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value.Trim().ToLowerInvariant()
}

function Get-DeployNameSeedRecordPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    return Join-Path (Get-DeployRuntimeStateDirectory -RepositoryRoot $RepositoryRoot) 'name-seed.json'
}

function Get-DeployLegacyNameSeedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    return Join-Path (Get-DeployRuntimeStateDirectory -RepositoryRoot $RepositoryRoot) 'name-seed.txt'
}

function Write-DeployNameSeedRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$NameSeed
    )
    $record = [ordered]@{
        subscription_id = ConvertTo-DeployNormalizedContextId -Value $SubscriptionId
        tenant_id       = ConvertTo-DeployNormalizedContextId -Value $TenantId
        name_seed       = $NameSeed
    }
    ($record | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $Path -Encoding utf8 -NoNewline
    Set-DeployContextUnixPermissions -Path $Path -Mode '600'
}

function Read-DeployNameSeedRecord {

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
        throw "Persisted NameSeed record at '$Path' is invalid or corrupt (not valid JSON: $($_.Exception.Message)). Remove the file (a fresh stable seed will be derived and persisted for this context on the next run) or supply -NameSeed explicitly."
    }

    $subscriptionId = if ($null -ne $parsed.PSObject.Properties['subscription_id']) { [string]$parsed.subscription_id } else { '' }
    $tenantId = if ($null -ne $parsed.PSObject.Properties['tenant_id']) { [string]$parsed.tenant_id } else { '' }
    $nameSeed = if ($null -ne $parsed.PSObject.Properties['name_seed']) { [string]$parsed.name_seed } else { '' }

    if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($tenantId) -or -not (Test-DeployNameSeedValue -Value $nameSeed)) {
        throw "Persisted NameSeed record at '$Path' is invalid or corrupt (missing/blank subscription_id or tenant_id, or an invalid name_seed). Remove the file (a fresh stable seed will be derived and persisted for this context on the next run) or supply -NameSeed explicitly."
    }

    return [pscustomobject]@{
        SubscriptionId = ConvertTo-DeployNormalizedContextId -Value $subscriptionId
        TenantId       = ConvertTo-DeployNormalizedContextId -Value $tenantId
        NameSeed       = $nameSeed
    }
}

function Resolve-DeployNameSeed {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$NameSeed,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $stateDirectory = Get-DeployRuntimeStateDirectory -RepositoryRoot $RepositoryRoot
    Initialize-DeployRuntimeStateDirectory -Path $stateDirectory
    $recordPath = Get-DeployNameSeedRecordPath -RepositoryRoot $RepositoryRoot
    $legacyPath = Get-DeployLegacyNameSeedPath -RepositoryRoot $RepositoryRoot
    $normalizedSubscriptionId = ConvertTo-DeployNormalizedContextId -Value $SubscriptionId
    $normalizedTenantId = ConvertTo-DeployNormalizedContextId -Value $TenantId

    $record = Read-DeployNameSeedRecord -Path $recordPath

    if (-not [string]::IsNullOrWhiteSpace($NameSeed)) {

        if ($null -ne $record) {
            if (($record.SubscriptionId -cne $normalizedSubscriptionId) -or ($record.TenantId -cne $normalizedTenantId)) {
                throw "Persisted NameSeed record at '$recordPath' belongs to a different Azure context (persisted subscription '$($record.SubscriptionId)' / tenant '$($record.TenantId)'; current subscription '$normalizedSubscriptionId' / tenant '$normalizedTenantId'). Refusing to overwrite it with the explicitly supplied -NameSeed for a different context -- this file only ever tracks one context's seed at a time, and Azure Storage account names derived from it are globally unique. If you switched context by mistake, run \`Select-AzSubscription\` back to the persisted subscription/tenant; if you intend to permanently move to this new context, remove or rename '$recordPath' first (this explicit -NameSeed will then be persisted for the new context) only after independently confirming the old context's own resources are no longer needed under that recorded seed."
            }
            if ($record.NameSeed -cne $NameSeed) {
                throw "Persisted NameSeed record at '$recordPath' already records a different NameSeed ('$($record.NameSeed)') for this exact subscription/tenant context than the one just supplied explicitly ('$NameSeed'). Refusing to silently overwrite it: a later run that omits -NameSeed (most importantly a simple '-DestroyAll') reads this persisted record to find the already-deployed backend/resources, so overwriting it here would silently orphan whatever was created under the recorded seed. To safely repeat this exact explicit seed, rerun with -NameSeed '$($record.NameSeed)' instead (the one already on record); to intentionally switch to '$NameSeed', first fully destroy everything created under the recorded seed's context (for example '-DestroyAll -NameSeed $($record.NameSeed)'), then remove '$recordPath' and rerun with the new -NameSeed."
            }

            Set-DeployContextUnixPermissions -Path $recordPath -Mode '600'
            return [pscustomobject]@{ NameSeed = $NameSeed; AutoDerived = $false; PersistedPath = $recordPath }
        }

        Write-DeployNameSeedRecord -Path $recordPath -SubscriptionId $SubscriptionId -TenantId $TenantId -NameSeed $NameSeed
        return [pscustomobject]@{ NameSeed = $NameSeed; AutoDerived = $false; PersistedPath = $recordPath }
    }

    if ($null -ne $record) {
        if (($record.SubscriptionId -ceq $normalizedSubscriptionId) -and ($record.TenantId -ceq $normalizedTenantId)) {

            Set-DeployContextUnixPermissions -Path $recordPath -Mode '600'
            return [pscustomobject]@{ NameSeed = $record.NameSeed; AutoDerived = $true; PersistedPath = $recordPath }
        }
        throw "Persisted NameSeed record at '$recordPath' belongs to a different Azure context (persisted subscription '$($record.SubscriptionId)' / tenant '$($record.TenantId)'; current subscription '$normalizedSubscriptionId' / tenant '$normalizedTenantId'). Refusing to silently reuse a seed derived for a different subscription/tenant -- Azure Storage account names derived from it are globally unique across all of Azure. If you switched context by mistake, run \`Select-AzSubscription\` back to the persisted subscription/tenant; if you intend to permanently move to this new context, remove or rename '$recordPath' (a fresh seed will then be derived and persisted for it); or supply -NameSeed explicitly to pin a specific value for this run."
    }

    if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
        $legacyValue = (Get-Content -LiteralPath $legacyPath -Raw -Encoding utf8).Trim()
        $deterministicForThisContext = Get-DeployDerivedNameSeed -SubscriptionId $SubscriptionId -TenantId $TenantId
        if ((Test-DeployNameSeedValue -Value $legacyValue) -and ($legacyValue -ceq $deterministicForThisContext)) {
            Write-DeployNameSeedRecord -Path $recordPath -SubscriptionId $SubscriptionId -TenantId $TenantId -NameSeed $legacyValue
            Remove-Item -LiteralPath $legacyPath -Force
            return [pscustomobject]@{ NameSeed = $legacyValue; AutoDerived = $true; PersistedPath = $recordPath }
        }
        throw "Found a legacy, context-unbound NameSeed file at '$legacyPath' whose value does not match this subscription/tenant's own deterministic derivation, so it cannot be safely migrated or reused -- it may have been derived for a different Azure context, or hand-edited/corrupted, and this file alone carries no subscription/tenant record to verify that against. Remove '$legacyPath' if it is no longer needed (a fresh seed will be derived and persisted for this context instead), or supply -NameSeed '<the value inside that file>' explicitly if you have independently confirmed it is correct for this context."
    }

    $derived = Get-DeployDerivedNameSeed -SubscriptionId $SubscriptionId -TenantId $TenantId
    Write-DeployNameSeedRecord -Path $recordPath -SubscriptionId $SubscriptionId -TenantId $TenantId -NameSeed $derived
    return [pscustomobject]@{ NameSeed = $derived; AutoDerived = $true; PersistedPath = $recordPath }
}

function Select-DeployNewestRockyImageVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Images)

    $parsed = foreach ($image in $Images) {
        $versionText = [string]$image.Version
        if ([string]::IsNullOrWhiteSpace($versionText)) {
            continue
        }
        $sortable = $null
        if ([version]::TryParse($versionText, [ref]$sortable)) {
            [pscustomobject]@{ Text = $versionText; Sortable = $sortable }
        }
        else {
            [pscustomobject]@{ Text = $versionText; Sortable = $null }
        }
    }
    $parsable = @($parsed | Where-Object { $null -ne $_.Sortable } | Sort-Object -Property Sortable -Descending)
    if ($parsable.Count -gt 0) {
        return $parsable[0].Text
    }
    $fallback = @($parsed | Sort-Object -Property Text -Descending)
    if ($fallback.Count -gt 0) {
        return $fallback[0].Text
    }
    return $null
}

function Resolve-DeployRockyImageVersion {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$RockyImageVersion,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Offer,
        [Parameter(Mandatory)][string]$Sku
    )
    if (-not [string]::IsNullOrWhiteSpace($RockyImageVersion)) {
        return [pscustomobject]@{ Version = $RockyImageVersion; AutoDerived = $false }
    }
    try {
        $images = @(Get-AzVMImage -Location $Location -PublisherName $Publisher -Offer $Offer -Skus $Sku -ErrorAction Stop)
    }
    catch {
        throw "Could not list Rocky Linux images ($Publisher/$Offer/$Sku in $Location) via ``Get-AzVMImage`` ($($_.Exception.Message)). Supply -RockyImageVersion explicitly (advanced usage), or verify the image is available in this subscription/region and that its Marketplace terms have already been reviewed by an operator -- this command never accepts Marketplace terms automatically."
    }
    $newest = Select-DeployNewestRockyImageVersion -Images $images
    if ([string]::IsNullOrWhiteSpace($newest)) {
        throw "No Rocky Linux 10 image version is available for publisher '$Publisher', offer '$Offer', SKU '$Sku' in location '$Location'. Verify the publisher/offer/SKU are still correct and that this subscription has reviewed/accepted the image's Marketplace terms (this command never accepts them automatically); or supply -RockyImageVersion explicitly."
    }
    return [pscustomobject]@{ Version = $newest; AutoDerived = $true }
}

function Resolve-DeploySimpleContext {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$SubscriptionId,
        [AllowEmptyString()][string]$TenantId,
        [AllowEmptyCollection()][string[]]$StateAdministratorObjectId,
        [AllowEmptyString()][string]$UpnDomain,
        [AllowEmptyString()][string]$NameSeed,
        [AllowEmptyString()][string]$RockyImageVersion,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$RockyImagePublisher,
        [Parameter(Mandatory)][string]$RockyImageOffer,
        [Parameter(Mandatory)][string]$RockyImageSku,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $subscriptionAndTenant = Resolve-DeploySubscriptionAndTenant -SubscriptionId $SubscriptionId -TenantId $TenantId
    $administrator = Resolve-DeployStateAdministratorObjectId -StateAdministratorObjectId $StateAdministratorObjectId
    $upn = Resolve-DeployUpnDomain -UpnDomain $UpnDomain -TenantId $subscriptionAndTenant.TenantId

    $seedResolution = Resolve-DeployNameSeed -NameSeed $NameSeed -SubscriptionId $subscriptionAndTenant.SubscriptionId `
        -TenantId $subscriptionAndTenant.TenantId -RepositoryRoot $RepositoryRoot
    $imageResolution = Resolve-DeployRockyImageVersion -RockyImageVersion $RockyImageVersion -Location $Location `
        -Publisher $RockyImagePublisher -Offer $RockyImageOffer -Sku $RockyImageSku

    return [ordered]@{
        SubscriptionId                 = $subscriptionAndTenant.SubscriptionId
        TenantId                       = $subscriptionAndTenant.TenantId
        SubscriptionTenantAutoDerived  = $subscriptionAndTenant.AutoDerived
        StateAdministratorObjectId     = $administrator.ObjectIds
        StateAdministratorAutoDerived  = $administrator.AutoDerived
        UpnDomain                      = $upn.UpnDomain
        UpnDomainAutoDerived           = $upn.AutoDerived
        NameSeed                       = $seedResolution.NameSeed
        NameSeedAutoDerived            = $seedResolution.AutoDerived
        NameSeedPersistedPath          = $seedResolution.PersistedPath
        RockyImageVersion              = $imageResolution.Version
        RockyImageVersionAutoDerived   = $imageResolution.AutoDerived
    }
}

function Get-DeployEntraManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    return Join-Path (Get-DeployRuntimeStateDirectory -RepositoryRoot $RepositoryRoot) 'entra-users.json'
}

function Read-DeployEntraManifest {

    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Entra user manifest at '$Path' is invalid or corrupt (not valid JSON: $($_.Exception.Message)). Refusing to use it to decide which Entra users may be deleted; repair or remove it only after independently reconciling which users this script previously created."
    }

    $recordSubscriptionId = if ($null -ne $parsed.PSObject.Properties['subscription_id']) { [string]$parsed.subscription_id } else { '' }
    $recordTenantId = if ($null -ne $parsed.PSObject.Properties['tenant_id']) { [string]$parsed.tenant_id } else { '' }

    $usersRaw = $null
    if ($null -ne $parsed.PSObject.Properties['users']) {
        $usersRaw = @($parsed.users)
    }

    if ([string]::IsNullOrWhiteSpace($recordSubscriptionId) -or [string]::IsNullOrWhiteSpace($recordTenantId) -or $null -eq $usersRaw) {
        throw "Entra user manifest at '$Path' is invalid or corrupt (missing subscription_id, tenant_id, or users). Refusing to use it to decide which Entra users may be deleted."
    }

    $normalizedSubscriptionId = ConvertTo-DeployNormalizedContextId -Value $SubscriptionId
    $normalizedTenantId = ConvertTo-DeployNormalizedContextId -Value $TenantId
    $normalizedRecordSubscriptionId = ConvertTo-DeployNormalizedContextId -Value $recordSubscriptionId
    $normalizedRecordTenantId = ConvertTo-DeployNormalizedContextId -Value $recordTenantId

    if (($normalizedRecordSubscriptionId -cne $normalizedSubscriptionId) -or ($normalizedRecordTenantId -cne $normalizedTenantId)) {
        throw "Entra user manifest at '$Path' belongs to a different Azure context (persisted subscription '$normalizedRecordSubscriptionId' / tenant '$normalizedRecordTenantId'; current subscription '$normalizedSubscriptionId' / tenant '$normalizedTenantId'). Refusing to use it -- this would risk deleting the wrong subscription/tenant's Entra users, or silently ignoring this context's own script-created users. If you switched context by mistake, run \`Select-AzSubscription\` back to the persisted subscription/tenant; otherwise resolve this by hand before rerunning."
    }

    $entries = [Collections.Generic.List[pscustomobject]]::new()
    foreach ($user in $usersRaw) {
        $upn = if ($null -ne $user.PSObject.Properties['upn']) { [string]$user.upn } else { '' }
        $objectId = if ($null -ne $user.PSObject.Properties['object_id']) { [string]$user.object_id } else { '' }
        $slug = if ($null -ne $user.PSObject.Properties['slug']) { [string]$user.slug } else { '' }
        $role = if ($null -ne $user.PSObject.Properties['role']) { [string]$user.role } else { '' }
        if ([string]::IsNullOrWhiteSpace($upn) -or [string]::IsNullOrWhiteSpace($objectId)) {
            throw "Entra user manifest at '$Path' has an entry missing upn or object_id. Refusing to use it to decide which Entra users may be deleted."
        }
        $entries.Add([pscustomobject]@{ Upn = $upn; ObjectId = $objectId; Slug = $slug; Role = $role })
    }
    return @($entries)
}

function Write-DeployEntraManifestRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Users
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Set-DeployContextUnixPermissions -Path $directory -Mode '700'

    $record = [ordered]@{
        subscription_id = ConvertTo-DeployNormalizedContextId -Value $SubscriptionId
        tenant_id       = ConvertTo-DeployNormalizedContextId -Value $TenantId
        users           = @($Users | ForEach-Object {
                [ordered]@{ upn = $_.Upn; object_id = $_.ObjectId; slug = $_.Slug; role = $_.Role }
            })
    }

    $tempPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        ($record | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tempPath -Encoding utf8 -NoNewline
        Set-DeployContextUnixPermissions -Path $tempPath -Mode '600'
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
    Set-DeployContextUnixPermissions -Path $Path -Mode '600'
}

function Add-DeployEntraManifestEntry {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$ObjectId,
        [AllowEmptyString()][string]$Slug = '',
        [AllowEmptyString()][string]$Role = ''
    )

    $path = Get-DeployEntraManifestPath -RepositoryRoot $RepositoryRoot
    $existing = @(Read-DeployEntraManifest -Path $path -SubscriptionId $SubscriptionId -TenantId $TenantId)
    $withoutThisUpn = @($existing | Where-Object { $_.Upn -ine $Upn })
    $updated = @($withoutThisUpn) + [pscustomobject]@{ Upn = $Upn; ObjectId = $ObjectId; Slug = $Slug; Role = $Role }
    Write-DeployEntraManifestRecord -Path $path -SubscriptionId $SubscriptionId -TenantId $TenantId -Users $updated
}

function Remove-DeployEntraManifestEntry {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Upn
    )

    $path = Get-DeployEntraManifestPath -RepositoryRoot $RepositoryRoot
    $existing = @(Read-DeployEntraManifest -Path $path -SubscriptionId $SubscriptionId -TenantId $TenantId)
    $updated = @($existing | Where-Object { $_.Upn -ine $Upn })
    Write-DeployEntraManifestRecord -Path $path -SubscriptionId $SubscriptionId -TenantId $TenantId -Users $updated
}

function Get-DeployEntraUserByUpn {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Upn)
    try {
        return Get-AzADUser -UserPrincipalName $Upn -ErrorAction Stop
    }
    catch {
        throw "Could not look up Entra user '$Upn' via ``Get-AzADUser`` ($($_.Exception.Message)). This usually means there is no active Az PowerShell session, or the signed-in principal lacks Microsoft Entra directory-read permission (Directory Readers, or a role that includes User.Read.All)."
    }
}

function Resolve-DeployEntraDeletionDecision {

    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$CurrentUser,
        [Parameter(Mandatory)][string]$ExpectedObjectId
    )

    if ($null -eq $CurrentUser -or [string]::IsNullOrWhiteSpace([string]$CurrentUser.Id)) {
        return 'absent'
    }
    if ([string]$CurrentUser.Id -ieq $ExpectedObjectId) {
        return 'delete'
    }
    return 'mismatch'
}

function Remove-DeployManifestTrackedEntraUsers {

    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $manifestPath = Get-DeployEntraManifestPath -RepositoryRoot $RepositoryRoot
    $entries = @(Read-DeployEntraManifest -Path $manifestPath -SubscriptionId $SubscriptionId -TenantId $TenantId)
    $results = [Collections.Generic.List[pscustomobject]]::new()

    foreach ($entry in $entries) {
        $current = $null
        try {
            $current = Get-DeployEntraUserByUpn -Upn $entry.Upn
        }
        catch {
            $results.Add([pscustomobject]@{ Upn = $entry.Upn; Status = 'lookup_failed'; Detail = $_.Exception.Message })
            continue
        }

        $decision = Resolve-DeployEntraDeletionDecision -CurrentUser $current -ExpectedObjectId $entry.ObjectId
        switch ($decision) {
            'absent' {
                Remove-DeployEntraManifestEntry -RepositoryRoot $RepositoryRoot -SubscriptionId $SubscriptionId -TenantId $TenantId -Upn $entry.Upn
                $results.Add([pscustomobject]@{ Upn = $entry.Upn; Status = 'already_removed' })
            }
            'delete' {
                try {
                    Remove-AzADUser -ObjectId $entry.ObjectId -Confirm:$false -ErrorAction Stop
                    Remove-DeployEntraManifestEntry -RepositoryRoot $RepositoryRoot -SubscriptionId $SubscriptionId -TenantId $TenantId -Upn $entry.Upn
                    $results.Add([pscustomobject]@{ Upn = $entry.Upn; Status = 'deleted' })
                }
                catch {
                    $results.Add([pscustomobject]@{ Upn = $entry.Upn; Status = 'delete_failed'; Detail = $_.Exception.Message })
                }
            }
            'mismatch' {
                $results.Add([pscustomobject]@{ Upn = $entry.Upn; Status = 'object_id_mismatch_skipped' })
            }
        }
    }

    return @($results)
}

function Get-DeployEntraUserExistence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Upn)
    try {
        $user = Get-AzADUser -UserPrincipalName $Upn -ErrorAction Stop
    }
    catch {
        throw "Could not look up Entra user '$Upn' via ``Get-AzADUser`` ($($_.Exception.Message)). This usually means there is no active Az PowerShell session, or the signed-in principal lacks Microsoft Entra directory-read permission (Directory Readers, or a role that includes User.Read.All)."
    }
    return ($null -ne $user) -and (-not [string]::IsNullOrWhiteSpace([string]$user.Id))
}

function Get-DeployMissingEntraUsers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Users)

    $existing = [Collections.Generic.List[pscustomobject]]::new()
    $missing = [Collections.Generic.List[pscustomobject]]::new()
    foreach ($user in $Users) {
        if (Get-DeployEntraUserExistence -Upn $user.Upn) {
            $existing.Add($user)
        }
        else {
            $missing.Add($user)
        }
    }
    return [pscustomobject]@{ Existing = @($existing); Missing = @($missing) }
}

function ConvertTo-DeployDisplayNameFromSlug {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Slug)
    $words = @($Slug -split '-' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
            if ($_.Length -le 1) { $_.ToUpperInvariant() } else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
        })
    return ($words -join ' ')
}

function ConvertTo-DeployMailNickname {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Slug)
    $nickname = ($Slug -replace '[^a-z0-9]', '')
    if ($nickname.Length -gt 64) {
        $nickname = $nickname.Substring(0, 64)
    }
    return $nickname
}

function New-DeployMissingEntraUsers {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$MissingUsers,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $created = [Collections.Generic.List[string]]::new()
    foreach ($user in $MissingUsers) {
        Write-Host "Creating missing Entra user '$($user.Upn)' ($($user.Role))."
        $securePassword = Read-Host -Prompt "  Temporary password for '$($user.Upn)' (input hidden; must be changed at next sign-in)" -AsSecureString
        $newUser = $null
        try {
            if ($null -eq $securePassword -or $securePassword.Length -eq 0) {
                throw "A temporary password is required to create '$($user.Upn)'."
            }
            $newUser = New-AzADUser -DisplayName (ConvertTo-DeployDisplayNameFromSlug -Slug $user.Slug) `
                -UserPrincipalName $user.Upn `
                -MailNickname (ConvertTo-DeployMailNickname -Slug $user.Slug) `
                -Password $securePassword `
                -ForceChangePasswordNextLogin `
                -AccountEnabled $true `
                -ErrorAction Stop
        }
        catch {
            throw "Could not create Entra user '$($user.Upn)' via ``New-AzADUser`` ($($_.Exception.Message)). This usually means the signed-in principal lacks the Entra User Administrator (or equivalent) role, or the tenant's password policy rejected the supplied temporary password."
        }
        finally {
            $securePassword = $null
        }
        if ($null -eq $newUser -or [string]::IsNullOrWhiteSpace([string]$newUser.Id)) {
            throw "New-AzADUser did not return an immutable object ID for '$($user.Upn)'; refusing to continue without one to track for safe future -DestroyAll deletion. The account may already exist in Entra -- verify by hand before retrying."
        }
        Add-DeployEntraManifestEntry -RepositoryRoot $RepositoryRoot -SubscriptionId $SubscriptionId -TenantId $TenantId `
            -Upn $user.Upn -ObjectId ([string]$newUser.Id) -Slug $user.Slug -Role $user.Role
        $created.Add($user.Upn)
    }
    return @($created)
}

function Get-DeployAzureErrorHint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $hints = [Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @($hints)
    }
    if ($Text -imatch 'provider_not_registered|MissingSubscriptionRegistration|is not registered to use namespace|SubscriptionNotRegistered') {
        $hints.Add("HINT: a required resource provider (typically Microsoft.Resources, Microsoft.Storage, and/or Microsoft.Authorization) is not registered on this subscription. This command never registers providers automatically (AGENTS.md); ask an operator to run ``Register-AzResourceProvider -ProviderNamespace <Microsoft.Xxx>`` explicitly after reviewing the change, then rerun.")
    }
    if ($Text -imatch 'QuotaExceeded|OverconstrainedAllocationRequest|AllocationFailed|SkuNotAvailable|NotAvailableForSubscription|exceeding approved.*quota') {
        $hints.Add('HINT: this looks like a quota/capacity limit (vCPU quota, a SKU not offered in this region/zone, or a temporary capacity shortage). Try a different -Location, request a quota increase in the Azure Portal, or retry later; this command never changes quotas.')
    }
    if ($Text -imatch 'RequestDisallowedByAzure|is currently not accepting new customers|disallowed by Azure|location.*polic(y|ies)|not an allowed location|Resource.*was disallowed by policy') {
        $hints.Add('HINT: a subscription/management-group policy (or Azure regional capacity control) is blocking resource creation in the resolved region -- typically "RequestDisallowedByAzure: selected region is currently not accepting new customers" or an "Allowed locations"-style Deny policy. This command never registers providers, changes policy, or requests quota. After confirming no deployment still depends on runtime/state/deployment-profile.json, remove that record and rerun so scripts/Resolve-AzureDeploymentProfile.ps1 can evaluate the candidate regions again.')
    }
    if ($Text -imatch 'Authorization_RequestDenied|Insufficient privileges|AADSTS650056|AADSTS53003|does not have permission to (create|update|read)|Forbidden|state_admin_rbac_missing') {
        $hints.Add('HINT: the signed-in principal lacks the Microsoft Entra/Azure RBAC permission this step needs (typically the User Administrator directory role to create users, Directory Readers to look up UPNs/domains, or Storage Blob Data Contributor once the state account exists). Ask a directory/subscription administrator to grant it, or supply the affected value explicitly (-StateAdministratorObjectId/-UpnDomain) to skip the lookup.')
    }
    if ($Text -imatch "platform image .* is not available|image sku.*is not available|The Offer information for the following was not found") {
        $hints.Add("HINT: Azure reports the pinned Rocky Linux image is not available for this subscription/region. Confirm this subscription has already reviewed/accepted the image's Marketplace terms (Azure Portal, or ``Get-AzMarketplaceTerms``/``Set-AzMarketplaceTerms`` -- this command never runs those automatically), or rerun to re-resolve the newest available -RockyImageVersion.")
    }
    if ($Text -imatch 'az_context_mismatch') {
        $hints.Add('HINT: the active Az PowerShell session does not match the resolved -SubscriptionId/-TenantId. Run `Select-AzSubscription -SubscriptionId <id>` to switch the active session to match, or rerun without -SubscriptionId/-TenantId so they are re-derived from whatever session is active.')
    }
    if ($Text -imatch 'required_az_module_missing') {
        $hints.Add('HINT: a required Az PowerShell module is missing. Install it, for example `Install-Module Az.Accounts, Az.Resources, Az.Storage, Az.Compute, Az.Network -Scope CurrentUser`.')
    }
    return @($hints)
}
