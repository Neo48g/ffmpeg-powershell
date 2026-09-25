#Requires -Version 5.1
# ============================================================================
# compress_video.ps1 — пакетное сжатие видео (CPU/GPU) с VMAF и Авто-CRF
# ============================================================================
[CmdletBinding()]
param(
    [string]$VideoFolder   # необязательный стартовый каталог (для запуска из .bat)
)

. (Join-Path $PSScriptRoot "common.ps1")

$PresetsFile = Join-Path $global:ScriptDir "presets.json"

# --- State Variables ---
$script:inputFolder = if ($VideoFolder -and (Test-Path $VideoFolder)) { $VideoFolder } else { $global:ScriptDir }
$script:crfValue = 23; $script:hwDevice = "CPU"; $script:codec = "h264"
$script:enableVMAF = $false; $script:enableAutoCRF = $false
$script:vmafThreshold = 90; $script:maxIterations = 3; $script:minCRF = 18
$script:enableRecursiveSearch = $false
$script:presets = @{}
$extensions = @(".mp4",".mkv",".avi",".mov",".m4v",".webm",".ts",".mts",".flv",".wmv")
$excludedFolders = @("compressed", "logs", "trimmed", "tools")

# --- Presets Management ---
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

function Show-PresetList {
    $keys = $script:presets.Keys | Sort-Object
    $i = 1
    foreach ($k in $keys) { Write-Host "  [$i] $k" -ForegroundColor White; $i++ }
    return $keys
}

function Show-PresetsMenu {
    do {
        Show-Banner (L "PRESETS MANAGEMENT" "УПРАВЛЕНИЕ ПРЕСЕТАМИ")
        Write-Host "  [1] $(L 'Save current settings' 'Сохранить текущие настройки')" -ForegroundColor White
        Write-Host "  [2] $(L 'Load preset' 'Загрузить пресет')" -ForegroundColor White
        Write-Host "  [3] $(L 'Delete preset' 'Удалить пресет')" -ForegroundColor White
        Write-Host "`n  [0] $(L 'Back' 'Назад')" -ForegroundColor Red

        $c = Read-Host (L "  Choice" "  Выбор")
        switch ($c) {
            '1' {
                $name = Read-Host (L "  Enter preset name" "  Введите имя пресета")
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $script:presets[$name] = @{
                    HwDevice=$script:hwDevice; Codec=$script:codec; CRF=$script:crfValue
                    EnableVMAF=$script:enableVMAF; EnableAutoCRF=$script:enableAutoCRF
                    VMAFThreshold=$script:vmafThreshold; MaxIterations=$script:maxIterations; MinCRF=$script:minCRF
                }
                Save-Presets
                Write-Host "`n  [OK] $(L 'Preset saved' 'Пресет сохранен')" -ForegroundColor Green
                Start-Sleep 1
            }
            '2' {
                if ($script:presets.Count -eq 0) { Write-Host "`n  [X] $(L 'No presets saved' 'Нет сохраненных пресетов')" -ForegroundColor Red; Start-Sleep 1; continue }
                $keys = @($script:presets.Keys | Sort-Object); $i = 1
                foreach ($k in $keys) { Write-Host "  [$i] $k ($($script:presets[$k].HwDevice) | $($script:presets[$k].Codec) | CRF:$($script:presets[$k].CRF))" -ForegroundColor White; $i++ }
                $idx = Read-Host (L "  Select number" "  Выберите номер")
                if ($idx -match '^\d+$' -and [int]$idx -ge 1 -and [int]$idx -le $keys.Count) {
                    $p = $script:presets[$keys[[int]$idx - 1]]
                    $script:hwDevice=$p.HwDevice; $script:codec=$p.Codec; $script:crfValue=[int]$p.CRF
                    $script:enableVMAF=[bool]$p.EnableVMAF; $script:enableAutoCRF=[bool]$p.EnableAutoCRF
                    $script:vmafThreshold=[int]$p.VMAFThreshold; $script:maxIterations=[int]$p.MaxIterations; $script:minCRF=[int]$p.MinCRF
                    Write-Host "`n  [OK] $(L 'Preset loaded' 'Пресет загружен')" -ForegroundColor Green
                    Start-Sleep 1
                }
            }
            '3' {
                if ($script:presets.Count -eq 0) { Write-Host "`n  [X] $(L 'No presets saved' 'Нет сохраненных пресетов')" -ForegroundColor Red; Start-Sleep 1; continue }
                $keys = @($script:presets.Keys | Sort-Object); $i = 1
                foreach ($k in $keys) { Write-Host "  [$i] $k" -ForegroundColor White; $i++ }
                $idx = Read-Host (L "  Select number to delete" "  Выберите номер для удаления")
                if ($idx -match '^\d+$' -and [int]$idx -ge 1 -and [int]$idx -le $keys.Count) {
                    $script:presets.Remove($keys[[int]$idx - 1]); Save-Presets
                    Write-Host "`n  [OK] $(L 'Preset deleted' 'Пресет удален')" -ForegroundColor Green
                    Start-Sleep 1
                }
            }
            '0' { return }
        }
    } while ($true)
}

# --- Core Settings Helpers ---
function Get-VideoFiles {
    Get-ChildItem -Path $script:inputFolder -File -Recurse:$script:enableRecursiveSearch -ErrorAction SilentlyContinue | Where-Object {
        $isVideo = $extensions -contains $_.Extension.ToLower()
        $isAllowed = $true
        if ($isVideo) { foreach ($part in $_.DirectoryName.Split('\','/')) { if ($excludedFolders -contains $part.ToLower()) { $isAllowed = $false; break } } }
        return ($isVideo -and $isAllowed)
    }
}

function Build-FFmpegVideoArgs {
    param([int]$Quality)
    if ($script:hwDevice -eq "CPU") {
        $enc = switch ($script:codec) { "h264" {"libx264"} "h265" {"libx265"} "av1" {"libsvtav1"} default {"libx264"} }
        return "-c:v $enc -crf $Quality -preset medium"
    }
    $enc = switch ($script:hwDevice) {
        "NVIDIA" { switch ($script:codec) { "h264" {"h264_nvenc"} "h265" {"hevc_nvenc"} "av1" {"av1_nvenc"} } }
        "AMD"    { switch ($script:codec) { "h264" {"h264_amf"}  "h265" {"hevc_amf"}  "av1" {"av1_amf"} } }
        "Intel"  { switch ($script:codec) { "h264" {"h264_qsv"}  "h265" {"hevc_qsv"}  "av1" {"av1_qsv"} } }
    }
    return "-c:v $enc -cq $Quality -preset p4"
}

function Get-MediaDuration {
    param([string]$FilePath)
    try {
        $durStr = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FilePath" 2>$null
        if ($durStr) { return [double]$durStr }
    } catch {}
    return 0
}

# Прогресс-бар на основе time= в stderr-логе ffmpeg
function Wait-FFmpegProgress {
    param($Process, [string]$LogFile, [double]$Duration, [string]$Activity, [int]$BarId = 1)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Process.HasExited) {
        $currentTime = 0
        if (Test-Path $LogFile) {
            try {
                foreach ($line in (Get-Content $LogFile -Tail 5 -ErrorAction SilentlyContinue)) {
                    if ($line -match 'time=(\d+):(\d+):(\d+(?:\.\d+)?)') {
                        $currentTime = [int]$matches[1]*3600 + [int]$matches[2]*60 + [double]$matches[3]
                    }
                }
            } catch {}
        }
        $status = "$(L 'Time' 'Время'): $($sw.Elapsed.ToString('hh\:mm\:ss'))"
        $percent = 0
        if ($Duration -gt 0) {
            $percent = [math]::Min(100, ($currentTime / $Duration) * 100)
            $status += " | $(L 'Progress' 'Прогресс'): $([math]::Round($percent, 1))%"
        }
        Write-Progress -Activity $Activity -Status $status -PercentComplete $percent -Id $BarId
        Start-Sleep -Milliseconds 500
    }
    $sw.Stop()
    Write-Progress -Activity $Activity -Completed -Id $BarId
}

function Measure-VMAF {
    param([string]$RefFile, [string]$DistFile, [double]$Duration, [string]$FileName)
    $vmafArgs = "-hide_banner -loglevel info -i `"$RefFile`" -i `"$DistFile`" -lavfi `"[0:v]scale=1920:1080,fps=30[ref];[1:v]scale=1920:1080,fps=30[dist];[ref][dist]libvmaf`" -f null -"
    $vmafLog = Join-Path $env:TEMP "vmaf_log.txt"
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $vmafArgs -RedirectStandardError $vmafLog -PassThru -NoNewWindow
    Wait-FFmpegProgress -Process $proc -LogFile $vmafLog -Duration $Duration -Activity "$(L 'Calculating VMAF' 'Расчет VMAF'): $FileName" -BarId 2
    $score = 0
    if (Test-Path $vmafLog) {
        $logContent = Get-Content $vmafLog -Raw -ErrorAction SilentlyContinue
        if     ($logContent -match 'VMAF score:\s*([\d\.]+)')   { $score = [math]::Round([double]$matches[1], 2) }
        elseif ($logContent -match '"vmaf":\s*([\d\.]+)')       { $score = [math]::Round([double]$matches[1], 2) }
        Remove-Item $vmafLog -Force -ErrorAction SilentlyContinue
    }
    return $score
}

# --- Main Menu Loop ---
Load-Presets
:MainLoop do {
    Show-Banner (L "VIDEO COMPRESSION" "СЖАТИЕ ВИДЕО")
    $files = @(Get-VideoFiles)
    Write-Host "  $(L 'Folder' 'Папка'): $script:inputFolder" -ForegroundColor Gray
    Write-Host "  $(L 'Files' 'Файлы'): $($files.Count) | $(L 'HW' 'Железо'): $script:hwDevice | $(L 'Codec' 'Кодек'): $script:codec | $(L 'CRF' 'CRF'): $script:crfValue" -ForegroundColor White
    Write-Host "  $(L 'VMAF' 'VMAF'): $(if($script:enableVMAF){'ON'}else{'OFF'}) | $(L 'AutoCRF' 'АвтоCRF'): $(if($script:enableAutoCRF){'ON'}else{'OFF'}) | $(L 'Presets' 'Пресеты'): $($script:presets.Count)" -ForegroundColor White
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [1] $(L 'Change Folder' 'Изменить папку')" -ForegroundColor White
    Write-Host "  [2] $(L 'Hardware & Codec' 'Железо и Кодек')" -ForegroundColor White
    Write-Host "  [3] $(L 'Quality & VMAF' 'Качество и VMAF')" -ForegroundColor White
    Write-Host "  [4] $(L 'Presets Management' 'Управление пресетами')" -ForegroundColor White
    Write-Host "  [5] $(L 'Toggle Recursive' 'Рекурсивный поиск'): $(if($script:enableRecursiveSearch){'ON'}else{'OFF'})" -ForegroundColor White
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [0] $(L 'START COMPRESSION' 'НАЧАТЬ СЖАТИЕ')" -ForegroundColor Green
    Write-Host "  [9] $(L 'Back to Hub' 'Вернуться в Хаб')" -ForegroundColor Red

    $c = Read-Host (L "  Choice" "  Выбор")
    switch ($c) {
        '1' {
            Add-Type -AssemblyName System.Windows.Forms
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($d.ShowDialog() -eq 'OK') { $script:inputFolder = $d.SelectedPath }
        }
        '2' {
            Show-Banner (L "HARDWARE & CODEC" "ЖЕЛЕЗО И КОДЕК")
            Write-Host "  [1] CPU  [2] NVIDIA  [3] AMD  [4] Intel" -ForegroundColor White
            $hwC = Read-Host (L "  Select HW" "  Выберите железо")
            $script:hwDevice = switch ($hwC) { '1' {'CPU'} '2' {'NVIDIA'} '3' {'AMD'} '4' {'Intel'} default {'CPU'} }
            Write-Host "  [1] H.264  [2] H.265  [3] AV1" -ForegroundColor White
            $cC = Read-Host (L "  Select Codec" "  Выберите кодек")
            $script:codec = switch ($cC) { '1' {'h264'} '2' {'h265'} '3' {'av1'} default {'h264'} }
        }
        '3' {
            Show-Banner (L "QUALITY & VMAF" "КАЧЕСТВО И VMAF")
            $v = Read-Host (L "  CRF (0-51) [$script:crfValue]" "  CRF (0-51) [$script:crfValue]")
            if ($v -match '^\d+$') { $script:crfValue = [int]$v }
            $script:enableVMAF = (Read-Host (L "  Enable VMAF? (Y/N)" "  Включить VMAF? (Y/N)")) -match '^[Yy]'
            if ($script:enableVMAF) {
                $script:enableAutoCRF = (Read-Host (L "  Enable AutoCRF? (Y/N)" "  Включить АвтоCRF? (Y/N)")) -match '^[Yy]'
                if ($script:enableAutoCRF) {
                    $t = Read-Host (L "  VMAF Threshold (0-100) [$script:vmafThreshold]" "  Порог VMAF (0-100) [$script:vmafThreshold]")
                    if ($t -match '^\d+$') { $script:vmafThreshold = [int]$t }
                }
            }
        }
        '4' { Show-PresetsMenu }
        '5' { $script:enableRecursiveSearch = -not $script:enableRecursiveSearch }
        '0' {
            if ($files.Count -eq 0) { Write-Host "`n  [X] $(L 'No files found' 'Файлы не найдены')" -ForegroundColor Red; Start-Sleep 2; continue }
            $outDir = Join-Path $script:inputFolder "compressed"
            if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

            $i = 1
            foreach ($f in $files) {
                $outFile = Join-Path $outDir "$($f.BaseName)_compressed.mp4"
                Write-Host "`n  [$i/$($files.Count)] $($f.Name)" -ForegroundColor Yellow

                $duration = Get-MediaDuration -FilePath $f.FullName

                $currentCRF = $script:crfValue; $iteration = 0; $needsRecompress = $true
                while ($needsRecompress) {
                    $iteration++
                    $vArgs = Build-FFmpegVideoArgs -Quality $currentCRF
                    $args = "-hide_banner -loglevel info -i `"$($f.FullName)`" $vArgs -c:a aac -b:a 128k -y `"$outFile`""
                    $logFile = Join-Path $env:TEMP "ffmpeg_comp.txt"

                    if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }

                    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $args -RedirectStandardError $logFile -PassThru -NoNewWindow
                    Wait-FFmpegProgress -Process $proc -LogFile $logFile -Duration $duration -Activity "$(L 'Compressing' 'Сжатие'): $($f.Name)" -BarId 1

                    # Проверяем результат по файлу, а не по ExitCode
                    $compressOK = (Test-Path $outFile) -and ((Get-Item $outFile -ErrorAction SilentlyContinue).Length -gt 0)
                    if (-not $compressOK) {
                        Write-Host "  [X] $(L 'FFmpeg Error' 'Ошибка FFmpeg')" -ForegroundColor Red
                        break
                    }

                    # VMAF & AutoCRF Logic
                    $needsRecompress = $false
                    if ($script:enableVMAF -and $iteration -le $script:maxIterations) {
                        Write-Host "  -> $(L 'Calculating VMAF...' 'Расчет VMAF...')" -ForegroundColor White
                        $vmafScore = Measure-VMAF -RefFile $f.FullName -DistFile $outFile -Duration $duration -FileName $f.Name
                        Write-Host "  -> VMAF: $vmafScore" -ForegroundColor $(if ($vmafScore -ge $script:vmafThreshold) { "Green" } else { "Yellow" })

                        if ($script:enableAutoCRF -and $vmafScore -lt $script:vmafThreshold -and $currentCRF -gt $script:minCRF) {
                            $currentCRF -= 2
                            $needsRecompress = $true
                            Remove-Item $outFile -Force -ErrorAction SilentlyContinue
                            Write-Host "  -> $(L 'AutoCRF: Retrying with CRF' 'АвтоCRF: Повтор с CRF') $currentCRF" -ForegroundColor Cyan
                        }
                    }
                }

                if (Test-Path $outFile) { Write-Host "  [OK] $(L 'Saved' 'Сохранено')" -ForegroundColor Green }
                $i++
            }
            Wait-Enter (L 'Done! Press Enter to return.' 'Готово! Нажмите Enter.')
            break MainLoop
        }
        '9' { break MainLoop }
    }
} while ($true)
