[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$ConfigPath,
    [string]$ReviewRoot,
    [ValidateSet('json', 'text')]
    [string]$Format = 'json',
    # Runtime-only callers (the drain guard) skip the per-channel Git
    # inspection; blockers then cover process state only.
    [switch]$SkipWorkspace
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\CursorHandoff.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib\LocalData.ps1')
. (Join-Path $PSScriptRoot 'lib\Presentation.ps1')
. (Join-Path $PSScriptRoot 'lib\Result.ps1')

trap { Write-FoundationFailure -Command 'Get-FoundationStatus.ps1' -ErrorRecord $_; exit 1 }

$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$state = Read-ReleaseState -StatePath $resolvedStatePath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
Assert-ReleaseStateRuntimePlacement -State $state -Configuration $config
$configDirectory = Split-Path -Parent $resolvedConfigPath
$runtimeLockPath = Join-Path $configDirectory 'runtime.lock'
$declared = @(Get-ConfiguredWorkspaceRepositories -Configuration $config)
$cursorProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'Cursor.exe'" | Where-Object {
    $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch 'gitWorker'
})

function Get-InstanceRuntime {
    param([Parameter(Mandatory)][string]$InstanceName)

    $instance = Get-ConfiguredInstance -Configuration $config -Name $InstanceName
    $instanceUserDataDir = if ($instance.userDataDir) { Resolve-ConfiguredPath -Value ([string]$instance.userDataDir) -BasePath $configDirectory } else { $null }

    # Dedicated --user-data-dir processes are recorded for display/remediation.
    # Default-profile Cursor.exe is not instance-bound; counting it as stable
    # running blocks seed from the operator's own window.
    $windowsProcesses = if ($instanceUserDataDir) {
        @($cursorProcesses | Where-Object { $_.CommandLine -like "*$instanceUserDataDir*" })
    } else {
        @()
    }

    $remote = @(Get-WslCursorServerProcesses -Distro ([string]$instance.wslDistro) -User ([string]$instance.wslUser) -SubjectHome ([string]$instance.wslHome))

    [ordered]@{
        instance = $InstanceName
        userDataDir = if ($instanceUserDataDir) { $instanceUserDataDir } else { '<default>' }
        wslDistro = [string]$instance.wslDistro
        wslUser = [string]$instance.wslUser
        windowsProcessIds = @($windowsProcesses.ProcessId)
        windowsProcessCount = $windowsProcesses.Count
        remoteProcessCount = $remote.Count
        # Reuse is pinned by this instance's WSL .cursor-server, not by a
        # Windows Cursor.exe that happens to be the default profile.
        running = ($remote.Count -gt 0)
    }
}

$stableRuntime = Get-InstanceRuntime -InstanceName stable
$candidateRuntime = Get-InstanceRuntime -InstanceName candidate
$runtimeByName = @{ stable = $stableRuntime; candidate = $candidateRuntime }

function Resolve-RoleRuntime {
    param([Parameter(Mandatory)][AllowNull()][object]$Release, [Parameter(Mandatory)][string]$Role)

    if ($null -eq $Release) { return $null }
    $instanceName = [string]$Release.instance
    if (-not $runtimeByName.ContainsKey($instanceName)) {
        # Never fall through to $null here: previousDrained would then report the
        # unsafe answer (drained) for a release we could not inspect at all.
        throw "Release state.$Role.instance '$instanceName' has no inspectable runtime."
    }
    return $runtimeByName[$instanceName]
}

$baselineRuntime = Resolve-RoleRuntime -Release $state.baseline -Role 'baseline'
$runRuntime = Resolve-RoleRuntime -Release $state.run -Role 'run'
$canSeedRun = ($null -eq $state.run)

$blockers = [System.Collections.Generic.List[object]]::new()
$workspaces = $null
if (-not $SkipWorkspace) {
    $workspaces = [ordered]@{}
    foreach ($role in @('baseline', 'run')) {
        $release = $state.$role
        if ($null -eq $release) {
            $workspaces[$role] = $null
            continue
        }

        $instance = Get-ConfiguredInstance -Configuration $config -Name ([string]$release.instance)
        $snapshot = Get-ReleaseWorkspaceSnapshot `
            -Instance $instance `
            -WorkspaceRoot ([string]$release.path) `
            -GitRef ([string]$release.gitRef) `
            -DeclaredRepositories $declared `
            -Channel $role `
            -EnforceMembership

        # ~/local-data holds files that neither a clone nor a git bundle carries.
        # Both live roles are checked; previousBaseline is a backup, not a workspace.
        $instanceHome = Assert-AbsolutePosixPath `
            -Path ([string]$instance.wslHome) `
            -Context "Environment config.instances.$($release.instance).wslHome"
        $localData = Get-LocalDataStatus `
            -Distro ([string]$instance.wslDistro) `
            -User ([string]$instance.wslUser) `
            -StoreRoot "$instanceHome/local-data" `
            -WorkspaceRoot ([string]$snapshot.path)

        $workspaces[$role] = [ordered]@{
            role = $role
            name = [string]$release.name
            path = [string]$snapshot.path
            commit = [string]$snapshot.commit
            refMatchesHead = [bool]$snapshot.refMatchesHead
            clean = [bool]$snapshot.clean
            dirtyRepositories = @($snapshot.dirtyRepositories)
            missingDeclared = @($snapshot.missingDeclared)
            undeclaredRepositories = @($snapshot.undeclaredRepositories)
            errors = @($snapshot.errors)
            warnings = @($snapshot.warnings)
            localData = $localData
        }

        if (-not $snapshot.refMatchesHead) {
            $blockers.Add((New-FoundationBlocker `
                -Code 'ref-head-mismatch' `
                -Channel $role `
                -Detail "HEAD $($snapshot.commit) does not match gitRef $($snapshot.gitRef) ($($snapshot.refCommit))." `
                -Remediation @("Inspect the release with .\Get-FoundationVersion.ps1 and re-pin gitRef, or check out the pinned commit in ${role}."))) | Out-Null
        }
        foreach ($relative in @($snapshot.missingDeclared)) {
            $blockers.Add((New-FoundationBlocker `
                -Code 'declared-repo-missing' `
                -Channel $role `
                -Detail "Declared repository '$relative' is not present in the workspace." `
                -Remediation @("Clone the declared repository into $($snapshot.path)/$relative, or remove it from environment.json workspace.repositories."))) | Out-Null
        }
        if ($role -eq 'run' -and -not $snapshot.clean) {
            $blockers.Add((New-FoundationBlocker `
                -Code 'run-dirty' `
                -Channel $role `
                -Detail "Run workspace has uncommitted changes in: $(@($snapshot.dirtyRepositories) -join ', ')." `
                -Remediation @('Commit or stash the changes in the run workspace; acceptance never ignores dirty state.'))) | Out-Null
        }
        foreach ($relative in @($snapshot.undeclaredRepositories)) {
            if ($role -ne 'run') { continue }
            $blockers.Add((New-FoundationBlocker `
                -Code 'run-undeclared-repo' `
                -Channel $role `
                -Detail "Undeclared Git repository '$relative' is inside the run workspace." `
                -Remediation @("Declare '$relative' in environment.json workspace.repositories, or remove it from the workspace."))) | Out-Null
        }

        if ($localData.state -eq 'drift') {
            $problems = @($localData.problems)
            $shown = @($problems | Select-Object -First 10)
            $detail = "Local data is missing or has drifted in the workspace ($($localData.summary))"
            if ($shown.Count -gt 0) { $detail += ': ' + ($shown -join '; ') }
            if ($problems.Count -gt $shown.Count) {
                $detail += " (+$($problems.Count - $shown.Count) more; see workspaces.$role.localData.problems)"
            }
            # `local-data.sh status` reports one tag per problem, and the tags do not
            # all point the same way. ABSENT/BROKEN/NOTLINK mean the store is the only
            # copy left, so pull is the fix. DIFF means both copies exist and differ,
            # and the script compares bytes only -- it cannot tell which side is newer
            # (the release roots and the legacy ~/Projects root share one store, so a
            # push from either side makes the other read DIFF). pull is also not
            # selective: it rewrites every MANIFEST entry. So a DIFF has to be settled
            # before the pull line is safe to run, and the remediation says so instead
            # of naming a direction it cannot know.
            $blockers.Add((New-FoundationBlocker `
                -Code 'local-data-drift' `
                -Channel $role `
                -Detail "$detail." `
                -Remediation @(
                    if (@($problems | Where-Object { $_ -clike 'DIFF *' }).Count -gt 0) {
                        $diffPaths = @($problems |
                            Where-Object { $_ -clike 'DIFF *' } |
                            ForEach-Object { ($_ -split ' ', 2)[1] } |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                        'A DIFF line means the workspace copy and the store copy differ; local-data.sh cannot tell which side is newer. Settle every DIFF path before the pull below, because pull overwrites the workspace copy (moving it to <path>.bak-local-data).'
                        "Compare one: wsl -d $($instance.wslDistro) -u $($instance.wslUser) -- diff -u $($localData.store)/files/$($diffPaths[0]) $($localData.workspaceRoot)/$($diffPaths[0])   # '-' lines are the store copy, '+' the workspace copy; repeat for each DIFF path above"
                        "Keep the workspace copy -> wsl -d $($instance.wslDistro) -u $($instance.wslUser) -- $($localData.script) push $($localData.workspaceRoot), then commit the store. Keep the store copy -> the pull below is the fix. push and pull act on every MANIFEST entry, so copy files by hand first when DIFF paths need opposite directions."
                    }
                    "Restore from the store: wsl -d $($instance.wslDistro) -u $($instance.wslUser) -- $($localData.script) pull $($localData.workspaceRoot)"
                    if (@($problems | Where-Object { $_ -clike 'NOSTORE *' }).Count -gt 0) {
                        "A NOSTORE line means the shared store itself lacks the file; pull cannot invent it. Run $($localData.script) push from a workspace that still has the file, then commit the store."
                    }
                    "Confirm: wsl -d $($instance.wslDistro) -u $($instance.wslUser) -- $($localData.script) status $($localData.workspaceRoot)   # expects ok=N diff=0 missing=0 and no report lines"))) | Out-Null
        }
        if ($localData.state -eq 'unavailable') {
            $blockers.Add((New-FoundationBlocker `
                -Code 'local-data-unavailable' `
                -Channel $role `
                -Detail "The local data store could not be inspected on instance '$($release.instance)' ($($instance.wslDistro):$($localData.script)): exit $($localData.exitCode) with no status summary, so whether this release still carries its non-regenerable files is unknown." `
                -Remediation @(
                    "Check the store link: wsl -d $($instance.wslDistro) -u $($instance.wslUser) -- ls -ld $($localData.store)   # must resolve to the shared store named by environment.json storage.localDataRoot",
                    "See the reason: wsl -d $($instance.wslDistro) -u $($instance.wslUser) -- $($localData.script) status $($localData.workspaceRoot)",
                    "Raw output is in workspaces.$role.localData.output (-Format json); it is not repeated here because local-data.sh reports fatal errors in Japanese and the console encoding mangles them.",
                    'seed does not tolerate a missing store either: Initialize-NextFoundation.ps1 throws when its target instance has no ~/local-data.'))) | Out-Null
        }
    }
}

$sharedByInstance = @{}
foreach ($role in @('baseline', 'run')) {
    $release = $state.$role
    if ($null -eq $release) { continue }
    $instanceName = [string]$release.instance
    if ([string]::IsNullOrWhiteSpace($instanceName)) { continue }
    if (-not $sharedByInstance.ContainsKey($instanceName)) {
        $sharedByInstance[$instanceName] = [System.Collections.Generic.List[string]]::new()
    }
    $sharedByInstance[$instanceName].Add($role)
}
$sharedInstances = [System.Collections.Generic.List[object]]::new()
foreach ($instanceName in @($sharedByInstance.Keys | Sort-Object)) {
    $roles = @($sharedByInstance[$instanceName])
    if ($roles.Count -lt 2) { continue }
    $sharedInstances.Add([ordered]@{
        instance = $instanceName
        roles = $roles
    })
}

$nextAction = if ($blockers.Count -gt 0) {
    'Resolve the blockers above, then re-run .\Invoke-FoundationRelease.ps1 -Stage doctor'
} elseif ($state.run) {
    $resolvedReviewRoot = Resolve-ReviewRoot -ReviewRoot $ReviewRoot -StatePath $resolvedStatePath
    $recordPath = Join-Path $resolvedReviewRoot ("{0}.json" -f [string]$state.run.name)
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        '.\Invoke-FoundationRelease.ps1 -Stage review-init   # add -Goal / -SuccessCriteria for late:false'
    } else {
        '.\Invoke-FoundationRelease.ps1 -Stage accept'
    }
} elseif ($canSeedRun) {
    '.\Invoke-FoundationRelease.ps1 -Stage seed   # then -Stage seed -Execute'
} else {
    'No release transition is pending.'
}

$status = [ordered]@{
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    generation = [int]$state.generation
    stateSchemaVersion = [int]$state.schemaVersion
    configurationSchemaVersion = [int]$config.schemaVersion
    workspace = [ordered]@{
        declaredRepositoryCount = $declared.Count
        membershipSource = 'environment.workspace.repositories'
        inspected = (-not $SkipWorkspace)
    }
    baseline = $state.baseline
    run = $state.run
    previousBaseline = $state.previousBaseline
    baselineRuntime = $baselineRuntime
    runRuntime = $runRuntime
    canSeedRun = $canSeedRun
    runtimes = [ordered]@{
        stable = $stableRuntime
        candidate = $candidateRuntime
    }
    workspaces = $workspaces
    handoff = [ordered]@{
        command = '.\Invoke-FoundationRelease.ps1 -Stage handoff'
        executeCommand = '.\Invoke-FoundationRelease.ps1 -Stage handoff -Execute'
        runtimeLockPath = $runtimeLockPath
        runtimeLockPresent = (Test-Path -LiteralPath $runtimeLockPath -PathType Leaf)
    }
    sharedInstances = @($sharedInstances)
    blockers = @($blockers)
    nextAction = $nextAction
}

if ($Format -eq 'text') {
    Format-FoundationStatusText -Status ([pscustomobject]$status)
} else {
    (ConvertTo-FoundationSuccess -Result $status) | ConvertTo-Json -Depth 8
}

# Set the exit code explicitly: without this the caller would observe the code
# of the last native command run above (pgrep exits 1 when an instance has no
# Cursor processes, which is a normal, healthy result).
exit 0
