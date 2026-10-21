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
        $out = Join-Path $outDir "$base`_gray.mp4"
        $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,"-vf","hue=s=0","-c:v","libx264","-preset","medium","-crf","20")
        if ($audMode -eq '2') { $FFArgs += @("-an") } else { $FFArgs += @("-c:a","copy") }
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

# --- 3. Шакалитие видео (комичный эффект) ---
function Invoke-MiscWobble {
    $ff = Get-FFmpegPath
    if (-not $ff) { Write-Host "  [X] $('FFmpeg not found')" -ForegroundColor Red; Read-Host; return }

    $inPath = Ask-InputFile -Prompt "  $('Enter input video path: (drag the file into the window), or 0 to return:')" -AllowedExt $VideoExt
    if ($inPath -eq $false) { return }; if (-not $inPath) { return }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
    $outDir = Join-Path $ScriptDir "misc"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $out = Join-Path $outDir "$base`_wobble.mp4"

    Write-Host "`n  $('Effect intensity:')" -ForegroundColor White
    Write-Host "  [1] $('Soft')  [2] $('Medium')  [3] $('Crazy (max comedy)')  [0] $('Back')" -ForegroundColor White
    $lvl = Read-Host "  $('Intensity')"
    switch ($lvl) {
        '1' { $ampX = 6;  $ampY = 4; $freq = 0.8 }
        '2' { $ampX = 12; $ampY = 8; $freq = 1.5 }
        '3' { $ampX = 25; $ampY = 15; $freq = 3 }
        default { return }
    }

    # "Зашкал" = синусоидальное смещение пикселей (displace) + лёгкая резкость = комичный эффект дрожащего видео
    $logFile = Join-Path $TempDir "ffmpeg_misc_wobble.txt"
    $pi8 = [math]::Round([math]::PI/8, 4)     # шаг фазы по кадрам (N)
    $wfreq = [math]::Round($freq*2, 2)        # скорость покачивания по времени (T)
    $fc = "[0:v]split=3[base][mx][my];" +
          "[mx]format=gray,geq=lum='128+{0}*sin(N*{1}+T*{2}+X*0.05)'[dx];" +
          "[my]format=gray,geq=lum='128+{3}*cos(N*{1}-T*{2}+Y*0.05)'[dy];" +
          "[base][dx][dy]displace=edge=smear[v]" -f $ampX, $pi8, $wfreq, $ampY
    $FFArgs = @(
        "-hide_banner","-loglevel","error","-y",
        "-i", $inPath,
        "-filter_complex", $fc,
        "-map","[v]","-map","0:a?",
        "-c:v","libx264","-preset","fast","-crf","21","-c:a","copy",
        $out
    )

    Write-Host "`n  $('Processing...')" -ForegroundColor Yellow
    $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
    if ($code -ne 0 -or -not (Test-Path $out)) {
        # Резервный вариант: покачивание всего кадра (rotate), если displace недоступен
        $rotAmp = [math]::Round($ampX/60.0, 4)
        $FFArgs = @(
            "-hide_banner","-loglevel","error","-y","-i",$inPath,
            "-vf",("rotate='{0}*sin(2*PI*{1}*t)':fillcolor=black:ow='hypot(iw,ih)':oh=ow" -f $rotAmp, $freq),
            "-c:v","libx264","-preset","fast","-crf","21","-c:a","copy",
            $out
        )
        $code = Invoke-FFmpegJob -Exe $ff -FFArgs $FFArgs -LogFile $logFile
    }
    if ($code -eq 0 -and (Test-Path $out)) { Write-Host "  [OK] $('Saved'): $out" -ForegroundColor Green }
    else {
        Write-Host "  [X] $('Error')" -ForegroundColor Red
        Save-JobLog -BaseName $base -LogFile $logFile
        Get-Content $logFile -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
    Read-Host
}

# --- Меню Misc ---
do {
    Show-Banner "MISC EFFECTS"
    Write-Host "  [1] $('Black & White (photo/video)')" -ForegroundColor White
    Write-Host "  [2] $('Extract audio from video')" -ForegroundColor White
    Write-Host "  [3] $('Remove audio from video')" -ForegroundColor White
    Write-Host "  [4] $('Wobble video (comedy effect)')" -ForegroundColor White
    Write-Host "`n  [0] $('Back to Hub')" -ForegroundColor Red
    $choice = Read-Host "  $('Enter choice')"
    switch ($choice) {
        '1' { Invoke-MiscGrayscale }
        '2' { Invoke-MiscExtractAudio }
        '3' { Invoke-MiscRemoveAudio }
        '4' { Invoke-MiscWobble }
        '0' { return }
        default { Write-Host "`n  [!] $('Invalid choice')" -ForegroundColor Red; Start-Sleep 1 }
    }
} while ($true)
