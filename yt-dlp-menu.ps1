#Requires -Version 5.1
# ============================================================================
# yt-dlp-menu.ps1 — скачивание видео/аудио/плейлистов/фрагментов через yt-dlp
# ============================================================================
[CmdletBinding()]
param(
    [string]$VideoFolder   # необязательный стартовый каталог (для запуска из .bat)
)

. (Join-Path $PSScriptRoot "common.ps1")

# --- Tool Detection ---
$ytdlpExe = Get-ToolPath "yt-dlp"
if (-not $ytdlpExe) {
    Show-Banner (L "YT-DLP DOWNLOADER" "СКАЧИВАНИЕ YT-DLP")
    Write-Host "  [X] yt-dlp $(L 'not found. Install via Hub.' 'не найден. Установите через Хаб.')" -ForegroundColor Red
    Wait-Enter (L "Press Enter to return..." "Нажмите Enter для возврата...")
    return
}

# --- Quality Selection ---
function Select-VideoQuality {
    param([string]$Url, [string[]]$AuthArgs)

    Write-Host "`n  $(L 'Fetching available formats...' 'Получение доступных форматов...')" -ForegroundColor Cyan
    $fetchArgs = $AuthArgs + @("-J", "--no-colors", $Url)
    $jsonOutput = & $ytdlpExe @fetchArgs 2>$null

    try {
        $videoData = $jsonOutput | ConvertFrom-Json
        $formats = $videoData.formats
    } catch {
        Write-Host "  [!] $(L 'Failed to parse formats. Using best quality.' 'Не удалось получить форматы. Используется лучшее качество.')" -ForegroundColor Yellow
        return "bv+ba/b"
    }

    $allowedHeights = @(480, 720, 1080, 1440, 2160, 4320)
    $heightLabels = @{ 480 = "480p"; 720 = "720p (HD)"; 1080 = "1080p (Full HD)"; 1440 = "1440p (2K)"; 2160 = "2160p (4K)"; 4320 = "4320p (8K)" }
    $parsedFormats = @()

    foreach ($f in $formats) {
        if ($f.ext -ne 'mp4' -or $f.vcodec -eq 'none' -or $null -eq $f.vcodec) { continue }

        $height = $f.height
        if (-not $height -and $f.resolution -match '(\d+)x(\d+)') { $height = [int]$matches[2] }
        if ($allowedHeights -notcontains $height) { continue }

        $sizeBytes = if ($f.filesize) { $f.filesize } elseif ($f.filesize_approx) { $f.filesize_approx } else { 0 }
        $sizeStr = switch ($true) {
            ($sizeBytes -ge 1GB) { "{0:N2} GB" -f ($sizeBytes / 1GB) }
            ($sizeBytes -ge 1MB) { "{0:N2} MB" -f ($sizeBytes / 1MB) }
            ($sizeBytes -ge 1KB) { "{0:N2} KB" -f ($sizeBytes / 1KB) }
            default              { "N/A" }
        }

        # Если в MP4 нет аудиодорожки — добавляем +ba для лучшей аудио
        $hasAudio = ($f.acodec -ne 'none' -and $null -ne $f.acodec)

        $parsedFormats += @{
            DownloadID = if ($hasAudio) { $f.format_id } else { "$($f.format_id)+ba" }
            Label      = $heightLabels[$height]
            Codec      = (($f.vcodec) -split '\.')[0]   # avc1.640028 -> avc1
            FPS        = if ($f.fps) { "$($f.fps) fps" } else { "N/A" }
            Size       = $sizeStr
            Height     = $height
        }
    }

    if ($parsedFormats.Count -eq 0) {
        Write-Host "  [!] $(L 'No matching MP4 formats found. Using best quality.' 'Подходящие MP4 форматы не найдены. Используется лучшее качество.')" -ForegroundColor Yellow
        return "bv+ba/b"
    }

    $parsedFormats = @($parsedFormats | Sort-Object { $_.Height } -Descending)

    Write-Host "`n  $(L 'AVAILABLE MP4 FORMATS' 'ДОСТУПНЫЕ MP4 ФОРМАТЫ')" -ForegroundColor Yellow
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  {0,-6} {1,-20} {2,-10} {3,-10} {4}" -f "#", (L "Resolution" "Разрешение"), "Codec", "FPS", (L "Size" "Размер")) -ForegroundColor Gray
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

    $idMap = @{}
    $i = 1
    foreach ($fmt in $parsedFormats) {
        $resColor = switch ($fmt.Height) {
            4320 { "Magenta" } 2160 { "Green" } 1440 { "Cyan" }
            1080 { "White" }   720  { "Gray" }  default { "DarkGray" }
        }
        Write-Host ("  [{0,-4}]" -f $i) -NoNewline -ForegroundColor White
        Write-Host (" {0,-20}" -f $fmt.Label) -NoNewline -ForegroundColor $resColor
        Write-Host (" {0,-10}" -f $fmt.Codec) -NoNewline -ForegroundColor Cyan
        Write-Host (" {0,-10}" -f $fmt.FPS) -NoNewline -ForegroundColor White
        Write-Host (" {0}" -f $fmt.Size) -ForegroundColor Cyan
        $idMap[$i] = $fmt.DownloadID
        $i++
    }

    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  $(L 'Enter number from the list, or press Enter for best quality.' 'Введите номер из списка, или нажмите Enter для лучшего качества.')" -ForegroundColor White

    $userChoice = Read-Host "`n  $(L 'Choice' 'Выбор')"

    if ([string]::IsNullOrWhiteSpace($userChoice) -or $userChoice -eq '0') {
        Write-Host "  -> $(L 'Using best available quality.' 'Используется лучшее доступное качество.')" -ForegroundColor Green
        return "bv+ba/b"
    }
    if ($userChoice -match '^\d+$' -and $idMap.ContainsKey([int]$userChoice)) {
        $selectedId = $idMap[[int]$userChoice]
        Write-Host "  -> $(L 'Using format ID:' 'Используется формат ID:') $selectedId" -ForegroundColor Green
        return $selectedId
    }
    Write-Host "  [!] $(L 'Invalid choice. Using best quality.' 'Неверный выбор. Используется лучшее качество.')" -ForegroundColor Yellow
    return "bv+ba/b"
}

# --- Cookies path helper ---
function Get-CookiesArgs {
    $defaultPath = $global:Cfg.PSObject.Properties['CookiesPath'] | ForEach-Object { $_.Value }

    if ($defaultPath) {
        Write-Host "`n  $(L 'Saved cookies path' 'Сохраненный путь к куки'): " -ForegroundColor White -NoNewline
        Write-Host "$defaultPath" -ForegroundColor Cyan
        Write-Host "  $(L 'Press Enter to use saved path, or enter a new one' 'Нажмите Enter, чтобы использовать сохраненный путь, или введите новый'):" -ForegroundColor Gray
    } else {
        Write-Host "`n  $(L 'Enter path to cookies.txt:' 'Введите путь к cookies.txt:')" -ForegroundColor White
    }

    $inputPath = (Read-Host "  > ").Trim().Trim('"')
    $cookiePath = if ([string]::IsNullOrWhiteSpace($inputPath)) { $defaultPath } else { $inputPath }

    if (-not $cookiePath -or -not (Test-Path $cookiePath)) {
        Write-Host "  [X] $(L 'File not found' 'Файл не найден')" -ForegroundColor Red
        return $null
    }

    # Запоминаем путь в глобальной конфигурации
    if (-not $global:Cfg.PSObject.Properties['CookiesPath']) {
        $global:Cfg | Add-Member -NotePropertyName "CookiesPath" -NotePropertyValue $cookiePath
    } else {
        $global:Cfg.CookiesPath = $cookiePath
    }
    Save-Config $global:Cfg

    return @("--cookies", $cookiePath)
}

# --- Timecode fragment helper ---
function Read-TimeFragment {
    Write-Host "  $(L 'Start time (e.g., 1:30 or 1 30):' 'Время начала (например, 1:30 или 1 30):')" -ForegroundColor White
    $start = (Read-Host "  > ").Trim().Replace(" ", ":")
    Write-Host "  $(L 'End time (e.g., 1:30 or 1 30):' 'Время окончания (например, 1:30 или 1 30):')" -ForegroundColor White
    $end = (Read-Host "  > ").Trim().Replace(" ", ":")
    return "*$start-$end"
}

# --- Colored yt-dlp output ---
# Возвращает результат через $script:ytOk (return в PowerShell возвращает весь вывод потока success)
function Invoke-YtDlp {
    param([string[]]$FinalArgs)
    $script:ytErr = $false
    & $ytdlpExe @FinalArgs 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if     ($line -match 'ERROR|failed|refused|403')                                  { Write-Host $line -ForegroundColor Red;    $script:ytErr = $true }
        elseif ($line -match 'WARNING')                                                   { Write-Host $line -ForegroundColor Yellow }
        elseif ($line -match '^\[download\]|\d+\.\d+%')                                   { Write-Host $line -ForegroundColor Cyan }
        elseif ($line -match '^\[ExtractAudio\]|^\[Merger\]|^\[Fixup\]|^\[Metadata\]|^\[Subtitles\]') { Write-Host $line -ForegroundColor Magenta }
        elseif ($line -match '^\[info\]')                                                 { Write-Host $line -ForegroundColor DarkGray }
        else                                                                              { Write-Host $line -ForegroundColor White }
    }
    $script:ytOk = ($LASTEXITCODE -eq 0 -and -not $script:ytErr)
}

# --- Main Loop ---
do {
    $script:ytErr = $false
    Show-Banner (L "YT-DLP DOWNLOADER" "СКАЧИВАНИЕ YT-DLP")

    Write-Host "  $(L 'STEP 1: AUTHENTICATION METHOD' 'ШАГ 1: МЕТОД АВТОРИЗАЦИИ')" -ForegroundColor Yellow
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [1] $(L 'Standard (No cookies)' 'Стандартный (без cookies)')" -ForegroundColor White
    Write-Host "  [2] $(L 'Browser Cookies (Recommended for 403 errors)' 'Cookies браузера (Рекомендуется от ошибок 403)')" -ForegroundColor Cyan
    Write-Host "  [3] $(L 'Cookies File (.txt)' 'Файл Cookies (.txt)')" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [4] $(L 'Clear yt-dlp Cache' 'Очистить кэш yt-dlp')" -ForegroundColor White
    Write-Host "  [0] $(L 'Back to Hub' 'Вернуться в Хаб')" -ForegroundColor Red

    $authChoice = Read-Host (L "  Choice" "  Выбор")

    if ($authChoice -eq '0') { return }

    if ($authChoice -eq '4') {
        Write-Host "`n  $(L 'Clearing cache...' 'Очистка кэша...')" -ForegroundColor Cyan
        & $ytdlpExe --rm-cache-dir
        Write-Host "  [OK] $(L 'Cache cleared.' 'Кэш очищен.')" -ForegroundColor Green
        Wait-Enter
        continue
    }

    if ($authChoice -notmatch '^[1-3]$') {
        Write-Host "`n  [!] $(L 'Invalid choice' 'Неверный выбор')" -ForegroundColor Red
        Start-Sleep 1
        continue
    }

    $authArgs = @()
    if ($authChoice -eq '2') {
        Write-Host "`n  $(L 'Select browser:' 'Выберите браузер:')" -ForegroundColor White
        Write-Host "  [1] Chrome  [2] Edge  [3] Firefox  [4] Opera" -ForegroundColor Gray
        $bChoice = Read-Host (L "  Choice" "  Выбор")
        $browser = switch ($bChoice) { '1' {'chrome'} '2' {'edge'} '3' {'firefox'} '4' {'opera'} default {'chrome'} }
        Write-Host "`n  $(L 'Extracting cookies from' 'Извлечение cookies из') $browser... $(L 'Please approve if prompted.' 'Одобрите, если браузер запросит.')" -ForegroundColor Cyan
        $authArgs = @("--cookies-from-browser", $browser)
    }
    elseif ($authChoice -eq '3') {
        $authArgs = Get-CookiesArgs
        if ($null -eq $authArgs) { Wait-Enter; continue }
    }

    Show-Banner (L "STEP 2: SELECT CONTENT TYPE" "ШАГ 2: ВЫБОР ТИПА КОНТЕНТА")
    Write-Host "  [1] $(L 'Video (MP4)' 'Видео (MP4)')" -ForegroundColor White
    Write-Host "  [2] $(L 'Audio (MP3)' 'Аудио (MP3)')" -ForegroundColor White
    Write-Host "  [3] $(L 'Playlist' 'Плейлист')" -ForegroundColor White
    Write-Host "  [4] $(L 'Video Fragment (by timecode)' 'Фрагмент видео (по таймкоду)')" -ForegroundColor White
    Write-Host "  [5] $(L 'Audio Fragment (by timecode)' 'Фрагмент аудио (по таймкоду)')" -ForegroundColor White
    Write-Host "  [0] $(L 'Back to previous menu' 'Вернуться в предыдущее меню')" -ForegroundColor Red

    $contentChoice = Read-Host (L "  Choice" "  Выбор")
    if ($contentChoice -eq '0') { continue }
    if ($contentChoice -notmatch '^[1-5]$') {
        Write-Host "`n  [!] $(L 'Invalid choice' 'Неверный выбор')" -ForegroundColor Red
        Start-Sleep 1
        continue
    }

    Write-Host "`n  $(L 'Enter URL:' 'Введите ссылку:')" -ForegroundColor White
    $url = Read-Host "  > "

    $downloadArgs = @()
    $statusMsg = L "Downloading..." "Скачивание..."

    switch ($contentChoice) {
        '1' {
            $formatString = Select-VideoQuality -Url $url -AuthArgs $authArgs
            $downloadArgs = @("-f", $formatString, "--merge-output-format", "mp4", $url)
        }
        '2' { $downloadArgs = @("-x", "--audio-format", "mp3", $url) }
        '3' { $downloadArgs = @("--yes-playlist", $url) }
        '4' {
            $formatString = Select-VideoQuality -Url $url -AuthArgs $authArgs
            $section = Read-TimeFragment
            $downloadArgs = @("--download-sections", $section, "-f", $formatString, "--merge-output-format", "mp4", "--force-keyframes-at-cuts", $url)
            $statusMsg = L "Downloading fragment..." "Скачивание фрагмента..."
        }
        '5' {
            $section = Read-TimeFragment
            $downloadArgs = @("-x", "--audio-format", "mp3", "--download-sections", $section, $url)
            $statusMsg = L "Downloading audio fragment..." "Скачивание аудио фрагмента..."
        }
    }

    Write-Host "`n  $statusMsg" -ForegroundColor Yellow
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

    Invoke-YtDlp -FinalArgs ($authArgs + $downloadArgs + @("--no-colors"))

    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    if ($script:ytOk) {
        Write-Host "  [OK] $(L 'Done' 'Готово')" -ForegroundColor Green
    } else {
        Write-Host "  [X] $(L 'Error. Try using Cookies or clearing cache.' 'Ошибка. Попробуйте использовать Cookies или очистить кэш.')" -ForegroundColor Red
    }

    Wait-Enter
} while ($true)
