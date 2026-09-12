#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsersCsv,
    [AllowEmptyString()][string]$SubscriptionId = '',
    [AllowEmptyString()][string]$TenantId = '',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'Resolve-AzureContext.ps1')
$BootstrapScript = Join-Path $RepositoryRoot 'bootstrap/Initialize-AzureTerraformState.ps1'

function Assert-ExportAnsibleStateContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackendConfigPath,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $hasSubscription = -not [string]::IsNullOrWhiteSpace($SubscriptionId)
    $hasTenant = -not [string]::IsNullOrWhiteSpace($TenantId)
    if ($hasSubscription -xor $hasTenant) {
        throw 'SubscriptionId and TenantId must be supplied together; refusing to infer an incomplete Azure context.'
    }

    $context = Resolve-DeploySubscriptionAndTenant -SubscriptionId $SubscriptionId -TenantId $TenantId
    $activeContext = Get-DeployActiveAzureContext
    Assert-DeployAzureContextUsable -Context $activeContext
    if ([string]$activeContext.Subscription.Id -ine $context.SubscriptionId -or
        [string]$activeContext.Tenant.Id -ine $context.TenantId) {
        throw 'The active Azure PowerShell session does not match the requested subscription/tenant; refusing to read Terraform state.'
    }

    $administrator = Resolve-DeployStateAdministratorObjectId -StateAdministratorObjectId @()
    $seed = Resolve-DeployNameSeed -NameSeed '' -SubscriptionId $context.SubscriptionId -TenantId $context.TenantId -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $BackendConfigPath -PathType Leaf)) {
        throw 'Terraform backend configuration is missing; refusing to read shared or tenant state.'
    }
    $backendText = Get-Content -LiteralPath $BackendConfigPath -Raw -Encoding utf8
    if ($backendText -notmatch '(?im)^\s*use_azuread_auth\s*=\s*true\s*$' -or
        $backendText -match '(?im)^\s*(access_key|sas_token|client_secret|client_certificate)\s*=') {
        throw 'Terraform backend configuration is not the approved Azure AD-only backend; refusing to read state.'
    }
    $locationShortName = $null
    if ($backendText -match '(?im)resource_group_name\s*=\s*"rg-ts-state-testing-([a-z]{2,6})"') {
        $locationShortName = $Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($locationShortName)) {
        throw 'Terraform backend configuration does not identify the canonical state resource group; refusing to read state.'
    }

    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $arguments = @(
        '-NoLogo', '-NoProfile', '-File', $BootstrapScript,
        '-SubscriptionId', $context.SubscriptionId,
        '-TenantId', $context.TenantId,
        '-NameSeed', $seed.NameSeed,
        '-LocationShortName', $locationShortName,
        '-StateAdministratorObjectId'
    ) + @($administrator.ObjectIds) + @('-PreflightOnly')
    $null = & $pwsh @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Terraform state backend preflight did not pass for the active Azure subscription/tenant; refusing to read state.'
    }
    return [pscustomobject]@{
        SubscriptionId = $context.SubscriptionId
        TenantId       = $context.TenantId
        NameSeed       = $seed.NameSeed
        BackendPath    = (Resolve-Path -LiteralPath $BackendConfigPath -ErrorAction Stop).Path
    }
}

function Set-DeploySecretFileMode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($IsWindows) { return }
    & chmod 600 -- $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Could not enforce mode 0600 on a generated secret file (path suppressed)."
    }
}

function New-DeployMoodleAdminPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = [Convert]::ToBase64String($bytes).TrimEnd('=')
    return "Aa1!$token"
}

function ConvertTo-DeployAnsibleSecretsDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$TenantSecrets,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SharedMysqlSecrets
    )

    foreach ($required in @('mysql_administrator_login', 'mysql_administrator_password')) {
        if ([string]::IsNullOrWhiteSpace([string]$SharedMysqlSecrets[$required])) {
            throw "Shared Terraform runtime_secrets output is missing '$required'."
        }
    }

    $moodleSecrets = [ordered]@{}
    foreach ($slug in @($TenantSecrets.Keys | Sort-Object)) {
        $runtime = $TenantSecrets[$slug]
        foreach ($required in @('db_name', 'db_user', 'db_password')) {
            if ([string]::IsNullOrWhiteSpace([string]$runtime[$required])) {
                throw "Tenant '$slug' Terraform runtime_secrets output is missing '$required'."
            }
        }
        $moodleSecrets[$slug] = [ordered]@{
            db_name              = [string]$runtime.db_name
            db_user              = [string]$runtime.db_user
            db_password          = [string]$runtime.db_password
            mysql_admin_user     = [string]$SharedMysqlSecrets.mysql_administrator_login
            mysql_admin_password = [string]$SharedMysqlSecrets.mysql_administrator_password
            admin_user           = 'moodleadmin'
            admin_password       = New-DeployMoodleAdminPassword
            admin_email          = "moodleadmin@$slug.moodle.test"
        }
    }
    return [ordered]@{ moodle_secrets = $moodleSecrets }
}

function Get-DeploySharedRuntimeSecretsFromTerraform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SharedRoot,
        [Parameter(Mandatory)][string]$BackendConfigPath
    )

    $terraform = (Get-Command terraform -ErrorAction Stop).Source
    $initOutput = & $terraform "-chdir=$SharedRoot" init -reconfigure -input=false -no-color -upgrade=false `
        "-backend-config=$BackendConfigPath" '-backend-config=key=shared.tfstate' 2>&1
    if ($LASTEXITCODE -ne 0) {
        $initOutput = $null
        throw 'Shared Terraform backend initialization failed while reading the shared MySQL credential (output suppressed).'
    }
    $initOutput = $null

    $rawOutput = & $terraform "-chdir=$SharedRoot" output -json shared_runtime_secrets 2>&1
    if ($LASTEXITCODE -ne 0) {
        $rawOutput = $null
        throw 'Shared Terraform shared_runtime_secrets output could not be read (output suppressed).'
    }
    try {
        $parsed = ($rawOutput -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -Depth 10 -ErrorAction Stop
        # Terraform returns the named output value directly. Accept the wrapped
        # shape as well for compatibility with callers that read all outputs.
        $value = $parsed
        if ($parsed -is [System.Collections.IDictionary] -and $parsed.ContainsKey('value')) {
            $value = $parsed.value
        }
        foreach ($required in @('mysql_administrator_login', 'mysql_administrator_password')) {
            if ([string]::IsNullOrWhiteSpace([string]$value[$required])) {
                throw 'missing shared credential field'
            }
        }
        return $value
    }
    catch {
        throw 'Shared Terraform shared_runtime_secrets output was invalid or incomplete (content suppressed).'
    }
    finally {
        $rawOutput = $null
    }
}

function Get-DeployTenantRuntimeSecretsFromTerraform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantRoot,
        [Parameter(Mandatory)][string]$BackendConfigPath,
        [Parameter(Mandatory)][string[]]$TenantSlugs
    )

    $terraform = (Get-Command terraform -ErrorAction Stop).Source
    $result = [ordered]@{}
    $uniqueSlugs = @($TenantSlugs | Sort-Object -Unique)
    if ($uniqueSlugs.Count -ne @($TenantSlugs).Count) {
        throw 'Developer slugs were duplicated; refusing to read ambiguous tenant state keys.'
    }
    foreach ($slug in $uniqueSlugs) {
        if ($slug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw "Unsafe tenant slug '$slug'."
        }
        $stateKey = "tenants/$slug.tfstate"
        $initOutput = & $terraform "-chdir=$TenantRoot" init -reconfigure -input=false -no-color "-backend-config=$BackendConfigPath" "-backend-config=key=$stateKey" 2>&1
        if ($LASTEXITCODE -ne 0) {
            $initOutput = $null
            throw "Terraform backend initialization failed for tenant '$slug' (secret output suppressed)."
        }
        $initOutput = $null

        $rawOutput = & $terraform "-chdir=$TenantRoot" output -json runtime_secrets 2>&1
        if ($LASTEXITCODE -ne 0) {
            $rawOutput = $null
            throw "Terraform runtime_secrets output could not be read for tenant '$slug' (output suppressed)."
        }
        try {
            $parsed = ($rawOutput -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop
        }
        catch {
            $rawOutput = $null
            throw "Terraform runtime_secrets output for tenant '$slug' was not valid JSON (content suppressed)."
        }
        $rawOutput = $null
        $outputValue = $parsed
        if ($parsed -is [System.Collections.IDictionary] -and $parsed.ContainsKey('value')) {
            $outputValue = $parsed.value
        }
        $tenantProperty = $outputValue.moodle_secrets[$slug]
        if ($null -eq $tenantProperty) {
            throw "Terraform runtime_secrets output did not contain the expected tenant '$slug'."
        }
        $result[$slug] = $tenantProperty
    }
    return $result
}

function New-DeployVaultPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes)
}

function Initialize-DeployVaultPasswordFile {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$VaultDestinationPath
    )

    $passwordPath = Join-Path $RepositoryRoot 'ansible/.vault-password'
    if (Test-Path -LiteralPath $passwordPath -PathType Leaf) {
        Set-DeploySecretFileMode -Path $passwordPath
        return $passwordPath
    }
    if (Test-Path -LiteralPath $VaultDestinationPath -PathType Leaf) {
        throw "Ansible Vault password file '$passwordPath' is missing, but an encrypted vault already exists at '$VaultDestinationPath'. Refusing to generate a new password, which would silently orphan the existing vault. Restore the original password file from a secure backup before rerunning; never delete or regenerate it casually."
    }

    $passwordDirectory = Split-Path -Parent $passwordPath
    New-Item -ItemType Directory -Path $passwordDirectory -Force | Out-Null
    $tempPasswordPath = Join-Path $passwordDirectory (".vault-password.tmp-$([guid]::NewGuid().ToString('N'))")
    try {
        $password = New-DeployVaultPassword
        Set-Content -LiteralPath $tempPasswordPath -Value $password -Encoding utf8 -NoNewline
        $password = $null
        Set-DeploySecretFileMode -Path $tempPasswordPath
        Move-Item -LiteralPath $tempPasswordPath -Destination $passwordPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPasswordPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPasswordPath -Force -ErrorAction SilentlyContinue
        }
    }
    Set-DeploySecretFileMode -Path $passwordPath
    return $passwordPath
}

function Protect-DeployAnsibleVaultDocument {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlaintextContent,
        [Parameter(Mandatory)][string]$VaultPasswordFilePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $ansibleVault = (Get-Command ansible-vault -ErrorAction Stop).Source
    $destinationDirectory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    $tempOutputPath = Join-Path $destinationDirectory (".vault.tmp-$([guid]::NewGuid().ToString('N'))")

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ansibleVault
    foreach ($argument in @('encrypt', '--vault-password-file', $VaultPasswordFilePath, '--output', $tempOutputPath, '-')) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false

    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $process.StandardInput.Write($PlaintextContent)
        }
        finally {
            $process.StandardInput.Close()
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $null = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $PlaintextContent = $null
    }

    if ($exitCode -ne 0) {
        if (Test-Path -LiteralPath $tempOutputPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempOutputPath -Force -ErrorAction SilentlyContinue
        }
        throw "ansible-vault encrypt failed with exit code $exitCode (details suppressed to avoid leaking sensitive content)."
    }
    if (-not (Test-Path -LiteralPath $tempOutputPath -PathType Leaf)) {
        throw 'ansible-vault did not produce the expected encrypted output file.'
    }

    Set-DeploySecretFileMode -Path $tempOutputPath
    Move-Item -LiteralPath $tempOutputPath -Destination $DestinationPath -Force
    Set-DeploySecretFileMode -Path $DestinationPath
    return $DestinationPath
}

function Export-DeployAnsibleSecrets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CsvPath,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [switch]$Overwrite
    )

    $backendConfig = Join-Path $RepositoryRoot 'bootstrap/backend.hcl'
    $tenantRoot = Join-Path $RepositoryRoot 'infra/azure/tenant'
    $sharedRoot = Join-Path $RepositoryRoot 'infra/azure/shared'
    $destination = Join-Path $RepositoryRoot 'ansible/inventories/production/group_vars/all/vault.yml'
    if (-not (Test-Path -LiteralPath $backendConfig -PathType Leaf)) {
        throw "bootstrap/backend.hcl is missing; restore the guarded state backend configuration before exporting Terraform outputs."
    }
    [void](Assert-ExportAnsibleStateContext -BackendConfigPath $backendConfig -RepositoryRoot $RepositoryRoot)
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and -not $Overwrite) {
        throw "Refusing to overwrite existing '$destination'. Review it, then rerun with -Force only if replacement is intended."
    }

    $vaultPasswordPath = Initialize-DeployVaultPasswordFile -RepositoryRoot $RepositoryRoot -VaultDestinationPath $destination

    $validator = Join-Path $RepositoryRoot 'scripts/Validate-AzureUsers.ps1'
    . $validator -Path $CsvPath
    $validated = Test-UsersCsv -Path $CsvPath -UpnDomain ''
    $slugs = @($validated.users | Where-Object { $_.role -eq 'developer' } | ForEach-Object { [string]$_.slug } | Sort-Object)
    if ($slugs.Count -lt 2) {
        throw 'At least two developer tenants are required before exporting Ansible secrets.'
    }

    # Read the shared administrator credential exactly once from shared state, then merge that
    # in memory into each tenant record. Tenant Terraform state contains only its own DB-user
    # password and never receives this shared administrator secret.
    $sharedMysqlSecrets = Get-DeploySharedRuntimeSecretsFromTerraform -SharedRoot $sharedRoot -BackendConfigPath $backendConfig
    $runtimeSecrets = Get-DeployTenantRuntimeSecretsFromTerraform -TenantRoot $tenantRoot -BackendConfigPath $backendConfig -TenantSlugs $slugs
    $document = ConvertTo-DeployAnsibleSecretsDocument -TenantSecrets $runtimeSecrets -SharedMysqlSecrets $sharedMysqlSecrets
    $sharedMysqlSecrets = $null
    $runtimeSecrets = $null
    $json = $document | ConvertTo-Json -Depth 10
    Protect-DeployAnsibleVaultDocument -PlaintextContent $json -VaultPasswordFilePath $vaultPasswordPath -DestinationPath $destination | Out-Null
    $json = $null
    Write-Host "Generated repository-local, gitignored, Ansible-Vault-encrypted secrets for $($slugs.Count) tenants at '$destination' (values suppressed)."
    return $destination
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Export-DeployAnsibleSecrets -CsvPath $UsersCsv -RepositoryRoot $repositoryRoot -Overwrite:$Force | Out-Null
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
