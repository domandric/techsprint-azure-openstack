#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Preflight', 'Bootstrap', 'Plan', 'Apply', 'Destroy', 'Reconcile')]
    [string]$Command,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NameSeed,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$StateAdministratorObjectId,

    [string]$Location = 'swedencentral',

    [string]$LocationShortName = 'swc',

    [ValidateSet('shared', 'tenant')]
    [string]$Root,

    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$TenantSlug,

    [string[]]$VarFile,

    [string]$VarFilesJson,

    [string]$PlanFile,

    [switch]$DestroyPlan,

    [switch]$ApplyStateBootstrap,

    [switch]$ApproveSubscriptionMutations,

    [switch]$ApproveDirectoryMutations,

    [switch]$AllowDestroy,

    [string]$DestroyConfirmation,

    [string]$TenantVarFileDirectory,

    [string]$TenantSecretsCommand,

    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not [string]::IsNullOrWhiteSpace($VarFilesJson)) {
    if ($null -ne $VarFile -and $VarFile.Count -gt 0) {
        throw 'Use either -VarFile or -VarFilesJson, never both.'
    }
    try {
        $decodedVarFiles = @($VarFilesJson | ConvertFrom-Json -NoEnumerate -ErrorAction Stop)
    }
    catch {
        throw '-VarFilesJson must be a valid JSON array of non-empty path strings.'
    }
    if ($decodedVarFiles.Count -ne 1 -or $decodedVarFiles[0] -isnot [array]) {
        throw '-VarFilesJson must be a valid JSON array of non-empty path strings.'
    }
    $VarFile = @($decodedVarFiles[0])
    if ($VarFile.Count -eq 0 -or @($VarFile | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
        throw '-VarFilesJson must be a valid JSON array of non-empty path strings.'
    }
}

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BootstrapScript = Join-Path $RepositoryRoot 'bootstrap/Initialize-AzureTerraformState.ps1'
$BootstrapBackendHcl = Join-Path $RepositoryRoot 'bootstrap/backend.hcl'
$TerraformRoots = @{
    shared = Join-Path $RepositoryRoot 'infra/azure/shared'
    tenant = Join-Path $RepositoryRoot 'infra/azure/tenant'
}

. (Join-Path $PSScriptRoot 'PathSafety.ps1')

function Stop-Usage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    throw "$Message`nThis runner intentionally accepts manual, root-specific tfvars only; keep sensitive tenant tfvars outside the repository."
}

function Get-RequiredFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Usage -Message "$Label must name an existing file."
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-RequiredDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        Stop-Usage -Message "$Label must name an existing directory."
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-OutsideRepository {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-RepositoryPathIsAllowed -Path $Path -RepositoryRoot $RepositoryRoot)) {
        throw "$Label must be outside the repository, or under the ignored repository runtime/ directory, because Terraform input and plan files can contain sensitive values."
    }
}

function Assert-TerraformAvailable {
    [CmdletBinding()]
    param()

    if ($null -eq (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw 'terraform is required on PATH; no Azure command was run.'
    }
}

function Invoke-CheckedTerraform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & terraform @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        throw "terraform $($Arguments[0]) failed with exit code $exitCode."
    }
}

function New-SharedMysqlAdministratorPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return "Aa1!$([Convert]::ToBase64String($bytes).TrimEnd('='))"
}

function Get-SharedMysqlAdministratorPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [switch]$AllowGenerate
    )

    if (-not [string]::IsNullOrWhiteSpace($env:TF_VAR_mysql_administrator_password)) {
        return [string]$env:TF_VAR_mysql_administrator_password
    }

    $rawOutput = & terraform "-chdir=$RootPath" output -json shared_runtime_secrets 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $parsed = ($rawOutput -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -Depth 10 -ErrorAction Stop
            # A named terraform output is normally emitted as its raw value;
            # tolerate the all-outputs wrapper as well.
            $outputValue = $parsed
            if ($parsed -is [System.Collections.IDictionary] -and $parsed.ContainsKey('value')) {
                $outputValue = $parsed.value
            }
            $password = [string]$outputValue.mysql_administrator_password
            if ([string]::IsNullOrWhiteSpace($password)) { throw 'missing password' }
            return $password
        }
        catch {
            throw 'BLOCKED: shared Terraform state exposed an unusable MySQL administrator credential output; refusing to generate a replacement.'
        }
        finally {
            $rawOutput = $null
        }
    }

    $isEmptyState = (($rawOutput -join [Environment]::NewLine) -match '(?i)no outputs found|output .* not found')
    $rawOutput = $null
    if (-not $isEmptyState) {
        throw 'BLOCKED: shared Terraform state could not be read for the MySQL administrator credential; refusing to generate a replacement.'
    }
    if ($AllowGenerate) {
        return New-SharedMysqlAdministratorPassword
    }
    throw 'BLOCKED: shared Terraform state has no shared MySQL credential output and no scoped credential was supplied; refusing to generate a replacement for this operation.'
}

function Invoke-CheckedTerraformWithSharedMysqlPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Password
    )
    $prior = $env:TF_VAR_mysql_administrator_password
    $env:TF_VAR_mysql_administrator_password = $Password
    try {
        Invoke-CheckedTerraform -WorkingDirectory $WorkingDirectory -Arguments $Arguments
    }
    finally {
        $env:TF_VAR_mysql_administrator_password = $prior
    }
}

function Assert-BackendConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Get-RequiredFile -Path $Path -Label 'BackendConfigPath'
    $contents = Get-Content -LiteralPath $resolved -Raw -Encoding utf8

    if ($contents -match '(?im)^\s*(access_key|sas_token|client_secret|client_certificate)\s*=') {
        throw 'BackendConfigPath contains credential material. Use Azure AD/OIDC authentication only.'
    }
    if ($contents -notmatch '(?im)^\s*use_azuread_auth\s*=\s*true\s*$') {
        throw 'BackendConfigPath must set use_azuread_auth = true.'
    }

    return $resolved
}

function Assert-RootRequest {
    [CmdletBinding()]
    param([switch]$RequireVarFile)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        Stop-Usage -Message 'Root is required and must be shared or tenant.'
    }
    if (-not $TerraformRoots.ContainsKey($Root)) {
        Stop-Usage -Message "Unknown Terraform root '$Root'."
    }
    if ($Root -eq 'tenant' -and [string]::IsNullOrWhiteSpace($TenantSlug)) {
        Stop-Usage -Message 'TenantSlug is required for the tenant root so each developer has a separate state key.'
    }
    if ($Root -eq 'shared' -and -not [string]::IsNullOrWhiteSpace($TenantSlug)) {
        Stop-Usage -Message 'TenantSlug is valid only with the tenant root.'
    }

    $resolvedVarFiles = @()
    if ($RequireVarFile) {
        if ($null -eq $VarFile -or $VarFile.Count -eq 0) {
            Stop-Usage -Message 'At least one VarFile is required for plan or apply.'
        }
        foreach ($path in $VarFile) {
            $resolved = Get-RequiredFile -Path $path -Label 'VarFile'
            Assert-OutsideRepository -Path $resolved -Label 'VarFile'
            $resolvedVarFiles += $resolved
        }
    }

    return [pscustomobject]@{
        RootPath    = $TerraformRoots[$Root]
        BackendPath = Assert-BackendConfig -Path $BootstrapBackendHcl
        StateKey    = if ($Root -eq 'shared') { 'shared.tfstate' } else { "tenants/$TenantSlug.tfstate" }
        VarFiles    = @($resolvedVarFiles)
    }
}

function Invoke-StateBackend {
    [CmdletBinding()]
    param([switch]$ApplyBootstrap)

    if (-not (Test-Path -LiteralPath $BootstrapScript -PathType Leaf)) {
        throw "Required state bootstrap script is missing: $BootstrapScript"
    }

    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $arguments = @(
        '-NoLogo', '-NoProfile', '-File', $BootstrapScript,
        '-SubscriptionId', $SubscriptionId,
        '-TenantId', $TenantId,
        '-NameSeed', $NameSeed,
        '-Location', $Location,
        '-LocationShortName', $LocationShortName,
        '-StateAdministratorObjectId'
    ) + @($StateAdministratorObjectId)

    if ($ApplyBootstrap) {
        $arguments += '-Apply'
        if ($WhatIf) {
            $arguments += '-WhatIf'
        }
        elseif ($ApproveSubscriptionMutations -and $ApproveDirectoryMutations) {

            $arguments += '-Confirm:$false'
        }
    }
    else {
        $arguments += '-PreflightOnly'
    }

    $output = @(& $pwsh @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    $script:StateBootstrapExitCode = $exitCode
    $script:StateBootstrapOutput = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
}

function Invoke-StateBackendPreflightWithRetry {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 5)][int]$MaximumAttempts = 3,
        [ValidateRange(0, 120)][int]$InitialDelaySeconds = 10
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        Invoke-StateBackend
        if ($script:StateBootstrapExitCode -eq 0) { return }
        $retryable = $script:StateBootstrapExitCode -eq 1 -and $script:StateBootstrapOutput -match '"failure_code"\s*:\s*"fail_closed"'
        if (-not $retryable -or $attempt -eq $MaximumAttempts) { return }
        $delay = $InitialDelaySeconds * [math]::Pow(2, $attempt - 1)
        Write-Warning "Azure state-backend preflight failed transiently on attempt $attempt/$MaximumAttempts. Waiting $delay seconds before retrying the read-only check."
        Start-Sleep -Seconds $delay
    }
}

function Assert-StateBackendReady {
    [CmdletBinding()]
    param()

    Invoke-StateBackendPreflightWithRetry
    if ($script:StateBootstrapExitCode -ne 0) {
        throw "State backend preflight is not PASS (exit $script:StateBootstrapExitCode). Resolve its reported issue before Terraform init or plan."
    }
    [void](Assert-BackendConfig -Path $BootstrapBackendHcl)
}

function Initialize-TerraformRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Request)

    Invoke-CheckedTerraform -WorkingDirectory $Request.RootPath -Arguments @(
        'init', '-input=false', '-no-color', '-upgrade=false', '-reconfigure', "-backend-config=$($Request.BackendPath)", "-backend-config=key=$($Request.StateKey)"
    )
    Invoke-CheckedTerraform -WorkingDirectory $Request.RootPath -Arguments @('validate', '-no-color')
}

function Get-PlanPath {
    [CmdletBinding()]
    param(
        [switch]$Required,
        [switch]$Existing
    )

    if ([string]::IsNullOrWhiteSpace($PlanFile)) {
        if ($Required) {
            Stop-Usage -Message 'PlanFile is required. Apply only accepts an explicit saved plan stored outside the repository.'
        }
        return $null
    }

    $resolved = [System.IO.Path]::GetFullPath($PlanFile)
    Assert-OutsideRepository -Path $resolved -Label 'PlanFile'
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        throw 'PlanFile must be a file path, not a directory.'
    }
    if ($Existing -and -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        Stop-Usage -Message 'PlanFile must name an existing reviewed saved destroy plan.'
    }

    return $resolved
}

function Invoke-TerraformPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [switch]$ForDestroy
    )

    Initialize-TerraformRoot -Request $Request
    $arguments = @('plan', '-input=false', '-no-color', '-lock-timeout=5m')
    foreach ($path in $Request.VarFiles) {
        $arguments += "-var-file=$path"
    }
    if ($ForDestroy) {
        $arguments += '-destroy'
        if ([string]::IsNullOrWhiteSpace($PlanFile)) {
            Stop-Usage -Message 'PlanFile is required when -DestroyPlan is used so Destroy can apply the reviewed saved plan.'
        }
    }

    $savedPlan = Get-PlanPath
    if ($null -ne $savedPlan) {
        $arguments += "-out=$savedPlan"
    }

    if ($Root -eq 'shared') {
        $password = Get-SharedMysqlAdministratorPassword -RootPath $Request.RootPath -AllowGenerate:(-not $ForDestroy)
        Invoke-CheckedTerraformWithSharedMysqlPassword -WorkingDirectory $Request.RootPath -Arguments $arguments -Password $password
        $password = $null
    }
    else {
        Invoke-CheckedTerraform -WorkingDirectory $Request.RootPath -Arguments $arguments
    }
}

function Assert-MutationApprovals {
    [CmdletBinding()]
    param([switch]$ForDestroy)

    if (-not $ApproveSubscriptionMutations -or -not $ApproveDirectoryMutations) {
        throw 'Refusing Azure mutation. Supply both -ApproveSubscriptionMutations and -ApproveDirectoryMutations after reviewing the plan.'
    }
    if ($ForDestroy) {
        if (-not $AllowDestroy -or $DestroyConfirmation -cne 'AZURE-DESTROY') {
            throw "Refusing destroy. Supply -AllowDestroy and -DestroyConfirmation 'AZURE-DESTROY' after reviewing the saved destroy plan."
        }
    }
}

function Invoke-TerraformApply {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Request)

    $savedPlan = Get-PlanPath -Required -Existing
    if ($savedPlan.EndsWith('.destroy.tfplan', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'PlanFile names a saved destroy plan; use the Destroy command for it instead of Apply.'
    }

    Initialize-TerraformRoot -Request $Request

    $arguments = @('apply', '-input=false', '-no-color', $savedPlan)
    if ($Root -eq 'shared') {
        $password = Get-SharedMysqlAdministratorPassword -RootPath $Request.RootPath
        try {
            Invoke-CheckedTerraformWithSharedMysqlPassword -WorkingDirectory $Request.RootPath -Arguments $arguments -Password $password
        }
        finally {
            $password = $null
        }
    }
    else {
        Invoke-CheckedTerraform -WorkingDirectory $Request.RootPath -Arguments $arguments
    }
}

function Get-TenantSecretEnv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Slug)

    if ([string]::IsNullOrWhiteSpace($TenantSecretsCommand)) {
        return $null
    }

    $output = & $TenantSecretsCommand $Slug
    if ($LASTEXITCODE -ne 0) {
        throw "TenantSecretsCommand failed for tenant '$Slug' with exit code $LASTEXITCODE."
    }
    try {
        $secret = ($output -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "TenantSecretsCommand output for tenant '$Slug' was not valid JSON."
    }
    foreach ($key in @('moodle_database_password')) {
        if (-not $secret.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$secret[$key])) {
            throw "TenantSecretsCommand output for tenant '$Slug' is missing '$key'."
        }
    }
    return @{ moodle_database_password = [string]$secret.moodle_database_password }
}

function Get-ExpectedTenantSlugs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$SharedRequest)

    $expression = 'jsonencode([for d in var.users.developers : d.slug])'
    $arguments = @('console', '-no-color')
    foreach ($path in $SharedRequest.VarFiles) {
        $arguments += "-var-file=$path"
    }

    Push-Location -LiteralPath $SharedRequest.RootPath
    try {
        $rawLines = @($expression | & terraform @arguments)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    $rawLines = @($rawLines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($exitCode -ne 0 -or $rawLines.Count -eq 0) {
        throw 'BLOCKED: unable to evaluate var.users.developers from the supplied shared var file(s) through terraform console; refusing Reconcile.'
    }

    try {

        $jsonText = $rawLines[-1] | ConvertFrom-Json
        $slugs = @($jsonText | ConvertFrom-Json)
    }
    catch {
        throw 'BLOCKED: unable to parse var.users.developers slugs evaluated through terraform console; refusing Reconcile.'
    }

    if ($slugs.Count -eq 0) {
        throw 'BLOCKED: the supplied shared var file(s) declare zero users.developers; refusing Reconcile (nothing to converge).'
    }

    $seen = [Collections.Generic.HashSet[string]]::new()
    $duplicates = [Collections.Generic.List[string]]::new()
    $normalized = [Collections.Generic.List[string]]::new()
    foreach ($slugValue in $slugs) {
        $slugString = [string]$slugValue
        if ($slugString -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw "BLOCKED: shared var.users.developers has slug '$slugString' that does not use the canonical slug pattern; refusing Reconcile."
        }
        if (-not $seen.Add($slugString)) {
            $duplicates.Add($slugString)
        }
        $normalized.Add($slugString)
    }
    if ($duplicates.Count -gt 0) {
        throw "BLOCKED: shared var.users.developers has duplicate slug(s): $((@($duplicates) | Sort-Object -Unique) -join ', '); refusing Reconcile."
    }

    return @($normalized | Sort-Object)
}

function Invoke-TenantReconcile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$SharedVarFile,
        [Parameter(Mandatory)][string]$Directory
    )

    $resolvedDirectory = Get-RequiredDirectory -Path $Directory -Label 'TenantVarFileDirectory'
    Assert-OutsideRepository -Path $resolvedDirectory -Label 'TenantVarFileDirectory'

    $tenantFiles = @(Get-ChildItem -LiteralPath $resolvedDirectory -Filter '*.tfvars' -File | Sort-Object Name)
    if ($tenantFiles.Count -eq 0) {
        Stop-Usage -Message 'TenantVarFileDirectory must contain one <slug>.tfvars file per known developer (mirroring shared var.users.developers).'
    }

    $backendPath = Assert-BackendConfig -Path $BootstrapBackendHcl
    $results = [ordered]@{}
    $stale = [Collections.Generic.List[string]]::new()
    $failed = [Collections.Generic.List[string]]::new()

    function Test-RootConverged {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Key,
            [Parameter(Mandatory)][pscustomobject]$PlanRequest
        )

        Initialize-TerraformRoot -Request $PlanRequest
        $arguments = @('plan', '-input=false', '-no-color', '-lock-timeout=5m', '-detailed-exitcode')
        foreach ($path in $PlanRequest.VarFiles) {
            $arguments += "-var-file=$path"
        }
        $priorSharedPassword = $env:TF_VAR_mysql_administrator_password
        if ($Key -eq 'shared') {
            $env:TF_VAR_mysql_administrator_password = $sharedMysqlPassword
        }
        try {
            Push-Location -LiteralPath $PlanRequest.RootPath
            try {
                & terraform @arguments 2>&1 | Out-Null
                $planExitCode = $LASTEXITCODE
            }
            finally {
                Pop-Location
            }
        }
        finally {
            if ($Key -eq 'shared') {
                $env:TF_VAR_mysql_administrator_password = $priorSharedPassword
            }
        }

        switch ($planExitCode) {
            0 { $results[$Key] = 'converged' }
            2 { $results[$Key] = 'stale'; $stale.Add($Key) }
            default { $results[$Key] = 'error'; $failed.Add($Key) }
        }
    }

    $sharedRequest = [pscustomobject]@{
        RootPath    = $TerraformRoots['shared']
        BackendPath = $backendPath
        StateKey    = 'shared.tfstate'
        VarFiles    = @($SharedVarFile | ForEach-Object { Get-RequiredFile -Path $_ -Label 'SharedVarFile' })
    }

    Initialize-TerraformRoot -Request $sharedRequest
    $sharedMysqlPassword = Get-SharedMysqlAdministratorPassword -RootPath $sharedRequest.RootPath
    $expectedSlugs = @(Get-ExpectedTenantSlugs -SharedRequest $sharedRequest)

    $foundSlugs = [Collections.Generic.List[string]]::new()
    foreach ($file in $tenantFiles) {
        $slug = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($slug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            Stop-Usage -Message "TenantVarFileDirectory file name '$($file.Name)' must be <slug>.tfvars using the canonical slug pattern."
        }
        $foundSlugs.Add($slug)
    }

    $foundDuplicates = @(@($foundSlugs) | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($foundDuplicates.Count -gt 0) {
        throw "BLOCKED: TenantVarFileDirectory has duplicate tenant slug(s) derived from file names: $($foundDuplicates -join ', '). Refusing Reconcile."
    }

    $expectedSet = [Collections.Generic.HashSet[string]]::new([string[]]$expectedSlugs)
    $foundSet = [Collections.Generic.HashSet[string]]::new([string[]]$foundSlugs)
    $missingSlugs = @($expectedSlugs | Where-Object { -not $foundSet.Contains($_) })
    $extraSlugs = @($foundSlugs | Where-Object { -not $expectedSet.Contains($_) })
    if ($missingSlugs.Count -gt 0 -or $extraSlugs.Count -gt 0) {
        $details = @()
        if ($missingSlugs.Count -gt 0) {
            $details += "missing <slug>.tfvars for slug(s) present in shared var.users.developers: $($missingSlugs -join ', ')"
        }
        if ($extraSlugs.Count -gt 0) {
            $details += "extra tenant varfile(s) whose slug(s) are not in shared var.users.developers: $($extraSlugs -join ', ')"
        }
        throw "BLOCKED: TenantVarFileDirectory does not exactly match shared var.users.developers -- $($details -join '; '). Refusing Reconcile."
    }

    Test-RootConverged -Key 'shared' -PlanRequest $sharedRequest

    foreach ($file in $tenantFiles) {
        $slug = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

        $priorMoodlePassword = $env:TF_VAR_moodle_database_password
        $secret = Get-TenantSecretEnv -Slug $slug
        if ($null -ne $secret) {
            $env:TF_VAR_moodle_database_password = [string]$secret.moodle_database_password
        }
        try {
            $tenantRequest = [pscustomobject]@{
                RootPath    = $TerraformRoots['tenant']
                BackendPath = $backendPath
                StateKey    = "tenants/$slug.tfstate"
                VarFiles    = @($file.FullName)
            }
            Test-RootConverged -Key $slug -PlanRequest $tenantRequest
        }
        finally {
            if ($null -ne $secret) {
                $env:TF_VAR_moodle_database_password = $priorMoodlePassword
            }
        }
    }

    [ordered]@{
        status         = if ($failed.Count -gt 0) { 'FAIL' } elseif ($stale.Count -gt 0) { 'BLOCKED' } else { 'PASS' }
        expected_slugs = @($expectedSlugs)
        roots          = $results
    } | ConvertTo-Json -Depth 4 | Write-Host

    if ($failed.Count -gt 0) {
        throw "Reconcile could not plan: $($failed -join ', '). Resolve the Terraform error for each, then rerun Reconcile."
    }
    if ($stale.Count -gt 0) {
        throw "BLOCKED: not every root is converged. Plan and apply these before onboarding is complete: $($stale -join ', ')."
    }
}

function Invoke-TerraformDestroy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Request)

    $savedPlan = Get-PlanPath -Required -Existing
    if (-not $savedPlan.EndsWith('.destroy.tfplan', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'PlanFile must use the .destroy.tfplan suffix to distinguish the reviewed destroy plan from an ordinary Terraform plan.'
    }

    Initialize-TerraformRoot -Request $Request

    Push-Location -LiteralPath $Request.RootPath
    try {
        $planJson = & terraform show -json $savedPlan 2>$null
        $showExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($showExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($planJson)) {
        throw 'Unable to inspect the saved destroy plan; refusing destructive apply.'
    }
    try {
        $plan = $planJson | ConvertFrom-Json -AsHashtable -Depth 100
        $changes = @($plan.resource_changes)
        if ($changes.Count -eq 0) {
            throw 'Saved destroy plan has no resource changes; refusing destructive apply.'
        }
        foreach ($change in $changes) {
            if (-not [string]::IsNullOrWhiteSpace([string]$change.mode) -and [string]$change.mode -cne 'managed') {
                continue
            }
            $actions = @($change.change.actions)
            if ($actions.Count -ne 1 -or $actions[0] -cne 'delete') {
                throw 'Saved plan includes a non-delete action; refusing destructive apply.'
            }
        }
    }
    catch {
        throw 'Saved destroy plan is not exclusively delete actions; refusing destructive apply.'
    }
    $arguments = @('apply', '-input=false', '-no-color', $savedPlan)
    if ($Root -eq 'shared') {
        # A reviewed destroy plan must use the existing shared credential when the
        # provider still needs it, but must never generate a replacement just to tear
        # down a server. Applying the saved plan does not require plaintext output.
        $password = Get-SharedMysqlAdministratorPassword -RootPath $Request.RootPath
        try {
            Invoke-CheckedTerraformWithSharedMysqlPassword -WorkingDirectory $Request.RootPath -Arguments $arguments -Password $password
        }
        finally {
            $password = $null
        }
    }
    else {
        Invoke-CheckedTerraform -WorkingDirectory $Request.RootPath -Arguments $arguments
    }
}

if ($MyInvocation.InvocationName -ne '.') {
try {
    switch ($Command) {
        'Preflight' {
            Assert-TerraformAvailable
            Invoke-StateBackendPreflightWithRetry
            if ($script:StateBootstrapExitCode -ne 0) {
                throw "BLOCKED: state backend preflight returned exit $script:StateBootstrapExitCode."
            }
            Write-Host 'PASS: state backend and local Terraform executable preflight completed.'
        }
        'Bootstrap' {
            Invoke-StateBackend -ApplyBootstrap:$ApplyStateBootstrap
            if ($script:StateBootstrapExitCode -eq 2) {
                throw "BLOCKED: state bootstrap is not ready (exit $script:StateBootstrapExitCode)."
            }
            if ($script:StateBootstrapExitCode -ne 0) {
                throw "State bootstrap did not complete successfully (exit $script:StateBootstrapExitCode)."
            }
        }
        'Plan' {
            Assert-TerraformAvailable
            Assert-StateBackendReady
            $request = Assert-RootRequest -RequireVarFile
            Invoke-TerraformPlan -Request $request -ForDestroy:$DestroyPlan
            Write-Host "PASS: $Root Terraform plan completed."
        }
        'Apply' {
            Assert-TerraformAvailable
            Assert-StateBackendReady
            $request = Assert-RootRequest
            Assert-MutationApprovals
            Invoke-TerraformApply -Request $request
            Write-Host "PASS: applied reviewed $Root Terraform plan."
        }
        'Destroy' {
            Assert-TerraformAvailable
            Assert-StateBackendReady
            $request = Assert-RootRequest
            Assert-MutationApprovals -ForDestroy
            Invoke-TerraformDestroy -Request $request
            Write-Host "PASS: applied reviewed destroy plan for $Root Terraform root. The state backend is intentionally preserved."
        }
        'Reconcile' {
            Assert-TerraformAvailable
            Assert-StateBackendReady
            if ($null -eq $VarFile -or $VarFile.Count -eq 0) {
                Stop-Usage -Message 'At least one -VarFile (the shared root input) is required for Reconcile.'
            }
            if ([string]::IsNullOrWhiteSpace($TenantVarFileDirectory)) {
                Stop-Usage -Message 'TenantVarFileDirectory is required for Reconcile.'
            }
            Invoke-TenantReconcile -SharedVarFile $VarFile -Directory $TenantVarFileDirectory
            Write-Host 'PASS: the shared root and every known tenant root are converged (no pending Terraform changes).'
        }
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
