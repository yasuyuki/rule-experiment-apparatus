[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('baseline', 'run')]
    [string]$Role,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib\ReleaseReview.ps1')
. (Join-Path $PSScriptRoot 'lib\Result.ps1')

trap { Write-FoundationFailure -Command 'Get-FoundationReleaseDiff.ps1' -Stage 'diff' -ErrorRecord $_; exit 1 }

# Everything below is a read-only report: it never writes release-state.json,
# never touches the lock, and never mutates the workspaces it inspects.

function Assert-FoundationChangePathSafe {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Path,
        [Parameter(Mandatory)] [string]$Context
    )

    if ($Path.Contains([char]9) -or $Path.Contains('"')) {
        throw "$Context contains a tab or double-quote character git could not report unambiguously as plain tab-separated text: '$Path'"
    }
    return $Path
}

function ConvertFrom-FoundationCommitLog {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text
    )

    $commits = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @($commits) }
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = $line -split ([char]31)
        if ($fields.Count -lt 3) { throw "Malformed commit log line: '$line'" }
        $commits.Add([ordered]@{
            commit = $fields[0]
            at = $fields[1]
            subject = ($fields[2..($fields.Count - 1)] -join ([string][char]31))
        }) | Out-Null
    }
    return @($commits)
}

function ConvertFrom-FoundationNameStatus {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @($entries) }
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = $line -split "`t"
        if ($fields.Count -eq 2) {
            $status = $fields[0]
            $path = Assert-FoundationChangePathSafe -Path $fields[1] -Context 'diff --name-status path'
            $oldPath = $null
        } elseif ($fields.Count -eq 3) {
            # Rename/copy rows: <status><score>\t<oldPath>\t<newPath>.
            $status = $fields[0]
            $oldPath = Assert-FoundationChangePathSafe -Path $fields[1] -Context 'diff --name-status oldPath'
            $path = Assert-FoundationChangePathSafe -Path $fields[2] -Context 'diff --name-status path'
        } else {
            throw "Malformed diff --name-status line: '$line'"
        }
        $entries.Add([ordered]@{
            status = $status
            path = $path
            oldPath = $oldPath
        }) | Out-Null
    }
    return @($entries)
}

function ConvertFrom-FoundationNumstat {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text
    )

    # Only insertions/deletions/binary are read from this output. The path
    # field uses a compressed "{old => new}" notation for renames that is not
    # reliably reconstructible, so paths come from --name-status instead and
    # the two outputs are aligned positionally (Merge-FoundationReleaseDiffFiles).
    $entries = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @($entries) }
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = $line -split "`t", 3
        if ($fields.Count -lt 3) { throw "Malformed diff --numstat line: '$line'" }
        $isBinary = ($fields[0] -eq '-' -and $fields[1] -eq '-')
        $entries.Add([ordered]@{
            insertions = if ($isBinary) { $null } else { [int]$fields[0] }
            deletions = if ($isBinary) { $null } else { [int]$fields[1] }
            binary = $isBinary
        }) | Out-Null
    }
    return @($entries)
}

function Merge-FoundationReleaseDiffFiles {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$NameStatusEntries,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$NumstatEntries
    )

    $nameStatusCount = @($NameStatusEntries).Count
    $numstatCount = @($NumstatEntries).Count
    if ($nameStatusCount -ne $numstatCount) {
        throw "diff --name-status produced $nameStatusCount entries but diff --numstat produced $numstatCount; cannot align them positionally."
    }

    $files = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $nameStatusCount; $i++) {
        $ns = $NameStatusEntries[$i]
        $num = $NumstatEntries[$i]
        $files.Add([ordered]@{
            status = $ns.status
            path = $ns.path
            oldPath = $ns.oldPath
            area = Get-FoundationChangeArea -Path $ns.path
            insertions = $num.insertions
            deletions = $num.deletions
            binary = $num.binary
        }) | Out-Null
    }
    return @($files)
}

function Get-FoundationReleaseAreaSummary {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Files
    )

    $summary = [ordered]@{}
    foreach ($area in @('llm-config', 'control-plane', 'docs', 'other')) {
        $filesInArea = @($Files | Where-Object { $_.area -eq $area })
        $insertions = 0
        $deletions = 0
        foreach ($file in $filesInArea) {
            if ($null -ne $file.insertions) { $insertions += $file.insertions }
            if ($null -ne $file.deletions) { $deletions += $file.deletions }
        }
        $summary[$area] = [ordered]@{
            files = $filesInArea.Count
            insertions = $insertions
            deletions = $deletions
        }
    }
    return $summary
}

function Get-FoundationReleaseTotals {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Commits,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Files
    )

    $insertions = 0
    $deletions = 0
    foreach ($file in @($Files)) {
        if ($null -ne $file.insertions) { $insertions += $file.insertions }
        if ($null -ne $file.deletions) { $deletions += $file.deletions }
    }
    return [ordered]@{
        commits = @($Commits).Count
        filesChanged = @($Files).Count
        insertions = $insertions
        deletions = $deletions
    }
}

# Runs the same three git commands (log / diff --name-status / diff --numstat)
# for one repo path+range and tags each commit/file with $Repo (root is '.').
function Get-FoundationReleaseRepoRangeDiff {
    param(
        [Parameter(Mandatory)] [string]$Distro,
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Range,
        [Parameter(Mandatory)] [string]$Repo
    )

    $logText = Invoke-WslGitText -Distro $Distro -User $User -Path $Path `
        -GitArguments @('log', '--reverse', '--format=%H%x1f%cI%x1f%s', $Range)
    $nameStatusText = Invoke-WslGitText -Distro $Distro -User $User -Path $Path `
        -GitArguments @('-c', 'core.quotePath=false', 'diff', '--name-status', $Range)
    $numstatText = Invoke-WslGitText -Distro $Distro -User $User -Path $Path `
        -GitArguments @('-c', 'core.quotePath=false', 'diff', '--numstat', $Range)

    # @() at each call site is required, not decorative: a PowerShell function
    # that emits exactly one or zero pipeline objects has that output collapsed
    # to a bare object or $null on assignment, even though the function itself
    # returns "@($list)". Wrapping the call re-collects the pipeline into a
    # true array in both edge cases (see codebase-wide convention, e.g.
    # `@(Get-ConfiguredWorkspaceRepositories ...)` in lib/Configuration.ps1).
    $parsedCommits = @(ConvertFrom-FoundationCommitLog -Text $logText)
    $commits = [System.Collections.Generic.List[object]]::new()
    foreach ($commit in $parsedCommits) {
        $commits.Add([ordered]@{
            commit = $commit.commit
            at = $commit.at
            subject = $commit.subject
            repo = $Repo
        }) | Out-Null
    }

    $nameStatusEntries = @(ConvertFrom-FoundationNameStatus -Text $nameStatusText)
    $numstatEntries = @(ConvertFrom-FoundationNumstat -Text $numstatText)
    $parsedFiles = @(Merge-FoundationReleaseDiffFiles -NameStatusEntries $nameStatusEntries -NumstatEntries $numstatEntries)
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $parsedFiles) {
        $files.Add([ordered]@{
            status = $file.status
            path = $file.path
            oldPath = $file.oldPath
            area = $file.area
            insertions = $file.insertions
            deletions = $file.deletions
            binary = $file.binary
            repo = $Repo
        }) | Out-Null
    }

    return [ordered]@{
        commits = @($commits)
        files = @($files)
    }
}

$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$state = Read-ReleaseState -StatePath $resolvedStatePath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath

$release = $state.$Role
if ($null -eq $release) {
    throw "Release state.$Role is not set; there is no release in this role to report a diff for."
}

$releaseName = [string]$release.name
$instanceName = [string]$release.instance
$instance = Get-ConfiguredInstance -Configuration $config -Name $instanceName
$declared = @(Get-ConfiguredWorkspaceRepositories -Configuration $config)

# Reuses the one workspace inspector (see wrapper/README.md "One workspace
# inspector") to get the root HEAD and each declared child repository's HEAD
# in a single batched WSL call, instead of issuing our own rev-parse.
$snapshot = Get-ReleaseWorkspaceSnapshot `
    -Instance $instance `
    -WorkspaceRoot ([string]$release.path) `
    -GitRef ([string]$release.gitRef) `
    -DeclaredRepositories $declared `
    -Channel $Role

$headCommit = [string]$snapshot.commit
$distro = [string]$instance.wslDistro
$user = [string]$instance.wslUser
$rootPath = [string]$snapshot.path

$baseCommit = Resolve-FoundationReleaseBaseCommit -State $state -ReleaseName $releaseName
$baseCommitResolved = -not [string]::IsNullOrWhiteSpace($baseCommit)

$nestedRepositories = @($snapshot.repositories | Where-Object { $_.relativePath -ne '.' } | ForEach-Object {
    [ordered]@{
        relativePath = $_.relativePath
        origin = $_.origin
        headCommit = $_.head
        branch = $_.branch
        dirty = $_.dirty
    }
})

$commits = [System.Collections.Generic.List[object]]::new()
$files = [System.Collections.Generic.List[object]]::new()
if ($baseCommitResolved) {
    $rootDiff = Get-FoundationReleaseRepoRangeDiff `
        -Distro $distro -User $user -Path $rootPath `
        -Range "$baseCommit..HEAD" -Repo '.'
    foreach ($commit in @($rootDiff.commits)) { $commits.Add($commit) | Out-Null }
    foreach ($file in @($rootDiff.files)) { $files.Add($file) | Out-Null }

    # Child base matches Test-FoundationIdentityLeak.ps1: run uses the
    # baseline sibling's same-relativePath HEAD..HEAD; baseline uses HEAD..HEAD.
    $baselineRelease = $null
    $baselineInstance = $null
    if ($Role -eq 'run') {
        $baselineRelease = $state.baseline
        if ($null -eq $baselineRelease) {
            throw "Release state.baseline is not set; run diff needs baseline sibling HEADs as the child base."
        }
        $baselineInstance = Get-ConfiguredInstance -Configuration $config -Name ([string]$baselineRelease.instance)
    }

    foreach ($nested in $nestedRepositories) {
        $relativePath = [string]$nested.relativePath
        $childPath = Join-WorkspaceRelativePath -WorkspaceRoot $rootPath -RelativePath $relativePath
        if ($Role -eq 'run') {
            $baselineChildPath = Join-WorkspaceRelativePath -WorkspaceRoot ([string]$baselineRelease.path) -RelativePath $relativePath
            $baselineHead = Invoke-WslGitText `
                -Distro ([string]$baselineInstance.wslDistro) `
                -User ([string]$baselineInstance.wslUser) `
                -Path $baselineChildPath `
                -GitArguments @('rev-parse', 'HEAD')
            if ([string]::IsNullOrWhiteSpace($baselineHead)) {
                throw "Could not resolve baseline HEAD for child repository '$relativePath' at '$baselineChildPath'."
            }
            $nested.baseCommit = $baselineHead
            $childRange = "$baselineHead..HEAD"
        } else {
            $nested.baseCommit = [string]$nested.headCommit
            $childRange = 'HEAD..HEAD'
        }

        $childDiff = Get-FoundationReleaseRepoRangeDiff `
            -Distro $distro -User $user -Path $childPath `
            -Range $childRange -Repo $relativePath
        foreach ($commit in @($childDiff.commits)) { $commits.Add($commit) | Out-Null }
        foreach ($file in @($childDiff.files)) { $files.Add($file) | Out-Null }
    }
}

$commitList = @($commits)
$fileList = @($files)

$result = [ordered]@{
    role = $Role
    release = $releaseName
    instance = $instanceName
    path = $rootPath
    baseCommit = $baseCommit
    baseCommitResolved = $baseCommitResolved
    headCommit = $headCommit
    commits = $commitList
    files = $fileList
    areaSummary = (Get-FoundationReleaseAreaSummary -Files $fileList)
    nestedRepositories = $nestedRepositories
    totals = (Get-FoundationReleaseTotals -Commits $commitList -Files $fileList)
    checkedAt = [DateTimeOffset]::Now.ToString('o')
}

(ConvertTo-FoundationSuccess -Result $result) | ConvertTo-Json -Depth 8
exit 0
