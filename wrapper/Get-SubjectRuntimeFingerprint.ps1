[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Model
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\CursorHandoff.ps1')

$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$fingerprint = Get-SubjectRuntimeFingerprint -Configuration $config -ConfigurationPath $resolvedConfigPath
if (-not [string]::IsNullOrWhiteSpace($Model)) { $fingerprint['model'] = $Model }
$fingerprint | ConvertTo-Json -Depth 6
