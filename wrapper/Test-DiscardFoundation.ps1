[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', got '$Actual'." }
}

function Assert-True([bool]$Value, [string]$Label) {
    if (-not $Value) { throw "ASSERT FAIL: $Label" }
    Write-Output "PASS: $Label"
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Label)
    try {
        & $Action | Out-Null
    } catch {
        Write-Output "PASS: $Label"
        return
    }
    throw "$Label expected an error."
}

$examplePath = Join-Path $PSScriptRoot 'config\environment.example.json'
$exampleStatePath = Join-Path $PSScriptRoot 'config\release-state.example.json'
$example = Read-EnvironmentConfig -ConfigPath $examplePath
$candidate = Get-ConfiguredInstance -Configuration $example -Name candidate
$runName = 'fixture-discard-run'
$runPath = Resolve-DefaultReleaseSeedPath -Instance $candidate -Name $runName -InstanceName candidate
$seedCommit = ('d' * 40)

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-discard-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $fixtureStatePath = Join-Path $temporaryRoot 'release-state.json'
    $state = Get-Content -Raw -LiteralPath $exampleStatePath | ConvertFrom-Json
    $seedTransition = [ordered]@{
        action = 'seed'
        at = '2026-01-02T00:00:00+00:00'
        release = $runName
        commit = $seedCommit
    }
    $state.generation = 3
    $state.run = [ordered]@{
        name = $runName
        instance = 'candidate'
        path = $runPath
        gitRef = 'run/fixture-discard'
    }
    $state.previousBaseline = [ordered]@{
        name = 'fixture-previous-baseline'
        commit = ('b' * 40)
        gitRef = 'main'
        backupManifest = 'fixture-previous-baseline.json'
        backupSha256 = ('a' * 64)
    }
    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($state.transitionHistory)) { $history.Add($entry) }
    $history.Add($seedTransition)
    $state | Add-Member -MemberType NoteProperty -Name transitionHistory -Value $history.ToArray() -Force
    $state | Add-Member -MemberType NoteProperty -Name lastTransition -Value $seedTransition -Force
    ($state | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $fixtureStatePath -Encoding utf8

    $baselineName = [string]$state.baseline.name
    $baselinePath = [string]$state.baseline.path
    $startHash = (Get-FileHash -LiteralPath $fixtureStatePath -Algorithm SHA256).Hash

    $dry = (& (Join-Path $PSScriptRoot 'Discard-Foundation.ps1') `
        -DryRun `
        -ExpectedGeneration 3 `
        -StatePath $fixtureStatePath `
        -ConfigPath $examplePath) | ConvertFrom-Json
    Assert-Equal $dry.action 'discard' 'dry-run action'
    Assert-True (-not [bool]$dry.execute) 'dry-run execute is false'
    Assert-Equal $dry.release $runName 'dry-run release'
    Assert-Equal $dry.commit $seedCommit 'dry-run commit'
    Assert-Equal $dry.baseline $baselineName 'dry-run baseline name'
    Assert-True ([bool]$dry.runCleared) 'dry-run runCleared'
    Assert-True (-not [bool]$dry.workspaceDeleted) 'dry-run does not delete workspace'
    Assert-Equal (Get-FileHash -LiteralPath $fixtureStatePath -Algorithm SHA256).Hash $startHash 'dry-run leaves state hash unchanged'

    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Discard-Foundation.ps1') `
            -DryRun `
            -ExpectedGeneration 99 `
            -StatePath $fixtureStatePath `
            -ConfigPath $examplePath
    } 'generation mismatch is refused'

    $executed = (& (Join-Path $PSScriptRoot 'Discard-Foundation.ps1') `
        -ExpectedGeneration 3 `
        -StatePath $fixtureStatePath `
        -ConfigPath $examplePath) | ConvertFrom-Json
    Assert-Equal $executed.action 'discard' 'execute action'
    Assert-True ([bool]$executed.execute) 'execute is true'
    Assert-Equal $executed.generation 4 'execute bumps generation'
    Assert-Equal $executed.release $runName 'execute release'
    Assert-Equal $executed.commit $seedCommit 'execute commit'
    Assert-Equal $executed.baseline $baselineName 'execute baseline name'

    $after = Read-ReleaseState -StatePath $fixtureStatePath
    Assert-True ($null -eq $after.run) 'execute clears run'
    Assert-Equal $after.generation 4 'written generation'
    Assert-Equal $after.baseline.name $baselineName 'baseline name unchanged'
    Assert-Equal $after.baseline.path $baselinePath 'baseline path unchanged'
    Assert-Equal $after.baseline.instance 'stable' 'baseline stays on stable'
    Assert-Equal $after.previousBaseline.name 'fixture-previous-baseline' 'previousBaseline preserved'
    Assert-Equal $after.previousBaseline.backupSha256 ('a' * 64) 'previousBaseline hash preserved'
    Assert-Equal $after.lastTransition.action 'discard' 'lastTransition is discard'
    Assert-Equal $after.lastTransition.release $runName 'lastTransition release'
    Assert-Equal $after.lastTransition.commit $seedCommit 'lastTransition commit'

    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Discard-Foundation.ps1') `
            -ExpectedGeneration 4 `
            -StatePath $fixtureStatePath `
            -ConfigPath $examplePath
    } 'discard without a run is refused'

    Write-Output 'PASS: Test-DiscardFoundation.ps1'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
