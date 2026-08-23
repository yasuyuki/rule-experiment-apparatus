[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib\Result.ps1')

trap { Write-FoundationFailure -Command 'Get-FoundationVersion.ps1' -ErrorRecord $_; exit 1 }

$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$state = Read-ReleaseState -StatePath $resolvedStatePath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$declared = @(Get-ConfiguredWorkspaceRepositories -Configuration $config)

$releases = [ordered]@{}
foreach ($role in @('baseline', 'run')) {
    $release = $state.$role
    if ($null -eq $release) {
        $releases[$role] = $null
        continue
    }

    $instance = Get-ConfiguredInstance -Configuration $config -Name ([string]$release.instance)
    # Membership enforcement adds a workspace-wide scan for undeclared repos.
    # This command reports what the routed releases contain; the inventory owns
    # discovery of repositories nobody declared.
    $snapshot = Get-ReleaseWorkspaceSnapshot `
        -Instance $instance `
        -WorkspaceRoot ([string]$release.path) `
        -GitRef ([string]$release.gitRef) `
        -DeclaredRepositories $declared `
        -Channel $role

    $subject = Invoke-WslGitText `
        -Distro ([string]$instance.wslDistro) `
        -User ([string]$instance.wslUser) `
        -Path ([string]$snapshot.path) `
        -GitArguments @('show', '-s', '--format=%h %cI %s', 'HEAD')

    $releases[$role] = [ordered]@{
        name = [string]$release.name
        instance = [string]$release.instance
        distro = [string]$instance.wslDistro
        user = [string]$instance.wslUser
        path = [string]$snapshot.path
        gitRef = [string]$snapshot.gitRef
        commit = [string]$snapshot.commit
        refCommit = [string]$snapshot.refCommit
        refMatchesHead = [bool]$snapshot.refMatchesHead
        branch = [string]($snapshot.repositories | Where-Object { $_.relativePath -eq '.' } | Select-Object -First 1).branch
        subject = $subject
        clean = [bool]$snapshot.clean
        changes = @($snapshot.rootChanges)
        errors = @($snapshot.errors)
        workspace = [ordered]@{
            declaredRepositoryCount = $declared.Count
            missingDeclared = @($snapshot.missingDeclared)
            dirtyRepositories = @($snapshot.dirtyRepositories)
            repositories = @($snapshot.repositories)
        }
    }
}
$releases['previousBaseline'] = $state.previousBaseline

$result = [ordered]@{
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    generation = [int]$state.generation
    stateSchemaVersion = [int]$state.schemaVersion
    configurationSchemaVersion = [int]$config.schemaVersion
    releases = $releases
    lastTransition = $state.lastTransition
    transitionHistory = @($state.transitionHistory)
    checkedAt = [DateTimeOffset]::Now.ToString('o')
}

(ConvertTo-FoundationSuccess -Result $result) | ConvertTo-Json -Depth 8
exit 0
