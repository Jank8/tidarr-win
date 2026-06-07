@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title Tidarr
chcp 65001 >nul

:: Fresh PATH
for /f "skip=2 tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v PATH') do set "SYSPATH=%%B"
for /f "skip=2 tokens=2*" %%A in ('reg query "HKCU\Environment" /v PATH 2^>nul') do set "USRPATH=%%B"
set "PATH=!SYSPATH!;!USRPATH!"

echo.
echo  _____ ___ ____    _    ____  ____
echo ^|_   _^|_ _^|  _ \  / \  ^|  _ \^|  _ \
echo   ^| ^|  ^| ^|^| ^| ^| ^|/ _ \ ^| ^|_) ^| ^|_) ^|
echo   ^| ^|  ^| ^|^| ^|_^| / ___ \^|  _ ^<^|  _ ^<
echo   ^|_^| ^|___^|____/_/   \_\_^| \_\_^| \_\
echo.
echo  Windows Launcher
echo ----------------------------------------

:: ── 1. Node.js ──────────────────────────────────────────────────────────────
echo [1/4] Checking Node.js...
node -v >nul 2>&1
if errorlevel 1 (
    echo   Installing Node.js...
    winget install OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements
    for /f "skip=2 tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v PATH') do set "SYSPATH=%%B"
    set "PATH=!SYSPATH!;!USRPATH!"
)
for /f %%v in ('node -v 2^>nul') do echo   Node.js %%v OK

:: ── 2. Python ───────────────────────────────────────────────────────────────
echo [2/4] Checking Python...
python --version >nul 2>&1
if errorlevel 1 (
    echo   Installing Python...
    winget install Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
    for /f "skip=2 tokens=2*" %%A in ('reg query "HKCU\Environment" /v PATH 2^>nul') do set "USRPATH=%%B"
    set "PATH=!SYSPATH!;!USRPATH!"
)
for /f "tokens=*" %%v in ('python --version 2^>nul') do echo   %%v OK

:: tiddl
echo   Checking tiddl...
tiddl --version >nul 2>&1
if errorlevel 1 (
    echo   Installing tiddl 3.4.3...
    python -m pip install tiddl==3.4.3 --quiet
    for /f "skip=2 tokens=2*" %%A in ('reg query "HKCU\Environment" /v PATH 2^>nul') do set "USRPATH=%%B"
    set "PATH=!SYSPATH!;!USRPATH!"
)
echo   tiddl OK

:: ── 3. ffmpeg ────────────────────────────────────────────────────────────────
echo [3/4] Checking ffmpeg...
ffmpeg -version >nul 2>&1
if errorlevel 1 (
    echo   Installing ffmpeg...
    winget install Gyan.FFmpeg --silent --accept-source-agreements --accept-package-agreements
    for /f "skip=2 tokens=2*" %%A in ('reg query "HKCU\Environment" /v PATH 2^>nul') do set "USRPATH=%%B"
    set "PATH=!SYSPATH!;!USRPATH!"
)
echo   ffmpeg OK

:: ── 4. Node dependencies ─────────────────────────────────────────────────────
echo [4/4] Checking Node dependencies...
if not exist "%~dp0node_modules\concurrently" (
    echo   Installing dependencies...
    npm install
    if errorlevel 1 ( echo ERROR: npm install failed & pause & exit /b 1 )
) else (
    echo   node_modules OK
)

:: ── Start ────────────────────────────────────────────────────────────────────
echo.
echo ----------------------------------------
echo  Starting Tidarr...
echo  Frontend : http://localhost:3000
echo  API      : http://localhost:8484
echo ----------------------------------------
echo.

npm run dev
echo.
echo Tidarr stopped.
pause
