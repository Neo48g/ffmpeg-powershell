#Requires -Version 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Host.UI.RawUI.WindowTitle = "FFmpeg Tools Hub"
$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
$ToolsDir = Join-Path $ScriptDir "tools"

# --- Информация о программе и автоапдейт ---
# Текущая версия программы (при успешном автоапдейте обновляется в global_config.json)
$global:HubDefaultVersion = "1.0.0"
$global:HubRepo        = "Neo48g/ffmpeg-powershell"  # GitHub-репозиторий для проверки обновлений (последний релиз)
$global:HubUpdateState = "unknown" # last / none / error / skipped (для повторных проверок в рамках сессии)

# --- Управление глобальной конфигурацией ---
function Get-Config {
    if (Test-Path $ConfigFile) { return Get-Content $ConfigFile -Raw | ConvertFrom-Json }
    # Создание логов выключено по умолчанию; все логи сохраняются в папку logs
    # Автоапдейт включен по умолчанию (AutoUpdate = $true); отключить можно в настройках [6]
    $def = @{ EnableLogs = $false; LogsFolder = (Join-Path $ScriptDir "logs"); AutoUpdate = $true }
    $def | ConvertTo-Json | Out-File $ConfigFile -Encoding UTF8
    return $def
}
function Save-Config { param($Cfg) $Cfg | ConvertTo-Json | Out-File $ConfigFile -Encoding UTF8 -Force }
$global:Cfg = Get-Config
if (-not $global:Cfg.PSObject.Properties['LogsFolder']) {
    $global:Cfg | Add-Member -NotePropertyName LogsFolder -NotePropertyValue (Join-Path $ScriptDir "logs")
}
if (-not $global:Cfg.PSObject.Properties['EnableLogs']) {
    # По умолчанию создание логов выключено
    $global:Cfg | Add-Member -NotePropertyName EnableLogs -NotePropertyValue $false
}
if (-not $global:Cfg.PSObject.Properties['AutoUpdate']) {
    # По умолчанию автоапдейт включен
    $global:Cfg | Add-Member -NotePropertyName AutoUpdate -NotePropertyValue $true
}
$global:HubVersion = if ($global:Cfg.PSObject.Properties['HubVersion'] -and $global:Cfg.HubVersion) { [string]$global:Cfg.HubVersion } else { $global:HubDefaultVersion }

# --- Вспомогательные функции интерфейса ---
function Show-Banner {
    param([string]$Title)
    Clear-Host
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "========================================================`n" -ForegroundColor Cyan
}

# --- Управление путями к локальным инструментам ---
function Update-LocalPath {
    if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }
    $ffmpegBin = Join-Path $ToolsDir "ffmpeg\bin"
    if ((Test-Path $ffmpegBin) -and ($env:Path -notlike "*$ffmpegBin*")) { $env:Path = "$ffmpegBin;$env:Path" }
    if ((Test-Path (Join-Path $ToolsDir "yt-dlp.exe")) -and ($env:Path -notlike "*$ToolsDir*")) { $env:Path = "$ToolsDir;$env:Path" }
    $nodeBin = Join-Path $ToolsDir "node"
    if ((Test-Path $nodeBin) -and ($env:Path -notlike "*$nodeBin*")) { $env:Path = "$nodeBin;$env:Path" }
}
Update-LocalPath

# --- Автоапдейт программы ---
function Get-LatestHubRelease {
    # Возвращает объект с полями Version, ZipUrl и ArchiveName последнего релиза (или $null)
    try {
        $api = "https://api.github.com/repos/$global:HubRepo/releases/latest"
        $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 10 -Headers @{ 'User-Agent' = 'FFmpegToolsHub' }
        if (-not $rel -or -not $rel.tag_name) { return $null }
        $ver = $rel.tag_name -replace '^v', ''
        # Приоритет: .zip-архивы, затем другие поддерживаемые архивы (.rar/.7z), затем исходники (Source code / tar.gz)
        $asset = $rel.assets | Where-Object { $_.name -match '(?i)\.zip$' } | Select-Object -First 1
        if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -match '(?i)\.(rar|7z)$' } | Select-Object -First 1 }
        if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -match '(?i)\.tar\.gz$|Source' } | Select-Object -First 1 }
        return [pscustomobject]@{ Version = $ver; ZipUrl = if ($asset) { $asset.browser_download_url } else { $null }; ArchiveName = if ($asset) { $asset.name } else { $null }; HtmlUrl = $rel.html_url }
    } catch { return $null }
}

function Expand-HubArchive {
    param([string]$ArchivePath, [string]$Destination)
    # Распаковывает zip штатно; rar/7z — через WinRAR или 7-Zip (если установлены); tar.gz — через bsdtar/tar
    if ($ArchivePath -match '(?i)\.zip$') {
        Expand-Archive -Path $ArchivePath -DestinationPath $Destination -Force
        return
    }
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $extractors = @(
        "$env:ProgramFiles\WinRAR\WinRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe",
        "$env:ProgramFiles\WinRAR\Rar.exe",
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($exe in $extractors) {
        & $exe x "-o+" "-y" $ArchivePath "$Destination\" 2>$null | Out-Null
        if ((Get-ChildItem -Path $Destination -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) { return }
    }
    if ($ArchivePath -match '(?i)\.tar\.gz$') {
        tar -xzf $ArchivePath -C $Destination
        if ((Get-ChildItem -Path $Destination -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) { return }
    }
    throw "Cannot extract '$(Split-Path $ArchivePath -Leaf)': no suitable extractor found (need WinRAR or 7-Zip for RAR/7Z archives)."
}

function Install-HubUpdate {
    param([string]$ArchiveUrl, [string]$NewVersion)
    # Скачивает архив последнего релиза с GitHub (zip/rar/7z/tar.gz), бэкапит текущие .ps1/.bat и заменяет их файлами из архива
    $ext = if ($ArchiveUrl -match '(?i)\.(rar|7z|zip|tar\.gz)(\?|$)') { $Matches[1] } else { 'zip' }
    $arcPath  = Join-Path $env:TEMP "hub_update.$ext"
    $tempDir  = Join-Path $env:TEMP "hub_update_extract"
    $backupDir = Join-Path $ScriptDir "backup_v$global:HubVersion"
    try {
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "  $('Downloading update...')`n" -ForegroundColor Cyan
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($ArchiveUrl, $arcPath)
        Expand-HubArchive -ArchivePath $arcPath -Destination $tempDir

        # Корень архива: если все файлы лежат в одной папке верхнего уровня (например "<repo>-<sha>" у GitHub Source code)
        $srcRoot = Get-Item $tempDir
        $topDirs = @(Get-ChildItem -Path $tempDir -Directory)
        if ((@(Get-ChildItem -Path $tempDir -File).Count -eq 0) -and $topDirs.Count -eq 1) { $srcRoot = $topDirs[0] }

        $files = @(Get-ChildItem -Path $srcRoot.FullName -File | Where-Object { $_.Extension -in '.ps1', '.bat' })
        if ($files.Count -eq 0) { throw "No update files found in archive." }

        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        foreach ($f in $files) {
            $target = Join-Path $ScriptDir $f.Name
            if (Test-Path $target) { Copy-Item $target -Destination $backupDir -Force }
        }
        foreach ($f in $files) {
            Copy-Item $f.FullName -Destination (Join-Path $ScriptDir $f.Name) -Force
        }
        Remove-Item $arcPath -Force -ErrorAction SilentlyContinue
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        # Фиксируем новую версию в конфигурации (AutoUpdate/настройки сохраняются)
        try {
            $cfgNow = Get-Config
            if ($cfgNow.PSObject.Properties['HubVersion']) { $cfgNow.HubVersion = $NewVersion }
            else { $cfgNow | Add-Member -NotePropertyName HubVersion -NotePropertyValue $NewVersion }
            Save-Config $cfgNow
            $global:Cfg = $cfgNow
        } catch {}
        Write-Host "  [OK] $('Update installed to version') $NewVersion" -ForegroundColor Green
        Write-Host "  $('Backup of previous files saved to'): $backupDir" -ForegroundColor Gray
        return $true
    } catch {
        Write-Host "  [X] $('Update failed'): $_" -ForegroundColor Red
        Write-Host "  $('Your current version was not modified.')" -ForegroundColor Gray
        return $false
    }
}

function Invoke-HubAutoUpdate {
    param([switch]$Manual)
    # Если автоапдейт выключен в настройках и запуск не ручной — пропускаем проверку
    if (-not $Manual -and -not $global:Cfg.AutoUpdate) { return }
    # В рамках одной сессии повторные автоматические проверки не выполняем
    if (-not $Manual -and $global:HubUpdateState -ne 'unknown') { return }

    Show-Banner "AUTO-UPDATE CHECK"
    Write-Host "  $('Current version'): $global:HubVersion" -ForegroundColor White
    Write-Host "  $('Checking for updates...')`n" -ForegroundColor Cyan
    $latest = Get-LatestHubRelease
    if (-not $latest) {
        $global:HubUpdateState = 'error'
        Write-Host "`n  [!] $('Unable to check for updates (no internet or repository unavailable). Continuing with the current version.')" -ForegroundColor Yellow
        if ($Manual) { Read-Host "  Press Enter to continue" }
        else { Start-Sleep 2 }
        return
    }
    try {
        $cur = [version]$global:HubVersion
        $new = [version]($latest.Version -replace '^v','')
    } catch {
        $global:HubUpdateState = 'error'
        Write-Host "  [!] $('Cannot compare versions'): $($latest.Version)" -ForegroundColor Yellow
        if ($Manual) { Read-Host "  Press Enter to continue" }
        return
    }

    if ($new -le $cur) {
        $global:HubUpdateState = 'last'
        Write-Host "  [OK] $('You are using the latest version') ($global:HubVersion)`n" -ForegroundColor Green
        if ($Manual) { Read-Host "  Press Enter to continue" }
        return
    }

    $global:HubUpdateState = 'none'
    Write-Host "  $('A new version is available'): $global:HubVersion -> $($latest.Version)" -ForegroundColor Yellow
    Write-Host "  [Y] $('Install update now')  [N] $('Skip this session')  [D] $('Download later from Releases page')" -ForegroundColor White
    $ans = ""
    try { $ans = (Read-Host "  Choice").Trim().ToUpper() } catch { $ans = "N" }
    switch ($ans) {
        'Y' {
            if ($latest.ZipUrl) {
                Write-Host "  $('Update archive'): $($latest.ArchiveName)" -ForegroundColor Gray
                if (Install-HubUpdate -ArchiveUrl $latest.ZipUrl -NewVersion $latest.Version) {
                    Write-Host "`n  $('The program will be restarted with the new version...')" -ForegroundColor Cyan
                    $hubPath = Join-Path $ScriptDir "ffmpeg_hub.ps1"
                    $batPath = Join-Path $ScriptDir "RUN_HUB.bat"
                    if (Test-Path $batPath) { Start-Process cmd.exe -ArgumentList "/c","`"$batPath`"" }
                    elseif (Test-Path $hubPath) { Start-Process powershell.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$hubPath`"" }
                    exit 0
                }
            } else {
                Write-Host "  [!] $('No update archive found in release. Opening Releases page in browser...')" -ForegroundColor Yellow
                Start-Process $latest.HtmlUrl
            }
        }
        'D' { if ($latest.HtmlUrl) { Start-Process $latest.HtmlUrl } }
        default { Write-Host "  $('Update skipped for this session.')" -ForegroundColor Gray }
    }
    if ($Manual) { Start-Sleep 1 } else { Start-Sleep 2 }
}

# Проверка обновлений при запуске (если автоапдейт включен в настройках)
Invoke-HubAutoUpdate

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
function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Show-FFmpegInfo {
    Show-Banner "FFMPEG DETAILED INFO"
    $ffPath = Get-ToolPath "ffmpeg"
    if (-not $ffPath) { Write-Host "  [X] $('FFmpeg not found')" -ForegroundColor Red; Read-Host; return }

    Write-Host "  $('VERSION')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    try { Write-Host "  $(& $ffPath -version 2>$null | Select-Object -First 1)" -ForegroundColor White } catch {}

    try { $prevEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    $utf8Session = $false
    try {
        & chcp.com 65001 | Out-Null
        if ($LASTEXITCODE -eq 0) { $utf8Session = $true }
    } catch {}

    Write-Host "`n  $('KEY LIBRARIES & CODECS')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan

    $encodersOutput = ""; $filtersOutput = ""
    try { $encodersOutput = & $ffPath -hide_banner -encoders 2>$null } catch {}
    try { $filtersOutput = & $ffPath -hide_banner -filters 2>$null } catch {}

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
    try {
        if ($utf8Session) { & chcp.com $prevEncoding.CodePage | Out-Null }
        [Console]::OutputEncoding = $prevEncoding
    } catch {}
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
        Write-Host "  [5] $('Check for Hub Updates (manual)')" -ForegroundColor Cyan
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
         '5' { Invoke-HubAutoUpdate -Manual }
         '0' { return }

         default { Write-Host "`n  [!] $('Invalid choice')" -ForegroundColor Red; Start-Sleep 1 }
     }
    } while ($true)
}

# --- Проверка зависимостей для процесса ---=
function Get-MissingDependencies {
    param([string]$Choice)
    $missing = @()
    switch ($Choice) {
        { $_ -in '1','2','3' } { if (-not (Get-ToolPath "ffmpeg")) { $missing += "FFmpeg" } }
        '4' {
            if (-not (Get-ToolPath "yt-dlp"))  { $missing += "yt-dlp" }
            if (-not (Get-ToolPath "ffmpeg")) { $missing += "FFmpeg" }
        }
    }
    return $missing
}

# Предупреждение при выборе процесса с неподключёнными зависимостями.=
function Test-ProcessDependencies {
    param([string]$Choice)
    $missing = @(Get-MissingDependencies -Choice $Choice)
    if ($missing.Count -eq 0) { return $true }

    Write-Host "`n  [!] $('Missing dependencies'): $(($missing -join ', '))" -ForegroundColor Red
    Write-Host "  $('This process may not work correctly until they are installed.')" -ForegroundColor Gray
    Write-Host "  [Y] $('Go to Dependencies Menu')  [N] $('Run Anyway')  [B] $('Back')" -ForegroundColor White
    $ans = (Read-Host "  Choice").Trim().ToUpper()
    switch ($ans) {
        'Y' { Show-DependenciesMenu; return $false }
        'B' { return $false }
        default { return $true }
    }
}

# --- Глобальные настройки ---
function Show-SettingsMenu {
    do {
        Show-Banner "GLOBAL SETTINGS"
        Write-Host "  [1] $('Logging'): $(if ($global:Cfg.EnableLogs) { '[ON]' } else { '[OFF]' })" -ForegroundColor White
        Write-Host "  [2] $('Open Logs Folder')" -ForegroundColor White
        Write-Host "  [3] $('Clear All Logs')" -ForegroundColor White
        Write-Host "  [4] $('Auto-Update'): $(if ($global:Cfg.AutoUpdate) { '[ON]' } else { '[OFF]' })" -NoNewline -ForegroundColor White
        Write-Host "   $('(automatic program update check on startup)')" -ForegroundColor Gray
        Write-Host "  [5] $('Check for Updates Now')" -ForegroundColor White
        Write-Host "`n  [0] $('Back to Hub')" -ForegroundColor Gray
        $choice = Read-Host "  Choice"
        switch ($choice) {
            '1' { $global:Cfg.EnableLogs = -not $global:Cfg.EnableLogs; Save-Config $global:Cfg }
            '2' { if (-not (Test-Path $global:Cfg.LogsFolder)) { New-Item -ItemType Directory -Path $global:Cfg.LogsFolder | Out-Null }; Start-Process explorer.exe $global:Cfg.LogsFolder }
            '3' { if (Test-Path $global:Cfg.LogsFolder) { Remove-Item "$($global:Cfg.LogsFolder)\*" -Force -Recurse -ErrorAction SilentlyContinue; Write-Host "  $('Logs cleared.')" -ForegroundColor Green } }
            '4' {
                $global:Cfg.AutoUpdate = -not $global:Cfg.AutoUpdate
                Save-Config $global:Cfg
                if ($global:Cfg.AutoUpdate) {
                    Write-Host "  [OK] $('Auto-update enabled: the program will check for new versions on every launch.')" -ForegroundColor Green
                } else {
                    Write-Host "  [OK] $('Auto-update disabled: you can still update manually via Dependencies menu [5].')" -ForegroundColor Yellow
                }
                Start-Sleep 2
            }
            '5' { Invoke-HubAutoUpdate -Manual }
            '0' { return }
            default { Write-Host "`n  [!] $('Invalid choice')" -ForegroundColor Red; Start-Sleep 1 }
        }
        Start-Sleep 1
    } while ($true)
}

# --- Справка / Руководство ---
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
    Write-Host ""
    Write-Host "  $('AUTO-UPDATE')" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "    $('With Auto-Update ON the hub checks GitHub Releases on every launch.')" -ForegroundColor Gray
    Write-Host "    $('Turn it OFF in Global Settings [4]. Manual check is always available in Settings [5].')" -ForegroundColor Gray
    Write-Host "`n  $('Press Enter to return to Hub...')" -ForegroundColor White
    Read-Host
}

# --- Главный цикл Хаба ---
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
        # Проверка установленных зависимостей перед запуском процесса
        if (-not (Test-ProcessDependencies -Choice $choice)) { continue }
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