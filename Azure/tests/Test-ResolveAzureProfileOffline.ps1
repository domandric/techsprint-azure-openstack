#requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..' 'scripts' 'Resolve-AzureProfile.ps1'
. (Resolve-Path -LiteralPath $scriptPath).Path

function Assert-Offline {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Assert-OfflineThrows {
    param([Parameter(Mandatory)][scriptblock]$Script, [Parameter(Mandatory)][string]$Message)
    $threw = $false
    try { & $Script } catch { $threw = $true }
    Assert-Offline -Condition $threw -Message $Message
}

# These are deliberately offline checks: loading the Az modules is enough for
# the command-ownership checks; no Azure context or network request is used.
$realContextCommand = Get-AzureTrustedCommandInfo -Name 'Get-AzContext' -ModuleName 'Az.Accounts'
Assert-Offline -Condition ($realContextCommand.CommandType -eq [System.Management.Automation.CommandTypes]::Cmdlet) -Message 'Get-AzContext must resolve to a cmdlet.'
Assert-Offline -Condition ([string]$realContextCommand.ModuleName -ceq 'Az.Accounts') -Message 'Get-AzContext must be owned by Az.Accounts.'

function Get-AzContext { }
Assert-OfflineThrows -Script { Get-AzureTrustedCommandInfo -Name 'Get-AzContext' -ModuleName 'Az.Accounts' } -Message 'a same-name function must not shadow the trusted cmdlet.'
Assert-OfflineThrows -Script { Get-AzureTrustedCommandInfo -Name 'Get-AzCommandThatDoesNotExist' -ModuleName 'Az.Resources' } -Message 'a missing Azure interface must fail closed.'

$context = [pscustomobject]@{
    Subscription = [pscustomobject]@{ Id = 'SUB-ONE' }
    Tenant       = [pscustomobject]@{ Id = 'TENANT-ONE' }
}
$verified = [pscustomobject]@{
    Context        = $context
    SubscriptionId = 'sub-one'
    TenantId       = 'tenant-one'
}
Assert-OfflineThrows -Script {
    Invoke-AzureVerifiedCommand -CommandInfo $realContextCommand -VerifiedContext ([pscustomobject]@{
            Context = $context; SubscriptionId = 'sub-two'; TenantId = 'tenant-one'
        }) -Parameters @{}
} -Message 'a context switch/mismatched verified identity must fail closed.'

# Replace only the command lookup in this test process with a FunctionInfo. The
# production resolver never accepts FunctionInfo; this permits checking every
# helper's DefaultProfile forwarding without Azure or an HTTP endpoint.
$script:Forwarded = [Collections.Generic.List[object]]::new()
function Invoke-OfflineAz {
    param(
        $DefaultProfile, $ProviderNamespace, $Location, $PublisherName, $Offer, $Skus,
        $Id, $Name, $ResourceGroupName, $Scope, $ObjectId, $Method, $Path, $Payload
    )
    $script:Forwarded.Add([pscustomobject]@{ Name = $MyInvocation.BoundParameters['Name']; Method = $Method; Profile = $DefaultProfile; Path = $Path })
    if ($null -ne $Method -and $Method -eq 'GET') {
        return [pscustomobject]@{ StatusCode = 200; Content = '{"name":"10-lvm","properties":{"publisher":"resf","product":"rockylinux-x86_64","state":"Active"}}' }
    }
    if ($null -ne $Method -and $Method -eq 'PUT') {
        return [pscustomobject]@{ StatusCode = 200; Content = '{}' }
    }
    if ($null -ne $PublisherName) {
        return @([pscustomobject]@{ Version = '1.0.0' }, [pscustomobject]@{ Version = '2.0.0' })
    }
    if ($null -ne $ProviderNamespace) { return @([pscustomobject]@{ RegistrationState = 'Registered' }) }
    if ($null -ne $Scope) { return @([pscustomobject]@{ RoleDefinitionName = 'Reader' }) }
    if ($null -ne $ResourceGroupName) { return @([pscustomobject]@{ Name = 'resource' }) }
    if ($null -ne $Id) { return [pscustomobject]@{ Properties = [pscustomobject]@{ PolicyRule = @{} } } }
    if ($null -ne $Name) { return [pscustomobject]@{ ResourceGroupName = $Name } }
    if ($null -ne $Location -and $null -eq $PublisherName) {
        return @([pscustomobject]@{ Name = 'Standard_B2s'; Family = 'standardBFamily'; Location = $Location })
    }
    return @([pscustomobject]@{ DisplayName = 'location' })
}

function Get-AzureTrustedCommandInfo {
    param([string]$Name, [string]$ModuleName)
    return Microsoft.PowerShell.Core\Get-Command -Name Invoke-OfflineAz -CommandType Function
}

Get-DeployLocations -VerifiedContext $verified | Out-Null
Get-DeployResourceProvider -Namespace 'Microsoft.Compute' -VerifiedContext $verified | Out-Null
Get-DeployPolicyAssignments -VerifiedContext $verified | Out-Null
Get-DeployPolicyDefinitionRule -PolicyDefinitionId '/providers/Microsoft.Authorization/policyDefinitions/x' -VerifiedContext $verified | Out-Null
Get-DeployComputeResourceSkus -Location 'swedencentral' -VerifiedContext $verified | Out-Null
Get-DeployVmUsage -Location 'swedencentral' -VerifiedContext $verified | Out-Null
Resolve-DeployRockyImageVersion -RockyImageVersion '' -Location 'swedencentral' -Publisher 'resf' -Offer 'rockylinux-x86_64' -Sku '10-lvm' -VerifiedContext $verified | Out-Null
Get-DeployResourceGroupByName -Name 'rg-test' -VerifiedContext $verified | Out-Null
Get-DeployResourceGroupResourceCount -ResourceGroupName 'rg-test' -VerifiedContext $verified | Out-Null
Get-DeployRoleAssignments -Scope '/subscriptions/sub-one' -ObjectId 'object-one' -VerifiedContext $verified | Out-Null
Get-DeployRockyMarketplaceTermsStatus -Publisher 'resf' -Product 'rockylinux-x86_64' -Name '10-lvm' -VerifiedContext $verified | Out-Null
Set-DeployRockyMarketplaceTermsAccepted -Publisher 'resf' -Product 'rockylinux-x86_64' -Name '10-lvm' -VerifiedContext $verified -Confirm:$false | Out-Null

Assert-Offline -Condition ($script:Forwarded.Count -ge 12) -Message 'representative helpers must have invoked the offline CommandInfo.'
foreach ($call in $script:Forwarded) {
    Assert-Offline -Condition ($call.Profile -eq $context) -Message 'every Azure helper must forward the exact nested VerifiedContext.Context as DefaultProfile.'
}
$putCalls = @($script:Forwarded | Where-Object { $_.Method -eq 'PUT' })
Assert-Offline -Condition ($putCalls.Count -eq 1) -Message 'Marketplace acceptance must issue exactly one PUT.'
Assert-Offline -Condition ($putCalls[0].Path -match '/subscriptions/sub-one/') -Message 'Marketplace PUT must be bound to the verified subscription path.'

$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath).Path, [ref]$tokens, [ref]$errors) | Out-Null
Assert-Offline -Condition ($errors.Count -eq 0) -Message 'profile resolver must parse as PowerShell.'
$bareAzure = @($tokens | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandAst] -and
        [string]$_.GetCommandName() -match '^(Get|Set|Invoke)-Az'
    })
Assert-Offline -Condition ($bareAzure.Count -eq 0) -Message 'the resolver must not contain bare Azure command invocations.'

Write-Output 'PASS: Resolve-AzureProfile offline ownership, context, forwarding, Marketplace GET/PUT, and AST checks.'
