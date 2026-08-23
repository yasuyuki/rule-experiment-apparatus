[CmdletBinding()]
param(
    [string]$ReviewRoot,
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\ReleaseReview.ps1')
. (Join-Path $PSScriptRoot 'lib\Result.ps1')

trap { Write-FoundationFailure -Command 'Test-FoundationReview.ps1' -ErrorRecord $_; exit 1 }

# Everything below is a read-only report over private-control/reviews: it
# never writes a review record and never mutates release-state.json. A
# missing reviews/ directory (the common case before Phase3's review-init
# stage is ever run) is not an error; it just reports an empty list.

$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$resolvedReviewRoot = Resolve-ReviewRoot -ReviewRoot $ReviewRoot -StatePath $resolvedStatePath

$reviewFiles = @(Get-ChildItem -LiteralPath $resolvedReviewRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)

$reviews = [System.Collections.Generic.List[object]]::new()
foreach ($file in $reviewFiles) {
    try {
        $record = Read-FoundationReviewRecord -Path $file.FullName
        $review = $record.review
        $reviews.Add([ordered]@{
            file = $file.Name
            valid = $true
            error = $null
            release = [string]$record.release
            generation = [int]$record.generation
            baseCommit = [string]$record.baseCommit
            late = [bool]$record.late
            intentComplete = (Test-FoundationReviewIntentComplete -Record $record)
            goal = [string]$record.intent.goal
            successCriteriaCount = @($record.intent.successCriteria).Count
            recordPresent = $true
            reviewPresent = ($null -ne $review)
            verdict = if ($review) { [string]$review.verdict } else { $null }
            reviewedCommit = if ($review) { [string]$review.reviewedCommit } else { $null }
        }) | Out-Null
    } catch {
        $reviews.Add([ordered]@{
            file = $file.Name
            valid = $false
            error = [string]$_.Exception.Message
            release = $null
            generation = $null
            baseCommit = $null
            late = $null
            intentComplete = $null
            goal = $null
            successCriteriaCount = $null
            recordPresent = $true
            reviewPresent = $null
            verdict = $null
            reviewedCommit = $null
        }) | Out-Null
    }
}

$result = [ordered]@{
    statePath = $resolvedStatePath
    reviewRoot = $resolvedReviewRoot
    reviewRootExists = (Test-Path -LiteralPath $resolvedReviewRoot -PathType Container)
    count = $reviews.Count
    reviews = @($reviews)
    checkedAt = [DateTimeOffset]::Now.ToString('o')
}

(ConvertTo-FoundationSuccess -Result $result) | ConvertTo-Json -Depth 8
exit 0
