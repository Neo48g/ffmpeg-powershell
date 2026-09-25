#Requires -Version 5.1
$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
$global:Cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { @{Language="EN"; EnableLogs=$true; LogsFolder=(Join-Path $ScriptDir "logs")} }
function L($en, $ru) { if ($global:Cfg.Language -eq 'RU') { return $ru } return $en }

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
        Write-Host (L "  Multiple files found. Select:" "  Найдено несколько файлов. Выберите:") -ForegroundColor White
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host "    [$($i + 1)] $([System.IO.Path]::GetFileName($candidates[$i]))" -ForegroundColor White
        }
        $choice = Read-Host (L "  Number" "  Номер")
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
    Show-Banner (L "VIDEO FORMATS" "ФОРМАТЫ ВИДЕО")
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
    Write-Host "  [0]  $(L 'Back' 'Назад')" -ForegroundColor Red
    return Read-Host (L "  Select format" "  Выберите формат")
}

function Show-ImageFormats {
    Show-Banner (L "IMAGE FORMATS" "ФОРМАТЫ ИЗОБРАЖЕНИЙ")
    Write-Host "  [1]  PNG   [2]  JPG   [3]  JFIF  [4]  WebP" -ForegroundColor White
    Write-Host "  [5]  BMP   [6]  TIFF  [7]  GIF   [8]  ICO" -ForegroundColor White
    Write-Host "  [9]  TGA   [10] PCX   [11] PPM   [12] PGM" -ForegroundColor White
    Write-Host "  [13] PBM   [14] XPM   [15] XBM   [16] JP2" -ForegroundColor White
    Write-Host "  [17] HDR   [18] EXR   [19] DDS   [20] SUN" -ForegroundColor White
    Write-Host "  [21] SGI   [22] PICT  [23] VIFF  [24] XWD" -ForegroundColor White
    Write-Host "  [0]  $(L 'Back' 'Назад')" -ForegroundColor Red
    return Read-Host (L "  Select format" "  Выберите формат")
}

function Show-AudioFormats {
    Show-Banner (L "AUDIO FORMATS" "ФОРМАТЫ АУДИО")
    Write-Host "  [1] MP3  [2] WAV  [3] FLAC  [4] AAC  [5] OGG" -ForegroundColor White
    Write-Host "  [0] $(L 'Back' 'Назад')" -ForegroundColor Red
    return Read-Host (L "  Select format" "  Выберите формат")
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

# Main Loop
do {
    Show-Banner (L "MEDIA CONVERTER" "КОНВЕРТЕР МЕДИА")
    Write-Host (L "  Drag & drop file here, enter path, or '0' to return:" "  Перетащите файл, введите путь или '0' для возврата:") -ForegroundColor White
    $raw = Read-Host "  > "
    if ($raw -eq '0' -or [string]::IsNullOrWhiteSpace($raw)) { break }
    
    $path = Get-CleanPath $raw
    $inputFile = Resolve-InputPath $path
    if (-not $inputFile) {
        Write-Host "  [X] $(L 'File not found' 'Файл не найден'): $path" -ForegroundColor Red
        Write-Host "`n  $(L 'Press Enter to continue...' 'Нажмите Enter для продолжения...')" -ForegroundColor Gray
        Read-Host
        continue
    }

    $fileType = Get-FileType $inputFile
    if ($fileType -eq "Unknown") {
        Write-Host "  [X] $(L 'Unsupported format' 'Неподдерживаемый формат')" -ForegroundColor Red
        Write-Host "`n  $(L 'Press Enter to continue...' 'Нажмите Enter для продолжения...')" -ForegroundColor Gray
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
        Write-Host "  [X] $(L 'Invalid choice' 'Неверный выбор')" -ForegroundColor Red
        Write-Host "`n  $(L 'Press Enter to continue...' 'Нажмите Enter для продолжения...')" -ForegroundColor Gray
        Read-Host
        continue
    }

    $dir = [System.IO.Path]::GetDirectoryName($inputFile)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
    $outPath = Join-Path $dir "$baseName`_converted.$($target.Ext)"

    Write-Host "`n  $(L 'Converting...' 'Конвертация...')" -ForegroundColor Yellow
    $ffmpegArgs = @("-i", $inputFile) + $target.Args + @("-y", $outPath)
    $logFile = Join-Path $env:TEMP "ffmpeg_conv.txt"
    
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru -RedirectStandardError $logFile
    
    if ($proc.ExitCode -eq 0) {
        Write-Host "  [OK] $(L 'Saved' 'Сохранено'): $outPath" -ForegroundColor Green
    } else {
        Write-Host "  [X] $(L 'Conversion failed' 'Ошибка конвертации')" -ForegroundColor Red
        if ($global:Cfg.EnableLogs -and (Test-Path $logFile)) {
            if (-not (Test-Path $global:Cfg.LogsFolder)) { New-Item -ItemType Directory -Path $global:Cfg.LogsFolder | Out-Null }
            Copy-Item $logFile (Join-Path $global:Cfg.LogsFolder "$baseName`_conv.log") -Force
        }
    }

    Write-Host "`n  $(L 'Press Enter to continue...' 'Нажмите Enter для продолжения...')" -ForegroundColor Gray
    Read-Host
} while ($true)