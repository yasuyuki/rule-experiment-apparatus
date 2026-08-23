[CmdletBinding()]
param(
    [ValidateSet('portable', 'live', 'all')]
    [string]$Suite = 'portable',
    [string]$ConfigPath,
    [string]$StatePath,
    [string]$ArchiveRoot,
    [switch]$Quick
)

$ErrorActionPreference = 'Stop'

$portable = @(
    'Test-Configuration.ps1'
    'Test-CursorConfiguration.ps1'
    'Test-VerifiedHandoff.ps1'
    'Test-RepositoryBoundary.ps1'
    'Test-ReleaseReview.ps1'
    'Test-DiscardFoundation.ps1'
)
$live = @(
    'Test-Wrappers.ps1'
    'Test-RepositoryDiscovery.ps1'
    'Test-ControlPlaneConfiguration.ps1'
    'Test-LocalDataStore.ps1'
    'Test-WorkspaceRelease.ps1'
    'Test-FoundationTransitions.ps1'
    'Test-FoundationReleaseUx.ps1'
    'Test-InjectFoundationVariant.ps1'
)
# Test-FoundationSystem already runs wrappers and the transition fixture.
$systemCovered = @('Test-Wrappers.ps1', 'Test-FoundationTransitions.ps1')
$names = switch ($Suite) {
    'portable' { $portable }
    'live' { $live }
    'all' { $portable + @($live | Where-Object { $_ -notin $systemCovered }) + @('Test-FoundationSystem.ps1') }
}

$previousConfig = [Environment]::GetEnvironmentVariable('FOUNDATION_CONTROL_CONFIG', 'Process')
$previousState = [Environment]::GetEnvironmentVariable('FOUNDATION_CONTROL_STATE', 'Process')
try {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
        [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_CONFIG', $ConfigPath, 'Process')
    }
    if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = [System.IO.Path]::GetFullPath($StatePath)
        [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_STATE', $StatePath, 'Process')
    }
    if ($Suite -eq 'all' -and [string]::IsNullOrWhiteSpace($ArchiveRoot)) {
        throw '-Suite all requires -ArchiveRoot; archives are private operator data.'
    }

    foreach ($name in $names) {
        $scriptPath = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Test script missing: $scriptPath"
        }
        $command = Get-Command $scriptPath
        $arguments = @{}
        if ($command.Parameters.ContainsKey('ConfigPath') -and -not [string]::IsNullOrWhiteSpace($ConfigPath)) {
            $arguments.ConfigPath = $ConfigPath
        }
        if ($command.Parameters.ContainsKey('StatePath') -and -not [string]::IsNullOrWhiteSpace($StatePath)) {
            $arguments.StatePath = $StatePath
        }
        if ($Quick -and $command.Parameters.ContainsKey('Quick')) {
            $arguments.Quick = $true
        }
        if ($command.Parameters.ContainsKey('ArchiveRoot') -and -not [string]::IsNullOrWhiteSpace($ArchiveRoot)) {
            $arguments.ArchiveRoot = [System.IO.Path]::GetFullPath($ArchiveRoot)
        }
        Write-Output "=== $name ==="
        & $scriptPath @arguments
        Write-Output "PASS: $name"
    }
    Write-Output "PASS: Invoke-FoundationTests.ps1 -Suite $Suite ($($names.Count) scripts)"
} finally {
    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_CONFIG', $previousConfig, 'Process')
    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_STATE', $previousState, 'Process')
}
