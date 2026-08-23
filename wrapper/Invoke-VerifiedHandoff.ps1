[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$ConfigPath,
    [switch]$Execute,
    [ValidateRange(1, 60)]
    [int]$WaitSeconds = 60
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\CursorHandoff.ps1')

function Write-HandoffRejection {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Detail,
        [string[]]$Remediation = @(),
        [string[]]$KillWhen = @(),
        [string[]]$KillCommand = @(),
        [string]$KillConfirm,
        [AllowNull()][object]$Process
    )
    [ordered]@{
        execute = $Execute.IsPresent
        ready = $false
        launchStarted = $false
        running = $false
        verified = $false
        launchVerified = $false
        code = $Code
        detail = $Detail
        pid = if ($Process) { [int]$Process.pid } else { $null }
        title = if ($Process) { [string](Get-OptionalJsonProperty -Object $Process -Name 'title') } else { $null }
        commandLine = if ($Process) { [string](Get-OptionalJsonProperty -Object $Process -Name 'commandLine') } else { $null }
        remediation = @($Remediation)
        killWhen = @($KillWhen)
        killCommand = @($KillCommand)
        killConfirm = $KillConfirm
    } | ConvertTo-Json -Depth 6
}

$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
try { $rawState = Get-Content -Raw -LiteralPath $resolvedStatePath | ConvertFrom-Json } catch {
    Write-HandoffRejection -Code 'invalid-run-state' -Detail $_.Exception.Message -Remediation @('Repair state through the documented wrapper transition; do not edit release-state.json by hand.')
    return
}
$rawSchemaVersion = Get-OptionalJsonProperty -Object $rawState -Name 'schemaVersion'
if ([int]$rawSchemaVersion -ne 3) {
    Write-HandoffRejection -Code 'runtime-model-migration-required' -Detail 'Verified handoff requires release state schema version 3.' -Remediation @('.\Invoke-FoundationRelease.ps1 -Stage migrate-runtime-model -PreviousDisposition <Rollback|Discard>')
    return
}
try {
    $state = Read-ReleaseState -StatePath $resolvedStatePath
    Assert-ReleaseStateRuntimePlacement -State $state -Configuration $config
} catch {
    Write-HandoffRejection -Code 'invalid-run-state' -Detail $_.Exception.Message -Remediation @('Repair state through the documented wrapper transition; do not edit release-state.json by hand.')
    return
}
if ($null -eq $state.run) {
    Write-HandoffRejection -Code 'run-missing' -Detail 'Release state.run is null.' -Remediation @('.\Invoke-FoundationRelease.ps1 -Stage seed   # then -Stage seed -Execute')
    return
}

try { $resolvedTarget = Resolve-VerifiedHandoffTarget -State $state -Configuration $config } catch {
    Write-HandoffRejection -Code 'invalid-run-target' -Detail $_.Exception.Message -Remediation @('Seed or restore the run through the wrapper; handoff never accepts an arbitrary target.')
    return
}
$run = $state.run
$instance = Get-ConfiguredInstance -Configuration $config -Name 'candidate'
$distro = [string]$instance.wslDistro
$user = [string]$instance.wslUser
$path = [string]$run.path
$gitRef = [string]$run.gitRef
$configDirectory = Split-Path -Parent $resolvedConfigPath
$userDataDir = Resolve-ConfiguredPath -Value ([string]$instance.userDataDir) -BasePath $configDirectory

& wsl.exe -d $distro -u $user -- test -d $path
if ($LASTEXITCODE -ne 0) {
    Write-HandoffRejection -Code 'target-missing' -Detail "Subject target does not exist: ${distro}:${path}." -Remediation @('Inspect state.run and seed a new run through the wrapper.')
    return
}
$head = ("$(& wsl.exe -d $distro -u $user -- git -C $path rev-parse HEAD 2>$null)").Trim()
$refCommit = ("$(& wsl.exe -d $distro -u $user -- git -C $path rev-parse $gitRef 2>$null)").Trim()
if ([string]::IsNullOrWhiteSpace($head) -or $head -ne $refCommit) {
    Write-HandoffRejection -Code 'target-gitref-mismatch' -Detail "state.run gitRef '$gitRef' does not resolve to target HEAD." -Remediation @('Restore the pinned run checkout before handoff.')
    return
}
$markerRaw = ("$(& wsl.exe -d $distro -u $user -- cat "$path/FOUNDATION-RELEASE.json" 2>$null)").Trim()
try { $marker = $markerRaw | ConvertFrom-Json } catch { $marker = $null }
$markerRelease = if ($null -eq $marker) { $null } else { [string](Get-OptionalJsonProperty -Object $marker -Name 'release') }
if ($null -eq $marker -or $markerRelease -ne [string]$run.name) {
    Write-HandoffRejection -Code 'target-marker-mismatch' -Detail 'FOUNDATION-RELEASE.json does not identify state.run.' -Remediation @('Do not launch this path; seed or restore the run through the wrapper.')
    return
}
if (-not (Test-CursorUserDataAuthenticated -UserDataDir $userDataDir)) {
    Write-HandoffRejection -Code 'subject-unauthenticated' -Detail 'The subject user-data-dir has no authenticated Cursor session.' -Remediation @('Sign in to the isolated subject profile once, close it cleanly, then re-run handoff.')
    return
}

$inventory = (& (Join-Path $PSScriptRoot 'Get-CursorHandoffInventory.ps1') -Instance candidate -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
$occupancy = Get-HandoffOccupancy -Inventory $inventory -UserDataDir $userDataDir
if ($occupancy.occupied) {
    $detail = if ($occupancy.code -eq 'instance-occupied') { 'The subject user-data-dir already has a Cursor root.' } else { 'The subject WSL already has .cursor-server processes, so a clean handoff cannot be proven.' }
    $plan = Get-HandoffOccupancyRemediation -Inventory $inventory -UserDataDir $userDataDir -Distro $distro -User $user
    Write-HandoffRejection -Code ([string]$occupancy.code) -Detail $detail -Process $occupancy.process `
        -Remediation @($plan.text) -KillWhen @($plan.when) -KillCommand @($plan.commands) -KillConfirm ([string]$plan.confirm)
    return
}

$lockPath = Join-Path $configDirectory 'runtime.lock'
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    Write-HandoffRejection -Code 'runtime-lock-missing' -Detail "Expected runtime fingerprint is missing: $lockPath" -Remediation @(".\Get-SubjectRuntimeFingerprint.ps1 -Model '<declared-model>' | Set-Content -LiteralPath '$lockPath' -Encoding utf8")
    return
}
try { $expectedFingerprint = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json } catch {
    Write-HandoffRejection -Code 'runtime-lock-invalid' -Detail $_.Exception.Message -Remediation @('Regenerate runtime.lock from Get-SubjectRuntimeFingerprint.ps1 and review it before handoff.')
    return
}
$actualFingerprint = Get-SubjectRuntimeFingerprint -Configuration $config -ConfigurationPath $resolvedConfigPath
$fingerprint = Compare-SubjectRuntimeFingerprint -Expected $expectedFingerprint -Actual $actualFingerprint
if (-not $fingerprint.matches) {
    $detail = (@('Subject runtime differs from runtime.lock.') + @($fingerprint.mismatchDetails)) -join "`n"
    $model = [string](Get-OptionalJsonProperty -Object $expectedFingerprint -Name 'model')
    if ([string]::IsNullOrWhiteSpace($model)) { $model = '<declared-model>' }
    Write-HandoffRejection -Code 'runtime-fingerprint-mismatch' -Detail $detail -Remediation @(
        'Accept current runtime as the new pin, or restore the planned subject runtime.'
        'RELOCK_COMMAND does not launch Cursor. Confirm with DryRun. Use -Execute only when you want a new subject window.'
        'RELOCK_COMMAND'
        ".\wrapper\Get-SubjectRuntimeFingerprint.ps1 -Model '$model' | Set-Content -LiteralPath '$lockPath' -Encoding utf8"
        'CONFIRM'
        '.\wrapper\Invoke-FoundationRelease.ps1 -Stage handoff'
    )
    return
}

$target = [ordered]@{
    release = [string]$run.name
    instance = 'candidate'
    path = $path
    gitRef = $gitRef
    commit = $head
    remoteAuthority = "wsl+$distro"
    userDataDir = $userDataDir
}
if (-not $Execute) {
    [ordered]@{
        execute = $false
        ready = $true
        launchStarted = $false
        running = $false
        verified = $false
        launchVerified = $false
        code = 'dry-run-ready'
        target = $target
        runtimeFingerprint = $fingerprint
        remediation = @()
        next = 'Preflight passed. Run -Stage handoff -Execute only after you confirm you want a new subject window.'
    } | ConvertTo-Json -Depth 6
    return
}

$launch = (& (Join-Path $PSScriptRoot 'cursor-instance.ps1') `
    -Instance candidate `
    -Path $path `
    -Kind wsl `
    -GitRef $gitRef `
    -VerifiedHandoff `
    -RemoteWaitSeconds $WaitSeconds `
    -ConfigPath $resolvedConfigPath `
    -StatePath $resolvedStatePath) | ConvertFrom-Json
[ordered]@{
    execute = $true
    ready = $true
    launchStarted = [bool]$launch.processStarted
    running = [bool]$launch.running
    verified = [bool]$launch.verified
    launchVerified = [bool]$launch.launchVerified
    code = [string]$launch.code
    target = $target
    startedPid = [int]$launch.startedPid
    rootPid = $launch.rootPid
    rootCommandLine = $launch.rootCommandLine
    windowPid = $launch.windowPid
    windowTitle = $launch.windowTitle
    runtimeFingerprint = $fingerprint
    remediation = @($launch.remediation)
} | ConvertTo-Json -Depth 6
