[CmdletBinding()]
param(
    [ValidateSet('Rollback', 'Discard')][string]$PreviousDisposition,
    [switch]$ConfirmMigration,
    [int]$ExpectedGeneration = -1,
    [string]$ExpectedStateSha256,
    [string]$BackupRoot,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\CursorHandoff.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib\WorkspaceBackup.ps1')
$StatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$ConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $ConfigPath
$configuredBackupRoot = Resolve-BackupRoot -BackupRoot $BackupRoot -Configuration $config -ConfigurationPath $ConfigPath -BasePath (Get-ConfigurationWorkspaceRoot)
$lock = Enter-ReleaseStateLock -StatePath $StatePath -DryRun:(-not $ConfirmMigration)
try {
$legacy = Read-LegacyReleaseStateV2ForMigration -StatePath $StatePath
if ($legacy.candidate) { throw 'Migration requires the legacy candidate channel to be empty.' }
if ($legacy.previous -and [string]::IsNullOrWhiteSpace($PreviousDisposition)) {
    throw 'Legacy previous exists. Choose -PreviousDisposition Rollback or Discard before migration.'
}
if (-not $legacy.previous -and $PreviousDisposition -eq 'Rollback') {
    throw 'PreviousDisposition Rollback requires a legacy previous release.'
}

function Test-LegacyReleaseDrained {
    param([Parameter(Mandatory)][object]$Release)

    $instance = Get-ConfiguredInstance -Configuration $config -Name ([string]$Release.instance)
    $configDirectory = Split-Path -Parent $ConfigPath
    $userDataDir = if ($instance.userDataDir) {
        Resolve-ConfiguredPath -Value ([string]$instance.userDataDir) -BasePath $configDirectory
    } else { $null }
    $windowsCount = 0
    if ($userDataDir) {
        $windowsCount = @(Get-CimInstance Win32_Process -Filter "Name = 'Cursor.exe'" | Where-Object {
            $_.CommandLine -notmatch '--type=' -and $_.CommandLine -like "*$userDataDir*"
        }).Count
    }
    $remote = @(Get-WslCursorServerProcesses -Distro ([string]$instance.wslDistro) -User ([string]$instance.wslUser) -SubjectHome ([string]$instance.wslHome))
    return ($windowsCount -eq 0 -and $remote.Count -eq 0)
}

if ($ConfirmMigration -and $legacy.previous -and -not (Test-LegacyReleaseDrained -Release $legacy.previous)) {
    throw "Legacy previous '$($legacy.previous.name)' is still running; migration requires the subject profile and Remote WSL runtime to be closed."
}

$source = if ($PreviousDisposition -eq 'Rollback') { $legacy.previous } else { $legacy.active }
$sourceInstance = Get-ConfiguredInstance -Configuration $config -Name ([string]$source.instance)
$stable = Get-ConfiguredInstance -Configuration $config -Name 'stable'
$stableRoot = Get-ConfiguredReleasesRoot -Instance $stable -InstanceName 'stable'
if ([string]::IsNullOrWhiteSpace($stableRoot)) { throw 'Environment config.instances.stable.releasesRoot is required for migration.' }
$targetPath = Resolve-DefaultReleaseSeedPath -Instance $stable -Name ([string]$source.name) -InstanceName 'stable'
$sourceCommit = ("$(& wsl.exe -d $sourceInstance.wslDistro -u $sourceInstance.wslUser -- git -C $source.path rev-parse ([string]$source.gitRef))").Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) { throw 'Unable to resolve the migration source commit.' }

$stateHash = (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash
if ($ConfirmMigration) {
    if ($ExpectedGeneration -lt 0 -or [string]::IsNullOrWhiteSpace($ExpectedStateSha256)) {
        throw 'ConfirmMigration requires -ExpectedGeneration and -ExpectedStateSha256 from the approved dry-run.'
    }
    if ([int]$legacy.generation -ne $ExpectedGeneration) {
        throw "Migration generation changed: expected $ExpectedGeneration, actual $($legacy.generation)."
    }
    if ($stateHash -ne $ExpectedStateSha256) {
        throw "Migration state hash changed: expected $ExpectedStateSha256, actual $stateHash."
    }
}
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("foundation-migration-$([guid]::NewGuid().ToString('N'))")
$fixtureStatePath = Join-Path $tempRoot 'release-state.json'
$dryBackupRoot = Join-Path $tempRoot 'backups'
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

function Convert-LegacyHistory {
    $converted = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($legacy.transitionHistory)) {
        if ([string]$entry.action -eq 'initialize-next') {
            $converted.Add([ordered]@{
                action = 'seed'; at = [string]$entry.at; release = [string]$entry.release; commit = [string]$entry.commit
            }) | Out-Null
        } else {
            $copy = [ordered]@{ action = [string]$entry.action; at = [string]$entry.at }
            foreach ($field in @('from', 'to', 'commit')) {
                if ($entry.PSObject.Properties.Name -contains $field) { $copy[$field] = [string]$entry.$field }
            }
            if ($copy.action -eq 'rollback' -and -not $copy.Contains('commit')) { $copy['commit'] = $sourceCommit }
            $converted.Add($copy) | Out-Null
        }
    }
    return @($converted)
}

try {
    # The migration-only fixture lets the existing v3 backup implementation
    # inspect either legacy role without exposing v2 aliases to normal readers.
    $fixtureBaseline = if ([string]$legacy.active.instance -eq 'stable') { $legacy.active } elseif ($legacy.previous -and [string]$legacy.previous.instance -eq 'stable') { $legacy.previous } else { $null }
    if (-not $fixtureBaseline) { throw 'Migration requires one legacy release on the stable physical instance.' }
    $fixtureRun = if ([string]$source.instance -eq 'candidate') { $source } else { $null }
    $fixtureTransition = [ordered]@{ action = 'bootstrap'; at = [DateTimeOffset]::Now.ToString('o'); from = 'legacy-v2'; to = [string]$fixtureBaseline.name; commit = $sourceCommit }
    [ordered]@{
        schemaVersion = 3; generation = [int]$legacy.generation
        baseline = [ordered]@{ name = [string]$fixtureBaseline.name; instance = 'stable'; path = [string]$fixtureBaseline.path; gitRef = [string]$fixtureBaseline.gitRef }
        run = if ($fixtureRun) { [ordered]@{ name = [string]$fixtureRun.name; instance = 'candidate'; path = [string]$fixtureRun.path; gitRef = [string]$fixtureRun.gitRef } } else { $null }
        previousBaseline = $null; lastTransition = $fixtureTransition; transitionHistory = @($fixtureTransition)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureStatePath -Encoding utf8
    $role = if ([string]$source.instance -eq 'candidate') { 'run' } else { 'baseline' }
    $effectiveBackupRoot = if ($ConfirmMigration) { $configuredBackupRoot } else { $dryBackupRoot }
    $backup = (& (Join-Path $PSScriptRoot 'New-FoundationReleaseBackup.ps1') -Role $role -ExpectedGeneration ([int]$legacy.generation) -ExpectedCommit $sourceCommit -Execute -BackupRoot $effectiveBackupRoot -StatePath $fixtureStatePath -ConfigPath $ConfigPath) | ConvertFrom-Json
    $backupManifestSha256 = (Get-FileHash -LiteralPath ([string]$backup.manifestPath) -Algorithm SHA256).Hash
    $restore = (& (Join-Path $PSScriptRoot 'Test-FoundationRepositoryArchive.ps1') -ManifestPath ([string]$backup.manifestPath) -VerificationRoot (Join-Path $effectiveBackupRoot '.foundation-verify')) | ConvertFrom-Json
    if (-not $restore.restoreVerified -or [string]$restore.sourceCommit -ne $sourceCommit) { throw 'Migration source backup restore verification failed.' }
    $sameWorkspace = ([string]$source.instance -eq 'stable' -and [string]$source.path -eq $targetPath)
    if (-not $sameWorkspace) {
        & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- test '!' -e $targetPath
        if ($LASTEXITCODE -ne 0) { throw "Migration target already exists: $targetPath" }
    }

    $plan = [ordered]@{
        action = 'migrate-runtime-model'; execute = [bool]$ConfirmMigration
        configPath = $ConfigPath; statePath = $StatePath
        fromSchemaVersion = 2; toSchemaVersion = 3
        sourceStateSha256 = $stateHash; generation = [int]$legacy.generation
        nextGeneration = [int]$legacy.generation + 1
        previousDisposition = if ($legacy.previous) { $PreviousDisposition } else { 'None' }
        baseline = [ordered]@{ name = [string]$source.name; instance = 'stable'; path = $targetPath; gitRef = [string]$source.gitRef; commit = $sourceCommit }
        backupVerified = $true; restoreVerified = $true
        backupManifest = if ($ConfirmMigration) { [string]$backup.manifestPath } else { '<dry-run>' }
        backupManifestSha256 = $backupManifestSha256
        resultStateSha256 = $stateHash
    }
    if (-not $ConfirmMigration) {
        if ((Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash -ne $stateHash) { throw 'Migration dry-run changed the legacy state.' }
        $plan | ConvertTo-Json -Depth 8
        return
    }

    $stagePath = "$targetPath.migrate-$([guid]::NewGuid().ToString('N'))"
    $published = $false
    if (-not $sameWorkspace) {
        try {
            Restore-FoundationWorkspaceBackup -ManifestPath ([string]$backup.manifestPath) -RestorePath $stagePath -TargetDistro ([string]$stable.wslDistro) -TargetUser ([string]$stable.wslUser) | Out-Null
            & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- mv $stagePath $targetPath
            if ($LASTEXITCODE -ne 0) { throw "Failed to publish migrated baseline at '$targetPath'." }
            $published = $true
        } catch {
            & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- rm -rf $stagePath 2>$null | Out-Null
            throw
        }
    }

    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(Convert-LegacyHistory)) { $history.Add($entry) }
    $transition = [ordered]@{ action = 'migrate-runtime-model'; at = [DateTimeOffset]::Now.ToString('o'); from = [string]$legacy.active.name; to = [string]$source.name; commit = $sourceCommit }
    $history.Add($transition)
    $newState = [ordered]@{
        schemaVersion = 3; generation = [int]$legacy.generation + 1
        baseline = [ordered]@{ name = [string]$source.name; instance = 'stable'; path = $targetPath; gitRef = [string]$source.gitRef }
        run = $null; previousBaseline = $null; lastTransition = $transition; transitionHistory = $history.ToArray()
    }
    try {
        if ((Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash -ne $stateHash) {
            throw 'Migration source state changed before the atomic write.'
        }
        Write-ReleaseStateAtomic -StatePath $StatePath -State $newState
    } catch {
        if ($published) { & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- rm -rf $targetPath 2>$null | Out-Null }
        throw
    }
    $plan['generation'] = [int]$newState.generation
    $plan['resultStateSha256'] = (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash
    $plan | ConvertTo-Json -Depth 8
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
} finally {
    Exit-ReleaseStateLock -Lock $lock
}
