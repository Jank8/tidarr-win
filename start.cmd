@echo off
rem Launch the launcher in this console but do not stay in the batch: cmd.exe
rem would otherwise catch Ctrl+C too and answer with "Terminate batch job (Y/N)?".
rem The console stays open while PowerShell (started with /b) is running.
start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
