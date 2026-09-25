@echo off

:: Меняем заголовок окна
title FFmpeg Tools Hub Launcher

:: Переходим в директорию, где лежит этот bat-файл (важно для поиска остальных скриптов)
cd /d "%~dp0"

:: Запускаем PowerShell скрипт. 
:: -NoProfile ускоряет запуск, -ExecutionPolicy Bypass снимает запреты на выполнение.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "ffmpeg_hub.ps1"

:: Если скрипт завершился (или произошла ошибка), окно не закроется мгновенно
pause