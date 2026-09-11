@echo off
rem Logon helper: bring up the WARP SOCKS5 tunnel and point git at it.
rem Registered as scheduled task "NetWarp-OnLogon" (runs with highest privileges).
setlocal
set GITHUB_ACCEL_NO_PAUSE=1
if not exist "%~dp0logs" mkdir "%~dp0logs"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-warp-on.ps1" > "%~dp0logs\net-warp-on.log" 2>&1
exit /b %errorlevel%
