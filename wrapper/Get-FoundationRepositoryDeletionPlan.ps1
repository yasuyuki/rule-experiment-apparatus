[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchiveRoot,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Result.ps1')

trap { Write-FoundationFailure -Command 'Get-FoundationRepositoryDeletionPlan.ps1' -ErrorRecord $_; exit 1 }

$inventory = Invoke-FoundationJsonScript `
    -Path (Join-Path $PSScriptRoot 'Get-FoundationRepositoryInventory.ps1') `
    -Arguments @{ StatePath = $StatePath; ConfigPath = $ConfigPath }
$manifests = [System.Collections.Generic.List[object]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath $ArchiveRoot -Filter *.json -File -ErrorAction SilentlyContinue)) {
    $manifest = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
    $bundleExists = Test-Path -LiteralPath $manifest.bundle.path -PathType Leaf
    $hashMatches = $false
    if ($bundleExists) {
        $hashMatches = (Get-FileHash -LiteralPath $manifest.bundle.path -Algorithm SHA256).Hash -eq $manifest.bundle.sha256
    }
    $manifests.Add([pscustomobject]@{
        manifestPath = $file.FullName
        sourceInstance = [string]$manifest.source.instance
        sourcePath = [string]$manifest.source.path
        sourceCommit = [string]$manifest.source.commit
        bundlePath = [string]$manifest.bundle.path
        verified = [bool]$manifest.verified
        hashMatches = $hashMatches
    })
}

$targets = [System.Collections.Generic.List[object]]::new()
$protected = [System.Collections.Generic.List[object]]::new()
foreach ($repo in @($inventory.repositories)) {
    $archive = @($manifests | Where-Object {
        $_.sourceInstance -eq $repo.instance -and $_.sourcePath -eq $repo.path -and $_.sourceCommit -eq $repo.commit
    })
    $eligible = $repo.channel -eq 'retired-unreferenced' -and -not $repo.dirty -and
        $archive.Count -eq 1 -and $archive[0].verified -and $archive[0].hashMatches
    $entry = [ordered]@{
        instance = [string]$repo.instance
        distro = [string]$repo.distro
        user = [string]$repo.user
        path = [string]$repo.path
        channel = [string]$repo.channel
        commit = [string]$repo.commit
        dirty = [bool]$repo.dirty
        archiveManifest = if ($archive.Count -eq 1) { [string]$archive[0].manifestPath } else { $null }
        archiveBundle = if ($archive.Count -eq 1) { [string]$archive[0].bundlePath } else { $null }
        archiveHashMatches = ($archive.Count -eq 1 -and $archive[0].hashMatches)
    }
    if ($eligible) { $targets.Add($entry) } else { $protected.Add($entry) }
}

$result = [ordered]@{
    generation = [int]$inventory.generation
    destructiveActionPerformed = $false
    deletionTargets = @($targets)
    protectedRepositories = @($protected)
    requiredConfirmation = 'Delete exactly the listed retired foundation repositories.'
}

(ConvertTo-FoundationSuccess -Result $result) | ConvertTo-Json -Depth 7
exit 0
