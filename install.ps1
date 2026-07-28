# Installiert PalHatcheryLive in die UE4SS-Mods des lokalen Palworld-Builds.
# Aufruf:  powershell -ExecutionPolicy Bypass -File .\install.ps1
param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"

$modsDir = Join-Path $GameDir "Pal\Binaries\Win64\ue4ss\Mods"
if (-not (Test-Path $modsDir)) {
    throw "UE4SS-Mods-Ordner nicht gefunden: $modsDir"
}

$src = Join-Path $PSScriptRoot "Mods\PalHatcheryLive"
$dst = Join-Path $modsDir "PalHatcheryLive"

New-Item -ItemType Directory -Force -Path (Join-Path $dst "Scripts") | Out-Null
Copy-Item (Join-Path $src "Scripts\main.lua") (Join-Path $dst "Scripts\main.lua") -Force
if (-not (Test-Path (Join-Path $dst "enabled.txt"))) {
    New-Item -ItemType File -Path (Join-Path $dst "enabled.txt") | Out-Null
}

Write-Host "PalHatcheryLive installiert nach $dst"
