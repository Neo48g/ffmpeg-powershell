#Requires -Version 5.1
# ============================================================================
# convert-media.ps1 — конвертер видео / изображений / аудио (FFmpeg)
# ============================================================================
[CmdletBinding()]
param(
    [string]$InputPath   # необязательный стартовый файл/папка (для запуска из .bat)
)

. (Join-Path $PSScriptRoot "common.ps1")

# --- Списки расширений (единый источник истины) ---
$script:VideoExts = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.ts', '.mpg', '.mpeg',
                      '.3gp', '.3g2', '.vob', '.ogv', '.rm', '.rmvb', '.asf', '.dv', '.mts', '.m2ts', '.f4v',
                      '.divx', '.amv', '.mxf', '.vro', '.gxf')
$script:ImageExts = @('.png', '.jpg', '.jpeg', '.jfif', '.bmp', '.tiff', '.tif', '.webp', '.gif', '.heic',
                      '.heif', '.ico', '.raw', '.cr2', '.nef', '.arw', '.dng', '.orf', '.svg', '.psd', '.ai',
                      '.eps', '.jp2', '.jxr', '.pcx', '.tga', '.ppm', '.pgm', '.pbm', '.pnm', '.xpm', '.xbm',
                      '.hdr', '.exr', '.dds', '.pict', '.sgi', '.sun', '.viff', '.xwd')
$script:AudioExts = @('.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a', '.wma')
$AllKnownExts = $script:VideoExts + $script:ImageExts + $script:AudioExts

function Get-CleanPath {
    param([string]$RawPath)
    return $RawPath.Trim().Trim('"').Trim("'").TrimEnd('.')
}

# Если точного пути нет — ищем файлы с тем же именем и известными расширениями
function Resolve-InputPath {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return $Path }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $null }
    $candidates = foreach ($ext in $AllKnownExts) {
        $candidatePath = Join-Path $dir "$baseName$ext"
        if (Test-Path -LiteralPath $candidatePath) { $candidatePath }
    }
    $candidates = @($candidates)
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
    if ($script:VideoExts -contains $ext) { return "Video" }
    if ($script:ImageExts -contains $ext) { return "Image" }
    if ($script:AudioExts -contains $ext) { return "Audio" }
    return "Unknown"
}

# --- Таблица форматов: выводимые пункты меню генерируются из неё ---
$script:FormatTable = @{
    Video = @(
        @{ Ext = "mp4";  Label = "MP4  (H.264 + AAC)";        Args = @("-c:v","libx264","-crf","23","-preset","medium","-c:a","aac","-b:a","192k","-movflags","+faststart") }
        @{ Ext = "mkv";  Label = "MKV  (H.264 + AAC)";        Args = @("-c:v","libx264","-crf","23","-preset","medium","-c:a","aac","-b:a","192k") }
        @{ Ext = "avi";  Label = "AVI  (MPEG-4 + MP3)";       Args = @("-c:v","mpeg4","-q:v","5","-c:a","mp3","-b:a","192k") }
        @{ Ext = "mov";  Label = "MOV  (H.264 + AAC)";        Args = @("-c:v","libx264","-crf","23","-preset","medium","-c:a","aac","-b:a","192k") }
        @{ Ext = "webm"; Label = "WebM (VP9 + Opus)";         Args = @("-c:v","libvpx-vp9","-crf","30","-b:v","0","-c:a","libopus","-b:a","128k") }
        @{ Ext = "wmv";  Label = "WMV  (WMV2 + WMA)";         Args = @("-c:v","wmv2","-b:v","2M","-c:a","wmav2","-b:a","192k") }
        @{ Ext = "gif";  Label = "GIF  (Animation)";          Args = @("-vf","fps=15,scale=320:-1","-loop","0") }
        @{ Ext = "flv";  Label = "FLV  (FLV + MP3)";          Args = @("-c:v","flv","-q:v","5","-c:a","mp3","-b:a","128k") }
        @{ Ext = "mpg";  Label = "MPEG (MPEG-2 + MP2)";       Args = @("-c:v","mpeg2video","-b:v","5M","-c:a","mp2","-b:a","192k") }
        @{ Ext = "3gp";  Label = "3GP  (H.263 + AMR)";        Args = @("-c:v","h263","-s","qcif","-c:a","amr_nb","-ar","8000","-ac","1","-ab","12k") }
        @{ Ext = "ogv";  Label = "OGV  (Theora + Vorbis)";    Args = @("-c:v","libtheora","-q:v","6","-c:a","libvorbis","-q:a","4") }
        @{ Ext = "ts";   Label = "TS   (MPEG-TS)";            Args = @("-c:v","libx264","-crf","23","-preset","medium","-c:a","aac","-b:a","192k","-f","mpegts") }
        @{ Ext = "asf";  Label = "ASF  (MSMPEG4 + WMA)";      Args = @("-c:v","msmpeg4v3","-b:v","2M","-c:a","wmav2","-b:a","192k") }
        @{ Ext = "dv";   Label = "DV   (DV Video + PCM)";     Args = @("-c:v","dvvideo","-pix_fmt","yuv420p","-c:a","pcm_s16le") }
        @{ Ext = "mxf";  Label = "MXF  (MPEG-2 + PCM)";       Args = @("-c:v","mpeg2video","-b:v","50M","-c:a","pcm_s16le","-f","mxf") }
        @{ Ext = "amv";  Label = "AMV  (MJPEG + ADPCM)";      Args = @("-c:v","mjpeg","-q:v","5","-c:a","adpcm_ima_amv","-ar","22050") }
    )
    Image = @(
        @{ Ext = "png";  Label = "PNG";  Args = @() }
        @{ Ext = "jpg";  Label = "JPG";  Args = @("-q:v","2") }
        @{ Ext = "jfif"; Label = "JFIF"; Args = @("-q:v","2") }
        @{ Ext = "webp"; Label = "WebP"; Args = @("-quality","85") }
        @{ Ext = "bmp";  Label = "BMP";  Args = @() }
        @{ Ext = "tiff"; Label = "TIFF"; Args = @() }
        @{ Ext = "gif";  Label = "GIF";  Args = @() }
        @{ Ext = "ico";  Label = "ICO";  Args = @() }
        @{ Ext = "tga";  Label = "TGA";  Args = @() }
        @{ Ext = "pcx";  Label = "PCX";  Args = @() }
        @{ Ext = "ppm";  Label = "PPM";  Args = @() }
        @{ Ext = "pgm";  Label = "PGM";  Args = @() }
        @{ Ext = "pbm";  Label = "PBM";  Args = @() }
        @{ Ext = "xpm";  Label = "XPM";  Args = @() }
        @{ Ext = "xbm";  Label = "XBM";  Args = @() }
        @{ Ext = "jp2";  Label = "JP2";  Args = @() }
        @{ Ext = "hdr";  Label = "HDR";  Args = @() }
        @{ Ext = "exr";  Label = "EXR";  Args = @() }
        @{ Ext = "dds";  Label = "DDS";  Args = @() }
        @{ Ext = "sun";  Label = "SUN";  Args = @() }
        @{ Ext = "sgi";  Label = "SGI";  Args = @() }
        @{ Ext = "pct";  Label = "PICT"; Args = @() }
        @{ Ext = "viff"; Label = "VIFF"; Args = @() }
        @{ Ext = "xwd";  Label = "XWD";  Args = @() }
    )
    Audio = @(
        @{ Ext = "mp3";  Label = "MP3";  Args = @("-c:a","libmp3lame","-q:a","2") }
        @{ Ext = "wav";  Label = "WAV";  Args = @("-c:a","pcm_s16le") }
        @{ Ext = "flac"; Label = "FLAC"; Args = @("-c:a","flac") }
        @{ Ext = "aac";  Label = "AAC";  Args = @("-c:a","aac","-b:a","192k") }
        @{ Ext = "ogg";  Label = "OGG";  Args = @("-c:a","libvorbis","-q:a","6") }
    )
}

function Show-FormatsMenu {
    param([string]$Type, [string]$TitleEn, [string]$TitleRu)
    Show-Banner (L $TitleEn $TitleRu)
    $items = $script:FormatTable[$Type]
    $i = 1
    foreach ($fmt in $items) {
        Write-Host ("  [{0,-3}] {1,-6}" -f $i, $fmt.Ext.ToUpper()) -NoNewline -ForegroundColor White
        Write-Host " $($fmt.Label)" -ForegroundColor Gray
        $i++
    }
    Write-Host "  [0]  $(L 'Back' 'Назад')" -ForegroundColor Red
    return Read-Host (L "  Select format" "  Выберите формат")
}

function Get-FormatByChoice {
    param([string]$Type, [string]$Choice)
    if ($Choice -notmatch '^\d+$') { return $null }
    $items = $script:FormatTable[$Type]
    $idx = [int]$Choice - 1
    if ($idx -ge 0 -and $idx -lt $items.Count) { return $items[$idx] }
    return $null
}

# --- Main Loop ---
do {
    Show-Banner (L "MEDIA CONVERTER" "КОНВЕРТЕР МЕДИА")
    Write-Host (L "  Drag & drop file here, enter path, or '0' to return:" "  Перетащите файл, введите путь или '0' для возврата:") -ForegroundColor White
    $raw = if ($InputPath) { $tmp = $InputPath; $InputPath = ''; $tmp } else { Read-Host "  > " }
    if ($raw -eq '0' -or [string]::IsNullOrWhiteSpace($raw)) { break }

    $path = Get-CleanPath $raw
    $inputFile = Resolve-InputPath $path
    if (-not $inputFile) {
        Write-Host "  [X] $(L 'File not found' 'Файл не найден'): $path" -ForegroundColor Red
        Wait-Enter
        continue
    }

    $fileType = Get-FileType $inputFile
    if ($fileType -eq "Unknown") {
        Write-Host "  [X] $(L 'Unsupported format' 'Неподдерживаемый формат')" -ForegroundColor Red
        Wait-Enter
        continue
    }

    $choice = switch ($fileType) {
        "Video" { Show-FormatsMenu -Type "Video" -TitleEn "VIDEO FORMATS" -TitleRu "ФОРМАТЫ ВИДЕО" }
        "Image" { Show-FormatsMenu -Type "Image" -TitleEn "IMAGE FORMATS" -TitleRu "ФОРМАТЫ ИЗОБРАЖЕНИЙ" }
        "Audio" { Show-FormatsMenu -Type "Audio" -TitleEn "AUDIO FORMATS" -TitleRu "ФОРМАТЫ АУДИО" }
    }
    if ($choice -eq '0') { continue }

    $target = Get-FormatByChoice -Type $fileType -Choice $choice
    if (-not $target) {
        Write-Host "  [X] $(L 'Invalid choice' 'Неверный выбор')" -ForegroundColor Red
        Wait-Enter
        continue
    }

    $dir = [System.IO.Path]::GetDirectoryName($inputFile)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
    $outPath = Join-Path $dir "$baseName`_converted.$($target.Ext)"

    Write-Host "`n  $(L 'Converting...' 'Конвертация...')" -ForegroundColor Yellow
    $ffmpegArgs = @("-hide_banner", "-loglevel", "error", "-i", $inputFile) + $target.Args + @("-y", $outPath)
    $logFile = Join-Path $env:TEMP "ffmpeg_conv.txt"

    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru -RedirectStandardError $logFile

    if ((Test-Path $outPath) -and ((Get-Item $outPath).Length -gt 0)) {
        Write-Host "  [OK] $(L 'Saved' 'Сохранено'): $outPath" -ForegroundColor Green
    } else {
        Write-Host "  [X] $(L 'Conversion failed' 'Ошибка конвертации')" -ForegroundColor Red
        if ($global:Cfg.EnableLogs -and (Test-Path $logFile)) {
            if (-not (Test-Path $global:Cfg.LogsFolder)) { New-Item -ItemType Directory -Path $global:Cfg.LogsFolder | Out-Null }
            Copy-Item $logFile (Join-Path $global:Cfg.LogsFolder "$baseName`_conv.log") -Force
        }
    }

    Wait-Enter
} while ($true)
