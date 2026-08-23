[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [string]$StatePath,

    [string]$BackupRoot,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')

$resolvedConfigPath = Resolve-ExistingPath -Path $ConfigPath -Description 'Environment config'
$resolvedStatePath = Resolve-ExistingPath -Path $StatePath -Description 'Release state'
$resolvedBackupRoot = $null
if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
    $expanded = [Environment]::ExpandEnvironmentVariables($BackupRoot)
    $resolvedBackupRoot = [System.IO.Path]::GetFullPath($expanded)
}

$destination = Get-LocalEnvironmentConfigPath
if ((Test-Path -LiteralPath $destination -PathType Leaf) -and -not $Force) {
    throw "Local config already exists: $destination (pass -Force to overwrite)."
}

$document = [ordered]@{
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
}
if (-not [string]::IsNullOrWhiteSpace($resolvedBackupRoot)) {
    $document['backupRoot'] = $resolvedBackupRoot
}

$directory = Split-Path -Parent $destination
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

($document | ConvertTo-Json) + [Environment]::NewLine | Set-Content -LiteralPath $destination -Encoding utf8

[pscustomobject]@{
    path = $destination
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    backupRoot = $resolvedBackupRoot
} | ConvertTo-Json -Compress
