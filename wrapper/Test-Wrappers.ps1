param(
    [string]$ConfigPath,
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')

$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$rawState = Get-Content -Raw -LiteralPath $resolvedStatePath | ConvertFrom-Json
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$projects = Get-JsonProperty -Object $config -Name 'projects' -DocumentName 'Environment config'
$sshProject = @($projects.PSObject.Properties | Where-Object {
    $_.Value.PSObject.Properties['candidate'] -and $_.Value.candidate.kind -eq 'ssh'
} | Select-Object -First 1)
if ($sshProject.Count -ne 1) { throw 'Environment config must contain one candidate SSH project for wrapper routing verification.' }
$agentProjectName = [string]$sshProject[0].Name
$agentTarget = $sshProject[0].Value.candidate
$agentLaunch = (& (Join-Path $PSScriptRoot 'cursor-instance.ps1') -Instance candidate -Project $agentProjectName -DryRun -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath) | ConvertFrom-Json
if ($agentLaunch.targetKind -ne 'ssh' -or $agentLaunch.sshAuthority -ne $agentTarget.authority -or $agentLaunch.expectedUser -ne $agentTarget.expectedUser -or $agentLaunch.targetPath -ne $agentTarget.path) {
    throw 'Agent Remote SSH DryRun did not preserve its configured target.'
}
$expectedAuthority = [regex]::Escape("ssh-remote+$($agentTarget.authority)")
if (($agentLaunch.arguments -join ' ') -notmatch "(^| )$expectedAuthority( |$)" -or ($agentLaunch.arguments -join ' ') -match 'wsl\+') {
    throw 'Agent Remote SSH DryRun did not use the explicit SSH authority.'
}
if ([int]$rawState.schemaVersion -eq 2) {
    & (Join-Path $PSScriptRoot 'Test-CursorConfiguration.ps1')
    & (Join-Path $PSScriptRoot 'Test-VerifiedHandoff.ps1')
    Write-Output 'SKIP: live wrapper routing requires the phase-06 schema v3 migration; portable launch/handoff checks passed'
    return
}
$configDirectory = Split-Path -Parent $resolvedConfigPath
$state = Read-ReleaseState -StatePath $resolvedStatePath

function Invoke-DryRun {
    param(
        [Parameter(Mandatory)] [string]$Wrapper,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [string]$StatePath
    )

    $json = & (Join-Path $PSScriptRoot $Wrapper) $Project -DryRun -ConfigPath $ConfigPath -StatePath $StatePath
    $json | ConvertFrom-Json
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        throw "$Label expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param([scriptblock]$Script, [string]$Label)
    $threw = $false
    try {
        & $Script | Out-Null
    } catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "$Label expected an exception."
    }
}

$stableConfig = Get-ConfiguredInstance -Configuration $config -Name 'stable'
$candidateConfig = Get-ConfiguredInstance -Configuration $config -Name 'candidate'
$projects = Get-JsonProperty -Object $config -Name 'projects' -DocumentName 'Environment config'
$sharedWslProject = @($projects.PSObject.Properties | Where-Object {
    $_.Value.stable.kind -eq 'wsl' -and $_.Value.candidate.kind -eq 'wsl'
} | Select-Object -First 1)
if ($sharedWslProject.Count -ne 1) {
    throw 'Environment config.projects must contain a shared WSL project for wrapper smoke testing.'
}
$homeProjectName = [string]$sharedWslProject[0].Name
$windowsProject = @($projects.PSObject.Properties | Where-Object {
    $_.Value.candidate.kind -eq 'windows'
} | Select-Object -First 1)
if ($windowsProject.Count -ne 1) {
    throw 'Environment config.projects must contain a candidate Windows project for wrapper smoke testing.'
}
$windowsProjectName = [string]$windowsProject[0].Name
$windowsProject = $windowsProject[0].Value
$expectedWindowsPath = Resolve-ConfiguredPath -Value ([string](Get-JsonProperty -Object $windowsProject.candidate -Name 'path' -DocumentName "Environment config.projects.$windowsProjectName.candidate")) -BasePath $configDirectory
$expectedStableUserProfile = if ($stableConfig.userProfile) { Resolve-ConfiguredPath -Value ([string]$stableConfig.userProfile) -BasePath $configDirectory } else { '<inherited>' }
$expectedStableUserDataDir = if ($stableConfig.userDataDir) { Resolve-ConfiguredPath -Value ([string]$stableConfig.userDataDir) -BasePath $configDirectory } else { '<default>' }

$stable = Invoke-DryRun -Wrapper 'cursor-stable.ps1' -Project $homeProjectName -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath
$candidate = Invoke-DryRun -Wrapper 'cursor-candidate.ps1' -Project $homeProjectName -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath
$candidateWindows = Invoke-DryRun -Wrapper 'cursor-candidate.ps1' -Project $windowsProjectName -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath

Assert-Equal $stable.instance 'stable' 'stable.instance'
Assert-equal $stable.configPath $resolvedConfigPath 'stable.configPath'
Assert-equal $stable.statePath $resolvedStatePath 'stable.statePath'
Assert-equal $stable.userProfile $expectedStableUserProfile 'stable.userProfile'
Assert-equal $stable.userDataDir $expectedStableUserDataDir 'stable.userDataDir'
Assert-equal $stable.wslDistro $stableConfig.wslDistro 'stable.wslDistro'
Assert-equal $stable.wslUser $stableConfig.wslUser 'stable.wslUser'

Assert-equal $candidate.instance 'candidate' 'candidate.instance'
Assert-equal $candidate.configPath $resolvedConfigPath 'candidate.configPath'
Assert-equal $candidate.statePath $resolvedStatePath 'candidate.statePath'
Assert-equal $candidate.wslDistro $candidateConfig.wslDistro 'candidate.wslDistro'
Assert-equal $candidate.wslUser $candidateConfig.wslUser 'candidate.wslUser'
if ($candidate.userProfile -eq '<inherited>' -or $candidate.userDataDir -eq '<default>') {
    throw 'Candidate must have dedicated userProfile and userDataDir.'
}

Assert-Equal $candidateWindows.targetKind 'windows' 'candidateWindows.targetKind'
Assert-Equal $candidateWindows.targetPath $expectedWindowsPath 'candidateWindows.targetPath'

Assert-Equal $state.baseline.instance 'stable' 'baseline.instance'
if ($state.run) { Assert-Equal $state.run.instance 'candidate' 'run.instance' }

$originalUserProfile = $env:USERPROFILE
$adversaryProfile = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-userprofile-adversary-' + [guid]::NewGuid().ToString('N'))
try {
    $env:USERPROFILE = $adversaryProfile
    $handoffJson = (& (Join-Path $PSScriptRoot 'Invoke-FoundationRelease.ps1') -Stage handoff -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath) -join "`n"
    $handoff = $handoffJson | ConvertFrom-Json
    if ($handoff.launchStarted) { throw "live handoff DryRun started a process: $($handoff.code)" }
    if ($state.run -and $handoff.code -eq 'run-missing') {
        throw 'live handoff DryRun treated a present run as missing'
    }
    $target = Get-OptionalJsonProperty -Object $handoff -Name 'target'
    $targetDir = if ($target) { [string](Get-OptionalJsonProperty -Object $target -Name 'userDataDir') } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($targetDir) -and $targetDir -ne $candidate.userDataDir) {
        throw "live handoff userDataDir '$targetDir' != '$($candidate.userDataDir)'"
    }
    $commandLine = [string](Get-OptionalJsonProperty -Object $handoff -Name 'commandLine')
    if ($handoff.code -eq 'instance-occupied' -and $commandLine -notlike "*$($candidate.userDataDir)*") {
        throw 'instance-occupied commandLine did not use candidate userDataDir'
    }
    if ($handoffJson -match [regex]::Escape($adversaryProfile)) {
        throw 'live handoff DryRun leaked process-local USERPROFILE into output'
    }
    if ($handoffJson -match 'home\\work\\foundation-candidate') {
        throw 'live handoff DryRun nested USERPROFILE into isolation paths'
    }
} finally {
    $env:USERPROFILE = $originalUserProfile
}

Assert-Throws {
    & (Join-Path $PSScriptRoot 'cursor-channel.ps1') -Channel active -DryRun -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath
} 'legacy active channel fails closed'
Assert-Throws {
    & (Join-Path $PSScriptRoot 'cursor-channel.ps1') -Channel candidate -DryRun -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath
} 'legacy candidate channel fails closed'
Assert-Throws {
    & (Join-Path $PSScriptRoot 'cursor-current.ps1') -DryRun -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath
} 'legacy cursor-current fails closed'

Write-Output 'PASS: physical wrapper routing, fixed runtime roles, and legacy channel fail-closed guards'
