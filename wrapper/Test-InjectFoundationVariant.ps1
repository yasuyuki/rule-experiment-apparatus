[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$StatePath
)

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

function Assert-ThrowsLike {
    param([scriptblock]$Action, [string]$Pattern, [string]$Label)
    try {
        & $Action | Out-Null
    } catch {
        if ($_.Exception.Message -match $Pattern) {
            Write-Output "PASS: $Label"
            return
        }
        throw "$Label expected '$Pattern', got '$($_.Exception.Message)'."
    }
    throw "$Label expected an error."
}

function New-InjectFixtureState {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [object]$Run
    )
    $state = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'config\release-state.example.json') | ConvertFrom-Json
    if ($null -ne $Run) {
        $seed = [ordered]@{
            action = 'seed'
            at = '2026-01-02T00:00:00+00:00'
            release = [string]$Run.name
            commit = ('d' * 40)
        }
        $history = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($state.transitionHistory)) { $history.Add($entry) }
        $history.Add($seed)
        $state | Add-Member -MemberType NoteProperty -Name run -Value $Run -Force
        $state | Add-Member -MemberType NoteProperty -Name transitionHistory -Value $history.ToArray() -Force
        $state | Add-Member -MemberType NoteProperty -Name lastTransition -Value $seed -Force
        $state.generation = 1
    }
    ($state | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Destination -Encoding utf8
}

$injectScript = Join-Path $PSScriptRoot 'Inject-FoundationVariant.ps1'
$invokePath = Join-Path $PSScriptRoot 'Invoke-FoundationRelease.ps1'
$exampleConfig = Join-Path $PSScriptRoot 'config\environment.example.json'
$example = Read-EnvironmentConfig -ConfigPath $exampleConfig
$candidate = Get-ConfiguredInstance -Configuration $example -Name candidate
$runName = 'fixture-inject-run'
$runPath = Resolve-DefaultReleaseSeedPath -Instance $candidate -Name $runName -InstanceName candidate

$invoke = Get-Command $invokePath
$stageValues = @($invoke.Parameters['Stage'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues })
Assert-True ($stageValues -contains 'inject') 'inject is a public stage'
Assert-True (-not $invoke.Parameters.ContainsKey('Channel')) 'inject public stage has no Channel parameter'
Assert-True (-not $invoke.Parameters.ContainsKey('Path')) 'inject public stage has no Path parameter'
Assert-True (-not $invoke.Parameters.ContainsKey('Instance')) 'inject public stage has no Instance parameter'
Assert-True (-not $invoke.Parameters.ContainsKey('Role')) 'inject public stage has no Role parameter'
Assert-True ($invoke.Parameters.ContainsKey('Experiment')) 'inject public stage has -Experiment'
Assert-True ($invoke.Parameters.ContainsKey('Variant')) 'inject public stage has -Variant'

$injectSource = Get-Content -Raw -LiteralPath $injectScript
Assert-True ($injectSource -match '\$state\.run') 'inject resolves state.run only'
Assert-True ($injectSource -notmatch '(?m)^\s*\[ValidateSet\(''baseline''') 'inject script has no baseline Role parameter'
Assert-True ($injectSource -match '\$runPath/\$relativeDest') 'destination is built from run path plus relative dest'
Assert-True ($injectSource -match '\.cursor/rules/') 'destination is release-root .cursor/rules'
Assert-True ($injectSource -match 'relativeDest -notmatch') 'destination outside .cursor/rules is refused'
Assert-True ($injectSource -match '--exec') 'git/copy uses wsl --exec'
Assert-True ($injectSource -notmatch 'stamp|transcript|MEASUREMENT|obeyed|loaded') 'inject has no measurement/observation code'
Assert-True ($injectSource -notmatch 'Write-ReleaseStateAtomic|release-state\.json') 'inject does not write release-state.json'

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-inject-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $emptyRunState = Join-Path $temporaryRoot 'empty-run.json'
    New-InjectFixtureState -Destination $emptyRunState -Run $null
    Assert-ThrowsLike {
        & $injectScript -Experiment 'gui-verify' -Variant 'v1' -ConfigPath $exampleConfig -StatePath $emptyRunState
    } 'no run' 'missing state.run is refused'

    $runStatePath = Join-Path $temporaryRoot 'with-run.json'
    New-InjectFixtureState -Destination $runStatePath -Run ([ordered]@{
        name = $runName
        instance = 'candidate'
        path = $runPath
        gitRef = 'run/fixture-inject'
    })
    $startHash = (Get-FileHash -LiteralPath $runStatePath -Algorithm SHA256).Hash

    Assert-ThrowsLike {
        & $injectScript -Experiment '..' -Variant 'v1' -ConfigPath $exampleConfig -StatePath $runStatePath
    } 'canonical identifier' 'experiment path escape is refused'
    Assert-ThrowsLike {
        & $injectScript -Experiment 'gui-verify' -Variant '..' -ConfigPath $exampleConfig -StatePath $runStatePath
    } 'canonical identifier' 'variant path escape is refused'
    Assert-ThrowsLike {
        & $injectScript -Experiment 'missing-exp' -Variant 'v1' -ConfigPath $exampleConfig -StatePath $runStatePath
    } 'does not exist' 'missing variant source is refused'
    Assert-Equal (Get-FileHash -LiteralPath $runStatePath -Algorithm SHA256).Hash $startHash 'refusals leave fixture state unchanged'

    $missingArgsJson = (& $invokePath -Stage inject -Variant 'v1' -ConfigPath $exampleConfig -StatePath $emptyRunState) | Out-String
    $missingArgs = $missingArgsJson | ConvertFrom-Json
    Assert-True (-not [bool]$missingArgs.ok) 'facade inject without -Experiment returns ok:false'
    Assert-True ([string]$missingArgs.message -match 'Experiment and -Variant') 'facade refuses inject without -Experiment'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

$liveConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$liveStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$liveConfigHash = (Get-FileHash -LiteralPath $liveConfigPath -Algorithm SHA256).Hash
$liveStateHash = (Get-FileHash -LiteralPath $liveStatePath -Algorithm SHA256).Hash
$live = Read-EnvironmentConfig -ConfigPath $liveConfigPath
$candidateLive = Get-ConfiguredInstance -Configuration $live -Name candidate
$stableLive = Get-ConfiguredInstance -Configuration $live -Name stable
$distro = [string]$candidateLive.wslDistro
$user = [string]$candidateLive.wslUser
if ($distro -match '^<.*>$' -or $user -match '^<.*>$') {
    throw 'Live inject fixture needs a real WSL distro/user; example placeholders are not enough.'
}

$fixtureId = [guid]::NewGuid().ToString('N')
$fixtureRoot = "/tmp/foundation-inject-fixture-$fixtureId"
$baselineRoot = "$fixtureRoot/fixture-baseline"
$runRoot = "$fixtureRoot/fixture-run"
$windowsFixture = Join-Path $env:TEMP "foundation-inject-fixture-$fixtureId"
New-Item -ItemType Directory -Force -Path $windowsFixture | Out-Null
$setupScript = Join-Path $windowsFixture 'setup.sh'
$setupBody = (@'
set -euo pipefail
root="$1"
mkdir -p "$root/.cursor/rules"
git -C "$root" init -b main
git -C "$root" config user.email 'fixture@example.invalid'
git -C "$root" config user.name 'fixture'
printf 'fixture\n' > "$root/README.md"
git -C "$root" add README.md .cursor
git -C "$root" commit -m 'fixture seed'
'@ -replace "`r`n", "`n")
[System.IO.File]::WriteAllText($setupScript, $setupBody + "`n", [System.Text.UTF8Encoding]::new($false))
$setupWsl = ConvertTo-WslPath -WindowsPath $setupScript

try {
    & wsl.exe -d $distro -u $user --exec bash $setupWsl $runRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to create inject fixture at $runRoot." }

    $fixtureInstances = $live.instances | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $fixtureInstances.stable.releasesRoot = $fixtureRoot
    $fixtureInstances.candidate.releasesRoot = $fixtureRoot
    $fixtureConfigPath = Join-Path $windowsFixture 'environment.json'
    $fixtureStatePath = Join-Path $windowsFixture 'release-state.json'
    $configDoc = [ordered]@{
        schemaVersion = 2
        cursor = $live.cursor
        instances = $fixtureInstances
        controlPlane = $live.controlPlane
        repositoryDiscovery = $live.repositoryDiscovery
        storage = $live.storage
        workspace = $live.workspace
        projects = $live.projects
    }
    ($configDoc | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $fixtureConfigPath -Encoding utf8

    $liveState = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'config\release-state.example.json') | ConvertFrom-Json
    $seed = [ordered]@{
        action = 'seed'
        at = '2026-01-02T00:00:00+00:00'
        release = 'fixture-run'
        commit = ('d' * 40)
    }
    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($liveState.transitionHistory)) { $history.Add($entry) }
    $history.Add($seed)
    $liveState.generation = 1
    $liveState.baseline = [ordered]@{
        name = 'fixture-baseline'
        instance = 'stable'
        path = $baselineRoot
        gitRef = 'main'
    }
    $liveState.run = [ordered]@{
        name = 'fixture-run'
        instance = 'candidate'
        path = $runRoot
        gitRef = 'main'
    }
    $liveState | Add-Member -MemberType NoteProperty -Name transitionHistory -Value $history.ToArray() -Force
    $liveState | Add-Member -MemberType NoteProperty -Name lastTransition -Value $seed -Force
    ($liveState | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $fixtureStatePath -Encoding utf8
    $fixtureStateHash = (Get-FileHash -LiteralPath $fixtureStatePath -Algorithm SHA256).Hash

    & wsl.exe -d $distro -u $user --exec sh -c "printf dirty >> $runRoot/README.md"
    Assert-ThrowsLike {
        & $injectScript -Experiment 'gui-verify' -Variant 'v1' -ConfigPath $fixtureConfigPath -StatePath $fixtureStatePath
    } 'dirty' 'dirty run is refused'
    & wsl.exe -d $distro -u $user --exec git -C $runRoot checkout -- README.md
    if ($LASTEXITCODE -ne 0) { throw 'Failed to restore fixture README after dirty check.' }

    $injected = (& $invokePath -Stage inject -Experiment 'gui-verify' -Variant 'v1' `
        -ConfigPath $fixtureConfigPath -StatePath $fixtureStatePath) | ConvertFrom-Json
    Assert-True ([bool]$injected.ok) 'inject stage ok'
    Assert-Equal $injected.stage 'inject' 'inject stage field'
    Assert-Equal $injected.release 'fixture-run' 'inject release'
    Assert-Equal $injected.experiment 'gui-verify' 'inject experiment'
    Assert-Equal $injected.variant 'v1' 'inject variant'
    Assert-Equal $injected.sourceSha256 $injected.injectedSha256 'destination sha256 matches source'
    Assert-True ([bool]$injected.committed) 'first inject creates a commit'
    Assert-True ([string]$injected.commit -match '^[0-9a-f]{40}$') 'inject commit is a SHA'
    Assert-True ([string]$injected.destination -eq "$runRoot/.cursor/rules/gui-verify-v1.mdc") 'destination is release-root .cursor/rules'
    $subject = (& wsl.exe -d $distro -u $user --exec git -C $runRoot log -1 --format=%s)
    $subjectText = ([string]$subject).Trim()
    Assert-True ($subjectText -eq "experiment-inject-gui-verify-v1-$($injected.sourceSha256)") 'commit message has experiment/variant/source SHA'
    Assert-True ($injected.next -match '-Stage handoff') 'inject next points at handoff'
    Assert-Equal (Get-FileHash -LiteralPath $fixtureStatePath -Algorithm SHA256).Hash $fixtureStateHash 'inject leaves fixture state unchanged'

    $repeat = (& $invokePath -Stage inject -Experiment 'gui-verify' -Variant 'v1' `
        -ConfigPath $fixtureConfigPath -StatePath $fixtureStatePath) | ConvertFrom-Json
    Assert-True ([bool]$repeat.ok) 'idempotent inject ok'
    Assert-True (-not [bool]$repeat.committed) 'identical re-inject does not create a commit'
    Assert-Equal $repeat.commit $injected.commit 'idempotent inject keeps HEAD'
    Assert-Equal $repeat.sourceSha256 $repeat.injectedSha256 'idempotent inject sha256 still matches'

    Assert-Equal (Get-FileHash -LiteralPath $liveConfigPath -Algorithm SHA256).Hash $liveConfigHash 'live config unchanged'
    Assert-Equal (Get-FileHash -LiteralPath $liveStatePath -Algorithm SHA256).Hash $liveStateHash 'live state unchanged'
    Write-Output 'PASS: Test-InjectFoundationVariant.ps1'
} finally {
    & wsl.exe -d $distro -u $user --exec rm -rf $fixtureRoot | Out-Null
    if (Test-Path -LiteralPath $windowsFixture) {
        Remove-Item -LiteralPath $windowsFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
