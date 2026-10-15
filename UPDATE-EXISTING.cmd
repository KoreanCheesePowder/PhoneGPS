@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UPDATE-EXISTING.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] Update failed. Do not delete or recreate the existing device.
) else (
  echo.
  echo [OK] Phone GPS update command completed.
)
pause
