@echo off
setlocal
if not exist "%~dp0Install-WISP.ps1" (
  echo Extract all ZIP files into one folder first.
  pause
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WISP.ps1"
set "installResult=%ERRORLEVEL%"
echo.
if not "%installResult%"=="0" echo Installation failed. See the message above.
pause
exit /b %installResult%
