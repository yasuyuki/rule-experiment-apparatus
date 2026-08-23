$ErrorActionPreference = 'Stop'

# Restores only into a new staging path. Publishing, failure cleanup, and state
# changes remain the responsibility of the guarded promote/rollback path.

function Test-LiveReleaseBackupRestoreTarget {
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] $State,
        [string] $BaselineCommit,
        [string] $RunCommit
    )

    $generation = [int]$Manifest.generation
    if ($generation -ne [int]$State.generation) { return $false }

    $role = [string]$Manifest.role
    $commit = [string]$Manifest.source.commit
    if ($role -eq 'baseline' -and -not [string]::IsNullOrWhiteSpace($BaselineCommit) -and $commit -eq $BaselineCommit) {
        return $true
    }
    if ($role -eq 'run' -and $State.run -and -not [string]::IsNullOrWhiteSpace($RunCommit) -and $commit -eq $RunCommit) {
        return $true
    }
    return $false
}

function Restore-FoundationWorkspaceBackup {
    param(
        [Parameter(Mandatory)] [string]$ManifestPath,
        [Parameter(Mandatory)] [string]$RestorePath,
        [string]$TargetDistro,
        [string]$TargetUser
    )

    $manifestFull = [System.IO.Path]::GetFullPath($ManifestPath)
    if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) {
        throw "Manifest is missing: $manifestFull"
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestFull | ConvertFrom-Json
    if (-not $manifest.verified) { throw 'Manifest does not record a verified bundle.' }
    $schemaVersion = [int]$manifest.schemaVersion
    if ($schemaVersion -ne 1 -and $schemaVersion -ne 2) {
        throw "Unsupported backup manifest schemaVersion: $schemaVersion"
    }

    if ([string]::IsNullOrWhiteSpace($TargetDistro)) { $TargetDistro = [string]$manifest.source.distro }
    if ([string]::IsNullOrWhiteSpace($TargetUser)) { $TargetUser = [string]$manifest.source.user }
    if ([string]::IsNullOrWhiteSpace($TargetDistro) -or [string]::IsNullOrWhiteSpace($TargetUser)) {
        throw 'Backup restore requires a target distro and user.'
    }

    $restoreRoot = if ($RestorePath.StartsWith('/')) {
        Assert-AbsolutePosixPath -Path $RestorePath -Context 'Backup restore path'
    } else {
        ConvertTo-WslPath -WindowsPath ([System.IO.Path]::GetFullPath($RestorePath))
    }
    & wsl.exe -d $TargetDistro -u $TargetUser -- test '!' -e $restoreRoot
    if ($LASTEXITCODE -ne 0) { throw "Backup restore path already exists: $restoreRoot" }
    $restoreParent = $restoreRoot.Substring(0, $restoreRoot.LastIndexOf('/'))
    & wsl.exe -d $TargetDistro -u $TargetUser -- mkdir -p $restoreParent
    if ($LASTEXITCODE -ne 0) { throw "Failed to create backup restore parent: $restoreParent" }

    $manifestDirectory = Split-Path $manifestFull -Parent
    $repositorySpecs = [System.Collections.Generic.List[object]]::new()
    if ($schemaVersion -eq 1) {
        $repositorySpecs.Add([ordered]@{
            relativePath = '.'
            branch = [string]$manifest.source.branch
            commit = [string]$manifest.source.commit
            origin = [string]$manifest.source.origin
            bundle = $manifest.bundle
        }) | Out-Null
    } else {
        if ([string]$manifest.kind -ne 'routed-foundation-workspace-backup') {
            throw "Unsupported schema 2 backup kind: $($manifest.kind)"
        }
        foreach ($repo in @($manifest.repositories)) { $repositorySpecs.Add($repo) | Out-Null }
        $rootRepositories = @($repositorySpecs | Where-Object { [string]$_.relativePath -eq '.' })
        if ($rootRepositories.Count -ne 1) {
            throw "Workspace backup must contain exactly one root repository; found $($rootRepositories.Count)."
        }
        if ([string]$rootRepositories[0].commit -ne [string]$manifest.source.commit) {
            throw 'Workspace backup root commit does not match manifest.source.commit.'
        }
    }

    $orderedRepositories = @($repositorySpecs | Where-Object { [string]$_.relativePath -eq '.' }) +
        @($repositorySpecs | Where-Object { [string]$_.relativePath -ne '.' })
    $seen = @{}
    $restored = [System.Collections.Generic.List[object]]::new()
    foreach ($repo in $orderedRepositories) {
        $relativePath = [string]$repo.relativePath
        if ($relativePath -ne '.') {
            $relativePath = Assert-WorkspaceRelativePath -RelativePath $relativePath
        }
        if ($seen.ContainsKey($relativePath)) { throw "Duplicate repository in backup manifest: $relativePath" }
        $seen[$relativePath] = $true

        $recordedBundle = [System.IO.Path]::GetFullPath([string]$repo.bundle.path)
        $adjacentBundle = Join-Path $manifestDirectory (Split-Path $recordedBundle -Leaf)
        $bundlePath = if (Test-Path -LiteralPath $adjacentBundle -PathType Leaf) {
            $adjacentBundle
        } elseif (Test-Path -LiteralPath $recordedBundle -PathType Leaf) {
            $recordedBundle
        } else {
            throw "Bundle is missing: recorded=$recordedBundle adjacent=$adjacentBundle"
        }
        $bundleItem = Get-Item -LiteralPath $bundlePath
        if ([long]$bundleItem.Length -ne [long]$repo.bundle.length) {
            throw "Bundle length mismatch for $relativePath."
        }
        $actualHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
        if ($actualHash -ne [string]$repo.bundle.sha256) {
            throw "Bundle SHA-256 mismatch for $relativePath."
        }

        $targetPath = if ($relativePath -eq '.') {
            $restoreRoot
        } else {
            Join-WorkspaceRelativePath -WorkspaceRoot $restoreRoot -RelativePath $relativePath
        }
        if ($relativePath -ne '.') {
            $targetParent = $targetPath.Substring(0, $targetPath.LastIndexOf('/'))
            & wsl.exe -d $TargetDistro -u $TargetUser -- mkdir -p $targetParent
            if ($LASTEXITCODE -ne 0) { throw "Failed to create restore parent for $relativePath." }
        }

        $bundleWsl = ConvertTo-WslPath -WindowsPath $bundlePath
        & wsl.exe -d $TargetDistro -u $TargetUser -- git clone --quiet $bundleWsl $targetPath
        if ($LASTEXITCODE -ne 0) { throw "Backup restore clone failed for $relativePath." }

        $commit = [string]$repo.commit
        & wsl.exe -d $TargetDistro -u $TargetUser -- git -C $targetPath cat-file -e "$commit^{commit}"
        if ($LASTEXITCODE -ne 0) { throw "Source commit is not recoverable for ${relativePath}: $commit" }
        $branch = [string]$repo.branch
        if ([string]::IsNullOrWhiteSpace($branch)) {
            & wsl.exe -d $TargetDistro -u $TargetUser -- git -C $targetPath checkout --quiet --detach $commit
        } else {
            & wsl.exe -d $TargetDistro -u $TargetUser -- git -C $targetPath checkout --quiet -B $branch $commit
        }
        if ($LASTEXITCODE -ne 0) { throw "Failed to check out recorded commit for $relativePath." }
        $origin = [string]$repo.origin
        if (-not [string]::IsNullOrWhiteSpace($origin)) {
            & wsl.exe -d $TargetDistro -u $TargetUser -- git -C $targetPath remote set-url origin $origin
            if ($LASTEXITCODE -ne 0) { throw "Failed to restore origin for $relativePath." }
        }
        $restoredHead = ("$(& wsl.exe -d $TargetDistro -u $TargetUser -- git -C $targetPath rev-parse HEAD)").Trim()
        if ($restoredHead -ne $commit) {
            throw "Restored HEAD mismatch for ${relativePath}: expected $commit, actual $restoredHead"
        }
        $restored.Add([ordered]@{
            relativePath = $relativePath
            commit = $commit
            restoredHead = $restoredHead
            sha256 = $actualHash
        }) | Out-Null
    }

    return [ordered]@{
        restoreVerified = $true
        schemaVersion = $schemaVersion
        manifest = $manifestFull
        sourceCommit = [string]$manifest.source.commit
        repositories = @($restored)
        restorePath = $restoreRoot
    }
}
