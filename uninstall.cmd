@echo off
setlocal EnableDelayedExpansion
title Tidarr - Tools
cd /d "%~dp0"

:: Elevate to admin if needed (required for PATH cleanup in registry)
net session >nul 2>&1
if errorlevel 1 (
    powershell -Command "Start-Process cmd -ArgumentList '/c cd /d ""%~dp0"" && ""%~f0""' -Verb RunAs"
    exit /b
)

echo.
echo  Tidarr Tools
echo ----------------------------------------
echo  [1] Uninstall all dependencies
echo      (Node.js, Python, tiddl, ffmpeg)
echo.
echo  [2] Check installed dependencies
echo ----------------------------------------
echo.

set /p CHOICE=Choose [1/2]: 
if "!CHOICE!"=="2" goto :check
if "!CHOICE!"=="1" goto :uninstall
echo Invalid choice.
pause & exit /b 0

:: ════════════════════════════════════════════════════════════════════════════
:check
echo.
echo ----------------------------------------
echo  Dependency Check
echo ----------------------------------------

echo Node.js:
where node >nul 2>&1
if errorlevel 1 ( echo   NOT FOUND ) else ( for /f "tokens=*" %%v in ('node -v') do echo   %%v )

echo Python:
where python >nul 2>&1
if errorlevel 1 ( echo   NOT FOUND ) else ( for /f "tokens=*" %%v in ('python --version 2^>^&1') do echo   %%v )

echo tiddl:
where tiddl >nul 2>&1
if errorlevel 1 ( echo   NOT FOUND ) else ( echo   OK )

echo ffmpeg:
where ffmpeg >nul 2>&1
if errorlevel 1 ( echo   NOT FOUND ) else ( echo   OK )

echo npm:
where npm >nul 2>&1
if errorlevel 1 ( echo   NOT FOUND ) else ( for /f "tokens=*" %%v in ('npm -v 2^>nul') do echo   %%v )

echo.
echo ----------------------------------------
pause & exit /b 0

:: ════════════════════════════════════════════════════════════════════════════
:uninstall
echo.
echo ----------------------------------------
echo  This will uninstall:
echo   - tiddl (Python package)
echo   - ffmpeg
echo   - Python 3.13
echo   - Node.js
echo.
echo  Your music files will NOT be deleted.
echo ----------------------------------------
echo.

set /p CONFIRM=Are you sure? (y/N): 
if /i not "!CONFIRM!"=="y" ( echo Cancelled. & pause & exit /b 0 )
echo.

echo [0] Stopping running processes...
taskkill /f /im node.exe >nul 2>&1
taskkill /f /im tiddl.exe >nul 2>&1
taskkill /f /im ffmpeg.exe >nul 2>&1
timeout /t 1 /nobreak >nul
echo   Done.

echo [1] Uninstalling tiddl...
where pip >nul 2>&1
if not errorlevel 1 ( pip uninstall tiddl -y >nul 2>&1 & echo   Done. ) else ( echo   pip not found, skipping. )

echo [2] Uninstalling ffmpeg...
winget uninstall Gyan.FFmpeg --silent >nul 2>&1
if errorlevel 1 ( echo   Not found or already removed. ) else ( echo   Done. )

echo [3] Uninstalling Python...
winget uninstall Python.Python.3.13 --silent >nul 2>&1
if errorlevel 1 (
    winget uninstall Python.Python.3.14 --silent >nul 2>&1
    if errorlevel 1 ( echo   Not found or already removed. ) else ( echo   Done. )
) else ( echo   Done. )

echo [4] Uninstalling Node.js...
winget uninstall OpenJS.NodeJS.LTS --silent >nul 2>&1
if errorlevel 1 ( echo   Not found or already removed. ) else ( echo   Done. )

echo [5] Cleaning up PATH...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$toRemove = @(" ^
  "  'C:\Program Files\nodejs'," ^
  "  'C:\Program Files\nodejs\node_modules\npm\bin'," ^
  "  'C:\Users\' + $env:USERNAME + '\AppData\Local\Programs\Python\Python313\Scripts'," ^
  "  'C:\Users\' + $env:USERNAME + '\AppData\Local\Programs\Python\Python313'," ^
  "  'C:\Users\' + $env:USERNAME + '\AppData\Local\Programs\Python\Launcher'," ^
  "  'C:\Users\' + $env:USERNAME + '\AppData\Roaming\npm'" ^
  ");" ^
  "$machine = [System.Environment]::GetEnvironmentVariable('PATH','Machine');" ^
  "$user    = [System.Environment]::GetEnvironmentVariable('PATH','User');" ^
  "$cleanMachine = ($machine -split ';' | Where-Object { $p = $_.TrimEnd('\'); -not ($toRemove | Where-Object { $_.TrimEnd('\') -eq $p }) }) -join ';';" ^
  "$cleanUser    = ($user    -split ';' | Where-Object { $p = $_.TrimEnd('\'); -not ($toRemove | Where-Object { $_.TrimEnd('\') -eq $p }) }) -join ';';" ^
  "[System.Environment]::SetEnvironmentVariable('PATH', $cleanMachine, 'Machine');" ^
  "[System.Environment]::SetEnvironmentVariable('PATH', $cleanUser,    'User');" ^
  "Write-Host '  PATH cleaned.'"

echo.
echo ----------------------------------------
echo  Uninstall complete.
echo ----------------------------------------
echo.
pause
