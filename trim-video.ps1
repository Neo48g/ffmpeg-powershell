#Requires -Version 5.1
# ============================================================================
# trim-video.ps1 — обрезка видео по таймкоду (быстро или точно)
# ============================================================================
[CmdletBinding()]
param(
    [string]$VideoFolder   # необязательный стартовый каталог (для запуска из .bat)
)

. (Join-Path $PSScriptRoot "common.ps1")

function Read-Timecode {
    param([string]$PromptEn, [string]$PromptRu)
    Write-Host "  $(L $PromptEn $PromptRu)" -ForegroundColor White
    $raw = (Read-Host "  > ").Trim().Replace(" ", ":")
    if ($raw -notmatch '^\d+(:\d+){0,2}$') { return $null }
    return $raw
}

do {
    Show-Banner (L "VIDEO TRIMMER" "ОБРЕЗКА ВИДЕО")

    Write-Host "  $(L 'Enter input file path: (drag the file into the window)' 'Введите путь к файлу: (перетащите файл в окно)')" -ForegroundColor White
    $inPath = (Read-Host "  > ").Trim().Trim('"')
    if ($inPath -eq '0') { break }
    if (-not (Test-Path $inPath)) { Write-Host "  [X] $(L 'File not found' 'Файл не найден')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host ""
    $start = Read-Timecode -PromptEn 'Start time (e.g., 1:30 or 1 30):' -PromptRu 'Время начала (например, 1:30 или 1 30):'
    if (-not $start) { Write-Host "  [X] $(L 'Invalid time format' 'Неверный формат времени')" -ForegroundColor Red; Start-Sleep 2; continue }

    $end = Read-Timecode -PromptEn 'End time (e.g., 1:30 or 1 30):' -PromptRu 'Время окончания (например, 1:30 или 1 30):'
    if (-not $end) { Write-Host "  [X] $(L 'Invalid time format' 'Неверный формат времени')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "`n  [1] $(L 'Fast (Stream Copy)' 'Быстро (Копирование потоков)')  [2] $(L 'Exact (Re-encode)' 'Точно (Перекодирование)')" -ForegroundColor White
    $mode = Read-Host (L "  Mode" "  Режим")
    $cArgs = if ($mode -eq '1') { @("-c", "copy") } else { @("-c:v", "libx264", "-c:a", "aac") }

    $dir = Split-Path -Parent $inPath
    if (-not $dir) { $dir = (Get-Location).Path }
    $trimmedDir = Join-Path $dir "trimmed"
    if (-not (Test-Path $trimmedDir)) { New-Item -ItemType Directory -Path $trimmedDir -Force | Out-Null }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
    $out = Join-Path $trimmedDir "$base`_trimmed.mp4"

    Write-Host "`n  $(L 'Processing...' 'Обработка...')" -ForegroundColor Yellow
    $args = @("-hide_banner", "-loglevel", "error", "-y", "-i", $inPath, "-ss", $start, "-to", $end) + $cArgs + @($out)
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\trim.log"

    if ((Test-Path $out) -and ((Get-Item $out).Length -gt 0)) {
        Write-Host "  [OK] $(L 'Saved' 'Сохранено'): $out" -ForegroundColor Green
    } else {
        Write-Host "  [X] $(L 'Error' 'Ошибка')" -ForegroundColor Red
        if ($global:Cfg.EnableLogs) {
            if (-not (Test-Path $global:Cfg.LogsFolder)) { New-Item -ItemType Directory -Path $global:Cfg.LogsFolder | Out-Null }
            Copy-Item "$env:TEMP\trim.log" (Join-Path $global:Cfg.LogsFolder "$base`_trim.log") -Force -ErrorAction SilentlyContinue
        }
    }

    Wait-Enter (L "Press Enter to return to Hub..." "Нажмите Enter для возврата в Хаб...")
    break
} while ($true)
