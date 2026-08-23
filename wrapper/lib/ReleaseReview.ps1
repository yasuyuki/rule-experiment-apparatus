$ErrorActionPreference = 'Stop'

# Get-JsonProperty / Get-OptionalJsonProperty / Assert-SupportedSchemaVersion /
# Resolve-ReviewRoot live in Configuration.ps1. Sourcing it here makes this
# file self-contained wherever it is dot-sourced directly (e.g.
# Test-ReleaseReview.ps1), mirroring how Configuration.ps1 sources
# ReleaseState.ps1 at its own end.
. (Join-Path $PSScriptRoot 'Configuration.ps1')

# Pure classification of a release diff path into a coarse change area, used by
# Get-FoundationReleaseDiff.ps1 to summarize what kind of files a release
# touched. First matching rule wins: `.claude/agents/designer.md` is
# `llm-config`, not `docs`, even though it also ends in `.md`.
function Get-FoundationChangeArea {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    $normalized = $Path.Replace('\', '/')
    if ($normalized.StartsWith('.cursor/')) { return 'llm-config' }
    if ($normalized.StartsWith('.claude/')) { return 'llm-config' }
    if ($normalized -eq 'AGENTS.md' -or $normalized.EndsWith('/AGENTS.md') -or
        $normalized -eq 'CLAUDE.md' -or $normalized.EndsWith('/CLAUDE.md')) {
        return 'llm-config'
    }
    if ($normalized.StartsWith('wrapper/')) { return 'control-plane' }
    if ($normalized.StartsWith('docs/') -or $normalized.EndsWith('.md')) { return 'docs' }
    return 'other'
}

# Build the identity-leak needle list from the live environment and config.
# Callers must not hardcode real usernames or home paths; this is the only
# place those strings are assembled for scanning.
function Get-FoundationIdentityLeakNeedles {
    param(
        [Parameter(Mandatory)] [object]$Configuration
    )

    $needles = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $addNeedle = {
        param([AllowNull()] [AllowEmptyString()] [string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return }
        if (-not $seen.Add($Value)) { return }
        $needles.Add($Value) | Out-Null
    }

    $username = $env:USERNAME
    & $addNeedle $username

    $instances = Get-OptionalJsonProperty -Object $Configuration -Name 'instances'
    if ($null -ne $instances) {
        foreach ($instanceName in @('stable', 'candidate')) {
            if ($instances -is [System.Collections.IDictionary]) {
                if (-not $instances.Contains($instanceName)) { continue }
                $instance = $instances[$instanceName]
            } else {
                $property = $instances.PSObject.Properties[$instanceName]
                if ($null -eq $property) { continue }
                $instance = $property.Value
            }
            if ($null -eq $instance) { continue }

            foreach ($fieldName in @('wslUser', 'wslHome', 'releasesRoot')) {
                $raw = Get-OptionalJsonProperty -Object $instance -Name $fieldName
                if ($null -eq $raw) { continue }
                & $addNeedle ([string]$raw)
            }
        }
    }

    $storage = Get-OptionalJsonProperty -Object $Configuration -Name 'storage'
    if ($null -ne $storage) {
        $localDataRoot = Get-OptionalJsonProperty -Object $storage -Name 'localDataRoot'
        if ($null -ne $localDataRoot) {
            & $addNeedle ([string]$localDataRoot)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($username)) {
        $windowsHome = 'C:\Users\' + $username
        & $addNeedle $windowsHome
        & $addNeedle ($windowsHome.Replace('\', '/'))
    }

    return [string[]]@($needles.ToArray())
}

function Test-FoundationIdentityLeakLine {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Line,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Needles
    )

    foreach ($needle in @($Needles)) {
        if ([string]::IsNullOrEmpty($needle)) { continue }
        if ($Line.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $needle
        }
    }
    return $null
}

# See schemas/release-review.schema.json for the record shape and
# docs/REVIEW-CRITERIA.md for judgment semantics. schemaVersion 1 only;
# there is no migration path yet.
$script:FoundationReviewCorrectnessValues = @('pass', 'partial', 'fail')
$script:FoundationReviewProcedureValues = @('good', 'acceptable', 'needs-improvement')
$script:FoundationReviewCriterionResultValues = @('met', 'unmet', 'unknown')
$script:FoundationReviewProcedureCheckValues = @('yes', 'no', 'na')
$script:FoundationReviewProcedureCheckKeys = @('minimalChange', 'verifiedBeforeProceeding', 'rollbackPreserved', 'stableIsolationUsed')
$script:FoundationReviewVerdictValues = @('accepted', 'needs-work', 'rejected')

# schemas/release-review.schema.json is the authority for the static record
# shape. The helpers below interpret its static keywords (type / const / enum /
# pattern / minLength / minItems / required / properties / additionalProperties /
# $ref / anyOf) with plain ConvertFrom-Json — no JSON Schema library. The
# allOf/if/then blocks encode intent-completeness conditions that stay
# hand-written in Assert-FoundationReviewRecordShape, as does every other
# cross-field semantic check JSON Schema cannot express. New schema keywords
# are rejected at load time until the interpreter explicitly supports them.
$script:CachedFoundationReviewSchema = $null
$script:FoundationReviewSchemaKeywords = @(
    '$schema', '$id', 'title', 'comment', 'type', 'const', 'enum', 'pattern',
    'minLength', 'minItems', 'required', 'properties', 'additionalProperties',
    '$ref', '$defs', 'anyOf', 'allOf', 'if', 'then', 'items'
)

function Assert-FoundationReviewSchemaSupported {
    param(
        [Parameter(Mandatory)] [object]$Schema,
        [Parameter(Mandatory)] [string]$Context
    )

    if ($Schema -isnot [pscustomobject]) {
        throw "$Context must be a JSON Schema object."
    }

    foreach ($property in $Schema.PSObject.Properties) {
        $name = [string]$property.Name
        if ($script:FoundationReviewSchemaKeywords -cnotcontains $name) {
            throw "$Context uses unsupported schema keyword '$name'."
        }

        switch ($name) {
            'properties' {
                if ($property.Value -isnot [pscustomobject]) { throw "$Context.properties must be an object." }
                foreach ($child in $property.Value.PSObject.Properties) {
                    Assert-FoundationReviewSchemaSupported -Schema $child.Value -Context "$Context.properties.$($child.Name)"
                }
            }
            '$defs' {
                if ($property.Value -isnot [pscustomobject]) { throw "$Context.`$defs must be an object." }
                foreach ($child in $property.Value.PSObject.Properties) {
                    Assert-FoundationReviewSchemaSupported -Schema $child.Value -Context "$Context.`$defs.$($child.Name)"
                }
            }
            'anyOf' {
                foreach ($child in @($property.Value)) {
                    Assert-FoundationReviewSchemaSupported -Schema $child -Context "$Context.anyOf"
                }
            }
            'allOf' {
                foreach ($child in @($property.Value)) {
                    Assert-FoundationReviewSchemaSupported -Schema $child -Context "$Context.allOf"
                }
            }
            'if' { Assert-FoundationReviewSchemaSupported -Schema $property.Value -Context "$Context.if" }
            'then' { Assert-FoundationReviewSchemaSupported -Schema $property.Value -Context "$Context.then" }
            'items' { Assert-FoundationReviewSchemaSupported -Schema $property.Value -Context "$Context.items" }
        }
    }
}

function Get-FoundationReviewSchema {
    if ($null -eq $script:CachedFoundationReviewSchema) {
        $schemaPath = Join-Path $PSScriptRoot '..\schemas\release-review.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
            throw "Release review schema not found: $schemaPath"
        }
        $schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json
        Assert-FoundationReviewSchemaSupported -Schema $schema -Context 'Release review schema'
        $script:CachedFoundationReviewSchema = $schema
    }
    return $script:CachedFoundationReviewSchema
}

function Resolve-FoundationSchemaRef {
    param(
        [Parameter(Mandatory)] [object]$Root,
        [Parameter(Mandatory)] [object]$Node
    )

    $refProperty = $Node.PSObject.Properties['$ref']
    if ($null -eq $refProperty) { return $Node }
    $current = $Root
    foreach ($segment in ([string]$refProperty.Value).TrimStart('#').Split('/') | Where-Object { $_ }) {
        $segment = $segment.Replace('~1', '/').Replace('~0', '~')
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            throw "Release review schema ref '$($refProperty.Value)' cannot resolve segment '$segment'."
        }
        $current = $property.Value
    }
    return $current
}

function Test-FoundationSchemaType {
    param(
        [Parameter(Mandatory)] [AllowNull()] [object]$Value,
        [Parameter(Mandatory)] [string[]]$Types
    )

    foreach ($type in $Types) {
        $typeMatches = switch ($type) {
            'object'  { $Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject] }
            'array'   { $Value -is [System.Collections.IList] }
            'string'  { $Value -is [string] -or $Value -is [datetime] -or $Value -is [datetimeoffset] }
            'integer' { $Value -is [int] -or $Value -is [long] -or $Value -is [byte] -or ($Value -is [double] -and ([math]::Floor($Value) -eq $Value)) }
            'number'  { $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] }
            'boolean' { $Value -is [bool] }
            'null'    { $null -eq $Value }
            default   { throw "Unsupported release review schema type '$type'." }
        }
        if ($typeMatches) { return $true }
    }
    return $false
}

# Returns $null when $Value satisfies the static keywords of $Node (resolving
# $ref against $Root), otherwise a human-readable error including $Path.
# Enum and pattern matching are case-sensitive, matching JSON Schema semantics.
function Get-FoundationSchemaShapeError {
    param(
        [Parameter(Mandatory)] [object]$Root,
        [Parameter(Mandatory)] [object]$Node,
        [Parameter(Mandatory)] [AllowNull()] [object]$Value,
        [Parameter(Mandatory)] [string]$Path
    )

    $node = Resolve-FoundationSchemaRef -Root $Root -Node $Node

    $allOfProperty = $node.PSObject.Properties['allOf']
    if ($null -ne $allOfProperty) {
        foreach ($branch in @($allOfProperty.Value)) {
            $branchError = Get-FoundationSchemaShapeError -Root $Root -Node $branch -Value $Value -Path $Path
            if ($null -ne $branchError) { return $branchError }
        }
    }

    $ifProperty = $node.PSObject.Properties['if']
    $thenProperty = $node.PSObject.Properties['then']
    if ($null -ne $ifProperty -and $null -ne $thenProperty) {
        $conditionError = Get-FoundationSchemaShapeError -Root $Root -Node $ifProperty.Value -Value $Value -Path $Path
        if ($null -eq $conditionError) {
            $thenError = Get-FoundationSchemaShapeError -Root $Root -Node $thenProperty.Value -Value $Value -Path $Path
            if ($null -ne $thenError) { return $thenError }
        }
    }

    $anyOfProperty = $node.PSObject.Properties['anyOf']
    if ($null -ne $anyOfProperty) {
        $firstBranchError = $null
        foreach ($branch in @($anyOfProperty.Value)) {
            $branchError = Get-FoundationSchemaShapeError -Root $Root -Node $branch -Value $Value -Path $Path
            if ($null -eq $branchError) { return $null }
            if ($null -eq $firstBranchError) { $firstBranchError = $branchError }
        }
        return "$Path does not match any allowed variant ($firstBranchError)."
    }

    $typeProperty = $node.PSObject.Properties['type']
    if ($null -ne $typeProperty) {
        $types = [string[]]@($typeProperty.Value)
        if (-not (Test-FoundationSchemaType -Value $Value -Types $types)) {
            $actual = if ($null -eq $Value) { 'null' } else { $Value.GetType().Name }
            return "$Path must be of type $($types -join '/'), got $actual."
        }
    }

    $constProperty = $node.PSObject.Properties['const']
    if ($null -ne $constProperty -and $Value -ne $constProperty.Value) {
        return "$Path must equal $($constProperty.Value), got '$Value'."
    }

    $enumProperty = $node.PSObject.Properties['enum']
    if ($null -ne $enumProperty) {
        $allowed = @($enumProperty.Value)
        $found = $false
        foreach ($candidate in $allowed) {
            if ([string]::Equals([string]$Value, [string]$candidate, [StringComparison]::Ordinal)) { $found = $true; break }
        }
        if (-not $found) {
            return "$Path value '$Value' is not one of: $($allowed -join ', ')."
        }
    }

    if ($Value -is [string]) {
        $patternProperty = $node.PSObject.Properties['pattern']
        if ($null -ne $patternProperty -and $Value -cnotmatch [string]$patternProperty.Value) {
            return "$Path value '$Value' must match $($patternProperty.Value)."
        }
        $minLengthProperty = $node.PSObject.Properties['minLength']
        if ($null -ne $minLengthProperty -and $Value.Length -lt [int]$minLengthProperty.Value) {
            return "$Path must be at least $($minLengthProperty.Value) character(s)."
        }
    }

    if ($Value -is [System.Collections.IList]) {
        $entries = @($Value)
        $minItemsProperty = $node.PSObject.Properties['minItems']
        if ($null -ne $minItemsProperty -and $entries.Count -lt [int]$minItemsProperty.Value) {
            return "$Path must have at least $($minItemsProperty.Value) entr(y/ies)."
        }
        $itemsProperty = $node.PSObject.Properties['items']
        if ($null -ne $itemsProperty) {
            for ($i = 0; $i -lt $entries.Count; $i++) {
                $entryError = Get-FoundationSchemaShapeError -Root $Root -Node $itemsProperty.Value -Value $entries[$i] -Path "$Path[$i]"
                if ($null -ne $entryError) { return $entryError }
            }
        }
    }

    $propertiesProperty = $node.PSObject.Properties['properties']
    $requiredProperty = $node.PSObject.Properties['required']
    $additionalProperty = $node.PSObject.Properties['additionalProperties']
    if ($null -ne $propertiesProperty -or $null -ne $requiredProperty -or $null -ne $additionalProperty) {
        $isObject = $Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]
        if (-not $isObject) { return "$Path must be an object." }

        if ($Value -is [System.Collections.IDictionary]) { $keys = [string[]]@($Value.Keys) } else { $keys = [string[]]@($Value.PSObject.Properties.Name) }

        if ($null -ne $requiredProperty) {
            foreach ($key in [string[]]@($requiredProperty.Value)) {
                if ($keys -cnotcontains $key) { return "$Path is missing required property '$key'." }
            }
        }

        $knownKeys = @()
        if ($null -ne $propertiesProperty) { $knownKeys = [string[]]@($propertiesProperty.Value.PSObject.Properties.Name) }
        if ($null -ne $additionalProperty -and $additionalProperty.Value -eq $false) {
            foreach ($key in $keys) {
                if ($knownKeys -cnotcontains $key) { return "$Path has unknown property '$key'." }
            }
        }

        if ($null -ne $propertiesProperty) {
            foreach ($key in $keys) {
                $childProperty = $propertiesProperty.Value.PSObject.Properties[$key]
                if ($null -eq $childProperty) { continue }
                if ($Value -is [System.Collections.IDictionary]) { $childValue = $Value[$key] } else { $childValue = $Value.PSObject.Properties[$key].Value }
                $childError = Get-FoundationSchemaShapeError -Root $Root -Node $childProperty.Value -Value $childValue -Path "$Path.$key"
                if ($null -ne $childError) { return $childError }
            }
        }
    }

    return $null
}

function Assert-FoundationReviewRecordShape {
    param(
        [Parameter(Mandatory)] [object]$Record,
        [Parameter(Mandatory)] [string]$Context,
        # A record's intent may legitimately be incomplete: a freshly created
        # skeleton (draft state) has goal='' and successCriteria=[]. Intent
        # completeness is only required when the caller asks for it directly
        # (-RequireIntentComplete), or when the record itself has already
        # moved past the draft state: `review` non-null (reviewed) or
        # `late:false` (review-init sealed the intent at the base commit).
        [switch]$RequireIntentComplete
    )

    Assert-SupportedSchemaVersion -Document $Record -SupportedVersion @(1) -DocumentName $Context | Out-Null

    # Static record shape, owned by schemas/release-review.schema.json: missing
    # required keys, unknown keys under additionalProperties:false, primitive
    # types, enums, patterns, and minLength/minItems. The hand-written checks
    # below then cover what the schema cannot express (intent completeness,
    # criteriaResults 1:1, duplicate reviewedRepositories).
    $reviewSchema = Get-FoundationReviewSchema
    $shapeError = Get-FoundationSchemaShapeError -Root $reviewSchema -Node $reviewSchema -Value $Record -Path 'record'
    if ($null -ne $shapeError) { throw "$Context`: $shapeError" }

    $release = [string](Get-JsonProperty -Object $Record -Name 'release' -DocumentName $Context)
    if ($release -notmatch '^[A-Za-z0-9._-]+$') {
        throw "$Context.release '$release' must match ^[A-Za-z0-9._-]+`$."
    }

    $generationValue = Get-JsonProperty -Object $Record -Name 'generation' -DocumentName $Context
    try { [void][int]$generationValue } catch { throw "$Context.generation '$generationValue' must be an integer." }

    $baseCommit = [string](Get-JsonProperty -Object $Record -Name 'baseCommit' -DocumentName $Context)
    if ($baseCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Context.baseCommit must be a 40-character lowercase hex commit id, got '$baseCommit'."
    }

    $lateValue = Get-JsonProperty -Object $Record -Name 'late' -DocumentName $Context
    if ($lateValue -isnot [bool]) { throw "$Context.late must be a boolean." }

    # `review` is a required key whose value is either null (not reviewed yet)
    # or a fully populated review block; there is no partially-filled review
    # shape. Fetched here, ahead of the intent completeness check below,
    # because both `review` being non-null and `late:false` widen intent
    # completeness from optional to required.
    $review = Get-JsonProperty -Object $Record -Name 'review' -DocumentName $Context

    $intent = Get-JsonProperty -Object $Record -Name 'intent' -DocumentName $Context
    $intentContext = "$Context.intent"
    $goal = [string](Get-JsonProperty -Object $intent -Name 'goal' -DocumentName $intentContext)
    $null = @(Get-JsonProperty -Object $intent -Name 'expectedEffects' -DocumentName $intentContext)
    $successCriteria = @(Get-JsonProperty -Object $intent -Name 'successCriteria' -DocumentName $intentContext)
    $null = @(Get-JsonProperty -Object $intent -Name 'nonGoals' -DocumentName $intentContext)

    $mustHaveCompleteIntent = $RequireIntentComplete.IsPresent -or ($null -ne $review) -or ($lateValue -eq $false)
    if ($mustHaveCompleteIntent) {
        if ([string]::IsNullOrWhiteSpace($goal)) { throw "$intentContext.goal is empty." }
        if ($successCriteria.Count -eq 0) { throw "$intentContext.successCriteria must not be empty." }
        for ($i = 0; $i -lt $successCriteria.Count; $i++) {
            if ([string]::IsNullOrWhiteSpace([string]$successCriteria[$i])) {
                throw "$intentContext.successCriteria[$i] is empty."
            }
        }
    }

    if ($null -eq $review) { return }

    $reviewContext = "$Context.review"
    $reviewedAt = [string](Get-JsonProperty -Object $review -Name 'reviewedAt' -DocumentName $reviewContext)
    if ([string]::IsNullOrWhiteSpace($reviewedAt)) { throw "$reviewContext.reviewedAt is empty." }

    $reviewedCommit = [string](Get-JsonProperty -Object $review -Name 'reviewedCommit' -DocumentName $reviewContext)
    if ($reviewedCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw "$reviewContext.reviewedCommit must be a 40-character lowercase hex commit id, got '$reviewedCommit'."
    }

    # Optional additive field (schemaVersion stays 1). Absent on historical records.
    $reviewedRepositoriesValue = Get-OptionalJsonProperty -Object $review -Name 'reviewedRepositories'
    if ($null -ne $reviewedRepositoriesValue) {
        # ConvertFrom-Json collapses a single-element JSON array to one object;
        # @() re-wraps so 0/1/N cases are all enumerable arrays.
        $reviewedRepositories = @($reviewedRepositoriesValue)
        $seenReviewedRepoPaths = @{}
        $reviewedRepoIndex = 0
        foreach ($reviewedRepo in $reviewedRepositories) {
            $reviewedRepoContext = "$reviewContext.reviewedRepositories[$reviewedRepoIndex]"
            $relativePath = [string](Get-JsonProperty -Object $reviewedRepo -Name 'relativePath' -DocumentName $reviewedRepoContext)
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                throw "$reviewedRepoContext.relativePath is empty."
            }
            if ($seenReviewedRepoPaths.ContainsKey($relativePath)) {
                throw "$reviewedRepoContext.relativePath '$relativePath' is duplicated."
            }
            $seenReviewedRepoPaths[$relativePath] = $true
            $nestedHead = [string](Get-JsonProperty -Object $reviewedRepo -Name 'headCommit' -DocumentName $reviewedRepoContext)
            if ($nestedHead -cnotmatch '^[0-9a-f]{40}$') {
                throw "$reviewedRepoContext.headCommit must be a 40-character lowercase hex commit id, got '$nestedHead'."
            }
            $reviewedRepoIndex += 1
        }
    }

    $correctness = [string](Get-JsonProperty -Object $review -Name 'correctness' -DocumentName $reviewContext)
    if ($script:FoundationReviewCorrectnessValues -cnotcontains $correctness) {
        throw "$reviewContext.correctness '$correctness' is not one of: $($script:FoundationReviewCorrectnessValues -join ', ')."
    }

    $procedure = [string](Get-JsonProperty -Object $review -Name 'procedure' -DocumentName $reviewContext)
    if ($script:FoundationReviewProcedureValues -cnotcontains $procedure) {
        throw "$reviewContext.procedure '$procedure' is not one of: $($script:FoundationReviewProcedureValues -join ', ')."
    }

    $criteriaResults = @(Get-JsonProperty -Object $review -Name 'criteriaResults' -DocumentName $reviewContext)
    if ($criteriaResults.Count -ne $successCriteria.Count) {
        throw "$reviewContext.criteriaResults has $($criteriaResults.Count) entries but intent.successCriteria has $($successCriteria.Count)."
    }
    # Bipartite 1:1 match against intent.successCriteria, order-independent:
    # each criteriaResults[].criterion consumes exactly one successCriteria
    # entry, so duplicates cannot silently cover for a missing criterion.
    $remainingCriteria = [System.Collections.Generic.List[string]]::new()
    foreach ($criterion in $successCriteria) { $remainingCriteria.Add([string]$criterion) }
    $criteriaResultIndex = 0
    foreach ($criteriaResult in $criteriaResults) {
        $criteriaResultContext = "$reviewContext.criteriaResults[$criteriaResultIndex]"
        $criterion = [string](Get-JsonProperty -Object $criteriaResult -Name 'criterion' -DocumentName $criteriaResultContext)
        $matchIndex = $remainingCriteria.IndexOf($criterion)
        if ($matchIndex -lt 0) {
            throw "$criteriaResultContext.criterion '$criterion' does not match intent.successCriteria 1:1."
        }
        $remainingCriteria.RemoveAt($matchIndex)

        $result = [string](Get-JsonProperty -Object $criteriaResult -Name 'result' -DocumentName $criteriaResultContext)
        if ($script:FoundationReviewCriterionResultValues -cnotcontains $result) {
            throw "$criteriaResultContext.result '$result' is not one of: $($script:FoundationReviewCriterionResultValues -join ', ')."
        }
        $null = Get-JsonProperty -Object $criteriaResult -Name 'evidence' -DocumentName $criteriaResultContext
        $criteriaResultIndex += 1
    }

    $null = @(Get-JsonProperty -Object $review -Name 'observedEffects' -DocumentName $reviewContext)

    $procedureChecks = Get-JsonProperty -Object $review -Name 'procedureChecks' -DocumentName $reviewContext
    $procedureChecksContext = "$reviewContext.procedureChecks"
    foreach ($key in $script:FoundationReviewProcedureCheckKeys) {
        $value = [string](Get-JsonProperty -Object $procedureChecks -Name $key -DocumentName $procedureChecksContext)
        if ($script:FoundationReviewProcedureCheckValues -cnotcontains $value) {
            throw "$procedureChecksContext.$key '$value' is not one of: $($script:FoundationReviewProcedureCheckValues -join ', ')."
        }
    }

    $betterProcedure = [string](Get-JsonProperty -Object $review -Name 'betterProcedure' -DocumentName $reviewContext)
    if ([string]::IsNullOrWhiteSpace($betterProcedure)) {
        throw "$reviewContext.betterProcedure is empty; record 'none' when there is nothing to suggest."
    }

    $verdict = [string](Get-JsonProperty -Object $review -Name 'verdict' -DocumentName $reviewContext)
    if ($script:FoundationReviewVerdictValues -cnotcontains $verdict) {
        throw "$reviewContext.verdict '$verdict' is not one of: $($script:FoundationReviewVerdictValues -join ', ')."
    }
}

function Read-FoundationReviewRecord {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [switch]$RequireIntentComplete
    )

    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Review record '$Path' is empty."
    }
    try {
        $record = $raw | ConvertFrom-Json
    } catch {
        throw "Could not parse review record '$Path': $($_.Exception.Message)"
    }
    if ($null -eq $record) {
        throw "Could not parse review record '$Path': content parsed to null."
    }
    Assert-FoundationReviewRecordShape -Record $record -Context "Review record '$Path'" -RequireIntentComplete:$RequireIntentComplete
    return $record
}

# A review record moves through three states as it is filled in:
#   draft            - late:true, intent.goal/successCriteria empty or
#                       partial. Assert-FoundationReviewRecordShape accepts
#                       this by default (-RequireIntentComplete not set).
#   intent-recorded   - intent.goal/successCriteria are fully populated.
#                       Typically produced by Get-FoundationReviewInitPlan
#                       sealing the intent at HEAD==baseCommit, in which case
#                       late:false; Assert-FoundationReviewRecordShape also
#                       requires a complete intent whenever late:false, even
#                       outside that helper.
#   reviewed          - review is non-null. Assert-FoundationReviewRecordShape
#                       always requires a complete intent once review is set,
#                       regardless of late, because a review cannot be judged
#                       against success criteria that were never recorded.
# This skeleton produces a draft when Goal/SuccessCriteria are omitted (the
# historical default); callers that already have a complete intent to record
# (e.g. Get-FoundationReviewInitPlan sealing it at the base commit) pass
# -Goal/-SuccessCriteria to produce an intent-recorded skeleton directly.
function New-FoundationReviewRecordSkeleton {
    param(
        [Parameter(Mandatory)] [string]$Release,
        [Parameter(Mandatory)] [int]$Generation,
        [Parameter(Mandatory)] [string]$BaseCommit,
        [Parameter(Mandatory)] [bool]$Late,
        [string]$Goal = '',
        [string[]]$SuccessCriteria = @()
    )

    return [ordered]@{
        schemaVersion = 1
        release = $Release
        generation = $Generation
        baseCommit = $BaseCommit
        late = $Late
        intent = [ordered]@{
            recordedAt = [DateTimeOffset]::Now.ToString('o')
            goal = $Goal
            expectedEffects = @()
            successCriteria = @($SuccessCriteria | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            nonGoals = @()
        }
        review = $null
    }
}

# Never throws: a purely descriptive predicate over whatever shape `Record`
# happens to be (including $null, or a draft that would fail
# Assert-FoundationReviewRecordShape), so Test-FoundationReviewGate and
# presentation code can ask "is the intent usable yet?" without first
# validating the whole record.
function Test-FoundationReviewIntentComplete {
    param(
        [AllowNull()] [object]$Record
    )

    if ($null -eq $Record) { return $false }
    $intent = Get-OptionalJsonProperty -Object $Record -Name 'intent'
    if ($null -eq $intent) { return $false }
    $goal = Get-OptionalJsonProperty -Object $intent -Name 'goal'
    if ([string]::IsNullOrWhiteSpace([string]$goal)) { return $false }
    $successCriteria = @(Get-OptionalJsonProperty -Object $intent -Name 'successCriteria')
    $nonWhitespaceCriteria = @($successCriteria | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($nonWhitespaceCriteria.Count -eq 0) { return $false }
    return $true
}

# Pure gate decision so every combination can be unit tested without a live
# promote. The truth table is covered by Test-ReleaseReview.ps1:
#   Record = $null                                -> recordPresent:false, satisfied:false
#   intentComplete = false (draft record)          -> satisfied:false
#   Record.review = $null                          -> verdict:null,       satisfied:false
#   Record.review.verdict in {needs-work,rejected} -> satisfied:false
#   verdict = accepted, reviewedCommit != Current   -> satisfied:false
#   verdict = accepted, reviewedCommit == Current, intentComplete
#     (-CurrentRepositories omitted)              -> satisfied:true
#   -CurrentRepositories supplied:
#     reviewedCommitMatches means root match AND nested 1:1
#     (missing/extra/sha-mismatch/duplicate relativePath -> false;
#      CurrentRepositories empty + reviewedRepositories absent/empty -> true;
#      CurrentRepositories non-empty + reviewedRepositories absent -> false;
#      CurrentRepositories empty + reviewedRepositories non-empty -> false)
function Test-FoundationReviewGate {
    param(
        [AllowNull()] [object]$Record,
        [string]$CurrentCommit,
        # Optional. When omitted, only root reviewedCommit vs CurrentCommit is
        # checked (historical callers / tests). When supplied (including @()),
        # nested repositories must also 1:1-match review.reviewedRepositories.
        [AllowEmptyCollection()] [object[]]$CurrentRepositories
    )

    if ($null -eq $Record) {
        return [ordered]@{
            recordPresent = $false
            intentComplete = $false
            verdict = $null
            reviewedCommitMatches = $false
            satisfied = $false
            late = $null
        }
    }

    $lateValue = Get-OptionalJsonProperty -Object $Record -Name 'late'
    $late = if ($null -eq $lateValue) { $null } else { [bool]$lateValue }
    $review = Get-OptionalJsonProperty -Object $Record -Name 'review'
    $intentComplete = Test-FoundationReviewIntentComplete -Record $Record

    if ($null -eq $review) {
        return [ordered]@{
            recordPresent = $true
            intentComplete = $intentComplete
            verdict = $null
            reviewedCommitMatches = $false
            satisfied = $false
            late = $late
        }
    }

    $verdict = [string](Get-OptionalJsonProperty -Object $review -Name 'verdict')
    $reviewedCommit = [string](Get-OptionalJsonProperty -Object $review -Name 'reviewedCommit')
    # -eq/-contains are case-insensitive by PowerShell's default; verdict enum
    # values and commit ids are both case-sensitive by contract (schema enum,
    # and the lowercase-hex commit id pattern enforced above), so an
    # upper-cased 'ACCEPTED' or commit id must not silently satisfy the gate.
    $rootMatches = [string]::Equals($reviewedCommit, $CurrentCommit, [StringComparison]::Ordinal)
    $reviewedCommitMatches = $rootMatches
    if ($PSBoundParameters.ContainsKey('CurrentRepositories')) {
        # ConvertFrom-Json / @() can collapse [] to $null; @($null) is one
        # element, not an empty list. Skip null entries so that means "no nested repos".
        $currentRepos = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($CurrentRepositories)) {
            if ($null -eq $entry) { continue }
            $currentRepos.Add($entry) | Out-Null
        }
        $reviewedReposValue = Get-OptionalJsonProperty -Object $review -Name 'reviewedRepositories'
        if ($null -eq $reviewedReposValue) {
            $reviewedCommitMatches = $rootMatches -and ($currentRepos.Count -eq 0)
        } else {
            $reviewedRepos = @($reviewedReposValue)
            if ($currentRepos.Count -ne $reviewedRepos.Count) {
                $reviewedCommitMatches = $false
            } else {
                $reviewedByPath = @{}
                $nestedOk = $true
                foreach ($entry in $reviewedRepos) {
                    $path = [string](Get-OptionalJsonProperty -Object $entry -Name 'relativePath')
                    if ([string]::IsNullOrWhiteSpace($path) -or $reviewedByPath.ContainsKey($path)) {
                        $nestedOk = $false
                        break
                    }
                    $reviewedByPath[$path] = [string](Get-OptionalJsonProperty -Object $entry -Name 'headCommit')
                }
                if ($nestedOk) {
                    $seenCurrent = @{}
                    foreach ($entry in $currentRepos) {
                        $path = [string](Get-OptionalJsonProperty -Object $entry -Name 'relativePath')
                        if ([string]::IsNullOrWhiteSpace($path) -or $seenCurrent.ContainsKey($path)) {
                            $nestedOk = $false
                            break
                        }
                        $seenCurrent[$path] = $true
                        if (-not $reviewedByPath.ContainsKey($path)) {
                            $nestedOk = $false
                            break
                        }
                        $currentHead = [string](Get-OptionalJsonProperty -Object $entry -Name 'headCommit')
                        if (-not [string]::Equals($reviewedByPath[$path], $currentHead, [StringComparison]::Ordinal)) {
                            $nestedOk = $false
                            break
                        }
                    }
                }
                $reviewedCommitMatches = $rootMatches -and $nestedOk
            }
        }
    }
    $satisfied = ($intentComplete -and [string]::Equals($verdict, 'accepted', [StringComparison]::Ordinal) -and $reviewedCommitMatches)

    return [ordered]@{
        recordPresent = $true
        intentComplete = $intentComplete
        verdict = $verdict
        reviewedCommitMatches = $reviewedCommitMatches
        satisfied = $satisfied
        late = $late
    }
}

# Computes what `-Stage review-init` should write, and validates it, without
# touching disk. Isolated as a pure function so Phase3b's stage handler can
# call it directly and every branch (intent sealed at the base commit, draft,
# late intent, unresolved base commit, half-supplied intent) is unit-testable
# without a live release.
function Get-FoundationReviewInitPlan {
    param(
        [Parameter(Mandatory)] [string]$Release,
        [Parameter(Mandatory)] [int]$Generation,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string]$BaseCommit,
        [Parameter(Mandatory)] [string]$HeadCommit,
        [AllowEmptyString()] [string]$Goal = '',
        [AllowEmptyCollection()] [string[]]$SuccessCriteria = @(),
        [AllowEmptyCollection()] [object[]]$NestedRepositories = @(),
        [switch]$AllowLateIntent
    )

    if ([string]::IsNullOrWhiteSpace($BaseCommit)) {
        throw "Could not resolve the base commit for release '$Release' from transitionHistory; -Stage review-init cannot record a review intent for it."
    }
    if ($BaseCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw "Base commit '$BaseCommit' for release '$Release' is not a 40-character lowercase hex commit id."
    }

    $goalSupplied = -not [string]::IsNullOrWhiteSpace($Goal)
    $successCriteriaSupplied = (@($SuccessCriteria | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)
    if ($goalSupplied -ne $successCriteriaSupplied) {
        throw '-Goal and -SuccessCriteria must be supplied together.'
    }

    $headAtBase = ($HeadCommit -ceq $BaseCommit)
    $atBase = $headAtBase
    $movedNestedPath = $null
    foreach ($entry in @($NestedRepositories)) {
        if ($null -eq $entry) { continue }
        $childHead = [string](Get-OptionalJsonProperty -Object $entry -Name 'headCommit')
        $childBase = [string](Get-OptionalJsonProperty -Object $entry -Name 'baseCommit')
        if ([string]::IsNullOrWhiteSpace($childHead) -or [string]::IsNullOrWhiteSpace($childBase) -or ($childHead -cne $childBase)) {
            $atBase = $false
            if ($null -eq $movedNestedPath) {
                $movedNestedPath = [string](Get-OptionalJsonProperty -Object $entry -Name 'relativePath')
            }
        }
    }

    if (-not $atBase -and -not $AllowLateIntent.IsPresent) {
        if (-not $headAtBase) {
            throw "Candidate HEAD $HeadCommit is not the release base commit $BaseCommit; development has already started. Re-run with -AllowLateIntent to record a late intent (late:true)."
        }
        throw "Nested repository '$movedNestedPath' HEAD has moved past its base commit; development has already started. Re-run with -AllowLateIntent to record a late intent (late:true)."
    }

    $intentSupplied = $goalSupplied -and $successCriteriaSupplied
    $late = -not ($atBase -and $intentSupplied)

    $record = New-FoundationReviewRecordSkeleton -Release $Release -Generation $Generation -BaseCommit $BaseCommit -Late $late -Goal $Goal -SuccessCriteria $SuccessCriteria
    $intentComplete = Test-FoundationReviewIntentComplete -Record $record
    Assert-FoundationReviewRecordShape -Record $record -Context 'review-init record' -RequireIntentComplete:$intentComplete

    return [ordered]@{
        record = $record
        late = $late
        intentComplete = $intentComplete
        headAtBase = $headAtBase
        atBase = $atBase
    }
}

# Writes a brand new review record file, refusing to overwrite an existing
# one. FileMode.CreateNew makes the exclusive-create atomic at the OS level
# (closing the check-then-write race structurally); the Test-Path check ahead
# of it exists only so the error message is one this codebase controls,
# rather than whatever wording .NET happens to raise for that race.
function New-FoundationReviewRecordFile {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Record
    )

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "Review record path '$Path' must be an absolute path."
    }

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        throw "Review record '$Path' already exists; refusing to overwrite it."
    }

    $json = ConvertTo-Json -InputObject $Record -Depth 10
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return [System.IO.Path]::GetFullPath($Path)
}

# Pure merge of a review block into an existing record. Does not touch disk.
# reviewedCommit / reviewedRepositories from Block are discarded; live
# CurrentCommit / CurrentRepositories win. Existing review without -Force throws.
function Merge-FoundationReviewBlock {
    param(
        [Parameter(Mandatory)] [object]$Record,
        [Parameter(Mandatory)] [object]$Block,
        [Parameter(Mandatory)] [string]$CurrentCommit,
        [AllowEmptyCollection()] [object[]]$CurrentRepositories = @(),
        [switch]$Force
    )

    $existingReview = Get-JsonProperty -Object $Record -Name 'review' -DocumentName 'merge review record'
    # Check the switch as a bool, not .IsPresent: callers (review stage) pass
    # -Force:$Force, which binds the parameter even when the value is $false.
    if (($null -ne $existingReview) -and (-not $Force)) {
        throw "Review record already has a review block; re-run with -Force to overwrite it."
    }

    $reviewedRepositories = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($CurrentRepositories)) {
        if ($null -eq $entry) { continue }
        $relativePath = [string](Get-OptionalJsonProperty -Object $entry -Name 'relativePath')
        $headCommit = [string](Get-OptionalJsonProperty -Object $entry -Name 'headCommit')
        $reviewedRepositories.Add([ordered]@{
            relativePath = $relativePath
            headCommit = $headCommit
        }) | Out-Null
    }

    $review = [ordered]@{
        reviewedAt = Get-JsonProperty -Object $Block -Name 'reviewedAt' -DocumentName 'merge review block'
        reviewedCommit = $CurrentCommit
        correctness = Get-JsonProperty -Object $Block -Name 'correctness' -DocumentName 'merge review block'
        procedure = Get-JsonProperty -Object $Block -Name 'procedure' -DocumentName 'merge review block'
        criteriaResults = @(Get-JsonProperty -Object $Block -Name 'criteriaResults' -DocumentName 'merge review block')
        observedEffects = @(Get-JsonProperty -Object $Block -Name 'observedEffects' -DocumentName 'merge review block')
        procedureChecks = Get-JsonProperty -Object $Block -Name 'procedureChecks' -DocumentName 'merge review block'
        betterProcedure = Get-JsonProperty -Object $Block -Name 'betterProcedure' -DocumentName 'merge review block'
        verdict = Get-JsonProperty -Object $Block -Name 'verdict' -DocumentName 'merge review block'
    }
    if ($reviewedRepositories.Count -gt 0) {
        $review['reviewedRepositories'] = @($reviewedRepositories.ToArray())
    }

    # Round-trip intent (and other top-level values) through JSON so the input
    # $Record is never mutated, while nested PSCustomObjects stay intact.
    $intentCopy = (Get-JsonProperty -Object $Record -Name 'intent' -DocumentName 'merge review record') |
        ConvertTo-Json -Depth 10 | ConvertFrom-Json

    $merged = [ordered]@{
        schemaVersion = Get-JsonProperty -Object $Record -Name 'schemaVersion' -DocumentName 'merge review record'
        release = Get-JsonProperty -Object $Record -Name 'release' -DocumentName 'merge review record'
        generation = Get-JsonProperty -Object $Record -Name 'generation' -DocumentName 'merge review record'
        baseCommit = Get-JsonProperty -Object $Record -Name 'baseCommit' -DocumentName 'merge review record'
        late = Get-JsonProperty -Object $Record -Name 'late' -DocumentName 'merge review record'
        intent = $intentCopy
        review = $review
    }

    Assert-FoundationReviewRecordShape -Record $merged -Context 'merged review record'
    return $merged
}

# Overwrites an existing review record file (UTF-8 without BOM). Refuses to
# create a missing file — callers must have run review-init first. Uses the
# same temp + File.Replace pattern as Write-ReleaseStateAtomic so a failed
# write leaves the previous bytes intact.
function Set-FoundationReviewRecordFile {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Record
    )

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "Review record path '$Path' must be an absolute path."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Review record '$Path' does not exist; run -Stage review-init first."
    }

    $replaceId = [guid]::NewGuid().ToString('N')
    $tempPath = "$Path.$replaceId.tmp"
    $backupPath = "$Path.$replaceId.bak"
    try {
        $json = ConvertTo-Json -InputObject $Record -Depth 10
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempPath, $json, $encoding)
        [System.IO.File]::Replace($tempPath, $Path, $backupPath)
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
    return [System.IO.Path]::GetFullPath($Path)
}

# Moved here from Get-FoundationReleaseDiff.ps1 (which dot-sources this file
# ahead of using it) so Get-FoundationReviewInitPlan can resolve a release's
# base commit the same way the diff report does, without duplicating the
# walk.
function Resolve-FoundationReleaseBaseCommit {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [string]$ReleaseName
    )

    # Walk from the end: the most recent seed for this release name
    # is where its run development started. An older entry with the same
    # name (a retired release reusing a name) must not win.
    $history = @($State.transitionHistory)
    for ($i = $history.Count - 1; $i -ge 0; $i--) {
        $entry = $history[$i]
        if ([string]$entry.action -eq 'seed' -and [string]$entry.release -eq $ReleaseName) {
            return [string]$entry.commit
        }
    }
    return $null
}
