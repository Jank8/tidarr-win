@echo off
setlocal EnableDelayedExpansion
title Tidarr - Windows Launcher
cd /d "%~dp0"
:: Set UTF-8 code page to handle Unicode output from Python/tiddl
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
echo [1/5] Checking Node.js...
where node >nul 2>&1
if errorlevel 1 (
    echo   Node.js not found. Installing via winget...
    winget install OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements
    if errorlevel 1 (
        echo   ERROR: Could not install Node.js automatically.
        echo   Please install it manually from https://nodejs.org and re-run this script.
        pause & exit /b 1
    )
    :: Refresh PATH so node is available in this session
    for /f "tokens=*" %%i in ('where node 2^>nul') do set NODE_PATH=%%~dpi
    set "PATH=!NODE_PATH!;%PATH%"
)
for /f "tokens=*" %%v in ('node -v 2^>nul') do set NODE_VER=%%v
echo   Node.js !NODE_VER! OK

:: ── 2. Node dependencies ────────────────────────────────────────────────────
echo [2/4] Checking Python...
where python >nul 2>&1
if errorlevel 1 (
    echo   Python not found. Installing via winget...
    winget install Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
    if errorlevel 1 (
        echo   ERROR: Could not install Python automatically.
        echo   Please install it manually from https://python.org and re-run this script.
        pause & exit /b 1
    )
    for /f "tokens=*" %%i in ('where python 2^>nul') do set PY_PATH=%%~dpi
    set "PATH=!PY_PATH!;!PY_PATH!Scripts;%PATH%"
)
for /f "tokens=*" %%v in ('python --version 2^>nul') do set PY_VER=%%v
echo   !PY_VER! OK

echo [2/4] Checking tiddl...
where tiddl >nul 2>&1
if errorlevel 1 (
    echo   tiddl not found. Installing tiddl 3.4.3...
    pip install tiddl==3.4.3 --quiet
    if errorlevel 1 (
        echo   ERROR: Could not install tiddl. Make sure Python and pip are working.
        pause & exit /b 1
    )
    echo   tiddl 3.4.3 installed OK
) else (
    echo   tiddl OK
)

:: ── 4. ffmpeg ────────────────────────────────────────────────────────────────
echo [3/4] Checking ffmpeg...
where ffmpeg >nul 2>&1
if errorlevel 1 (
    echo   ffmpeg not found. Installing via winget...
    winget install Gyan.FFmpeg --silent --accept-source-agreements --accept-package-agreements
    if errorlevel 1 (
        echo   WARNING: Could not install ffmpeg automatically.
        echo   tiddl may not convert audio files. Install ffmpeg manually from https://ffmpeg.org
    ) else (
        :: Try to refresh PATH with typical ffmpeg location
        for /f "tokens=*" %%i in ('where ffmpeg 2^>nul') do set FF_PATH=%%~dpi
        set "PATH=!FF_PATH!;%PATH%"
    )
) else (
    echo   ffmpeg OK
)

:: ── Node dependencies ───────────────────────────────────────────────────────
echo [4/4] Checking Node dependencies...
if not exist "node_modules\concurrently" (
    echo   Installing dependencies...
    call npm install
    if errorlevel 1 (
        echo   ERROR: npm install failed.
        pause & exit /b 1
    )
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
if errorlevel 1 (
    echo.
    echo ERROR: Tidarr failed to start. See log above.
    pause
)
