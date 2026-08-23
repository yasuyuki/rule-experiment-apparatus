$ErrorActionPreference = 'Stop'

# `local-data.sh status` prints one padded line per problem
# (NOSTORE/BROKEN/NOTLINK/ABSENT/DIFF) and always closes with a summary line
# "-- <root>: ok=N diff=N missing=N". The summary line is therefore the only
# reliable proof that the script ran to completion: a missing store, a missing
# MANIFEST or a missing workspace-root makes it exit before printing anything.
# Do not classify on the exit code alone -- ABSENT is not counted in `missing=`,
# and those early exits share exit code 1 with an ordinary drift.
#
# The script is invoked through `bash -s` on stdin with stderr merged inside
# WSL. Both details are load bearing:
#   * wsl.exe rebuilds its argument list into one command string, so a nested
#     `bash -c '...'` loses the quoting (see Invoke-WslRepositoryBatch).
#   * Windows PowerShell 5.1 turns native stderr captured with `2>&1` into a
#     NativeCommandError, which under $ErrorActionPreference = 'Stop' would
#     abort Get-FoundationStatus.ps1 through its trap and print no status at
#     all -- on exactly the failure path this check exists to report.
# The batch string must not end in a newline: PowerShell appends CRLF to a
# piped string, and a bare CR on its own line makes bash exit 127 and destroys
# the exit code being read.
function Get-LocalDataStatus {
    param(
        [Parameter(Mandatory)] [string]$Distro,
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [string]$StoreRoot,
        [Parameter(Mandatory)] [string]$WorkspaceRoot
    )

    $scriptPath = "$StoreRoot/local-data.sh"
    $quotedScript = ConvertTo-PosixSingleQuoted -Value $scriptPath
    $quotedRoot = ConvertTo-PosixSingleQuoted -Value $WorkspaceRoot
    $batch = ("set -- $quotedScript $quotedRoot`n" +
        '"$1" status "$2" 2>&1' +
        "`n# end of local-data status") -replace "`r`n", "`n"

    $output = @($batch | & wsl.exe -d $Distro -u $User -- bash -s | ForEach-Object { [string]$_ })
    return ConvertFrom-LocalDataStatusOutput `
        -StoreRoot $StoreRoot `
        -ScriptPath $scriptPath `
        -WorkspaceRoot $WorkspaceRoot `
        -Output $output `
        -ExitCode $LASTEXITCODE
}

function ConvertFrom-LocalDataStatusOutput {
    param(
        [Parameter(Mandatory)] [string]$StoreRoot,
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [AllowEmptyCollection()] [string[]]$Output,
        [Parameter(Mandatory)] [int]$ExitCode
    )

    $summary = $null
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($Output)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('-- ')) { $summary = $line.Trim(); continue }
        $problems.Add((($line -replace '\s+', ' ').Trim())) | Out-Null
    }

    $state = if ($null -eq $summary) {
        'unavailable'
    } elseif ($ExitCode -eq 0 -and $problems.Count -eq 0) {
        'ok'
    } else {
        'drift'
    }

    return [ordered]@{
        store = $StoreRoot
        script = $ScriptPath
        workspaceRoot = $WorkspaceRoot
        state = $state
        exitCode = $ExitCode
        summary = $summary
        problems = @($problems.ToArray())
        output = @($Output)
    }
}
