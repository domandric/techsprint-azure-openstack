#requires -Version 7.4

function Test-RepositoryPathIsAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $resolved = [System.IO.Path]::GetFullPath($Path)
    $comparison = if ($IsLinux) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    $runtimeRoot = Join-Path $RepositoryRoot 'runtime'
    $runtimePrefix = "$runtimeRoot$([System.IO.Path]::DirectorySeparatorChar)"
    $repositoryPrefix = "$RepositoryRoot$([System.IO.Path]::DirectorySeparatorChar)"

    $isUnderRuntime = $resolved.StartsWith($runtimePrefix, $comparison) -or $resolved.Equals($runtimeRoot, $comparison)
    $isInsideRepository = $resolved.StartsWith($repositoryPrefix, $comparison) -or $resolved.Equals($RepositoryRoot, $comparison)

    return (-not $isInsideRepository) -or $isUnderRuntime
}
