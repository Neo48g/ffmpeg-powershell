#Requires -Version 5.1
$ScriptDir = $PSScriptRoot; if (-not $ScriptDir) { $ScriptDir = Get-Location }
$ConfigFile = Join-Path $ScriptDir "global_config.json"
$PresetsFile = Join-Path $ScriptDir "presets.json"

# --- Глобальная конфигурация ---
# Создание логов выключено по умолчанию; все логи сохраняются в папку logs
$global:Cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { @{EnableLogs=$false; LogsFolder=(Join-Path $ScriptDir "logs")} }
if (-not ($global:Cfg.PSObject.Properties['LogsFolder'] -or ($global:Cfg -is [System.Collections.IDictionary] -and $global:Cfg.Contains('LogsFolder')))) {
    $global:Cfg = $global:Cfg + @{ LogsFolder = (Join-Path $ScriptDir "logs") }
}
if (-not ($global:Cfg.PSObject.Properties['EnableLogs'] -or ($global:Cfg -is [System.Collections.IDictionary] -and $global:Cfg.Contains('EnableLogs')))) {
    $global:Cfg = $global:Cfg + @{ EnableLogs = $false }
}

function Show-Banner {
    param([string]$Title)
    Clear-Host
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "========================================================`n" -ForegroundColor Cyan
}

# --- Переменные состояния ---
# Файлы для сжатия добавляются перетаскиванием (drag & drop) в окно скрипта (как в опции Trim)
$script:selectedFiles = New-Object System.Collections.Generic.List[string]
$script:crfValue = 23; $script:hwDevice = "CPU"; $script:codec = "h264"
$script:enableVMAF = $false; $script:enableAutoCRF = $false
$script:vmafThreshold = 90; $script:maxIterations = 3; $script:minCRF = 18
# Ограничение целевого размера файла (МБ). 0 = выключено. Варианты: 10, 20 или своё значение.
$script:targetSizeMB = 0
$script:LastProgressInfo = @{ CurrentTime = 0.0; Percent = 0.0 }  # обновляется циклом прогресса
$script:presets = @{}
$extensions = @(".mp4",".mkv",".avi",".mov",".m4v",".webm",".ts",".mts",".flv",".wmv")
$excludedFolders = @("compressed", "trimmed", "converted", "downloaded", "logs")

# --- Управление пресетами ---
function Load-Presets {
    if (Test-Path $PresetsFile) {
        try {
            $jsonData = Get-Content $PresetsFile -Raw | ConvertFrom-Json
            $script:presets = @{}
            foreach ($prop in $jsonData.PSObject.Properties) { $script:presets[$prop.Name] = $prop.Value }
        } catch { $script:presets = @{} }
    }
}
function Save-Presets { $script:presets | ConvertTo-Json -Depth 5 | Out-File -FilePath $PresetsFile -Encoding UTF8 -Force }

function Show-PresetsMenu {
    do {
        Show-Banner "PRESETS MANAGEMENT"
        Write-Host "  [1] $('Save current settings')" -ForegroundColor White
        Write-Host "  [2] $('Load preset')" -ForegroundColor White
        Write-Host "  [3] $('Delete preset')" -ForegroundColor White
        Write-Host "`n  [0] $('Back')" -ForegroundColor Red

        $c = Read-Host "  Choice"
        switch ($c) {
            '1' {
                $name = Read-Host "  Enter preset name"
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $script:presets[$name] = @{
                    HwDevice=$script:hwDevice; Codec=$script:codec; CRF=$script:crfValue
                    EnableVMAF=$script:enableVMAF; EnableAutoCRF=$script:enableAutoCRF
                    VMAFThreshold=$script:vmafThreshold; MaxIterations=$script:maxIterations; MinCRF=$script:minCRF
                    TargetSizeMB=$script:targetSizeMB
                }
                Save-Presets
                Write-Host "`n  [OK] $('Preset saved')" -ForegroundColor Green
                Start-Sleep 1
            }
            '2' {
                if ($script:presets.Count -eq 0) { Write-Host "`n  [X] $('No presets saved')" -ForegroundColor Red; Start-Sleep 1; continue }
                $keys = $script:presets.Keys | Sort-Object; $i = 1
                foreach ($k in $keys) { Write-Host "  [$i] $k ($($script:presets[$k].HwDevice) | $($script:presets[$k].Codec) | CRF:$($script:presets[$k].CRF) | $(if ($script:presets[$k].TargetSizeMB -gt 0) { "<=$($script:presets[$k].TargetSizeMB) MB" } else { 'MaxSize:OFF' }))" -ForegroundColor White; $i++ }
                $idx = Read-Host "  Select number"
                if ($idx -match '^\d+$' -and [int]$idx -ge 1 -and [int]$idx -le $keys.Count) {
                    $p = $script:presets[$keys[[int]$idx - 1]]
                    $script:hwDevice=$p.HwDevice; $script:codec=$p.Codec; $script:crfValue=[int]$p.CRF
                    $script:enableVMAF=[bool]$p.EnableVMAF; $script:enableAutoCRF=[bool]$p.EnableAutoCRF
                    $script:vmafThreshold=[int]$p.VMAFThreshold; $script:maxIterations=[int]$p.MaxIterations; $script:minCRF=[int]$p.MinCRF
                    if ($null -ne $p.TargetSizeMB) { $script:targetSizeMB = [double]$p.TargetSizeMB } else { $script:targetSizeMB = 0 }
                    Write-Host "`n  [OK] $('Preset loaded')" -ForegroundColor Green
                    Start-Sleep 1
                }
            }
            '3' {
                if ($script:presets.Count -eq 0) { Write-Host "`n  [X] $('No presets saved')" -ForegroundColor Red; Start-Sleep 1; continue }
                $keys = $script:presets.Keys | Sort-Object; $i = 1
                foreach ($k in $keys) { Write-Host "  [$i] $k" -ForegroundColor White; $i++ }
                $idx = Read-Host "  Select number to delete"
                if ($idx -match '^\d+$' -and [int]$idx -ge 1 -and [int]$idx -le $keys.Count) {
                    $script:presets.Remove($keys[[int]$idx - 1]); Save-Presets
                    Write-Host "`n  [OK] $('Preset deleted')" -ForegroundColor Green
                    Start-Sleep 1
                }
            }
            '0' { return }
        }
    } while ($true)
}

# --- Логирование ошибок и зависаний ---
# Все логи сохраняются в папку logs; создание логов выключено по умолчанию (EnableLogs=false)
$script:LogsFolder = if ($global:Cfg.LogsFolder) { [string]$global:Cfg.LogsFolder } else { Join-Path $ScriptDir "logs" }
$script:ErrorLogFile = Join-Path $script:LogsFolder "compression_errors.log"
$script:NoProgressTimeoutSec = 300     # секунд без прогресса => процесс считается зависшим
# $script:MaxRuntimeSec = 7200          # максимальное время обработки одного файла (сек)

# Значения можно переопределить в global_config.json: NoProgressTimeoutSec / MaxRuntimeSec
if ($null -ne $global:Cfg.NoProgressTimeoutSec) { $script:NoProgressTimeoutSec = [int]$global:Cfg.NoProgressTimeoutSec }
if ($null -ne $global:Cfg.MaxRuntimeSec)        { $script:MaxRuntimeSec = [int]$global:Cfg.MaxRuntimeSec }

# --- Сжатие до целевого размера файла (двухпроходное кодирование по битрейту) ---
# Возвращает строку аргументов ffmpeg для одного прохода; $PassNum = 1 или 2.
function Build-TwoPassArgs {
    param([int]$VideoBitrateK, [double]$AudioBitrateK, [int]$PassNum, [string]$PassLogFile)
    $vCodec = switch ($script:codec) { "h265" {"libx265"} "av1" {"libsvtav1"} default {"libx264"} }
    $aArgs = if ($AudioBitrateK -gt 0) { "-c:a aac -b:a ${AudioBitrateK}k" } else { "-an" }
    $passLogArg = if ($PassLogFile) { " -passlogfile `"$PassLogFile`"" } else { "" }
    return "-c:v $vCodec -preset medium -b:v ${VideoBitrateK}k -maxrate ${VideoBitrateK}k -bufsize $([int]($VideoBitrateK * 2))k -pass $PassNum$passLogArg $aArgs"
}

# Двухпроходное сжатие до целевого размера. Возвращает $true при успехе.
function Invoke-TwoPassToTargetSize {
    param([string]$SrcPath, [string]$OutPath, [pscustomobject]$Meta, [double]$TargetMB)
    $duration = [double]$Meta.duration
    if ($duration -le 0) { return $false }

    $targetBytes  = [math]::Floor($TargetMB * 1MB * 0.98)  # 2% запас на контейнер
    $targetBits   = $targetBytes * 8.0
    $audioBits    = [double]$Meta.audioBitrate             # бит/сек (0 = аудио нет)
    $videoTotalK  = [int][math]::Floor(($targetBits / $duration - $audioBits) / 1000.0)
    $minVideoKbps = if ($Meta.width -ge 1920) { 300 } elseif ($Meta.width -ge 1280) { 200 } else { 120 }
    if ($videoTotalK -lt $minVideoKbps) { $videoTotalK = $minVideoKbps }

    # Разделение видео-битрейта между проходами: первый проход — анализ (stats), второй — финальный файл
    $pass1K = [int][math]::Max(120, $videoTotalK * 0.4); $pass2K = $videoTotalK
    $passLog = Join-Path $env:TEMP ("ffmpeg2pass_" + [System.IO.Path]::GetFileNameWithoutExtension($OutPath))
    Remove-Item "$passLog*.log*" -Force -ErrorAction SilentlyContinue
    $swAll = [System.Diagnostics.Stopwatch]::StartNew()

    for ($pass = 1; $pass -le 2; $pass++) {
        $bk = if ($pass -eq 1) { $pass1K } else { $pass2K }
        $vArgs = Build-TwoPassArgs -VideoBitrateK $bk -AudioBitrateK ([int]($audioBits/1000)) -PassNum $pass -PassLogFile $passLog
        $args = "-hide_banner -loglevel info -i `"$SrcPath`" $vArgs -y `"$OutPath`""
        $logFile = Join-Path $env:TEMP "ffmpeg_comp_pass$pass.txt"
        if ($pass -eq 2 -and (Test-Path $OutPath)) { Remove-Item $OutPath -Force -ErrorAction SilentlyContinue }

        Write-Host "  -> $('Two-pass compression'): pass $pass/2 | $('Video bitrate'): ${bk} kbps" -ForegroundColor Cyan
        $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $args -RedirectStandardError $logFile -PassThru -NoNewWindow

        $lastTime = -1.0; $lastLogSize = 0; $lastOutSize = 0; $lastProgressAt = $swAll.Elapsed
        $hung = $false
        while (-not $proc.HasExited) {
            $currentTime = 0
            if (Test-Path $logFile) {
                try {
                    foreach ($line in @(Get-Content $logFile -Tail 5 -ErrorAction SilentlyContinue)) {
                        if ($line -match 'time=(\d+):(\d+):(\d+(?:\.\d+)?)') {
                            $currentTime = [int]$matches[1]*3600 + [int]$matches[2]*60 + [double]$matches[3]
                        }
                    }
                } catch {}
            }
            $percent = 0
            if ($duration -gt 0) { $percent = [math]::Min(100, ($currentTime / $duration) * 100) }
            $status = "Pass $pass/2 | $('Time'): $($swAll.Elapsed.ToString('hh\:mm\:ss')) | $('Press L to write log')"
            if ($duration -gt 0) { $status += " | $('Progress'): $([math]::Round($percent, 1))%" }
            Write-Progress -Activity "('Two-pass compression'): $(Split-Path $OutPath -Leaf)" -Status $status -PercentComplete $percent -Id 1

            $script:LastProgressInfo.CurrentTime = $currentTime
            $script:LastProgressInfo.Percent = $percent
            if (Test-LoggingHotkey) {
                $res = Write-ProgressLog -FileName $SrcPath -Stage "CompressPass$pass" -Iteration $pass `
                    -CurrentCRF $videoTotalK -ElapsedSec $swAll.Elapsed.TotalSeconds -LogFile $logFile `
                    -FileCount 1 -Index 1
                if ($res.Success) { Write-Host "`n  [LOG] $('State written to log'): $($res.LogFile)" -ForegroundColor Magenta }
            }

            $logSize = 0; $outSize = 0
            try { if (Test-Path $logFile) { $logSize = (Get-Item $logFile).Length } } catch {}
            try { if (Test-Path $OutPath) { $outSize = (Get-Item $OutPath).Length } } catch {}
            if ($currentTime -gt $lastTime -or $logSize -ne $lastLogSize -or $outSize -ne $lastOutSize) {
                $lastTime = $currentTime; $lastLogSize = $logSize; $lastOutSize = $outSize
                $lastProgressAt = $swAll.Elapsed
            } elseif ($swAll.Elapsed.TotalSeconds -gt $script:MaxRuntimeSec) {
                $hung = $true
                Write-Host "`n  [!] $('Process hung detected: max runtime exceeded'). $('Stopping FFmpeg...')" -ForegroundColor Red
                try { & taskkill /F /T /PID $proc.Id 2>$null | Out-Null; $proc.Kill() } catch {}
                break
            } elseif (($swAll.Elapsed - $lastProgressAt).TotalSeconds -gt $script:NoProgressTimeoutSec) {
                $hung = $true
                Write-Host "`n  [!] $('Process hung detected: no progress for') $([int]$script:NoProgressTimeoutSec)$(' s'). $('Stopping FFmpeg...')" -ForegroundColor Red
                try { & taskkill /F /T /PID $proc.Id 2>$null | Out-Null; $proc.Kill() } catch {}
                break
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Progress -Activity "('Two-pass compression'): $(Split-Path $OutPath -Leaf)" -Completed -Id 1

        if ($hung) {
            $savedLog = Save-FFmpegLogToRoot -SourceLog $logFile -Stage "two-pass_hang" -SrcName (Split-Path $OutPath -Leaf)
            Write-ErrorLog -Type "HANG" -FileName $SrcPath -Details (
                "Stage: Two-pass compression, pass $pass | Target: $TargetMB MB | Video bitrate: ${bk} kbps`n" +
                "Command: ffmpeg $args`n" +
                $(if ($savedLog) { "Full FFmpeg log saved to: $savedLog`n" } else { "" }) +
                "Last FFmpeg output:`n" + (Get-FFmpegTail -Path $logFile)
            ) | Out-Null
            Remove-Item $OutPath -Force -ErrorAction SilentlyContinue
            Remove-Item "$passLog*.log*" -Force -ErrorAction SilentlyContinue
            return $false
        }
        if ($pass -eq 2 -and -not ((Test-Path $OutPath) -and ((Get-Item $OutPath).Length -gt 0))) {
            $savedLog = Save-FFmpegLogToRoot -SourceLog $logFile -Stage "two-pass_error" -SrcName (Split-Path $OutPath -Leaf)
            Write-ErrorLog -Type "ERROR" -FileName $SrcPath -Details (
                "Stage: Two-pass compression, pass 2 failed | Target: $TargetMB MB | Video bitrate: ${bk} kbps`n" +
                "Command: ffmpeg $args`n" +
                $(if ($savedLog) { "Full FFmpeg log saved to: $savedLog`n" } else { "" }) +
                "Last FFmpeg output:`n" + (Get-FFmpegTail -Path $logFile)
            ) | Out-Null
            Remove-Item "$passLog*.log*" -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    Remove-Item "$passLog*.log*" -Force -ErrorAction SilentlyContinue

    # Финальная проверка: если файл всё ещё больше лимита — ужесточаем битрейт и пережимаем (до 2 попыток)
    $attempt = 0
    while ($attempt -lt 2) {
        $curBytes = if (Test-Path $OutPath) { (Get-Item $OutPath).Length } else { 0 }
        if ($curBytes -eq 0) { return $false }
        if ($curBytes -le [math]::Floor($TargetMB * 1MB)) { break }
        $attempt++
        $overRatio = $TargetMB * 1MB / [double]$curBytes
        $videoTotalK = [int][math]::Max($minVideoKbps, [math]::Floor($videoTotalK * $overRatio * 0.95))
        Write-Host "  -> $('Over target size, retrying'): pass $($attempt + 2)/... | $('Video bitrate'): ${videoTotalK} kbps" -ForegroundColor Cyan
        $bk = $videoTotalK
        $vArgs = Build-TwoPassArgs -VideoBitrateK ([int][math]::Max(120, $bk * 0.4)) -AudioBitrateK ([int]($audioBits/1000)) -PassNum 1 -PassLogFile $passLog
        $argsP1 = "-hide_banner -loglevel info -i `"$SrcPath`" $vArgs -y `"$OutPath`""
        $logP1 = Join-Path $env:TEMP "ffmpeg_comp_pass1.txt"
        $procP1 = Start-Process -FilePath "ffmpeg" -ArgumentList $argsP1 -RedirectStandardError $logP1 -Wait -PassThru -NoNewWindow
        $vArgs2 = Build-TwoPassArgs -VideoBitrateK $bk -AudioBitrateK ([int]($audioBits/1000)) -PassNum 2 -PassLogFile $passLog
        if (Test-Path $OutPath) { Remove-Item $OutPath -Force -ErrorAction SilentlyContinue }
        $argsP2 = "-hide_banner -loglevel info -i `"$SrcPath`" $vArgs2 -y `"$OutPath`""
        $logP2 = Join-Path $env:TEMP "ffmpeg_comp_pass2.txt"
        $procP2 = Start-Process -FilePath "ffmpeg" -ArgumentList $argsP2 -RedirectStandardError $logP2 -Wait -PassThru -NoNewWindow
        if (-not ((Test-Path $OutPath) -and ((Get-Item $OutPath).Length -gt 0))) {
            $savedLog = Save-FFmpegLogToRoot -SourceLog $logP2 -Stage "two-pass_retry_error" -SrcName (Split-Path $OutPath -Leaf)
            Write-ErrorLog -Type "ERROR" -FileName $SrcPath -Details ("Stage: Two-pass retry failed | Target: $TargetMB MB | Video bitrate: ${bk} kbps`n" + $(if ($savedLog) { "Full FFmpeg log saved to: $savedLog`n" } else { "" }) + "Last FFmpeg output:`n" + (Get-FFmpegTail -Path $logP2)) | Out-Null
            Remove-Item "$passLog*.log*" -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    Remove-Item "$passLog*.log*" -Force -ErrorAction SilentlyContinue
    return $true
}

# Получение метаданных файла: длительность, аудио-битрейт (бит/сек), разрешение
function Get-VideoMeta {
    param([string]$Path)
    $meta = [pscustomobject]@{ duration = 0.0; audioBitrate = 0.0; width = 0 }
    try {
        $json = & ffprobe -v error -print_format json -show_format -show_streams "$Path" 2>$null | Out-String
        if ($json) {
            $obj = $json | ConvertFrom-Json
            if ($obj.format.duration) { $meta.duration = [double]$obj.format.duration }
            foreach ($st in @($obj.streams)) {
                if ($st.codec_type -eq 'video' -and $st.width -and $meta.width -eq 0) { $meta.width = [int]$st.width }
                if ($st.codec_type -eq 'audio' -and $st.bit_rate) {
                    $br = [double]$st.bit_rate
                    if ($br -gt $meta.audioBitrate) { $meta.audioBitrate = $br }
                }
            }
        }
    } catch {
        Write-ErrorLog -Type "ERROR" -FileName $Path -Details "Stage: ffprobe metadata check failed`n$($_.Exception.Message)" | Out-Null
    }
    return $meta
}

function Write-ErrorLog {
    param(
        [string]$Type,        # ERROR | HANG | INFO
        [string]$FileName,
        [string]$Details
    )
    # Создание логов выключено по умолчанию — записи не пишутся, файлы не создаются
    if (-not $global:Cfg.EnableLogs) { return $false }
    try {
        if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
        # Если лог-файл был удалён вручную — пересоздаём его с заголовком
        if (-not (Test-Path $script:ErrorLogFile)) {
            Set-Content -Path $script:ErrorLogFile -Value @(
                "=== Compression error log | Root folder: $ScriptDir | Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===", ""
            ) -Encoding UTF8
        }
        $entry = @(
            "======================================================================"
            "[$Type] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "File: $FileName"
            "Settings: HW=$script:hwDevice | Codec=$script:codec | CRF=$script:crfValue | VMAF=$(if($script:enableVMAF){'ON'}else{'OFF'})"
            "Details:"
            $Details
            ""
        ) -join [Environment]::NewLine
        Add-Content -Path $script:ErrorLogFile -Value $entry -Encoding UTF8
        return $true
    } catch { return $false }
}

function Get-FFmpegTail {
    param([string]$Path, [int]$Lines = 40)
    if (Test-Path $Path) {
        try { return ((Get-Content $Path -Tail $Lines -ErrorAction SilentlyContinue) -join "`n") } catch {}
    }
    return "(no output captured)"
}

# Сохраняет полный вывод ffmpeg в папку logs (для разбора проблемы)
function Save-FFmpegLogToRoot {
    param([string]$SourceLog, [string]$Stage, [string]$SrcName)
    # Создание логов выключено по умолчанию — снимки не сохраняются
    if (-not $global:Cfg.EnableLogs) { return $null }
    try {
        if (-not (Test-Path $SourceLog)) { return $null }
        if (-not (Test-Path $script:LogsFolder)) { New-Item -ItemType Directory -Path $script:LogsFolder -Force | Out-Null }
        $safeName = ($SrcName -replace '[^\w\.\-]', '_')
        $dest = Join-Path $script:LogsFolder ("ffmpeg_{0}_{1}.log" -f $Stage, $safeName)
        Copy-Item -Path $SourceLog -Destination $dest -Force
        return $dest
    } catch { return $null }
}

# --- Лог по нажатию клавиши во время процесса сжатия ---
$script:LastProgressInfo = @{ CurrentTime = 0.0; Percent = 0.0 }  # обновляется циклом прогресса

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

# Создаёт запись в корневом логе ошибок с текущим состоянием процесса (по нажатию клавиши L)
function Write-ProgressLog {
    param(
        [string]$FileName,       # обрабатываемый файл
        [string]$Stage,          # Compress / VMAF
        [int]$Iteration,         # номер итерации сжатия
        [int]$CurrentCRF,        # текущий CRF
        [double]$ElapsedSec,     # сколько секунд идёт процесс
        [string]$LogFile,        # временный лог ffmpeg (для хвоста и сохранения копии)
        [int]$FileCount,         # всего файлов в очереди
        [int]$Index              # номер текущего файла
    )
    $info = $script:LastProgressInfo
    $elapsedStr = [TimeSpan]::FromSeconds($ElapsedSec).ToString('hh\:mm\:ss')
    $details = @(
        "Manual log request (key 'L' pressed)"
        "Stage: $Stage | File $Index/$FileCount | Iteration: $Iteration"
        "Progress: $([math]::Round($info.Percent, 1))% | FFmpeg time: $([math]::Round($info.CurrentTime, 1)) s | Elapsed: $elapsedStr"
    ) -join [Environment]::NewLine
    $savedLog = Save-FFmpegLogToRoot -SourceLog $LogFile -Stage "manual" -SrcName $FileName
    if ($savedLog) {
        $details += [Environment]::NewLine + "Full FFmpeg log snapshot saved to: $savedLog"
    }
    $details += [Environment]::NewLine + "Last FFmpeg output:" + [Environment]::NewLine + (Get-FFmpegTail -Path $LogFile)
    $ok = Write-ErrorLog -Type "MANUAL" -FileName $FileName -Details $details
    return [pscustomobject]@{ Success = $ok; LogFile = $script:ErrorLogFile; Snapshot = $savedLog }
}

# --- Вспомогательные функции основных настроек ---
# Drag & drop: при перетаскивании файлов в окно консоли Windows их пути добавляются в очередь сжатия.
function Add-FilesToQueue {
    param([string[]]$Paths)
    $added = 0; $skipped = 0
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $clean = $p.Trim().Trim('"').Trim("'")
        if (-not (Test-Path -LiteralPath $clean)) { $skipped++; continue }
        $item = Get-Item -LiteralPath $clean
        if ($item.PSIsContainer) {
            # если перетащили папку — берём из неё видеофайлы
            Get-ChildItem -LiteralPath $clean -File -ErrorAction SilentlyContinue | Where-Object { $extensions -contains $_.Extension.ToLower() } | ForEach-Object {
                if (-not $script:selectedFiles.Contains($_.FullName)) { $script:selectedFiles.Add($_.FullName); $added++ }
            }
        } elseif ($extensions -contains $item.Extension.ToLower()) {
            if (-not $script:selectedFiles.Contains($item.FullName)) { $script:selectedFiles.Add($item.FullName); $added++ }
        } else { $skipped++ }
    }
    return [pscustomobject]@{ Added = $added; Skipped = $skipped }
}

function Build-FileList {
    $items = @()
    foreach ($fp in $script:selectedFiles) {
        if (Test-Path -LiteralPath $fp) {
            $fi = New-Object System.IO.FileInfo($fp)
            $items += [pscustomobject]@{ Name = $fi.Name; FullName = $fi.FullName; BaseName = $fi.BaseName }
        }
    }
    return ,@($items)
}

function Build-FFmpegArgs {
    param([int]$Quality)
    $vArgs = ""
    if ($script:hwDevice -eq "CPU") {
        $enc = switch ($script:codec) { "h264" {"libx264"} "h265" {"libx265"} "av1" {"libsvtav1"} default {"libx264"} }
        $vArgs = "-c:v $enc -crf $Quality -preset medium"
    } else {
        $enc = switch ($script:hwDevice) {
            "NVIDIA" { switch ($script:codec) { "h264" {"h264_nvenc"} "h265" {"hevc_nvenc"} "av1" {"av1_nvenc"} } }
            "AMD"    { switch ($script:codec) { "h264" {"h264_amf"} "h265" {"hevc_amf"} "av1" {"av1_amf"} } }
            "Intel"  { switch ($script:codec) { "h264" {"h264_qsv"} "h265" {"hevc_qsv"} "av1" {"av1_qsv"} } }
        }
        $vArgs = "-c:v $enc -cq $Quality -preset p4"
    }
    return $vArgs
}

# --- Главный цикл меню ---
Load-Presets
# Если файлы были перетащены в окно при запуске — сразу добавляем их в очередь
$initialDrop = @($args)
if ($initialDrop.Count -gt 0) { Add-FilesToQueue -Paths $initialDrop | Out-Null }

:MainLoop do {
    Show-Banner "VIDEO COMPRESSION"
    $files = Build-FileList
    Write-Host "  $('Files for compression'): $($files.Count)" -ForegroundColor White
    foreach ($fd in $files) { Write-Host "    - $($fd.Name)" -ForegroundColor Gray }
    Write-Host "  $('HW'): $script:hwDevice | $('Codec'): $script:codec | $('CRF'): $script:crfValue" -ForegroundColor White
    Write-Host "  $('VMAF'): $(if($script:enableVMAF){'ON'}else{'OFF'}) | $('AutoCRF'): $(if($script:enableAutoCRF){'ON'}else{'OFF'}) | $('Presets'): $($script:presets.Count)" -ForegroundColor White
    $sizeTxt = if ($script:targetSizeMB -gt 0) { "<= $script:targetSizeMB MB" } else { "OFF" }
    Write-Host "  $('Max file size'): $sizeTxt" -ForegroundColor White
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [1] $('Add Files (drag & drop into this window)')" -ForegroundColor White
    Write-Host "  [2] $('Hardware & Codec')" -ForegroundColor White
    Write-Host "  [3] $('Quality & VMAF')" -ForegroundColor White
    Write-Host "  [4] $('Max File Size') ($sizeTxt)" -ForegroundColor White
    Write-Host "  [5] $('Presets Management')" -ForegroundColor White
    Write-Host "  [6] $('Clear File List')" -ForegroundColor White
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [0] $('START COMPRESSION')" -ForegroundColor Green
    Write-Host "  [9] $('Back to Hub')" -ForegroundColor Red
    Write-Host "  $('Tip'): Press L during compression to write a log entry" -ForegroundColor DarkGray

    $c = Read-Host "  Choice"
    switch ($c) {
        '1' {
            Write-Host "`n  $('Drag file or folder with files into window, then press Enter:')  $('(empty line to cancel)')" -ForegroundColor Yellow
            $dropped = @()
            while ($true) {
                $line = Read-Host "  > "
                if ([string]::IsNullOrWhiteSpace($line)) { break }
                # строка может содержать несколько путей в кавычках или через пробел/запятую (как при drag&drop)
                $trimmedLine = $line.Trim().Trim('"')
                $parts = @([regex]::Matches($trimmedLine, '"([^"]*)"|[^",]+') | ForEach-Object { $_.Value.Trim().Trim('"') } | Where-Object { $_ })
                foreach ($pt in $parts) { $dropped += $pt.Trim().Trim('"', "'") }
            }
            if ($dropped.Count -gt 0) {
                $res = Add-FilesToQueue -Paths $dropped
                Write-Host "  [OK] $('Added'): $($res.Added)" -ForegroundColor Green
                if ($res.Skipped -gt 0) { Write-Host "  [!] $('Skipped (not found or not a video file)'): $($res.Skipped)" -ForegroundColor Yellow }
                Start-Sleep 1
            }
        }
        '2' {
            Show-Banner "HARDWARE & CODEC"
            Write-Host "  [1] CPU  [2] NVIDIA  [3] AMD  [4] Intel" -ForegroundColor White
            $hwC = Read-Host "  Select HW"
            $script:hwDevice = switch($hwC) { '1'{'CPU'} '2'{'NVIDIA'} '3'{'AMD'} '4'{'Intel'} default{'CPU'} }
            Write-Host "  [1] H.264  [2] H.265  [3] AV1" -ForegroundColor White
            $cC = Read-Host "  Select Codec"
            $script:codec = switch($cC) { '1'{'h264'} '2'{'h265'} '3'{'av1'} default{'h264'} }
        }
        '3' {
            Show-Banner "QUALITY & VMAF"
            $v = Read-Host "  CRF (0-51) [$script:crfValue]"
            if ($v -match '^\d+$') { $script:crfValue = [int]$v }
            $script:enableVMAF = (Read-Host "  Enable VMAF? (Y/N)") -match '^[Yy]'
            if ($script:enableVMAF) {
                $script:enableAutoCRF = (Read-Host "  Enable AutoCRF? (Y/N)") -match '^[Yy]'
                if ($script:enableAutoCRF) {
                    $t = Read-Host "  VMAF Threshold (0-100) [$script:vmafThreshold]"
                    if ($t -match '^\d+$') { $script:vmafThreshold = [int]$t }
                }
            }
        }
        '4' {
            # Отдельное меню ограничения максимального размера файла
            # (двухпроходное сжатие по битрейту до целевого веса)
            Show-Banner "MAX FILE SIZE"
            $curTxt = if ($script:targetSizeMB -gt 0) { "<= $script:targetSizeMB MB" } else { "OFF" }
            Write-Host "  $('Current'): $curTxt" -ForegroundColor White
            Write-Host "  [1] $('Off')  [2] 10 MB  [3] 20 MB  $('or enter custom size in MB')" -ForegroundColor White
            $sz = Read-Host "  Choice [$($script:targetSizeMB)]"
            if ($sz -eq '1') { $script:targetSizeMB = 0 }
            elseif ($sz -eq '2') { $script:targetSizeMB = 10 }
            elseif ($sz -eq '3') { $script:targetSizeMB = 20 }
            elseif ($sz -match '^\d+(\.\d+)?$' -and [double]$sz -gt 0) { $script:targetSizeMB = [double]$sz }
            $newTxt = if ($script:targetSizeMB -gt 0) { "<= $script:targetSizeMB MB" } else { "OFF" }
            Write-Host "  $('Max file size'): $newTxt" -ForegroundColor Green
            Start-Sleep 1
        }
        '5' { Show-PresetsMenu }
        '6' { $script:selectedFiles.Clear() }
        '0' {
            if ($files.Count -eq 0) { Write-Host "`n  [X] $('No files found')" -ForegroundColor Red; Start-Sleep 2; continue }
            # Папка результата создаётся в главной директории скрипта (например: $ScriptDir\compressed)
            function Get-CompressedOutFile {
                param($SrcFile)
                $outDir = Join-Path $ScriptDir "compressed"
                if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
                return Join-Path $outDir "$($SrcFile.BaseName)_compressed.mp4"
            }

            # Пишем в корневой лог начало каждого прогона сжатия (INFO) — ошибки ищутся по метке [ERROR]/[HANG]
            $sizeTxt = if ($script:targetSizeMB -gt 0) { "<= $script:targetSizeMB MB" } else { "OFF" }
            Write-ErrorLog -Type "INFO" -FileName "$($files.Count) file(s)" -Details "Run started | Output: $ScriptDir\compressed\*_compressed.mp4 | MaxFileSize: $sizeTxt" | Out-Null

            try {
            $i = 1; foreach ($f in $files) {
                $outFile = Get-CompressedOutFile -SrcFile $f
                Write-Host "`n  [$i/$($files.Count)] $($f.Name)" -ForegroundColor Yellow

                # Получаем длительность для индикатора выполнения
                $duration = 0
                try {
                    $durStr = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$($f.FullName)" 2>$null
                    if ($durStr) { $duration = [double]$durStr }
                } catch {
                    Write-ErrorLog -Type "ERROR" -FileName $f.FullName -Details "Stage: ffprobe duration check failed`n$($_.Exception.Message)" | Out-Null
                }

                # --- Режим ограничения максимального размера файла (например, 10 или 20 МБ) ---
                if ($script:targetSizeMB -gt 0) {
                    $meta = Get-VideoMeta -Path $f.FullName
                    if ($meta.duration -le 0) {
                        Write-Host "  [X] $('Could not read video duration, skipping')" -ForegroundColor Red
                        $i++
                        continue
                    }
                    $srcMB = [math]::Round((Get-Item $f.FullName).Length / 1MB, 2)
                    $curOutMB = 0
                    if (Test-Path $outFile) { $curOutMB = [math]::Round((Get-Item $outFile).Length / 1MB, 2) }
                    if (($srcMB -le $script:targetSizeMB) -and ($curOutMB -eq 0 -or $curOutMB -le $script:targetSizeMB)) {
                        Write-Host "  [=] $('Already within size limit') ($srcMB $('MB'))" -ForegroundColor Gray
                        $i++
                        continue
                    }
                    $tpOk = Invoke-TwoPassToTargetSize -SrcPath $f.FullName -OutPath $outFile -Meta $meta -TargetMB $script:targetSizeMB
                    if (-not $tpOk) {
                        Write-Host "  [X] $('Two-pass compression failed, logged')" -ForegroundColor Red
                        break
                    }
                    $finalBytes = (Get-Item $outFile).Length
                    $finalMB = [math]::Round($finalBytes / 1MB, 2)
                    if ($finalBytes -gt [math]::Floor($script:targetSizeMB * 1MB)) {
                        Write-Host "  [!] $('Result exceeds target size'): $finalMB $('MB') > $script:targetSizeMB $('MB'). $('Lower bitrate floor reached')" -ForegroundColor Yellow
                        Write-ErrorLog -Type "ERROR" -FileName $f.FullName -Details "Stage: Two-pass result over target | Final: $finalMB MB | Target: $script:targetSizeMB MB" | Out-Null
                    } else {
                        Write-Host "  [OK] $('Final size'): $finalMB / $script:targetSizeMB $('MB')" -ForegroundColor Green
                    }
                    $i++
                    continue
                }

                                $currentCRF = $script:crfValue; $iteration = 0; $needsRecompress = $true
                while ($needsRecompress) {
                    $iteration++
                    $vArgs = Build-FFmpegArgs -Quality $currentCRF
                    $args = "-hide_banner -loglevel info -i `"$($f.FullName)`" $vArgs -c:a aac -b:a 128k -y `"$outFile`""
                    $logFile = Join-Path $env:TEMP "ffmpeg_comp.txt"

                    # Удаляем старый файл перед запуском, чтобы проверка была корректной
                    if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }

                    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $args -RedirectStandardError $logFile -PassThru -NoNewWindow
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()

                    # --- Анти-зависание: отслеживаем прогресс и время работы ---
                    $lastTime = -1.0; $lastLogSize = 0; $lastOutSize = 0; $lastProgressAt = $sw.Elapsed
                    $hung = $false
                    while (-not $proc.HasExited) {
                        $currentTime = 0
                        if (Test-Path $logFile) {
                            try {
                                $lastLines = Get-Content $logFile -Tail 5 -ErrorAction SilentlyContinue
                                foreach ($line in $lastLines) {
                                    if ($line -match 'time=(\d+):(\d+):(\d+(?:\.\d+)?)') {
                                        $currentTime = [int]$matches[1]*3600 + [int]$matches[2]*60 + [double]$matches[3]
                                    }
                                }
                            } catch {}
                        }

                        $percent = 0
                        if ($duration -gt 0) { $percent = [math]::Min(100, ($currentTime / $duration) * 100) }

                        $elapsed = $sw.Elapsed.ToString('hh\:mm\:ss')
                        $status = "$('Time'): $elapsed | $('Press L to write log')"
                        if ($duration -gt 0) { $status += " | $('Progress'): $([math]::Round($percent, 1))%" }

                        Write-Progress -Activity "$('Compressing'): $($f.Name)" -Status $status -PercentComplete $percent -Id 1

                        # Запоминаем текущий прогресс для записи лога по нажатию клавиши "L"
                        $script:LastProgressInfo.CurrentTime = $currentTime
                        $script:LastProgressInfo.Percent = $percent

                        # Лог по нажатию клавиши: [L] — записать текущее состояние процесса в корневой лог
                        if (Test-LoggingHotkey) {
                            $res = Write-ProgressLog -FileName $f.FullName -Stage "Compress" -Iteration $iteration `
                                -CurrentCRF $currentCRF -ElapsedSec $sw.Elapsed.TotalSeconds -LogFile $logFile `
                                -FileCount $files.Count -Index $i
                            if ($res.Success) {
                                Write-Host "`n  [LOG] $('State written to log'): $($res.LogFile)" -ForegroundColor Magenta
                            } else {
                                Write-Host "`n  [X] $('Failed to write log')" -ForegroundColor Red
                            }
                        }

                        # Признак жизни: рост time= в выводе ffmpeg или размера файла лога/результата
                        $logSize = 0
                        try { if (Test-Path $logFile) { $logSize = (Get-Item $logFile).Length } } catch {}
                        $outSize = 0
                        try { if (Test-Path $outFile) { $outSize = (Get-Item $outFile).Length } } catch {}

                        if ($currentTime -gt $lastTime -or $logSize -ne $lastLogSize -or $outSize -ne $lastOutSize) {
                            $lastTime = $currentTime; $lastLogSize = $logSize; $lastOutSize = $outSize
                            $lastProgressAt = $sw.Elapsed
                        } elseif ($sw.Elapsed.TotalSeconds -gt $script:MaxRuntimeSec) {
                            $hung = $true
                            Write-Host "`n  [!] $('Process hung detected: max runtime exceeded'). $('Stopping FFmpeg...')" -ForegroundColor Red
                            try { & taskkill /F /T /PID $proc.Id 2>$null | Out-Null; $proc.Kill() } catch {}
                            break
                        } elseif (($sw.Elapsed - $lastProgressAt).TotalSeconds -gt $script:NoProgressTimeoutSec) {
                            $hung = $true
                            Write-Host "`n  [!] $('Process hung detected: no progress for') $([int]$script:NoProgressTimeoutSec)$(' s'). $('Stopping FFmpeg...')" -ForegroundColor Red
                            try { & taskkill /F /T /PID $proc.Id 2>$null | Out-Null; $proc.Kill() } catch {}
                            break
                        }
                        Start-Sleep -Milliseconds 500
                    }
                    $sw.Stop()
                    Write-Progress -Activity "$('Compressing'): $($f.Name)" -Completed -Id 1

                    if ($hung) {
                        $savedLog = Save-FFmpegLogToRoot -SourceLog $logFile -Stage "hang" -SrcName $f.Name
                        Write-ErrorLog -Type "HANG" -FileName $f.FullName -Details (
                            "CRF: $currentCRF | Encoder: $script:hwDevice/$script:codec`n" +
                            "Elapsed: $($sw.Elapsed.ToString('hh\:mm\:ss'))`n" +
                            $(if ($savedLog) { "Full FFmpeg log saved to: $savedLog`n" } else { "" }) +
                            "Last FFmpeg output:`n" + (Get-FFmpegTail -Path $logFile)
                        )
                        Write-Host "  [X] $('Logged to'): $script:ErrorLogFile" -ForegroundColor DarkGray
                        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
                        break
                    }

                    # проверяем выходной файл, а не код завершения
                    $compressOK = (Test-Path $outFile) -and ((Get-Item $outFile -ErrorAction SilentlyContinue).Length -gt 0)
                    if (-not $compressOK) {
                        Write-Host "  [X] $('FFmpeg Error')" -ForegroundColor Red
                        $savedLog = Save-FFmpegLogToRoot -SourceLog $logFile -Stage "error" -SrcName $f.Name
                        Write-ErrorLog -Type "ERROR" -FileName $f.FullName -Details (
                            "Command: ffmpeg $args`n" +
                            "ExitCode: $(try { $proc.ExitCode } catch { 'n/a' })`n" +
                            $(if ($savedLog) { "Full FFmpeg log saved to: $savedLog`n" } else { "" }) +
                            "Last FFmpeg output:`n" + (Get-FFmpegTail -Path $logFile)
                        )
                        Write-Host "  [X] $('Logged to'): $script:ErrorLogFile" -ForegroundColor DarkGray
                        break
                    }

                    # Логика VMAF и AutoCRF
                    $needsRecompress = $false
                    if ($script:enableVMAF -and $iteration -le $script:maxIterations) {
                        Write-Host "  -> $('Calculating VMAF...')" -ForegroundColor White
                        $vmafArgs = "-hide_banner -loglevel info -i `"$($f.FullName)`" -i `"$outFile`" -lavfi `"[0:v]scale=1920:1080,fps=30[ref];[1:v]scale=1920:1080,fps=30[dist];[ref][dist]libvmaf`" -f null -"
                        $vmafLog = Join-Path $env:TEMP "vmaf_log.txt"

                        $vmafProc = Start-Process -FilePath "ffmpeg" -ArgumentList $vmafArgs -RedirectStandardError $vmafLog -PassThru -NoNewWindow
                        $vmafSw = [System.Diagnostics.Stopwatch]::StartNew()

                        # Анти-зависание для расчёта VMAF
                        $vmafLastTime = -1.0; $vmafLastLogSize = 0; $vmafLastProgressAt = $vmafSw.Elapsed
                        $vmafHung = $false
                        while (-not $vmafProc.HasExited) {
                            $vmafTime = 0
                            if (Test-Path $vmafLog) {
                                try {
                                    $vmafLastLines = Get-Content $vmafLog -Tail 5 -ErrorAction SilentlyContinue
                                    foreach ($line in $vmafLastLines) {
                                        if ($line -match 'time=(\d+):(\d+):(\d+(?:\.\d+)?)') {
                                            $vmafTime = [int]$matches[1]*3600 + [int]$matches[2]*60 + [double]$matches[3]
                                        }
                                    }
                                } catch {}
                            }
                            $vmafPercent = 0
                            if ($duration -gt 0) { $vmafPercent = [math]::Min(100, ($vmafTime / $duration) * 100) }
                            $vmafElapsed = $vmafSw.Elapsed.ToString('hh\:mm\:ss')
                            $vmafStatus = "$('Time'): $vmafElapsed | $('Progress'): $([math]::Round($vmafPercent, 1))% | $('Press L to write log')"
                            Write-Progress -Activity "$('Calculating VMAF'): $($f.Name)" -Status $vmafStatus -PercentComplete $vmafPercent -Id 2

                            # Запоминаем текущий прогресс для записи лога по нажатию клавиши "L"
                            $script:LastProgressInfo.CurrentTime = $vmafTime
                            $script:LastProgressInfo.Percent = $vmafPercent

                            # Лог по нажатию клавиши: [L] — записать текущее состояние процесса VMAF в корневой лог
                            if (Test-LoggingHotkey) {
                                $res = Write-ProgressLog -FileName $f.FullName -Stage "VMAF" -Iteration $iteration `
                                    -CurrentCRF $currentCRF -ElapsedSec $vmafSw.Elapsed.TotalSeconds -LogFile $vmafLog `
                                    -FileCount $files.Count -Index $i
                                if ($res.Success) {
                                    Write-Host "`n  [LOG] $('State written to log'): $($res.LogFile)" -ForegroundColor Magenta
                                } else {
                                    Write-Host "`n  [X] $('Failed to write log')" -ForegroundColor Red
                                }
                            }

                            $vmafLogSize = 0
                            try { if (Test-Path $vmafLog) { $vmafLogSize = (Get-Item $vmafLog).Length } } catch {}

                            if ($vmafTime -gt $vmafLastTime -or $vmafLogSize -ne $vmafLastLogSize) {
                                $vmafLastTime = $vmafTime; $vmafLastLogSize = $vmafLogSize
                                $vmafLastProgressAt = $vmafSw.Elapsed
                            } elseif (($vmafSw.Elapsed - $vmafLastProgressAt).TotalSeconds -gt $script:NoProgressTimeoutSec) {
                                $vmafHung = $true
                                Write-Host "`n  [!] $('VMAF process hung detected'). $('Stopping FFmpeg...')" -ForegroundColor Red
                                try { & taskkill /F /T /PID $vmafProc.Id 2>$null | Out-Null; $vmafProc.Kill() } catch {}
                                break
                            }
                            Start-Sleep -Milliseconds 500
                        }
                        $vmafSw.Stop()
                        Write-Progress -Activity "$('Calculating VMAF'): $($f.Name)" -Completed -Id 2

                        if ($vmafHung) {
                            $savedLog = Save-FFmpegLogToRoot -SourceLog $vmafLog -Stage "vmaf_hang" -SrcName $f.Name
                            Write-ErrorLog -Type "HANG" -FileName $f.FullName -Details (
                                "Stage: VMAF calculation`n" +
                                "CRF: $currentCRF | Encoder: $script:hwDevice/$script:codec`n" +
                                "Elapsed: $($vmafSw.Elapsed.ToString('hh\:mm\:ss'))`n" +
                                $(if ($savedLog) { "Full FFmpeg log saved to: $savedLog`n" } else { "" }) +
                                "Last FFmpeg output:`n" + (Get-FFmpegTail -Path $vmafLog)
                            )
                            Write-Host "  [X] $('Logged to'): $script:ErrorLogFile" -ForegroundColor DarkGray
                            Remove-Item $vmafLog -Force -ErrorAction SilentlyContinue
                            break
                        }

                        $vmafScore = 0
                        if (Test-Path $vmafLog) {
                            $logContent = Get-Content $vmafLog -Raw -ErrorAction SilentlyContinue
                            if ($logContent -match 'VMAF score:\s*([\d\.]+)') { $vmafScore = [math]::Round([double]$matches[1], 2) }
                            elseif ($logContent -match '"vmaf":\s*([\d\.]+)') { $vmafScore = [math]::Round([double]$matches[1], 2) }
                            else {
                                $savedLog = Save-FFmpegLogToRoot -SourceLog $vmafLog -Stage "vmaf_parse_error" -SrcName $f.Name
                                Write-ErrorLog -Type "ERROR" -FileName $f.FullName -Details (
                                    "Stage: VMAF score not found in output`n" +
                                    $(if ($savedLog) { "Full FFmpeg log saved to: $savedLog`n" } else { "" }) +
                                    "Last FFmpeg output:`n" + (Get-FFmpegTail -Path $vmafLog)
                                )
                                Write-Host "  [X] $('VMAF parse error, logged'): $script:ErrorLogFile" -ForegroundColor DarkGray
                            }
                            Remove-Item $vmafLog -Force -ErrorAction SilentlyContinue
                        }
                        Write-Host "  -> VMAF: $vmafScore" -ForegroundColor $(if ($vmafScore -ge $script:vmafThreshold) { "Green" } else { "Yellow" })

                        if ($script:enableAutoCRF -and $vmafScore -lt $script:vmafThreshold -and $currentCRF -gt $script:minCRF) {
                            $currentCRF -= 2
                            $needsRecompress = $true
                            Remove-Item $outFile -Force -ErrorAction SilentlyContinue
                            Write-Host "  -> $('AutoCRF: Retrying with CRF') $currentCRF" -ForegroundColor Cyan
                        }
                    }
                }

                if (Test-Path $outFile) { Write-Host "  [OK] $('Saved')" -ForegroundColor Green }
                $i++
            }
            } catch {
                # Любая непредвиденная ошибка во время процесса сжатия — в корневой лог
                Write-ErrorLog -Type "ERROR" -FileName $(if ($f) { $f.FullName } else { "(unknown)" }) -Details (
                    "Stage: Unexpected error during compression loop`n" +
                    "Message: $($_.Exception.Message)`n" +
                    "Line: $($_.InvocationInfo.ScriptLineNumber) | $($_.InvocationInfo.Line.Trim())"
                ) | Out-Null
                Write-Host "  [X] $('Unexpected error, logged to'): $script:ErrorLogFile" -ForegroundColor Red
            }
            Write-Host "`n  [OK] $('Done! Press Enter to return.')" -ForegroundColor Green
            Read-Host
            break MainLoop
        }
        '9' { break MainLoop }
    }
} while ($true)