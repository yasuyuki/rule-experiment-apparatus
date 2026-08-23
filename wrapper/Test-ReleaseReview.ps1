[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\ReleaseReview.ps1')
. (Join-Path $PSScriptRoot 'lib\Presentation.ps1')

function Assert-Area {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Expected
    )

    $actual = Get-FoundationChangeArea -Path $Path
    if ($actual -ne $Expected) {
        throw "Get-FoundationChangeArea('$Path') expected '$Expected', got '$actual'."
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', got '$Actual'." }
}

function Assert-EqualSequence {
    param([object[]]$Actual, [object[]]$Expected, [string]$Label)
    if ($Actual.Count -ne $Expected.Count) { throw "$Label expected $($Expected.Count) items, got $($Actual.Count)." }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ([string]$Actual[$i] -cne [string]$Expected[$i]) { throw "$Label expected '$($Expected[$i])' at [$i], got '$($Actual[$i]).'" }
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Label)
    try {
        & $Action | Out-Null
    } catch {
        return
    }
    throw "$Label expected an error."
}

Assert-Area '.cursor/rules/foundation.mdc' 'llm-config'
Assert-Area '.claude/agents/designer.md' 'llm-config'
Assert-Area 'AGENTS.md' 'llm-config'
Assert-Area 'sub/CLAUDE.md' 'llm-config'
Assert-Area 'wrapper/lib/Configuration.ps1' 'control-plane'
Assert-Area 'docs/COMMANDS.md' 'docs'
Assert-Area 'README.md' 'docs'
Assert-Area 'example-app/src/a.ts' 'other'

# --- Assert-FoundationReviewRecordShape: a valid record and its rejection cases ---

function New-ValidReviewRecord {
    return [ordered]@{
        schemaVersion = 1
        release = 'release-11'
        generation = 2
        baseCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        late = $false
        intent = [ordered]@{
            recordedAt = '2026-01-01T00:00:00+00:00'
            goal = 'Try a new .cursor rule for X.'
            expectedEffects = @('Fewer Y errors.')
            successCriteria = @('No Y errors in a 30 minute session.')
            nonGoals = @()
        }
        review = [ordered]@{
            reviewedAt = '2026-01-02T00:00:00+00:00'
            reviewedCommit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            correctness = 'pass'
            procedure = 'good'
            criteriaResults = @(
                [ordered]@{ criterion = 'No Y errors in a 30 minute session.'; result = 'met'; evidence = 'Ran for 45 minutes, no Y errors.' }
            )
            observedEffects = @('Fewer Y errors.')
            procedureChecks = [ordered]@{
                minimalChange = 'yes'
                verifiedBeforeProceeding = 'yes'
                rollbackPreserved = 'yes'
                stableIsolationUsed = 'yes'
            }
            betterProcedure = 'none'
            verdict = 'accepted'
        }
    }
}

function ConvertTo-ReviewRecordObject {
    param([Parameter(Mandatory)] [object]$Record)
    # Round-trip through JSON so mutated hashtables are exercised as the same
    # PSCustomObject shape Read-FoundationReviewRecord sees from disk.
    return ($Record | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
}

$validRecord = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
Assert-FoundationReviewRecordShape -Record $validRecord -Context 'valid fixture'

foreach ($case in @(
        @{ label = 'empty goal'; mutate = { param($r) $r.intent.goal = '' } },
        @{ label = 'empty successCriteria'; mutate = { param($r) $r.intent.successCriteria = @() } },
        @{ label = 'baseCommit not 40-hex'; mutate = { param($r) $r.baseCommit = 'not-a-commit' } },
        @{ label = 'release name does not match pattern'; mutate = { param($r) $r.release = 'has a space' } },
        @{ label = 'schemaVersion is not 1'; mutate = { param($r) $r.schemaVersion = 2 } },
        @{ label = 'criteriaResults count mismatch'; mutate = { param($r) $r.review.criteriaResults = @() } },
        @{ label = 'criterion string mismatch'; mutate = { param($r) $r.review.criteriaResults[0].criterion = 'a different criterion' } },
        @{ label = 'verdict outside enum'; mutate = { param($r) $r.review.verdict = 'maybe' } },
        @{ label = 'reviewedCommit not 40-hex'; mutate = { param($r) $r.review.reviewedCommit = 'short' } },
        @{ label = 'procedureChecks missing a key'; mutate = { param($r) $r.review.procedureChecks.PSObject.Properties.Remove('stableIsolationUsed') } },
        # -notmatch/-notcontains are case-insensitive by default in PowerShell;
        # an upper-cased hex commit id or enum value must still be rejected.
        @{ label = 'baseCommit uppercase hex'; mutate = { param($r) $r.baseCommit = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' } },
        @{ label = 'verdict uppercase'; mutate = { param($r) $r.review.verdict = 'ACCEPTED' } }
    )) {
    $mutated = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
    & $case.mutate $mutated
    Assert-Throws { Assert-FoundationReviewRecordShape -Record $mutated -Context $case.label } "rejects $($case.label)"
}

# --- schema parity: release-review.schema.json is the static shape authority ---

# Pin the public contract, then generate an invalid fixture for every static
# constraint reachable from the schema root and require the validator to
# reject each one. The cases are derived from the schema file at test time:
# changing required / enum / additionalProperties / types / patterns in the
# schema changes the generated cases, so validator drift fails here.

$schemaPath = Join-Path $PSScriptRoot 'schemas\release-review.schema.json'
$reviewSchema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json
$reviewSchemaDefs = $reviewSchema.'$defs'

Assert-EqualSequence -Actual @($reviewSchema.required) -Expected @('schemaVersion', 'release', 'generation', 'baseCommit', 'late', 'intent', 'review') -Label 'schema root.required'
Assert-Equal $reviewSchema.additionalProperties $false 'schema root.additionalProperties'
Assert-Equal $reviewSchema.properties.schemaVersion.const 1 'schema schemaVersion.const'
Assert-EqualSequence -Actual @($reviewSchemaDefs.review.properties.correctness.enum) -Expected @('pass', 'partial', 'fail') -Label 'schema correctness.enum'
Assert-EqualSequence -Actual @($reviewSchemaDefs.review.properties.procedure.enum) -Expected @('good', 'acceptable', 'needs-improvement') -Label 'schema procedure.enum'
Assert-EqualSequence -Actual @($reviewSchemaDefs.review.properties.verdict.enum) -Expected @('accepted', 'needs-work', 'rejected') -Label 'schema verdict.enum'
Assert-EqualSequence -Actual @($reviewSchemaDefs.criteriaResult.properties.result.enum) -Expected @('met', 'unmet', 'unknown') -Label 'schema criteriaResult.result.enum'
Assert-EqualSequence -Actual @($reviewSchemaDefs.procedureChecks.properties.minimalChange.enum) -Expected @('yes', 'no', 'na') -Label 'schema procedureCheck.enum'
Assert-EqualSequence -Actual @($reviewSchemaDefs.procedureChecks.required) -Expected @('minimalChange', 'verifiedBeforeProceeding', 'rollbackPreserved', 'stableIsolationUsed') -Label 'schema procedureChecks.required'

# The interpreter must reject keywords it does not implement, but property and
# definition names are user-defined schema map keys rather than keywords.
$unknownKeywordSchema = $reviewSchema | ConvertTo-Json -Depth 100 | ConvertFrom-Json
$unknownKeywordSchema | Add-Member -NotePropertyName 'unsupportedKeyword' -NotePropertyValue $true
Assert-Throws { Assert-FoundationReviewSchemaSupported -Schema $unknownKeywordSchema -Context 'unknown keyword fixture' } 'rejects an unsupported schema keyword'

$namedSchema = $reviewSchema | ConvertTo-Json -Depth 100 | ConvertFrom-Json
$namedSchema.properties | Add-Member -NotePropertyName 'arbitraryPropertyName' -NotePropertyValue ([pscustomobject]@{ type = 'string' })
$namedSchema.'$defs' | Add-Member -NotePropertyName 'arbitraryDefinitionName' -NotePropertyValue ([pscustomobject]@{ type = 'string' })
Assert-FoundationReviewSchemaSupported -Schema $namedSchema -Context 'arbitrary schema map names fixture'

$conditionalSchema = $reviewSchema | ConvertTo-Json -Depth 100 | ConvertFrom-Json
$conditionalSchema.allOf = @($conditionalSchema.allOf) + @(
    [pscustomobject]@{ properties = [pscustomobject]@{ release = [pscustomobject]@{ const = '__must_not_pass__' } } }
)
$conditionalRecord = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$conditionalError = Get-FoundationSchemaShapeError -Root $conditionalSchema -Node $conditionalSchema -Value $conditionalRecord -Path 'record'
if ($null -eq $conditionalError) { throw 'allOf constraints must be enforced by the runtime schema interpreter.' }

function Copy-ParityRecord {
    # Includes the optional reviewedRepositories block so generated cases can
    # reach every path the schema describes.
    $record = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
    $record.review | Add-Member -NotePropertyName 'reviewedRepositories' -NotePropertyValue @(
        [pscustomobject]@{ relativePath = 'parity-child'; headCommit = ('c' * 40) }
    )
    return $record
}

function Get-ParityTarget {
    param([object]$Object, [object[]]$Segments)
    foreach ($segment in $Segments) { $Object = $Object.PSObject.Properties[$segment].Value }
    return $Object
}

# Applies one generated case to a record (or to a synthesized array element
# when building items cases). Returns the possibly-replaced target.
function Invoke-ParityMutation {
    param([object]$Target, [object]$Case)
    $segments = @($Case.segments)
    if ($segments.Count -eq 0) {
        if ($Case.kind -eq 'set') { return $Case.value }
        throw "parity case '$($Case.label)' cannot $($Case.kind) the value itself."
    }
    $parent = $Target
    for ($i = 0; $i -lt $segments.Count - 1; $i++) { $parent = $parent.PSObject.Properties[$segments[$i]].Value }
    $key = [string]$segments[-1]
    switch ($Case.kind) {
        'remove' { $parent.PSObject.Properties.Remove($key) }
        'add'    { $parent | Add-Member -NotePropertyName $key -NotePropertyValue $Case.value }
        default  { $parent.PSObject.Properties[$key].Value = $Case.value }
    }
    return $Target
}

# A valid element for each array in the record, used as the base when an items
# sub-case mutates one element. Keys must match schema property names; a schema
# rename falls through to the string default and those cases fail loudly.
function New-ParityValidItem {
    param([string]$ArrayPath)
    switch ($ArrayPath) {
        'record.review.criteriaResults' {
            return [pscustomobject]@{ criterion = 'No Y errors in a 30 minute session.'; result = 'met'; evidence = 'Observed during the parity fixture run.' }
        }
        'record.review.reviewedRepositories' {
            return [pscustomobject]@{ relativePath = 'parity-child'; headCommit = ('c' * 40) }
        }
        default { return 'parity-item' }
    }
}

function Get-ParitySubCases {
    param([object]$Schema, [object]$Node, [string]$Where)

    $node = Resolve-FoundationSchemaRef -Root $Schema -Node $Node
    $cases = [System.Collections.Generic.List[object]]::new()

    $anyOfProperty = $node.PSObject.Properties['anyOf']
    if ($null -ne $anyOfProperty) {
        foreach ($branch in @($anyOfProperty.Value)) {
            foreach ($case in (Get-ParitySubCases -Schema $Schema -Node $branch -Where $Where)) { $cases.Add($case) }
        }
        return @($cases.ToArray())
    }

    $typeProperty = $node.PSObject.Properties['type']
    $types = @(); if ($null -ne $typeProperty) { $types = @([string[]]$typeProperty.Value) }

    if ($null -ne $typeProperty) {
        foreach ($type in $types) {
            $wrongTypeValue = switch ($type) {
                'object'  { 'not-an-object' }
                'array'   { 'not-an-array' }
                'string'  { 12345 }
                'integer' { 'not-an-integer' }
                'number'  { 'not-a-number' }
                'boolean' { 'not-a-boolean' }
                'null'    { 12345 }
                default   { $null }
            }
            if ($null -ne $wrongTypeValue) {
                $cases.Add(@{ label = "$Where type must be $type"; kind = 'set'; segments = @(); value = $wrongTypeValue })
            }
        }
    }

    $constProperty = $node.PSObject.Properties['const']
    if ($null -ne $constProperty) {
        $cases.Add(@{ label = "$Where const violated"; kind = 'set'; segments = @(); value = '__parity_wrong_const__' })
    }

    $enumProperty = $node.PSObject.Properties['enum']
    if ($null -ne $enumProperty) {
        $cases.Add(@{ label = "$Where enum violated"; kind = 'set'; segments = @(); value = '__parity_not_in_enum__' })
    }

    if ($types -contains 'string') {
        $patternProperty = $node.PSObject.Properties['pattern']
        if ($null -ne $patternProperty) {
            $pattern = [string]$patternProperty.Value
            foreach ($candidate in @('!!', 'has a space', 'ZZZZ', '')) {
                if ($candidate -cnotmatch $pattern) {
                    $cases.Add(@{ label = "$Where pattern violated"; kind = 'set'; segments = @(); value = $candidate })
                    break
                }
            }
        }
        if ($null -ne $node.PSObject.Properties['minLength']) {
            $cases.Add(@{ label = "$Where minLength violated"; kind = 'set'; segments = @(); value = '' })
        }
    }

    if ($types -contains 'array') {
        if ($null -ne $node.PSObject.Properties['minItems']) {
            $cases.Add(@{ label = "$Where minItems violated"; kind = 'set'; segments = @(); value = @() })
        }
        $itemsProperty = $node.PSObject.Properties['items']
        if ($null -ne $itemsProperty) {
            foreach ($itemCase in (Get-ParitySubCases -Schema $Schema -Node $itemsProperty.Value -Where "$Where[]")) {
                $element = Invoke-ParityMutation -Target (New-ParityValidItem -ArrayPath $Where) -Case $itemCase
                $cases.Add(@{ label = $itemCase.label; kind = 'set'; segments = @(); value = @($element) })
            }
        }
    }

    $isObjectSchema = ($types -contains 'object') -or
        ($null -ne $node.PSObject.Properties['properties']) -or
        ($null -ne $node.PSObject.Properties['required']) -or
        ($null -ne $node.PSObject.Properties['additionalProperties'])
    if ($isObjectSchema) {
        $requiredProperty = $node.PSObject.Properties['required']
        if ($null -ne $requiredProperty) {
            foreach ($key in [string[]]@($requiredProperty.Value)) {
                $cases.Add(@{ label = "$Where missing required '$key'"; kind = 'remove'; segments = @([string]$key); value = $null })
            }
        }
        $additionalProperty = $node.PSObject.Properties['additionalProperties']
        if ($null -ne $additionalProperty -and $additionalProperty.Value -eq $false) {
            $cases.Add(@{ label = "$Where unknown property rejected"; kind = 'add'; segments = @('__parityUnknown__'); value = 'parity' })
        }
        $propertiesProperty = $node.PSObject.Properties['properties']
        if ($null -ne $propertiesProperty) {
            foreach ($property in $propertiesProperty.Value.PSObject.Properties) {
                foreach ($case in (Get-ParitySubCases -Schema $Schema -Node $property.Value -Where "$Where.$($property.Name)")) {
                    $case.segments = @([string]$property.Name) + @($case.segments)
                    $cases.Add($case)
                }
            }
        }
    }

    return @($cases.ToArray())
}

$parityCases = Get-ParitySubCases -Schema $reviewSchema -Node $reviewSchema -Where 'record'
if ($parityCases.Count -lt 30) {
    throw "schema parity walker produced only $($parityCases.Count) cases; it is not walking the full schema."
}
foreach ($parityCase in $parityCases) {
    $mutated = Invoke-ParityMutation -Target (Copy-ParityRecord) -Case $parityCase
    Assert-Throws { Assert-FoundationReviewRecordShape -Record $mutated -Context 'parity fixture' } "rejects parity: $($parityCase.label)"
}

# --- New-FoundationReviewRecordSkeleton / Read-FoundationReviewRecord ---

$skeleton = New-FoundationReviewRecordSkeleton -Release 'release-12' -Generation 3 -BaseCommit 'cccccccccccccccccccccccccccccccccccccccc' -Late $true
Assert-equal $skeleton.schemaVersion 1 'skeleton.schemaVersion'
Assert-equal $skeleton.release 'release-12' 'skeleton.release'
Assert-equal $skeleton.late $true 'skeleton.late'
Assert-equal $skeleton.review $null 'skeleton.review'
Assert-equal $skeleton.intent.goal '' 'skeleton.intent.goal'
Assert-equal @($skeleton.intent.successCriteria).Count 0 'skeleton.intent.successCriteria'

$temporaryReviewRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-review-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryReviewRoot | Out-Null
try {
    $recordPath = Join-Path $temporaryReviewRoot 'release-11.json'
    (New-ValidReviewRecord | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $recordPath -Encoding utf8
    $readRecord = Read-FoundationReviewRecord -Path $recordPath
    Assert-equal $readRecord.release 'release-11' 'Read-FoundationReviewRecord.release'

    $invalidPath = Join-Path $temporaryReviewRoot 'invalid.json'
    '{"schemaVersion":1}' | Set-Content -LiteralPath $invalidPath -Encoding utf8
    Assert-Throws { Read-FoundationReviewRecord -Path $invalidPath } 'Read-FoundationReviewRecord rejects a malformed record'
} finally {
    Remove-Item -LiteralPath $temporaryReviewRoot -Recurse -Force
}

# --- Test-FoundationReviewGate truth table ---

$currentCommit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$otherCommit = 'dddddddddddddddddddddddddddddddddddddddd'

$gate = Test-FoundationReviewGate -Record $null -CurrentCommit $currentCommit
Assert-equal $gate.recordPresent $false 'gate(null record).recordPresent'
Assert-equal $gate.satisfied $false 'gate(null record).satisfied'

$noReviewRecord = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$noReviewRecord.review = $null
$gate = Test-FoundationReviewGate -Record $noReviewRecord -CurrentCommit $currentCommit
Assert-equal $gate.recordPresent $true 'gate(review=null).recordPresent'
Assert-equal $gate.verdict $null 'gate(review=null).verdict'
Assert-equal $gate.satisfied $false 'gate(review=null).satisfied'

foreach ($verdict in @('needs-work', 'rejected')) {
    $record = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
    $record.review.verdict = $verdict
    $gate = Test-FoundationReviewGate -Record $record -CurrentCommit $currentCommit
    Assert-equal $gate.satisfied $false "gate(verdict=$verdict).satisfied"
}

$acceptedMismatch = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$gate = Test-FoundationReviewGate -Record $acceptedMismatch -CurrentCommit $otherCommit
Assert-equal $gate.reviewedCommitMatches $false 'gate(accepted, commit mismatch).reviewedCommitMatches'
Assert-equal $gate.satisfied $false 'gate(accepted, commit mismatch).satisfied'

$acceptedMatch = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$gate = Test-FoundationReviewGate -Record $acceptedMatch -CurrentCommit $currentCommit
Assert-equal $gate.reviewedCommitMatches $true 'gate(accepted, commit match).reviewedCommitMatches'
Assert-equal $gate.satisfied $true 'gate(accepted, commit match).satisfied'

# Test-FoundationReviewGate itself must compare verdict case-sensitively: an
# upper-cased 'ACCEPTED' (which Assert-FoundationReviewRecordShape now rejects
# on its own) must not satisfy the gate if it somehow reaches it directly.
$acceptedUppercase = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$acceptedUppercase.review.verdict = 'ACCEPTED'
$gate = Test-FoundationReviewGate -Record $acceptedUppercase -CurrentCommit $currentCommit
Assert-equal $gate.satisfied $false 'gate(verdict=ACCEPTED uppercase).satisfied'

# --- reviewedRepositories shape (optional) + gate with -CurrentRepositories ---

$withReviewedRepos = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$withReviewedRepos.review | Add-Member -NotePropertyName 'reviewedRepositories' -NotePropertyValue @(
    [pscustomobject]@{ relativePath = 'example-player'; headCommit = ('c' * 40) }
) -Force
Assert-FoundationReviewRecordShape -Record $withReviewedRepos -Context 'valid fixture with reviewedRepositories'

$badNestedHead = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$badNestedHead.review | Add-Member -NotePropertyName 'reviewedRepositories' -NotePropertyValue @(
    [pscustomobject]@{ relativePath = 'example-player'; headCommit = 'short' }
) -Force
Assert-Throws { Assert-FoundationReviewRecordShape -Record $badNestedHead -Context 'nested headCommit not 40-hex' } 'rejects nested headCommit not 40-hex'

$dupNestedPath = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$dupNestedPath.review | Add-Member -NotePropertyName 'reviewedRepositories' -NotePropertyValue @(
    [pscustomobject]@{ relativePath = 'example-player'; headCommit = ('c' * 40) },
    [pscustomobject]@{ relativePath = 'example-player'; headCommit = ('d' * 40) }
) -Force
Assert-Throws { Assert-FoundationReviewRecordShape -Record $dupNestedPath -Context 'duplicate relativePath' } 'rejects duplicate reviewedRepositories.relativePath'

# Field absent: existing fixture still passes (already asserted above as validRecord).
Assert-FoundationReviewRecordShape -Record $validRecord -Context 'existing fixture without reviewedRepositories still passes'

$nestedCurrent = @(
    [ordered]@{ relativePath = 'example-player'; headCommit = ('c' * 40) }
)

# Omitting -CurrentRepositories keeps the historical root-only truth table.
$gate = Test-FoundationReviewGate -Record $acceptedMatch -CurrentCommit $currentCommit
Assert-equal $gate.satisfied $true 'gate(omit CurrentRepositories, accepted+root match).satisfied'

$acceptedMissingNested = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$gate = Test-FoundationReviewGate -Record $acceptedMissingNested -CurrentCommit $currentCommit -CurrentRepositories $nestedCurrent
Assert-equal $gate.reviewedCommitMatches $false 'gate(CurrentRepositories present, reviewedRepositories absent).reviewedCommitMatches'
Assert-equal $gate.satisfied $false 'gate(CurrentRepositories present, reviewedRepositories absent).satisfied'

$acceptedNestedMatch = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$acceptedNestedMatch.review | Add-Member -NotePropertyName 'reviewedRepositories' -NotePropertyValue @(
    [pscustomobject]@{ relativePath = 'example-player'; headCommit = ('c' * 40) }
) -Force
$gate = Test-FoundationReviewGate -Record $acceptedNestedMatch -CurrentCommit $currentCommit -CurrentRepositories $nestedCurrent
Assert-equal $gate.reviewedCommitMatches $true 'gate(root+nested 1:1).reviewedCommitMatches'
Assert-equal $gate.satisfied $true 'gate(root+nested 1:1).satisfied'

$nestedShaMismatchCurrent = @(
    [ordered]@{ relativePath = 'example-player'; headCommit = ('d' * 40) }
)
$gate = Test-FoundationReviewGate -Record $acceptedNestedMatch -CurrentCommit $currentCommit -CurrentRepositories $nestedShaMismatchCurrent
Assert-equal $gate.reviewedCommitMatches $false 'gate(nested sha mismatch).reviewedCommitMatches'
Assert-equal $gate.satisfied $false 'gate(nested sha mismatch).satisfied'

$gate = Test-FoundationReviewGate -Record $acceptedMatch -CurrentCommit $currentCommit -CurrentRepositories @()
Assert-equal $gate.reviewedCommitMatches $true 'gate(CurrentRepositories @(), reviewedRepositories absent).reviewedCommitMatches'
Assert-equal $gate.satisfied $true 'gate(CurrentRepositories @(), reviewedRepositories absent).satisfied'

$gate = Test-FoundationReviewGate -Record $acceptedMatch -CurrentCommit $currentCommit -CurrentRepositories @($null)
Assert-equal $gate.reviewedCommitMatches $true 'gate(CurrentRepositories @($null) treated as empty).reviewedCommitMatches'
Assert-equal $gate.satisfied $true 'gate(CurrentRepositories @($null) treated as empty).satisfied'

$gate = Test-FoundationReviewGate -Record $acceptedNestedMatch -CurrentCommit $currentCommit -CurrentRepositories @()
Assert-equal $gate.reviewedCommitMatches $false 'gate(empty current, reviewedRepositories present).reviewedCommitMatches'
Assert-equal $gate.satisfied $false 'gate(empty current, reviewedRepositories present).satisfied'

# --- Resolve-ReviewRoot resolution order: argument > env var > environment.local.json > default ---

. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')

$temporaryConfigRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-reviewroot-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryConfigRoot | Out-Null
$originalReviewRootEnv = [Environment]::GetEnvironmentVariable('FOUNDATION_CONTROL_REVIEW_ROOT', 'Process')
$localConfigPath = Get-LocalEnvironmentConfigPath
$localConfigBackup = $null
try {
    if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
        $localConfigBackup = Join-Path $temporaryConfigRoot 'environment.local.json.bak'
        Move-Item -LiteralPath $localConfigPath -Destination $localConfigBackup
    }

    $statePath = Join-Path $PSScriptRoot 'config\release-state.example.json'
    $stateParent = Split-Path -Parent (Resolve-Path -LiteralPath $statePath).Path
    $expectedDefault = [System.IO.Path]::GetFullPath((Join-Path $stateParent 'reviews'))
    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_REVIEW_ROOT', $null, 'Process')
    Assert-equal (Resolve-ReviewRoot -StatePath $statePath) $expectedDefault 'Resolve-ReviewRoot default (StatePath parent + reviews)'

    (@{ reviewRoot = (Join-Path $temporaryConfigRoot 'from-local-config') } | ConvertTo-Json) | Set-Content -LiteralPath $localConfigPath -Encoding utf8
    Assert-equal (Resolve-ReviewRoot -StatePath $statePath) ([System.IO.Path]::GetFullPath((Join-Path $temporaryConfigRoot 'from-local-config'))) 'Resolve-ReviewRoot from environment.local.json'

    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_REVIEW_ROOT', (Join-Path $temporaryConfigRoot 'from-env'), 'Process')
    Assert-equal (Resolve-ReviewRoot -StatePath $statePath) ([System.IO.Path]::GetFullPath((Join-Path $temporaryConfigRoot 'from-env'))) 'Resolve-ReviewRoot from FOUNDATION_CONTROL_REVIEW_ROOT env var (overrides local config)'

    Assert-equal (Resolve-ReviewRoot -ReviewRoot (Join-Path $temporaryConfigRoot 'from-arg') -StatePath $statePath) ([System.IO.Path]::GetFullPath((Join-Path $temporaryConfigRoot 'from-arg'))) 'Resolve-ReviewRoot -ReviewRoot argument (overrides env var)'
} finally {
    [Environment]::SetEnvironmentVariable('FOUNDATION_CONTROL_REVIEW_ROOT', $originalReviewRootEnv, 'Process')
    if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
        Remove-Item -LiteralPath $localConfigPath -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($localConfigBackup)) {
        Move-Item -LiteralPath $localConfigBackup -Destination $localConfigPath
    }
    Remove-Item -LiteralPath $temporaryConfigRoot -Recurse -Force
}

# --- Assert-FoundationReviewRecordShape / Read-FoundationReviewRecord: draft vs. sealed intent ---

$draftSkeleton = New-FoundationReviewRecordSkeleton -Release 'release-13' -Generation 4 -BaseCommit ('0' * 40) -Late $true
Assert-FoundationReviewRecordShape -Record $draftSkeleton -Context 'draft record passes without RequireIntentComplete'

$draftSkeletonForCompleteness = New-FoundationReviewRecordSkeleton -Release 'release-13' -Generation 4 -BaseCommit ('0' * 40) -Late $true
Assert-Throws { Assert-FoundationReviewRecordShape -Record $draftSkeletonForCompleteness -Context 'draft record fails with RequireIntentComplete' -RequireIntentComplete } 'draft record fails with RequireIntentComplete'

$lateFalseDraft = New-FoundationReviewRecordSkeleton -Release 'release-13' -Generation 4 -BaseCommit ('0' * 40) -Late $false
Assert-Throws { Assert-FoundationReviewRecordShape -Record $lateFalseDraft -Context 'draft record with late false is rejected' } 'draft record with late false is rejected'

$sealedRecord = New-FoundationReviewRecordSkeleton -Release 'release-13' -Generation 4 -BaseCommit ('0' * 40) -Late $false -Goal 'g' -SuccessCriteria @('c')
Assert-FoundationReviewRecordShape -Record $sealedRecord -Context 'sealed record with late false passes' -RequireIntentComplete

$whitespaceCriteriaRecord = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$whitespaceCriteriaRecord.intent.successCriteria = @('   ')
Assert-Throws { Assert-FoundationReviewRecordShape -Record $whitespaceCriteriaRecord -Context 'successCriteria with only whitespace entries is rejected' } 'successCriteria with only whitespace entries is rejected'

$temporaryDraftRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-review-draft-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryDraftRoot | Out-Null
try {
    $draftPath = Join-Path $temporaryDraftRoot 'draft.json'
    $draftToWrite = New-FoundationReviewRecordSkeleton -Release 'release-14' -Generation 5 -BaseCommit ('1' * 40) -Late $true
    ($draftToWrite | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $draftPath -Encoding utf8
    $readDraft = Read-FoundationReviewRecord -Path $draftPath
    Assert-equal $readDraft.late $true 'Read-FoundationReviewRecord reads a draft'
    Assert-Throws { Read-FoundationReviewRecord -Path $draftPath -RequireIntentComplete } 'Read-FoundationReviewRecord -RequireIntentComplete rejects a draft'
} finally {
    Remove-Item -LiteralPath $temporaryDraftRoot -Recurse -Force
}

# --- gate(draft record).intentComplete / gate(accepted, empty intent).satisfied ---

$draftForGate = New-FoundationReviewRecordSkeleton -Release 'release-14' -Generation 5 -BaseCommit ('1' * 40) -Late $true
$gate = Test-FoundationReviewGate -Record $draftForGate -CurrentCommit $currentCommit
Assert-equal $gate.intentComplete $false 'gate(draft record).intentComplete'
Assert-equal $gate.satisfied $false 'gate(draft record).satisfied'

$acceptedEmptyIntent = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$acceptedEmptyIntent.intent.goal = ''
$acceptedEmptyIntent.intent.successCriteria = @()
$gate = Test-FoundationReviewGate -Record $acceptedEmptyIntent -CurrentCommit $currentCommit
Assert-equal $gate.satisfied $false 'gate(accepted, empty intent).satisfied'

# --- Test-FoundationReviewIntentComplete predicate ---

Assert-equal (Test-FoundationReviewIntentComplete -Record $null) $false 'intent complete predicate: null'
$draftForPredicate = New-FoundationReviewRecordSkeleton -Release 'release-14' -Generation 5 -BaseCommit ('1' * 40) -Late $true
Assert-equal (Test-FoundationReviewIntentComplete -Record $draftForPredicate) $false 'intent complete predicate: draft'
$completeForPredicate = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
Assert-equal (Test-FoundationReviewIntentComplete -Record $completeForPredicate) $true 'intent complete predicate: complete record'

# --- Get-FoundationReviewInitPlan ---

$planBaseCommit = 'e' * 40
$planOtherCommit = 'f' * 40

$sealedPlan = Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit $planBaseCommit -HeadCommit $planBaseCommit -Goal 'Try X' -SuccessCriteria @('Criterion A')
Assert-equal $sealedPlan.late $false 'Get-FoundationReviewInitPlan seals intent at base commit: late'
Assert-equal $sealedPlan.intentComplete $true 'Get-FoundationReviewInitPlan seals intent at base commit: intentComplete'
Assert-equal $sealedPlan.atBase $true 'Get-FoundationReviewInitPlan seals intent at base commit: atBase'

$draftPlan = Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit $planBaseCommit -HeadCommit $planBaseCommit
Assert-equal $draftPlan.late $true 'Get-FoundationReviewInitPlan drafts when intent is omitted: late'
Assert-equal $draftPlan.intentComplete $false 'Get-FoundationReviewInitPlan drafts when intent is omitted: intentComplete'

try {
    Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit $planBaseCommit -HeadCommit $planOtherCommit | Out-Null
    throw 'Get-FoundationReviewInitPlan refuses a late head without AllowLateIntent expected an error.'
} catch {
    if ($_.Exception.Message -notmatch [regex]::Escape('-AllowLateIntent')) {
        throw "Get-FoundationReviewInitPlan refuses a late head without AllowLateIntent: message did not mention -AllowLateIntent: $($_.Exception.Message)"
    }
}

$latePlan = Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit $planBaseCommit -HeadCommit $planOtherCommit -Goal 'Try X' -SuccessCriteria @('Criterion A') -AllowLateIntent
Assert-equal $latePlan.late $true 'Get-FoundationReviewInitPlan marks a late head as late'

Assert-Throws { Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit $planBaseCommit -HeadCommit $planBaseCommit -Goal 'Try X' } 'Get-FoundationReviewInitPlan refuses a half-supplied intent (goal only)'
Assert-Throws { Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit $planBaseCommit -HeadCommit $planBaseCommit -SuccessCriteria @('Criterion A') } 'Get-FoundationReviewInitPlan refuses a half-supplied intent (successCriteria only)'

Assert-Throws { Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit '' -HeadCommit $planBaseCommit } 'Get-FoundationReviewInitPlan refuses an unresolved base commit'

$nestedAtBase = @(
    [ordered]@{
        relativePath = 'example-player'
        headCommit = $planBaseCommit
        baseCommit = $planBaseCommit
    }
)
$nestedSealedPlan = Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit $planBaseCommit -HeadCommit $planBaseCommit -Goal 'Try X' -SuccessCriteria @('Criterion A') -NestedRepositories $nestedAtBase
Assert-equal $nestedSealedPlan.late $false 'Get-FoundationReviewInitPlan seals intent with nested at base: late'
Assert-equal $nestedSealedPlan.atBase $true 'Get-FoundationReviewInitPlan seals intent with nested at base: atBase'

$nestedMoved = @(
    [ordered]@{
        relativePath = 'example-player'
        headCommit = $planOtherCommit
        baseCommit = $planBaseCommit
    }
)
try {
    Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit $planBaseCommit -HeadCommit $planBaseCommit -NestedRepositories $nestedMoved | Out-Null
    throw 'Get-FoundationReviewInitPlan refuses a moved nested head without AllowLateIntent expected an error.'
} catch {
    if ($_.Exception.Message -notmatch [regex]::Escape('example-player')) {
        throw "Get-FoundationReviewInitPlan refuses a moved nested head without AllowLateIntent: message did not mention example-player: $($_.Exception.Message)"
    }
    if ($_.Exception.Message -notmatch [regex]::Escape('-AllowLateIntent')) {
        throw "Get-FoundationReviewInitPlan refuses a moved nested head without AllowLateIntent: message did not mention -AllowLateIntent: $($_.Exception.Message)"
    }
}

$nestedLatePlan = Get-FoundationReviewInitPlan -Release 'release-15' -Generation 6 -BaseCommit $planBaseCommit -HeadCommit $planBaseCommit -Goal 'Try X' -SuccessCriteria @('Criterion A') -NestedRepositories $nestedMoved -AllowLateIntent
Assert-equal $nestedLatePlan.late $true 'Get-FoundationReviewInitPlan marks a moved nested head as late'
Assert-equal $nestedLatePlan.atBase $false 'Get-FoundationReviewInitPlan marks a moved nested head as not atBase'

# --- New-FoundationReviewRecordFile ---

$temporaryFileRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-review-file-' + [Guid]::NewGuid().ToString('N'))
try {
    $filePath = Join-Path $temporaryFileRoot 'release-16.json'
    $recordToWrite = New-FoundationReviewRecordSkeleton -Release 'release-16' -Generation 7 -BaseCommit ('2' * 40) -Late $true
    $writtenPath = New-FoundationReviewRecordFile -Path $filePath -Record $recordToWrite
    $firstHash = (Get-FileHash -LiteralPath $writtenPath).Hash

    try {
        New-FoundationReviewRecordFile -Path $filePath -Record $recordToWrite | Out-Null
        throw 'New-FoundationReviewRecordFile refuses to overwrite expected an error.'
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape('already exists')) {
            throw "New-FoundationReviewRecordFile refuses to overwrite: message did not mention 'already exists': $($_.Exception.Message)"
        }
    }
    $secondHash = (Get-FileHash -LiteralPath $writtenPath).Hash
    Assert-equal $secondHash $firstHash 'New-FoundationReviewRecordFile refuses to overwrite: first write unchanged'

    $writtenBytes = [System.IO.File]::ReadAllBytes($writtenPath)
    $hasBom = ($writtenBytes.Length -ge 3 -and $writtenBytes[0] -eq 0xEF -and $writtenBytes[1] -eq 0xBB -and $writtenBytes[2] -eq 0xBF)
    Assert-equal $hasBom $false 'New-FoundationReviewRecordFile writes UTF-8 without BOM'
} finally {
    if (Test-Path -LiteralPath $temporaryFileRoot) { Remove-Item -LiteralPath $temporaryFileRoot -Recurse -Force }
}

# --- Resolve-FoundationReleaseBaseCommit ---

$fixtureStateForBaseCommit = [ordered]@{
    transitionHistory = @(
        [ordered]@{ action = 'seed'; release = 'release-20'; commit = ('3' * 40) },
        [ordered]@{ action = 'promote'; from = 'release-19'; to = 'release-20'; commit = ('3' * 40) },
        [ordered]@{ action = 'seed'; release = 'release-20'; commit = ('4' * 40) }
    )
}
$resolvedBaseCommit = Resolve-FoundationReleaseBaseCommit -State $fixtureStateForBaseCommit -ReleaseName 'release-20'
Assert-equal $resolvedBaseCommit ('4' * 40) 'Resolve-FoundationReleaseBaseCommit picks the last matching seed'

# --- Format-FoundationReviewText ---

$formatRecord = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$formatDiff = [ordered]@{
    baseCommit = $formatRecord.baseCommit
    headCommit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    totals = [ordered]@{ commits = 1; filesChanged = 1; insertions = 5; deletions = 1 }
    areaSummary = [ordered]@{
        'llm-config' = [ordered]@{ files = 1; insertions = 5; deletions = 1 }
        'control-plane' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
        'docs' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
        'other' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
    }
    commits = @([ordered]@{ commit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; at = '2026-01-02T00:00:00+00:00'; subject = 'Try X' })
    files = @([ordered]@{ status = 'M'; path = '.cursor/rules/foundation.mdc'; oldPath = $null; area = 'llm-config'; insertions = 5; deletions = 1 })
}
$formatGate = Test-FoundationReviewGate -Record $formatRecord -CurrentCommit $formatDiff.headCommit
$formattedText = Format-FoundationReviewText -Record $formatRecord -Diff $formatDiff -Gate $formatGate -RecordPath 'C:\example\release-11.json'
$formattedLines = @($formattedText -split [Environment]::NewLine)
foreach ($sectionHeading in @('## intent', '## success criteria', '## diff summary', '## verdict')) {
    if (@($formattedLines | Where-Object { $_ -eq $sectionHeading }).Count -lt 1) {
        throw "Format-FoundationReviewText contains the four sections: missing line '$sectionHeading'."
    }
}
if ($formattedText -notmatch 'reviewedRepositories') {
    throw "Format-FoundationReviewText how-to-fill mentions reviewedRepositories."
}
if ($formattedText -match 'candidate-side') {
    throw "Format-FoundationReviewText must not mention candidate-side."
}
if ($formattedText -match 'candidate 側') {
    throw "Format-FoundationReviewText must not mention candidate 側."
}
if ($formattedText -notmatch 'REVIEW-CRITERIA') {
    throw "Format-FoundationReviewText how-to-fill mentions REVIEW-CRITERIA."
}
if ($formattedText -notmatch 'calibration') {
    throw "Format-FoundationReviewText how-to-fill mentions calibration."
}

$nestedHeadFull = 'cccccccccccccccccccccccccccccccccccccccc'
$nestedFormatDiff = [ordered]@{
    baseCommit = $formatRecord.baseCommit
    headCommit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    nestedRepositories = @(
        [ordered]@{ relativePath = 'example-player'; origin = 'git@example.com:player.git'; headCommit = $nestedHeadFull; branch = 'develop'; dirty = $false }
    )
    totals = [ordered]@{ commits = 1; filesChanged = 1; insertions = 3; deletions = 0 }
    areaSummary = [ordered]@{
        'llm-config' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
        'control-plane' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
        'docs' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
        'other' = [ordered]@{ files = 1; insertions = 3; deletions = 0 }
    }
    commits = @(
        [ordered]@{ commit = $nestedHeadFull; at = '2026-01-02T00:00:00+00:00'; subject = 'Child-only change'; repo = 'example-player' }
    )
    files = @(
        [ordered]@{ status = 'M'; path = 'src/lib.rs'; oldPath = $null; area = 'other'; insertions = 3; deletions = 0; repo = 'example-player' }
    )
}
$nestedFormatGate = Test-FoundationReviewGate -Record $formatRecord -CurrentCommit $nestedFormatDiff.headCommit -CurrentRepositories @($nestedFormatDiff.nestedRepositories)
$nestedFormattedText = Format-FoundationReviewText -Record $formatRecord -Diff $nestedFormatDiff -Gate $nestedFormatGate -RecordPath 'C:\example\release-11.json'
$nestedFormattedLines = @($nestedFormattedText -split [Environment]::NewLine)
if (@($nestedFormattedLines | Where-Object { $_ -eq 'nested:' }).Count -lt 1) {
    throw "Format-FoundationReviewText with nestedRepositories emits a nested: heading."
}
if (@($nestedFormattedLines | Where-Object { $_ -eq "  example-player $nestedHeadFull" }).Count -lt 1) {
    throw "Format-FoundationReviewText emits full nested headCommit sha."
}
if (@($nestedFormattedLines | Where-Object { $_ -eq 'totals: commits=1 files=1 +3 -0' }).Count -lt 1) {
    throw "Format-FoundationReviewText nested-only fixture shows non-zero totals."
}
if (@($nestedFormattedLines | Where-Object { $_ -eq '  ccccccc example-player 2026-01-02T00:00:00+00:00 Child-only change' }).Count -lt 1) {
    throw "Format-FoundationReviewText prefixes nested commit lines with repo."
}
if (@($nestedFormattedLines | Where-Object { $_ -eq '  M [other] example-player/src/lib.rs +3 -0' }).Count -lt 1) {
    throw "Format-FoundationReviewText prefixes nested file paths with repo."
}
if ($nestedFormattedText -notmatch 'reviewedRepositories') {
    throw "Format-FoundationReviewText how-to-fill mentions reviewedRepositories (nested fixture)."
}
if ($nestedFormattedText -match 'candidate-side') {
    throw "Format-FoundationReviewText must not mention candidate-side (nested fixture)."
}
if ($nestedFormattedText -match 'candidate 側') {
    throw "Format-FoundationReviewText must not mention candidate 側 (nested fixture)."
}
if ($nestedFormattedText -notmatch 'REVIEW-CRITERIA') {
    throw "Format-FoundationReviewText how-to-fill mentions REVIEW-CRITERIA (nested fixture)."
}
if ($nestedFormattedText -notmatch 'calibration') {
    throw "Format-FoundationReviewText how-to-fill mentions calibration (nested fixture)."
}

$draftForFormat = New-FoundationReviewRecordSkeleton -Release 'release-17' -Generation 8 -BaseCommit ('5' * 40) -Late $true
$emptyAreaSummary = [ordered]@{
    'llm-config' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
    'control-plane' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
    'docs' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
    'other' = [ordered]@{ files = 0; insertions = 0; deletions = 0 }
}
$draftDiff = [ordered]@{
    baseCommit = $draftForFormat.baseCommit
    headCommit = ('5' * 40)
    totals = [ordered]@{ commits = 0; filesChanged = 0; insertions = 0; deletions = 0 }
    areaSummary = $emptyAreaSummary
    commits = @()
    files = @()
}
$draftGate = Test-FoundationReviewGate -Record $draftForFormat -CurrentCommit $draftDiff.headCommit
$draftFormattedText = Format-FoundationReviewText -Record $draftForFormat -Diff $draftDiff -Gate $draftGate -RecordPath 'C:\example\draft.json'
if ($draftFormattedText -notmatch [regex]::Escape('(not recorded yet)')) {
    throw "Format-FoundationReviewText renders a draft: expected '(not recorded yet)' in output."
}
$draftFormattedLines = @($draftFormattedText -split [Environment]::NewLine)
foreach ($sectionHeading in @('## intent', '## success criteria', '## diff summary', '## verdict')) {
    if (@($draftFormattedLines | Where-Object { $_ -eq $sectionHeading }).Count -lt 1) {
        throw "Format-FoundationReviewText without nestedRepositories still emits four sections: missing '$sectionHeading'."
    }
}
if (@($draftFormattedLines | Where-Object { $_ -eq 'nested:' }).Count -ne 0) {
    throw "Format-FoundationReviewText without nestedRepositories must not emit nested:."
}

# --- wrapper/config/release-review.example.json passes -RequireIntentComplete ---

$exampleRecordPath = Join-Path $PSScriptRoot 'config\release-review.example.json'
$exampleRecord = Get-Content -Raw -LiteralPath $exampleRecordPath | ConvertFrom-Json
Assert-FoundationReviewRecordShape -Record $exampleRecord -Context 'wrapper/config/release-review.example.json passes -RequireIntentComplete' -RequireIntentComplete

# --- New-FoundationReviewRecordFile refuses a relative path ---

$relativeGuardScratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-review-relguard-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $relativeGuardScratchRoot | Out-Null
Push-Location $relativeGuardScratchRoot
try {
    $relativeGuardRecord = New-FoundationReviewRecordSkeleton -Release 'release-18' -Generation 9 -BaseCommit ('6' * 40) -Late $true
    try {
        New-FoundationReviewRecordFile -Path 'relative-test.json' -Record $relativeGuardRecord | Out-Null
        throw 'New-FoundationReviewRecordFile refuses a relative path expected an error.'
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape('must be an absolute path')) {
            throw "New-FoundationReviewRecordFile refuses a relative path: message did not mention 'must be an absolute path': $($_.Exception.Message)"
        }
    }
} finally {
    Pop-Location
    if (Test-Path -LiteralPath $relativeGuardScratchRoot) { Remove-Item -LiteralPath $relativeGuardScratchRoot -Recurse -Force }
}

# --- Read-FoundationReviewRecord rejects empty / literal-null content ---

$emptyContentRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-review-emptycontent-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $emptyContentRoot | Out-Null
try {
    $emptyFilePath = Join-Path $emptyContentRoot 'empty.json'
    [System.IO.File]::WriteAllBytes($emptyFilePath, [byte[]]@())
    try {
        Read-FoundationReviewRecord -Path $emptyFilePath | Out-Null
        throw 'Read-FoundationReviewRecord rejects an empty file expected an error.'
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape('is empty')) {
            throw "Read-FoundationReviewRecord rejects an empty file: message did not mention 'is empty': $($_.Exception.Message)"
        }
    }

    $nullFilePath = Join-Path $emptyContentRoot 'null.json'
    'null' | Set-Content -LiteralPath $nullFilePath -Encoding utf8 -NoNewline
    try {
        Read-FoundationReviewRecord -Path $nullFilePath | Out-Null
        throw 'Read-FoundationReviewRecord rejects a file containing literal null expected an error.'
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape('parsed to null')) {
            throw "Read-FoundationReviewRecord rejects a file containing literal null: message did not mention 'parsed to null': $($_.Exception.Message)"
        }
    }
} finally {
    Remove-Item -LiteralPath $emptyContentRoot -Recurse -Force
}

# --- Get-FoundationIdentityLeakNeedles / Test-FoundationIdentityLeakLine ---

$fixtureConfigForLeak = @{
    instances = @{
        stable = @{
            wslUser = 'fixture-user'
            wslHome = '/home/fixture-user'
            releasesRoot = '/home/fixture-user/releases'
        }
    }
    storage = @{ localDataRoot = 'D:\fixture-local-data' }
}

$leakNeedles = @(Get-FoundationIdentityLeakNeedles -Configuration $fixtureConfigForLeak)
if ($leakNeedles -notcontains 'fixture-user') {
    throw "Get-FoundationIdentityLeakNeedles includes fixture-user: missing from $($leakNeedles -join ', ')"
}
if ($leakNeedles -notcontains '/home/fixture-user') {
    throw "Get-FoundationIdentityLeakNeedles includes /home/fixture-user: missing from $($leakNeedles -join ', ')"
}
if ($leakNeedles -notcontains 'D:\fixture-local-data') {
    throw "Get-FoundationIdentityLeakNeedles includes D:\fixture-local-data: missing from $($leakNeedles -join ', ')"
}
if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
    if ($leakNeedles -notcontains $env:USERNAME) {
        throw "Get-FoundationIdentityLeakNeedles includes `$env:USERNAME when set: missing from $($leakNeedles -join ', ')"
    }
}

$hitNeedle = Test-FoundationIdentityLeakLine -Line 'owned by fixture-user on disk' -Needles $leakNeedles
Assert-equal $hitNeedle 'fixture-user' 'Test-FoundationIdentityLeakLine hit returns the first matching needle'

$missNeedle = Test-FoundationIdentityLeakLine -Line 'no forbidden identity tokens here' -Needles $leakNeedles
Assert-equal $missNeedle $null 'Test-FoundationIdentityLeakLine miss returns null'

$caseNeedle = Test-FoundationIdentityLeakLine -Line 'FIXTURE-USER in uppercase' -Needles $leakNeedles
Assert-equal $caseNeedle 'fixture-user' 'Test-FoundationIdentityLeakLine matches case-insensitively'

# --- Merge-FoundationReviewBlock / Set-FoundationReviewRecordFile ---

function New-ValidReviewBlock {
    return [ordered]@{
        reviewedAt = '2026-01-02T00:00:00+00:00'
        correctness = 'pass'
        procedure = 'good'
        criteriaResults = @(
            [ordered]@{ criterion = 'No Y errors in a 30 minute session.'; result = 'met'; evidence = 'Ran for 45 minutes, no Y errors.' }
        )
        observedEffects = @('Fewer Y errors.')
        procedureChecks = [ordered]@{
            minimalChange = 'yes'
            verifiedBeforeProceeding = 'yes'
            rollbackPreserved = 'yes'
            stableIsolationUsed = 'yes'
        }
        betterProcedure = 'none'
        verdict = 'accepted'
    }
}

function New-NullReviewRecord {
    $record = New-ValidReviewRecord
    $record.review = $null
    return ConvertTo-ReviewRecordObject -Record $record
}

$mergeLiveCommit = 'dddddddddddddddddddddddddddddddddddddddd'
$mergeBlock = ConvertTo-ReviewRecordObject -Record (New-ValidReviewBlock)
$nullReviewInput = New-NullReviewRecord
$intentGoalBefore = [string]$nullReviewInput.intent.goal
$lateBefore = [bool]$nullReviewInput.late

$mergedFresh = Merge-FoundationReviewBlock -Record $nullReviewInput -Block $mergeBlock -CurrentCommit $mergeLiveCommit
Assert-equal ([string]$mergedFresh.review.reviewedCommit) $mergeLiveCommit 'Merge-FoundationReviewBlock pins reviewedCommit to CurrentCommit'
Assert-equal ([string]$mergedFresh.intent.goal) $intentGoalBefore 'Merge-FoundationReviewBlock leaves intent.goal unchanged'
Assert-equal ([bool]$mergedFresh.late) $lateBefore 'Merge-FoundationReviewBlock leaves late unchanged'
Assert-equal ($null -eq $nullReviewInput.review) $true 'Merge-FoundationReviewBlock does not mutate input review when null'
Assert-FoundationReviewRecordShape -Record $mergedFresh -Context 'merged fresh review record'

$staleBlockHashtable = New-ValidReviewBlock
$staleBlockHashtable['reviewedCommit'] = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
$staleBlockHashtable['reviewedRepositories'] = @(
    [ordered]@{ relativePath = 'stale-child'; headCommit = ('f' * 40) }
)
$staleBlock = ConvertTo-ReviewRecordObject -Record $staleBlockHashtable
$liveNestedHead = 'cccccccccccccccccccccccccccccccccccccccc'
$liveNested = @(
    [ordered]@{ relativePath = 'example-player'; headCommit = $liveNestedHead; origin = 'git@example.com:player.git'; branch = 'develop'; dirty = $true; baseCommit = ('a' * 40) }
)
$mergedLiveWins = Merge-FoundationReviewBlock -Record (New-NullReviewRecord) -Block $staleBlock -CurrentCommit $mergeLiveCommit -CurrentRepositories $liveNested
Assert-equal ([string]$mergedLiveWins.review.reviewedCommit) $mergeLiveCommit 'Merge-FoundationReviewBlock prefers live CurrentCommit over block reviewedCommit'
Assert-equal (@($mergedLiveWins.review.reviewedRepositories).Count) 1 'Merge-FoundationReviewBlock fills reviewedRepositories from live CurrentRepositories'
Assert-equal ([string]$mergedLiveWins.review.reviewedRepositories[0].relativePath) 'example-player' 'Merge-FoundationReviewBlock uses live nested relativePath'
Assert-equal ([string]$mergedLiveWins.review.reviewedRepositories[0].headCommit) $liveNestedHead 'Merge-FoundationReviewBlock uses live nested headCommit'
$nestedRepoProps = @($mergedLiveWins.review.reviewedRepositories[0].PSObject.Properties.Name)
if ($nestedRepoProps -contains 'origin' -or $nestedRepoProps -contains 'branch' -or $nestedRepoProps -contains 'dirty' -or $nestedRepoProps -contains 'baseCommit') {
    throw 'Merge-FoundationReviewBlock reviewedRepositories keeps only relativePath and headCommit'
}
$nestedGate = Test-FoundationReviewGate -Record $mergedLiveWins -CurrentCommit $mergeLiveCommit -CurrentRepositories $liveNested
Assert-equal $nestedGate.reviewedCommitMatches $true 'Merge-FoundationReviewBlock nested fill can satisfy reviewedCommitMatches'

$alreadyReviewed = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
$reviewBeforeThrow = $alreadyReviewed.review
try {
    Merge-FoundationReviewBlock -Record $alreadyReviewed -Block $mergeBlock -CurrentCommit $mergeLiveCommit | Out-Null
    throw 'Merge-FoundationReviewBlock refuses existing review when Force is omitted expected an error.'
} catch {
    if ($_.Exception.Message -notmatch [regex]::Escape('-Force')) {
        throw "Merge-FoundationReviewBlock refuses existing review when Force is omitted: message did not mention -Force: $($_.Exception.Message)"
    }
}
Assert-equal ($alreadyReviewed.review -eq $reviewBeforeThrow) $true 'Merge-FoundationReviewBlock without -Force does not mutate input review'

try {
    Merge-FoundationReviewBlock -Record $alreadyReviewed -Block $mergeBlock -CurrentCommit $mergeLiveCommit -Force:$false | Out-Null
    throw 'Merge-FoundationReviewBlock refuses existing review when Force is false expected an error.'
} catch {
    if ($_.Exception.Message -notmatch [regex]::Escape('-Force')) {
        throw "Merge-FoundationReviewBlock refuses existing review when Force is false: message did not mention -Force: $($_.Exception.Message)"
    }
}
Assert-equal ([string]$alreadyReviewed.review.reviewedCommit) 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'Merge-FoundationReviewBlock -Force:$false does not mutate input review'

$forceMerged = Merge-FoundationReviewBlock -Record $alreadyReviewed -Block $mergeBlock -CurrentCommit $mergeLiveCommit -Force
Assert-equal ([string]$forceMerged.review.reviewedCommit) $mergeLiveCommit 'Merge-FoundationReviewBlock -Force replaces reviewedCommit'
Assert-equal ([string]$forceMerged.intent.goal) ([string]$alreadyReviewed.intent.goal) 'Merge-FoundationReviewBlock -Force leaves intent unchanged'
Assert-equal ([string]$alreadyReviewed.review.reviewedCommit) 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'Merge-FoundationReviewBlock -Force does not mutate input Record'

$badVerdictBlockHashtable = New-ValidReviewBlock
$badVerdictBlockHashtable['verdict'] = 'maybe'
$badVerdictBlock = ConvertTo-ReviewRecordObject -Record $badVerdictBlockHashtable
Assert-Throws { Merge-FoundationReviewBlock -Record (New-NullReviewRecord) -Block $badVerdictBlock -CurrentCommit $mergeLiveCommit } 'Merge-FoundationReviewBlock rejects verdict outside enum'

$mergeFileRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('foundation-review-merge-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $mergeFileRoot | Out-Null
try {
    $mergeFilePath = Join-Path $mergeFileRoot 'record.json'
    $onDisk = New-NullReviewRecord
    $writtenMergePath = New-FoundationReviewRecordFile -Path $mergeFilePath -Record $onDisk
    $hashBeforeRefuse = (Get-FileHash -LiteralPath $writtenMergePath).Hash

    $existingOnDisk = ConvertTo-ReviewRecordObject -Record (New-ValidReviewRecord)
    Set-FoundationReviewRecordFile -Path $writtenMergePath -Record $existingOnDisk | Out-Null
    $hashWithReview = (Get-FileHash -LiteralPath $writtenMergePath).Hash

    try {
        Merge-FoundationReviewBlock -Record (Read-FoundationReviewRecord -Path $writtenMergePath) -Block $mergeBlock -CurrentCommit $mergeLiveCommit | Out-Null
        throw 'Merge-FoundationReviewBlock refuses existing review on disk when Force is omitted expected an error.'
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape('-Force')) {
            throw "Merge-FoundationReviewBlock refuses existing review on disk when Force is omitted: message did not mention -Force: $($_.Exception.Message)"
        }
    }
    Assert-equal (Get-FileHash -LiteralPath $writtenMergePath).Hash $hashWithReview 'Merge-FoundationReviewBlock throw leaves file hash unchanged'

    try {
        Merge-FoundationReviewBlock -Record (Read-FoundationReviewRecord -Path $writtenMergePath) -Block $badVerdictBlock -CurrentCommit $mergeLiveCommit -Force | Out-Null
        throw 'Merge-FoundationReviewBlock shape failure on invalid enum expected an error.'
    } catch {
        if ($_.Exception.Message -notmatch 'verdict') {
            throw "Merge-FoundationReviewBlock rejects bad verdict before write: $($_.Exception.Message)"
        }
    }
    Assert-equal (Get-FileHash -LiteralPath $writtenMergePath).Hash $hashWithReview 'Merge-FoundationReviewBlock shape failure leaves file hash unchanged'

    $setBytes = [System.IO.File]::ReadAllBytes($writtenMergePath)
    $setHasBom = ($setBytes.Length -ge 3 -and $setBytes[0] -eq 0xEF -and $setBytes[1] -eq 0xBB -and $setBytes[2] -eq 0xBF)
    Assert-equal $setHasBom $false 'Set-FoundationReviewRecordFile writes UTF-8 without BOM'

    $missingSetPath = Join-Path $mergeFileRoot 'missing.json'
    try {
        Set-FoundationReviewRecordFile -Path $missingSetPath -Record $mergedFresh | Out-Null
        throw 'Set-FoundationReviewRecordFile refuses a missing file expected an error.'
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape('review-init')) {
            throw "Set-FoundationReviewRecordFile refuses a missing file: message did not mention review-init: $($_.Exception.Message)"
        }
    }

    Push-Location $mergeFileRoot
    try {
        try {
            Set-FoundationReviewRecordFile -Path 'relative-set.json' -Record $mergedFresh | Out-Null
            throw 'Set-FoundationReviewRecordFile refuses a relative path expected an error.'
        } catch {
            if ($_.Exception.Message -notmatch [regex]::Escape('must be an absolute path')) {
                throw "Set-FoundationReviewRecordFile refuses a relative path: message did not mention 'must be an absolute path': $($_.Exception.Message)"
            }
        }
    } finally {
        Pop-Location
    }

    # Path-omission equivalent: Merge throw after a write leaves the prior hash.
    Assert-equal $hashWithReview (Get-FileHash -LiteralPath $writtenMergePath).Hash 'review write path omission equivalent: hash unchanged after refused merge'
    Assert-equal ($hashBeforeRefuse -ne $hashWithReview) $true 'Set-FoundationReviewRecordFile changes hash when writing a review'
} finally {
    if (Test-Path -LiteralPath $mergeFileRoot) { Remove-Item -LiteralPath $mergeFileRoot -Recurse -Force }
}

Write-Output 'PASS: Test-ReleaseReview.ps1'
