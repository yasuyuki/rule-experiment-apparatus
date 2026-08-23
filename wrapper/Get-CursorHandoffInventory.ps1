[CmdletBinding()]
param(
    [ValidateSet('stable', 'candidate')]
    [string]$Instance = 'candidate',
    [string]$ConfigPath,
    [string]$FixturePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Configuration.ps1')
. (Join-Path $PSScriptRoot 'lib\CursorHandoff.ps1')

if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
    (Get-Content -Raw -LiteralPath $FixturePath | ConvertFrom-Json) | ConvertTo-Json -Depth 6
    return
}

$resolvedConfigPath = Resolve-EnvironmentConfigPath -ConfigPath $ConfigPath
$config = Read-EnvironmentConfig -ConfigPath $resolvedConfigPath
$instanceConfig = Get-ConfiguredInstance -Configuration $config -Name $Instance

if (-not ('Foundation.Native.Window' -as [type])) {
    Add-Type -TypeDefinition @'
namespace Foundation.Native {
    public static class Window {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool IsWindowVisible(System.IntPtr handle);
    }
}
'@
}

$roots = @(Get-CimInstance Win32_Process -Filter "Name = 'Cursor.exe'" | Where-Object {
    $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch 'gitWorker'
} | ForEach-Object {
    [ordered]@{
        pid = [int]$_.ProcessId
        parentPid = [int]$_.ParentProcessId
        commandLine = [string]$_.CommandLine
    }
})
$windows = @(Get-Process Cursor -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -ne 0 -and [Foundation.Native.Window]::IsWindowVisible($_.MainWindowHandle)
} | ForEach-Object {
    [ordered]@{
        pid = [int]$_.Id
        handle = [long]$_.MainWindowHandle
        title = [string]$_.MainWindowTitle
    }
})

$remote = @(Get-WslCursorServerProcesses -Distro ([string]$instanceConfig.wslDistro) -User ([string]$instanceConfig.wslUser) -SubjectHome ([string]$instanceConfig.wslHome))

[ordered]@{
    instance = $Instance
    capturedAt = [DateTimeOffset]::Now.ToString('o')
    roots = @($roots)
    windows = @($windows)
    remote = @($remote)
} | ConvertTo-Json -Depth 6
