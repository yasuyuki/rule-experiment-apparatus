[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$ExpectedGeneration = -1,
    [switch]$AllowSameCommit,
    [string]$BackupRoot,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\WorkspaceBackup.ps1')
$StatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$ConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $ConfigPath
$BackupRoot = Resolve-BackupRoot -BackupRoot $BackupRoot -Configuration $config -ConfigurationPath $ConfigPath -BasePath (Get-ConfigurationWorkspaceRoot)
$lock = Enter-ReleaseStateLock -StatePath $StatePath -DryRun:$DryRun

function Invoke-JsonFile {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Arguments)
    $text = & (Join-Path $PSScriptRoot $Name) @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed." }
    return ($text | ConvertFrom-Json)
}

function Add-Transition {
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Transition)
    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($State.transitionHistory)) { $history.Add($entry) }
    $history.Add($Transition)
    $State | Add-Member -MemberType NoteProperty -Name transitionHistory -Value $history.ToArray() -Force
    $State | Add-Member -MemberType NoteProperty -Name lastTransition -Value $Transition -Force
}

try {
    $state = Read-ReleaseState -StatePath $StatePath
    Assert-ReleaseStateRuntimePlacement -State $state -Configuration $config
    Assert-ReleaseStateGeneration -State $state -ExpectedGeneration $ExpectedGeneration | Out-Null
    if (-not $state.run) { throw 'No run is available for promotion.' }

    $acceptance = Invoke-JsonFile -Name 'Test-FoundationRelease.ps1' -Arguments @{
        Role = 'run'; StatePath = $StatePath; ConfigPath = $ConfigPath
    }
    if (-not $acceptance.accepted) { throw 'Run acceptance did not pass.' }

    $baselineAcceptance = Invoke-JsonFile -Name 'Test-FoundationRelease.ps1' -Arguments @{
        Role = 'baseline'; StatePath = $StatePath; ConfigPath = $ConfigPath
    }
    if (-not $DryRun -and -not $AllowSameCommit -and [string]$baselineAcceptance.commit -eq [string]$acceptance.commit) {
        throw "Run commit equals baseline commit ($($acceptance.commit)). Refusing no-op promotion."
    }

    $stable = Get-ConfiguredInstance -Configuration $config -Name 'stable'
    $stableRoot = Get-ConfiguredReleasesRoot -Instance $stable -InstanceName 'stable'
    if ([string]::IsNullOrWhiteSpace($stableRoot)) { throw 'Environment config.instances.stable.releasesRoot is required for promotion.' }
    $publishPath = Resolve-DefaultReleaseSeedPath -Instance $stable -Name ([string]$state.run.name) -InstanceName 'stable'
    $stagePath = "$publishPath.stage-$([guid]::NewGuid().ToString('N'))"

    $plan = [ordered]@{
        action = 'promote'
        execute = (-not $DryRun)
        generation = [int]$state.generation
        from = [string]$state.baseline.name
        to = [string]$state.run.name
        acceptedCommit = [string]$acceptance.commit
        targetInstance = 'stable'
        targetPath = $publishPath
        backupRoles = @('baseline', 'run')
    }
    if ($DryRun) { $plan | ConvertTo-Json -Depth 8; return }

    & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- test '!' -e $publishPath
    if ($LASTEXITCODE -ne 0) { throw "Promotion target already exists: $publishPath" }

    $generation = [int]$state.generation
    $baselineBackup = Invoke-JsonFile -Name 'New-FoundationReleaseBackup.ps1' -Arguments @{
        Role = 'baseline'; ExpectedGeneration = $generation; ExpectedCommit = [string]$baselineAcceptance.commit
        Execute = $true; BackupRoot = $BackupRoot; StatePath = $StatePath; ConfigPath = $ConfigPath
    }
    $runBackup = Invoke-JsonFile -Name 'New-FoundationReleaseBackup.ps1' -Arguments @{
        Role = 'run'; ExpectedGeneration = $generation; ExpectedCommit = [string]$acceptance.commit
        Execute = $true; BackupRoot = $BackupRoot; StatePath = $StatePath; ConfigPath = $ConfigPath
    }
    foreach ($backup in @($baselineBackup, $runBackup)) {
        $verified = Invoke-JsonFile -Name 'Test-FoundationRepositoryArchive.ps1' -Arguments @{
            ManifestPath = [string]$backup.manifestPath
            VerificationRoot = (Join-Path $BackupRoot '.foundation-verify')
        }
        if (-not $verified.restoreVerified) { throw "Backup restore verification failed: $($backup.manifestPath)" }
    }

    $published = $false
    try {
        Restore-FoundationWorkspaceBackup -ManifestPath ([string]$runBackup.manifestPath) -RestorePath $stagePath -TargetDistro ([string]$stable.wslDistro) -TargetUser ([string]$stable.wslUser) | Out-Null
        & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- mv $stagePath $publishPath
        if ($LASTEXITCODE -ne 0) { throw "Failed to publish restored run at '$publishPath'." }
        $published = $true

        $oldBaseline = $state.baseline
        $baselineManifest = [System.IO.Path]::GetFullPath([string]$baselineBackup.manifestPath)
        $state.previousBaseline = [ordered]@{
            name = [string]$oldBaseline.name
            gitRef = [string]$oldBaseline.gitRef
            commit = [string]$baselineAcceptance.commit
            backupManifest = Split-Path $baselineManifest -Leaf
            backupSha256 = (Get-FileHash -LiteralPath $baselineManifest -Algorithm SHA256).Hash
        }
        $state.baseline = [ordered]@{
            name = [string]$state.run.name
            instance = 'stable'
            path = $publishPath
            gitRef = [string]$state.run.gitRef
        }
        $state.run = $null
        $state.generation = $generation + 1
        $transition = [ordered]@{
            action = 'promote'
            at = [DateTimeOffset]::Now.ToString('o')
            from = [string]$oldBaseline.name
            to = [string]$state.baseline.name
            commit = [string]$acceptance.commit
        }
        Add-Transition -State $state -Transition $transition
        try {
            Write-ReleaseStateAtomic -StatePath $StatePath -State $state
        } catch {
            throw "Promoted workspace was published at '$publishPath', but release state write failed. The old baseline remains authoritative. $($_.Exception.Message)"
        }
        $state | ConvertTo-Json -Depth 10
    } finally {
        if (-not $published) {
            & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- rm -rf $stagePath 2>$null | Out-Null
        }
    }
} finally {
    Exit-ReleaseStateLock -Lock $lock
}
