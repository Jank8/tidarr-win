@echo off
title Tidarr - Cleanup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup.ps1"
pause
