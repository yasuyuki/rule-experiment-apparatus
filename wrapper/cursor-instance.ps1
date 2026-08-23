[CmdletBinding(DefaultParameterSetName = 'Project')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('stable', 'candidate')]
    [string]$Instance,

    [Parameter(Position = 0, ParameterSetName = 'Project')]
    [string]$Project = 'home',

    [Parameter(Mandatory, ParameterSetName = 'Path')]
    [string]$Path,

    [Parameter(ParameterSetName = 'Path')]
    [ValidateSet('auto', 'windows', 'wsl')]
    [string]$Kind = 'auto',

    [Parameter(ParameterSetName = 'Path')]
    [string]$GitRef,

    [switch]$DryRun,
    [switch]$ReuseWindow,
    [switch]$AllowUnauthenticated,
    [switch]$VerifiedHandoff,
    [string]$ConfigPath,
    [string]$StatePath,
    [ValidateRange(0, 60)]
    [int]$RemoteWaitSeconds = 15
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\CursorHandoff.ps1')
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$configDirectory = Split-Path -Parent $resolvedConfigPath
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$instanceConfig = Get-ConfiguredInstance -Configuration $config -Name $Instance

if (-not $instanceConfig) {
    throw "Unknown Cursor instance: $Instance"
}

$target = if ($PSCmdlet.ParameterSetName -eq 'Path') {
    $resolvedKind = $Kind
    if ($resolvedKind -eq 'auto') {
        $resolvedKind = if ($Path.StartsWith('/')) { 'wsl' } else { 'windows' }
    }
    [pscustomobject]@{ kind = $resolvedKind; path = $Path; gitRef = $GitRef }
} else {
    $projects = Get-JsonProperty -Object $config -Name 'projects' -DocumentName 'Environment config'
    $projectProperty = $projects.PSObject.Properties[$Project]
    $projectConfig = if ($null -eq $projectProperty) { $null } else { $projectProperty.Value }
    if (-not $projectConfig) {
        $known = @($projects.psobject.Properties.Name) -join ', '
        throw "Unknown project '$Project'. Known projects: $known"
    }
    $projectTarget = $projectConfig.$Instance
    if (-not $projectTarget) {
        throw "Project '$Project' has no '$Instance' target."
    }
    $projectTarget
}

$cursor = Get-JsonProperty -Object $config -Name 'cursor' -DocumentName 'Environment config'
$cursorExe = Resolve-ConfiguredPath -Value ([string](Get-JsonProperty -Object $cursor -Name 'executable' -DocumentName 'Environment config.cursor')) -BasePath $configDirectory
if (-not $DryRun -and -not (Test-Path -LiteralPath $cursorExe -PathType Leaf)) {
    throw "Cursor executable not found: $cursorExe"
}

if ($instanceConfig.userProfile) {
    $instanceUserProfile = Resolve-ConfiguredPath -Value ([string]$instanceConfig.userProfile) -BasePath $configDirectory
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $instanceUserProfile | Out-Null
        # Electron/Cursor exits immediately if USERPROFILE lacks AppData\Roaming.
        New-Item -ItemType Directory -Force -Path (Join-Path $instanceUserProfile 'AppData\Roaming') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $instanceUserProfile 'AppData\Local') | Out-Null
    }
} else {
    $instanceUserProfile = $null
}
if ($instanceConfig.userDataDir) {
    $instanceUserDataDir = Resolve-ConfiguredPath -Value ([string]$instanceConfig.userDataDir) -BasePath $configDirectory
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $instanceUserDataDir | Out-Null }
} else {
    $instanceUserDataDir = $null
}

$authenticated = if ($instanceUserDataDir) {
    Test-CursorUserDataAuthenticated -UserDataDir $instanceUserDataDir
} else {
    $null
}
if ($instanceUserDataDir -and -not $DryRun -and -not $AllowUnauthenticated -and -not $authenticated) {
    throw "Cursor instance '$Instance' has no authenticated session in user-data-dir '$instanceUserDataDir'. No process was started. Sign in once with -AllowUnauthenticated, then launch normally. Stable credentials are not copied into the isolated profile."
}
if ($instanceConfig.extensionsDir) {
    $instanceExtensionsDir = Resolve-ConfiguredPath -Value ([string]$instanceConfig.extensionsDir) -BasePath $configDirectory
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $instanceExtensionsDir | Out-Null }
} else {
    $instanceExtensionsDir = $null
}

# Project targets in environment.json have kind/path only. Channel launches add
# gitRef via the Path parameter set. Read it optionally so StrictMode sessions
# (protect → Test-Wrappers → cursor-stable) do not throw PropertyNotFound.
$targetGitRef = [string](Get-OptionalJsonProperty -Object $target -Name 'gitRef')
$resolvedCommit = $null
$currentBranch = $null
$isDirty = $null

$arguments = [System.Collections.Generic.List[string]]::new()
$resolvedTargetPath = $null
if (-not $ReuseWindow) {
    $arguments.Add('--new-window')
}
if ($instanceUserDataDir) {
    $arguments.Add('--user-data-dir')
    $arguments.Add($instanceUserDataDir)
}
if ($instanceExtensionsDir) {
    $arguments.Add('--extensions-dir')
    $arguments.Add($instanceExtensionsDir)
}

switch ([string]$target.kind) {
    'windows' {
        $targetBasePath = if ($PSCmdlet.ParameterSetName -eq 'Project') { $configDirectory } else { (Get-Location).Path }
        $windowsPath = Resolve-ConfiguredPath -Value ([string]$target.path) -BasePath $targetBasePath
        if (-not (Test-Path -LiteralPath $windowsPath)) {
            throw "Windows target does not exist: $windowsPath"
        }
        $resolvedTargetPath = $windowsPath
        $arguments.Add($windowsPath)
    }
    'wsl' {
        $distro = [string]$instanceConfig.wslDistro
        $wslUser = [string]$instanceConfig.wslUser
        $wslHome = [string]$instanceConfig.wslHome
        if (-not $distro -or -not $wslUser -or -not $wslHome) {
            throw "Instance '$Instance' requires wslDistro, wslUser, and wslHome for a WSL target."
        }

        $requiredCommands = @('test', 'pgrep')
        if (-not [string]::IsNullOrWhiteSpace($targetGitRef)) { $requiredCommands += 'git' }
        $wslCapability = Test-WslSubjectCapability -Distro $distro -User $wslUser -SubjectHome $wslHome -RequiredCommands $requiredCommands

        $wslPath = [string]$target.path
        $resolvedTargetPath = $wslPath
        $targetExists = Invoke-WslSubjectCommand -Distro $distro -User $wslUser -SubjectHome $wslHome -Command @('test', '-e', $wslPath)
        if ($targetExists.exitCode -ne 0) {
            throw "WSL target does not exist: ${distro}:${wslPath} (user $wslUser)"
        }

        if (-not [string]::IsNullOrWhiteSpace($targetGitRef)) {
            $gitRepository = Invoke-WslSubjectCommand -Distro $distro -User $wslUser -SubjectHome $wslHome -Command @('git', '-C', $wslPath, 'rev-parse', '--is-inside-work-tree')
            if ($gitRepository.exitCode -ne 0) {
                throw "Configured Git target is not a repository: ${distro}:${wslPath}"
            }

            $resolvedCommit = (@(Invoke-WslSubjectCommand -Distro $distro -User $wslUser -SubjectHome $wslHome -Command @('git', '-C', $wslPath, 'rev-parse', 'HEAD')).output -join '').Trim()
            $expected = Invoke-WslSubjectCommand -Distro $distro -User $wslUser -SubjectHome $wslHome -Command @('git', '-C', $wslPath, 'rev-parse', $targetGitRef)
            $expectedCommit = (@($expected.output) -join '').Trim()
            if ($expected.exitCode -ne 0 -or $resolvedCommit -ne $expectedCommit) {
                throw "Git pin mismatch for '$Project' ($Instance): HEAD=$resolvedCommit, ref=$targetGitRef, expected=$expectedCommit"
            }
            $currentBranch = (@(Invoke-WslSubjectCommand -Distro $distro -User $wslUser -SubjectHome $wslHome -Command @('git', '-C', $wslPath, 'branch', '--show-current')).output -join '').Trim()
            $dirtyLines = @(Invoke-WslSubjectCommand -Distro $distro -User $wslUser -SubjectHome $wslHome -Command @('git', '-C', $wslPath, 'status', '--short')).output
            $isDirty = $dirtyLines.Count -gt 0
        }

        # Cursor 3 Agents/Glass windows do not reliably activate Remote WSL.
        # Force the Editor/classic layout for every WSL launch.
        $arguments.Add('--classic')
        $arguments.Add('--remote')
        $arguments.Add("wsl+$distro")
        $arguments.Add($wslPath)
    }
    'ssh' {
        $authority = [string](Get-JsonProperty -Object $target -Name 'authority' -DocumentName "Cursor target '$Project'")
        $expectedUser = [string](Get-JsonProperty -Object $target -Name 'expectedUser' -DocumentName "Cursor target '$Project'")
        $remoteWorkspace = [string]$target.path
        $resolvedTargetPath = $remoteWorkspace

        if (-not $DryRun) {
            $identity = @(& ssh.exe -o BatchMode=yes -- $authority id -un 2>$null)
            if ($LASTEXITCODE -ne 0 -or (@($identity) -join '').Trim() -ne $expectedUser) {
                throw "SSH target identity does not match expected user '$expectedUser' for authority '$authority'."
            }
            $repository = @(& ssh.exe -o BatchMode=yes -- $authority git -C $remoteWorkspace rev-parse --is-inside-work-tree 2>$null)
            if ($LASTEXITCODE -ne 0 -or (@($repository) -join '').Trim() -ne 'true') {
                throw "SSH target is not a Git checkout: $remoteWorkspace"
            }
        }

        $arguments.Add('--remote')
        $arguments.Add("ssh-remote+$authority")
        $arguments.Add($remoteWorkspace)
    }
    default {
        throw "Unsupported target kind: $($target.kind)"
    }
}

$launch = [ordered]@{
    instance = $Instance
    cursorExe = $cursorExe
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    userProfile = if ($instanceUserProfile) { $instanceUserProfile } else { '<inherited>' }
    userDataDir = if ($instanceUserDataDir) { $instanceUserDataDir } else { '<default>' }
    authenticated = if ($null -eq $authenticated) { '<inherited>' } else { $authenticated }
    extensionsDir = if ($instanceExtensionsDir) { $instanceExtensionsDir } else { '<default>' }
    targetKind = [string]$target.kind
    targetPath = $resolvedTargetPath
    wslDistro = if ($target.kind -eq 'wsl') { [string]$instanceConfig.wslDistro } else { $null }
    wslUser = if ($target.kind -eq 'wsl') { [string]$instanceConfig.wslUser } else { $null }
    wslCapability = if ($target.kind -eq 'wsl') { $wslCapability } else { $null }
    sshAuthority = if ($target.kind -eq 'ssh') { $authority } else { $null }
    expectedUser = if ($target.kind -eq 'ssh') { $expectedUser } else { $null }
    gitRef = if (-not [string]::IsNullOrWhiteSpace($targetGitRef)) { $targetGitRef } else { $null }
    resolvedCommit = $resolvedCommit
    currentBranch = $currentBranch
    isDirty = $isDirty
    remoteWaitSeconds = if ($target.kind -eq 'wsl') { $RemoteWaitSeconds } else { 0 }
    arguments = @($arguments)
    processStarted = $false
    launchVerified = $false
}

if ($DryRun) {
    $launch | ConvertTo-Json -Depth 4
    return
}

$beforeInventory = $null
if ($VerifiedHandoff) {
    if ($Instance -ne 'candidate' -or $target.kind -ne 'wsl' -or $ReuseWindow) {
        throw 'Verified handoff requires candidate, a WSL target, and a new window.'
    }
    if (-not $instanceUserDataDir) { throw 'Verified handoff requires a dedicated user-data-dir.' }
    $beforeInventory = (& (Join-Path $PSScriptRoot 'Get-CursorHandoffInventory.ps1') -Instance candidate -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
    $occupiedRoots = @($beforeInventory.roots | Where-Object {
        Test-HandoffCommandLineValue -CommandLine ([string]$_.commandLine) -Value $instanceUserDataDir
    })
    if ($occupiedRoots.Count -gt 0) { throw "instance-occupied: subject user-data-dir already has a Cursor root (PID $($occupiedRoots[0].pid))." }
    if (@($beforeInventory.remote).Count -gt 0) { throw "remote-occupied: subject WSL already has .cursor-server processes." }
}

$originalUserProfile = $env:USERPROFILE
$started = $null
try {
    if ($instanceUserProfile) {
        $env:USERPROFILE = $instanceUserProfile
    }
    $started = Start-Process -FilePath $cursorExe -ArgumentList @($arguments) -WindowStyle Normal -PassThru
} finally {
    $env:USERPROFILE = $originalUserProfile
}
$launch['startedPid'] = [int]$started.Id
$launch['processStarted'] = $true

if ($VerifiedHandoff) {
    $assessment = $null
    $authority = "wsl+$distro"
    $stableVerifiedRootPid = $null
    for ($attempt = 0; $attempt -lt [Math]::Max(1, $RemoteWaitSeconds); $attempt++) {
        $afterInventory = (& (Join-Path $PSScriptRoot 'Get-CursorHandoffInventory.ps1') -Instance candidate -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
        $assessment = Get-VerifiedHandoffAssessment `
            -Before $beforeInventory `
            -After $afterInventory `
            -UserDataDir $instanceUserDataDir `
            -RemoteAuthority $authority `
            -TargetPath $wslPath
        if ($assessment.launchVerified) {
            if ($stableVerifiedRootPid -eq $assessment.rootPid) { break }
            $stableVerifiedRootPid = $assessment.rootPid
            $assessment['verified'] = $false
            $assessment['launchVerified'] = $false
            $assessment['code'] = 'launch-stabilizing'
        } else {
            $stableVerifiedRootPid = $null
        }
        if ($attempt + 1 -lt [Math]::Max(1, $RemoteWaitSeconds)) { Start-Sleep -Seconds 1 }
    }
    foreach ($key in $assessment.Keys) { $launch[$key] = $assessment[$key] }
    $launch | ConvertTo-Json -Depth 6
    return
}

function Test-LaunchedCursorAlive {
    if ($null -eq $started) { return $false }
    $started.Refresh()
    if (-not $started.HasExited) { return $true }
    if (-not $instanceUserDataDir) { return $false }
    $roots = @(Get-CimInstance Win32_Process -Filter "Name = 'Cursor.exe'" | Where-Object {
        $_.CommandLine -like "*$instanceUserDataDir*" -and $_.CommandLine -notmatch '--type='
    })
    return $roots.Count -gt 0
}

Start-Sleep -Seconds 2
if (-not (Test-LaunchedCursorAlive)) {
    $exitCode = if ($null -ne $started -and $started.HasExited) { $started.ExitCode } else { 'unknown' }
    throw "Cursor process exited immediately after Start-Process (exit=$exitCode). userDataDir=$($launch.userDataDir); userProfile=$($launch.userProfile). If userProfile is set, ensure AppData\Roaming exists under it."
}
$launch['cursorPid'] = [int]$started.Id
$launch['cursorAlive'] = $true

if ($target.kind -eq 'wsl' -and $RemoteWaitSeconds -gt 0) {
    $remoteReady = $false
    for ($attempt = 0; $attempt -lt $RemoteWaitSeconds; $attempt++) {
        if (-not (Test-LaunchedCursorAlive)) {
            $exitCode = if ($null -ne $started -and $started.HasExited) { $started.ExitCode } else { 'unknown' }
            throw "Cursor process died while waiting for Remote WSL (exit=$exitCode) (${distro}:${wslPath})."
        }
        if (@(Get-WslCursorServerProcesses -Distro $distro -User $wslUser -SubjectHome $wslHome).Count -gt 0) {
            $remoteReady = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    $launch['remoteReady'] = $remoteReady
    if (-not $remoteReady) {
        throw "Cursor is running, but Remote WSL did not become ready within $RemoteWaitSeconds seconds (${distro}:${wslPath})."
    }
}

$launch | ConvertTo-Json -Depth 4
