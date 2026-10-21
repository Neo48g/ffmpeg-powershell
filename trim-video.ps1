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

# --- Логирование (папка logs в корне; все логи сохраняются туда) ---
$script:LogsFolder = [string]$global:Cfg.LogsFolder
$script:ErrorLogFile = Join-Path $script:LogsFolder "trim_errors.log"

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
                "=== Trim error log | Root folder: $ScriptDir | Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===", ""
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

    # Папка результата создаётся в главной директории скрипта: $ScriptDir\trimmed
    $trimmedDir = Join-Path $ScriptDir "trimmed"
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
        # Лог ошибки сохраняется ВСЕГДА в папку logs (корень)
        $trimLog = Join-Path $script:LogsFolder "$base`_trim.log"
        $tail = "(no output captured)"
        if (Test-Path $logFile) {
            try { $tail = ((Get-Content $logFile -Tail 40 -ErrorAction SilentlyContinue) -join "`n") } catch {}
            if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
            Copy-Item $logFile $trimLog -Force
        }
        Write-ErrorLog -Type "ERROR" -FileName $inPath -Details ("Stage: Trim failed | ExitCode: $($proc.ExitCode)`nFull FFmpeg log saved to: $trimLog`nLast FFmpeg output:`n$tail") | Out-Null
    }

    Write-Host "`n  $('Press Enter to continue...')" -ForegroundColor Gray
    Read-Host
} while ($true)
