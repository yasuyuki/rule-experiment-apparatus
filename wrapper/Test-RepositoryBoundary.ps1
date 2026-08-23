[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$gitArguments = @('-c', "safe.directory=$repositoryRoot", '-C', $repositoryRoot, 'check-ignore', '--no-index', '-q', '--')

function Assert-Ignored {
    param([Parameter(Mandatory)] [string]$Path)

    & git @gitArguments $Path
    if ($LASTEXITCODE -ne 0) { throw "Expected '$Path' to be ignored by .gitignore." }
}

function Assert-NotIgnored {
    param([Parameter(Mandatory)] [string]$Path)

    & git @gitArguments $Path
    if ($LASTEXITCODE -eq 0) { throw "Expected '$Path' to be allowed by .gitignore." }
}

function Assert-MandatoryParameter {
    param([Parameter(Mandatory)] [string]$Script, [Parameter(Mandatory)] [string]$Name)

    $parameter = (Get-Command (Join-Path $PSScriptRoot $Script)).Parameters[$Name]
    $mandatory = @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory })
    if ($mandatory.Count -ne 1) { throw "Expected $Script -$Name to be mandatory." }
}

Assert-NotIgnored 'README.md'
Assert-NotIgnored 'wrapper/Test-RepositoryBoundary.ps1'
Assert-NotIgnored 'wrapper/Invoke-FoundationTests.ps1'
Assert-NotIgnored 'wrapper/config/README.md'
Assert-NotIgnored 'wrapper/config/environment.example.json'
Assert-NotIgnored 'wrapper/config/release-state.example.json'
Assert-Ignored 'wrapper/config/environment.json'
Assert-Ignored 'wrapper/config/environment.local.json'
Assert-Ignored 'wrapper/config/release-state.json'
Assert-Ignored 'wrapper/config/runtime.lock'
Assert-Ignored 'home/profile.db'
Assert-Ignored 'user-data/storage.db'
Assert-Ignored 'project-probe/test.txt'
Assert-Ignored 'archives/example.json'
Assert-Ignored 'archives/example.bundle'
Assert-Ignored 'HANDOFF.md'
Assert-Ignored 'ISSUES.md'
Assert-Ignored 'apparatus/cycles/runtime.json'
Assert-Ignored 'tools/opencode-policy/node_modules/opencode-ai/package.json'

Assert-MandatoryParameter 'New-FoundationRepositoryArchive.ps1' 'ArchiveRoot'
Assert-MandatoryParameter 'Get-FoundationRepositoryDeletionPlan.ps1' 'ArchiveRoot'
Assert-MandatoryParameter 'Test-FoundationSystem.ps1' 'ArchiveRoot'
Assert-MandatoryParameter 'Test-FoundationRepositoryArchive.ps1' 'VerificationRoot'

$tracked = @(& git -c "safe.directory=$repositoryRoot" -C $repositoryRoot ls-files)
$forbiddenTracked = @($tracked | Where-Object {
    $_ -match '^(?:archives/|apparatus/cycles/|\.claude/plan-phases/|docs/incidents/)' -or
    $_ -match '(?i)(?:^|/)(?:HANDOFF|ISSUES)\.md$' -or
    $_ -match '(?i)(?:^|/)(?:credentials?|transcripts?|profiles?|runtime|sessions?|cache|backups?)(?:/|$)'
})
if ($forbiddenTracked.Count -gt 0) {
    throw "Forbidden public paths are tracked: $($forbiddenTracked -join ', ')"
}

Write-Output 'PASS: Git boundary allows sources/templates and ignores archives, handoff files, and local runtime data'
