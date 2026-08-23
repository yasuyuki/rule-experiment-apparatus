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

trap { Write-FoundationFailure -Command 'Test-FoundationIdentityLeak.ps1' -Stage 'leak-scan' -ErrorRecord $_; exit 1 }

function Find-FoundationIdentityLeaksInUnifiedDiff {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$DiffText,
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Needles
    )

    $leaks = [System.Collections.Generic.List[object]]::new()
    $currentPath = $null

    if ([string]::IsNullOrEmpty($DiffText)) {
        return @($leaks)
    }

    foreach ($rawLine in ($DiffText -split "`r?`n")) {
        # Unified-diff headers are `+++ ` (plus-plus-plus-space). An added
        # line whose body starts with `++` is `+++body` with no space and
        # must still be scanned.
        if ($rawLine.StartsWith('+++ ')) {
            if ($rawLine.StartsWith('+++ b/')) {
                $currentPath = $rawLine.Substring(6)
            } elseif ($rawLine.StartsWith('+++ /dev/null')) {
                $currentPath = ''
            }
            continue
        }

        if ($rawLine.StartsWith('+')) {
            if ($null -eq $currentPath) {
                throw "Malformed unified diff in repo '$Repo': added line before any +++ header."
            }
            $body = $rawLine.Substring(1)
            $hit = Test-FoundationIdentityLeakLine -Line $body -Needles $Needles
            if ($null -ne $hit) {
                $leaks.Add([ordered]@{
                    repo = $Repo
                    path = $currentPath
                    needle = $hit
                    line = $body
                }) | Out-Null
            }
        }
    }

    return @($leaks)
}

$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$state = Read-ReleaseState -StatePath $resolvedStatePath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath

$release = $state.$Role
if ($null -eq $release) {
    throw "Release state.$Role is not set; there is no release in this role to scan for identity leaks."
}

$releaseName = [string]$release.name
$instanceName = [string]$release.instance
$instance = Get-ConfiguredInstance -Configuration $config -Name $instanceName
$distro = [string]$instance.wslDistro
$user = [string]$instance.wslUser
$rootPath = [string]$release.path
$declared = @(Get-ConfiguredWorkspaceRepositories -Configuration $config)
$needles = @(Get-FoundationIdentityLeakNeedles -Configuration $config)

$leaks = [System.Collections.Generic.List[object]]::new()
$scannedRepos = 0

$baseCommit = Resolve-FoundationReleaseBaseCommit -State $state -ReleaseName $releaseName
if ([string]::IsNullOrWhiteSpace($baseCommit)) {
    throw "Could not resolve the base commit for release '$releaseName' from transitionHistory; identity leak scan cannot run."
}

$rootRange = "$baseCommit..HEAD"
$rootDiff = Invoke-WslGitText -Distro $distro -User $user -Path $rootPath `
    -GitArguments @('-c', 'core.quotePath=false', 'diff', '-U0', $rootRange)
$scannedRepos += 1
foreach ($hit in @(Find-FoundationIdentityLeaksInUnifiedDiff -DiffText $rootDiff -Repo '.' -Needles $needles)) {
    $leaks.Add($hit) | Out-Null
}

$baselineRelease = $null
$baselineInstance = $null
if ($Role -eq 'run') {
    $baselineRelease = $state.baseline
    if ($null -eq $baselineRelease) {
        throw "Release state.baseline is not set; run identity leak scan needs baseline sibling HEADs as the child base."
    }
    $baselineInstance = Get-ConfiguredInstance -Configuration $config -Name ([string]$baselineRelease.instance)
}

foreach ($repo in $declared) {
    $relativePath = [string]$repo.relativePath
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
        $childRange = "$baselineHead..HEAD"
    } else {
        $childRange = 'HEAD..HEAD'
    }

    $childDiff = Invoke-WslGitText -Distro $distro -User $user -Path $childPath `
        -GitArguments @('-c', 'core.quotePath=false', 'diff', '-U0', $childRange)
    $scannedRepos += 1
    foreach ($hit in @(Find-FoundationIdentityLeaksInUnifiedDiff -DiffText $childDiff -Repo $relativePath -Needles $needles)) {
        $leaks.Add($hit) | Out-Null
    }
}

if ($leaks.Count -gt 0) {
    $parts = @($leaks | ForEach-Object { "repo=$($_.repo) needle=$($_.needle)" })
    throw ("Identity leak detected ($($leaks.Count)): " + ($parts -join '; '))
}

$result = [ordered]@{
    role = $Role
    release = $releaseName
    leaks = @()
    scanned = [ordered]@{ repos = $scannedRepos }
    skipped = $false
}

(ConvertTo-FoundationSuccess -Result $result) | ConvertTo-Json -Depth 8
exit 0
