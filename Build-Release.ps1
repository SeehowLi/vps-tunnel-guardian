#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$releaseDirectory = Join-Path $projectRoot 'release'
$compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$executablePath = Join-Path $releaseDirectory 'VPS-Tunnel-Guardian.exe'
$iconPath = Join-Path $projectRoot 'tunnel-logo.ico'

if (-not (Test-Path -LiteralPath $compiler)) {
    throw "The .NET Framework C# compiler was not found: $compiler"
}

New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null

$compilerArguments = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/debug-',
    "/out:$executablePath",
    "/win32icon:$iconPath",
    '/r:System.Windows.Forms.dll',
    "/resource:$projectRoot\VPS-Tunnel-Guardian.ps1,VpsTunnelGuardian.VPS-Tunnel-Guardian.ps1",
    "/resource:$iconPath,VpsTunnelGuardian.tunnel-logo.ico",
    "/resource:$projectRoot\settings.json,VpsTunnelGuardian.settings.json",
    "$projectRoot\Launcher.cs"
)

& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) {
    throw "C# compiler failed with exit code $LASTEXITCODE."
}

Get-Item -LiteralPath $executablePath | Select-Object FullName, Length, LastWriteTime
