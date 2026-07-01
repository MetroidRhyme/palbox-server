# 01 - Server setup

## Install

Put this repo's files in the folder you want the server to live in (e.g. `C:\PalWorldServer`).
All scripts locate themselves with `$PSScriptRoot`, so there are **no hardcoded paths** to edit.

```powershell
& .\Install-PalWorldServer.ps1
```

This downloads SteamCMD into `steamcmd\` and installs the **PalWorld Dedicated Server** (Steam
app `2394010`, anonymous login) into this folder. Re-running it applies game updates.

### First-time machine bootstrap (extra one-off setup)

`Install-PalWorldServer.ps1` above only handles SteamCMD + the game files. When standing up a
**brand-new machine**, a few one-time OS-level prerequisites are also needed. These are captured
in the archived **`Install-PalWorldServer.desktop-bootstrap.ps1`** (the original script that first
provisioned this box), which additionally:

- installs the **DirectX End-User Runtime** (`d3dx9_43.dll`);
- installs the **Visual C++ 2022 x64 redistributable** (required by Unreal Engine 5);
- creates the inbound **Windows Firewall** rules (`8211/UDP` game, `27015/UDP` Steam query);
- sets the active **power plan** to High Performance.

Run it once on a fresh machine (it is idempotent -- each step checks and skips if already done).
After that, the plain `Install-PalWorldServer.ps1` is all you need for game updates. The archived
script uses hardcoded paths (`C:\SteamCMD`, `C:\PalWorldServer`) rather than `$PSScriptRoot`, so
adjust those if your install lives elsewhere.

## Configure

Gameplay settings live in **one file**:

```
Pal\Saved\Config\WindowsServer\PalWorldSettings.ini
```

Start from the included `DefaultPalWorldSettings.ini` (copy it to the path above) and edit it.

> **Format gotcha:** the entire config is a **single line** -- one big
> `OptionSettings=(Key1=Value1,Key2=Value2,...)` tuple. There is no one-setting-per-line
> format. Edit it with the dashboard's Settings panel, or with a careful regex replace, e.g.:
> ```powershell
> $f = "Pal\Saved\Config\WindowsServer\PalWorldSettings.ini"
> $c = Get-Content $f -Raw
> $c = $c -replace '(?<=ServerName=")[^"]*(?=")', 'My Server'       # quoted string value
> $c = $c -replace '(?<=ExpRate=)[^,)]+', '2.000000'               # numeric value
> Set-Content $f $c -NoNewline                                      # ALWAYS -NoNewline
> ```

Key settings to set first: `ServerName`, `ServerPassword`, `AdminPassword`, `ServerPlayerMaxNum`,
`PublicPort` (default 8211), `RESTAPIEnabled=True` + `RESTAPIPort=8212` (the dashboard uses this),
and your gameplay multipliers (`ExpRate`, `PalCaptureRate`, `PalSpawnNumRate`, ...).

The scripts read `AdminPassword` **from this file at runtime** -- you never put it in a script.

## Launch

```powershell
& .\Start-PalWorldServer.ps1
```

The launch script includes `-publiclobby` (required for PS5/Xbox visibility in the Community
Servers browser). Settings changes require a **server restart** to take effect.

## Ports / firewall

| Port | Purpose |
|---|---|
| `8211/UDP` | Game traffic (PublicPort) -- forward this on your router |
| `8212/TCP` | REST API (localhost only; the dashboard uses it) |
| `8213/TCP` | The Manager dashboard (localhost only) |

## Gotchas

- **The server rewrites `PalWorldSettings.ini` on shutdown** with its in-memory (startup)
  values. So editing the file while the server is running, then restarting, loses the edit.
  The dashboard's Reboot/Shutdown routes handle this for you (they re-apply settings after the
  process exits). If you hand-edit, **stop the server first**.
- **Which world loads** is set by `DedicatedServerName` in
  `Pal\Saved\Config\WindowsServer\GameUserSettings.ini` (a normal per-line INI; write UTF-8
  **without BOM**). Multiple worlds can coexist under `Pal\Saved\SaveGames\0\<GUID>\`; the
  dashboard's **Save Manager** automates switching/backing up (see [02](02-dashboard.md)).
- **The server also rewrites `GameUserSettings.ini` on shutdown** -- only edit
  `DedicatedServerName` while stopped.

## Stopping

```powershell
Stop-Process -Name "PalServer-Win64-Test-Cmd" -Force
```

Or use the dashboard's Server Controls (graceful reboot / shutdown with an in-game countdown).
