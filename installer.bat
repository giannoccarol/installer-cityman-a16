@echo off
rem LineageOS 23.2 (Android 16) installer for the Lumia 950 XL (cityman).
rem Starts installer.ps1. Options are passed through, for example:
rem   installer.bat -Mode Update -Rom D:\lineage-23.2-20261030-UNOFFICIAL-cityman.zip
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer.ps1" %*
set "rc=%errorlevel%"
echo.
pause
exit /b %rc%
