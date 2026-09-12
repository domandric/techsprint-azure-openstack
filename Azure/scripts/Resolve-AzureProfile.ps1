#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Azure cmdlets are deliberately not called by name in this file.  A function or
# alias with an Az-looking name is an input, not an implementation of an Azure
# operation.  Resolve the implementation once and invoke that CommandInfo.
function Get-AzureTrustedCommandInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ModuleName
    )

    $commands = @(Microsoft.PowerShell.Core\Get-Command -Name $Name -All -ErrorAction SilentlyContinue)
    if ($commands.Count -ne 1) {
        throw "Azure interface '$Name' is missing or ambiguous; expected exactly one command owned by '$ModuleName' (found $($commands.Count)). Refusing a shadowed or unavailable Azure interface."
    }

    $command = $commands[0]
    if ($command.CommandType -ne [System.Management.Automation.CommandTypes]::Cmdlet -or
        [string]::IsNullOrWhiteSpace([string]$command.ModuleName) -or
        [string]$command.ModuleName -cne $ModuleName -or
        [string]$command.Name -cne $Name) {
        throw "Azure interface '$Name' is not the exact cmdlet exported by '$ModuleName' (resolved '$($command.Name)' from '$($command.ModuleName)' as '$($command.CommandType)'). Refusing a shadowed or wrong-module interface."
    }
    return $command
}

function Assert-AzureVerifiedContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$VerifiedContext)

    $contextProperty = $VerifiedContext.PSObject.Properties['Context']
    $subscriptionProperty = $VerifiedContext.PSObject.Properties['SubscriptionId']
    $tenantProperty = $VerifiedContext.PSObject.Properties['TenantId']
    if ($null -eq $contextProperty -or $null -eq $contextProperty.Value -or
        $null -eq $subscriptionProperty -or $null -eq $tenantProperty) {
        throw 'VerifiedContext is incomplete; refusing an Azure operation without the exact verified context.'
    }

    $context = $contextProperty.Value
    $contextSubscriptionProperty = $context.PSObject.Properties['Subscription']
    $contextTenantProperty = $context.PSObject.Properties['Tenant']
    if ($null -eq $contextSubscriptionProperty -or $null -eq $contextTenantProperty -or
        $null -eq $contextSubscriptionProperty.Value -or $null -eq $contextTenantProperty.Value) {
        throw 'VerifiedContext contains no complete subscription and tenant objects; refusing an Azure operation.'
    }
    $actualSubscription = [string]$contextSubscriptionProperty.Value.Id
    $actualTenant = [string]$contextTenantProperty.Value.Id
    $expectedSubscription = ([string]$subscriptionProperty.Value).Trim().ToLowerInvariant()
    $expectedTenant = ([string]$tenantProperty.Value).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($actualSubscription) -or [string]::IsNullOrWhiteSpace($actualTenant) -or
        $actualSubscription.Trim().ToLowerInvariant() -cne $expectedSubscription -or
        $actualTenant.Trim().ToLowerInvariant() -cne $expectedTenant) {
        throw "VerifiedContext does not match its verified subscription/tenant ('$expectedSubscription'/'$expectedTenant'); refusing an Azure operation."
    }
    return $context
}

function New-AzureVerifiedContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $contextCommand = Get-AzureTrustedCommandInfo -Name 'Get-AzContext' -ModuleName 'Az.Accounts'
    try {
        $context = & $contextCommand -ErrorAction Stop
    }
    catch {
        throw "Could not read the active Azure context through the trusted Az.Accounts interface: $($_.Exception.Message)"
    }
    if ($null -eq $context -or $null -eq $context.Subscription -or $null -eq $context.Tenant) {
        throw 'No complete active Azure context was returned; refusing to use an ambient or incomplete context.'
    }

    $expectedSubscription = $SubscriptionId.Trim().ToLowerInvariant()
    $expectedTenant = $TenantId.Trim().ToLowerInvariant()
    $actualSubscription = ([string]$context.Subscription.Id).Trim().ToLowerInvariant()
    $actualTenant = ([string]$context.Tenant.Id).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($expectedSubscription) -or [string]::IsNullOrWhiteSpace($expectedTenant) -or
        $actualSubscription -cne $expectedSubscription -or $actualTenant -cne $expectedTenant) {
        throw "The active Azure context does not exactly match subscription '$SubscriptionId' and tenant '$TenantId'; refusing an ambient-context operation."
    }

    return [pscustomobject]@{
        Context        = $context
        SubscriptionId = $expectedSubscription
        TenantId       = $expectedTenant
    }
}

function Invoke-AzureVerifiedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.CommandInfo]$CommandInfo,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $context = Assert-AzureVerifiedContext -VerifiedContext $VerifiedContext
    if ($Parameters.ContainsKey('DefaultProfile')) {
        throw 'An Azure operation attempted to provide a second or unverified DefaultProfile.'
    }
    $Parameters['DefaultProfile'] = $context
    $Parameters['ErrorAction'] = 'Stop'
    return & $CommandInfo @Parameters
}

function Get-DeployLocations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$VerifiedContext)
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzLocation' -ModuleName 'Az.Resources'
    return @(Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{})
}

function Get-DeployResourceProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzResourceProvider' -ModuleName 'Az.Resources'
    return @(Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{ ProviderNamespace = $Namespace })
}

function Get-DeployPolicyAssignments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$VerifiedContext)
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzPolicyAssignment' -ModuleName 'Az.Resources'
    return @(Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{})
}

function Get-DeployPolicyDefinitionRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PolicyDefinitionId,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzPolicyDefinition' -ModuleName 'Az.Resources'
    $definition = Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{ Id = $PolicyDefinitionId }
    return $definition.Properties.PolicyRule
}

function Get-DeployComputeResourceSkus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzComputeResourceSku' -ModuleName 'Az.Compute'
    return @(Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{ Location = $Location })
}

function Get-DeployVmUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzVMUsage' -ModuleName 'Az.Compute'
    return @(Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{ Location = $Location })
}

function Resolve-DeployRockyImageVersion {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$RockyImageVersion,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Offer,
        [Parameter(Mandatory)][string]$Sku,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    if (-not [string]::IsNullOrWhiteSpace($RockyImageVersion)) {
        return [pscustomobject]@{ Version = $RockyImageVersion; AutoDerived = $false }
    }
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzVMImage' -ModuleName 'Az.Compute'
    try {
        $images = @(Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{
                Location = $Location; PublisherName = $Publisher; Offer = $Offer; Skus = $Sku
            })
    }
    catch {
        throw "Could not list the requested image through the trusted Az.Compute interface: $($_.Exception.Message)"
    }
    $versions = @($images | ForEach-Object { [string]$_.Version } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($versions.Count -eq 0) { throw "No image version is available for '$Publisher/$Offer/$Sku' in '$Location'." }
    $parsed = @($versions | ForEach-Object {
            $version = $null
            if ([version]::TryParse($_, [ref]$version)) { [pscustomobject]@{ Text = $_; Value = $version } }
        } | Sort-Object Value -Descending)
    $newest = if ($parsed.Count -gt 0) { $parsed[0].Text } else { @($versions | Sort-Object -Descending)[0] }
    return [pscustomobject]@{ Version = $newest; AutoDerived = $true }
}

function Get-DeployResourceGroupByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    [void](Assert-AzureVerifiedContext -VerifiedContext $VerifiedContext)
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzResourceGroup' -ModuleName 'Az.Resources'
    try {
        return Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{ Name = $Name }
    }
    catch { return $null }
}

function Get-DeployResourceGroupResourceCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    [void](Assert-AzureVerifiedContext -VerifiedContext $VerifiedContext)
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzResource' -ModuleName 'Az.Resources'
    return @(Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{ ResourceGroupName = $ResourceGroupName }).Count
}

function Get-DeployRoleAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$ObjectId,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    $command = Get-AzureTrustedCommandInfo -Name 'Get-AzRoleAssignment' -ModuleName 'Az.Resources'
    return @(Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters @{ Scope = $Scope; ObjectId = $ObjectId })
}

function Get-AzureMarketplaceAgreementPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Plan,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    [void](Assert-AzureVerifiedContext -VerifiedContext $VerifiedContext)
    $subscription = [Uri]::EscapeDataString([string]$VerifiedContext.SubscriptionId)
    $publisherValue = [Uri]::EscapeDataString($Publisher)
    $productValue = [Uri]::EscapeDataString($Product)
    $planValue = [Uri]::EscapeDataString($Plan)
    return "/subscriptions/$subscription/providers/Microsoft.MarketplaceOrdering/agreements/$publisherValue/offers/$productValue/plans/${planValue}?api-version=2021-01-01"
}

function Invoke-AzureMarketplaceAgreement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT')][string]$Method,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Plan,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    $command = Get-AzureTrustedCommandInfo -Name 'Invoke-AzRestMethod' -ModuleName 'Az.Accounts'
    $parameters = @{ Method = $Method; Path = (Get-AzureMarketplaceAgreementPath -Publisher $Publisher -Product $Product -Plan $Plan -VerifiedContext $VerifiedContext) }
    if ($Method -eq 'PUT') {
        $parameters['Payload'] = (@{ properties = @{ publisher = $Publisher; product = $Product; plan = $Plan } } | ConvertTo-Json -Depth 4 -Compress)
    }
    return Invoke-AzureVerifiedCommand -CommandInfo $command -VerifiedContext $VerifiedContext -Parameters $parameters
}

function Get-DeployRockyMarketplaceTermsStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    $response = Invoke-AzureMarketplaceAgreement -Method GET -Publisher $Publisher -Product $Product -Plan $Name -VerifiedContext $VerifiedContext
    $statusCodeProperty = if ($null -ne $response) { $response.PSObject.Properties['StatusCode'] } else { $null }
    $statusCode = if ($null -ne $statusCodeProperty) { [int]$statusCodeProperty.Value } else { 0 }
    # A precise 404 for this exact, verified agreement means it has not yet been
    # created.  No other transport or HTTP failure is interpreted as consent.
    if ($statusCode -eq 404) { return [pscustomobject]@{ Status = 'NotAccepted'; Response = $null } }
    if ($statusCode -lt 200 -or $statusCode -gt 299) { throw "Marketplace agreement GET returned HTTP $statusCode; refusing to infer acceptance." }
    $contentProperty = if ($null -ne $response) { $response.PSObject.Properties['Content'] } else { $null }
    $body = if ($null -ne $contentProperty) { [string]$contentProperty.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($body)) { throw 'Marketplace agreement GET returned no body; refusing to infer acceptance.' }
    $parsed = $body | ConvertFrom-Json -ErrorAction Stop
    $responseName = [string]$parsed.name
    $responsePublisher = [string]$parsed.properties.publisher
    $responseProduct = [string]$parsed.properties.product
    if ([string]::IsNullOrWhiteSpace($responseName) -or $responseName -cne $Name -or
        [string]::IsNullOrWhiteSpace($responsePublisher) -or $responsePublisher -cne $Publisher -or
        [string]::IsNullOrWhiteSpace($responseProduct) -or $responseProduct -cne $Product) {
        throw 'Marketplace agreement GET returned an agreement with an unexpected publisher, product, or plan; refusing to use it.'
    }
    $state = [string]$parsed.properties.state
    if ([string]::IsNullOrWhiteSpace($state)) { throw 'Marketplace agreement GET returned no usable state; refusing to infer acceptance.' }
    return [pscustomobject]@{ Status = $(if ($state -ieq 'Active') { 'Accepted' } else { 'NotAccepted' }); Response = $parsed }
}

function Set-DeployRockyMarketplaceTermsAccepted {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    [void](Assert-AzureVerifiedContext -VerifiedContext $VerifiedContext)
    if (-not $PSCmdlet.ShouldProcess("Marketplace agreement $Publisher/$Product/$Name for subscription $($VerifiedContext.SubscriptionId)", 'Accept legal terms')) {
        throw 'Marketplace acceptance was not confirmed; refusing to mutate the agreement.'
    }
    $response = Invoke-AzureMarketplaceAgreement -Method PUT -Publisher $Publisher -Product $Product -Plan $Name -VerifiedContext $VerifiedContext
    $statusCodeProperty = if ($null -ne $response) { $response.PSObject.Properties['StatusCode'] } else { $null }
    $statusCode = if ($null -ne $statusCodeProperty) { [int]$statusCodeProperty.Value } else { 0 }
    if ($statusCode -lt 200 -or $statusCode -gt 299) { throw "Marketplace agreement PUT returned HTTP $statusCode; acceptance is not confirmed." }
    return Get-DeployRockyMarketplaceTermsStatus -Publisher $Publisher -Product $Product -Name $Name -VerifiedContext $VerifiedContext
}

function Resolve-DeployRockyMarketplaceTerms {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext,
        [Parameter(Mandatory)][bool]$AutoAccept
    )
    $status = Get-DeployRockyMarketplaceTermsStatus -Publisher $Publisher -Product $Product -Name $Name -VerifiedContext $VerifiedContext
    if ($status.Status -eq 'Accepted' -or -not $AutoAccept) { return $status }
    return Set-DeployRockyMarketplaceTermsAccepted -Publisher $Publisher -Product $Product -Name $Name -VerifiedContext $VerifiedContext -Confirm:$false
}

function Resolve-AzureProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$CandidateRegions,
        [Parameter(Mandatory)][string[]]$CandidateVmSkus,
        [Parameter(Mandatory)][string]$RockyImagePublisher,
        [Parameter(Mandatory)][string]$RockyImageOffer,
        [Parameter(Mandatory)][string]$RockyImageSku,
        [Parameter(Mandatory)][pscustomobject]$VerifiedContext
    )
    [void](Assert-AzureVerifiedContext -VerifiedContext $VerifiedContext)
    foreach ($region in $CandidateRegions) {
        try {
            $rawSkus = @(Get-DeployComputeResourceSkus -Location $region -VerifiedContext $VerifiedContext)
            $usage = @(Get-DeployVmUsage -Location $region -VerifiedContext $VerifiedContext)
            foreach ($sku in $CandidateVmSkus) {
                $match = @($rawSkus | Where-Object { [string]$_.Name -ieq $sku })[0]
                if ($null -eq $match) { continue }
                $image = Resolve-DeployRockyImageVersion -RockyImageVersion '' -Location $region -Publisher $RockyImagePublisher -Offer $RockyImageOffer -Sku $RockyImageSku -VerifiedContext $VerifiedContext
                return [pscustomobject]@{ Location = $region; VmSku = $sku; RockyImageVersion = $image.Version; Usage = $usage }
            }
        }
        catch {
            if ([string]$_.Exception.Message -match 'Azure interface|VerifiedContext|ambient-context') { throw }
            continue
        }
    }
    throw 'Could not resolve an Azure deployment profile from the verified subscription; no unsafe or ambient fallback is permitted.'
}
