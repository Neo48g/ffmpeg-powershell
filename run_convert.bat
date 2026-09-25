@echo off
chcp 866 >nul
title Media Converter
cd /d "%~dp0"

:: Запускаем конвертер медиа (путь к файлу запрашивается в скрипте)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\convert-media.ps1"

echo.
echo -------------------------------------------------------------------
echo Process finished. Press any key to close this window.
pause >nul
