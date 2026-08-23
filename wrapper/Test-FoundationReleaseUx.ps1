[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$StatePath,
    [string]$BackupRoot,
    [string]$PatchPath,
    [string]$ExpectedBlob
)

$ErrorActionPreference = 'Stop'
$wrapper = $PSScriptRoot
. (Join-Path $wrapper 'lib\Configuration.ps1')

$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$rawState = Get-Content -Raw -LiteralPath $resolvedStatePath | ConvertFrom-Json
if ([int]$rawState.schemaVersion -eq 2) {
    & (Join-Path $wrapper 'Test-VerifiedHandoff.ps1')
    Write-Output 'SKIP: live UX checks require the phase-06 schema v3 migration; verified-handoff UX fixture passed'
    return
}
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$resolvedBackupRoot = Resolve-BackupRoot -BackupRoot $BackupRoot -Configuration $config -ConfigurationPath $resolvedConfigPath -BasePath (Get-ConfigurationWorkspaceRoot)

function Assert-True([bool]$Value, [string]$Label) {
    if (-not $Value) { throw "ASSERT FAIL: $Label" }
    Write-Output "PASS: $Label"
}

$generation = [int](Read-ReleaseState -StatePath $resolvedStatePath).generation

# 1) Release backup for the current baseline is idempotent for the same
#    generation + commit, so re-running protect never duplicates a bundle.
$baseline = (& (Join-Path $wrapper 'Test-FoundationRelease.ps1') `
    -Role baseline `
    -ConfigPath $resolvedConfigPath `
    -StatePath $resolvedStatePath) | ConvertFrom-Json

$backupArguments = @{
    Role = 'baseline'
    ExpectedGeneration = $generation
    ExpectedCommit = [string]$baseline.commit
    BackupRoot = $resolvedBackupRoot
    ConfigPath = $resolvedConfigPath
    StatePath = $resolvedStatePath
    Execute = $true
}
$backup1 = (& (Join-Path $wrapper 'New-FoundationReleaseBackup.ps1') @backupArguments) | ConvertFrom-Json
Assert-True (Test-Path -LiteralPath $backup1.manifestPath) 'baseline backup manifest path exists'

$backup2 = (& (Join-Path $wrapper 'New-FoundationReleaseBackup.ps1') @backupArguments) | ConvertFrom-Json
Assert-True ([bool]$backup2.alreadyExisted) 're-run reports alreadyExisted'
Assert-True ($backup1.manifestPath -eq $backup2.manifestPath) 'manifest path stable across re-runs'

# 2) doctor stage returns JSON and a usable next hint
$doctor = (& (Join-Path $wrapper 'Invoke-FoundationRelease.ps1') `
    -Stage doctor `
    -ConfigPath $resolvedConfigPath `
    -StatePath $resolvedStatePath) | ConvertFrom-Json
Assert-True ($doctor.stage -eq 'doctor') 'doctor stage field'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$doctor.next)) 'doctor next hint present'

# 3) Root file patch readiness, only when the caller supplies a patch to check.
if ([string]::IsNullOrWhiteSpace($PatchPath)) {
    Write-Output 'SKIP: root file patch readiness (no -PatchPath supplied)'
} else {
    if ([string]::IsNullOrWhiteSpace($ExpectedBlob)) {
        throw '-PatchPath requires -ExpectedBlob.'
    }
    $patchTest = (& (Join-Path $wrapper 'Test-FoundationRootFilePatch.ps1') `
        -PatchPath $PatchPath `
        -ExpectedBlob $ExpectedBlob `
        -Role baseline `
        -ConfigPath $resolvedConfigPath `
        -StatePath $resolvedStatePath) | ConvertFrom-Json
    Assert-True ($patchTest.recommendation -in @('skip-already-applied', 'apply', 'conflict-investigate')) 'patch recommendation is a known value'
    Assert-True ([bool]$patchTest.alreadyApplied -ne [bool]$patchTest.readyToApply) 'alreadyApplied and readyToApply are mutually exclusive'
}

# 4) Promote gate wiring (source checks; run may be absent live).
$invokePath = Join-Path $wrapper 'Invoke-FoundationRelease.ps1'
$invokeLines = Get-Content -LiteralPath $invokePath
$promoteStart = -1
$promoteEnd = $invokeLines.Count
for ($i = 0; $i -lt $invokeLines.Count; $i++) {
    if ($invokeLines[$i] -match "^\s*'promote'\s*\{") {
        $promoteStart = $i
        continue
    }
    if ($promoteStart -ge 0 -and $i -gt $promoteStart -and $invokeLines[$i] -match "^\s*'[a-z0-9-]+'\s*\{") {
        $promoteEnd = $i
        break
    }
}
Assert-True ($promoteStart -ge 0) 'promote stage block found in Invoke-FoundationRelease.ps1'
$promoteBlock = $invokeLines[$promoteStart..($promoteEnd - 1)]
$gateLineInPromote = -1
$promoteCallLineInPromote = -1
for ($i = 0; $i -lt $promoteBlock.Count; $i++) {
    if ($gateLineInPromote -lt 0 -and $promoteBlock[$i] -match 'Test-FoundationReviewGate') {
        $gateLineInPromote = $i
    }
    if ($promoteCallLineInPromote -lt 0 -and $promoteBlock[$i] -match 'Promote-Foundation\.ps1') {
        $promoteCallLineInPromote = $i
    }
}
Assert-True ($gateLineInPromote -ge 0) 'promote block calls Test-FoundationReviewGate'
Assert-True ($promoteCallLineInPromote -ge 0) 'promote block calls Promote-Foundation.ps1'
Assert-True ($gateLineInPromote -lt $promoteCallLineInPromote) 'review gate runs before Promote-Foundation.ps1 in promote stage'

$promoteDryStart = -1
$promoteDryEnd = $invokeLines.Count
for ($i = 0; $i -lt $invokeLines.Count; $i++) {
    if ($invokeLines[$i] -match "^\s*'promote-dry'\s*\{") {
        $promoteDryStart = $i
        continue
    }
    if ($promoteDryStart -ge 0 -and $i -gt $promoteDryStart -and $invokeLines[$i] -match "^\s*'[a-z0-9-]+'\s*\{") {
        $promoteDryEnd = $i
        break
    }
}
Assert-True ($promoteDryStart -ge 0) 'promote-dry stage block found'
$promoteDryBlock = ($invokeLines[$promoteDryStart..($promoteDryEnd - 1)] -join "`n")
Assert-True ($promoteDryBlock -match 'review\s*=\s*\$gate') 'promote-dry result includes review = $gate'
Assert-True ($promoteDryBlock -match 'approvalChecklist\s*=\s*\$checklist') 'promote-dry sets approvalChecklist from $checklist'
$checklistStart = -1
for ($i = 0; $i -lt ($promoteDryEnd - $promoteDryStart); $i++) {
    if ($invokeLines[$promoteDryStart + $i] -match '\$checklist\s*=\s*@\(') {
        $checklistStart = $promoteDryStart + $i
        break
    }
}
Assert-True ($checklistStart -ge 0) 'promote-dry $checklist array start found'
$checklistItems = @()
for ($i = $checklistStart + 1; $i -lt $promoteDryEnd; $i++) {
    $line = $invokeLines[$i]
    if ($line -match '^\s*\)\s*$') { break }
    $m = [regex]::Match($line, "'(.*)'")
    if ($m.Success) { $checklistItems += $m.Groups[1].Value }
}
Assert-True ($checklistItems.Count -eq 6) 'promote-dry approvalChecklist has 6 items'
Assert-True ($checklistItems[5] -match 'review') 'promote-dry checklist increment mentions review'

Assert-True (($promoteBlock -join "`n") -match 'reviewSkipped') 'SkipReview path sets reviewSkipped on promote result'
Assert-True (($promoteBlock -join "`n") -match '\$SkipReview') 'promote stage references -SkipReview'

$seedStart = -1
$seedEnd = $invokeLines.Count
for ($i = 0; $i -lt $invokeLines.Count; $i++) {
    if ($invokeLines[$i] -match "^\s*'seed'\s*\{") {
        $seedStart = $i
        continue
    }
    if ($seedStart -ge 0 -and $i -gt $seedStart -and $invokeLines[$i] -match "^\s*'[a-z0-9-]+'\s*\{") {
        $seedEnd = $i
        break
    }
}
Assert-True ($seedStart -ge 0) 'seed stage block found in Invoke-FoundationRelease.ps1'
$seedBlock = ($invokeLines[$seedStart..($seedEnd - 1)] -join "`n")
Assert-True ($seedBlock -match 'review-init') 'seed execute next points to review-init'
Assert-True ($seedBlock -notmatch 'Edit/commit the candidate workspace') 'seed execute next no longer points at accept-first edit'
$seedSource = Get-Content -LiteralPath (Join-Path $wrapper 'Initialize-NextFoundation.ps1') -Raw
Assert-True ($seedSource -match "\`$targetName\s*=\s*'candidate'") 'seed target is fixed to candidate'
Assert-True ($seedSource -match "Get-ConfiguredInstance\s+-Configuration\s+\`$config\s+-Name\s+'stable'") 'seed source is fixed to stable'

$statusSource = Get-Content -LiteralPath (Join-Path $wrapper 'Get-FoundationStatus.ps1') -Raw
Assert-True ($statusSource -match 'Resolve-ReviewRoot') 'Get-FoundationStatus resolves review root'
Assert-True ($statusSource -match 'review-init') 'Get-FoundationStatus nextAction can point to review-init'
Assert-True ($statusSource -match 'running = \(\$remote\.Count -gt 0\)') 'instance running is WSL .cursor-server only'
Assert-True ($statusSource -notmatch "CommandLine -notmatch '--user-data-dir'") 'default-profile Cursor.exe is not attributed to an instance'
Assert-True ($statusSource -notmatch '\$state\.(active|candidate|previous)\b') 'status does not use legacy channel state'
$runBranchMatch = [regex]::Match(
    $statusSource,
    '(?s)elseif\s*\(\s*\$state\.run\s*\)\s*\{(?<body>.*?)\}\s*elseif\s*\(\s*\$canSeedRun\s*\)'
)
Assert-True ($runBranchMatch.Success) 'Get-FoundationStatus run nextAction branch found'
Assert-True ($runBranchMatch.Groups['body'].Value -match 'Resolve-ReviewRoot') 'run branch resolves review root'
Assert-True ($runBranchMatch.Groups['body'].Value -match 'Test-Path\s+-LiteralPath\s+\$recordPath\s+-PathType\s+Leaf') 'run branch tests review record path existence'

$protectStart = -1
$protectEnd = $invokeLines.Count
for ($i = 0; $i -lt $invokeLines.Count; $i++) {
    if ($invokeLines[$i] -match "^\s*'protect'\s*\{") {
        $protectStart = $i
        continue
    }
    if ($protectStart -ge 0 -and $i -gt $protectStart -and $invokeLines[$i] -match "^\s*'[a-z0-9-]+'\s*\{") {
        $protectEnd = $i
        break
    }
}
Assert-True ($protectStart -ge 0) 'protect stage block found'
$protectBlock = ($invokeLines[$protectStart..($protectEnd - 1)] -join "`n")
Assert-True ($protectBlock -match '-Stage review') 'protect next points to -Stage review'
Assert-True ($protectBlock -notmatch 'promote-dry') 'protect next does not point to promote-dry'

$reviewStart = -1
$reviewEnd = $invokeLines.Count
for ($i = 0; $i -lt $invokeLines.Count; $i++) {
    if ($invokeLines[$i] -match "^\s*'review'\s*\{") {
        $reviewStart = $i
        continue
    }
    if ($reviewStart -ge 0 -and $i -gt $reviewStart -and $invokeLines[$i] -match "^\s*'[a-z0-9-]+'\s*\{") {
        $reviewEnd = $i
        break
    }
}
Assert-True ($reviewStart -ge 0) 'review stage block found'
$reviewBlock = ($invokeLines[$reviewStart..($reviewEnd - 1)] -join "`n")
Assert-True ($reviewBlock -match 'promote-dry') 'review next points to promote-dry'
Assert-True ($reviewBlock -match 'ReviewBlockPath') 'review stage references ReviewBlockPath'
$reviewNextLine = ($invokeLines[$reviewStart..($reviewEnd - 1)] | Where-Object { $_ -match '^\s*next\s*=' } | Select-Object -First 1)
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$reviewNextLine)) 'review next assignment line found'
Assert-True ($reviewNextLine -notmatch '-Stage protect') 'review next assignment does not point to -Stage protect'
Assert-True ($reviewNextLine -match 'REVIEW-CRITERIA') 'review next assignment mentions REVIEW-CRITERIA'

$reviewInitStart = -1
$reviewInitEnd = $invokeLines.Count
for ($i = 0; $i -lt $invokeLines.Count; $i++) {
    if ($invokeLines[$i] -match "^\s*'review-init'\s*\{") {
        $reviewInitStart = $i
        continue
    }
    if ($reviewInitStart -ge 0 -and $i -gt $reviewInitStart -and $invokeLines[$i] -match "^\s*'[a-z0-9-]+'\s*\{") {
        $reviewInitEnd = $i
        break
    }
}
Assert-True ($reviewInitStart -ge 0) 'review-init stage block found'
$reviewInitBlock = ($invokeLines[$reviewInitStart..($reviewInitEnd - 1)] -join "`n")
Assert-True ($reviewInitBlock -match '-Stage inject') 'review-init next points to inject'
Assert-True ($reviewInitBlock -match 'protect') 'review-init next includes protect'
Assert-True ($reviewInitBlock -match 'overwrite|already exists|一度') 'review-init next mentions once-only / overwrite'

$discardStart = -1
$discardEnd = $invokeLines.Count
for ($i = 0; $i -lt $invokeLines.Count; $i++) {
    if ($invokeLines[$i] -match "^\s*'discard'\s*\{") {
        $discardStart = $i
        continue
    }
    if ($discardStart -ge 0 -and $i -gt $discardStart -and $invokeLines[$i] -match "^\s*'[a-z0-9-]+'\s*\{") {
        $discardEnd = $i
        break
    }
}
Assert-True ($discardStart -ge 0) 'discard stage block found in Invoke-FoundationRelease.ps1'
$discardBlock = ($invokeLines[$discardStart..($discardEnd - 1)] -join "`n")
Assert-True ($discardBlock -match '\$ConfirmDiscard') 'discard stage references -ConfirmDiscard'
Assert-True ($discardBlock -match 'Discard-Foundation\.ps1') 'discard block calls Discard-Foundation.ps1'
Assert-True ($discardBlock -notmatch 'Promote-Foundation\.ps1') 'discard block does not call Promote-Foundation.ps1'
Assert-True ($discardBlock -match 'ConfirmDiscard') 'discard next mentions ConfirmDiscard'
$invokeParamBlock = ($invokeLines[0..40] -join "`n")
Assert-True ($invokeParamBlock -match 'ConfirmDiscard') 'facade declares -ConfirmDiscard'
Assert-True ($invokeParamBlock -match '\[string\]\$Experiment') 'facade declares -Experiment'
Assert-True ($invokeParamBlock -match '\[string\]\$Variant') 'facade declares -Variant'
Assert-True ($invokeParamBlock -notmatch '\[string\]\$Channel') 'discard public stage has no Channel parameter'
Assert-True ($invokeParamBlock -notmatch '\[string\]\$Path') 'discard public stage has no Path parameter'
Assert-True ($invokeParamBlock -notmatch '\[string\]\$Instance') 'discard public stage has no Instance parameter'

$injectStart = -1
$injectEnd = $invokeLines.Count
for ($i = 0; $i -lt $invokeLines.Count; $i++) {
    if ($invokeLines[$i] -match "^\s*'inject'\s*\{") {
        $injectStart = $i
        continue
    }
    if ($injectStart -ge 0 -and $i -gt $injectStart -and $invokeLines[$i] -match "^\s*'[a-z0-9-]+'\s*\{") {
        $injectEnd = $i
        break
    }
}
Assert-True ($injectStart -ge 0) 'inject stage block found in Invoke-FoundationRelease.ps1'
$injectBlock = ($invokeLines[$injectStart..($injectEnd - 1)] -join "`n")
Assert-True ($injectBlock -match 'Inject-FoundationVariant\.ps1') 'inject block calls Inject-FoundationVariant.ps1'
Assert-True ($injectBlock -match '-Stage handoff') 'inject next points to handoff'
Assert-True ($injectBlock -notmatch 'cursor-instance\.ps1') 'inject does not call a low-level launcher'

# Seed dry-run must refuse an existing target; existence check precedes the plan return.
$existCheckIndex = $seedSource.IndexOf("test '!' -e")
$dryRunPlanIndex = $seedSource.IndexOf('if ($DryRun) { $plan | ConvertTo-Json')
Assert-True ($existCheckIndex -ge 0) 'Initialize-NextFoundation.ps1 has target existence check'
Assert-True ($dryRunPlanIndex -ge 0) 'Initialize-NextFoundation.ps1 has DryRun plan return'
Assert-True ($existCheckIndex -lt $dryRunPlanIndex) 'target existence check runs before DryRun plan return'

Write-Output 'PASS: Test-FoundationReleaseUx.ps1'
