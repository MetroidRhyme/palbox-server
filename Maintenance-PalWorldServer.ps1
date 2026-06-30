# Maintenance-PalWorldServer.ps1
# Keep this window open. Runs a daily cycle:
#   8:30 AM    - broadcasts 30-minute shutdown warning
#   8:45 AM    - broadcasts 15-minute shutdown warning
#   8:55 AM    - broadcasts 5-minute shutdown warning
#   8:59 AM    - 1-minute in-game countdown (60s / 40s / 20s / 10s / 5s)
#   9:00 AM    - stops server, runs update, restarts server

$ServerDir     = $PSScriptRoot
$InstallScript = "$ServerDir\Install-PalWorldServer.ps1"
$StartScript   = "$ServerDir\Start-PalWorldServer.ps1"
$AdminPassword = $(try{$m=[regex]::Match((Get-Content (Join-Path $PSScriptRoot 'Pal\Saved\Config\WindowsServer\PalWorldSettings.ini') -Raw),'AdminPassword="([^"]*)"');if($m.Success){$m.Groups[1].Value}else{''}}catch{''})
$RestApiBase   = "http://localhost:8212"

# --- Save backup + health monitoring ---------------------------------------
# A pre-maintenance world backup runs before every update (the update could in
# theory corrupt or roll back the world). Backups land in SaveLibrary using the
# same layout the Server Manager UI reads, so they show up there too.
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

function Write-Log {
    param([string]$Msg, [string]$Color = "White")
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg" -ForegroundColor $Color
}

function Get-ApiHeaders {
    $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$AdminPassword"))
    return @{ Authorization = "Basic $cred"; "Content-Type" = "application/json" }
}

# Shared server-message feed helper (Add-ServerMessage) so maintenance broadcasts also
# show in the dashboard chat banner. Loaded best-effort; never fatal if missing.
try { . "$ServerDir\server_messages.ps1" } catch {}

function Send-Broadcast {
    param([string]$Message)
    try {
        Invoke-RestMethod `
            -Uri     "$RestApiBase/v1/api/announce" `
            -Method  POST `
            -Headers (Get-ApiHeaders) `
            -Body    (ConvertTo-Json @{ message = $Message }) | Out-Null
        Write-Log "Broadcast: $Message" Green
        try { if (Get-Command Add-ServerMessage -EA SilentlyContinue) { Add-ServerMessage $Message 'maintenance' } } catch {}
    } catch {
        Write-Log "Broadcast failed (server may be offline): $($_.Exception.Message)" Yellow
    }
}

function Wait-Until {
    param([datetime]$Until)
    $secs = [math]::Max(1, [int]($Until - (Get-Date)).TotalSeconds)
    $mins = [math]::Round($secs / 60)
    Write-Log "Sleeping until $($Until.ToString('HH:mm')) ($mins min)" Cyan
    Start-Sleep -Seconds $secs
}

function Stop-PalServer {
    if (-not (Get-Process | Where-Object { $_.Name -like "*PalServer*" })) {
        Write-Log "No running PalServer process found - skipping stop." Yellow
        return
    }

    Write-Log "Sending shutdown via REST API..." Yellow
    try {
        Invoke-RestMethod `
            -Uri     "$RestApiBase/v1/api/shutdown" `
            -Method  POST `
            -Headers (Get-ApiHeaders) `
            -Body    (ConvertTo-Json @{ waittime = 15; message = "Shutting down for maintenance." }) | Out-Null
    } catch {
        Write-Log "REST shutdown failed: $($_.Exception.Message)" Yellow
    }

    # Wait for process to fully exit (up to 60s)
    $waited = 0
    while ((Get-Process | Where-Object { $_.Name -like "*PalServer*" }) -and $waited -lt 60) {
        Start-Sleep -Seconds 2
        $waited += 2
    }

    if (Get-Process | Where-Object { $_.Name -like "*PalServer*" }) {
        Write-Log "Server did not exit after 60s - it may still be shutting down." Yellow
    } else {
        Write-Log "Server stopped." Green
    }
}

# --- Save backup + health helpers ---------------------------------------------

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
# that matches what the Server Manager writes, so the backup appears in its UI.
function Backup-LiveWorld {
    $worldDir = Get-ActiveWorldDir
    if (-not $worldDir) { Write-Log "Backup skipped: no active world found." Yellow; return }
    $guid  = Split-Path $worldDir -Leaf
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH_mm'
    $slot  = Join-Path $SaveLibraryRoot "Auto-backup_$stamp"
    $dest  = Join-Path $slot $guid
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

    # robocopy: fast, handles the deep backup\ tree; exit codes < 8 are success.
    robocopy $worldDir $dest /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Log "Backup FAILED (robocopy $LASTEXITCODE): $slot" Red; return }

    if (Test-Path $ActiveSettings) { Copy-Item $ActiveSettings (Join-Path $slot 'PalWorldSettings.ini') -Force }
    $parent = ''
    $marker = Join-Path $SaveLibraryRoot '.active-slot'
    if (Test-Path $marker) { $parent = (Get-Content $marker -Raw -Encoding UTF8).Trim() }
    $meta = [ordered]@{
        name="Auto-backup $stamp"; guid=$guid; created=(Get-Date -Format o)
        note="Pre-maintenance snapshot"; auto=$true; parent=$parent
    }
    ($meta | ConvertTo-Json) | Set-Content (Join-Path $slot 'slot.json') -Encoding UTF8
    Write-Log "Backup saved: $slot" Green
}

# Keep only the newest $BackupKeep pre-maintenance auto-backups (by folder name,
# which is timestamp-sortable). Only prunes the ones THIS script makes; named
# saves and Manager snapshots are left untouched.
function Prune-AutoBackups {
    $mine = Get-ChildItem $SaveLibraryRoot -Directory -EA SilentlyContinue |
            Where-Object { $_.Name -like 'Auto-backup_*' } |
            Sort-Object Name -Descending
    if ($mine.Count -le $BackupKeep) { return }
    foreach ($old in $mine[$BackupKeep..($mine.Count - 1)]) {
        try { Remove-Item $old.FullName -Recurse -Force -EA Stop; Write-Log "Pruned old backup: $($old.Name)" Cyan }
        catch { Write-Log "Could not prune $($old.Name): $($_.Exception.Message)" Yellow }
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
    if (-not $json) { Write-Log "Save health: report unavailable (python/save_health.py?)." Yellow; return }
    try { $h = $json | ConvertFrom-Json } catch { Write-Log "Save health: bad output." Yellow; return }
    if (-not $h.ok) { Write-Log "Save health error: $($h.error)" Yellow; return }

    $diskMB   = [math]::Round($h.levelDiskBytes   / 1MB, 1)
    $decompMB = [math]::Round($h.levelDecompBytes / 1MB, 1)
    $dpsMB    = [math]::Round($h.maxDpsDiskBytes  / 1MB, 1)
    Write-Log "Save health: Level.sav ${diskMB}MB disk / ${decompMB}MB decompressed, eggs=$($h.eggItems), max _dps=${dpsMB}MB" Green
    if ($diskMB     -ge $WarnLevelDiskMB) { Write-Log "WARNING: Level.sav is ${diskMB}MB on disk (>= ${WarnLevelDiskMB}MB). Consider an offline save cleanup." Red }
    if ($h.eggItems -ge $WarnEggItems)    { Write-Log "WARNING: $($h.eggItems) egg dynamic-item records (>= $WarnEggItems) - save bloat building up." Red }
}

# ── Startup ──────────────────────────────────────────────────────────────────

Write-Log "Maintenance script started." Cyan

if (-not (Get-Process | Where-Object { $_.Name -like "*PalServer*" })) {
    Write-Log "Server not running - starting it now..." Yellow
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$StartScript`""
    Write-Log "Server launched." Green
    Start-Sleep -Seconds 30   # give the server time to initialize
} else {
    Write-Log "Server is already running." Green
}

Write-Log "Maintenance at 9:00 AM daily." Cyan
Write-Log "Keep this window open. Press Ctrl+C to cancel." Yellow
Write-Host ""

# ── Main loop ─────────────────────────────────────────────────────────────────

while ($true) {

    # Build today's maintenance schedule
    $today       = (Get-Date).Date
    $t_warn30    = $today.AddHours(8).AddMinutes(30)
    $t_warn15    = $today.AddHours(8).AddMinutes(45)
    $t_warn5     = $today.AddHours(8).AddMinutes(55)
    $t_countdown = $today.AddHours(8).AddMinutes(59)
    $t_shutdown  = $today.AddHours(9)

    # If we've already passed today's shutdown, schedule for tomorrow
    if ((Get-Date) -ge $t_shutdown) {
        $today       = $today.AddDays(1)
        $t_warn30    = $today.AddHours(8).AddMinutes(30)
        $t_warn15    = $today.AddHours(8).AddMinutes(45)
        $t_warn5     = $today.AddHours(8).AddMinutes(55)
        $t_countdown = $today.AddHours(8).AddMinutes(59)
        $t_shutdown  = $today.AddHours(9)
    }

    Write-Log "Next maintenance: $($t_shutdown.ToString('yyyy-MM-dd HH:mm'))" Cyan

    # Status-log until 30-minute warning
    if ((Get-Date) -lt $t_warn30) {
        Wait-Until -Until $t_warn30
        Send-Broadcast "Server will shut down in 30 minutes for daily maintenance. Wrap up and save!"
    }

    # Status-log until 15-minute warning
    if ((Get-Date) -lt $t_warn15) {
        Wait-Until -Until $t_warn15
        Send-Broadcast "Server shutting down in 15 minutes for maintenance!"
    }

    # Status-log until 5-minute warning
    if ((Get-Date) -lt $t_warn5) {
        Wait-Until -Until $t_warn5
        Send-Broadcast "Server shutting down in 5 minutes for maintenance!"
    }

    # Status-log until 1-minute countdown
    if ((Get-Date) -lt $t_countdown) {
        Wait-Until -Until $t_countdown
    }

    # 1-minute in-game countdown
    Write-Log "Starting 1-minute shutdown countdown." Yellow
    Send-Broadcast "Server shutting down in 60 seconds!"
    Start-Sleep -Seconds 20
    Send-Broadcast "Server shutting down in 40 seconds!"
    Start-Sleep -Seconds 20
    Send-Broadcast "Server shutting down in 20 seconds!"
    Start-Sleep -Seconds 10
    Send-Broadcast "Server shutting down in 10 seconds!"
    Start-Sleep -Seconds 5
    Send-Broadcast "Server shutting down in 5 seconds!"
    Start-Sleep -Seconds 5

    # Shutdown
    Send-Broadcast "Server is shutting down NOW for maintenance. Back online soon!"
    Stop-PalServer

    # Pre-update safety: snapshot the world, report bloat, prune old snapshots.
    # Runs while the server is stopped so the save files are quiescent.
    Write-Log "Backing up world before update..." Cyan
    Backup-LiveWorld
    Report-SaveHealth
    Prune-AutoBackups

    # Update
    Write-Log "Running update script..." Cyan
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $InstallScript
    Write-Log "Update complete." Green

    # Restart
    Write-Log "Starting server..." Cyan
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$StartScript`""
    Write-Log "Server launched. Next maintenance cycle scheduled." Green
    Write-Host ""

    # Wait for server to come up before looping
    Start-Sleep -Seconds 60

}
