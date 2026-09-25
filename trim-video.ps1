$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
$global:Cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { @{Language="EN"} }
function L($en, $ru) { if ($global:Cfg.Language -eq 'RU') { return $ru } return $en }
function Show-Banner { param([string]$Title) Clear-Host; Write-Host "`n========================================================" -ForegroundColor Cyan; Write-Host "  $Title" -ForegroundColor Yellow; Write-Host "========================================================`n" -ForegroundColor Cyan }

do {
    Show-Banner (L "VIDEO TRIMMER" "ОБРЕЗКА ВИДЕО")
    Write-Host "  $(L 'Enter input file path: (drag the file into the window)' 'Введите путь к файлу: (перетащите файл в окно)')" -ForegroundColor White
    $inPath = (Read-Host "  > ").Trim().Trim('"')
    if (-not (Test-Path $inPath)) { Write-Host "  [X] $(L 'File not found' 'Файл не найден')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "`n  $(L 'Start time (e.g., 1:30 or 1 30):' 'Время начала (например, 1:30 или 1 30):')" -ForegroundColor White
    $startRaw = Read-Host "  > "
    $start = $startRaw.Trim().Replace(" ", ":")
    if ($start -notmatch '^\d+(:\d+){0,2}$') { Write-Host "  [X] $(L 'Invalid time format' 'Неверный формат времени')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "  $(L 'End time (e.g., 1:30 or 1 30):' 'Время окончания (например, 1:30 или 1 30):')" -ForegroundColor White
    $endRaw = Read-Host "  > "
    $end = $endRaw.Trim().Replace(" ", ":")
    if ($end -notmatch '^\d+(:\d+){0,2}$') { Write-Host "  [X] $(L 'Invalid time format' 'Неверный формат времени')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "`n  [1] $(L 'Fast (Stream Copy)' 'Быстро (Копирование потоков)')  [2] $(L 'Exact (Re-encode)' 'Точно (Перекодирование)')" -ForegroundColor White
    $mode = Read-Host (L "  Mode" "  Режим")
    $cArgs = if ($mode -eq '1') { @("-c", "copy") } else { @("-c:v", "libx264", "-c:a", "aac") }

    $dir = [System.IO.Path]::GetDirectoryName($inPath)
    $trimmedDir = Join-Path $dir "trimmed"
    if (-not (Test-Path $trimmedDir)) {
        New-Item -ItemType Directory -Path $trimmedDir -Force | Out-Null
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
    $out = Join-Path $trimmedDir "$base`_trimmed.mp4"
    # -----------------------------------------------

    Write-Host "`n  $(L 'Processing...' 'Обработка...')" -ForegroundColor Yellow
    $args = @("-hide_banner", "-loglevel", "error", "-y", "-i", $inPath, "-ss", $start, "-to", $end) + $cArgs + @($out)
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\trim.log"
    
    if ($proc.ExitCode -eq 0) { Write-Host "  [OK] $(L 'Saved' 'Сохранено'): $out" -ForegroundColor Green }
    else { Write-Host "  [X] $(L 'Error' 'Ошибка')" -ForegroundColor Red }

    Write-Host "`n  $(L 'Press Enter to return to Hub...' 'Нажмите Enter для возврата в Хаб...')" -ForegroundColor Gray
    Read-Host
    break
} while ($true)