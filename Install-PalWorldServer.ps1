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
& $SteamCmd +force_install_dir $ServerDir +login anonymous +app_info_update 1 +app_update 2394010 validate +quit

# steamcmd ignores -force_install_dir once an app is already registered in its own
# internal library (C:\PalWorldServer\steamcmd\steamapps) and updates THAT copy
# instead - confirmed 2026-07-09: every update since 2026-07-04 silently landed in
# steamcmd\steamapps\common\PalServer while the live server here stayed on the
# May-28 build. Mirror the real depot output into $ServerDir ourselves so this
# can't go stale again, excluding Saved (never part of the depot; holds live saves).
$nestedInstall = Join-Path $SteamDir 'steamapps\common\PalServer'
if (Test-Path $nestedInstall) {
    Write-Host "[install] syncing updated files from steamcmd's internal library into $ServerDir ..."
    robocopy $nestedInstall $ServerDir /E /XD "Saved" /NJH /NDL /NP | Out-Null
    $nestedAcf = Join-Path $SteamDir 'steamapps\appmanifest_2394010.acf'
    $topAcf    = Join-Path $ServerDir 'steamapps\appmanifest_2394010.acf'
    if ((Test-Path $nestedAcf) -and (Test-Path (Split-Path $topAcf))) { Copy-Item $nestedAcf $topAcf -Force }
}
Write-Host "[install] done."
