# 03 - Maintenance & backups

## Built-in maintenance (in the dashboard)

The Manager has a **built-in maintenance job** (configurable time, default 4:00 AM, with a
"Skip Next" toggle). It broadcasts a warning, stops the server, runs
`Install-PalWorldServer.ps1` to apply any game update, and relaunches. Use this **or** the
standalone loop below -- not both at once.

## Standalone maintenance loop

`Maintenance-PalWorldServer.ps1` is an older, standalone alternative. Run it in its own window:

```powershell
& .\Maintenance-PalWorldServer.ps1
```

Each 24h cycle it broadcasts shutdown warnings, stops the server, updates it via
`Install-PalWorldServer.ps1`, and relaunches with `Start-PalWorldServer.ps1`. It reads the
admin password from your `PalWorldSettings.ini` and points `$InstallScript` at
`Install-PalWorldServer.ps1` in this folder.

## Backups + save health

Before each update (server stopped), the maintenance loop:

- snapshots the live world into `SaveLibrary\Auto-backup_<stamp>\` (matching the Save Manager
  layout) and prunes to the newest N backups;
- logs a **save-health** line via `save_health.py` (read-only: `Level.sav` on-disk / decompressed
  size, egg dynamic-item count, largest `_dps.sav`) with advisory threshold warnings.

```powershell
python .\save_health.py <path-to-world-save-folder>
```

> **No automated save *editing* / cleanup.** A full parse of the current save format fails in
> the community save tools, so orphan removal can't be safely automated. The save is small on
> disk anyway. Do any cleanup manually, verified, offline, against a backup.

## One-time REST API note

The REST API change (`RESTAPIEnabled=True` + `AdminPassword`) needs **one manual server restart**
to take effect before broadcasts/controls work.
