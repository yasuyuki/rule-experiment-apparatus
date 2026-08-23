[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
$StatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$ConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$startHash = (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash
$rawState = Read-ReleaseStateDocument -StatePath $StatePath -DocumentName 'transition fixture state'

if ([int]$rawState.schemaVersion -eq 2) {
    $null = Read-LegacyReleaseStateV2ForMigration -StatePath $StatePath
    $endHash = (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash
    if ($endHash -ne $startHash) { throw 'Live schema v2 state changed during transition preflight.' }
    [ordered]@{
        passed = $true
        skipped = $true
        reasonCode = 'migration-required'
        reason = 'Transition fixture requires schema version 3; migrate-runtime-model is required.'
        schemaVersion = 2
        liveStateUnchanged = $true
        actionsTested = @()
        cyclesVerified = 0
    } | ConvertTo-Json -Depth 5
    return
}

$state = Read-ReleaseState -StatePath $StatePath
$fixtureId = [guid]::NewGuid().ToString('N')
$fixtureFull = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".transition-fixture-$fixtureId.json"))
$wrapperRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
if (-not $fixtureFull.StartsWith($wrapperRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe fixture path: $fixtureFull"
}

function Assert-StateRejected {
    param([Parameter(Mandatory)][object]$FixtureState, [Parameter(Mandatory)][string]$Label)

    $FixtureState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixtureFull -Encoding utf8
    try {
        $null = Read-ReleaseState -StatePath $fixtureFull
    } catch {
        return
    }
    throw "$Label fixture was accepted."
}

function Set-FixtureTransition {
    param([Parameter(Mandatory)][object]$FixtureState, [Parameter(Mandatory)][object]$Transition)

    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($FixtureState.transitionHistory)) { $history.Add($entry) }
    $history.Add($Transition)
    $FixtureState | Add-Member -MemberType NoteProperty -Name transitionHistory -Value $history.ToArray() -Force
    $FixtureState | Add-Member -MemberType NoteProperty -Name lastTransition -Value $Transition -Force
}

function Assert-FixtureStateValid {
    param([Parameter(Mandatory)][object]$FixtureState)

    $FixtureState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixtureFull -Encoding utf8
    return (Read-ReleaseState -StatePath $fixtureFull)
}

$actions = [System.Collections.Generic.List[string]]::new()
try {
    $badBaseline = ($state | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $badBaseline.baseline.instance = 'candidate'
    Assert-StateRejected -FixtureState $badBaseline -Label 'baseline on candidate instance'

    if ($state.run) {
        $badRun = ($state | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        $badRun.run.instance = 'stable'
        Assert-StateRejected -FixtureState $badRun -Label 'run on stable instance'

        $plan = (& (Join-Path $PSScriptRoot 'Promote-Foundation.ps1') `
            -DryRun `
            -ExpectedGeneration ([int]$state.generation) `
            -StatePath $StatePath `
            -ConfigPath $ConfigPath) | ConvertFrom-Json
        if ($plan.action -ne 'promote' -or $plan.targetInstance -ne 'stable') {
            throw 'Promotion dry-run did not preserve the stable baseline instance.'
        }
        $actions.Add('promote-dry')

        $discardPlan = (& (Join-Path $PSScriptRoot 'Discard-Foundation.ps1') `
            -DryRun `
            -ExpectedGeneration ([int]$state.generation) `
            -StatePath $StatePath `
            -ConfigPath $ConfigPath) | ConvertFrom-Json
        if ($discardPlan.action -ne 'discard' -or [bool]$discardPlan.execute -or [bool]$discardPlan.workspaceDeleted) {
            throw 'Discard dry-run did not keep baseline and leftover workspace.'
        }
        if ([string]$discardPlan.baseline -ne [string]$state.baseline.name) {
            throw 'Discard dry-run changed the reported baseline name.'
        }
        $actions.Add('discard-dry')
    }

    # Exercise the v3 state contract independently of live workspaces. Production
    # scripts are dry-run above/below; this fixture alone advances state.
    $cycleState = ($state | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $cycleState.run = $null
    $cycleState.previousBaseline = $null
    $restoredBaseline = ($cycleState.baseline | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
    $restoredCommit = ('F' * 40)
    for ($cycle = 1; $cycle -le 2; $cycle++) {
        $runName = "fixture-run-$cycle"
        $runCommit = ([string]$cycle * 40)
        $cycleState.run = [ordered]@{
            name = $runName
            instance = 'candidate'
            path = "/tmp/foundation-transition-$fixtureId/candidate/$runName"
            gitRef = "fixture/run-$cycle"
        }
        $cycleState.generation = [int]$cycleState.generation + 1
        Set-FixtureTransition -FixtureState $cycleState -Transition ([ordered]@{
            action = 'seed'; at = [DateTimeOffset]::Now.ToString('o'); release = $runName; commit = $runCommit
        })
        $cycleState = Assert-FixtureStateValid -FixtureState $cycleState

        $discardedName = [string]$cycleState.run.name
        $baselineBeforeDiscard = [string]$cycleState.baseline.name
        $cycleState.run = $null
        $cycleState.generation = [int]$cycleState.generation + 1
        Set-FixtureTransition -FixtureState $cycleState -Transition ([ordered]@{
            action = 'discard'; at = [DateTimeOffset]::Now.ToString('o'); release = $discardedName; commit = $runCommit
        })
        $cycleState = Assert-FixtureStateValid -FixtureState $cycleState
        if ($cycleState.run -or [string]$cycleState.baseline.name -ne $baselineBeforeDiscard -or [string]$cycleState.baseline.instance -ne 'stable') {
            throw "State-model cycle $cycle discard did not keep the original baseline."
        }

        $cycleState.run = [ordered]@{
            name = $runName
            instance = 'candidate'
            path = "/tmp/foundation-transition-$fixtureId/candidate/$runName"
            gitRef = "fixture/run-$cycle"
        }
        $cycleState.generation = [int]$cycleState.generation + 1
        Set-FixtureTransition -FixtureState $cycleState -Transition ([ordered]@{
            action = 'seed'; at = [DateTimeOffset]::Now.ToString('o'); release = $runName; commit = $runCommit
        })
        $cycleState = Assert-FixtureStateValid -FixtureState $cycleState

        $oldBaseline = $cycleState.baseline
        $cycleState.previousBaseline = [ordered]@{
            name = [string]$oldBaseline.name
            commit = $restoredCommit
            gitRef = [string]$oldBaseline.gitRef
            backupManifest = "fixture-baseline-$cycle.json"
            backupSha256 = ('A' * 64)
        }
        $cycleState.baseline = [ordered]@{
            name = [string]$cycleState.run.name
            instance = 'stable'
            path = "/tmp/foundation-transition-$fixtureId/stable/$runName"
            gitRef = [string]$cycleState.run.gitRef
        }
        $cycleState.run = $null
        $cycleState.generation = [int]$cycleState.generation + 1
        Set-FixtureTransition -FixtureState $cycleState -Transition ([ordered]@{
            action = 'promote'; at = [DateTimeOffset]::Now.ToString('o'); from = [string]$oldBaseline.name; to = $runName; commit = $runCommit
        })
        $cycleState = Assert-FixtureStateValid -FixtureState $cycleState

        $from = [string]$cycleState.baseline.name
        $cycleState.baseline = ($restoredBaseline | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        $cycleState.previousBaseline = $null
        $cycleState.generation = [int]$cycleState.generation + 1
        Set-FixtureTransition -FixtureState $cycleState -Transition ([ordered]@{
            action = 'rollback'; at = [DateTimeOffset]::Now.ToString('o'); from = $from; to = [string]$restoredBaseline.name; commit = $restoredCommit
        })
        $cycleState = Assert-FixtureStateValid -FixtureState $cycleState
        if ($cycleState.baseline.instance -ne 'stable' -or $cycleState.baseline.name -ne $restoredBaseline.name -or $cycleState.run -or $cycleState.previousBaseline) {
            throw "State-model cycle $cycle did not restore the original fixed baseline."
        }
    }

    if (-not $state.run -and $state.previousBaseline) {
        $plan = (& (Join-Path $PSScriptRoot 'Rollback-Foundation.ps1') `
            -DryRun `
            -ExpectedGeneration ([int]$state.generation) `
            -StatePath $StatePath `
            -ConfigPath $ConfigPath) | ConvertFrom-Json
        if ($plan.action -ne 'rollback' -or $plan.targetInstance -ne 'stable') {
            throw 'Rollback dry-run did not preserve the stable baseline instance.'
        }
        $actions.Add('rollback-dry')
    }

    $endHash = (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash
    if ($endHash -ne $startHash) { throw 'Live release state changed during transition fixture test.' }
    [ordered]@{
        passed = $true
        skipped = ($actions.Count -eq 0)
        reasonCode = if ($actions.Count -eq 0) { 'no-runnable-transition' } else { $null }
        reason = if ($actions.Count -eq 0) { 'Neither a run nor a previousBaseline is available for a transition dry-run.' } else { $null }
        schemaVersion = 3
        liveStateUnchanged = $true
        fixedInstancesVerified = $true
        baselineInstance = [string]$state.baseline.instance
        runInstance = if ($state.run) { [string]$state.run.instance } else { $null }
        actionsTested = @($actions)
        cyclesVerified = 2
    } | ConvertTo-Json -Depth 5
} finally {
    foreach ($suffix in @('', '.lock', '.tmp')) {
        $path = "$fixtureFull$suffix"
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
