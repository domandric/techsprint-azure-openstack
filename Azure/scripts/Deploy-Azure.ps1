#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$UsersCsv,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [AllowEmptyString()]
    [string]$SubscriptionId = '',

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [AllowEmptyString()]
    [string]$TenantId = '',

    [string]$NameSeed = '',

    [AllowEmptyCollection()]
    [string[]]$StateAdministratorObjectId = @(),

    [AllowEmptyString()]
    [string]$UpnDomain = '',

    [AllowEmptyString()]
    [string]$RockyImageVersion = '',

    [string]$WorkDir,

    [string]$TenantSecretsCommand,

    [switch]$ApproveSubscriptionMutations,

    [switch]$ApproveDirectoryMutations,

    [string]$RockyMarketplaceTermsConfirmation,

    [switch]$DestroyAll,

    [string]$DestroyAllConfirmation,

    [switch]$KeepStateBackend,

    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$EntraMode = 'existing'
$RockyImagePublisher = 'resf'
$RockyImageOffer = 'rockylinux-x86_64'
$RockyImageSku = '10-lvm'
$ApplyStateBootstrap = $false

$Location = ''
$LocationShortName = ''
$VmSku = ''

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$InvokeAzureScript = Join-Path $PSScriptRoot 'Invoke-Azure.ps1'
$SharedRootPath = Join-Path $RepositoryRoot 'infra/azure/shared'
$TenantRootPath = Join-Path $RepositoryRoot 'infra/azure/tenant'
$KeysDirectory = Join-Path $RepositoryRoot 'keys'
$AnsiblePlaybook = 'playbooks/deploy_moodle.yml'
$AnsibleVaultFilePath = Join-Path $RepositoryRoot 'ansible/inventories/production/group_vars/all/vault.yml'
$AnsibleVaultPasswordFilePath = Join-Path $RepositoryRoot 'ansible/.vault-password'
$ExportAnsibleSecretsScript = Join-Path $PSScriptRoot 'Export-AnsibleSecrets.ps1'
$script:PwshPath = (Get-Command pwsh -ErrorAction Stop).Source

$script:DestroyAllConfirmationPhrase = 'AZURE-DESTROY-ALL'

$script:RockyMarketplaceTermsConfirmationPhrase = 'ACCEPT-ROCKY-MARKETPLACE-TERMS'

# Tracked, non-secret, human-audited config file recording a standing subscription-owner
# approval to auto-accept the Rocky Linux Marketplace terms without a prompt. See
# Get-DeployRockyMarketplaceTermsStandingApproval for the exact-match/fail-closed rules.
$script:RockyMarketplaceTermsStandingApprovalConfigPath = Join-Path $PSScriptRoot 'RockyMarketplaceTermsStandingApproval.json'

$script:StateResourceGroupName = 'rg-ts-state-testing-weu'
$script:StateContainerName = 'tfstate'
$BootstrapScript = Join-Path $RepositoryRoot 'bootstrap/Initialize-AzureTerraformState.ps1'
$BootstrapBackendHclPath = Join-Path $RepositoryRoot 'bootstrap/backend.hcl'

$script:DestroyAllPlaceholderRockyVersion = '0.0.0'
$script:DestroyAllPlaceholderSshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDestroyAllPlaceholderNeverUsedForRealAccess destroy-all-placeholder'
$script:DestroyAllPlaceholderPassword = 'Destroy-All-Placeholder-Not-A-Real-Credential-1'
$script:DestroyAllPlaceholderSharedValues = @{
    hub_vnet_id                = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/providers/Microsoft.Network/virtualNetworks/placeholder'
    jump_public_ip              = '203.0.113.1'
    admin_username               = 'destroyallplaceholder'
    private_dns_zone_ids = @{
        blob   = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/providers/Microsoft.Network/privateDnsZones/blob.placeholder'
        file   = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/providers/Microsoft.Network/privateDnsZones/file.placeholder'
        moodle = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/providers/Microsoft.Network/privateDnsZones/moodle.placeholder'
    }
    developer_group_ids        = @{}
    lead_group_id               = '00000000-0000-0000-0000-000000000000'
    custom_role_definition_id = '/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000000'
    mysql = @{
        fqdn                   = 'mysql-placeholder.mysql.database.azure.com'
        version                = '8.4'
        sku_name               = 'GP_Standard_D2ds_v4'
        sku_tier               = 'GeneralPurpose'
        high_availability_mode = 'ZoneRedundant'
        administrator_login    = 'destroyallplaceholder'
        database_names         = @{}
    }
}

. (Join-Path $PSScriptRoot 'Validate-AzureUsers.ps1') -Path 'unused.csv' -UpnDomain $UpnDomain

. (Join-Path $PSScriptRoot 'PathSafety.ps1')

. (Join-Path $PSScriptRoot 'Resolve-AzureContext.ps1')

. (Join-Path $PSScriptRoot 'Resolve-AzureDeploymentProfile.ps1')

function Resolve-DeployUsersCsvPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ProviderRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Stop-DeployUsage -Message 'UsersCsv path must not be empty.'
    }

    $candidates = [Collections.Generic.List[string]]::new()
    if ([IO.Path]::IsPathRooted($Path)) {
        $candidates.Add([IO.Path]::GetFullPath($Path))
    }
    else {
        # Preserve normal PowerShell semantics first: explicit relative paths are
        # resolved from the caller's current directory.
        $candidates.Add([IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path)))

        # Compatibility for provider-local invocation after the root dispatcher
        # was removed: from Azure/, "config/users.csv" means the shared root CSV.
        $repositoryRoot = Split-Path -Parent $ProviderRoot
        $sharedCandidate = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
        if ($sharedCandidate -notin $candidates) {
            $candidates.Add($sharedCandidate)
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }

    Stop-DeployUsage -Message "UsersCsv file was not found. Checked: $($candidates -join ', ')"
}

function Stop-DeployUsage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    throw "$Message`nThis one-invocation workflow refuses to guess: fix the input and rerun."
}

function Assert-DeploySshKeygenAvailable {
    [CmdletBinding()]
    param()
    if ($null -eq (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        throw 'ssh-keygen is required on PATH to generate missing SSH key pairs; no Azure/Terraform work was started.'
    }
}

function Initialize-DeployKeysDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KeysDirectory)
    New-Item -ItemType Directory -Path $KeysDirectory -Force | Out-Null
    Set-DeployUnixPermissions -Path $KeysDirectory -Mode '700'
}

function Assert-DeploySshKeyPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KeysDirectory,
        [Parameter(Mandatory)][string]$Slug
    )
    $privatePath = Join-Path $KeysDirectory $Slug
    $publicPath = Join-Path $KeysDirectory "$Slug.pub"
    $hasPrivate = Test-Path -LiteralPath $privatePath -PathType Leaf
    $hasPublic = Test-Path -LiteralPath $publicPath -PathType Leaf

    if ($hasPrivate -and $hasPublic) {

        Set-DeployUnixPermissions -Path $privatePath -Mode '600'
        Set-DeployUnixPermissions -Path $publicPath -Mode '644'
        return $publicPath
    }
    if ($hasPrivate -or $hasPublic) {
        throw "Incomplete SSH key pair for '$Slug' in $KeysDirectory (only the $(if ($hasPrivate) { 'private' } else { 'public' }) half exists). Restore or remove it by hand; this command never overwrites an existing key."
    }

    $sshKeygen = (Get-Command ssh-keygen -ErrorAction Stop).Source
    & $sshKeygen -q -t ed25519 -N '' -C $Slug -f $privatePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $privatePath -PathType Leaf) -or -not (Test-Path -LiteralPath $publicPath -PathType Leaf)) {
        throw "ssh-keygen did not produce a complete key pair for '$Slug'."
    }
    Set-DeployUnixPermissions -Path $privatePath -Mode '600'
    Set-DeployUnixPermissions -Path $publicPath -Mode '644'
    return $publicPath
}

function Assert-DeploySshKeyPairs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KeysDirectory,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Slugs
    )
    Initialize-DeployKeysDirectory -KeysDirectory $KeysDirectory
    $result = @{}
    foreach ($slug in @($Slugs | Sort-Object -Unique)) {
        $result[$slug] = Assert-DeploySshKeyPair -KeysDirectory $KeysDirectory -Slug $slug
    }
    return $result
}

function ConvertTo-HclStringLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return "`"$escaped`""
}

function Get-DeploySshPublicKeyLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PublicKeyPath)
    if (-not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
        throw "SSH public key file not found: $PublicKeyPath"
    }
    $raw = Get-Content -LiteralPath $PublicKeyPath -Raw
    if ($null -eq $raw) { $raw = '' }
    $trimmed = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "SSH public key file is empty: $PublicKeyPath"
    }
    if ($trimmed -match '[\r\n]') {
        throw "SSH public key file must contain a single-line OpenSSH public key (embedded newline found): $PublicKeyPath"
    }
    return ConvertTo-HclStringLiteral $trimmed
}

function New-SharedTfvarsContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$LocationShortName,
        [Parameter(Mandatory)][string]$VmSku,
        [Parameter(Mandatory)][string]$NameSeed,
        [Parameter(Mandatory)][string]$AllowedSshCidr,
        [Parameter(Mandatory)][string]$EntraMode,
        [Parameter(Mandatory)][pscustomobject]$RockyImage,
        [Parameter(Mandatory)][pscustomobject]$Lead,
        [Parameter(Mandatory)][pscustomobject[]]$Developers,
        [Parameter(Mandatory)][string]$LeadSshPublicKeyAbsolutePath,
        [bool]$AppGatewayEnabled = $false
    )

    $developerLines = foreach ($developer in $Developers) {
        @"
    {
      slug         = $(ConvertTo-HclStringLiteral $developer.Slug)
      rola         = "developer"
      upn          = $(ConvertTo-HclStringLiteral $developer.Upn)
      network_slot = $($developer.NetworkSlot)
    },
"@
    }

    return @"
subscription_id      = $(ConvertTo-HclStringLiteral $SubscriptionId)
location             = $(ConvertTo-HclStringLiteral $Location)
location_short_name  = $(ConvertTo-HclStringLiteral $LocationShortName)
vm_sku               = $(ConvertTo-HclStringLiteral $VmSku)
name_seed            = $(ConvertTo-HclStringLiteral $NameSeed)
allowed_ssh_cidr     = $(ConvertTo-HclStringLiteral $AllowedSshCidr)
entra_mode           = $(ConvertTo-HclStringLiteral $EntraMode)

rocky_image = {
  publisher = $(ConvertTo-HclStringLiteral $RockyImage.Publisher)
  offer     = $(ConvertTo-HclStringLiteral $RockyImage.Offer)
  sku       = $(ConvertTo-HclStringLiteral $RockyImage.Sku)
  version   = $(ConvertTo-HclStringLiteral $RockyImage.Version)
}

users = {
  lead = {
    slug = $(ConvertTo-HclStringLiteral $Lead.Slug)
    rola = "devops_lead"
    upn  = $(ConvertTo-HclStringLiteral $Lead.Upn)
  }
  developers = [
$($developerLines -join "`n")
  ]
}

lead_ssh_public_key = $(Get-DeploySshPublicKeyLiteral $LeadSshPublicKeyAbsolutePath)

tenant_networks     = {}
tenant_backends     = {}
app_gateway_enabled = $($AppGatewayEnabled.ToString().ToLowerInvariant())
"@
}

function New-TenantTfvarsContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$LocationShortName,
        [Parameter(Mandatory)][string]$VmSku,
        [Parameter(Mandatory)][string]$NameSeed,
        [Parameter(Mandatory)][pscustomobject]$Developer,
        [Parameter(Mandatory)][pscustomobject[]]$AllDevelopers,
        [Parameter(Mandatory)][hashtable]$SharedValues,
        [Parameter(Mandatory)][string]$DeveloperSshPublicKeyAbsolutePath,
        [Parameter(Mandatory)][string]$LeadSshPublicKeyAbsolutePath,
        [Parameter(Mandatory)][pscustomobject]$RockyImage
    )

    $databaseNames = @{}
    foreach ($known in $AllDevelopers) {
        $databaseNames[$known.Slug] = "moodle_$(($known.Slug -replace '-', '_'))"
    }
    if ($null -ne $SharedValues.mysql -and $null -ne $SharedValues.mysql.database_names -and $SharedValues.mysql.database_names.Count -gt 0) {
        $databaseNames = $SharedValues.mysql.database_names
    }

    $knownDeveloperLines = foreach ($other in $AllDevelopers) {
        @"
  $($other.Slug) = { slug = $(ConvertTo-HclStringLiteral $other.Slug), network_slot = $($other.NetworkSlot) }
"@
    }

    $zoneKeys = @('blob', 'file', 'moodle')
    $zoneLines = foreach ($key in $zoneKeys) {
        "    $key = $(ConvertTo-HclStringLiteral ([string]$SharedValues.private_dns_zone_ids.$key))"
    }

    return @"
location             = $(ConvertTo-HclStringLiteral $Location)
location_short_name  = $(ConvertTo-HclStringLiteral $LocationShortName)
vm_sku               = $(ConvertTo-HclStringLiteral $VmSku)
name_seed            = $(ConvertTo-HclStringLiteral $NameSeed)

developer = {
  slug         = $(ConvertTo-HclStringLiteral $Developer.Slug)
  rola         = "developer"
  network_slot = $($Developer.NetworkSlot)
}

known_developers = {
$($knownDeveloperLines -join "`n")
}

 shared = {
  hub_vnet_id    = $(ConvertTo-HclStringLiteral ([string]$SharedValues.hub_vnet_id))
  jump_public_ip = $(ConvertTo-HclStringLiteral ([string]$SharedValues.jump_public_ip))
  admin_username = $(ConvertTo-HclStringLiteral ([string]$SharedValues.admin_username))
  private_dns_zone_ids = {
$($zoneLines -join "`n")
  }
  developer_group_id        = $(ConvertTo-HclStringLiteral ([string]$SharedValues.developer_group_ids[$Developer.Slug]))
  lead_group_id              = $(ConvertTo-HclStringLiteral ([string]$SharedValues.lead_group_id))
   custom_role_definition_id  = $(ConvertTo-HclStringLiteral ([string]$SharedValues.custom_role_definition_id))
   mysql = {
     fqdn                   = $(ConvertTo-HclStringLiteral ([string]$SharedValues.mysql.fqdn))
     version                = $(ConvertTo-HclStringLiteral ([string]$SharedValues.mysql.version))
     sku_name               = $(ConvertTo-HclStringLiteral ([string]$SharedValues.mysql.sku_name))
     sku_tier               = $(ConvertTo-HclStringLiteral ([string]$SharedValues.mysql.sku_tier))
     high_availability_mode = $(ConvertTo-HclStringLiteral ([string]$SharedValues.mysql.high_availability_mode))
     administrator_login    = $(ConvertTo-HclStringLiteral ([string]$SharedValues.mysql.administrator_login))
     database_names = {
 $(($databaseNames.GetEnumerator() | Sort-Object Name | ForEach-Object { "       $($_.Name) = $(ConvertTo-HclStringLiteral ([string]$_.Value))" }) -join "`n")
     }
   }
 }

developer_ssh_public_key = $(Get-DeploySshPublicKeyLiteral $DeveloperSshPublicKeyAbsolutePath)
lead_ssh_public_key      = $(Get-DeploySshPublicKeyLiteral $LeadSshPublicKeyAbsolutePath)

rocky_image = {
  publisher = $(ConvertTo-HclStringLiteral $RockyImage.Publisher)
  offer     = $(ConvertTo-HclStringLiteral $RockyImage.Offer)
  sku       = $(ConvertTo-HclStringLiteral $RockyImage.Sku)
  version   = $(ConvertTo-HclStringLiteral $RockyImage.Version)
}
"@
}

function New-SharedReconcileTfvarsContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject[]]$TenantReconciliations)

    $networkLines = foreach ($item in $TenantReconciliations) {
        @"
  $($item.network.slug) = {
    slug         = $(ConvertTo-HclStringLiteral $item.network.slug)
    network_slot = $($item.network.network_slot)
    vnet_id      = $(ConvertTo-HclStringLiteral $item.network.vnet_id)
  }
"@
    }
    $backendLines = foreach ($item in $TenantReconciliations) {
        @"
  $($item.backend.slug) = {
    slug             = $(ConvertTo-HclStringLiteral $item.backend.slug)
    network_slot     = $($item.backend.network_slot)
    app01_private_ip = $(ConvertTo-HclStringLiteral $item.backend.app01_private_ip)
    app02_private_ip = $(ConvertTo-HclStringLiteral $item.backend.app02_private_ip)
  }
"@
    }

    return @"
tenant_networks = {
$($networkLines -join "`n")
}

tenant_backends = {
$($backendLines -join "`n")
}

app_gateway_enabled = true
"@
}

function Set-DeployUnixPermissions {

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

function Resolve-DeployWorkDir {

    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)

    $resolved = if ([string]::IsNullOrWhiteSpace($Path)) {
        Join-Path $RepositoryRoot 'runtime/deploy'
    }
    else {
        [System.IO.Path]::GetFullPath($Path)
    }

    if (-not (Test-RepositoryPathIsAllowed -Path $resolved -RepositoryRoot $RepositoryRoot)) {
        throw 'WorkDir must be outside the repository, or under the ignored runtime/ directory (default: runtime/deploy); refusing a path Git could track.'
    }
    return $resolved
}

function Initialize-DeployWorkDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-DeployUnixPermissions -Path $Path -Mode '700'
}

function New-DeployVarFilesRunnerArgs {

    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Paths)

    if (@($Paths | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'Var-file paths must not be empty.'
    }
    return @('-VarFilesJson', (ConvertTo-Json -InputObject @($Paths) -Compress))
}

function Get-DeployRunnerArgValue {

    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$RunnerArgs,
        [Parameter(Mandatory)][string]$Name
    )
    for ($index = 0; $index -lt $RunnerArgs.Count - 1; $index++) {
        if ([string]$RunnerArgs[$index] -ceq $Name) { return [string]$RunnerArgs[$index + 1] }
    }
    return $null
}

function Invoke-DeployRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$RunnerArgs,
        [switch]$AllowNonZeroExit
    )

    Write-Host "==> Invoke-Azure.ps1 $($RunnerArgs -join ' ')"
    $output = & $script:PwshPath -NoLogo -NoProfile -File $InvokeAzureScript @RunnerArgs 2>&1
    $output | ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowNonZeroExit) {

        foreach ($hint in @(Get-DeployAzureErrorHint -Text ($output -join [Environment]::NewLine))) {
            Write-Host $hint
        }

        $context = [string]$RunnerArgs[1]
        $rootName = Get-DeployRunnerArgValue -RunnerArgs $RunnerArgs -Name '-Root'
        if (-not [string]::IsNullOrWhiteSpace($rootName)) { $context += " -Root $rootName" }
        $tenantSlugName = Get-DeployRunnerArgValue -RunnerArgs $RunnerArgs -Name '-TenantSlug'
        if (-not [string]::IsNullOrWhiteSpace($tenantSlugName)) { $context += " -TenantSlug $tenantSlugName" }

        $outputLines = @($output | ForEach-Object { [string]$_ })
        $tailLineCount = 40
        $tailLines = if ($outputLines.Count -gt $tailLineCount) { @($outputLines[-$tailLineCount..-1]) } else { $outputLines }
        $tailText = ($tailLines -join [Environment]::NewLine)

        throw "scripts/Invoke-Azure.ps1 $context failed with exit code $exitCode.`n--- last $($tailLines.Count) line(s) of its Plan/Apply/Destroy output ---`n$tailText"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join [Environment]::NewLine) }
}

function Test-DeployTransientTerraformApplyFailure {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Message)

    return $Message -match 'ConflictingConcurrentWriteNotAllowed|AnotherOperationInProgress|HTTP response was nil; connection may have been reset'
}

function Invoke-DeployTerraformApplyWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$PlanRunnerArgs,
        [Parameter(Mandatory)][string[]]$ApplyRunnerArgs,
        [AllowEmptyString()][string]$SharedMysqlAdministratorPassword,
        [ValidateRange(1, 5)][int]$MaximumAttempts = 3,
        [ValidateRange(0, 300)][int]$InitialDelaySeconds = 30
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            if ([string]::IsNullOrWhiteSpace($SharedMysqlAdministratorPassword)) {
                Invoke-DeployRunner -RunnerArgs $ApplyRunnerArgs | Out-Null
            }
            else {
                Invoke-DeployRunnerWithSharedMysqlPassword -RunnerArgs $ApplyRunnerArgs -Password $SharedMysqlAdministratorPassword | Out-Null
            }
            return
        }
        catch {
            if ($attempt -eq $MaximumAttempts -or -not (Test-DeployTransientTerraformApplyFailure -Message $_.Exception.Message)) {
                throw
            }
            $delay = $InitialDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Warning "Azure reported a transient Terraform apply conflict on attempt $attempt/$MaximumAttempts. Waiting $delay seconds, refreshing state with a new plan, and retrying automatically."
            Start-Sleep -Seconds $delay
            if ([string]::IsNullOrWhiteSpace($SharedMysqlAdministratorPassword)) {
                Invoke-DeployRunner -RunnerArgs $PlanRunnerArgs | Out-Null
            }
            else {
                Invoke-DeployRunnerWithSharedMysqlPassword -RunnerArgs $PlanRunnerArgs -Password $SharedMysqlAdministratorPassword | Out-Null
            }
        }
    }
}

function Get-TerraformOutputJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$BackendConfigPath,
        [Parameter(Mandatory)][string]$StateKey
    )

    try {
        $terraform = (Get-Command terraform -ErrorAction Stop).Source
        $null = & $terraform "-chdir=$RootPath" init -reconfigure -input=false -no-color -upgrade=false `
            "-backend-config=$BackendConfigPath" "-backend-config=key=$StateKey" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [InvalidOperationException]::new('backend_init')
        }

        $json = & $terraform "-chdir=$RootPath" output -json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [InvalidOperationException]::new('output_command')
        }
        $parsed = ($json -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        throw 'terraform output -json failed (status=unavailable; category=terraform_not_found).'
    }
    catch [System.Management.Automation.RuntimeException] {
        throw 'terraform output -json failed (status=invalid; category=output_decode).'
    }
    catch [System.InvalidOperationException] {
        $category = [string]$_.Exception.Message
        if ($category -notin @('backend_init', 'output_command')) { $category = 'operation' }
        throw "terraform output -json failed (status=failed; category=$category)."
    }
    catch {
        throw 'terraform output -json failed (status=failed; category=unexpected).'
    }

    $result = @{}
    foreach ($key in $parsed.Keys) { $result[$key] = $parsed[$key].value }
    return $result
}

function New-DeployMySqlAdministratorPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Azure receives this value only through the scoped TF_VAR environment channel. The
    # password is never placed in a tfvars file, argv, output, or a tracked artifact.
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return "Aa1!$([Convert]::ToBase64String($bytes).TrimEnd('='))"
}

function Get-DeploySharedMysqlAdministratorPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BackendConfigPath,
        [Parameter(Mandatory)][string]$RootPath
    )

    $terraform = (Get-Command terraform -ErrorAction Stop).Source
    $initOutput = & $terraform "-chdir=$RootPath" init -reconfigure -input=false -no-color -upgrade=false `
        "-backend-config=$BackendConfigPath" '-backend-config=key=shared.tfstate' 2>&1
    if ($LASTEXITCODE -ne 0) {
        $initOutput = $null
        throw 'BLOCKED: the shared Terraform backend could not be initialized for the read-only MySQL credential lookup; refusing to generate or use a new shared administrator credential.'
    }
    $initOutput = $null

    $rawOutput = & $terraform "-chdir=$RootPath" output -json shared_runtime_secrets 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        try {
            $parsed = ($rawOutput -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -Depth 10 -ErrorAction Stop
            # A named terraform output is normally emitted as its raw value;
            # tolerate the all-outputs wrapper as well.
            $outputValue = $parsed
            if ($parsed -is [System.Collections.IDictionary] -and $parsed.ContainsKey('value')) {
                $outputValue = $parsed.value
            }
            $password = [string]$outputValue.mysql_administrator_password
            if ([string]::IsNullOrWhiteSpace($password)) {
                throw 'missing password'
            }
            $rawOutput = $null
            return $password
        }
        catch {
            $rawOutput = $null
            throw 'BLOCKED: the shared Terraform state exposed an unusable shared MySQL administrator credential output; refusing to generate a replacement that could strand the existing server.'
        }
    }

    # An empty/new shared state has no output yet. Any other backend/output error is not
    # evidence that the credential is absent and must fail closed.
    $isEmptyState = (($rawOutput -join [Environment]::NewLine) -match '(?i)no outputs found|output .* not found')
    $rawOutput = $null
    if (-not $isEmptyState) {
        throw 'BLOCKED: the shared Terraform state could not be read for the MySQL administrator credential; refusing to generate a replacement.'
    }
    return New-DeployMySqlAdministratorPassword
}

function Invoke-DeployRunnerWithSharedMysqlPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$RunnerArgs,
        [Parameter(Mandatory)][string]$Password
    )

    $prior = $env:TF_VAR_mysql_administrator_password
    $env:TF_VAR_mysql_administrator_password = $Password
    try {
        return Invoke-DeployRunner -RunnerArgs $RunnerArgs
    }
    finally {
        $env:TF_VAR_mysql_administrator_password = $prior
    }
}

function Assert-DeployNoLegacyTenantPaaSState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackendConfigPath,
        [Parameter(Mandatory)][string]$TenantRootPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Developers
    )

    $terraform = (Get-Command terraform -ErrorAction Stop).Source
    foreach ($developer in $Developers) {
        $slug = [string]$developer.Slug
        $stateKey = "tenants/$slug.tfstate"
        $initOutput = & $terraform "-chdir=$TenantRootPath" init -reconfigure -input=false -no-color -upgrade=false `
            "-backend-config=$BackendConfigPath" "-backend-config=key=$stateKey" 2>&1
        if ($LASTEXITCODE -ne 0) {
            $initOutput = $null
            throw "BLOCKED: could not inspect the exact tenant Terraform backend for developer '$slug'; migration safety requires a readable remote state before the shared MySQL server can be created."
        }
        $initOutput = $null

        $stateOutput = & $terraform "-chdir=$TenantRootPath" state list -no-color 2>&1
        $stateExitCode = $LASTEXITCODE
        $stateText = $stateOutput -join [Environment]::NewLine
        $noState = $stateText -match '(?i)no state file was found|no state'
        if ($stateExitCode -ne 0 -and -not $noState) {
            $stateOutput = $null
            throw "BLOCKED: could not inspect the exact tenant Terraform state for developer '$slug'; migration safety requires a readable remote state before the shared MySQL server can be created."
        }

        $stateLines = @($stateText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        foreach ($stateLine in $stateLines) {
            if ($stateLine -notmatch '^(?:(?:module\.[A-Za-z0-9_]+(?:\[[^]]+\])?)\.)*[A-Za-z0-9_]+\.[A-Za-z0-9_]+(?:\[[^]]+\])?$') {
                $stateOutput = $null
                $stateText = $null
                throw "BLOCKED: the exact tenant Terraform state for developer '$slug' returned an ambiguous state address; migration safety requires manual review before the shared MySQL server can be created."
            }
        }

        $legacyAddresses = @($stateLines | Where-Object {
                $_ -match '(?i)^module\.paas\.(?:azurerm_mysql_flexible_server|azurerm_mysql_flexible_database|azurerm_private_dns_zone|azurerm_private_dns_zone_virtual_network_link)(?:\.|\[|$)'
            })
        $stateOutput = $null
        $stateText = $null
        if ($legacyAddresses.Count -gt 0) {
            throw "BLOCKED: migration required for developer '$slug': legacy per-tenant MySQL/PaaS resources remain in its Terraform state. Remove or migrate those addresses by hand after review; no shared MySQL resource was created and this workflow never moves, imports, or destroys them automatically."
        }
    }
}

function Get-TenantSecretPair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Slug)

    if (-not [string]::IsNullOrWhiteSpace($TenantSecretsCommand)) {
        $output = & $TenantSecretsCommand $Slug
        if ($LASTEXITCODE -ne 0) {
            throw "TenantSecretsCommand failed for tenant '$Slug' with exit code $LASTEXITCODE."
        }
        $secret = ($output -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable
        foreach ($key in @('moodle_database_password')) {
            if (-not $secret.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$secret[$key])) {
                throw "TenantSecretsCommand output for tenant '$Slug' is missing '$key'."
            }
        }
        return @{ moodle_database_password = [string]$secret.moodle_database_password }
    }

    Write-Host "Tenant '$Slug': enter the Moodle database-user password (input hidden; never written to disk or logged)."
    $moodle = Read-Host -Prompt "  Moodle database-user password for '$Slug'" -MaskInput
    if ([string]::IsNullOrWhiteSpace($moodle)) {
        throw "A Moodle database-user password is required for tenant '$Slug'."
    }
    return @{ moodle_database_password = $moodle }
}

function Initialize-DeployAnsibleVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CsvPath,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$VaultFilePath,
        [Parameter(Mandatory)][string]$VaultPasswordFilePath,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $vaultExists = Test-Path -LiteralPath $VaultFilePath -PathType Leaf
    $passwordExists = Test-Path -LiteralPath $VaultPasswordFilePath -PathType Leaf
    if ($vaultExists -and -not $passwordExists) {
        throw "The encrypted Ansible vault exists but its password file is missing. Restore '$VaultPasswordFilePath' from backup."
    }
    if (-not $vaultExists) {
        & $script:PwshPath -NoLogo -NoProfile -File $ExportAnsibleSecretsScript -UsersCsv $CsvPath -SubscriptionId $SubscriptionId -TenantId $TenantId
        if ($LASTEXITCODE -ne 0) { throw "Ansible vault export failed with exit code $LASTEXITCODE." }
    }
    if (-not (Test-Path -LiteralPath $VaultFilePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $VaultPasswordFilePath -PathType Leaf)) {
        throw 'Ansible vault export did not produce both required encrypted files.'
    }
    Set-DeployUnixPermissions -Path $VaultFilePath -Mode '600'
    Set-DeployUnixPermissions -Path $VaultPasswordFilePath -Mode '600'
}

function Assert-DeployAnsiblePrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$VaultFilePath,
        [Parameter(Mandatory)][string]$VaultPasswordFilePath
    )

    $missing = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf)) {
        $missing.Add("lead private key '$PrivateKeyPath'")
    }
    if (-not (Test-Path -LiteralPath $VaultFilePath -PathType Leaf)) {
        $missing.Add("encrypted inventory vault '$VaultFilePath'")
    }
    if (-not (Test-Path -LiteralPath $VaultPasswordFilePath -PathType Leaf)) {
        $missing.Add("vault password file '$VaultPasswordFilePath'")
    }
    if ($missing.Count -gt 0) {
        throw "Ansible prerequisites are incomplete: $($missing -join '; ')."
    }
}

function Export-DeployProductionAnsibleInventory {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        throw "Terraform-generated Ansible inventory staging directory '$SourceDirectory' does not exist. Apply every tenant and the shared reconciliation first."
    }

    $sourceFiles = @(Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.yml' -File -ErrorAction Stop)
    if ($sourceFiles.Count -lt 2 -or -not ($sourceFiles.Name -contains '00-shared.yml')) {
        throw "Terraform-generated Ansible inventory staging is incomplete: expected 00-shared.yml and at least one tenant fragment under '$SourceDirectory'."
    }

    $destinationDirectory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    $ansibleInventoryCommand = (Get-Command ansible-inventory -ErrorAction Stop).Source
    & $ansibleInventoryCommand -i $SourceDirectory --list --export --yaml --output $DestinationPath
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
        throw "ansible-inventory could not export the Terraform-generated production inventory (exit $exitCode)."
    }
    Set-DeployUnixPermissions -Path $DestinationPath -Mode '600'
    return (Resolve-Path -LiteralPath $DestinationPath).Path
}

function Invoke-DeployAnsible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InventoryPath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$Playbook
    )

    $ansibleDirectory = Join-Path $RepositoryRoot 'ansible'
    $privateKey = (Resolve-Path -LiteralPath $PrivateKeyPath).Path
    $ansiblePlaybookCommand = (Get-Command ansible-playbook -ErrorAction Stop).Source

    $ansibleArgs = @(
        '-i', $InventoryPath,
        $Playbook,
        '--private-key', $privateKey,
        '--ssh-common-args', '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'
    )
    $sshAgentCommand = (Get-Command ssh-agent -ErrorAction Stop).Source
    $sshAddCommand = (Get-Command ssh-add -ErrorAction Stop).Source
    $priorAuthSock = $env:SSH_AUTH_SOCK
    $priorAgentPid = $env:SSH_AGENT_PID
    $agentStarted = $false

    try {
        $agentOutput = @(& $sshAgentCommand -s 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'ssh-agent could not start for the Ansible ProxyJump connection.' }
        $agentText = ($agentOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($agentText -notmatch 'SSH_AUTH_SOCK=([^;]+);' -or $agentText -notmatch 'SSH_AGENT_PID=([0-9]+);') {
            throw 'ssh-agent did not return SSH_AUTH_SOCK and SSH_AGENT_PID.'
        }
        $env:SSH_AUTH_SOCK = [regex]::Match($agentText, 'SSH_AUTH_SOCK=([^;]+);').Groups[1].Value
        $env:SSH_AGENT_PID = [regex]::Match($agentText, 'SSH_AGENT_PID=([0-9]+);').Groups[1].Value
        $agentStarted = $true

        & $sshAddCommand $privateKey | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'ssh-add could not load the deployment private key for Ansible ProxyJump.' }

        Write-Host "==> ansible-playbook -i $InventoryPath $Playbook (run from $ansibleDirectory; inventory vault auto-loaded)"
        Push-Location -LiteralPath $ansibleDirectory
        try {
            & $ansiblePlaybookCommand @ansibleArgs
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
        if ($exitCode -ne 0) {
            throw "ansible-playbook failed with exit code $exitCode."
        }
    }
    finally {
        if ($agentStarted) { & $sshAgentCommand -k | Out-Null }
        $env:SSH_AUTH_SOCK = $priorAuthSock
        $env:SSH_AGENT_PID = $priorAgentPid
    }
}

function Format-DeployAutoTag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$AutoDerived)
    return $(if ($AutoDerived) { '(auto-derived)' } else { '(explicit)' })
}

function Show-DeploySimpleSummary {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Context,
        [Parameter(Mandatory)][pscustomobject]$Lead,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Developers,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$MissingUsers,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$ExistingUsers,
        [Parameter(Mandatory)][bool]$StateBootstrapNeeded,
        [Parameter(Mandatory)][bool]$EntraProvisioningActive,
        [Parameter(Mandatory)][pscustomobject]$RockyMarketplaceTermsStatus
    )

    Write-Host ''
    Write-Host '=== Pre-mutation summary: review carefully before confirming ==='
    Write-Host "Subscription:            $($Context.SubscriptionId) $(Format-DeployAutoTag $Context.SubscriptionTenantAutoDerived)"
    Write-Host "Tenant:                  $($Context.TenantId) $(Format-DeployAutoTag $Context.SubscriptionTenantAutoDerived)"
    Write-Host "State administrator(s):  $($Context.StateAdministratorObjectId -join ', ') $(Format-DeployAutoTag $Context.StateAdministratorAutoDerived)"
    Write-Host "UPN domain:              $($Context.UpnDomain) $(Format-DeployAutoTag $Context.UpnDomainAutoDerived)"
    $seedNote = if ($Context.NameSeedPersistedPath) { " [persisted: $($Context.NameSeedPersistedPath)]" } else { '' }
    Write-Host "NameSeed:                $($Context.NameSeed) $(Format-DeployAutoTag $Context.NameSeedAutoDerived)$seedNote"
    Write-Host "Rocky Linux 10 image:    $($Context.RockyImageVersion) $(Format-DeployAutoTag $Context.RockyImageVersionAutoDerived)"
    Write-Host ''
    Write-Host 'Expected users (from the CSV; UPN = <slug>@<UpnDomain>):'
    Write-Host "  devops_lead: $($Lead.Upn)"
    foreach ($developer in $Developers) {
        Write-Host "  developer:   $($developer.Upn)"
    }
    Write-Host ''
    if (-not $EntraProvisioningActive) {
        Write-Host "-EntraMode is not 'existing'; this command's own Entra user creation is skipped. Ensure users and passwords are provisioned by your own process before Terraform identity lookup runs."
    }
    elseif ($MissingUsers.Count -gt 0) {
        Write-Host 'Entra users that will be CREATED now (one masked temporary-password prompt each; forced change at next sign-in):'
        foreach ($user in $MissingUsers) {
            Write-Host "  + $($user.Upn)"
        }
    }
    else {
        Write-Host 'Every expected Entra user already exists; no accounts will be created.'
    }
    if ($ExistingUsers.Count -gt 0) {
        Write-Host "Entra users that already exist (reused, never overwritten): $(($ExistingUsers | ForEach-Object Upn) -join ', ')"
    }
    Write-Host ''

    if ($RockyMarketplaceTermsStatus.Status -eq 'Accepted') {
        Write-Host 'Rocky Linux 10 Marketplace image terms: already ACCEPTED for this subscription; no separate legal confirmation will be required.'
    }
    else {
        Write-Host "Rocky Linux 10 Marketplace image terms: NOT YET accepted for this subscription. Typing 'yes' below does NOT accept them: a *separate*, exact 'ACCEPT-ROCKY-MARKETPLACE-TERMS' phrase (or -RockyMarketplaceTermsConfirmation) will be required at its own dedicated prompt, immediately before the shared-foundation Terraform apply, and this status will be re-checked independently at that point -- this disclosure never authorizes that mutation by itself. If you decline that later, separate phrase, any state backend bootstrap or Entra user creation already approved and completed just below under this 'yes' is not rolled back; a rerun detects and reuses them (idempotent) rather than repeating them."
    }
    Write-Host ''
    Write-Host 'Planned actions if confirmed:'
    Write-Host "  1. $(if ($StateBootstrapNeeded) { 'Bootstrap' } else { 'Reuse the already-bootstrapped' }) Terraform state backend ($script:StateResourceGroupName)."
    if ($EntraProvisioningActive) {
        Write-Host "  2. Create $($MissingUsers.Count) missing Entra user(s) via Az PowerShell (never Terraform; no password ever leaves this prompt)."
    }
    Write-Host "  3. Plan and apply the shared foundation, every tenant ($($Developers.Count) developer(s)), and shared reconciliation in Azure."
    if ($RockyMarketplaceTermsStatus.Status -ne 'Accepted') {
        Write-Host "  4. Before step 3's apply actually provisions any VM: require the separate ACCEPT-ROCKY-MARKETPLACE-TERMS phrase above (its own prompt, not this one) before calling Set-AzMarketplaceTerms."
    }
    Write-Host ''
}

function Confirm-DeploySimpleRun {

    [CmdletBinding()]
    param()
    $response = Read-Host -Prompt "Type 'yes' to proceed with every action above, or anything else to cancel with no changes made"
    return $response -ceq 'yes'
}

function Resolve-DeployMutationApproval {

    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool]$WhatIf,
        [Parameter(Mandatory)][bool]$ApproveSubscriptionMutations,
        [Parameter(Mandatory)][bool]$ApproveDirectoryMutations,
        [Parameter(Mandatory)][bool]$InteractiveConfirmationGranted
    )

    $explicitlyApproved = $ApproveSubscriptionMutations -and $ApproveDirectoryMutations
    $requiresInteractiveConfirmation = (-not $WhatIf) -and (-not $explicitlyApproved)
    $confirmed = $explicitlyApproved -or ($requiresInteractiveConfirmation -and $InteractiveConfirmationGranted)
    $mutationsApproved = (-not $WhatIf) -and $confirmed

    return [pscustomobject]@{
        ExplicitlyApproved              = $explicitlyApproved
        RequiresInteractiveConfirmation = $requiresInteractiveConfirmation
        MutationsApproved               = $mutationsApproved

        StateBootstrapApplyAllowed      = $mutationsApproved
        EntraUserCreationAllowed        = $mutationsApproved
        TerraformApplyAllowed           = $mutationsApproved
    }
}

function Get-DeployRockyMarketplaceTermsArmFallbackStatus {

    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $identity = "publisher '$Publisher', offer '$Product', plan '$Name', subscription '$SubscriptionId'"

    $escapedSubscriptionId = [Uri]::EscapeDataString($SubscriptionId)
    $escapedPublisher = [Uri]::EscapeDataString($Publisher)
    $escapedProduct = [Uri]::EscapeDataString($Product)
    $escapedName = [Uri]::EscapeDataString($Name)
    $armPath = "/subscriptions/$escapedSubscriptionId/providers/Microsoft.MarketplaceOrdering/agreements/$escapedPublisher/offers/$escapedProduct/plans/$escapedName" + '?api-version=2021-01-01'

    try {
        $response = Invoke-AzRestMethod -Method GET -Path $armPath -ErrorAction Stop
    }
    catch {
        throw "Could not read the Rocky Linux Marketplace agreement state via the read-only Invoke-AzRestMethod ARM fallback ($identity): $($_.Exception.Message). This is an unexpected failure and is treated as fail-closed: it is never assumed to mean the terms are already accepted."
    }

    $statusCode = 0
    if ($null -ne $response) {
        $statusCodeProperty = $response.PSObject.Properties['StatusCode']
        if ($null -ne $statusCodeProperty) { $statusCode = [int]$statusCodeProperty.Value }
    }
    if ($statusCode -lt 200 -or $statusCode -gt 299) {
        throw "The read-only Invoke-AzRestMethod ARM fallback returned an unexpected HTTP status ($statusCode) for the Rocky Linux Marketplace agreement ($identity). Treated as fail-closed: never assumed to mean the terms are already accepted."
    }

    $rawContent = $null
    if ($null -ne $response) {
        $contentProperty = $response.PSObject.Properties['Content']
        if ($null -ne $contentProperty) { $rawContent = [string]$contentProperty.Value }
    }

    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($rawContent)) {
        try {
            $parsed = $rawContent | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "The read-only Invoke-AzRestMethod ARM fallback returned a response body that could not be parsed as JSON for the Rocky Linux Marketplace agreement ($identity). Treated as fail-closed: never assumed to mean the terms are already accepted."
        }
    }
    if ($null -eq $parsed) {
        throw "The read-only Invoke-AzRestMethod ARM fallback returned an empty or unusable response body for the Rocky Linux Marketplace agreement ($identity). Treated as fail-closed: never assumed to mean the terms are already accepted."
    }

    $properties = $null
    $propertiesProperty = $parsed.PSObject.Properties['properties']
    if ($null -ne $propertiesProperty) { $properties = $propertiesProperty.Value }
    if ($null -eq $properties) {
        throw "The read-only Invoke-AzRestMethod ARM fallback response is missing a usable 'properties' object for the Rocky Linux Marketplace agreement ($identity). Treated as fail-closed: never assumed to mean the terms are already accepted."
    }

    $responsePublisher = $null
    $publisherProperty = $properties.PSObject.Properties['publisher']
    if ($null -ne $publisherProperty) { $responsePublisher = [string]$publisherProperty.Value }

    $responseOffer = $null
    $offerProperty = $properties.PSObject.Properties['offer']
    if ($null -ne $offerProperty) { $responseOffer = [string]$offerProperty.Value }

    $responsePlan = $null
    $nameProperty = $parsed.PSObject.Properties['name']
    if ($null -ne $nameProperty) { $responsePlan = [string]$nameProperty.Value }

    if ([string]::IsNullOrEmpty($responsePublisher) -or $responsePublisher -ne $Publisher -or
        [string]::IsNullOrEmpty($responseOffer) -or $responseOffer -ne $Product -or
        [string]::IsNullOrEmpty($responsePlan) -or $responsePlan -ne $Name) {
        throw "The read-only Invoke-AzRestMethod ARM fallback returned an agreement whose publisher/offer/plan identity does not exactly match the one requested ($identity). Treated as fail-closed: never assumed to mean the terms are already accepted."
    }

    $responseState = $null
    $stateProperty = $properties.PSObject.Properties['state']
    if ($null -ne $stateProperty) { $responseState = $stateProperty.Value }
    if (($responseState -isnot [string]) -or [string]::IsNullOrWhiteSpace($responseState)) {
        throw "The read-only Invoke-AzRestMethod ARM fallback response is missing a usable 'properties.state' value for the Rocky Linux Marketplace agreement ($identity). Treated as fail-closed: never assumed to mean the terms are already accepted."
    }

    if ($responseState -ieq 'Active') {
        return [pscustomobject]@{ Status = 'Accepted' }
    }
    return [pscustomobject]@{ Status = 'NotAccepted' }
}

function Get-DeployRockyMarketplaceTermsStatus {

    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    try {
        $terms = Get-AzMarketplaceTerms -Publisher $Publisher -Product $Product -Name $Name -SubscriptionId $SubscriptionId -ErrorAction Stop
    }
    catch {
        $exceptionMessage = [string]$_.Exception.Message
        if ($exceptionMessage -imatch 'never been signed') {
            return [pscustomobject]@{ Status = 'NotAccepted'; Terms = $null }
        }
        throw "Could not read Rocky Linux Marketplace terms (publisher '$Publisher', offer '$Product', plan '$Name', subscription '$SubscriptionId') via ``Get-AzMarketplaceTerms`` ($exceptionMessage). This is an unexpected failure -- not the known (Az.MarketplaceOrdering 2.2.0-verified) 'agreement has never been signed' case -- and is treated as fail-closed: it is never assumed to mean the terms are already accepted. Verify the Az.MarketplaceOrdering module is installed and the signed-in principal can read Marketplace agreements for this subscription, then retry."
    }

    $acceptedValue = $null
    if ($null -ne $terms) {
        $acceptedProperty = $terms.PSObject.Properties['Accepted']
        if ($null -ne $acceptedProperty) { $acceptedValue = $acceptedProperty.Value }
    }

    if ($null -ne $acceptedValue) {

        return [pscustomobject]@{ Status = $(if ([bool]$acceptedValue) { 'Accepted' } else { 'NotAccepted' }); Terms = $terms }
    }

    $armStatus = Get-DeployRockyMarketplaceTermsArmFallbackStatus -Publisher $Publisher -Product $Product -Name $Name -SubscriptionId $SubscriptionId
    return [pscustomobject]@{ Status = $armStatus.Status; Terms = $terms }
}

function Show-DeployRockyMarketplaceTermsGuidance {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Name
    )
    Write-Host ''
    Write-Host '=== Rocky Linux 10 Azure Marketplace image terms: not yet accepted for this subscription ==='
    Write-Host "Subscription ID:  $SubscriptionId"
    Write-Host "Publisher:        $Publisher"
    Write-Host "Offer (product):  $Product"
    Write-Host "Plan (SKU/name):  $Name"
    Write-Host ''
    Write-Host 'This is a subscription-level LEGAL agreement between you and the image publisher, separate from every other confirmation in this command. Review it yourself, independently, before accepting:'
    Write-Host "  Azure Marketplace listing:      https://azuremarketplace.microsoft.com/en-us/marketplace/apps/$Publisher.$Product"
    Write-Host '  Azure Portal (per-subscription): portal.azure.com -> Subscriptions -> <this subscription> -> Legal terms (Settings)'
    Write-Host "  Inspect programmatically:        Get-AzMarketplaceTerms -Publisher $Publisher -Product $Product -Name $Name -SubscriptionId $SubscriptionId"
    Write-Host ''
    Write-Host "This command never accepts these terms automatically. If -- and only if -- you have already reviewed and agree to them for this exact subscription, type the exact phrase below (or rerun with -RockyMarketplaceTermsConfirmation '$script:RockyMarketplaceTermsConfirmationPhrase' for non-interactive automation) to accept them now via Set-AzMarketplaceTerms; anything else cancels with no terms mutation."
    Write-Host ''
}

function Confirm-DeployRockyMarketplaceTermsPhrase {

    [CmdletBinding()]
    param()
    $response = Read-Host -Prompt "Type '$script:RockyMarketplaceTermsConfirmationPhrase' to accept the Rocky Linux 10 Marketplace legal terms above for this subscription now, or anything else to cancel with no terms mutation"
    return $response -ceq $script:RockyMarketplaceTermsConfirmationPhrase
}

function Resolve-DeployRockyMarketplaceTermsApproval {

    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool]$WhatIf,
        [Parameter(Mandatory)][ValidateSet('Accepted', 'NotAccepted')][string]$TermsStatus,
        [Parameter(Mandatory)][bool]$ConfirmationPhraseSuppliedMatches,
        [Parameter(Mandatory)][bool]$InteractiveConfirmationGranted
    )

    $alreadyAccepted = $TermsStatus -eq 'Accepted'
    $requiresInteractiveConfirmation = (-not $WhatIf) -and (-not $alreadyAccepted) -and (-not $ConfirmationPhraseSuppliedMatches)
    $approvedToAccept = (-not $WhatIf) -and (-not $alreadyAccepted) -and ($ConfirmationPhraseSuppliedMatches -or ($requiresInteractiveConfirmation -and $InteractiveConfirmationGranted))

    return [pscustomobject]@{
        AlreadyAccepted                  = $alreadyAccepted
        RequiresInteractiveConfirmation  = $requiresInteractiveConfirmation
        ApprovedToAccept                 = $approvedToAccept
    }
}

function Set-DeployRockyMarketplaceTermsAccepted {

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    if (-not $PSCmdlet.ShouldProcess("Rocky Linux Marketplace terms ($Publisher/$Product/$Name) for subscription $SubscriptionId", 'Accept legal terms (Set-AzMarketplaceTerms -Accept)')) {
        throw 'Rocky Linux Marketplace terms acceptance was not confirmed; refusing to call Set-AzMarketplaceTerms.'
    }

    $setResult = $null
    try {
        $setResult = Set-AzMarketplaceTerms -Publisher $Publisher -Product $Product -Name $Name -SubscriptionId $SubscriptionId -Accept -ErrorAction Stop
    }
    catch {
        throw "Set-AzMarketplaceTerms failed for Rocky Linux ($Publisher/$Product/$Name, subscription $SubscriptionId): $($_.Exception.Message). No further mutation was attempted; the terms are not confirmed accepted."
    }

    $setAccepted = $false
    if ($null -ne $setResult) {
        $acceptedProperty = $setResult.PSObject.Properties['Accepted']
        if ($null -ne $acceptedProperty) { $setAccepted = [bool]$acceptedProperty.Value }
    }
    if (-not $setAccepted) {
        throw "Set-AzMarketplaceTerms did not report Accepted=true in its own response for Rocky Linux ($Publisher/$Product/$Name, subscription $SubscriptionId); refusing to continue. Verify the terms manually in the Azure Portal before retrying."
    }

    $readBack = Get-DeployRockyMarketplaceTermsStatus -Publisher $Publisher -Product $Product -Name $Name -SubscriptionId $SubscriptionId
    if ($readBack.Status -ne 'Accepted') {
        throw "Set-AzMarketplaceTerms reported success, but an independent read-back (Get-AzMarketplaceTerms) still does not show Accepted=true for Rocky Linux ($Publisher/$Product/$Name, subscription $SubscriptionId); refusing to continue. Verify the terms manually in the Azure Portal before retrying."
    }
    Write-Host "Rocky Linux 10 Marketplace terms accepted for subscription $SubscriptionId (confirmed by both the Set-AzMarketplaceTerms response and an independent read-back)."
}

function Get-DeployRockyMarketplaceTermsStandingApproval {

    # Reads the tracked, non-secret standing-approval config file (never a required CLI flag).
    # Fail-closed by construction: any outcome other than "the file exists, parses as JSON, its
    # 'accepted' property is the exact JSON boolean true, AND its publisher/offer/sku match the
    # exact image identity requested" returns Accepted = $false, which leaves the existing
    # interactive / -RockyMarketplaceTermsConfirmation gate completely unchanged. A present but
    # unparseable file throws (a corrupt, human-edited config is never silently ignored); a
    # missing file is the ordinary "no standing approval recorded" case and never throws.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Accepted = $false }
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The Rocky Linux Marketplace terms standing-approval config at '$Path' is not valid JSON ($($_.Exception.Message)). This is a tracked, human-edited file, not a secret -- fix or remove it before continuing. Refusing to treat an unparseable config as any kind of approval."
    }

    $acceptedValue = $null
    $acceptedProperty = $parsed.PSObject.Properties['accepted']
    if ($null -ne $acceptedProperty) { $acceptedValue = $acceptedProperty.Value }

    if (($acceptedValue -isnot [bool]) -or ($acceptedValue -ne $true)) {
        # Absent, false, or anything other than the literal JSON boolean true (a string "true",
        # a number, null, ...) never auto-accepts anything.
        return [pscustomobject]@{ Accepted = $false }
    }

    $configuredPublisher = $null
    $publisherProperty = $parsed.PSObject.Properties['publisher']
    if ($null -ne $publisherProperty) { $configuredPublisher = [string]$publisherProperty.Value }

    $configuredOffer = $null
    $offerProperty = $parsed.PSObject.Properties['offer']
    if ($null -ne $offerProperty) { $configuredOffer = [string]$offerProperty.Value }

    $configuredSku = $null
    $skuProperty = $parsed.PSObject.Properties['sku']
    if ($null -ne $skuProperty) { $configuredSku = [string]$skuProperty.Value }

    $identityMatches = ($configuredPublisher -ceq $Publisher) -and ($configuredOffer -ceq $Product) -and ($configuredSku -ceq $Name)
    if (-not $identityMatches) {
        # The recorded standing approval is bound to a different exact publisher/offer/sku than
        # the one being deployed; never let it auto-accept a different image on its behalf.
        return [pscustomobject]@{ Accepted = $false }
    }

    return [pscustomobject]@{ Accepted = $true }
}

function Invoke-DeployRockyMarketplaceTermsGate {

    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][bool]$WhatIf,
        [AllowEmptyString()][AllowNull()][string]$TermsConfirmation,
        [string]$StandingApprovalConfigPath = $script:RockyMarketplaceTermsStandingApprovalConfigPath
    )

    $status = Get-DeployRockyMarketplaceTermsStatus -Publisher $Publisher -Product $Product -Name $Name -SubscriptionId $SubscriptionId

    if ($status.Status -eq 'Accepted') {
        Write-Host "Rocky Linux 10 Marketplace terms ($Publisher/$Product/$Name) are already accepted for subscription $SubscriptionId; continuing without any prompt or mutation."
        return [pscustomobject]@{ AlreadyAccepted = $true; Accepted = $true }
    }

    if ($WhatIf) {
        Show-DeployRockyMarketplaceTermsGuidance -SubscriptionId $SubscriptionId -Publisher $Publisher -Product $Product -Name $Name
        Write-Host 'PLANNED (legal blocker): Rocky Linux 10 Marketplace terms are not yet accepted for this subscription. -WhatIf never calls Set-AzMarketplaceTerms (even under a recorded standing approval) and never prompts; a real (non-WhatIf) run will auto-accept under a matching recorded standing approval, or otherwise require a separate, explicit ACCEPT-ROCKY-MARKETPLACE-TERMS confirmation before the shared foundation can be applied.'
        return [pscustomobject]@{ AlreadyAccepted = $false; Accepted = $false }
    }

    $standingApproval = Get-DeployRockyMarketplaceTermsStandingApproval -Path $StandingApprovalConfigPath -Publisher $Publisher -Product $Product -Name $Name
    if ($standingApproval.Accepted) {
        Write-Host "AUTO-ACCEPTED (recorded standing approval): the Rocky Linux 10 Marketplace legal terms for publisher '$Publisher', offer '$Product', sku '$Name' were accepted automatically under the repository owner's recorded standing approval; no interactive prompt was shown."
        Set-DeployRockyMarketplaceTermsAccepted -Publisher $Publisher -Product $Product -Name $Name -SubscriptionId $SubscriptionId -Confirm:$false
        return [pscustomobject]@{ AlreadyAccepted = $false; Accepted = $true }
    }

    $confirmationPhraseSuppliedMatches = (-not [string]::IsNullOrEmpty($TermsConfirmation)) -and ($TermsConfirmation -ceq $script:RockyMarketplaceTermsConfirmationPhrase)
    $decision = Resolve-DeployRockyMarketplaceTermsApproval -WhatIf $false -TermsStatus $status.Status `
        -ConfirmationPhraseSuppliedMatches $confirmationPhraseSuppliedMatches -InteractiveConfirmationGranted $false

    if ($decision.RequiresInteractiveConfirmation) {
        Show-DeployRockyMarketplaceTermsGuidance -SubscriptionId $SubscriptionId -Publisher $Publisher -Product $Product -Name $Name
        $granted = Confirm-DeployRockyMarketplaceTermsPhrase
        $decision = Resolve-DeployRockyMarketplaceTermsApproval -WhatIf $false -TermsStatus $status.Status `
            -ConfirmationPhraseSuppliedMatches $confirmationPhraseSuppliedMatches -InteractiveConfirmationGranted $granted
    }

    if (-not $decision.ApprovedToAccept) {
        throw "Rocky Linux 10 Marketplace legal terms ($Publisher/$Product/$Name) are not accepted for subscription $SubscriptionId, and acceptance was not confirmed (declined, or the confirmation phrase did not match exactly). No terms mutation was made. Aborting before any Terraform apply; rerun and type the exact phrase to accept, supply -RockyMarketplaceTermsConfirmation '$script:RockyMarketplaceTermsConfirmationPhrase' for automation, or accept the terms independently (Azure Portal / Set-AzMarketplaceTerms) before retrying."
    }

    Set-DeployRockyMarketplaceTermsAccepted -Publisher $Publisher -Product $Product -Name $Name -SubscriptionId $SubscriptionId -Confirm:$false
    return [pscustomobject]@{ AlreadyAccepted = $false; Accepted = $true }
}

function Resolve-DeployDestroyAllApproval {

    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool]$WhatIf,
        [Parameter(Mandatory)][bool]$ConfirmationPhraseSuppliedMatches,
        [Parameter(Mandatory)][bool]$InteractiveConfirmationGranted
    )

    $requiresInteractiveConfirmation = (-not $WhatIf) -and (-not $ConfirmationPhraseSuppliedMatches)
    $approved = (-not $WhatIf) -and ($ConfirmationPhraseSuppliedMatches -or ($requiresInteractiveConfirmation -and $InteractiveConfirmationGranted))

    return [pscustomobject]@{
        RequiresInteractiveConfirmation = $requiresInteractiveConfirmation
        Approved                        = $approved
    }
}

function Confirm-DeployDestroyAllRun {
    [CmdletBinding()]
    param()
    $response = Read-Host -Prompt "Type '$script:DestroyAllConfirmationPhrase' to permanently destroy every resource and script-created Entra user listed above, or anything else to cancel with no changes made"
    return $response -ceq $script:DestroyAllConfirmationPhrase
}

function Test-DeployBackendAbsent {

    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PreflightOutput)
    return $PreflightOutput -match 'state_resource_group_missing|state_storage_account_missing'
}

function Test-DeployStateBootstrapNeeded {

    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$PreflightExitCode,
        [Parameter(Mandatory)][bool]$BackendConfigExists
    )
    return ($PreflightExitCode -ne 0) -or (-not $BackendConfigExists)
}

function Get-DeployDestroyAllResourceGroupNames {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Developers,
        [string]$LocationShortName = 'weu'
    )

    $tenantResourceGroups = [ordered]@{}
    foreach ($developer in $Developers) {
        $tenantResourceGroups[$developer.Slug] = "rg-ts-$($developer.Slug)-testing-$LocationShortName"
    }
    return [pscustomobject]@{
        State   = $script:StateResourceGroupName
        Shared  = "rg-ts-shared-testing-$LocationShortName"
        Tenants = $tenantResourceGroups
    }
}

function Get-DeployDestroyAllStateStorageAccountName {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NameSeed)
    $bytes = [Text.Encoding]::UTF8.GetBytes("${NameSeed}:state")
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return "sttsstateb$($hash.Substring(0, 4))"
}

function Get-DeployBackendConfigValues {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $result = @{ ResourceGroupName = ''; StorageAccountName = ''; ContainerName = '' }
    foreach ($line in ($content -split "`n")) {
        if ($line -match '^\s*resource_group_name\s*=\s*"([^"]*)"') { $result.ResourceGroupName = $Matches[1] }
        if ($line -match '^\s*storage_account_name\s*=\s*"([^"]*)"') { $result.StorageAccountName = $Matches[1] }
        if ($line -match '^\s*container_name\s*=\s*"([^"]*)"') { $result.ContainerName = $Matches[1] }
    }
    if ([string]::IsNullOrWhiteSpace($result.ResourceGroupName) -or [string]::IsNullOrWhiteSpace($result.StorageAccountName) -or [string]::IsNullOrWhiteSpace($result.ContainerName)) {
        throw "Could not parse resource_group_name/storage_account_name/container_name from '$Path'."
    }
    return [pscustomobject]$result
}

function Test-DeployPreflightConclusivelyPass {

    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$PreflightExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PreflightOutput
    )
    return ($PreflightExitCode -eq 0) -and ($PreflightOutput -match '"status"\s*:\s*"PASS"')
}

function Repair-DeployBackendConfigFile {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$PreflightExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PreflightOutput,
        [Parameter(Mandatory)][string]$BackendConfigPath,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$StorageAccountName,
        [Parameter(Mandatory)][string]$ContainerName
    )

    if (-not (Test-DeployPreflightConclusivelyPass -PreflightExitCode $PreflightExitCode -PreflightOutput $PreflightOutput)) {
        return
    }

    $expectedContent = @(
        "resource_group_name  = `"$ResourceGroupName`""
        "storage_account_name = `"$StorageAccountName`""
        "container_name       = `"$ContainerName`""
        'use_azuread_auth     = true'
    ) -join [Environment]::NewLine

    if (Test-Path -LiteralPath $BackendConfigPath -PathType Leaf) {
        $actualContent = Get-Content -LiteralPath $BackendConfigPath -Raw -Encoding utf8
        if ($actualContent -cne $expectedContent) {
            throw "BLOCKED: '$BackendConfigPath' already exists but does not match the expected canonical backend identity (resource_group_name='$ResourceGroupName', storage_account_name='$StorageAccountName', container_name='$ContainerName') that Preflight just independently confirmed for this exact subscription/tenant/-NameSeed context. Refusing to overwrite it: investigate by hand (confirm the correct -NameSeed, or restore the correct backend.hcl) before rerunning -DestroyAll."
        }
        return
    }

    Set-Content -LiteralPath $BackendConfigPath -Value $expectedContent -Encoding utf8 -NoNewline -ErrorAction Stop
    Set-DeployUnixPermissions -Path $BackendConfigPath -Mode '600'
    Write-Host "Recovered missing local '$BackendConfigPath': Preflight independently confirmed the Azure-side state backend already exists with this exact identity, so no Azure resource was created or modified -- only this one local, non-secret file was (re)written."
}

function Get-DeployBackendTenantStateKeys {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorageAccountName,
        [Parameter(Mandatory)][string]$ContainerName
    )
    $context = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop
    $blobs = @(Get-AzStorageBlob -Container $ContainerName -Prefix 'tenants/' -Context $context -ErrorAction Stop)
    return @($blobs | ForEach-Object { [string]$_.Name })
}

function Get-DeployOrphanedTenantStateSlugs {

    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$BlobNames,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$KnownSlugs
    )
    $knownSet = [Collections.Generic.HashSet[string]]::new([string[]]$KnownSlugs, [StringComparer]::OrdinalIgnoreCase)
    $slugs = [Collections.Generic.List[string]]::new()
    foreach ($name in $BlobNames) {
        if ($name -match '^tenants/([a-z0-9]+(?:-[a-z0-9]+)*)\.tfstate$') {
            $slug = $Matches[1]
            if (-not $knownSet.Contains($slug)) {
                $slugs.Add($slug)
            }
        }
    }
    return @($slugs | Sort-Object -Unique)
}

function Test-DeployCanonicalProjectTags {

    [CmdletBinding()]
    param([Parameter()][AllowNull()]$ActualTags)

    if ($null -eq $ActualTags) { return $false }
    $required = [ordered]@{ project = 'techsprint'; environment = 'testing'; 'managed-by' = 'terraform'; cloud = 'azure' }
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

function Get-DeployAllResourceGroups {

    [CmdletBinding()]
    param()
    return @(Get-AzResourceGroup -ErrorAction Stop)
}

function Get-DeployBackendAbsentResourceGroupConflicts {

    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][pscustomobject]$ResourceGroupNames)

    $candidateNames = [Collections.Generic.List[string]]::new()
    $candidateNames.Add([string]$ResourceGroupNames.Shared)
    foreach ($name in @($ResourceGroupNames.Tenants.Values)) {
        $candidateNames.Add([string]$name)
    }
    $candidateSet = [Collections.Generic.HashSet[string]]::new([string[]]$candidateNames, [StringComparer]::OrdinalIgnoreCase)

    $conflicts = [Collections.Generic.List[string]]::new()
    foreach ($group in @(Get-DeployAllResourceGroups)) {
        $name = [string]$group.ResourceGroupName
        if ($candidateSet.Contains($name) -and (Test-DeployCanonicalProjectTags -ActualTags $group.Tags)) {
            $conflicts.Add($name)
        }
    }
    return @($conflicts | Sort-Object -Unique)
}

function Get-DeployPlanResourceChanges {

    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$PlanFile
    )
    Push-Location -LiteralPath $RootPath
    try {
        $json = & terraform show -json $PlanFile 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($json -join ''))) {
        throw "Unable to inspect saved plan '$PlanFile' in $RootPath (exit $exitCode): $($json -join [Environment]::NewLine)"
    }
    $parsed = ($json -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -Depth 100

    $resourceChanges = @()
    if ($parsed.ContainsKey('resource_changes')) {
        $resourceChanges = @($parsed.resource_changes)
    }
    return @($resourceChanges | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.mode) -or [string]$_.mode -ceq 'managed'
        })
}

function Test-DeployAddressIsSharedDetachResource {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Address)

    return $Address.StartsWith('azurerm_private_dns_zone_virtual_network_link.tenant[', [StringComparison]::Ordinal) -or
        $Address.StartsWith('module.network.azurerm_virtual_network_peering.hub_to_tenant[', [StringComparison]::Ordinal) -or
        $Address.StartsWith('module.app_gateway.azurerm_', [StringComparison]::Ordinal)
}

function Test-DeployPlanHasSharedDetachChanges {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$PlanFile
    )

    foreach ($change in @(Get-DeployPlanResourceChanges -RootPath $RootPath -PlanFile $PlanFile)) {
        $actions = @($change.change.actions)
        if (-not ($actions.Count -eq 1 -and [string]$actions[0] -ceq 'no-op') -and
            (Test-DeployAddressIsSharedDetachResource -Address ([string]$change.address))) {
            return $true
        }
    }
    return $false
}

function Test-DeployPlanHasResourceChanges {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$PlanFile
    )
    $changes = @(Get-DeployPlanResourceChanges -RootPath $RootPath -PlanFile $PlanFile | Where-Object {
            -not (@($_.change.actions).Count -eq 1 -and [string]@($_.change.actions)[0] -ceq 'no-op')
        })
    return $changes.Count -gt 0
}

function Get-DeployPlanUnexpectedActions {

    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$PlanFile,
        [Parameter(Mandatory)][string[]]$AllowedActions
    )
    $allowedSet = [Collections.Generic.HashSet[string]]::new([string[]]$AllowedActions, [StringComparer]::Ordinal)
    $unexpected = [Collections.Generic.List[string]]::new()
    foreach ($change in @(Get-DeployPlanResourceChanges -RootPath $RootPath -PlanFile $PlanFile)) {
        foreach ($action in @($change.change.actions)) {
            if (-not $allowedSet.Contains([string]$action)) {
                $unexpected.Add([string]$change.address)
                break
            }
        }
    }
    return @($unexpected | Sort-Object -Unique)
}

function Get-DeploySharedTerraformStateJson {

    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RootPath)

    Push-Location -LiteralPath $RootPath
    try {
        $json = & terraform show -json 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exitCode -ne 0) {
        throw "terraform show -json failed for the Terraform state in $RootPath (exit $exitCode): $($json -join [Environment]::NewLine)"
    }
    $text = ($json -join [Environment]::NewLine)
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "terraform show -json produced no output for the Terraform state in $RootPath."
    }
    return ($text | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Get-DeployStateResourceCount {

    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()]$RootModule)

    if ($null -eq $RootModule) { return 0 }
    $count = 0
    if ($RootModule.ContainsKey('resources')) {
        $count += @($RootModule['resources']).Count
    }
    if ($RootModule.ContainsKey('child_modules')) {
        foreach ($child in @($RootModule['child_modules'])) {
            $count += Get-DeployStateResourceCount -RootModule $child
        }
    }
    return $count
}

function Get-DeployStateResourceAddresses {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()]$RootModule)

    if ($null -eq $RootModule) { return @() }
    $addresses = [Collections.Generic.List[string]]::new()
    if ($RootModule.ContainsKey('resources')) {
        foreach ($resource in @($RootModule['resources'])) {
            $addresses.Add([string]$resource['address'])
        }
    }
    if ($RootModule.ContainsKey('child_modules')) {
        foreach ($child in @($RootModule['child_modules'])) {
            foreach ($address in @(Get-DeployStateResourceAddresses -RootModule $child)) {
                $addresses.Add($address)
            }
        }
    }
    return @($addresses)
}

function Test-DeployStateHasSharedDetachResources {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$RootModule)

    foreach ($address in @(Get-DeployStateResourceAddresses -RootModule $RootModule)) {
        if (Test-DeployAddressIsSharedDetachResource -Address $address) {
            return $true
        }
    }
    return $false
}

function Find-DeployStateResourceByAddress {

    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$RootModule,
        [Parameter(Mandatory)][string]$Address
    )

    if ($null -eq $RootModule) { return $null }
    if ($RootModule.ContainsKey('resources')) {
        foreach ($resource in @($RootModule['resources'])) {
            if ([string]$resource['address'] -ceq $Address) { return $resource }
        }
    }
    if ($RootModule.ContainsKey('child_modules')) {
        foreach ($child in @($RootModule['child_modules'])) {
            $found = Find-DeployStateResourceByAddress -RootModule $child -Address $Address
            if ($null -ne $found) { return $found }
        }
    }
    return $null
}

function Get-DeployStateResourceAdminSshPublicKey {

    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Resource,
        [Parameter(Mandatory)][string]$HostLabel
    )

    $values = $Resource['values']
    if ($null -eq $values -or -not $values.ContainsKey('admin_ssh_key')) {
        throw "the shared Terraform state's '$HostLabel' compute resource has no 'admin_ssh_key' value; refusing to build a shared-detach plan without it (a placeholder key could force VM replacement)."
    }
    $keys = @($values['admin_ssh_key'])
    if ($keys.Count -ne 1) {
        throw "the shared Terraform state's '$HostLabel' compute resource has $($keys.Count) admin_ssh_key entries (expected exactly 1); refusing to guess which is authoritative."
    }
    $publicKey = [string]$keys[0]['public_key']
    if ([string]::IsNullOrWhiteSpace($publicKey)) {
        throw "the shared Terraform state's '$HostLabel' compute resource has an empty admin_ssh_key.public_key; refusing to build a shared-detach plan without it."
    }
    return $publicKey
}

function Get-DeployStateResourceSourceImage {

    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Resource,
        [Parameter(Mandatory)][string]$HostLabel
    )

    $values = $Resource['values']
    if ($null -eq $values -or -not $values.ContainsKey('source_image_reference')) {
        throw "the shared Terraform state's '$HostLabel' compute resource has no 'source_image_reference' value; refusing to build a shared-detach plan without it (a placeholder/incorrect image version could force VM replacement)."
    }
    $references = @($values['source_image_reference'])
    if ($references.Count -ne 1) {
        throw "the shared Terraform state's '$HostLabel' compute resource has $($references.Count) source_image_reference entries (expected exactly 1); refusing to guess which is authoritative."
    }
    $reference = $references[0]
    foreach ($key in @('publisher', 'offer', 'sku', 'version')) {
        if (-not $reference.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$reference[$key])) {
            throw "the shared Terraform state's '$HostLabel' compute resource has an empty source_image_reference.$key; refusing to build a shared-detach plan without it."
        }
    }
    return [pscustomobject]@{
        Publisher = [string]$reference['publisher']
        Offer     = [string]$reference['offer']
        Sku       = [string]$reference['sku']
        Version   = [string]$reference['version']
    }
}

function Get-DeploySharedDetachStateFacts {

    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SharedTfvarsPath,
        [Parameter(Mandatory)][string]$ResolvedWorkDir,
        [Parameter(Mandatory)][string[]]$CommonRunnerArgs
    )

    $stateProbePlanPath = Join-Path $ResolvedWorkDir 'shared-detach-state-probe.tfplan'
    Invoke-DeployRunner -RunnerArgs (@('-Command', 'Plan', '-Root', 'shared', '-VarFile', $SharedTfvarsPath, '-PlanFile', $stateProbePlanPath) + $CommonRunnerArgs) | Out-Null

    $state = Get-DeploySharedTerraformStateJson -RootPath $SharedRootPath
    if (-not $state.ContainsKey('values') -or $null -eq $state['values']) {
        return [pscustomobject]@{ HasResources = $false }
    }
    $rootModule = $state['values']['root_module']
    if ((Get-DeployStateResourceCount -RootModule $rootModule) -eq 0) {
        return [pscustomobject]@{ HasResources = $false }
    }

    if (-not (Test-DeployStateHasSharedDetachResources -RootModule $rootModule)) {
        return [pscustomobject]@{ HasResources = $true; HasDetachResources = $false }
    }

    $jumpAddress = 'module.compute.azurerm_linux_virtual_machine.host["jump"]'
    $leadAddress = 'module.compute.azurerm_linux_virtual_machine.host["lead"]'
    $jumpResource = Find-DeployStateResourceByAddress -RootModule $rootModule -Address $jumpAddress
    $leadResource = Find-DeployStateResourceByAddress -RootModule $rootModule -Address $leadAddress
    if ($null -eq $jumpResource -or $null -eq $leadResource) {
        throw "the shared Terraform state is not empty, but the expected Jump/Lead compute resources ('$jumpAddress', '$leadAddress') could not both be found in it. Refusing to build a shared-detach plan without their exact deployed admin_ssh_key/rocky_image values -- a placeholder could force VM replacement. Investigate the shared Terraform state by hand (terraform state list, in infra/azure/shared) before rerunning -DestroyAll."
    }

    $jumpKey = Get-DeployStateResourceAdminSshPublicKey -Resource $jumpResource -HostLabel 'jump'
    $leadKey = Get-DeployStateResourceAdminSshPublicKey -Resource $leadResource -HostLabel 'lead'
    if ($jumpKey -cne $leadKey) {
        throw "the shared Terraform state has different admin_ssh_key values for Jump and Lead, but infra/azure/shared/main.tf always derives both from the single var.lead_ssh_public_key. Refusing to guess which is authoritative; investigate the shared Terraform state by hand before rerunning -DestroyAll."
    }

    $jumpImage = Get-DeployStateResourceSourceImage -Resource $jumpResource -HostLabel 'jump'
    $leadImage = Get-DeployStateResourceSourceImage -Resource $leadResource -HostLabel 'lead'
    foreach ($field in @('Publisher', 'Offer', 'Sku', 'Version')) {
        if ([string]$jumpImage.$field -cne [string]$leadImage.$field) {
            throw "the shared Terraform state has different source_image_reference.$($field.ToLowerInvariant()) values for Jump and Lead. Refusing to guess which is authoritative; investigate the shared Terraform state by hand before rerunning -DestroyAll."
        }
    }

    return [pscustomobject]@{
        HasResources       = $true
        HasDetachResources = $true
        LeadSshPublicKey   = $jumpKey
        RockyImage         = $jumpImage
    }
}

function Get-DeployResidualManagedState {

    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$SharedTfvarsPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Developers,
        [Parameter(Mandatory)][string]$NameSeed,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$LocationShortName,
        [Parameter(Mandatory)][string]$VmSku,
        [Parameter(Mandatory)][string]$PlaceholderKeyPath,
        [Parameter(Mandatory)][string]$TenantsDir,
        [Parameter(Mandatory)][string]$ResolvedWorkDir,
        [Parameter(Mandatory)][string[]]$CommonRunnerArgs
    )

    $residual = [Collections.Generic.List[string]]::new()

    $sharedVerifyPlanPath = Join-Path $ResolvedWorkDir 'shared.destroy-verify.tfplan'
    Invoke-DeployRunner -RunnerArgs (@('-Command', 'Plan', '-Root', 'shared', '-VarFile', $SharedTfvarsPath, '-DestroyPlan', '-PlanFile', $sharedVerifyPlanPath) + $CommonRunnerArgs) | Out-Null
    if (Test-DeployPlanHasResourceChanges -RootPath $SharedRootPath -PlanFile $sharedVerifyPlanPath) {
        $residual.Add('shared')
    }

    foreach ($developer in $Developers) {
        $tenantTfvarsPath = Join-Path $TenantsDir "$($developer.Slug).tfvars"
        if (-not (Test-Path -LiteralPath $tenantTfvarsPath -PathType Leaf)) {

            $tenantTfvarsContent = New-TenantTfvarsContent -Location $Location -LocationShortName $LocationShortName -VmSku $VmSku -NameSeed $NameSeed -Developer $developer `
                -AllDevelopers $Developers -SharedValues $script:DestroyAllPlaceholderSharedValues -DeveloperSshPublicKeyAbsolutePath $PlaceholderKeyPath `
                -LeadSshPublicKeyAbsolutePath $PlaceholderKeyPath -RockyImage ([pscustomobject]@{
                    Publisher = $RockyImagePublisher; Offer = $RockyImageOffer; Sku = $RockyImageSku; Version = $script:DestroyAllPlaceholderRockyVersion
                })
            Set-Content -LiteralPath $tenantTfvarsPath -Value $tenantTfvarsContent -Encoding utf8 -NoNewline
        }
        $tenantVerifyPlanPath = Join-Path $ResolvedWorkDir "tenant-$($developer.Slug).destroy-verify.tfplan"
        $priorMoodle = $env:TF_VAR_moodle_database_password
        $env:TF_VAR_moodle_database_password = $script:DestroyAllPlaceholderPassword
        try {
            Invoke-DeployRunner -RunnerArgs (@('-Command', 'Plan', '-Root', 'tenant', '-TenantSlug', $developer.Slug, '-VarFile', $tenantTfvarsPath, '-DestroyPlan', '-PlanFile', $tenantVerifyPlanPath) + $CommonRunnerArgs) | Out-Null
            if (Test-DeployPlanHasResourceChanges -RootPath $TenantRootPath -PlanFile $tenantVerifyPlanPath) {
                $residual.Add("tenant:$($developer.Slug)")
            }
        }
        finally {
            $env:TF_VAR_moodle_database_password = $priorMoodle
        }
    }

    return @($residual)
}

function Remove-DeployStateBackend {

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$StorageAccountName,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StateAdministratorObjectId
    )

    . $BootstrapScript -SubscriptionId '00000000-0000-0000-0000-000000000000' -TenantId '00000000-0000-0000-0000-000000000000' `
        -NameSeed 'placeholder-unused-seed-for-dot-source-only' -StateAdministratorObjectId '00000000-0000-0000-0000-000000000000' -PreflightOnly

    $matchingResourceGroups = @(Get-AzResourceGroup -ErrorAction Stop | Where-Object { $_.ResourceGroupName -ieq $ResourceGroupName })
    if ($matchingResourceGroups.Count -eq 0) {
        Write-Host "State resource group '$ResourceGroupName' does not exist; nothing to retire."
        return
    }
    $resourceGroup = $matchingResourceGroups[0]
    if (-not (Test-CanonicalTags $resourceGroup.Tags)) {
        throw "Refusing to retire state resource group '$ResourceGroupName': its tags do not match the canonical bootstrap tags. This does not look like the resource group bootstrap/Initialize-AzureTerraformState.ps1 created; investigate and remove it by hand only after independent verification."
    }

    $resourcesInGroup = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    $unexpected = @($resourcesInGroup | Where-Object { -not ($_.ResourceType -ieq 'Microsoft.Storage/storageAccounts' -and $_.Name -ieq $StorageAccountName) })
    if ($unexpected.Count -gt 0) {
        $unexpectedList = ($unexpected | ForEach-Object { "$($_.ResourceType)/$($_.Name)" }) -join ', '
        throw "Refusing to retire state resource group '$ResourceGroupName': it contains unexpected resource(s) beyond the one expected storage account '$StorageAccountName' ($unexpectedList). Investigate and remove those by hand first."
    }

    $matchingStorageAccounts = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Where-Object { $_.StorageAccountName -ieq $StorageAccountName })
    if ($matchingStorageAccounts.Count -eq 0) {
        Write-Host "State storage account '$StorageAccountName' does not exist under '$ResourceGroupName'; removing the empty resource group only."
        if ($PSCmdlet.ShouldProcess("resource group $ResourceGroupName", 'Remove empty canonical state resource group')) {
            Remove-AzResourceGroup -Name $ResourceGroupName -Force -ErrorAction Stop | Out-Null
        }
        return
    }
    $account = $matchingStorageAccounts[0]
    if (-not (Test-CanonicalStorageAccount $account)) {
        throw "Refusing to retire storage account '$StorageAccountName': it does not match the canonical hardened bootstrap configuration (Azure AD-only, no shared key/local user/SFTP, TLS 1.2). This does not look like the account bootstrap/Initialize-AzureTerraformState.ps1 created; investigate and remove it by hand only after independent verification."
    }

    $subscriptionSegment = @($account.Id -split '/')[2]
    $scope = "/subscriptions/$subscriptionSegment/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
    foreach ($objectId in $StateAdministratorObjectId) {
        $assignments = @(Get-AzRoleAssignment -Scope $scope -ObjectId $objectId -ErrorAction Stop |
                Where-Object { $_.RoleDefinitionName -ieq 'Storage Blob Data Contributor' -and $_.Scope -ieq $scope })
        foreach ($assignment in $assignments) {
            if ($PSCmdlet.ShouldProcess('state administrator role assignment', 'Remove Storage Blob Data Contributor at the storage-account scope')) {
                Remove-AzRoleAssignment -ObjectId $objectId -RoleDefinitionName 'Storage Blob Data Contributor' -Scope $scope -ErrorAction Stop | Out-Null
            }
        }
    }

    $storageContext = Get-StorageContext $StorageAccountName
    $container = Get-PrivateContainer $storageContext
    if ($null -ne $container) {
        if ($PSCmdlet.ShouldProcess("container $ContainerName", 'Remove the tfstate container')) {
            Remove-AzStorageContainer -Name $ContainerName -Context $storageContext -Force -ErrorAction Stop
        }
    }

    if ($PSCmdlet.ShouldProcess("storage account $StorageAccountName", 'Remove the canonical state storage account')) {
        Remove-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -Force -ErrorAction Stop
    }

    if ($PSCmdlet.ShouldProcess("resource group $ResourceGroupName", 'Remove the canonical state resource group')) {
        Remove-AzResourceGroup -Name $ResourceGroupName -Force -ErrorAction Stop | Out-Null
    }
}

$script:ProjectRoleName = 'TechSprint VM Power Operator'
$script:ProjectRoleDescription = 'Least-privilege start/restart/power-off/deallocate operations for Azure app VMs.'

$script:ProjectRoleActions = @(
    'Microsoft.Compute/virtualMachines/read'
    'Microsoft.Compute/virtualMachines/instanceView/read'
    'Microsoft.Compute/virtualMachines/start/action'
    'Microsoft.Compute/virtualMachines/restart/action'
    'Microsoft.Compute/virtualMachines/powerOff/action'
    'Microsoft.Compute/virtualMachines/deallocate/action'
    'Microsoft.Resources/subscriptions/resourceGroups/read'
)

function Get-DeployProjectRoleCandidates {

    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$SubscriptionId)
    return @(Get-AzRoleDefinition -Name $script:ProjectRoleName -Scope "/subscriptions/$SubscriptionId" -ErrorAction Stop)
}

function Get-DeployProjectRoleAssignments {

    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$RoleDefinitionId)
    return @(Get-AzRoleAssignment -RoleDefinitionId $RoleDefinitionId -ErrorAction Stop)
}

function Get-DeployPSObjectPropertyValue {

    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-DeployProjectRolePermissionBlocks {

    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowNull()]$Role)

    if ($null -eq $Role) { return @() }

    $permissions = Get-DeployPSObjectPropertyValue -InputObject $Role -Name 'Permissions'
    if ($null -ne $permissions) {
        return @($permissions)
    }

    $flattenedActionProperties = @('Actions', 'NotActions', 'DataActions', 'NotDataActions') | Where-Object {
        $null -ne $Role.PSObject.Properties[$_]
    }
    if (@($flattenedActionProperties).Count -gt 0) {
        return @($Role)
    }

    return @()
}

function Test-DeployProjectRoleFingerprint {

    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Role,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    if ($null -eq $Role) { return $false }
    if ([string](Get-DeployPSObjectPropertyValue -InputObject $Role -Name 'Name') -cne $script:ProjectRoleName) { return $false }
    if ([string](Get-DeployPSObjectPropertyValue -InputObject $Role -Name 'Description') -cne $script:ProjectRoleDescription) { return $false }
    if ((Get-DeployPSObjectPropertyValue -InputObject $Role -Name 'IsCustom') -ne $true) { return $false }

    $expectedScope = "/subscriptions/$SubscriptionId"
    $actualScopes = @(@(Get-DeployPSObjectPropertyValue -InputObject $Role -Name 'AssignableScopes') | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if ($actualScopes.Count -ne 1 -or $actualScopes[0] -ine $expectedScope) { return $false }

    $permissionBlocks = @(Get-DeployProjectRolePermissionBlocks -Role $Role)
    if ($permissionBlocks.Count -ne 1) { return $false }
    $permission = $permissionBlocks[0]

    $expectedActions = @($script:ProjectRoleActions | Sort-Object)
    $actualActions = @(@(Get-DeployPSObjectPropertyValue -InputObject $permission -Name 'Actions') | ForEach-Object { [string]$_ } | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expectedActions -DifferenceObject $actualActions).Count -gt 0) { return $false }

    foreach ($emptyPropertyName in @('NotActions', 'DataActions', 'NotDataActions')) {
        $values = @(@(Get-DeployPSObjectPropertyValue -InputObject $permission -Name $emptyPropertyName) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($values.Count -gt 0) { return $false }
    }

    return $true
}

function Resolve-DeployProjectRoleForDestroyAll {

    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    $candidates = @(Get-DeployProjectRoleCandidates -SubscriptionId $SubscriptionId)
    if ($candidates.Count -eq 0) {
        return $null
    }
    if ($candidates.Count -gt 1) {
        throw "BLOCKED: found $($candidates.Count) role definitions named exactly '$script:ProjectRoleName' visible to this subscription; refusing to guess which one (if any) this project owns. Investigate by hand (Get-AzRoleDefinition -Name '$script:ProjectRoleName') before rerunning -DestroyAll."
    }

    $role = $candidates[0]
    if (-not (Test-DeployProjectRoleFingerprint -Role $role -SubscriptionId $SubscriptionId)) {
        throw "BLOCKED: found a role definition named exactly '$script:ProjectRoleName' (id: $([string]$role.Id)), but its description/IsCustom/assignable-scope/permissions do not exactly match this project's own canonical definition (infra/azure/shared/main.tf's azurerm_role_definition.vm_power_operator). Refusing to remove a role based on its name alone. Investigate by hand before rerunning -DestroyAll."
    }

    $assignments = @(Get-DeployProjectRoleAssignments -RoleDefinitionId ([string]$role.Id))
    return [pscustomobject]@{
        Role        = $role
        Assignments = $assignments
    }
}

function Remove-DeployProjectRole {

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][pscustomobject]$RoleInfo,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $roleId = [string]$RoleInfo.Role.Id
    $currentAssignments = @(Get-DeployProjectRoleAssignments -RoleDefinitionId $roleId)
    if ($currentAssignments.Count -gt 0) {
        throw "BLOCKED: refusing to remove the project custom role '$script:ProjectRoleName' ($roleId): $($currentAssignments.Count) role assignment(s) still reference it. Remove those assignments by hand (or investigate why this project's own Terraform teardown did not already remove them) before rerunning -DestroyAll."
    }

    if ($PSCmdlet.ShouldProcess("custom role definition '$script:ProjectRoleName' ($roleId)", 'Remove out-of-band (subscription-scoped; survives resource-group deletion)')) {
        Remove-AzRoleDefinition -Id $roleId -Scope "/subscriptions/$SubscriptionId" -Force -ErrorAction Stop
    }
}

function Get-DeployDestroyAllSummary {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Developers,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$ManifestUsers,
        [Parameter(Mandatory)][bool]$BackendAbsent,
        [Parameter(Mandatory)][bool]$KeepStateBackend,
        [Parameter(Mandatory)][pscustomobject]$ResourceGroupNames,
        [Parameter(Mandatory)][string]$StateStorageAccountName,

        [Parameter()][AllowNull()][pscustomobject]$ProjectRoleInfo = $null
    )

    $phases = [Collections.Generic.List[pscustomobject]]::new()
    if ($BackendAbsent) {
        $phases.Add([pscustomobject]@{ Phase = '1-3'; Action = 'SKIPPED (state backend does not exist)'; Scope = "$($ResourceGroupNames.Shared), $((@($ResourceGroupNames.Tenants.Values)) -join ', ')" })
    }
    else {
        $phases.Add([pscustomobject]@{ Phase = '1/5'; Action = 'Detach shared foundation (Application Gateway, hub-to-spoke peerings, shared DNS links)'; Scope = $ResourceGroupNames.Shared })
        foreach ($developer in $Developers) {
            $phases.Add([pscustomobject]@{ Phase = '2/5'; Action = "Destroy tenant '$($developer.Slug)' (app VMs, storage, shared-MySQL database access, networking)"; Scope = $ResourceGroupNames.Tenants[$developer.Slug] })
        }
        $phases.Add([pscustomobject]@{ Phase = '3/5'; Action = 'Destroy shared foundation (Jump, Lead, hub network, identity)'; Scope = $ResourceGroupNames.Shared })
    }
    if ($null -ne $ProjectRoleInfo) {

        $phases.Add([pscustomobject]@{
                Phase  = '4/5'
                Action = "Remove out-of-band-verified project custom role '$script:ProjectRoleName' (subscription-scoped; survives resource-group deletion; re-verified fresh immediately before removal)"
                Scope  = "/subscriptions/$SubscriptionId (role id: $([string]$ProjectRoleInfo.Role.Id))"
            })
    }
    foreach ($user in $ManifestUsers) {
        $phases.Add([pscustomobject]@{ Phase = '5/5'; Action = "Remove script-created Entra user (only after its current object ID is re-verified)"; Scope = $user.Upn })
    }
    $backendAction = if ($KeepStateBackend) { 'KEPT (-KeepStateBackend)' } elseif ($BackendAbsent) { 'nothing to retire (does not exist)' } else { 'Retire Terraform state backend' }
    $phases.Add([pscustomobject]@{ Phase = 'final'; Action = $backendAction; Scope = "$script:StateResourceGroupName / $StateStorageAccountName" })

    return [pscustomobject]@{
        SubscriptionId = $SubscriptionId
        TenantId       = $TenantId
        BackendAbsent  = $BackendAbsent
        Phases         = @($phases)
    }
}

function Show-DeployDestroyAllSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Summary)

    Write-Host ''
    Write-Host '=== -DestroyAll pre-mutation summary: review carefully before confirming ==='
    Write-Host "Subscription: $($Summary.SubscriptionId)"
    Write-Host "Tenant:       $($Summary.TenantId)"
    Write-Host ''
    Write-Host 'Exact resources/scopes that will be affected if confirmed:'
    foreach ($phase in $Summary.Phases) {
        Write-Host "  [$($phase.Phase)] $($phase.Action) -- scope: $($phase.Scope)"
    }
    Write-Host ''
}

function Get-DeployDestroyAllPreview {

    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$NameSeed,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$LocationShortName,
        [Parameter(Mandatory)][string]$VmSku,
        [Parameter(Mandatory)][string]$EntraMode,
        [Parameter(Mandatory)][pscustomobject]$RockyImage,
        [Parameter(Mandatory)][pscustomobject]$Lead,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Developers,
        [Parameter(Mandatory)][string]$PlaceholderKeyPath,
        [Parameter(Mandatory)][string]$ResolvedWorkDir,
        [Parameter(Mandatory)][string]$TenantsDir,
        [Parameter(Mandatory)][string[]]$CommonRunnerArgs
    )

    $phaseResults = [Collections.Generic.List[pscustomobject]]::new()

    $sharedTfvarsPath = Join-Path $ResolvedWorkDir 'shared-detach-preview.tfvars'
    $sharedPlanPath = Join-Path $ResolvedWorkDir 'shared-detach-preview.tfplan'
    try {
        $sharedTfvarsContent = New-SharedTfvarsContent -SubscriptionId $SubscriptionId -Location $Location -LocationShortName $LocationShortName -VmSku $VmSku -NameSeed $NameSeed `
            -AllowedSshCidr '0.0.0.0/0' -EntraMode $EntraMode -RockyImage $RockyImage `
            -Lead $Lead -Developers $Developers -LeadSshPublicKeyAbsolutePath $PlaceholderKeyPath -AppGatewayEnabled $false
        Set-Content -LiteralPath $sharedTfvarsPath -Value $sharedTfvarsContent -Encoding utf8 -NoNewline
        $planResult = Invoke-DeployRunner -RunnerArgs (@('-Command', 'Plan', '-Root', 'shared', '-VarFile', $sharedTfvarsPath, '-PlanFile', $sharedPlanPath) + $CommonRunnerArgs) -AllowNonZeroExit
        if ($planResult.ExitCode -ne 0) {
            $phaseResults.Add([pscustomobject]@{ Phase = '1/5'; Scope = 'shared-detach'; Status = 'preview_failed'; PlanFile = $null })
        }
        else {
            $hasChanges = Test-DeployPlanHasSharedDetachChanges -RootPath $SharedRootPath -PlanFile $sharedPlanPath
            $phaseResults.Add([pscustomobject]@{
                    Phase    = '1/5'
                    Scope    = 'shared-detach'
                    Status   = if ($hasChanges) { 'changes_pending' } else { 'already_detached' }
                    PlanFile = $sharedPlanPath
                })
        }
    }
    catch {
        $phaseResults.Add([pscustomobject]@{ Phase = '1/5'; Scope = 'shared-detach'; Status = 'preview_failed'; PlanFile = $null })
    }

    foreach ($developer in $Developers) {
        $tenantTfvarsPath = Join-Path $TenantsDir "$($developer.Slug).destroy-preview.tfvars"
        $tenantPlanPath = Join-Path $ResolvedWorkDir "tenant-$($developer.Slug).destroy-preview.tfplan"
        $priorMoodle = $env:TF_VAR_moodle_database_password
        $env:TF_VAR_moodle_database_password = $script:DestroyAllPlaceholderPassword
        try {
            $tenantTfvarsContent = New-TenantTfvarsContent -Location $Location -LocationShortName $LocationShortName -VmSku $VmSku -NameSeed $NameSeed -Developer $developer `
                -AllDevelopers $Developers -SharedValues $script:DestroyAllPlaceholderSharedValues -DeveloperSshPublicKeyAbsolutePath $PlaceholderKeyPath `
                -LeadSshPublicKeyAbsolutePath $PlaceholderKeyPath -RockyImage $RockyImage
            Set-Content -LiteralPath $tenantTfvarsPath -Value $tenantTfvarsContent -Encoding utf8 -NoNewline
            $planResult = Invoke-DeployRunner -RunnerArgs (@('-Command', 'Plan', '-Root', 'tenant', '-TenantSlug', $developer.Slug, '-VarFile', $tenantTfvarsPath, '-DestroyPlan', '-PlanFile', $tenantPlanPath) + $CommonRunnerArgs) -AllowNonZeroExit
            if ($planResult.ExitCode -ne 0) {
                $phaseResults.Add([pscustomobject]@{ Phase = '2/5'; Scope = "tenant:$($developer.Slug)"; Status = 'preview_failed'; PlanFile = $null })
            }
            else {
                $hasChanges = Test-DeployPlanHasResourceChanges -RootPath $TenantRootPath -PlanFile $tenantPlanPath
                $phaseResults.Add([pscustomobject]@{
                        Phase    = '2/5'
                        Scope    = "tenant:$($developer.Slug)"
                        Status   = if ($hasChanges) { 'changes_pending' } else { 'already_empty' }
                        PlanFile = $tenantPlanPath
                    })
            }
        }
        catch {
            $phaseResults.Add([pscustomobject]@{ Phase = '2/5'; Scope = "tenant:$($developer.Slug)"; Status = 'preview_failed'; PlanFile = $null })
        }
        finally {
            $env:TF_VAR_moodle_database_password = $priorMoodle
        }
    }

    $phaseResults.Add([pscustomobject]@{
            Phase    = '3/5'
            Scope    = 'shared-destroy'
            Status   = 'not_previewed_requires_phase1_apply'
            PlanFile = $null
        })

    return @($phaseResults)
}

function Invoke-DeployDestroyAllCommand {

    [CmdletBinding()]
    param()

    if ([IO.Path]::GetExtension($UsersCsv) -ine '.csv') {
        Stop-DeployUsage -Message 'UsersCsv must be a .csv file.'
    }

    $resolvedWorkDir = Resolve-DeployWorkDir -Path $WorkDir
    Initialize-DeployWorkDir -Path $resolvedWorkDir
    $tenantsDir = Join-Path $resolvedWorkDir 'tenants'
    New-Item -ItemType Directory -Path $tenantsDir -Force | Out-Null

    Write-Host '=== DestroyAll Step 0: resolving Azure subscription/tenant/operator/UPN-domain/NameSeed/deployment-profile (read-only Az PowerShell lookups) ==='
    $subscriptionAndTenantForProfile = Resolve-DeploySubscriptionAndTenant -SubscriptionId $SubscriptionId -TenantId $TenantId

    $deploymentProfile = Resolve-DeployDeploymentProfile -SubscriptionId $subscriptionAndTenantForProfile.SubscriptionId -TenantId $subscriptionAndTenantForProfile.TenantId `
        -LocationOverride $Location -LocationShortNameOverride $LocationShortName -VmSkuOverride $VmSku -RepositoryRoot $RepositoryRoot `
        -RockyImagePublisher $RockyImagePublisher -RockyImageOffer $RockyImageOffer -RockyImageSku $RockyImageSku
    $resolvedLocation = $deploymentProfile.Location
    $resolvedLocationShortName = $deploymentProfile.LocationShortName
    $resolvedVmSku = $deploymentProfile.VmSku
    $script:StateResourceGroupName = Get-DeployStateResourceGroupName -LocationShortName $resolvedLocationShortName
    Write-Host "Resolved deployment profile: location=$resolvedLocation ($resolvedLocationShortName), VM SKU=$resolvedVmSku $(Format-DeployAutoTag $deploymentProfile.AutoDerived) [persisted: $($deploymentProfile.PersistedPath)]"
    $legacyStateAdvisory = Get-DeployLegacyStateResourceGroupAdvisory -ResolvedStateResourceGroupName $script:StateResourceGroupName
    if ($legacyStateAdvisory) { Write-Host $legacyStateAdvisory }

    $destroyRockyVersionInput = if ([string]::IsNullOrWhiteSpace($RockyImageVersion)) { [string]$deploymentProfile.RockyImageVersion } else { $RockyImageVersion }
    if ([string]::IsNullOrWhiteSpace($destroyRockyVersionInput)) {
        throw 'BLOCKED: the persisted deployment profile has no Rocky image version; refusing to build a shared-detach plan that could propose VM replacement. Supply the exact deployed -RockyImageVersion after verifying it from state.'
    }
    $simpleContext = Resolve-DeploySimpleContext -SubscriptionId $SubscriptionId -TenantId $TenantId `
        -StateAdministratorObjectId $StateAdministratorObjectId -UpnDomain $UpnDomain -NameSeed $NameSeed `
        -RockyImageVersion $destroyRockyVersionInput -Location $resolvedLocation -RockyImagePublisher $RockyImagePublisher `
        -RockyImageOffer $RockyImageOffer -RockyImageSku $RockyImageSku -RepositoryRoot $RepositoryRoot
    $resolvedSubscriptionId = [string]$simpleContext.SubscriptionId
    $resolvedTenantId = [string]$simpleContext.TenantId
    $resolvedStateAdministratorObjectId = @($simpleContext.StateAdministratorObjectId)
    $resolvedUpnDomain = [string]$simpleContext.UpnDomain
    $resolvedNameSeed = [string]$simpleContext.NameSeed

    $commonRunnerArgs = @(
        '-SubscriptionId', $resolvedSubscriptionId, '-TenantId', $resolvedTenantId,
        '-NameSeed', $resolvedNameSeed, '-Location', $resolvedLocation, '-LocationShortName', $resolvedLocationShortName,
        '-StateAdministratorObjectId'
    ) + @($resolvedStateAdministratorObjectId)

    Write-Host '=== DestroyAll Step 1: validating the users CSV structure (read-only; SSH key files under keys/ are never required for -DestroyAll) ==='
    $structural = Test-UsersCsv -Path $UsersCsv -UpnDomain $resolvedUpnDomain
    $missingUpn = @($structural.users | Where-Object { [string]::IsNullOrWhiteSpace($_.upn) })
    if ($missingUpn.Count -gt 0) {
        Stop-DeployUsage -Message "UPN could not be resolved for: $(($missingUpn | ForEach-Object slug) -join ', '). Supply -UpnDomain."
    }
    $leadRow = $structural.users | Where-Object { $_.role -eq 'devops_lead' } | Select-Object -First 1
    if ($null -eq $leadRow) { Stop-DeployUsage -Message 'No devops_lead row found (Test-UsersCsv should already have refused this).' }
    $lead = [pscustomobject]@{ Slug = $leadRow.slug; Upn = $leadRow.upn }

    $developers = @($structural.users | Where-Object { $_.role -eq 'developer' } | Sort-Object { $_.slug } | ForEach-Object {
            [pscustomobject]@{ Slug = $_.slug; Upn = $_.upn; NetworkSlot = $_.network_slot }
        })

    $placeholderKeyPath = Join-Path $resolvedWorkDir 'destroy-all-placeholder.pub'
    Set-Content -LiteralPath $placeholderKeyPath -Value $script:DestroyAllPlaceholderSshPublicKey -Encoding utf8 -NoNewline
    $rockyImage = [pscustomobject]@{ Publisher = $RockyImagePublisher; Offer = $RockyImageOffer; Sku = $RockyImageSku; Version = [string]$simpleContext.RockyImageVersion }

    Write-Host '=== DestroyAll Step 2: checking whether the Terraform state backend exists (read-only) ==='
    $preflight = Invoke-DeployRunner -RunnerArgs (@('-Command', 'Preflight') + $commonRunnerArgs) -AllowNonZeroExit
    $backendAbsent = Test-DeployBackendAbsent -PreflightOutput $preflight.Output

    $stateStorageAccountName = Get-DeployDestroyAllStateStorageAccountName -NameSeed $resolvedNameSeed
    Repair-DeployBackendConfigFile -PreflightExitCode $preflight.ExitCode -PreflightOutput $preflight.Output `
        -BackendConfigPath $BootstrapBackendHclPath -ResourceGroupName $script:StateResourceGroupName `
        -StorageAccountName $stateStorageAccountName -ContainerName $script:StateContainerName

    $manifestPath = Get-DeployEntraManifestPath -RepositoryRoot $RepositoryRoot
    $manifestUsers = @(Read-DeployEntraManifest -Path $manifestPath -SubscriptionId $resolvedSubscriptionId -TenantId $resolvedTenantId)

    $projectRoleInfo = Resolve-DeployProjectRoleForDestroyAll -SubscriptionId $resolvedSubscriptionId

    $resourceGroupNames = Get-DeployDestroyAllResourceGroupNames -Developers $developers -LocationShortName $resolvedLocationShortName

    if ($backendAbsent) {

        $conflictingResourceGroups = @(Get-DeployBackendAbsentResourceGroupConflicts -ResourceGroupNames $resourceGroupNames)
        if ($conflictingResourceGroups.Count -gt 0) {
            throw "BLOCKED: the Terraform state backend appears absent, but $($conflictingResourceGroups.Count) canonical project resource group(s) matching this CSV/shared topology still exist in Azure with this repository's own project tags: $($conflictingResourceGroups -join ', '). A missing backend does not mean nothing was ever deployed -- this usually indicates a wrong/stale -NameSeed, corrupted or lost runtime/state metadata (runtime/state/name-seed.json), or a partially retired backend. Investigate by hand (confirm the correct -NameSeed, or restore bootstrap/backend.hcl if the backend itself still exists) before rerunning -DestroyAll; this command never deletes a resource group it cannot first plan a delete-only Terraform destroy against."
        }
    }

    $summary = Get-DeployDestroyAllSummary -SubscriptionId $resolvedSubscriptionId -TenantId $resolvedTenantId `
        -Developers $developers -ManifestUsers $manifestUsers -BackendAbsent $backendAbsent -KeepStateBackend $KeepStateBackend.IsPresent `
        -ResourceGroupNames $resourceGroupNames -StateStorageAccountName $stateStorageAccountName -ProjectRoleInfo $projectRoleInfo
    Show-DeployDestroyAllSummary -Summary $summary

    if ($backendAbsent -and $manifestUsers.Count -eq 0 -and $null -eq $projectRoleInfo) {

        Write-Host 'Nothing to destroy: the Terraform state backend does not exist yet, no Entra users are recorded as created by this script for this subscription/tenant, and no out-of-band project custom role was found.'
        $previewArtifacts = @(Get-ChildItem -LiteralPath $resolvedWorkDir -Filter '*.tfplan' -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
        [ordered]@{
            status            = 'NOTHING_TO_DESTROY'
            backend_exists    = $false
            preview_artifacts = @($previewArtifacts)
        } | ConvertTo-Json -Depth 4 | Write-Host
        return
    }

    if ($WhatIf) {
        Write-Host 'PLANNED (preview only): -DestroyAll -WhatIf never deletes, applies, or removes anything.'
        if ($backendAbsent) {
            Write-Host 'Phases 1-3 (shared detach, tenant destroy, shared destroy) are unavailable to preview: the state backend does not exist yet, so no shared/tenant Terraform state exists to plan a destroy against.'
            [ordered]@{ status = 'PLANNED'; summary = $summary } | ConvertTo-Json -Depth 6 | Write-Host
            return
        }
        Write-Host 'Previewing Phase 1 (shared detach) and Phase 2 (each tenant destroy) via read-only Terraform plans against the real Terraform state (never applied). Phase 3 (shared full destroy) is not previewed: its accuracy depends on Phase 1''s detach having already been applied for real -- Azure refuses to delete a VNet while a private DNS zone virtual-network link from the shared root still points to it -- so rerun -DestroyAll without -WhatIf to apply Phase 1 before a later Phase 3 preview would be meaningful.'
        $preview = @(Get-DeployDestroyAllPreview -SubscriptionId $resolvedSubscriptionId -NameSeed $resolvedNameSeed `
                -Location $resolvedLocation -LocationShortName $resolvedLocationShortName -VmSku $resolvedVmSku -EntraMode $EntraMode -RockyImage $rockyImage -Lead $lead -Developers $developers `
                -PlaceholderKeyPath $placeholderKeyPath -ResolvedWorkDir $resolvedWorkDir -TenantsDir $tenantsDir -CommonRunnerArgs $commonRunnerArgs)
        foreach ($item in $preview) {
            $planNote = if ($item.PlanFile) { " (saved plan: $($item.PlanFile))" } else { '' }
            Write-Host "  [$($item.Phase)] $($item.Scope): $($item.Status)$planNote"
        }
        [ordered]@{ status = 'PLANNED'; summary = $summary; preview = $preview } | ConvertTo-Json -Depth 6 | Write-Host
        return
    }

    $confirmationSuppliedMatches = (-not [string]::IsNullOrWhiteSpace($DestroyAllConfirmation)) -and ($DestroyAllConfirmation -ceq $script:DestroyAllConfirmationPhrase)
    if ((-not [string]::IsNullOrWhiteSpace($DestroyAllConfirmation)) -and (-not $confirmationSuppliedMatches)) {
        throw "BLOCKED: -DestroyAllConfirmation did not exactly match '$script:DestroyAllConfirmationPhrase' (case-sensitive); refusing to destroy anything. Retype it exactly, or omit -DestroyAllConfirmation to be prompted interactively instead."
    }
    $approvalDecision = Resolve-DeployDestroyAllApproval -WhatIf $false -ConfirmationPhraseSuppliedMatches $confirmationSuppliedMatches -InteractiveConfirmationGranted $false
    if ($approvalDecision.RequiresInteractiveConfirmation) {
        $granted = Confirm-DeployDestroyAllRun
        $approvalDecision = Resolve-DeployDestroyAllApproval -WhatIf $false -ConfirmationPhraseSuppliedMatches $confirmationSuppliedMatches -InteractiveConfirmationGranted $granted
    }
    if (-not $approvalDecision.Approved) {
        Write-Host 'Cancelled: no changes were made.'
        exit 1
    }

    $phaseFailures = [Collections.Generic.List[string]]::new()
    $sharedTfvarsPath = Join-Path $resolvedWorkDir 'shared.tfvars'

    if ($backendAbsent) {
        Write-Host 'Terraform state backend does not exist; skipping Phase 1-3 (nothing deployed in Azure to detach or destroy).'
    }
    else {
        Write-Host '=== DestroyAll Phase 1/5: detaching the shared foundation from every tenant (Application Gateway, hub-to-spoke peerings, shared DNS links) ==='
        try {
            $sharedTfvarsContent = New-SharedTfvarsContent -SubscriptionId $resolvedSubscriptionId -Location $resolvedLocation -LocationShortName $resolvedLocationShortName -VmSku $resolvedVmSku -NameSeed $resolvedNameSeed `
                -AllowedSshCidr '0.0.0.0/0' -EntraMode $EntraMode -RockyImage $rockyImage `
                -Lead $lead -Developers $developers -LeadSshPublicKeyAbsolutePath $placeholderKeyPath -AppGatewayEnabled $false
            Set-Content -LiteralPath $sharedTfvarsPath -Value $sharedTfvarsContent -Encoding utf8 -NoNewline

            $sharedStateFacts = Get-DeploySharedDetachStateFacts -SharedTfvarsPath $sharedTfvarsPath -ResolvedWorkDir $resolvedWorkDir -CommonRunnerArgs $commonRunnerArgs
            if (-not $sharedStateFacts.HasResources) {
                Write-Host 'Shared Terraform state is already empty; nothing to detach (safe rerun).'
            }
            elseif (-not $sharedStateFacts.HasDetachResources) {
                Write-Host 'Shared foundation is already detached; unrelated shared drift will be removed by the full shared destroy phase.'
            }
            else {
                $exactLeadKeyPath = Join-Path $resolvedWorkDir 'shared-detach-exact-lead.pub'
                Set-Content -LiteralPath $exactLeadKeyPath -Value $sharedStateFacts.LeadSshPublicKey -Encoding utf8 -NoNewline

                $sharedDetachTfvarsPath = Join-Path $resolvedWorkDir 'shared-detach.tfvars'
                $sharedDetachTfvarsContent = New-SharedTfvarsContent -SubscriptionId $resolvedSubscriptionId -Location $resolvedLocation -LocationShortName $resolvedLocationShortName -VmSku $resolvedVmSku -NameSeed $resolvedNameSeed `
                    -AllowedSshCidr '0.0.0.0/0' -EntraMode $EntraMode -RockyImage $sharedStateFacts.RockyImage `
                    -Lead $lead -Developers $developers -LeadSshPublicKeyAbsolutePath $exactLeadKeyPath -AppGatewayEnabled $false
                Set-Content -LiteralPath $sharedDetachTfvarsPath -Value $sharedDetachTfvarsContent -Encoding utf8 -NoNewline

                $sharedDetachPlanPath = Join-Path $resolvedWorkDir 'shared-detach.tfplan'
                Invoke-DeployRunner -RunnerArgs (@('-Command', 'Plan', '-Root', 'shared', '-VarFile', $sharedDetachTfvarsPath, '-PlanFile', $sharedDetachPlanPath) + $commonRunnerArgs) | Out-Null

                $disallowedDetachActions = @(Get-DeployPlanUnexpectedActions -RootPath $SharedRootPath -PlanFile $sharedDetachPlanPath -AllowedActions @('no-op', 'update', 'delete'))
                if ($disallowedDetachActions.Count -gt 0) {
                    throw "BLOCKED: the shared-detach plan proposes create/replace action(s) on: $($disallowedDetachActions -join ', '). Phase 1 must only disable the Application Gateway/peerings/DNS links via in-place update or delete; it must never create or replace resources. The exact plan is saved at '$sharedDetachPlanPath' for investigation."
                }

                if (Test-DeployPlanHasResourceChanges -RootPath $SharedRootPath -PlanFile $sharedDetachPlanPath) {
                    Invoke-DeployRunner -RunnerArgs (@('-Command', 'Apply', '-Root', 'shared', '-PlanFile', $sharedDetachPlanPath, '-ApproveSubscriptionMutations', '-ApproveDirectoryMutations') + $commonRunnerArgs) | Out-Null
                    Write-Host 'Shared foundation detached from every tenant.'
                }
                else {
                    Write-Host 'Shared foundation is already detached (no pending Application Gateway/peering/DNS-link changes); skipping.'
                }
            }
        }
        catch {
            $phaseFailures.Add('shared-detach')
            Write-Host "FAILED to detach the shared foundation: $($_.Exception.Message)"
        }

        Write-Host '=== DestroyAll Phase 2/5: destroying every tenant environment in the supplied CSV ==='
        foreach ($developer in $developers) {
            Write-Host "--- Tenant: $($developer.Slug) ---"
            $tenantTfvarsPath = Join-Path $tenantsDir "$($developer.Slug).tfvars"
            $tenantTfvarsContent = New-TenantTfvarsContent -Location $resolvedLocation -LocationShortName $resolvedLocationShortName -VmSku $resolvedVmSku -NameSeed $resolvedNameSeed -Developer $developer `
                -AllDevelopers $developers -SharedValues $script:DestroyAllPlaceholderSharedValues -DeveloperSshPublicKeyAbsolutePath $placeholderKeyPath `
                -LeadSshPublicKeyAbsolutePath $placeholderKeyPath -RockyImage $rockyImage
            Set-Content -LiteralPath $tenantTfvarsPath -Value $tenantTfvarsContent -Encoding utf8 -NoNewline

            $priorMoodle = $env:TF_VAR_moodle_database_password
            $env:TF_VAR_moodle_database_password = $script:DestroyAllPlaceholderPassword
            try {
                $tenantDestroyPlanPath = Join-Path $resolvedWorkDir "tenant-$($developer.Slug).destroy.tfplan"
                Invoke-DeployRunner -RunnerArgs (@('-Command', 'Plan', '-Root', 'tenant', '-TenantSlug', $developer.Slug, '-VarFile', $tenantTfvarsPath, '-DestroyPlan', '-PlanFile', $tenantDestroyPlanPath) + $commonRunnerArgs) | Out-Null
                if (Test-DeployPlanHasResourceChanges -RootPath $TenantRootPath -PlanFile $tenantDestroyPlanPath) {
                    Invoke-DeployRunner -RunnerArgs (@('-Command', 'Destroy', '-Root', 'tenant', '-TenantSlug', $developer.Slug, '-PlanFile', $tenantDestroyPlanPath, '-AllowDestroy', '-DestroyConfirmation', 'AZURE-DESTROY', '-ApproveSubscriptionMutations', '-ApproveDirectoryMutations') + $commonRunnerArgs) | Out-Null
                    Write-Host "Tenant '$($developer.Slug)' destroyed."
                }
                else {
                    Write-Host "Tenant '$($developer.Slug)' state is already empty; nothing to destroy (safe rerun)."
                }
            }
            catch {
                $phaseFailures.Add("tenant:$($developer.Slug)")
                Write-Host "FAILED to destroy tenant '$($developer.Slug)': $($_.Exception.Message)"
            }
            finally {
                $env:TF_VAR_moodle_database_password = $priorMoodle
            }
        }

        if ($phaseFailures.Count -eq 0) {
            Write-Host '=== DestroyAll Phase 3/5: destroying the shared foundation (Jump, Lead, hub network, identity) ==='
            try {
                $sharedDestroyPlanPath = Join-Path $resolvedWorkDir 'shared.destroy.tfplan'
                Invoke-DeployRunner -RunnerArgs (@('-Command', 'Plan', '-Root', 'shared', '-VarFile', $sharedTfvarsPath, '-DestroyPlan', '-PlanFile', $sharedDestroyPlanPath) + $commonRunnerArgs) | Out-Null
                if (Test-DeployPlanHasResourceChanges -RootPath $SharedRootPath -PlanFile $sharedDestroyPlanPath) {
                    Invoke-DeployRunner -RunnerArgs (@('-Command', 'Destroy', '-Root', 'shared', '-PlanFile', $sharedDestroyPlanPath, '-AllowDestroy', '-DestroyConfirmation', 'AZURE-DESTROY', '-ApproveSubscriptionMutations', '-ApproveDirectoryMutations') + $commonRunnerArgs) | Out-Null
                    Write-Host 'Shared foundation destroyed.'
                }
                else {
                    Write-Host 'Shared foundation state is already empty; nothing to destroy (safe rerun).'
                }
            }
            catch {
                $phaseFailures.Add('shared-destroy')
                Write-Host "FAILED to destroy the shared foundation: $($_.Exception.Message)"
            }
        }
        else {
            Write-Host "Skipping Phase 3/5 (shared destroy): $($phaseFailures.Count) earlier phase(s) already failed ($($phaseFailures -join ', '))."
        }
    }

    if ($phaseFailures.Count -eq 0) {

        Write-Host '=== DestroyAll Phase 4/5: removing the out-of-band-verified project custom role (if this project''s own Terraform teardown above did not already remove it) ==='
        $freshProjectRoleInfo = Resolve-DeployProjectRoleForDestroyAll -SubscriptionId $resolvedSubscriptionId
        if ($null -ne $freshProjectRoleInfo) {
            try {
                Remove-DeployProjectRole -RoleInfo $freshProjectRoleInfo -SubscriptionId $resolvedSubscriptionId -Confirm:$false
                Write-Host "Removed out-of-band project custom role '$script:ProjectRoleName' ($([string]$freshProjectRoleInfo.Role.Id))."
            }
            catch {
                $phaseFailures.Add('project-role-removal')
                Write-Host "FAILED to remove the project custom role: $($_.Exception.Message)"
            }
        }
        else {
            Write-Host "No out-of-band project custom role found (already removed by this project's own Terraform teardown, or never existed)."
        }
    }
    else {
        Write-Host "Skipping Phase 4/5 (project custom role removal): infrastructure teardown is incomplete ($($phaseFailures -join ', ')). The role, if any, was not touched."
    }

    if ($phaseFailures.Count -eq 0) {
        Write-Host '=== DestroyAll Phase 5/5: removing script-created Entra users recorded in the manifest ==='
        $entraResults = @(Remove-DeployManifestTrackedEntraUsers -RepositoryRoot $RepositoryRoot -SubscriptionId $resolvedSubscriptionId -TenantId $resolvedTenantId)
        foreach ($result in $entraResults) {
            Write-Host "  $($result.Upn): $($result.Status)"
            if ($result.Status -eq 'object_id_mismatch_skipped') {
                Write-Host "    SKIPPED: '$($result.Upn)' now resolves to a different Entra object ID than this script recorded creating; refusing to delete a possibly different account. Investigate by hand."
                $phaseFailures.Add("entra-mismatch:$($result.Upn)")
            }
            elseif ($result.Status -in @('delete_failed', 'lookup_failed')) {
                $phaseFailures.Add("entra:$($result.Upn)")
            }
        }
    }
    else {

        Write-Host "Skipping Phase 5/5 (Entra user removal): infrastructure/role-cleanup teardown is incomplete ($($phaseFailures -join ', ')). No directory users were touched."
    }

    if ($KeepStateBackend) {
        Write-Host 'Keeping the Terraform state backend (-KeepStateBackend supplied).'
    }
    elseif ($backendAbsent) {
        Write-Host 'Terraform state backend does not exist; nothing to retire.'
    }
    else {
        $remainingManifest = @(Read-DeployEntraManifest -Path $manifestPath -SubscriptionId $resolvedSubscriptionId -TenantId $resolvedTenantId)
        $orphanSlugs = @()
        $residualRoots = @()
        $finalVerificationOk = $false
        if ($phaseFailures.Count -eq 0 -and $remainingManifest.Count -eq 0) {
            try {
                $backendConfig = Get-DeployBackendConfigValues -Path $BootstrapBackendHclPath
                $blobNames = @(Get-DeployBackendTenantStateKeys -StorageAccountName $backendConfig.StorageAccountName -ContainerName $backendConfig.ContainerName)
                $orphanSlugs = @(Get-DeployOrphanedTenantStateSlugs -BlobNames $blobNames -KnownSlugs @($developers | ForEach-Object Slug))

                $residualRoots = @(Get-DeployResidualManagedState -SharedTfvarsPath $sharedTfvarsPath -Developers $developers `
                        -NameSeed $resolvedNameSeed -Location $resolvedLocation -LocationShortName $resolvedLocationShortName -VmSku $resolvedVmSku -PlaceholderKeyPath $placeholderKeyPath -TenantsDir $tenantsDir `
                        -ResolvedWorkDir $resolvedWorkDir -CommonRunnerArgs $commonRunnerArgs)

                $finalVerificationOk = $true
            }
            catch {
                Write-Host "Could not independently verify the backend container is free of unexpected tenant states, and that the shared/tenant Terraform state is actually empty ($($_.Exception.Message)); leaving the state backend in place."
            }
        }

        if ($phaseFailures.Count -gt 0) {
            Write-Host "Not retiring the state backend: $($phaseFailures.Count) earlier phase(s) failed ($($phaseFailures -join ', ')). Resolve them, then rerun -DestroyAll."
        }
        elseif ($remainingManifest.Count -gt 0) {
            Write-Host 'Not retiring the state backend: Entra user(s) recorded in the manifest could not be removed.'

            $phaseFailures.Add('backend-retirement-skipped:entra-manifest-nonempty')
        }
        elseif (-not $finalVerificationOk) {
            Write-Host 'Not retiring the state backend: could not independently verify no other tenant state remains in the backend container, and that the shared/tenant Terraform state is actually empty.'
            $phaseFailures.Add('backend-retirement-skipped:verification-failed')
        }
        elseif ($orphanSlugs.Count -gt 0) {
            Write-Host "Not retiring the state backend: found tenant state(s) in the backend container not covered by this CSV: $($orphanSlugs -join ', '). Add them back to the CSV and rerun -DestroyAll, or remove them by hand first."
            $phaseFailures.Add('backend-retirement-skipped:orphan-tenant-state')
        }
        elseif ($residualRoots.Count -gt 0) {
            Write-Host "Not retiring the state backend: a fresh destroy plan still shows pending managed-resource changes for: $($residualRoots -join ', '). This means Terraform state is not actually empty despite every earlier Destroy command reporting success -- investigate by hand (rerun the advanced per-root Plan -DestroyPlan/Destroy for the affected root(s), see docs/operations/runbook.md) before retrying -DestroyAll."
            $phaseFailures.Add('backend-retirement-skipped:residual-managed-state')
        }
        else {
            Write-Host '=== Retiring the Terraform state backend ==='
            Remove-DeployStateBackend -ResourceGroupName $script:StateResourceGroupName -StorageAccountName $stateStorageAccountName `
                -ContainerName $script:StateContainerName -StateAdministratorObjectId $resolvedStateAdministratorObjectId -Confirm:$false
            if (Test-Path -LiteralPath $BootstrapBackendHclPath -PathType Leaf) {
                Remove-Item -LiteralPath $BootstrapBackendHclPath -Force
            }
            Write-Host 'State backend retired.'

            if (Remove-DeployDeploymentProfileRecord -Path $deploymentProfile.PersistedPath) {
                Write-Host "Removed persisted deployment profile '$($deploymentProfile.PersistedPath)' now that the full teardown succeeded; the next normal deploy will re-resolve a fresh region/VM SKU (read-only, quota-aware) for this subscription instead of reusing the retired profile."
            }
        }
    }

    [ordered]@{
        status          = if ($phaseFailures.Count -gt 0) { 'PARTIAL' } else { 'DESTROYED' }
        phase_failures  = @($phaseFailures)
        tenants         = @($developers | ForEach-Object Slug)
    } | ConvertTo-Json -Depth 4 | Write-Host

    if ($phaseFailures.Count -gt 0) {
        throw "BLOCKED: -DestroyAll completed with $($phaseFailures.Count) unresolved failure(s): $($phaseFailures -join ', '). Rerun -DestroyAll after investigating; completed phases are safely skipped on rerun."
    }
}

function Get-DeployOrchestrationLockPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    return Join-Path (Get-DeployRuntimeStateDirectory -RepositoryRoot $RepositoryRoot) 'orchestration.lock'
}

function Test-DeployOrchestrationLockOwnerAlive {

    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Enter-DeployOrchestrationLock {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $stateDirectory = Get-DeployRuntimeStateDirectory -RepositoryRoot $RepositoryRoot
    Initialize-DeployRuntimeStateDirectory -Path $stateDirectory
    $lockPath = Get-DeployOrchestrationLockPath -RepositoryRoot $RepositoryRoot
    $record = [ordered]@{
        pid         = $PID
        started_utc = [DateTime]::UtcNow.ToString('o')
        host        = [Environment]::MachineName
    }
    $payload = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress))

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $stream.Write($payload, 0, $payload.Length)
            }
            finally {
                $stream.Dispose()
            }
            Set-DeployContextUnixPermissions -Path $lockPath -Mode '600'
            return
        }
        catch [IO.IOException] {
            if ($attempt -gt 0) {
                throw "Could not acquire the same-checkout orchestration lock at '$lockPath' even after reclaiming a stale one; refusing to proceed."
            }
            $existingPid = 0
            $existingStarted = 'an unknown time'
            try {
                $existing = Get-Content -LiteralPath $lockPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $existing.PSObject.Properties['pid']) { $existingPid = [int]$existing.pid }
                if ($null -ne $existing.PSObject.Properties['started_utc']) { $existingStarted = [string]$existing.started_utc }
            }
            catch {
                throw "A same-checkout orchestration lock already exists at '$lockPath' but could not be parsed. Refusing to run concurrently with a possibly still-running deploy/-DestroyAll invocation against this checkout (see docs/operations/runbook.md's Concurrency section). If you have independently confirmed no other invocation of this script is running, remove this file by hand and rerun."
            }
            if ($existingPid -gt 0 -and (Test-DeployOrchestrationLockOwnerAlive -ProcessId $existingPid)) {
                throw "Refusing to run: another deploy/-DestroyAll invocation (process ID $existingPid, started $existingStarted UTC) already holds the same-checkout orchestration lock at '$lockPath'. Concurrent invocations of scripts/Deploy-Azure.ps1 against the same checkout are not supported (see docs/operations/runbook.md's Concurrency section). Wait for it to finish, or -- only after independently confirming that process is no longer running -- remove the lock file by hand."
            }

            Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
        }
    }
}

function Exit-DeployOrchestrationLock {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $lockPath = Get-DeployOrchestrationLockPath -RepositoryRoot $RepositoryRoot
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

if ($MyInvocation.InvocationName -ne '.') {
try {

    Enter-DeployOrchestrationLock -RepositoryRoot $RepositoryRoot
    try {
    $UsersCsv = Resolve-DeployUsersCsvPath -Path $UsersCsv -ProviderRoot $RepositoryRoot
    if ($DestroyAll) {

        Invoke-DeployDestroyAllCommand
        exit 0
    }
    if ([IO.Path]::GetExtension($UsersCsv) -ine '.csv') {
        Stop-DeployUsage -Message 'UsersCsv must be a .csv file.'
    }
    Assert-DeploySshKeygenAvailable

    $resolvedWorkDir = Resolve-DeployWorkDir -Path $WorkDir
    Initialize-DeployWorkDir -Path $resolvedWorkDir
    $tenantsDir = Join-Path $resolvedWorkDir 'tenants'
    New-Item -ItemType Directory -Path $tenantsDir -Force | Out-Null

    Write-Host '=== Step 0a/7: resolving a subscription-usable deployment region and VM SKU (read-only, quota-aware) ==='
    $subscriptionAndTenantForProfile = Resolve-DeploySubscriptionAndTenant -SubscriptionId $SubscriptionId -TenantId $TenantId
    $deploymentProfile = Resolve-DeployDeploymentProfile -SubscriptionId $subscriptionAndTenantForProfile.SubscriptionId -TenantId $subscriptionAndTenantForProfile.TenantId `
        -LocationOverride $Location -LocationShortNameOverride $LocationShortName -VmSkuOverride $VmSku -RepositoryRoot $RepositoryRoot `
        -RockyImagePublisher $RockyImagePublisher -RockyImageOffer $RockyImageOffer -RockyImageSku $RockyImageSku
    $Location = $deploymentProfile.Location
    $LocationShortName = $deploymentProfile.LocationShortName
    $VmSku = $deploymentProfile.VmSku
    if ([string]::IsNullOrWhiteSpace($RockyImageVersion)) {
        $RockyImageVersion = $deploymentProfile.RockyImageVersion
    }
    $script:StateResourceGroupName = Get-DeployStateResourceGroupName -LocationShortName $LocationShortName
    Write-Host "Resolved deployment profile: location=$Location ($LocationShortName), VM SKU=$VmSku $(Format-DeployAutoTag $deploymentProfile.AutoDerived) [persisted: $($deploymentProfile.PersistedPath)]"

    $legacyStateAdvisory = Get-DeployLegacyStateResourceGroupAdvisory -ResolvedStateResourceGroupName $script:StateResourceGroupName
    if ($legacyStateAdvisory) { Write-Host $legacyStateAdvisory }

    Write-Host '=== Step 0/7: resolving Azure subscription/tenant/operator/UPN-domain/NameSeed/Rocky-image (read-only Az PowerShell lookups; any value already supplied explicitly is used as-is) ==='
    $simpleContext = Resolve-DeploySimpleContext -SubscriptionId $SubscriptionId -TenantId $TenantId `
        -StateAdministratorObjectId $StateAdministratorObjectId -UpnDomain $UpnDomain -NameSeed $NameSeed `
        -RockyImageVersion $RockyImageVersion -Location $Location -RockyImagePublisher $RockyImagePublisher `
        -RockyImageOffer $RockyImageOffer -RockyImageSku $RockyImageSku -RepositoryRoot $RepositoryRoot
    $SubscriptionId = [string]$simpleContext.SubscriptionId
    $TenantId = [string]$simpleContext.TenantId
    $StateAdministratorObjectId = @($simpleContext.StateAdministratorObjectId)
    $UpnDomain = [string]$simpleContext.UpnDomain
    $NameSeed = [string]$simpleContext.NameSeed
    $RockyImageVersion = [string]$simpleContext.RockyImageVersion

    $commonRunnerArgs = @(
        '-SubscriptionId', $SubscriptionId, '-TenantId', $TenantId,
        '-NameSeed', $NameSeed, '-Location', $Location, '-LocationShortName', $LocationShortName,
        '-StateAdministratorObjectId'
    ) + @($StateAdministratorObjectId)

    Write-Host '=== Step 1/7: validating the users CSV structure (read-only, no keys/Azure/Terraform I/O yet) ==='
    $structural = Test-UsersCsv -Path $UsersCsv -UpnDomain $UpnDomain
    $missingUpn = @($structural.users | Where-Object { [string]::IsNullOrWhiteSpace($_.upn) })
    if ($missingUpn.Count -gt 0) {
        Stop-DeployUsage -Message "UPN could not be resolved for: $(($missingUpn | ForEach-Object slug) -join ', '). Supply -UpnDomain."
    }

    Write-Host '=== Step 2/7: SSH keys (local only; generates any missing Ed25519 pair under keys/) ==='
    [void](Assert-DeploySshKeyPairs -KeysDirectory $KeysDirectory -Slugs @($structural.users | ForEach-Object slug))

    Write-Host '=== Step 3/7: resolving each generated SSH public key path (read-only, no Azure/Terraform I/O) ==='
    $validated = Test-UsersCsv -Path $UsersCsv -UpnDomain $UpnDomain -SshKeyDirectory $KeysDirectory -RequirePublicKeyFiles
    $validatedUsers = @($validated.users | ForEach-Object {
            [pscustomobject]@{
                Slug        = $_.slug
                Role        = $_.role
                Upn         = $_.upn
                SshKeyPath  = $_.ssh_public_key
                NetworkSlot = $_.network_slot
            }
        })

    $lead = $validatedUsers | Where-Object { $_.Role -eq 'devops_lead' } | Select-Object -First 1
    $developers = @($validatedUsers | Where-Object { $_.Role -eq 'developer' } | Sort-Object Slug)
    if ($null -eq $lead) { Stop-DeployUsage -Message 'No devops_lead row found (Test-UsersCsv should already have refused this).' }

    $rockyImage = [pscustomobject]@{
        Publisher = $RockyImagePublisher
        Offer     = $RockyImageOffer
        Sku       = $RockyImageSku
        Version   = $RockyImageVersion
    }
    $leadKeyPath = $lead.SshKeyPath

    Write-Host '=== Step 4/7: state-backend preflight, Entra account check, and Rocky Marketplace terms status (all read-only), then the pre-mutation summary ==='
    $preflight = Invoke-DeployRunner -RunnerArgs (@('-Command', 'Preflight') + $commonRunnerArgs) -AllowNonZeroExit

    $stateBootstrapNeeded = Test-DeployStateBootstrapNeeded -PreflightExitCode $preflight.ExitCode `
        -BackendConfigExists (Test-Path -LiteralPath $BootstrapBackendHclPath -PathType Leaf)

    $entraProvisioningActive = ($EntraMode -eq 'existing')
    $missingUsers = @()
    $existingUsers = @()
    if ($entraProvisioningActive) {
        $entraStatus = Get-DeployMissingEntraUsers -Users $validatedUsers
        $missingUsers = @($entraStatus.Missing)
        $existingUsers = @($entraStatus.Existing)
    }

    $marketplaceTermsStatus = Get-DeployRockyMarketplaceTermsStatus -Publisher $RockyImagePublisher `
        -Product $RockyImageOffer -Name $RockyImageSku -SubscriptionId $SubscriptionId

    Show-DeploySimpleSummary -Context $simpleContext -Lead $lead -Developers $developers `
        -MissingUsers $missingUsers -ExistingUsers $existingUsers -StateBootstrapNeeded $stateBootstrapNeeded `
        -EntraProvisioningActive $entraProvisioningActive -RockyMarketplaceTermsStatus $marketplaceTermsStatus

    $mutationDecision = Resolve-DeployMutationApproval -WhatIf $WhatIf.IsPresent `
        -ApproveSubscriptionMutations $ApproveSubscriptionMutations.IsPresent `
        -ApproveDirectoryMutations $ApproveDirectoryMutations.IsPresent `
        -InteractiveConfirmationGranted $false

    if ($WhatIf) {
        Write-Host 'PLANNED (preview only): -WhatIf never bootstraps the state backend, creates Entra users, or applies Terraform.'
        if ($stateBootstrapNeeded) {
            $ApplyStateBootstrap = $true
        }
    }
    elseif ($mutationDecision.RequiresInteractiveConfirmation) {
        $granted = Confirm-DeploySimpleRun
        $mutationDecision = Resolve-DeployMutationApproval -WhatIf $WhatIf.IsPresent `
            -ApproveSubscriptionMutations $ApproveSubscriptionMutations.IsPresent `
            -ApproveDirectoryMutations $ApproveDirectoryMutations.IsPresent `
            -InteractiveConfirmationGranted $granted
        if (-not $mutationDecision.MutationsApproved) {
            Write-Host 'Cancelled: no changes were made.'
            exit 1
        }
        $ApplyStateBootstrap = $true
        $ApproveSubscriptionMutations = $true
        $ApproveDirectoryMutations = $true
    }

    Write-Host '=== Step 5/7: state backend (Bootstrap only if needed) and missing-Entra-user creation (Az PowerShell, never Terraform) ==='
    if ($stateBootstrapNeeded) {
        if (-not $ApplyStateBootstrap) {
            foreach ($hint in @(Get-DeployAzureErrorHint -Text $preflight.Output)) { Write-Host $hint }
            throw 'BLOCKED: state backend preflight is not PASS and -ApplyStateBootstrap was not supplied. Review `Bootstrap -ApplyStateBootstrap -WhatIf` output, then rerun this command with -ApplyStateBootstrap after approval.'
        }
        $bootstrapArgs = @('-Command', 'Bootstrap') + $commonRunnerArgs + @('-ApplyStateBootstrap')
        if ($mutationDecision.StateBootstrapApplyAllowed) {

            $bootstrapArgs += @('-ApproveSubscriptionMutations', '-ApproveDirectoryMutations')
        }
        if ($WhatIf) { $bootstrapArgs += '-WhatIf' }
        $bootstrap = Invoke-DeployRunner -RunnerArgs $bootstrapArgs -AllowNonZeroExit
        if ($bootstrap.ExitCode -eq 2) {
            foreach ($hint in @(Get-DeployAzureErrorHint -Text $bootstrap.Output)) { Write-Host $hint }
            throw 'BLOCKED: state bootstrap is not ready; review its reported issue (Az context, required modules, or provider registration) before retrying.'
        }
        if ($bootstrap.ExitCode -ne 0) {
            throw "State bootstrap did not complete successfully (exit $($bootstrap.ExitCode))."
        }
        if ($WhatIf) {
            Write-Host 'PLANNED: -WhatIf stops after previewing the state bootstrap; rerun without -WhatIf to actually create it.'
            return
        }
        $preflightAfterBootstrap = Invoke-DeployRunner -RunnerArgs (@('-Command', 'Preflight') + $commonRunnerArgs) -AllowNonZeroExit
        if ($preflightAfterBootstrap.ExitCode -ne 0) {
            foreach ($hint in @(Get-DeployAzureErrorHint -Text $preflightAfterBootstrap.Output)) { Write-Host $hint }
            throw 'BLOCKED: state backend is still not PASS after Bootstrap; resolve the reported issue before continuing.'
        }
    }

    if ($entraProvisioningActive -and $mutationDecision.EntraUserCreationAllowed -and $missingUsers.Count -gt 0) {

        [void](New-DeployMissingEntraUsers -MissingUsers $missingUsers -RepositoryRoot $RepositoryRoot -SubscriptionId $SubscriptionId -TenantId $TenantId)
    }

    Write-Host '=== Step 5b/7: Rocky Linux 10 Azure Marketplace image terms (read-only check; a separate, explicit gate -- never inferred from -ApproveSubscriptionMutations/-ApproveDirectoryMutations or the general "yes" above -- only if not already accepted) ==='

    [void](Invoke-DeployRockyMarketplaceTermsGate -Publisher $RockyImagePublisher -Product $RockyImageOffer -Name $RockyImageSku `
            -SubscriptionId $SubscriptionId -WhatIf $WhatIf.IsPresent -TermsConfirmation $RockyMarketplaceTermsConfirmation)

    Write-Host '=== Step 5c/7: verifying every tenant remote state before shared MySQL migration (read-only) ==='
    Assert-DeployNoLegacyTenantPaaSState -BackendConfigPath $BootstrapBackendHclPath -TenantRootPath $TenantRootPath -Developers $developers

    # Read the one existing shared credential when available; otherwise create one only in
    # memory for the first shared plan/apply. A retry after a failed initial apply may obtain a
    # fresh value only when shared state has no credential output; Terraform then performs its
    # normal administrator-password update against the partially created server. It is restored
    # from the process environment after each shared Terraform operation and is never passed to
    # a tenant root.
    $sharedMysqlAdministratorPassword = Get-DeploySharedMysqlAdministratorPassword -BackendConfigPath $BootstrapBackendHclPath -RootPath $SharedRootPath

    Write-Host '=== Step 6/7: shared foundation, every tenant, and shared reconciliation (plan, then apply only once approved) ==='
    $sharedTfvarsPath = Join-Path $resolvedWorkDir 'shared.tfvars'

    $sharedTfvarsContent = New-SharedTfvarsContent -SubscriptionId $SubscriptionId -Location $Location -LocationShortName $LocationShortName -VmSku $VmSku -NameSeed $NameSeed `
        -AllowedSshCidr '0.0.0.0/0' -EntraMode $EntraMode -RockyImage $rockyImage `
        -Lead $lead -Developers $developers -LeadSshPublicKeyAbsolutePath $leadKeyPath -AppGatewayEnabled $false
    Set-Content -LiteralPath $sharedTfvarsPath -Value $sharedTfvarsContent -Encoding utf8 -NoNewline

    $sharedPlanPath = Join-Path $resolvedWorkDir 'shared-foundation.tfplan'
    Invoke-DeployRunnerWithSharedMysqlPassword -RunnerArgs (@('-Command', 'Plan', '-Root', 'shared', '-VarFile', $sharedTfvarsPath, '-PlanFile', $sharedPlanPath) + $commonRunnerArgs) -Password $sharedMysqlAdministratorPassword | Out-Null

    $approved = $mutationDecision.TerraformApplyAllowed
    if (-not $approved) {
        [ordered]@{
            status  = 'PLANNED'
            message = 'Every root through the shared foundation has been planned but nothing was applied (both -ApproveSubscriptionMutations and -ApproveDirectoryMutations are required, and -WhatIf always previews only). Review the saved plan, then rerun with both switches (and without -WhatIf).'
            plans   = @($sharedPlanPath)
        } | ConvertTo-Json -Depth 4 | Write-Host
        return
    }
    Invoke-DeployTerraformApplyWithRetry `
        -PlanRunnerArgs (@('-Command', 'Plan', '-Root', 'shared', '-VarFile', $sharedTfvarsPath, '-PlanFile', $sharedPlanPath) + $commonRunnerArgs) `
        -ApplyRunnerArgs (@('-Command', 'Apply', '-Root', 'shared', '-PlanFile', $sharedPlanPath, '-ApproveSubscriptionMutations', '-ApproveDirectoryMutations') + $commonRunnerArgs) `
        -SharedMysqlAdministratorPassword $sharedMysqlAdministratorPassword

    $sharedOutputs = Get-TerraformOutputJson -RootPath $SharedRootPath -BackendConfigPath $BootstrapBackendHclPath -StateKey 'shared.tfstate'
    $sharedValues = @{
        hub_vnet_id          = $sharedOutputs.shared_values.hub_vnet_id
        jump_public_ip       = $sharedOutputs.shared_values.jump_public_ip
        admin_username       = $sharedOutputs.shared_values.admin_username
        private_dns_zone_ids = $sharedOutputs.shared_values.private_dns_zone_ids
        developer_group_ids  = $sharedOutputs.identity.developer_group_ids
        lead_group_id        = $sharedOutputs.identity.lead_group_id
        custom_role_definition_id = $sharedOutputs.identity.custom_role_definition_id
        mysql                = $sharedOutputs.mysql
    }

    $tenantPlans = [Collections.Generic.List[string]]::new()
    $reconciliations = [Collections.Generic.List[pscustomobject]]::new()
    foreach ($developer in $developers) {
        Write-Host "--- Tenant: $($developer.Slug) ---"
        $tenantTfvarsPath = Join-Path $tenantsDir "$($developer.Slug).tfvars"
        $tenantTfvarsContent = New-TenantTfvarsContent -Location $Location -LocationShortName $LocationShortName -VmSku $VmSku -NameSeed $NameSeed -Developer $developer `
            -AllDevelopers $developers -SharedValues $sharedValues -DeveloperSshPublicKeyAbsolutePath $developer.SshKeyPath `
            -LeadSshPublicKeyAbsolutePath $leadKeyPath -RockyImage $rockyImage
        Set-Content -LiteralPath $tenantTfvarsPath -Value $tenantTfvarsContent -Encoding utf8 -NoNewline

        $tenantPlanPath = Join-Path $resolvedWorkDir "tenant-$($developer.Slug).tfplan"
        $tenantPlans.Add($tenantPlanPath)

        $secret = Get-TenantSecretPair -Slug $developer.Slug
        $priorMoodle = $env:TF_VAR_moodle_database_password
        $env:TF_VAR_moodle_database_password = [string]$secret.moodle_database_password
        try {
            Invoke-DeployRunner -RunnerArgs (@('-Command', 'Plan', '-Root', 'tenant', '-TenantSlug', $developer.Slug, '-VarFile', $tenantTfvarsPath, '-PlanFile', $tenantPlanPath) + $commonRunnerArgs) | Out-Null
            if ($approved) {
                Invoke-DeployTerraformApplyWithRetry `
                    -PlanRunnerArgs (@('-Command', 'Plan', '-Root', 'tenant', '-TenantSlug', $developer.Slug, '-VarFile', $tenantTfvarsPath, '-PlanFile', $tenantPlanPath) + $commonRunnerArgs) `
                    -ApplyRunnerArgs (@('-Command', 'Apply', '-Root', 'tenant', '-TenantSlug', $developer.Slug, '-PlanFile', $tenantPlanPath, '-ApproveSubscriptionMutations', '-ApproveDirectoryMutations') + $commonRunnerArgs)
                $tenantOutputs = Get-TerraformOutputJson -RootPath $TenantRootPath -BackendConfigPath $BootstrapBackendHclPath -StateKey "tenants/$($developer.Slug).tfstate"
                $reconciliations.Add([pscustomobject]$tenantOutputs.reconciliation)
            }
        }
        finally {
            $env:TF_VAR_moodle_database_password = $priorMoodle
        }
    }

    if (-not $approved) {
        [ordered]@{
            status  = 'PLANNED'
            message = 'Every tenant has been planned but nothing was applied. Review each saved plan, then rerun with both approval switches.'
            plans   = @($tenantPlans)
        } | ConvertTo-Json -Depth 4 | Write-Host
        return
    }

    $reconcileTfvarsPath = Join-Path $resolvedWorkDir 'shared-reconcile.tfvars'
    Set-Content -LiteralPath $reconcileTfvarsPath -Value (New-SharedReconcileTfvarsContent -TenantReconciliations $reconciliations) -Encoding utf8 -NoNewline
    $reconcilePlanPath = Join-Path $resolvedWorkDir 'shared-reconcile.tfplan'
    Invoke-DeployRunnerWithSharedMysqlPassword -RunnerArgs (@('-Command', 'Plan', '-Root', 'shared') + (New-DeployVarFilesRunnerArgs -Paths @($sharedTfvarsPath, $reconcileTfvarsPath)) + @('-PlanFile', $reconcilePlanPath) + $commonRunnerArgs) -Password $sharedMysqlAdministratorPassword | Out-Null
    Invoke-DeployTerraformApplyWithRetry `
        -PlanRunnerArgs (@('-Command', 'Plan', '-Root', 'shared') + (New-DeployVarFilesRunnerArgs -Paths @($sharedTfvarsPath, $reconcileTfvarsPath)) + @('-PlanFile', $reconcilePlanPath) + $commonRunnerArgs) `
        -ApplyRunnerArgs (@('-Command', 'Apply', '-Root', 'shared', '-PlanFile', $reconcilePlanPath, '-ApproveSubscriptionMutations', '-ApproveDirectoryMutations') + $commonRunnerArgs) `
        -SharedMysqlAdministratorPassword $sharedMysqlAdministratorPassword

    if (-not [string]::IsNullOrWhiteSpace($TenantSecretsCommand)) {
        Write-Host '=== Step 6/7: confirming every Terraform root is converged ==='
        Invoke-DeployRunner -RunnerArgs (@('-Command', 'Reconcile') + (New-DeployVarFilesRunnerArgs -Paths @($sharedTfvarsPath, $reconcileTfvarsPath)) + @('-TenantVarFileDirectory', $tenantsDir, '-TenantSecretsCommand', $TenantSecretsCommand) + $commonRunnerArgs) | Out-Null
    }

    $ansibleInventoryStagingDir = Join-Path $RepositoryRoot 'runtime/ansible/inventory'
    $ansibleInventoryPath = Join-Path $RepositoryRoot 'ansible/inventories/production/hosts.yml'
    $ansibleInventoryPath = Export-DeployProductionAnsibleInventory -SourceDirectory $ansibleInventoryStagingDir -DestinationPath $ansibleInventoryPath
    Write-Host '=== Step 7/7: configuring hosts with Ansible ==='
    Initialize-DeployAnsibleVault -CsvPath $UsersCsv -RepositoryRoot $RepositoryRoot `
        -VaultFilePath $AnsibleVaultFilePath -VaultPasswordFilePath $AnsibleVaultPasswordFilePath `
        -SubscriptionId $SubscriptionId -TenantId $TenantId
    $ansiblePrivateKeyPath = Join-Path $KeysDirectory $lead.Slug
    Assert-DeployAnsiblePrerequisites -PrivateKeyPath $ansiblePrivateKeyPath `
        -VaultFilePath $AnsibleVaultFilePath -VaultPasswordFilePath $AnsibleVaultPasswordFilePath
    Invoke-DeployAnsible -InventoryPath $ansibleInventoryPath -PrivateKeyPath $ansiblePrivateKeyPath `
        -Playbook $AnsiblePlaybook

    [ordered]@{
        status                = 'DEPLOYED'
        tenants               = @($developers | ForEach-Object { $_.Slug })
        work_dir              = $resolvedWorkDir
        ansible_inventory     = $ansibleInventoryPath
    } | ConvertTo-Json -Depth 4 | Write-Host
    }
    finally {
        $sharedMysqlAdministratorPassword = $null
        Exit-DeployOrchestrationLock -RepositoryRoot $RepositoryRoot
    }
}
catch {
    $message = $_.Exception.Message
    if ($message -match '^BLOCKED\b') {
        Write-Host $message
        exit 2
    }
    Write-Error $message
    exit 1
}
}
