@echo off
chcp 866 >nul
title YT-DLP Downloader
cd /d "%~dp0"

:: Запускает меню скачивания yt-dlp
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\yt-dlp-menu.ps1"

echo.
echo -------------------------------------------------------------------
echo Process finished. Press any key to close this window.
pause >nul
