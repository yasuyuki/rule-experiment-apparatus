[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('active', 'candidate')]
    [string]$Channel,
    [switch]$DryRun,
    [switch]$ReuseWindow,
    [switch]$AllowUnauthenticated,
    [string]$ConfigPath,
    [string]$StatePath,
    # Refuse to launch unless the channel's physical instance matches.
    # Prevents equating "stable Cursor" with cursor-current when active is on candidate.
    [ValidateSet('stable', 'candidate')]
    [string]$RequireInstance
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$state = Read-ReleaseState -StatePath $resolvedStatePath
$release = $state.$Channel
if (-not $release) {
    throw "Release channel '$Channel' is empty. Seed a new candidate before launching it."
}

$physicalInstance = [string]$release.instance
$releaseName = [string]$release.name
if ($RequireInstance -and $physicalInstance -ne $RequireInstance) {
    throw @"
Release channel '$Channel' ($releaseName) is on physical instance '$physicalInstance', but -RequireInstance '$RequireInstance' was requested.
Channel names (active / candidate / previous) alternate between physical instances after promote; they are not the same as physical 'stable' / 'candidate'.
If the operator asked for stable Cursor, do not use cursor-current.ps1 unless status shows active [stable]. Check: .\Invoke-FoundationRelease.ps1 -Stage status -Format text
"@.Trim()
}

$forward = @{
    Instance = $physicalInstance
    Path = [string]$release.path
    Kind = 'wsl'
    GitRef = [string]$release.gitRef
    DryRun = $DryRun
    ReuseWindow = $ReuseWindow
    AllowUnauthenticated = $AllowUnauthenticated
    ConfigPath = $ConfigPath
    StatePath = $resolvedStatePath
}
$raw = & (Join-Path $PSScriptRoot 'cursor-instance.ps1') @forward
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$launch = $raw | ConvertFrom-Json
$enriched = [ordered]@{
    channel = $Channel
    releaseName = $releaseName
}
foreach ($property in $launch.PSObject.Properties) {
    $enriched[$property.Name] = $property.Value
}
if ($Channel -eq 'active' -and $physicalInstance -ne 'stable') {
    $enriched['namingNote'] = "active is on physical instance '$physicalInstance' (not 'stable'). 'stable Cursor' means the stable profile/WSL; pass -RequireInstance stable to refuse this launch."
    Write-Warning $enriched['namingNote']
}

$enriched | ConvertTo-Json -Depth 6
exit 0
