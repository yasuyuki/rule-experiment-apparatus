param(
    [switch]$DryRun,
    [switch]$ReuseWindow,
    [switch]$AllowUnauthenticated,
    [string]$ConfigPath,
    [string]$StatePath,
    [ValidateSet('stable', 'candidate')]
    [string]$RequireInstance
)
$forward = @{
    Channel = 'active'
    DryRun = $DryRun
    ReuseWindow = $ReuseWindow
    AllowUnauthenticated = $AllowUnauthenticated
    ConfigPath = $ConfigPath
    StatePath = $StatePath
}
if ($RequireInstance) { $forward.RequireInstance = $RequireInstance }
& (Join-Path $PSScriptRoot 'cursor-channel.ps1') @forward
exit $LASTEXITCODE
