[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OffsiteRoot,
    [switch]$Execute,
    [string]$BackupRoot,
    [string]$ConfigPath,
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$backupRootFull = Resolve-BackupRoot -BackupRoot $BackupRoot -Configuration $config -ConfigurationPath $resolvedConfigPath -BasePath (Get-ConfigurationWorkspaceRoot)
$newBackup = Join-Path $PSScriptRoot 'New-ControlPlaneBackup.ps1'
$testBackup = Join-Path $PSScriptRoot 'Test-ControlPlaneBackup.ps1'
$publishBackup = Join-Path $PSScriptRoot 'Publish-VerifiedBackup.ps1'
$plan = (& $newBackup -BackupRoot $backupRootFull -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath) | ConvertFrom-Json
$manifestPath = [string]$plan.manifestPath
$bundlePath = [string]$plan.bundlePath
$manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
$bundleExists = Test-Path -LiteralPath $bundlePath -PathType Leaf
if ($manifestExists -xor $bundleExists) { throw 'Local control-plane backup pair is incomplete.' }

$result = [ordered]@{
    action = 'protect-control-plane-offsite'
    execute = [bool]$Execute
    commit = [string]$plan.commit
    localManifest = $manifestPath
    localBundle = $bundlePath
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    backupRoot = $backupRootFull
    localBackupAlreadyExisted = $manifestExists -and $bundleExists
    offsiteRoot = [System.IO.Path]::GetFullPath($OffsiteRoot)
}
if (-not $Execute) {
    $publishPlan = if ($manifestExists -and $bundleExists) {
        (& $publishBackup -ManifestPath $manifestPath -DestinationRoot $OffsiteRoot) | ConvertFrom-Json
    } else { $null }
    $result['localBackupWillBeCreated'] = -not $manifestExists
    $result['publishPlan'] = $publishPlan
    $result | ConvertTo-Json -Depth 7
    return
}

if (-not $manifestExists) {
    (& $newBackup -BackupRoot $backupRootFull -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath -Execute) | ConvertFrom-Json | Out-Null
}
$localVerification = (& $testBackup -ManifestPath $manifestPath -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath -VerifyRestore) | ConvertFrom-Json
if (-not $localVerification.backupVerified -or -not $localVerification.restoreVerified) {
    throw 'Local control-plane backup verification failed.'
}
$publication = (& $publishBackup -ManifestPath $manifestPath -DestinationRoot $OffsiteRoot -Execute) | ConvertFrom-Json
if (-not $publication.published) { throw 'Off-site publication failed.' }
$offsiteManifest = Join-Path ([System.IO.Path]::GetFullPath($OffsiteRoot)) (Split-Path $manifestPath -Leaf)
$offsiteVerification = (& $testBackup -ManifestPath $offsiteManifest -ConfigPath $resolvedConfigPath -StatePath $resolvedStatePath -VerifyRestore) | ConvertFrom-Json
if (-not $offsiteVerification.backupVerified -or -not $offsiteVerification.restoreVerified) {
    throw 'Off-site control-plane restore verification failed.'
}

$result['localRestoreVerified'] = $true
$result['published'] = $true
$result['alreadyPublished'] = [bool]$publication.alreadyPublished
$result['offsiteManifest'] = $offsiteManifest
$result['offsiteRestoreVerified'] = $true
$result['temporaryDataDeleted'] = [bool]$offsiteVerification.temporaryDataDeleted
$result | ConvertTo-Json -Depth 7
