@echo off
rem Run the launcher in its own console window and leave the batch immediately.
rem If PowerShell ran as a child of this batch, Ctrl+C would reach cmd.exe too
rem and it would print "Terminate batch job (Y/N)?" on top of our shutdown
rem summary. The separate console has no cmd.exe in it, so Ctrl+C goes only to
rem the launcher.
start "Tidarr" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
