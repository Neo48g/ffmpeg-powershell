#Requires -Version 5.1
$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
# Создание логов выключено по умолчанию; все логи сохраняются в папку logs
$global:Cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { @{EnableLogs=$false; LogsFolder=(Join-Path $ScriptDir "logs")} }
if (-not ($global:Cfg.PSObject.Properties['LogsFolder'] -or ($global:Cfg -is [System.Collections.IDictionary] -and $global:Cfg.Contains('LogsFolder')))) {
    $global:Cfg = $global:Cfg + @{ LogsFolder = (Join-Path $ScriptDir "logs") }
}
if (-not ($global:Cfg.PSObject.Properties['EnableLogs'] -or ($global:Cfg -is [System.Collections.IDictionary] -and $global:Cfg.Contains('EnableLogs')))) {
    $global:Cfg = $global:Cfg + @{ EnableLogs = $false }
}
function Show-Banner { param([string]$Title) Clear-Host; Write-Host "`n========================================================" -ForegroundColor Cyan; Write-Host "  $Title" -ForegroundColor Yellow; Write-Host "========================================================`n" -ForegroundColor Cyan }

$TempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$VideoExt = @('.mp4','.mkv','.mov','.avi','.webm','.flv','.wmv','.m4v','.mpg','.mpeg','.ts')
$ImageExt = @('.jpg','.jpeg','.png','.bmp','.tiff','.tif','.webp','.gif')

function Get-FFmpegPath {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-FFmpegJob {
    # Запускает ffmpeg с указанными аргументами, пишет лог и возвращает код возврата
    param([string]$Exe, [object[]]$FFArgs, [string]$LogFile)
    try {
        & $Exe @FFArgs 2>&1 | Out-File $LogFile -Encoding UTF8
        return $LASTEXITCODE
    } catch {
        $_ | Out-File $LogFile -Encoding UTF8
        return 1
    }
}

function Save-JobLog {
    param([string]$BaseName, [string]$LogFile)
    if ($global:Cfg.EnableLogs -and (Test-Path $LogFile)) {
        if (-not (Test-Path $global:Cfg.LogsFolder)) { New-Item -ItemType Directory -Path $global:Cfg.LogsFolder -Force | Out-Null }
        Copy-Item $LogFile (Join-Path $global:Cfg.LogsFolder "${BaseName}_misc.log") -Force
    }
}

function Ask-InputFile {
    param([string]$Prompt, [string[]]$AllowedExt)
    Write-Host "  $Prompt" -ForegroundColor White
    $inPath = (Read-Host "  > ").Trim().Trim('"')
    if ($inPath -eq '0' -or [string]::IsNullOrWhiteSpace($inPath)) { return $null }
    if (-not (Test-Path $inPath)) { Write-Host "  [X] $('File not found')" -ForegroundColor Red; Start-Sleep 2; return $false }
    $ext = [System.IO.Path]::GetExtension($inPath).ToLower()
    if ($AllowedExt -notcontains $ext) {
        Write-Host "  [X] $('Unsupported file format'): $ext ($('Supported'): $($AllowedExt -join ', '))" -ForegroundColor Red
        Start-Sleep 2
        return $false
    }
    return (Resolve-Path $inPath).Path
}

function Get-AudioCodecName {
    param([string]$InPath)
    # Пытаемся определить кодек аудио для выбора способа сохранения (copy где возможно)
    $codec = ''
    try {
        $codec = (& ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$InPath" 2>$null | Select-Object -First 1)
    } catch {}
    return ("$codec").Trim()
}

# --- 1. Чёрно-белое фото/видео ---
function Invoke-MiscGrayscale {
    $ff = Get-FFmpegPath
    if (-not $ff) { Write-Host "  [X] $('FFmpeg not found')" -ForegroundColor Red; Read-Host; return }

    $inPath = Ask-InputFile -Prompt "  $('Enter input photo/video path: (drag the file into the window), or 0 to return:')" -AllowedExt ($ImageExt + $VideoExt)
    if ($inPath -eq $false) { return }; if (-not $inPath) { return }

    $ext = [System.IO.Path]::GetExtension($inPath).ToLower()
    $isImage = $ImageExt -contains $ext
    $base = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
    $outDir = Join-Path $ScriptDir "misc"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    Write-Host "`n  $('Processing...')" -ForegroundColor Yellow
    $logFile = Join-Path $TempDir "ffmpeg_misc_gray.txt"
    if ($isImage) {
        # GIF — развёртываем в анимированный ч/б GIF; остальные форматы сохраняем с тем же расширением
        $outExt = $ext
        $out = Join-Path $outDir "$base`_gray$outExt"
        $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,"-vf","hue=s=0")
        if ($ext -eq '.gif') { $FFArgs += @("-loop","0") }
        if ($ext -eq '.jpg' -or $ext -eq '.jpeg') { $FFArgs += @("-q:v","2") }
        if ($ext -eq '.png') { $FFArgs += @("-compression_level","9") }
        $FFArgs += $out
    } else {
        # Аудио перекодируется в AAC: "-c:a copy" несовместим с MP4 для PCM-дорожек (alac/pcm из MOV)
        $out = Join-Path $outDir "$base`_gray.mp4"
        $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,
            "-vf","scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1,hue=s=0,format=yuv420p",
            "-c:v","libx264","-preset","medium","-crf","20","-pix_fmt","yuv420p",
            "-c:a","aac","-b:a","192k")
        $FFArgs += $out
    }

    $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
    if ($code -eq 0 -and (Test-Path $out)) { Write-Host "  [OK] $('Saved'): $out" -ForegroundColor Green }
    else {
        Write-Host "  [X] $('Error')" -ForegroundColor Red
        Save-JobLog -BaseName $base -LogFile $logFile
        Get-Content $logFile -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
    Read-Host
}

# --- 2a. Извлечение аудио из видео ---
function Invoke-MiscExtractAudio {
    $ff = Get-FFmpegPath
    if (-not $ff) { Write-Host "  [X] $('FFmpeg not found')" -ForegroundColor Red; Read-Host; return }

    $inPath = Ask-InputFile -Prompt "  $('Enter input video path: (drag the file into the window), or 0 to return:')" -AllowedExt $VideoExt
    if ($inPath -eq $false) { return }; if (-not $inPath) { return }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
    $outDir = Join-Path $ScriptDir "misc"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    Write-Host "`n  $('Select output format:')" -ForegroundColor White
    Write-Host "  [1] $('Original codec (no re-encoding, fast)')" -ForegroundColor White
    Write-Host "  [2] MP3   [3] M4A (AAC)   [4] OPUS   [5] FLAC   [6] WAV   [0] $('Back')" -ForegroundColor White
    $fmt = Read-Host "  Format"
    if ($fmt -eq '0' -or [string]::IsNullOrWhiteSpace($fmt)) { return }

    Write-Host "`n  $('Processing...')" -ForegroundColor Yellow
    $logFile = Join-Path $TempDir "ffmpeg_misc_audio.txt"
    $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,"-vn")
    switch ($fmt) {
        '1' {
            $codec = Get-AudioCodecName -InPath $inPath
            if (-not $codec) { Write-Host "  [X] $('No audio track found in this video')" -ForegroundColor Red; Start-Sleep 2; return }
            $map = [ordered]@{ 'aac'=@('.m4a','ipod'); 'mp3'=@('.mp3','mp3'); 'opus'=@('.opus','opus'); 'flac'=@('.flac','flac'); 'vorbis'=@('.ogg','ogg'); 'pcm_s16le'=@('.wav','wav'); 'pcm_s24le'=@('.wav','wav') }
            if ($map.Contains($codec)) { $outExt = $map[$codec][0]; $muxer = $map[$codec][1] }
            else { $outExt = ".$codec"; $muxer = $null }
            $out = Join-Path $outDir "$base`_audio$outExt"
            $FFArgs += @("-acodec","copy")
            if ($muxer) { $FFArgs += @("-f",$muxer) }
            $FFArgs += $out
        }
        '2' { $out = Join-Path $outDir "$base`_audio.mp3"; $FFArgs += @("-acodec","libmp3lame","-q:a","2",$out) }
        '3' { $out = Join-Path $outDir "$base`_audio.m4a"; $FFArgs += @("-acodec","aac","-b:a","192k",$out) }
        '4' { $out = Join-Path $outDir "$base`_audio.opus"; $FFArgs += @("-acodec","libopus","-b:a","128k",$out) }
        '5' { $out = Join-Path $outDir "$base`_audio.flac"; $FFArgs += @("-acodec","flac",$out) }
        '6' { $out = Join-Path $outDir "$base`_audio.wav";  $FFArgs += @("-acodec","pcm_s16le",$out) }
        default { return }
    }

    $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
    if ($code -eq 0 -and (Test-Path $out)) { Write-Host "  [OK] $('Saved'): $out" -ForegroundColor Green }
    else {
        Write-Host "  [X] $('Error')" -ForegroundColor Red
        Save-JobLog -BaseName $base -LogFile $logFile
        Get-Content $logFile -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
    Read-Host
}

# --- 2b. Удаление аудио из видео ---
function Invoke-MiscRemoveAudio {
    $ff = Get-FFmpegPath
    if (-not $ff) { Write-Host "  [X] $('FFmpeg not found')" -ForegroundColor Red; Read-Host; return }

    $inPath = Ask-InputFile -Prompt "  $('Enter input video path: (drag the file into the window), or 0 to return:')" -AllowedExt $VideoExt
    if ($inPath -eq $false) { return }; if (-not $inPath) { return }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
    $srcExt = [System.IO.Path]::GetExtension($inPath).ToLower()
    $outDir = Join-Path $ScriptDir "misc"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $outExt = if ($srcExt -in @('.mp4','.m4v','.mov')) { $srcExt } else { '.mp4' }
    $out = Join-Path $outDir "$base`_mute$outExt"

    Write-Host "`n  $('Processing...')" -ForegroundColor Yellow
    $logFile = Join-Path $TempDir "ffmpeg_misc_mute.txt"
    $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,"-an","-c:v","copy",$out)

    $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
    if ($code -ne 0 -or -not (Test-Path $out)) {
        # Резервный вариант: контейнер не принял stream copy — перекодируем
        $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,"-an","-c:v","libx264","-preset","medium","-crf","20",$out)
        $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
    }
    if ($code -eq 0 -and (Test-Path $out)) { Write-Host "  [OK] $('Saved'): $out" -ForegroundColor Green }
    else {
        Write-Host "  [X] $('Error')" -ForegroundColor Red
        Save-JobLog -BaseName $base -LogFile $logFile
        Get-Content $logFile -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
    Read-Host
}

# --- 4. Зашакаливание (деградация до комичного эффекта) ---
function Read-CustomParam {
    # Читает одно значение для пользовательского пресета; Enter оставляет текущее, 0 отменяет ввод
    param([string]$Name, [string]$Hint, [double]$Cur, [double]$Min, [double]$Max, [ref]$Out)
    while ($true) {
        $raw = (Read-Host "  ${Name} [$Cur]").Trim().Replace(',', '.')
        if ($raw -eq '') { $Out.Value = $Cur; return $true }
        if ($raw -eq '0') { return $false }
        $val = 0.0
        if (-not [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
            Write-Host "  [X] $('Invalid choice'): $Hint" -ForegroundColor Red; continue
        }
        if ($val -lt $Min -or $val -gt $Max) {
            Write-Host "  [!] ${Hint}: $Min..$Max, $([Math]::Round($val,4)) -> $([Math]::Max($Min,[Math]::Min($Max,$val)))" -ForegroundColor DarkYellow
            $val = [Math]::Max($Min, [Math]::Min($Max, $val))
        }
        $Out.Value = $val
        return $true
    }
}

function Invoke-MiscDeepfried {
    $ff = Get-FFmpegPath
    if (-not $ff) { Write-Host "  [X] $('FFmpeg not found')" -ForegroundColor Red; Read-Host; return }

    $inPath = Ask-InputFile -Prompt "  $('Enter input photo/video path: (drag the file into the window), or 0 to return:')" -AllowedExt ($ImageExt + $VideoExt)
    if ($inPath -eq $false) { return }; if (-not $inPath) { return }

    $ext = [System.IO.Path]::GetExtension($inPath).ToLower()
    $isImage = $ImageExt -contains $ext
    $base = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
    $outDir = Join-Path $ScriptDir "misc"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    # Уровень комичности: 1 — лёгкое, 2 — среднее, 3 — сильное (но не запредельное), 4 — свои значения
    Write-Host "`n  $('Select deep-fry level:')" -ForegroundColor White
    Write-Host "  [1] $('Soft')   [2] $('Medium')   [3] $('Strong')   [4] $('Custom...')   [0] $('Back')" -ForegroundColor White
    $lvlRaw = Read-Host "  $('Level')"
    if ($lvlRaw -eq '0' -or [string]::IsNullOrWhiteSpace($lvlRaw)) { return }
    $qval = 2          # качество JPEG/GIF-артефактов (mjpeg q:v и GIF b:v = qval*200 kбит/с): 1..31, меньше = сильнее
    $maxbrk = 150      # потолок битрейта видео в кбит/с (-maxrate/-bufsize); 0 = без ограничений
    switch ($lvlRaw) {
        '1' { $scale = 0.88; $crf = 25; $abr = '124k'; $volDb = 3; $gop = 12 }
        '2' { $scale = 0.60; $crf = 30; $abr = '86k'; $volDb = 6; $gop = 6 }
        '3' { $scale = 0.30; $crf = 35; $abr = '42k'; $volDb = 9; $gop = 6 }
        '4' {
            # Пользовательские значения: по умолчанию берём Medium, дальше каждое поле можно переписать (Enter = оставить)
            $scale = 0.20; $crf = 36; $abr = '48k'; $volDb = 9; $gop = 6
            Write-Host "`n  $('Custom values:') (Enter = keep, 0 = cancel)" -ForegroundColor Cyan
            $v = 0.0
            if (-not (Read-CustomParam -Name 'Scale factor (0.05..0.95, lower = more pixelated)' -Hint 'Must be 0.05..0.95' -Cur $scale -Min 0.05 -Max 0.95 -Out ([ref]$v))) { return }
            $scale = $v
            $v = 0.0
            if (-not (Read-CustomParam -Name 'CRF video quality (18..51, higher = more artifacts)' -Hint 'Must be 18..51' -Cur $crf -Min 18 -Max 51 -Out ([ref]$v))) { return }
            $crf = [int][Math]::Round($v)
            $v = 0.0
            if (-not (Read-CustomParam -Name 'Audio bitrate kbps (8..320, lower = worse)' -Hint 'Must be 8..320' -Cur ([double](($abr -replace 'k',''))) -Min 8 -Max 320 -Out ([ref]$v))) { return }
            $abr = "$([int][Math]::Round($v))k"
            $v = 0.0
            if (-not (Read-CustomParam -Name 'Audio overload dB (0..24)' -Hint 'Must be 0..24' -Cur $volDb -Min 0 -Max 24 -Out ([ref]$v))) { return }
            $volDb = $v
            $v = 0.0
            if (-not (Read-CustomParam -Name 'GOP size frames (1..300, lower = chunkier)' -Hint 'Must be 1..300' -Cur $gop -Min 1 -Max 300 -Out ([ref]$v))) { return }
            $gop = [int][Math]::Round($v)
            $v = 0.0
            if (-not (Read-CustomParam -Name 'JPEG/GIF artifact q (1..31, lower = stronger)' -Hint 'Must be 1..31' -Cur $qval -Min 1 -Max 31 -Out ([ref]$v))) { return }
            $qval = [int][Math]::Round($v)
            $v = 0.0
            if (-not (Read-CustomParam -Name 'Video max bitrate kbps (0 = unlimited)' -Hint 'Must be 0..5000' -Cur $maxbrk -Min 0 -Max 5000 -Out ([ref]$v))) { return }
            $maxbrk = [int][Math]::Round($v)
        }
        default { $scale = 0.20; $crf = 36; $abr = '48k'; $volDb = 9; $gop = 6 }
    }

    Write-Host "`n  $('Processing...')" -ForegroundColor Yellow
    $logFile = Join-Path $TempDir "ffmpeg_misc_deep.txt"
    # Целевые размеры берутся из исходника: сначала понижение до чётных размеров (гарантия делимости на 2 для libx264),
    # затем обратное увеличение соседним интерполятором ровно до исходного W:H.
    # Прежняя запись scale=iw*${up} давала нечётные размеры (например 1279x719) и падение либх264 с ошибкой "Could not open encoder before EOF".
    $tgtW = ''; $tgtH = ''
    try {
        # берём размеры из потока-изображения, а не из контейнера (у mp4/mkv контейнер может врать)
        $dimLine = (& ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$inPath" 2>$null | Select-Object -First 1)
        $dimParts = ("$dimLine").Trim() -split ','
        if ($dimParts.Count -ge 2) { $tgtW = $dimParts[0]; $tgtH = $dimParts[1] }
    } catch {}
    if (-not $tgtW -or -not $tgtH) {
        # если ffprobe недоступен — fallback: понижение + увеличение с принудительно чётными размерами
        $vfDown = "scale=trunc(iw*${scale}/2)*2:trunc(ih*${scale}/2)*2:flags=neighbor,scale=trunc(iw/${scale}/2)*2:trunc(ih/${scale}/2)*2:flags=neighbor"
    } else {
        $vfDown = "scale=trunc(iw*${scale}/2)*2:trunc(ih*${scale}/2)*2:flags=neighbor,scale=${tgtW}:${tgtH}:flags=neighbor"
    }

    if ($isImage) {
        # GIF сохраняем анимированным (деградация через пиксельизацию + низкий битрейт);
        # остальные картинки — JPEG-артефакты через mjpeg q:v 2, если исходник не PNG;
        # для PNG делаем два прохода: деградированный JPEG во временном файле -> пересборка в PNG (формат сохраняется)
        $outExt = if ($ext -eq '.gif') { '.gif' } elseif ($ext -in @('.jpg','.jpeg')) { '.jpg' } else { $ext }
        $out = Join-Path $outDir "$base`_deepfry$outExt"
        $logFile2 = Join-Path $TempDir "ffmpeg_misc_deep2.txt"
        $tmpJpg = Join-Path $TempDir "ffmpeg_misc_deep_tmp.jpg"
        # -frames:v 1 — берём только первый кадр (для статичных картинок; GIF обрабатывается целиком ниже)
        $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,"-vf","${vfDown},setsar=1")
        if ($ext -eq '.gif') {
            $FFArgs += @("-loop","0","-b:v","$([int]$qval * 200)k")
            $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
        } elseif ($ext -eq '.png') {
            $FFArgs += @("-frames:v","1","-c:v","mjpeg","-q:v","$qval",$tmpJpg)
            $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
            if ($code -eq 0 -and (Test-Path $tmpJpg)) {
                $FFArgs2 = @("-hide_banner","-loglevel","error","-y","-i",$tmpJpg,"-compression_level","9",$out)
                $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs2 -LogFile $logFile2
                Remove-Item $tmpJpg -Force -ErrorAction SilentlyContinue
            }
        } else {
            $FFArgs += @("-frames:v","1","-c:v","mjpeg","-q:v","$qval",$out)
            $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
        }
    } else {
        # Проверка наличия аудиодорожки: без неё перегруз звука невозможен
        $acb = ''
        try {
            $acb = (& ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$inPath" 2>$null | Select-Object -First 1)
        } catch {}
        $hasAudio = -not [string]::IsNullOrWhiteSpace("$acb")
        if (-not $hasAudio) { Write-Host "  [!] $('No audio track found in this video')" -ForegroundColor DarkYellow }

        $out = Join-Path $outDir "$base`_deepfry.mp4"
        # Перегруз звука: умеренная громкость с клиппингом лимитером + компрессор (без запредельного дисторшна)
        $volBoost2 = [double]$volDb + 3
        $afOver = "volume=${volDb}dB:precision=fixed,alimiter=limit=0.7:attack=5:release=50,acompressor=threshold=0.05:ratio=8:attack=5:release=50,volume=${volBoost2}dB,alimiter=limit=0.95:attack=5:release=50"
        $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,
            "-vf","${vfDown},setsar=1,format=yuv420p",
            "-c:v","libx264","-preset","fast","-crf","$crf",
            "-g","$gop","-keyint_min","$gop")
        if ($maxbrk -gt 0) {
            # Принудительный низкий битрейт усиливает артефакты сжатия; minrate=maxrate = жёсткий CBR-потолок
            $minbrk = [Math]::Min(50, $maxbrk)
            $FFArgs += @("-minrate","${minbrk}k","-maxrate","${maxbrk}k","-bufsize","$([int]$maxbrk * 2)k")
        }
        if ($hasAudio) { $FFArgs += @("-af",$afOver,"-c:a","aac","-b:a",$abr) } else { $FFArgs += @("-an") }
        $FFArgs += $out
        $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
    }

    if ($code -eq 0 -and (Test-Path $out)) { Write-Host "  [OK] $('Saved'): $out" -ForegroundColor Green }
    else {
        Write-Host "  [X] $('Error')" -ForegroundColor Red
        Save-JobLog -BaseName $base -LogFile $logFile
        Get-Content $logFile -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
    Read-Host
}

# --- Меню Misc ---
do {
    Show-Banner "MISC EFFECTS"
    Write-Host "  [1] $('Black & White')" -ForegroundColor White
    Write-Host "  [2] $('Extract audio from video')" -ForegroundColor White
    Write-Host "  [3] $('Remove audio from video')" -ForegroundColor White
    Write-Host "  [4] $('Deep-fry (comedy low quality)')" -ForegroundColor White
    Write-Host "`n  [0] $('Back to Hub')" -ForegroundColor Red
    $choice = Read-Host "  $('Enter choice')"
    switch ($choice) {
        '1' { Invoke-MiscGrayscale }
        '2' { Invoke-MiscExtractAudio }
        '3' { Invoke-MiscRemoveAudio }
        '4' { Invoke-MiscDeepfried }
        '0' { return }
        default { Write-Host "`n  [!] $('Invalid choice')" -ForegroundColor Red; Start-Sleep 1 }
    }
} while ($true)
