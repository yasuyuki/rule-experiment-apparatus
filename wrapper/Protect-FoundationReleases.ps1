[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OffsiteRoot,
    [switch]$Execute,
    [string]$BackupRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'release-backups'),
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$state = Read-ReleaseState -StatePath $resolvedStatePath
$inventory = (& (Join-Path $PSScriptRoot 'Get-FoundationRepositoryInventory.ps1') -StatePath $resolvedStatePath -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
$newBackup = Join-Path $PSScriptRoot 'New-FoundationReleaseBackup.ps1'
$testBackup = Join-Path $PSScriptRoot 'Test-FoundationRepositoryArchive.ps1'
$publishBackup = Join-Path $PSScriptRoot 'Publish-VerifiedBackup.ps1'
$results = [System.Collections.Generic.List[object]]::new()

foreach ($channel in @('active', 'previous')) {
    $release = $state.$channel
    if (-not $release) { continue }
    $matches = @($inventory.repositories | Where-Object { $_.channel -eq $channel -and $_.instance -eq $release.instance -and $_.path -eq $release.path })
    if ($matches.Count -ne 1) { throw "Expected one inventory match for '$channel'; found $($matches.Count)." }
    $commit = [string]$matches[0].commit
    $plan = (& $newBackup -Channel $channel -ExpectedGeneration ([int]$state.generation) -ExpectedCommit $commit -BackupRoot $BackupRoot -StatePath $resolvedStatePath -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
    $manifestPath = [string]$plan.manifestPath
    $bundlePaths = if ($plan.repositories) {
        @($plan.repositories | ForEach-Object { if ($_.bundlePath) { [string]$_.bundlePath } elseif ($_.bundle.path) { [string]$_.bundle.path } else { $null } })
    } else {
        @([string]$plan.bundlePath)
    }
    $bundlePaths = @($bundlePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $existingBundles = @($bundlePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($manifestExists -and $existingBundles.Count -notin @(0, $bundlePaths.Count)) {
        throw "Local release backup set is incomplete for '$channel'."
    }
    if (-not $manifestExists -and $existingBundles.Count -gt 0) {
        throw "Local release backup set is incomplete for '$channel'."
    }
    $backupComplete = $manifestExists -and ($existingBundles.Count -eq $bundlePaths.Count)

    $item = [ordered]@{
        channel = $channel
        commit = $commit
        localManifest = $manifestPath
        schemaVersion = [int]$plan.schemaVersion
        localBackupAlreadyExisted = $backupComplete
    }
    if (-not $Execute) {
        $item['localBackupWillBeCreated'] = -not $backupComplete
        $item['publishPlan'] = if ($backupComplete) {
            (& $publishBackup -ManifestPath $manifestPath -DestinationRoot $OffsiteRoot) | ConvertFrom-Json
        } else { $null }
        $results.Add($item)
        continue
    }

    if (-not $backupComplete) {
        (& $newBackup -Channel $channel -ExpectedGeneration ([int]$state.generation) -ExpectedCommit $commit -BackupRoot $BackupRoot -StatePath $resolvedStatePath -ConfigPath $resolvedConfigPath -Execute) | ConvertFrom-Json | Out-Null
    }
    $localRestore = (& $testBackup -ManifestPath $manifestPath -VerificationRoot (Join-Path $BackupRoot '.foundation-verify')) | ConvertFrom-Json
    if (-not $localRestore.restoreVerified -or $localRestore.sourceCommit -ne $commit) { throw "Local restore failed for '$channel'." }
    $publication = (& $publishBackup -ManifestPath $manifestPath -DestinationRoot $OffsiteRoot -Execute) | ConvertFrom-Json
    if (-not $publication.published) { throw "Off-site publish failed for '$channel'." }
    $offsiteManifest = Join-Path ([System.IO.Path]::GetFullPath($OffsiteRoot)) (Split-Path $manifestPath -Leaf)
    $offsiteRestore = (& $testBackup -ManifestPath $offsiteManifest -VerificationRoot (Join-Path $OffsiteRoot '.foundation-verify')) | ConvertFrom-Json
    if (-not $offsiteRestore.restoreVerified -or $offsiteRestore.sourceCommit -ne $commit) { throw "Off-site restore failed for '$channel'." }
    $item['localRestoreVerified'] = $true
    $item['published'] = $true
    $item['alreadyPublished'] = [bool]$publication.alreadyPublished
    $item['offsiteManifest'] = $offsiteManifest
    $item['offsiteRestoreVerified'] = $true
    $item['temporaryDataDeleted'] = [bool]$offsiteRestore.temporaryRestoreDeleted
    $results.Add($item)
}

[ordered]@{
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    action = 'protect-rule-experiment-systems-offsite'
    execute = [bool]$Execute
    generation = [int]$state.generation
    offsiteRoot = [System.IO.Path]::GetFullPath($OffsiteRoot)
    releases = @($results)
} | ConvertTo-Json -Depth 8
