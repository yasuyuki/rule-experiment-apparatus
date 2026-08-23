$ErrorActionPreference = 'Stop'

function Read-ReleaseStateDocument {
    param(
        [Parameter(Mandatory)] [string]$StatePath,
        [Parameter(Mandatory)] [string]$DocumentName
    )

    $resolvedPath = Resolve-ReleaseStatePath -StatePath $StatePath
    try {
        return Get-Content -Raw -LiteralPath $resolvedPath | ConvertFrom-Json
    } catch {
        throw "Could not parse $DocumentName '$resolvedPath': $($_.Exception.Message)"
    }
}

function Assert-OnlyReleaseStateProperties {
    param(
        [Parameter(Mandatory)] [object]$Object,
        [Parameter(Mandatory)] [string[]]$Allowed,
        [Parameter(Mandatory)] [string]$Context
    )
    $names = if ($Object -is [System.Collections.IDictionary]) { @($Object.Keys) } else { @($Object.PSObject.Properties.Name) }
    foreach ($name in $names) {
        if ($Allowed -notcontains $name) { throw "$Context contains unsupported property '$name'." }
    }
}

function Assert-ReleaseWorkspaceShape {
    param(
        [Parameter(Mandatory)] [AllowNull()] [object]$Release,
        [Parameter(Mandatory)] [string]$Role,
        [string]$ExpectedInstance
    )

    if ($null -eq $Release) { return }
    $context = "Release state.$Role"
    Assert-OnlyReleaseStateProperties -Object $Release -Allowed @('name', 'instance', 'path', 'gitRef') -Context $context
    foreach ($field in @('name', 'instance', 'path', 'gitRef')) {
        $value = [string](Get-JsonProperty -Object $Release -Name $field -DocumentName $context)
        if ([string]::IsNullOrWhiteSpace($value)) { throw "$context.$field is empty." }
    }

    $instance = [string]$Release.instance
    if (-not [string]::IsNullOrWhiteSpace($ExpectedInstance) -and $instance -ne $ExpectedInstance) {
        throw "$context.instance must be '$ExpectedInstance'; got '$instance'."
    }
    if (@('stable', 'candidate') -notcontains $instance) {
        throw "$context.instance '$instance' is not a known physical instance; expected stable or candidate."
    }
    $null = Assert-AbsolutePosixPath -Path ([string]$Release.path) -Context "$context.path"
}

function Assert-PreviousBaselineShape {
    param([Parameter(Mandatory)] [AllowNull()] [object]$PreviousBaseline)

    if ($null -eq $PreviousBaseline) { return }
    $context = 'Release state.previousBaseline'
    Assert-OnlyReleaseStateProperties -Object $PreviousBaseline -Allowed @('name', 'commit', 'gitRef', 'backupManifest', 'backupSha256') -Context $context
    foreach ($field in @('name', 'commit', 'gitRef', 'backupManifest', 'backupSha256')) {
        $value = [string](Get-JsonProperty -Object $PreviousBaseline -Name $field -DocumentName $context)
        if ([string]::IsNullOrWhiteSpace($value)) { throw "$context.$field is empty." }
    }
    $manifest = [string]$PreviousBaseline.backupManifest
    if ($manifest -in @('.', '..') -or $manifest.IndexOfAny([char[]]@('/', '\', ':')) -ge 0) {
        throw "$context.backupManifest must be a file name relative to storage.backupRoot; got '$manifest'."
    }
    if ([string]$PreviousBaseline.backupSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "$context.backupSha256 must be a 64-character hexadecimal SHA-256."
    }
}

$script:ReleaseTransitionRequiredFieldsV3 = @{
    'bootstrap'             = @('from', 'to', 'commit')
    'seed'                  = @('release', 'commit')
    'promote'               = @('from', 'to', 'commit')
    'discard'               = @('release', 'commit')
    'rollback'              = @('from', 'to', 'commit')
    'migrate-runtime-model' = @('from', 'to', 'commit')
}

$script:ReleaseTransitionRequiredFieldsV2 = @{
    'bootstrap'       = @('from', 'to', 'commit')
    'promote'         = @('from', 'to', 'commit')
    'rollback'        = @('from', 'to')
    'initialize-next' = @('release', 'commit', 'retired')
}

function Assert-ReleaseTransitionShape {
    param(
        [Parameter(Mandatory)] [object]$Transition,
        [Parameter(Mandatory)] [string]$Context,
        [Parameter(Mandatory)] [hashtable]$RequiredFields,
        [string[]]$AllowedProperties = @('action', 'at', 'from', 'to', 'commit', 'release', 'historyImported')
    )

    Assert-OnlyReleaseStateProperties -Object $Transition -Allowed $AllowedProperties -Context $Context
    foreach ($field in @('action', 'at')) {
        $value = [string](Get-JsonProperty -Object $Transition -Name $field -DocumentName $Context)
        if ([string]::IsNullOrWhiteSpace($value)) { throw "$Context.$field is empty." }
    }

    $action = [string]$Transition.action
    if (-not $RequiredFields.ContainsKey($action)) {
        $supported = (($RequiredFields.Keys | Sort-Object) -join ', ')
        throw "$Context.action '$action' is not a known transition; expected one of $supported."
    }
    foreach ($field in $RequiredFields[$action]) {
        $value = [string](Get-JsonProperty -Object $Transition -Name $field -DocumentName "$Context ($action)")
        if ([string]::IsNullOrWhiteSpace($value)) { throw "$Context.$field is required for action '$action'." }
    }
}

function Assert-ReleaseTransitionHistory {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$RequiredFields,
        [string[]]$AllowedProperties = @('action', 'at', 'from', 'to', 'commit', 'release', 'historyImported')
    )

    if (@($State.transitionHistory).Count -eq 0) {
        throw 'Release state.transitionHistory must not be empty.'
    }
    Assert-ReleaseTransitionShape -Transition $State.lastTransition -Context 'Release state.lastTransition' -RequiredFields $RequiredFields -AllowedProperties $AllowedProperties
    $historyIndex = 0
    foreach ($entry in @($State.transitionHistory)) {
        Assert-ReleaseTransitionShape -Transition $entry -Context "Release state.transitionHistory[$historyIndex]" -RequiredFields $RequiredFields -AllowedProperties $AllowedProperties
        $historyIndex += 1
    }
}

function Read-ReleaseState {
    param([string]$StatePath)

    $state = Read-ReleaseStateDocument -StatePath $StatePath -DocumentName 'release state'
    $schemaVersion = Get-JsonProperty -Object $state -Name 'schemaVersion' -DocumentName 'Release state'
    if ([int]$schemaVersion -eq 2) {
        throw 'Release state schema version 2 is legacy. Run Invoke-FoundationRelease.ps1 -Stage migrate-runtime-model; normal operations require schema version 3.'
    }
    Assert-SupportedSchemaVersion -Document $state -SupportedVersion @(3) -DocumentName 'Release state' | Out-Null
    Assert-OnlyReleaseStateProperties -Object $state -Allowed @('schemaVersion', 'generation', 'baseline', 'run', 'previousBaseline', 'lastTransition', 'transitionHistory') -Context 'Release state'
    foreach ($field in @('generation', 'baseline', 'run', 'previousBaseline', 'lastTransition', 'transitionHistory')) {
        $null = Get-JsonProperty -Object $state -Name $field -DocumentName 'Release state'
    }
    Assert-ReleaseStateGeneration -State $state | Out-Null
    if ($null -eq $state.baseline) { throw 'Release state.baseline is required.' }
    Assert-ReleaseWorkspaceShape -Release $state.baseline -Role 'baseline' -ExpectedInstance 'stable'
    Assert-ReleaseWorkspaceShape -Release $state.run -Role 'run' -ExpectedInstance 'candidate'
    Assert-PreviousBaselineShape -PreviousBaseline $state.previousBaseline
    Assert-ReleaseTransitionHistory -State $state -RequiredFields $script:ReleaseTransitionRequiredFieldsV3
    $tail = @($state.transitionHistory)[-1] | ConvertTo-Json -Compress -Depth 8
    $last = $state.lastTransition | ConvertTo-Json -Compress -Depth 8
    if ($tail -ne $last) { throw 'Release state.lastTransition must exactly match the transitionHistory tail.' }
    return $state
}

# Schema v2 is accepted only by the explicit migration/preflight path. This
# function deliberately returns the legacy shape without projecting aliases
# into the v3 runtime model.
function Read-LegacyReleaseStateV2ForMigration {
    param([string]$StatePath)

    $state = Read-ReleaseStateDocument -StatePath $StatePath -DocumentName 'legacy release state'
    Assert-SupportedSchemaVersion -Document $state -SupportedVersion @(2) -DocumentName 'Legacy release state for migration' | Out-Null
    foreach ($field in @('generation', 'active', 'candidate', 'previous', 'lastTransition', 'transitionHistory')) {
        $null = Get-JsonProperty -Object $state -Name $field -DocumentName 'Legacy release state for migration'
    }
    Assert-ReleaseStateGeneration -State $state | Out-Null
    if ($null -eq $state.active) { throw 'Legacy release state.active is required for migration.' }
    foreach ($channel in @('active', 'candidate', 'previous')) {
        Assert-ReleaseWorkspaceShape -Release $state.$channel -Role $channel
    }
    Assert-ReleaseTransitionHistory -State $state -RequiredFields $script:ReleaseTransitionRequiredFieldsV2 -AllowedProperties @('action', 'at', 'from', 'to', 'commit', 'release', 'sourceCommit', 'retired', 'sourcePath', 'sharedInstance', 'historyImported')
    return $state
}

function Assert-ReleaseStateGeneration {
    param(
        [Parameter(Mandatory)] [object]$State,
        [int]$ExpectedGeneration = -1
    )

    $generationValue = Get-JsonProperty -Object $State -Name 'generation' -DocumentName 'Release state'
    try {
        $generation = [int]$generationValue
    } catch {
        throw "Release state generation '$generationValue' is invalid."
    }
    if ($ExpectedGeneration -ge 0 -and $generation -ne $ExpectedGeneration) {
        throw "Generation mismatch: expected $ExpectedGeneration, actual $generation."
    }
    return $generation
}

function Assert-ReleaseStateRuntimePlacement {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [object]$Configuration
    )
    foreach ($role in @('baseline', 'run')) {
        $release = $State.$role
        if ($null -eq $release) { continue }
        $expectedInstance = if ($role -eq 'baseline') { 'stable' } else { 'candidate' }
        $instance = Get-ConfiguredInstance -Configuration $Configuration -Name $expectedInstance
        $root = Get-ConfiguredReleasesRoot -Instance $instance -InstanceName $expectedInstance
        if ([string]::IsNullOrWhiteSpace($root)) { throw "Environment config.instances.$expectedInstance.releasesRoot is required by runtime state schema v3." }
        $expectedPath = Resolve-DefaultReleaseSeedPath -Instance $instance -Name ([string]$release.name) -InstanceName $expectedInstance
        if ([string]$release.path -ne $expectedPath) {
            throw "Release state.$role.path must be '$expectedPath'; got '$($release.path)'."
        }
    }
}

function Enter-ReleaseStateLock {
    param(
        [Parameter(Mandatory)] [string]$StatePath,
        [switch]$DryRun
    )

    if ($DryRun) { return $null }

    $lockPath = "$StatePath.lock"
    try {
        $handle = [System.IO.File]::Open($lockPath, 'CreateNew', 'Write', 'None')
    } catch {
        # Kill leaves the file behind after the exclusive handle is gone. Open
        # with FileShare.None succeeds only for that stale leftover; a live
        # holder still fails and we throw the same contention message.
        try {
            $handle = [System.IO.File]::Open($lockPath, 'Open', 'Write', 'None')
        } catch {
            throw "Release state is locked by another transition: $lockPath"
        }
    }
    return [pscustomobject]@{
        Handle = $handle
        Path = $lockPath
    }
}

function Exit-ReleaseStateLock {
    param([AllowNull()] [object]$Lock)

    if ($null -eq $Lock) { return }
    try {
        if ($null -ne $Lock.Handle) { $Lock.Handle.Dispose() }
    } finally {
        Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction SilentlyContinue
    }
}

function Write-ReleaseStateAtomic {
    param(
        [Parameter(Mandatory)] [string]$StatePath,
        [Parameter(Mandatory)] [object]$State
    )

    Assert-SupportedSchemaVersion -Document $State -SupportedVersion @(3) -DocumentName 'Release state write' | Out-Null
    Assert-OnlyReleaseStateProperties -Object $State -Allowed @('schemaVersion', 'generation', 'baseline', 'run', 'previousBaseline', 'lastTransition', 'transitionHistory') -Context 'Release state write'
    Assert-ReleaseStateGeneration -State $State | Out-Null
    if ($null -eq $State.baseline) { throw 'Refusing state write without a baseline.' }
    Assert-ReleaseWorkspaceShape -Release $State.baseline -Role 'baseline' -ExpectedInstance 'stable'
    Assert-ReleaseWorkspaceShape -Release $State.run -Role 'run' -ExpectedInstance 'candidate'
    Assert-PreviousBaselineShape -PreviousBaseline $State.previousBaseline
    Assert-ReleaseTransitionHistory -State $State -RequiredFields $script:ReleaseTransitionRequiredFieldsV3
    $tail = @($State.transitionHistory)[-1] | ConvertTo-Json -Compress -Depth 8
    $last = $State.lastTransition | ConvertTo-Json -Compress -Depth 8
    if ($tail -ne $last) { throw 'Refusing state write: lastTransition does not match transitionHistory tail.' }

    $replaceId = [guid]::NewGuid().ToString('N')
    $tempPath = "$StatePath.$replaceId.tmp"
    $backupPath = "$StatePath.$replaceId.bak"
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 8
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempPath, $json, $encoding)
        [System.IO.File]::Replace($tempPath, $StatePath, $backupPath)
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}
