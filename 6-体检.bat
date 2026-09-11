@echo off
setlocal
title net-warp - health check
rem Doctor is read-only and does NOT need administrator privileges.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-warp-autostart.ps1" doctor
echo.
echo   [Enter] = exit    [1] = run doctor again    [2] = restart local bridge
set /p CH=  choose:
if "%CH%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-warp-autostart.ps1" doctor
if "%CH%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-warp-autostart.ps1" restart
echo.
pause
