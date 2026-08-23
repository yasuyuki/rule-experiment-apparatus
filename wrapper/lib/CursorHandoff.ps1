$ErrorActionPreference = 'Stop'

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-WindowsPathFingerprint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$NamesOnly,
        [switch]$MetadataOnly
    )

    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $root = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $lines = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
        $relative = $_.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
        if ($NamesOnly) { $relative } elseif ($MetadataOnly) { "$relative`t$($_.Length)`t$($_.LastWriteTimeUtc.Ticks)" } else { "$relative`t$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())" }
    } | Sort-Object)
    return Get-TextSha256 -Text ($lines -join "`n")
}

function Get-WslPathFingerprint {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Path,
        [switch]$NamesOnly
    )

    & wsl.exe -d $Distro -u $User -- test -e $Path 2>$null | Out-Null
    if ($LASTEXITCODE -eq 1) { return 'missing' }
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect ${Distro}:${Path} as $User." }

    & wsl.exe -d $Distro -u $User -- test -f $Path 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        if ($NamesOnly) { return Get-TextSha256 -Text ([System.IO.Path]::GetFileName($Path)) }
        $line = ("$(& wsl.exe -d $Distro -u $User -- sha256sum $Path 2>$null)").Trim()
        if ($LASTEXITCODE -ne 0 -or $line -notmatch '^(?<hash>[0-9a-fA-F]{64})\s') {
            throw "Unable to fingerprint ${Distro}:${Path} as $User."
        }
        return $Matches['hash'].ToLowerInvariant()
    }
    if ($LASTEXITCODE -ne 1) { throw "Unable to inspect ${Distro}:${Path} as $User." }

    $format = if ($NamesOnly) { '%P\n' } else { '%P\t%s\t%T@\n' }
    $lines = @(& wsl.exe -d $Distro -u $User -- find $Path -type f -printf $format 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Unable to fingerprint ${Distro}:${Path} as $User." }
    return Get-TextSha256 -Text (@($lines | ForEach-Object { [string]$_ } | Sort-Object) -join "`n")
}

function Get-SubjectRuntimeFingerprint {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    $configDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($ConfigurationPath))
    $instance = Get-ConfiguredInstance -Configuration $Configuration -Name 'candidate'
    foreach ($field in @('userProfile', 'userDataDir', 'extensionsDir')) {
        if ([string]::IsNullOrWhiteSpace([string]$instance.$field)) {
            throw "Subject runtime requires environment.json instances.candidate.$field."
        }
    }
    $userProfile = Resolve-ConfiguredPath -Value ([string]$instance.userProfile) -BasePath $configDirectory
    $userDataDir = Resolve-ConfiguredPath -Value ([string]$instance.userDataDir) -BasePath $configDirectory
    $extensionsDir = Resolve-ConfiguredPath -Value ([string]$instance.extensionsDir) -BasePath $configDirectory
    $cursorConfig = Get-JsonProperty -Object $Configuration -Name 'cursor' -DocumentName 'Environment config'
    $cursorExe = Resolve-ConfiguredPath -Value ([string](Get-JsonProperty -Object $cursorConfig -Name 'executable' -DocumentName 'Environment config.cursor')) -BasePath $configDirectory
    if (-not (Test-Path -LiteralPath $cursorExe -PathType Leaf)) { throw "Cursor executable not found: $cursorExe" }

    $distro = [string]$instance.wslDistro
    $user = [string]$instance.wslUser
    $subjectWslHome = Assert-AbsolutePosixPath -Path ([string]$instance.wslHome) -Context 'Environment config.instances.candidate.wslHome'
    [ordered]@{
        schemaVersion = 1
        instance = 'candidate'
        profile = [ordered]@{
            userProfile = $userProfile
            userDataDir = $userDataDir
            extensionsDir = $extensionsDir
        }
        wsl = [ordered]@{ distro = $distro; user = $user }
        cursor = [ordered]@{
            path = $cursorExe
            sha256 = (Get-FileHash -LiteralPath $cursorExe -Algorithm SHA256).Hash.ToLowerInvariant()
            version = [string][System.Diagnostics.FileVersionInfo]::GetVersionInfo($cursorExe).FileVersion
        }
        settings = [ordered]@{
            windows = Get-WindowsPathFingerprint -Path (Join-Path $userDataDir 'User\settings.json')
            remote = Get-WslPathFingerprint -Distro $distro -User $user -Path "$subjectWslHome/.cursor-server/data/Machine/settings.json"
        }
        extensions = [ordered]@{
            windows = Get-WindowsPathFingerprint -Path $extensionsDir -NamesOnly
            remote = Get-WslPathFingerprint -Distro $distro -User $user -Path "$subjectWslHome/.cursor-server/extensions" -NamesOnly
        }
        skills = [ordered]@{
            windows = Get-WindowsPathFingerprint -Path (Join-Path $userProfile '.cursor\skills') -MetadataOnly
            windowsCursor = Get-WindowsPathFingerprint -Path (Join-Path $userProfile '.cursor\skills-cursor') -MetadataOnly
            remote = Get-WslPathFingerprint -Distro $distro -User $user -Path "$subjectWslHome/.cursor/skills"
            remoteCursor = Get-WslPathFingerprint -Distro $distro -User $user -Path "$subjectWslHome/.cursor/skills-cursor"
        }
    }
}

function Compare-SubjectRuntimeFingerprint {
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][object]$Actual
    )

    function Get-NestedFingerprintValue([object]$Object, [string]$Path) {
        $value = $Object
        foreach ($segment in $Path.Split('.')) {
            if ($null -eq $value) { return $null }
            $value = Get-OptionalJsonProperty -Object $value -Name $segment
        }
        return $value
    }

    $mismatches = [System.Collections.Generic.List[string]]::new()
    $mismatchDetails = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(
        'schemaVersion', 'instance',
        'profile.userProfile', 'profile.userDataDir', 'profile.extensionsDir',
        'wsl.distro', 'wsl.user',
        'cursor.path', 'cursor.sha256', 'cursor.version',
        'settings.windows', 'settings.remote',
        'extensions.windows', 'extensions.remote',
        'skills.windows', 'skills.windowsCursor', 'skills.remote', 'skills.remoteCursor'
    )) {
        $expectedValue = Get-NestedFingerprintValue -Object $Expected -Path $path
        $actualValue = Get-NestedFingerprintValue -Object $Actual -Path $path
        if ([string]$expectedValue -cne [string]$actualValue) {
            $mismatches.Add($path) | Out-Null
            $mismatchDetails.Add("${path}: lock=$expectedValue now=$actualValue") | Out-Null
        }
    }
    $model = [string](Get-OptionalJsonProperty -Object $Expected -Name 'model')
    if ([string]::IsNullOrWhiteSpace($model)) {
        $mismatches.Add('model') | Out-Null
        $mismatchDetails.Add('model: lock is empty') | Out-Null
    }
    [ordered]@{
        matches = ($mismatches.Count -eq 0)
        mismatches = @($mismatches)
        mismatchDetails = @($mismatchDetails)
        model = [ordered]@{ declared = $model; observed = $false }
    }
}

function Test-HandoffCommandLineValue {
    param(
        [AllowNull()][string]$CommandLine,
        [Parameter(Mandatory)][string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $escaped = [regex]::Escape($Value)
    return [regex]::IsMatch($CommandLine, "(?i)(?:^|\s|=)(?:`"$escaped`"|$escaped)(?=\s|$)")
}

function Resolve-VerifiedHandoffTarget {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Configuration
    )

    if ($null -eq $State.run) { throw 'run-missing: Release state.run is null.' }
    $run = $State.run
    if ([string]$run.instance -ne 'candidate') { throw 'invalid-run-instance: Verified handoff only launches state.run on candidate.' }
    $path = [string]$run.path
    if (-not $path.StartsWith('/') -or $path -match '^[A-Za-z]:') { throw 'invalid-run-path: Verified handoff requires an absolute POSIX path.' }
    if ($null -ne $State.baseline -and $path -eq [string]$State.baseline.path) { throw 'baseline-target: Verified handoff cannot launch the baseline path.' }
    $instance = Get-ConfiguredInstance -Configuration $Configuration -Name 'candidate'
    $expectedPath = Resolve-DefaultReleaseSeedPath -Instance $instance -Name ([string]$run.name) -InstanceName 'candidate'
    if ($path -ne $expectedPath) { throw "outside-release-root: state.run.path must be '$expectedPath'." }
    if ([string]::IsNullOrWhiteSpace([string]$run.gitRef)) { throw 'invalid-run-gitref: state.run.gitRef is empty.' }
    return [ordered]@{
        release = [string]$run.name
        instance = 'candidate'
        path = $path
        gitRef = [string]$run.gitRef
    }
}

function ConvertTo-WslCursorServerProcesses {
    param($PgrepLines)

    $remote = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($PgrepLines)) {
        $match = [regex]::Match([string]$line, '^\s*(?<pid>\d+)\s*(?<command>.*)$')
        if (-not $match.Success) { continue }
        $command = [string]$match.Groups['command'].Value
        if ($command -match '(^|/)pgrep(\s|$)') { continue }
        $remote.Add([ordered]@{
            pid = [int]$match.Groups['pid'].Value
            commandLine = $command
        }) | Out-Null
    }
    @($remote.ToArray())
}

function Get-WslSubjectEnvironment {
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$SubjectHome
    )

    [ordered]@{
        profile = 'wsl-subject-path-v1'
        values = @(
            "HOME=$SubjectHome"
            "USER=$User"
            "LOGNAME=$User"
            "PATH=$SubjectHome/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        )
    }
}

function Invoke-WslSubjectCommand {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$SubjectHome,
        [Parameter(Mandatory)][string[]]$Command,
        [scriptblock]$Runner
    )

    $environment = Get-WslSubjectEnvironment -User $User -SubjectHome $SubjectHome
    $arguments = @('-d', $Distro, '-u', $User, '--exec', 'env', '-i') + @($environment.values) + @($Command)
    if ($Runner) { return & $Runner $arguments }
    $output = @(& wsl.exe @arguments 2>$null)
    [ordered]@{ output = @($output | ForEach-Object { [string]$_ }); exitCode = $LASTEXITCODE }
}

function Test-WslSubjectCapability {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$SubjectHome,
        [Parameter(Mandatory)][string[]]$RequiredCommands,
        [scriptblock]$Runner
    )

    $identity = Invoke-WslSubjectCommand -Distro $Distro -User $User -SubjectHome $SubjectHome -Command @('id', '-un') -Runner $Runner
    if ($identity.exitCode -ne 0 -or (@($identity.output) -join '').Trim() -ne $User) {
        throw "WSL subject capability failure: identity does not match '$User' in '$Distro'."
    }
    $actualHome = Invoke-WslSubjectCommand -Distro $Distro -User $User -SubjectHome $SubjectHome -Command @('/bin/sh', '-c', 'printf %s "$HOME"') -Runner $Runner
    if ($actualHome.exitCode -ne 0 -or (@($actualHome.output) -join '').Trim() -ne $SubjectHome) {
        throw "WSL subject capability failure: home does not match configured subject in '$Distro'."
    }
    $resolved = [ordered]@{}
    foreach ($command in @($RequiredCommands | Select-Object -Unique)) {
        $result = Invoke-WslSubjectCommand -Distro $Distro -User $User -SubjectHome $SubjectHome -Command @('/bin/sh', '-c', 'command -v "$1"', 'sh', $command) -Runner $Runner
        $path = (@($result.output) -join '').Trim()
        if ($result.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($path)) {
            throw "WSL subject capability failure: required command '$command' is unavailable in profile wsl-subject-path-v1."
        }
        $resolved[$command] = $path
    }
    [ordered]@{ profile = 'wsl-subject-path-v1'; user = $User; home = $SubjectHome; commands = $resolved }
}

function Get-WslCursorServerProcesses {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$SubjectHome,
        [scriptblock]$Runner
    )

    Test-WslSubjectCapability -Distro $Distro -User $User -SubjectHome $SubjectHome -RequiredCommands @('pgrep') -Runner $Runner | Out-Null
    $result = Invoke-WslSubjectCommand -Distro $Distro -User $User -SubjectHome $SubjectHome -Command @('pgrep', '-a', '-u', $User, '-f', '[.]cursor-server/') -Runner $Runner
    if ($result.exitCode -eq 1) { return @() }
    if ($result.exitCode -ne 0) { throw "Unable to inspect Cursor server processes in $Distro (profile wsl-subject-path-v1)." }
    @(ConvertTo-WslCursorServerProcesses -PgrepLines @($result.output))
}

function Get-HandoffOccupancy {
    param(
        [Parameter(Mandatory)][object]$Inventory,
        [Parameter(Mandatory)][string]$UserDataDir
    )

    $root = @($Inventory.roots | Where-Object {
        Test-HandoffCommandLineValue -CommandLine ([string]$_.commandLine) -Value $UserDataDir
    } | Select-Object -First 1)
    if ($root.Count -gt 0) { return [ordered]@{ occupied = $true; code = 'instance-occupied'; process = $root[0] } }
    $remote = @($Inventory.remote | Where-Object {
        $null -ne (Get-OptionalJsonProperty -Object $_ -Name 'pid')
    } | Select-Object -First 1)
    if ($remote.Count -gt 0) { return [ordered]@{ occupied = $true; code = 'remote-occupied'; process = $remote[0] } }
    return [ordered]@{ occupied = $false; code = $null; process = $null }
}

function Get-HandoffOccupancyRemediation {
    param(
        [Parameter(Mandatory)][object]$Inventory,
        [Parameter(Mandatory)][string]$UserDataDir,
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$User
    )

    $subjectRoots = @($Inventory.roots | Where-Object {
        Test-HandoffCommandLineValue -CommandLine ([string]$_.commandLine) -Value $UserDataDir
    })
    $windowsIds = @($subjectRoots | ForEach-Object { [int]$_.pid })
    $wslIds = @($Inventory.remote | ForEach-Object {
        $processId = Get-OptionalJsonProperty -Object $_ -Name 'pid'
        if ($null -ne $processId -and "$processId" -match '^\d+$') { [int]$processId }
    })
    $when = @(
        'Listed PIDs are subject user-data-dir Cursor roots or leftover candidate WSL .cursor-server processes.'
        'None of the listed PIDs is the controller Cursor (commandLine has no --user-data-dir).'
        'You accept discarding that subject session. If you still need it, do not kill.'
    )
    $commands = [System.Collections.Generic.List[string]]::new()
    if ($windowsIds.Count -gt 0) {
        $commands.Add('Stop-Process -Id ' + ($windowsIds -join ',')) | Out-Null
    }
    if ($wslIds.Count -gt 0) {
        $commands.Add('wsl.exe -d ' + $Distro + ' -u ' + $User + ' --exec /bin/kill ' + ($wslIds -join ' ')) | Out-Null
    }
    $confirm = '.\wrapper\Get-CursorHandoffInventory.ps1 -Instance candidate'
    $text = [System.Collections.Generic.List[string]]::new()
    $text.Add('Kill only if every condition below is true:') | Out-Null
    foreach ($item in $when) { $text.Add("- $item") | Out-Null }
    foreach ($item in $commands) { $text.Add($item) | Out-Null }
    $text.Add("Confirm: $confirm") | Out-Null
    $text.Add('Re-run Execute only when no root commandLine contains the subject user-data-dir and remote is [].') | Out-Null
    [ordered]@{
        when = [string[]]$when
        commands = [string[]]$commands.ToArray()
        confirm = $confirm
        text = [string[]]$text.ToArray()
    }
}

function ConvertTo-HandoffStringArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value)
    }
    @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-HandoffFailureKillPlan {
    param(
        [Parameter(Mandatory)][object]$Result
    )

    $details = Get-OptionalJsonProperty -Object $Result -Name 'details'
    $when = @(ConvertTo-HandoffStringArray (Get-OptionalJsonProperty -Object $Result -Name 'killWhen'))
    if ($when.Count -eq 0 -and $null -ne $details) {
        $when = @(ConvertTo-HandoffStringArray (Get-OptionalJsonProperty -Object $details -Name 'killWhen'))
    }
    $commands = @(ConvertTo-HandoffStringArray (Get-OptionalJsonProperty -Object $Result -Name 'killCommand'))
    if ($commands.Count -eq 0 -and $null -ne $details) {
        $commands = @(ConvertTo-HandoffStringArray (Get-OptionalJsonProperty -Object $details -Name 'killCommand'))
    }
    $confirm = [string](Get-OptionalJsonProperty -Object $Result -Name 'killConfirm')
    if ([string]::IsNullOrWhiteSpace($confirm) -and $null -ne $details) {
        $confirm = [string](Get-OptionalJsonProperty -Object $details -Name 'killConfirm')
    }
    [ordered]@{
        when = @($when)
        commands = @($commands)
        confirm = $confirm
    }
}

function Get-HandoffFailureThrowMessage {
    param(
        [Parameter(Mandatory)][object]$Result
    )

    $code = [string](Get-OptionalJsonProperty -Object $Result -Name 'code')
    $plan = Get-HandoffFailureKillPlan -Result $Result
    if ($plan.when.Count -gt 0 -or $plan.commands.Count -gt 0) {
        return "Live handoff is not ready ($code). Use KILL_WHEN/KILL_COMMAND printed above."
    }
    $remediation = @(ConvertTo-HandoffStringArray (Get-OptionalJsonProperty -Object $Result -Name 'remediation'))
    $details = Get-OptionalJsonProperty -Object $Result -Name 'details'
    if ($remediation.Count -eq 0 -and $null -ne $details) {
        $remediation = @(ConvertTo-HandoffStringArray (Get-OptionalJsonProperty -Object $details -Name 'remediation'))
    }
    if ($remediation -contains 'RELOCK_COMMAND') {
        return "Live handoff is not ready ($code). Use RELOCK_COMMAND printed above."
    }
    return "Live handoff is not ready ($code). See DETAIL printed above."
}

function Format-HandoffFailureException {
    param(
        [Parameter(Mandatory)][object]$Result
    )

    $code = [string](Get-OptionalJsonProperty -Object $Result -Name 'code')
    $detail = [string](Get-OptionalJsonProperty -Object $Result -Name 'detail')
    $details = Get-OptionalJsonProperty -Object $Result -Name 'details'
    if ([string]::IsNullOrWhiteSpace($detail) -and $null -ne $details) {
        $detail = [string](Get-OptionalJsonProperty -Object $details -Name 'detail')
    }
    $plan = Get-HandoffFailureKillPlan -Result $Result
    $when = @($plan.when)
    $commands = @($plan.commands)
    $confirm = [string]$plan.confirm
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("LIVE_HANDOFF_NOT_READY code=$code") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        $lines.Add('DETAIL') | Out-Null
        foreach ($line in @($detail -split "`n")) { $lines.Add($line) | Out-Null }
    }
    if ($when.Count -gt 0 -or $commands.Count -gt 0) {
        $lines.Add('KILL_WHEN (all must be true)') | Out-Null
        foreach ($item in $when) { $lines.Add("- $item") | Out-Null }
        $lines.Add('KILL_COMMAND') | Out-Null
        if ($commands.Count -eq 0) {
            $lines.Add('(none)') | Out-Null
        } else {
            foreach ($item in $commands) { $lines.Add($item) | Out-Null }
        }
        if (-not [string]::IsNullOrWhiteSpace($confirm)) {
            $lines.Add('CONFIRM') | Out-Null
            $lines.Add($confirm) | Out-Null
        }
    } else {
        foreach ($item in @(ConvertTo-HandoffStringArray (Get-OptionalJsonProperty -Object $Result -Name 'remediation'))) {
            if (-not [string]::IsNullOrWhiteSpace($item)) { $lines.Add($item) | Out-Null }
        }
    }
    return ($lines -join "`n")
}

function Get-VerifiedHandoffAssessment {
    param(
        [Parameter(Mandatory)][object]$Before,
        [Parameter(Mandatory)][object]$After,
        [Parameter(Mandatory)][string]$UserDataDir,
        [Parameter(Mandatory)][string]$RemoteAuthority,
        [Parameter(Mandatory)][string]$TargetPath
    )

    $beforeRootIds = @{}; foreach ($item in @($Before.roots)) { $beforeRootIds[[string]$item.pid] = $true }
    $beforeWindowHandles = @{}; foreach ($item in @($Before.windows)) { $beforeWindowHandles[[string]$item.handle] = $true }
    $beforeRemoteIds = @{}; foreach ($item in @($Before.remote)) { $beforeRemoteIds[[string]$item.pid] = $true }
    $newRoots = @($After.roots | Where-Object { -not $beforeRootIds.ContainsKey([string]$_.pid) })
    $matchingRoots = @($newRoots | Where-Object {
        (Test-HandoffCommandLineValue -CommandLine ([string]$_.commandLine) -Value $UserDataDir) -and
        (Test-HandoffCommandLineValue -CommandLine ([string]$_.commandLine) -Value $RemoteAuthority) -and
        (Test-HandoffCommandLineValue -CommandLine ([string]$_.commandLine) -Value $TargetPath)
    })
    $newWindows = @($After.windows | Where-Object { -not $beforeWindowHandles.ContainsKey([string]$_.handle) })
    $matchingRootIds = @{}; foreach ($item in $matchingRoots) { $matchingRootIds[[string]$item.pid] = $true }
    $matchingWindows = @($newWindows | Where-Object { $matchingRootIds.ContainsKey([string]$_.pid) })
    $newRemote = @($After.remote | Where-Object { -not $beforeRemoteIds.ContainsKey([string]$_.pid) })
    $verified = ($matchingRoots.Count -eq 1 -and $matchingWindows.Count -gt 0 -and $newRemote.Count -gt 0)
    $root = if ($matchingRoots.Count -eq 1) { $matchingRoots[0] } else { $null }
    $window = if ($matchingWindows.Count -gt 0) { $matchingWindows[0] } else { $null }
    [ordered]@{
        running = ($newRoots.Count -gt 0)
        verified = $verified
        launchVerified = $verified
        code = if ($verified) { 'launch-verified' } elseif ($newRoots.Count -gt 0) { 'launch-running-unverified' } else { 'launch-not-running' }
        rootPid = if ($root) { [int]$root.pid } else { $null }
        rootCommandLine = if ($root) { [string]$root.commandLine } else { $null }
        windowPid = if ($window) { [int]$window.pid } else { $null }
        windowTitle = if ($window) { [string]$window.title } else { $null }
        newRootCount = $newRoots.Count
        matchingRootCount = $matchingRoots.Count
        newWindowCount = $newWindows.Count
        matchingWindowCount = $matchingWindows.Count
        newRemoteCount = $newRemote.Count
        remediation = if ($verified) { @() } else { @('Close the subject Cursor profile and its Remote WSL server, then run handoff again. Do not kill or foreground processes automatically.') }
    }
}
