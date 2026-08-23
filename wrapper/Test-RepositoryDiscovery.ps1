[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\RepositoryDiscovery.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', got '$Actual'." }
}

function Assert-True {
    param([bool]$Value, [string]$Label)
    if (-not $Value) { throw "$Label expected true." }
}

$config = Read-EnvironmentConfig -ConfigPath (Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath)
$discovery = Get-JsonProperty -Object $config -Name 'repositoryDiscovery' -DocumentName 'Environment config'
$patterns = [string[]]@(Get-JsonProperty -Object $discovery -Name 'namePatterns' -DocumentName 'Environment config.repositoryDiscovery')
$origins = [string[]]@(Get-JsonProperty -Object $discovery -Name 'origins' -DocumentName 'Environment config.repositoryDiscovery')

$nameMatch = @(Get-RepositoryDiscoveryReasons -Leaf 'foundation-fixture' -Origin '' -NamePatterns $patterns -Origins $origins)
if ($nameMatch.Count -eq 0) { throw 'Configured name pattern did not match a foundation fixture.' }

if ($origins.Count -gt 0) {
    $originMatch = @(Get-RepositoryDiscoveryReasons -Leaf 'unrelated-fixture' -Origin $origins[0] -NamePatterns $patterns -Origins $origins)
    if ($originMatch.Count -eq 0) { throw 'Configured origin did not match an origin fixture.' }
}

$falseMatch = @(Get-RepositoryDiscoveryReasons -Leaf 'unrelated-fixture' -Origin 'https://example.invalid/unrelated.git' -NamePatterns $patterns -Origins $origins)
Assert-Equal $falseMatch.Count 0 'unmatched repository reasons'

Assert-Equal (Join-WorkspaceRelativePath -WorkspaceRoot '/home/u/Projects/release-5' -RelativePath 'example-app') `
    '/home/u/Projects/release-5/example-app' 'join workspace relative path'
Assert-True (Test-PathIsUnderWorkspaceRoot -WorkspaceRoot '/home/u/ws' -CandidatePath '/home/u/ws/example-app') 'child under root'
Assert-True (-not (Test-PathIsUnderWorkspaceRoot -WorkspaceRoot '/home/u/ws' -CandidatePath '/home/u/other')) 'outside root rejected'
Assert-True (-not (Test-PathIsUnderWorkspaceRoot -WorkspaceRoot '/home/u/ws' -CandidatePath '/home/u/ws-extra')) 'prefix sibling rejected'

$exact = @{ 'candidate|/home/u/Projects/release-5' = 'active' }
$prefix = @{
    candidate = @([ordered]@{ channel = 'active'; path = '/home/u/Projects/release-5'; name = 'release-5' })
    stable = @([ordered]@{ channel = 'previous'; path = '/home/y/Projects/release-4'; name = 'release-4' })
}
Assert-Equal (Resolve-ReleaseChannelForPath -ReleaseByExactPath $exact -ReleaseByInstancePathPrefix $prefix -InstanceName candidate -Path '/home/u/Projects/release-5') 'active' 'exact release root channel'
Assert-equal (Resolve-ReleaseChannelForPath -ReleaseByExactPath $exact -ReleaseByInstancePathPrefix $prefix -InstanceName candidate -Path '/home/u/Projects/release-5/example-app') 'active' 'child inherits release channel'
Assert-equal (Resolve-ReleaseChannelForPath -ReleaseByExactPath $exact -ReleaseByInstancePathPrefix $prefix -InstanceName stable -Path '/home/y/Projects') 'retired-unreferenced' 'legacy projects root stays unreferenced'
$exactOutside = @{ 'candidate|/home/u/releases/release-7' = 'active' }
$prefixOutside = @{
    candidate = @([ordered]@{ channel = 'active'; path = '/home/u/releases/release-7'; name = 'release-7' })
    stable = @()
}
Assert-equal (Resolve-ReleaseChannelForPath -ReleaseByExactPath $exactOutside -ReleaseByInstancePathPrefix $prefixOutside -InstanceName candidate -Path '/home/u/releases/release-7') 'active' 'exact release root outside Projects'
Assert-Equal (Resolve-ReleaseChannelForPath -ReleaseByExactPath $exactOutside -ReleaseByInstancePathPrefix $prefixOutside -InstanceName candidate -Path '/home/u/releases/release-7/example-app') 'active' 'child inherits channel outside Projects'

$status = New-WorkspaceRepositoryStatus `
    -RelativePath 'example-app' `
    -Declared $true `
    -Present $false `
    -ExpectedOrigin 'https://example.invalid/example-app.git' `
    -Origin $null `
    -Head $null `
    -Branch $null `
    -Dirty $null `
    -Channel 'active' `
    -ResolvedPath '/home/u/Projects/release-5/example-app'
Assert-equal $status.present $false 'missing declared present=false'
Assert-equal $status.originMatches $false 'missing declared originMatches=false'
Assert-equal $status.declared $true 'missing declared declared=true'

Assert-equal (ConvertTo-WorkspaceBundleLeaf -RelativePath '.') 'root' 'bundle leaf root'
Assert-Equal (ConvertTo-WorkspaceBundleLeaf -RelativePath 'apps/player') 'apps__player' 'bundle leaf nested'

Write-Output 'PASS: repository discovery and workspace path/channel helpers'
