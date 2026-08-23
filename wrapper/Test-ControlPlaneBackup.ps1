[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,
    [switch]$VerifyRestore,
    [string]$ConfigPath,
    [string]$StatePath,
    [string]$VerificationRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$controlPlane = Get-JsonProperty -Object $config -Name 'controlPlane' -DocumentName 'Environment config'
$controlPlaneInstanceName = [string](Get-JsonProperty -Object $controlPlane -Name 'gitInstance' -DocumentName 'Environment config.controlPlane')
$controlPlaneInstance = Get-ConfiguredInstance -Configuration $config -Name $controlPlaneInstanceName
$controlPlaneDistro = [string]$controlPlaneInstance.wslDistro
$controlPlaneUser = [string]$controlPlaneInstance.wslUser
$manifestFull = [System.IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) {
    throw "Backup manifest not found: $manifestFull"
}
$manifest = Get-Content -Raw -LiteralPath $manifestFull | ConvertFrom-Json
if ([int]$manifest.schemaVersion -ne 1) { throw 'Unsupported backup manifest schema.' }
if (-not $manifest.commit) { throw 'Backup manifest has no commit.' }

$recordedBundlePath = [string]$manifest.bundle.path
# Prefer the bundle copied beside the selected manifest. This ensures an
# off-site verification really exercises that copy even when the original
# absolute path recorded in the manifest still exists.
$adjacentBundlePath = Join-Path (Split-Path $manifestFull -Parent) (Split-Path $recordedBundlePath -Leaf)
$bundlePath = if (Test-Path -LiteralPath $adjacentBundlePath -PathType Leaf) { $adjacentBundlePath } else { $recordedBundlePath }
if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) { throw "Backup bundle not found: $bundlePath" }

$bundleItem = Get-Item -LiteralPath $bundlePath
if ([long]$bundleItem.Length -ne [long]$manifest.bundle.length) { throw "Backup length mismatch: $bundlePath" }
$hash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
if ($hash -ne [string]$manifest.bundle.sha256) { throw "Backup hash mismatch: $bundlePath" }

$restoredHead = $null
$temporaryDataDeleted = $null
$verifyRoot = Resolve-VerificationRoot -VerificationRoot $VerificationRoot -Configuration $config -ConfigurationPath $resolvedConfigPath -BasePath (Get-ConfigurationWorkspaceRoot)
$verifyPath = Join-Path $verifyRoot ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $verifyPath | Out-Null
try {
    # Cloud-backed drives may be readable from Windows while WSL cannot safely
    # address or write them. Verify one hash-identical workspace staging copy.
    $stagedBundle = Join-Path $verifyPath (Split-Path $bundlePath -Leaf)
    Copy-Item -LiteralPath $bundlePath -Destination $stagedBundle
    $stagedHash = (Get-FileHash -LiteralPath $stagedBundle -Algorithm SHA256).Hash
    if ($stagedHash -ne $hash) { throw 'Staged backup hash mismatch.' }
    $stagedBundleWsl = ConvertTo-WslPath -WindowsPath $stagedBundle
    & wsl.exe -d $controlPlaneDistro -u $controlPlaneUser -- git bundle list-heads $stagedBundleWsl 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Git bundle verification failed: $bundlePath" }

    if ($VerifyRestore) {
        $restorePath = Join-Path $verifyPath 'restore'
        $restoreWsl = ConvertTo-WslPath -WindowsPath $restorePath
        & wsl.exe -d $controlPlaneDistro -u $controlPlaneUser -- git clone --quiet $stagedBundleWsl $restoreWsl
        if ($LASTEXITCODE -ne 0) { throw 'Temporary backup restore failed.' }
        $restoredHead = (& wsl.exe -d $controlPlaneDistro -u $controlPlaneUser -- git -C $restoreWsl rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $restoredHead -ne [string]$manifest.commit) {
            throw "Restored HEAD mismatch. Expected $($manifest.commit), got $restoredHead"
        }
    }
}
finally {
    $resolvedRoot = [System.IO.Path]::GetFullPath($verifyRoot)
    $resolvedTarget = [System.IO.Path]::GetFullPath($verifyPath)
    if (-not $resolvedTarget.StartsWith($resolvedRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe temporary cleanup target: $resolvedTarget"
    }
    if (Test-Path -LiteralPath $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
    if ((Test-Path -LiteralPath $resolvedRoot) -and -not (Get-ChildItem -LiteralPath $resolvedRoot -Force)) {
        Remove-Item -LiteralPath $resolvedRoot -Force
    }
    $temporaryDataDeleted = -not (Test-Path -LiteralPath $resolvedTarget)
}

[ordered]@{
    backupVerified = $true
    manifestPath = $manifestFull
    bundlePath = $bundlePath
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    verificationRoot = $verifyRoot
    controlPlane = [ordered]@{ instance = $controlPlaneInstanceName; distro = $controlPlaneDistro; user = $controlPlaneUser }
    sha256 = $hash
    expectedHead = [string]$manifest.commit
    restoreVerified = if ($VerifyRestore) { $restoredHead -eq [string]$manifest.commit } else { $null }
    restoredHead = $restoredHead
    temporaryDataDeleted = $temporaryDataDeleted
} | ConvertTo-Json -Depth 5
