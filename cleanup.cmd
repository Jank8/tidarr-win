@echo off
setlocal EnableDelayedExpansion
title Tidarr - Cleanup
cd /d "%~dp0"

echo.
echo  Tidarr Cleanup
echo ----------------------------------------
echo  This will remove ALL generated files:
echo   - node_modules (all)
echo   - build output (api\dist, app\build)
echo   - package-lock.json
echo   - npm / vite cache
echo   - shared\  (all data, auth, queue, logs)
echo.
echo  After cleanup, run start.cmd to
echo  reinstall and set up from scratch.
echo ----------------------------------------
echo.

set /p CONFIRM=Are you sure? (y/N): 
if /i not "!CONFIRM!"=="y" (
    echo Cancelled.
    exit /b 0
)

echo.

:: ── node_modules ─────────────────────────────────────────────────────────────
echo [1/5] Removing node_modules...
if exist "node_modules"       rmdir /s /q "node_modules"
if exist "api\node_modules"   rmdir /s /q "api\node_modules"
if exist "app\node_modules"   rmdir /s /q "app\node_modules"
if exist "e2e\node_modules"   rmdir /s /q "e2e\node_modules"
echo   Done.

:: ── build output ─────────────────────────────────────────────────────────────
echo [2/5] Removing build output...
if exist "api\dist"    rmdir /s /q "api\dist"
if exist "app\build"   rmdir /s /q "app\build"
if exist "app\dist"    rmdir /s /q "app\dist"
if exist "app\.vite"   rmdir /s /q "app\.vite"
echo   Done.

:: ── lock files ───────────────────────────────────────────────────────────────
echo [3/5] Removing lock files...
if exist "package-lock.json"       del /f /q "package-lock.json"
if exist "api\package-lock.json"   del /f /q "api\package-lock.json"
if exist "app\package-lock.json"   del /f /q "app\package-lock.json"
echo   Done.

:: ── npm cache ────────────────────────────────────────────────────────────────
echo [4/5] Removing npm cache...
if exist "%LOCALAPPDATA%\npm-cache\_npx" rmdir /s /q "%LOCALAPPDATA%\npm-cache\_npx"
echo   Done.

:: ── shared (all runtime data) ────────────────────────────────────────────────
echo [5/5] Removing shared data...
if exist "shared" rmdir /s /q "shared"
echo   Done.

echo.
echo ----------------------------------------
echo  Cleanup complete. Project is fresh.
echo  Run start.cmd to reinstall and launch.
echo ----------------------------------------
echo.
pause
