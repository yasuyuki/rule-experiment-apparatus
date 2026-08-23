[CmdletBinding()]
param(
    # Hash-check every backup; restore only the live baseline/run snapshot and
    # previousBaseline. Historical backups were restore-verified at creation.
    # -Quick skips restores and the transition fixture.
    [switch]$Quick,
    [string]$StatePath,
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$ArchiveRoot,
    [string]$ReleaseBackupRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\WorkspaceBackup.ps1')

$VerifyArchiveRestore = -not $Quick
$VerifyReleaseBackupRestore = -not $Quick
$VerifyTransitions = -not $Quick
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$startStateHash = (Get-FileHash -LiteralPath $resolvedStatePath -Algorithm SHA256).Hash
$stateDocument = Read-ReleaseStateDocument -StatePath $resolvedStatePath -DocumentName 'system test state'
if ([int]$stateDocument.schemaVersion -eq 2) {
    $null = Read-LegacyReleaseStateV2ForMigration -StatePath $resolvedStatePath
    $transitionResult = if ($VerifyTransitions) {
        (& (Join-Path $PSScriptRoot 'Test-FoundationTransitions.ps1') -StatePath $resolvedStatePath -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
    } else {
        $null
    }
    $endStateHash = (Get-FileHash -LiteralPath $resolvedStatePath -Algorithm SHA256).Hash
    if ($endStateHash -ne $startStateHash) { throw 'Live schema v2 state changed during system preflight.' }
    [ordered]@{
        configPath = $resolvedConfigPath
        statePath = $resolvedStatePath
        healthy = $true
        migrationRequired = $true
        reasonCode = 'migration-required'
        schemaVersion = 2
        liveStateUnchanged = $true
        transitionFixture = $transitionResult
        checkedAt = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 7
    return
}
$state = Read-ReleaseState -StatePath $resolvedStatePath
if (-not $state.baseline) { throw 'Release state has no baseline.' }
if ([int]$state.generation -lt 0) { throw 'Release generation cannot be negative.' }
if ([int]$state.schemaVersion -ne 3) { throw 'Release state must use schema version 3.' }
if (@($state.transitionHistory).Count -lt 1) { throw 'Release transition history is empty.' }
$historyTail = @($state.transitionHistory)[-1] | ConvertTo-Json -Compress -Depth 8
$lastTransition = $state.lastTransition | ConvertTo-Json -Compress -Depth 8
if ($historyTail -ne $lastTransition) { throw 'lastTransition does not match the transitionHistory tail.' }
if ($state.baseline.instance -ne 'stable') { throw 'Baseline must occupy the stable instance.' }
if ($state.run -and $state.run.instance -ne 'candidate') { throw 'Run must occupy the candidate instance.' }

& (Join-Path $PSScriptRoot 'Test-Wrappers.ps1') -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Wrapper smoke test failed.' }
$baselineAcceptance = (& (Join-Path $PSScriptRoot 'Test-FoundationRelease.ps1') -Role baseline -StatePath $resolvedStatePath -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
if (-not $baselineAcceptance.accepted) { throw 'Baseline acceptance failed.' }

$runAcceptance = $null
if ($state.run) {
    $runAcceptance = (& (Join-Path $PSScriptRoot 'Test-FoundationRelease.ps1') -Role run -StatePath $resolvedStatePath -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
    if (-not $runAcceptance.accepted) { throw 'Run acceptance failed.' }
}

$status = (& (Join-Path $PSScriptRoot 'Get-FoundationStatus.ps1') -StatePath $resolvedStatePath -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
foreach ($role in @('baseline', 'run')) {
    $workspace = $status.workspaces.$role
    if ($null -eq $workspace) { continue }
    $localData = $workspace.localData
    if ($null -eq $localData) { throw "workspaces.$role.localData is missing." }
    if ([string]$localData.state -notin @('ok', 'skipped')) {
        throw "workspaces.$role.localData.state=$($localData.state) $($localData.summary) $($localData.problems -join '; ')"
    }
}
$transitionResult = $null
if ($VerifyTransitions) {
    $transitionResult = (& (Join-Path $PSScriptRoot 'Test-FoundationTransitions.ps1') -StatePath $resolvedStatePath -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
    if (-not $transitionResult.passed -or -not $transitionResult.liveStateUnchanged) {
        throw 'Transition fixture verification failed.'
    }
}
$archiveResults = [System.Collections.Generic.List[object]]::new()
$archiveVerificationRoot = Join-Path ([System.IO.Path]::GetFullPath($ArchiveRoot)) '.foundation-verify'
foreach ($manifestFile in @(Get-ChildItem -LiteralPath $ArchiveRoot -Filter *.json -File -ErrorAction SilentlyContinue)) {
    $manifest = Get-Content -Raw -LiteralPath $manifestFile.FullName | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $manifest.bundle.path -PathType Leaf)) { throw "Archive bundle missing: $($manifest.bundle.path)" }
    $actualHash = (Get-FileHash -LiteralPath $manifest.bundle.path -Algorithm SHA256).Hash
    if ($actualHash -ne $manifest.bundle.sha256) { throw "Archive hash mismatch: $($manifest.bundle.path)" }
    $restoreVerified = $null
    if ($VerifyArchiveRestore) {
        $restore = (& (Join-Path $PSScriptRoot 'Test-FoundationRepositoryArchive.ps1') -ManifestPath $manifestFile.FullName -VerificationRoot $archiveVerificationRoot) | ConvertFrom-Json
        if (-not $restore.restoreVerified) { throw "Archive restore failed: $($manifest.bundle.path)" }
        $restoreVerified = $true
    }
    $archiveResults.Add([ordered]@{
        manifest = $manifestFile.Name
        sha256Valid = $true
        sourceDeleted = [bool]$manifest.sourceDeleted
        restoreVerified = $restoreVerified
    })
}

$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
if ([string]::IsNullOrWhiteSpace($ReleaseBackupRoot)) {
    $ReleaseBackupRoot = Resolve-BackupRoot -Configuration $config -ConfigurationPath $resolvedConfigPath -BasePath (Get-ConfigurationWorkspaceRoot)
}
$expectedBackupSchema = 2
$expectedBackupKind = 'routed-foundation-workspace-backup'
$releaseBackupResults = [System.Collections.Generic.List[object]]::new()
$releaseBackupVerificationRoot = Join-Path ([System.IO.Path]::GetFullPath($ReleaseBackupRoot)) '.foundation-verify'
$releaseBackupManifests = @(Get-ChildItem -LiteralPath $ReleaseBackupRoot -Filter *.json -File -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{ File = $_; Manifest = (Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json) }
})
foreach ($item in @($releaseBackupManifests | Where-Object {
    [int]$_.Manifest.schemaVersion -eq $expectedBackupSchema -and $_.Manifest.kind -eq $expectedBackupKind
})) {
    $manifest = $item.Manifest
    if (-not $manifest.verified -or $manifest.deletionSupported) { throw "Unsafe release backup manifest: $($item.File.FullName)" }

    $bundles = @($manifest.repositories | ForEach-Object { $_.bundle })
    foreach ($bundle in $bundles) {
        if (-not (Test-Path -LiteralPath $bundle.path -PathType Leaf)) { throw "Release backup missing: $($bundle.path)" }
        $bundleItem = Get-Item -LiteralPath $bundle.path
        if ([long]$bundleItem.Length -ne [long]$bundle.length) { throw "Release backup length mismatch: $($bundle.path)" }
        $actualHash = (Get-FileHash -LiteralPath $bundle.path -Algorithm SHA256).Hash
        if ($actualHash -ne $bundle.sha256) { throw "Release backup hash mismatch: $($bundle.path)" }
    }
    $expectedCommit = [string]$manifest.source.commit
    if ([string]::IsNullOrWhiteSpace($expectedCommit)) {
        throw "Release backup source commit is empty: $($item.File.FullName)"
    }
    $restoreVerified = $null
    $isLiveRestoreTarget = Test-LiveReleaseBackupRestoreTarget `
        -Manifest $manifest `
        -State $state `
        -BaselineCommit ([string]$baselineAcceptance.commit) `
        -RunCommit $(if ($runAcceptance) { [string]$runAcceptance.commit } else { $null })
    if ($VerifyReleaseBackupRestore -and $isLiveRestoreTarget) {
        $restore = (& (Join-Path $PSScriptRoot 'Test-FoundationRepositoryArchive.ps1') -ManifestPath $item.File.FullName -VerificationRoot $releaseBackupVerificationRoot) | ConvertFrom-Json
        if (-not $restore.restoreVerified -or $restore.sourceCommit -ne $expectedCommit) {
            throw "Release backup restore failed for '$($item.File.Name)'."
        }
        $restoreVerified = $true
    }
    $releaseBackupResults.Add([ordered]@{
        role = [string]$manifest.role
        manifest = $item.File.Name
        schemaVersion = $expectedBackupSchema
        commit = $expectedCommit
        sha256Valid = $true
        restoreVerified = $restoreVerified
    })
}

$previousBaselineVerified = $null
if ($state.previousBaseline) {
    $previousManifest = Join-Path $ReleaseBackupRoot ([string]$state.previousBaseline.backupManifest)
    if (-not (Test-Path -LiteralPath $previousManifest -PathType Leaf)) {
        throw "Previous baseline backup manifest is missing: $previousManifest"
    }
    $previousHash = (Get-FileHash -LiteralPath $previousManifest -Algorithm SHA256).Hash
    if ($previousHash -ne [string]$state.previousBaseline.backupSha256) {
        throw 'Previous baseline backup manifest SHA-256 mismatch.'
    }
    if ($VerifyReleaseBackupRestore) {
        $previousRestore = (& (Join-Path $PSScriptRoot 'Test-FoundationRepositoryArchive.ps1') -ManifestPath $previousManifest -VerificationRoot $releaseBackupVerificationRoot) | ConvertFrom-Json
        if (-not $previousRestore.restoreVerified -or [string]$previousRestore.sourceCommit -ne [string]$state.previousBaseline.commit) {
            throw 'Previous baseline backup restore verification failed.'
        }
    }
    $previousBaselineVerified = $true
}

$endStateHash = (Get-FileHash -LiteralPath $resolvedStatePath -Algorithm SHA256).Hash
if ($endStateHash -ne $startStateHash) { throw 'Live release state changed during system verification.' }

[ordered]@{
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    healthy = $true
    migrationRequired = $false
    schemaVersion = 3
    liveStateUnchanged = $true
    checkedAt = [DateTimeOffset]::Now.ToString('o')
    generation = [int]$state.generation
    transitionHistoryCount = @($state.transitionHistory).Count
    baseline = [ordered]@{ name = [string]$state.baseline.name; instance = [string]$state.baseline.instance; commit = [string]$baselineAcceptance.commit; clean = [bool]$baselineAcceptance.clean }
    run = if ($state.run) { [ordered]@{ name = [string]$state.run.name; instance = [string]$state.run.instance; commit = [string]$runAcceptance.commit; clean = [bool]$runAcceptance.clean } } else { $null }
    previousBaseline = if ($state.previousBaseline) { [ordered]@{ name = [string]$state.previousBaseline.name; commit = [string]$state.previousBaseline.commit; verified = $previousBaselineVerified } } else { $null }
    canSeedRun = [bool]$status.canSeedRun
    transitionFixture = if ($VerifyTransitions) { $transitionResult } else { $null }
    archives = @($archiveResults)
    releaseBackups = @($releaseBackupResults)
} | ConvertTo-Json -Depth 7
