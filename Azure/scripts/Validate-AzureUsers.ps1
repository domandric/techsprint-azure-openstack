#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [string]$UpnDomain,

    [string]$SshKeyDirectory,

    [switch]$RequirePublicKeyFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RequiredHeader = 'ime;prezime;rola'
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function ConvertTo-AzureSlug {
    param([Parameter(Mandatory)][string]$Value)

    $decomposed = $Value.Replace([char]0x0111, 'd').Replace([char]0x0110, 'D').Normalize([Text.NormalizationForm]::FormD)
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $decomposed.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -notin @(
                [Globalization.UnicodeCategory]::NonSpacingMark,
                [Globalization.UnicodeCategory]::SpacingCombiningMark,
                [Globalization.UnicodeCategory]::EnclosingMark
            )) {
            [void]$builder.Append($character)
        }
    }

    $slug = $builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $slug = $slug -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug) -or $slug.Length -gt 40) {
        throw "Invalid slug '$slug'; it must contain 1-40 lowercase ASCII characters."
    }
    return $slug
}

function Get-DeterministicSlot {
    param([Parameter(Mandatory)][string]$Slug)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Slug)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    $value = [Convert]::ToUInt32([Convert]::ToHexString($hash).Substring(0, 8), 16)
    return [int]($value % 64)
}

function Resolve-SshKeyDirectoryPublicKeyPath {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Slug,
        [switch]$RequireFile
    )
    $resolvedDirectory = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path
    $candidate = [IO.Path]::GetFullPath((Join-Path $resolvedDirectory "$Slug.pub"))
    $prefix = "$resolvedDirectory$([IO.Path]::DirectorySeparatorChar)"
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved key path for '$Slug' escapes -SshKeyDirectory."
    }
    if ($RequireFile -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "ssh_public_key does not resolve to a file under -SshKeyDirectory for '$Slug': $candidate"
    }
    return $candidate
}

function Test-UsersCsv {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$UpnDomain,
        [AllowEmptyString()][string]$SshKeyDirectory,
        [switch]$RequirePublicKeyFiles
    )

    if (-not [string]::IsNullOrWhiteSpace($UpnDomain) -and $UpnDomain -match '[@\s]') {
        throw "UpnDomain must not contain '@' or whitespace."
    }

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if ([IO.Path]::GetExtension($resolved) -ine '.csv') {
        throw 'Users input must be a UTF-8 .csv file.'
    }
    $header = Get-Content -LiteralPath $resolved -Encoding utf8 -TotalCount 1
    if ($header -cne $script:RequiredHeader) {
        throw "CSV header must be exactly '$script:RequiredHeader' (../docs/IRUO_Projekt_2025_2026-2.pdf's own example)."
    }

    $rows = @(Import-Csv -LiteralPath $resolved -Delimiter ';' -Encoding utf8)
    if ($rows.Count -eq 0) {
        throw 'Users CSV must contain at least one user row.'
    }

    $slugs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $leadCount = 0
    $developerCount = 0
    $summary = [Collections.Generic.List[object]]::new()
    $developerSlots = [Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $firstName = $row.ime.Trim()
        $lastName = $row.prezime.Trim()
        $role = $row.rola.Trim()
        if ([string]::IsNullOrWhiteSpace($firstName) -or [string]::IsNullOrWhiteSpace($lastName) -or
            $role -notin @('developer', 'devops_lead')) {
            throw 'Every row needs non-empty ime, prezime, and rola (developer or devops_lead).'
        }

        $slug = ConvertTo-AzureSlug "$firstName-$lastName"
        if (-not $slugs.Add($slug)) {
            throw "Slug collision: $slug"
        }

        $upn = if ([string]::IsNullOrWhiteSpace($UpnDomain)) { '' } else { "$slug@$UpnDomain" }

        $keyPath = ''
        if (-not [string]::IsNullOrWhiteSpace($SshKeyDirectory)) {
            $keyPath = Resolve-SshKeyDirectoryPublicKeyPath -Directory $SshKeyDirectory -Slug $slug -RequireFile:$RequirePublicKeyFiles
        }
        elseif ($RequirePublicKeyFiles) {
            throw "ssh_public_key is required for $firstName $lastName when -RequirePublicKeyFiles is used (supply -SshKeyDirectory)."
        }

        $slot = $null
        if ($role -eq 'devops_lead') {
            $leadCount++
        }
        else {
            $developerCount++
            $slot = Get-DeterministicSlot $slug
            $developerSlots.Add([pscustomobject]@{ Slug = $slug; Slot = $slot })
        }

        $summary.Add([ordered]@{ slug = $slug; role = $role; upn = $upn; ssh_public_key = $keyPath; network_slot = $slot })
    }

    $slotCollisions = @($developerSlots | Group-Object Slot | Where-Object Count -gt 1)
    if ($slotCollisions.Count -gt 0) {
        $details = ($slotCollisions | ForEach-Object {
                "slot $($_.Name): $(($_.Group | ForEach-Object Slug) -join ', ')"
            }) -join '; '
        throw "network_slot collision ($details). network_slot is derived from the slug's hash, not chosen; change one of the colliding developers' ime/prezime so its slug -- and therefore its slot -- differs."
    }

    if ($leadCount -ne 1) {
        throw "Exactly one devops_lead is required; found $leadCount."
    }
    if ($developerCount -lt 2) {
        throw "At least 2 developers are required; found $developerCount."
    }

    return [ordered]@{
        status     = 'PASS'

        users      = @($summary | Sort-Object { $_.role }, { $_.slug })
        user_count = $rows.Count
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Test-UsersCsv -Path $Path -UpnDomain $UpnDomain -SshKeyDirectory $SshKeyDirectory -RequirePublicKeyFiles:$RequirePublicKeyFiles |
            ConvertTo-Json -Depth 4
    }
    catch {
        [ordered]@{ status = 'FAIL'; failure = $_.Exception.Message } | ConvertTo-Json -Compress
        exit 1
    }
}
