[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$StatePath
)

# Live, non-mutating check that both WSL homes' ~/local-data resolve to
# storage.localDataRoot and that active/candidate are not in drift.
# Does not write HANDOFF.md, unlink workspace files, or call seed.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib\LocalData.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', got '$Actual'." }
}

$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$configHash = (Get-FileHash -LiteralPath $resolvedConfigPath -Algorithm SHA256).Hash
$stateHash = (Get-FileHash -LiteralPath $resolvedStatePath -Algorithm SHA256).Hash
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$expectedStore = ConvertTo-WslPath -WindowsPath (Resolve-LocalDataRoot -Configuration $config)

foreach ($name in @('stable', 'candidate')) {
    $instance = Get-ConfiguredInstance -Configuration $config -Name $name
    $instanceHome = Assert-AbsolutePosixPath -Path ([string]$instance.wslHome) -Context "Environment config.instances.$name.wslHome"
    $argv = @('-d', [string]$instance.wslDistro, '-u', [string]$instance.wslUser, '--exec', 'readlink', '-f', "$instanceHome/local-data")
    $resolved = (@(& wsl.exe @argv | ForEach-Object { [string]$_ }) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolved)) {
        throw "${name}: ~/local-data did not resolve (exit $LASTEXITCODE)."
    }
    Assert-Equal $resolved $expectedStore "${name}: ~/local-data must be the shared store"
}

$status = (& (Join-Path $PSScriptRoot 'Get-FoundationStatus.ps1') -StatePath $resolvedStatePath -ConfigPath $resolvedConfigPath) | ConvertFrom-Json
foreach ($channel in @('active', 'candidate')) {
    $workspace = $status.workspaces.$channel
    if ($null -eq $workspace) { continue }
    $localData = $workspace.localData
    if ($null -eq $localData) { throw "workspaces.$channel.localData is missing." }
    if ([string]$localData.state -notin @('ok', 'skipped')) {
        throw "workspaces.$channel.localData.state=$($localData.state) $($localData.summary) $($localData.problems -join '; ')"
    }
}

$endConfigHash = (Get-FileHash -LiteralPath $resolvedConfigPath -Algorithm SHA256).Hash
$endStateHash = (Get-FileHash -LiteralPath $resolvedStatePath -Algorithm SHA256).Hash
Assert-Equal $endConfigHash $configHash 'live config hash unchanged'
Assert-Equal $endStateHash $stateHash 'live state hash unchanged'

Write-Output 'PASS: shared local-data store identity and live-channel status'
