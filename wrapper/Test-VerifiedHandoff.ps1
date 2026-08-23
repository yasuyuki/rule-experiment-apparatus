[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\CursorHandoff.ps1')

function Assert-True([bool]$Value, [string]$Label) {
    if (-not $Value) { throw "ASSERT FAIL: $Label" }
}
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', got '$Actual'." }
}
function Assert-ThrowsLike([scriptblock]$Action, [string]$Pattern, [string]$Label) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw "$Label expected '$Pattern', got '$($_.Exception.Message)'."
    }
    throw "$Label expected an exception."
}

$invoke = Get-Command (Join-Path $PSScriptRoot 'Invoke-FoundationRelease.ps1')
$stageValues = @($invoke.Parameters['Stage'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues })
Assert-True ($stageValues -contains 'handoff') 'handoff stage is public'
Assert-True ($stageValues -contains 'inject') 'inject stage is public'
Assert-True (-not $invoke.Parameters.ContainsKey('Path')) 'handoff has no arbitrary Path parameter'
Assert-True (-not $invoke.Parameters.ContainsKey('Kind')) 'handoff has no arbitrary Kind parameter'
Assert-True (-not $invoke.Parameters.ContainsKey('Instance')) 'handoff has no arbitrary Instance parameter'
Assert-True (-not $invoke.Parameters.ContainsKey('Channel')) 'public facade has no Channel parameter'
$handoffSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Invoke-VerifiedHandoff.ps1')
Assert-True ($handoffSource.IndexOf('Get-HandoffOccupancy') -lt $handoffSource.IndexOf("'cursor-instance.ps1'")) 'occupied profile is rejected before process launch'
Assert-True ($handoffSource.IndexOf('Get-HandoffOccupancy') -lt $handoffSource.IndexOf('Compare-SubjectRuntimeFingerprint')) 'occupied profile is rejected before fingerprint'
Assert-True ($handoffSource -match 'FOUNDATION-RELEASE\.json') 'release marker is checked before launch'
if ($handoffSource -notmatch "code = 'dry-run-ready'[\s\S]{0,400}?next = '(?<next>[^']+)'") {
    throw 'dry-run-ready next not found'
}
Assert-True ($Matches['next'] -notmatch '(?i)-Execute\s*$') 'dry-run-ready next is not a copy-pasteable Execute command'
Assert-True ($Matches['next'] -match '(?i)confirm you want a new subject window') 'dry-run-ready next requires confirmation before Execute'
$launcherSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'cursor-instance.ps1')
Assert-True ($launcherSource -match 'stableVerifiedRootPid') 'verified root must persist across inventory polls'

$config = [pscustomobject]@{
    instances = [pscustomobject]@{
        candidate = [pscustomobject]@{
            releasesRoot = '/home/subject/releases'
            wslHome = '/home/subject'
        }
    }
}
$state = [pscustomobject]@{
    baseline = [pscustomobject]@{ path = '/home/baseline/releases/base' }
    run = [pscustomobject]@{
        name = 'run-1'; instance = 'candidate'; path = '/home/subject/releases/run-1'; gitRef = 'run/1'
    }
}
$target = Resolve-VerifiedHandoffTarget -State $state -Configuration $config
Assert-Equal $target.path '/home/subject/releases/run-1' 'state.run is the only target'
$bad = $state | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$bad.run.path = [string]$bad.baseline.path
Assert-ThrowsLike { Resolve-VerifiedHandoffTarget -State $bad -Configuration $config } 'baseline-target' 'baseline path rejected'
$bad = $state | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$bad.run.path = 'C:\fixture\run'
Assert-ThrowsLike { Resolve-VerifiedHandoffTarget -State $bad -Configuration $config } 'invalid-run-path' 'Windows path rejected'
$bad = $state | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$bad.run.path = '/home/subject/releases/stale'
Assert-ThrowsLike { Resolve-VerifiedHandoffTarget -State $bad -Configuration $config } 'outside-release-root' 'stale previous path rejected'
$bad = $state | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$bad.run.instance = 'stable'
Assert-ThrowsLike { Resolve-VerifiedHandoffTarget -State $bad -Configuration $config } 'invalid-run-instance' 'non-candidate run rejected'
$empty = $state | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$empty.run = $null
Assert-ThrowsLike { Resolve-VerifiedHandoffTarget -State $empty -Configuration $config } 'run-missing' 'null run rejected'

$profile = 'C:\fixture\subject\user-data'
$before = [pscustomobject]@{
    roots = @([pscustomobject]@{ pid = 10; commandLine = 'Cursor.exe --user-data-dir C:\other' })
    windows = @([pscustomobject]@{ pid = 10; handle = 100; title = 'controller' })
    remote = @()
}
$occupied = [pscustomobject]@{
    roots = @([pscustomobject]@{ pid = 20; commandLine = "Cursor.exe --user-data-dir $profile" })
    windows = @()
    remote = @()
}
Assert-Equal (Get-HandoffOccupancy -Inventory $occupied -UserDataDir $profile).code 'instance-occupied' 'occupied profile refuses before launch'
$remoteOccupied = [pscustomobject]@{ roots = @(); windows = @(); remote = @([pscustomobject]@{ pid = 22; commandLine = 'server' }) }
$pgrepOnly = @(ConvertTo-WslCursorServerProcesses -PgrepLines @('571 pgrep -a -u ubuntu -f /.cursor-server/'))
Assert-Equal $pgrepOnly.Count 0 'pgrep self-match is not a Cursor server'
$parsedRemote = @(ConvertTo-WslCursorServerProcesses -PgrepLines @(
    '571 pgrep -a -u ubuntu -f /.cursor-server/'
    '770 /home/ubuntu/.cursor-server/bin/node'
))
Assert-Equal $parsedRemote.Count 1 'real .cursor-server survives pgrep filter'
Assert-Equal $parsedRemote[0].pid 770 'real .cursor-server PID is kept'
$subjectProfile = Get-WslSubjectEnvironment -User 'fixture-user' -SubjectHome '/home/fixture-user'
Assert-Equal $subjectProfile.profile 'wsl-subject-path-v1' 'subject profile identifier'
Assert-Equal $subjectProfile.values[3] 'PATH=/home/fixture-user/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' 'subject fixed PATH'
$missingCommandRunner = {
    param($commandArguments)
    if ($commandArguments -contains 'id') { return [ordered]@{ output = @('fixture-user'); exitCode = 0 } }
    if ($commandArguments[-1] -eq 'pgrep') { return [ordered]@{ output = @(); exitCode = 127 } }
    [ordered]@{ output = @('/home/fixture-user'); exitCode = 0 }
}
Assert-ThrowsLike { Test-WslSubjectCapability -Distro 'fixture-distro' -User 'fixture-user' -SubjectHome '/home/fixture-user' -RequiredCommands @('pgrep') -Runner $missingCommandRunner } 'required command .pgrep. is unavailable' 'missing pgrep is capability failure'
$noMatchRunner = {
    param($commandArguments)
    if ($commandArguments -contains 'id') { return [ordered]@{ output = @('fixture-user'); exitCode = 0 } }
    if ($commandArguments -contains '/bin/sh') {
        if ($commandArguments[-1] -eq 'pgrep') { return [ordered]@{ output = @('/usr/bin/pgrep'); exitCode = 0 } }
        return [ordered]@{ output = @('/home/fixture-user'); exitCode = 0 }
    }
    [ordered]@{ output = @(); exitCode = 1 }
}
Assert-Equal @(Get-WslCursorServerProcesses -Distro 'fixture-distro' -User 'fixture-user' -SubjectHome '/home/fixture-user' -Runner $noMatchRunner).Count 0 'pgrep no-match is empty inventory'
Assert-Equal (Get-HandoffOccupancy -Inventory $remoteOccupied -UserDataDir $profile).code 'remote-occupied' 'occupied Remote WSL refuses before launch'
$nestedEmptyRemote = [pscustomobject]@{ roots = @(); windows = @(); remote = @(@()) }
Assert-True (-not (Get-HandoffOccupancy -Inventory $nestedEmptyRemote -UserDataDir $profile).occupied) 'empty nested remote is not occupancy'
$remoteKill = Get-HandoffOccupancyRemediation -Inventory $remoteOccupied -UserDataDir $profile -Distro 'fixture-distro' -User 'fixture-user'
if ($remoteKill.commands -notcontains 'wsl.exe -d fixture-distro -u fixture-user --exec /bin/kill 22') {
    throw 'remote occupancy remediation includes the WSL kill command'
}
if (@($remoteKill.commands | Where-Object { $_ -like 'Stop-Process*' }).Count -ne 0) {
    throw 'remote occupancy remediation must not Stop-Process a controller or unrelated root'
}
$windowsKill = Get-HandoffOccupancyRemediation -Inventory $occupied -UserDataDir $profile -Distro 'fixture-distro' -User 'fixture-user'
if ($windowsKill.commands -notcontains 'Stop-Process -Id 20') {
    throw 'instance occupancy remediation includes Stop-Process for the subject root'
}
$controllerOnly = Get-HandoffOccupancyRemediation -Inventory $before -UserDataDir $profile -Distro 'fixture-distro' -User 'fixture-user'
if (@($controllerOnly.commands | Where-Object { $_ -match 'Stop-Process -Id 10\b' }).Count -ne 0) {
    throw 'occupancy remediation must not kill the controller Cursor PID'
}
$formatted = Format-HandoffFailureException -Result ([pscustomobject]@{
    code = 'remote-occupied'
    detail = 'The subject WSL already has .cursor-server processes.'
    killWhen = $remoteKill.when
    killCommand = $remoteKill.commands
    killConfirm = $remoteKill.confirm
})
if ($formatted -notmatch '(?m)^KILL_WHEN \(all must be true\)$') {
    throw 'failure exception names KILL_WHEN'
}
if ($formatted -notmatch '(?m)^KILL_COMMAND$') {
    throw 'failure exception names KILL_COMMAND'
}
if ($formatted -notmatch '(?m)^wsl\.exe -d fixture-distro -u fixture-user --exec /bin/kill 22$') {
    throw 'failure exception contains the kill command as its own line'
}
if ($formatted -notmatch [regex]::Escape($remoteKill.when[0])) {
    throw 'failure exception contains the first kill-when condition'
}
Assert-Equal (Get-HandoffFailureThrowMessage -Result ([pscustomobject]@{
    code = 'remote-occupied'
    killWhen = $remoteKill.when
    killCommand = $remoteKill.commands
})) 'Live handoff is not ready (remote-occupied). Use KILL_WHEN/KILL_COMMAND printed above.' 'occupied throw points at KILL_COMMAND'
$fingerprintFailure = [pscustomobject]@{
    code = 'runtime-fingerprint-mismatch'
    detail = "Subject runtime differs from runtime.lock.`nextensions.remote: lock=aaa now=bbb"
    remediation = @(
        'Accept current runtime as the new pin, or restore the planned subject runtime.'
        'RELOCK_COMMAND does not launch Cursor. Confirm with DryRun. Use -Execute only when you want a new subject window.'
        'RELOCK_COMMAND'
        ".\wrapper\Get-SubjectRuntimeFingerprint.ps1 -Model 'fixture-model' | Set-Content -LiteralPath 'C:\fixture\runtime.lock' -Encoding utf8"
        'CONFIRM'
        '.\wrapper\Invoke-FoundationRelease.ps1 -Stage handoff'
    )
}
$formattedFingerprint = Format-HandoffFailureException -Result $fingerprintFailure
if ($formattedFingerprint -match 'KILL_WHEN|KILL_COMMAND') {
    throw 'fingerprint failure must not print KILL_WHEN/KILL_COMMAND'
}
if ($formattedFingerprint -notmatch '(?m)^extensions\.remote: lock=aaa now=bbb$') {
    throw 'fingerprint failure prints lock vs now on its own line'
}
if ($formattedFingerprint -notmatch '(?m)^RELOCK_COMMAND$') {
    throw 'fingerprint failure names RELOCK_COMMAND'
}
if ($formattedFingerprint -notmatch [regex]::Escape(".\wrapper\Get-SubjectRuntimeFingerprint.ps1 -Model 'fixture-model' | Set-Content -LiteralPath 'C:\fixture\runtime.lock' -Encoding utf8")) {
    throw 'fingerprint failure contains the relock command'
}
if ($formattedFingerprint -notmatch 'does not launch Cursor') {
    throw 'fingerprint failure says RELOCK does not launch Cursor'
}
if ($formattedFingerprint -notmatch [regex]::Escape('.\wrapper\Invoke-FoundationRelease.ps1 -Stage handoff')) {
    throw 'fingerprint failure confirms with DryRun, not Execute'
}
Assert-Equal (Get-HandoffFailureThrowMessage -Result $fingerprintFailure) 'Live handoff is not ready (runtime-fingerprint-mismatch). Use RELOCK_COMMAND printed above.' 'fingerprint throw points at RELOCK_COMMAND'

# Start-Process PID 999 is intentionally absent. The verified root is PID 21.
$after = [pscustomobject]@{
    roots = @(
        [pscustomobject]@{ pid = 10; commandLine = 'Cursor.exe --user-data-dir C:\other' },
        [pscustomobject]@{ pid = 21; commandLine = "Cursor.exe --user-data-dir $profile --remote wsl+fixture /home/subject/releases/run-1" }
    )
    windows = @(
        [pscustomobject]@{ pid = 10; handle = 100; title = 'controller' },
        [pscustomobject]@{ pid = 21; handle = 200; title = 'run-1 - Cursor' }
    )
    remote = @([pscustomobject]@{ pid = 30; commandLine = '/home/subject/.cursor-server/bin/server' })
}
$verified = Get-VerifiedHandoffAssessment -Before $before -After $after -UserDataDir $profile -RemoteAuthority 'wsl+fixture' -TargetPath '/home/subject/releases/run-1'
Assert-True $verified.launchVerified 'new root/window/remote verifies launch'
Assert-Equal $verified.rootPid 21 'verified root PID replaces ephemeral starter PID'

$absorbed = [pscustomobject]@{
    roots = @($before.roots)
    windows = @($before.windows + [pscustomobject]@{ pid = 10; handle = 201; title = 'wrong reused root' })
    remote = @([pscustomobject]@{ pid = 31; commandLine = 'server' })
}
$notVerified = Get-VerifiedHandoffAssessment -Before $before -After $absorbed -UserDataDir $profile -RemoteAuthority 'wsl+fixture' -TargetPath '/home/subject/releases/run-1'
Assert-True (-not $notVerified.launchVerified) 'existing root cannot absorb and pass handoff'
Assert-True (-not $notVerified.running) 'no new root is not running'

$wrongTarget = $after | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$wrongTarget.roots[1].commandLine = "Cursor.exe --user-data-dir $profile --remote wsl+fixture /home/subject/releases/other"
$timedOut = Get-VerifiedHandoffAssessment -Before $before -After $wrongTarget -UserDataDir $profile -RemoteAuthority 'wsl+fixture' -TargetPath '/home/subject/releases/run-1'
Assert-True $timedOut.running 'cold-start timeout preserves running state'
Assert-True (-not $timedOut.verified) 'cold-start timeout does not claim verified'
$unrelatedWindow = $after | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$unrelatedWindow.windows[1].pid = 999
$unrelated = Get-VerifiedHandoffAssessment -Before $before -After $unrelatedWindow -UserDataDir $profile -RemoteAuthority 'wsl+fixture' -TargetPath '/home/subject/releases/run-1'
Assert-True (-not $unrelated.verified) 'window from an unrelated root cannot verify handoff'

$fingerprint = [pscustomobject]@{
    schemaVersion = 1; instance = 'candidate'; model = 'declared-model'
    profile = [pscustomobject]@{ userProfile = 'p'; userDataDir = 'd'; extensionsDir = 'e' }
    wsl = [pscustomobject]@{ distro = 'w'; user = 'u' }
    cursor = [pscustomobject]@{ path = 'c'; sha256 = 'h'; version = 'v' }
    settings = [pscustomobject]@{ windows = 'a'; remote = 'b' }
    extensions = [pscustomobject]@{ windows = 'c'; remote = 'd' }
    skills = [pscustomobject]@{ windows = 'e'; windowsCursor = 'f'; remote = 'g'; remoteCursor = 'h' }
}
$actualFingerprint = $fingerprint | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$actualFingerprint.PSObject.Properties.Remove('model')
$comparison = Compare-SubjectRuntimeFingerprint -Expected $fingerprint -Actual $actualFingerprint
Assert-True $comparison.matches 'runtime fingerprint exact match'
Assert-True (-not $comparison.model.observed) 'model is declared, not observed'
$actualFingerprint.cursor.version = 'other'
$drift = Compare-SubjectRuntimeFingerprint -Expected $fingerprint -Actual $actualFingerprint
Assert-Equal $drift.mismatches[0] 'cursor.version' 'runtime drift named'
Assert-Equal $drift.mismatchDetails[0] 'cursor.version: lock=v now=other' 'runtime drift names lock vs now'

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-handoff-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $fixturePath = Join-Path $temporaryRoot 'inventory.json'
    $before | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixturePath -Encoding utf8
    $roundTrip = (& (Join-Path $PSScriptRoot 'Get-CursorHandoffInventory.ps1') -FixturePath $fixturePath) | ConvertFrom-Json
    Assert-Equal $roundTrip.roots[0].pid 10 'portable inventory fixture'

    $fixtureConfigPath = Join-Path $temporaryRoot 'environment.json'
    $fixtureStatePath = Join-Path $temporaryRoot 'release-state.json'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config\environment.example.json') -Destination $fixtureConfigPath
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config\release-state.example.json') -Destination $fixtureStatePath
    $originalUserProfile = $env:USERPROFILE
    $env:USERPROFILE = Join-Path $temporaryRoot 'nested-host'
    try {
        $fixtureConfig = Read-EnvironmentConfig -ConfigPath $fixtureConfigPath
        $configDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($fixtureConfigPath))
        $instance = Get-ConfiguredInstance -Configuration $fixtureConfig -Name candidate
        foreach ($field in @('userProfile', 'userDataDir', 'extensionsDir')) {
            $resolved = Resolve-ConfiguredPath -Value ([string]$instance.$field) -BasePath $configDirectory
            if ($resolved -like '*nested-host*') {
                throw "fixture $field expanded process-local USERPROFILE: $resolved"
            }
        }
        $stageJson = (& (Join-Path $PSScriptRoot 'Invoke-FoundationRelease.ps1') -Stage handoff -ConfigPath $fixtureConfigPath -StatePath $fixtureStatePath) -join "`n"
    } finally {
        $env:USERPROFILE = $originalUserProfile
    }
    $stage = $stageJson | ConvertFrom-Json
    if ($null -eq $stage.PSObject.Properties['code']) { throw "public handoff stage returned an unexpected shape: $stageJson" }
    Assert-Equal $stage.code 'run-missing' 'public stage rejects null run without starting a process'
    Assert-True (-not $stage.launchStarted) 'null run starts zero processes'
} finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

Write-Output 'PASS: verified handoff fixtures reject occupied profiles, ephemeral PIDs, and empty/windows/baseline targets'
