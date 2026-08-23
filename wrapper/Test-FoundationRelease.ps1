[CmdletBinding()]
param(
    [ValidateSet('baseline', 'run')]
    [string]$Role = 'baseline',
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$rawState = Get-Content -Raw -LiteralPath $resolvedStatePath | ConvertFrom-Json
if ([int]$rawState.schemaVersion -eq 2 -and -not $PSBoundParameters.ContainsKey('Role')) {
    $beforeHash = (Get-FileHash -LiteralPath $resolvedStatePath -Algorithm SHA256).Hash
    $legacy = Read-LegacyReleaseStateV2ForMigration -StatePath $resolvedStatePath
    [ordered]@{
        accepted = $false
        migrationRequired = $true
        candidateEmpty = ($null -eq $legacy.candidate)
        liveStateUnchanged = ((Get-FileHash -LiteralPath $resolvedStatePath -Algorithm SHA256).Hash -eq $beforeHash)
        next = '.\Invoke-FoundationRelease.ps1 -Stage migrate-runtime-model -PreviousDisposition <Rollback|Discard>'
    } | ConvertTo-Json -Depth 4
    return
}
$state = Read-ReleaseState -StatePath $resolvedStatePath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
Assert-ReleaseStateRuntimePlacement -State $state -Configuration $config
$release = $state.$Role
if (-not $release) { throw "Release role '$Role' is empty." }
$instance = Get-ConfiguredInstance -Configuration $config -Name ([string]$release.instance)

$distro = [string]$instance.wslDistro
$user = [string]$instance.wslUser
$path = [string]$release.path
$ref = [string]$release.gitRef

$actualUser = (& wsl.exe -d $distro -- id -un).Trim()
if ($actualUser -ne $user) { throw "Default user mismatch: ${distro} expected $user, got $actualUser" }

$declared = @(Get-ConfiguredWorkspaceRepositories -Configuration $config)
$snapshot = Get-ReleaseWorkspaceSnapshot `
    -Instance $instance `
    -WorkspaceRoot $path `
    -GitRef $ref `
    -DeclaredRepositories $declared `
    -Channel $Role `
    -EnforceMembership:$true

if ($snapshot.errors.Count -gt 0) {
    throw "Workspace acceptance failed for ${Role}: $($snapshot.errors -join '; ')"
}
if ($Role -eq 'run' -and -not $snapshot.clean) {
    throw "Run workspace is dirty: $($snapshot.dirtyRepositories -join ', ')"
}
if ($Role -eq 'run' -and @($snapshot.undeclaredRepositories).Count -gt 0) {
    throw "Run workspace has undeclared repositories: $(@($snapshot.undeclaredRepositories) -join ', ')"
}

$required = @('.cursor/rules', '.cursor/agents', '.claude/rules', '.claude/agents', 'README.md', 'FOUNDATION-RELEASE.json')
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $required) {
    & wsl.exe -d $distro -u $user -- test -e "$path/$relative"
    if ($LASTEXITCODE -ne 0) { $missing.Add($relative) }
}
if ($missing.Count -gt 0) { throw "Missing foundation paths: $($missing -join ', ')" }

$detached = [System.Collections.Generic.List[string]]::new()
foreach ($repo in @($snapshot.repositories)) {
    if (-not $repo.present) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$repo.branch)) {
        $detached.Add([string]$repo.relativePath)
    }
}
$acceptanceWarnings = [System.Collections.Generic.List[string]]::new()
foreach ($warning in @($snapshot.warnings)) { $acceptanceWarnings.Add([string]$warning) }
if ($detached.Count -gt 0) {
    $detachedMessage = "Workspace has detached HEAD (named branch required): $($detached -join ', ')"
    if ($Role -eq 'run') {
        throw $detachedMessage
    }
    $acceptanceWarnings.Add($detachedMessage)
}

$manifestRaw = ("$(& wsl.exe -d $distro -u $user -- cat "$path/FOUNDATION-RELEASE.json")").Trim()
if ([string]::IsNullOrWhiteSpace($manifestRaw)) {
    throw "FOUNDATION-RELEASE.json is empty at $path"
}
$manifest = $manifestRaw | ConvertFrom-Json
$manifestRelease = [string]$manifest.release
if ([string]::IsNullOrWhiteSpace($manifestRelease)) {
    $missingRelease = "FOUNDATION-RELEASE.json missing 'release' field at $path"
    throw $missingRelease
} elseif ($manifestRelease -ne [string]$release.name) {
    $mismatch = "FOUNDATION-RELEASE.json release='$manifestRelease' does not match role name '$($release.name)'"
    throw $mismatch
}

[ordered]@{
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    accepted = $true
    role = $Role
    release = [string]$release.name
    instance = [string]$release.instance
    distro = $distro
    user = $user
    path = $path
    gitRef = $ref
    commit = [string]$snapshot.commit
    clean = [bool]$snapshot.clean
    dirtyRepositories = @($snapshot.dirtyRepositories)
    warnings = @($acceptanceWarnings)
    foundationRelease = $manifestRelease
    workspace = [ordered]@{
        schemaVersion = [int]$config.schemaVersion
        declaredRepositoryCount = $declared.Count
        missingDeclared = @($snapshot.missingDeclared)
        undeclaredRepositories = @($snapshot.undeclaredRepositories)
        repositories = @($snapshot.repositories)
    }
    checkedAt = [DateTimeOffset]::Now.ToString('o')
} | ConvertTo-Json -Depth 8
