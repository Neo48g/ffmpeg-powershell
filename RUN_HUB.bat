@echo off
title FFmpeg Tools Hub Launcher
cd /d "%~dp0"

:: Launch PowerShell hub script.
:: -NoProfile speeds up startup, -ExecutionPolicy Bypass allows script execution.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "ffmpeg_hub.ps1"

:: Keep the window open after the script exits
pause
