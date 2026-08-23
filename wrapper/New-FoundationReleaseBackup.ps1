[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('baseline', 'run')][string]$Role,
    [Parameter(Mandatory)][int]$ExpectedGeneration,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [switch]$Execute,
    [string]$BackupRoot,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$state = Read-ReleaseState -StatePath $resolvedStatePath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
Assert-ReleaseStateRuntimePlacement -State $state -Configuration $config
$BackupRoot = Resolve-BackupRoot -BackupRoot $BackupRoot -Configuration $config -ConfigurationPath $resolvedConfigPath -BasePath (Get-ConfigurationWorkspaceRoot)
Assert-ReleaseStateGeneration -State $state -ExpectedGeneration $ExpectedGeneration | Out-Null
$release = $state.$Role
if (-not $release) { throw "Release role '$Role' is empty." }

$instance = Get-ConfiguredInstance -Configuration $config -Name ([string]$release.instance)
$declared = @(Get-ConfiguredWorkspaceRepositories -Configuration $config)
$snapshot = Get-ReleaseWorkspaceSnapshot `
    -Instance $instance `
    -WorkspaceRoot ([string]$release.path) `
    -GitRef ([string]$release.gitRef) `
    -DeclaredRepositories $declared `
    -Channel $Role `
    -EnforceMembership:$true
if ($snapshot.errors.Count -gt 0) {
    throw "Workspace backup refused for ${Role}: $($snapshot.errors -join '; ')"
}
if (-not $snapshot.clean) {
    throw "The $Role workspace is dirty; backup refused. Dirty: $($snapshot.dirtyRepositories -join ', ')"
}
if ([string]$snapshot.commit -ne $ExpectedCommit -or [string]$snapshot.refCommit -ne $ExpectedCommit) {
    throw "Commit mismatch for ${Role}: expected $ExpectedCommit, stateRef=$($snapshot.refCommit), repository=$($snapshot.commit)."
}

$shortCommit = $ExpectedCommit.Substring(0, [Math]::Min(12, $ExpectedCommit.Length))
$baseName = "foundation-$Role-generation-$ExpectedGeneration-$shortCommit"
$backupRootFull = [System.IO.Path]::GetFullPath($BackupRoot)
$manifestPath = Join-Path $backupRootFull "$baseName.json"

$repositoryPlans = [System.Collections.Generic.List[object]]::new()
foreach ($repo in @($snapshot.repositories)) {
    if (-not $repo.present) { continue }
    $leaf = ConvertTo-WorkspaceBundleLeaf -RelativePath ([string]$repo.relativePath)
    $bundlePath = Join-Path $backupRootFull "$baseName.$leaf.bundle"
    $repositoryPlans.Add([ordered]@{
        relativePath = [string]$repo.relativePath
        role = [string]$repo.role
        path = [string]$repo.path
        branch = [string]$repo.branch
        commit = [string]$repo.head
        origin = [string]$repo.origin
        bundlePath = $bundlePath
    }) | Out-Null
}

$plan = [ordered]@{
    action = 'backup-foundation-workspace'
    execute = [bool]$Execute
    generation = $ExpectedGeneration
    role = $Role
    schemaVersion = 2
    source = [ordered]@{
        instance = [string]$release.instance
        distro = [string]$instance.wslDistro
        user = [string]$instance.wslUser
        path = [string]$release.path
        branch = [string](@($snapshot.repositories)[0].branch)
        commit = [string]$snapshot.commit
        origin = [string](@($snapshot.repositories)[0].origin)
    }
    repositories = @($repositoryPlans)
    bundlePath = [string]$repositoryPlans[0].bundlePath
    manifestPath = $manifestPath
    deletionSupported = $false
}
$bundlePaths = @($repositoryPlans | ForEach-Object { [string]$_.bundlePath })
$manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
$existingBundles = @($bundlePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if ($manifestExists -and $existingBundles.Count -notin @(0, $bundlePaths.Count)) {
    throw "Release backup set is incomplete for ${Role}: $manifestPath"
}
if (-not $manifestExists -and $existingBundles.Count -gt 0) {
    throw "Release backup set is incomplete for ${Role}: bundles without manifest under $backupRootFull"
}
$alreadyComplete = $manifestExists -and ($existingBundles.Count -eq $bundlePaths.Count)
$plan['alreadyExisted'] = $alreadyComplete
if (-not $Execute) { $plan | ConvertTo-Json -Depth 8; return }

if ($alreadyComplete) {
    $existing = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $existingCommit = if ($existing.source -and $existing.source.commit) {
        [string]$existing.source.commit
    } elseif ($existing.bundle) {
        $null
    } else {
        $null
    }
    if ($existingCommit -and $existingCommit -ne $ExpectedCommit) {
        throw "Existing backup commit mismatch for ${Role}: expected $ExpectedCommit, manifest=$existingCommit"
    }
    if ([int]$existing.generation -ne $ExpectedGeneration) {
        throw "Existing backup generation mismatch for ${Role}: expected $ExpectedGeneration, manifest=$($existing.generation)"
    }
    $existingRepos = [System.Collections.Generic.List[object]]::new()
    if ($existing.repositories) {
        foreach ($repo in @($existing.repositories)) { $existingRepos.Add($repo) | Out-Null }
    } elseif ($existing.bundle) {
        $existingRepos.Add([pscustomobject]@{
            relativePath = '.'
            commit = $existingCommit
            bundle = $existing.bundle
        }) | Out-Null
    } else {
        throw "Existing backup for ${Role} has no repositories or bundle."
    }
    if ($existingRepos.Count -ne $repositoryPlans.Count) {
        throw "Existing backup repository count mismatch for ${Role}: expected $($repositoryPlans.Count), manifest=$($existingRepos.Count)"
    }
    $existingByPath = @{}
    foreach ($repo in $existingRepos) {
        $rel = [string]$repo.relativePath
        if ($existingByPath.ContainsKey($rel)) {
            throw "Existing backup has duplicate repository ${rel} for ${Role}."
        }
        $existingByPath[$rel] = $repo
    }
    foreach ($planRepo in @($repositoryPlans)) {
        $rel = [string]$planRepo.relativePath
        if (-not $existingByPath.ContainsKey($rel)) {
            throw "Existing backup is missing repository ${rel} for ${Role}."
        }
        $existingRepo = $existingByPath[$rel]
        $existingRepoCommit = [string]$existingRepo.commit
        if ($existingRepoCommit -ne [string]$planRepo.commit) {
            throw "Existing backup commit mismatch for ${Role} ${rel}: expected $($planRepo.commit), manifest=$existingRepoCommit"
        }
        $actualHash = (Get-FileHash -LiteralPath ([string]$planRepo.bundlePath) -Algorithm SHA256).Hash
        if ($actualHash -ne [string]$existingRepo.bundle.sha256) {
            throw "Existing backup bundle hash mismatch for ${Role} ${rel}."
        }
    }
    $plan['verified'] = [bool]$existing.verified
    $plan['sha256'] = if ($existing.repositories) {
        [string]$existing.repositories[0].bundle.sha256
    } elseif ($existing.bundle) {
        [string]$existing.bundle.sha256
    } else {
        $null
    }
    if ($existing.repositories) { $plan['repositories'] = @($existing.repositories) }
    $plan | ConvertTo-Json -Depth 8
    return
}

New-Item -ItemType Directory -Force -Path $backupRootFull | Out-Null

$manifestRepos = [System.Collections.Generic.List[object]]::new()
foreach ($repoPlan in @($repositoryPlans)) {
    $bundlePath = [string]$repoPlan.bundlePath
    $bundleWsl = ConvertTo-WslPath -WindowsPath $bundlePath
    & wsl.exe -d $instance.wslDistro -u $instance.wslUser -- git -C $repoPlan.path bundle create $bundleWsl --all
    if ($LASTEXITCODE -ne 0) { throw "Release Git bundle creation failed for $($repoPlan.relativePath)." }
    & wsl.exe -d $instance.wslDistro -u $instance.wslUser -- git -C $repoPlan.path bundle verify $bundleWsl | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Release Git bundle verification failed for $($repoPlan.relativePath)." }
    $hash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
    $manifestRepos.Add([ordered]@{
        relativePath = [string]$repoPlan.relativePath
        role = [string]$repoPlan.role
        path = [string]$repoPlan.path
        branch = [string]$repoPlan.branch
        commit = [string]$repoPlan.commit
        origin = [string]$repoPlan.origin
        bundle = [ordered]@{
            path = $bundlePath
            sha256 = $hash
            length = (Get-Item -LiteralPath $bundlePath).Length
        }
    }) | Out-Null
}

$manifest = [ordered]@{
    schemaVersion = 2
    kind = 'routed-foundation-workspace-backup'
    createdAt = [DateTimeOffset]::Now.ToString('o')
    generation = $ExpectedGeneration
    role = $Role
    source = $plan.source
    repositories = @($manifestRepos)
    verified = $true
    deletionSupported = $false
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$plan['repositories'] = @($manifestRepos)
$plan['sha256'] = [string]$manifestRepos[0].bundle.sha256
$plan['verified'] = $true
$plan['alreadyExisted'] = $false
$plan | ConvertTo-Json -Depth 8
