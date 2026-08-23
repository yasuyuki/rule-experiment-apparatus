$ErrorActionPreference = 'Stop'

function New-FoundationBlocker {
    param(
        [Parameter(Mandatory)] [string]$Code,
        [Parameter(Mandatory)] [Alias('Channel')] [AllowNull()] [string]$Role,
        [Parameter(Mandatory)] [string]$Detail,
        [Parameter(Mandatory)] [string[]]$Remediation
    )

    return [ordered]@{
        code = $Code
        role = $Role
        detail = $Detail
        remediation = @($Remediation)
    }
}

function Format-FoundationRoleLine {
    param(
        [Parameter(Mandatory)] [string]$Role,
        [AllowNull()] [object]$Release,
        [AllowNull()] [object]$Workspace,
        [AllowNull()] [object]$Runtime
    )

    if ($null -eq $Release) { return ("{0,-16} -" -f $Role) }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("$($Release.name) [$($Release.instance)]")
    if ($null -ne $Workspace) {
        $parts.Add($(if ($Workspace.clean) { 'clean' } else { "dirty($($Workspace.dirtyRepositories.Count))" }))
        if (-not $Workspace.refMatchesHead) { $parts.Add('ref!=HEAD') }
        if (@($Workspace.missingDeclared).Count -gt 0) { $parts.Add("missing($(@($Workspace.missingDeclared).Count))") }
        if (@($Workspace.undeclaredRepositories).Count -gt 0) { $parts.Add("undeclared($(@($Workspace.undeclaredRepositories).Count))") }
        $localData = $Workspace.localData
        if ($null -ne $localData) {
            switch ([string]$localData.state) {
                'drift' { $parts.Add("localdata($(@($localData.problems).Count))") }
                'unavailable' { $parts.Add('localdata!') }
            }
        }
    }
    if ($null -ne $Runtime) {
        $parts.Add($(if ($Runtime.running) { "running(win=$($Runtime.windowsProcessCount),wsl=$($Runtime.remoteProcessCount))" } else { 'stopped' }))
    }
    return ("{0,-16} {1}" -f $Role, ($parts -join '  '))
}

function Format-FoundationStatusText {
    param([Parameter(Mandatory)] [object]$Status)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("generation $($Status.generation)   state $($Status.statePath)")
    $lines.Add('')
    foreach ($role in @('baseline', 'run')) {
        $runtime = if ($role -eq 'baseline') { $Status.baselineRuntime } else { $Status.runRuntime }
        $workspace = if ($null -ne $Status.workspaces) { $Status.workspaces.$role } else { $null }
        $lines.Add((Format-FoundationRoleLine -Role $role -Release $Status.$role -Workspace $workspace -Runtime $runtime))
    }
    $previous = if ($null -eq $Status.previousBaseline) { '-' } else { "$($Status.previousBaseline.name) [verified backup]" }
    $lines.Add(("{0,-16} {1}" -f 'previousBaseline', $previous))
    if ($null -ne $Status.sharedInstances) {
        foreach ($shared in @($Status.sharedInstances)) {
            $roleList = @($shared.roles) -join ', '
            $lines.Add(("{0,-16} {1}: {2}" -f 'shared', [string]$shared.instance, $roleList))
        }
    }
    $lines.Add('')
    if ($null -ne $Status.handoff) {
        $lockState = if ($Status.handoff.runtimeLockPresent) { 'present' } else { 'missing' }
        $lines.Add("handoff   $($Status.handoff.command)  runtime.lock=$lockState")
        $lines.Add('')
    }

    $blockers = @($Status.blockers)
    if ($blockers.Count -eq 0) {
        $lines.Add('blockers  none')
    } else {
        $lines.Add("blockers  $($blockers.Count)")
        foreach ($blocker in $blockers) {
            $scope = if ([string]::IsNullOrWhiteSpace([string]$blocker.role)) { '-' } else { [string]$blocker.role }
            $lines.Add("  [$($blocker.code)] ${scope}: $($blocker.detail)")
            foreach ($line in @($blocker.remediation)) { $lines.Add("      $line") }
        }
    }
    $lines.Add('')
    $lines.Add("next      $($Status.nextAction)")
    return ($lines -join [Environment]::NewLine)
}

# Renders a review record together with its diff and gate state as a single
# screen for the work-side lead (see docs/REVIEW-CRITERIA.md). Pure: reads
# only its parameters, touches no global state, and performs no file I/O.
function Format-FoundationReviewText {
    param(
        [Parameter(Mandatory)] [object]$Record,
        [Parameter(Mandatory)] [object]$Diff,
        [Parameter(Mandatory)] [object]$Gate,
        [Parameter(Mandatory)] [string]$RecordPath
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("release $($Record.release)")
    $lines.Add("generation $($Record.generation)")
    $lines.Add("record $RecordPath")
    $lines.Add("base $($Record.baseCommit) (matches state: $($Record.baseCommit -ceq $Diff.baseCommit))")
    $lines.Add("head $($Diff.headCommit)")
    $nestedRepositories = Get-OptionalJsonProperty -Object $Diff -Name 'nestedRepositories'
    if ($null -ne $nestedRepositories) {
        $nestedList = @($nestedRepositories)
        if ($nestedList.Count -gt 0) {
            $lines.Add('nested:')
            foreach ($nested in $nestedList) {
                $lines.Add("  $($nested.relativePath) $($nested.headCommit)")
            }
        }
    }
    $lines.Add("late $($Record.late)   intentComplete $($Gate.intentComplete)")
    $lines.Add('')

    $lines.Add('## intent')
    $goal = [string]$Record.intent.goal
    $lines.Add("goal: $(if ([string]::IsNullOrWhiteSpace($goal)) { '(not recorded yet)' } else { $goal })")
    $lines.Add('expected effects:')
    $expectedEffects = @($Record.intent.expectedEffects)
    if ($expectedEffects.Count -eq 0) {
        $lines.Add('  (not recorded yet)')
    } else {
        foreach ($effect in $expectedEffects) { $lines.Add("  - $effect") }
    }
    $lines.Add('non-goals:')
    $nonGoals = @($Record.intent.nonGoals)
    if ($nonGoals.Count -eq 0) {
        $lines.Add('  (not recorded yet)')
    } else {
        foreach ($nonGoal in $nonGoals) { $lines.Add("  - $nonGoal") }
    }
    $lines.Add('')

    $lines.Add('## success criteria')
    $successCriteria = @($Record.intent.successCriteria)
    if ($successCriteria.Count -eq 0) {
        $lines.Add('(not recorded yet)')
    } else {
        $index = 1
        foreach ($criterion in $successCriteria) {
            $lines.Add("$index. $criterion")
            $index += 1
        }
    }
    $lines.Add('')

    $lines.Add('## diff summary')
    $totals = $Diff.totals
    $lines.Add("totals: commits=$($totals.commits) files=$($totals.filesChanged) +$($totals.insertions) -$($totals.deletions)")
    foreach ($area in @('llm-config', 'control-plane', 'docs', 'other')) {
        $areaSummary = $Diff.areaSummary.$area
        $lines.Add("  ${area}: files=$($areaSummary.files) +$($areaSummary.insertions) -$($areaSummary.deletions)")
    }
    $lines.Add('commits:')
    $commits = @($Diff.commits)
    if ($commits.Count -eq 0) {
        $lines.Add('  (none)')
    } else {
        foreach ($commit in $commits) {
            $commitId = [string]$commit.commit
            $shortSha = $commitId.Substring(0, [Math]::Min(7, $commitId.Length))
            $repo = [string](Get-OptionalJsonProperty -Object $commit -Name 'repo')
            if (-not [string]::IsNullOrWhiteSpace($repo) -and $repo -ne '.') {
                $lines.Add("  $shortSha $repo $($commit.at) $($commit.subject)")
            } else {
                $lines.Add("  $shortSha $($commit.at) $($commit.subject)")
            }
        }
    }
    $lines.Add('files:')
    $files = @($Diff.files)
    if ($files.Count -eq 0) {
        $lines.Add('  (none)')
    } else {
        foreach ($file in $files) {
            $repo = [string](Get-OptionalJsonProperty -Object $file -Name 'repo')
            $displayPath = if (-not [string]::IsNullOrWhiteSpace($repo) -and $repo -ne '.') {
                "$repo/$($file.path)"
            } else {
                [string]$file.path
            }
            $lines.Add("  $($file.status) [$($file.area)] $displayPath +$($file.insertions) -$($file.deletions)")
        }
    }
    $lines.Add('')

    $lines.Add('## verdict')
    if ($null -eq $Record.review) {
        $lines.Add('(not reviewed yet)')
    } else {
        $review = $Record.review
        $lines.Add("correctness: $($review.correctness)")
        $lines.Add("procedure: $($review.procedure)")
        $lines.Add("verdict: $($review.verdict)")
        $procedureChecks = $review.procedureChecks
        $lines.Add("procedureChecks: minimalChange=$($procedureChecks.minimalChange) verifiedBeforeProceeding=$($procedureChecks.verifiedBeforeProceeding) rollbackPreserved=$($procedureChecks.rollbackPreserved) stableIsolationUsed=$($procedureChecks.stableIsolationUsed)")
        $lines.Add("betterProcedure: $($review.betterProcedure)")
    }
    $lines.Add("gate satisfied=$($Gate.satisfied) (intentComplete=$($Gate.intentComplete), reviewedCommitMatches=$($Gate.reviewedCommitMatches))")
    $lines.Add('')

    $lines.Add('## how to fill this in')
    if (-not $Gate.intentComplete) {
        $lines.Add('Fill in intent.goal and intent.successCriteria first; the sections below are only useful once the intent is recorded.')
    }
    $lines.Add('(1) The work-side lead judges. Do not ask the candidate session that made the change to judge.')
    $lines.Add('(2) Keep the four fields separate: correctness = outcome, procedure = how you operated, verdict = may we promote, procedureChecks = the four facts. Complaints about the mechanism go in betterProcedure and the calibration log; they are not a reason to lower verdict.')
    $lines.Add('(3) Criteria live in rule-experiment-apparatus/docs/REVIEW-CRITERIA.md (section 1 is the four-field table).')
    $lines.Add('(4) Write the review block with -ReviewBlockPath. The mechanism pins reviewedCommit (root head) and reviewedRepositories (nested relativePath + headCommit). Do not hand-edit reviews/*.json. Omitting nested on a candidate with child repos fails the gate.')
    $lines.Add('(5) In the same cycle, append one calibration-log block to REVIEW-CRITERIA.md section 7.')

    return ($lines -join [Environment]::NewLine)
}
