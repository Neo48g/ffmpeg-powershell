#Requires -Version 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Host.UI.RawUI.WindowTitle = "FFmpeg Tools Hub"
$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
$ToolsDir = Join-Path $ScriptDir "tools"

# --- Управление глобальной конфигурацией ---
function Get-Config {
    if (Test-Path $ConfigFile) { return Get-Content $ConfigFile -Raw | ConvertFrom-Json }
    $def = @{ EnableLogs = $true; LogsFolder = (Join-Path $ScriptDir "logs") }
    $def | ConvertTo-Json | Out-File $ConfigFile -Encoding UTF8
    return $def
}
function Save-Config { param($Cfg) $Cfg | ConvertTo-Json | Out-File $ConfigFile -Encoding UTF8 -Force }
$global:Cfg = Get-Config

# --- Вспомогательные функции интерфейса ---
function Show-Banner {
    param([string]$Title)
    Clear-Host
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "========================================================`n" -ForegroundColor Cyan
}

# --- Управление локальным путём к инструментам ---
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

# --- Подробная информация о FFmpeg ---
function Show-FFmpegInfo {
    Show-Banner "FFMPEG DETAILED INFO"
    if (-not (Test-Command "ffmpeg")) { Write-Host "  [X] $('FFmpeg not found')" -ForegroundColor Red; Read-Host; return }
    
    Write-Host "  $('VERSION')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    try { Write-Host "  $(& ffmpeg -version 2>$null | Select-Object -First 1)" -ForegroundColor White } catch {}
    
    Write-Host "`n  $('KEY LIBRARIES & CODECS')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    
    $encodersOutput = ""; $filtersOutput = ""
    try { $encodersOutput = & ffmpeg -encoders 2>$null } catch {}
    try { $filtersOutput = & ffmpeg -filters 2>$null } catch {}
    
    $libs = @(
        @{ Name = "libx264"; Desc = "H.264 encoder"; Check = ($encodersOutput -match "libx264") }
        @{ Name = "libx265"; Desc = "H.265/HEVC encoder"; Check = ($encodersOutput -match "libx265") }
        @{ Name = "libsvtav1"; Desc = "AV1 encoder (SVT)"; Check = ($encodersOutput -match "libsvtav1") }
        @{ Name = "libvmaf"; Desc = "VMAF quality metric"; Check = ($filtersOutput -match "libvmaf") }
        @{ Name = "nvenc"; Desc = "NVIDIA hardware encoding"; Check = ($encodersOutput -match "nvenc") }
        @{ Name = "amf"; Desc = "AMD hardware encoding"; Check = ($encodersOutput -match "h264_amf|hevc_amf|av1_amf") }
        @{ Name = "qsv"; Desc = "Intel hardware encoding"; Check = ($encodersOutput -match "qsv") }
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

    Write-Host "`n  $('HARDWARE ENCODERS DETAIL')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    try {
        $hwCodecs = @("h264_nvenc", "hevc_nvenc", "av1_nvenc", "h264_amf", "hevc_amf", "av1_amf", "h264_qsv", "hevc_qsv", "av1_qsv")
        foreach ($c in $hwCodecs) {
            $found = $encodersOutput | Where-Object { $_ -match "\b$c\b" }
            if ($found) { Write-Host "  [OK] $c" -ForegroundColor Green }
            else { Write-Host "  [X]  $c" -ForegroundColor Red }
        }
    } catch {}
    
    Write-Host "`n  $('Press Enter to return...')" -ForegroundColor Gray
    Read-Host
}

# --- Управление зависимостями ---
function Show-DependenciesMenu {
    do {
        Show-Banner "DEPENDENCIES MANAGEMENT"
        
        $ffmpegExe = Get-ToolPath "ffmpeg"
        $ytdlpExe = Get-ToolPath "yt-dlp"
        $nodeExe = Get-ToolPath "node"

        $ffmpegStatus = if ($ffmpegExe) { "[OK] $(& $ffmpegExe -version 2>&1 | Select-Object -First 1)" } else { "[X] $('Not found')" }
        $ffmpegColor = if ($ffmpegExe) { "Green" } else { "Red" }
        
        $ytdlpStatus = if ($ytdlpExe) { "[OK] $(& $ytdlpExe --version 2>&1 | Select-Object -First 1)" } else { "[X] $('Not found')" }
        $ytdlpColor = if ($ytdlpExe) { "Green" } else { "Red" }
        
        $nodeStatus = if ($nodeExe) { "[OK] $(& $nodeExe -v 2>&1 | Select-Object -First 1)" } else { "[X] $('Not found')" }
        $nodeColor = if ($nodeExe) { "Green" } else { "Red" }

        Write-Host "  $('STATUS')" -ForegroundColor Yellow
        Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "  FFmpeg (Full GPL): " -NoNewline -ForegroundColor White; Write-Host $ffmpegStatus -ForegroundColor $ffmpegColor
        Write-Host "  yt-dlp:            " -NoNewline -ForegroundColor White; Write-Host $ytdlpStatus -ForegroundColor $ytdlpColor
        Write-Host "  Node.js (LTS):     " -NoNewline -ForegroundColor White; Write-Host $nodeStatus -ForegroundColor $nodeColor
        
        Write-Host "`n  $('ACTIONS')" -ForegroundColor Yellow
        Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "  [1] $('Install/Update FFmpeg (Full Build)')" -ForegroundColor White
        Write-Host "  [2] $('Install/Update yt-dlp')" -ForegroundColor White
        Write-Host "  [3] $('Install/Update Node.js (LTS)')" -ForegroundColor White
        Write-Host "  [4] $('View FFmpeg Detailed Info')" -ForegroundColor Cyan
        Write-Host "`n  [0] $('Back to Hub')" -ForegroundColor Red
        
             $choice = Read-Host "  Select action"
     switch ($choice) {
         '1' {
             $url = "https://github.com/BtbN/ffmpeg-builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
             $zipPath = Join-Path $env:TEMP "ffmpeg_full.zip"
             $tempDir = Join-Path $env:TEMP "ffmpeg_extract"
             $destParent = Join-Path $ToolsDir "ffmpeg"
             $destBin = Join-Path $destParent "bin"
             Write-Host "`n  $('Downloading FFmpeg Full GPL (with VMAF, NVENC, etc.)...')" -ForegroundColor Cyan
             try {
                 if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
                 if (Test-Path $destParent) { Remove-Item $destParent -Recurse -Force -ErrorAction SilentlyContinue }
                 $wc = New-Object System.Net.WebClient
                 $wc.DownloadFile($url, $zipPath)
                 Write-Host "  $('Extracting...')" -ForegroundColor Cyan
                 Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
                 $binFolder = Get-ChildItem -Path $tempDir -Recurse -Directory -Filter "bin" | Select-Object -First 1
                 if ($binFolder) {
                     New-Item -ItemType Directory -Path $destParent -Force | Out-Null
                     Move-Item -Path $binFolder.FullName -Destination $destBin -Force
                     Write-Host "  [OK] $('FFmpeg installed successfully!')" -ForegroundColor Green
                 } else {
                     Write-Host "  [X] $('Error: bin folder not found in archive')" -ForegroundColor Red
                 }
                 Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                 Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                 Update-LocalPath
             } catch { 
                 Write-Host "  [X] $('Error'): $_" -ForegroundColor Red 
             }
             Read-Host "  Press Enter to continue"
         }
         '2' {
             $url = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
             $destPath = Join-Path $ToolsDir "yt-dlp.exe"
             Write-Host "`n  $('Downloading yt-dlp...')" -ForegroundColor Cyan
             try {
                 if (Test-Path $destPath) { Remove-Item $destPath -Force }
                 Invoke-WebRequest -Uri $url -OutFile $destPath -UseBasicParsing
                 $fileSize = (Get-Item $destPath).Length
                 if ($fileSize -lt 1000000) {
                     Remove-Item $destPath -Force
                     throw ("Downloaded file is corrupted (HTML page?).")
                 }
                 Update-LocalPath
                 Write-Host "  [OK] $('yt-dlp installed successfully!')" -ForegroundColor Green
             } catch { Write-Host "  [X] $('Error'): $_" -ForegroundColor Red }
             Read-Host "  Press Enter to continue"
         }
         '3' {
             $nodeVersion = "v22.11.0"
             $url = "https://nodejs.org/dist/$nodeVersion/node-$nodeVersion-win-x64.zip"
             $zipPath = Join-Path $env:TEMP "node_lts.zip"
             $tempDir = Join-Path $env:TEMP "node_extract"
             $destParent = Join-Path $ToolsDir "node"
             Write-Host "`n  $('Downloading Node.js LTS...')" -ForegroundColor Cyan
             try {
                 if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
                 if (Test-Path $destParent) { Remove-Item $destParent -Recurse -Force -ErrorAction SilentlyContinue }
                 $wc = New-Object System.Net.WebClient
                 $wc.DownloadFile($url, $zipPath)
                 Write-Host "  $('Extracting...')" -ForegroundColor Cyan
                 Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
                 $extractedFolder = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
                 if ($extractedFolder) {
                     Move-Item -Path $extractedFolder.FullName -Destination $destParent -Force
                     Write-Host "  [OK] $('Node.js installed successfully!')" -ForegroundColor Green
                 } else {
                     Write-Host "  [X] $('Error: Node folder not found in archive')" -ForegroundColor Red
                 }
                 Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                 Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                 Update-LocalPath
             } catch { 
                 Write-Host "  [X] $('Error'): $_" -ForegroundColor Red 
             }
             Read-Host "  Press Enter to continue"
         }
         '4' { Show-FFmpegInfo }
         
         # ИСПРАВЛЕНИЕ: используется return вместо break.
         # return немедленно выходит из Show-DependenciesMenu и возвращает управление в главный цикл Hub.
         '0' { return } 
         
         default { Write-Host "`n  [!] $('Invalid choice')" -ForegroundColor Red; Start-Sleep 1 }
     }
    } while ($true)
}

# --- Глобальные настройки ---
function Show-SettingsMenu {
    Show-Banner "GLOBAL SETTINGS"
    Write-Host "  [1] $('Logging'): $(if ($global:Cfg.EnableLogs) { '[ON]' } else { '[OFF]' })" -ForegroundColor White
    Write-Host "  [2] $('Open Logs Folder')" -ForegroundColor White
    Write-Host "  [3] $('Clear All Logs')" -ForegroundColor White
    Write-Host "`n  [0] $('Back to Hub')" -ForegroundColor Gray
    $choice = Read-Host "  Choice"
    switch ($choice) {
        '1' { $global:Cfg.EnableLogs = -not $global:Cfg.EnableLogs; Save-Config $global:Cfg }
        '2' { if (-not (Test-Path $global:Cfg.LogsFolder)) { New-Item -ItemType Directory -Path $global:Cfg.LogsFolder | Out-Null }; Start-Process explorer.exe $global:Cfg.LogsFolder }
        '3' { if (Test-Path $global:Cfg.LogsFolder) { Remove-Item "$($global:Cfg.LogsFolder)\*" -Force -Recurse -ErrorAction SilentlyContinue; Write-Host "  $('Logs cleared.')" -ForegroundColor Green } }
    }
}

# --- Руководство / Справка ---
function Show-Guide {
    Show-Banner "HELP & GUIDE"
    Write-Host "  $('BASIC SETTINGS')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $('Quality (CRF/CQ):')" -ForegroundColor White
    Write-Host "    $('Lower values = better quality, larger files.')" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  $('HARDWARE ACCELERATION')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "    $('GPU encoding is 5-20x faster than CPU with good quality.')" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  $('VMAF & AUTO CRF')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "    $('VMAF measures perceived video quality (0-100). 90+ is excellent.')" -ForegroundColor Gray
    Write-Host "`n  $('Press Enter to return to Hub...')" -ForegroundColor White
    Read-Host
}

# --- Главный цикл Hub ---
$scripts = @{
    '1' = "compress_video.ps1"
    '2' = "convert-media.ps1"
    '3' = "trim-video.ps1"
    '4' = "yt-dlp-menu.ps1"
}

do {
    Show-Banner "FFmpeg Tools Hub"
    Write-Host "  [1] $('Video Compression')" -ForegroundColor White
    Write-Host "  [2] $('Media Conversion')" -ForegroundColor White
    Write-Host "  [3] $('Video Trimming')" -ForegroundColor White
    Write-Host "  [4] $('Download (yt-dlp)')" -ForegroundColor White
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [5] $('Manage Dependencies')" -ForegroundColor Cyan
    Write-Host "  [6] $('Global Settings')" -ForegroundColor Cyan
    Write-Host "  [7] $('Help & Guide')" -ForegroundColor Cyan
    Write-Host "  [0] $('Exit')" -ForegroundColor Red
    
    $choice = Read-Host "`n  $('Enter choice')"
    
    if ($scripts.ContainsKey($choice)) {
        $path = Join-Path $ScriptDir $scripts[$choice]
        if (Test-Path $path) { & $path } 
        else { Write-Host "`n  [!] $('Script not found'): $path" -ForegroundColor Red; Start-Sleep 2 }
    } else {
        switch ($choice) {
            '5' { Show-DependenciesMenu }
            '6' { Show-SettingsMenu }
            '7' { Show-Guide }
            '0' { exit }
            default { Write-Host "`n  [!] $('Invalid choice')" -ForegroundColor Red; Start-Sleep 1 }
        }
    }
} while ($true)