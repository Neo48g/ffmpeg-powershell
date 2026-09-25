@echo off
chcp 866 >nul
title Video Trimmer
cd /d "%~dp0"

:: Запускаем обрезку видео (путь к файлу запрашивается в скрипте)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\trim-video.ps1"

echo.
echo -------------------------------------------------------------------
echo Process finished. Press any key to close this window.
pause >nul
