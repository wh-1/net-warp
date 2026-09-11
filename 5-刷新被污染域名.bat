@echo off
setlocal
rem --- self-elevate (writes hosts) ---
fltmc >nul 2>&1
if errorlevel 1 (
    echo [i] Requesting administrator privileges ...
    set "SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
    exit /b
)
title Refresh poisoned domains (Google / YouTube / HF / Docker)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-poisoned-hosts.ps1"
echo.
if "%GITHUB_ACCEL_NO_PAUSE%"=="1" goto :eof
pause
