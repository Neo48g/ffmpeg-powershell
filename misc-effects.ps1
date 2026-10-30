#Requires -Version 5.1
$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
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

$TempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
# --- Логирование (папка logs в корне; все логи сохраняются туда) ---
$script:LogsFolder = [string]$global:Cfg.LogsFolder
$script:ErrorLogFile = Join-Path $script:LogsFolder "misc_errors.log"

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
        if (-not (Test-Path $script:ErrorLogFile)) {
            Set-Content -Path $script:ErrorLogFile -Value @(
                "=== Misc effects error log | Root folder: $ScriptDir | Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===", ""
            ) -Encoding UTF8
        }
        $entry = @(
            "======================================================================"
            "[$Type] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "File: $FileName"
            "Details:"
            $Details
            ""
        ) -join [Environment]::NewLine
        Add-Content -Path $script:ErrorLogFile -Value $entry -Encoding UTF8
        return $true
    } catch { return $false }
}
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
    # Вызывается только при ошибке ffmpeg: логи ошибок сохраняются ВСЕГДА в папку logs (корень)
    param([string]$BaseName, [string]$LogFile)
    $miscLog = Join-Path $script:LogsFolder "${BaseName}_misc.log"
    $tail = "(no output captured)"
    if (Test-Path $LogFile) {
        try { $tail = ((Get-Content $LogFile -Tail 40 -ErrorAction SilentlyContinue) -join "`n") } catch {}
        if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
        Copy-Item $LogFile $miscLog -Force -ErrorAction SilentlyContinue
    }
    Write-ErrorLog -Type "ERROR" -FileName $BaseName -Details ("Stage: FFmpeg job failed`nFull FFmpeg log saved to: $miscLog`nLast FFmpeg output:`n$tail") | Out-Null
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

function Get-AudioStreamList {
    # Возвращает список всех аудиодорожек медиафайла: индекс audio-потока (0:a:N), кодек, язык, название дорожки
    param([string]$InPath)
    $list = @()
    try {
        $lines = & ffprobe -v error -select_streams "a" -show_entries "stream=index,codec_name:stream_tags=language,title" -of "csv=p=0" "$InPath" 2>$null
        $audioNo = 0   # порядковый номер аудиодорожки для -map 0:a:N (ffprobe нумерует потоки в файле сквозным индексом)
        foreach ($line in @($lines)) {
            $s = ("$line").Trim()
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $parts = @($s.Split(',') | ForEach-Object { ('{0}' -f $_).Trim() })
            if ($parts.Count -lt 2 -or $parts[0] -notmatch '^\d+$') { continue }
            $codecName = $parts[1]
            if (-not $codecName) { continue }
            $lang = ''; $title = ''
            foreach ($t in $parts) {
                if ($t -like 'language=*') { $lang  = $t.Substring(9) }
                elseif ($t -like 'title=*') { $title = $t.Substring(6) }
            }
            $list += [pscustomobject]@{ Index = "$audioNo"; Codec = $codecName; Language = $lang; Title = $title }
            $audioNo++
        }
    } catch {}
    return $list
}

function Get-MuxerForCodec {
    # Подбирает контейнер/максер и расширение для stream copy выбранного аудиокодека
    param([string]$Codec)
    switch ($Codec) {
        'aac'        { return @{ Ext = '.m4a'; Muxer = 'ipod' } }
        'mp3'        { return @{ Ext = '.mp3'; Muxer = 'mp3' } }
        'opus'       { return @{ Ext = '.opus'; Muxer = 'opus' } }
        'flac'       { return @{ Ext = '.flac'; Muxer = 'flac' } }
        'vorbis'     { return @{ Ext = '.ogg'; Muxer = 'ogg' } }
        'pcm_s16le'  { return @{ Ext = '.wav'; Muxer = 'wav' } }
        'pcm_s24le'  { return @{ Ext = '.wav'; Muxer = 'wav' } }
        'pcm_f32le'  { return @{ Ext = '.wav'; Muxer = 'wav' } }
        'alac'       { return @{ Ext = '.m4a'; Muxer = 'ipod' } }
        default      { return @{ Ext = '.mkv'; Muxer = 'matroska' } }  # ac3/eac3/dts/truehd и прочие — в MKV без перекодирования
    }
}

function Test-AudioFileValid {
    # Проверяет, что извлечённый файл действительно содержит аудиопоток (ffmpeg может вернуть 0 при пустом выводе)
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $c = & ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$Path" 2>$null
        return -not [string]::IsNullOrWhiteSpace(("$c").Trim())
    } catch { return $false }
}

function Show-AudioTrackList {
    # Печатает список аудиодорожек вида: [N] Track M: codec | Language: xx | title
    param($Tracks)
    for ($i = 0; $i -lt $Tracks.Count; $i++) {
        $t = $Tracks[$i]
        $info = "[$($i+1)] $('Track') $($t.Index): $($t.Codec)"
        if ($t.Language -and $t.Language -ne 'und') { $info += " | $('Language'): $($t.Language)" }
        if ($t.Title) { $info += " | $($t.Title)" }
        Write-Host "  $info" -ForegroundColor White
    }
}

function Select-AudioTracks {
    # Предлагает выбрать какую аудиодорожку извлечь (или каждую/все). Возвращает массив выбранных дорожек.
    param($Tracks)
    if ($Tracks.Count -eq 1) {
        # Дорожка одна — выбирать нечего
        return @($Tracks[0])
    }
    while ($true) {
        Write-Host "`n  $('Select an audio track to extract, or E to extract each track:')`n" -ForegroundColor White
        Show-AudioTrackList -Tracks $Tracks
        Write-Host "  [A] $('All tracks')   [E] $('Each track as a separate file')   [0] $('Back')" -ForegroundColor DarkGray
        $sel = (Read-Host "  $('Track')").Trim()
        if ($sel -eq '0' -or [string]::IsNullOrWhiteSpace($sel)) { return $null }
        if ($sel -match '^(?i:a)$') { return ,@($Tracks) }
        if ($sel -match '^(?i:e)$') { return ,@(@($Tracks)) }
        if ($sel -match '^[\d,\s]+$') {
            $picked = @(); $bad = $false
            foreach ($p in ($sel -split '[,\s]+' | Where-Object { $_ -ne '' })) {
                $idx = [int]$p - 1
                if ($idx -lt 0 -or $idx -ge $Tracks.Count) { $bad = $true; break }
                if ($picked.Index -notcontains $Tracks[$idx].Index) { $picked += $Tracks[$idx] }
            }
            if ($bad) {
                Write-Host "  [X] $('Invalid selection') (1..$($Tracks.Count))" -ForegroundColor Red; Start-Sleep 1; continue
            }
            if ($picked.Count -gt 0) { return ,@($picked) }
        }
        Write-Host "  [X] $('Invalid selection')" -ForegroundColor Red; Start-Sleep 1
    }
}

function Ask-AudioFormat {
    # После выбора дорожки предлагает формат извлечения.
    # Возвращает hashtable: Copy=$true (stream copy без перекодирования, контейнер подберётся по кодеку дорожки)
    # либо Copy=$false и Encoder (целевой кодировщик: mp3/aac/opus/flac/wav).
    while ($true) {
        Write-Host "`n  $('Select output format:')`n" -ForegroundColor White
        Write-Host "  [1] $('Original codec (no re-encoding, fast)')" -ForegroundColor White
        Write-Host "  [2] MP3   [3] M4A (AAC)   [4] OPUS   [5] FLAC   [6] WAV" -ForegroundColor White
        Write-Host "  [0] $('Back')" -ForegroundColor White
        $fmt = (Read-Host "  $('Format')").Trim()
        if ($fmt -eq '0' -or [string]::IsNullOrWhiteSpace($fmt)) { return $null }
        if ($fmt -notin @('1','2','3','4','5','6')) { Write-Host "  [X] $('Invalid selection')" -ForegroundColor Red; Start-Sleep 1; continue }
        if ($fmt -eq '1') { return @{ Copy = $true } }
        $mapFmt = @{ '2'='libmp3lame'; '3'='aac'; '4'='libopus'; '5'='flac'; '6'='pcm_s16le' }
        return @{ Copy = $false; Encoder = $mapFmt[$fmt] }
    }
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

    # --- Шаг 1: после ввода видеофайла предлагаем выбрать аудиодорожку (или каждую) ---
    $allTracks = @(Get-AudioStreamList -InPath $inPath)
    if ($allTracks.Count -eq 0) { Write-Host "  [X] $('No audio track found in this video')" -ForegroundColor Red; Start-Sleep 2; return }

    if ($allTracks.Count -gt 1) {
        Write-Host "`n  $('Audio tracks found'): $($allTracks.Count)" -ForegroundColor White
    }
    $sel = Select-AudioTracks -Tracks $allTracks
    if ($null -eq $sel) { return }   # возвращаемся в меню

    $eachMode = ($sel.Count -gt 1)   # выбрано несколько дорожек (каждая/все) — каждая сохраняется отдельным файлом
    $multi = ($eachMode -or $allTracks.Count -gt 1)

    # --- Шаг 2: после выбора дорожки предлагаем формат извлечения (один раз для всех выбранных дорожек) ---
    $fmtSel = Ask-AudioFormat
    if ($null -eq $fmtSel) { return }  # «Назад» — возвращаемся в меню

    function script:Build-ExtractArgs {
        param([string]$InPath, $Track, $Fmt, [string]$Out, [switch]$MapTrack)
        # Собирает аргументы ffmpeg для одной дорожки: stream copy либо перекодирование в выбранный формат
        $a = @("-hide_banner","-loglevel","error","-y","-i",$InPath)
        if ($MapTrack) { $a += @("-map","0:a:$($Track.Index)","-vn","-map_metadata","-1") } else { $a += "-vn" }
        if ($Fmt.Copy) {
            # Stream copy: контейнер подбирается под кодек именно этой дорожки
            $mk = Get-MuxerForCodec -Codec $Track.Codec
            $a += @("-c:a","copy","-f",$mk.Muxer,$Out)
        }
        else {
            $a += @("-c:a",$Fmt.Encoder)
            switch ($Fmt.Encoder) {
                'libmp3lame' { $a += @("-q:a","2") }
                'aac'        { $a += @("-b:a","192k") }
                'libopus'    { $a += @("-b:a","128k") }
            }
            $a += $Out
        }
        return $a
    }

    function script:Get-AudioOutExt {
        param($Fmt, $Track)
        # Расширение выходного файла: по контейнеру кодировщика либо по максеру оригинального кодека
        if (-not $Fmt.Copy) {
            $encExt = @{ 'libmp3lame'='.mp3'; 'aac'='.m4a'; 'libopus'='.opus'; 'flac'='.flac'; 'pcm_s16le'='.wav' }
            if ($encExt.ContainsKey($Fmt.Encoder)) { return $encExt[$Fmt.Encoder] }
        }
        return (Get-MuxerForCodec -Codec $Track.Codec).Ext
    }

    function script:Extract-AudioTrack {
        param([string]$Ff, [string]$InPath, [string]$Base, [string]$OutDir, $Track, $Fmt, [bool]$Multi)
        # Извлекает одну аудиодорожку в выбранном формате; возвращает $true при успехе
        $safeBase = ($Base -replace '[\\/:*?"<>|]', '_')
        $suffix = ''
        if ($Multi) {
            $suffix = "-a$($Track.Index)"
            if ($Track.Language -and $Track.Language -ne 'und') { $suffix += "_$($Track.Language)" }
        }
        $out = Join-Path $OutDir "$safeBase${suffix}_audio$(Get-AudioOutExt -Fmt $Fmt -Track $Track)"
        $logFile = Join-Path $TempDir "ffmpeg_misc_audio.txt"
        $FFArgs = Build-ExtractArgs -InPath $InPath -Track $Track -Fmt $Fmt -Out $out -MapTrack:$Multi
        $code = Invoke-FFmpegJob -Exe $Ff -FFArgs $FFArgs -LogFile $logFile
        if ($Fmt.Copy -and ($code -ne 0 -or -not (Test-AudioFileValid -Path $out))) {
            # Резервный вариант: stream copy в этот контейнер невозможен — перекодируем дорожку в AAC (M4A)
            if (Test-Path $out) { Remove-Item $out -Force -ErrorAction SilentlyContinue }
            $out = Join-Path $OutDir "$safeBase${suffix}_audio.m4a"
            $FFArgs = Build-ExtractArgs -InPath $InPath -Track $Track -Fmt @{ Copy = $false; Encoder = 'aac' } -Out $out -MapTrack:$Multi
            $code = Invoke-FFmpegJob -Exe $Ff -FFArgs $FFArgs -LogFile $logFile
        }
        if ($code -eq 0 -and (Test-Path $out)) {
            Write-Host "  [OK] $('Saved'): $out" -ForegroundColor Green
            return $true
        }
        Write-Host "  [X] $('Error'): $('Track') $($Track.Index)" -ForegroundColor Red
        Save-JobLog -BaseName "${Base}_track$($Track.Index)" -LogFile $logFile
        Get-Content $logFile -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        return $false
    }

    Write-Host "`n  $('Processing...')" -ForegroundColor Yellow
    $okCount = 0; $failCount = 0
    foreach ($t in $sel) {
        if (Extract-AudioTrack -Ff $ff -InPath $inPath -Base $base -OutDir $outDir -Track $t -Fmt $fmtSel -Multi $multi) {
            $okCount++
        } else {
            $failCount++
        }
    }
    if ($eachMode) {
        Write-Host "`n  $('Done'): $okCount $('file(s) saved')" -ForegroundColor Green
        if ($failCount -gt 0) { Write-Host "  [!] $('Failed'): $failCount" -ForegroundColor DarkYellow }
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
    # Параметры "жара" (одинаковы для картинок и видео): contrast/saturation/hueShift/bright/gain — цветовой дисторшн;
    # crf/gop/maxbrk/abr/volDb — только для видео; qval — сила JPEG/GIF-артефактов для картинок
    switch ($lvlRaw) {
        '1' { $scale = 0.88; $crf = 25; $abr = '124k'; $volDb = 3; $gop = 12; $contrast = 1.18; $saturation = 1.7; $hueShift = -4;  $bright = 0.02; $gain = 1.05 }
        '2' { $scale = 0.60; $crf = 30; $abr = '86k'; $volDb = 6; $gop = 6;  $contrast = 1.35; $saturation = 2.3; $hueShift = -8;  $bright = 0.05; $gain = 1.12 }
        '3' { $scale = 0.30; $crf = 35; $abr = '42k'; $volDb = 9; $gop = 6;  $contrast = 1.5;  $saturation = 2.9; $hueShift = -12; $bright = 0.07; $gain = 1.18 }
        '4' {
            # Пользовательские значения: по умолчанию берём Strong, дальше каждое поле можно переписать (Enter = оставить)
            $scale = 0.20; $crf = 36; $abr = '48k'; $volDb = 9; $gop = 6
            $contrast = 1.55; $saturation = 3.0; $hueShift = -12; $bright = 0.07; $gain = 1.2
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
            $v = 0.0
            if (-not (Read-CustomParam -Name 'Fry contrast (1.0..2.0, higher = harsher)' -Hint 'Must be 1.0..2.0' -Cur $contrast -Min 1.0 -Max 2.0 -Out ([ref]$v))) { return }
            $contrast = $v
            $v = 0.0
            if (-not (Read-CustomParam -Name 'Fry saturation (1.0..4.0, higher = more acid)' -Hint 'Must be 1.0..4.0' -Cur $saturation -Min 1.0 -Max 4.0 -Out ([ref]$v))) { return }
            $saturation = $v
            $v = 0.0
            if (-not (Read-CustomParam -Name 'Fry hue shift degrees (-90..90)' -Hint 'Must be -90..90' -Cur $hueShift -Min -90 -Max 90 -Out ([ref]$v))) { return }
            $hueShift = $v
            $v = 0.0
            if (-not (Read-CustomParam -Name 'Fry brightness (-0.3..0.3)' -Hint 'Must be -0.3..0.3' -Cur $bright -Min -0.3 -Max 0.3 -Out ([ref]$v))) { return }
            $bright = $v
            $v = 0.0
            if (-not (Read-CustomParam -Name 'Fry white point gain (1.0..1.6, blown highlights)' -Hint 'Must be 1.0..1.6' -Cur $gain -Min 1.0 -Max 1.6 -Out ([ref]$v))) { return }
            $gain = $v
        }
        default { $scale = 0.20; $crf = 36; $abr = '48k'; $volDb = 9; $gop = 6; $contrast = 1.55; $saturation = 3.0; $hueShift = -12; $bright = 0.07; $gain = 1.2 }
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
    # Цветовой дисторшн "жара" — одинаковые приёмы для картинок и видео:
    # перекос контраста/насыщенности, сдвиг оттенка в кислотную сторону, экстремальные точки кривых (выбитые света) и резкость
    $curveMaster = "0/0 0.25/$([Math]::Round(0.25 * $gain, 3)) 0.5/0.56 0.75/$([Math]::Round(0.93 - 0.18 * $gain, 3)) 1/1"
    $vfFry = "eq=contrast=${contrast}:brightness=${bright}:saturation=${saturation},hue=h=${hueShift},curves=master='${curveMaster}',unsharp=5:5:1.2:5:5:0"

    if ($isImage) {
        # GIF сохраняем анимированным (деградация через пиксельизацию + цветовой жар + низкий битрейт);
        # остальные картинки — JPEG-артефакты через mjpeg q:v, если исходник не PNG;
        # для PNG делаем два прохода: деградированный JPEG во временном файле -> пересборка в PNG (формат сохраняется)
        $outExt = if ($ext -eq '.gif') { '.gif' } elseif ($ext -in @('.jpg','.jpeg')) { '.jpg' } else { $ext }
        $out = Join-Path $outDir "$base`_deepfry$outExt"
        $logFile2 = Join-Path $TempDir "ffmpeg_misc_deep2.txt"
        $tmpJpg = Join-Path $TempDir "ffmpeg_misc_deep_tmp.jpg"
        # -frames:v 1 — берём только первый кадр (для статичных картинок; GIF обрабатывается целиком ниже)
        $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,"-vf","${vfDown},${vfFry},setsar=1")
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
        # Видео: пиксельизация + тот же цветовой жар, что и для картинок ($vfFry)
        $FFArgs = @("-hide_banner","-loglevel","error","-y","-i",$inPath,
            "-vf","${vfDown},${vfFry},setsar=1,format=yuv420p",
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
