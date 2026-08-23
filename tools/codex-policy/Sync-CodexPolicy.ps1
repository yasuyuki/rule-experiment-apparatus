[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CodexHome,
    [string[]] $Project = @(),
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
$policy = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'policy.psd1')
$configPath = Join-Path $CodexHome 'config.toml'
$agentsPath = Join-Path $CodexHome 'agents'
$templatesPath = Join-Path $PSScriptRoot 'agents'

function Get-Section([string] $Content, [string] $Header) {
    $match = [regex]::Match($Content, "(?ms)^\[$([regex]::Escape($Header))\]\r?\n.*?(?=^\[|\z)")
    if ($match.Success) { return $match.Value }
    return $null
}

function Set-OwnedKey([string] $Content, [string] $Header, [string] $Key, [string] $Value) {
    $section = Get-Section $Content $Header
    $line = "$Key = $Value"
    if ($null -eq $section) { return ($Content.TrimEnd() + "`n`n[$Header]`n$line`n") }
    $keyPattern = "(?m)^$([regex]::Escape($Key))\s*=.*$"
    $replacement = if ([regex]::IsMatch($section, $keyPattern)) { [regex]::Replace($section, $keyPattern, $line) } else { $section.TrimEnd() + "`n$line`n" }
    return $Content.Remove($Content.IndexOf($section), $section.Length).Insert($Content.IndexOf($section), $replacement)
}

function Get-HashOrNull([string] $Path) {
    if (Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $null
}

if (-not (Test-Path -LiteralPath $configPath)) { throw "Missing config.toml: $configPath" }
$authPath = Join-Path $CodexHome 'auth.json'
$authBefore = Get-HashOrNull $authPath
$original = [IO.File]::ReadAllText($configPath)
$updated = $original

foreach ($path in $Project) {
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'Project paths must not be empty.' }
    $updated = Set-OwnedKey $updated ("projects.'{0}'" -f $path) 'trust_level' ('"{0}"' -f $policy.ProjectTrustLevel)
}
foreach ($entry in $policy.Agents.GetEnumerator()) {
    $tomlValue = switch ($entry.Value.GetType().Name) {
        'Boolean' { $entry.Value.ToString().ToLowerInvariant() }
        'Int32' { $entry.Value.ToString([Globalization.CultureInfo]::InvariantCulture) }
        'Int64' { $entry.Value.ToString([Globalization.CultureInfo]::InvariantCulture) }
        default { '"{0}"' -f $entry.Value }
    }
    $updated = Set-OwnedKey $updated 'agents' $entry.Key $tomlValue
}

$drift = @()
if ($updated -cne $original) { $drift += 'config.toml owned keys differ' }
foreach ($template in Get-ChildItem -LiteralPath $templatesPath -Filter '*.toml' -File) {
    $target = Join-Path $agentsPath $template.Name
    if (-not (Test-Path -LiteralPath $target) -or (Get-FileHash $template -Algorithm SHA256).Hash -ne (Get-FileHash $target -Algorithm SHA256).Hash) {
        $drift += "agent profile differs: $($template.Name)"
    }
}

if (-not $Apply) {
    if ($drift.Count) { $drift | ForEach-Object { "DRIFT: $_" }; exit 1 }
    'Codex policy: OK'
    exit 0
}

if ($updated -cne $original) { [IO.File]::WriteAllText($configPath, $updated, [Text.UTF8Encoding]::new($false)) }
New-Item -ItemType Directory -Force -Path $agentsPath | Out-Null
foreach ($template in Get-ChildItem -LiteralPath $templatesPath -Filter '*.toml' -File) {
    Copy-Item -LiteralPath $template.FullName -Destination (Join-Path $agentsPath $template.Name) -Force
}
if ((Get-HashOrNull $authPath) -ne $authBefore) { throw 'auth.json changed; refusing to continue.' }
'Codex policy: applied'
