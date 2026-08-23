[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [switch]$Execute,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
if (-not $Execute) { throw 'Live handoff smoke requires explicit -Execute.' }
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\CursorHandoff.ps1')
$wrapper = Join-Path $PSScriptRoot 'Invoke-FoundationRelease.ps1'

function Invoke-HandoffStage {
    param([switch]$Launch)
    $arguments = @{ Stage = 'handoff' }
    if ($Launch) { $arguments.Execute = $true }
    if (-not [string]::IsNullOrWhiteSpace($StatePath)) { $arguments.StatePath = $StatePath }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $arguments.ConfigPath = $ConfigPath }
    (& $wrapper @arguments) | ConvertFrom-Json
}

function Write-HandoffFailure([object]$Result) {
    # pwsh ConciseView collapses exception newlines into spaces, so the
    # copy-paste block cannot live in throw. Print it, then throw one line.
    $message = Format-HandoffFailureException -Result $Result
    foreach ($line in @($message -split "`n")) {
        Write-Output $line
    }
    $short = Get-HandoffFailureThrowMessage -Result $Result
    $exception = [System.Exception]::new($short)
    $exception.Data['HandoffFailure'] = $message
    $record = New-Object System.Management.Automation.ErrorRecord (
        $exception,
        'HandoffNotReady',
        [System.Management.Automation.ErrorCategory]::ResourceBusy,
        $Result
    )
    throw $record
}

$preflight = Invoke-HandoffStage
if (-not $preflight.ready) { Write-HandoffFailure $preflight }

$result = Invoke-HandoffStage -Launch
if (-not $result.launchVerified) { Write-HandoffFailure $result }

$repeat = Invoke-HandoffStage
if ($repeat.launchStarted) { throw "Occupied retest started a process: $($repeat.code)" }
if ($repeat.code -notin @('instance-occupied', 'remote-occupied')) {
    throw "Occupied retest expected instance-occupied or remote-occupied, got $($repeat.code)"
}
[ordered]@{ launch = $result; occupied = $repeat } | ConvertTo-Json -Depth 10
