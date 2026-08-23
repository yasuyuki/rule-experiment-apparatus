[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', got '$Actual'." }
}

$configPath = Resolve-EnvironmentConfigPath
$statePath = Resolve-ReleaseStatePath
$config = Read-EnvironmentConfig -ConfigPath $configPath
$controlPlane = Get-JsonProperty -Object $config -Name 'controlPlane' -DocumentName 'Environment config'
$instanceName = [string](Get-JsonProperty -Object $controlPlane -Name 'gitInstance' -DocumentName 'Environment config.controlPlane')
$instance = Get-ConfiguredInstance -Configuration $config -Name $instanceName
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('private-control-plane-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $newBackup = (& (Join-Path $PSScriptRoot 'New-ControlPlaneBackup.ps1') `
        -ConfigPath $configPath `
        -StatePath $statePath `
        -BackupRoot $temporaryRoot `
        -Execute) | ConvertFrom-Json
    if (-not $newBackup.verified) { throw 'Temporary control-plane backup was not verified.' }

    $verificationRoot = Join-Path $temporaryRoot 'verification'
    $restore = (& (Join-Path $PSScriptRoot 'Test-ControlPlaneBackup.ps1') `
        -ManifestPath $newBackup.manifestPath `
        -ConfigPath $configPath `
        -StatePath $statePath `
        -VerificationRoot $verificationRoot `
        -VerifyRestore) | ConvertFrom-Json
    if (-not $restore.restoreVerified -or -not $restore.temporaryDataDeleted) {
        throw 'Temporary control-plane backup restore was not verified and cleaned up.'
    }

    $manifest = Get-Content -Raw -LiteralPath $newBackup.manifestPath | ConvertFrom-Json
    Assert-Equal $manifest.source.distro $instance.wslDistro 'manifest.source.distro'
    Assert-Equal $manifest.source.user $instance.wslUser 'manifest.source.user'
    Assert-Equal $manifest.source.configPath ([System.IO.Path]::GetFullPath($configPath)) 'manifest.source.configPath'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Output 'PASS: control-plane backup and restore use configured instance and temporary roots'
