@echo off
setlocal
rem --- self-elevate (scheduled task registration needs administrator) ---
fltmc >nul 2>&1
if errorlevel 1 (
    echo [i] Requesting administrator privileges ...
    set "SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
    exit /b
)
title net-warp - Autostart toggle
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-warp-autostart.ps1" status
echo.
echo   [Enter] = keep as is   [1] = enable autostart   [2] = disable autostart
set /p CH=  choose:
if "%CH%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-warp-autostart.ps1" on
if "%CH%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-warp-autostart.ps1" off
echo.
pause
