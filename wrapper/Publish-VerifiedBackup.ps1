[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$DestinationRoot,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
$manifestFull = [System.IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) { throw "Manifest not found: $manifestFull" }
$manifest = Get-Content -Raw -LiteralPath $manifestFull | ConvertFrom-Json
$schemaVersion = [int]$manifest.schemaVersion
if (($schemaVersion -ne 1 -and $schemaVersion -ne 2) -or -not $manifest.verified) {
    throw 'Manifest is not a verified schema-1 or schema-2 backup.'
}

$artifactFiles = [System.Collections.Generic.List[object]]::new()
if ($schemaVersion -eq 1) {
    $artifactFiles.Add([ordered]@{
        role = 'bundle'
        source = [System.IO.Path]::GetFullPath([string]$manifest.bundle.path)
        sha256 = [string]$manifest.bundle.sha256
        length = [long]$manifest.bundle.length
    }) | Out-Null
} else {
    foreach ($repo in @($manifest.repositories)) {
        $artifactFiles.Add([ordered]@{
            role = "bundle:$($repo.relativePath)"
            source = [System.IO.Path]::GetFullPath([string]$repo.bundle.path)
            sha256 = [string]$repo.bundle.sha256
            length = [long]$repo.bundle.length
        }) | Out-Null
    }
}
$artifactFiles.Add([ordered]@{
    role = 'manifest'
    source = $manifestFull
    sha256 = (Get-FileHash -LiteralPath $manifestFull -Algorithm SHA256).Hash
    length = (Get-Item -LiteralPath $manifestFull).Length
}) | Out-Null

foreach ($artifact in @($artifactFiles)) {
    if ($artifact.role -eq 'manifest') { continue }
    if (-not (Test-Path -LiteralPath ([string]$artifact.source) -PathType Leaf)) {
        throw "Bundle not found: $($artifact.source)"
    }
    $item = Get-Item -LiteralPath ([string]$artifact.source)
    if ([long]$item.Length -ne [long]$artifact.length) { throw "Source bundle length mismatch: $($artifact.source)" }
    $hash = (Get-FileHash -LiteralPath ([string]$artifact.source) -Algorithm SHA256).Hash
    if ($hash -ne [string]$artifact.sha256) { throw "Source bundle SHA-256 mismatch: $($artifact.source)" }
}

$destinationFull = [System.IO.Path]::GetFullPath($DestinationRoot)
$destinationPairs = [System.Collections.Generic.List[object]]::new()
foreach ($artifact in @($artifactFiles)) {
    $destinationPath = Join-Path $destinationFull (Split-Path ([string]$artifact.source) -Leaf)
    $destinationPairs.Add([ordered]@{
        role = [string]$artifact.role
        source = [string]$artifact.source
        destination = $destinationPath
        sha256 = [string]$artifact.sha256
        exists = (Test-Path -LiteralPath $destinationPath -PathType Leaf)
    }) | Out-Null
}

$existingCount = @($destinationPairs | Where-Object { $_.exists }).Count
if ($existingCount -ne 0 -and $existingCount -ne $destinationPairs.Count) {
    throw 'Destination contains an incomplete backup set; refusing to overwrite it.'
}

$alreadyPublished = $false
if ($existingCount -eq $destinationPairs.Count) {
    foreach ($pair in @($destinationPairs)) {
        $destinationHash = (Get-FileHash -LiteralPath ([string]$pair.destination) -Algorithm SHA256).Hash
        if ($destinationHash -ne [string]$pair.sha256) {
            throw 'Destination backup exists with different content; refusing to overwrite it.'
        }
    }
    $alreadyPublished = $true
}

$rootBundleSha = [string](@($artifactFiles | Where-Object { $_.role -ne 'manifest' })[0].sha256)
$result = [ordered]@{
    action = 'publish-verified-backup'
    execute = [bool]$Execute
    schemaVersion = $schemaVersion
    sourceManifest = $manifestFull
    destinationRoot = $destinationFull
    artifacts = @($destinationPairs)
    sha256 = $rootBundleSha
    alreadyPublished = $alreadyPublished
}
if (-not $Execute -or $alreadyPublished) {
    $result['published'] = $alreadyPublished
    $result | ConvertTo-Json -Depth 6
    return
}

New-Item -ItemType Directory -Force -Path $destinationFull | Out-Null
$stageRoot = Join-Path $destinationFull ('.publish-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageRoot | Out-Null
try {
    foreach ($pair in @($destinationPairs)) {
        $stagePath = Join-Path $stageRoot (Split-Path ([string]$pair.source) -Leaf)
        Copy-Item -LiteralPath ([string]$pair.source) -Destination $stagePath
        if ((Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash -ne [string]$pair.sha256) {
            throw "Staged SHA-256 mismatch: $($pair.role)"
        }
        Move-Item -LiteralPath $stagePath -Destination ([string]$pair.destination)
    }
} finally {
    $resolvedDestination = [System.IO.Path]::GetFullPath($destinationFull)
    $resolvedStage = [System.IO.Path]::GetFullPath($stageRoot)
    if (-not $resolvedStage.StartsWith($resolvedDestination + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe staging cleanup target: $resolvedStage"
    }
    for ($cleanupAttempt = 0; $cleanupAttempt -lt 5 -and (Test-Path -LiteralPath $resolvedStage); $cleanupAttempt++) {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        if (Test-Path -LiteralPath $resolvedStage) { Start-Sleep -Milliseconds 200 }
    }
}

foreach ($pair in @($destinationPairs)) {
    if ((Get-FileHash -LiteralPath ([string]$pair.destination) -Algorithm SHA256).Hash -ne [string]$pair.sha256) {
        throw "Published SHA-256 mismatch: $($pair.role)"
    }
}
$result['published'] = $true
$result['stagingRemoved'] = -not (Test-Path -LiteralPath $stageRoot)
$result | ConvertTo-Json -Depth 6
