@echo off
chcp 866 >nul
title Video Compressor
cd /d "%~dp0"

:: Запускаем скрипт сжатия видео (папка выбирается в самом скрипте)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\compress_video.ps1"

echo.
echo -------------------------------------------------------------------
echo Process finished. Press any key to close this window.
pause >nul
