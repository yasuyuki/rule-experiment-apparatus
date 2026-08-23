[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$ExpectedGeneration = -1,
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

try {
    $state = Read-ReleaseState -StatePath $StatePath
    Assert-ReleaseStateRuntimePlacement -State $state -Configuration $config
    Assert-ReleaseStateGeneration -State $state -ExpectedGeneration $ExpectedGeneration | Out-Null
    if ($state.run) { throw 'Rollback requires an empty run slot.' }
    if (-not $state.previousBaseline) { throw 'No previous baseline is available for rollback.' }

    $stable = Get-ConfiguredInstance -Configuration $config -Name 'stable'
    $stableRoot = Get-ConfiguredReleasesRoot -Instance $stable -InstanceName 'stable'
    if ([string]::IsNullOrWhiteSpace($stableRoot)) { throw 'Environment config.instances.stable.releasesRoot is required for rollback.' }
    $targetPath = Resolve-DefaultReleaseSeedPath -Instance $stable -Name ([string]$state.previousBaseline.name) -InstanceName 'stable'
    if ($targetPath -eq [string]$state.baseline.path) { throw 'Rollback target resolves to the current baseline path.' }
    $manifestPath = Join-Path $BackupRoot ([string]$state.previousBaseline.backupManifest)
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Previous baseline manifest is missing: $manifestPath" }
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    if ($manifestHash -ne [string]$state.previousBaseline.backupSha256) { throw 'Previous baseline manifest SHA-256 mismatch.' }
    $verified = Invoke-JsonFile -Name 'Test-FoundationRepositoryArchive.ps1' -Arguments @{
        ManifestPath = $manifestPath
        VerificationRoot = (Join-Path $BackupRoot '.foundation-verify')
    }
    if (-not $verified.restoreVerified -or [string]$verified.sourceCommit -ne [string]$state.previousBaseline.commit) {
        throw 'Previous baseline backup verification failed.'
    }

    $plan = [ordered]@{
        action = 'rollback'
        execute = (-not $DryRun)
        generation = [int]$state.generation
        from = [string]$state.baseline.name
        to = [string]$state.previousBaseline.name
        commit = [string]$state.previousBaseline.commit
        targetInstance = 'stable'
        targetPath = $targetPath
        sourceBackup = $manifestPath
    }
    if ($DryRun) { $plan | ConvertTo-Json -Depth 8; return }

    $stagePath = "$targetPath.stage-$([guid]::NewGuid().ToString('N'))"
    $quarantinePath = "$targetPath.unreferenced-$([guid]::NewGuid().ToString('N'))"
    $published = $false
    try {
        Restore-FoundationWorkspaceBackup -ManifestPath $manifestPath -RestorePath $stagePath -TargetDistro ([string]$stable.wslDistro) -TargetUser ([string]$stable.wslUser) | Out-Null
        & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- test -e $targetPath
        if ($LASTEXITCODE -eq 0) {
            & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- mv $targetPath $quarantinePath
            if ($LASTEXITCODE -ne 0) { throw "Failed to quarantine unreferenced rollback path '$targetPath'." }
        }
        & wsl.exe -d $stable.wslDistro -u $stable.wslUser -- mv $stagePath $targetPath
        if ($LASTEXITCODE -ne 0) { throw "Failed to publish rollback workspace at '$targetPath'." }
        $published = $true

        $from = [string]$state.baseline.name
        $restored = $state.previousBaseline
        $state.baseline = [ordered]@{
            name = [string]$restored.name
            instance = 'stable'
            path = $targetPath
            gitRef = [string]$restored.gitRef
        }
        $state.previousBaseline = $null
        $state.generation = [int]$state.generation + 1
        $transition = [ordered]@{
            action = 'rollback'
            at = [DateTimeOffset]::Now.ToString('o')
            from = $from
            to = [string]$restored.name
            commit = [string]$restored.commit
        }
        $history = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($state.transitionHistory)) { $history.Add($entry) }
        $history.Add($transition)
        $state | Add-Member -MemberType NoteProperty -Name transitionHistory -Value $history.ToArray() -Force
        $state | Add-Member -MemberType NoteProperty -Name lastTransition -Value $transition -Force
        try {
            Write-ReleaseStateAtomic -StatePath $StatePath -State $state
        } catch {
            throw "Rollback workspace was published at '$targetPath', but release state write failed. The current baseline remains authoritative. $($_.Exception.Message)"
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
