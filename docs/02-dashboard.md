# 02 - The Manager dashboard

`PalWorldServerManager.ps1` is the primary management UI. Launch it in its own window and
keep it open:

```powershell
& .\PalWorldServerManager.ps1
```

It serves **http://localhost:8213** and runs two background jobs: the dashboard HTTP listener
and a built-in maintenance loop. It also talks to the server's REST API on `:8212` for live
control (using the `AdminPassword` it reads from your `PalWorldSettings.ini`).

## Panels

- **Live stats** -- FPS/frame time, players online, uptime, base count, in-game day.
- **Players** -- who's online, with kick / ban.
- **Server Controls** -- broadcast a message, force-save, graceful **Reboot** / **Shutdown**
  (graduated in-game countdown, save, then relaunch or stay offline), and **Force Stop**.
- **Charts** -- 24h players/FPS history; per-player playtime.
- **Save Manager** -- a library of named world + settings copies; one-click switch/backup/restore
  (see below).
- **Server Settings** -- an editor for `PalWorldSettings.ini` that handles the single-line
  `OptionSettings=(...)` format for you, with an "Editing:" dropdown to edit the live world or
  any saved slot.
- **Pals / Paldeck / Eggs / Effigy + Spawn maps** -- the same player-facing views the public
  site is generated from (powered by the Python readers + the curated data tables).

## Save Manager

The server loads whichever world `DedicatedServerName` (in `GameUserSettings.ini`) points at.
The Save Manager automates this safely:

- **Loading a save copies** (never moves) it from the library into `Pal\Saved\SaveGames\0`, so
  reverts are always possible.
- **Every switch first auto-snapshots** the current live world + its settings (tagged as a
  backup) so in-progress play is never lost.
- **Settings are tied to each save** -- each slot keeps its own `PalWorldSettings.ini`, applied
  to the live config when that save is loaded.
- **New World** creates a fresh random GUID; the server generates an empty world on next start.

## REST API (server, port 8212)

The dashboard proxies these; you can also call them directly. Auth is HTTP Basic
`admin:<AdminPassword>`:

```powershell
$pw   = (Get-Content "Pal\Saved\Config\WindowsServer\PalWorldSettings.ini" -Raw) -replace '(?s).*AdminPassword="([^"]*)".*','$1'
$cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$pw"))
$h    = @{ Authorization = "Basic $cred"; "Content-Type" = "application/json" }
$base = "http://localhost:8212/v1/api"

Invoke-RestMethod "$base/info"    -Headers $h
Invoke-RestMethod "$base/metrics" -Headers $h
Invoke-RestMethod "$base/players" -Headers $h
Invoke-RestMethod "$base/announce" -Method POST -Headers $h -Body (ConvertTo-Json @{ message = "Hi" })
```

Endpoints: `info`, `settings`, `metrics`, `players`, `announce`, `kick`, `ban`, `unban`, `save`,
`shutdown`, `stop`.

## Editing the dashboard (if you customize it)

The dashboard HTML/JS is a single-quoted PowerShell here-string (`$HtmlPage`) served as bytes.

- **The Manager runs under Windows PowerShell 5.1** -- route/server code must avoid PS7-only
  syntax (no ternary `? :`, no `??`/`?.`; use if/else).
- **Keep served strings pure ASCII.** A raw non-ASCII char in a served string gets mangled
  (the file is read as ANSI). Use HTML entities (`&mdash;`, `&bull;`) in markup and `\uXXXX`
  in JS strings.
- **Dashboard HTML changes only take effect after a Manager restart** (the HTML is an in-memory
  here-string).
- Syntax-check after editing:
  ```powershell
  $e=$null;[System.Management.Automation.Language.Parser]::ParseFile("PalWorldServerManager.ps1",[ref]$null,[ref]$e)|Out-Null;if($e){$e}else{"OK"}
  ```

If you also run the public site, see [04](04-public-site.md) -- the generator extracts and
transforms this dashboard's HTML, so some edits require regenerating + redeploying the site.
