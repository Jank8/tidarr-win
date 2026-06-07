@echo off
setlocal EnableDelayedExpansion
title Tidarr - Cleanup
cd /d "%~dp0"

echo.
echo  Tidarr Cleanup
echo ----------------------------------------
echo  [1] Quick cleanup (default)
echo      - build output, lock files, user data
echo      - keeps node_modules (faster next start)
echo.
echo  [2] Full cleanup
echo      - everything including node_modules
echo      - npm will reinstall on next start
echo ----------------------------------------
echo.

set /p CHOICE=Choose [1/2] (default: 1): 
if "!CHOICE!"=="" set CHOICE=1
if "!CHOICE!"=="2" goto :full
if "!CHOICE!"=="1" goto :quick
echo Invalid choice.
exit /b 0

:quick
echo.
echo  Quick cleanup selected.
echo ----------------------------------------
set SKIP_MODULES=1
goto :start

:full
echo.
echo  Full cleanup selected.
echo ----------------------------------------
set SKIP_MODULES=0
goto :start

:start
set /p CONFIRM=Are you sure? (y/N): 
if /i not "!CONFIRM!"=="y" ( echo Cancelled. & exit /b 0 )
echo.

:: ── Kill running Tidarr processes ────────────────────────────────────────────
echo [0] Stopping running processes...
taskkill /f /im node.exe >nul 2>&1
taskkill /f /im tsx.exe >nul 2>&1
taskkill /f /im tiddl.exe >nul 2>&1
timeout /t 2 /nobreak >nul
echo   Done.

:: ── node_modules (full only) ──────────────────────────────────────────────────
if "!SKIP_MODULES!"=="0" (
    echo [1] Removing node_modules...
    if exist "node_modules"       rmdir /s /q "node_modules"
    if exist "api\node_modules"   rmdir /s /q "api\node_modules"
    if exist "app\node_modules"   rmdir /s /q "app\node_modules"
    echo   Done.
) else (
    echo [1] Keeping node_modules.
)

:: ── build output ─────────────────────────────────────────────────────────────
echo [2] Removing build output...
if exist "api\dist"    rmdir /s /q "api\dist"
if exist "app\build"   rmdir /s /q "app\build"
if exist "app\dist"    rmdir /s /q "app\dist"
if exist "app\.vite"   rmdir /s /q "app\.vite"
echo   Done.

:: ── lock files ───────────────────────────────────────────────────────────────
echo [3] Removing lock files...
if exist "package-lock.json"       del /f /q "package-lock.json"
if exist "api\package-lock.json"   del /f /q "api\package-lock.json"
if exist "app\package-lock.json"   del /f /q "app\package-lock.json"
echo   Done.

:: ── npm cache ────────────────────────────────────────────────────────────────
echo [4] Removing npm cache...
if exist "%LOCALAPPDATA%\npm-cache\_npx" rmdir /s /q "%LOCALAPPDATA%\npm-cache\_npx"
echo   Done.

:: ── user data ────────────────────────────────────────────────────────────────
echo [5] Removing user data...
if exist "shared"     rmdir /s /q "shared"
if exist "userfiles"  rmdir /s /q "userfiles"
echo   Done.

echo.
echo ----------------------------------------
echo  Cleanup complete.
echo  Run start.cmd to launch.
echo ----------------------------------------
echo.
pause
