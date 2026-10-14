#Requires -Version 5.1
$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
# --- Глобальная конфигурация ---
# Создание логов выключено по умолчанию; все логи сохраняются в папку logs
$global:Cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { @{EnableLogs=$false; LogsFolder=(Join-Path $ScriptDir "logs")} }
if (-not ($global:Cfg.PSObject.Properties['LogsFolder'] -or ($global:Cfg -is [System.Collections.IDictionary] -and $global:Cfg.Contains('LogsFolder')))) {
    $global:Cfg = $global:Cfg + @{ LogsFolder = (Join-Path $ScriptDir "logs") }
}
if (-not ($global:Cfg.PSObject.Properties['EnableLogs'] -or ($global:Cfg -is [System.Collections.IDictionary] -and $global:Cfg.Contains('EnableLogs')))) {
    $global:Cfg = $global:Cfg + @{ EnableLogs = $false }
}

# --- Логирование ошибок и зависаний (все логи сохраняются в папку logs) ---
$script:LogsFolder = if ($global:Cfg.LogsFolder) { [string]$global:Cfg.LogsFolder } else { Join-Path $ScriptDir "logs" }
$script:ErrorLogFile = Join-Path $script:LogsFolder "conversion_errors.log"
$script:NoProgressTimeoutSec = 300   # секунд без прогресса => процесс считается зависшим
# Значение можно переопределить в global_config.json: NoProgressTimeoutSec
if ($null -ne $global:Cfg.NoProgressTimeoutSec) { $script:NoProgressTimeoutSec = [int]$global:Cfg.NoProgressTimeoutSec }

function Write-ErrorLog {
    param([string]$Type, [string]$FileName, [string]$Details)
    # Создание логов выключено по умолчанию — записи не пишутся, файлы не создаются
    if (-not $global:Cfg.EnableLogs) { return }
    try {
        if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
        # Если лог-файл был удалён вручную — пересоздаём его с заголовком
        if (-not (Test-Path $script:ErrorLogFile)) {
            Set-Content -Path $script:ErrorLogFile -Value @(
                "=== Conversion error log | Root folder: $ScriptDir | Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===", ""
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
    } catch {}
}

function Get-FFmpegTail {
    param([string]$Path, [int]$Lines = 40)
    if (Test-Path $Path) {
        try { return ((Get-Content $Path -Tail $Lines -ErrorAction SilentlyContinue) -join "`n") } catch {}
    }
    return "(no output captured)"
}

# --- Лог по нажатию клавиши во время процесса ---
# Проверяет, была ли нажата клавиша "L" (без блокировки цикла). Возвращает $true, если нажата.
function Test-LoggingHotkey {
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'L' -or $k.KeyChar -eq 'l' -or $k.KeyChar -eq 'L') { return $true }
        }
    } catch {}
    return $false
}

# Создаёт запись в корневом логе с текущим состоянием процесса и снимком вывода ffmpeg (по нажатию клавиши L)
function Write-ProgressLog {
    param(
        [string]$FileName,   # обрабатываемый файл
        [string]$Stage,      # Convert
        [double]$ElapsedSec, # сколько секунд идёт процесс
        [string]$LogFile,    # временный лог ffmpeg (для хвоста и сохранения копии)
        [string]$OutPath     # путь к результату
    )
    $elapsedStr = [TimeSpan]::FromSeconds($ElapsedSec).ToString('hh\:mm\:ss')
    $details = @(
        "Manual log request (key 'L' pressed)"
        "Stage: $Stage | Elapsed: $elapsedStr"
        "Output: $OutPath"
    ) -join [Environment]::NewLine
    $savedLog = $null
    if ($global:Cfg.EnableLogs -and (Test-Path $LogFile)) {
        try {
            if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
            $safeName = ((Split-Path -Leaf $FileName) -replace '[^\w\.\-]', '_')
            $savedLog = Join-Path $script:LogsFolder ("ffmpeg_manual_{0}.log" -f $safeName)
            Copy-Item -Path $LogFile -Destination $savedLog -Force
        } catch { $savedLog = $null }
    }
    if ($savedLog) { $details += [Environment]::NewLine + "Full FFmpeg log snapshot saved to: $savedLog" }
    $details += [Environment]::NewLine + "Last FFmpeg output:" + [Environment]::NewLine + (Get-FFmpegTail -Path $LogFile)
    $ok = $false
    try { Write-ErrorLog -Type "MANUAL" -FileName $FileName -Details $details; $ok = $true } catch {}
    return [pscustomobject]@{ Success = $ok; LogFile = $script:ErrorLogFile; Snapshot = $savedLog }
}

function Show-Banner {
    param([string]$Title)
    Clear-Host
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "========================================================`n" -ForegroundColor Cyan
}

$AllKnownExts = @(
    '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.ts',
    '.mpg', '.mpeg', '.3gp', '.3g2', '.vob', '.ogv', '.rm', '.rmvb', '.asf',
    '.dv', '.mts', '.m2ts', '.f4v', '.divx', '.amv', '.mxf', '.vro', '.gxf',
    '.png', '.jpg', '.jpeg', '.jfif', '.bmp', '.tiff', '.tif', '.webp', '.gif',
    '.heic', '.heif', '.ico', '.raw', '.cr2', '.nef', '.arw', '.dng', '.orf',
    '.svg', '.psd', '.ai', '.eps', '.jp2', '.jxr', '.pcx', '.tga', '.ppm',
    '.pgm', '.pbm', '.pnm', '.xpm', '.xbm', '.hdr', '.exr', '.dds', '.pict',
    '.sgi', '.sun', '.viff', '.xwd', '.mp3', '.wav', '.flac', '.aac', '.ogg'
)

function Get-CleanPath {
    param([string]$RawPath)
    return $RawPath.Trim().Trim('"').Trim("'").TrimEnd('.')
}

function Resolve-InputPath {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return $Path }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $null }
    $candidates = @()
    foreach ($ext in $AllKnownExts) {
        $candidatePath = Join-Path $dir "$baseName$ext"
        if (Test-Path -LiteralPath $candidatePath) { $candidates += $candidatePath }
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    elseif ($candidates.Count -gt 1) {
        Write-Host ("  Multiple files found. Select:") -ForegroundColor White
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host "    [$($i + 1)] $([System.IO.Path]::GetFileName($candidates[$i]))" -ForegroundColor White
        }
        $choice = Read-Host "  Number"
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $candidates.Count) {
            return $candidates[[int]$choice - 1]
        }
    }
    return $null
}

function Get-FileType {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $videoExts = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.ts', '.mpg', '.mpeg', '.3gp', '.3g2', '.vob', '.ogv', '.rm', '.rmvb', '.asf', '.dv', '.mts', '.m2ts', '.f4v', '.divx', '.amv', '.mxf', '.vro', '.gxf')
    $imageExts = @('.png', '.jpg', '.jpeg', '.jfif', '.bmp', '.tiff', '.tif', '.webp', '.gif', '.heic', '.heif', '.ico', '.raw', '.cr2', '.nef', '.arw', '.dng', '.orf', '.svg', '.psd', '.ai', '.eps', '.jp2', '.jxr', '.pcx', '.tga', '.ppm', '.pgm', '.pbm', '.pnm', '.xpm', '.xbm', '.hdr', '.exr', '.dds', '.pict', '.sgi', '.sun', '.viff', '.xwd')
    $audioExts = @('.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a', '.wma')
    if ($videoExts -contains $ext) { return "Video" }
    if ($imageExts -contains $ext) { return "Image" }
    if ($audioExts -contains $ext) { return "Audio" }
    return "Unknown"
}

function Show-VideoFormats {
    Show-Banner "VIDEO FORMATS"
    Write-Host "  [1]  MP4  (H.264 + AAC)" -ForegroundColor White
    Write-Host "  [2]  MKV  (H.264 + AAC)" -ForegroundColor White
    Write-Host "  [3]  AVI  (MPEG-4 + MP3)" -ForegroundColor White
    Write-Host "  [4]  MOV  (H.264 + AAC)" -ForegroundColor White
    Write-Host "  [5]  WebM (VP9 + Opus)" -ForegroundColor White
    Write-Host "  [6]  WMV  (WMV2 + WMA)" -ForegroundColor White
    Write-Host "  [7]  GIF  (Animation)" -ForegroundColor White
    Write-Host "  [8]  FLV  (FLV + MP3)" -ForegroundColor White
    Write-Host "  [9]  MPEG (MPEG-2 + MP2)" -ForegroundColor White
    Write-Host "  [10] 3GP  (H.263 + AMR)" -ForegroundColor White
    Write-Host "  [11] OGV  (Theora + Vorbis)" -ForegroundColor White
    Write-Host "  [12] TS   (MPEG-TS)" -ForegroundColor White
    Write-Host "  [13] ASF  (MSMPEG4 + WMA)" -ForegroundColor White
    Write-Host "  [14] DV   (DV Video + PCM)" -ForegroundColor White
    Write-Host "  [15] MXF  (MPEG-2 + PCM)" -ForegroundColor White
    Write-Host "  [16] AMV  (MJPEG + ADPCM)" -ForegroundColor White
    Write-Host "  [0]  $('Back')" -ForegroundColor Red
    return Read-Host "  Select format"
}

function Show-ImageFormats {
    Show-Banner "IMAGE FORMATS"
    Write-Host "  [1]  PNG   [2]  JPG   [3]  JFIF  [4]  WebP" -ForegroundColor White
    Write-Host "  [5]  BMP   [6]  TIFF  [7]  GIF   [8]  ICO" -ForegroundColor White
    Write-Host "  [9]  TGA   [10] PCX   [11] PPM   [12] PGM" -ForegroundColor White
    Write-Host "  [13] PBM   [14] XPM   [15] XBM   [16] JP2" -ForegroundColor White
    Write-Host "  [17] HDR   [18] EXR   [19] DDS   [20] SUN" -ForegroundColor White
    Write-Host "  [21] SGI   [22] PICT  [23] VIFF  [24] XWD" -ForegroundColor White
    Write-Host "  [0]  $('Back')" -ForegroundColor Red
    return Read-Host "  Select format"
}

function Show-AudioFormats {
    Show-Banner "AUDIO FORMATS"
    Write-Host "  [1] MP3  [2] WAV  [3] FLAC  [4] AAC  [5] OGG" -ForegroundColor White
    Write-Host "  [0] $('Back')" -ForegroundColor Red
    return Read-Host "  Select format"
}

function Get-FormatArgs {
    param([string]$Type, [string]$Choice)
    $formats = @{}
    if ($Type -eq "Video") {
        $formats = @{
            "1"  = @{ Ext = "mp4";  Args = @("-c:v","libx264","-crf","23","-preset","medium","-c:a","aac","-b:a","192k","-movflags","+faststart") }
            "2"  = @{ Ext = "mkv";  Args = @("-c:v","libx264","-crf","23","-preset","medium","-c:a","aac","-b:a","192k") }
            "3"  = @{ Ext = "avi";  Args = @("-c:v","mpeg4","-q:v","5","-c:a","mp3","-b:a","192k") }
            "4"  = @{ Ext = "mov";  Args = @("-c:v","libx264","-crf","23","-preset","medium","-c:a","aac","-b:a","192k") }
            "5"  = @{ Ext = "webm"; Args = @("-c:v","libvpx-vp9","-crf","30","-b:v","0","-c:a","libopus","-b:a","128k") }
            "6"  = @{ Ext = "wmv";  Args = @("-c:v","wmv2","-b:v","2M","-c:a","wmav2","-b:a","192k") }
            "7"  = @{ Ext = "gif";  Args = @("-vf","fps=15,scale=320:-1","-loop","0") }
            "8"  = @{ Ext = "flv";  Args = @("-c:v","flv","-q:v","5","-c:a","mp3","-b:a","128k") }
            "9"  = @{ Ext = "mpg";  Args = @("-c:v","mpeg2video","-b:v","5M","-c:a","mp2","-b:a","192k") }
            "10" = @{ Ext = "3gp";  Args = @("-c:v","h263","-s","qcif","-c:a","amr_nb","-ar","8000","-ac","1","-ab","12k") }
            "11" = @{ Ext = "ogv";  Args = @("-c:v","libtheora","-q:v","6","-c:a","libvorbis","-q:a","4") }
            "12" = @{ Ext = "ts";   Args = @("-c:v","libx264","-crf","23","-preset","medium","-c:a","aac","-b:a","192k","-f","mpegts") }
            "13" = @{ Ext = "asf";  Args = @("-c:v","msmpeg4v3","-b:v","2M","-c:a","wmav2","-b:a","192k") }
            "14" = @{ Ext = "dv";   Args = @("-c:v","dvvideo","-pix_fmt","yuv420p","-c:a","pcm_s16le") }
            "15" = @{ Ext = "mxf";  Args = @("-c:v","mpeg2video","-b:v","50M","-c:a","pcm_s16le","-f","mxf") }
            "16" = @{ Ext = "amv";  Args = @("-c:v","mjpeg","-q:v","5","-c:a","adpcm_ima_amv","-ar","22050") }
        }
    } elseif ($Type -eq "Image") {
        $formats = @{
            "1"  = @{ Ext = "png";  Args = @() }
            "2"  = @{ Ext = "jpg";  Args = @("-q:v","2") }
            "3"  = @{ Ext = "jfif"; Args = @("-q:v","2") }
            "4"  = @{ Ext = "webp"; Args = @("-quality","85") }
            "5"  = @{ Ext = "bmp";  Args = @() }
            "6"  = @{ Ext = "tiff"; Args = @() }
            "7"  = @{ Ext = "gif";  Args = @() }
            "8"  = @{ Ext = "ico";  Args = @() }
            "9"  = @{ Ext = "tga";  Args = @() }
            "10" = @{ Ext = "pcx";  Args = @() }
            "11" = @{ Ext = "ppm";  Args = @() }
            "12" = @{ Ext = "pgm";  Args = @() }
            "13" = @{ Ext = "pbm";  Args = @() }
            "14" = @{ Ext = "xpm";  Args = @() }
            "15" = @{ Ext = "xbm";  Args = @() }
            "16" = @{ Ext = "jp2";  Args = @() }
            "17" = @{ Ext = "hdr";  Args = @() }
            "18" = @{ Ext = "exr";  Args = @() }
            "19" = @{ Ext = "dds";  Args = @() }
            "20" = @{ Ext = "sun";  Args = @() }
            "21" = @{ Ext = "sgi";  Args = @() }
            "22" = @{ Ext = "pct";  Args = @() }
            "23" = @{ Ext = "viff"; Args = @() }
            "24" = @{ Ext = "xwd";  Args = @() }
        }
    } elseif ($Type -eq "Audio") {
        $formats = @{
            "1" = @{ Ext = "mp3";  Args = @("-c:a","libmp3lame","-q:a","2") }
            "2" = @{ Ext = "wav";  Args = @("-c:a","pcm_s16le") }
            "3" = @{ Ext = "flac"; Args = @("-c:a","flac") }
            "4" = @{ Ext = "aac";  Args = @("-c:a","aac","-b:a","192k") }
            "5" = @{ Ext = "ogg";  Args = @("-c:a","libvorbis","-q:a","6") }
        }
    }
    if ($formats.ContainsKey($Choice)) { return $formats[$Choice] }
    return $null
}

# Основной цикл
do {
    Show-Banner "MEDIA CONVERTER"
    Write-Host ("  Drag & drop file here, enter path, or '0' to return:") -ForegroundColor White
    $raw = Read-Host "  > "
    if ($raw -eq '0' -or [string]::IsNullOrWhiteSpace($raw)) { break }

    $path = Get-CleanPath $raw
    $inputFile = Resolve-InputPath $path
    if (-not $inputFile) {
        Write-Host "  [X] $('File not found'): $path" -ForegroundColor Red
        Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
        Read-Host
        continue
    }

    $fileType = Get-FileType $inputFile
    if ($fileType -eq "Unknown") {
        Write-Host "  [X] $('Unsupported format')" -ForegroundColor Red
        Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
        Read-Host
        continue
    }

    $choice = ""
    if ($fileType -eq "Video") { $choice = Show-VideoFormats }
    elseif ($fileType -eq "Image") { $choice = Show-ImageFormats }
    elseif ($fileType -eq "Audio") { $choice = Show-AudioFormats }

    if ($choice -eq '0') { continue }

    $target = Get-FormatArgs -Type $fileType -Choice $choice
    if (-not $target) {
        Write-Host "  [X] $('Invalid choice')" -ForegroundColor Red
        Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
        Read-Host
        continue
    }

    $dir = [System.IO.Path]::GetDirectoryName($inputFile)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)

    # Папка результата под вид операции: ...\converted
    $outDir = Join-Path $dir "converted"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $outPath = Join-Path $outDir "$baseName`_converted.$($target.Ext)"

    Write-Host "`n  $('Converting...') ($('Press L to write log'))" -ForegroundColor Yellow
    $ffmpegArgs = @("-i", $inputFile) + $target.Args + @("-y", $outPath)
    $logFile = Join-Path $env:TEMP "ffmpeg_conv.txt"

    # Пишем в корневой лог начало каждого прогона (INFO) — ошибки ищутся по метке [ERROR]/[HANG]
    Write-ErrorLog -Type "INFO" -FileName $inputFile -Details "Conversion started | Target: $fileType/$($target.Ext) | Output: $outPath"

    try {
    # Запуск без -Wait с контролем зависания (отсутствие прогресса => остановка и запись в лог)
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -PassThru -RedirectStandardError $logFile
    if (-not $proc) { throw "Failed to start FFmpeg process (ffmpeg not found or access denied)" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastLogSize = 0; $lastOutSize = 0; $lastProgressAt = $sw.Elapsed
    $hung = $false
    while (-not $proc.HasExited) {
        # Лог по нажатию клавиши: [L] — записать текущее состояние процесса в корневой лог
        if (Test-LoggingHotkey) {
            $res = Write-ProgressLog -FileName $inputFile -Stage "Convert" -ElapsedSec $sw.Elapsed.TotalSeconds -LogFile $logFile -OutPath $outPath
            if ($res.Success) {
                Write-Host "`n  [LOG] $('State written to log'): $($res.LogFile)" -ForegroundColor Magenta
            } else {
                Write-Host "`n  [X] $('Failed to write log')" -ForegroundColor Red
            }
        }
        $logSize = 0; $outSize = 0
        try { if (Test-Path $logFile) { $logSize = (Get-Item $logFile).Length } } catch {}
        try { if (Test-Path $outPath) { $outSize = (Get-Item $outPath).Length } } catch {}
        if ($logSize -ne $lastLogSize -or $outSize -ne $lastOutSize) {
            $lastLogSize = $logSize; $lastOutSize = $outSize
            $lastProgressAt = $sw.Elapsed
        } elseif (($sw.Elapsed - $lastProgressAt).TotalSeconds -gt $script:NoProgressTimeoutSec) {
            $hung = $true
            Write-Host "`n  [!] $('Process hung detected: no progress for') $([int]$script:NoProgressTimeoutSec)$(' s'). $('Stopping FFmpeg...')" -ForegroundColor Red
            try { & taskkill /F /T /PID $proc.Id 2>$null | Out-Null; $proc.Kill() } catch {}
            break
        }
        Start-Sleep -Milliseconds 500
    }
    $sw.Stop()

    if ($hung) {
        $rootFFLog = $null
        if ($global:Cfg.EnableLogs -and (Test-Path $logFile)) {
            try {
                if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
                $rootFFLog = Join-Path $script:LogsFolder ("ffmpeg_hang_{0}.log" -f ($baseName -replace '[^\w\.\-]', '_'))
                Copy-Item $logFile $rootFFLog -Force
            } catch { $rootFFLog = $null }
        }
        Write-ErrorLog -Type "HANG" -FileName $inputFile -Details (
            "Output: $outPath`n" +
            "Elapsed: $($sw.Elapsed.ToString('hh\:mm\:ss'))`n" +
            $(if ($rootFFLog) { "Full FFmpeg log saved to: $rootFFLog`n" } else { "" }) +
            "Last FFmpeg output:`n" + (Get-FFmpegTail -Path $logFile)
        )
        Write-Host "  [X] $('Logged to'): $script:ErrorLogFile" -ForegroundColor DarkGray
        Remove-Item $outPath -Force -ErrorAction SilentlyContinue
    } elseif ($proc.ExitCode -eq 0) {
        Write-Host "  [OK] $('Saved'): $outPath" -ForegroundColor Green
    } else {
        Write-Host "  [X] $('Conversion failed')" -ForegroundColor Red
        $rootFFLog = $null
        if ($global:Cfg.EnableLogs -and (Test-Path $logFile)) {
            try {
                if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
                $rootFFLog = Join-Path $script:LogsFolder ("ffmpeg_error_{0}.log" -f ($baseName -replace '[^\w\.\-]', '_'))
                Copy-Item $logFile $rootFFLog -Force
            } catch { $rootFFLog = $null }
        }
        Write-ErrorLog -Type "ERROR" -FileName $inputFile -Details (
            "ExitCode: $($proc.ExitCode)`n" +
            "Output: $outPath`n" +
            $(if ($rootFFLog) { "Full FFmpeg log saved to: $rootFFLog`n" } else { "" }) +
            "Last FFmpeg output:`n" + (Get-FFmpegTail -Path $logFile)
        )
        Write-Host "  [X] $('Logged to'): $script:ErrorLogFile" -ForegroundColor DarkGray
        if ($global:Cfg.EnableLogs -and (Test-Path $logFile)) {
            if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
            Copy-Item $logFile (Join-Path $script:LogsFolder "$baseName`_conv.log") -Force
        }
    }
    } catch {
        # Любая непредвиденная ошибка во время конвертации — в корневой лог
        Write-ErrorLog -Type "ERROR" -FileName $(if ($inputFile) { $inputFile } else { "(unknown)" }) -Details (
            "Stage: Unexpected error during conversion`n" +
            "Message: $($_.Exception.Message)`n" +
            "Line: $($_.InvocationInfo.ScriptLineNumber) | $($_.InvocationInfo.Line.Trim())"
        )
        Write-Host "  [X] $('Unexpected error, logged to'): $script:ErrorLogFile" -ForegroundColor Red
    }

    Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
    Read-Host
} while ($true)