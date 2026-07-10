# PalWorldServerManager.ps1
# Dashboard: http://localhost:8213  |  Full server control, settings editor, maintenance.
# Keep this window open. Press Ctrl+C to stop.

$ServerDir           = $PSScriptRoot
$InstallScript       = "$ServerDir\Install-PalWorldServer.ps1"
$StartScript         = "$ServerDir\Start-PalWorldServer.ps1"
$AdminPassword       = $(try{$m=[regex]::Match((Get-Content (Join-Path $PSScriptRoot 'Pal\Saved\Config\WindowsServer\PalWorldSettings.ini') -Raw),'AdminPassword="([^"]*)"');if($m.Success){$m.Groups[1].Value}else{''}}catch{''})
$RestApiBase         = "http://localhost:8212"
$DashPort            = 8213
$ConfigFile          = "$ServerDir\manager-config.json"
$SkipFlagFile        = "$ServerDir\maintenance-skip.flag"
$MaintLogFile        = "$ServerDir\maintenance.log"
$DefaultSettingsPath = "$ServerDir\DefaultPalWorldSettings.ini"
$ActiveSettingsPath  = "$ServerDir\Pal\Saved\Config\WindowsServer\PalWorldSettings.ini"

# ── Maintenance Job ───────────────────────────────────────────────────────────

$MaintenanceJob = Start-Job -Name "PalMaintenance" -ScriptBlock {
    param($InstallScript, $StartScript, $AdminPassword, $RestApiBase,
          $ConfigFile, $SkipFlagFile, $MaintLogFile, $ServerDir)

    # --- Save backup + health monitoring ---------------------------------------
    # Runs before every update (the update could in theory corrupt or roll back the
    # world). Backups land in SaveLibrary using the same layout the Save Manager UI
    # writes, so they show up there too.
    $SaveGamesRoot    = "$ServerDir\Pal\Saved\SaveGames\0"
    $SaveLibraryRoot  = "$ServerDir\SaveLibrary"
    $GameUserSettings = "$ServerDir\Pal\Saved\Config\WindowsServer\GameUserSettings.ini"
    $ActiveSettings   = "$ServerDir\Pal\Saved\Config\WindowsServer\PalWorldSettings.ini"
    $HealthScript     = "$ServerDir\save_health.py"
    $BackupKeep       = 14          # keep this many maintenance auto-backups, prune older
    # Advisory bloat thresholds (well below the ~60 MB on-disk level where saves are
    # known to crash). There is no safe in-place cleaner for this 0.6/PlM save format,
    # so crossing these only logs a warning - it never edits the save automatically.
    $WarnLevelDiskMB  = 25
    $WarnEggItems     = 8000

    # Off-machine backup: SaveLibrary is git-ignored and lives on this one disk, so a
    # weekly zip goes to R2 too -- retention is a native R2 lifecycle rule on the
    # backups/ prefix (expire after ~32 days / ~4 weekly backups), not pruned here.
    $OffMachineStateFile = "$ServerDir\.palbox_offmachine_backup_state.json"
    $OffMachineConfig    = "$ServerDir\config.ps1"

    function Log([string]$Msg) {
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg"
        Write-Output $line
        try {
            Add-Content $MaintLogFile $line -Encoding UTF8
            $lines = @(Get-Content $MaintLogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 2000) { $lines[-2000..-1] | Set-Content $MaintLogFile -Encoding UTF8 }
        } catch {}
    }

    function Get-Headers {
        $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$AdminPassword"))
        @{ Authorization = "Basic $cred"; "Content-Type" = "application/json" }
    }

    function Send-Broadcast([string]$Msg) {
        try {
            Invoke-RestMethod -Uri "$RestApiBase/v1/api/announce" -Method POST `
                -Headers (Get-Headers) -Body (ConvertTo-Json @{ message = $Msg }) | Out-Null
            Log "Broadcast: $Msg"
        } catch { Log "Broadcast failed: $($_.Exception.Message)" }
    }

    function Save-World {
        try {
            Invoke-RestMethod -Uri "$RestApiBase/v1/api/save" -Method POST -Headers (Get-Headers) | Out-Null
            Log "World saved."
        } catch { Log "World save failed (non-fatal): $($_.Exception.Message)" }
    }

    function Wait-Until([datetime]$Until) {
        $secs = [math]::Max(1, [int]($Until - (Get-Date)).TotalSeconds)
        Log "Sleeping $([math]::Round($secs/60,1)) min until $($Until.ToString('HH:mm'))"
        Start-Sleep -Seconds $secs
    }

    function Stop-PalServer {
        if (-not (Get-Process | Where-Object { $_.Name -like "*PalServer*" })) {
            Log "No PalServer process found - skipping stop."
            return
        }
        Log "Saving world before shutdown..."
        Save-World
        Start-Sleep -Seconds 5

        Log "Sending graceful shutdown via REST API..."
        try {
            Invoke-RestMethod -Uri "$RestApiBase/v1/api/shutdown" -Method POST -Headers (Get-Headers) `
                -Body (ConvertTo-Json @{ waittime = 10; message = "Server shutting down for maintenance." }) | Out-Null
        } catch { Log "REST shutdown failed: $($_.Exception.Message)" }

        $waited = 0
        while ((Get-Process | Where-Object { $_.Name -like "*PalServer*" }) -and $waited -lt 90) {
            Start-Sleep -Seconds 3; $waited += 3
        }
        if (Get-Process | Where-Object { $_.Name -like "*PalServer*" }) {
            Log "Server still alive after 90s - force killing..."
            Get-Process | Where-Object { $_.Name -like "*PalServer*" } |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        Log "Server stopped."
    }

    function Wait-ForServerOnline {
        Log "Waiting for server to come online (up to 5 min)..."
        $deadline = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 15
            try {
                $h = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$AdminPassword")))" }
                Invoke-RestMethod -Uri "$RestApiBase/v1/api/info" -Method GET -Headers $h -ErrorAction Stop | Out-Null
                Log "Server is online."
                return $true
            } catch {}
        }
        Log "WARNING: Server did not come online within 5 minutes."
        return $false
    }

    function Get-Config {
        if (Test-Path $ConfigFile) {
            try { return Get-Content $ConfigFile -Raw | ConvertFrom-Json } catch {}
        }
        return [PSCustomObject]@{ maintHour = 4; maintMinute = 0 }
    }

    function IsSkipSet { return (Test-Path $SkipFlagFile) }
    function ClearSkip { Remove-Item $SkipFlagFile -Force -ErrorAction SilentlyContinue }

    # The world the server loads is named by DedicatedServerName in GameUserSettings.ini.
    # The server rewrites that file on shutdown, so we only read it while stopped.
    function Get-ActiveWorldDir {
        if (-not (Test-Path $GameUserSettings)) { return $null }
        $c = Get-Content $GameUserSettings -Raw -Encoding UTF8
        if ($c -match '(?m)^\s*DedicatedServerName\s*=\s*(.+?)\s*$') {
            $dir = Join-Path $SaveGamesRoot $Matches[1].Trim()
            if (Test-Path (Join-Path $dir 'Level.sav')) { return $dir }
        }
        # Fallback: the only world folder that actually has a Level.sav.
        $cand = Get-ChildItem $SaveGamesRoot -Directory -EA SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'Level.sav') } |
                Select-Object -First 1
        if ($cand) { return $cand.FullName }
        return $null
    }

    # Copy the live world into SaveLibrary\Auto-backup_<stamp>\<guid>\ with a slot.json
    # that matches what the Save Manager writes, so the backup appears in its UI.
    function Backup-LiveWorld {
        $worldDir = Get-ActiveWorldDir
        if (-not $worldDir) { Log "Backup skipped: no active world found."; return }
        $guid  = Split-Path $worldDir -Leaf
        $stamp = Get-Date -Format 'yyyy-MM-dd_HH_mm'
        $slot  = Join-Path $SaveLibraryRoot "Auto-backup_$stamp"
        $dest  = Join-Path $slot $guid
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

        # robocopy: fast, handles the deep backup\ tree; exit codes < 8 are success.
        robocopy $worldDir $dest /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { Log "Backup FAILED (robocopy $LASTEXITCODE): $slot"; return }

        if (Test-Path $ActiveSettings) { Copy-Item $ActiveSettings (Join-Path $slot 'PalWorldSettings.ini') -Force }
        $parent = ''
        $marker = Join-Path $SaveLibraryRoot '.active-slot'
        if (Test-Path $marker) { $parent = (Get-Content $marker -Raw -Encoding UTF8).Trim() }
        $meta = [ordered]@{
            name="Auto-backup $stamp"; guid=$guid; created=(Get-Date -Format o)
            note="Pre-maintenance snapshot"; auto=$true; parent=$parent
        }
        ($meta | ConvertTo-Json) | Set-Content (Join-Path $slot 'slot.json') -Encoding UTF8
        Log "Backup saved: $slot"
    }

    # Keep only the newest $BackupKeep pre-maintenance auto-backups (by folder name,
    # which is timestamp-sortable). Only prunes the ones this job makes; named saves
    # and Manager snapshots are left untouched.
    function Prune-AutoBackups {
        $mine = Get-ChildItem $SaveLibraryRoot -Directory -EA SilentlyContinue |
                Where-Object { $_.Name -like 'Auto-backup_*' } |
                Sort-Object Name -Descending
        if ($mine.Count -le $BackupKeep) { return }
        foreach ($old in $mine[$BackupKeep..($mine.Count - 1)]) {
            try { Remove-Item $old.FullName -Recurse -Force -EA Stop; Log "Pruned old backup: $($old.Name)" }
            catch { Log "Could not prune $($old.Name): $($_.Exception.Message)" }
        }
    }

    # Read-only bloat report. Logs sizes + egg-item count and warns past thresholds.
    # Never edits the save: the 0.6/PlM format has no safe in-place cleaner (the parse
    # libraries the community tools build on cannot round-trip it). If a warning fires,
    # do a manual, verified cleanup offline against a backup - don't automate it.
    function Report-SaveHealth {
        $worldDir = Get-ActiveWorldDir
        if (-not $worldDir) { return }
        $json = $null
        try { $json = & python $HealthScript $worldDir 2>$null | Select-Object -Last 1 } catch {}
        if (-not $json) { Log "Save health: report unavailable (python/save_health.py?)."; return }
        try { $h = $json | ConvertFrom-Json } catch { Log "Save health: bad output."; return }
        if (-not $h.ok) { Log "Save health error: $($h.error)"; return }

        $diskMB   = [math]::Round($h.levelDiskBytes   / 1MB, 1)
        $decompMB = [math]::Round($h.levelDecompBytes / 1MB, 1)
        $dpsMB    = [math]::Round($h.maxDpsDiskBytes  / 1MB, 1)
        Log "Save health: Level.sav ${diskMB}MB disk / ${decompMB}MB decompressed, eggs=$($h.eggItems), max _dps=${dpsMB}MB"
        if ($diskMB     -ge $WarnLevelDiskMB) { Log "WARNING: Level.sav is ${diskMB}MB on disk (>= ${WarnLevelDiskMB}MB). Consider an offline save cleanup." }
        if ($h.eggItems -ge $WarnEggItems)    { Log "WARNING: $($h.eggItems) egg dynamic-item records (>= $WarnEggItems) - save bloat building up." }
    }

    # Zips SaveLibrary (which, run right after Backup-LiveWorld, already holds a fresh
    # live-world snapshot) and pushes it to R2 so a single-disk failure can't take out
    # every backup along with the live world. Runs at most once every ~7 days, gated on
    # a persisted timestamp rather than a fixed weekday so it still catches up if the
    # job was down on the usual day. Retention is the R2-side lifecycle rule, not here.
    function Backup-OffMachine {
        $last = $null
        if (Test-Path $OffMachineStateFile) {
            try { $last = (Get-Content $OffMachineStateFile -Raw | ConvertFrom-Json).lastBackup } catch {}
        }
        if ($last) {
            try { if (((Get-Date) - [datetime]$last).TotalDays -lt 7) { return } } catch {}
        }

        # Same Process -> User -> Machine credential fallback as sync_public_data.ps1,
        # since this job (like that script) can start with a bare Process environment.
        foreach ($v in 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID') {
            if (-not [Environment]::GetEnvironmentVariable($v, 'Process')) {
                $val = [Environment]::GetEnvironmentVariable($v, 'User')
                if (-not $val) { $val = [Environment]::GetEnvironmentVariable($v, 'Machine') }
                if ($val) { Set-Item -Path ("Env:" + $v) -Value $val }
            }
        }
        if (-not $env:CLOUDFLARE_API_TOKEN -or -not $env:CLOUDFLARE_ACCOUNT_ID) {
            Log "Off-machine backup skipped: R2 credentials not set in the environment."
            return
        }

        $bucket = 'your-r2-bucket'
        if (Test-Path $OffMachineConfig) { . $OffMachineConfig; if ($R2Bucket) { $bucket = $R2Bucket } }

        $stamp = Get-Date -Format 'yyyy-MM-dd'

        # Wrangler rejects any single R2 upload over 300 MiB. SaveLibrary grows over time
        # (confirmed 2026-07-09: a single whole-folder zip hit 344 MiB and failed outright),
        # so bin-pack the top-level slot folders into <=250MB groups (margin below the cap,
        # since zip gives these already-compressed .sav files ~1:1) and upload one part per bin.
        $maxBinMB = 250
        $entries = Get-ChildItem $SaveLibraryRoot -Directory -EA SilentlyContinue | ForEach-Object {
            $sz = (Get-ChildItem $_.FullName -Recurse -File -EA SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            [PSCustomObject]@{ Name = $_.Name; MB = $sz / 1MB }
        } | Sort-Object MB -Descending

        $bins = New-Object System.Collections.ArrayList
        foreach ($e in $entries) {
            $placed = $false
            foreach ($b in $bins) {
                if (($b.TotalMB + $e.MB) -le $maxBinMB) {
                    [void]$b.Items.Add($e.Name)
                    $b.TotalMB += $e.MB
                    $placed = $true
                    break
                }
            }
            if (-not $placed) {
                $newBin = [PSCustomObject]@{ Items = (New-Object System.Collections.ArrayList); TotalMB = 0 }
                [void]$newBin.Items.Add($e.Name)
                $newBin.TotalMB = $e.MB
                [void]$bins.Add($newBin)
            }
        }

        if ($bins.Count -eq 0) { Log "Off-machine backup: SaveLibrary is empty, nothing to upload."; return }

        Log "Off-machine backup: zipping SaveLibrary into $($bins.Count) part(s)..."
        $zipPaths = New-Object System.Collections.ArrayList
        $allOk = $true
        for ($i = 0; $i -lt $bins.Count; $i++) {
            $partNum = $i + 1
            $zipPath = Join-Path $env:TEMP "palbox-offmachine-backup-$stamp-part$partNum.zip"
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force -EA SilentlyContinue }
            $paths = $bins[$i].Items | ForEach-Object { Join-Path $SaveLibraryRoot $_ }
            try {
                Compress-Archive -Path $paths -DestinationPath $zipPath -CompressionLevel Optimal -EA Stop
                [void]$zipPaths.Add($zipPath)
            } catch {
                Log "Off-machine backup FAILED (zip part $partNum): $($_.Exception.Message)"
                $allOk = $false
                break
            }
        }

        if ($allOk) {
            $wranglerCmd = Get-Command wrangler -ErrorAction SilentlyContinue
            for ($i = 0; $i -lt $zipPaths.Count; $i++) {
                $partNum = $i + 1
                $zipPath = $zipPaths[$i]
                $key = "backups/offmachine-backup-$stamp-part$partNum.zip"
                $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
                Log "Off-machine backup: uploading $key (${sizeMB}MB)..."
                if ($wranglerCmd) { & wrangler r2 object put "$bucket/$key" --file $zipPath --content-type application/zip --remote | Out-Null }
                else { & npx wrangler r2 object put "$bucket/$key" --file $zipPath --content-type application/zip --remote | Out-Null }
                if ($LASTEXITCODE -ne 0) {
                    Log "Off-machine backup FAILED (wrangler put exit $LASTEXITCODE, part $partNum)."
                    $allOk = $false
                    break
                }
            }
        }

        foreach ($zipPath in $zipPaths) { Remove-Item $zipPath -Force -EA SilentlyContinue }

        if (-not $allOk) { return }

        ([ordered]@{ lastBackup = (Get-Date -Format o) } | ConvertTo-Json) |
            Set-Content $OffMachineStateFile -Encoding UTF8
        Log "Off-machine backup uploaded: $($zipPaths.Count) part(s)"
    }

    # Deploys the public site's STATIC shell (dashboard.html-derived index.html, map
    # category data, pal-species/etc.) once per daily maintenance cycle. Map data
    # (confirmed_locations.json changes -- new confirms, imports) only reaches
    # palbox.evoveriv.com via a real deploy_public_site.ps1 run, unlike the per-player
    # data sync_public_data.ps1 already pushes to R2 every ~60s -- see the
    # palbox-confirmed-locations skill's "R2 vs static deploy" note. Independent of
    # whether PalServer itself is up (it only reads local files + calls wrangler), so
    # this runs regardless of the online-wait result below.
    function Deploy-PublicSite {
        # Same Process -> User -> Machine credential fallback as Backup-OffMachine above,
        # since this job can start with a bare Process environment.
        foreach ($v in 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID') {
            if (-not [Environment]::GetEnvironmentVariable($v, 'Process')) {
                $val = [Environment]::GetEnvironmentVariable($v, 'User')
                if (-not $val) { $val = [Environment]::GetEnvironmentVariable($v, 'Machine') }
                if ($val) { Set-Item -Path ("Env:" + $v) -Value $val }
            }
        }
        if (-not $env:CLOUDFLARE_API_TOKEN -or -not $env:CLOUDFLARE_ACCOUNT_ID) {
            Log "Public site deploy skipped: Cloudflare credentials not set in the environment."
            return
        }
        Log "Deploying public site (deploy_public_site.ps1 -Force)..."
        try {
            & "$ServerDir\deploy_public_site.ps1" -Root $ServerDir -Force *>&1 | ForEach-Object { Log "  $_" }
            Log "Public site deploy complete."
        } catch {
            Log "Public site deploy FAILED: $($_.Exception.Message)"
        }
    }

    # sync_public_data.ps1 logs a line roughly every ~60s tick (SUCCESS or FAILED, the
    # latter up to 4 lines) with no rotation of its own -- unlike this job's own Log
    # function, which already self-trims maintenance.log. Once/day here (same
    # maintenance-style tail-trim technique) is enough to keep it bounded.
    function Trim-SyncLog {
        $syncLog = "$ServerDir\sync_public_data.log"
        if (-not (Test-Path -LiteralPath $syncLog)) { return }
        try {
            $lines = @(Get-Content -LiteralPath $syncLog -Encoding UTF8 -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 5000) {
                $lines[-5000..-1] | Set-Content -LiteralPath $syncLog -Encoding UTF8
                Log "Trimmed sync_public_data.log to 5000 lines."
            }
        } catch { Log "Could not trim sync_public_data.log: $($_.Exception.Message)" }
    }

    # Start server if not already running
    if (-not (Get-Process | Where-Object { $_.Name -like "*PalServer*" })) {
        Log "Server not running - starting now..."
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$StartScript`""
        Log "Server process launched."
        Wait-ForServerOnline | Out-Null
    } else { Log "Server is already running." }

    while ($true) {
        $cfg  = Get-Config
        $mh   = if ($cfg.PSObject.Properties['maintHour'])   { [int]$cfg.maintHour   } else { 4 }
        $mm   = if ($cfg.PSObject.Properties['maintMinute']) { [int]$cfg.maintMinute } else { 0 }
        $now  = Get-Date
        $next = $now.Date.AddHours($mh).AddMinutes($mm)
        if ($now -ge $next) { $next = $next.AddDays(1) }

        $w60 = $next.AddMinutes(-60)
        $w30 = $next.AddMinutes(-30)
        $w15 = $next.AddMinutes(-15)
        $w5  = $next.AddMinutes(-5)
        $w1  = $next.AddMinutes(-1)

        Log "Next maintenance: $($next.ToString('ddd yyyy-MM-dd HH:mm'))"

        if ($now -lt $w60) { Wait-Until $w60 }
        if (IsSkipSet) { Log "Maintenance skipped (flag)."; ClearSkip; continue }
        if ((Get-Date) -le $w60.AddMinutes(1)) {
            Send-Broadcast "Server restarts at $($next.ToString('HH:mm')) for daily maintenance (60 min)."
        }

        if ((Get-Date) -lt $w30) { Wait-Until $w30 }
        if (IsSkipSet) { Log "Maintenance skipped (flag)."; ClearSkip; continue }
        if ((Get-Date) -le $w30.AddMinutes(1)) { Send-Broadcast "Server restarting in 30 minutes for maintenance." }

        if ((Get-Date) -lt $w15) { Wait-Until $w15 }
        if (IsSkipSet) { Log "Maintenance skipped (flag)."; ClearSkip; continue }
        if ((Get-Date) -le $w15.AddMinutes(1)) { Send-Broadcast "Server restarting in 15 minutes for maintenance." }

        if ((Get-Date) -lt $w5) { Wait-Until $w5 }
        if (IsSkipSet) { Log "Maintenance skipped (flag)."; ClearSkip; continue }
        if ((Get-Date) -le $w5.AddMinutes(1)) { Send-Broadcast "Server restarting in 5 minutes for maintenance. Wrap up!" }

        if ((Get-Date) -lt $w1) { Wait-Until $w1 }
        Send-Broadcast "Server restarting in 60 seconds for maintenance!"; Start-Sleep -Seconds 30
        Send-Broadcast "Server restarting in 30 seconds!";                 Start-Sleep -Seconds 20
        Send-Broadcast "Server restarting in 10 seconds!";                 Start-Sleep -Seconds 5
        Send-Broadcast "Server restarting in 5 seconds!";                  Start-Sleep -Seconds 5

        if (IsSkipSet) {
            Log "Skip flag set at last moment - cancelling maintenance."
            ClearSkip
            Send-Broadcast "Maintenance cancelled. Server remains online."
            continue
        }

        Send-Broadcast "Restarting for maintenance now. Back online in a few minutes!"
        Log "=== MAINTENANCE START ==="
        Stop-PalServer

        Log "Backing up world before update..."
        Backup-LiveWorld
        Report-SaveHealth
        Prune-AutoBackups
        Backup-OffMachine
        Trim-SyncLog

        Log "Running update script..."
        & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $InstallScript
        Log "Update complete."

        Log "Restarting server..."
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$StartScript`""
        if (Wait-ForServerOnline) {
            Send-Broadcast "Server is back online! Thanks for your patience."
            Log "=== MAINTENANCE COMPLETE ==="
        } else {
            Log "=== MAINTENANCE COMPLETE - WARNING: health check timed out ==="
        }

        Deploy-PublicSite

        Start-Sleep -Seconds 60
    }

} -ArgumentList $InstallScript, $StartScript, $AdminPassword, $RestApiBase,
                $ConfigFile, $SkipFlagFile, $MaintLogFile, $ServerDir

# ── Dashboard Job ─────────────────────────────────────────────────────────────

$DashboardJob = Start-Job -Name "PalDashboard" -ScriptBlock {
    param($ServerDir, $AdminPassword, $PalApiBase, $DashPort, $StartScript,
          $ConfigFile, $SkipFlagFile, $MaintLogFile, $DefaultSettingsPath, $ActiveSettingsPath)

    $LogFile      = "$ServerDir\metrics-log.jsonl"
    $PollInterval = 300   # metrics-collection cadence (also the history-chart granularity)
    $SyncInterval = 20    # public-data R2 sync cadence -- how fresh the dashboards' data is
                          # (60->30->20s on 2026-07-09; Level.sav is genuinely rewritten
                          #  every ~5s (AutoSaveSpan=5, measured), so 20s is a real freshness
                          #  gain, not just faster no-op polling. Each changed cycle is ~2 R2
                          #  puts + a ~16s build; 20s > that run time so no mutex backlog, and
                          #  ~260k puts/mo stays well under the 1M/mo Class A free tier.
                          #  Don't go below ~18s or runs start hitting the single-flight skip.)
    $EggCheckInterval = 30   # egg-ready check cadence (re-parses only when Level.sav changed)

    # Per-player in-game "egg ready to hatch" alerts. egg_notify.json is the admin-set
    # opt-in list ({ "<8-hex prefix>": { enabled, name } }); .egg_notify_state.json is
    # the runtime high-water mark of the last ready-count we announced per player, so we
    # alert once per new ready egg rather than every poll. The game has no DM, so the
    # alert is a server-wide announce that names the player (see Check-EggNotifications).
    $EggNotifyFile      = "$ServerDir\egg_notify.json"
    $EggNotifyStateFile = "$ServerDir\.egg_notify_state.json"

    # Shared server-message feed helper (Add-ServerMessage / Get-ServerMessagesJson) that
    # backs the dashboard chat banner. Dot-sourced so every broadcast site here records.
    . "$ServerDir\server_messages.ps1"

    # Shared map-location data layer (Get-ConfirmedLocations, Get-MapCategoryJson, etc.) --
    # also dot-sourced by build_public_data.ps1, so both callers share one implementation
    # instead of two hand-kept, drifting copies. See map_data_lib.ps1 for the full function
    # list; used by the /api/effigies...towers routes below.
    . "$ServerDir\map_data_lib.ps1"
    Initialize-MapDataLib -Root $ServerDir

    # Save-management paths. The dedicated server loads whichever world folder
    # DedicatedServerName (in GameUserSettings.ini) points at, under SaveGames\0.
    # SaveLibrary holds named copies of worlds + auto snapshots; nothing here is
    # ever deleted when a save is loaded into the server, so reverts are safe.
    $SaveGamesRoot    = "$ServerDir\Pal\Saved\SaveGames\0"
    $SaveLibraryRoot  = "$ServerDir\SaveLibrary"
    $GameUserSettings = "$ServerDir\Pal\Saved\Config\WindowsServer\GameUserSettings.ini"

    # ── INI helpers ───────────────────────────────────────────────────────────

    function Parse-IniSettings($path) {
        $result = [ordered]@{}
        if (-not (Test-Path $path)) { return $result }
        foreach ($line in (Get-Content $path -Encoding UTF8)) {
            if ($line -notmatch 'OptionSettings=') { continue }
            if ($line -notmatch 'OptionSettings=\((.+)\)') { break }
            $content = $Matches[1]; $depth = 0; $token = ""
            foreach ($ch in $content.ToCharArray()) {
                if     ($ch -eq '(') { $depth++; $token += $ch }
                elseif ($ch -eq ')') { $depth--; $token += $ch }
                elseif ($ch -eq ',' -and $depth -eq 0) {
                    if ($token -match '^([^=]+)=(.*)$') { $result[$Matches[1]] = $Matches[2] }
                    $token = ""
                } else { $token += $ch }
            }
            if ($token -match '^([^=]+)=(.*)$') { $result[$Matches[1]] = $Matches[2] }
            break
        }
        return $result
    }

    function Write-IniSettings($settings, $path) {
        $pairs = foreach ($k in $settings.Keys) { "$k=$($settings[$k])" }
        $body  = "OptionSettings=($($pairs -join ','))"
        $tmp   = "$path.tmp"
        # No-BOM UTF-8 (WriteAllText, matching Set-ActiveGuid's GameUserSettings write just
        # below). Set-Content -Encoding UTF8 under Windows PowerShell 5.1 prepends a UTF-8 BOM
        # before the "[/Script/Pal.PalGameWorldSettings]" header; the server itself always
        # rewrites this file WITHOUT a BOM on shutdown, so a no-BOM write is exactly the shape
        # the game already round-trips, and keeps a BOM from ever preceding the section header.
        [System.IO.File]::WriteAllText($tmp, "[/Script/Pal.PalGameWorldSettings]`r`n$body`r`n", (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Path $tmp -Destination $path -Force
    }

    # ── Playtime / metrics helpers ────────────────────────────────────────────

    function Get-PalHeaders {
        $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$AdminPassword"))
        @{ Authorization = "Basic $cred"; "Content-Type" = "application/json" }
    }

    # ── Egg-ready alert opt-in + state ────────────────────────────────────────────
    # Keys are normalized to the uppercase 8-hex player prefix so they match the egg
    # reader's `owner` and the online players' UID prefix.
    function Get-EggNotifyConfig {
        $ht = @{}
        if (Test-Path $EggNotifyFile) {
            try {
                $o = Get-Content $EggNotifyFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($p in $o.PSObject.Properties) {
                    $ht[$p.Name.ToUpper()] = @{ enabled = [bool]$p.Value.enabled; name = [string]$p.Value.name }
                }
            } catch {}
        }
        return $ht
    }
    function Save-EggNotifyConfig($ht) {
        ($ht | ConvertTo-Json -Depth 4) | Set-Content $EggNotifyFile -Encoding UTF8
    }
    function Get-EggNotifyState {
        $ht = @{}
        if (Test-Path $EggNotifyStateFile) {
            try {
                $o = Get-Content $EggNotifyStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($p in $o.PSObject.Properties) { $ht[$p.Name.ToUpper()] = [int]$p.Value }
            } catch {}
        }
        return $ht
    }
    function Save-EggNotifyState($ht) {
        ($ht | ConvertTo-Json) | Set-Content $EggNotifyStateFile -Encoding UTF8
    }

    function Send-Response {
        param($Response, [int]$StatusCode, [string]$ContentType, [string]$Body)
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $Response.StatusCode  = $StatusCode
        $Response.ContentType = $ContentType
        try { $Response.OutputStream.Write($bytes, 0, $bytes.Length); $Response.OutputStream.Close() } catch {}
    }

    function Get-GzipBytes([string]$Text) {
        $ms = New-Object System.IO.MemoryStream
        $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $gz.Write($bytes, 0, $bytes.Length)
        $gz.Dispose()
        $result = $ms.ToArray()
        $ms.Dispose()
        return $result
    }

    # Last-Modified/If-Modified-Since 304 handling + optional gzip, same pattern the icon
    # routes already use -- copied here for the two biggest uncompressed payloads (the
    # ~430KB dashboard page and the 165KB pal-species.json), which previously had no
    # Cache-Control/ETag/gzip at all. $GzipBytes is precomputed by the caller (once at
    # startup for $HtmlPage, lazily on first request for pal-species) rather than
    # gzip'd fresh on every single request.
    function Send-CachedResponse($Response, $Request, [string]$ContentType, [string]$Body, [byte[]]$GzipBytes, [datetime]$Mtime) {
        $lastModStr = $Mtime.ToString('R')
        $ims = $Request.Headers['If-Modified-Since']
        $imsDate = [datetime]::MinValue
        if ($ims -and [datetime]::TryParse($ims, [ref]$imsDate) -and $Mtime -le $imsDate.ToUniversalTime().AddSeconds(1)) {
            $Response.StatusCode = 304
            $Response.AddHeader('Cache-Control', 'no-cache')
            $Response.AddHeader('Last-Modified', $lastModStr)
            try { $Response.OutputStream.Close() } catch {}
            return
        }
        $Response.AddHeader('Cache-Control', 'no-cache')
        $Response.AddHeader('Last-Modified', $lastModStr)
        $Response.ContentType = $ContentType
        $acceptEnc = $Request.Headers['Accept-Encoding']
        if ($acceptEnc -and $acceptEnc -like '*gzip*' -and $GzipBytes) {
            $Response.AddHeader('Content-Encoding', 'gzip')
            $Response.StatusCode = 200
            $Response.ContentLength64 = $GzipBytes.Length
            try { $Response.OutputStream.Write($GzipBytes, 0, $GzipBytes.Length) } catch {}
        } else {
            $Response.StatusCode = 200
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $Response.ContentLength64 = $bytes.Length
            try { $Response.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
        }
        try { $Response.OutputStream.Close() } catch {}
    }

    # Registry for the admin dashboard's generic Data Mine key/property browser (mirrors
    # pal_save_reader.py's DATAMINE_PROPERTIES -- keep both lists in sync). Properties in
    # this set have real map-location meaning, so an edit to one is upserted directly into
    # confirmed_locations.json (stamped source=<property>) -- Anthony explicitly opted into
    # treating the dashboard as a second trusted writer alongside the Desktop dataminer
    # script for this feature (see /palworld-dataminer skill), even though every OTHER
    # manual-confirm feature above deliberately avoids that file. Anything not in this set
    # (item/quest/recipe counts and names -- no location meaning) is upserted into the
    # separate datamine_labels.json instead.
    $script:DatamineSpatialProperties = @(
        'NormalBossDefeatFlag', 'RelicObtainForInstanceFlag', 'NoteObtainForInstanceFlag',
        'FastTravelPointUnlockFlag', 'DestroyedWeapon'
    )

    # datamine_labels.json holds {property,key,name,gx,gy} for non-spatial properties --
    # read fresh every call, same no-caching convention as the other small roster files.
    function Get-DatamineLabels {
        $f = "$ServerDir\datamine_labels.json"
        if (Test-Path -LiteralPath $f) {
            try {
                $arr = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -eq $arr) { $arr = @() }
                return $arr
            } catch { return @() }
        }
        return @()
    }

    # ── Save-management helpers ───────────────────────────────────────────────

    # Read/write the world GUID the server loads on start. The server rewrites
    # GameUserSettings.ini on shutdown, so this must only be changed while stopped.
    function Get-ActiveGuid {
        if (-not (Test-Path $GameUserSettings)) { return $null }
        $c = Get-Content $GameUserSettings -Raw -Encoding UTF8
        if ($c -match '(?m)^\s*DedicatedServerName\s*=\s*(.+?)\s*$') { return $Matches[1].Trim() }
        return $null
    }
    function Set-ActiveGuid([string]$guid) {
        $c = Get-Content $GameUserSettings -Raw -Encoding UTF8
        if ($c -match '(?m)^\s*DedicatedServerName\s*=') {
            # '${1}' is a single-quoted regex backref (not a PowerShell var) so the
            # captured "DedicatedServerName=" prefix survives; $guid is appended.
            $c = [regex]::Replace($c, '(?m)^(\s*DedicatedServerName\s*=).*$', '${1}' + $guid)
        } else {
            $c = $c -replace '(\[/Script/Pal\.PalGameLocalSettings\]\r?\n)', ('${1}' + "DedicatedServerName=$guid`r`n")
        }
        [IO.File]::WriteAllText($GameUserSettings, $c, (New-Object Text.UTF8Encoding($false)))
    }

    # -- Reader-backed route response cache ------------------------------------
    # /api/pals, /api/paldeck, /api/eggs, /api/player-locations, and the 7 per-player
    # routes below each used to spawn Python + do a full PS 5.1 JSON round-trip on EVERY
    # request, even though the underlying .sav hasn't changed between polls (the Map tab
    # alone polls /api/player-locations every 15s). This caches the RAW reader output --
    # NOT any live-enriched response built on top of it, since online-player names come
    # from a separate always-fresh REST poll each route does after calling this, and must
    # never be served stale -- keyed on the relevant file's own LastWriteTimeUtc ticks, so
    # a request between saves is a dictionary lookup instead of a process spawn. The cache
    # stores the STRING only; each caller re-parses it fresh via ConvertFrom-Json, so a
    # route that mutates its own $data in place (name enrichment, Add-Member, ...) never
    # corrupts what's cached for the next request.
    $script:readerCache = @{}
    # $StampPaths accepts either a single path (existing callers) or an array -- for readers
    # whose output depends on more than just the save file (bounty/datamine species matching
    # also reads anonymous_boss_keys.json/excluded_boss_keys.json/bounty_bosses.json), pass all
    # of them so editing a roster file invalidates the cache even though the .sav is unchanged.
    # Missed this originally: a species mapping added to anonymous_boss_keys.json after a
    # player's datamine result was already cached stayed invisible (stuck in the "anonymous"
    # bucket) until that player's save changed again, even though the Map tab (which reads
    # confirmed_locations.json directly, uncached) showed the new pin immediately.
    function Get-CachedReaderOutput([string]$CacheKey, [string[]]$StampPaths, [scriptblock]$Producer) {
        $stamp = ($StampPaths | ForEach-Object {
            if (Test-Path -LiteralPath $_) { [string]([System.IO.File]::GetLastWriteTimeUtc($_).Ticks) } else { '' }
        }) -join '|'
        $entry = $script:readerCache[$CacheKey]
        if ($entry -and $entry.stamp -eq $stamp) { return $entry.json }
        $json = & $Producer
        $script:readerCache[$CacheKey] = [pscustomobject]@{ stamp = $stamp; json = $json }
        return $json
    }

    # robocopy is used for the world copies: fast, handles the deep backup\ tree,
    # and treats long paths well. Exit codes < 8 are success.
    function Copy-WorldTree([string]$src, [string]$dst, [switch]$Mirror) {
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        $mode = if ($Mirror) { '/MIR' } else { '/E' }
        robocopy $src $dst $mode /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
        return ($LASTEXITCODE -lt 8)
    }

    function Read-SlotMeta([string]$slotDir) {
        $f = Join-Path $slotDir 'slot.json'
        if (Test-Path $f) { try { return Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
        return [PSCustomObject]@{ name=(Split-Path $slotDir -Leaf); guid=$null; created=''; note=''; auto=$false }
    }
    function Write-SlotMeta([string]$slotDir, $meta) {
        if (-not (Test-Path $slotDir)) { New-Item -ItemType Directory -Path $slotDir -Force | Out-Null }
        ($meta | ConvertTo-Json) | Set-Content (Join-Path $slotDir 'slot.json') -Encoding UTF8
    }

    # Turn a display name into a unique, filesystem-safe slot folder id.
    function New-SlotId([string]$name) {
        $base = ($name -replace '[^\w\-]+', '_').Trim('_')
        if (-not $base) { $base = 'save' }
        $id = $base; $n = 1
        while (Test-Path (Join-Path $SaveLibraryRoot $id)) { $n++; $id = "$base-$n" }
        return $id
    }

    # Validate a client-supplied slot id before it is ever joined to a path. Generated
    # ids come from New-SlotId (constrained to [\w\-]); inbound ids from the dashboard
    # must match that same shape so a value like '..\..\Windows' can't traverse out of
    # the save library into an arbitrary directory delete/write. Returns $true if safe.
    function Test-SlotId([string]$id) {
        return ($id -and ($id -match '^[\w\-]+$'))
    }

    function Get-SlotWorldDir([string]$slotDir, $meta) {
        $guid = if ($meta.guid) { $meta.guid } else {
            $sub = Get-ChildItem $slotDir -Directory -EA SilentlyContinue | Select-Object -First 1
            if ($sub) { $sub.Name } else { $null }
        }
        $dir = if ($guid) { Join-Path $slotDir $guid } else { $null }
        return @{ guid = $guid; dir = $dir }
    }

    # Save the live world into the library under a name (used by capture + the
    # pre-switch auto snapshot). Never touches the running world's files.
    # $parent ties an auto-backup to the save it was snapshotted from, so the UI
    # can group backups under that save instead of cluttering the main list.
    function Save-WorldToLibrary([string]$displayName, [string]$note, [bool]$auto, [string]$parent = '') {
        $activeGuid = Get-ActiveGuid
        if (-not $activeGuid) { return $null }
        $liveDir = Join-Path $SaveGamesRoot $activeGuid
        if (-not (Test-Path (Join-Path $liveDir 'Level.sav'))) { return $null }
        $id   = New-SlotId $displayName
        $dest = Join-Path $SaveLibraryRoot $id
        if (-not (Copy-WorldTree $liveDir (Join-Path $dest $activeGuid))) { return $null }
        # Tie the current settings to this save so loading it restores them too.
        if (Test-Path $ActiveSettingsPath) { Copy-Item $ActiveSettingsPath (Join-Path $dest 'PalWorldSettings.ini') -Force }
        Write-SlotMeta $dest ([ordered]@{ name=$displayName; guid=$activeGuid; created=(Get-Date -Format o); note=$note; auto=$auto; parent=$parent })
        return $id
    }

    # Graceful stop (save + REST shutdown), force-kill as a last resort. Returns
    # $true once no PalServer process remains.
    function Stop-PalServerWait {
        # -Name 'PalServer*' instead of piping every process on the box through
        # Where-Object -- a targeted Get-Process filter, not a full enumeration.
        if (-not (Get-Process -Name 'PalServer*' -EA SilentlyContinue)) { return $true }
        try { Invoke-RestMethod -Uri "$PalApiBase/v1/api/save" -Method POST -Headers (Get-PalHeaders) -EA Stop | Out-Null } catch {}
        Start-Sleep -Seconds 3
        try {
            Invoke-RestMethod -Uri "$PalApiBase/v1/api/shutdown" -Method POST -Headers (Get-PalHeaders) `
                -Body (ConvertTo-Json @{ waittime=5; message="Switching world save - back shortly." }) -EA Stop | Out-Null
        } catch {}
        $waited = 0
        while ((Get-Process -Name 'PalServer*' -EA SilentlyContinue) -and $waited -lt 60) {
            Start-Sleep -Seconds 2; $waited += 2
        }
        if (Get-Process -Name 'PalServer*' -EA SilentlyContinue) {
            Get-Process -Name 'PalServer*' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
            Start-Sleep -Seconds 3
        }
        return -not [bool](Get-Process -Name 'PalServer*' -EA SilentlyContinue)
    }

    function Get-SaveList {
        if (-not (Test-Path $SaveLibraryRoot)) { New-Item -ItemType Directory -Path $SaveLibraryRoot -Force | Out-Null }
        $activeGuid = Get-ActiveGuid
        $running    = [bool](Get-Process | Where-Object { $_.Name -like "*PalServer*" })
        $markerFile = Join-Path $SaveLibraryRoot '.active-slot'
        $activeSlot = if (Test-Path $markerFile) { (Get-Content $markerFile -Raw -Encoding UTF8).Trim() } else { $null }

        $slotDirs = @(Get-ChildItem $SaveLibraryRoot -Directory -EA SilentlyContinue)

        # First-run bootstrap: import the current live world so it always has a
        # kept copy. Save via REST first if running so the snapshot is consistent.
        if ($slotDirs.Count -eq 0 -and $activeGuid -and (Test-Path (Join-Path (Join-Path $SaveGamesRoot $activeGuid) 'Level.sav'))) {
            if ($running) { try { Invoke-RestMethod -Uri "$PalApiBase/v1/api/save" -Method POST -Headers (Get-PalHeaders) -EA Stop | Out-Null; Start-Sleep -Seconds 2 } catch {} }
            $id = Save-WorldToLibrary 'Original' 'Imported from live server' $false
            if ($id) { Set-Content $markerFile $id -NoNewline -Encoding UTF8; $activeSlot = $id }
            $slotDirs = @(Get-ChildItem $SaveLibraryRoot -Directory -EA SilentlyContinue)
        }

        # Finalize pending new worlds: once the server has generated the world,
        # copy it into the library slot so the slot is a real, re-loadable backup.
        foreach ($d in $slotDirs) {
            $m = Read-SlotMeta $d.FullName
            if ($m.PSObject.Properties['pending'] -and $m.pending -and $m.guid) {
                $liveLvl = Join-Path (Join-Path $SaveGamesRoot $m.guid) 'Level.sav'
                $libLvl  = Join-Path (Join-Path $d.FullName $m.guid) 'Level.sav'
                if ((Test-Path $liveLvl) -and -not (Test-Path $libLvl)) {
                    if (Copy-WorldTree (Join-Path $SaveGamesRoot $m.guid) (Join-Path $d.FullName $m.guid)) {
                        $m.pending = $false
                        Write-SlotMeta $d.FullName $m
                    }
                }
            }
        }

        $slots = foreach ($d in $slotDirs) {
            $meta  = Read-SlotMeta $d.FullName
            $world = Get-SlotWorldDir $d.FullName $meta
            $pending = [bool]($meta.PSObject.Properties['pending'] -and $meta.pending)
            # For the active world, prefer the live folder (source of truth) so a
            # freshly generated world or in-progress play reports accurate stats.
            $statsDir = $world.dir
            if ($world.guid -eq $activeGuid -and (Test-Path (Join-Path (Join-Path $SaveGamesRoot $world.guid) 'Level.sav'))) {
                $statsDir = Join-Path $SaveGamesRoot $world.guid
            }
            $saved = ''; $players = 0; $sizeMB = 0
            if ($statsDir -and (Test-Path $statsDir)) {
                $lvl = Join-Path $statsDir 'Level.sav'
                if (Test-Path $lvl) { $saved = (Get-Item $lvl).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss') }
                $pdir = Join-Path $statsDir 'Players'
                if (Test-Path $pdir) { $players = @(Get-ChildItem $pdir -File -Filter *.sav -EA SilentlyContinue).Count }
                $sum = (Get-ChildItem $statsDir -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
                $sizeMB = [math]::Round(($sum / 1MB), 1)
            }
            $parent = if ($meta.PSObject.Properties['parent']) { [string]$meta.parent } else { '' }
            [ordered]@{ id=$d.Name; name=$meta.name; guid=$world.guid; saved=$saved;
                        players=$players; sizeMB=$sizeMB; auto=[bool]$meta.auto; pending=$pending;
                        parent=$parent;
                        hasSettings=[bool](Test-Path (Join-Path $d.FullName 'PalWorldSettings.ini'));
                        note=$meta.note; isActive=($d.Name -eq $activeSlot) }
        }

        return [ordered]@{ activeGuid=$activeGuid; activeSlot=$activeSlot; serverRunning=$running; slots=@($slots) }
    }

    # Player Stats are scoped per-world (one log file per world GUID) rather than one
    # global cross-save total, so switching to a different save (Save Manager) shows
    # that save's own history instead of carrying over hours from another playthrough.
    function Get-PlaytimeFile([string]$Guid) {
        if (-not $Guid) { $Guid = 'unknown' }
        return "$ServerDir\playtime-log-$Guid.json"
    }

    function Load-Playtime {
        $ht = @{}
        if (Test-Path $script:PlaytimeFile) {
            try {
                $arr = Get-Content $script:PlaytimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($e in $arr) {
                    if (-not $e.name) { continue }
                    $ht[$e.name] = @{ totalSeconds=$([long]$e.totalSeconds); sessions=$([int]$e.sessions);
                                      lastSeen=$([string]$e.lastSeen); avgPing=$([double]$e.avgPing);
                                      sampleCount=$([int]$e.sampleCount); steamid=$([string]$e.steamid) }
                }
            } catch {}
        }
        return $ht
    }

    function Save-Playtime {
        $arr = @($script:playtime.GetEnumerator() | ForEach-Object {
            @{ name=$_.Key; totalSeconds=$_.Value.totalSeconds; sessions=$_.Value.sessions;
               lastSeen=$_.Value.lastSeen; avgPing=[math]::Round($_.Value.avgPing,1);
               sampleCount=$_.Value.sampleCount; steamid=$_.Value.steamid }
        })
        $(if ($arr.Count) { ConvertTo-Json $arr -Depth 3 -Compress } else { '[]' }) |
            Set-Content $script:PlaytimeFile -Encoding UTF8
    }

    # Re-points $script:playtime at whichever world is currently active (checked cheaply
    # against Get-ActiveGuid), flushing the outgoing world's data first so nothing is
    # lost on a switch. Call after any action that can change DedicatedServerName
    # (save-new, save-activate) and defensively on every metrics poll in case the GUID
    # changed some other way (manual edit, external script).
    function Sync-PlaytimeToActiveWorld {
        $guid = Get-ActiveGuid
        if ($guid -eq $script:playtimeGuid) { return }
        if ($script:playtimeGuid) { Save-Playtime }
        $script:playtimeGuid  = $guid
        $script:PlaytimeFile  = Get-PlaytimeFile $guid
        $script:playtime      = Load-Playtime
        $script:onlinePlayers = @{}
    }

    function Append-Metric($entry) {
        Add-Content $LogFile (ConvertTo-Json $entry -Depth 3 -Compress) -Encoding UTF8
        $script:metricAppendCount++
        # Once the log reaches its steady-state size (~7 days in), the count check below used
        # to trip on EVERY call -- a full Get-Content + Set-Content over 2000+ lines (~206KB)
        # every 5 minutes, forever, just to drop the single line that grew past the cap. Lazy:
        # only check/trim about once/day (every 288 calls at the 300s poll interval). The log
        # is allowed to sit a bit over 2016 lines between trims; /api/history only ever reads
        # -Tail 288, so that has no effect on it either way.
        if ($script:metricAppendCount % 288 -eq 0) {
            $lines = @(Get-Content $LogFile -Encoding UTF8)
            if ($lines.Count -gt 2016) { $lines[-2016..-1] | Set-Content $LogFile -Encoding UTF8 }
        }
    }

    function CollectMetrics {
        try {
            Sync-PlaytimeToActiveWorld
            $m = Invoke-RestMethod -Uri "$PalApiBase/v1/api/metrics" -Method GET -Headers (Get-PalHeaders) -EA Stop
            $p = Invoke-RestMethod -Uri "$PalApiBase/v1/api/players" -Method GET -Headers (Get-PalHeaders) -EA Stop
            $playerList   = if ($p.players) { @($p.players) } elseif ($p.Players) { @($p.Players) } else { @() }
            # A player's in-game "name" can come back blank for a character that hasn't set
            # one yet (observed 2026-07-09/10: a brand-new world's first ~3hr session went
            # completely untracked because /players had an entry but $_.name was empty, so it
            # never hit $currentNames/$script:playtime -- and the empty-/players resilience
            # fallback below didn't cover it either, since the list wasn't empty). Fall back to
            # accountName (Steam/Epic account name, always populated per docs.palworldgame.com).
            $currentNames = @($playerList | ForEach-Object { if ($_.name) { $_.name } elseif ($_.accountName) { $_.accountName } } | Where-Object { $_ })
            $pings        = @($playerList | Where-Object { $null -ne $_.ping } | ForEach-Object { $_.ping })
            $avgPing      = if ($pings.Count) { [math]::Round(($pings | Measure-Object -Average).Average,1) } else { 0 }
            $fps   = if ($null -ne $m.serverFps)        { $m.serverFps        } elseif ($null -ne $m.fps)            { $m.fps }            else { 0 }
            $pcnt  = if ($null -ne $m.currentplayernum) { $m.currentplayernum } elseif ($null -ne $m.currentPlayers) { $m.currentPlayers }  else { $playerList.Count }
            $bases = if ($null -ne $m.basecampnum)      { $m.basecampnum      } elseif ($null -ne $m.basecampcount)  { $m.basecampcount }   elseif ($null -ne $m.basecamps) { $m.basecamps } else { 0 }
            $days  = if ($null -ne $m.days)             { [int]$m.days }        else { 0 }
            $ft    = if ($null -ne $m.serverframetime)  { [math]::Round([double]$m.serverframetime,2) } elseif ($null -ne $m.frametime) { [math]::Round([double]$m.frametime,2) } else { 0 }
            $entry = [ordered]@{ ts=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); players=[int]$pcnt;
                                  fps=[math]::Round([double]$fps,1); avgPing=$avgPing;
                                  bases=[int]$bases; days=$days; frametime=$ft }
            Append-Metric $entry

            # PalWorld's /v1/api/players endpoint can intermittently come back empty for a
            # few polls in a row even while /v1/api/metrics still correctly reports someone
            # connected (observed 2026-07-01 ~21:50-22:15: 5 straight polls logged players:1
            # here while /players returned nothing, silently freezing the tracker for the
            # rest of that session even though the player never disconnected). When the two
            # disagree like that, keep crediting whoever was already being tracked online
            # instead of losing the time -- but only to EXTEND an existing session (never
            # invent one without a name), and only while the metrics count still matches, so
            # a real disconnect (metrics count actually dropping) still stops the credit.
            if ($playerList.Count -eq 0 -and [int]$pcnt -gt 0 -and $script:onlinePlayers.Count -eq [int]$pcnt) {
                foreach ($name in @($script:onlinePlayers.Keys)) {
                    if (-not $script:playtime.ContainsKey($name)) { continue }
                    $script:playtime[$name].totalSeconds += $PollInterval
                    $script:playtime[$name].lastSeen      = $entry.ts
                }
                Save-Playtime
                try {
                    $line = "[{0:yyyy-MM-dd HH:mm:ss}] /players empty while metrics reported {1} online - credited {2}`n" -f (Get-Date), $pcnt, ($script:onlinePlayers.Keys -join ',')
                    Add-Content -LiteralPath "$ServerDir\playtime-glitch.log" -Value $line -Encoding UTF8
                } catch {}
                return
            }

            foreach ($pl in $playerList) {
                $name = if ($pl.name) { $pl.name } elseif ($pl.accountName) { $pl.accountName } else { $null }
                if (-not $name) {
                    try {
                        $line = "[{0:yyyy-MM-dd HH:mm:ss}] player entry with no name/accountName, skipped - raw: {1}`n" -f (Get-Date), (ConvertTo-Json $pl -Depth 2 -Compress)
                        Add-Content -LiteralPath "$ServerDir\playtime-glitch.log" -Value $line -Encoding UTF8
                    } catch {}
                    continue
                }
                if (-not $script:playtime.ContainsKey($name)) {
                    $script:playtime[$name] = @{ totalSeconds=0L; sessions=0; lastSeen=''; avgPing=0.0; sampleCount=0; steamid='' }
                }
                if (-not $script:onlinePlayers.ContainsKey($name)) {
                    $script:onlinePlayers[$name] = Get-Date
                    $script:playtime[$name].sessions++
                }
                $script:playtime[$name].totalSeconds += $PollInterval
                $script:playtime[$name].lastSeen      = $entry.ts
                # PalWorld's REST API player fields are playerId/userId (docs.palworldgame.com),
                # not "steamid"/"playeruid" -- neither of those ever matched, so this was always
                # blank. Kept steamid as the stored field name (already in playtime-log-*.json)
                # to avoid a schema migration, just fixed what populates it.
                $sid = if ($pl.playerId) { [string]$pl.playerId } elseif ($pl.userId) { [string]$pl.userId } else { '' }
                if ($sid) { $script:playtime[$name].steamid = $sid }
                $ping = if ($null -ne $pl.ping) { [double]$pl.ping } else { $null }
                if ($null -ne $ping) {
                    $sc = $script:playtime[$name].sampleCount
                    $script:playtime[$name].avgPing = ($script:playtime[$name].avgPing * $sc + $ping) / ($sc + 1)
                    $script:playtime[$name].sampleCount++
                }
            }
            foreach ($name in @($script:onlinePlayers.Keys)) {
                if ($name -notin $currentNames) { $script:onlinePlayers.Remove($name) }
            }
            Save-Playtime
        } catch {}
    }

    $ProxyRoutes = @{
        "GET /api/info"      = @{ PalPath="info";     Method="GET"  }
        "GET /api/metrics"   = @{ PalPath="metrics";  Method="GET"  }
        "GET /api/players"   = @{ PalPath="players";  Method="GET"  }
        "GET /api/settings"  = @{ PalPath="settings"; Method="GET"  }
        "POST /api/announce" = @{ PalPath="announce"; Method="POST" }
        "POST /api/kick"     = @{ PalPath="kick";     Method="POST" }
        "POST /api/ban"      = @{ PalPath="ban";      Method="POST" }
        "POST /api/unban"    = @{ PalPath="unban";    Method="POST" }
        "POST /api/save"     = @{ PalPath="save";     Method="POST" }
        "POST /api/shutdown" = @{ PalPath="shutdown"; Method="POST" }
        "POST /api/stop"     = @{ PalPath="stop";     Method="POST" }
    }

    # ── HTML Page ─────────────────────────────────────────────────────────────

    # Read from dashboard.html (extracted verbatim from this here-string) rather than
    # inline, for syntax highlighting and reviewable diffs; gen_public_site.ps1 reads the
    # same file directly instead of extracting it via string markers.
    $HtmlPage = [System.IO.File]::ReadAllText((Join-Path $ServerDir 'dashboard.html'), [System.Text.UTF8Encoding]::new($false))
    $script:htmlMtime = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $ServerDir 'dashboard.html'))
    # Precompute once at startup rather than per-request -- ASCII HTML gzips ~5:1, and this
    # is the single biggest payload the dashboard serves (~430KB uncompressed).
    $script:htmlGzip = Get-GzipBytes $HtmlPage

    # ── State ─────────────────────────────────────────────────────────────────
    $script:playtimeGuid  = $null
    $script:PlaytimeFile  = $null
    $script:playtime      = @{}
    $script:onlinePlayers = @{}
    Sync-PlaytimeToActiveWorld
    $nextCollect          = [datetime]::MinValue
    $nextSync             = [datetime]::MinValue
    $nextEggCheck         = [datetime]::MinValue
    $script:lastEggStamp  = ''
    $script:metricAppendCount = 0
    $script:palSpawnRaw   = $null
    $script:palTileCache  = @{}
    $script:effigyData    = $null
    $script:palIconCache  = @{}
    $script:palIconDir    = "$ServerDir\PalAssets\Pals"

    # ── HTTP listener ──────────────────────────────────────────────────────────
    $taken = Get-NetTCPConnection -LocalPort $DashPort -State Listen -ErrorAction SilentlyContinue
    if ($taken) {
        Write-Output "Port $DashPort in use - clearing..."
        foreach ($c in @($taken)) {
            try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
        }
        Start-Sleep -Seconds 2
    }

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://+:$DashPort/")
    try { $listener.Start() }
    catch { Write-Output "ERROR: Could not start listener on port $DashPort. $($_.Exception.Message)"; exit 1 }

    Write-Output "Dashboard started: http://localhost:$DashPort"
    Start-Process "http://localhost:$DashPort"

    $asyncResult = $listener.BeginGetContext($null, $null)

    # Fire the read-only public-site DATA SYNC on the same cadence as metrics. This
    # pushes the changed per-player JSON to the R2 bucket the public Worker reads from
    # (sync_public_data.ps1). It self-gates -- does nothing unless Level.sav changed --
    # and uploads only files whose content actually changed, so it is cheap and NEVER
    # triggers a Cloudflare Pages deploy (so it can run every poll, far under the
    # 500-deploys/month cap). It runs detached so a wrangler upload never stalls this
    # dashboard listener. The static Pages "shell" (index.html/_worker.js/portraits/
    # icons/effigies/species) is deployed separately and manually via
    # deploy_public_site.ps1 only when the dashboard UI changes.
    function Trigger-PublicDeploy {
        try {
            # Manager-side gate (same pattern as Check-EggNotifications' $script:lastEggStamp):
            # skip the powershell.exe spawn entirely when the save hasn't moved since the last
            # sync that actually succeeded. sync_public_data.ps1 already no-ops internally on
            # an unchanged save, but that still cost a full process spawn every tick even while
            # idle (~2 CPU-hours/day across a day of autosave ticks with zero players). Compare
            # against sync_public_data.ps1's OWN persisted levelStamp (not a separate cache
            # here) so a failed sync still retries every tick as before -- that field only
            # advances on a real success, so a persistent failure naturally keeps comparing
            # unequal until it's fixed.
            $activeGuid = Get-ActiveGuid
            if ($activeGuid) {
                $levelSav = Join-Path (Join-Path $SaveGamesRoot $activeGuid) 'Level.sav'
                $syncState = "$ServerDir\.palbox_r2_sync_state.json"
                if ((Test-Path -LiteralPath $levelSav) -and (Test-Path -LiteralPath $syncState)) {
                    $stamp = [string]([System.IO.File]::GetLastWriteTimeUtc($levelSav).Ticks)
                    try {
                        $lastStamp = (Get-Content -LiteralPath $syncState -Raw | ConvertFrom-Json).levelStamp
                        if ($stamp -eq [string]$lastStamp) { return }
                    } catch {}
                }
            }

            $syncScript = "$ServerDir\sync_public_data.ps1"
            if (Test-Path $syncScript) {
                # -Root is passed explicitly rather than left to sync_public_data.ps1's own
                # $PSScriptRoot default: root-caused 2026-07-01 that $PSScriptRoot comes back
                # EMPTY when the script is launched this way (Start-Process -File, hidden, from
                # inside this Manager's background Start-Job) -- which made every unforced
                # auto-sync crash immediately, silently, on every single poll, for as long as
                # this has existed. $ServerDir is always correct here (threaded in via the
                # Dashboard job's own -ArgumentList), so passing it removes the dependency on
                # $PSScriptRoot resolving correctly in this specific nested-process context.
                Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $syncScript, '-Root', $ServerDir) `
                    -WindowStyle Hidden
            }
        } catch {
            # This previously swallowed everything silently, so a launch-level failure here
            # (as opposed to a failure inside sync_public_data.ps1 itself, which now logs on
            # its own) could go unnoticed indefinitely -- log it instead.
            try {
                $entry = "[{0:yyyy-MM-dd HH:mm:ss}] Trigger-PublicDeploy FAILED to launch: {1}`n" -f (Get-Date), $_.Exception.Message
                Add-Content -LiteralPath "$ServerDir\sync_public_data.log" -Value $entry -Encoding UTF8
            } catch {}
        }
    }

    # Notify each opted-in player when their eggs become ready to hatch. Runs on a fast
    # (30s) cadence, but only re-parses when Level.sav has actually changed since the last
    # check ($script:lastEggStamp) -- so at most one egg-reader run per save write (~60s
    # while the server is up), and nothing while the world is idle.
    #
    # TWO delivery channels, deliberately decoupled so you're notified whether or not you're
    # in-game (PalWorld has no DM; the only chat primitive is the server-wide announce):
    #   * Dashboard banner (Add-ServerMessage): fires for ANY enabled player whose ready
    #     count rose -- so it shows on the admin/public dashboard (incl. your phone) even
    #     when you are NOT logged into the game.
    #   * In-game broadcast (/v1/api/announce): only when that player is actually online, so
    #     it never spams in-game chat about a player who isn't there.
    # The per-player high-water ready count (.egg_notify_state.json) makes each newly-ready
    # egg alert once (not every cycle) and re-arms after you hatch/collect some.
    function Check-EggNotifications {
        try {
            $cfg = Get-EggNotifyConfig
            $enabled = @($cfg.Keys | Where-Object { $cfg[$_].enabled })
            if (-not $enabled) { return }

            # Cheap gate: do real work only when the world save advanced since the last check.
            $activeGuid = Get-ActiveGuid
            if (-not $activeGuid) { return }
            $saveDir  = Join-Path $SaveGamesRoot $activeGuid
            $levelSav = Join-Path $saveDir 'Level.sav'
            if (-not (Test-Path -LiteralPath $levelSav)) { return }
            $stamp = [string]([System.IO.File]::GetLastWriteTimeUtc($levelSav).Ticks)
            if ($stamp -eq $script:lastEggStamp) { return }

            $rawJson = & python "$ServerDir\pal_egg_reader.py" $saveDir 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $rawJson) { return }   # leave stamp unset -> retry next tick
            $data = ($rawJson -join '') | ConvertFrom-Json

            # Ready (fully incubated) eggs per owner prefix.
            $readyByPrefix = @{}
            foreach ($egg in @($data.eggs)) {
                if (-not $egg.ready) { continue }
                $pfx = ([string]$egg.owner).ToUpper()
                if (-not $pfx) { continue }
                if ($readyByPrefix.ContainsKey($pfx)) { $readyByPrefix[$pfx]++ } else { $readyByPrefix[$pfx] = 1 }
            }

            # Who is online (best effort), by uppercase 8-hex UID prefix -- gates ONLY the
            # in-game broadcast, not the banner. If the call fails, no broadcast (but the
            # banner still fires).
            $onlinePrefixes = @{}
            try {
                $online = Invoke-RestMethod -Uri "$PalApiBase/v1/api/players" -Method GET -Headers (Get-PalHeaders) -EA Stop
                $opl = if ($online.players) { @($online.players) } elseif ($online.Players) { @($online.Players) } else { @() }
                foreach ($op in $opl) {
                    $uid = if ($op.playerid) { [string]$op.playerid } elseif ($op.playeruid) { [string]$op.playeruid } elseif ($op.userid) { [string]$op.userid } else { '' }
                    if ($uid) { $onlinePrefixes[$uid.Replace('-', '').Substring(0, 8).ToUpper()] = $true }
                }
            } catch {}

            $state = Get-EggNotifyState
            $changed = $false
            foreach ($pfx in $enabled) {
                $ready = if ($readyByPrefix.ContainsKey($pfx)) { [int]$readyByPrefix[$pfx] } else { 0 }
                $last  = if ($state.ContainsKey($pfx)) { [int]$state[$pfx] } else { 0 }
                if ($ready -gt $last) {
                    $name = $cfg[$pfx].name; if (-not $name) { $name = 'Trainer' }
                    $word = if ($ready -eq 1) { 'egg' } else { 'eggs' }
                    $msg  = "[PalBox] $name - You have $ready $word ready to hatch!"
                    Add-ServerMessage $msg 'egg'   # dashboard banner (phone/desktop), always
                    if ($onlinePrefixes.ContainsKey($pfx)) {
                        try { Invoke-RestMethod -Uri "$PalApiBase/v1/api/announce" -Method POST -Headers (Get-PalHeaders) `
                                -Body (ConvertTo-Json @{ message = $msg }) -EA Stop | Out-Null } catch {}
                    }
                    $state[$pfx] = $ready; $changed = $true
                } elseif ($ready -lt $last) {
                    # Player hatched/collected some -> lower the mark so a later rise re-alerts.
                    $state[$pfx] = $ready; $changed = $true
                }
            }
            if ($changed) { Save-EggNotifyState $state }
            $script:lastEggStamp = $stamp   # mark this save processed only after a successful run
        } catch {}
    }

    try {
        while ($listener.IsListening) {

            if ((Get-Date) -ge $nextCollect) {
                CollectMetrics
                $nextCollect = (Get-Date).AddSeconds($PollInterval)
                # Release the cached ~34MB Paldex JSON once its 24h TTL (see /api/palspawn)
                # has passed, rather than leaving it resident until the next spawn-map
                # request happens to overwrite it -- if the Map tab isn't in active use for a
                # while, this frees the memory instead of holding stale data indefinitely.
                if ($script:palSpawnRaw -and $script:palSpawnFetched -and (((Get-Date) - $script:palSpawnFetched).TotalHours -ge 24)) {
                    $script:palSpawnRaw = $null
                }
            }

            # Egg-ready notifications on a fast cadence so an egg that becomes ready is
            # surfaced within ~30s. Self-gates on Level.sav so it only parses on a real save
            # change (~once/min while up), and is a no-op while the world is idle.
            if ((Get-Date) -ge $nextEggCheck) {
                Check-EggNotifications
                $nextEggCheck = (Get-Date).AddSeconds($EggCheckInterval)
            }

            # Public-data R2 sync on its own faster cadence so the dashboards refresh ~every
            # minute, decoupled from metrics collection (keeping that at 300s preserves the
            # history charts' 24h window -- 60s metrics would shrink it ~5x). The sync
            # self-gates on Level.sav changes, so a cycle with no new save data is cheap.
            if ((Get-Date) -ge $nextSync) {
                Trigger-PublicDeploy
                $nextSync = (Get-Date).AddSeconds($SyncInterval)
            }

            if (-not $asyncResult.AsyncWaitHandle.WaitOne(1000)) { continue }
            if (-not $listener.IsListening) { break }

            $ctx = try { $listener.EndGetContext($asyncResult) } catch { $null }
            if (-not $ctx) { break }
            $asyncResult = $listener.BeginGetContext($null, $null)

            $req      = $ctx.Request
            $res      = $ctx.Response
            $path     = $req.Url.AbsolutePath
            $method   = $req.HttpMethod
            $routeKey = "$method $path"

            $reqBody = $null
            if ($req.HasEntityBody) {
                $reader  = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                $reqBody = $reader.ReadToEnd()
                $reader.Close()
            }

            switch ($true) {

                ($path -eq '/' -or $path -eq '/index.html') {
                    Send-CachedResponse -Response $res -Request $req -ContentType "text/html; charset=utf-8" -Body $HtmlPage -GzipBytes $script:htmlGzip -Mtime $script:htmlMtime
                    break
                }

                # Icon/portrait routes are the highest-frequency GETs (every pal card
                # loads one); placed early in this switch so they don't fall through
                # every other route's condition check first, unlike their previous
                # spot much further down.
                ($path -like '/icons/*' -and $method -eq 'GET') {
                    # Bundled work/element suitability icons (downloaded from paldb, whose
                    # CDN blocks hotlinking). The public site serves these statically; here
                    # we serve our local copies so the admin dashboard matches.
                    #
                    # Cache-Control here previously had NO validator (no ETag/Last-Modified) on
                    # top of a blind 24h max-age -- so once a browser cached an icon URL, it
                    # wouldn't even ask the server again for a full day, with zero way to detect
                    # a changed file. That's bad enough on its own, but these <img> tags are
                    # loading="lazy" and sit inside the pal-detail popup, which isn't opened
                    # during the initial page load -- so Chrome's hard-reload cache bypass
                    # (which only covers resources loaded as part of that initial navigation)
                    # never touches them either. Net effect: a regenerated icon (e.g. when the
                    # elem_*.webp assets were swapped from plain squares to the wider banner
                    # art) could silently keep showing the OLD image in an existing browser
                    # profile for up to 24h with no hard-refresh able to fix it. Fix: shorten
                    # max-age so staleness is bounded to minutes instead of a day, and add a
                    # Last-Modified validator + If-Modified-Since/304 handling so repeat checks
                    # after that are cheap when the file hasn't actually changed.
                    $res.KeepAlive = $false
                    $iconBytes = $null
                    $iconMtime = $null
                    try {
                        $fname = [System.IO.Path]::GetFileName($path)   # strips any traversal
                        # work_/elem_ suitability icons (webp) + passive rank icons/frame (png).
                        if ($fname -match '^[A-Za-z0-9_]+\.(webp|png)$') {
                            $file = Join-Path "$ServerDir\pal_icons" $fname
                            if (Test-Path -LiteralPath $file) {
                                $iconMtime = [System.IO.File]::GetLastWriteTimeUtc($file)
                                $lastModStr = $iconMtime.ToString('R')
                                $ims = $req.Headers['If-Modified-Since']
                                $imsDate = [datetime]::MinValue
                                if ($ims -and [datetime]::TryParse($ims, [ref]$imsDate)) {
                                    if ($iconMtime -le $imsDate.ToUniversalTime().AddSeconds(1)) {
                                        $res.StatusCode = 304
                                        $res.AddHeader('Cache-Control', 'public, max-age=300')
                                        $res.AddHeader('Last-Modified', $lastModStr)
                                        $res.OutputStream.Close()
                                        break
                                    }
                                }
                                $iconBytes = [System.IO.File]::ReadAllBytes($file)
                            }
                        }
                    } catch {}
                    if ($iconBytes) {
                        try {
                            $res.StatusCode = 200
                            $res.ContentType = if ([System.IO.Path]::GetExtension($fname).ToLower() -eq '.png') { 'image/png' } else { 'image/webp' }
                            $res.AddHeader('Cache-Control', 'public, max-age=300')
                            if ($iconMtime) { $res.AddHeader('Last-Modified', $iconMtime.ToString('R')) }
                            $res.ContentLength64 = $iconBytes.Length
                            $res.OutputStream.Write($iconBytes, 0, $iconBytes.Length)
                        } catch {}
                    } else { try { $res.StatusCode = 404 } catch {} }
                    try { $res.OutputStream.Close() } catch {}
                    break
                }

                ($path -eq '/api/palicon' -and $method -eq 'GET') {
                    # Serve Pal portrait PNGs from the LOCAL copy in PalAssets\Pals so the
                    # dashboard no longer depends on palcalc's GitHub repo at runtime.
                    # (Refresh the local copy with: python gen_pal_assets.py)
                    $res.KeepAlive = $false
                    $iconBytes = $null
                    try {
                        $name = $req.QueryString['name']
                        if ($name) {
                            # Block path traversal: only allow a bare file name.
                            $name = $name -replace '[\\/:*?"<>|]', ''
                            if (-not $script:palIconCache.ContainsKey($name)) {
                                $file = Join-Path $script:palIconDir ($name + '.png')
                                if (Test-Path -LiteralPath $file) {
                                    $script:palIconCache[$name] = [System.IO.File]::ReadAllBytes($file)
                                } else {
                                    $script:palIconCache[$name] = $null
                                }
                            }
                            $iconBytes = $script:palIconCache[$name]
                        }
                    } catch {}
                    if ($iconBytes) {
                        try {
                            $res.StatusCode = 200
                            $res.ContentType = 'image/png'
                            $res.Headers.Add('Cache-Control', 'public, max-age=604800')
                            $res.ContentLength64 = $iconBytes.Length
                            $res.OutputStream.Write($iconBytes, 0, $iconBytes.Length)
                        } catch {}
                    } else {
                        try { $res.StatusCode = 404 } catch {}
                    }
                    try { $res.OutputStream.Close() } catch {}
                    break
                }

                ($path -eq '/api/history' -and $method -eq 'GET') {
                    try {
                        if (Test-Path $LogFile) {
                            # Each line in metrics-log.jsonl is already a compact JSON object
                            # (see Append-Metric) -- string-join into an array instead of
                            # parsing then re-serializing all 288 lines every request (576
                            # JSON conversions for data that needs none).
                            $lines = @(Get-Content $LogFile -Tail 288 -Encoding UTF8 | Where-Object { $_.Trim() })
                            $json = if ($lines.Count) { '[' + ($lines -join ',') + ']' } else { '[]' }
                        } else { $json = '[]' }
                    } catch { $json = '[]' }
                    Send-Response $res 200 "application/json" $json
                    break
                }

                ($path -eq '/api/playtime' -and $method -eq 'GET') {
                    $arr  = @($script:playtime.GetEnumerator() | ForEach-Object {
                        @{ name=$_.Key; totalSeconds=$_.Value.totalSeconds; sessions=$_.Value.sessions;
                           lastSeen=$_.Value.lastSeen; avgPing=[math]::Round($_.Value.avgPing,1);
                           steamid=$_.Value.steamid }
                    })
                    $json = if ($arr.Count) { ConvertTo-Json $arr -Depth 3 -Compress } else { '[]' }
                    Send-Response $res 200 "application/json" $json
                    break
                }

                ($path -eq '/api/file-settings' -and $method -eq 'GET') {
                    # ?slot=<id> reads that save's stored settings; no slot = live file.
                    # A slot with no stored settings is seeded from the live file
                    # (hasCustom=false) so the editor always has values to show.
                    $slotParam = $req.QueryString['slot']
                    $settingsPath = $ActiveSettingsPath
                    $hasCustom = $true
                    if ($slotParam -and (Test-SlotId $slotParam)) {
                        $sp = Join-Path (Join-Path $SaveLibraryRoot $slotParam) 'PalWorldSettings.ini'
                        if (Test-Path $sp) { $settingsPath = $sp } else { $hasCustom = $false }
                    }
                    $active   = Parse-IniSettings $settingsPath
                    $defaults = Parse-IniSettings $DefaultSettingsPath
                    $obj = @{ active = $active; defaults = $defaults; hasCustom = $hasCustom }
                    Send-Response $res 200 "application/json" (ConvertTo-Json $obj -Depth 4 -Compress)
                    break
                }

                ($path -eq '/api/file-settings' -and $method -eq 'POST') {
                    # Body: { slot:<id|null>, settings:{...} }. Editing the active save
                    # (or no slot) writes the live file AND syncs the active slot's copy
                    # so the save stays tied to it. Editing another save writes only
                    # that slot's stored settings (applied when it is loaded).
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $slotParam   = [string]$body.slot
                        # Empty slot = live file; any provided slot must be a safe id.
                        if ($slotParam -and -not (Test-SlotId $slotParam)) { throw "Invalid save id." }
                        $settingsObj = $body.settings
                        if ($null -eq $settingsObj) { throw "No settings provided." }
                        $ht = [ordered]@{}
                        foreach ($prop in $settingsObj.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }

                        $markerFile = Join-Path $SaveLibraryRoot '.active-slot'
                        $activeSlot = if (Test-Path $markerFile) { (Get-Content $markerFile -Raw -Encoding UTF8).Trim() } else { $null }

                        if (-not $slotParam -or $slotParam -eq $activeSlot) {
                            Write-IniSettings $ht $ActiveSettingsPath
                            if ($activeSlot) {
                                $asp = Join-Path $SaveLibraryRoot $activeSlot
                                if (Test-Path $asp) { Write-IniSettings $ht (Join-Path $asp 'PalWorldSettings.ini') }
                            }
                            Send-Response $res 200 "application/json" '{"status":"Saved","target":"live"}'
                        } else {
                            $slotDir = Join-Path $SaveLibraryRoot $slotParam
                            if (-not (Test-Path $slotDir)) { throw "Save not found." }
                            Write-IniSettings $ht (Join-Path $slotDir 'PalWorldSettings.ini')
                            Send-Response $res 200 "application/json" '{"status":"Saved","target":"slot"}'
                        }
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/maintenance-info' -and $method -eq 'GET') {
                    $cfg = if (Test-Path $ConfigFile) {
                        try { Get-Content $ConfigFile -Raw | ConvertFrom-Json } catch { $null }
                    } else { $null }
                    $mh  = if ($cfg -and $cfg.PSObject.Properties['maintHour'])   { [int]$cfg.maintHour   } else { 4 }
                    $mm  = if ($cfg -and $cfg.PSObject.Properties['maintMinute']) { [int]$cfg.maintMinute } else { 0 }
                    $now = Get-Date
                    $nextM = $now.Date.AddHours($mh).AddMinutes($mm)
                    if ($now -ge $nextM) { $nextM = $nextM.AddDays(1) }
                    $info = @{ nextMaint=$nextM.ToString('yyyy-MM-ddTHH:mm:ss'); skipPending=(Test-Path $SkipFlagFile); maintHour=$mh; maintMinute=$mm }
                    Send-Response $res 200 "application/json" (ConvertTo-Json $info -Compress)
                    break
                }

                ($path -eq '/api/sync-status' -and $method -eq 'GET') {
                    # Reads the R2 sync state sync_public_data.ps1 maintains -- lastSuccess/
                    # lastError there is what used to require inspecting the state file's mtime
                    # by hand to tell "healthy no-op" from "hasn't run in a week" (same blindness
                    # that let the 2026-07-02 outage run silently for ~15h). See its own comments
                    # for exactly when each field is written.
                    $info = @{ lastSuccess = $null; lastError = $null }
                    try {
                        $f = "$ServerDir\.palbox_r2_sync_state.json"
                        if (Test-Path -LiteralPath $f) {
                            $s = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
                            if ($s.PSObject.Properties['lastSuccess']) { $info.lastSuccess = $s.lastSuccess }
                            if ($s.PSObject.Properties['lastError'] -and $s.lastError) {
                                $info.lastError = @{ at = $s.lastError.at; message = $s.lastError.message }
                            }
                        }
                    } catch {}
                    Send-Response $res 200 "application/json" (ConvertTo-Json $info -Compress -Depth 4)
                    break
                }

                ($path -eq '/api/maintenance-skip' -and $method -eq 'POST') {
                    '1' | Set-Content $SkipFlagFile -Encoding UTF8
                    Send-Response $res 200 "application/json" '{"status":"Skip scheduled"}'
                    break
                }

                ($path -eq '/api/maintenance-unskip' -and $method -eq 'POST') {
                    Remove-Item $SkipFlagFile -Force -ErrorAction SilentlyContinue
                    Send-Response $res 200 "application/json" '{"status":"Skip cleared"}'
                    break
                }

                ($path -eq '/api/maintenance-time' -and $method -eq 'POST') {
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $mh   = [int]$body.hour; $mm = [int]$body.minute
                        if ($mh -lt 0 -or $mh -gt 23 -or $mm -lt 0 -or $mm -gt 59) { throw "Invalid time" }
                        @{ maintHour=$mh; maintMinute=$mm } | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
                        Send-Response $res 200 "application/json" '{"status":"Updated"}'
                    } catch {
                        Send-Response $res 400 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/start' -and $method -eq 'POST') {
                    if (Get-Process | Where-Object { $_.Name -like "*PalServer*" }) {
                        Send-Response $res 200 "application/json" '{"status":"Already running"}'
                    } else {
                        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$StartScript`""
                        Send-Response $res 200 "application/json" '{"status":"Starting server..."}'
                    }
                    break
                }

                ($path -eq '/api/maint-log' -and $method -eq 'GET') {
                    $lines = if (Test-Path $MaintLogFile) {
                        # Get-Content decorates each string with PSPath/PSProvider/etc.
                        # note properties; ConvertTo-Json serializes those decorated
                        # strings as objects ({"value":...,"PSPath":...}), which render
                        # as [object Object] in the UI. Cast to plain [string[]] so the
                        # response is a clean JSON array of strings.
                        [string[]]@(Get-Content $MaintLogFile -Tail 50 -Encoding UTF8 -ErrorAction SilentlyContinue)
                    } else { @() }
                    Send-Response $res 200 "application/json" (ConvertTo-Json $lines -Compress)
                    break
                }

                ($path -eq '/api/server-messages' -and $method -eq 'GET') {
                    # Recent server broadcasts for the dashboard chat banner (admin copy;
                    # the public site reads the mirrored R2 server-messages.json).
                    Send-Response $res 200 "application/json" (Get-ServerMessagesJson 50)
                    break
                }

                ($path -eq '/api/announce' -and $method -eq 'POST') {
                    # Explicit (ahead of the generic proxy) so a manual broadcast is also
                    # recorded into the server-message feed that drives the chat banner.
                    try {
                        $bobj = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $bmsg = [string]$bobj.message
                        Invoke-RestMethod -Uri "$PalApiBase/v1/api/announce" -Method POST -Headers (Get-PalHeaders) `
                            -Body (ConvertTo-Json @{ message = $bmsg }) -ErrorAction Stop | Out-Null
                        if ($bmsg) { Add-ServerMessage $bmsg 'broadcast' }
                        Send-Response $res 200 "application/json" '{"status":"sent"}'
                    } catch {
                        Send-Response $res 502 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($ProxyRoutes.ContainsKey($routeKey)) {
                    $route  = $ProxyRoutes[$routeKey]
                    $palUri = "$PalApiBase/v1/api/$($route.PalPath)"
                    try {
                        $result = if ($reqBody) {
                            Invoke-RestMethod -Uri $palUri -Method $route.Method -Headers (Get-PalHeaders) `
                                -Body $reqBody -ContentType "application/json" -ErrorAction Stop
                        } else {
                            Invoke-RestMethod -Uri $palUri -Method $route.Method -Headers (Get-PalHeaders) -ErrorAction Stop
                        }
                        Send-Response $res 200 "application/json" (ConvertTo-Json $result -Depth 10 -Compress)
                    } catch {
                        Send-Response $res 502 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/reboot' -and $method -eq 'POST') {
                    $params   = if ($reqBody) { $reqBody | ConvertFrom-Json -EA SilentlyContinue } else { $null }
                    $waitSecs = if ($params -and $null -ne $params.waittime) { [int]$params.waittime } else { 60 }
                    $palBase  = $PalApiBase; $adminPw = $AdminPassword; $startSc = $StartScript
                    # Capture the live settings now (the user's saved edit). The server
                    # overwrites PalWorldSettings.ini with its in-memory values on
                    # shutdown, so we re-apply this after it exits, before relaunch.
                    $setPath  = $ActiveSettingsPath
                    $setStage = if (Test-Path $setPath) { Get-Content $setPath -Raw -Encoding UTF8 } else { $null }

                    Start-Job -Name "PalReboot" -ScriptBlock {
                        param($ServerDir,$palBase,$adminPw,$startSc,$waitSecs,$setPath,$setStage)
                        function BC([string]$msg) {
                            $cred=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$adminPw"))
                            $h=@{Authorization="Basic $cred";"Content-Type"="application/json"}
                            try{Invoke-RestMethod -Uri "$palBase/v1/api/announce" -Method POST -Headers $h `
                                    -Body (ConvertTo-Json @{message=$msg})|Out-Null}catch{}
                            # Record into the banner feed (nested job: dot-source once on demand).
                            try{ if(-not (Get-Command Add-ServerMessage -EA SilentlyContinue)){ . "$ServerDir\server_messages.ps1" }; Add-ServerMessage $msg 'maintenance' }catch{}
                        }
                        BC "Server rebooting in $waitSecs seconds!"
                        $rem=$waitSecs
                        foreach ($mark in @(300,120,60,30,10,5)) {
                            if($rem-gt$mark){Start-Sleep -Seconds($rem-$mark);$rem=$mark;BC "Server rebooting in $mark seconds!"}
                        }
                        if($rem-gt 0){Start-Sleep -Seconds $rem}
                        BC "Rebooting now. Back online soon!"
                        Start-Sleep -Seconds 2
                        $cred=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$adminPw"))
                        $h=@{Authorization="Basic $cred";"Content-Type"="application/json"}
                        try{Invoke-RestMethod -Uri "$palBase/v1/api/save" -Method POST -Headers $h|Out-Null}catch{}
                        Start-Sleep -Seconds 3
                        try{Invoke-RestMethod -Uri "$palBase/v1/api/shutdown" -Method POST -Headers $h `
                                -Body(ConvertTo-Json @{waittime=10;message="Shutting down now."})|Out-Null}catch{}
                        $waited=0
                        while((Get-Process|Where-Object{$_.Name-like"*PalServer*"})-and$waited-lt 90){Start-Sleep -Seconds 3;$waited+=3}
                        # Re-apply the captured settings now that the server has exited
                        # (and finished its own clobbering write), before it starts again.
                        if($setStage){ try{[IO.File]::WriteAllText($setPath,$setStage,(New-Object Text.UTF8Encoding($false)))}catch{} }
                        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$startSc`""
                    } -ArgumentList $ServerDir,$palBase,$adminPw,$startSc,$waitSecs,$setPath,$setStage | Out-Null

                    Send-Response $res 200 "application/json" (ConvertTo-Json @{status="Reboot initiated";waittime=$waitSecs} -Compress)
                    break
                }

                ($path -eq '/api/shutdown-graceful' -and $method -eq 'POST') {
                    $params   = if ($reqBody) { $reqBody | ConvertFrom-Json -EA SilentlyContinue } else { $null }
                    $waitSecs = if ($params -and $null -ne $params.waittime) { [int]$params.waittime } else { 60 }
                    $palBase  = $PalApiBase; $adminPw = $AdminPassword
                    # Capture the live settings so the server's on-shutdown overwrite
                    # doesn't lose an edit made while it was running (re-applied after exit).
                    $setPath  = $ActiveSettingsPath
                    $setStage = if (Test-Path $setPath) { Get-Content $setPath -Raw -Encoding UTF8 } else { $null }

                    # Same graduated countdown as reboot, but the server stays off
                    # afterwards (no relaunch).
                    Start-Job -Name "PalShutdown" -ScriptBlock {
                        param($ServerDir,$palBase,$adminPw,$waitSecs,$setPath,$setStage)
                        function BC([string]$msg) {
                            $cred=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$adminPw"))
                            $h=@{Authorization="Basic $cred";"Content-Type"="application/json"}
                            try{Invoke-RestMethod -Uri "$palBase/v1/api/announce" -Method POST -Headers $h `
                                    -Body (ConvertTo-Json @{message=$msg})|Out-Null}catch{}
                            # Record into the banner feed (nested job: dot-source once on demand).
                            try{ if(-not (Get-Command Add-ServerMessage -EA SilentlyContinue)){ . "$ServerDir\server_messages.ps1" }; Add-ServerMessage $msg 'maintenance' }catch{}
                        }
                        BC "Server shutting down in $waitSecs seconds!"
                        $rem=$waitSecs
                        foreach ($mark in @(300,120,60,30,10,5)) {
                            if($rem-gt$mark){Start-Sleep -Seconds($rem-$mark);$rem=$mark;BC "Server shutting down in $mark seconds!"}
                        }
                        if($rem-gt 0){Start-Sleep -Seconds $rem}
                        BC "Shutting down now. See you next time!"
                        Start-Sleep -Seconds 2
                        $cred=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$adminPw"))
                        $h=@{Authorization="Basic $cred";"Content-Type"="application/json"}
                        try{Invoke-RestMethod -Uri "$palBase/v1/api/save" -Method POST -Headers $h|Out-Null}catch{}
                        Start-Sleep -Seconds 3
                        try{Invoke-RestMethod -Uri "$palBase/v1/api/shutdown" -Method POST -Headers $h `
                                -Body(ConvertTo-Json @{waittime=5;message="Shutting down now."})|Out-Null}catch{}
                        # Force-kill if it has not exited on its own within 90s.
                        $waited=0
                        while((Get-Process|Where-Object{$_.Name-like"*PalServer*"})-and$waited-lt 90){Start-Sleep -Seconds 3;$waited+=3}
                        if(Get-Process|Where-Object{$_.Name-like"*PalServer*"}){Get-Process|Where-Object{$_.Name-like"*PalServer*"}|Stop-Process -Force -EA SilentlyContinue}
                        # Restore the captured settings after the server has exited, so
                        # the next start uses the edited values rather than the clobbered ones.
                        if($setStage){ Start-Sleep -Seconds 2; try{[IO.File]::WriteAllText($setPath,$setStage,(New-Object Text.UTF8Encoding($false)))}catch{} }
                    } -ArgumentList $ServerDir,$palBase,$adminPw,$waitSecs,$setPath,$setStage | Out-Null

                    Send-Response $res 200 "application/json" (ConvertTo-Json @{status="Shutdown initiated";waittime=$waitSecs} -Compress)
                    break
                }

                ($path -eq '/api/saves' -and $method -eq 'GET') {
                    try {
                        Send-Response $res 200 "application/json" (ConvertTo-Json (Get-SaveList) -Depth 5 -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/save-capture' -and $method -eq 'POST') {
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $name = [string]$body.name
                        if (-not $name.Trim()) { throw "A name is required." }
                        if (-not (Get-ActiveGuid)) { throw "No active world found to copy." }
                        # Force a save first so the copy reflects current progress.
                        if (Get-Process | Where-Object { $_.Name -like "*PalServer*" }) {
                            try { Invoke-RestMethod -Uri "$PalApiBase/v1/api/save" -Method POST -Headers (Get-PalHeaders) -EA Stop | Out-Null; Start-Sleep -Seconds 2 } catch {}
                        }
                        $id = Save-WorldToLibrary $name.Trim() ([string]$body.note) $false
                        if (-not $id) { throw "Copy failed - world files not found." }
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ status="Saved to library"; id=$id; name=$name.Trim() } -Compress)
                    } catch {
                        Send-Response $res 400 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/save-new' -and $method -eq 'POST') {
                    try {
                        $body    = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $name    = [string]$body.name
                        $restart = [bool]$body.restart
                        if (-not $name.Trim()) { throw "A name is required." }

                        if (-not (Stop-PalServerWait)) { throw "Could not stop the server - aborted, no files changed." }

                        # Back up the current world so creating a new one never loses it.
                        # Tag the backup with the save it came from (the current active slot).
                        $markerFile = Join-Path $SaveLibraryRoot '.active-slot'
                        $prevActive = if (Test-Path $markerFile) { (Get-Content $markerFile -Raw -Encoding UTF8).Trim() } else { '' }
                        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
                        Save-WorldToLibrary "Auto-backup $stamp" "Snapshot taken before creating new world '$($name.Trim())'" $true $prevActive | Out-Null

                        # A GUID with no existing folder = the server generates a fresh
                        # empty world there on next start. Register the slot as 'pending';
                        # Get-SaveList captures the generated world into the library once
                        # the server has created it.
                        $newGuid = [guid]::NewGuid().ToString('N').ToUpper()
                        $id      = New-SlotId $name.Trim()
                        $slotDir = Join-Path $SaveLibraryRoot $id
                        Write-SlotMeta $slotDir ([ordered]@{ name=$name.Trim(); guid=$newGuid; created=(Get-Date -Format o); note=[string]$body.note; auto=$false; pending=$true })
                        # The world generates with the current live settings, so tie a
                        # copy to the new save from the start.
                        if (Test-Path $ActiveSettingsPath) { Copy-Item $ActiveSettingsPath (Join-Path $slotDir 'PalWorldSettings.ini') -Force }
                        Set-ActiveGuid $newGuid
                        Sync-PlaytimeToActiveWorld
                        Set-Content (Join-Path $SaveLibraryRoot '.active-slot') $id -NoNewline -Encoding UTF8

                        $restarted = $false
                        if ($restart) {
                            Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$StartScript`""
                            $restarted = $true
                        }
                        $msg = if ($restarted) { "Created '$($name.Trim())' - server starting on the new world." } else { "Created '$($name.Trim())' - it will generate next time you start the server." }
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ status=$msg; id=$id; guid=$newGuid; restarted=$restarted } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/save-activate' -and $method -eq 'POST') {
                    try {
                        $body    = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $slotId  = [string]$body.slot
                        $restart = [bool]$body.restart
                        if (-not (Test-SlotId $slotId)) { throw "Save not found." }
                        $slotDir = Join-Path $SaveLibraryRoot $slotId
                        if (-not (Test-Path $slotDir)) { throw "Save not found." }
                        $meta  = Read-SlotMeta $slotDir
                        $world = Get-SlotWorldDir $slotDir $meta
                        if (-not $world.guid -or -not (Test-Path (Join-Path $world.dir 'Level.sav'))) { throw "Save has no world data." }

                        if (-not (Stop-PalServerWait)) { throw "Could not stop the server - aborted, no files changed." }

                        # Snapshot the current live world so progress is never lost
                        # and the previous save can be restored from the library. Tag it
                        # with the save it came from (the current active slot).
                        $markerFile = Join-Path $SaveLibraryRoot '.active-slot'
                        $prevActive = if (Test-Path $markerFile) { (Get-Content $markerFile -Raw -Encoding UTF8).Trim() } else { '' }
                        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
                        Save-WorldToLibrary "Auto-backup $stamp" "Snapshot taken before loading '$($meta.name)'" $true $prevActive | Out-Null

                        # Mirror the chosen world into the live location and point
                        # the server at it. /MIR only affects this GUID's folder;
                        # the library copy is left untouched (copy, not move).
                        $liveTarget = Join-Path $SaveGamesRoot $world.guid
                        if (-not (Copy-WorldTree $world.dir $liveTarget -Mirror)) { throw "Copy into server failed." }
                        # Swap in this save's settings if it has them; otherwise the
                        # current live settings are left in place.
                        $slotSettings = Join-Path $slotDir 'PalWorldSettings.ini'
                        if (Test-Path $slotSettings) { Copy-Item $slotSettings $ActiveSettingsPath -Force }
                        Set-ActiveGuid $world.guid
                        Sync-PlaytimeToActiveWorld
                        Set-Content (Join-Path $SaveLibraryRoot '.active-slot') $slotId -NoNewline -Encoding UTF8

                        $restarted = $false
                        if ($restart) {
                            Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$StartScript`""
                            $restarted = $true
                        }
                        $msg = if ($restarted) { "Loaded '$($meta.name)' - server restarting." } else { "Loaded '$($meta.name)' - server is stopped." }
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ status=$msg; restarted=$restarted } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/save-rename' -and $method -eq 'POST') {
                    try {
                        $body    = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $slotId  = [string]$body.slot
                        $newName = [string]$body.name
                        if (-not $newName.Trim()) { throw "Name cannot be empty." }
                        if (-not (Test-SlotId $slotId)) { throw "Save not found." }
                        $slotDir = Join-Path $SaveLibraryRoot $slotId
                        if (-not (Test-Path $slotDir)) { throw "Save not found." }
                        $meta = Read-SlotMeta $slotDir
                        $meta.name = $newName.Trim()
                        Write-SlotMeta $slotDir $meta
                        Send-Response $res 200 "application/json" '{"status":"Renamed"}'
                    } catch {
                        Send-Response $res 400 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/save-delete' -and $method -eq 'POST') {
                    try {
                        $body   = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $slotId = [string]$body.slot
                        if (-not (Test-SlotId $slotId)) { throw "Save not found." }
                        $slotDir = Join-Path $SaveLibraryRoot $slotId
                        if (-not (Test-Path $slotDir)) { throw "Save not found." }
                        $markerFile = Join-Path $SaveLibraryRoot '.active-slot'
                        $activeSlot = if (Test-Path $markerFile) { (Get-Content $markerFile -Raw -Encoding UTF8).Trim() } else { $null }
                        if ($slotId -eq $activeSlot) { throw "Cannot delete the active save - switch to another save first." }
                        Remove-Item $slotDir -Recurse -Force
                        Send-Response $res 200 "application/json" '{"status":"Deleted"}'
                    } catch {
                        Send-Response $res 400 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/paldeck' -and $method -eq 'GET') {
                    try {
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "paldeck:$activeGuid" (Join-Path $saveDir 'Level.sav') {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        $data = $rawJson | ConvertFrom-Json
                        # Build GUID->name from playtime steamid (populated when players connect)
                        $guidToName = @{}
                        foreach ($entry in $script:playtime.GetEnumerator()) {
                            $sid = $entry.Value.steamid
                            if ($sid) { $guidToName[$sid.ToUpper()] = $entry.Key }
                        }
                        # Also try live REST API for online players
                        try {
                            $online = Invoke-RestMethod -Uri "$PalApiBase/v1/api/players" -Method GET -Headers (Get-PalHeaders) -EA Stop
                            $onlinePlayers = if ($online.players) { @($online.players) } elseif ($online.Players) { @($online.Players) } else { @() }
                            foreach ($op in $onlinePlayers) {
                                $uid = if ($op.playerid) { [string]$op.playerid } `
                                       elseif ($op.playeruid) { [string]$op.playeruid } `
                                       elseif ($op.userid) { [string]$op.userid } else { '' }
                                if ($uid -and $op.name) { $guidToName[$uid.Replace('-','').ToUpper()] = [string]$op.name }
                            }
                        } catch {}
                        $outPlayers = @($data.players | ForEach-Object {
                            $guid = [string]$_.guid
                            $pyName = if ($_.PSObject.Properties['name'] -and $_.name) { [string]$_.name } else { $guid.Substring(0,8) }
                            $name = if ($guidToName.ContainsKey($guid.ToUpper())) { $guidToName[$guid.ToUpper()] } else { $pyName }
                            $entry = [ordered]@{ guid=$guid; name=$name; total=[int]$_.tribeCaptureCount; counts=$_.counts }
                            if ($_.PSObject.Properties['error']) { $entry.error = [string]$_.error }
                            $entry
                        })
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ players=$outPlayers } -Compress -Depth 5)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-locations' -and $method -eq 'GET') {
                    # Live player world position (Translation/Rotation from each player's own
                    # save, via pal_team_reader.py's lightweight "locations" mode -- skips the
                    # full Level.sav Pal parse /api/pals does). Optional ?guid= scopes to one
                    # player (used by the public site's "just me" view); omitted returns
                    # everyone, for the admin dashboard's Map tab.
                    try {
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $guidParam = $req.QueryString['guid']
                        $cacheKey = "locations:${activeGuid}:" + $(if ($guidParam) { $guidParam } else { 'ALL' })
                        $rawJson = Get-CachedReaderOutput $cacheKey (Join-Path $saveDir 'Level.sav') {
                            if ($guidParam) {
                                $j = & python "$ServerDir\pal_team_reader.py" $saveDir locations $guidParam 2>$null
                            } else {
                                $j = & python "$ServerDir\pal_team_reader.py" $saveDir locations 2>$null
                            }
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_team_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        $data = $rawJson | ConvertFrom-Json

                        # Same name-resolution as /api/paldeck: playtime steamid map, then live
                        # REST API for anyone currently online.
                        $guidToName = @{}
                        foreach ($entry in $script:playtime.GetEnumerator()) {
                            $sid = $entry.Value.steamid
                            if ($sid) { $guidToName[$sid.ToUpper()] = $entry.Key }
                        }
                        try {
                            $online = Invoke-RestMethod -Uri "$PalApiBase/v1/api/players" -Method GET -Headers (Get-PalHeaders) -EA Stop
                            $onlinePlayers = if ($online.players) { @($online.players) } elseif ($online.Players) { @($online.Players) } else { @() }
                            foreach ($op in $onlinePlayers) {
                                $uid = if ($op.playerid) { [string]$op.playerid } `
                                       elseif ($op.playeruid) { [string]$op.playeruid } `
                                       elseif ($op.userid) { [string]$op.userid } else { '' }
                                if ($uid -and $op.name) { $guidToName[$uid.Replace('-','').ToUpper()] = [string]$op.name }
                            }
                        } catch {}

                        $outPlayers = @($data.players | ForEach-Object {
                            $g = [string]$_.guid
                            $name = if ($guidToName.ContainsKey($g.ToUpper())) { $guidToName[$g.ToUpper()] } else { $g.Substring(0,8) }
                            $entry = [ordered]@{ guid=$g; name=$name; x=$_.x; y=$_.y; z=$_.z; yawDeg=$_.yawDeg }
                            if ($_.PSObject.Properties['error']) { $entry.error = [string]$_.error }
                            $entry
                        })
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ players=$outPlayers } -Compress -Depth 5)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/pals' -and $method -eq 'GET') {
                    try {
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "pals:$activeGuid" (Join-Path $saveDir 'Level.sav') {
                            $j = & python "$ServerDir\pal_team_reader.py" $saveDir 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_team_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        $data = $rawJson | ConvertFrom-Json

                        # Prefer richer display names (live REST / accumulated playtime)
                        # over the in-save NickName, keyed by the 8-hex UID prefix.
                        $prefixToName = @{}
                        foreach ($entry in $script:playtime.GetEnumerator()) {
                            $sid = $entry.Value.steamid
                            if ($sid) { $prefixToName[$sid.Replace('-','').Substring(0,8).ToUpper()] = $entry.Key }
                        }
                        try {
                            $online = Invoke-RestMethod -Uri "$PalApiBase/v1/api/players" -Method GET -Headers (Get-PalHeaders) -EA Stop
                            $onlinePlayers = if ($online.players) { @($online.players) } elseif ($online.Players) { @($online.Players) } else { @() }
                            foreach ($op in $onlinePlayers) {
                                $uid = if ($op.playerid) { [string]$op.playerid } elseif ($op.playeruid) { [string]$op.playeruid } elseif ($op.userid) { [string]$op.userid } else { '' }
                                if ($uid -and $op.name) { $prefixToName[$uid.Replace('-','').Substring(0,8).ToUpper()] = [string]$op.name }
                            }
                        } catch {}
                        foreach ($pl in @($data.players)) {
                            $pfx = [string]$pl.prefix
                            if ($pfx -and $prefixToName.ContainsKey($pfx.ToUpper())) { $pl.name = $prefixToName[$pfx.ToUpper()] }
                        }

                        Send-Response $res 200 "application/json" (ConvertTo-Json $data -Depth 8 -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/eggs' -and $method -eq 'GET') {
                    try {
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "eggs:$activeGuid" (Join-Path $saveDir 'Level.sav') {
                            $j = & python "$ServerDir\pal_egg_reader.py" $saveDir 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_egg_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        $data = $rawJson | ConvertFrom-Json

                        # Resolve owner prefix -> display name (same source as /api/pals).
                        $prefixToName = @{}
                        foreach ($entry in $script:playtime.GetEnumerator()) {
                            $sid = $entry.Value.steamid
                            if ($sid) { $prefixToName[$sid.Replace('-','').Substring(0,8).ToUpper()] = $entry.Key }
                        }
                        foreach ($egg in @($data.eggs)) {
                            $pfx = [string]$egg.owner
                            if ($pfx -and $prefixToName.ContainsKey($pfx.ToUpper())) {
                                $egg | Add-Member -NotePropertyName ownerName -NotePropertyValue $prefixToName[$pfx.ToUpper()] -Force
                            }
                        }

                        # Full known-player roster (prefix -> name) so the Eggs owner filter
                        # keeps every player even when they currently have zero eggs.
                        $owners = @()
                        foreach ($kv in $prefixToName.GetEnumerator()) {
                            $owners += [ordered]@{ prefix = $kv.Key; name = $kv.Value }
                        }
                        $data | Add-Member -NotePropertyName owners -NotePropertyValue $owners -Force

                        Send-Response $res 200 "application/json" (ConvertTo-Json $data -Depth 8 -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/egg-notify' -and $method -eq 'GET') {
                    # Admin-only opt-in map for in-game egg-ready alerts. Not exposed on the
                    # public site (this route lives only here; the toggle UI is in the
                    # generator-stripped #view-dashboard).
                    $cfg = Get-EggNotifyConfig
                    $out = if ($cfg.Count) { ConvertTo-Json $cfg -Depth 4 -Compress } else { '{}' }
                    Send-Response $res 200 "application/json" $out
                    break
                }

                ($path -eq '/api/egg-notify' -and $method -eq 'POST') {
                    # Body: { prefix:<8-hex>, name:<display>, enabled:<bool> }. Upserts one
                    # player's opt-in. The 8-hex guard also keeps junk keys out of the file.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $pfx = ([string]$body.prefix).ToUpper()
                        if ($pfx -notmatch '^[0-9A-F]{8}$') { throw "Invalid player prefix." }
                        $cfg = Get-EggNotifyConfig
                        $cfg[$pfx] = @{ enabled = [bool]$body.enabled; name = [string]$body.name }
                        Save-EggNotifyConfig $cfg
                        Send-Response $res 200 "application/json" '{"status":"Saved"}'
                    } catch {
                        Send-Response $res 400 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/palmaptile' -and $method -eq 'GET') {
                    # Proxy paldb.cc map tiles -- Referer must be set server-side,
                    # browsers sending from localhost would get 403 on z2+ tiles.
                    $res.KeepAlive = $false
                    $tileBytes = $null
                    try {
                        $tz = $req.QueryString['z']
                        $tx = $req.QueryString['x']
                        $ty = $req.QueryString['y']
                        if ($tz -and $tx -and $ty) {
                            $cacheKey = "${tz}_${tx}_${ty}"
                            # Crude cap: this cache never evicted anything, so panning/zooming
                            # around the map over a long enough uptime grows it unbounded.
                            # Full clear (not per-entry LRU) once it gets large -- simple, and
                            # tiles are cheap to refetch from paldb's CDN if actually revisited.
                            if ($script:palTileCache.Count -ge 2000) { $script:palTileCache = @{} }
                            if (-not $script:palTileCache.ContainsKey($cacheKey)) {
                                try {
                                    $wreq = [System.Net.HttpWebRequest]::Create("https://cdn.paldb.cc/image/map7/z${tz}x${tx}y${ty}.webp")
                                    $wreq.UserAgent = 'Mozilla/5.0'
                                    $wreq.Referer   = 'https://paldb.cc/'
                                    $wreq.Timeout   = 8000
                                    $wres = $wreq.GetResponse()
                                    $ms = New-Object System.IO.MemoryStream
                                    $wres.GetResponseStream().CopyTo($ms)
                                    $wres.Close()
                                    $script:palTileCache[$cacheKey] = $ms.ToArray()
                                } catch { $script:palTileCache[$cacheKey] = $null }
                            }
                            $tileBytes = $script:palTileCache[$cacheKey]
                        }
                    } catch {}
                    # Write response in its own try so a client disconnect can't crash the handler
                    if ($tileBytes) {
                        try {
                            $res.StatusCode = 200
                            $res.ContentType = 'image/webp'
                            $res.ContentLength64 = $tileBytes.Length
                            $res.OutputStream.Write($tileBytes, 0, $tileBytes.Length)
                        } catch {}
                    } else {
                        try { $res.StatusCode = 404 } catch {}
                    }
                    try { $res.OutputStream.Close() } catch {}
                    break
                }

                ($path -eq '/api/palspawn' -and $method -eq 'GET') {
                    try {
                        $pal = $req.QueryString['pal']
                        if (-not $pal) { throw 'Missing pal parameter' }

                        # Cache the 17MB Paldex in memory but refresh it daily -- without a
                        # TTL it went stale until the Manager was restarted (the public
                        # Worker already edge-caches this with a 24h max-age).
                        $spawnFresh = $script:palSpawnRaw -and $script:palSpawnFetched -and (((Get-Date) - $script:palSpawnFetched).TotalHours -lt 24)
                        if (-not $spawnFresh) {
                            $wc = New-Object System.Net.WebClient
                            $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
                            $wc.Headers.Add('Referer', 'https://paldb.cc/')
                            $script:palSpawnRaw = $wc.DownloadString('https://paldb.cc/DataTable/UI/DT_PaldexDistributionData.json')
                            $script:palSpawnFetched = Get-Date
                        }

                        $escaped = [regex]::Escape($pal)
                        $m = [regex]::Match($script:palSpawnRaw, '"' + $escaped + '"\s*:\s*\{', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                        if (-not $m.Success) {
                            Send-Response $res 404 'application/json' '{"error":"not found"}'
                        } else {
                            $start = $m.Index + $m.Length - 1
                            $depth = 0; $end = $start
                            for ($i = $start; $i -lt $script:palSpawnRaw.Length; $i++) {
                                $c = $script:palSpawnRaw[$i]
                                if     ($c -eq '{') { $depth++ }
                                elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
                            }
                            $palJson = $script:palSpawnRaw.Substring($start, $end - $start + 1)
                            Send-Response $res 200 'application/json' $palJson
                        }
                    } catch {
                        Send-Response $res 500 'application/json' (ConvertTo-Json @{ error = $_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/effigies' -and $method -eq 'GET') {
                    try {
                        # Recomputed every request (not cached) so edits to
                        # confirmed_locations.json show up immediately -- see
                        # Get-ConfirmedLocations' own mtime-based cache above. Phase 3's
                        # importer already upserted every effigies.json row into the
                        # canonical store, so this reads straight from there now instead
                        # of re-merging a live copy of effigies.json on every request (the
                        # runtime GitHub-download fallback that used to live here is gone
                        # too -- effigies.json is now purely an importer input, refreshed
                        # by gen_pal_assets.py / import_scraped_rosters.ps1, not read live).
                        $script:effigyData = Get-MapCategoryJson 'effigy'
                        Send-Response $res 200 "application/json" $script:effigyData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/map-confirm' -and $method -eq 'POST') {
                    # Admin-only manual confirm from a map marker popup checkbox (see
                    # EFFIGY_CONFIRM_ENABLED / toggleMapConfirm in dashboard.html). Body:
                    # { category, key?, species?, name?, confirmed }. Flips "verified"
                    # directly on the matching confirmed_locations.json row via
                    # Set-MapConfirmVerified. Replaced six separate per-category routes
                    # (/api/effigy-confirm, /api/journal-confirm, /api/bounty-confirm,
                    # /api/tower-confirm, /api/fugitive-confirm, /api/eagle-confirm), which
                    # each wrote to their own *_confirmed_keys.json overlay file -- those
                    # files are retired now that every route/client call goes through this
                    # one, single-source-of-truth path.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $category = [string]$body.category
                        if (-not $category) { throw "No category provided." }
                        $key = [string]$body.key
                        $species = [string]$body.species
                        $name = [string]$body.name
                        $confirmFlag = [bool]$body.confirmed
                        $ok = Set-MapConfirmVerified $category $key $species $name $confirmFlag
                        if (-not $ok) { throw "No confirmed_locations.json row found (category $category)." }
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true; category=$category; confirmed=$confirmFlag } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/tower-key-confirm' -and $method -eq 'POST') {
                    # Tower's two independent per-key verification checkboxes (added
                    # 2026-07-07, separate from /api/map-confirm's location "verified"
                    # above). Body: { name, field, verified } -- field is "eagleVerified" or
                    # "bossVerified" (see Set-TowerKeyVerified's whitelist).
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $towerName = [string]$body.name
                        if (-not $towerName) { throw "No name provided." }
                        $field = [string]$body.field
                        $verifiedFlag = [bool]$body.verified
                        $ok = Set-TowerKeyVerified $towerName $field $verifiedFlag
                        if (-not $ok) { throw "No confirmed_locations.json tower row found, or unknown field." }
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true; name=$towerName; field=$field; verified=$verifiedFlag } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/map-add-icon' -and $method -eq 'POST') {
                    # "Add Icon" header button -> modal (dashboard.html, openAddIconModal/
                    # saveAddIcon) -- hand-creates a brand-new confirmed_locations.json row
                    # for one of the 6 live map categories, optionally tied to an already-
                    # discovered but still-unmapped raw save key (Data Mine tab's Unmapped
                    # Keys list). Stamped custom:true by Add-CustomMapEntry so it's
                    # distinguishable from every other creation path; scraped-roster
                    # re-imports (import_scraped_rosters.ps1) reconcile it for free later via
                    # the normal identity-matched upsert, no special-casing needed here.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $category = [string]$body.category
                        if (-not $category) { throw "No category provided." }
                        $key = if ($body.key) { [string]$body.key } else { $null }
                        $name = if ($body.name) { [string]$body.name } else { $null }
                        $species = if ($body.species) { [string]$body.species } else { $null }
                        $gx = if ($null -ne $body.gx -and [string]$body.gx -ne '') { [int]$body.gx } else { $null }
                        $gy = if ($null -ne $body.gy -and [string]$body.gy -ne '') { [int]$body.gy } else { $null }
                        $newRow = Add-CustomMapEntry $category $key $name $species $gx $gy
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true; entry=$newRow } -Depth 6 -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/map-custom-edit' -and $method -eq 'POST') {
                    # Data Mine tab's Custom Icons review list -- edits a custom:true row
                    # in place. Body: { category, identityKey?, identitySpecies?,
                    # identityName?, name?, gx?, gy?, key?, species? }. Edit-CustomMapEntry
                    # refuses to touch anything that isn't custom:true, so this can never be
                    # pointed at a scraped/live row even via a matching identity.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $category = [string]$body.category
                        if (-not $category) { throw "No category provided." }
                        $identKey = if ($body.identityKey) { [string]$body.identityKey } else { $null }
                        $identSpecies = if ($body.identitySpecies) { [string]$body.identitySpecies } else { $null }
                        $identName = if ($body.identityName) { [string]$body.identityName } else { $null }
                        $fields = @{}
                        if ($body.PSObject.Properties['name']) { $fields.name = if ($body.name) { [string]$body.name } else { $null } }
                        if ($body.PSObject.Properties['gx']) { $fields.gx = if ([string]$body.gx -ne '') { [int]$body.gx } else { $null } }
                        if ($body.PSObject.Properties['gy']) { $fields.gy = if ([string]$body.gy -ne '') { [int]$body.gy } else { $null } }
                        if ($body.PSObject.Properties['key']) { $fields.key = if ($body.key) { [string]$body.key } else { $null } }
                        if ($body.PSObject.Properties['species']) { $fields.species = if ($body.species) { [string]$body.species } else { $null } }
                        $updated = Edit-CustomMapEntry $category $identKey $identSpecies $identName $fields
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true; entry=$updated } -Depth 6 -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/map-custom-delete' -and $method -eq 'POST') {
                    # Data Mine tab's Custom Icons review list -- deletes a custom:true row.
                    # Body: { category, key?, species?, name? }. Same custom:true guard as
                    # /api/map-custom-edit above.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $category = [string]$body.category
                        if (-not $category) { throw "No category provided." }
                        $key = if ($body.key) { [string]$body.key } else { $null }
                        $species = if ($body.species) { [string]$body.species } else { $null }
                        $name = if ($body.name) { [string]$body.name } else { $null }
                        Remove-CustomMapEntry $category $key $species $name | Out-Null
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/map-add-entrance' -and $method -eq 'POST') {
                    # Cave-entrance sub-pin -> attaches a hand-typed grid coordinate to an
                    # existing pin (any category/origin), rendered client-side as a cave icon
                    # linked to the parent by a line in the parent's status-ring color. Body:
                    # { category, key?, species?, name?, gx, gy }. See map_data_lib.ps1
                    # Add-MapEntrance and dashboard.html openEntranceModal/desireEntrances.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $category = [string]$body.category
                        if (-not $category) { throw "No category provided." }
                        $key = if ($body.key) { [string]$body.key } else { $null }
                        $species = if ($body.species) { [string]$body.species } else { $null }
                        $name = if ($body.name) { [string]$body.name } else { $null }
                        $gx = if ($null -ne $body.gx -and [string]$body.gx -ne '') { [int]$body.gx } else { $null }
                        $gy = if ($null -ne $body.gy -and [string]$body.gy -ne '') { [int]$body.gy } else { $null }
                        $updated = Add-MapEntrance $category $key $species $name $gx $gy
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true; entry=$updated } -Depth 6 -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/map-remove-entrance' -and $method -eq 'POST') {
                    # Removes one cave-entrance sub-pin by 0-based index. Body:
                    # { category, key?, species?, name?, index }. See Remove-MapEntrance.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $category = [string]$body.category
                        if (-not $category) { throw "No category provided." }
                        $key = if ($body.key) { [string]$body.key } else { $null }
                        $species = if ($body.species) { [string]$body.species } else { $null }
                        $name = if ($body.name) { [string]$body.name } else { $null }
                        $index = [int]$body.index
                        Remove-MapEntrance $category $key $species $name $index | Out-Null
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/map-add-boss-prereq' -and $method -eq 'POST') {
                    # Boss prerequisite link, on a Field Boss OR a Tower -- see Add-BossPrereq
                    # in map_data_lib.ps1 and dashboard.html openPrereqModal/savePrereqLink.
                    # Body: { category, species, name, prereqSpecies }. species is the locked
                    # boss (category "bounty"); name is the locked tower (category "tower").
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $category = [string]$body.category
                        $species = [string]$body.species
                        $name = [string]$body.name
                        $preSpecies = [string]$body.prereqSpecies
                        $updated = Add-BossPrereq $category $species $name $preSpecies
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true; entry=$updated } -Depth 6 -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/map-remove-boss-prereq' -and $method -eq 'POST') {
                    # Removes one boss prerequisite link. Body:
                    # { category, species, name, prereqSpecies }. See Remove-BossPrereq in
                    # map_data_lib.ps1.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $category = [string]$body.category
                        $species = [string]$body.species
                        $name = [string]$body.name
                        $preSpecies = [string]$body.prereqSpecies
                        Remove-BossPrereq $category $species $name $preSpecies | Out-Null
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/journals' -and $method -eq 'GET') {
                    # Lore-journal/diary locations (game-world fixed, not per-save). Phase 3's
                    # importer already upserted every journal_locations.json row into the
                    # canonical store, so this reads straight from there -- see the
                    # /api/effigies note above for why the roster file is no longer read live.
                    try {
                        $script:journalData = Get-MapCategoryJson 'journal'
                        Send-Response $res 200 "application/json" $script:journalData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/bounty-bosses' -and $method -eq 'GET') {
                    # Bounty-boss (named legendary Alpha) locations -- see the /api/journals
                    # note above; served straight from the canonical store.
                    try {
                        $script:bountyBossData = Get-MapCategoryJson 'bounty'
                        Send-Response $res 200 "application/json" $script:bountyBossData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/wanted-fugitives' -and $method -eq 'GET') {
                    # Named human/Syndicate "boss" locations -- see the /api/journals note
                    # above; served straight from the canonical store.
                    try {
                        $script:wantedFugitiveData = Get-MapCategoryJson 'fugitive'
                        Send-Response $res 200 "application/json" $script:wantedFugitiveData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/eagle-statues' -and $method -eq 'GET') {
                    # Named fast-travel point locations -- see the /api/journals note above;
                    # served straight from the canonical store.
                    try {
                        $script:eagleStatueData = Get-MapCategoryJson 'eagle'
                        Send-Response $res 200 "application/json" $script:eagleStatueData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/sam-sites' -and $method -eq 'GET') {
                    # Feybreak SAM Site (anti-air missile turret) locations -- scraped from a
                    # community location guide (2026-07-09), no save-flag key identified yet
                    # (see the palbox-confirmed-locations skill). Same generic read path as
                    # every other category; will pick up per-player "found" tracking for free
                    # once a save key is discovered and confirmed_locations.json rows get a key.
                    try {
                        $script:samSiteData = Get-MapCategoryJson 'sam'
                        Send-Response $res 200 "application/json" $script:samSiteData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/towers' -and $method -eq 'GET') {
                    # Named raid Tower locations -- see the /api/journals note above; served
                    # straight from the canonical store.
                    try {
                        $script:towerData = Get-MapCategoryJson 'tower'
                        Send-Response $res 200 "application/json" $script:towerData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/syndicate-bosses' -and $method -eq 'GET') {
                    # Static roster of NPC/Syndicate "boss" defeat-flag keys (human enemies,
                    # e.g. Syndicate Tower bosses) -- see syndicate_bosses.json. Unlike
                    # bounty_bosses.json these carry no confirmed map location, so this is a
                    # flat list tab, not a map overlay.
                    try {
                        if (-not $script:syndicateBossData) {
                            $f = "$ServerDir\syndicate_bosses.json"
                            if (Test-Path -LiteralPath $f) {
                                $script:syndicateBossData = [System.IO.File]::ReadAllText($f)
                            } else {
                                $script:syndicateBossData = '[]'
                            }
                        }
                        Send-Response $res 200 "application/json" $script:syndicateBossData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/pal-species' -and $method -eq 'GET') {
                    # Curated species-level data (type/work/skills/stats) built by
                    # build_pal_species.py. The public site bundles this as a static file;
                    # here we serve it from the same JSON so both dashboards match. 165KB
                    # and effectively immutable for the life of this process (cached once
                    # below), so gzip + Last-Modified/304 are worth it same as the icon
                    # routes and the main page.
                    try {
                        if (-not $script:palSpeciesData) {
                            $f = "$ServerDir\pal_species.json"
                            if (Test-Path -LiteralPath $f) {
                                $script:palSpeciesData = [System.IO.File]::ReadAllText($f)
                                $script:palSpeciesMtime = [System.IO.File]::GetLastWriteTimeUtc($f)
                            } else {
                                $script:palSpeciesData = '{}'
                                $script:palSpeciesMtime = [datetime]::UtcNow
                            }
                            $script:palSpeciesGzip = Get-GzipBytes $script:palSpeciesData
                        }
                        Send-CachedResponse -Response $res -Request $req -ContentType "application/json" -Body $script:palSpeciesData -GzipBytes $script:palSpeciesGzip -Mtime $script:palSpeciesMtime
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/pal-skills' -and $method -eq 'GET') {
                    # Per active-skill metadata (element/power/cooldown/status/desc) built by
                    # build_pal_skills.py. The public site bundles this as a static file; here
                    # we serve it from the same JSON so both dashboards match.
                    try {
                        if (-not $script:palSkillsData) {
                            $f = "$ServerDir\pal_skills.json"
                            if (Test-Path -LiteralPath $f) {
                                $script:palSkillsData = [System.IO.File]::ReadAllText($f)
                            } else {
                                $script:palSkillsData = '{}'
                            }
                        }
                        Send-Response $res 200 "application/json" $script:palSkillsData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/pal-passives' -and $method -eq 'GET') {
                    # Per-passive effect text + rating rank built by build_pal_passives.py. The
                    # public site bundles this as a static file; here we serve it from the same
                    # JSON so both dashboards match.
                    try {
                        if (-not $script:palPassivesData) {
                            $f = "$ServerDir\pal_passives.json"
                            if (Test-Path -LiteralPath $f) {
                                $script:palPassivesData = [System.IO.File]::ReadAllText($f)
                            } else {
                                $script:palPassivesData = '{}'
                            }
                        }
                        Send-Response $res 200 "application/json" $script:palPassivesData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-effigies' -and $method -eq 'GET') {
                    try {
                        $guid = $req.QueryString['guid']
                        if (-not $guid) { throw "Missing guid parameter" }
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "effigies:$guid" (Join-Path $saveDir "Players\$guid.sav") {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir effigies $guid 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        Send-Response $res 200 "application/json" $rawJson
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-notes' -and $method -eq 'GET') {
                    # Journal/diary note collection state, read from NoteObtainForInstanceFlag
                    # in the player's save (same mechanism as effigies' RelicObtainForInstanceFlag).
                    # Returns the full raw collected-key list. The map can only color a specific
                    # dot found/new once journal_locations.json has that key confirmed (see the
                    # palbox-journal-overlay skill) -- entries without a confirmed key render
                    # blue/"unknown" regardless of what's in this list.
                    try {
                        $guid = $req.QueryString['guid']
                        if (-not $guid) { throw "Missing guid parameter" }
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "notes:$guid" (Join-Path $saveDir "Players\$guid.sav") {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir notes $guid 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        Send-Response $res 200 "application/json" $rawJson
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-bounties' -and $method -eq 'GET') {
                    # Bounty-boss (named legendary Alpha) defeat state, read from
                    # NormalBossDefeatFlag in the player's save (same mechanism as effigies'
                    # RelicObtainForInstanceFlag). "collected" here is a list of species codes
                    # matched against bounty_bosses.json, not raw instance IDs -- see
                    # extract_bounty_data in pal_save_reader.py.
                    try {
                        $guid = $req.QueryString['guid']
                        if (-not $guid) { throw "Missing guid parameter" }
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "bounties:$guid" @(
                            (Join-Path $saveDir "Players\$guid.sav"),
                            "$ServerDir\anonymous_boss_keys.json",
                            "$ServerDir\excluded_boss_keys.json",
                            "$ServerDir\bounty_bosses.json"
                        ) {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir bounties $guid 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        Send-Response $res 200 "application/json" $rawJson
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-fugitives' -and $method -eq 'GET') {
                    # Wanted Fugitive (human/Syndicate boss) defeat state, read from
                    # NormalBossDefeatFlag in the player's save -- same flag as bounty bosses,
                    # but matched by exact key (see extract_fugitive_data in
                    # pal_save_reader.py), not resolved to a species.
                    try {
                        $guid = $req.QueryString['guid']
                        if (-not $guid) { throw "Missing guid parameter" }
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "fugitives:$guid" (Join-Path $saveDir "Players\$guid.sav") {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir fugitives $guid 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        Send-Response $res 200 "application/json" $rawJson
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-eagles' -and $method -eq 'GET') {
                    # Eagle Statue (fast-travel point) unlock state, read from
                    # FastTravelPointUnlockFlag in the player's save (see
                    # extract_fast_travel_data in pal_save_reader.py).
                    try {
                        $guid = $req.QueryString['guid']
                        if (-not $guid) { throw "Missing guid parameter" }
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "eagles:$guid" (Join-Path $saveDir "Players\$guid.sav") {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir eagles $guid 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        Send-Response $res 200 "application/json" $rawJson
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-tower-bosses' -and $method -eq 'GET') {
                    # Tower raid-boss defeat state, read from TowerBossDefeatFlag in the
                    # player's save (see extract_tower_boss_data in pal_save_reader.py).
                    # Added 2026-07-07 -- keys are matched against towers.json's bossKey
                    # field (Tower category, not Eagle Statue's separate FastTravelPoint-
                    # UnlockFlag key) to drive the Tower marker's main-icon status.
                    try {
                        $guid = $req.QueryString['guid']
                        if (-not $guid) { throw "Missing guid parameter" }
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "towerbosses:$guid" (Join-Path $saveDir "Players\$guid.sav") {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir towerbosses $guid 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        Send-Response $res 200 "application/json" $rawJson
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-datamine' -and $method -eq 'GET') {
                    # All NormalBossDefeatFlag data for one player, bucketed into
                    # bounty/syndicate/anonymous (see extract_datamine_data in
                    # pal_save_reader.py). Also carries the account-wide
                    # PredatorDefeatCount/FixedDungeonClearCount/NormalDungeonClearCount
                    # stats, which aren't tied to a specific boss key but live in the same
                    # save data.
                    try {
                        $guid = $req.QueryString['guid']
                        if (-not $guid) { throw "Missing guid parameter" }
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "datamine:$guid" @(
                            (Join-Path $saveDir "Players\$guid.sav"),
                            "$ServerDir\anonymous_boss_keys.json",
                            "$ServerDir\excluded_boss_keys.json",
                            "$ServerDir\bounty_bosses.json"
                        ) {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir datamine $guid 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        Send-Response $res 200 "application/json" $rawJson
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-datamine-full' -and $method -eq 'GET') {
                    # Every DATAMINE_PROPERTIES entry (see pal_save_reader.py) for one player --
                    # backs the generic Data Mine key/property browser (all keys, all parent
                    # properties, not just NormalBossDefeatFlag like /api/player-datamine above).
                    # Cache depends on Level.sav too (not just the player's own .sav) because
                    # this response also carries DestroyedWeapon (SAM Site), which is world-
                    # scoped -- without it, a newly-destroyed SAM Site wouldn't show up here
                    # until the player's own save happened to change for an unrelated reason.
                    try {
                        $guid = $req.QueryString['guid']
                        if (-not $guid) { throw "Missing guid parameter" }
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "datamine-full:$guid" @(
                            (Join-Path $saveDir "Players\$guid.sav"),
                            (Join-Path $saveDir "Level.sav")
                        ) {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir datamine-full $guid 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        Send-Response $res 200 "application/json" $rawJson
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/destroyed-weapons' -and $method -eq 'GET') {
                    # Currently-destroyed SAM Site (fixed weapon) save keys -- world-scoped
                    # (Level.sav), same generic read path used by the Map tab's other collected-
                    # flag fetches (fetchEagleStatues etc.), independent of the heavier per-
                    # player Data Mine machinery above. See /palbox-confirmed-locations' SAM
                    # Site section for how FixedWeaponDestroySaveData was reverse-engineered.
                    try {
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = Get-CachedReaderOutput "destroyed-weapons" (Join-Path $saveDir "Level.sav") {
                            $j = & python "$ServerDir\pal_save_reader.py" $saveDir destroyed-weapons 2>$null
                            if ($LASTEXITCODE -ne 0 -or -not $j) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                            ($j -join '')
                        }
                        Send-Response $res 200 "application/json" $rawJson
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/datamine-mappings' -and $method -eq 'GET') {
                    # Current Display Name / Coordinates edits for the Data Mine browser --
                    # confirmedLocations for spatial properties (source-stamped subset of
                    # confirmed_locations.json), labels for everything else (datamine_labels.json).
                    try {
                        $confirmed = @(Get-ConfirmedLocations)
                        $labels = @(Get-DatamineLabels)
                        Send-Response $res 200 "application/json" (ConvertTo-Json -InputObject @{ confirmedLocations = $confirmed; labels = $labels } -Depth 6 -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/datamine-mapping' -and $method -eq 'POST') {
                    # Upserts one Data Mine browser edit. Body: {property,key,name,gx,gy,verified?}.
                    # Spatial properties (real map-location meaning, see
                    # $script:DatamineSpatialProperties above) go into confirmed_locations.json
                    # itself, stamped source=<property> -- the dashboard is a second trusted
                    # writer to that file for this feature specifically (Anthony's explicit
                    # call, see /palworld-dataminer skill). Everything else goes into the
                    # separate datamine_labels.json. "verified" defaults to true when omitted --
                    # this route is only ever called from the dashboard's own editable Name/
                    # Coordinates/Key fields, i.e. Anthony typing something in himself, which
                    # counts as his own confirmation. Auto-filled public-scrape suggestions go
                    # through /api/datamine-mapping-batch instead, which always passes false.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $property = [string]$body.property
                        $key = [string]$body.key
                        if (-not $property -or -not $key) { throw "property and key are required." }
                        $name = if ($null -ne $body.name -and [string]$body.name -ne '') { [string]$body.name } else { $null }
                        $gx = if ($null -ne $body.gx -and [string]$body.gx -ne '') { [int]$body.gx } else { $null }
                        $gy = if ($null -ne $body.gy -and [string]$body.gy -ne '') { [int]$body.gy } else { $null }
                        $verifiedFlag = if ($null -ne $body.verified) { [bool]$body.verified } else { $true }

                        if ($script:DatamineSpatialProperties -contains $property) {
                            $f = "$ServerDir\confirmed_locations.json"
                            $arr = @(Get-ConfirmedLocations)
                            $existing = $arr | Where-Object { $_.key -eq $key } | Select-Object -First 1
                            if (-not $existing -and $name) {
                                # No row carries this exact key yet -- before creating a brand-new
                                # pin, check for an already-scraped KEYLESS row with the same
                                # display name (e.g. a paldb-sourced Field Boss/Wanted Fugitive/
                                # Eagle pin that has no save key attached yet, see
                                # import_scraped_rosters.ps1). Typing in the key for a species
                                # that's already on the map should attach it to that existing pin
                                # instead of creating a visually-duplicate second one at (usually)
                                # the exact same location -- this is exactly the bug that produced
                                # a duplicate, never-green Fenglope pin (2026-07-07).
                                $nameU = $name.ToUpper()
                                $existing = $arr | Where-Object { -not $_.key -and $_.name -and $_.name.ToUpper() -eq $nameU } | Select-Object -First 1
                            }
                            # Species carried by a matched scraped row (bounty pins only) --
                            # captured BEFORE the update below so we still have it for the
                            # anonymous_boss_keys.json backfill after saving, whether this was a
                            # key-match or the name-fallback match above.
                            $matchedSpecies = if ($existing) { $existing.species } else { $null }
                            if ($existing) {
                                $existing.name = $name
                                $existing.gx = $gx
                                $existing.gy = $gy
                                $existing | Add-Member -MemberType NoteProperty -Name source -Value $property -Force
                                $existing | Add-Member -MemberType NoteProperty -Name verified -Value $verifiedFlag -Force
                                # Must run BEFORE Get-CategoryForEntry -- for a row matched via the
                                # name-fallback above, $existing.key is still the OLD value (null,
                                # for a scraped keyless row) at this point. Get-CategoryForEntry's
                                # NormalBossDefeatFlag branch reads .key to tell a Field Boss key
                                # apart from a syndicate "BOSS_*" one (Test-SyndicateKeyShape); with
                                # the key still null, a Wanted Fugitive key (e.g.
                                # "BOSS_FEMALE_PEOPLE02") always mis-derived to 'bounty' instead of
                                # 'fugitive', which routed the pin into the wrong map layer entirely
                                # and made its defeat status check the (always-false, since there's
                                # no real species) bounty species list instead of the raw fugitive
                                # key list -- confirmed live (2026-07-07): a manually-mapped
                                # Wanted Fugitive stayed permanently yellow/undefeated this way.
                                $existing.key = $key
                                # Re-derive category (source/name/key may have just changed) and
                                # origin -- see Get-CategoryForEntry; "manual" here overstates
                                # nothing new, it's the same convention the schema migration
                                # already used for any source-tagged, verified:true row.
                                $existing | Add-Member -MemberType NoteProperty -Name category -Value (Get-CategoryForEntry $existing) -Force
                                $existing | Add-Member -MemberType NoteProperty -Name origin -Value $(if ($verifiedFlag) { 'manual' } else { 'scraped' }) -Force
                            } else {
                                $newEntry = [pscustomobject]@{ key = $key; name = $name; gx = $gx; gy = $gy; source = $property; verified = $verifiedFlag }
                                $newEntry | Add-Member -MemberType NoteProperty -Name category -Value (Get-CategoryForEntry $newEntry) -Force
                                $newEntry | Add-Member -MemberType NoteProperty -Name origin -Value $(if ($verifiedFlag) { 'manual' } else { 'scraped' }) -Force
                                $arr = $arr + $newEntry
                            }
                            # Funnel through the canonical Save-ConfirmedLocations writer, which
                            # does the no-BOM, atomic temp-file + Move-Item swap for us (and keeps
                            # the in-memory cache in sync). See its definition in map_data_lib.ps1
                            # for why the atomic write matters (concurrent poll/Python readers).
                            Save-ConfirmedLocations $arr
                            # Bounty (Field Boss) keys resolve to a species via
                            # anonymous_boss_keys.json, NOT confirmed_locations.json -- that's what
                            # pal_save_reader.py's extract_bounty_data/extract_datamine_data (and
                            # therefore /api/player-bounties' "defeated" state on the map) actually
                            # reads. Without this, a manually-confirmed key never shows green even
                            # though the pin itself is now correct. Only fires when we matched an
                            # existing scraped row with a real species already on it (a brand-new
                            # pin typed from scratch has no species to backfill).
                            if ($property -eq 'NormalBossDefeatFlag' -and -not (Test-SyndicateKeyShape $key) -and $matchedSpecies) {
                                Add-AnonymousBossKey $key $matchedSpecies
                            }
                        } else {
                            $f = "$ServerDir\datamine_labels.json"
                            $arr = @(Get-DatamineLabels)
                            $existing = $arr | Where-Object { $_.property -eq $property -and $_.key -eq $key } | Select-Object -First 1
                            if ($existing) {
                                $existing.name = $name
                                $existing.gx = $gx
                                $existing.gy = $gy
                                $existing | Add-Member -MemberType NoteProperty -Name verified -Value $verifiedFlag -Force
                            } else {
                                $newEntry = [pscustomobject]@{ property = $property; key = $key; name = $name; gx = $gx; gy = $gy; verified = $verifiedFlag }
                                $arr = $arr + $newEntry
                            }
                            # No-BOM UTF8 -- confirmed_locations.json is also read by the
                            # Desktop dataminer script via plain Python json.load(encoding="utf-8"),
                            # which chokes on a BOM. [Text.Encoding]::UTF8 (used by the other
                            # manual-confirm routes above) writes one; this doesn't.
                            [System.IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @($arr) -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
                        }
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/datamine-verify' -and $method -eq 'POST') {
                    # Toggles ONLY the verified flag on an existing Data Mine mapping -- ticking
                    # the checkbox shouldn't require resubmitting name/gx/gy too. Body:
                    # {property,key,verified}. Errors if no mapping exists yet for that key
                    # (nothing to verify until a name/coordinates/key has actually been saved).
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $property = [string]$body.property
                        $key = [string]$body.key
                        if (-not $property -or -not $key) { throw "property and key are required." }
                        $verifiedFlag = [bool]$body.verified

                        if ($script:DatamineSpatialProperties -contains $property) {
                            $f = "$ServerDir\confirmed_locations.json"
                            $arr = @(Get-ConfirmedLocations)
                            $existing = $arr | Where-Object { $_.key -eq $key } | Select-Object -First 1
                            if (-not $existing) { throw "No existing mapping for this key yet." }
                            $existing | Add-Member -MemberType NoteProperty -Name verified -Value $verifiedFlag -Force
                            # Same origin convention as /api/datamine-mapping above.
                            $existing | Add-Member -MemberType NoteProperty -Name origin -Value $(if ($verifiedFlag) { 'manual' } else { 'scraped' }) -Force
                            # Atomic no-BOM write via the canonical helper (was a direct in-place
                            # WriteAllText -- same concurrent-reader truncation risk as the mapping
                            # route it mirrors).
                            Save-ConfirmedLocations $arr
                        } else {
                            $f = "$ServerDir\datamine_labels.json"
                            $arr = @(Get-DatamineLabels)
                            $existing = $arr | Where-Object { $_.property -eq $property -and $_.key -eq $key } | Select-Object -First 1
                            if (-not $existing) { throw "No existing mapping for this key yet." }
                            $existing | Add-Member -MemberType NoteProperty -Name verified -Value $verifiedFlag -Force
                            [System.IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @($arr) -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
                        }
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/datamine-mapping-batch' -and $method -eq 'POST') {
                    # Bulk upsert for auto-filling public-scrape suggestions in one pass (see
                    # dashboard.html's dmAutoFillFromRosters) -- one read-modify-write per
                    # target file instead of one HTTP round-trip per entry, since a tab load can
                    # touch 100+ keys at once. Body: {entries:[{property,key,name,gx,gy,
                    # verified}, ...]}. Each entry's "verified" defaults to false if omitted --
                    # unlike the singular route above, this one is for the system auto-filling
                    # data it scraped, not Anthony typing something in himself.
                    try {
                        $body = $reqBody | ConvertFrom-Json -ErrorAction Stop
                        $entries = $body.entries
                        if ($null -eq $entries) { $entries = @() }
                        $entries = @($entries)

                        $confirmedArr = @(Get-ConfirmedLocations)
                        $labelsArr = @(Get-DatamineLabels)
                        $confirmedDirty = $false
                        $labelsDirty = $false

                        foreach ($e in $entries) {
                            $property = [string]$e.property
                            $key = [string]$e.key
                            if (-not $property -or -not $key) { continue }
                            $name = if ($null -ne $e.name -and [string]$e.name -ne '') { [string]$e.name } else { $null }
                            $gx = if ($null -ne $e.gx -and [string]$e.gx -ne '') { [int]$e.gx } else { $null }
                            $gy = if ($null -ne $e.gy -and [string]$e.gy -ne '') { [int]$e.gy } else { $null }
                            $verifiedFlag = if ($null -ne $e.verified) { [bool]$e.verified } else { $false }

                            if ($script:DatamineSpatialProperties -contains $property) {
                                $existing = $confirmedArr | Where-Object { $_.key -eq $key } | Select-Object -First 1
                                if ($existing) {
                                    $existing.name = $name
                                    $existing.gx = $gx
                                    $existing.gy = $gy
                                    $existing | Add-Member -MemberType NoteProperty -Name source -Value $property -Force
                                    $existing | Add-Member -MemberType NoteProperty -Name verified -Value $verifiedFlag -Force
                                    # Re-derive category/origin -- see the singular
                                    # /api/datamine-mapping route above for why.
                                    $existing | Add-Member -MemberType NoteProperty -Name category -Value (Get-CategoryForEntry $existing) -Force
                                    $existing | Add-Member -MemberType NoteProperty -Name origin -Value $(if ($verifiedFlag) { 'manual' } else { 'scraped' }) -Force
                                } else {
                                    $newEntry = [pscustomobject]@{ key = $key; name = $name; gx = $gx; gy = $gy; source = $property; verified = $verifiedFlag }
                                    $newEntry | Add-Member -MemberType NoteProperty -Name category -Value (Get-CategoryForEntry $newEntry) -Force
                                    $newEntry | Add-Member -MemberType NoteProperty -Name origin -Value $(if ($verifiedFlag) { 'manual' } else { 'scraped' }) -Force
                                    $confirmedArr = $confirmedArr + $newEntry
                                }
                                $confirmedDirty = $true
                            } else {
                                $existing = $labelsArr | Where-Object { $_.property -eq $property -and $_.key -eq $key } | Select-Object -First 1
                                if ($existing) {
                                    $existing.name = $name
                                    $existing.gx = $gx
                                    $existing.gy = $gy
                                    $existing | Add-Member -MemberType NoteProperty -Name verified -Value $verifiedFlag -Force
                                } else {
                                    $newEntry = [pscustomobject]@{ property = $property; key = $key; name = $name; gx = $gx; gy = $gy; verified = $verifiedFlag }
                                    $labelsArr = $labelsArr + $newEntry
                                }
                                $labelsDirty = $true
                            }
                        }

                        # No-BOM atomic write via the canonical helper -- this batch can touch
                        # 100+ entries, the single largest confirmed_locations.json write there is,
                        # so it was the MOST likely of the three datamine routes to be caught
                        # mid-write by a concurrent poll/Python reader, yet it was the one still
                        # doing an unsafe in-place WriteAllText. See Save-ConfirmedLocations.
                        if ($confirmedDirty) {
                            Save-ConfirmedLocations $confirmedArr
                        }
                        if ($labelsDirty) {
                            [System.IO.File]::WriteAllText("$ServerDir\datamine_labels.json", (ConvertTo-Json -InputObject @($labelsArr) -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
                        }
                        Send-Response $res 200 "application/json" (ConvertTo-Json @{ ok=$true; count=$entries.Count } -Compress)
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                default { Send-Response $res 404 "application/json" '{"error":"Not found"}' }
            }
        }
    } finally {
        $listener.Stop()
        Write-Output "Dashboard stopped."
    }

} -ArgumentList $ServerDir, $AdminPassword, $RestApiBase, $DashPort, $StartScript,
                $ConfigFile, $SkipFlagFile, $MaintLogFile, $DefaultSettingsPath, $ActiveSettingsPath

# ── Monitor loop ──────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  PalWorld Server Manager" -ForegroundColor Cyan
Write-Host "  Dashboard  : http://localhost:$DashPort" -ForegroundColor Green
Write-Host "  Maintenance: daily at 4:00 AM (configurable from dashboard)" -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

function Show-JobLine([string]$Line, [string]$Prefix) {
    if (!$Line) { return }
    $c = if     ($Line -match 'error|fail|warning|timed out')         { 'Red'    }
         elseif ($Line -match 'shutting|restarting|seconds!|countdown') { 'Yellow' }
         elseif ($Line -match 'online|started|launched|complete|saved|broadcast') { 'Green'  }
         elseif ($Line -match 'sleeping|next|maintenance|dashboard|waiting') { 'Cyan'   }
         else                                                            { 'White'  }
    Write-Host "$Prefix $Line" -ForegroundColor $c
}

try {
    while ($true) {
        Receive-Job $MaintenanceJob | ForEach-Object { Show-JobLine $_ "[MAINT]" }
        Receive-Job $DashboardJob  | ForEach-Object { Show-JobLine $_ "[DASH ]" }

        if ($MaintenanceJob.State -eq 'Failed') {
            Write-Host "[MAINT] Job failed." -ForegroundColor Red
            Receive-Job $MaintenanceJob 2>&1 | ForEach-Object { Write-Host "[MAINT] $_" -ForegroundColor Red }
            break
        }
        if ($DashboardJob.State -eq 'Failed') {
            Write-Host "[DASH ] Job failed." -ForegroundColor Red
            Receive-Job $DashboardJob 2>&1 | ForEach-Object { Write-Host "[DASH ] $_" -ForegroundColor Red }
            break
        }

        Start-Sleep -Milliseconds 500
    }
} finally {
    Write-Host ""
    Write-Host "Stopping server manager..." -ForegroundColor Yellow
    Stop-Job  $MaintenanceJob, $DashboardJob -ErrorAction SilentlyContinue
    Remove-Job $MaintenanceJob, $DashboardJob -ErrorAction SilentlyContinue
    Write-Host "Done." -ForegroundColor Green
}
