[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib\WorkspaceBackup.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', got '$Actual'." }
}

function Assert-True {
    param([bool]$Actual, [string]$Label)
    if (-not $Actual) { throw "$Label expected true." }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Label)
    try {
        & $Action | Out-Null
    } catch {
        return
    }
    throw "$Label expected an error."
}

Assert-Equal (ConvertTo-WorkspaceBundleLeaf -RelativePath '.') 'root' 'bundle leaf root'
Assert-Equal (ConvertTo-WorkspaceBundleLeaf -RelativePath 'example-app') 'example-app' 'bundle leaf flat'
Assert-Equal (ConvertTo-WorkspaceBundleLeaf -RelativePath 'apps/player') 'apps__player' 'bundle leaf nested'

$liveCommit = 'aaaaaaaaaaaabbbbbbbbbbccccccccccdddddddd'
$otherCommit = 'ffffffffffffffffffffffffffffffffffffffff'
$liveState = [pscustomobject]@{ generation = 11; run = $null; previousBaseline = $null }
$runState = [pscustomobject]@{
    generation = 11
    run = [pscustomobject]@{ name = 'fixture-run' }
    previousBaseline = $null
}
$liveBaseline = [pscustomobject]@{ generation = 11; role = 'baseline'; source = [pscustomobject]@{ commit = $liveCommit } }
$historicalBaseline = [pscustomobject]@{ generation = 10; role = 'baseline'; source = [pscustomobject]@{ commit = $liveCommit } }
$otherCommitBaseline = [pscustomobject]@{ generation = 11; role = 'baseline'; source = [pscustomobject]@{ commit = $otherCommit } }
$legacyActive = [pscustomobject]@{ generation = 11; channel = 'active'; source = [pscustomobject]@{ commit = $liveCommit } }
$liveRun = [pscustomobject]@{ generation = 11; role = 'run'; source = [pscustomobject]@{ commit = $otherCommit } }
Assert-True (Test-LiveReleaseBackupRestoreTarget -Manifest $liveBaseline -State $liveState -BaselineCommit $liveCommit) 'live baseline is a restore target'
Assert-True (-not (Test-LiveReleaseBackupRestoreTarget -Manifest $historicalBaseline -State $liveState -BaselineCommit $liveCommit)) 'historical backup is hash-only'
Assert-True (-not (Test-LiveReleaseBackupRestoreTarget -Manifest $otherCommitBaseline -State $liveState -BaselineCommit $liveCommit)) 'same generation different commit is hash-only'
Assert-True (-not (Test-LiveReleaseBackupRestoreTarget -Manifest $legacyActive -State $liveState -BaselineCommit $liveCommit)) 'legacy channel backup is hash-only'
Assert-True (Test-LiveReleaseBackupRestoreTarget -Manifest $liveRun -State $runState -BaselineCommit $liveCommit -RunCommit $otherCommit) 'live run is a restore target'
Assert-True (-not (Test-LiveReleaseBackupRestoreTarget -Manifest $liveRun -State $liveState -BaselineCommit $liveCommit -RunCommit $otherCommit)) 'run backup is hash-only when run is empty'

# Only environment identity is read from the live control plane. The live state
# may still be legacy v2 until phase 6, so this fixture treats it as opaque bytes.
$liveConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$liveStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$liveConfigHash = (Get-FileHash -LiteralPath $liveConfigPath -Algorithm SHA256).Hash
$liveStateHash = (Get-FileHash -LiteralPath $liveStatePath -Algorithm SHA256).Hash
$live = Read-EnvironmentConfig -ConfigPath $liveConfigPath
$stable = Get-ConfiguredInstance -Configuration $live -Name stable
$candidate = Get-ConfiguredInstance -Configuration $live -Name candidate

$fixtureId = [guid]::NewGuid().ToString('N')
$fixtureRoot = "/tmp/foundation-workspace-fixture-$fixtureId"
$baselineRoot = "$fixtureRoot/fixture-baseline"
$runRoot = "$fixtureRoot/fixture-run"
$childRelative = 'demo-project'
$childOrigin = 'https://example.invalid/demo-project.git'
$rootOrigin = 'https://example.invalid/foundation-root.git'
$windowsFixture = Join-Path $env:TEMP "foundation-workspace-fixture-$fixtureId"
New-Item -ItemType Directory -Force -Path $windowsFixture | Out-Null
$configPath = Join-Path $windowsFixture 'environment.json'
$statePath = Join-Path $windowsFixture 'release-state.json'
$backupRoot = Join-Path $windowsFixture 'release-backups'
$offsiteRoot = Join-Path $windowsFixture 'offsite'
$verifyRoot = Join-Path $windowsFixture 'verify'

try {
    $stableDistro = [string]$stable.wslDistro
    $stableUser = [string]$stable.wslUser
    $candidateDistro = [string]$candidate.wslDistro
    $candidateUser = [string]$candidate.wslUser

    & wsl.exe -d $stableDistro -u $stableUser -- mkdir -p "$baselineRoot/.cursor/rules" "$baselineRoot/.cursor/agents" "$baselineRoot/.claude/rules" "$baselineRoot/.claude/agents" "$baselineRoot/$childRelative"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create fixture directories.' }
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $baselineRoot init -b main
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $baselineRoot config user.email 'fixture@example.invalid'
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $baselineRoot config user.name 'fixture'
    & wsl.exe -d $stableDistro -u $stableUser -- sh -c "printf 'fixture\n' > '$baselineRoot/README.md'"
    $baselineMetadata = '{"schemaVersion":1,"release":"fixture-baseline","parentCommit":"none","role":"baseline"}'
    $baselineMetadataB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($baselineMetadata + "`n"))
    & wsl.exe -d $stableDistro -u $stableUser -- bash -c "printf '%s' '$baselineMetadataB64' | base64 -d > '$baselineRoot/FOUNDATION-RELEASE.json'"
    & wsl.exe -d $stableDistro -u $stableUser -- sh -c "printf '$childRelative/\n' > '$baselineRoot/.gitignore'"
    foreach ($path in @('.cursor/rules/r.md', '.cursor/agents/a.md', '.claude/rules/r.md', '.claude/agents/a.md')) {
        & wsl.exe -d $stableDistro -u $stableUser -- sh -c "printf 'x\n' > '$baselineRoot/$path'"
    }
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $baselineRoot add README.md FOUNDATION-RELEASE.json .gitignore .cursor .claude
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $baselineRoot commit -m 'baseline seed'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit fixture baseline root.' }
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $baselineRoot remote add origin $rootOrigin

    $childRoot = "$baselineRoot/$childRelative"
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot init -b main
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot config user.email 'fixture@example.invalid'
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot config user.name 'fixture'
    & wsl.exe -d $stableDistro -u $stableUser -- sh -c "printf 'child\n' > '$childRoot/README.md'"
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot add README.md
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot commit -m 'child seed'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit fixture child.' }
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot remote add origin $childOrigin

    $rootCommit = ("$(& wsl.exe -d $stableDistro -u $stableUser -- git -C $baselineRoot rev-parse HEAD)").Trim()
    $childCommit = ("$(& wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot rev-parse HEAD)").Trim()

    $fixtureInstances = $live.instances | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $fixtureInstances.candidate.userProfile = 'candidate\home'
    $fixtureInstances.candidate.userDataDir = 'candidate\user-data'
    $fixtureInstances.candidate.extensionsDir = 'candidate\extensions'
    $fixtureInstances.stable.releasesRoot = $fixtureRoot
    $fixtureInstances.candidate.releasesRoot = $fixtureRoot
    $windowsProjectPath = Join-Path $windowsFixture 'windows-project'
    New-Item -ItemType Directory -Force -Path $windowsProjectPath | Out-Null
    $configDoc = [ordered]@{
        schemaVersion = 2
        cursor = $live.cursor
        instances = $fixtureInstances
        controlPlane = $live.controlPlane
        repositoryDiscovery = $live.repositoryDiscovery
        storage = @{
            backupRoot = 'release-backups'
            verificationRoot = 'verify'
            localDataRoot = (Join-Path $windowsFixture 'local-data')
        }
        workspace = @{ repositories = @(@{ relativePath = $childRelative; origin = $childOrigin }) }
        projects = [ordered]@{
            home = [ordered]@{
                stable = [ordered]@{ kind = 'wsl'; path = [string]$stable.wslHome }
                candidate = [ordered]@{ kind = 'wsl'; path = [string]$candidate.wslHome }
            }
            windows = [ordered]@{
                stable = [ordered]@{ kind = 'windows'; path = 'windows-project' }
                candidate = [ordered]@{ kind = 'windows'; path = 'windows-project' }
            }
        }
    }
    $configDoc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8

    $transition = [ordered]@{
        action = 'bootstrap'
        at = [DateTimeOffset]::Now.ToString('o')
        from = 'none'
        to = 'fixture-baseline'
        commit = $rootCommit
    }
    $stateDoc = [ordered]@{
        schemaVersion = 3
        generation = 100
        baseline = [ordered]@{ name = 'fixture-baseline'; instance = 'stable'; path = $baselineRoot; gitRef = 'main' }
        run = $null
        previousBaseline = $null
        lastTransition = $transition
        transitionHistory = @($transition)
    }
    $stateDoc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8

    $config = Read-EnvironmentConfig -ConfigPath $configPath
    $declared = @(Get-ConfiguredWorkspaceRepositories -Configuration $config)
    $baselineSnapshot = Get-ReleaseWorkspaceSnapshot `
        -Instance $stable `
        -WorkspaceRoot $baselineRoot `
        -GitRef main `
        -DeclaredRepositories $declared `
        -Channel baseline `
        -EnforceMembership
    Assert-True ($baselineSnapshot.errors.Count -eq 0) 'clean baseline snapshot has no errors'
    Assert-True $baselineSnapshot.seedReady 'clean baseline snapshot is seed-ready'
    Assert-Equal $baselineSnapshot.commit $rootCommit 'baseline snapshot root commit'
    Assert-Equal @($baselineSnapshot.repositories | Where-Object { $_.relativePath -eq $childRelative })[0].head $childCommit 'baseline snapshot child commit'

    $baselineAcceptance = (& (Join-Path $PSScriptRoot 'Test-FoundationRelease.ps1') -Role baseline -StatePath $statePath -ConfigPath $configPath) | ConvertFrom-Json
    Assert-True $baselineAcceptance.accepted 'baseline acceptance'
    Assert-Equal $baselineAcceptance.workspace.repositories.Count 2 'baseline acceptance repository count'

    $badReleaseStatePath = Join-Path $windowsFixture 'release-state.bad-release-name.json'
    $badReleaseState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $badReleaseState.baseline.name = 'fixture-other-name'
    $badReleaseState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $badReleaseStatePath -Encoding utf8
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Test-FoundationRelease.ps1') -Role baseline -StatePath $badReleaseStatePath -ConfigPath $configPath
    } 'baseline acceptance rejects release-name mismatch'

    & wsl.exe -d $stableDistro -u $stableUser -- sh -c "printf 'dirty\n' >> '$childRoot/README.md'"
    $dirtyBaseline = Get-ReleaseWorkspaceSnapshot -Instance $stable -WorkspaceRoot $baselineRoot -GitRef main -DeclaredRepositories $declared -Channel baseline -EnforceMembership
    Assert-True (-not $dirtyBaseline.seedReady) 'dirty baseline is not seed-ready'
    Assert-True ($dirtyBaseline.errors.Count -eq 0) 'dirty baseline does not hard-error'
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot checkout -- README.md

    foreach ($case in @(
            @{ label = 'missing child'; relativePath = 'missing-repo'; origin = 'https://example.invalid/missing.git' },
            @{ label = 'wrong origin'; relativePath = $childRelative; origin = 'https://example.invalid/wrong.git' }
        )) {
        $badConfigPath = Join-Path $windowsFixture ("environment.$($case.label -replace ' ','-').json")
        $badConfig = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $badConfig.workspace.repositories = @(@{ relativePath = $case.relativePath; origin = $case.origin })
        $badConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $badConfigPath -Encoding utf8
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Test-FoundationRelease.ps1') -Role baseline -StatePath $statePath -ConfigPath $badConfigPath
        } "baseline acceptance rejects $($case.label)"
    }

    $extraRoot = "$baselineRoot/undeclared-extra"
    & wsl.exe -d $stableDistro -u $stableUser -- mkdir -p $extraRoot
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $extraRoot init -b main
    $baselineExtra = Get-ReleaseWorkspaceSnapshot -Instance $stable -WorkspaceRoot $baselineRoot -GitRef main -DeclaredRepositories $declared -Channel baseline -EnforceMembership
    Assert-True ($baselineExtra.warnings.Count -gt 0) 'undeclared repository warns on baseline'
    Assert-True ($baselineExtra.errors.Count -eq 0) 'undeclared repository does not fail baseline'
    & wsl.exe -d $stableDistro -u $stableUser -- rm -rf $extraRoot

    $baselineBackup = (& (Join-Path $PSScriptRoot 'New-FoundationReleaseBackup.ps1') `
        -Role baseline -ExpectedGeneration 100 -ExpectedCommit $rootCommit `
        -BackupRoot $backupRoot -StatePath $statePath -ConfigPath $configPath -Execute) | ConvertFrom-Json
    Assert-Equal ([int]$baselineBackup.schemaVersion) 2 'baseline backup schema 2'
    Assert-Equal $baselineBackup.repositories.Count 2 'baseline backup repository count'
    $baselineReuse = (& (Join-Path $PSScriptRoot 'New-FoundationReleaseBackup.ps1') `
        -Role baseline -ExpectedGeneration 100 -ExpectedCommit $rootCommit `
        -BackupRoot $backupRoot -StatePath $statePath -ConfigPath $configPath -Execute) | ConvertFrom-Json
    Assert-True ([bool]$baselineReuse.alreadyExisted) 'identical nested snapshot reuses backup'
    Assert-True ([bool]$baselineReuse.verified) 'reused backup stays verified'

    $childBundlePath = [string](@($baselineBackup.repositories | Where-Object { $_.relativePath -eq $childRelative })[0].bundle.path)
    $childBundleBytes = [System.IO.File]::ReadAllBytes($childBundlePath)
    [System.IO.File]::WriteAllBytes($childBundlePath, [byte[]](1, 2, 3, 4))
    try {
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'New-FoundationReleaseBackup.ps1') `
                -Role baseline -ExpectedGeneration 100 -ExpectedCommit $rootCommit `
                -BackupRoot $backupRoot -StatePath $statePath -ConfigPath $configPath -Execute
        } 'reuse refuses bundle hash mismatch'
    } finally {
        [System.IO.File]::WriteAllBytes($childBundlePath, $childBundleBytes)
    }

    & wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot commit --allow-empty -m 'move nested head'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to move fixture child HEAD.' }
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'New-FoundationReleaseBackup.ps1') `
            -Role baseline -ExpectedGeneration 100 -ExpectedCommit $rootCommit `
            -BackupRoot $backupRoot -StatePath $statePath -ConfigPath $configPath -Execute
    } 'reuse refuses moved nested head'
    & wsl.exe -d $stableDistro -u $stableUser -- git -C $childRoot checkout --quiet -B main $childCommit
    if ($LASTEXITCODE -ne 0) { throw 'Failed to restore fixture child HEAD.' }

    $baselineRestore = (& (Join-Path $PSScriptRoot 'Test-FoundationRepositoryArchive.ps1') -ManifestPath ([string]$baselineBackup.manifestPath) -VerificationRoot $verifyRoot) | ConvertFrom-Json
    Assert-True $baselineRestore.restoreVerified 'baseline workspace restore verified'
    Assert-Equal $baselineRestore.sourceCommit $rootCommit 'baseline restore root commit'
    Assert-Equal $baselineRestore.repositories.Count 2 'baseline restore repository count'

    $legacyMigrationPath = Join-Path $windowsFixture 'release-state.legacy-v2.json'
    [ordered]@{
        schemaVersion = 2
        generation = 99
        active = [ordered]@{ name = 'fixture-baseline'; instance = 'stable'; path = $baselineRoot; gitRef = 'main' }
        candidate = $null
        previous = $null
        lastTransition = $transition
        transitionHistory = @($transition)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $legacyMigrationPath -Encoding utf8
    $legacyHash = (Get-FileHash -LiteralPath $legacyMigrationPath -Algorithm SHA256).Hash
    $migrationPlan = (& (Join-Path $PSScriptRoot 'Migrate-FoundationRuntimeModel.ps1') -StatePath $legacyMigrationPath -ConfigPath $configPath -BackupRoot $backupRoot) | ConvertFrom-Json
    Assert-True (-not $migrationPlan.execute) 'migration defaults to dry-run'
    Assert-True $migrationPlan.backupVerified 'migration dry-run verifies backup'
    Assert-True $migrationPlan.restoreVerified 'migration dry-run verifies restore'
    Assert-Equal $migrationPlan.sourceStateSha256 $legacyHash 'migration dry-run records source state hash'
    Assert-Equal $migrationPlan.resultStateSha256 $legacyHash 'migration dry-run records unchanged result state hash'
    Assert-Equal (Get-FileHash -LiteralPath $legacyMigrationPath -Algorithm SHA256).Hash $legacyHash 'migration dry-run leaves v2 state unchanged'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Migrate-FoundationRuntimeModel.ps1') `
            -StatePath $legacyMigrationPath -ConfigPath $configPath -BackupRoot $backupRoot -ConfirmMigration `
            -ExpectedGeneration 99 -ExpectedStateSha256 ('0' * 64)
    } 'migration execute rejects a changed state hash'
    $migration = (& (Join-Path $PSScriptRoot 'Migrate-FoundationRuntimeModel.ps1') `
        -StatePath $legacyMigrationPath -ConfigPath $configPath -BackupRoot $backupRoot -ConfirmMigration `
        -ExpectedGeneration 99 -ExpectedStateSha256 $legacyHash) | ConvertFrom-Json
    $migratedState = Read-ReleaseState -StatePath $legacyMigrationPath
    Assert-True $migration.execute 'migration execute is explicit'
    Assert-Equal $migratedState.schemaVersion 3 'migration execute writes schema v3'
    Assert-Equal $migratedState.generation 100 'migration execute increments generation once'
    Assert-Equal $migratedState.baseline.instance 'stable' 'migration execute fixes baseline on stable'
    Assert-True ($null -eq $migratedState.run) 'migration execute leaves run empty'
    Assert-True (Test-Path -LiteralPath ([string]$migration.backupManifest) -PathType Leaf) 'migration execute records a persistent backup manifest'
    Assert-Equal (Get-FileHash -LiteralPath ([string]$migration.backupManifest) -Algorithm SHA256).Hash $migration.backupManifestSha256 'migration backup manifest hash matches'
    Assert-Equal (Get-FileHash -LiteralPath $legacyMigrationPath -Algorithm SHA256).Hash $migration.resultStateSha256 'migration result state hash matches'
    Assert-True (-not (Test-Path -LiteralPath "$legacyMigrationPath.lock")) 'migration releases the state lock'

    $publish = (& (Join-Path $PSScriptRoot 'Publish-VerifiedBackup.ps1') -ManifestPath ([string]$baselineBackup.manifestPath) -DestinationRoot $offsiteRoot -Execute) | ConvertFrom-Json
    Assert-True $publish.published 'baseline backup published'
    $offsiteManifest = Join-Path $offsiteRoot (Split-Path -Path ([string]$baselineBackup.manifestPath) -Leaf)
    $offsiteRestore = (& (Join-Path $PSScriptRoot 'Test-FoundationRepositoryArchive.ps1') -ManifestPath $offsiteManifest -VerificationRoot $verifyRoot) | ConvertFrom-Json
    Assert-True $offsiteRestore.restoreVerified 'offsite baseline restore verified'

    $restoredRun = Restore-FoundationWorkspaceBackup `
        -ManifestPath ([string]$baselineBackup.manifestPath) `
        -RestorePath $runRoot `
        -TargetDistro $candidateDistro `
        -TargetUser $candidateUser
    Assert-Equal $restoredRun.repositories.Count 2 'candidate restore includes root and child'
    & wsl.exe -d $candidateDistro -u $candidateUser -- git -C $runRoot checkout -B run/fixture $rootCommit
    & wsl.exe -d $candidateDistro -u $candidateUser -- git -C $runRoot config user.email 'fixture@example.invalid'
    & wsl.exe -d $candidateDistro -u $candidateUser -- git -C $runRoot config user.name 'fixture'
    $runMetadata = '{"schemaVersion":1,"release":"fixture-run","parentCommit":"' + $rootCommit + '","role":"run"}'
    $runMetadataB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($runMetadata + "`n"))
    & wsl.exe -d $candidateDistro -u $candidateUser -- bash -c "printf '%s' '$runMetadataB64' | base64 -d > '$runRoot/FOUNDATION-RELEASE.json'"
    & wsl.exe -d $candidateDistro -u $candidateUser -- git -C $runRoot add FOUNDATION-RELEASE.json
    & wsl.exe -d $candidateDistro -u $candidateUser -- git -C $runRoot commit -m 'Set FOUNDATION-RELEASE metadata for fixture-run'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit fixture run metadata.' }
    $runCommit = ("$(& wsl.exe -d $candidateDistro -u $candidateUser -- git -C $runRoot rev-parse HEAD)").Trim()

    $legacyRollbackPath = Join-Path $windowsFixture 'release-state.legacy-rollback.json'
    $legacyRollbackTransition = [ordered]@{
        action = 'promote'; at = [DateTimeOffset]::Now.ToString('o')
        from = 'fixture-run'; to = 'fixture-baseline'; commit = $rootCommit
    }
    [ordered]@{
        schemaVersion = 2; generation = 100
        active = [ordered]@{ name = 'fixture-baseline'; instance = 'stable'; path = $baselineRoot; gitRef = 'main' }
        candidate = $null
        previous = [ordered]@{ name = 'fixture-run'; instance = 'candidate'; path = $runRoot; gitRef = 'run/fixture' }
        lastTransition = $legacyRollbackTransition
        transitionHistory = @($transition, $legacyRollbackTransition)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $legacyRollbackPath -Encoding utf8
    $legacyRollbackHash = (Get-FileHash -LiteralPath $legacyRollbackPath -Algorithm SHA256).Hash
    $rollbackMigrationPlan = (& (Join-Path $PSScriptRoot 'Migrate-FoundationRuntimeModel.ps1') `
        -PreviousDisposition Rollback -StatePath $legacyRollbackPath -ConfigPath $configPath -BackupRoot $backupRoot) | ConvertFrom-Json
    Assert-Equal $rollbackMigrationPlan.previousDisposition 'Rollback' 'legacy previous rollback choice is explicit'
    Assert-Equal $rollbackMigrationPlan.baseline.name 'fixture-run' 'legacy rollback chooses previous as baseline'
    Assert-Equal $rollbackMigrationPlan.baseline.instance 'stable' 'legacy rollback target is fixed to stable'
    Assert-Equal (Get-FileHash -LiteralPath $legacyRollbackPath -Algorithm SHA256).Hash $legacyRollbackHash 'legacy rollback dry-run leaves v2 state unchanged'

    $stateWithRun = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $stateWithRun.generation = 101
    $stateWithRun.run = [pscustomobject]@{ name = 'fixture-run'; instance = 'candidate'; path = $runRoot; gitRef = 'run/fixture' }
    $stateWithRun.lastTransition = [pscustomobject]@{ action = 'seed'; at = [DateTimeOffset]::Now.ToString('o'); release = 'fixture-run'; commit = $runCommit }
    $stateWithRun.transitionHistory = @($transition, $stateWithRun.lastTransition)
    $stateWithRun | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8

    $runAcceptance = (& (Join-Path $PSScriptRoot 'Test-FoundationRelease.ps1') -Role run -StatePath $statePath -ConfigPath $configPath) | ConvertFrom-Json
    Assert-True $runAcceptance.accepted 'run acceptance'
    Assert-Equal $runAcceptance.foundationRelease 'fixture-run' 'run metadata release'
    $runMetadataRead = ("$(& wsl.exe -d $candidateDistro -u $candidateUser -- cat "$runRoot/FOUNDATION-RELEASE.json")").Trim() | ConvertFrom-Json
    Assert-Equal $runMetadataRead.role 'run' 'run metadata role'

    $runChild = "$runRoot/$childRelative"
    & wsl.exe -d $candidateDistro -u $candidateUser -- sh -c "printf 'dirty\n' >> '$runChild/README.md'"
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Test-FoundationRelease.ps1') -Role run -StatePath $statePath -ConfigPath $configPath
    } 'dirty run acceptance'
    & wsl.exe -d $candidateDistro -u $candidateUser -- git -C $runChild checkout -- README.md

    $runExtra = "$runRoot/undeclared-extra"
    & wsl.exe -d $candidateDistro -u $candidateUser -- mkdir -p $runExtra
    & wsl.exe -d $candidateDistro -u $candidateUser -- git -C $runExtra init -b main
    $runExtraSnapshot = Get-ReleaseWorkspaceSnapshot -Instance $candidate -WorkspaceRoot $runRoot -GitRef run/fixture -DeclaredRepositories $declared -Channel run -EnforceMembership
    Assert-True ($runExtraSnapshot.errors.Count -gt 0) 'undeclared repository fails run'
    & wsl.exe -d $candidateDistro -u $candidateUser -- rm -rf $runExtra

    $vendored = "$runChild/node_modules/vendored"
    & wsl.exe -d $candidateDistro -u $candidateUser -- mkdir -p $vendored
    & wsl.exe -d $candidateDistro -u $candidateUser -- git -C $vendored init -b main
    $vendoredSnapshot = Get-ReleaseWorkspaceSnapshot -Instance $candidate -WorkspaceRoot $runRoot -GitRef run/fixture -DeclaredRepositories $declared -Channel run -EnforceMembership
    Assert-Equal $vendoredSnapshot.undeclaredRepositories.Count 0 'nested vendored repo is not workspace membership'
    Assert-Equal $vendoredSnapshot.errors.Count 0 'nested vendored repo does not fail run'
    & wsl.exe -d $candidateDistro -u $candidateUser -- rm -rf "$runChild/node_modules"

    $fixtureStateHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    $runBackup = (& (Join-Path $PSScriptRoot 'New-FoundationReleaseBackup.ps1') `
        -Role run -ExpectedGeneration 101 -ExpectedCommit $runCommit `
        -BackupRoot $backupRoot -StatePath $statePath -ConfigPath $configPath -Execute) | ConvertFrom-Json
    $runRestore = (& (Join-Path $PSScriptRoot 'Test-FoundationRepositoryArchive.ps1') -ManifestPath ([string]$runBackup.manifestPath) -VerificationRoot $verifyRoot) | ConvertFrom-Json
    Assert-True $runRestore.restoreVerified 'run workspace restore verified'
    Assert-Equal $runRestore.repositories.Count 2 'run restore repository count'
    Assert-Equal @($runRestore.repositories | Where-Object { $_.relativePath -eq $childRelative })[0].restoredHead $childCommit 'run restore child commit'
    Assert-Equal (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash $fixtureStateHash 'backup and restore leave fixture state unchanged'

    $promoted = (& (Join-Path $PSScriptRoot 'Promote-Foundation.ps1') `
        -ExpectedGeneration 101 -BackupRoot $backupRoot -StatePath $statePath -ConfigPath $configPath) | ConvertFrom-Json
    Assert-Equal $promoted.baseline.instance 'stable' 'promote keeps baseline on stable'
    Assert-True ($null -eq $promoted.run) 'promote empties run slot'
    Assert-True ($null -ne $promoted.previousBaseline) 'promote records previousBaseline backup'
    $promotedSnapshot = Get-ReleaseWorkspaceSnapshot -Instance $stable -WorkspaceRoot $runRoot -GitRef run/fixture -DeclaredRepositories $declared -Channel baseline -EnforceMembership
    Assert-Equal $promotedSnapshot.commit $runCommit 'promoted baseline root matches accepted run'
    Assert-Equal @($promotedSnapshot.repositories | Where-Object { $_.relativePath -eq $childRelative })[0].head $childCommit 'promoted baseline child matches accepted run'

    $rolledBack = (& (Join-Path $PSScriptRoot 'Rollback-Foundation.ps1') `
        -ExpectedGeneration 102 -BackupRoot $backupRoot -StatePath $statePath -ConfigPath $configPath) | ConvertFrom-Json
    Assert-Equal $rolledBack.baseline.instance 'stable' 'rollback keeps baseline on stable'
    Assert-Equal $rolledBack.baseline.name 'fixture-baseline' 'rollback restores previous baseline name'
    Assert-True ($null -eq $rolledBack.run) 'rollback keeps run empty'
    Assert-True ($null -eq $rolledBack.previousBaseline) 'rollback consumes previousBaseline'
    $rolledBackSnapshot = Get-ReleaseWorkspaceSnapshot -Instance $stable -WorkspaceRoot $baselineRoot -GitRef main -DeclaredRepositories $declared -Channel baseline -EnforceMembership
    Assert-Equal $rolledBackSnapshot.commit $rootCommit 'rollback restores baseline root commit'
    Assert-Equal @($rolledBackSnapshot.repositories | Where-Object { $_.relativePath -eq $childRelative })[0].head $childCommit 'rollback restores baseline child commit'

    Assert-Equal (Get-FileHash -LiteralPath $liveConfigPath -Algorithm SHA256).Hash $liveConfigHash 'live config unchanged'
    Assert-Equal (Get-FileHash -LiteralPath $liveStatePath -Algorithm SHA256).Hash $liveStateHash 'live state unchanged'
    Write-Output 'PASS: v3 baseline/run acceptance and root+nested backup/restore fixtures'
} finally {
    & wsl.exe -d ([string]$stable.wslDistro) -u ([string]$stable.wslUser) -- rm -rf $fixtureRoot 2>$null | Out-Null
    & wsl.exe -d ([string]$candidate.wslDistro) -u ([string]$candidate.wslUser) -- rm -rf $fixtureRoot 2>$null | Out-Null
    if (Test-Path -LiteralPath $windowsFixture) {
        Remove-Item -LiteralPath $windowsFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
