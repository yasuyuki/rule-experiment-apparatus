$ErrorActionPreference = 'Stop'

$script:ConfigurationWrapperRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ConfigurationWorkspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $script:ConfigurationWrapperRoot '..\..'))

function Get-ConfigurationWrapperRoot {
    return $script:ConfigurationWrapperRoot
}

function Get-ConfigurationWorkspaceRoot {
    return $script:ConfigurationWorkspaceRoot
}

function Get-JsonProperty {
    param(
        [Parameter(Mandatory)] [object]$Object,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$DocumentName
    )

    if ($null -eq $Object) { throw "$DocumentName is null; expected property '$Name'." }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { throw "$DocumentName is missing required property '$Name'." }
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$DocumentName is missing required property '$Name'." }
    return $property.Value
}

function Get-OptionalJsonProperty {
    param(
        [Parameter(Mandatory)] [object]$Object,
        [Parameter(Mandatory)] [string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $null }
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Assert-AbsolutePosixPath {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Context
    )

    $normalized = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "$Context is empty."
    }
    if ($normalized.Contains('\') -or $normalized.Contains([char]0)) {
        throw "$Context must be a POSIX path without backslashes: '$Path'."
    }
    if (-not $normalized.StartsWith('/')) {
        throw "$Context must be an absolute POSIX path: '$Path'."
    }
    if ($normalized -match '/\.\.(/|$)|/\.(/|$)') {
        throw "$Context must not contain '.' or '..' segments: '$Path'."
    }
    return $normalized.TrimEnd('/')
}

function Get-ConfiguredReleasesRoot {
    param(
        [Parameter(Mandatory)] [object]$Instance,
        [string]$InstanceName = 'instance'
    )

    $raw = Get-OptionalJsonProperty -Object $Instance -Name 'releasesRoot'
    if ($null -eq $raw) { return $null }
    $text = [string]$raw
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return (Assert-AbsolutePosixPath -Path $text -Context "Environment config.instances.$InstanceName.releasesRoot")
}

function Resolve-DefaultReleaseSeedPath {
    param(
        [Parameter(Mandatory)] [object]$Instance,
        [Parameter(Mandatory)] [string]$Name,
        [string]$InstanceName = 'instance'
    )

    if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Release name cannot be used as a safe default directory name: $Name"
    }
    $releasesRoot = Get-ConfiguredReleasesRoot -Instance $Instance -InstanceName $InstanceName
    if ($null -ne $releasesRoot) {
        return "$releasesRoot/$Name"
    }
    $wslHome = Assert-AbsolutePosixPath `
        -Path ([string](Get-JsonProperty -Object $Instance -Name 'wslHome' -DocumentName "Environment config.instances.$InstanceName")) `
        -Context "Environment config.instances.$InstanceName.wslHome"
    return "$wslHome/Projects/$Name"
}

function Get-InstanceInventoryScanRoots {
    param(
        [Parameter(Mandatory)] [object]$Instance,
        [Parameter(Mandatory)] [string]$InstanceName,
        [Parameter(Mandatory)] [object]$State
    )

    $roots = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    function Add-ScanRoot([string]$Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $normalized = Assert-AbsolutePosixPath -Path $Path -Context "inventory scan root ($InstanceName)"
        if ($seen.ContainsKey($normalized)) { return }
        $seen[$normalized] = $true
        $roots.Add($normalized) | Out-Null
    }

    Add-ScanRoot ([string](Get-JsonProperty -Object $Instance -Name 'projectsRoot' -DocumentName "Environment config.instances.$InstanceName"))
    $releasesRoot = Get-ConfiguredReleasesRoot -Instance $Instance -InstanceName $InstanceName
    if ($null -ne $releasesRoot) { Add-ScanRoot $releasesRoot }

    foreach ($role in @('baseline', 'run')) {
        $release = $State.$role
        if (-not $release) { continue }
        if ([string]$release.instance -ne $InstanceName) { continue }
        Add-ScanRoot ([string]$release.path)
    }

    return @($roots.ToArray())
}

function Assert-SupportedSchemaVersion {
    param(
        [Parameter(Mandatory)] [object]$Document,
        [Parameter(Mandatory)] [int[]]$SupportedVersion,
        [string]$DocumentName = 'document'
    )

    $version = Get-JsonProperty -Object $Document -Name 'schemaVersion' -DocumentName $DocumentName
    try { $versionNumber = [int]$version } catch { throw "$DocumentName has an invalid schemaVersion '$version'." }
    if ($SupportedVersion -notcontains $versionNumber) {
        $supported = ($SupportedVersion -join ', ')
        throw "$DocumentName schemaVersion $versionNumber is not supported; expected one of $supported."
    }
    return $versionNumber
}

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Description
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([string]::IsNullOrWhiteSpace($expanded)) { throw "$Description path is empty." }
    $full = [System.IO.Path]::GetFullPath($expanded)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Description not found: $full"
    }
    return $full
}

function Get-LocalEnvironmentConfigPath {
    return Join-Path (Get-ConfigurationWrapperRoot) 'config\environment.local.json'
}

function Read-LocalEnvironmentConfig {
    $path = Get-LocalEnvironmentConfigPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Get-LocalEnvironmentConfigValue {
    param([Parameter(Mandatory)] [string]$Name)

    $local = Read-LocalEnvironmentConfig
    if ($null -eq $local) { return $null }
    $value = Get-OptionalJsonProperty -Object $local -Name $Name
    if ($null -eq $value) { return $null }
    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Resolve-EnvironmentConfigPath {
    param(
        [string]$ConfigPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return Resolve-ExistingPath -Path $ConfigPath -Description 'Environment config'
    }

    $environmentPath = [Environment]::GetEnvironmentVariable('FOUNDATION_CONTROL_CONFIG')
    if (-not [string]::IsNullOrWhiteSpace($environmentPath)) {
        return Resolve-ExistingPath -Path $environmentPath -Description 'Environment config from FOUNDATION_CONTROL_CONFIG'
    }

    $localPath = Get-LocalEnvironmentConfigValue -Name 'configPath'
    if (-not [string]::IsNullOrWhiteSpace($localPath)) {
        return Resolve-ExistingPath -Path $localPath -Description 'Environment config from environment.local.json'
    }

    throw 'No environment config found. Pass -ConfigPath, set FOUNDATION_CONTROL_CONFIG, or create wrapper/config/environment.local.json (New-FoundationLocalConfig.ps1).'
}

function Resolve-ReleaseStatePath {
    param(
        [string]$StatePath
    )

    if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
        return Resolve-ExistingPath -Path $StatePath -Description 'Release state'
    }

    $environmentPath = [Environment]::GetEnvironmentVariable('FOUNDATION_CONTROL_STATE')
    if (-not [string]::IsNullOrWhiteSpace($environmentPath)) {
        return Resolve-ExistingPath -Path $environmentPath -Description 'Release state from FOUNDATION_CONTROL_STATE'
    }

    $localPath = Get-LocalEnvironmentConfigValue -Name 'statePath'
    if (-not [string]::IsNullOrWhiteSpace($localPath)) {
        return Resolve-ExistingPath -Path $localPath -Description 'Release state from environment.local.json'
    }

    # There is deliberately no in-repository fallback. A stale state file next
    # to the implementation would silently route commands at retired releases.
    throw 'No release state found. Pass -StatePath, set FOUNDATION_CONTROL_STATE, or create wrapper/config/environment.local.json (New-FoundationLocalConfig.ps1).'
}

function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory)] [string]$Value,
        [string]$BasePath = (Get-Location).Path
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    if ([string]::IsNullOrWhiteSpace($expanded)) { throw 'Configured path is empty.' }

    # WSL paths are absolute in their own namespace and must not be converted
    # into Windows paths by .NET running on the host.
    if ($expanded.StartsWith('/')) {
        return $expanded.Replace('\', '/')
    }
    if ($expanded -match '^[A-Za-z]:[\\/]' -or $expanded.StartsWith('\\')) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    $baseExpanded = [Environment]::ExpandEnvironmentVariables($BasePath)
    if ([string]::IsNullOrWhiteSpace($baseExpanded)) { throw 'Configured path base is empty.' }
    return [System.IO.Path]::GetFullPath((Join-Path $baseExpanded $expanded))
}

function Assert-ConfigRelativeWindowsPath {
    param(
        [Parameter(Mandatory)] [string]$Value,
        [Parameter(Mandatory)] [string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Context is empty." }
    if ($Value -match '%[^%]+%') {
        throw "$Context must not depend on process environment variables: '$Value'."
    }
    if ($Value.StartsWith('/') -or [System.IO.Path]::IsPathRooted($Value)) {
        throw "$Context must be relative to environment.json: '$Value'."
    }
    return $Value
}

function Test-CursorUserDataAuthenticated {
    param(
        [Parameter(Mandatory)] [string]$UserDataDir
    )

    # Cursor keeps the account session keys in its SQLite state database. Read
    # only the database bytes and look for the key names; never emit token
    # values. A missing, locked, or unreadable database is treated as logged
    # out so a normal launch cannot create another unauthenticated instance.
    $statePath = Join-Path $UserDataDir 'User\globalStorage\state.vscdb'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $false
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $statePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $bytes = [byte[]]::new($stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { return $false }
            $offset += $read
        }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        return $text.Contains('cursorAuth/accessToken') -and $text.Contains('cursorAuth/refreshToken')
    } catch {
        return $false
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-ConfiguredInstance {
    param(
        [Parameter(Mandatory)] [object]$Configuration,
        [Parameter(Mandatory)] [string]$Name
    )

    $instances = Get-JsonProperty -Object $Configuration -Name 'instances' -DocumentName 'Environment config'
    if ($instances -is [System.Collections.IDictionary]) {
        $instance = if ($instances.Contains($Name)) { $instances[$Name] } else { $null }
    } else {
        $property = $instances.PSObject.Properties[$Name]
        $instance = if ($null -eq $property) { $null } else { $property.Value }
    }
    if ($null -eq $instance) {
        throw "Environment config has no instance '$Name'."
    }
    return $instance
}

function Assert-WorkspaceRelativePath {
    param(
        [Parameter(Mandatory)] [string]$RelativePath,
        [string]$Context = 'workspace.repositories.relativePath'
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "$Context is empty."
    }
    if ($RelativePath.Contains('\') -or $RelativePath.Contains([char]0)) {
        throw "$Context must be a POSIX relative path without backslashes: '$RelativePath'."
    }
    if ($RelativePath.StartsWith('/') -or $RelativePath -match '^[A-Za-z]:') {
        throw "$Context must not be absolute: '$RelativePath'."
    }
    if ($RelativePath -eq '.' -or $RelativePath -eq '..') {
        throw "$Context must not be '.' or '..' (root foundation repo is not listed here): '$RelativePath'."
    }

    $segments = $RelativePath -split '/'
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "$Context contains an empty, '.', or '..' segment: '$RelativePath'."
        }
    }
    return $RelativePath
}

function Get-ConfiguredWorkspaceRepositories {
    param([Parameter(Mandatory)] [object]$Configuration)

    $workspace = Get-JsonProperty -Object $Configuration -Name 'workspace' -DocumentName 'Environment config'
    $repositories = Get-JsonProperty -Object $workspace -Name 'repositories' -DocumentName 'Environment config.workspace'
    if ($null -eq $repositories) { $repositories = @() }

    $normalized = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $index = 0
    foreach ($entry in @($repositories)) {
        $context = "Environment config.workspace.repositories[$index]"
        $relativePath = Assert-WorkspaceRelativePath `
            -RelativePath ([string](Get-JsonProperty -Object $entry -Name 'relativePath' -DocumentName $context)) `
            -Context "$context.relativePath"
        $origin = [string](Get-JsonProperty -Object $entry -Name 'origin' -DocumentName $context)
        if ([string]::IsNullOrWhiteSpace($origin)) {
            throw "$context.origin is empty."
        }
        if ($seen.ContainsKey($relativePath)) {
            throw "$context.relativePath duplicates '$relativePath'."
        }
        $seen[$relativePath] = $true
        $normalized.Add([ordered]@{
            relativePath = $relativePath
            origin = $origin
        }) | Out-Null
        $index += 1
    }
    return @($normalized.ToArray())
}

function Assert-EnvironmentConfigSupportsWorkspaceMutation {
    param([Parameter(Mandatory)] [object]$Configuration)

    $null = Get-ConfiguredWorkspaceRepositories -Configuration $Configuration
    return $true
}

function Assert-EnvironmentConfigShape {
    param([Parameter(Mandatory)] [object]$Configuration)

    $null = Assert-SupportedSchemaVersion -Document $Configuration -SupportedVersion @(2) -DocumentName 'Environment config'
    $cursor = Get-JsonProperty -Object $Configuration -Name 'cursor' -DocumentName 'Environment config'
    $executable = Get-JsonProperty -Object $cursor -Name 'executable' -DocumentName 'Environment config.cursor'
    if ([string]::IsNullOrWhiteSpace([string]$executable)) { throw 'Environment config.cursor.executable is empty.' }

    foreach ($instanceName in @('stable', 'candidate')) {
        $instance = Get-ConfiguredInstance -Configuration $Configuration -Name $instanceName
        foreach ($field in @('wslDistro', 'wslUser', 'wslHome', 'projectsRoot')) {
            $value = Get-JsonProperty -Object $instance -Name $field -DocumentName "Environment config.instances.$instanceName"
            if ([string]::IsNullOrWhiteSpace([string]$value)) {
                throw "Environment config.instances.$instanceName.$field is empty."
            }
        }
        $null = Assert-AbsolutePosixPath `
            -Path ([string]$instance.projectsRoot) `
            -Context "Environment config.instances.$instanceName.projectsRoot"
        $null = Assert-AbsolutePosixPath `
            -Path ([string]$instance.wslHome) `
            -Context "Environment config.instances.$instanceName.wslHome"
        $null = Get-ConfiguredReleasesRoot -Instance $instance -InstanceName $instanceName
        foreach ($field in @('userProfile', 'userDataDir', 'extensionsDir')) {
            $value = Get-JsonProperty -Object $instance -Name $field -DocumentName "Environment config.instances.$instanceName"
            if ($null -ne $value) {
                $null = Assert-ConfigRelativeWindowsPath `
                    -Value ([string]$value) `
                    -Context "Environment config.instances.$instanceName.$field"
            }
        }
    }

    $controlPlane = Get-JsonProperty -Object $Configuration -Name 'controlPlane' -DocumentName 'Environment config'
    $gitInstance = [string](Get-JsonProperty -Object $controlPlane -Name 'gitInstance' -DocumentName 'Environment config.controlPlane')
    if ([string]::IsNullOrWhiteSpace($gitInstance)) { throw 'Environment config.controlPlane.gitInstance is empty.' }
    $null = Get-ConfiguredInstance -Configuration $Configuration -Name $gitInstance

    $discovery = Get-JsonProperty -Object $Configuration -Name 'repositoryDiscovery' -DocumentName 'Environment config'
    $namePatterns = Get-JsonProperty -Object $discovery -Name 'namePatterns' -DocumentName 'Environment config.repositoryDiscovery'
    $origins = Get-JsonProperty -Object $discovery -Name 'origins' -DocumentName 'Environment config.repositoryDiscovery'
    if (@($namePatterns).Count -eq 0) { throw 'Environment config.repositoryDiscovery.namePatterns must not be empty.' }
    # An empty array is emitted as no pipeline object by PowerShell functions;
    # the property itself was already checked by Get-JsonProperty.
    if ($null -eq $origins) { $origins = @() }

    $storage = Get-JsonProperty -Object $Configuration -Name 'storage' -DocumentName 'Environment config'
    foreach ($field in @('backupRoot', 'verificationRoot', 'localDataRoot')) {
        $value = Get-JsonProperty -Object $storage -Name $field -DocumentName 'Environment config.storage'
        if ([string]::IsNullOrWhiteSpace([string]$value)) { throw "Environment config.storage.$field is empty." }
        if ($field -ne 'localDataRoot') {
            $null = Assert-ConfigRelativeWindowsPath `
                -Value ([string]$value) `
                -Context "Environment config.storage.$field"
        }
    }

    $projects = Get-JsonProperty -Object $Configuration -Name 'projects' -DocumentName 'Environment config'
    foreach ($project in $projects.PSObject.Properties) {
        foreach ($target in $project.Value.PSObject.Properties) {
            $context = "Environment config.projects.$($project.Name).$($target.Name)"
            $kind = [string](Get-JsonProperty -Object $target.Value -Name 'kind' -DocumentName $context)
            $path = [string](Get-JsonProperty -Object $target.Value -Name 'path' -DocumentName $context)
            if ($kind -eq 'windows') {
                $null = Assert-ConfigRelativeWindowsPath -Value $path -Context "$context.path"
            } elseif ($kind -eq 'wsl') {
                $null = Assert-AbsolutePosixPath -Path $path -Context "$context.path"
            } elseif ($kind -eq 'ssh') {
                if ([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '^/[A-Za-z0-9._/-]*$') {
                    throw "$context.path must be a safe absolute POSIX path."
                }
                $authority = [string](Get-JsonProperty -Object $target.Value -Name 'authority' -DocumentName $context)
                if ($authority -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                    throw "$context.authority must be a safe SSH authority name."
                }
                $expectedUser = [string](Get-JsonProperty -Object $target.Value -Name 'expectedUser' -DocumentName $context)
                if ($expectedUser -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
                    throw "$context.expectedUser must be a safe SSH user name."
                }
            } else {
                throw "$context.kind is unsupported: '$kind'."
            }
        }
    }
    $null = Get-ConfiguredWorkspaceRepositories -Configuration $Configuration
    return $true
}

function Read-EnvironmentConfig {
    param(
        [string]$ConfigPath
    )

    $resolvedPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
    try {
        $document = Get-Content -Raw -LiteralPath $resolvedPath | ConvertFrom-Json
    } catch {
        throw "Could not parse environment config '$resolvedPath': $($_.Exception.Message)"
    }

    Assert-EnvironmentConfigShape -Configuration $document | Out-Null
    return $document
}

function Resolve-BackupRoot {
    param(
        [string]$BackupRoot,
        [object]$Configuration,
        [string]$ConfigurationPath,
        [string]$BasePath = (Get-Location).Path
    )

    if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
        return Resolve-ConfiguredPath -Value $BackupRoot -BasePath $BasePath
    }
    $environmentPath = [Environment]::GetEnvironmentVariable('FOUNDATION_CONTROL_BACKUP_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($environmentPath)) {
        return Resolve-ConfiguredPath -Value $environmentPath -BasePath $BasePath
    }
    $localPath = Get-LocalEnvironmentConfigValue -Name 'backupRoot'
    if (-not [string]::IsNullOrWhiteSpace($localPath)) {
        return Resolve-ConfiguredPath -Value $localPath -BasePath $BasePath
    }
    if ($null -ne $Configuration) {
        if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
            throw 'ConfigurationPath is required when backupRoot comes from environment.json.'
        }
        $storage = Get-JsonProperty -Object $Configuration -Name 'storage' -DocumentName 'Environment config'
        $configuredPath = Get-JsonProperty -Object $storage -Name 'backupRoot' -DocumentName 'Environment config.storage'
        return Resolve-ConfiguredPath -Value ([string]$configuredPath) -BasePath (Split-Path -Parent ([System.IO.Path]::GetFullPath($ConfigurationPath)))
    }
    throw 'No backup root found. Pass -BackupRoot, set FOUNDATION_CONTROL_BACKUP_ROOT, set environment.local.json backupRoot, or provide an environment configuration.'
}

function Resolve-ReviewRoot {
    param(
        [string]$ReviewRoot,
        [string]$StatePath,
        [string]$BasePath = (Get-Location).Path
    )

    if (-not [string]::IsNullOrWhiteSpace($ReviewRoot)) {
        return Resolve-ConfiguredPath -Value $ReviewRoot -BasePath $BasePath
    }
    $environmentPath = [Environment]::GetEnvironmentVariable('FOUNDATION_CONTROL_REVIEW_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($environmentPath)) {
        return Resolve-ConfiguredPath -Value $environmentPath -BasePath $BasePath
    }
    $localPath = Get-LocalEnvironmentConfigValue -Name 'reviewRoot'
    if (-not [string]::IsNullOrWhiteSpace($localPath)) {
        return Resolve-ConfiguredPath -Value $localPath -BasePath $BasePath
    }
    # Default: a `reviews` folder next to release-state.json, so a fresh
    # private-control checkout gets review records for free without any
    # additional configuration.
    $resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
    $stateParent = Split-Path -Parent $resolvedStatePath
    return [System.IO.Path]::GetFullPath((Join-Path $stateParent 'reviews'))
}

function Resolve-VerificationRoot {
    param(
        [string]$VerificationRoot,
        [Parameter(Mandatory)] [object]$Configuration,
        [Parameter(Mandatory)] [string]$ConfigurationPath,
        [string]$BasePath = (Get-Location).Path
    )

    if (-not [string]::IsNullOrWhiteSpace($VerificationRoot)) {
        return Resolve-ConfiguredPath -Value $VerificationRoot -BasePath $BasePath
    }
    $storage = Get-JsonProperty -Object $Configuration -Name 'storage' -DocumentName 'Environment config'
    $configuredPath = Get-JsonProperty -Object $storage -Name 'verificationRoot' -DocumentName 'Environment config.storage'
    return Resolve-ConfiguredPath -Value ([string]$configuredPath) -BasePath (Split-Path -Parent ([System.IO.Path]::GetFullPath($ConfigurationPath)))
}

function Resolve-LocalDataRoot {
    param(
        [string]$LocalDataRoot,
        [object]$Configuration,
        [string]$BasePath = (Get-Location).Path
    )

    if (-not [string]::IsNullOrWhiteSpace($LocalDataRoot)) {
        return Resolve-ConfiguredPath -Value $LocalDataRoot -BasePath $BasePath
    }
    $environmentPath = [Environment]::GetEnvironmentVariable('FOUNDATION_CONTROL_LOCAL_DATA_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($environmentPath)) {
        return Resolve-ConfiguredPath -Value $environmentPath -BasePath $BasePath
    }
    $localPath = Get-LocalEnvironmentConfigValue -Name 'localDataRoot'
    if (-not [string]::IsNullOrWhiteSpace($localPath)) {
        return Resolve-ConfiguredPath -Value $localPath -BasePath $BasePath
    }
    if ($null -ne $Configuration) {
        $storage = Get-JsonProperty -Object $Configuration -Name 'storage' -DocumentName 'Environment config'
        $configuredPath = Get-JsonProperty -Object $storage -Name 'localDataRoot' -DocumentName 'Environment config.storage'
        return Resolve-ConfiguredPath -Value ([string]$configuredPath) -BasePath $BasePath
    }
    throw 'No local data root found. Pass -LocalDataRoot, set FOUNDATION_CONTROL_LOCAL_DATA_ROOT, set environment.local.json localDataRoot, or provide an environment configuration.'
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)] [string]$WindowsPath)

    $expanded = [Environment]::ExpandEnvironmentVariables($WindowsPath)
    $full = [System.IO.Path]::GetFullPath($expanded)
    if ($full.Length -lt 3 -or $full[1] -ne ':') {
        throw "Path must be an absolute Windows drive path: $full"
    }
    return '/mnt/' + $full.Substring(0, 1).ToLowerInvariant() + ($full.Substring(2) -replace '\\', '/')
}

. (Join-Path $PSScriptRoot 'ReleaseState.ps1')
