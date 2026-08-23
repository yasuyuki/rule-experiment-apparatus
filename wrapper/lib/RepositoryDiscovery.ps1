$ErrorActionPreference = 'Stop'

function Get-RepositoryDiscoveryReasons {
    param(
        [Parameter(Mandatory)] [string]$Leaf,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Origin,
        [Parameter(Mandatory)] [string[]]$NamePatterns,
        [Parameter(Mandatory)] [string[]]$Origins
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in @($NamePatterns)) {
        if ($Leaf -like $pattern) {
            $reasons.Add("namePattern:$pattern")
            break
        }
    }
    foreach ($configuredOrigin in @($Origins)) {
        if ($Origin -eq $configuredOrigin) {
            $reasons.Add("origin:$configuredOrigin")
            break
        }
    }
    return @($reasons)
}

function Join-WorkspaceRelativePath {
    param(
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [Parameter(Mandatory)] [string]$RelativePath
    )

    $relative = Assert-WorkspaceRelativePath -RelativePath $RelativePath
    $root = $WorkspaceRoot.TrimEnd('/').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($root) -or -not $root.StartsWith('/')) {
        throw "Workspace root must be an absolute POSIX path: '$WorkspaceRoot'."
    }
    return "$root/$relative"
}

function Test-PathIsUnderWorkspaceRoot {
    param(
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [Parameter(Mandatory)] [string]$CandidatePath
    )

    $root = $WorkspaceRoot.TrimEnd('/').Replace('\', '/')
    $candidate = $CandidatePath.TrimEnd('/').Replace('\', '/')
    if ($candidate -eq $root) { return $true }
    return $candidate.StartsWith("$root/")
}

function Resolve-ReleaseChannelForPath {
    param(
        [Parameter(Mandatory)] [hashtable]$ReleaseByExactPath,
        [Parameter(Mandatory)] [hashtable]$ReleaseByInstancePathPrefix,
        [Parameter(Mandatory)] [string]$InstanceName,
        [Parameter(Mandatory)] [string]$Path
    )

    $exactKey = "$InstanceName|$Path"
    if ($ReleaseByExactPath.ContainsKey($exactKey)) {
        return [string]$ReleaseByExactPath[$exactKey]
    }

    $normalized = $Path.TrimEnd('/')
    foreach ($entry in @($ReleaseByInstancePathPrefix[$InstanceName])) {
        $root = [string]$entry.path
        if (Test-PathIsUnderWorkspaceRoot -WorkspaceRoot $root -CandidatePath $normalized) {
            return [string]$entry.channel
        }
    }
    return 'retired-unreferenced'
}

function New-WorkspaceRepositoryStatus {
    param(
        [Parameter(Mandatory)] [string]$RelativePath,
        [Parameter(Mandatory)] [bool]$Declared,
        [Parameter(Mandatory)] [bool]$Present,
        [AllowNull()] [string]$ExpectedOrigin,
        [AllowNull()] [string]$Origin,
        [AllowNull()] [string]$Head,
        [AllowNull()] [string]$Branch,
        [AllowNull()] [object]$Dirty,
        [Parameter(Mandatory)] [string]$Channel,
        [string]$Role = 'project',
        [bool]$PathEscapesWorkspace = $false,
        [string]$ResolvedPath = $null
    )

    # The release root carries no declared origin (release state names it), so
    # there is nothing to compare. Report that as null rather than claiming a
    # match or a mismatch that was never checked.
    $originMatches = if ([string]::IsNullOrWhiteSpace($ExpectedOrigin)) {
        $null
    } elseif ($Present -and -not [string]::IsNullOrWhiteSpace($Origin)) {
        ($Origin -eq $ExpectedOrigin)
    } else {
        $false
    }

    return [ordered]@{
        relativePath = $RelativePath
        role = $Role
        declared = $Declared
        present = $Present
        expectedOrigin = $ExpectedOrigin
        origin = $Origin
        originMatches = $originMatches
        head = $Head
        branch = $Branch
        dirty = $Dirty
        channel = $Channel
        pathEscapesWorkspace = $PathEscapesWorkspace
        path = $ResolvedPath
    }
}

function Invoke-WslGitText {
    param(
        [Parameter(Mandatory)] [string]$Distro,
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string[]]$GitArguments,
        [switch]$AllowFail
    )

    $output = @(& wsl.exe -d $Distro -u $User -- git -C $Path @GitArguments 2>&1)
    if (-not $AllowFail -and $LASTEXITCODE -ne 0) {
        throw "Git failed for ${Distro}:${Path} ($($GitArguments -join ' ')): $($output -join ' ')"
    }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-WslCommandText {
    param(
        [Parameter(Mandatory)] [string]$Distro,
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [switch]$AllowFail
    )

    $output = @(& wsl.exe -d $Distro -u $User -- @Arguments 2>&1)
    if (-not $AllowFail -and $LASTEXITCODE -ne 0) {
        throw "WSL command failed for ${Distro} ($($Arguments -join ' ')): $($output -join ' ')"
    }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function ConvertTo-WorkspaceBundleLeaf {
    param([Parameter(Mandatory)] [string]$RelativePath)

    if ($RelativePath -eq '.') { return 'root' }
    return ($RelativePath -replace '/', '__')
}

function ConvertTo-PosixSingleQuoted {
    param([Parameter(Mandatory)] [string]$Value)

    if ($Value.Contains([char]0) -or $Value.Contains("`n") -or $Value.Contains("`r")) {
        throw "Path cannot be passed to WSL because it contains a control character: '$Value'."
    }
    return "'" + ($Value -replace "'", "'\''") + "'"
}

# One wsl.exe launch costs roughly a quarter second, so inspecting a workspace
# one git command at a time dominates the runtime of every reference command.
# Collect the whole batch in a single shell.
#
# The script travels on stdin: wsl.exe rebuilds its argument list into a command
# string for the login shell, so neither argv nor a nested `bash -c` string
# preserves quoting. PowerShell terminates a piped string with CRLF, hence the
# trailing comment line that absorbs the stray carriage return.
$script:RepositoryBatchScript = @'
for p in "$@"; do
  printf '%s\037' "$p"
  printf '%s\037' "$(realpath -m "$p" 2>/dev/null)"
  if [ -e "$p/.git" ]; then
    printf '1\037%s\037%s\037%s\037%s\037' \
      "$(git -C "$p" rev-parse HEAD 2>/dev/null)" \
      "$(git -C "$p" branch --show-current 2>/dev/null)" \
      "$(git -C "$p" remote get-url origin 2>/dev/null)" \
      "$(git -C "$p" status --short 2>/dev/null)"
    if [ "$INCLUDE_REMOTE_CONTAINS" = 1 ]; then
      printf '%s\037' "$(git -C "$p" branch -r --contains HEAD 2>/dev/null)"
    else
      printf '\037'
    fi
  else
    printf '0\037\037\037\037\037'
  fi
  printf '\036'
done
# end of batch
'@

function Invoke-WslRepositoryBatch {
    param(
        [Parameter(Mandatory)] [string]$Distro,
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Paths,
        [switch]$IncludeRemoteContains
    )

    $results = @{}
    $unique = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($unique.Count -eq 0) { return $results }

    $quoted = ($unique | ForEach-Object { ConvertTo-PosixSingleQuoted -Value $_ }) -join ' '
    $remoteFlag = if ($IncludeRemoteContains) { '1' } else { '0' }
    $prelude = "INCLUDE_REMOTE_CONTAINS=$remoteFlag`nset -- $quoted`n"
    $batch = ($prelude + $script:RepositoryBatchScript) -replace "`r`n", "`n"
    $output = $batch | & wsl.exe -d $Distro -u $User -- bash -s
    if ($LASTEXITCODE -ne 0) {
        throw "Repository batch inspection failed for ${Distro} (exit $LASTEXITCODE)."
    }

    $text = (($output | ForEach-Object { [string]$_ }) -join "`n")
    foreach ($record in ($text -split ([char]30))) {
        if ([string]::IsNullOrWhiteSpace($record)) { continue }
        $fields = $record -split ([char]31)
        if ($fields.Count -lt 8) { throw "Malformed repository batch record for ${Distro}: '$record'" }
        $path = $fields[0]
        $changes = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($fields[6] -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $changes.Add($line) }
        }
        $remoteBranches = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($fields[7] -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $remoteBranches.Add($line.Trim()) }
        }
        $present = ($fields[2] -eq '1')
        $results[$path] = [ordered]@{
            present = $present
            path = $path
            realPath = if ([string]::IsNullOrWhiteSpace($fields[1])) { $path } else { $fields[1].TrimEnd('/') }
            head = if ($present) { $fields[3] } else { $null }
            branch = if ($present) { $fields[4] } else { $null }
            origin = if ($present) { $fields[5] } else { $null }
            dirty = if ($present) { ($changes.Count -gt 0) } else { $null }
            changes = @($changes)
            originContainsHead = ($remoteBranches.Count -gt 0)
        }
    }

    foreach ($path in $unique) {
        if (-not $results.ContainsKey($path)) {
            throw "Repository batch inspection returned no record for ${Distro}:${path}."
        }
    }
    return $results
}

function Get-GitRepositorySnapshot {
    param(
        [Parameter(Mandatory)] [string]$Distro,
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [string]$Path,
        [string]$ExpectedOrigin = $null
    )

    & wsl.exe -d $Distro -u $User -- test -e "$Path/.git" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return [ordered]@{
            present = $false
            path = $Path
            head = $null
            branch = $null
            origin = $null
            originMatches = $false
            dirty = $null
            changes = @()
        }
    }

    $head = Invoke-WslGitText -Distro $Distro -User $User -Path $Path -GitArguments @('rev-parse', 'HEAD')
    $branch = Invoke-WslGitText -Distro $Distro -User $User -Path $Path -GitArguments @('branch', '--show-current')
    $origin = Invoke-WslGitText -Distro $Distro -User $User -Path $Path -GitArguments @('remote', 'get-url', 'origin') -AllowFail
    if ($LASTEXITCODE -ne 0) { $origin = '' }
    $status = Invoke-WslGitText -Distro $Distro -User $User -Path $Path -GitArguments @('status', '--short')
    $changes = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        foreach ($line in ($status -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $changes.Add($line) }
        }
    }
    $originMatches = $false
    if (-not [string]::IsNullOrWhiteSpace($ExpectedOrigin) -and -not [string]::IsNullOrWhiteSpace($origin)) {
        $originMatches = ($origin -eq $ExpectedOrigin)
    }

    return [ordered]@{
        present = $true
        path = $Path
        head = $head
        branch = $branch
        origin = $origin
        originMatches = $originMatches
        dirty = ($changes.Count -gt 0)
        changes = @($changes)
    }
}

function Find-UndeclaredWorkspaceGitRepos {
    param(
        [Parameter(Mandatory)] [string]$Distro,
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [AllowEmptyCollection()] [string[]]$DeclaredRelativePaths
    )

    $root = $WorkspaceRoot.TrimEnd('/')
    # Workspace membership is defined one level below the root, so bound the
    # scan the same way the inventory does. Without -maxdepth, a vendored .git
    # under node_modules would be reported as an undeclared repository and
    # would fail candidate acceptance.
    $findOutput = Get-WslCommandText -Distro $Distro -User $User -Arguments @(
        'find', $root, '-mindepth', '2', '-maxdepth', '2', '-name', '.git'
    ) -AllowFail
    if ($LASTEXITCODE -gt 1) {
        throw "Failed to scan workspace Git repositories under ${Distro}:${root}"
    }

    $declared = @{}
    foreach ($relative in @($DeclaredRelativePaths)) {
        $declared[$relative] = $true
    }

    $undeclared = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($findOutput)) { return @() }
    foreach ($gitEntry in ($findOutput -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($gitEntry)) { continue }
        $repoPath = $gitEntry.TrimEnd('/').Replace('\', '/')
        if ($repoPath.EndsWith('/.git')) {
            $repoPath = $repoPath.Substring(0, $repoPath.Length - 5)
        } elseif ($repoPath.EndsWith('.git')) {
            $repoPath = $repoPath.Substring(0, $repoPath.Length - 4).TrimEnd('/')
        }
        if (-not (Test-PathIsUnderWorkspaceRoot -WorkspaceRoot $root -CandidatePath $repoPath)) { continue }
        if ($repoPath -eq $root) { continue }
        $relative = $repoPath.Substring($root.Length + 1)
        if ($declared.ContainsKey($relative)) { continue }
        $undeclared.Add($relative)
    }
    return @($undeclared | Select-Object -Unique | Sort-Object)
}

function Get-ReleaseWorkspaceSnapshot {
    param(
        [Parameter(Mandatory)] [object]$Instance,
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [Parameter(Mandatory)] [string]$GitRef,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$DeclaredRepositories,
        [Parameter(Mandatory)] [string]$Channel,
        [switch]$EnforceMembership
    )

    $distro = [string]$Instance.wslDistro
    $user = [string]$Instance.wslUser
    $root = $WorkspaceRoot.TrimEnd('/').Replace('\', '/')

    $childPathByRelative = [ordered]@{}
    foreach ($entry in @($DeclaredRepositories)) {
        $relative = [string]$entry.relativePath
        $childPathByRelative[$relative] = Join-WorkspaceRelativePath -WorkspaceRoot $root -RelativePath $relative
    }
    $batch = Invoke-WslRepositoryBatch -Distro $distro -User $user -Paths (@($root) + @($childPathByRelative.Values))

    $rootSnap = $batch[$root]
    if (-not $rootSnap.present) {
        throw "Not a Git repository: ${distro}:${root}"
    }
    $refCommit = Invoke-WslGitText -Distro $distro -User $user -Path $root -GitArguments @('rev-parse', $GitRef)

    $repos = [System.Collections.Generic.List[object]]::new()
    $repos.Add((New-WorkspaceRepositoryStatus `
        -RelativePath '.' `
        -Declared $true `
        -Present $true `
        -ExpectedOrigin $null `
        -Origin ([string]$rootSnap.origin) `
        -Head ([string]$rootSnap.head) `
        -Branch ([string]$rootSnap.branch) `
        -Dirty ([bool]$rootSnap.dirty) `
        -Channel $Channel `
        -Role 'release-root' `
        -ResolvedPath $root)) | Out-Null

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($rootSnap.head -ne $refCommit) {
        $errors.Add("HEAD/ref mismatch: HEAD=$($rootSnap.head) ref=$GitRef resolved=$refCommit")
    }

    foreach ($entry in @($DeclaredRepositories)) {
        $relative = [string]$entry.relativePath
        $expectedOrigin = [string]$entry.origin
        $childPath = $childPathByRelative[$relative]
        $childSnap = $batch[$childPath]
        $resolved = [string]$childSnap.realPath
        if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = $childPath }
        $escapes = -not (Test-PathIsUnderWorkspaceRoot -WorkspaceRoot $root -CandidatePath $resolved)
        if ($escapes) {
            $errors.Add("Declared repository path escapes workspace: $relative -> $resolved")
            $repos.Add((New-WorkspaceRepositoryStatus `
                -RelativePath $relative `
                -Declared $true `
                -Present $false `
                -ExpectedOrigin $expectedOrigin `
                -Channel $Channel `
                -PathEscapesWorkspace $true `
                -ResolvedPath $resolved)) | Out-Null
            continue
        }

        $originMatches = ($childSnap.present -and
            -not [string]::IsNullOrWhiteSpace($expectedOrigin) -and
            [string]$childSnap.origin -eq $expectedOrigin)
        if (-not $childSnap.present) {
            $errors.Add("Missing declared repository: $relative")
        } elseif (-not $originMatches) {
            $errors.Add("Origin mismatch for ${relative}: expected $expectedOrigin, actual $($childSnap.origin)")
        }
        $repos.Add((New-WorkspaceRepositoryStatus `
            -RelativePath $relative `
            -Declared $true `
            -Present ([bool]$childSnap.present) `
            -ExpectedOrigin $expectedOrigin `
            -Origin $(if ($childSnap.present) { [string]$childSnap.origin } else { $null }) `
            -Head $(if ($childSnap.present) { [string]$childSnap.head } else { $null }) `
            -Branch $(if ($childSnap.present) { [string]$childSnap.branch } else { $null }) `
            -Dirty $(if ($childSnap.present) { [bool]$childSnap.dirty } else { $null }) `
            -Channel $Channel `
            -PathEscapesWorkspace $false `
            -ResolvedPath $childPath)) | Out-Null
    }

    $undeclared = @()
    if ($EnforceMembership) {
        $undeclared = @(Find-UndeclaredWorkspaceGitRepos `
            -Distro $distro `
            -User $user `
            -WorkspaceRoot $root `
            -DeclaredRelativePaths @($DeclaredRepositories | ForEach-Object { [string]$_.relativePath }))
        foreach ($relative in $undeclared) {
            $message = "Undeclared Git repository under workspace: $relative"
            if ($Channel -eq 'run') {
                $errors.Add($message)
            } else {
                $warnings.Add($message)
            }
        }
    }

    $dirtyRepos = @($repos | Where-Object { $_.present -and $_.dirty } | ForEach-Object { $_.relativePath })
    $missingDeclared = @($repos | Where-Object { $_.declared -and $_.relativePath -ne '.' -and -not $_.present } | ForEach-Object { $_.relativePath })
    $allPresentClean = ($errors.Count -eq 0 -and $dirtyRepos.Count -eq 0 -and $missingDeclared.Count -eq 0)

    return [ordered]@{
        channel = $Channel
        path = $root
        gitRef = $GitRef
        commit = [string]$rootSnap.head
        refCommit = $refCommit
        refMatchesHead = ($rootSnap.head -eq $refCommit)
        clean = ($dirtyRepos.Count -eq 0)
        dirtyRepositories = $dirtyRepos
        missingDeclared = $missingDeclared
        undeclaredRepositories = $undeclared
        errors = @($errors)
        warnings = @($warnings)
        seedReady = $allPresentClean
        repositories = @($repos)
        rootChanges = @($rootSnap.changes)
    }
}
