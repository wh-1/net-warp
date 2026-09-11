@echo off
setlocal
rem --- self-elevate (warp-cli needs administrator) ---
fltmc >nul 2>&1
if errorlevel 1 (
    echo [i] Requesting administrator privileges ...
    set "SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
    exit /b
)
title net-warp - OFF
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-warp-off.ps1"
echo.
if "%GITHUB_ACCEL_NO_PAUSE%"=="1" goto :eof
pause
