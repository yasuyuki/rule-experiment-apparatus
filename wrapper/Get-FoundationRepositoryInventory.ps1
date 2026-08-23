[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib\Result.ps1')

trap { Write-FoundationFailure -Command 'Get-FoundationRepositoryInventory.ps1' -ErrorRecord $_; exit 1 }

$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$state = Read-ReleaseState -StatePath $resolvedStatePath
$discovery = Get-JsonProperty -Object $config -Name 'repositoryDiscovery' -DocumentName 'Environment config'
$namePatterns = [string[]]@(Get-JsonProperty -Object $discovery -Name 'namePatterns' -DocumentName 'Environment config.repositoryDiscovery')
$origins = [string[]]@(Get-JsonProperty -Object $discovery -Name 'origins' -DocumentName 'Environment config.repositoryDiscovery')
$declaredRepositories = @(Get-ConfiguredWorkspaceRepositories -Configuration $config)

$releaseByExactPath = @{}
$releaseByInstancePathPrefix = @{ stable = @(); candidate = @() }
foreach ($stateRole in @('baseline', 'run')) {
    $release = $state.$stateRole
    if (-not $release) { continue }
    $instanceName = [string]$release.instance
    $path = ([string]$release.path).TrimEnd('/')
    $releaseByExactPath["$instanceName|$path"] = $stateRole
    $releaseByInstancePathPrefix[$instanceName] += [ordered]@{ channel = $stateRole; path = $path; name = [string]$release.name }
}

$items = [System.Collections.Generic.List[object]]::new()
foreach ($instanceName in @('stable', 'candidate')) {
    $instance = Get-ConfiguredInstance -Configuration $config -Name $instanceName
    $projectsRoot = ([string]$instance.projectsRoot).TrimEnd('/')
    $releasesRoot = Get-ConfiguredReleasesRoot -Instance $instance -InstanceName $instanceName
    $scanRoots = @(Get-InstanceInventoryScanRoots -Instance $instance -InstanceName $instanceName -State $state)
    $gitDirectories = [System.Collections.Generic.List[string]]::new()
    foreach ($scanRoot in $scanRoots) {
        $scanScript = "if [ ! -e '$scanRoot' ]; then echo '__MISSING__'; exit 0; fi; find '$scanRoot' -maxdepth 2 -type d -name .git -print"
        $findOutput = @(& wsl.exe -d $instance.wslDistro -u $instance.wslUser -- bash -lc "$scanScript")
        if ($LASTEXITCODE -ne 0) {
            throw "Could not inventory ${instanceName}:${scanRoot}"
        }
        if (@($findOutput) -contains '__MISSING__') {
            if ($scanRoot -eq $projectsRoot) {
                throw "Could not inventory ${instanceName}:${scanRoot} (projectsRoot missing)"
            }
            continue
        }
        foreach ($gitDirectory in @($findOutput | Where-Object { $_ -is [string] -and $_ -match '/\.git$' })) {
            $gitDirectories.Add(([string]$gitDirectory).Trim()) | Out-Null
        }
    }

    $repositoryPaths = @($gitDirectories |
        Select-Object -Unique |
        ForEach-Object { $_.Substring(0, $_.Length - '/.git'.Length).TrimEnd('/') } |
        Select-Object -Unique)
    $inspections = Invoke-WslRepositoryBatch `
        -Distro ([string]$instance.wslDistro) `
        -User ([string]$instance.wslUser) `
        -Paths $repositoryPaths `
        -IncludeRemoteContains

    foreach ($path in $repositoryPaths) {
        $info = $inspections[$path]
        if (-not $info.present) { throw "Could not read HEAD for $($instance.wslDistro):$path" }
        $leaf = $path.Substring($path.LastIndexOf('/') + 1)
        $discoveryReasons = @(Get-RepositoryDiscoveryReasons -Leaf $leaf -Origin ([string]$info.origin) -NamePatterns $namePatterns -Origins $origins)
        $stateRole = Resolve-ReleaseChannelForPath `
            -ReleaseByExactPath $releaseByExactPath `
            -ReleaseByInstancePathPrefix $releaseByInstancePathPrefix `
            -InstanceName $instanceName `
            -Path $path
        $isProjectsRoot = ($path -eq $projectsRoot)
        $role = if ($isProjectsRoot) { 'legacy-source' } elseif ($releaseByExactPath.ContainsKey("$instanceName|$path")) { 'release-root' } else { 'project' }

        $relativeFromProjects = if ($path.StartsWith("$projectsRoot/")) { $path.Substring($projectsRoot.Length + 1) } else { $null }
        $isDirectChildOfProjectsRoot = ($null -ne $relativeFromProjects -and -not $relativeFromProjects.Contains('/'))
        $relativeFromReleases = if (($null -ne $releasesRoot) -and $path.StartsWith("$releasesRoot/")) { $path.Substring($releasesRoot.Length + 1) } else { $null }
        $isDirectChildOfReleasesRoot = ($null -ne $relativeFromReleases -and -not $relativeFromReleases.Contains('/'))
        $include = ($discoveryReasons.Count -gt 0) `
            -or ($stateRole -ne 'retired-unreferenced') `
            -or $isProjectsRoot `
            -or $isDirectChildOfProjectsRoot `
            -or $isDirectChildOfReleasesRoot
        if (-not $include) { continue }

        $relativePath = if ($path.StartsWith("$projectsRoot/")) {
            $path.Substring($projectsRoot.Length + 1)
        } elseif ($path -eq $projectsRoot) {
            '.'
        } elseif (($null -ne $releasesRoot) -and $path.StartsWith("$releasesRoot/")) {
            $path.Substring($releasesRoot.Length + 1)
        } elseif (($null -ne $releasesRoot) -and ($path -eq $releasesRoot)) {
            '.'
        } else {
            $null
        }

        $items.Add([ordered]@{
            instance = $instanceName
            distro = [string]$instance.wslDistro
            user = [string]$instance.wslUser
            path = $path
            relativePath = $relativePath
            role = $role
            stateRole = $stateRole
            branch = [string]$info.branch
            commit = [string]$info.head
            dirty = [bool]$info.dirty
            origin = [string]$info.origin
            discoveryReasons = $discoveryReasons
            archiveEligible = ($stateRole -eq 'retired-unreferenced' -and -not [bool]$info.dirty)
            originContainsHead = [bool]$info.originContainsHead
            requiresBundle = ($stateRole -eq 'retired-unreferenced' -and -not [bool]$info.originContainsHead)
        })
    }
}

# Routed workspaces are reported through the same snapshot that acceptance
# uses, so the inventory can never disagree with Test-FoundationRelease about
# what a release contains.
$workspaces = [System.Collections.Generic.List[object]]::new()
foreach ($stateRole in @('baseline', 'run')) {
    $release = $state.$stateRole
    if (-not $release) { continue }

    $instanceName = [string]$release.instance
    $instance = Get-ConfiguredInstance -Configuration $config -Name $instanceName
    $snapshot = Get-ReleaseWorkspaceSnapshot `
        -Instance $instance `
        -WorkspaceRoot ([string]$release.path) `
        -GitRef ([string]$release.gitRef) `
        -DeclaredRepositories $declaredRepositories `
        -Channel $stateRole `
        -EnforceMembership

    $workspaces.Add([ordered]@{
        role = $stateRole
        name = [string]$release.name
        instance = $instanceName
        rootPath = [string]$snapshot.path
        schemaVersion = [int]$config.schemaVersion
        declaredRepositoryCount = $declaredRepositories.Count
        repositories = @($snapshot.repositories)
        missingDeclared = @($snapshot.missingDeclared)
        undeclaredRepositories = @($snapshot.undeclaredRepositories)
        pathEscapes = @($snapshot.repositories | Where-Object { $_.pathEscapesWorkspace })
        errors = @($snapshot.errors)
        warnings = @($snapshot.warnings)
    }) | Out-Null
}

$result = [ordered]@{
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    generation = [int]$state.generation
    stateSchemaVersion = [int]$state.schemaVersion
    configurationSchemaVersion = [int]$config.schemaVersion
    policy = [ordered]@{
        automaticDeletion = $false
        archiveRequires = @('retired-unreferenced', 'clean worktree', 'explicit operator approval')
        deletionPolicy = 'never automatic; require separately verified archive or remote reachability'
        deletionDecidedBy = 'Get-FoundationRepositoryDeletionPlan.ps1'
        workspaceMembership = 'environment.workspace.repositories'
    }
    workspaces = @($workspaces)
    repositories = @($items | Sort-Object instance, path)
}

(ConvertTo-FoundationSuccess -Result $result) | ConvertTo-Json -Depth 8
exit 0
