@echo off
rem Launch a SEPARATE browser window routed through WARP.
rem
rem   Preferred browser: portable Chrome (BlueSoft). It carries its own Data
rem   folder, so your iTab new tab page and bookmarks stay available there.
rem   Fallback browser : Microsoft Edge with an isolated profile.
rem
rem   Preferred upstream: local HTTP bridge on 127.0.0.1:7890 (local DNS -> all domains)
rem   Fallback upstream : raw WARP SOCKS5 on 127.0.0.1:40000   (a few domains may fail)
rem
rem   Prerequisite: run bat number 1 (enable acceleration) first.
rem
rem   Note: the portable Chrome gets its profile dir from version.dll (Chrome++),
rem   so --user-data-dir must NOT be passed for it.
setlocal EnableExtensions

set "URL=%~1"
if "%URL%"=="" set "URL=https://github.com"

set "PROXY="
netstat -an | findstr /C:"127.0.0.1:7890" | findstr /C:"LISTENING" >NUL 2>&1
if not errorlevel 1 set "PROXY=http://127.0.0.1:7890"

if not defined PROXY (
  netstat -an | findstr /C:"127.0.0.1:40000" | findstr /C:"LISTENING" >NUL 2>&1
  if not errorlevel 1 set "PROXY=socks5://127.0.0.1:40000"
)

if not defined PROXY goto :no_proxy

set "PCHROME=D:\WTool\BlueSoft\Chrome_142.0.7444.60_Portable_64Bit\App\chrome.exe"
if not exist "%PCHROME%" set "PCHROME="

set "EDGE=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=C:\Program Files\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE="

echo [i] proxy = %PROXY%
echo.

if defined PCHROME goto :use_pchrome
if defined EDGE goto :use_edge
goto :no_browser

rem ---------------------------------------------------------------------------
:use_pchrome
echo [i] launching WARP window with portable Chrome ...
echo     URL: %URL%
start "" "%PCHROME%" --proxy-server="%PROXY%" --no-first-run --no-default-browser-check "%URL%"
goto :done

rem ---------------------------------------------------------------------------
:use_edge
echo [i] launching WARP Edge window (isolated profile) ...
start "" "%EDGE%" --proxy-server="%PROXY%" --user-data-dir="%LOCALAPPDATA%\EdgeWarpProfile" --no-first-run --no-default-browser-check "%URL%"
goto :done

rem ---------------------------------------------------------------------------
:no_proxy
echo [!] Neither 7890 (bridge) nor 40000 (WARP) is listening.
echo     Run bat number 1 to enable acceleration first.
echo.
pause
exit /b 1

:no_browser
echo [!] No browser found. Open a browser manually with:
echo     --proxy-server="%PROXY%"
echo.
pause
exit /b 1

:done
exit /b 0
