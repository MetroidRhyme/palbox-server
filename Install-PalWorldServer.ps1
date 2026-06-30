# Install-PalWorldServer.ps1
# Installs / updates the PalWorld dedicated server into THIS folder via SteamCMD.
# Run once to install; the maintenance loop re-runs it to apply game updates.
# (PalWorld Dedicated Server = Steam app 2394010, anonymous login.)
$ErrorActionPreference = 'Stop'
$ServerDir = $PSScriptRoot
$SteamDir  = Join-Path $ServerDir 'steamcmd'
$SteamCmd  = Join-Path $SteamDir 'steamcmd.exe'

if (-not (Test-Path $SteamCmd)) {
  Write-Host "[install] downloading SteamCMD..."
  New-Item -ItemType Directory -Force -Path $SteamDir | Out-Null
  $zip = Join-Path $env:TEMP 'steamcmd.zip'
  Invoke-WebRequest 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip
  Expand-Archive $zip $SteamDir -Force
  Remove-Item $zip -Force
}

Write-Host "[install] installing/updating PalWorld dedicated server into $ServerDir ..."
& $SteamCmd +force_install_dir $ServerDir +login anonymous +app_update 2394010 validate +quit
Write-Host "[install] done."
