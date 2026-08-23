[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', got '$Actual'." }
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-cursor-fixture-' + [Guid]::NewGuid().ToString('N'))
$originalUserProfile = $env:USERPROFILE
$originalLocation = (Get-Location).Path
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $example = Read-EnvironmentConfig -ConfigPath (Join-Path $PSScriptRoot 'config\environment.example.json')
    $fixtureConfigPath = Join-Path $temporaryRoot 'environment.json'
    $fixtureStatePath = Join-Path $temporaryRoot 'release-state.json'
    $fixtureTarget = Join-Path $temporaryRoot 'project'
    $fixtureProfile = Join-Path $temporaryRoot 'profile'
    $fixtureUserData = Join-Path $temporaryRoot 'user-data'
    $fixtureExtensions = Join-Path $temporaryRoot 'extensions'
    $fixtureCursor = Join-Path $temporaryRoot 'Cursor.exe'
    New-Item -ItemType Directory -Path $fixtureTarget | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config\release-state.example.json') -Destination $fixtureStatePath

    $example.cursor.executable = $fixtureCursor
    $example.instances.candidate.wslDistro = 'fixture-distro'
    $example.instances.candidate.wslUser = 'fixture-user'
    $example.instances.candidate.wslHome = '/home/fixture-user'
    $example.instances.candidate.projectsRoot = '/home/fixture-user/Projects'
    $example.instances.candidate.userProfile = 'profile'
    $example.instances.candidate.userDataDir = 'user-data'
    $example.instances.candidate.extensionsDir = 'extensions'
    $example.projects = [pscustomobject]@{
        fixture = [pscustomobject]@{
            candidate = [pscustomobject]@{ kind = 'windows'; path = 'project' }
        }
        sshFixture = [pscustomobject]@{
            candidate = [pscustomobject]@{ kind = 'ssh'; authority = 'fixture-agent'; path = '/srv/fixture-agent/project'; expectedUser = 'fixture-agent' }
        }
    }
    $example | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fixtureConfigPath -Encoding utf8

    $env:USERPROFILE = Join-Path $temporaryRoot 'host-profile-a'
    $launch = (& (Join-Path $PSScriptRoot 'cursor-instance.ps1') `
        -Instance candidate `
        -Project fixture `
        -ConfigPath $fixtureConfigPath `
        -StatePath $fixtureStatePath `
        -DryRun) | ConvertFrom-Json

    $otherCwd = Join-Path $temporaryRoot 'other-cwd'
    New-Item -ItemType Directory -Path $otherCwd | Out-Null
    $env:USERPROFILE = Join-Path $temporaryRoot 'host-profile-b'
    Set-Location $otherCwd
    $secondLaunch = (& (Join-Path $PSScriptRoot 'cursor-instance.ps1') `
        -Instance candidate `
        -Project fixture `
        -ConfigPath $fixtureConfigPath `
        -StatePath $fixtureStatePath `
        -DryRun) | ConvertFrom-Json

    $sshLaunch = (& (Join-Path $PSScriptRoot 'cursor-instance.ps1') `
        -Instance candidate `
        -Project sshFixture `
        -ConfigPath $fixtureConfigPath `
        -StatePath $fixtureStatePath `
        -DryRun) | ConvertFrom-Json

    Assert-Equal $launch.configPath ([System.IO.Path]::GetFullPath($fixtureConfigPath)) 'fixture.configPath'
    Assert-Equal $launch.statePath ([System.IO.Path]::GetFullPath($fixtureStatePath)) 'fixture.statePath'
    Assert-Equal $launch.cursorExe ([System.IO.Path]::GetFullPath($fixtureCursor)) 'fixture.cursorExe'
    Assert-Equal $launch.targetPath ([System.IO.Path]::GetFullPath($fixtureTarget)) 'fixture.targetPath'
    Assert-Equal $launch.wslDistro $null 'fixture.wslDistro'
    Assert-Equal $launch.userProfile ([System.IO.Path]::GetFullPath($fixtureProfile)) 'fixture.userProfile'
    Assert-Equal $launch.userDataDir ([System.IO.Path]::GetFullPath($fixtureUserData)) 'fixture.userDataDir'
    Assert-Equal $launch.authenticated $false 'fixture.authenticated'
    Assert-Equal $launch.extensionsDir ([System.IO.Path]::GetFullPath($fixtureExtensions)) 'fixture.extensionsDir'
    Assert-Equal $sshLaunch.targetKind 'ssh' 'ssh.targetKind'
    Assert-Equal $sshLaunch.targetPath '/srv/fixture-agent/project' 'ssh.targetPath'
    Assert-Equal $sshLaunch.sshAuthority 'fixture-agent' 'ssh.authority'
    Assert-Equal $sshLaunch.expectedUser 'fixture-agent' 'ssh.expectedUser'
    $expectedSshArguments = @('--new-window', '--user-data-dir', ([System.IO.Path]::GetFullPath($fixtureUserData)), '--extensions-dir', ([System.IO.Path]::GetFullPath($fixtureExtensions)), '--remote', 'ssh-remote+fixture-agent', '/srv/fixture-agent/project') -join ' '
    Assert-Equal ($sshLaunch.arguments -join ' ') $expectedSshArguments 'ssh.arguments'
    foreach ($field in @('cursorExe', 'targetPath', 'userProfile', 'userDataDir', 'extensionsDir')) {
        Assert-Equal $secondLaunch.$field $launch.$field "fixture.host-anchored.$field"
    }
    foreach ($path in @($fixtureProfile, $fixtureUserData, $fixtureExtensions)) {
        if (Test-Path -LiteralPath $path) { throw "DryRun created '$path'." }
    }

    $fixtureStateDirectory = Join-Path $fixtureUserData 'User\globalStorage'
    New-Item -ItemType Directory -Path $fixtureStateDirectory -Force | Out-Null
    $fixtureStatePath = Join-Path $fixtureStateDirectory 'state.vscdb'
    [System.IO.File]::WriteAllText($fixtureStatePath, 'cursorAuth/accessToken cursorAuth/refreshToken')
    if (-not (Test-CursorUserDataAuthenticated -UserDataDir $fixtureUserData)) {
        throw 'fixture authenticated state was not detected.'
    }

    foreach ($invalidTarget in @(
        [pscustomobject]@{ kind = 'ssh'; path = '/srv/fixture-agent/project'; expectedUser = 'fixture-agent' },
        [pscustomobject]@{ kind = 'ssh'; authority = 'bad authority'; path = '/srv/fixture-agent/project'; expectedUser = 'fixture-agent' },
        [pscustomobject]@{ kind = 'ssh'; authority = 'fixture-agent'; path = 'C:\project'; expectedUser = 'fixture-agent' },
        [pscustomobject]@{ kind = 'ssh'; authority = 'fixture-agent'; path = '/srv/fixture-agent/project' }
    )) {
        $example.projects.sshFixture.candidate = $invalidTarget
        $example | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fixtureConfigPath -Encoding utf8
        $threw = $false
        try { Read-EnvironmentConfig -ConfigPath $fixtureConfigPath | Out-Null } catch { $threw = $true }
        if (-not $threw) { throw 'Invalid SSH target was accepted.' }
    }
} finally {
    Set-Location $originalLocation
    $env:USERPROFILE = $originalUserProfile
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Output 'PASS: Cursor DryRun paths are anchored to environment.json'
