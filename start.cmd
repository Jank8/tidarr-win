@echo off
rem The launcher runs in this console so Ctrl+C reaches it. It also closes this
rem batch (cmd.exe) on shutdown, so the "Terminate batch job (Y/N)?" prompt never
rem appears. The console stays open while PowerShell is attached.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
