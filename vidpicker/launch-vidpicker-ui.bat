@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "UI_SCRIPT=%SCRIPT_DIR%vidpicker-ui.ps1"

if not exist "%UI_SCRIPT%" (
  echo Could not find UI script:
  echo %UI_SCRIPT%
  pause
  exit /b 1
)

where pwsh >nul 2>&1
if %errorlevel%==0 (
  start "" pwsh -NoProfile -ExecutionPolicy Bypass -STA -File "%UI_SCRIPT%"
) else (
  start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%UI_SCRIPT%"
)

endlocal
exit /b 0
