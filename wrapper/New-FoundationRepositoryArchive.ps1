[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('stable', 'candidate')][string]$Instance,
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [switch]$Execute,
    [Parameter(Mandatory)][string]$ArchiveRoot,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$inventory = (& (Join-Path $PSScriptRoot 'Get-FoundationRepositoryInventory.ps1') -StatePath $StatePath -ConfigPath $ConfigPath) | ConvertFrom-Json
$matches = @($inventory.repositories | Where-Object { $_.instance -eq $Instance -and $_.path -eq $Path })
if ($matches.Count -ne 1) { throw "Expected exactly one inventory match for ${Instance}:${Path}; found $($matches.Count)." }
$repo = $matches[0]
if ($repo.channel -ne 'retired-unreferenced') { throw "Repository is still routed as '$($repo.channel)'." }
if ($repo.dirty) { throw 'Dirty repositories cannot be archived by this command.' }
if ($repo.commit -ne $ExpectedCommit) { throw "Commit mismatch: expected $ExpectedCommit, actual $($repo.commit)." }

$leaf = $Path.Substring($Path.LastIndexOf('/') + 1)
if (-not $leaf) { $leaf = 'foundation-root' }
$safeLeaf = $leaf -replace '[^A-Za-z0-9._-]', '-'
$shortCommit = $ExpectedCommit.Substring(0, [Math]::Min(12, $ExpectedCommit.Length))
$baseName = "$Instance-$safeLeaf-$shortCommit"
$archiveRootFull = [System.IO.Path]::GetFullPath($ArchiveRoot)
$bundlePath = Join-Path $archiveRootFull "$baseName.bundle"
$manifestPath = Join-Path $archiveRootFull "$baseName.json"

$plan = [ordered]@{
    action = 'archive-retired-foundation'
    execute = [bool]$Execute
    source = [ordered]@{
        instance = $Instance; distro = [string]$repo.distro; user = [string]$repo.user
        path = $Path; branch = [string]$repo.branch; commit = [string]$repo.commit; origin = [string]$repo.origin
    }
    bundlePath = $bundlePath
    manifestPath = $manifestPath
    deletionPerformed = $false
}

if (-not $Execute) { $plan | ConvertTo-Json -Depth 6; return }
if (Test-Path -LiteralPath $bundlePath) { throw "Archive already exists: $bundlePath" }
if (Test-Path -LiteralPath $manifestPath) { throw "Archive manifest already exists: $manifestPath" }
New-Item -ItemType Directory -Force -Path $archiveRootFull | Out-Null

if ($bundlePath.Substring(1, 1) -ne ':') { throw 'Archive root must be on a Windows drive visible to WSL.' }
$bundleWsl = '/mnt/' + $bundlePath.Substring(0, 1).ToLowerInvariant() + ($bundlePath.Substring(2) -replace '\\', '/')
& wsl.exe -d $repo.distro -u $repo.user -- git -C $Path bundle create $bundleWsl --all
if ($LASTEXITCODE -ne 0) { throw 'Git bundle creation failed.' }
& wsl.exe -d $repo.distro -u $repo.user -- git -C $Path bundle verify $bundleWsl | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Git bundle verification failed.' }

$hash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
$manifest = [ordered]@{
    schemaVersion = 1
    createdAt = [DateTimeOffset]::Now.ToString('o')
    source = $plan.source
    bundle = [ordered]@{ path = $bundlePath; sha256 = $hash; length = (Get-Item -LiteralPath $bundlePath).Length }
    verified = $true
    sourceDeleted = $false
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$plan['sha256'] = $hash
$plan['verified'] = $true
$plan | ConvertTo-Json -Depth 6
