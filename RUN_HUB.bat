@echo off

:: Set the window title
title FFmpeg Tools Hub Launcher

:: Switch to the directory of this .bat file (needed to locate the other scripts)
cd /d "%~dp0"

:: Launch the PowerShell script. 
:: -NoProfile speeds up startup, -ExecutionPolicy Bypass lifts execution restrictions.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "ffmpeg_hub.ps1"

:: If the script finished (or an error occurred), keep the window open until Enter is pressed
set /p _="Press Enter to close..."