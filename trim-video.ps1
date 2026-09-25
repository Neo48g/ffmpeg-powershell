$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
$global:Cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { @{} }
function Show-Banner { param([string]$Title) Clear-Host; Write-Host "`n========================================================" -ForegroundColor Cyan; Write-Host "  $Title" -ForegroundColor Yellow; Write-Host "========================================================`n" -ForegroundColor Cyan }

do {
    Show-Banner "VIDEO TRIMMER"
    Write-Host "  $('Enter input file path: (drag the file into the window)')" -ForegroundColor White
    $inPath = (Read-Host "  > ").Trim().Trim('"')
    if (-not (Test-Path $inPath)) { Write-Host "  [X] $('File not found')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "`n  $('Start time (e.g., 1:30 or 1 30):')" -ForegroundColor White
    $startRaw = Read-Host "  > "
    $start = $startRaw.Trim().Replace(" ", ":")
    if ($start -notmatch '^\d+(:\d+){0,2}$') { Write-Host "  [X] $('Invalid time format')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "  $('End time (e.g., 1:30 or 1 30):')" -ForegroundColor White
    $endRaw = Read-Host "  > "
    $end = $endRaw.Trim().Replace(" ", ":")
    if ($end -notmatch '^\d+(:\d+){0,2}$') { Write-Host "  [X] $('Invalid time format')" -ForegroundColor Red; Start-Sleep 2; continue }

    Write-Host "`n  [1] $('Fast (Stream Copy)')  [2] $('Exact (Re-encode)')" -ForegroundColor White
    $mode = Read-Host "  Mode"
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
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\trim.log"
    
    if ($proc.ExitCode -eq 0) { Write-Host "  [OK] $('Saved'): $out" -ForegroundColor Green }
    else { Write-Host "  [X] $('Error')" -ForegroundColor Red }

    Write-Host "`n  $('Press Enter to return to Hub...')" -ForegroundColor Gray
    Read-Host
    break
} while ($true)