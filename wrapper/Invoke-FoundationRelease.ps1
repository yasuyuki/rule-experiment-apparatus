[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('status', 'doctor', 'seed', 'inject', 'handoff', 'accept', 'protect', 'promote-dry', 'promote', 'discard', 'rollback-dry', 'rollback', 'verify', 'migrate-runtime-model', 'review-init', 'review')]
    [string]$Stage,

    [switch]$Execute,
    [switch]$ConfirmPromote,
    [switch]$ConfirmDiscard,
    [switch]$ConfirmRollback,
    [switch]$ConfirmMigration,
    [ValidateSet('Rollback', 'Discard')][string]$PreviousDisposition,
    [int]$ExpectedGeneration = -1,
    [string]$ExpectedStateSha256,
    [switch]$AllowSameCommit,
    [string]$Name,
    [string]$GitRef,
    [string]$Experiment,
    [string]$Variant,
    [string]$StatePath,
    [string]$ConfigPath,
    [string]$BackupRoot,
    [string]$ArchiveRoot,
    [string]$ReviewRoot,
    [switch]$AllowLateIntent,
    [string]$Goal,
    [string[]]$SuccessCriteria,
    [switch]$SkipReview,
    [switch]$SkipLeakScan,
    [string]$ReviewBlockPath,
    [switch]$Force,
    [ValidateSet('json', 'text')]
    [string]$Format = 'json'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\Presentation.ps1')
. (Join-Path $PSScriptRoot 'lib\ReleaseReview.ps1')
. (Join-Path $PSScriptRoot 'lib\Result.ps1')

trap { Write-FoundationFailure -Command 'Invoke-FoundationRelease.ps1' -Stage $Stage -ErrorRecord $_; exit 1 }

$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$backupRootFull = Resolve-BackupRoot -BackupRoot $BackupRoot -Configuration $config -ConfigurationPath $resolvedConfigPath -BasePath (Get-ConfigurationWorkspaceRoot)
$pathArguments = @{ StatePath = $resolvedStatePath; ConfigPath = $resolvedConfigPath }

function Invoke-JsonScript {
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][hashtable]$Arguments)
    return Invoke-FoundationJsonScript -Path (Join-Path $PSScriptRoot $Script) -Arguments $Arguments
}

function Get-Status {
    param([switch]$SkipWorkspace)
    $arguments = $pathArguments.Clone()
    if ($SkipWorkspace) { $arguments.SkipWorkspace = $true }
    if (-not [string]::IsNullOrWhiteSpace($ReviewRoot)) {
        $arguments.ReviewRoot = $ReviewRoot
    }
    return Invoke-JsonScript -Script 'Get-FoundationStatus.ps1' -Arguments $arguments
}

function Assert-NoBlockers {
    param([Parameter(Mandatory)][object]$Status, [Parameter(Mandatory)][string]$Action)

    $blockers = @($Status.blockers)
    if ($blockers.Count -eq 0) { return }
    $summary = ($blockers | ForEach-Object { "[$($_.code)] $($_.detail)" }) -join '; '
    throw "Refusing to $Action while $($blockers.Count) blocker(s) remain: $summary"
}

function Ensure-RoleBackup {
    param(
        [Parameter(Mandatory)][ValidateSet('baseline', 'run')][string]$Role,
        [Parameter(Mandatory)][int]$Generation
    )
    $acceptance = Invoke-JsonScript -Script 'Test-FoundationRelease.ps1' -Arguments ($pathArguments + @{ Role = $Role })
    if (-not $acceptance.accepted) { throw "$Role acceptance did not pass." }
    $backup = Invoke-JsonScript -Script 'New-FoundationReleaseBackup.ps1' -Arguments ($pathArguments + @{
        Role = $Role
        ExpectedGeneration = $Generation
        ExpectedCommit = [string]$acceptance.commit
        BackupRoot = $backupRootFull
        Execute = $true
    })
    $restore = Invoke-JsonScript -Script 'Test-FoundationRepositoryArchive.ps1' -Arguments @{
        ManifestPath = [string]$backup.manifestPath
        VerificationRoot = (Join-Path $backupRootFull '.foundation-verify')
    }
    if (-not $restore.restoreVerified) {
        throw "Restore failed for $Role manifest $($backup.manifestPath)"
    }
    return [ordered]@{
        role = $Role
        commit = [string]$acceptance.commit
        manifestPath = [string]$backup.manifestPath
        alreadyExisted = [bool]$backup.alreadyExisted
        restoreVerified = [bool]$restore.restoreVerified
    }
}

function Protect-RuntimeRoles {
    param([Parameter(Mandatory)][int]$Generation)

    $state = Read-ReleaseState -StatePath $resolvedStatePath
    $roles = [System.Collections.Generic.List[object]]::new()
    foreach ($role in @('baseline', 'run')) {
        if (-not $state.$role) { continue }
        $roles.Add((Ensure-RoleBackup -Role $role -Generation $Generation)) | Out-Null
    }
    return @($roles)
}

function Write-StageResult {
    param([Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Result)

    if ($Format -eq 'text' -and $Result.Contains('statusText')) {
        $Result['statusText']
        return
    }
    (ConvertTo-FoundationSuccess -Result $Result) | ConvertTo-Json -Depth 10
}

switch ($Stage) {
    'handoff' {
        $arguments = $pathArguments.Clone()
        if ($Execute) { $arguments.Execute = $true }
        $handoff = Invoke-JsonScript -Script 'Invoke-VerifiedHandoff.ps1' -Arguments $arguments
        $rootPid = Get-OptionalJsonProperty -Object $handoff -Name 'rootPid'
        $fallbackPid = Get-OptionalJsonProperty -Object $handoff -Name 'pid'
        $windowTitle = Get-OptionalJsonProperty -Object $handoff -Name 'windowTitle'
        $fallbackTitle = Get-OptionalJsonProperty -Object $handoff -Name 'title'
        $rootCommandLine = Get-OptionalJsonProperty -Object $handoff -Name 'rootCommandLine'
        $fallbackCommandLine = Get-OptionalJsonProperty -Object $handoff -Name 'commandLine'
        $target = Get-OptionalJsonProperty -Object $handoff -Name 'target'
        $runtimeFingerprint = Get-OptionalJsonProperty -Object $handoff -Name 'runtimeFingerprint'
        $handoffNext = [string](Get-OptionalJsonProperty -Object $handoff -Name 'next')
        Write-StageResult -Result ([ordered]@{
            stage = 'handoff'
            execute = [bool]$handoff.execute
            ready = [bool]$handoff.ready
            launchStarted = [bool]$handoff.launchStarted
            running = [bool]$handoff.running
            verified = [bool]$handoff.verified
            launchVerified = [bool]$handoff.launchVerified
            code = [string]$handoff.code
            pid = if ($rootPid) { [int]$rootPid } elseif ($fallbackPid) { [int]$fallbackPid } else { $null }
            title = if ($windowTitle) { [string]$windowTitle } elseif ($fallbackTitle) { [string]$fallbackTitle } else { $null }
            commandLine = if ($rootCommandLine) { [string]$rootCommandLine } elseif ($fallbackCommandLine) { [string]$fallbackCommandLine } else { $null }
            target = $target
            runtimeFingerprint = $runtimeFingerprint
            remediation = @($handoff.remediation)
            killWhen = @((Get-OptionalJsonProperty -Object $handoff -Name 'killWhen') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            killCommand = @((Get-OptionalJsonProperty -Object $handoff -Name 'killCommand') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            killConfirm = [string](Get-OptionalJsonProperty -Object $handoff -Name 'killConfirm')
            details = $handoff
            next = if (-not [string]::IsNullOrWhiteSpace($handoffNext)) { $handoffNext } elseif ($handoff.launchVerified) { 'Paste workload.md verbatim into this verified subject window.' } else { 'Apply remediation, then re-run -Stage handoff.' }
        })
    }
    'migrate-runtime-model' {
        $arguments = $pathArguments + @{ BackupRoot = $backupRootFull }
        if (-not [string]::IsNullOrWhiteSpace($PreviousDisposition)) { $arguments.PreviousDisposition = $PreviousDisposition }
        if ($ConfirmMigration) { $arguments.ConfirmMigration = $true }
        if ($ExpectedGeneration -ge 0) { $arguments.ExpectedGeneration = $ExpectedGeneration }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedStateSha256)) { $arguments.ExpectedStateSha256 = $ExpectedStateSha256 }
        $migration = Invoke-JsonScript -Script 'Migrate-FoundationRuntimeModel.ps1' -Arguments $arguments
        Write-StageResult -Result ([ordered]@{
            stage = 'migrate-runtime-model'; migration = $migration
            next = if ($ConfirmMigration) { '.\Invoke-FoundationRelease.ps1 -Stage status' } else { ".\Invoke-FoundationRelease.ps1 -Stage migrate-runtime-model -PreviousDisposition $PreviousDisposition -ConfirmMigration -ExpectedGeneration $([int]$migration.generation) -ExpectedStateSha256 $([string]$migration.sourceStateSha256)" }
        })
    }
    'status' {
        $status = Get-Status
        Write-StageResult -Result ([ordered]@{
            stage = 'status'
            generation = [int]$status.generation
            status = $status
            statusText = (Format-FoundationStatusText -Status $status)
            next = [string]$status.nextAction
        })
    }

    'doctor' {
        $status = Get-Status
        $blockers = @($status.blockers)
        Write-StageResult -Result ([ordered]@{
            stage = 'doctor'
            generation = [int]$status.generation
            canSeedRun = [bool]$status.canSeedRun
            baseline = $status.baseline
            run = $status.run
            previousBaseline = $status.previousBaseline
            runRuntime = $status.runRuntime
            workspaces = $status.workspaces
            blockers = $blockers
            healthy = ($blockers.Count -eq 0)
            statusText = (Format-FoundationStatusText -Status $status)
            next = [string]$status.nextAction
        })
    }

    'seed' {
        $status = Get-Status
        Assert-NoBlockers -Status $status -Action 'seed a run'
        if (-not $status.canSeedRun) {
            throw 'The current state cannot seed a run because the run slot is occupied.'
        }
        $generation = [int]$status.generation
        $next = $generation + 1
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "release-$next" }
        if ([string]::IsNullOrWhiteSpace($GitRef)) { $GitRef = "run/infra-next-$next" }
        $initArgs = $pathArguments + @{
            Name = $Name
            GitRef = $GitRef
            ExpectedGeneration = $generation
        }
        if (-not $Execute) {
            $plan = Invoke-JsonScript -Script 'Initialize-NextFoundation.ps1' -Arguments ($initArgs + @{ DryRun = $true })
            $seedResult = [ordered]@{
                stage = 'seed'
                execute = $false
                name = $Name
                gitRef = $GitRef
                expectedGeneration = $generation
                plan = $plan
                next = '.\Invoke-FoundationRelease.ps1 -Stage seed -Execute'
            }
            Write-StageResult -Result $seedResult
            break
        }
        $result = Invoke-JsonScript -Script 'Initialize-NextFoundation.ps1' -Arguments $initArgs
        Write-StageResult -Result ([ordered]@{
            stage = 'seed'
            execute = $true
            name = $Name
            gitRef = $GitRef
            result = $result
            next = '.\Invoke-FoundationRelease.ps1 -Stage review-init   # add -Goal / -SuccessCriteria for late:false'
        })
    }

    'inject' {
        if ([string]::IsNullOrWhiteSpace($Experiment) -or [string]::IsNullOrWhiteSpace($Variant)) {
            throw 'Inject requires -Experiment and -Variant.'
        }
        $injected = Invoke-JsonScript -Script 'Inject-FoundationVariant.ps1' -Arguments ($pathArguments + @{
            Experiment = $Experiment
            Variant = $Variant
        })
        Write-StageResult -Result ([ordered]@{
            stage = 'inject'
            release = [string]$injected.release
            experiment = [string]$injected.experiment
            variant = [string]$injected.variant
            source = [string]$injected.source
            destination = [string]$injected.destination
            sourceSha256 = [string]$injected.sourceSha256
            injectedSha256 = [string]$injected.injectedSha256
            commit = [string]$injected.commit
            committed = [bool]$injected.committed
            next = '.\Invoke-FoundationRelease.ps1 -Stage handoff   # DryRun; -Execute only after you confirm you want a new subject window'
        })
    }

    'accept' {
        $acceptance = Invoke-JsonScript -Script 'Test-FoundationRelease.ps1' -Arguments ($pathArguments + @{ Role = 'run' })
        if (-not $acceptance.accepted) { throw 'Run acceptance failed.' }
        if (-not $SkipLeakScan) {
            $leakScan = Invoke-JsonScript -Script 'Test-FoundationIdentityLeak.ps1' -Arguments ($pathArguments + @{ Role = 'run' })
        } else {
            $leakScan = [ordered]@{ skipped = $true }
        }
        Write-StageResult -Result ([ordered]@{
            stage = 'accept'
            acceptance = $acceptance
            leakScan = $leakScan
            next = '.\Invoke-FoundationRelease.ps1 -Stage protect'
        })
    }

    'protect' {
        $generation = [int](Read-ReleaseState -StatePath $resolvedStatePath).generation
        $roles = Protect-RuntimeRoles -Generation $generation
        Write-StageResult -Result ([ordered]@{
            stage = 'protect'
            generation = $generation
            roles = $roles
            next = '.\Invoke-FoundationRelease.ps1 -Stage review -Format text'
        })
    }

    'promote-dry' {
        $status = Get-Status
        Assert-NoBlockers -Status $status -Action 'promote'
        if (-not $status.run) { throw 'There is no run to promote.' }
        $generation = [int]$status.generation
        $plan = Invoke-JsonScript -Script 'Promote-Foundation.ps1' -Arguments ($pathArguments + @{
            DryRun = $true
            ExpectedGeneration = $generation; BackupRoot = $backupRootFull
        })
        $resolvedReviewRoot = Resolve-ReviewRoot -ReviewRoot $ReviewRoot -StatePath $resolvedStatePath
        $releaseName = [string]$status.run.name
        $recordPath = Join-Path $resolvedReviewRoot ("{0}.json" -f $releaseName)
        $record = $null
        if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
            $record = Read-FoundationReviewRecord -Path $recordPath
        }
        $diff = Invoke-JsonScript -Script 'Get-FoundationReleaseDiff.ps1' -Arguments ($pathArguments + @{ Role = 'run' })
        $gate = Test-FoundationReviewGate -Record $record -CurrentCommit ([string]$diff.headCommit) -CurrentRepositories @($diff.nestedRepositories)
        $checklist = @(
            'Approve only if the run content should become the new baseline.',
            'DryRun must show generation+1, baseline on stable, previousBaseline backed up, run=null.',
            'Existing sessions do not move; open new sessions after promote.',
            'The legacy Projects root is not deleted by promote.',
            'Path-only layout moves (same commit) require -AllowSameCommit with -ConfirmPromote.',
            'Review gate must be satisfied (.review.satisfied), or pass -SkipReview on promote.'
        )
        Write-StageResult -Result ([ordered]@{
            stage = 'promote-dry'
            expectedGeneration = $generation
            plan = $plan
            review = $gate
            approvalChecklist = $checklist
            next = 'After approval: .\Invoke-FoundationRelease.ps1 -Stage promote -ConfirmPromote   # add -AllowSameCommit only for same-commit path layout moves'
        })
    }

    'promote' {
        if (-not $ConfirmPromote) {
            throw 'Refusing promote without -ConfirmPromote. Run -Stage promote-dry first, then re-run with -ConfirmPromote.'
        }
        $status = Get-Status
        Assert-NoBlockers -Status $status -Action 'promote'
        if (-not $status.run) {
            throw 'There is no run to promote.'
        }
        if (-not $SkipReview) {
            $resolvedReviewRoot = Resolve-ReviewRoot -ReviewRoot $ReviewRoot -StatePath $resolvedStatePath
            $releaseName = [string]$status.run.name
            $recordPath = Join-Path $resolvedReviewRoot ("{0}.json" -f $releaseName)
            $record = $null
            if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
                $record = Read-FoundationReviewRecord -Path $recordPath
            }
            $diff = Invoke-JsonScript -Script 'Get-FoundationReleaseDiff.ps1' -Arguments ($pathArguments + @{ Role = 'run' })
            $gate = Test-FoundationReviewGate -Record $record -CurrentCommit ([string]$diff.headCommit) -CurrentRepositories @($diff.nestedRepositories)
            if (-not [bool]$gate.satisfied) {
                throw "Review gate not satisfied for run '$releaseName' (review.satisfied=false). Complete an accepted review at the current commit, or re-run with -SkipReview."
            }
        }
        $promoteArgs = $pathArguments + @{ ExpectedGeneration = [int]$status.generation; BackupRoot = $backupRootFull }
        if ($AllowSameCommit) { $promoteArgs.AllowSameCommit = $true }
        $promoted = Invoke-JsonScript -Script 'Promote-Foundation.ps1' -Arguments $promoteArgs
        $finalStatus = Get-Status
        $promoteResult = [ordered]@{
            stage = 'promote'
            promoted = $promoted
            status = $finalStatus
            statusText = (Format-FoundationStatusText -Status $finalStatus)
            next = 'Promotion complete. The accepted run is now the baseline.'
        }
        if ($SkipReview) {
            $promoteResult['reviewSkipped'] = $true
        }
        Write-StageResult -Result $promoteResult
    }

    'discard' {
        $status = Get-Status -SkipWorkspace
        if (-not $status.run) {
            throw 'There is no run to discard.'
        }
        $discardArgs = $pathArguments + @{ ExpectedGeneration = [int]$status.generation }
        if (-not $ConfirmDiscard) {
            $plan = Invoke-JsonScript -Script 'Discard-Foundation.ps1' -Arguments ($discardArgs + @{ DryRun = $true })
            Write-StageResult -Result ([ordered]@{
                stage = 'discard'
                execute = $false
                expectedGeneration = [int]$status.generation
                plan = $plan
                approvalChecklist = @(
                    'Discard frees the run slot without changing baseline.',
                    'The discarded run is not promoted. Baseline stays the current stable release.',
                    'The leftover candidate workspace is not deleted; the next seed uses a new path.',
                    'Review records remain. This is the remeasurement path, not -SkipReview promote.'
                )
                next = 'After approval: .\Invoke-FoundationRelease.ps1 -Stage discard -ConfirmDiscard'
            })
            break
        }
        $discarded = Invoke-JsonScript -Script 'Discard-Foundation.ps1' -Arguments $discardArgs
        $finalStatus = Get-Status
        Write-StageResult -Result ([ordered]@{
            stage = 'discard'
            execute = $true
            discarded = $discarded
            status = $finalStatus
            statusText = (Format-FoundationStatusText -Status $finalStatus)
            next = 'Run slot is empty. Next: .\Invoke-FoundationRelease.ps1 -Stage seed'
        })
    }

    'rollback-dry' {
        $status = Get-Status -SkipWorkspace
        if (-not $status.previousBaseline) {
            throw 'There is no previous baseline to roll back to; the rollback window is closed.'
        }
        $generation = [int]$status.generation
        $plan = Invoke-JsonScript -Script 'Rollback-Foundation.ps1' -Arguments ($pathArguments + @{
            DryRun = $true
            ExpectedGeneration = $generation; BackupRoot = $backupRootFull
        })
        Write-StageResult -Result ([ordered]@{
            stage = 'rollback-dry'
            expectedGeneration = $generation
            plan = $plan
            target = $status.previousBaseline
            approvalChecklist = @(
                'baseline must become the release named in target; run remains empty.',
                'Rollback consumes previousBaseline, closing the rollback window.',
                'Sessions already open keep their current workspace; open new sessions after rollback.'
            )
            next = 'After approval: .\Invoke-FoundationRelease.ps1 -Stage rollback -ConfirmRollback'
        })
    }

    'rollback' {
        if (-not $ConfirmRollback) {
            throw 'Refusing rollback without -ConfirmRollback. Run -Stage rollback-dry first, then re-run with -ConfirmRollback.'
        }
        $status = Get-Status -SkipWorkspace
        if (-not $status.previousBaseline) {
            throw 'There is no previous baseline to roll back to; the rollback window is closed.'
        }
        $rolledBack = Invoke-JsonScript -Script 'Rollback-Foundation.ps1' -Arguments ($pathArguments + @{
            ExpectedGeneration = [int]$status.generation; BackupRoot = $backupRootFull
        })
        $finalStatus = Get-Status
        Write-StageResult -Result ([ordered]@{
            stage = 'rollback'
            rolledBack = $rolledBack
            status = $finalStatus
            statusText = (Format-FoundationStatusText -Status $finalStatus)
            next = 'Rollback complete. The restored workspace is now the baseline.'
        })
    }

    'verify' {
        $rawState = Get-Content -Raw -LiteralPath $resolvedStatePath | ConvertFrom-Json
        if ([int]$rawState.schemaVersion -eq 2) {
            $beforeHash = (Get-FileHash -LiteralPath $resolvedStatePath -Algorithm SHA256).Hash
            $legacy = Read-LegacyReleaseStateV2ForMigration -StatePath $resolvedStatePath
            if ($legacy.candidate) { throw 'Legacy candidate must be empty before runtime-model migration.' }
            $afterHash = (Get-FileHash -LiteralPath $resolvedStatePath -Algorithm SHA256).Hash
            if ($beforeHash -ne $afterHash) { throw 'Legacy migration preflight changed the live state.' }
            Write-StageResult -Result ([ordered]@{
                stage = 'verify'; healthy = $true; migrationRequired = $true
                configPath = $resolvedConfigPath; statePath = $resolvedStatePath
                generation = [int]$legacy.generation; candidateEmpty = $true
                previousDecisionRequired = ($null -ne $legacy.previous)
                liveStateUnchanged = $true
                next = '.\Invoke-FoundationRelease.ps1 -Stage migrate-runtime-model -PreviousDisposition <Rollback|Discard>'
            })
            break
        }
        if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) {
            throw 'Stage verify requires -ArchiveRoot; archives are private operator data.'
        }
        $system = Invoke-JsonScript -Script 'Test-FoundationSystem.ps1' -Arguments ($pathArguments + @{
            ArchiveRoot = $ArchiveRoot
        })
        $transitionSkipped = [bool]$system.transitionFixture.skipped
        Write-StageResult -Result ([ordered]@{
            stage = 'verify'
            healthy = [bool]$system.healthy
            generation = [int]$system.generation
            archives = @($system.archives).Count
            releaseBackups = @($system.releaseBackups).Count
            transitionFixtureSkipped = $transitionSkipped
            liveStateUnchanged = [bool]$system.transitionFixture.liveStateUnchanged
            system = $system
            next = if ($transitionSkipped) {
                "System acceptance passed. Transition fixture skipped: $($system.transitionFixture.reason)"
            } else {
                'System acceptance passed.'
            }
        })
    }

    'review-init' {
        $status = Get-Status
        if (-not $status.run) {
            throw 'There is no run to initialize a review for.'
        }
        $state = Read-ReleaseState -StatePath $resolvedStatePath
        $resolvedReviewRoot = Resolve-ReviewRoot -ReviewRoot $ReviewRoot -StatePath $resolvedStatePath
        $releaseName = [string]$state.run.name
        $recordPath = Join-Path $resolvedReviewRoot ("{0}.json" -f $releaseName)
        $diff = Invoke-JsonScript -Script 'Get-FoundationReleaseDiff.ps1' -Arguments ($pathArguments + @{ Role = 'run' })
        $baseCommit = Resolve-FoundationReleaseBaseCommit -State $state -ReleaseName $releaseName
        $planArgs = @{
            Release = $releaseName
            Generation = [int]$state.generation
            BaseCommit = $baseCommit
            HeadCommit = [string]$diff.headCommit
            NestedRepositories = @($diff.nestedRepositories)
        }
        if ($PSBoundParameters.ContainsKey('Goal')) {
            $planArgs.Goal = $Goal
        }
        if ($PSBoundParameters.ContainsKey('SuccessCriteria')) {
            $planArgs.SuccessCriteria = $SuccessCriteria
        }
        if ($AllowLateIntent.IsPresent) {
            $planArgs.AllowLateIntent = $true
        }
        $plan = Get-FoundationReviewInitPlan @planArgs
        $written = New-FoundationReviewRecordFile -Path $recordPath -Record $plan.record
        Write-StageResult -Result ([ordered]@{
            stage = 'review-init'
            path = $written
            release = $releaseName
            generation = [int]$state.generation
            baseCommit = $baseCommit
            late = [bool]$plan.late
            intentComplete = [bool]$plan.intentComplete
            record = $plan.record
            next = 'Once-only: does not overwrite an existing review file. Intent cannot be fixed this cycle. Next: .\Invoke-FoundationRelease.ps1 -Stage inject -Experiment <experiment> -Variant <variant>   # then -Stage handoff. After development: -Stage accept, then -Stage protect, then -Stage review'
        })
    }

    'review' {
        $status = Get-Status
        if (-not $status.run) {
            throw 'There is no run to review.'
        }
        $state = Read-ReleaseState -StatePath $resolvedStatePath
        $resolvedReviewRoot = Resolve-ReviewRoot -ReviewRoot $ReviewRoot -StatePath $resolvedStatePath
        $releaseName = [string]$state.run.name
        $recordPath = Join-Path $resolvedReviewRoot ("{0}.json" -f $releaseName)
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            throw "No review record at '$recordPath'; run -Stage review-init first."
        }
        $record = Read-FoundationReviewRecord -Path $recordPath
        $diff = Invoke-JsonScript -Script 'Get-FoundationReleaseDiff.ps1' -Arguments ($pathArguments + @{ Role = 'run' })
        if (-not [string]::IsNullOrWhiteSpace($ReviewBlockPath)) {
            if (-not (Test-Path -LiteralPath $ReviewBlockPath -PathType Leaf)) {
                throw "Review block file '$ReviewBlockPath' does not exist."
            }
            $blockRaw = Get-Content -Raw -LiteralPath $ReviewBlockPath
            if ([string]::IsNullOrWhiteSpace($blockRaw)) {
                throw "Review block file '$ReviewBlockPath' is empty."
            }
            try {
                $block = $blockRaw | ConvertFrom-Json
            } catch {
                throw "Could not parse review block '$ReviewBlockPath': $($_.Exception.Message)"
            }
            if ($null -eq $block) {
                throw "Could not parse review block '$ReviewBlockPath': content parsed to null."
            }
            $mergeArgs = @{
                Record = $record
                Block = $block
                CurrentCommit = [string]$diff.headCommit
                CurrentRepositories = @($diff.nestedRepositories)
            }
            if ($Force) { $mergeArgs.Force = $true }
            $merged = Merge-FoundationReviewBlock @mergeArgs
            Set-FoundationReviewRecordFile -Path $recordPath -Record $merged | Out-Null
            $record = $merged
        }
        $gate = Test-FoundationReviewGate -Record $record -CurrentCommit ([string]$diff.headCommit) -CurrentRepositories @($diff.nestedRepositories)
        $statusText = Format-FoundationReviewText -Record $record -Diff $diff -Gate $gate -RecordPath $recordPath
        Write-StageResult -Result ([ordered]@{
            stage = 'review'
            record = $record
            diff = $diff
            gate = $gate
            statusText = $statusText
            next = 'Append one calibration-log block to docs/REVIEW-CRITERIA.md section 7, then .\Invoke-FoundationRelease.ps1 -Stage promote-dry'
        })
    }
}
