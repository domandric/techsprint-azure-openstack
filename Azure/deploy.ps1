#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$hasUsersCsv = @($args | Where-Object { [string]$_ -ieq "-UsersCsv" }).Count -gt 0
$hasCommand = @($args | Where-Object { [string]$_ -ieq "-Command" }).Count -gt 0

if ($hasUsersCsv -and $hasCommand) {
    Write-Error "Refusing ambiguous invocation: use -UsersCsv for the one-shot workflow or -Command for the advanced lifecycle runner, never both."
    exit 1
}
if (-not $hasUsersCsv -and -not $hasCommand) {
    Write-Error "Specify -UsersCsv <path> for the one-shot Azure deployment, or -Command <Preflight|Bootstrap|Plan|Apply|Destroy|Reconcile> for advanced lifecycle operations."
    exit 1
}

$runner = if ($hasUsersCsv) {
    Join-Path $PSScriptRoot "scripts/Deploy-Azure.ps1"
}
else {
    Join-Path $PSScriptRoot "scripts/Invoke-Azure.ps1"
}

& $runner @args
exit $LASTEXITCODE
