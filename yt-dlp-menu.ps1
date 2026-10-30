#Requires -Version 5.1
$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
$ToolsDir = Join-Path $ScriptDir "tools"

# --- Управление локальными путями ---
if (Test-Path $ToolsDir) {
    if ($env:Path -notlike "*$ToolsDir*") { $env:Path = "$ToolsDir;$env:Path" }
    $ffmpegBin = Join-Path $ToolsDir "ffmpeg\bin"
    if ((Test-Path $ffmpegBin) -and ($env:Path -notlike "*$ffmpegBin*")) { $env:Path = "$ffmpegBin;$env:Path" }
}

# Логи ошибок сохраняются ВСЕГДА; обычные логи — только при включённом пункте настроек (EnableLogs)
# Все логи сохраняются в папку logs в корневой папке
$global:Cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { @{EnableLogs=$false; LogsFolder=(Join-Path $ScriptDir "logs")} }
if (-not ($global:Cfg.PSObject.Properties['LogsFolder'] -or ($global:Cfg -is [System.Collections.IDictionary] -and $global:Cfg.Contains('LogsFolder')))) {
    $global:Cfg = $global:Cfg + @{ LogsFolder = (Join-Path $ScriptDir "logs") }
}
if (-not ($global:Cfg.PSObject.Properties['EnableLogs'] -or ($global:Cfg -is [System.Collections.IDictionary] -and $global:Cfg.Contains('EnableLogs')))) {
    $global:Cfg = $global:Cfg + @{ EnableLogs = $false }
}
# Папка logs всегда находится в корневой папке скрипта
$global:Cfg.LogsFolder = (Join-Path $ScriptDir "logs")
function Show-Banner { param([string]$Title) Clear-Host; Write-Host "`n========================================================" -ForegroundColor Cyan; Write-Host "  $Title" -ForegroundColor Yellow; Write-Host "========================================================`n" -ForegroundColor Cyan }

# --- Логирование ошибок (все логи сохраняются в папку logs в корне) ---
$script:LogsFolder = [string]$global:Cfg.LogsFolder
$script:ErrorLogFile = Join-Path $script:LogsFolder "download_errors.log"

function Write-ErrorLog {
    param(
        [string]$Type,        # ERROR | HANG | INFO | MANUAL
        [string]$FileName,
        [string]$Details
    )
    # Логи ошибок (ERROR/HANG) сохраняются ВСЕГДА; обычные логи (INFO/MANUAL) — только при EnableLogs
    if ((-not $global:Cfg.EnableLogs) -and ($Type -notin @('ERROR','HANG'))) { return $false }
    try {
        if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
        # Если лог-файл был удалён вручную — пересоздаём его с заголовком
        if (-not (Test-Path $script:ErrorLogFile)) {
            Set-Content -Path $script:ErrorLogFile -Value @(
                "=== Download error log | Root folder: $ScriptDir | Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===", ""
            ) -Encoding UTF8
        }
        $entry = @(
            "======================================================================"
            "[$Type] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "Target: $FileName"
            "Details:"
            $Details
            ""
        ) -join [Environment]::NewLine
        Add-Content -Path $script:ErrorLogFile -Value $entry -Encoding UTF8
        return $true
    } catch { return $false }
}

# --- Лог по нажатию клавиши во время процесса загрузки ---
# Проверяет, была ли нажата клавиша "L" (без блокировки). Возвращает $true, если нажата.
function Test-LoggingHotkey {
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'L' -or $k.KeyChar -eq 'l' -or $k.KeyChar -eq 'L') { return $true }
        }
    } catch {}
    return $false
}

# Создаёт запись в корневом логе с текущим состоянием загрузки (по нажатию клавиши L)
function Write-ProgressLog {
    param(
        [string]$Target,      # URL / цель загрузки
        [double]$ElapsedSec,  # сколько секунд идёт загрузка
        [array]$Output        # собранный вывод yt-dlp
    )
    $elapsedStr = [TimeSpan]::FromSeconds($ElapsedSec).ToString('hh\:mm\:ss')
    $tail = @($Output | Select-Object -Last 40)
    $details = @(
        "Manual log request (key 'L' pressed)"
        "Stage: Download | Elapsed: $elapsedStr | Lines captured: $(@($Output).Count)"
        "Last yt-dlp output:"
    ) -join [Environment]::NewLine
    $details += [Environment]::NewLine + ($tail -join [Environment]::NewLine)
    $ok = Write-ErrorLog -Type "MANUAL" -FileName $Target -Details $details
    return [pscustomobject]@{ Success = $ok; LogFile = $script:ErrorLogFile }
}

# --- Обнаружение инструмента ---
$ytdlpExe = Join-Path $ToolsDir "yt-dlp.exe"
$ytdlpCmd = if (Test-Path $ytdlpExe) { $ytdlpExe } else { "yt-dlp" }

$isYtDlpInstalled = $false
try { $null = & $ytdlpCmd --version 2>&1; $isYtDlpInstalled = $true } catch {}

if (-not $isYtDlpInstalled) {
    Show-Banner "YT-DLP DOWNLOADER"
    Write-Host "  [X] yt-dlp $('not found. Install via Hub.')" -ForegroundColor Red
    Write-Host "`n  $('Press Enter to return...')" -ForegroundColor Gray
    Read-Host
    return
}

# --- Функция выбора качества ---
function Select-VideoQuality {
    param([string]$Url, [string[]]$AuthArgs)

    Write-Host "`n  $('Fetching available formats...')" -ForegroundColor Cyan
    $fetchArgs = $AuthArgs + @("-J", "--no-colors", $Url)
    $jsonOutput = & $ytdlpCmd @fetchArgs 2>$null

    try {
        $videoData = $jsonOutput | ConvertFrom-Json
        $formats = $videoData.formats
    } catch {
        Write-Host "  [!] $('Failed to parse formats. Using best quality.')" -ForegroundColor Yellow
        return "bv+ba/b"
    }

    $allowedHeights = @(480, 720, 1080, 1440, 2160, 4320)
    $parsedFormats = @()

    foreach ($f in $formats) {
        if ($f.ext -eq 'mp4' -and $f.vcodec -ne 'none' -and $f.vcodec -ne $null) {
            $height = $f.height
            if (-not $height -and $f.resolution -match '(\d+)x(\d+)') {
                $height = [int]$matches[2]
            }

            if ($allowedHeights -contains $height) {
                $label = switch ($height) {
                    480  { "480p" }
                    720  { "720p (HD)" }
                    1080 { "1080p (Full HD)" }
                    1440 { "1440p (2K)" }
                    2160 { "2160p (4K)" }
                    4320 { "4320p (8K)" }
                }

                $fps = if ($f.fps) { "$($f.fps) fps" } else { "N/A" }

                # Извлекаем базовое имя кодека (напр. avc1.640028 -> avc1)
                $vcodec = if ($f.vcodec) { ($f.vcodec -split '\.')[0] } else { "N/A" }

                # Пропускаем форматы без известной информации о размере (N/A size)
                $sizeBytes = if ($f.filesize) { $f.filesize } elseif ($f.filesize_approx) { $f.filesize_approx } else { 0 }
                if ($sizeBytes -lt 1KB) { continue }
                if ($sizeBytes -ge 1GB) { $sizeStr = "{0:N2} GB" -f ($sizeBytes / 1GB) }
                elseif ($sizeBytes -ge 1MB) { $sizeStr = "{0:N2} MB" -f ($sizeBytes / 1MB) }
                else { $sizeStr = "{0:N2} KB" -f ($sizeBytes / 1KB) }

                # Если в MP4-формате нет аудиодорожки, автоматически добавляем +ba для загрузки лучшего аудио.
                $hasAudio = ($f.acodec -ne 'none' -and $f.acodec -ne $null)
                $downloadId = if ($hasAudio) { $f.format_id } else { "$($f.format_id)+ba" }

                $parsedFormats += @{
                    ID = $f.format_id
                    DownloadID = $downloadId
                    Label = $label
                    Codec = $vcodec
                    FPS = $fps
                    Size = $sizeStr
                    Height = $height
                }
            }
        }
    }

    if ($parsedFormats.Count -eq 0) {
        Write-Host "  [!] $('No matching MP4 formats found. Using best quality.')" -ForegroundColor Yellow
        return "bv+ba/b"
    }

    $parsedFormats = $parsedFormats | Sort-Object { $_.Height } -Descending

    Write-Host "`n  $('AVAILABLE MP4 FORMATS')" -ForegroundColor Yellow
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  {0,-6} {1,-10} {2,-20} {3,-10} {4,-10} {5}" -f "#", "ID", ("Resolution"), "Codec", "FPS", ("Size")) -ForegroundColor Gray
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

    $i = 1
    $idMap = @{}
    foreach ($fmt in $parsedFormats) {
        $resColor = switch ($fmt.Height) {
            4320 { "Magenta" }
            2160 { "Green" }
            1440 { "Cyan" }
            1080 { "White" }
            720  { "Gray" }
            default { "DarkGray" }
        }

        Write-Host ("  [{0,-4}]" -f $i) -NoNewline -ForegroundColor White
        Write-Host (" {0,-10}" -f $fmt.ID) -NoNewline -ForegroundColor DarkGray
        Write-Host (" {1,-20}" -f "", $fmt.Label) -NoNewline -ForegroundColor $resColor
        Write-Host (" {0,-10}" -f $fmt.Codec) -NoNewline -ForegroundColor Cyan
        Write-Host (" {0,-10}" -f $fmt.FPS) -NoNewline -ForegroundColor White
        Write-Host (" {0}" -f $fmt.Size) -ForegroundColor Cyan

        $idMap[$i] = $fmt.DownloadID
        $i++
    }

    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  $('Enter number from the list, or press Enter for best quality.')" -ForegroundColor White

    $userChoice = Read-Host "`n  $('Choice')"

    if ([string]::IsNullOrWhiteSpace($userChoice) -or $userChoice -eq '0') {
        Write-Host "  -> $('Using best available quality.')" -ForegroundColor Green
        return "bv+ba/b"
    }

    if ($userChoice -match '^\d+$' -and $idMap.ContainsKey([int]$userChoice)) {
        $selectedId = $idMap[[int]$userChoice]
        Write-Host "  -> $('Using format ID:') $selectedId" -ForegroundColor Green
        return $selectedId
    } else {
        Write-Host "  [!] $('Invalid choice. Using best quality.')" -ForegroundColor Yellow
        return "bv+ba/b"
    }
}

# --- Скачивание картинок по URL ---
# Поддерживает: прямые ссылки на изображения, страницы с превью (через yt-dlp),
# несколько URL через запятку/пробел и пакетную загрузку списка URL из файла (.txt)
function Invoke-ImageDownload {
    param([string[]]$Urls, [string]$OutputDir, [string[]]$AuthArgs)

    $imageExts = @('jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'tiff', 'tif', 'svg', 'ico', 'heic', 'avif')
    $okCount = 0; $failCount = 0

    # Пути cookies могут содержать пробелы и скобки ("... (1).txt") — снимаем обрамляющие кавычки,
    # чтобы yt-dlp не получал битый путь (--cookies C:\...\www.youtube.com_cookies (1).txt)
    $AuthArgs = @($AuthArgs | ForEach-Object { if ($_ -is [string]) { $_.Trim().Trim('"').Trim("'") } else { $_ } })

    foreach ($u in $Urls) {
        if ([string]::IsNullOrWhiteSpace($u)) { continue }
        # Очистка от кавычек и «хвостов» склеенной вставки; URL не должен содержать пробелов и кавычек
        $u = $u.Trim().Trim('"').Trim("'")
        if ($u -notmatch '^https?://[^\s""'']+$') {
            Write-Host "  [X] $('Invalid URL'): $u" -ForegroundColor Red
            $failCount++
            continue
        }

        # Прямая ссылка на файл-картинку: расширение ищем в конце URL или перед query-строкой (?...)
        # (ссылки DeviantArt и подобных CDN имеют вид ...jpg?token=<очень длинный JWT>)
        $uPath = ($u -split '\?')[0]

        # Google Images: ссылки вида «Показать изображение» / «Копировать ссылку на изображение»
        # имеют вид https://www.google.com/imgres?q=...&imgurl=<закодированная прямая ссылка>&imgrefurl=<страница-источник>&...
        # yt-dlp такие ссылки не скачивает — вытаскиваем настоящую ссылку на файл из параметра imgurl.
        # Работает для google.com / google.ru и других доменов, а также для старых /images?...&imgurl=...
        $origTarget = $u   # исходная ссылка (для имени файла, если картинка без расширения в пути)
        $refererArg = $null # Referer для прямого скачивания (страница-источник из imgrefurl)
        $isGoogleImgres = ($u -match 'google\.[a-zA-Z.]*/(?:search/)?img(?:res|ages)')
        if ($isGoogleImgres) {
            if ($u -imatch '[?&]imgurl=([^&]+)') {
                $decodedImgUrl = [Uri]::UnescapeDataString($Matches[1])
                if ($decodedImgUrl -match '^https?://') {
                    Write-Host "  $('Google image link detected, extracting direct URL from imgurl'): " -ForegroundColor DarkGray
                    Write-Host "    $decodedImgUrl" -ForegroundColor DarkGray
                    $u = $decodedImgUrl
                    $uPath = ($u -split '\?')[0]
                }
            }
            if ($u -imatch '[?&]imgrefurl=([^&]+)') {
                $decodedRef = [Uri]::UnescapeDataString($Matches[1])
                if ($decodedRef -match '^https?://') { $refererArg = $decodedRef }
            }
        }

        # -imatch: расширение в URL может быть в верхнем регистре (.JPG, .PNG)
        # Для Google imgres считаем ссылкой на файл также адреса без расширения (googleusercontent и т.п.)
        $looksLikeFile = ($u -match '^https?://' -and $uPath -imatch "\.($($imageExts -join '|'))$")
        $isGoogleDirect = ($isGoogleImgres -and $u -ne $origTarget -and $u -match '^https?://' -and $u -notmatch 'google')
        if ($looksLikeFile -or $isGoogleDirect) {
            if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
            try {
                $uriObj = [System.Uri]::new($u)
                # Имя файла берём из ПУТИ URL (до ?token=...), иначе в имя попадёт вся query-строка
                $fileName = ($uriObj.AbsolutePath.Split('/')[-1] -replace '/', '')
                # Если в пути нет имени файла — пробуем взять имя из query (filename=..., name=...)
                if ([string]::IsNullOrWhiteSpace([System.Uri]::UnescapeDataString($fileName))) {
                    $qs = [regex]::Matches($uriObj.Query, '(?:^|[&?])(?:filename|name)=([^&]+)')
                    if ($qs.Count -gt 0) { $fileName = $qs[0].Groups[1].Value }
                }
                # Имя файла: если путь URL закончился на '.'/'-' (после вырезания query), чистим хвост
                $fileName = ($fileName -replace '[\.-]+$', '')
                # Картинки Google (imgurl ведёт на googleusercontent без расширения в пути):
                # даём осмысленное имя — по запросу (q=...) или домену источника (imgrefurl) из исходной ссылки
                if ($isGoogleDirect -and $fileName -notmatch '\.(jpg|jpeg|png|gif|webp|bmp|tiff?|svg|ico|heic|avif)$') {
                    $gName = $null
                    if ($origTarget -imatch '[?&]q=([^&]+)') { $gName = [Uri]::UnescapeDataString($Matches[1]) -replace '[+]', ' ' }
                    if (-not $gName -and $refererArg -match '^https?://([^/]+)') { $gName = $Matches[1] }
                    if ($gName) {
                        $gName = ($gName.Trim() -replace '[^\w\.\- ]', '_') -replace '\s+', '_'
                        if ($gName.Length -gt 60) { $gName = $gName.Substring(0, 60) }
                        $fileName = "google_$gName"   # расширение допишем по сигнатуре файла
                    }
                }
                # Раскодировка %XX в имени файла без внешних зависимостей
                $baseName = [regex]::Replace($fileName, '%([0-9A-Fa-f]{2})', { param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16) })
                if ([string]::IsNullOrWhiteSpace($baseName)) { $baseName = "image_$((Get-Date -Format 'yyyyMMddHHmmss')).jpg" }
                $baseName = ($baseName -replace '[^\w\.\-]', '_')
                $destPath = Join-Path $OutputDir $baseName
                # Google imgres может вести на картинку БЕЗ расширения в пути (например .../image;CROP,xxx).
                # В этом случае расширение определим по сигнатуре скачанного файла (см. ниже).
                $needExtFix = ($baseName -notmatch '\.[A-Za-z0-9]{2,5}$')

                # Если файл уже существует — добавляем суффикс (1), (2), ...
                if (Test-Path $destPath) {
                    $stem = [System.IO.Path]::GetFileNameWithoutExtension($baseName)
                    $ext  = [System.IO.Path]::GetExtension($baseName)
                    $n = 1
                    while (Test-Path $destPath) { $destPath = Join-Path $OutputDir "$stem`_$n$ext"; $n++ }
                }

                Write-Host "  $('Downloading image')... $u" -ForegroundColor Cyan
                $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
                # Referer: для Google imgres это страница-источник из imgrefurl (многие CDN требуют её),
                # иначе — корень хоста картинки
                $refererVal = if ($refererArg) { $refererArg } else { "$($uriObj.Scheme)://$($uriObj.Host)/" }
                $got = $false
                try {
                    # WebClient на старых PS может не поддерживать TLS1.2 — включаем принудительно
                    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add('User-Agent', $ua)
                    $wc.Headers.Add('Referer', $refererVal)
                    $wc.DownloadFile($u, $destPath)
                    $got = $true
                } catch {
                    $wcErr = $_.Exception.Message
                }
                if (-not $got) {
                    # Резервный способ: Invoke-WebRequest (в PS 5.1 отключает «прогресс», чтобы не тормозить)
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri $u -OutFile $destPath -UserAgent $ua -Headers @{ Referer = $refererVal } -UseBasicParsing -ErrorAction Stop
                    Write-Host "  $('WebClient failed, used Invoke-WebRequest'): $wcErr" -ForegroundColor DarkGray
                }
                # Проверка, что скачался именно файл, а не страница ошибки / заглушка
                # Читаем заголовок файла через .NET: совместимо и с PowerShell 5.1 (-Encoding Byte), и с PS Core
                $head = @()
                try {
                    $fs = [System.IO.File]::OpenRead($destPath)
                    $buf = New-Object byte[] 16
                    $nRead = $fs.Read($buf, 0, 16)
                    $fs.Close()
                    $head = @($buf | Select-Object -First $nRead)
                } catch {}
                if ($head.Count -eq 0) { throw "Downloaded file is empty." }
                $asText = -join ($head | ForEach-Object { [char]$_ })
                $imgMagic = ($head[0] -eq 0xFF -or $head[0] -eq 0x89 -or ($head[0] -eq 0x47 -and $head[1] -eq 0x49) -or
                              ($head[0] -eq 0x52 -and $head[1] -eq 0x49 -and $head[2] -eq 0x46 -and $head[3] -eq 0x46) -or
                              ($head[0] -eq 0x42 -and $head[1] -eq 0x4D) -or ($asText -match '^<svg') -or ($asText -match '^(RIFF|BM)'))
                if ((Get-Item $destPath).Length -lt 100 -or (-not $imgMagic)) {
                    throw "Server did not return a valid image (HTML/error page or empty file). The link may be expired (check the token) or may require cookies."
                }
                # Если в имени файла не было расширения (типично для Google imgres-ссылок без .jpg в пути) —
                # дописываем расширение по сигнатуре скачанного файла
                if ($needExtFix) {
                    $sigExt = '.jpg'
                    if ($head[0] -eq 0x89) { $sigExt = '.png' }
                    elseif ($head[0] -eq 0x47) { $sigExt = '.gif' }
                    elseif (($head[0] -eq 0x52) -and ($head[1] -eq 0x49)) { $sigExt = '.webp' }
                    elseif (($head[0] -eq 0x42) -and ($head[1] -eq 0x4D)) { $sigExt = '.bmp' }
                    $newPath = "$destPath$sigExt"
                    if (Test-Path $newPath) { $n = 1; while (Test-Path $newPath) { $newPath = "${destPath}_$n$sigExt"; $n++ } }
                    Rename-Item -Path $destPath -NewName (Split-Path $newPath -Leaf) -ErrorAction SilentlyContinue
                    $destPath = $newPath
                }
                $sizeBytes = (Get-Item $destPath).Length
                $sizeStr = if ($sizeBytes -ge 1MB) { "{0:N2} MB" -f ($sizeBytes / 1MB) } else { "{0:N2} KB" -f ($sizeBytes / 1KB) }
                Write-Host "  [OK] $destPath ($sizeStr)" -ForegroundColor Green
                $okCount++
            } catch {
                # Удаляем неполный/мусорный файл и пишем реальную причину ошибки
                if (Test-Path $destPath) { Remove-Item $destPath -Force -ErrorAction SilentlyContinue }
                $errMsg = $_.Exception.Message
                if ($_ -is [System.Management.Automation.ErrorRecord] -and $_.Exception.Response) {
                    try { $errMsg += " (HTTP $([int]$_.Exception.Response.StatusCode))" } catch {}
                }
                Write-Host "  [X] $('Failed to download'): $errMsg" -ForegroundColor Red
                Write-ErrorLog -Type "ERROR" -FileName $u -Details "Stage: Direct image download failed | Error: $errMsg" | Out-Null
                $failCount++
            }
            continue
        }

        # Ссылка на страницу/пост (VK, Instagram, Pinterest и т.п.) или неизвестный тип —
        # передаём yt-dlp: он скачает превью/изображения со страниц, поддерживающих его экстракторы
        if ($u -match '^https?://') {
            # Резервный вариант для Google imgres БЕЗ параметра imgurl (например /imgres?...&tbnid=...):
            # скачиваем саму страницу-обёртку и вытаскиваем из неё прямую ссылку на картинку.
            # Ссылки в HTML Google лежат в атрибутах src="..." и data-src="..." — берём первую http-ссылку с расширением картинки.
            if ($isGoogleImgres) {
                Write-Host "  $('No imgurl parameter found, trying to extract direct image URL from the Google page')..." -ForegroundColor DarkGray
                try {
                    $ProgressPreference = 'SilentlyContinue'
                    $gHtml = (Invoke-WebRequest -Uri $u -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' -UseBasicParsing -ErrorAction Stop).Content
                    $gDirect = $null
                    # Картинки Google могут быть и без расширения в пути (lh3.googleusercontent.com/...) —
                    # сначала ищем googleusercontent, затем любой http-адрес с расширением картинки
                    foreach ($gm in [regex]::Matches($gHtml, '(?:src|data-src|href)="(https?://[^"]+)"')) {
                        $cand = ([Uri]::UnescapeDataString($gm.Groups[1].Value)) -replace '&amp;', '&'
                        if ($cand -match 'googleusercontent\.com/') { $gDirect = $cand; break }
                        if ($cand -imatch '\.(jpg|jpeg|png|gif|webp|bmp)(\?|$)' -and $cand -notmatch 'google') { $gDirect = $cand; break }
                    }
                    if (-not $gDirect) {
                        $gmAll = [regex]::Match($gHtml, '(https?://[^"''\s<>]+?\.(?:jpg|jpeg|png|gif|webp|bmp)(?:\?[^"''\s<>]*)?)', 'IgnoreCase')
                        if ($gmAll.Success) { $gDirect = $gmAll.Value }
                    }
                    if ($gDirect) {
                        Write-Host "    $('Extracted direct URL'): $gDirect" -ForegroundColor DarkGray
                        # Прямое скачивание извлечённой ссылки (без повторного прогона через весь конвейер)
                        try {
                            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
                            $gdUri = [System.Uri]::new($gDirect)
                            $gdName = ($gdUri.AbsolutePath.Split('/')[-1])
                            if ([string]::IsNullOrWhiteSpace($gdName)) { $gdName = "google_image" }
                            $gdName = ($gdName -replace '[^\w\.\-]', '_')
                            if ($gdName -notmatch '\.[A-Za-z0-9]{2,5}$') { $gdName += '.jpg' }
                            $gdPath = Join-Path $OutputDir $gdName
                            if (Test-Path $gdPath) { $n = 1; while (Test-Path $gdPath) { $stem=[System.IO.Path]::GetFileNameWithoutExtension($gdName); $ext=[System.IO.Path]::GetExtension($gdName); $gdPath = Join-Path $OutputDir "${stem}_$n$ext"; $n++ } }
                            $wc2 = New-Object System.Net.WebClient
                            $wc2.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')
                            $wc2.DownloadFile($gDirect, $gdPath)
                            if ((Get-Item $gdPath).Length -ge 100) {
                                Write-Host "  [OK] $gdPath" -ForegroundColor Green
                                $okCount++
                            } else { Remove-Item $gdPath -Force }
                        } catch {
                            Write-Host "  [X] $('Failed to download'): $($_.Exception.Message)" -ForegroundColor Red
                            $failCount++
                        }
                        continue
                    }
                    Write-Host "  [!] $('Could not extract a direct image link from the Google page')" -ForegroundColor Yellow
                } catch {
                    Write-Host "  [!] $('Google page request failed'): $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            Write-Host "  $('Trying yt-dlp image extraction')... $u" -ForegroundColor Cyan
            # ВАЖНО: параметры и URL разделяются знаком "--", иначе длинная ссылка (с токеном)
            # может быть воспринята неверно и yt-dlp выдаст "You must provide at least one URL"
            # Пустые элементы удаляем (иначе PowerShell склеит аргументы — та же ошибка "You must provide at least one URL")
            $AuthArgs = @($AuthArgs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $imgArgs = $AuthArgs + @("-P", $OutputDir, "--restrict-filenames",
                "--write-image", "--skip-download", "--no-playlist", "--ignore-no-formats-error", "--no-colors", "--", $u)
            $imgOutput = @()
            & $ytdlpCmd @imgArgs 2>&1 | ForEach-Object {
                $line = $_.ToString()
                $imgOutput += $line
                if ($line -match 'ERROR|failed|refused|403') { Write-Host $line -ForegroundColor Red }
                elseif ($line -match 'WARNING') { Write-Host $line -ForegroundColor Yellow }
                elseif ($line -match 'Writing video thumbnail|Destination|^ *\[') { Write-Host $line -ForegroundColor Green }
                else { Write-Host $line -ForegroundColor White }
            }
            # Код возврата проверяем ТОЛЬКО если yt-dlp вообще отработал (иначе это leftover-код от прошлой команды)
            $ytdlpRan = ($imgOutput.Count -gt 0)
            if ($ytdlpRan -and $LASTEXITCODE -eq 0) { $okCount++ }
            else {
                if (-not $ytdlpRan) { Write-Host "  [!] $('yt-dlp did not run for this URL') ($ytdlpCmd)" -ForegroundColor Yellow }
                Write-Host "  [X] $('yt-dlp could not extract an image from this URL')" -ForegroundColor Red
                $lastLines = ($imgOutput | Select-Object -Last 6) -join "`n"
                Write-ErrorLog -Type "ERROR" -FileName $u -Details ("Stage: yt-dlp image extraction failed | ContentChoice: 6 | ExitCode: $LASTEXITCODE`nCommand: $ytdlpCmd " + ($imgArgs -join ' ') + "`nLast yt-dlp output:`n$lastLines") | Out-Null
                $failCount++
            }
            continue
        }

        Write-Host "  [X] $('Invalid URL'): $u" -ForegroundColor Red
        $failCount++
    }

    Write-Host "`n  $('Result'): OK - $okCount, $('Failed') - $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
    Write-Host "  $('Saved to'): $OutputDir" -ForegroundColor Cyan
}

# --- Главный цикл ---
do {
    Show-Banner "YT-DLP DOWNLOADER"

    Write-Host "  $('STEP 1: AUTHENTICATION METHOD')" -ForegroundColor Yellow
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [1] $('Standard (No cookies)')" -ForegroundColor White
    Write-Host "  [2] $('Browser Cookies (Recommended for 403 errors)')" -ForegroundColor Cyan
    Write-Host "  [3] $('Cookies File (.txt)')" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [4] $('Clear yt-dlp Cache')" -ForegroundColor White
    Write-Host "  [0] $('Back to Hub')" -ForegroundColor Red

    $authChoice = Read-Host "  Choice"

    if ($authChoice -eq '0') { return }

    if ($authChoice -eq '4') {
        Write-Host "`n  $('Clearing cache...')" -ForegroundColor Cyan
        & $ytdlpCmd --rm-cache-dir
        Write-Host "  [OK] $('Cache cleared.')" -ForegroundColor Green
        Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
        Read-Host
        continue
    }

    if ($authChoice -match '^[1-3]$') {
        $authArgs = @()
        if ($authChoice -eq '2') {
            Write-Host "`n  $('Select browser:')" -ForegroundColor White
            Write-Host "  [1] Chrome  [2] Edge  [3] Firefox  [4] Opera" -ForegroundColor Gray
            $bChoice = Read-Host "  Choice"
            $browser = switch($bChoice) { '1'{'chrome'} '2'{'edge'} '3'{'firefox'} '4'{'opera'} default{'chrome'} }
            Write-Host "`n  $('Extracting cookies from') $browser... $('Please approve if prompted.')" -ForegroundColor Cyan
            $authArgs = @("--cookies-from-browser", $browser)
        }
        elseif ($authChoice -eq '3') {
            $defaultPath = $global:Cfg.CookiesPath

            if ($defaultPath) {
                Write-Host "`n  $('Saved cookies path'): " -ForegroundColor White -NoNewline
                Write-Host "$defaultPath" -ForegroundColor Cyan
                Write-Host "  $('Press Enter to use saved path, or enter a new one'):" -ForegroundColor Gray
            } else {
                Write-Host "`n  $('Enter path to cookies.txt: (drag in window)')" -ForegroundColor White
            }

            $inputPath = (Read-Host "  > ").Trim().Trim('"').Trim("'")

            if ([string]::IsNullOrWhiteSpace($inputPath)) {
                $cookiePath = $defaultPath
            } else {
                $cookiePath = $inputPath
            }

            if (-not (Test-Path $cookiePath)) {
                Write-Host "  [X] $('File not found')" -ForegroundColor Red
                Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
                Read-Host
                continue
            }

            if (-not $global:Cfg.PSObject.Properties['CookiesPath']) {
                $global:Cfg | Add-Member -NotePropertyName "CookiesPath" -NotePropertyValue $cookiePath
            } else {
                $global:Cfg.CookiesPath = $cookiePath
            }
            $global:Cfg | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8

            $authArgs = @("--cookies", $cookiePath)
        }

        Show-Banner "STEP 2: SELECT CONTENT TYPE"
        Write-Host "  [1] $('Video (MP4)')" -ForegroundColor White
        Write-Host "  [2] $('Audio (MP3)')" -ForegroundColor White
        Write-Host "  [3] $('Playlist')" -ForegroundColor White
        Write-Host "  [4] $('Video Fragment (by timecode)')" -ForegroundColor White
        Write-Host "  [5] $('Audio Fragment (by timecode)')" -ForegroundColor White
        Write-Host "  [6] $('Picture / Image by URL')" -ForegroundColor White
        Write-Host "  [0] $('Back to previous menu')" -ForegroundColor Red

        $contentChoice = Read-Host "  Choice"
        if ($contentChoice -eq '0') { continue }
        if ($contentChoice -notmatch '^[1-6]$') {
            Write-Host "`n  [!] $('Invalid choice')" -ForegroundColor Red
            Start-Sleep 1
            continue
        }

        # Для картинок [6] список вводится отдельным шагом ниже — здесь URL не запрашиваем,
        # иначе пользовательская вставка «склеивается» (URL + путь cookies) и попадает в yt-dlp битой
        if ($contentChoice -ne '6') {
            Write-Host "`n  $('Enter URL:')" -ForegroundColor White
            $url = Read-Host "  > "
        } else {
            $url = ""
        }

        $downloadArgs = @()
        $statusMsg = "Downloading..."
        $imagesDone = $false   # флаг ветки [6]: после картинок не заходить в видео-конвейер

        # Папка загрузки создаётся в корневой папке программы: $ScriptDir\downloaded
        $dlDir = Join-Path $ScriptDir "downloaded"
        if (-not (Test-Path $dlDir)) { New-Item -ItemType Directory -Path $dlDir -Force | Out-Null }
        $commonArgs = @("-P", $dlDir, "--restrict-filenames")

        switch ($contentChoice) {
            '1' {
                $formatString = Select-VideoQuality -Url $url -AuthArgs $authArgs
                $downloadArgs = @("-f", $formatString, "--merge-output-format", "mp4", $url)
            }
            '2' {
                $downloadArgs = @("-x", "--audio-format", "mp3", $url)
            }
            '3' {
                $downloadArgs = @("--yes-playlist", $url)
            }
            '4' {
                $formatString = Select-VideoQuality -Url $url -AuthArgs $authArgs
                Write-Host "  $('Start time (e.g., 1:30 or 1 30):')" -ForegroundColor White
                $start = (Read-Host "  > ").Trim().Replace(" ", ":")
                Write-Host "  $('End time (e.g., 1:30 or 1 30):')" -ForegroundColor White
                $end = (Read-Host "  > ").Trim().Replace(" ", ":")

                $section = "*$start-$end"
                $downloadArgs = @("--download-sections", $section, "-f", $formatString, "--merge-output-format", "mp4", "--force-keyframes-at-cuts", $url)
                $statusMsg = "Downloading fragment..."
            }
            '5' {
                Write-Host "  $('Start time (e.g., 1:30 or 1 30):')" -ForegroundColor White
                $start = (Read-Host "  > ").Trim().Replace(" ", ":")
                Write-Host "  $('End time (e.g., 1:30 or 1 30):')" -ForegroundColor White
                $end = (Read-Host "  > ").Trim().Replace(" ", ":")

                $section = "*$start-$end"
                $downloadArgs = @("-x", "--audio-format", "mp3", "--download-sections", $section, $url)
                $statusMsg = "Downloading audio fragment..."
            }
            '6' {
                # Скачивание картинок по URL — обрабатывается отдельно (без yt-dlp-конвейера видео)
                Write-Host "`n  $('You can enter several URLs separated by a comma, or a path to a .txt file with a list of URLs (one per line):')" -ForegroundColor Gray
                $imgInput = Read-Host "  > "

                $imageUrls = @()

                # 1) Извлекаем ВСЕ http(s)-ссылки из строки ввода. Регулярка останавливается на пробеле,
                #    запятой и кавычке — это защищает от «склеенных» вставок вида:
                #    https://...jpg?token=...""C:\Users\...\www.youtube.com_cookies (1).txt"
                $httpMatches = [regex]::Matches($imgInput, 'https?://[^\s,""'']+')
                if ($httpMatches.Count -gt 0) {
                    $imageUrls = @($httpMatches | ForEach-Object { $_.Value.TrimEnd(',', ';') })
                } else {
                    # 2) Введён путь к файлу со списком URL? Снимаем артефакты перетаскивания:
                    #    двойные кавычки (""...""), ведущие обратные слэши, обрамляющие кавычки.
                    $imgInput = $imgInput -replace '""+', '"'
                    $imgInput = $imgInput.Trim().Trim('"').Trim("'").TrimStart('\').Trim().Trim('"').Trim("'")
                    if ($imgInput -and (Test-Path $imgInput -ErrorAction SilentlyContinue)) {
                        Write-Host "  $('Reading URL list from file')..." -ForegroundColor Cyan
                        foreach ($line in (Get-Content $imgInput)) {
                            # В файле тоже возможна склейка — берём только http(s)-части строк
                            foreach ($m in [regex]::Matches($line, 'https?://[^\s,""'']+')) {
                                $imageUrls += $m.Value.TrimEnd(',', ';')
                            }
                        }
                    }
                }

                if (@($imageUrls).Count -gt 0) {
                    $imgDir = Join-Path $dlDir "images"
                    if (-not (Test-Path $imgDir)) { New-Item -ItemType Directory -Path $imgDir -Force | Out-Null }

                    Write-ErrorLog -Type "INFO" -FileName ($imageUrls -join ', ') -Details "Image download started | Count: $(@($imageUrls).Count) | Output folder: $imgDir" | Out-Null

                    Invoke-ImageDownload -Urls $imageUrls -OutputDir $imgDir -AuthArgs $authArgs
                } else {
                    Write-Host "  [X] $('No valid URLs entered')" -ForegroundColor Red
                }
                # Ветка картинок завершена: дальше — возврат в меню (см. флаг ниже),
                # видео-конвейер с пустым $url трогать нельзя
                $imagesDone = $true
            }
        }

        # Скачивание картинок [6] завершено — возвращаемся в начало цикла, минуя видео-конвейер.
        # Иначе fall-through с пустым $url выдавал пугающее "[X] Invalid URL..." после нажатия Enter.
        if ($imagesDone) {
            Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
            Read-Host
            continue
        }

        # Защита от пустого/битого ввода в основном конвейере: без корректного URL yt-dlp
        # вызывался без адреса и падал с "You must provide at least one URL" (ExitCode 2)
        if ($url -notmatch '^https?://') {
            Write-Host "`n  [X] $('Invalid URL. Please enter a link starting with http:// or https://')" -ForegroundColor Red
            Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
            Read-Host
            continue
        }

        Write-Host "`n  $statusMsg" -ForegroundColor Yellow
        Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  $('Tip'): Press L during download to write a log entry" -ForegroundColor DarkGray

        # Пишем в корневой лог начало каждой загрузки (INFO) — ошибки ищутся по метке [ERROR]
        Write-ErrorLog -Type "INFO" -FileName $url -Details "Download started | ContentChoice: $contentChoice | Output folder: $dlDir" | Out-Null

        # Снимаем обрамляющие кавычки с URL и пути cookies (артефакты вставки перетаскиванием),
        # иначе при пути с пробелом аргументы склеятся и yt-dlp не увидит URL ("You must provide at least one URL")
        $url = $url.Trim().Trim('"').Trim("'")
        if ($downloadArgs.Count -gt 0 -and $downloadArgs[-1] -match '^https?://') { $downloadArgs[-1] = $url }
        $authArgs = @($authArgs | ForEach-Object { if ($_ -is [string]) { $_.Trim().Trim('"').Trim("'") } else { $_ } })
        $downloadArgs = @($downloadArgs | ForEach-Object { if ($_ -eq $url) { $url } elseif ($_ -is [string]) { $_.Trim().Trim('"').Trim("'") } else { $_ } })
        # Пустые аргументы недопустимы: PowerShell склеивает их со следующим параметром
        $authArgs = @($authArgs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $downloadArgs = @($downloadArgs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $finalArgs = $authArgs + $commonArgs + $downloadArgs + @("--no-colors")
        $hasError = $false
        $dlOutput = @()
        $dlSw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
        & $ytdlpCmd @finalArgs 2>&1 | ForEach-Object {
            $line = $_.ToString()
            $dlOutput += $line
            if ([string]::IsNullOrWhiteSpace($line)) { return }

            # Лог по нажатию клавиши: [L] — записать текущее состояние загрузки в корневой лог
            if (Test-LoggingHotkey) {
                $res = Write-ProgressLog -Target $url -ElapsedSec $dlSw.Elapsed.TotalSeconds -Output $dlOutput
                if ($res.Success) {
                    Write-Host "  [LOG] $('State written to log'): $($res.LogFile)" -ForegroundColor Magenta
                } else {
                    Write-Host "  [X] $('Failed to write log')" -ForegroundColor Red
                }
            }

            if ($line -match '^\[download\]|\d+\.\d+%') {
                Write-Host $line -ForegroundColor Cyan
            }
            elseif ($line -match 'ERROR|failed|refused|403') {
                Write-Host $line -ForegroundColor Red
                $hasError = $true
            }
            elseif ($line -match 'WARNING') {
                Write-Host $line -ForegroundColor Yellow
            }
            elseif ($line -match '^\[ExtractAudio\]|^\[Merger\]|^\[Fixup\]|^\[Metadata\]|^\[Subtitles\]') {
                Write-Host $line -ForegroundColor Magenta
            }
            elseif ($line -match '^\[info\]') {
                Write-Host $line -ForegroundColor DarkGray
            }
            else {
                Write-Host $line -ForegroundColor White
            }
        }
        } catch {
            # Непредвиденная ошибка во время загрузки — в корневой лог
            $hasError = $true
            $dlOutput += "Unexpected error: $($_.Exception.Message)"
            Write-Host "  [X] $('Unexpected error during download')" -ForegroundColor Red
        }

        Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

        if ($LASTEXITCODE -eq 0 -and -not $hasError) {
            Write-Host "  [OK] $('Done')" -ForegroundColor Green
        }
        else {
            Write-Host "  [X] $('Error. Try using Cookies or clearing cache.')" -ForegroundColor Red
            Write-ErrorLog -Type "ERROR" -FileName $url -Details (
                "Stage: Download failed | ContentChoice: $contentChoice | ExitCode: $LASTEXITCODE`n" +
                "Command: $ytdlpCmd $($finalArgs -join ' ')`n" +
                "Last yt-dlp output:`n" + (($dlOutput | Select-Object -Last 40) -join "`n")
            )
            Write-Host "  [X] $('Logged to'): $script:ErrorLogFile" -ForegroundColor DarkGray
        }

        Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
        Read-Host
    }
    else {
        Write-Host "`n  [!] $('Invalid choice')" -ForegroundColor Red
        Start-Sleep 1
    }
} while ($true)