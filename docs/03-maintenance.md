# 03 - Maintenance & backups

## Built-in maintenance (in the dashboard)

The Manager has a **built-in maintenance job** (configurable time, default 4:00 AM, with a
"Skip Next" toggle). It broadcasts a warning, stops the server (saving the world first),
**backs up the live world and runs a save-health check**, runs `Install-PalWorldServer.ps1`
to apply any game update, and relaunches. This is the maintenance path in normal use -- the
standalone script below is legacy and not needed alongside it.

## Standalone maintenance loop (legacy)

`Maintenance-PalWorldServer.ps1` is an older, standalone alternative kept for reference. It
duplicates the same daily cycle (shutdown warnings, stop, update via
`Install-PalWorldServer.ps1`, relaunch via `Start-PalWorldServer.ps1`) plus its own copy of
the backup/health logic below. **Do not run it alongside the built-in job** -- both would
back up and update the world independently. Since the built-in job now does everything this
script does, there's normally no reason to run it.

## Backups + save health

Before each update (server stopped), the maintenance job:

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

## Off-machine backup

`SaveLibrary\` is git-ignored and lives on one disk, so local auto-backups alone don't survive
a disk failure. About once every 7 days (gated on a timestamp in
`.palbox_offmachine_backup_state.json`, not a fixed weekday, so a down day doesn't skip a
cycle entirely), the maintenance job zips `SaveLibrary\` -- which by that point already holds
a fresh `Backup-LiveWorld` snapshot -- and uploads it to the same R2 bucket the public site
uses, under `backups/offmachine-backup-<date>.zip`. Needs `CLOUDFLARE_API_TOKEN` +
`CLOUDFLARE_ACCOUNT_ID` in the environment (same credentials `sync_public_data.ps1` uses);
skipped with a log line if they're not set. Retention is a native R2 lifecycle rule on the
`backups/` prefix (expire after 32 days, i.e. roughly the last 4 weekly backups) rather than
PowerShell-side pruning, since wrangler's CLI has no object-list command to enumerate what's
already there.

## One-time REST API note

The REST API change (`RESTAPIEnabled=True` + `AdminPassword`) needs **one manual server restart**
to take effect before broadcasts/controls work.
