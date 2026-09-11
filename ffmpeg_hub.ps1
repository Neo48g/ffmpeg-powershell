#Requires -Version 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Host.UI.RawUI.WindowTitle = "FFmpeg Tools Hub"
$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
$ToolsDir = Join-Path $ScriptDir "tools"

# --- Global Config Management ---
function Get-Config {
    if (Test-Path $ConfigFile) { return Get-Content $ConfigFile -Raw | ConvertFrom-Json }
    $def = @{ Language = "EN"; EnableLogs = $true; LogsFolder = (Join-Path $ScriptDir "logs") }
    $def | ConvertTo-Json | Out-File $ConfigFile -Encoding UTF8
    return $def
}
function Save-Config { param($Cfg) $Cfg | ConvertTo-Json | Out-File $ConfigFile -Encoding UTF8 -Force }
$global:Cfg = Get-Config
function L($en, $ru) { if ($global:Cfg.Language -eq 'RU') { return $ru } return $en }

# --- UI Helpers ---
function Show-Banner {
    param([string]$Title)
    Clear-Host
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "========================================================`n" -ForegroundColor Cyan
}

# --- Local Tools Path Management ---
function Update-LocalPath {
    if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }
    $ffmpegBin = Join-Path $ToolsDir "ffmpeg\bin"
    if ((Test-Path $ffmpegBin) -and ($env:Path -notlike "*$ffmpegBin*")) { $env:Path = "$ffmpegBin;$env:Path" }
    if ((Test-Path (Join-Path $ToolsDir "yt-dlp.exe")) -and ($env:Path -notlike "*$ToolsDir*")) { $env:Path = "$ToolsDir;$env:Path" }
    $nodeBin = Join-Path $ToolsDir "node"
    if ((Test-Path $nodeBin) -and ($env:Path -notlike "*$nodeBin*")) { $env:Path = "$nodeBin;$env:Path" }
}
Update-LocalPath

function Get-ToolPath {
    param([string]$ToolName)
    $localPath = Join-Path $ToolsDir "$ToolName.exe"
    if (Test-Path $localPath) { return $localPath }

    try {
        $cmd = Get-Command $ToolName -ErrorAction Stop
        return $cmd.Source
    } catch {
        return $null
    }
}

# --- FFmpeg Detailed Info ---
function Show-FFmpegInfo {
    Show-Banner (L "FFMPEG DETAILED INFO" "ДЕТАЛЬНАЯ ИНФОРМАЦИЯ О FFMPEG")
    if (-not (Test-Command "ffmpeg")) { Write-Host "  [X] $(L 'FFmpeg not found' 'FFmpeg не найден')" -ForegroundColor Red; Read-Host; return }
    
    Write-Host "  $(L 'VERSION' 'ВЕРСИЯ')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    try { Write-Host "  $(& ffmpeg -version 2>$null | Select-Object -First 1)" -ForegroundColor White } catch {}
    
    Write-Host "`n  $(L 'KEY LIBRARIES & CODECS' 'КЛЮЧЕВЫЕ БИБЛИОТЕКИ И КОДЕКИ')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    
    $encodersOutput = ""; $filtersOutput = ""
    try { $encodersOutput = & ffmpeg -encoders 2>$null } catch {}
    try { $filtersOutput = & ffmpeg -filters 2>$null } catch {}
    
    $libs = @(
        @{ Name = "libx264"; Desc = L "H.264 encoder" "Кодировщик H.264"; Check = ($encodersOutput -match "libx264") }
        @{ Name = "libx265"; Desc = L "H.265/HEVC encoder" "Кодировщик H.265/HEVC"; Check = ($encodersOutput -match "libx265") }
        @{ Name = "libsvtav1"; Desc = L "AV1 encoder (SVT)" "Кодировщик AV1 (SVT)"; Check = ($encodersOutput -match "libsvtav1") }
        @{ Name = "libvmaf"; Desc = L "VMAF quality metric" "Метрика качества VMAF"; Check = ($filtersOutput -match "libvmaf") }
        @{ Name = "nvenc"; Desc = L "NVIDIA hardware encoding" "Аппаратное кодирование NVIDIA"; Check = ($encodersOutput -match "nvenc") }
        @{ Name = "amf"; Desc = L "AMD hardware encoding" "Аппаратное кодирование AMD"; Check = ($encodersOutput -match "h264_amf|hevc_amf|av1_amf") }
        @{ Name = "qsv"; Desc = L "Intel hardware encoding" "Аппаратное кодирование Intel"; Check = ($encodersOutput -match "qsv") }
    )

    foreach ($lib in $libs) {
        if ($lib.Check) {
            Write-Host "  [OK] $($lib.Name)" -NoNewline -ForegroundColor Green
            Write-Host " - $($lib.Desc)" -ForegroundColor White
        } else {
            Write-Host "  [X]  $($lib.Name)" -NoNewline -ForegroundColor Red
            Write-Host " - $($lib.Desc)" -ForegroundColor DarkGray
        }
    }

    Write-Host "`n  $(L 'HARDWARE ENCODERS DETAIL' 'ДЕТАЛИ АППАРАТНЫХ КОДЕКОВ')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    try {
        $hwCodecs = @("h264_nvenc", "hevc_nvenc", "av1_nvenc", "h264_amf", "hevc_amf", "av1_amf", "h264_qsv", "hevc_qsv", "av1_qsv")
        foreach ($c in $hwCodecs) {
            $found = $encodersOutput | Where-Object { $_ -match "\b$c\b" }
            if ($found) { Write-Host "  [OK] $c" -ForegroundColor Green }
            else { Write-Host "  [X]  $c" -ForegroundColor Red }
        }
    } catch {}
    
    Write-Host "`n  $(L 'Press Enter to return...' 'Нажмите Enter для возврата...')" -ForegroundColor Gray
    Read-Host
}

# --- Dependency Management ---
function Show-DependenciesMenu {
    do {
        Show-Banner (L "DEPENDENCIES MANAGEMENT" "УПРАВЛЕНИЕ ЗАВИСИМОСТЯМИ")
        
        $ffmpegExe = Get-ToolPath "ffmpeg"
        $ytdlpExe = Get-ToolPath "yt-dlp"
        $nodeExe = Get-ToolPath "node"

        $ffmpegStatus = if ($ffmpegExe) { "[OK] $(& $ffmpegExe -version 2>&1 | Select-Object -First 1)" } else { "[X] $(L 'Not found' 'Не найден')" }
        $ffmpegColor = if ($ffmpegExe) { "Green" } else { "Red" }
        
        $ytdlpStatus = if ($ytdlpExe) { "[OK] $(& $ytdlpExe --version 2>&1 | Select-Object -First 1)" } else { "[X] $(L 'Not found' 'Не найден')" }
        $ytdlpColor = if ($ytdlpExe) { "Green" } else { "Red" }
        
        $nodeStatus = if ($nodeExe) { "[OK] $(& $nodeExe -v 2>&1 | Select-Object -First 1)" } else { "[X] $(L 'Not found' 'Не найден')" }
        $nodeColor = if ($nodeExe) { "Green" } else { "Red" }

        Write-Host "  $(L 'STATUS' 'СТАТУС')" -ForegroundColor Yellow
        Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "  FFmpeg (Full GPL): " -NoNewline -ForegroundColor White; Write-Host $ffmpegStatus -ForegroundColor $ffmpegColor
        Write-Host "  yt-dlp:            " -NoNewline -ForegroundColor White; Write-Host $ytdlpStatus -ForegroundColor $ytdlpColor
        Write-Host "  Node.js (LTS):     " -NoNewline -ForegroundColor White; Write-Host $nodeStatus -ForegroundColor $nodeColor
        
        Write-Host "`n  $(L 'ACTIONS' 'ДЕЙСТВИЯ')" -ForegroundColor Yellow
        Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "  [1] $(L 'Install/Update FFmpeg (Full Build)' 'Установить/Обновить FFmpeg (Full Build)')" -ForegroundColor White
        Write-Host "  [2] $(L 'Install/Update yt-dlp' 'Установить/Обновить yt-dlp')" -ForegroundColor White
        Write-Host "  [3] $(L 'Install/Update Node.js (LTS)' 'Установить/Обновить Node.js (LTS)')" -ForegroundColor White
        Write-Host "  [4] $(L 'View FFmpeg Detailed Info' 'Посмотреть детальную информацию FFmpeg')" -ForegroundColor Cyan
        Write-Host "`n  [0] $(L 'Back to Hub' 'Вернуться в Хаб')" -ForegroundColor Red
        
             $choice = Read-Host (L "  Select action" "  Выберите действие")
     switch ($choice) {
         '1' {
             $url = "https://github.com/BtbN/ffmpeg-builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
             $zipPath = Join-Path $env:TEMP "ffmpeg_full.zip"
             $tempDir = Join-Path $env:TEMP "ffmpeg_extract"
             $destParent = Join-Path $ToolsDir "ffmpeg"
             $destBin = Join-Path $destParent "bin"
             Write-Host "`n  $(L 'Downloading FFmpeg Full GPL (with VMAF, NVENC, etc.)...' 'Скачивание FFmpeg Full GPL (с VMAF, NVENC и т.д.)...')" -ForegroundColor Cyan
             try {
                 if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
                 if (Test-Path $destParent) { Remove-Item $destParent -Recurse -Force -ErrorAction SilentlyContinue }
                 $wc = New-Object System.Net.WebClient
                 $wc.DownloadFile($url, $zipPath)
                 Write-Host "  $(L 'Extracting...' 'Извлечение...')" -ForegroundColor Cyan
                 Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
                 $binFolder = Get-ChildItem -Path $tempDir -Recurse -Directory -Filter "bin" | Select-Object -First 1
                 if ($binFolder) {
                     New-Item -ItemType Directory -Path $destParent -Force | Out-Null
                     Move-Item -Path $binFolder.FullName -Destination $destBin -Force
                     Write-Host "  [OK] $(L 'FFmpeg installed successfully!' 'FFmpeg успешно установлен!')" -ForegroundColor Green
                 } else {
                     Write-Host "  [X] $(L 'Error: bin folder not found in archive' 'Ошибка: папка bin не найдена в архиве')" -ForegroundColor Red
                 }
                 Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                 Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                 Update-LocalPath
             } catch { 
                 Write-Host "  [X] $(L 'Error' 'Ошибка'): $_" -ForegroundColor Red 
             }
             Read-Host (L "  Press Enter to continue" "  Нажмите Enter для продолжения")
         }
         '2' {
             $url = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
             $destPath = Join-Path $ToolsDir "yt-dlp.exe"
             Write-Host "`n  $(L 'Downloading yt-dlp...' 'Скачивание yt-dlp...')" -ForegroundColor Cyan
             try {
                 if (Test-Path $destPath) { Remove-Item $destPath -Force }
                 Invoke-WebRequest -Uri $url -OutFile $destPath -UseBasicParsing
                 $fileSize = (Get-Item $destPath).Length
                 if ($fileSize -lt 1000000) {
                     Remove-Item $destPath -Force
                     throw (L "Downloaded file is corrupted (HTML page?)." "Скачанный файл поврежден (HTML страница?).")
                 }
                 Update-LocalPath
                 Write-Host "  [OK] $(L 'yt-dlp installed successfully!' 'yt-dlp успешно установлен!')" -ForegroundColor Green
             } catch { Write-Host "  [X] $(L 'Error' 'Ошибка'): $_" -ForegroundColor Red }
             Read-Host (L "  Press Enter to continue" "  Нажмите Enter для продолжения")
         }
         '3' {
             $nodeVersion = "v22.11.0"
             $url = "https://nodejs.org/dist/$nodeVersion/node-$nodeVersion-win-x64.zip"
             $zipPath = Join-Path $env:TEMP "node_lts.zip"
             $tempDir = Join-Path $env:TEMP "node_extract"
             $destParent = Join-Path $ToolsDir "node"
             Write-Host "`n  $(L 'Downloading Node.js LTS...' 'Скачивание Node.js LTS...')" -ForegroundColor Cyan
             try {
                 if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
                 if (Test-Path $destParent) { Remove-Item $destParent -Recurse -Force -ErrorAction SilentlyContinue }
                 $wc = New-Object System.Net.WebClient
                 $wc.DownloadFile($url, $zipPath)
                 Write-Host "  $(L 'Extracting...' 'Извлечение...')" -ForegroundColor Cyan
                 Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
                 $extractedFolder = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
                 if ($extractedFolder) {
                     Move-Item -Path $extractedFolder.FullName -Destination $destParent -Force
                     Write-Host "  [OK] $(L 'Node.js installed successfully!' 'Node.js успешно установлен!')" -ForegroundColor Green
                 } else {
                     Write-Host "  [X] $(L 'Error: Node folder not found in archive' 'Ошибка: Папка Node не найдена в архиве')" -ForegroundColor Red
                 }
                 Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                 Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                 Update-LocalPath
             } catch { 
                 Write-Host "  [X] $(L 'Error' 'Ошибка'): $_" -ForegroundColor Red 
             }
             Read-Host (L "  Press Enter to continue" "  Нажмите Enter для продолжения")
         }
         '4' { Show-FFmpegInfo }
         
         # ИСПРАВЛЕНИЕ: return вместо break. 
         # return мгновенно завершает функцию Show-DependenciesMenu и возвращает управление в главный цикл Хаба.
         '0' { return } 
         
         default { Write-Host "`n  [!] $(L 'Invalid choice' 'Неверный выбор')" -ForegroundColor Red; Start-Sleep 1 }
     }
    } while ($true)
}

# --- Global Settings ---
function Show-SettingsMenu {
    Show-Banner (L "GLOBAL SETTINGS" "ГЛОБАЛЬНЫЕ НАСТРОЙКИ")
    Write-Host "  [1] $(L 'Language' 'Язык'): $($global:Cfg.Language)" -ForegroundColor White
    Write-Host "  [2] $(L 'Logging' 'Логирование'): $(if ($global:Cfg.EnableLogs) { '[ON]' } else { '[OFF]' })" -ForegroundColor White
    Write-Host "  [3] $(L 'Open Logs Folder' 'Открыть папку логов')" -ForegroundColor White
    Write-Host "  [4] $(L 'Clear All Logs' 'Очистить все логи')" -ForegroundColor White
    Write-Host "`n  [0] $(L 'Back to Hub' 'Вернуться в Хаб')" -ForegroundColor Gray
    $choice = Read-Host (L "  Choice" "  Выбор")
    switch ($choice) {
        '1' { $global:Cfg.Language = if ($global:Cfg.Language -eq 'EN') { 'RU' } else { 'EN' }; Save-Config $global:Cfg }
        '2' { $global:Cfg.EnableLogs = -not $global:Cfg.EnableLogs; Save-Config $global:Cfg }
        '3' { if (-not (Test-Path $global:Cfg.LogsFolder)) { New-Item -ItemType Directory -Path $global:Cfg.LogsFolder | Out-Null }; Start-Process explorer.exe $global:Cfg.LogsFolder }
        '4' { if (Test-Path $global:Cfg.LogsFolder) { Remove-Item "$($global:Cfg.LogsFolder)\*" -Force -Recurse -ErrorAction SilentlyContinue; Write-Host "  $(L 'Logs cleared.' 'Логи очищены.')" -ForegroundColor Green } }
    }
}

# --- Guide / Help ---
function Show-Guide {
    Show-Banner (L "HELP & GUIDE" "СПРАВКА И РУКОВОДСТВО")
    Write-Host "  $(L 'BASIC SETTINGS' 'ОСНОВНЫЕ НАСТРОЙКИ')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $(L 'Quality (CRF/CQ):' 'Качество (CRF/CQ):')" -ForegroundColor White
    Write-Host "    $(L 'Lower values = better quality, larger files.' 'Меньшие значения = лучшее качество, большие файлы.')" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  $(L 'HARDWARE ACCELERATION' 'АППАРАТНОЕ УСКОРЕНИЕ')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "    $(L 'GPU encoding is 5-20x faster than CPU with good quality.' 'Кодирование на GPU в 5-20 раз быстрее CPU с хорошим качеством.')" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  $(L 'VMAF & AUTO CRF' 'VMAF И АВТО CRF')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "    $(L 'VMAF measures perceived video quality (0-100). 90+ is excellent.' 'VMAF измеряет воспринимаемое качество видео (0-100). 90+ это отлично.')" -ForegroundColor Gray
    Write-Host "`n  $(L 'Press Enter to return to Hub...' 'Нажмите Enter для возврата в Хаб...')" -ForegroundColor White
    Read-Host
}

# --- Main Hub Loop ---
$scripts = @{
    '1' = "compress_video.ps1"
    '2' = "convert-media.ps1"
    '3' = "trim-video.ps1"
    '4' = "yt-dlp-menu.ps1"
}

do {
    Show-Banner (L "FFmpeg Tools Hub" "Хаб Инструментов FFmpeg")
    Write-Host "  [1] $(L 'Video Compression' 'Сжатие видео')" -ForegroundColor White
    Write-Host "  [2] $(L 'Media Conversion' 'Конвертация медиа')" -ForegroundColor White
    Write-Host "  [3] $(L 'Video Trimming' 'Обрезка видео')" -ForegroundColor White
    Write-Host "  [4] $(L 'Download (yt-dlp)' 'Скачивание (yt-dlp)')" -ForegroundColor White
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [5] $(L 'Manage Dependencies' 'Управление зависимостями')" -ForegroundColor Cyan
    Write-Host "  [6] $(L 'Global Settings' 'Глобальные настройки')" -ForegroundColor Cyan
    Write-Host "  [7] $(L 'Help & Guide' 'Справка и руководство')" -ForegroundColor Cyan
    Write-Host "  [0] $(L 'Exit' 'Выход')" -ForegroundColor Red
    
    $choice = Read-Host "`n  $(L 'Enter choice' 'Введите номер')"
    
    if ($scripts.ContainsKey($choice)) {
        $path = Join-Path $ScriptDir $scripts[$choice]
        if (Test-Path $path) { & $path } 
        else { Write-Host "`n  [!] $(L 'Script not found' 'Скрипт не найден'): $path" -ForegroundColor Red; Start-Sleep 2 }
    } else {
        switch ($choice) {
            '5' { Show-DependenciesMenu }
            '6' { Show-SettingsMenu }
            '7' { Show-Guide }
            '0' { exit }
            default { Write-Host "`n  [!] $(L 'Invalid choice' 'Неверный выбор')" -ForegroundColor Red; Start-Sleep 1 }
        }
    }
} while ($true)