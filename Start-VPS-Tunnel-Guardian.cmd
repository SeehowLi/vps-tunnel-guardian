@echo off
setlocal
powershell.exe -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0VPS-Tunnel-Guardian.ps1"
