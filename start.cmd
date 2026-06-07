@echo off
setlocal EnableDelayedExpansion
title Tidarr - Windows Launcher
cd /d "%~dp0"
chcp 65001 >nul

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
where node >nul 2>&1
if errorlevel 1 (
    echo   Node.js not found. Installing via winget...
    winget install OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements
    if errorlevel 1 ( echo   ERROR: Node.js install failed & pause & exit /b 1 )
    for /f "tokens=*" %%i in ('where node 2^>nul') do set NODE_PATH=%%~dpi
    set "PATH=!NODE_PATH!;%PATH%"
)
for /f "tokens=*" %%v in ('node -v 2^>nul') do echo   Node.js %%v OK

:: ── 2. Python + tiddl ───────────────────────────────────────────────────────
echo [2/4] Checking Python...
where python >nul 2>&1
if errorlevel 1 (
    echo   Python not found. Installing via winget...
    winget install Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
    if errorlevel 1 ( echo   ERROR: Python install failed & pause & exit /b 1 )
    for /f "tokens=*" %%i in ('where python 2^>nul') do set PY_PATH=%%~dpi
    set "PATH=!PY_PATH!;!PY_PATH!Scripts;%PATH%"
)
for /f "tokens=*" %%v in ('python --version 2^>nul') do echo   %%v OK

echo   Checking tiddl...
where tiddl >nul 2>&1
if errorlevel 1 (
    echo   Installing tiddl 3.4.3...
    pip install tiddl==3.4.3 --quiet
    if errorlevel 1 ( echo   ERROR: tiddl install failed & pause & exit /b 1 )
    echo   tiddl 3.4.3 OK
) else (
    echo   tiddl OK
)

:: ── 3. ffmpeg ────────────────────────────────────────────────────────────────
echo [3/4] Checking ffmpeg...
where ffmpeg >nul 2>&1
if errorlevel 1 (
    echo   ffmpeg not found. Installing via winget...
    winget install Gyan.FFmpeg --silent --accept-source-agreements --accept-package-agreements
    for /f "tokens=*" %%i in ('where ffmpeg 2^>nul') do set FF_PATH=%%~dpi
    if defined FF_PATH ( set "PATH=!FF_PATH!;%PATH%" & echo   ffmpeg OK ) else ( echo   WARNING: ffmpeg not in PATH )
) else (
    echo   ffmpeg OK
)

:: ── 4. Node dependencies ─────────────────────────────────────────────────────
echo [4/4] Checking Node dependencies...
if not exist "%~dp0node_modules\concurrently" (
    echo   Installing dependencies...
    call npm install
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

call npm run dev
echo.
echo Tidarr stopped.
pause
