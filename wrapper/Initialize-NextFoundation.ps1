[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$GitRef,
    [string]$Path,
    [int]$ExpectedGeneration = -1,
    [switch]$DryRun,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')
$StatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$ConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $ConfigPath
Assert-EnvironmentConfigSupportsWorkspaceMutation -Configuration $config | Out-Null
$lock = Enter-ReleaseStateLock -StatePath $StatePath -DryRun:$DryRun

function Assert-NamedBranches {
    param([Parameter(Mandatory)][object]$Snapshot, [Parameter(Mandatory)][string]$Label)

    $detached = [System.Collections.Generic.List[string]]::new()
    foreach ($repo in @($Snapshot.repositories)) {
        if (-not $repo.present) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$repo.branch)) {
            $detached.Add([string]$repo.relativePath)
        }
    }
    if ($detached.Count -gt 0) {
        throw "$Label has detached HEAD (named branch required): $($detached -join ', ')"
    }
}

function Update-FoundationReleaseMetadata {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ReleaseName,
        [Parameter(Mandatory)][string]$ParentCommit
    )

    $manifestPath = "$RootPath/FOUNDATION-RELEASE.json"
    & wsl.exe -d $Distro -u $User -- test -f $manifestPath
    if ($LASTEXITCODE -ne 0) {
        # Source tips that predate the allowlisted manifest still need release metadata.
        & wsl.exe -d $Distro -u $User -- sh -c "printf '%s\n' '{}' > '$manifestPath'"
        if ($LASTEXITCODE -ne 0) { throw "Failed to create FOUNDATION-RELEASE.json at $manifestPath" }
        $raw = '{}'
    } else {
        $raw = ("$(& wsl.exe -d $Distro -u $User -- cat $manifestPath)").Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
    }
    $meta = $raw | ConvertFrom-Json
    if ($null -eq $meta) { $meta = [pscustomobject]@{} }

    $meta | Add-Member -MemberType NoteProperty -Name schemaVersion -Value 1 -Force
    $meta | Add-Member -MemberType NoteProperty -Name release -Value $ReleaseName -Force
    $meta | Add-Member -MemberType NoteProperty -Name parentCommit -Value $ParentCommit -Force
    if ($meta.PSObject.Properties.Name -contains 'channel') {
        $meta.PSObject.Properties.Remove('channel')
    }
    $meta | Add-Member -MemberType NoteProperty -Name role -Value 'run' -Force

    $json = ($meta | ConvertTo-Json -Depth 8) -replace "`r`n", "`n"
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    $tempManifest = Join-Path ([System.IO.Path]::GetTempPath()) ("rule-experiment-system-" + [guid]::NewGuid().ToString('N') + ".json")
    try {
        [System.IO.File]::WriteAllText($tempManifest, $json, [System.Text.UTF8Encoding]::new($false))
        $tempManifestWsl = ConvertTo-WslPath -WindowsPath $tempManifest
        & wsl.exe -d $Distro -u $User -- cp -a $tempManifestWsl $manifestPath
        if ($LASTEXITCODE -ne 0) { throw "Failed to write FOUNDATION-RELEASE.json at $manifestPath" }
    } finally {
        if (Test-Path -LiteralPath $tempManifest) {
            Remove-Item -LiteralPath $tempManifest -Force -ErrorAction SilentlyContinue
        }
    }

    # Force-add: some source roots still use /* deny without !/FOUNDATION-RELEASE.json.
    & wsl.exe -d $Distro -u $User -- git -C $RootPath add -f FOUNDATION-RELEASE.json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to stage FOUNDATION-RELEASE.json' }
    $message = "Set FOUNDATION-RELEASE metadata for $ReleaseName"
    # Discard commit stdout so it is not mixed into this function's return value.
    & wsl.exe -d $Distro -u $User -- git -C $RootPath commit -m $message 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit FOUNDATION-RELEASE.json metadata' }

    return ("$(& wsl.exe -d $Distro -u $User -- git -C $RootPath rev-parse HEAD)").Trim()
}

try {
    $state = Read-ReleaseState -StatePath $StatePath
    Assert-ReleaseStateRuntimePlacement -State $state -Configuration $config
    Assert-ReleaseStateGeneration -State $state -ExpectedGeneration $ExpectedGeneration | Out-Null
    if ($state.run) { throw "Run '$($state.run.name)' already exists." }
    if (-not $state.baseline) { throw 'A baseline is required to seed a run.' }

    $targetName = 'candidate'
    $source = Get-ConfiguredInstance -Configuration $config -Name 'stable'
    $target = Get-ConfiguredInstance -Configuration $config -Name $targetName

    if (-not $Path) {
        $Path = Resolve-DefaultReleaseSeedPath -Instance $target -Name $Name -InstanceName $targetName
    }
    if (-not $Path.StartsWith('/')) { throw "Target path must be absolute: $Path" }

    $sourceWorkspaceRoot = ([string]$state.baseline.path).TrimEnd('/')

    $declared = @(Get-ConfiguredWorkspaceRepositories -Configuration $config)

    $sourceSnapshot = Get-ReleaseWorkspaceSnapshot `
        -Instance $source `
        -WorkspaceRoot $sourceWorkspaceRoot `
        -GitRef ([string]$state.baseline.gitRef) `
        -DeclaredRepositories $declared `
        -Channel baseline `
        -EnforceMembership
    if ($sourceSnapshot.errors.Count -gt 0) {
        throw "Baseline workspace is not seed-ready: $($sourceSnapshot.errors -join '; ')"
    }
    if (-not $sourceSnapshot.seedReady) {
        throw "Baseline workspace must be clean before seed. Dirty: $($sourceSnapshot.dirtyRepositories -join ', ')"
    }
    Assert-NamedBranches -Snapshot $sourceSnapshot -Label 'Baseline workspace'
    $acceptance = (& (Join-Path $PSScriptRoot 'Test-FoundationRelease.ps1') -Role baseline -StatePath $StatePath -ConfigPath $ConfigPath) | ConvertFrom-Json
    if (-not $acceptance.accepted) { throw 'Baseline foundation validation did not pass.' }
    $sourceCommit = [string]$acceptance.commit
    if ($sourceCommit -ne [string]$sourceSnapshot.commit) {
        throw "Baseline acceptance commit drifted during seed: acceptance=$sourceCommit snapshot=$($sourceSnapshot.commit)"
    }

    $seedRepos = [System.Collections.Generic.List[object]]::new()
    foreach ($repo in @($sourceSnapshot.repositories)) {
        if (-not $repo.present) { continue }
        $branchName = [string]$repo.branch
        if ([string]::IsNullOrWhiteSpace($branchName)) {
            throw "Refusing to seed detached repository '$($repo.relativePath)'."
        }
        $seedRepos.Add([ordered]@{
            relativePath = [string]$repo.relativePath
            role = [string]$repo.role
            path = [string]$repo.path
            commit = [string]$repo.head
            origin = [string]$repo.origin
            branch = $branchName
        }) | Out-Null
    }

    $plan = [ordered]@{
        action = 'seed'
        generation = [int]$state.generation + 1
        release = $Name
        source = [ordered]@{
            instance = 'stable'
            path = $sourceWorkspaceRoot
            commit = $sourceCommit
            repositories = @($seedRepos)
        }
        target = [ordered]@{
            instance = $targetName
            distro = [string]$target.wslDistro
            user = [string]$target.wslUser
            path = $Path
            gitRef = $GitRef
        }
    }
    & wsl.exe -d $target.wslDistro -u $target.wslUser -- test '!' -e $Path
    if ($LASTEXITCODE -ne 0) { throw "Target already exists; refusing to overwrite it: $Path" }
    if ($DryRun) { $plan | ConvertTo-Json -Depth 8; return }

    $seedId = [guid]::NewGuid().ToString('N')
    $stagePath = "$Path.seed-$seedId"
    $bundleDir = Join-Path ([System.IO.Path]::GetTempPath()) "foundation-seed-$seedId"
    New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
    $published = $false
    try {
        $parent = $Path.Substring(0, $Path.LastIndexOf('/'))
        & wsl.exe -d $target.wslDistro -u $target.wslUser -- mkdir -p $parent
        if ($LASTEXITCODE -ne 0) { throw "Failed to create target parent: $parent" }

        foreach ($repo in @($seedRepos)) {
            $leaf = ConvertTo-WorkspaceBundleLeaf -RelativePath ([string]$repo.relativePath)
            $bundleWindows = Join-Path $bundleDir "$leaf.bundle"
            $bundleWsl = ConvertTo-WslPath -WindowsPath $bundleWindows
            & wsl.exe -d $source.wslDistro -u $source.wslUser -- git -C $repo.path bundle create $bundleWsl HEAD
            if ($LASTEXITCODE -ne 0) { throw "Failed to create seed bundle for $($repo.relativePath)." }

            if ($repo.relativePath -eq '.') {
                $cloneTarget = $stagePath
            } else {
                $cloneTarget = Join-WorkspaceRelativePath -WorkspaceRoot $stagePath -RelativePath ([string]$repo.relativePath)
                $cloneParent = $cloneTarget.Substring(0, $cloneTarget.LastIndexOf('/'))
                & wsl.exe -d $target.wslDistro -u $target.wslUser -- mkdir -p $cloneParent
                if ($LASTEXITCODE -ne 0) { throw "Failed to create staging parent for $($repo.relativePath)." }
            }

            & wsl.exe -d $target.wslDistro -u $target.wslUser -- git clone $bundleWsl $cloneTarget
            if ($LASTEXITCODE -ne 0) { throw "Failed to clone seed bundle for $($repo.relativePath)." }

            if ($repo.relativePath -eq '.') {
                & wsl.exe -d $target.wslDistro -u $target.wslUser -- git -C $cloneTarget switch -c $GitRef $sourceCommit
                if ($LASTEXITCODE -ne 0) { throw "Failed to create candidate branch '$GitRef'." }
            } else {
                $childBranch = [string]$repo.branch
                & wsl.exe -d $target.wslDistro -u $target.wslUser -- git -C $cloneTarget switch -c $childBranch ([string]$repo.commit)
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create branch '$childBranch' for $($repo.relativePath)."
                }
                $clonedHead = ("$(& wsl.exe -d $target.wslDistro -u $target.wslUser -- git -C $cloneTarget rev-parse HEAD)").Trim()
                if ([string]::IsNullOrWhiteSpace($clonedHead)) {
                    throw "Failed to read staged HEAD for $($repo.relativePath)."
                }
                if ($clonedHead -ne [string]$repo.commit) {
                    throw "Staged HEAD mismatch for $($repo.relativePath): expected $($repo.commit), actual $clonedHead"
                }
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$repo.origin)) {
                & wsl.exe -d $target.wslDistro -u $target.wslUser -- git -C $cloneTarget remote set-url origin ([string]$repo.origin)
                if ($LASTEXITCODE -ne 0) { throw "Failed to restore origin for $($repo.relativePath)." }
            }

            # PS 5.1: [string]$null stays $null for empty native output; "$()" yields "".
            $sourceUserName = ("$(& wsl.exe -d $source.wslDistro -u $source.wslUser -- git -C $repo.path config --local --get user.name 2>$null)").Trim()
            $sourceUserEmail = ("$(& wsl.exe -d $source.wslDistro -u $source.wslUser -- git -C $repo.path config --local --get user.email 2>$null)").Trim()
            if ($sourceUserName) {
                & wsl.exe -d $target.wslDistro -u $target.wslUser -- git -C $cloneTarget config --local user.name $sourceUserName
                if ($LASTEXITCODE -ne 0) { throw "Failed to copy user.name for $($repo.relativePath)." }
            }
            if ($sourceUserEmail) {
                & wsl.exe -d $target.wslDistro -u $target.wslUser -- git -C $cloneTarget config --local user.email $sourceUserEmail
                if ($LASTEXITCODE -ne 0) { throw "Failed to copy user.email for $($repo.relativePath)." }
            }
        }

        # Machine-local Claude settings are gitignored; copy explicitly when present.
        $settingsCopied = $false
        $sourceSettings = "$sourceWorkspaceRoot/.claude/settings.local.json"
        & wsl.exe -d $source.wslDistro -u $source.wslUser -- test -f $sourceSettings
        if ($LASTEXITCODE -eq 0) {
            & wsl.exe -d $target.wslDistro -u $target.wslUser -- mkdir -p "$stagePath/.claude"
            if ($LASTEXITCODE -ne 0) { throw 'Failed to create staging .claude directory.' }
            # Cross-distro copy via Windows temp when source and target distros differ.
            $settingsTemp = Join-Path $bundleDir 'settings.local.json'
            $settingsTempWslSource = ConvertTo-WslPath -WindowsPath $settingsTemp
            # Source distro may not see the Windows path the same way; use cat redirect from source to a shared path.
            # Prefer piping through Windows when distros differ.
            if ([string]$source.wslDistro -eq [string]$target.wslDistro) {
                & wsl.exe -d $source.wslDistro -u $source.wslUser -- cp -a $sourceSettings "$stagePath/.claude/settings.local.json"
                if ($LASTEXITCODE -ne 0) { throw 'Failed to copy .claude/settings.local.json into staging.' }
            } else {
                $content = & wsl.exe -d $source.wslDistro -u $source.wslUser -- cat $sourceSettings
                if ($LASTEXITCODE -ne 0) { throw 'Failed to read source .claude/settings.local.json' }
                $text = (($content | ForEach-Object { [string]$_ }) -join "`n")
                if (-not $text.EndsWith("`n")) { $text += "`n" }
                [System.IO.File]::WriteAllText($settingsTemp, $text.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
                # Avoid piping into bash -s: PowerShell appends CRLF and breaks the script.
                # Both distros can read the Windows temp path via /mnt/c/...
                & wsl.exe -d $target.wslDistro -u $target.wslUser -- cp -a $settingsTempWslSource "$stagePath/.claude/settings.local.json"
                if ($LASTEXITCODE -ne 0) { throw 'Failed to copy .claude/settings.local.json across distros.' }
            }
            $settingsCopied = $true
        }

        # ~/local-data is a shared store (symlinked per WSL home); restore gitignored
        # files (HANDOFF.md, ISSUES.md, ...) into the staged candidate on the target
        # instance. Cross-distro copying is unnecessary: the store itself is shared,
        # so running local-data.sh on the target instance is sufficient.
        $targetHome = Assert-AbsolutePosixPath -Path ([string]$target.wslHome) -Context "Environment config.instances.$targetName.wslHome"
        $targetLocalData = "$targetHome/local-data"
        & wsl.exe -d $target.wslDistro -u $target.wslUser -- test -e $targetLocalData
        if ($LASTEXITCODE -ne 0) {
            throw "local-data store not found on target instance (expected symlink): $targetLocalData"
        }
        # Merge stderr inside WSL (same shape as Get-LocalDataStatus). A fatal
        # local-data.sh failure writes its reason to stderr, and Windows PowerShell
        # 5.1 turns a captured `2>&1` into NativeCommandError, which under
        # $ErrorActionPreference='Stop' would abort seed instead of recording the
        # failure on $plan.localDataPull (pwsh 7 does not throw).
        $quotedPullScript = ConvertTo-PosixSingleQuoted -Value "$targetLocalData/local-data.sh"
        $quotedStagePath = ConvertTo-PosixSingleQuoted -Value $stagePath
        $pullBatch = ("set -- $quotedPullScript $quotedStagePath`n" +
            '"$1" pull "$2" 2>&1' +
            "`n# end of local-data pull") -replace "`r`n", "`n"
        $localDataPullOutput = @($pullBatch | & wsl.exe -d $target.wslDistro -u $target.wslUser -- bash -s | ForEach-Object { [string]$_ })
        $localDataPullExitCode = $LASTEXITCODE

        $rootAfterMeta = Update-FoundationReleaseMetadata `
            -Distro ([string]$target.wslDistro) `
            -User ([string]$target.wslUser) `
            -RootPath $stagePath `
            -ReleaseName $Name `
            -ParentCommit $sourceCommit

        $stagedSnapshot = Get-ReleaseWorkspaceSnapshot `
            -Instance $target `
            -WorkspaceRoot $stagePath `
            -GitRef $GitRef `
            -DeclaredRepositories $declared `
            -Channel run `
            -EnforceMembership
        if ($stagedSnapshot.errors.Count -gt 0 -or -not $stagedSnapshot.seedReady -or @($stagedSnapshot.undeclaredRepositories).Count -gt 0) {
            throw "Staged run workspace failed verification: $($stagedSnapshot.errors -join '; '); dirty=$($stagedSnapshot.dirtyRepositories -join ','); undeclared=$(@($stagedSnapshot.undeclaredRepositories) -join ',')"
        }
        Assert-NamedBranches -Snapshot $stagedSnapshot -Label 'Staged run workspace'
        if ([string]$stagedSnapshot.commit -ne $rootAfterMeta) {
            throw "Staged root commit mismatch after metadata commit: expected $rootAfterMeta, actual $($stagedSnapshot.commit)"
        }
        foreach ($repo in @($seedRepos)) {
            if ($repo.relativePath -eq '.') { continue }
            $staged = @($stagedSnapshot.repositories | Where-Object { $_.relativePath -eq $repo.relativePath })
            if ($staged.Count -ne 1 -or [string]$staged[0].head -ne [string]$repo.commit) {
                throw "Staged commit mismatch for $($repo.relativePath)."
            }
            if ([string]$staged[0].branch -ne [string]$repo.branch) {
                throw "Staged branch mismatch for $($repo.relativePath): expected $($repo.branch), actual $($staged[0].branch)"
            }
        }

        & wsl.exe -d $target.wslDistro -u $target.wslUser -- mv $stagePath $Path
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to publish seeded run at '$Path'. Staging remains at '$stagePath'."
        }
        $published = $true

        $plan['settingsLocalCopied'] = $settingsCopied
        $plan['localDataPull'] = [ordered]@{
            store = $targetLocalData
            exitCode = $localDataPullExitCode
            output = @($localDataPullOutput)
        }
        $plan['runRootCommit'] = $rootAfterMeta
        $state.run = [ordered]@{ name = $Name; instance = 'candidate'; path = $Path; gitRef = $GitRef }
        $state.generation = [int]$state.generation + 1
        $transition = [ordered]@{
            action = 'seed'
            at = [DateTimeOffset]::Now.ToString('o')
            release = $Name
            commit = $rootAfterMeta
        }
        $state.lastTransition = $transition
        $history = [System.Collections.Generic.List[object]]::new()
        if ($state.PSObject.Properties.Name -contains 'transitionHistory') {
            foreach ($entry in @($state.transitionHistory)) { $history.Add($entry) }
        }
        $history.Add($transition)
        $historyArray = $history.ToArray()
        $state | Add-Member -MemberType NoteProperty -Name transitionHistory -Value $historyArray -Force
        try {
            Write-ReleaseStateAtomic -StatePath $StatePath -State $state
        } catch {
            throw "Run published at '$Path' but release state write failed. Leave the path in place for recovery. $($_.Exception.Message)"
        }
        $plan | ConvertTo-Json -Depth 8
    } finally {
        if (Test-Path -LiteralPath $bundleDir) {
            Remove-Item -LiteralPath $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not $published) {
            & wsl.exe -d $target.wslDistro -u $target.wslUser -- rm -rf $stagePath 2>$null | Out-Null
        }
    }
} finally {
    Exit-ReleaseStateLock -Lock $lock
}
