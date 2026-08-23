[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PatchPath,
    [Parameter(Mandatory)][string]$ExpectedBlob,
    [ValidateSet('run')][string]$Role = 'run',
    [string]$CommitMessage = 'Clarify HANDOFF parallel-branch rules and ISSUES.md in CLAUDE.md',
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

$helperWindows = Join-Path $PSScriptRoot 'lib\apply-root-claude-patch.sh'
# /mnt/c sed -i is unreliable; normalize CRLF on the Windows side.
$helperText = [System.IO.File]::ReadAllText($helperWindows) -replace "`r`n", "`n" -replace "`r", "`n"
[System.IO.File]::WriteAllText($helperWindows, $helperText, [System.Text.UTF8Encoding]::new($false))
$helperWsl = ConvertTo-WslPath -WindowsPath $helperWindows
$patchWsl = ConvertTo-WslPath -WindowsPath $patchFull
$root = [string]$release.path

$output = & wsl.exe -d $instance.wslDistro -u $instance.wslUser -- bash $helperWsl $root $patchWsl $ExpectedBlob $CommitMessage
if ($LASTEXITCODE -eq 2) {
    throw "Refusing apply for ${Role}:$root — CLAUDE.md already matches expected blob. Run Test-FoundationRootFilePatch.ps1 first."
}
if ($LASTEXITCODE -ne 0) {
    throw "Patch apply/commit failed for ${Role}:$root`n$($output -join "`n")"
}

$commitLine = @($output | Where-Object { $_ -like 'commit=*' } | Select-Object -Last 1)
$commit = if ($commitLine) { ([string]$commitLine).Substring(7).Trim() } else { $null }
$blobLine = @($output | Where-Object { $_ -like 'working_blob=*' } | Select-Object -Last 1)
$blob = if ($blobLine) { ([string]$blobLine).Substring(13).Trim() } else { $null }

[ordered]@{
    role = $Role
    path = $root
    patchPath = $patchFull
    expectedBlob = $ExpectedBlob
    workingBlob = $blob
    commit = $commit
    output = @($output)
} | ConvertTo-Json -Depth 4
