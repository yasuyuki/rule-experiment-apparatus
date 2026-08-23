[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Experiment,
    [Parameter(Mandatory)][string]$Variant,
    [string]$StatePath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')

$StatePath = Resolve-ReleaseStatePath -StatePath $StatePath
$ConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$state = Read-ReleaseState -StatePath $StatePath
$config = Read-EnvironmentConfig -ConfigPath $ConfigPath
Assert-ReleaseStateRuntimePlacement -State $state -Configuration $config
if (-not $state.run) { throw 'There is no run to inject a variant into.' }

$namePattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
if ($Experiment -notmatch $namePattern) {
    throw "Experiment name is not a canonical identifier: '$Experiment'."
}
if ($Variant -notmatch $namePattern) {
    throw "Variant name is not a canonical identifier: '$Variant'."
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path (Get-ConfigurationWrapperRoot) '..'))
$variantsRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot "rule-experiments\$Experiment\variants"))
$sourceFull = [System.IO.Path]::GetFullPath((Join-Path $variantsRoot "$Variant.mdc"))
$rootPrefix = if ($variantsRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $variantsRoot
} else {
    $variantsRoot + [System.IO.Path]::DirectorySeparatorChar
}
if (-not $sourceFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Variant source escapes the canonical directory rule-experiments/$Experiment/variants/."
}
if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) {
    throw "Variant source does not exist: rule-experiments/$Experiment/variants/$Variant.mdc"
}

$run = $state.run
$runPath = [string]$run.path
$relativeDest = ".cursor/rules/$Experiment-$Variant.mdc"
if ($relativeDest -notmatch '^\.cursor/rules/[A-Za-z0-9._-]+\.mdc$') {
    throw "Refusing destination outside release-root .cursor/rules/: $relativeDest"
}
$destination = "$runPath/$relativeDest"

$instance = Get-ConfiguredInstance -Configuration $config -Name ([string]$run.instance)
$distro = [string]$instance.wslDistro
$user = [string]$instance.wslUser

function Invoke-InjectGit {
    param([Parameter(Mandatory)][string[]]$GitArguments)
    $output = & wsl.exe -d $distro -u $user --exec git -C $runPath @GitArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed for ${distro}:${runPath} ($($GitArguments -join ' '))."
    }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

$status = Invoke-InjectGit -GitArguments @('status', '--short')
if (-not [string]::IsNullOrWhiteSpace($status)) {
    throw "Run workspace is dirty; inject refused."
}

$sourceWsl = ConvertTo-WslPath -WindowsPath $sourceFull
$destDir = "$runPath/.cursor/rules"
& wsl.exe -d $distro -u $user --exec mkdir -p $destDir
if ($LASTEXITCODE -ne 0) { throw "Could not create $destDir." }
& wsl.exe -d $distro -u $user --exec cp -- $sourceWsl $destination
if ($LASTEXITCODE -ne 0) { throw "Could not copy variant to $destination." }

$sourceSha = (Get-FileHash -LiteralPath $sourceFull -Algorithm SHA256).Hash.ToLowerInvariant()
$sumLine = & wsl.exe -d $distro -u $user --exec sha256sum -- $destination
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$sumLine)) {
    throw "Could not hash injected variant at $destination."
}
$injectedSha = ([string]$sumLine).Trim().Split([char[]]@(' ', "`t"), 2, [System.StringSplitOptions]::RemoveEmptyEntries)[0].ToLowerInvariant()
if ($sourceSha -ne $injectedSha) {
    throw 'Injected variant does not match its source.'
}

$afterCopy = Invoke-InjectGit -GitArguments @('status', '--short', '--', $relativeDest)
$committed = $false
if (-not [string]::IsNullOrWhiteSpace($afterCopy)) {
    Invoke-InjectGit -GitArguments @('add', '-f', '--', $relativeDest) | Out-Null
    $message = "experiment-inject-$Experiment-$Variant-$sourceSha"
    Invoke-InjectGit -GitArguments @('commit', '-m', $message) | Out-Null
    $committed = $true
}

$commit = Invoke-InjectGit -GitArguments @('rev-parse', 'HEAD')
$verifyLine = & wsl.exe -d $distro -u $user --exec sha256sum -- $destination
$verifySha = ([string]$verifyLine).Trim().Split([char[]]@(' ', "`t"), 2, [System.StringSplitOptions]::RemoveEmptyEntries)[0].ToLowerInvariant()
if ($sourceSha -ne $verifySha) {
    throw 'Injected variant does not match its source after commit.'
}

[ordered]@{
    release = [string]$run.name
    experiment = $Experiment
    variant = $Variant
    source = "rule-experiments/$Experiment/variants/$Variant.mdc"
    destination = $destination
    sourceSha256 = $sourceSha
    injectedSha256 = $verifySha
    commit = $commit
    committed = $committed
} | ConvertTo-Json -Depth 4
