[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$BackupRoot,
    [string]$ConfigPath,
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$resolvedStatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$controlPlane = Get-JsonProperty -Object $config -Name 'controlPlane' -DocumentName 'Environment config'
$controlPlaneInstanceName = [string](Get-JsonProperty -Object $controlPlane -Name 'gitInstance' -DocumentName 'Environment config.controlPlane')
$controlPlaneInstance = Get-ConfiguredInstance -Configuration $config -Name $controlPlaneInstanceName
$controlPlaneDistro = [string]$controlPlaneInstance.wslDistro
$controlPlaneUser = [string]$controlPlaneInstance.wslUser
$backupRootFull = Resolve-BackupRoot -BackupRoot $BackupRoot -Configuration $config -ConfigurationPath $resolvedConfigPath -BasePath (Get-ConfigurationWorkspaceRoot)
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$repoWsl = ConvertTo-WslPath -WindowsPath $repoRoot
$head = (& wsl.exe -d $controlPlaneDistro -u $controlPlaneUser -- git -C $repoWsl rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Could not resolve control-plane HEAD.' }
$short = $head.Substring(0, 12)
$bundlePath = Join-Path $backupRootFull "cursor-isolation-control-plane-$short.bundle"
$manifestPath = Join-Path $backupRootFull "cursor-isolation-control-plane-$short.json"

$plan = [ordered]@{
    action = 'backup-control-plane'
    execute = [bool]$Execute
    repository = $repoRoot
    commit = $head
    configPath = $resolvedConfigPath
    statePath = $resolvedStatePath
    controlPlane = [ordered]@{ instance = $controlPlaneInstanceName; distro = $controlPlaneDistro; user = $controlPlaneUser }
    backupRoot = $backupRootFull
    bundlePath = $bundlePath
    manifestPath = $manifestPath
}
if (-not $Execute) { $plan | ConvertTo-Json -Depth 5; return }
if (Test-Path -LiteralPath $bundlePath) { throw "Backup already exists: $bundlePath" }
if (Test-Path -LiteralPath $manifestPath) { throw "Backup manifest already exists: $manifestPath" }
New-Item -ItemType Directory -Force -Path $backupRootFull | Out-Null

$bundleWsl = ConvertTo-WslPath -WindowsPath $bundlePath
& wsl.exe -d $controlPlaneDistro -u $controlPlaneUser -- git -C $repoWsl bundle create $bundleWsl --all
if ($LASTEXITCODE -ne 0) { throw 'Control-plane bundle creation failed.' }
& wsl.exe -d $controlPlaneDistro -u $controlPlaneUser -- git -C $repoWsl bundle verify $bundleWsl | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Control-plane bundle verification failed.' }

$hash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
$manifest = [ordered]@{
    schemaVersion = 1
    createdAt = [DateTimeOffset]::Now.ToString('o')
    repository = $repoRoot
    commit = $head
    branch = (& wsl.exe -d $controlPlaneDistro -u $controlPlaneUser -- git -C $repoWsl branch --show-current).Trim()
    source = [ordered]@{ repository = $repoRoot; distro = $controlPlaneDistro; user = $controlPlaneUser; configPath = $resolvedConfigPath }
    bundle = [ordered]@{ path = $bundlePath; sha256 = $hash; length = (Get-Item -LiteralPath $bundlePath).Length }
    verified = $true
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$plan['sha256'] = $hash
$plan['verified'] = $true
$plan | ConvertTo-Json -Depth 5
