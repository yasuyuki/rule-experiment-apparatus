[CmdletBinding()]
param(
    [switch]$Live
)

$ErrorActionPreference = 'Stop'

$toolRoot = Split-Path -Parent $PSCommandPath
function Assert-Policy {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$manifest = Get-Content -Raw -LiteralPath (Join-Path $toolRoot 'package.json') | ConvertFrom-Json
$lock = Get-Content -Raw -LiteralPath (Join-Path $toolRoot 'package-lock.json') | ConvertFrom-Json -AsHashtable
$npmrcLines = @(Get-Content -LiteralPath (Join-Path $toolRoot '.npmrc') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

Assert-Policy ($manifest.name -ceq 'opencode-policy') 'package.json name must be opencode-policy.'
Assert-Policy ($manifest.private -eq $true) 'package.json must set private to true.'
Assert-Policy ($manifest.dependencies.PSObject.Properties.Name.Count -eq 1 -and $manifest.dependencies.'opencode-ai' -ceq '1.18.21') 'package.json must pin only opencode-ai 1.18.21.'
Assert-Policy ($manifest.allowScripts.PSObject.Properties.Name.Count -eq 1 -and $manifest.allowScripts.'opencode-ai@1.18.21' -eq $true) 'package.json must allow only opencode-ai@1.18.21 install scripts.'
Assert-Policy ($npmrcLines -ccontains 'strict-allow-scripts=true') '.npmrc must set strict-allow-scripts=true.'
Assert-Policy (-not ($npmrcLines -ccontains 'strict-allow-scripts=false')) '.npmrc must not disable strict-allow-scripts.'
Assert-Policy ($lock.lockfileVersion -eq 3) 'package-lock.json must use lockfileVersion 3.'
Assert-Policy ($lock['packages']['']['dependencies']['opencode-ai'] -ceq '1.18.21') 'package-lock.json root dependency must pin opencode-ai 1.18.21.'
Assert-Policy ($lock['packages']['node_modules/opencode-ai']['version'] -ceq '1.18.21') 'package-lock.json must resolve opencode-ai 1.18.21.'

$installScriptPackages = @($lock['packages'].GetEnumerator() | Where-Object { $_.Value['hasInstallScript'] -eq $true } | ForEach-Object Key)
Assert-Policy ($installScriptPackages.Count -eq 1 -and $installScriptPackages[0] -ceq 'node_modules/opencode-ai') 'package-lock.json must contain an install script only for opencode-ai.'

# Only these credential-free sources may be tracked. Inspecting them cannot
# read user-local authentication, sessions, or logs.
$tracked = @(& git -C $toolRoot ls-files -- .)
Assert-Policy ($LASTEXITCODE -eq 0) 'Unable to list tracked OpenCode policy files.'
$expectedTracked = @('.npmrc', 'README.md', 'Test-OpenCodePolicy.ps1', 'package-lock.json', 'package.json')
$trackedDifference = @(Compare-Object -ReferenceObject $expectedTracked -DifferenceObject $tracked -CaseSensitive)
Assert-Policy ($trackedDifference.Count -eq 0) 'OpenCode policy tracked-file allowlist does not match.'

$secretPattern = '(?im)(?:api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*["'']?[A-Za-z0-9_./+=-]{8,}|\b(?:sk-(?:or-v1-)?|ghp_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{8,}'
foreach ($path in $expectedTracked) {
    if ((Get-Content -Raw -LiteralPath (Join-Path $toolRoot $path)) -match $secretPattern) {
        throw "OpenCode policy source appears to contain a secret: $path"
    }
}

Write-Output 'PASS: static OpenCode policy verification'
if (-not $Live) { return }

$cli = Join-Path $toolRoot 'node_modules\.bin\opencode.cmd'
if (-not (Test-Path -LiteralPath $cli)) {
    throw "Local OpenCode CLI is missing. Run npm ci --prefix $toolRoot first."
}

$versionOutput = & $cli --version 2>&1
$versionText = [string]::Join([Environment]::NewLine, @($versionOutput))
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '\b1\.18\.21\b') {
    throw 'Local OpenCode is not version 1.18.21.'
}

# Do not display command output: auth list is used only to establish the
# provider name, never to read credentials or user-local auth files.
$authProviders = & $cli auth list 2>&1
$authProviderText = [string]::Join([Environment]::NewLine, @($authProviders))
if ($LASTEXITCODE -ne 0 -or $authProviderText -notmatch '(?i)\bopenrouter\b') {
    throw 'OpenRouter is not authenticated. Connect it through the local OpenCode CLI.'
}

$models = & $cli models openrouter 2>&1
$modelsText = [string]::Join([Environment]::NewLine, @($models))
if ($LASTEXITCODE -ne 0 -or $modelsText -notmatch '(?i)(?:openrouter/)?stealth/ox-alpha') {
    throw 'OpenRouter does not list stealth/ox-alpha.'
}

Write-Output 'Local OpenCode: 1.18.21'
Write-Output 'Authenticated provider: OpenRouter'
Write-Output 'Available model: openrouter/stealth/ox-alpha'
