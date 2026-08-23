[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$VerificationRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib\WorkspaceBackup.ps1')
$manifestFull = [System.IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) { throw "Manifest is missing: $manifestFull" }
$manifest = Get-Content -Raw -LiteralPath $manifestFull | ConvertFrom-Json

$verifyRoot = [System.IO.Path]::GetFullPath($VerificationRoot)
$verifyPath = [System.IO.Path]::GetFullPath((Join-Path $verifyRoot ([guid]::NewGuid().ToString('N'))))
if (-not $verifyPath.StartsWith($verifyRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe verification path: $verifyPath"
}
New-Item -ItemType Directory -Force -Path $verifyPath | Out-Null

function Remove-VerificationWorkspace {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [string]$Distro,
        [string]$User
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    # WSL git holds Windows file locks; delete from the same side that created the clone.
    if (-not [string]::IsNullOrWhiteSpace($Distro) -and -not [string]::IsNullOrWhiteSpace($User)) {
        $wslPath = ConvertTo-WslPath -WindowsPath $Path
        & wsl.exe -d $Distro -u $User -- rm -rf $wslPath 2>$null | Out-Null
    }
    for ($attempt = 0; $attempt -lt 5 -and (Test-Path -LiteralPath $Path); $attempt++) {
        Start-Sleep -Milliseconds (100 * ($attempt + 1))
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $Path) {
        throw "Failed to delete temporary restore path: $Path"
    }
}

$sourceDistro = [string]$manifest.source.distro
$sourceUser = [string]$manifest.source.user
try {
    $restore = Restore-FoundationWorkspaceBackup `
        -ManifestPath $manifestFull `
        -RestorePath (Join-Path $verifyPath 'restore') `
        -TargetDistro $sourceDistro `
        -TargetUser $sourceUser
} finally {
    Remove-VerificationWorkspace -Path $verifyPath -Distro $sourceDistro -User $sourceUser
    if ((Test-Path -LiteralPath $verifyRoot) -and -not (Get-ChildItem -LiteralPath $verifyRoot -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $verifyRoot -Force -ErrorAction SilentlyContinue
    }
}

[ordered]@{
    restoreVerified = $true
    schemaVersion = [int]$restore.schemaVersion
    manifest = $manifestFull
    sourceCommit = [string]$restore.sourceCommit
    repositories = @($restore.repositories)
    temporaryRestoreDeleted = -not (Test-Path -LiteralPath $verifyPath)
} | ConvertTo-Json -Depth 6
