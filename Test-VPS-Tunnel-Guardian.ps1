$ErrorActionPreference = 'Stop'
$appPath = Join-Path $PSScriptRoot 'VPS-Tunnel-Guardian.ps1'
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($appPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}

$source = Get-Content -LiteralPath $appPath -Encoding utf8 -Raw
foreach ($required in @(
    'ServerAliveInterval=30',
    'ServerAliveCountMax=3',
    'ExitOnForwardFailure=yes',
    'BatchMode=yes',
    'Stop-Tunnel',
    'Open-TunnelSettings',
    'Test-TunnelConfiguration',
    'NotifyIcon',
    'Show-ApplicationWindow',
    'Exit-Application',
    'CloseReason]::WindowsShutDown',
    'ShowBalloonTip',
    '活动日志',
    '连接路径',
    'Set-ToggleButtonMode',
    'AutoScaleMode',
    'SmoothingMode]::AntiAlias',
    'DwmSetWindowAttribute'
)) {
    if (-not $source.Contains($required)) {
        throw "Required tunnel safeguard missing: $required"
    }
}

$settingsPath = Join-Path $PSScriptRoot 'settings.json'
$settings = Get-Content -LiteralPath $settingsPath -Encoding utf8 -Raw | ConvertFrom-Json
foreach ($required in @('SshUser', 'SshServer', 'LocalPort', 'TargetHost', 'TargetPort', 'RetrySeconds')) {
    if ($null -eq $settings.PSObject.Properties[$required]) {
        throw "Required configurable setting missing: $required"
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'tunnel-logo.ico'))) {
    throw 'Application icon missing: tunnel-logo.ico'
}

Write-Host 'PASS: VPS Tunnel Guardian parsed and exposes tunnel safeguards, settings, a high-DPI dark UI, a tray controller, and a dedicated app icon.'
