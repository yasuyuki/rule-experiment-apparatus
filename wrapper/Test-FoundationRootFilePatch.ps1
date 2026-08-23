[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PatchPath,
    [Parameter(Mandatory)][string]$ExpectedBlob,
    [ValidateSet('baseline', 'run')][string]$Role = 'run',
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$state = Read-ReleaseState -StatePath $resolvedStatePath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$release = $state.$Role
if (-not $release) { throw "Release role '$Role' is empty." }

$instance = Get-ConfiguredInstance -Configuration $config -Name ([string]$release.instance)
$patchFull = [System.IO.Path]::GetFullPath($PatchPath)
if (-not (Test-Path -LiteralPath $patchFull -PathType Leaf)) {
    throw "Patch file not found: $patchFull"
}

$helperWindows = Join-Path $PSScriptRoot 'lib\test-root-claude-patch.sh'
# /mnt/c sed -i is unreliable; normalize CRLF on the Windows side.
$helperText = [System.IO.File]::ReadAllText($helperWindows) -replace "`r`n", "`n" -replace "`r", "`n"
[System.IO.File]::WriteAllText($helperWindows, $helperText, [System.Text.UTF8Encoding]::new($false))
$helperWsl = ConvertTo-WslPath -WindowsPath $helperWindows
$patchWsl = ConvertTo-WslPath -WindowsPath $patchFull
$root = [string]$release.path

$output = & wsl.exe -d $instance.wslDistro -u $instance.wslUser -- bash $helperWsl $root $patchWsl $ExpectedBlob
if ($LASTEXITCODE -ne 0) {
    throw "Patch test failed for ${Role}:$root`n$($output -join "`n")"
}

function Get-Kv([string]$Prefix) {
    $line = @($output | Where-Object { $_ -like "$Prefix*" } | Select-Object -Last 1)
    if (-not $line) { return $null }
    return ([string]$line).Substring($Prefix.Length).Trim()
}

$currentBlob = Get-Kv 'current_blob='
$headBlob = Get-Kv 'head_blob='
$alreadyApplied = (Get-Kv 'already_applied=') -eq 'true'
$applyCheck = (Get-Kv 'apply_check=') -eq 'true'

$recommendation = if ($alreadyApplied) {
    'skip-already-applied'
} elseif ($applyCheck) {
    'apply'
} else {
    'conflict-investigate'
}

[ordered]@{
    role = $Role
    path = $root
    patchPath = $patchFull
    expectedBlob = $ExpectedBlob
    currentBlob = $currentBlob
    headBlob = $headBlob
    alreadyApplied = $alreadyApplied
    applyCheck = $applyCheck
    readyToApply = (-not $alreadyApplied -and $applyCheck)
    recommendation = $recommendation
    output = @($output)
} | ConvertTo-Json -Depth 4
