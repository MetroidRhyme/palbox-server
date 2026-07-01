# PalWorld Server + PalBox Dashboard

A complete, self-hosted toolkit for running a **PalWorld dedicated server** on Windows, with:

- a **local web dashboard** ("the Manager") for live stats, player admin, server controls, a Save Manager, and a settings editor;
- Python **save readers** that parse the world save into JSON (every captured Pal, eggs, paldeck, effigies);
- a generated, read-only **public player site** ("PalBox") hosted free on **Cloudflare Pages + R2 + Access**, where each player signs in and sees only their own Pals, paldeck, eggs, and an interactive spawn/effigy map.

> This repo is the **authored tooling only**. It does **not** include the PalWorld game files, any save data, or any game art — you install the server with the included script and regenerate art/data with the included scrapers. See [docs/05-data-and-assets.md](docs/05-data-and-assets.md).

## Architecture

```
  PalWorld dedicated server  (Level.sav, player saves, settings .ini)
            |
            v
  Python readers  (pal_team_reader / pal_egg_reader / pal_save_reader / save_health)
            |
            v
  PalWorldServerManager.ps1   --- local dashboard  http://localhost:8213
            |                      (also proxies the server's REST API on :8212)
            |
            +--> gen_public_site.ps1  --> static "shell"  --> deploy_public_site.ps1 --> Cloudflare Pages
            |
            +--> build_public_data.ps1 --> sync_public_data.ps1 (per-player JSON) --> Cloudflare R2
                                                       |
  Player browser --> palbox.<your-domain>  (Cloudflare Access: email allowlist + PIN)
                       --> _worker.js verifies the Access JWT and serves ONLY that user's data
```

The public site costs **$0** (Cloudflare free tier). The Manager pushes fresh data to R2 every poll (~5 min) without redeploying the site.

## Prerequisites

- **Windows 10/11** (the dashboard runs under Windows PowerShell 5.1).
- **Python 3.9+** on PATH (for the save readers + scrapers).
- **Node.js + Wrangler** (`npm i -g wrangler`) — only for the public site.
- A **Cloudflare account** with a domain on Cloudflare — only for the public site.
- Disk space for the game server (SteamCMD pulls it).

## Quickstart

1. **Server:** put this repo's files in your server folder, then
   `& .\Install-PalWorldServer.ps1` (SteamCMD installs PalWorld here) -> [docs/01-server-setup.md](docs/01-server-setup.md).
   On a brand-new machine, run `Install-PalWorldServer.desktop-bootstrap.ps1` once first for the
   OS-level prerequisites (DirectX, VC++ 2022, firewall rules, power plan) -> [docs/01](docs/01-server-setup.md#first-time-machine-bootstrap-extra-one-off-setup).
2. **Configure** `Pal\Saved\Config\WindowsServer\PalWorldSettings.ini` (server name, passwords, rates) -> [docs/01](docs/01-server-setup.md).
3. **Launch:** `& .\Start-PalWorldServer.ps1`.
4. **Dashboard:** `& .\PalWorldServerManager.ps1` -> open http://localhost:8213 -> [docs/02-dashboard.md](docs/02-dashboard.md).
5. **(Optional) Public site:** copy `config.example.ps1` -> `config.ps1`, set Cloudflare env vars, and follow [docs/04-public-site.md](docs/04-public-site.md).

## Docs

| Guide | What it covers |
|---|---|
| [01 - Server setup](docs/01-server-setup.md) | SteamCMD install, `PalWorldSettings.ini`, launching, ports, gotchas |
| [02 - Dashboard](docs/02-dashboard.md) | Running the Manager, panels, Save Manager, REST API |
| [03 - Maintenance](docs/03-maintenance.md) | Auto-update loop, backups, save-health checks |
| [04 - Public site](docs/04-public-site.md) | Cloudflare Pages + R2 + Access, the Worker, deploy/sync |
| [05 - Data & assets](docs/05-data-and-assets.md) | Save readers, scrapers, regeneration order |

## Configuration / secrets

Nothing secret is committed. You supply:

- **Server name + passwords** in `PalWorldSettings.ini` (use the included `DefaultPalWorldSettings.ini` as a starting point). The scripts read the admin password from this file at runtime.
- **Cloudflare names** in `config.ps1` (copied from `config.example.ps1`, git-ignored).
- **Cloudflare API token + account id** as environment variables (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`) — never in a file.
- **Worker identity** (your admin email, the player email->GUID map, your Access team domain + AUD) directly in `site_src/_worker.js` (it ships with placeholders).

## Credits / third-party data

This project fetches data and art from third parties at your discretion (not redistributed here):

- Pal portraits: [tylercamp/palcalc](https://github.com/tylercamp/palcalc)
- Species / skills / passives / spawn / map tiles: [paldb.cc](https://paldb.cc)
- Effigy locations: [oMaN-Rod/palworld-save-pal](https://github.com/oMaN-Rod/palworld-save-pal)
- Passive frame art: [palworld.wiki.gg](https://palworld.wiki.gg)

PalWorld is a trademark of Pocketpair, Inc. This is an unofficial fan tool. See [LICENSE](LICENSE) (covers the authored scripts only).
