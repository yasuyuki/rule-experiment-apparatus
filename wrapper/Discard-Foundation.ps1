[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$ExpectedGeneration = -1,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
$StatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$ConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $ConfigPath
$lock = Enter-ReleaseStateLock -StatePath $StatePath -DryRun:$DryRun

function Resolve-DiscardedRunCommit {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$ReleaseName
    )

    $history = @($State.transitionHistory)
    for ($i = $history.Count - 1; $i -ge 0; $i--) {
        $entry = $history[$i]
        if ([string]$entry.action -ne 'seed') { continue }
        if ([string]$entry.release -ne $ReleaseName) { continue }
        $commit = [string]$entry.commit
        if (-not [string]::IsNullOrWhiteSpace($commit)) { return $commit }
    }
    throw "Could not resolve seed commit for run '$ReleaseName' from transitionHistory."
}

try {
    $state = Read-ReleaseState -StatePath $StatePath
    Assert-ReleaseStateRuntimePlacement -State $state -Configuration $config
    Assert-ReleaseStateGeneration -State $state -ExpectedGeneration $ExpectedGeneration | Out-Null
    if (-not $state.run) { throw 'There is no run to discard.' }

    $releaseName = [string]$state.run.name
    $commit = Resolve-DiscardedRunCommit -State $state -ReleaseName $releaseName
    $plan = [ordered]@{
        action = 'discard'
        execute = (-not $DryRun)
        generation = [int]$state.generation
        release = $releaseName
        commit = $commit
        baseline = [string]$state.baseline.name
        baselineInstance = [string]$state.baseline.instance
        runCleared = $true
        workspaceDeleted = $false
    }
    if ($DryRun) { $plan | ConvertTo-Json -Depth 8; return }

    $state.run = $null
    $state.generation = [int]$state.generation + 1
    $transition = [ordered]@{
        action = 'discard'
        at = [DateTimeOffset]::Now.ToString('o')
        release = $releaseName
        commit = $commit
    }
    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($state.transitionHistory)) { $history.Add($entry) }
    $history.Add($transition)
    $state | Add-Member -MemberType NoteProperty -Name transitionHistory -Value $history.ToArray() -Force
    $state | Add-Member -MemberType NoteProperty -Name lastTransition -Value $transition -Force
    Write-ReleaseStateAtomic -StatePath $StatePath -State $state
    $plan['generation'] = [int]$state.generation
    $plan | ConvertTo-Json -Depth 8
} finally {
    Exit-ReleaseStateLock -Lock $lock
}
