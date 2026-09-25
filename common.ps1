#Requires -Version 5.1
# ============================================================================
# common.ps1 — общий модуль проекта FFmpeg Tools Hub
# Содержит: загрузку/сохранение конфигурации, локализацию (EN/RU),
#           UI-хелперы, управление PATH и поиск инструментов в ./tools.
# Использование:  . (Join-Path $PSScriptRoot 'common.ps1')
# ============================================================================

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Пути проекта ---
if (-not $global:ScriptDir) {
    $global:ScriptDir = $PSScriptRoot
    if (-not $global:ScriptDir) { $global:ScriptDir = (Get-Location).Path }
}
$global:ConfigFile = Join-Path $global:ScriptDir "global_config.json"
$global:ToolsDir   = Join-Path $global:ScriptDir "tools"

# --- Конфигурация ---
function Get-Config {
    if (Test-Path $global:ConfigFile) {
        try { return Get-Content $global:ConfigFile -Raw | ConvertFrom-Json } catch {}
    }
    $def = [pscustomobject]@{
        Language   = "EN"
        EnableLogs = $true
        LogsFolder = (Join-Path $global:ScriptDir "logs")
    }
    Save-Config $def
    return $def
}

function Save-Config {
    param($Cfg)
    $Cfg | ConvertTo-Json | Out-File $global:ConfigFile -Encoding UTF8 -Force
}

if (-not $global:Cfg) { $global:Cfg = Get-Config }

# --- Локализация: L "English" "Русский" ---
function L {
    param([string]$en, [string]$ru)
    if ($global:Cfg.Language -eq 'RU') { return $ru }
    return $en
}

# --- UI-хелперы ---
function Show-Banner {
    param([string]$Title)
    Clear-Host
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "========================================================`n" -ForegroundColor Cyan
}

function Wait-Enter {
    param([string]$Message)
    if (-not $Message) { $Message = L "Press Enter to continue..." "Нажмите Enter для продолжения..." }
    Write-Host "`n  $Message" -ForegroundColor Gray
    Read-Host | Out-Null
}

# --- Управление локальным PATH (папка tools) ---
function Update-LocalPath {
    if (-not (Test-Path $global:ToolsDir)) { New-Item -ItemType Directory -Path $global:ToolsDir -Force | Out-Null }
    $ffmpegBin = Join-Path $global:ToolsDir "ffmpeg\bin"
    if ((Test-Path $ffmpegBin) -and ($env:Path -notlike "*$ffmpegBin*")) { $env:Path = "$ffmpegBin;$env:Path" }
    if ((Test-Path (Join-Path $global:ToolsDir "yt-dlp.exe")) -and ($env:Path -notlike "*$($global:ToolsDir)*")) { $env:Path = "$($global:ToolsDir);$env:Path" }
    $nodeBin = Join-Path $global:ToolsDir "node"
    if ((Test-Path $nodeBin) -and ($env:Path -notlike "*$nodeBin*")) { $env:Path = "$nodeBin;$env:Path" }
}

# Поиск инструмента: сначала локально в tools\, затем в системном PATH
function Get-ToolPath {
    param([string]$ToolName)
    $localPath = Join-Path $global:ToolsDir "$ToolName.exe"
    if (Test-Path $localPath) { return $localPath }
    try { return (Get-Command $ToolName -ErrorAction Stop).Source } catch { return $null }
}

function Test-Tool {
    param([string]$ToolName)
    return [bool](Get-ToolPath $ToolName)
}

Update-LocalPath
