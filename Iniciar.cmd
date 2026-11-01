@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo Esta aplicacion necesita PowerShell 7.4 o posterior.
  echo Descarga oficial: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows
  pause
  exit /b 1
)
pwsh.exe -NoProfile -STA -File "%~dp0MiBoveda.ps1"
if errorlevel 1 pause
