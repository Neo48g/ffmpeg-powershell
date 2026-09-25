@echo off

:: Устанавливаем заголовок окна
title FFmpeg Tools Hub Launcher

:: Переходим в каталог этого .bat-файла (нужно для поиска остальных скриптов)
cd /d "%~dp0"

:: Запускаем PowerShell-скрипт.
:: -NoProfile ускоряет запуск, -ExecutionPolicy Bypass снимает ограничения на выполнение.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "ffmpeg_hub.ps1"

:: Если скрипт завершился (или произошла ошибка), оставляем окно открытым до нажатия Enter
set /p _="Press Enter to close..."