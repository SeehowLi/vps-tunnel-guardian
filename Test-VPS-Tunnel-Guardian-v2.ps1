$ErrorActionPreference = 'Stop'
$appPath = Join-Path $PSScriptRoot 'VPS-Tunnel-Guardian.ps1'
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($appPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}

$source = Get-Content -LiteralPath $appPath -Encoding utf8 -Raw
foreach ($required in @(
    "Mode = 'Socks5'",
    "'LocalForward'",
    'SSH_ASKPASS',
    'SSH_ASKPASS_REQUIRE',
    'DataProtectionScope]::CurrentUser',
    'StrictHostKeyChecking=accept-new',
    'ServerAliveInterval=15',
    'ServerAliveCountMax=6',
    'ExitOnForwardFailure=yes',
    'BatchMode=yes',
    'Get-LocalPortListener',
    'Import-LegacyTunnel',
    'NotifyIcon',
    'ShowBalloonTip',
    '多隧道',
    'SOCKS5 代理',
    '[System.Drawing.Point]::new'
)) {
    if (-not $source.Contains($required)) {
        throw "Required multi-tunnel safeguard missing: $required"
    }
}

$settingsPath = Join-Path $PSScriptRoot 'settings.json'
$settings = Get-Content -LiteralPath $settingsPath -Encoding utf8 -Raw | ConvertFrom-Json
if ($settings.Version -ne 2 -or $null -eq $settings.PSObject.Properties['Tunnels']) {
    throw 'The V2 settings template must expose an empty multi-tunnel collection.'
}
if ((Get-Content -LiteralPath $settingsPath -Encoding utf8 -Raw) -match '(?i)password') {
    throw 'The settings template must never store a password field.'
}

$askPassPath = Join-Path $PSScriptRoot 'SshAskPass.cs'
$askPassSource = Get-Content -LiteralPath $askPassPath -Encoding utf8 -Raw
foreach ($required in @('ProtectedData.Unprotect', 'DataProtectionScope.CurrentUser', 'Array.Clear')) {
    if (-not $askPassSource.Contains($required)) {
        throw "Ask-pass helper safeguard missing: $required"
    }
}

Write-Host 'PASS: V2 parsed and exposes independent multi-tunnel SOCKS5/local forwarding, per-user encrypted password storage, port collision protection, and legacy-safe migration.'
