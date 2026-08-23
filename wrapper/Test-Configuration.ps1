[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\LocalData.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', got '$Actual'." }
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

function Assert-ThrowsLike {
    param([scriptblock]$Action, [string]$Pattern, [string]$Label)
    try {
        & $Action | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Label expected error matching '$Pattern', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "$Label expected an error."
}

$examplePath = Join-Path $PSScriptRoot 'config\environment.example.json'
$statePath = Join-Path $PSScriptRoot 'config\release-state.example.json'
$schemaPaths = @(
    (Join-Path $PSScriptRoot 'schemas\environment.schema.json'),
    (Join-Path $PSScriptRoot 'schemas\release-state.schema.json')
)

foreach ($schemaPath in $schemaPaths) {
    $null = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json
}

$exampleText = Get-Content -Raw -LiteralPath $examplePath
$example = Read-EnvironmentConfig -ConfigPath $examplePath
Assert-equal $example.schemaVersion 2 'example.schemaVersion'
Assert-equal (Get-ConfiguredInstance -Configuration $example -Name stable).wslHome '/home/<stable-user>' 'example.stable.wslHome'
Assert-equal (Get-ConfiguredInstance -Configuration $example -Name candidate).userProfile '..\foundation-candidate\home' 'example.candidate.userProfile'
Assert-equal (Get-ConfiguredReleasesRoot -Instance (Get-ConfiguredInstance -Configuration $example -Name stable) -InstanceName stable) '/home/<stable-user>/releases' 'example.stable.releasesRoot'
Assert-equal (Resolve-DefaultReleaseSeedPath -Instance (Get-ConfiguredInstance -Configuration $example -Name stable) -Name 'release-7' -InstanceName stable) '/home/<stable-user>/releases/release-7' 'example default seed uses releasesRoot'
$exampleRepos = @(Get-ConfiguredWorkspaceRepositories -Configuration $example)
Assert-equal $exampleRepos.Count 3 'example.workspace.repositories.count'
Assert-equal $exampleRepos[0].relativePath 'example-app' 'example.workspace.repositories[0].relativePath'
if (-not $exampleText.Contains('<stable-user>')) { throw 'Example must keep placeholder identity values.' }

$state = Read-ReleaseState -StatePath $statePath
Assert-equal $state.schemaVersion 3 'release-state.schemaVersion'
if ($null -eq $state.baseline) { throw 'release-state.baseline must be present.' }
Assert-equal $state.baseline.instance 'stable' 'release-state.baseline.instance'
if ($null -ne $state.run) { throw 'release-state example run must be empty.' }
Assert-ReleaseStateRuntimePlacement -State $state -Configuration $example

$environmentVariableNames = @(
    'FOUNDATION_CONTROL_CONFIG',
    'FOUNDATION_CONTROL_STATE',
    'FOUNDATION_CONTROL_BACKUP_ROOT',
    'FOUNDATION_CONFIGURATION_TEST_ROOT'
)
$originalEnvironment = @{}
foreach ($name in $environmentVariableNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-configuration-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_CONFIG', $examplePath, 'Process')
    Assert-equal (Resolve-EnvironmentConfigPath) ([System.IO.Path]::GetFullPath($examplePath)) 'config environment variable resolution'

    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_STATE', $statePath, 'Process')
    Assert-equal (Resolve-ReleaseStatePath) ([System.IO.Path]::GetFullPath($statePath)) 'state environment variable resolution'

    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_BACKUP_ROOT', 'relative-backups', 'Process')
    Assert-equal (Resolve-BackupRoot -BasePath $temporaryRoot) ([System.IO.Path]::GetFullPath((Join-Path $temporaryRoot 'relative-backups'))) 'backup environment variable resolution'

    [Environment]::SetEnvironmentVariable('FOUNDATION_CONFIGURATION_TEST_ROOT', $temporaryRoot, 'Process')
    $expandedPath = Resolve-ConfiguredPath -Value '%FOUNDATION_CONFIGURATION_TEST_ROOT%\child'
    Assert-equal $expandedPath ([System.IO.Path]::GetFullPath((Join-Path $temporaryRoot 'child'))) 'environment variable expansion'
    Assert-equal (Resolve-ConfiguredPath -Value 'relative\state.json' -BasePath $temporaryRoot) ([System.IO.Path]::GetFullPath((Join-Path $temporaryRoot 'relative\state.json'))) 'relative path resolution'
    Assert-equal (Resolve-ConfiguredPath -Value '/home/example/Projects') '/home/example/Projects' 'WSL path preservation'

    $invalidPath = Join-Path $temporaryRoot 'unsupported.json'
    '{"schemaVersion":99}' | Set-Content -LiteralPath $invalidPath -Encoding utf8
    Assert-Throws { Read-EnvironmentConfig -ConfigPath $invalidPath } 'unsupported environment schema'

    # Schema 1 and schemaVersion-less legacy instances.json shapes are rejected.
    $schema1Path = Join-Path $temporaryRoot 'environment.schema1.json'
    $schema1 = Get-Content -Raw -LiteralPath $examplePath | ConvertFrom-Json
    $schema1.schemaVersion = 1
    if ($null -ne $schema1.PSObject.Properties['workspace']) {
        $schema1.PSObject.Properties.Remove('workspace')
    }
    ($schema1 | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $schema1Path -Encoding utf8
    Assert-Throws { Read-EnvironmentConfig -ConfigPath $schema1Path } 'schema1 environment rejected'

    $legacyInstancesPath = Join-Path $temporaryRoot 'instances.legacy.json'
    (@{
        cursorExe = 'C:\Cursor\Cursor.exe'
        instances = @{
            stable = @{ wslDistro = 'Ubuntu'; wslUser = 'u'; wslHome = '/home/u' }
            candidate = @{ wslDistro = 'Ubuntu-24.04'; wslUser = 'c'; wslHome = '/home/c' }
        }
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $legacyInstancesPath -Encoding utf8
    Assert-Throws { Read-EnvironmentConfig -ConfigPath $legacyInstancesPath } 'legacy instances.json shape rejected'

    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_CONFIG', $null, 'Process')
    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_STATE', $null, 'Process')
    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_BACKUP_ROOT', $null, 'Process')

    $localConfigPath = Get-LocalEnvironmentConfigPath
    $localConfigBackup = $null
    if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
        $localConfigBackup = Join-Path $temporaryRoot 'environment.local.json.bak'
        Move-Item -LiteralPath $localConfigPath -Destination $localConfigBackup
    }
    try {
        Assert-Throws { Resolve-EnvironmentConfigPath } 'config path required without env or local fallback'
        # There must be no in-repository state fallback: resolving to a stale
        # wrapper/release-state.json would route commands at retired releases.
        Assert-Throws { Resolve-ReleaseStatePath } 'state path required without env or local fallback'

        $localBackupRoot = Join-Path $temporaryRoot 'local-backups'
        (@{
            configPath = $examplePath
            statePath = $statePath
            backupRoot = $localBackupRoot
        } | ConvertTo-Json) | Set-Content -LiteralPath $localConfigPath -Encoding utf8
        Assert-equal (Resolve-EnvironmentConfigPath) ([System.IO.Path]::GetFullPath($examplePath)) 'config local file resolution'
        Assert-equal (Resolve-ReleaseStatePath) ([System.IO.Path]::GetFullPath($statePath)) 'state local file resolution'
        Assert-equal (Resolve-BackupRoot -BasePath $temporaryRoot) ([System.IO.Path]::GetFullPath($localBackupRoot)) 'backup local file resolution'
    } finally {
        if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
            Remove-Item -LiteralPath $localConfigPath -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($localConfigBackup)) {
            Move-Item -LiteralPath $localConfigBackup -Destination $localConfigPath
        }
    }

    function Write-Schema2Fixture {
        param([string]$Path, [object[]]$Repositories)
        $doc = [ordered]@{
            schemaVersion = 2
            cursor = @{ executable = 'C:\Cursor\Cursor.exe' }
            instances = @{
                stable = @{
                    wslDistro = 'Ubuntu'; wslUser = 'u'; wslHome = '/home/u'
                    projectsRoot = '/home/u/Projects'
                    userProfile = $null; userDataDir = $null; extensionsDir = $null
                }
                candidate = @{
                    wslDistro = 'Ubuntu-24.04'; wslUser = 'c'; wslHome = '/home/c'
                    projectsRoot = '/home/c/Projects'
                    userProfile = 'candidate\home'; userDataDir = 'candidate\user-data'; extensionsDir = 'candidate\extensions'
                }
            }
            controlPlane = @{ gitInstance = 'candidate' }
            repositoryDiscovery = @{ namePatterns = @('foundation*'); origins = @() }
            storage = @{ backupRoot = 'storage\backups'; verificationRoot = 'storage\verify'; localDataRoot = 'C:\bak\local-data' }
            workspace = @{ repositories = @($Repositories) }
            projects = @{}
        }
        ($doc | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding utf8
    }

    $okPath = Join-Path $temporaryRoot 'environment.schema2.ok.json'
    Write-Schema2Fixture -Path $okPath -Repositories @(
        @{ relativePath = 'example-app'; origin = 'https://example.invalid/example-app.git' }
    )
    $ok = Read-EnvironmentConfig -ConfigPath $okPath
    Assert-equal (@(Get-ConfiguredWorkspaceRepositories -Configuration $ok))[0].relativePath 'example-app' 'schema2.ok.relativePath'
    Assert-EnvironmentConfigSupportsWorkspaceMutation -Configuration $ok | Out-Null
    Assert-equal (Get-ConfiguredReleasesRoot -Instance (Get-ConfiguredInstance -Configuration $ok -Name stable) -InstanceName stable) $null 'schema2.ok.releasesRoot optional absent'
    Assert-equal (Resolve-DefaultReleaseSeedPath -Instance (Get-ConfiguredInstance -Configuration $ok -Name stable) -Name 'release-8' -InstanceName stable) '/home/u/Projects/release-8' 'schema2.ok default seed falls back to Projects'
    $fixtureLocalConfigBackup = $null
    if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
        $fixtureLocalConfigBackup = Join-Path $temporaryRoot 'environment.local.fixture.bak'
        Move-Item -LiteralPath $localConfigPath -Destination $fixtureLocalConfigBackup
    }
    try {
        Assert-equal (Resolve-BackupRoot -Configuration $ok -ConfigurationPath $okPath -BasePath (Join-Path $temporaryRoot 'wrong-cwd')) ([System.IO.Path]::GetFullPath((Join-Path $temporaryRoot 'storage\backups'))) 'configured backup root uses config directory'

        $parentRelativePath = Join-Path $temporaryRoot 'nested\environment.parent-relative.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $parentRelativePath) | Out-Null
        Write-Schema2Fixture -Path $parentRelativePath -Repositories @()
        $parentRelative = Get-Content -Raw -LiteralPath $parentRelativePath | ConvertFrom-Json
        $parentRelative.storage.backupRoot = '..\backups'
        ($parentRelative | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $parentRelativePath -Encoding utf8
        $parentRelative = Read-EnvironmentConfig -ConfigPath $parentRelativePath
        Assert-equal (Resolve-BackupRoot -Configuration $parentRelative -ConfigurationPath $parentRelativePath) ([System.IO.Path]::GetFullPath((Join-Path $temporaryRoot 'backups'))) 'config-relative parent path normalization'
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($fixtureLocalConfigBackup)) {
            Move-Item -LiteralPath $fixtureLocalConfigBackup -Destination $localConfigPath
        }
    }

    $userProfilePath = Join-Path $temporaryRoot 'environment.userprofile.json'
    Write-Schema2Fixture -Path $userProfilePath -Repositories @()
    $userProfileFixture = Get-Content -Raw -LiteralPath $userProfilePath | ConvertFrom-Json
    $userProfileFixture.instances.candidate.userProfile = '%USERPROFILE%\work\candidate'
    ($userProfileFixture | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $userProfilePath -Encoding utf8
    Assert-Throws { Read-EnvironmentConfig -ConfigPath $userProfilePath } 'isolation path rejects USERPROFILE'

    $withReleasesPath = Join-Path $temporaryRoot 'environment.schema2.releasesRoot.json'
    Write-Schema2Fixture -Path $withReleasesPath -Repositories @(
        @{ relativePath = 'example-app'; origin = 'https://example.invalid/example-app.git' }
    )
    $withReleases = Get-Content -Raw -LiteralPath $withReleasesPath | ConvertFrom-Json
    $withReleases.instances.stable | Add-Member -NotePropertyName releasesRoot -NotePropertyValue '/home/u/releases' -Force
    $withReleases.instances.candidate | Add-Member -NotePropertyName releasesRoot -NotePropertyValue '/home/c/releases' -Force
    ($withReleases | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $withReleasesPath -Encoding utf8
    $loadedReleases = Read-EnvironmentConfig -ConfigPath $withReleasesPath
    Assert-equal (Resolve-DefaultReleaseSeedPath -Instance (Get-ConfiguredInstance -Configuration $loadedReleases -Name candidate) -Name 'release-9' -InstanceName candidate) '/home/c/releases/release-9' 'releasesRoot default seed path'

    $badReleasesPath = Join-Path $temporaryRoot 'environment.bad-releasesRoot.json'
    Write-Schema2Fixture -Path $badReleasesPath -Repositories @(
        @{ relativePath = 'example-app'; origin = 'https://example.invalid/example-app.git' }
    )
    $badReleases = Get-Content -Raw -LiteralPath $badReleasesPath | ConvertFrom-Json
    $badReleases.instances.stable | Add-Member -NotePropertyName releasesRoot -NotePropertyValue 'relative/releases' -Force
    ($badReleases | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $badReleasesPath -Encoding utf8
    Assert-Throws { Read-EnvironmentConfig -ConfigPath $badReleasesPath } 'schema2 rejects relative releasesRoot'

    $scanState = [ordered]@{
        baseline = [ordered]@{ instance = 'stable'; path = '/home/u/Projects/release-8'; name = 'release-8' }
        run = [ordered]@{ instance = 'candidate'; path = '/home/c/releases/release-9'; name = 'release-9' }
        previousBaseline = $null
    }
    $scanRoots = @(Get-InstanceInventoryScanRoots -Instance (Get-ConfiguredInstance -Configuration $loadedReleases -Name candidate) -InstanceName candidate -State $scanState)
    if ($scanRoots -notcontains '/home/c/Projects') { throw 'candidate inventory scan roots missing projectsRoot' }
    if ($scanRoots -notcontains '/home/c/releases') { throw 'candidate inventory scan roots missing releasesRoot' }
    if ($scanRoots -notcontains '/home/c/releases/release-9') { throw 'candidate inventory scan roots missing state release path' }
    if ($scanRoots -contains '/home/u/Projects/release-8') { throw 'candidate scan roots must ignore other-instance state paths' }

    foreach ($case in @(
            @{ label = 'absolute path'; repos = @(@{ relativePath = '/etc/passwd'; origin = 'https://example.invalid/a.git' }) },
            @{ label = 'parent escape'; repos = @(@{ relativePath = '../outside'; origin = 'https://example.invalid/a.git' }) },
            @{ label = 'dot segment'; repos = @(@{ relativePath = 'foo/../bar'; origin = 'https://example.invalid/a.git' }) },
            @{ label = 'empty origin'; repos = @(@{ relativePath = 'example-app'; origin = '' }) },
            @{ label = 'duplicate path'; repos = @(
                    @{ relativePath = 'example-app'; origin = 'https://example.invalid/a.git' },
                    @{ relativePath = 'example-app'; origin = 'https://example.invalid/b.git' }
                ) },
            @{ label = 'root dot'; repos = @(@{ relativePath = '.'; origin = 'https://example.invalid/a.git' }) }
        )) {
        $badPath = Join-Path $temporaryRoot ("environment.bad-$($case.label -replace '[^a-z0-9]+','-').json")
        Write-Schema2Fixture -Path $badPath -Repositories $case.repos
        Assert-Throws { Read-EnvironmentConfig -ConfigPath $badPath } "schema2 rejects $($case.label)"
    }

    foreach ($case in @(
            @{ label = 'baseline on candidate'; role = 'baseline'; field = 'instance'; value = 'candidate' },
            @{ label = 'run on stable'; role = 'run'; field = 'instance'; value = 'stable' },
            @{ label = 'relative path'; role = 'baseline'; field = 'path'; value = 'releases/foundation' },
            @{ label = 'windows path'; role = 'run'; field = 'path'; value = 'C:\releases\foundation' },
            @{ label = 'empty gitRef'; role = 'baseline'; field = 'gitRef'; value = '' }
        )) {
        $badStatePath = Join-Path $temporaryRoot ("release-state.bad-$($case.label -replace '[^a-z0-9]+','-').json")
        $badState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        if ($case.role -eq 'run') {
            $badState.run = [pscustomobject]@{
                name = 'fixture-run'; instance = 'candidate'; path = '/home/c/releases/fixture-run'; gitRef = 'run/fixture'
            }
        }
        $badState."$($case.role)"."$($case.field)" = $case.value
        ($badState | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $badStatePath -Encoding utf8
        Assert-Throws { Read-ReleaseState -StatePath $badStatePath } "release state rejects $($case.label)"
    }

    foreach ($case in @(
            @{ label = 'manifest path'; field = 'backupManifest'; value = 'C:\backups\baseline.json' },
            @{ label = 'manifest parent'; field = 'backupManifest'; value = '..\baseline.json' },
            @{ label = 'bad sha'; field = 'backupSha256'; value = 'not-a-sha' }
        )) {
        $badStatePath = Join-Path $temporaryRoot ("release-state.previous-$($case.label -replace '[^a-z0-9]+','-').json")
        $badState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $badState.previousBaseline = [pscustomobject]@{
            name = 'old-baseline'
            commit = 'abc123'
            gitRef = 'main'
            backupManifest = 'foundation-baseline.json'
            backupSha256 = ('a' * 64)
        }
        $badState.previousBaseline."$($case.field)" = $case.value
        ($badState | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $badStatePath -Encoding utf8
        Assert-Throws { Read-ReleaseState -StatePath $badStatePath } "previousBaseline rejects $($case.label)"
    }

    $legacyStatePath = Join-Path $temporaryRoot 'release-state.schema2.json'
    $legacyState = [ordered]@{
        schemaVersion = 2
        generation = 7
        active = [ordered]@{ name = 'legacy-active'; instance = 'stable'; path = '/home/u/releases/legacy-active'; gitRef = 'main' }
        candidate = $null
        previous = [ordered]@{ name = 'legacy-previous'; instance = 'candidate'; path = '/home/c/releases/legacy-previous'; gitRef = 'main' }
        lastTransition = [ordered]@{ action = 'promote'; at = '2026-01-01T00:00:00+09:00'; from = 'legacy-previous'; to = 'legacy-active'; commit = 'abc123' }
        transitionHistory = @([ordered]@{ action = 'promote'; at = '2026-01-01T00:00:00+09:00'; from = 'legacy-previous'; to = 'legacy-active'; commit = 'abc123' })
    }
    ($legacyState | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $legacyStatePath -Encoding utf8
    Assert-ThrowsLike { Read-ReleaseState -StatePath $legacyStatePath } 'migrate-runtime-model' 'normal reader rejects legacy v2 with migration guidance'
    $loadedLegacy = Read-LegacyReleaseStateV2ForMigration -StatePath $legacyStatePath
    Assert-equal $loadedLegacy.active.name 'legacy-active' 'migration reader preserves legacy active'
    Assert-Throws { Read-LegacyReleaseStateV2ForMigration -StatePath $statePath } 'migration reader rejects v3'

    # transitionHistory is an audit log with a different payload per action;
    # the reader must enforce exactly what the schema documents.
    foreach ($case in @(
            @{ label = 'unknown action'; transition = [ordered]@{ action = 'legacy-action'; at = '2026-01-01T00:00:00+09:00'; from = 'a'; to = 'b'; commit = 'c' } },
            @{ label = 'promote without commit'; transition = [ordered]@{ action = 'promote'; at = '2026-01-01T00:00:00+09:00'; from = 'a'; to = 'b' } },
            @{ label = 'rollback without commit'; transition = [ordered]@{ action = 'rollback'; at = '2026-01-01T00:00:00+09:00'; from = 'b'; to = 'a' } },
            @{ label = 'seed without release'; transition = [ordered]@{ action = 'seed'; at = '2026-01-01T00:00:00+09:00'; commit = 'c' } },
            @{ label = 'discard without release'; transition = [ordered]@{ action = 'discard'; at = '2026-01-01T00:00:00+09:00'; commit = 'c' } },
            @{ label = 'discard without commit'; transition = [ordered]@{ action = 'discard'; at = '2026-01-01T00:00:00+09:00'; release = 'n' } }
        )) {
        $badStatePath = Join-Path $temporaryRoot ("release-state.transition-$($case.label -replace '[^a-z0-9]+','-').json")
        $badState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $badState.lastTransition = $case.transition
        $badState.transitionHistory = @($case.transition)
        ($badState | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $badStatePath -Encoding utf8
        Assert-Throws { Read-ReleaseState -StatePath $badStatePath } "release state rejects $($case.label)"
    }

    # rollback pins the restored commit; seed names the run and omits from/to.
    $rollbackStatePath = Join-Path $temporaryRoot 'release-state.rollback.json'
    $rollbackState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $rollbackState.lastTransition = [ordered]@{ action = 'rollback'; at = '2026-01-01T00:00:00+09:00'; from = 'b'; to = 'a'; commit = 'c' }
    $rollbackState.transitionHistory = @(
        [ordered]@{ action = 'seed'; at = '2026-01-01T00:00:00+09:00'; release = 'n'; commit = 'c' },
        $rollbackState.lastTransition
    )
    ($rollbackState | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $rollbackStatePath -Encoding utf8
    $null = Read-ReleaseState -StatePath $rollbackStatePath

    $discardStatePath = Join-Path $temporaryRoot 'release-state.discard.json'
    $discardState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $discardState.lastTransition = [ordered]@{ action = 'discard'; at = '2026-01-01T00:00:00+09:00'; release = 'n'; commit = 'c' }
    $discardState.transitionHistory = @(
        [ordered]@{ action = 'seed'; at = '2026-01-01T00:00:00+09:00'; release = 'n'; commit = 'c' },
        $discardState.lastTransition
    )
    ($discardState | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $discardStatePath -Encoding utf8
    $null = Read-ReleaseState -StatePath $discardStatePath

    $fixtureStatePath = Join-Path $temporaryRoot 'release-state.json'
    Copy-Item -LiteralPath $statePath -Destination $fixtureStatePath
    $fixtureState = Read-ReleaseState -StatePath $fixtureStatePath
    Assert-equal (Assert-ReleaseStateGeneration -State $fixtureState) ([int]$state.generation) 'state generation helper'
    Assert-Throws {
        Assert-ReleaseStateGeneration -State $fixtureState -ExpectedGeneration ([int]$state.generation + 1)
    } 'state generation mismatch helper'

    $heldLock = Enter-ReleaseStateLock -StatePath $fixtureStatePath
    try {
        if (-not (Test-Path -LiteralPath "$fixtureStatePath.lock" -PathType Leaf)) {
            throw 'state lock file was not created.'
        }
        Assert-Throws { Enter-ReleaseStateLock -StatePath $fixtureStatePath } 'state lock contention helper'
    } finally {
        Exit-ReleaseStateLock -Lock $heldLock
    }
    if (Test-Path -LiteralPath "$fixtureStatePath.lock") { throw 'state lock file was not removed.' }

    Set-Content -LiteralPath "$fixtureStatePath.lock" -Value '' -Encoding utf8
    $staleLock = Enter-ReleaseStateLock -StatePath $fixtureStatePath
    try {
        Assert-Throws { Enter-ReleaseStateLock -StatePath $fixtureStatePath } 'stale lock re-enter contention helper'
    } finally {
        Exit-ReleaseStateLock -Lock $staleLock
    }
    if (Test-Path -LiteralPath "$fixtureStatePath.lock") { throw 'stale lock file was not removed after exit.' }

    $fixtureState.generation = [int]$fixtureState.generation + 1
    Write-ReleaseStateAtomic -StatePath $fixtureStatePath -State $fixtureState
    $rewrittenState = Read-ReleaseState -StatePath $fixtureStatePath
    Assert-equal ([int]$rewrittenState.generation) ([int]$state.generation + 1) 'atomic state replace helper'
    if (@(Get-ChildItem -LiteralPath $temporaryRoot -Filter '*.tmp' -File).Count -ne 0) {
        throw 'atomic state replace left a temporary file.'
    }
} finally {
    foreach ($name in $environmentVariableNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
    }
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

$parseArgs = @{ StoreRoot = '/tmp/store'; ScriptPath = '/tmp/store/local-data.sh'; WorkspaceRoot = '/tmp/ws' }
$ok = ConvertFrom-LocalDataStatusOutput @parseArgs -Output @('-- /tmp/ws: ok=42 diff=0 missing=0') -ExitCode 0
Assert-Equal $ok.state 'ok' 'local-data parse ok.state'
Assert-Equal $ok.problems.Count 0 'local-data parse ok.problems'
$absent = ConvertFrom-LocalDataStatusOutput @parseArgs -Output @(
    'ABSENT  example-player/HANDOFF.md',
    '-- /tmp/ws: ok=41 diff=0 missing=0'
) -ExitCode 1
Assert-Equal $absent.state 'drift' 'local-data parse ABSENT is drift (not missing=)'
Assert-Equal $absent.problems[0] 'ABSENT example-player/HANDOFF.md' 'local-data parse collapses ABSENT padding'
$noSummary = ConvertFrom-LocalDataStatusOutput @parseArgs -Output @('MANIFEST がない') -ExitCode 1
Assert-Equal $noSummary.state 'unavailable' 'local-data parse no summary is unavailable'
$empty = ConvertFrom-LocalDataStatusOutput @parseArgs -Output @() -ExitCode 1
Assert-Equal $empty.state 'unavailable' 'local-data parse empty output is unavailable'

Write-Output 'PASS: configuration schemas, path resolution, workspace membership, and state helpers'
