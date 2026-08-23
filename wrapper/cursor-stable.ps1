[CmdletBinding(DefaultParameterSetName = 'Project')]
param(
    [Parameter(Position = 0, ParameterSetName = 'Project')]
    [string]$Project = 'home',
    [Parameter(Mandatory, ParameterSetName = 'Path')]
    [string]$Path,
    [Parameter(ParameterSetName = 'Path')]
    [ValidateSet('auto', 'windows', 'wsl')]
    [string]$Kind = 'auto',
    [switch]$DryRun,
    [switch]$ReuseWindow,
    [switch]$AllowUnauthenticated,
    [string]$ConfigPath,
    [string]$StatePath
)

$forward = @{ DryRun = $DryRun; ReuseWindow = $ReuseWindow; AllowUnauthenticated = $AllowUnauthenticated; ConfigPath = $ConfigPath; StatePath = $StatePath }
if ($PSCmdlet.ParameterSetName -eq 'Path') {
    $forward.Path = $Path
    $forward.Kind = $Kind
} else {
    $forward.Project = $Project
}
& (Join-Path $PSScriptRoot 'cursor-instance.ps1') -Instance stable @forward
exit $LASTEXITCODE
