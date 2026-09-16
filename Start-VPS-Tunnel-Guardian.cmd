@echo off
setlocal
if not exist "%~dp0release\VPS-Tunnel-Guardian-v2.1.exe" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Release.ps1"
  if errorlevel 1 exit /b 1
)
start "" "%~dp0release\VPS-Tunnel-Guardian-v2.1.exe"
