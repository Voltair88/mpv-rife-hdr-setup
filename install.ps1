<#
.SYNOPSIS
  Deploy this RIFE + HDR mpv config into an existing mpv-enhanced install.

.DESCRIPTION
  Copies this repo's portable_config/ into your mpv install folder (the one containing mpv.exe),
  backing up any existing portable_config first. It does NOT install mpv / VapourSynth / vsrife /
  TensorRT -- get those from F0903/mpv-enhanced first (see README "How it fits together").

.PARAMETER Target
  Path to your mpv install folder (contains mpv.exe). Auto-detected / prompted if omitted.

.EXAMPLE
  # from the repo root, in an elevated PowerShell if mpv lives under Program Files:
  ./install.ps1
  ./install.ps1 -Target "C:\Program Files\mpv-enhanced-installer\mpv-enhanced-installer"
#>
[CmdletBinding()]
param([string]$Target)

$ErrorActionPreference = 'Stop'

$repoConfig = Join-Path $PSScriptRoot 'portable_config'
if (-not (Test-Path $repoConfig)) { throw "portable_config not found next to install.ps1 ($repoConfig)" }

# --- locate the target mpv install -------------------------------------------------------------
if (-not $Target) {
    $candidates = @(
        "$env:ProgramFiles\mpv-enhanced-installer\mpv-enhanced-installer",
        "${env:ProgramFiles(x86)}\mpv-enhanced-installer\mpv-enhanced-installer",
        "$env:LOCALAPPDATA\mpv-enhanced-installer\mpv-enhanced-installer"
    ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'mpv.exe')) }
    if ($candidates) { $Target = $candidates[0]; Write-Host "Detected mpv install: $Target" -ForegroundColor Green }
    else { $Target = (Read-Host "Path to your mpv install folder (the one containing mpv.exe)").Trim('"') }
}
if (-not (Test-Path (Join-Path $Target 'mpv.exe'))) {
    throw "mpv.exe not found in '$Target'. Point -Target at your mpv-enhanced install folder."
}

$dest = Join-Path $Target 'portable_config'

# --- back up an existing config --------------------------------------------------------------
if (Test-Path $dest) {
    $bakLeaf = "portable_config.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Host "Backing up existing config -> $bakLeaf" -ForegroundColor Yellow
    Rename-Item -LiteralPath $dest -NewName $bakLeaf
}

# --- copy ------------------------------------------------------------------------------------
Write-Host "Installing config -> $dest"
Copy-Item -LiteralPath $repoConfig -Destination $dest -Recurse -Force
Write-Host "Config installed." -ForegroundColor Green

# --- post-install checklist ------------------------------------------------------------------
@"

================ Post-install checklist ================
Core (RIFE + HDR + info card):
  * First RIFE playback at a new resolution builds a TensorRT engine (slow once, then cached).
    Pre-build: VSPipe.exe -o 0 -e 0 portable_config\prebuild_engine.vpy .
  * Tune HDR/display in portable_config\mpv.conf (target-peak) and rife_config.py for your GPU/panel.
  * TMDb info card: put a free TMDb v3 API key in script-opts\tmdb-info.conf  (api_key=)

Optional (each independent; disable in its script-opts\*.conf):
  * Subtitles: works on uosc's shared key; for your own quota add an opensubtitles.com API key in
    scripts\uosc\main.lua (open_subtitles_api_key). Languages in uosc.conf (languages=).
  * Virtual surround: download a SOFA HRTF (e.g. SADIE II KU100 'HRIR') to a SPACE-FREE path and set
    script-opts\spatial.conf  sofa=  (off by default; toggle Ctrl+Shift+V).
  * Auto audio-delay: only if you route mpv through Voicemeeter. Calibrate with Ctrl+/- then
    Ctrl+Shift+S, or set enabled=no in script-opts\voicemeeter-sync.conf.

Keys: Ctrl+Shift+R RIFE | Ctrl+i card | Ctrl+t tools | Ctrl+Shift+D subs | Ctrl+Shift+V surround
========================================================
"@ | Write-Host
