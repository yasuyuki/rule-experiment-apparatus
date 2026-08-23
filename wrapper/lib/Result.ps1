$ErrorActionPreference = 'Stop'

# Operator-facing commands emit JSON on stdout and are routinely piped into
# ConvertFrom-Json. A bare exception leaves that pipeline with nothing to read
# and no exit code to test, so entry points report failure in the same shape as
# success and exit non-zero.
#
# Library code and composed sub-scripts deliberately keep throwing: fail-fast is
# what stops a release transition half way through.
function Write-FoundationFailure {
    param(
        [Parameter(Mandatory)] [string]$Command,
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Stage
    )

    $result = [ordered]@{
        ok = $false
        command = $Command
        stage = $Stage
        message = [string]$ErrorRecord.Exception.Message
        at = [DateTimeOffset]::Now.ToString('o')
    }
    $result | ConvertTo-Json -Depth 4
}

function ConvertTo-FoundationSuccess {
    param([Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$Result)

    $withStatus = [ordered]@{ ok = $true }
    foreach ($key in $Result.Keys) { $withStatus[$key] = $Result[$key] }
    return $withStatus
}

# Composed sub-scripts report failure by throwing under $ErrorActionPreference
# = 'Stop', which propagates to the caller. Their $LASTEXITCODE is deliberately
# not consulted: a PowerShell script that never calls exit leaves behind the
# code of whatever native command it happened to run last (a pgrep that matched
# nothing, for example), which says nothing about whether the script succeeded.
function Invoke-FoundationJsonScript {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [hashtable]$Arguments
    )

    $json = & $Path @Arguments
    if ($null -eq $json) {
        throw "$([System.IO.Path]::GetFileName($Path)) produced no output."
    }
    $parsed = ($json | ConvertFrom-Json)
    if ($null -ne $parsed.PSObject.Properties['ok'] -and -not $parsed.ok) {
        throw "$([System.IO.Path]::GetFileName($Path)) reported failure: $($parsed.message)"
    }
    return $parsed
}
