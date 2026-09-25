$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
$global:Cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { @{EnableLogs=$true; LogsFolder=(Join-Path $ScriptDir "logs")} }
function Show-Banner { param([string]$Title) Clear-Host; Write-Host "`n========================================================" -ForegroundColor Cyan; Write-Host "  $Title" -ForegroundColor Yellow; Write-Host "========================================================`n" -ForegroundColor Cyan }

do {
    Show-Banner "VIDEO TRIMMER"
    Write-Host "  $('Enter input file path: (drag the file into the window), or 0 to return:')" -ForegroundColor White
    $inPath = (Read-Host "  > ").Trim().Trim('"')
    if ($inPath -eq '0' -or [string]::IsNullOrWhiteSpace($inPath)) { break }
    if (-not (Test-Path $inPath)) { Write-Host "  [X] $('File not found')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "`n  $('Start time (e.g., 1:30 or 1 30). Enter 0 to go back:')" -ForegroundColor White
    $startRaw = Read-Host "  > "
    if ($startRaw.Trim() -eq '0') { continue }
    $start = $startRaw.Trim().Replace(" ", ":")
    if ($start -notmatch '^\d+(:\d+){0,2}$') { Write-Host "  [X] $('Invalid time format')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "  $('End time (e.g., 1:30 or 1 30). Enter 0 to go back:')" -ForegroundColor White
    $endRaw = Read-Host "  > "
    if ($endRaw.Trim() -eq '0') { continue }
    $end = $endRaw.Trim().Replace(" ", ":")
    if ($end -notmatch '^\d+(:\d+){0,2}$') { Write-Host "  [X] $('Invalid time format')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "`n  [1] $('Fast (Stream Copy)')  [2] $('Exact (Re-encode)')  [0] $('Back')" -ForegroundColor White
    $mode = Read-Host "  Mode"
    if ($mode -eq '0') { continue }
    $cArgs = if ($mode -eq '1') { @("-c", "copy") } else { @("-c:v", "libx264", "-c:a", "aac") }

    $dir = [System.IO.Path]::GetDirectoryName($inPath)
    $trimmedDir = Join-Path $dir "trimmed"
    if (-not (Test-Path $trimmedDir)) {
        New-Item -ItemType Directory -Path $trimmedDir -Force | Out-Null
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
    $out = Join-Path $trimmedDir "$base`_trimmed.mp4"
    # -----------------------------------------------

    Write-Host "`n  $('Processing...')" -ForegroundColor Yellow
    $args = @("-hide_banner", "-loglevel", "error", "-y", "-i", $inPath, "-ss", $start, "-to", $end) + $cArgs + @($out)
    $logFile = Join-Path $env:TEMP "ffmpeg_trim.txt"
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardError $logFile

    if ($proc.ExitCode -eq 0) { Write-Host "  [OK] $('Saved'): $out" -ForegroundColor Green }
    else {
        Write-Host "  [X] $('Error')" -ForegroundColor Red
        if ($global:Cfg.EnableLogs -and (Test-Path $logFile)) {
            if (-not (Test-Path $global:Cfg.LogsFolder)) { New-Item -ItemType Directory -Path $global:Cfg.LogsFolder | Out-Null }
            Copy-Item $logFile (Join-Path $global:Cfg.LogsFolder "$base`_trim.log") -Force
        }
    }

    Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
    Read-Host
} while ($true)
