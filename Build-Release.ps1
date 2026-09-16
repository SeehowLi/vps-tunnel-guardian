#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$releaseDirectory = Join-Path $projectRoot 'release'
$buildDirectory = Join-Path $projectRoot 'build'
$compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$askPassPath = Join-Path $buildDirectory 'SshAskPass.exe'
$executablePath = Join-Path $releaseDirectory 'VPS-Tunnel-Guardian-v2.1.exe'
$runtimePath = Join-Path $buildDirectory 'GuardianRuntime.dll'
$iconPath = Join-Path $projectRoot 'tunnel-logo.ico'

if (-not (Test-Path -LiteralPath $compiler)) {
    throw "The .NET Framework C# compiler was not found: $compiler"
}

New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null

& $compiler '/nologo' '/target:library' '/optimize+' '/r:System.Windows.Forms.dll' '/r:System.Drawing.dll' "/out:$runtimePath" "$projectRoot\GuardianRuntime.cs"
if ($LASTEXITCODE -ne 0) { throw 'Runtime compilation failed.' }

& $compiler '/nologo' '/target:exe' '/optimize+' '/debug-' "/out:$askPassPath" '/r:System.Security.dll' "$projectRoot\SshAskPass.cs"
if ($LASTEXITCODE -ne 0) {
    throw "SshAskPass compiler failed with exit code $LASTEXITCODE."
}

$compilerArguments = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/debug-',
    "/out:$executablePath",
    "/win32icon:$iconPath",
    '/r:System.Windows.Forms.dll',
    '/r:System.Management.dll',
    "/resource:$runtimePath,VpsTunnelGuardian.GuardianRuntime.dll",
    "/resource:$projectRoot\VPS-Tunnel-Guardian.ps1,VpsTunnelGuardian.VPS-Tunnel-Guardian.ps1",
    "/resource:$askPassPath,VpsTunnelGuardian.SshAskPass.exe",
    "/resource:$iconPath,VpsTunnelGuardian.tunnel-logo.ico",
    "/resource:$projectRoot\settings.json,VpsTunnelGuardian.settings.json",
    "$projectRoot\Launcher.cs"
)

& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) {
    throw "Launcher compiler failed with exit code $LASTEXITCODE."
}

# Keep the familiar V2 filename current so an old shortcut cannot reinstall the obsolete wrapper.
Copy-Item -LiteralPath $executablePath -Destination (Join-Path $releaseDirectory 'VPS-Tunnel-Guardian-v2.exe') -Force
Get-Item -LiteralPath $executablePath | Select-Object FullName, Length, LastWriteTime
