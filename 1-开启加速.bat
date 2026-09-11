@echo off
setlocal
rem --- self-elevate (hosts file + warp-cli need administrator) ---
fltmc >nul 2>&1
if errorlevel 1 (
    echo [i] Requesting administrator privileges ...
    set "SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
    exit /b
)
title net-warp - ON
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-warp-on.ps1"
echo.
if "%GITHUB_ACCEL_NO_PAUSE%"=="1" goto :eof
pause
