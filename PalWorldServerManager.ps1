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
          $ConfigFile, $SkipFlagFile, $MaintLogFile)

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

        Start-Sleep -Seconds 60
    }

} -ArgumentList $InstallScript, $StartScript, $AdminPassword, $RestApiBase,
                $ConfigFile, $SkipFlagFile, $MaintLogFile

# ── Dashboard Job ─────────────────────────────────────────────────────────────

$DashboardJob = Start-Job -Name "PalDashboard" -ScriptBlock {
    param($ServerDir, $AdminPassword, $PalApiBase, $DashPort, $StartScript,
          $ConfigFile, $SkipFlagFile, $MaintLogFile, $DefaultSettingsPath, $ActiveSettingsPath)

    $LogFile      = "$ServerDir\metrics-log.jsonl"
    $PollInterval = 300   # metrics-collection cadence (also the history-chart granularity)
    $SyncInterval = 60    # public-data R2 sync cadence -- how fresh the dashboards' data is
    $EggCheckInterval = 30   # egg-ready check cadence (re-parses only when Level.sav changed)

    # Per-player in-game "egg ready to hatch" alerts. egg_notify.json is the admin-set
    # opt-in list ({ "<8-hex prefix>": { enabled, name } }); .egg_notify_state.json is
    # the runtime high-water mark of the last ready-count we announced per player, so we
    # alert once per new ready egg rather than every poll. The game has no DM, so the
    # alert is a server-wide announce that names the player (see Check-EggNotifications).
    $EggNotifyFile      = "$ServerDir\egg_notify.json"
    $EggNotifyStateFile = "$ServerDir\.egg_notify_state.json"

    # Shared server-message feed helper (Add-ServerMessage / Get-ServerMessages) that
    # backs the dashboard chat banner. Dot-sourced so every broadcast site here records.
    . "$ServerDir\server_messages.ps1"

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
        Set-Content -Path $tmp -Encoding UTF8 -Value "[/Script/Pal.PalGameWorldSettings]`r`n$body`r`n"
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

    # ── Hand-confirmed map locations (Anthony's own live-play data) ──────────────
    # confirmed_locations.json holds flag-key -> {name,gx,gy} entries Anthony has
    # personally verified in-game via a companion save-watching script (Desktop
    # DataMine\palworld_full_save_dump.py, see the palworld-project skill). These
    # are the source of truth wherever they overlap a key in effigies.json /
    # journal_locations.json / bounty_bosses.json, which were sourced from a
    # public GitHub dataset or third-party wiki guides -- see Merge-Confirmed*
    # below, applied inside the /api/effigies, /api/journals, and
    # /api/bounty-bosses handlers.
    function Get-ConfirmedLocations {
        if ($null -eq $script:confirmedLocations) {
            $f = "$ServerDir\confirmed_locations.json"
            if (Test-Path -LiteralPath $f) {
                # NOTE: do NOT wrap the pipeline in @() here -- under Windows PowerShell 5.1
                # (what this Manager runs under), ConvertFrom-Json emits an already-parsed
                # JSON array as a SINGLE pipeline object rather than enumerating it, so @()
                # re-wraps that one object into a bogus 1-element array (confirmed via direct
                # test: a 47-element journal_locations.json collapsed to Count=1, which then
                # threw "cannot call a method on a null-valued expression" once code assumed
                # a normal array). Plain assignment handles 0/1/N-element JSON arrays correctly
                # on both PS 5.1 and PS 7.
                try { $script:confirmedLocations = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json }
                catch { $script:confirmedLocations = @() }
            } else {
                $script:confirmedLocations = @()
            }
        }
        return $script:confirmedLocations
    }

    # gx/gy (in-game grid coords) -> real world x/y. Inverse of the effigy
    # tooltip's cx=(y-158000)/459, cy=(x+123888)/459 -- see the
    # palbox-journal-overlay skill's coordinate-transform section.
    function ConvertTo-WorldXY([int]$gx, [int]$gy) {
        return @{ x = ($gy * 459) - 123888; y = ($gx * 459) + 158000 }
    }

    # Anthony wants ONLY his own confirmed locations on the map -- these Merge-Confirmed*
    # functions FILTER the base public/wiki-sourced data down to matches only (not overlay
    # onto the full set). NOTE: build with -InputObject rather than piping into
    # ConvertTo-Json -- piping a PowerShell array with exactly one element unwraps it into
    # a bare JSON object instead of a 1-item array (confirmed via direct test), which would
    # break the client's .forEach() the moment a filtered list happens to have one entry.
    function Merge-ConfirmedEffigies([string]$json) {
        $confirmed = Get-ConfirmedLocations
        try { $obj = $json | ConvertFrom-Json } catch { $obj = $null }
        $props = @{}
        if ($obj) { foreach ($p in $obj.PSObject.Properties) { $props[$p.Name.ToUpper()] = $p.Name } }
        $result = [ordered]@{}
        foreach ($c in $confirmed) {
            if ($props.ContainsKey($c.key.ToUpper())) {
                $xy = ConvertTo-WorldXY $c.gx $c.gy
                $result[$c.key] = @{ x = $xy.x; y = $xy.y; z = 0 }
            }
        }
        return (ConvertTo-Json -InputObject $result -Depth 6 -Compress)
    }

    function Merge-ConfirmedJournals([string]$json) {
        $confirmed = Get-ConfirmedLocations
        # No @() wrap -- see the note on Get-ConfirmedLocations above.
        try { $arr = $json | ConvertFrom-Json } catch { $arr = @() }
        if ($null -eq $arr) { $arr = @() }
        $byKey = @{}
        foreach ($c in $confirmed) { $byKey[$c.key.ToUpper()] = $c }
        $result = @()
        foreach ($entry in $arr) {
            if (-not $entry.key) { continue }
            $c = $byKey[$entry.key.ToUpper()]
            if ($c) {
                $xy = ConvertTo-WorldXY $c.gx $c.gy
                $entry.x = $xy.x
                $entry.y = $xy.y
                $entry.gx = $c.gx
                $entry.gy = $c.gy
                # Anthony's script is the source of truth -- override the name too,
                # not just the coordinates, if it has one for this key.
                if ($c.name) { $entry.name = $c.name }
                $result += $entry
            }
        }
        return (ConvertTo-Json -InputObject @($result) -Depth 6)
    }

    # Resolve a confirmed key to a bounty species via anonymous_boss_keys.json (the world
    # map is fixed, so a confirmed key/species pair holds for every save -- see the
    # palbox-bounty-tracker skill) plus literal species-named keys (BlueDragon/FairyDragon,
    # the two that self-name-tag in the save). Shared by Merge-ConfirmedBounty and
    # Get-ConfirmedLandmarks (which needs to know a key is already claimed as a bounty
    # species so it doesn't ALSO show up as a landmark).
    function Get-AnonymousBossKeyMap {
        $anonMap = @{}
        $anonFile = "$ServerDir\anonymous_boss_keys.json"
        if (Test-Path -LiteralPath $anonFile) {
            try {
                foreach ($e in (Get-Content -LiteralPath $anonFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.key -and $e.species) { $anonMap[$e.key.ToUpper()] = $e.species }
                }
            } catch {}
        }
        return $anonMap
    }

    function Merge-ConfirmedBounty([string]$json) {
        $confirmed = Get-ConfirmedLocations
        # No @() wrap -- see the note on Get-ConfirmedLocations above.
        try { $arr = $json | ConvertFrom-Json } catch { $arr = @() }
        if ($null -eq $arr) { $arr = @() }
        $anonMap = Get-AnonymousBossKeyMap
        $bySpecies = @{}
        foreach ($entry in $arr) { if ($entry.species) { $bySpecies[$entry.species.ToUpper()] = $entry } }
        $result = @()
        foreach ($c in $confirmed) {
            $species = $anonMap[$c.key.ToUpper()]
            if (-not $species) { $species = $c.key }
            $entry = $bySpecies[$species.ToUpper()]
            if ($entry) {
                $xy = ConvertTo-WorldXY $c.gx $c.gy
                $entry.x = $xy.x
                $entry.y = $xy.y
                if ($c.name) { $entry.name = $c.name }
                $result += $entry
            }
        }
        return (ConvertTo-Json -InputObject @($result) -Depth 6)
    }

    # "Wanted Fugitive" -- NPC/Syndicate boss defeat-flag keys (syndicate_bosses.json, e.g.
    # BOSS_MALE_SOLDIER02) that Anthony has personally located. Unlike bounty bosses these
    # carry no location at all in the base roster, so this is entirely sourced from
    # confirmed_locations.json, matched against the syndicate roster just to confirm the
    # key really is a human/Syndicate boss (not some other kind of flag) and to borrow its
    # roster label as a name fallback. No per-player found/unfound state (that would need
    # /api/player-datamine, which is admin-only and has no public-site route) -- static
    # named pins only, same as Landmarks below.
    function Get-ConfirmedWantedFugitives {
        $confirmed = Get-ConfirmedLocations
        $roster = @{}
        $synFile = "$ServerDir\syndicate_bosses.json"
        if (Test-Path -LiteralPath $synFile) {
            try {
                foreach ($e in (Get-Content -LiteralPath $synFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.key) { $roster[$e.key.ToUpper()] = $e.label }
                }
            } catch {}
        }
        $result = @()
        foreach ($c in $confirmed) {
            if ($roster.ContainsKey($c.key.ToUpper())) {
                $xy = ConvertTo-WorldXY $c.gx $c.gy
                $name = if ($c.name) { $c.name } else { $roster[$c.key.ToUpper()] }
                $result += @{ key = $c.key; name = $name; x = $xy.x; y = $xy.y }
            }
        }
        return (ConvertTo-Json -InputObject @($result) -Depth 6)
    }

    # "Eagle Statues" -- fast-travel points (FastTravelPointUnlockFlag), matched against
    # fast_travel_keys.json (a roster of confirmed fast-travel point GUIDs, grown from real
    # save data -- see pal_save_reader.py's extract_fast_travel_data). Static named pins
    # only, same as Landmarks -- Anthony didn't ask for per-player unlock tracking on these.
    function Get-ConfirmedEagleStatues {
        $confirmed = Get-ConfirmedLocations
        $roster = New-Object System.Collections.Generic.HashSet[string]
        $ftFile = "$ServerDir\fast_travel_keys.json"
        if (Test-Path -LiteralPath $ftFile) {
            try {
                foreach ($e in (Get-Content -LiteralPath $ftFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.key) { [void]$roster.Add($e.key.ToUpper()) }
                }
            } catch {}
        }
        $result = @()
        foreach ($c in $confirmed) {
            if ($roster.Contains($c.key.ToUpper())) {
                $xy = ConvertTo-WorldXY $c.gx $c.gy
                $name = if ($c.name) { $c.name } else { $c.key }
                $result += @{ key = $c.key; name = $name; x = $xy.x; y = $xy.y }
            }
        }
        return (ConvertTo-Json -InputObject @($result) -Depth 6)
    }

    # "NPC" -- NPCTalkCountMap keys, matched against npc_keys.json (a roster of confirmed
    # NPC GUIDs, grown from real save data -- see pal_save_reader.py's extract_npc_data).
    # Unlike Eagle Statues/Landmarks, this DOES get per-player tracking: /api/player-npcs
    # (below) marks an NPC "found" once its key shows up in that player's own
    # NPCTalkCountMap, same mechanism as effigies/journals/bounty.
    function Get-ConfirmedNPCs {
        $confirmed = Get-ConfirmedLocations
        $roster = New-Object System.Collections.Generic.HashSet[string]
        $npcFile = "$ServerDir\npc_keys.json"
        if (Test-Path -LiteralPath $npcFile) {
            try {
                foreach ($e in (Get-Content -LiteralPath $npcFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.key) { [void]$roster.Add($e.key.ToUpper()) }
                }
            } catch {}
        }
        $result = @()
        foreach ($c in $confirmed) {
            if ($roster.Contains($c.key.ToUpper())) {
                $xy = ConvertTo-WorldXY $c.gx $c.gy
                $name = if ($c.name) { $c.name } else { $c.key }
                $result += @{ key = $c.key; name = $name; x = $xy.x; y = $xy.y }
            }
        }
        return (ConvertTo-Json -InputObject @($result) -Depth 6)
    }

    # "Landmarks" -- everything else in confirmed_locations.json that isn't already
    # plotted as an effigy, journal note, bounty boss, Wanted Fugitive, Eagle Statue, or
    # NPC: discovered-area markers and any other named spot Anthony has confirmed. A
    # catch-all so a new category of confirmed location doesn't need its own plumbing to
    # show up somewhere on the map.
    function Get-ConfirmedLandmarks {
        $confirmed = Get-ConfirmedLocations
        $claimed = New-Object System.Collections.Generic.HashSet[string]
        $effFile = "$ServerDir\effigies.json"
        if (Test-Path -LiteralPath $effFile) {
            try {
                $effObj = Get-Content -LiteralPath $effFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($p in $effObj.PSObject.Properties) { [void]$claimed.Add($p.Name.ToUpper()) }
            } catch {}
        }
        $journalFile = "$ServerDir\journal_locations.json"
        if (Test-Path -LiteralPath $journalFile) {
            try {
                foreach ($e in (Get-Content -LiteralPath $journalFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
                }
            } catch {}
        }
        $anonMap = Get-AnonymousBossKeyMap
        $bountyFile = "$ServerDir\bounty_bosses.json"
        $bountySpecies = @{}
        if (Test-Path -LiteralPath $bountyFile) {
            try {
                foreach ($e in (Get-Content -LiteralPath $bountyFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.species) { $bountySpecies[$e.species.ToUpper()] = $true }
                }
            } catch {}
        }
        foreach ($c in $confirmed) {
            $species = $anonMap[$c.key.ToUpper()]
            if (-not $species) { $species = $c.key }
            if ($bountySpecies.ContainsKey($species.ToUpper())) { [void]$claimed.Add($c.key.ToUpper()) }
        }
        $synFile = "$ServerDir\syndicate_bosses.json"
        if (Test-Path -LiteralPath $synFile) {
            try {
                foreach ($e in (Get-Content -LiteralPath $synFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
                }
            } catch {}
        }
        $ftFile = "$ServerDir\fast_travel_keys.json"
        if (Test-Path -LiteralPath $ftFile) {
            try {
                foreach ($e in (Get-Content -LiteralPath $ftFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
                }
            } catch {}
        }
        $npcFile = "$ServerDir\npc_keys.json"
        if (Test-Path -LiteralPath $npcFile) {
            try {
                foreach ($e in (Get-Content -LiteralPath $npcFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
                }
            } catch {}
        }
        $result = @()
        foreach ($c in $confirmed) {
            if (-not $claimed.Contains($c.key.ToUpper())) {
                $xy = ConvertTo-WorldXY $c.gx $c.gy
                $name = if ($c.name) { $c.name } else { $c.key }
                $result += @{ key = $c.key; name = $name; x = $xy.x; y = $xy.y }
            }
        }
        return (ConvertTo-Json -InputObject @($result) -Depth 6)
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
        if (-not (Get-Process | Where-Object { $_.Name -like "*PalServer*" })) { return $true }
        try { Invoke-RestMethod -Uri "$PalApiBase/v1/api/save" -Method POST -Headers (Get-PalHeaders) -EA Stop | Out-Null } catch {}
        Start-Sleep -Seconds 3
        try {
            Invoke-RestMethod -Uri "$PalApiBase/v1/api/shutdown" -Method POST -Headers (Get-PalHeaders) `
                -Body (ConvertTo-Json @{ waittime=5; message="Switching world save - back shortly." }) -EA Stop | Out-Null
        } catch {}
        $waited = 0
        while ((Get-Process | Where-Object { $_.Name -like "*PalServer*" }) -and $waited -lt 60) {
            Start-Sleep -Seconds 2; $waited += 2
        }
        if (Get-Process | Where-Object { $_.Name -like "*PalServer*" }) {
            Get-Process | Where-Object { $_.Name -like "*PalServer*" } | Stop-Process -Force -EA SilentlyContinue
            Start-Sleep -Seconds 3
        }
        return -not [bool](Get-Process | Where-Object { $_.Name -like "*PalServer*" })
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
        $lines = @(Get-Content $LogFile -Encoding UTF8)
        if ($lines.Count -gt 2016) { $lines[-2016..-1] | Set-Content $LogFile -Encoding UTF8 }
    }

    function CollectMetrics {
        try {
            Sync-PlaytimeToActiveWorld
            $m = Invoke-RestMethod -Uri "$PalApiBase/v1/api/metrics" -Method GET -Headers (Get-PalHeaders) -EA Stop
            $p = Invoke-RestMethod -Uri "$PalApiBase/v1/api/players" -Method GET -Headers (Get-PalHeaders) -EA Stop
            $playerList   = if ($p.players) { @($p.players) } elseif ($p.Players) { @($p.Players) } else { @() }
            $currentNames = @($playerList | Where-Object { $_.name } | ForEach-Object { $_.name })
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
                $name = $pl.name; if (-not $name) { continue }
                if (-not $script:playtime.ContainsKey($name)) {
                    $script:playtime[$name] = @{ totalSeconds=0L; sessions=0; lastSeen=''; avgPing=0.0; sampleCount=0; steamid='' }
                }
                if (-not $script:onlinePlayers.ContainsKey($name)) {
                    $script:onlinePlayers[$name] = Get-Date
                    $script:playtime[$name].sessions++
                }
                $script:playtime[$name].totalSeconds += $PollInterval
                $script:playtime[$name].lastSeen      = $entry.ts
                $sid = if ($pl.steamid) { [string]$pl.steamid } elseif ($pl.playeruid) { [string]$pl.playeruid } else { '' }
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

    $HtmlPage = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PalWorld Server Admin</title>
<style>
:root {
  --bg:#0d1117; --surface:#161b22; --surface2:#21262d; --border:#30363d;
  --text:#c9d1d9; --muted:#8b949e;
  --green:#3fb950; --red:#f85149; --yellow:#e3b341; --blue:#58a6ff; --purple:#a371f7;
}
*{box-sizing:border-box;margin:0;padding:0;}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;font-size:14px;}
/* Kill the browser focus outline Leaflet's interactive SVG markers get on click -- it
   shows as a stray white ring around an effigy/spawn marker that lingers after clicking. */
.leaflet-interactive:focus{outline:none;}
/* Effigy marker tooltip: a touch larger and roomier than Leaflet's default. */
.eff-tip{font-size:13px;line-height:1.45;padding:5px 9px;}
/* Effigy + journal map markers: icon glyphs (Flaticon, see footer credit) instead of plain
   dots - full color for uncollected, grey/faded for already-found. Shared across the acorn
   (effigy) and book (journal) markers since the sizing/hover/found behavior is identical.
   Drop-shadow doubles as the hover ring since divIcons aren't SVG-restylable like
   circleMarker was. */
.eff-map-marker{filter:drop-shadow(0 0 1px rgba(0,0,0,.6));transition:transform .12s ease,opacity .12s ease;}
.eff-map-marker img{width:100%;height:100%;display:block;pointer-events:none;}
.eff-map-marker.eff-map-found{opacity:.55;}
.eff-map-marker.eff-map-hover{transform:scale(1.35);opacity:1;filter:drop-shadow(0 0 3px #f0c000) drop-shadow(0 0 1px rgba(0,0,0,.6));}
/* Bounty-boss (named Alpha) marker: circular portrait ring, same divIcon plumbing as
   effigies/journals above but with the Pal's own portrait instead of a glyph, and a
   grayscale wash (not just the shared opacity fade) when defeated so it reads as "spent". */
.bounty-marker .bounty-ring{width:100%;height:100%;border-radius:50%;overflow:hidden;border:2px solid #e3b341;box-shadow:0 1px 4px rgba(0,0,0,.85);background:#1a1a1a;}
.bounty-marker img{border-radius:50%;object-fit:cover;}
.bounty-marker.eff-map-found .bounty-ring{border-color:#484f58;filter:grayscale(1) brightness(.65);}

/* Header */
header{background:var(--surface);border-bottom:1px solid var(--border);padding:0 20px;height:52px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:100;}
.hdr-left{display:flex;align-items:center;gap:10px;}
.logo{font-size:18px;font-weight:700;letter-spacing:-.3px;}
.logo span{color:var(--green);}
.status-dot{width:9px;height:9px;border-radius:50%;background:var(--muted);transition:background .4s,box-shadow .4s;}
.status-dot.online{background:var(--green);box-shadow:0 0 6px var(--green);}
.status-dot.offline{background:var(--red);}
.hdr-right{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:12px;}
.btn-icon{background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 10px;border-radius:6px;cursor:pointer;font-size:12px;font-family:inherit;}
.btn-icon:hover{background:var(--border);}

/* Layout */
.page{padding:14px 16px;display:flex;flex-direction:column;gap:12px;}

/* Stats bar */
.stats-bar{display:flex;gap:10px;}
.stat-card{flex:1;background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:12px 14px;}
.stat-label{font-size:10px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted);margin-bottom:5px;}
.stat-val{font-size:24px;font-weight:700;color:var(--blue);line-height:1;}
.stat-val.good{color:var(--green)}.stat-val.warn{color:var(--yellow)}.stat-val.bad{color:var(--red)}.stat-val.sm{font-size:14px;padding-top:5px;}
.stat-sub{font-size:10px;color:var(--muted);margin-top:4px;}

/* Mid row */
.mid-row{display:flex;gap:12px;}
.mid-row .panel-players{flex:7;min-width:0;}
.mid-row .panel-actions{flex:5;min-width:260px;}

/* Charts row */
.charts-row{display:flex;gap:12px;}
.charts-row .panel{flex:1;min-width:0;}

/* Panel */
.panel{background:var(--surface);border:1px solid var(--border);border-radius:10px;display:flex;flex-direction:column;overflow:hidden;}
.panel-header{padding:9px 14px;border-bottom:1px solid var(--border);font-weight:600;font-size:13px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0;background:var(--surface2);}
.panel-body{flex:1;overflow:auto;}
.badge{background:var(--surface);border:1px solid var(--border);border-radius:20px;padding:2px 8px;font-size:11px;color:var(--muted);font-weight:400;}

/* Table */
table{width:100%;border-collapse:collapse;}
th{text-align:left;padding:8px 14px;font-size:11px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);border-bottom:1px solid var(--border);background:var(--surface2);position:sticky;top:0;z-index:1;}
td{padding:9px 14px;border-bottom:1px solid var(--border);vertical-align:middle;}
tr:last-child td{border-bottom:none;}
tr:hover td{background:rgba(255,255,255,.02);}
.player-name{font-weight:500;}
.ping-good{color:var(--green)}.ping-ok{color:var(--yellow)}.ping-bad{color:var(--red)}
.empty-state{padding:40px 16px;text-align:center;color:var(--muted);}
.empty-state.err{color:var(--red);}

/* Buttons */
.btn{padding:5px 10px;border-radius:6px;border:1px solid var(--border);cursor:pointer;font-size:12px;font-family:inherit;transition:all .12s;display:inline-flex;align-items:center;gap:4px;}
.btn:disabled{opacity:.35;cursor:not-allowed;}
.btn-ghost{background:transparent;color:var(--muted);}
.btn-ghost:hover:not(:disabled){background:var(--surface2);color:var(--text);}
.btn-primary{background:var(--blue);color:#0d1117;border-color:var(--blue);font-weight:600;}
.btn-primary:hover:not(:disabled){opacity:.85;}
.btn-green{background:transparent;color:var(--green);border-color:var(--green);}
.btn-green:hover:not(:disabled){background:rgba(63,185,80,.1);}
.btn-warn{background:transparent;color:var(--yellow);border-color:var(--yellow);}
.btn-warn:hover:not(:disabled){background:rgba(227,179,65,.1);}
.btn-danger{background:transparent;color:var(--red);border-color:var(--red);}
.btn-danger:hover:not(:disabled){background:rgba(248,81,73,.1);}
.btn-full{width:100%;justify-content:center;padding:8px;font-size:13px;}

/* Actions panel */
.actions-inner{padding:14px;display:flex;flex-direction:column;gap:14px;overflow-y:auto;}
.action-group{display:flex;flex-direction:column;gap:7px;}
.action-label{font-size:11px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted);font-weight:600;}
hr.divider{border:none;border-top:1px solid var(--border);}
input[type=text],input[type=number],textarea{width:100%;background:var(--surface2);border:1px solid var(--border);border-radius:6px;padding:6px 9px;color:var(--text);font-family:inherit;font-size:13px;outline:none;}
input:focus,textarea:focus{border-color:var(--blue);}
textarea{resize:vertical;min-height:58px;}
.row{display:flex;gap:8px;}
.row input[type=number]{width:68px;flex-shrink:0;text-align:center;}
.hint{font-size:11px;color:var(--muted);}

/* Maintenance */
.maint-row{display:flex;justify-content:space-between;align-items:center;font-size:12px;padding:2px 0;}
.maint-key{color:var(--muted);}
.maint-log-box{font-family:'Cascadia Code','Consolas',monospace;font-size:10px;color:var(--muted);padding:6px 8px;background:var(--bg);border-radius:4px;border:1px solid var(--border);max-height:80px;overflow-y:auto;line-height:1.5;}
.time-row{display:flex;gap:6px;align-items:center;}
.time-row input[type=number]{width:52px;flex-shrink:0;text-align:center;padding:4px 6px;}

/* Charts */
.chart-body{padding:8px 10px 6px;height:180px;display:flex;flex-direction:column;}
.chart-body canvas{flex:1;display:block;width:100%;}

/* Settings editor */
.tab-bar{display:flex;gap:3px;padding:8px 14px 0;overflow-x:auto;border-bottom:1px solid var(--border);flex-shrink:0;scrollbar-width:none;}
.tab-bar::-webkit-scrollbar{display:none;}
.tab{padding:5px 12px;font-size:12px;cursor:pointer;color:var(--muted);border-radius:6px 6px 0 0;border:1px solid transparent;border-bottom:none;white-space:nowrap;transition:color .12s;user-select:none;}
.tab:hover{color:var(--text);}
.tab.active{background:var(--surface);border-color:var(--border);color:var(--text);font-weight:600;margin-bottom:-1px;}
.tab-dot{display:inline-block;width:5px;height:5px;border-radius:50%;background:var(--yellow);margin-left:4px;vertical-align:middle;}
.settings-grid{padding:10px 14px;display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:7px;max-height:500px;overflow-y:auto;}
.setting-row{display:flex;align-items:flex-start;gap:12px;padding:8px 10px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;transition:border-color .15s;}
.setting-row.modified{border-color:var(--yellow);}
.setting-info{flex:1;min-width:0;}
.setting-name{font-size:12px;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.setting-desc{font-size:11px;color:var(--muted);margin-top:2px;}
.setting-def{font-size:10px;color:var(--border);margin-top:1px;}
.setting-ctrl{flex-shrink:0;display:flex;align-items:center;}
.setting-ctrl input[type=text],.setting-ctrl input[type=number]{width:110px;padding:4px 6px;font-size:12px;}
.setting-ctrl select{background:var(--surface);border:1px solid var(--border);border-radius:6px;padding:4px 6px;color:var(--text);font-family:inherit;font-size:12px;cursor:pointer;outline:none;}
.setting-ctrl select:focus{border-color:var(--blue);}

/* Toggle switch */
.toggle{position:relative;display:inline-block;width:36px;height:20px;flex-shrink:0;}
.toggle input{opacity:0;width:0;height:0;position:absolute;}
.tog-sl{position:absolute;cursor:pointer;inset:0;background:#30363d;border-radius:20px;transition:.2s;}
.tog-sl:before{content:'';position:absolute;height:14px;width:14px;left:3px;bottom:3px;background:#8b949e;border-radius:50%;transition:.2s;}
input:checked+.tog-sl{background:var(--green);}
input:checked+.tog-sl:before{transform:translateX(16px);background:#fff;}

/* Top-level nav tabs */
.nav-tab{position:relative;padding:4px 14px;font-size:13px;cursor:pointer;color:var(--muted);border-radius:6px;border:1px solid transparent;background:transparent;font-family:inherit;font-weight:500;transition:color .12s,background .12s,border-color .12s;}
.nav-tab:hover{color:var(--text);background:var(--surface2);}
.nav-tab.active{color:var(--text);background:var(--surface2);border-color:var(--border);}
.nav-tab.has-new::after{content:'';position:absolute;top:2px;right:2px;width:7px;height:7px;border-radius:50%;background:#ffd84d;animation:tabNewPulse 1.4s ease-out infinite;}
@keyframes tabNewPulse{0%{box-shadow:0 0 0 0 rgba(255,216,77,.65);}70%{box-shadow:0 0 0 6px rgba(255,216,77,0);}100%{box-shadow:0 0 0 0 rgba(255,216,77,0);}}

/* Tags */
.tag{display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;font-weight:500;}
.tag-green{background:rgba(63,185,80,.15);color:var(--green);}
.tag-red{background:rgba(248,81,73,.15);color:var(--red);}
.tag-yellow{background:rgba(227,179,65,.15);color:var(--yellow);}
.tag-blue{background:rgba(88,166,255,.15);color:var(--blue);}
.tag-muted{background:rgba(139,148,158,.15);color:var(--muted);}

/* Toasts */
#toasts{position:fixed;bottom:20px;right:20px;display:flex;flex-direction:column;gap:8px;z-index:9999;}
.toast{background:var(--surface2);border:1px solid var(--border);border-radius:8px;padding:11px 15px;font-size:13px;max-width:340px;animation:fadeIn .18s ease;}
.toast.success{border-left:3px solid var(--green);}
.toast.error{border-left:3px solid var(--red);}
.toast.info{border-left:3px solid var(--blue);}
.toast.warn{border-left:3px solid var(--yellow);}
@keyframes fadeIn{from{opacity:0;transform:translateX(12px);}to{opacity:1;transform:none;}}

/* ── Responsive ── */
@media(max-width:640px){
  /* Prevent iOS input zoom */
  input,textarea,select{font-size:16px!important;}

  header{padding:6px 10px;gap:6px 8px;height:auto;min-height:52px;flex-wrap:wrap;}
  .hdr-mid{display:none;}
  .logo{font-size:16px;white-space:nowrap;}
  .page{padding:10px;gap:10px;}

  /* Header nav: when the logo + update time fill the top row, the tabs drop onto
     their own full-width row below instead of squashing/scrolling on the top row.
     hdr-right is ordered before nav so the top row reads "logo ... updated" with
     the tabs underneath; overflow-x stays as a fallback if the tabs alone are
     wider than the screen. */
  .hdr-left{order:1;}
  .hdr-right{order:2;gap:6px;flex-shrink:0;}
  nav{order:3;flex:1 1 100%;min-width:0;justify-content:flex-start;overflow-x:auto;overflow-y:hidden;scrollbar-width:none;}
  nav::-webkit-scrollbar{display:none;}
  .nav-tab{padding:4px 11px;white-space:nowrap;flex-shrink:0;}

  /* Stats: 3 per row */
  .stats-bar{flex-wrap:wrap;}
  .stat-card{flex:0 0 calc(33.33% - 7px);min-width:0;}
  .stat-val{font-size:20px;}

  /* Mid row: stack vertically, actions second */
  .mid-row{flex-direction:column;}
  .mid-row .panel-actions{min-width:0;}

  /* Charts: 2 per row */
  .charts-row{flex-wrap:wrap;}
  .charts-row .panel{flex:0 0 calc(50% - 6px);min-width:0;}
  .chart-body{height:130px;}

  /* Settings grid: single column, no height cap */
  .settings-grid{grid-template-columns:1fr;max-height:none;padding:8px 10px;}

  /* Panel header: allow button row to wrap */
  .panel-header{flex-wrap:wrap;gap:6px;}

  /* Player table: scroll horizontally instead of mangling columns */
  #player-area,#playtime-area{overflow-x:auto;}

  /* Toasts: full-width at bottom */
  #toasts{left:10px;right:10px;bottom:10px;}
  .toast{max-width:none;}
}

/* ---- Pal Box ---- */
.pal-group-hdr{display:flex;align-items:center;gap:8px;margin:14px 4px 8px;font-size:13px;font-weight:600;color:var(--text);}
.pal-group-hdr .cnt{color:var(--muted);font-weight:400;font-size:12px;}
.pal-group-hdr::after{content:"";flex:1;height:1px;background:var(--border);}
.pal-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:10px;}
.pal-card{background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:10px;display:flex;flex-direction:column;gap:7px;position:relative;}
.pal-card.alpha{border-color:#d29922;}
.pal-card.lucky{border-color:#e3b341;box-shadow:0 0 0 1px rgba(227,179,65,.25);}
.pal-card-top{display:flex;gap:9px;align-items:center;}
.pal-portrait{width:46px;height:46px;border-radius:8px;background:var(--surface);object-fit:contain;flex-shrink:0;}
.pal-name{font-weight:600;font-size:15px;line-height:1.2;display:flex;align-items:center;flex-wrap:wrap;gap:5px;}
.pal-nick{font-size:11px;color:var(--yellow);font-style:italic;line-height:1.2;}
.pal-sub{font-size:11px;color:var(--muted);margin-top:1px;}
.pal-badges{display:flex;gap:4px;flex-wrap:wrap;margin-top:2px;}
.pal-badge{font-size:9.5px;font-weight:700;padding:1px 5px;border-radius:4px;letter-spacing:.3px;text-transform:uppercase;}
.pb-alpha{background:rgba(210,153,34,.18);color:#e3b341;}
.pb-lucky{background:rgba(227,179,65,.2);color:#f0c84a;}
.pb-loc{background:var(--surface);color:var(--muted);text-transform:none;font-weight:600;letter-spacing:0;}
.pb-male{background:rgba(88,166,255,.16);color:#58a6ff;}
.pb-female{background:rgba(247,129,182,.16);color:#f781b6;}
.pal-ivs{display:flex;flex-direction:column;gap:3px;}
.iv-row{display:flex;align-items:center;gap:6px;font-size:10px;color:var(--muted);}
.iv-row .lbl{width:26px;flex-shrink:0;}
.iv-row .val{width:24px;text-align:right;color:var(--text);font-variant-numeric:tabular-nums;}
.iv-bar{flex:1;height:5px;border-radius:3px;background:var(--surface);overflow:hidden;}
.iv-fill{height:100%;border-radius:3px;}
.pal-chips{display:flex;gap:3px;flex-wrap:wrap;}
.pal-chip{font-size:10px;padding:1px 6px;border-radius:4px;background:var(--surface);color:var(--muted);border:1px solid var(--border);}
.pal-stars{color:#e3b341;font-size:11px;letter-spacing:1px;}
/* Pals page advanced filter bar */
.pf-badge{background:#58a6ff;color:#fff;border-radius:10px;font-size:10px;font-weight:700;padding:0 5px;margin-left:5px;}
.pf-panel{display:none;padding:12px 14px;border-bottom:1px solid var(--border);background:var(--surface);}
.pf-panel.open{display:block;}
.pf-grid{display:flex;flex-wrap:wrap;gap:18px;}
.pf-group{display:flex;flex-direction:column;gap:7px;}
.pf-label{font-size:10px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);font-weight:700;}
.pf-chips{display:flex;flex-wrap:wrap;gap:5px;align-items:center;}
.pf-chip{display:inline-flex;align-items:center;gap:4px;background:var(--surface2);border:1px solid var(--border);border-radius:7px;padding:3px 8px;font-size:12px;cursor:pointer;user-select:none;color:var(--muted);}
.pf-chip img{width:16px;height:16px;}
.pf-chip:hover{border-color:#58a6ff;}
.pf-chip.on{background:rgba(88,166,255,.18);border-color:#58a6ff;color:var(--text);}
.pf-input{background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;}
.pf-num{width:62px;}
.pf-seg{display:inline-flex;border:1px solid var(--border);border-radius:7px;overflow:hidden;}
.pf-seg button{background:var(--surface2);color:var(--muted);border:0;border-left:1px solid var(--border);padding:4px 11px;font-size:12px;cursor:pointer;font-family:inherit;}
.pf-seg button:first-child{border-left:0;}
.pf-seg button.on{background:#58a6ff;color:#fff;}
.pf-pass-sel{display:flex;flex-wrap:wrap;gap:5px;align-items:center;}
.pf-pass-chip{display:inline-flex;align-items:center;gap:4px;background:rgba(88,166,255,.16);border:1px solid #58a6ff;border-radius:7px;padding:2px 4px 2px 9px;font-size:12px;color:var(--text);}
.pf-pass-chip b{cursor:pointer;color:var(--muted);font-weight:700;padding:0 3px;}
.pf-pass-chip b:hover{color:#f85149;}
.pf-flag{display:flex;align-items:center;gap:5px;font-size:12px;color:var(--muted);cursor:pointer;}
</style>
</head>
<body>

<header>
  <div class="hdr-left">
    <div class="status-dot" id="dot"></div>
    <div class="logo">Server<span>Six</span> Admin</div>
  </div>
  <nav style="display:flex;gap:2px;">
    <button class="nav-tab active" data-tab="dashboard" onclick="switchView('dashboard')">Dashboard</button>
    <button class="nav-tab" data-tab="pals" onclick="switchView('pals')">Pals</button>
    <button class="nav-tab" data-tab="eggs" onclick="switchView('eggs')">Eggs</button>
    <button class="nav-tab" data-tab="paldeck" onclick="switchView('paldeck')">Paldeck</button>
    <button class="nav-tab" data-tab="effigies" onclick="switchView('effigies')">Map</button>
    <button class="nav-tab" data-tab="datamine" onclick="switchView('datamine')">Data Mine</button>
  </nav>
  <div class="hdr-right">
    <button class="btn-icon" id="msglog-toggle" onclick="toggleMsgLog()" title="Server message history (last 24h)">&#128220;</button>
    <button class="btn-icon" id="snd-toggle" onclick="toggleChatSound()" title="Notification sound for server messages">&#128276;</button>
    <button class="btn btn-green" id="btn-start-hdr" onclick="startServer()" style="display:none">&#9654; Start Server</button>
    <span class="hdr-mid">Updated <b id="last-updated">-</b> &bull; refresh in <b id="countdown">5:00</b></span>
    <button class="btn-icon" onclick="refreshAll()">&#8635; Refresh</button>
  </div>
</header>

<div id="msglog-panel" class="msglog-panel" style="display:none;">
  <div class="msglog-hdr"><span>Message Log <span style="color:var(--muted);font-weight:400;">(24h)</span></span><button onclick="toggleMsgLog()" title="Close">&times;</button></div>
  <div class="msglog-body" id="msglog-body"><div class="empty-state">No messages yet.</div></div>
</div>

<div id="view-dashboard" class="page">

  <!-- Stats bar -->
  <div class="stats-bar">
    <div class="stat-card"><div class="stat-label">Players</div><div class="stat-val" id="s-players">-</div><div class="stat-sub" id="s-players-sub">of ? max</div></div>
    <div class="stat-card"><div class="stat-label">FPS</div><div class="stat-val" id="s-fps">-</div><div class="stat-sub" id="s-fps-sub">frame rate</div></div>
    <div class="stat-card"><div class="stat-label">Uptime</div><div class="stat-val" id="s-uptime">-</div><div class="stat-sub" id="s-uptime-sub">&nbsp;</div></div>
    <div class="stat-card"><div class="stat-label">Base Camps</div><div class="stat-val" id="s-bases">-</div><div class="stat-sub">active</div></div>
    <div class="stat-card"><div class="stat-label">Day</div><div class="stat-val" id="s-days">-</div><div class="stat-sub">in-game</div></div>
    <div class="stat-card"><div class="stat-label">Version</div><div class="stat-val sm" id="s-version">-</div><div class="stat-sub">build</div></div>
  </div>

  <!-- Players + Actions -->
  <div class="mid-row">
    <div class="panel panel-players">
      <div class="panel-header">
        <span>Online Players</span>
        <span class="badge" id="player-badge">0</span>
      </div>
      <div class="panel-body" id="player-area"><div class="empty-state">Loading...</div></div>
    </div>

    <div class="panel panel-actions">
      <div class="panel-header"><span>Server Controls</span></div>
      <div class="panel-body">
        <div class="actions-inner">

          <div class="action-group">
            <div class="action-label">Broadcast</div>
            <textarea id="msg" placeholder="Message to all players..."></textarea>
            <button class="btn btn-primary btn-full" onclick="sendMsg()">Send Message</button>
          </div>

          <hr class="divider">
          <div class="action-group">
            <div class="action-label">Egg Hatch Alerts</div>
            <div class="hint" style="margin-bottom:6px">In-game alert when an enabled player's egg is ready &mdash; only while they're online. (Broadcast to all; PalWorld has no private messages.)</div>
            <div id="egg-notify-list"><div class="empty-state" style="padding:6px">Loading...</div></div>
          </div>

          <hr class="divider">
          <div class="action-group">
            <div class="action-label">World</div>
            <button class="btn btn-green btn-full" onclick="saveWorld()">&#128190; Save World</button>
          </div>

          <hr class="divider">
          <div class="action-group">
            <div class="action-label">Reboot Server</div>
            <div class="row">
              <input type="number" id="reboot-secs" value="60" min="10" max="600" title="Warning seconds">
              <button class="btn btn-warn btn-full" onclick="rebootServer()">Reboot</button>
            </div>
            <div class="hint">Broadcasts countdown then restarts.</div>
          </div>

          <hr class="divider">
          <div class="action-group">
            <div class="action-label">Shutdown Server</div>
            <div class="row">
              <input type="number" id="shutdown-secs" value="60" min="10" max="600" title="Warning seconds">
              <button class="btn btn-warn btn-full" onclick="shutdownServer()">Shutdown</button>
            </div>
            <div class="hint">Broadcasts countdown, saves, then stops. Stays offline until you start it.</div>
          </div>

          <hr class="divider">
          <div class="action-group">
            <div class="action-label">Maintenance</div>
            <div class="maint-row"><span class="maint-key">Next:</span><b id="maint-next-time">Loading...</b></div>
            <div class="maint-row" style="margin-top:4px">
              <span class="maint-key">Time:</span>
              <div class="time-row">
                <input type="number" id="maint-hour" min="0" max="23" value="4">
                <span style="color:var(--muted);font-size:14px;font-weight:600">:</span>
                <input type="number" id="maint-min" min="0" max="59" value="0">
                <button class="btn btn-ghost" onclick="saveMaintTime()" style="padding:4px 8px">Set</button>
              </div>
            </div>
            <div class="row" style="margin-top:4px">
              <button class="btn btn-warn btn-full" id="btn-skip" onclick="toggleSkip()">Skip Next</button>
              <button class="btn btn-ghost btn-full" onclick="startServer()">Start Server</button>
            </div>
            <div id="maint-log" class="maint-log-box" style="margin-top:6px">No log yet.</div>
          </div>

          <hr class="divider">
          <div class="action-group">
            <div class="action-label">Danger Zone</div>
            <button class="btn btn-danger btn-full" onclick="forceStop()">&#9889; Force Stop</button>
          </div>

        </div>
      </div>
    </div>
  </div>

  <!-- Charts -->
  <div class="charts-row">
    <div class="panel"><div class="panel-header"><span>Players Online <span style="font-weight:400;font-size:11px;color:var(--muted)">(24h)</span></span></div><div class="chart-body"><canvas id="chart-players"></canvas></div></div>
    <div class="panel"><div class="panel-header"><span>Server FPS <span style="font-weight:400;font-size:11px;color:var(--muted)">(24h)</span></span></div><div class="chart-body"><canvas id="chart-fps"></canvas></div></div>
    <div class="panel"><div class="panel-header"><span>Avg Ping ms <span style="font-weight:400;font-size:11px;color:var(--muted)">(24h)</span></span></div><div class="chart-body"><canvas id="chart-ping"></canvas></div></div>
    <div class="panel"><div class="panel-header"><span>Frame Time ms <span style="font-weight:400;font-size:11px;color:var(--muted)">(24h)</span></span></div><div class="chart-body"><canvas id="chart-frametime"></canvas></div></div>
  </div>

  <!-- Player Stats -->
  <div class="panel">
    <div class="panel-header"><span>Player Stats</span></div>
    <div class="panel-body" id="playtime-area"><div class="empty-state">No data yet &mdash; stats accumulate as players connect.</div></div>
  </div>

  <!-- Save Manager -->
  <div class="panel">
    <div class="panel-header">
      <span>Save Manager</span>
      <div style="display:flex;gap:8px;align-items:center">
        <span class="badge" id="saves-active-badge">-</span>
        <label class="hint" style="display:flex;align-items:center;gap:5px;cursor:pointer"><input type="checkbox" id="restart-after" checked style="width:auto"> Restart after switching</label>
        <button class="btn btn-ghost" onclick="fetchSaves()">&#8635; Reload</button>
      </div>
    </div>
    <div class="actions-inner" style="border-bottom:1px solid var(--border)">
      <div class="action-group">
        <div class="action-label">Save current world to library</div>
        <div class="row">
          <input type="text" id="capture-name" placeholder="Name e.g. Before the boss fight">
          <button class="btn btn-green" onclick="captureSave()" style="white-space:nowrap">&#128190; Save Copy</button>
        </div>
        <div class="hint">Copies the live world into your library without affecting the running game. Library copies are kept until you delete them, so you can always revert.</div>
      </div>
      <hr class="divider">
      <div class="action-group">
        <div class="action-label">Create a new world</div>
        <div class="row">
          <input type="text" id="newworld-name" placeholder="Name e.g. Fresh Start">
          <button class="btn btn-primary" onclick="newWorld()" style="white-space:nowrap">&#10010; New World</button>
        </div>
        <div class="hint">Backs up the current world, then starts a brand-new empty world using your current server settings. Uses the &ldquo;Restart after switching&rdquo; toggle.</div>
      </div>
    </div>
    <div class="panel-body" id="saves-area"><div class="empty-state">Loading...</div></div>
  </div>

  <!-- Settings Editor -->
  <div class="panel">
    <div class="panel-header">
      <span>Server Settings</span>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:flex-end">
        <span class="hint">Editing:</span>
        <select id="settings-target" onchange="changeSettingsTarget()"><option value="">Active world &mdash; live</option></select>
        <span id="dirty-badge" class="badge" style="display:none;color:var(--yellow);border-color:var(--yellow)"></span>
        <button class="btn btn-ghost" onclick="reloadSettings()">&#8635; Reload</button>
        <button class="btn btn-ghost" onclick="resetDirty()">Discard</button>
        <button class="btn btn-warn" onclick="resetTabToDefaults()">Reset Tab to Defaults</button>
        <button class="btn btn-primary" onclick="saveFileSettings()">Save Settings</button>
      </div>
    </div>
    <div id="settings-tab-bar" class="tab-bar"><div class="empty-state" style="padding:12px">Loading settings...</div></div>
    <div id="settings-grid" class="settings-grid"></div>
  </div>

</div>

<div id="view-paldeck" class="page" style="display:none">
  <div class="panel">
    <div class="panel-header">
      <span>Paldeck</span>
      <div style="display:flex;gap:8px;align-items:center">
        <select id="paldeck-player" onchange="renderPaldeck()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;min-width:120px;"></select>
        <span id="paldeck-summary" style="color:var(--muted);font-size:12px;"></span>
        <button class="btn btn-ghost" onclick="fetchPaldeck()">&#8635; Reload</button>
      </div>
    </div>
    <div class="panel-body" id="paldeck-area"><div class="empty-state">Loading...</div></div>
  </div>
</div>

<div id="view-effigies" class="page" style="display:none;height:calc(100vh - 52px);overflow:hidden;box-sizing:border-box;">
  <div class="panel" style="flex:1;min-height:0;">
    <div class="panel-header">
      <span>Lifmunk Effigy Tracker</span>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
        <select id="effigy-player" onchange="fetchEffigyPlayer()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;min-width:120px;"></select>
        <span id="effigy-summary" style="color:var(--muted);font-size:12px;"></span>
        <span style="font-size:11px;display:inline-flex;gap:6px;align-items:center;">
          <button id="eff-filt-new" onclick="toggleEffigyFilter('new')" class="btn btn-ghost" style="font-size:11px;padding:2px 8px;" title="Show / hide effigies you have not found yet"><span style="color:#3fb950;">&#9679;</span> New</button>
          <button id="eff-filt-found" onclick="toggleEffigyFilter('found')" class="btn btn-ghost" style="font-size:11px;padding:2px 8px;" title="Show / hide effigies you have already found"><span style="color:#484f58;">&#9679;</span> Found</button>
          <button id="eff-filt-journal" onclick="toggleEffigyFilter('journal')" class="btn btn-ghost" style="font-size:11px;padding:2px 8px;" title="Show / hide journal / diary note locations"><span style="color:#3399ff;">&#9679;</span> Journals</button>
          <span id="journal-summary" style="color:var(--muted);font-size:11px;" title="Journal / diary notes collected, from the save (individual notes on the map aren't matched to specific locations yet)"></span>
          <button id="eff-filt-bounty" onclick="toggleEffigyFilter('bounty')" class="btn btn-ghost" style="font-size:11px;padding:2px 8px;" title="Show / hide named Alpha boss (Bounty Token) locations"><span style="color:#e3b341;">&#9679;</span> Field Boss</button>
          <span id="bounty-summary" style="color:var(--muted);font-size:11px;" title="Named legendary Alpha bosses defeated, from the save"></span>
          <button id="eff-filt-fugitive" onclick="toggleEffigyFilter('fugitive')" class="btn btn-ghost" style="font-size:11px;padding:2px 8px;" title="Show / hide human/Syndicate boss (Wanted Fugitive) locations"><span style="color:#f85149;">&#9679;</span> Wanted Fugitive</button>
          <button id="eff-filt-eagle" onclick="toggleEffigyFilter('eagle')" class="btn btn-ghost" style="font-size:11px;padding:2px 8px;" title="Show / hide fast-travel point (Eagle Statue) locations"><span style="color:#e8b339;">&#9679;</span> Eagle Statues</button>
          <button id="eff-filt-npc" onclick="toggleEffigyFilter('npc')" class="btn btn-ghost" style="font-size:11px;padding:2px 8px;" title="Show / hide NPC locations"><span style="color:#39c5bb;">&#9679;</span> NPCs</button>
          <span id="npc-summary" style="color:var(--muted);font-size:11px;" title="NPCs talked to, from the save"></span>
          <button id="eff-filt-landmark" onclick="toggleEffigyFilter('landmark')" class="btn btn-ghost" style="font-size:11px;padding:2px 8px;" title="Show / hide other confirmed landmarks (discovered areas, etc.)"><span style="color:#a371f7;">&#9679;</span> Landmarks</button>
          <button id="eff-filt-players" onclick="toggleEffigyFilter('players')" class="btn btn-ghost" style="font-size:11px;padding:2px 8px;" title="Show / hide every player's live position (from their own save's Translation/Rotation)"><span style="color:#58a6ff;">&#9679;</span> Players</button>
        </span>
        <button class="btn btn-ghost" onclick="reloadEffigyView()">&#8635; Reload</button>
      </div>
    </div>
    <div id="effigy-leaflet-map" style="flex:1;min-height:0;"></div>
  </div>
</div>

<div id="view-datamine" class="page" style="display:none">
  <style>
    .syn-stats{display:flex;gap:18px;flex-wrap:wrap;padding:10px 14px;border-bottom:1px solid var(--border);}
    .syn-stat-card{min-width:150px;}
    .syn-stat-card .syn-stat-name{font-size:12px;font-weight:600;color:var(--text);margin-bottom:4px;}
    .syn-stat-card .syn-stat-row{font-size:11px;color:var(--muted);display:flex;justify-content:space-between;gap:10px;}
    table.syn-table{width:100%;border-collapse:collapse;font-size:12px;}
    table.syn-table th,table.syn-table td{padding:6px 10px;border-bottom:1px solid var(--border);text-align:left;}
    table.syn-table th{color:var(--muted);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.4px;position:sticky;top:0;background:var(--bg);}
    table.syn-table td.syn-check{text-align:center;font-size:14px;}
    .syn-key{color:var(--muted);font-size:10px;font-family:monospace;}
    .dm-section-hdr{padding:12px 14px 4px;font-size:13px;font-weight:700;border-top:1px solid var(--border);margin-top:6px;cursor:pointer;user-select:none;display:flex;align-items:center;gap:6px;}
    .dm-section-hdr .dm-arrow{display:inline-block;font-size:10px;color:var(--muted);transition:transform .15s;}
    .dm-section-sub{padding:0 14px 8px;color:var(--muted);font-size:11px;}
    .dm-section.collapsed .dm-section-hdr .dm-arrow{transform:rotate(-90deg);}
    .dm-section.collapsed .dm-section-body{display:none;}
  </style>
  <div class="panel">
    <div class="panel-header">
      <span>Data Mine</span>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
        <span id="dm-summary" style="color:var(--muted);font-size:12px;"></span>
        <button class="btn btn-ghost" onclick="fetchDataMine()">&#8635; Reload</button>
      </div>
    </div>
    <div style="padding:8px 14px 0;color:var(--muted);font-size:11px;">
      Everything pulled from each player's NormalBossDefeatFlag save data, in one place: named
      Alpha bounty bosses (known location + species), human/Syndicate "boss" fights (no
      location data), and leftover zone-numbered field-alpha spawns whose species isn't
      recoverable from the save. Labels not sourced from paldb/wiki are inferred from the raw
      key name, not confirmed in-game text -- raw keys are always shown alongside labels.
    </div>
    <div id="dm-stats" class="syn-stats"></div>

    <div class="dm-section" id="dm-sec-bounty">
      <div class="dm-section-hdr" onclick="toggleDmSection('dm-sec-bounty')"><span class="dm-arrow">&#9660;</span>Alpha Bounty Bosses</div>
      <div class="dm-section-body">
        <div class="dm-section-sub">Named legendary Alphas with a single known fixed world location (bounty_bosses.json). Species/location sourced from paldb.cc + wiki -- see the palbox-bounty-tracker skill for provenance.</div>
        <div id="dm-bounty-area" style="overflow:auto;"><div class="empty-state">Loading...</div></div>
      </div>
    </div>

    <div class="dm-section" id="dm-sec-syndicate">
      <div class="dm-section-hdr" onclick="toggleDmSection('dm-sec-syndicate')"><span class="dm-arrow">&#9660;</span>Syndicate / NPC Bosses</div>
      <div class="dm-section-body">
        <div class="dm-section-sub">Human "boss" fights (Syndicate Towers and similar). No location data exists for these in the save.</div>
        <div id="dm-syndicate-area" style="overflow:auto;"><div class="empty-state">Loading...</div></div>
      </div>
    </div>

    <div class="dm-section" id="dm-sec-anon">
      <div class="dm-section-hdr" onclick="toggleDmSection('dm-sec-anon')"><span class="dm-arrow">&#9660;</span>Anonymous Field-Alpha Spawns</div>
      <div class="dm-section-body">
        <div class="dm-section-sub">Zone-numbered field-alpha defeat keys that didn't match a known bounty species. Species for these is baked into the game's .pak assets, not the save -- raw keys only, auto-discovered from whatever's in each player's save (not a fixed roster).</div>
        <div id="dm-anon-area" style="overflow:auto;"><div class="empty-state">Loading...</div></div>
      </div>
    </div>

    <div class="dm-section" id="dm-sec-journal">
      <div class="dm-section-hdr" onclick="toggleDmSection('dm-sec-journal')"><span class="dm-arrow">&#9660;</span>Journal / Diary Notes</div>
      <div class="dm-section-body">
        <div class="dm-section-sub">From NoteObtainForInstanceFlag (same mechanism as effigies). Mixes lore-journal/diary "DayN" pickups with dungeon-boss lore notes under one flag map, so the "N / 49" total on the Effigy map can never reach 49 from map pins alone. See the palbox-journal-overlay skill for full provenance rules -- a raw key only earns a "key" in journal_locations.json (and real found/new coloring on the map) after being directly observed flipping true in a live save diff.</div>
        <div id="dm-journal-area" style="overflow:auto;"><div class="empty-state">Loading...</div></div>
        <div class="dm-section-sub" style="padding-top:10px;">Every raw key that has actually appeared as collected in at least one player's save, including ones already tied to a confirmed pin above (Mapped Pin column shows which). Rows with no Mapped Pin are either one of the still-unconfirmed diary pins on the map (blue, "Found status unknown"; needs a live-save diff to match it to a pin), or a dungeon-boss lore note with no map location at all (awarded on boss kill: GrassBoss1/2/3, ForestBoss3/4, VikingBoss1/2, SakurajimaBoss2/5, SnowBoss1 observed so far). Not auto-classified between the two -- confirm manually before editing journal_locations.json.</div>
        <div id="dm-journal-unmapped-area" style="overflow:auto;"><div class="empty-state">Loading...</div></div>
      </div>
    </div>
  </div>
</div>

<div id="view-pals" class="page" style="display:none">
  <div class="panel">
    <div class="panel-header">
      <span>Pal Box</span>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
        <select id="pals-player" onchange="renderPals()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;min-width:110px;"></select>
        <select id="pals-location" onchange="renderPals()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;min-width:110px;"></select>
        <select id="pals-sort" onchange="renderPals()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;">
          <option value="iv">Sort: Best IVs</option>
          <option value="work">Sort: Work Suitability</option>
          <option value="level">Sort: Level</option>
          <option value="paldex">Sort: Paldex No.</option>
          <option value="name">Sort: Name</option>
          <option value="slot">Sort: Box Slot</option>
        </select>
        <input id="pals-search" type="text" placeholder="Search name / passive..." oninput="renderPals()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;width:180px;">
        <button class="btn btn-ghost" onclick="togglePalFilters()" style="position:relative;">Filters<span id="pals-filter-count" class="pf-badge" style="display:none;">0</span></button>
        <button id="pals-clear" class="btn btn-ghost" onclick="clearPalFilters()" style="display:none;">Clear</button>
        <button id="pals-watch-btn" class="btn btn-ghost" onclick="savePalWatch()" title="Save the current filter as a watch - matching pals get pinned at the top">&#9733; Watch filter</button>
        <button id="pals-cancel-edit" class="btn btn-ghost" onclick="cancelPalEdit()" style="display:none;">Cancel edit</button>
        <span id="pals-summary" style="color:var(--muted);font-size:12px;"></span>
        <button class="btn btn-ghost" onclick="fetchPals()">&#8635; Reload</button>
      </div>
    </div>
    <div id="pals-filters" class="pf-panel">
      <div class="pf-grid">
        <div class="pf-group"><span class="pf-label">Type</span><div id="pf-types" class="pf-chips"></div></div>
        <div class="pf-group"><span class="pf-label">Work suitability</span>
          <div style="display:flex;gap:8px;align-items:flex-start;flex-wrap:wrap;">
            <div id="pf-work" class="pf-chips"></div>
            <select id="pf-work-min" class="pf-input" onchange="renderPals()"><option value="1">Any Lv</option><option value="2">Lv 2+</option><option value="3">Lv 3+</option><option value="4">Lv 4+</option></select>
          </div>
        </div>
        <div class="pf-group"><span class="pf-label">Passives (up to 4, must have all)</span>
          <div class="pf-pass-sel"><select id="pf-pass-add" class="pf-input" onchange="addPassiveFilter(this.value)"><option value="">+ Add passive...</option></select><span id="pf-pass" class="pf-pass-sel"></span></div>
          <label class="pf-flag" style="margin-top:5px;"><input id="pf-pass-exact" type="checkbox" onchange="renderPals()"> Exact match (no extra passives)</label>
        </div>
        <div class="pf-group"><span class="pf-label">Specific pals (any of)</span>
          <div class="pf-pass-sel"><select id="pf-pal-add" class="pf-input" onchange="addPalFilter(this.value)"><option value="">+ Add pal...</option></select><span id="pf-pal" class="pf-pass-sel"></span></div>
        </div>
        <div class="pf-group"><span class="pf-label">Gender</span>
          <div class="pf-seg" id="pf-gender"><button data-g="" class="on" onclick="setGender(this)">Any</button><button data-g="Male" onclick="setGender(this)">&#9794; M</button><button data-g="Female" onclick="setGender(this)">&#9792; F</button></div>
        </div>
        <div class="pf-group"><span class="pf-label">Min IV</span>
          <div style="display:flex;gap:6px;align-items:center;">
            <input id="pf-iv-min" type="number" min="0" max="100" placeholder="0" class="pf-input pf-num" oninput="renderPals()">
            <select id="pf-iv-scope" class="pf-input" onchange="renderPals()"><option value="avg">Average</option><option value="all">All stats</option><option value="any">Any stat</option></select>
          </div>
        </div>
        <div class="pf-group"><span class="pf-label">Min IV per stat (each &ge;)</span>
          <div style="display:flex;gap:6px;align-items:center;">
            <input id="pf-iv-hp" type="number" min="0" max="100" placeholder="HP" class="pf-input pf-num" oninput="renderPals()">
            <input id="pf-iv-atk" type="number" min="0" max="100" placeholder="Atk" class="pf-input pf-num" oninput="renderPals()">
            <input id="pf-iv-def" type="number" min="0" max="100" placeholder="Def" class="pf-input pf-num" oninput="renderPals()">
          </div>
        </div>
        <div class="pf-group"><span class="pf-label">Level</span>
          <div style="display:flex;gap:6px;align-items:center;">
            <input id="pf-lvl-min" type="number" min="1" max="55" placeholder="min" class="pf-input pf-num" oninput="renderPals()">
            <span style="color:var(--muted);">to</span>
            <input id="pf-lvl-max" type="number" min="1" max="55" placeholder="max" class="pf-input pf-num" oninput="renderPals()">
          </div>
        </div>
        <div class="pf-group"><span class="pf-label">Condensed</span>
          <select id="pf-cond" class="pf-input" onchange="renderPals()">
            <option value="">Any</option>
            <option value="1">1&#9733;+</option>
            <option value="2">2&#9733;+</option>
            <option value="3">3&#9733;+</option>
            <option value="4">4&#9733;</option>
          </select>
        </div>
        <div class="pf-group"><span class="pf-label">Flags</span>
          <div style="display:flex;gap:12px;align-items:center;">
            <label class="pf-flag"><input id="pals-alpha" type="checkbox" onchange="renderPals()"> Alpha</label>
            <label class="pf-flag"><input id="pals-lucky" type="checkbox" onchange="renderPals()"> Lucky</label>
          </div>
        </div>
      </div>
    </div>
    <div id="pals-watches" class="egg-watches" style="display:none;"></div>
    <div class="panel-body" id="pals-area"><div class="empty-state">Loading...</div></div>
  </div>
</div>

<div id="view-eggs" class="page" style="display:none">
  <style>
    /* Egg cards reuse the Pals-page layout (.pal-grid/.pal-card) but never open a
       popup; status is shown by the outline: green=ready, yellow=incubating. */
    .pal-card.egg-card-w{cursor:default;}
    .pal-card.egg-ready{border-color:#3fb950;box-shadow:0 0 0 1px rgba(63,185,80,.35);}
    .pal-card.egg-incu{border-color:#e3b341;box-shadow:0 0 0 1px rgba(227,179,65,.35);}
    .egg-card-w.egg-unowned{opacity:.6;border-style:dashed;}
    .egg-incu-tag{position:absolute;right:8px;top:8px;font-size:15px;}
    .egg-status{font-size:11px;font-weight:600;}
    .egg-status.sr{color:#3fb950;}
    .egg-status.si{color:#e3b341;}
    .egg-ghost{color:#f85149;border:1px solid #f85149;border-radius:4px;padding:0 4px;font-size:10px;margin-left:4px;}
    .egg-hint{font-size:11px;color:var(--muted);font-style:italic;}
    .egg-group-hdr{font-weight:700;margin:14px 2px 6px;display:flex;align-items:center;gap:8px;}
    .egg-group-hdr .cnt{color:var(--muted);font-weight:400;font-size:12px;}
    .egg-loc-hdr{font-size:13px;font-weight:600;color:var(--muted);margin:8px 2px 5px 10px;border-left:2px solid var(--border);padding-left:8px;}
    .egg-loc-hdr .cnt{color:var(--muted);font-weight:400;font-size:11px;margin-left:4px;}
    .egg-watches{display:flex;flex-wrap:wrap;gap:6px;align-items:center;padding:8px 2px 2px;}
    .egg-watch-chip{display:inline-flex;align-items:center;gap:6px;background:var(--surface2);border:1px solid var(--border);border-radius:14px;padding:3px 6px 3px 10px;font-size:12px;}
    .egg-watch-chip .wc-n{color:var(--text);cursor:pointer;} .egg-watch-chip .wc-n:hover{text-decoration:underline;} .egg-watch-chip .wc-c{color:#ffd84d;font-weight:700;}
    .egg-watch-chip b{cursor:pointer;color:var(--muted);font-size:14px;line-height:1;padding:0 2px;} .egg-watch-chip b:hover{color:#f85149;}
    .egg-watch-chip b.wc-edit:hover{color:#58a6ff;}
    .egg-watch-chip.editing{border-color:#58a6ff;box-shadow:0 0 0 1px rgba(88,166,255,.4);}
    .egg-matches{border:1px solid #ffd84d;border-radius:10px;padding:8px 10px 10px;margin:6px 2px 14px;background:rgba(255,216,77,.05);}
    .egg-matches-hdr{font-weight:700;color:#ffd84d;margin:0 0 2px;}
    .egg-match-sub{font-size:13px;font-weight:600;margin:8px 2px 5px;}
    .egg-match-sub .cnt{color:var(--muted);font-weight:400;font-size:11px;margin-left:4px;}
    .pal-card.egg-watched{box-shadow:0 0 0 2px rgba(255,216,77,.55);}
    .egg-watch-star{position:absolute;left:8px;top:8px;color:#ffd84d;font-size:14px;text-shadow:0 0 3px #000;}
    .egg-loc-tag{font-size:11px;color:var(--muted);margin-top:4px;}
  </style>
  <div class="panel">
    <div class="panel-header">
      <span>Eggs</span>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
        <select id="eggs-owner" onchange="renderEggs()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;min-width:110px;"></select>
        <select id="eggs-location" onchange="renderEggs()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;min-width:110px;">
          <option value="">All locations</option>
          <option value="incubator">Incubators</option>
          <option value="breedfarm">Breeding Farm</option>
          <option value="storage">Storage</option>
          <option value="inventory">Inventory</option>
        </select>
        <select id="eggs-sort" onchange="renderEggs()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;">
          <option value="iv">Sort: Best IVs</option>
          <option value="work">Sort: Work Suitability</option>
          <option value="rarity">Sort: Rarity</option>
          <option value="species">Sort: Species</option>
          <option value="element">Sort: Element</option>
        </select>
        <input id="eggs-search" type="text" placeholder="Search name / passive..." oninput="renderEggs()" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:6px;font-size:13px;width:180px;">
        <button class="btn btn-ghost" onclick="toggleEggFilters()" style="position:relative;">Filters<span id="eggs-filter-count" class="pf-badge" style="display:none;">0</span></button>
        <button id="eggs-clear" class="btn btn-ghost" onclick="clearEggFilters()" style="display:none;">Clear</button>
        <button id="eggs-watch-btn" class="btn btn-ghost" onclick="saveEggWatch()" title="Save the current filter as a watch - matching eggs get pinned at the top">&#9733; Watch filter</button>
        <button id="eggs-cancel-edit" class="btn btn-ghost" onclick="cancelEggEdit()" style="display:none;">Cancel edit</button>
        <span id="eggs-summary" style="color:var(--muted);font-size:12px;"></span>
        <button class="btn btn-ghost" onclick="fetchEggs()">&#8635; Reload</button>
      </div>
    </div>
    <div id="eggs-watches" class="egg-watches" style="display:none;"></div>
    <div id="eggs-filters" class="pf-panel">
      <div class="pf-grid">
        <div class="pf-group"><span class="pf-label">Type</span><div id="ef-types" class="pf-chips"></div></div>
        <div class="pf-group"><span class="pf-label">Work suitability</span>
          <div style="display:flex;gap:8px;align-items:flex-start;flex-wrap:wrap;">
            <div id="ef-work" class="pf-chips"></div>
            <select id="ef-work-min" class="pf-input" onchange="renderEggs()"><option value="1">Any Lv</option><option value="2">Lv 2+</option><option value="3">Lv 3+</option><option value="4">Lv 4+</option></select>
          </div>
        </div>
        <div class="pf-group"><span class="pf-label">Passives (up to 4, must have all)</span>
          <div class="pf-pass-sel"><select id="ef-pass-add" class="pf-input" onchange="addEggPassive(this.value)"><option value="">+ Add passive...</option></select><span id="ef-pass" class="pf-pass-sel"></span></div>
          <label class="pf-flag" style="margin-top:5px;"><input id="ef-pass-exact" type="checkbox" onchange="renderEggs()"> Exact match (no extra passives)</label>
        </div>
        <div class="pf-group"><span class="pf-label">Specific pals (any of)</span>
          <div class="pf-pass-sel"><select id="ef-pal-add" class="pf-input" onchange="addEggPal(this.value)"><option value="">+ Add pal...</option></select><span id="ef-pal" class="pf-pass-sel"></span></div>
        </div>
        <div class="pf-group"><span class="pf-label">Gender</span>
          <div class="pf-seg" id="ef-gender"><button data-g="" class="on" onclick="setEggGender(this)">Any</button><button data-g="Male" onclick="setEggGender(this)">&#9794; M</button><button data-g="Female" onclick="setEggGender(this)">&#9792; F</button></div>
        </div>
        <div class="pf-group"><span class="pf-label">Min IV</span>
          <div style="display:flex;gap:6px;align-items:center;">
            <input id="ef-iv-min" type="number" min="0" max="100" placeholder="0" class="pf-input pf-num" oninput="renderEggs()">
            <select id="ef-iv-scope" class="pf-input" onchange="renderEggs()"><option value="avg">Average</option><option value="all">All stats</option><option value="any">Any stat</option></select>
          </div>
        </div>
        <div class="pf-group"><span class="pf-label">Min IV per stat (each &ge;)</span>
          <div style="display:flex;gap:6px;align-items:center;">
            <input id="ef-iv-hp" type="number" min="0" max="100" placeholder="HP" class="pf-input pf-num" oninput="renderEggs()">
            <input id="ef-iv-atk" type="number" min="0" max="100" placeholder="Atk" class="pf-input pf-num" oninput="renderEggs()">
            <input id="ef-iv-def" type="number" min="0" max="100" placeholder="Def" class="pf-input pf-num" oninput="renderEggs()">
          </div>
        </div>
        <div class="pf-group"><span class="pf-label">Flags</span>
          <div style="display:flex;gap:12px;align-items:center;">
            <label class="pf-flag"><input id="eggs-alpha" type="checkbox" onchange="renderEggs()"> Alpha</label>
            <label class="pf-flag"><input id="eggs-lucky" type="checkbox" onchange="renderEggs()"> Lucky</label>
          </div>
        </div>
      </div>
    </div>
    <div class="panel-body" id="eggs-area"><div class="empty-state">Loading...</div></div>
  </div>
</div>

<div id="pal-map-modal" style="display:none;position:fixed;top:0;left:0;right:0;bottom:0;z-index:500;align-items:center;justify-content:center;">
  <div onclick="closePalMap()" style="position:absolute;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.75);"></div>
  <div onclick="event.stopPropagation()" style="position:relative;background:var(--surface);border:1px solid var(--border);border-radius:12px;width:92vw;max-width:1000px;max-height:90vh;display:flex;flex-direction:column;overflow:hidden;">
    <div style="padding:10px 16px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:10px;flex-shrink:0;">
      <img id="pal-map-img" src="" style="width:40px;height:40px;object-fit:contain;flex-shrink:0;">
      <div style="min-width:0;flex:1;">
        <div id="pal-map-name" style="font-weight:700;font-size:15px;"></div>
      </div>
      <div style="display:flex;gap:6px;align-items:center;flex-shrink:0;">
        <button id="btn-map-day" class="btn btn-ghost" style="font-size:12px;padding:3px 10px;font-weight:700;" onclick="setPalMapTime('dayTimeLocations')">Day</button>
        <button id="btn-map-night" class="btn btn-ghost" style="font-size:12px;padding:3px 10px;" onclick="setPalMapTime('nightTimeLocations')">Night</button>
        <span id="pal-map-status" style="color:var(--muted);font-size:11px;min-width:90px;text-align:center;"></span>
        <button class="btn-icon" onclick="closePalMap()">&#10005;</button>
      </div>
    </div>
    <div style="position:relative;flex:1 1 auto;min-height:240px;">
      <div id="pal-leaflet-map" style="position:absolute;inset:0;height:100%;"></div>
      <div id="pal-map-empty" style="display:none;position:absolute;inset:0;z-index:1000;align-items:center;justify-content:center;background:var(--surface);color:var(--border);font-size:150px;font-weight:800;line-height:1;">?</div>
    </div>
  </div>
</div>
<div id="toasts"></div>
<div id="chart-tooltip" style="position:fixed;background:#161b22;border:1px solid #30363d;color:#e6edf3;padding:4px 8px;border-radius:4px;font-size:11px;pointer-events:none;display:none;z-index:100;white-space:nowrap;"></div>
<footer style="padding:14px 16px;text-align:center;font-size:11px;color:var(--muted);">
  <a href="https://www.flaticon.com/free-icons/acorn" title="acorn icons" style="color:inherit;" target="_blank" rel="noopener">Acorn icons created by Freepik - Flaticon</a>
  &bull;
  <a href="https://www.flaticon.com/free-icons/book" title="book icons" style="color:inherit;" target="_blank" rel="noopener">Book icons created by Freepik - Flaticon</a>
</footer>

<script>
// ── Globals ───────────────────────────────────────────────────────────────────
var players     = [];
var historyData = [];
var countdown   = 300;
var maxPlayers  = null;
var maintSkip   = false;

// ── Settings state ────────────────────────────────────────────────────────────
var sActive   = {};
var sDefault  = {};
var sDirty    = {};
var sCat      = 'Server';
var sLoaded   = false;
var sTarget   = '';   // '' = active/live settings; otherwise a library slot id
var savesList = [];   // last-known save slots (for the settings target dropdown)

var META = {
  ServerName:{c:'Server',t:'string',d:'Server name shown in browser'},
  ServerDescription:{c:'Server',t:'string',d:'Server description'},
  ServerPassword:{c:'Server',t:'string',d:'Join password (blank = open)'},
  AdminPassword:{c:'Server',t:'string',d:'Admin password (auth in-game via /AdminPassword <pw>)'},
  PublicPort:{c:'Server',t:'int',d:"Community-browser advertised port -- not the listen port (that's the -port launch arg)"},
  ServerPlayerMaxNum:{c:'Server',t:'int',d:'Max players on the server'},
  CoopPlayerMaxNum:{c:'Server',t:'int',d:'Max players per co-op party (distinct from the server-wide cap)'},
  RCONEnabled:{c:'Server',t:'bool',d:'Enable RCON remote control'},
  RCONPort:{c:'Server',t:'int',d:'RCON port'},
  RESTAPIEnabled:{c:'Server',t:'bool',d:'Enable REST API'},
  RESTAPIPort:{c:'Server',t:'int',d:'REST API port'},
  bUseAuth:{c:'Server',t:'bool',d:'Steam authentication'},
  bIsUseBackupSaveData:{c:'Server',t:'bool',d:'Keep backup save files'},
  bAllowClientMod:{c:'Server',t:'bool',d:'Allow client-side mods'},
  bShowPlayerList:{c:'Server',t:'bool',d:'Show player list in the in-game ESC menu'},
  ChatPostLimitPerMinute:{c:'Server',t:'int',d:'Chat messages per minute limit'},
  bIsShowJoinLeftMessage:{c:'Server',t:'bool',d:'Show join/leave in chat'},
  DeathPenalty:{c:'Gameplay',t:'enum',d:'Items lost on death',opts:['None','Item','ItemAndEquipment','All']},
  bIsPvP:{c:'Gameplay',t:'bool',d:'Enable PvP damage'},
  bIsMultiplay:{c:'Gameplay',t:'bool',d:'Multiplayer mode'},
  bHardcore:{c:'Gameplay',t:'bool',d:'No respawn on death (see character recreation below)'},
  bPalLost:{c:'Gameplay',t:'bool',d:'Pals permanently lost on death'},
  bCharacterRecreateInHardcore:{c:'Gameplay',t:'bool',d:'Allow character recreation in hardcore'},
  bEnablePlayerToPlayerDamage:{c:'Gameplay',t:'bool',d:'Player-to-player damage'},
  bEnableFriendlyFire:{c:'Gameplay',t:'bool',d:'Friendly fire'},
  bEnableInvaderEnemy:{c:'Gameplay',t:'bool',d:'Raider invasion events'},
  bEnableFastTravel:{c:'Gameplay',t:'bool',d:'Fast travel'},
  bEnableFastTravelOnlyBaseCamp:{c:'Gameplay',t:'bool',d:'Fast travel only to base camps'},
  bIsStartLocationSelectByMap:{c:'Gameplay',t:'bool',d:'Choose spawn on map'},
  bExistPlayerAfterLogout:{c:'Gameplay',t:'bool',d:'Player appears sleeping in place after logout (vs. vanishing)'},
  bCanPickupOtherGuildDeathPenaltyDrop:{c:'Gameplay',t:'bool',d:'Other guilds can loot your drops'},
  EnablePredatorBossPal:{c:'Gameplay',t:'bool',d:'Predator boss Pals spawn'},
  bEnableNonLoginPenalty:{c:'Gameplay',t:'bool',d:'Offline penalty applies'},
  bAllowGlobalPalboxExport:{c:'Gameplay',t:'bool',d:'Allow uploading Pals to the Global Palbox'},
  bAllowGlobalPalboxImport:{c:'Gameplay',t:'bool',d:'Allow downloading Pals from the Global Palbox'},
  ExpRate:{c:'Rates',t:'float',d:'XP gain multiplier'},
  PalCaptureRate:{c:'Rates',t:'float',d:'Pal capture rate multiplier'},
  PalSpawnNumRate:{c:'Rates',t:'float',d:'Pal spawn quantity multiplier'},
  DayTimeSpeedRate:{c:'Rates',t:'float',d:'Daytime speed multiplier'},
  NightTimeSpeedRate:{c:'Rates',t:'float',d:'Nighttime speed multiplier'},
  WorkSpeedRate:{c:'Rates',t:'float',d:'Pal work speed multiplier'},
  CollectionDropRate:{c:'Rates',t:'float',d:'Resource drop rate multiplier'},
  EnemyDropItemRate:{c:'Rates',t:'float',d:'Enemy drop rate multiplier'},
  ItemWeightRate:{c:'Rates',t:'float',d:'Carry weight multiplier'},
  EquipmentDurabilityDamageRate:{c:'Rates',t:'float',d:'Equipment durability loss rate'},
  PalDamageRateAttack:{c:'Damage',t:'float',d:'Damage dealt BY Pals'},
  PalDamageRateDefense:{c:'Damage',t:'float',d:'Damage taken BY Pals'},
  PlayerDamageRateAttack:{c:'Damage',t:'float',d:'Damage dealt BY players'},
  PlayerDamageRateDefense:{c:'Damage',t:'float',d:'Damage taken BY players'},
  PlayerStomachDecreaceRate:{c:'Player',t:'float',d:'Hunger drain rate'},
  PlayerStaminaDecreaceRate:{c:'Player',t:'float',d:'Stamina drain rate'},
  PlayerAutoHPRegeneRate:{c:'Player',t:'float',d:'HP regen rate'},
  PlayerAutoHpRegeneRateInSleep:{c:'Player',t:'float',d:'HP regen while sleeping'},
  PalStomachDecreaceRate:{c:'Pal',t:'float',d:'Pal hunger drain rate'},
  PalStaminaDecreaceRate:{c:'Pal',t:'float',d:'Pal stamina drain rate'},
  PalAutoHPRegeneRate:{c:'Pal',t:'float',d:'Pal HP regen rate'},
  PalAutoHpRegeneRateInSleep:{c:'Pal',t:'float',d:'Pal HP regen while sleeping in the Palbox'},
  PalEggDefaultHatchingTime:{c:'Pal',t:'float',d:'Hatch time (hours) for the largest egg tier; smaller eggs hatch faster'},
  BuildObjectHpRate:{c:'Building',t:'float',d:'Building HP multiplier'},
  BuildObjectDamageRate:{c:'Building',t:'float',d:'Damage to buildings multiplier'},
  BuildObjectDeteriorationDamageRate:{c:'Building',t:'float',d:'Building decay rate'},
  CollectionObjectHpRate:{c:'Building',t:'float',d:'Resource node HP multiplier'},
  CollectionObjectRespawnSpeedRate:{c:'Building',t:'float',d:'Resource respawn speed'},
  BaseCampMaxNum:{c:'Building',t:'int',d:'Max total base camps in world'},
  BaseCampWorkerMaxNum:{c:'Building',t:'int',d:'Max Pal workers per base camp (max 50)'},
  BaseCampMaxNumInGuild:{c:'Building',t:'int',d:'Max base camps per guild (default 4, max 10)'},
  MaxBuildingLimitNum:{c:'Building',t:'int',d:'Max buildings per player (0=unlimited)'},
  bBuildAreaLimit:{c:'Building',t:'bool',d:'Prevent building near landmarks like fast-travel points'},
  bInvisibleOtherGuildBaseCampAreaFX:{c:'Building',t:'bool',d:"Hide other guilds' base-camp area effect (plain boundary only)"},
  DropItemMaxNum:{c:'Items',t:'int',d:'Max dropped items in world at once'},
  DropItemAliveMaxHours:{c:'Items',t:'float',d:'Hours before drops despawn'},
  GuildPlayerMaxNum:{c:'Guild',t:'int',d:'Max players per guild'},
  bAutoResetGuildNoOnlinePlayers:{c:'Guild',t:'bool',d:"Delete a guild's structures & base Pals if no members log in"},
  AutoResetGuildTimeNoOnlinePlayers:{c:'Guild',t:'float',d:'Hours of inactivity before guild resets'},
  GuildRejoinCooldownMinutes:{c:'Guild',t:'int',d:'Guild rejoin cooldown (minutes)'},
  AutoSaveSpan:{c:'World',t:'float',d:'Autosave interval (seconds)'},
  SupplyDropSpan:{c:'World',t:'int',d:'Supply drop interval (minutes)'},
  ServerReplicatePawnCullDistance:{c:'World',t:'float',d:'Pal sync distance to remote players, cm (min 5000, max 15000)'}
};
var CATS = ['Server','Gameplay','Rates','Damage','Player','Pal','Building','Items','Guild','World'];

// ── Toast ─────────────────────────────────────────────────────────────────────
function toast(msg, type, ms) {
  type = type||'info'; ms = ms||4500;
  var el = document.createElement('div');
  el.className = 'toast '+type; el.textContent = msg;
  document.getElementById('toasts').appendChild(el);
  setTimeout(function(){ el.remove(); }, ms);
}

// ── API ───────────────────────────────────────────────────────────────────────
async function api(path, method, body) {
  method = method||'GET';
  var opts = {method:method, headers:{'Content-Type':'application/json'}};
  if (body) opts.body = JSON.stringify(body);
  var res  = await fetch(path, opts);
  var data = await res.json().catch(function(){ return {}; });
  if (!res.ok) throw new Error(data.error||'HTTP '+res.status);
  return data;
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function pick(obj) {
  var keys = Array.prototype.slice.call(arguments,1);
  for (var i=0;i<keys.length;i++) {
    var lk=keys[i].toLowerCase(), entries=Object.entries(obj);
    for (var j=0;j<entries.length;j++) {
      if (entries[j][0].toLowerCase()===lk && entries[j][1]!=null) return entries[j][1];
    }
  }
  return null;
}
function fmtUptime(s){s=Number(s)||0;var h=Math.floor(s/3600),m=Math.floor((s%3600)/60);return h>0?h+'h '+m+'m':m+'m';}
function fmtPlaytime(s){s=s||0;var h=Math.floor(s/3600),m=Math.floor((s%3600)/60);return h>0?h+'h '+m+'m':m+'m';}
function pingCls(ms){return ms<80?'ping-good':ms<150?'ping-ok':'ping-bad';}
function esc(s){return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
function setText(id,val){var el=document.getElementById(id);if(el)el.textContent=val==null?'-':val;}
function fmtTs(ts){var d=new Date(ts);return isNaN(d.getTime())?ts:d.getHours()+':'+String(d.getMinutes()).padStart(2,'0');}
function stripQ(v){return String(v||'').replace(/^"|"$/g,'');}

// ── Charts ────────────────────────────────────────────────────────────────────
var chartStore={};
function hexToRgb(h){return parseInt(h.slice(1,3),16)+','+parseInt(h.slice(3,5),16)+','+parseInt(h.slice(5,7),16);}
function drawLineChart(id,pts,color){
  var canvas=document.getElementById(id); if(!canvas)return;
  canvas.width=canvas.offsetWidth>0?canvas.offsetWidth:400;
  canvas.height=canvas.offsetHeight>0?canvas.offsetHeight:160;
  var ctx=canvas.getContext('2d'), W=canvas.width, H=canvas.height;
  var pad={t:8,r:10,b:26,l:38}, cw=W-pad.l-pad.r, ch=H-pad.t-pad.b;
  ctx.clearRect(0,0,W,H);
  if(!pts||!pts.length){ctx.fillStyle='#8b949e';ctx.font='11px system-ui';ctx.textAlign='center';ctx.fillText('No data yet',W/2,H/2+4);chartStore[id]=null;return;}
  var vals=pts.map(function(p){return p.y;});
  var mn=Math.floor(Math.min.apply(null,vals)), mx=Math.ceil(Math.max.apply(null,vals));
  if(mn===mx){mn=Math.max(0,mn-1);mx=mx+1;}
  var range=mx-mn;
  // pick a nice integer step so Y gridlines never show fractions
  var rawStep=range/3;
  var mag=Math.pow(10,Math.floor(Math.log(rawStep)/Math.LN10));
  var niceStep=rawStep<=mag?mag:rawStep<=2*mag?2*mag:rawStep<=5*mag?5*mag:10*mag;
  if(niceStep<1)niceStep=1;
  var gridMn=Math.floor(mn/niceStep)*niceStep, gridMx=Math.ceil(mx/niceStep)*niceStep;
  var gridRange=gridMx-gridMn; if(!gridRange)gridRange=1;
  function toX(i){return pts.length>1?pad.l+i/(pts.length-1)*cw:pad.l+cw/2;}
  function toY(v){return pad.t+ch-(v-gridMn)/gridRange*ch;}
  for(var gv=gridMn;gv<=gridMx;gv+=niceStep){
    var gy=toY(gv);
    if(gy<pad.t-2||gy>pad.t+ch+2)continue;
    ctx.strokeStyle='#21262d';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(pad.l,gy);ctx.lineTo(pad.l+cw,gy);ctx.stroke();
    ctx.fillStyle='#8b949e';ctx.font='9px system-ui';ctx.textAlign='right';
    ctx.fillText(gv,pad.l-4,gy+3);
  }
  var rgb=hexToRgb(color), grad=ctx.createLinearGradient(0,pad.t,0,pad.t+ch);
  grad.addColorStop(0,'rgba('+rgb+',.18)'); grad.addColorStop(1,'rgba('+rgb+',0)');
  ctx.fillStyle=grad;ctx.beginPath();ctx.moveTo(toX(0),toY(pts[0].y));
  for(var i=1;i<pts.length;i++)ctx.lineTo(toX(i),toY(pts[i].y));
  ctx.lineTo(toX(pts.length-1),pad.t+ch);ctx.lineTo(toX(0),pad.t+ch);ctx.closePath();ctx.fill();
  ctx.strokeStyle=color;ctx.lineWidth=2;ctx.lineJoin='round';
  ctx.beginPath();ctx.moveTo(toX(0),toY(pts[0].y));
  for(var i=1;i<pts.length;i++)ctx.lineTo(toX(i),toY(pts[i].y));
  ctx.stroke();
  ctx.fillStyle=color;ctx.beginPath();ctx.arc(toX(pts.length-1),toY(pts[pts.length-1].y),3.5,0,Math.PI*2);ctx.fill();
  // collect whole-hour boundary indices, then thin to ~4-5 labels that fit
  var hourPts=[],lastHr2=-1;
  for(var i=0;i<pts.length;i++){
    if(pts[i].ts){
      var dt=new Date(pts[i].ts),hr=dt.getHours(),mm=dt.getMinutes();
      if(mm<5&&hr!==lastHr2){hourPts.push({i:i,hr:hr});lastHr2=hr;}
    }
  }
  var maxLbls=Math.max(2,Math.floor(cw/55));
  var hrStep=hourPts.length<=maxLbls?1:Math.ceil(hourPts.length/maxLbls);
  ctx.fillStyle='#8b949e';ctx.font='9px system-ui';ctx.textAlign='center';
  for(var k=0;k<hourPts.length;k+=hrStep){
    ctx.fillText(hourPts[k].hr+':00',toX(hourPts[k].i),H-4);
  }
  chartStore[id]={pts:pts,pad:pad,cw:cw,ch:ch,W:W,H:H};
}
function renderCharts(){
  var mk=function(k){return historyData.map(function(d){return{x:fmtTs(d.ts),ts:d.ts,y:d[k]||0};});};
  drawLineChart('chart-players',mk('players'),'#58a6ff');
  drawLineChart('chart-fps',mk('fps'),'#3fb950');
  drawLineChart('chart-ping',mk('avgPing'),'#e3b341');
  drawLineChart('chart-frametime',mk('frametime'),'#a371f7');
}
function initChartHover(){
  var tip=document.getElementById('chart-tooltip');
  if(!tip)return;
  ['chart-players','chart-fps','chart-ping','chart-frametime'].forEach(function(id){
    var cv=document.getElementById(id); if(!cv)return;
    cv.addEventListener('mousemove',function(e){
      var store=chartStore[id];
      if(!store||!store.pts||!store.pts.length){tip.style.display='none';return;}
      var rect=cv.getBoundingClientRect();
      var mx=(e.clientX-rect.left)*(cv.width/rect.width);
      var pts=store.pts,pad=store.pad,cw=store.cw;
      var toX=function(j){return pts.length>1?pad.l+j/(pts.length-1)*cw:pad.l+cw/2;};
      var best=0,bestD=Infinity;
      for(var i=0;i<pts.length;i++){var dx=Math.abs(toX(i)-mx);if(dx<bestD){bestD=dx;best=i;}}
      var p=pts[best];
      tip.textContent=p.x+': '+p.y;
      tip.style.left=e.clientX+'px';
      tip.style.top=(e.clientY-40)+'px';
      tip.style.transform='translateX(-50%)';
      tip.style.display='block';
    });
    cv.addEventListener('mouseleave',function(){tip.style.display='none';});
  });
}

// ── Server-message chat banner + notification sound ─────────────────────────────
// Polls the recent server broadcasts (egg alerts, maintenance/reboot countdowns, manual
// broadcasts) and pops a transient top banner + a short chime for each NEW one. Shared by
// admin and public: the admin reads /api/server-messages, the public the generator
// repoints to data/server-messages.json (the R2 mirror). PalWorld has no chat-read API, so
// this only surfaces what the SERVER sends -- there is no player chat. Sound is a WebAudio
// chime (no asset to host) muteable via the header bell, persisted per-browser.
var _chatLastId=0, _chatInit=false, _msgLog=[];
function chatSoundOn(){ try{ return localStorage.getItem('palbox_chat_sound')!=='off'; }catch(e){ return true; } }
function toggleChatSound(){
  var on=!chatSoundOn();
  try{ localStorage.setItem('palbox_chat_sound', on?'on':'off'); }catch(e){}
  var b=document.getElementById('snd-toggle'); if(b) b.innerHTML=on?'&#128276;':'&#128277;';
  if(on) playChime();   // confirmation beep when (re)enabling
}
function playChime(){
  if(!chatSoundOn()) return;
  try{
    var Ctx=window.AudioContext||window.webkitAudioContext; if(!Ctx) return;
    var ac=window._palAC||(window._palAC=new Ctx());
    if(ac.state==='suspended'){ try{ac.resume();}catch(e){} }
    var o=ac.createOscillator(), g=ac.createGain();
    o.type='sine'; o.connect(g); g.connect(ac.destination);
    var t=ac.currentTime;
    o.frequency.setValueAtTime(880,t); o.frequency.setValueAtTime(1320,t+0.12);
    g.gain.setValueAtTime(0.0001,t);
    g.gain.exponentialRampToValueAtTime(0.22,t+0.02);
    g.gain.exponentialRampToValueAtTime(0.0001,t+0.34);
    o.start(t); o.stop(t+0.36);
  }catch(e){}
}
function showChatBanner(msg){
  var host=document.getElementById('chat-banner-host');
  if(!host){ host=document.createElement('div'); host.id='chat-banner-host'; host.className='chat-banner-host'; document.body.appendChild(host); }
  var el=document.createElement('div'); el.className='chat-banner';
  var ico=document.createElement('span'); ico.className='chat-banner-ico'; ico.innerHTML='&#128226;';
  var txt=document.createElement('span'); txt.className='chat-banner-msg'; txt.textContent=msg;   // textContent => no HTML injection
  el.appendChild(ico); el.appendChild(txt); host.appendChild(el);
  requestAnimationFrame(function(){ el.classList.add('show'); });
  setTimeout(function(){ el.classList.remove('show'); setTimeout(function(){ if(el.parentNode) el.parentNode.removeChild(el); },400); }, 6500);
}
async function pollServerMessages(){
  try{
    var arr=await api('/api/server-messages');
    if(!Array.isArray(arr)) arr=(arr&&arr.messages)||[];
    arr.sort(function(a,b){ return (a.id||0)-(b.id||0); });
    _msgLog=arr; renderMsgLog();
    if(!_chatInit){   // first load: adopt the latest id WITHOUT replaying the backlog
      _chatInit=true;
      if(arr.length) _chatLastId=arr[arr.length-1].id||0;
      return;
    }
    arr.forEach(function(m){
      if((m.id||0)>_chatLastId){ _chatLastId=m.id; showChatBanner(m.message||''); playChime(); }
    });
  }catch(e){}
}
// ── Message Log panel (top right): full history of the server-message feed above,
// windowed to the last 24h client-side (the backend already caps the feed at the last
// 50 lines total -- see server_messages.ps1 -- so this is a display window on top of
// that, not a separate retention mechanism).
function renderMsgLog(){
  var body=document.getElementById('msglog-body'); if(!body)return;
  var cutoff=Date.now()-24*3600*1000;
  var items=_msgLog.filter(function(m){ var t=Date.parse(m.ts); return !isNaN(t)&&t>=cutoff; })
    .slice().reverse();
  if(!items.length){ body.innerHTML='<div class="empty-state">No messages in the last 24h.</div>'; return; }
  var icon={egg:'&#129370;',maintenance:'&#128295;',broadcast:'&#128226;'};
  body.innerHTML=items.map(function(m){
    var kind=m.kind||'broadcast';
    var d=new Date(m.ts);
    var timeStr=isNaN(d.getTime())?'':d.toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
    return '<div class="msglog-item ml-'+esc(kind)+'"><span class="ml-time">'+(icon[kind]||icon.broadcast)+' '+esc(timeStr)+'</span><span class="ml-msg">'+esc(m.message||'')+'</span></div>';
  }).join('');
}
function toggleMsgLog(){
  var p=document.getElementById('msglog-panel'); if(!p)return;
  var show=p.style.display==='none';
  p.style.display=show?'':'none';
  if(show) renderMsgLog();
}
document.addEventListener('click',function(e){
  var p=document.getElementById('msglog-panel'); if(!p||p.style.display==='none')return;
  if(p.contains(e.target))return;
  var btn=document.getElementById('msglog-toggle'); if(btn&&btn.contains(e.target))return;
  p.style.display='none';
});

// Remember the last-opened tab across browser reloads. Captured BEFORE the boot
// sequence runs (the public build's boot calls switchView('pals'), which would
// otherwise overwrite the stored value before we can read it) so a reload restores the
// tab the user was actually on, not the boot default. restoreView() runs on
// DOMContentLoaded so any view injected late (e.g. the public Settings tab, appended at
// the end of the page) already exists, and only restores tabs whose nav button is present
// on this page (so a public reload never tries to open the admin-only Dashboard tab).
var SAVED_TAB=null; try{SAVED_TAB=localStorage.getItem('palbox_active_tab');}catch(e){}
function restoreView(){
  if(!SAVED_TAB) return;
  var btn=document.querySelector('.nav-tab[data-tab="'+SAVED_TAB+'"]');
  if(btn) switchView(SAVED_TAB);
}
function switchView(name){
  document.getElementById('view-dashboard').style.display=name==='dashboard'?'':'none';
  document.getElementById('view-pals').style.display=name==='pals'?'':'none';
  var ve=document.getElementById('view-eggs'); if(ve)ve.style.display=name==='eggs'?'':'none';
  document.getElementById('view-paldeck').style.display=name==='paldeck'?'':'none';
  document.getElementById('view-effigies').style.display=name==='effigies'?'':'none';
  var vdm=document.getElementById('view-datamine'); if(vdm)vdm.style.display=name==='datamine'?'':'none';
  document.querySelectorAll('.nav-tab').forEach(function(t){
    t.classList.toggle('active',t.dataset.tab===name);
  });
  clearTabNew(name);
  if(name==='effigies') initEffigyView();
  if(name==='pals' && !palsData) fetchPals();
  if(name==='eggs') fetchEggs();
  if(name==='datamine') fetchDataMine();
  try{localStorage.setItem('palbox_active_tab',name);}catch(e){}
  // Player positions move in real time, unlike the rest of the Map tab's mostly-static
  // overlays -- poll faster than the 5-minute refreshAll cadence, but only while the tab
  // is actually on screen (stopped immediately on tab-away, not left running in the
  // background racking up needless save reads).
  if(_playerLocPollTimer){clearInterval(_playerLocPollTimer);_playerLocPollTimer=null;}
  if(name==='effigies'){_playerLocPollTimer=setInterval(fetchPlayerLocations,15000);}
}
var _playerLocPollTimer=null;
// "New content" pulse dot on a nav tab -- lit when a watch match (or other tracked
// event) surfaces while the user isn't already looking at that tab, cleared the moment
// they click into it (switchView above). Keyed by data-tab so callers just pass the tab
// name ('pals'/'eggs'/etc.) -- notifyWatchFinds's `kind` already matches 1:1.
function markTabNew(name){
  var btn=document.querySelector('.nav-tab[data-tab="'+name+'"]');
  if(btn && !btn.classList.contains('active')) btn.classList.add('has-new');
}
function clearTabNew(name){
  var btn=document.querySelector('.nav-tab[data-tab="'+name+'"]');
  if(btn) btn.classList.remove('has-new');
}

// ── Paldeck data ──────────────────────────────────────────────────────────────
// [paldexNo, internalName, displayName, isVariant]
var PAL_LIST=[
[1,'SheepBall','Lamball',false],
[2,'PinkCat','Cattiva',false],
[3,'ChickenPal','Chikipi',false],
[4,'Carbunclo','Lifmunk',false],
[5,'Kitsunebi','Foxparks',false],
[5,'Kitsunebi_Ice','Foxparks Cryst',true],
[6,'BluePlatypus','Fuack',false],
[7,'ElecCat','Sparkit',false],
[8,'Monkey','Tanzee',false],
[9,'FlameBambi','Rooby',false],
[10,'Penguin','Pengullet',false],
[11,'CaptainPenguin','Penking',false],
[11,'CaptainPenguin_Black','Penking Lux',true],
[12,'Hedgehog','Jolthog',false],
[12,'Hedgehog_Ice','Jolthog Cryst',true],
[13,'PlantSlime','Gumoss',false],
[14,'CuteFox','Vixy',false],
[15,'WizardOwl','Hoocrates',false],
[16,'Ganesha','Teafant',false],
[17,'NegativeKoala','Depresso',false],
[18,'WoolFox','Cremis',false],
[19,'DreamDemon','Daedream',false],
[20,'Boar','Rushoar',false],
[21,'NightFox','Nox',false],
[22,'CuteMole','Fuddler',false],
[23,'NegativeOctopus','Killamari',false],
[23,'NegativeOctopus_Neutral','Killamari Primo',true],
[24,'Bastet','Mau',false],
[24,'Bastet_Ice','Mau Cryst',true],
[25,'FlyingManta','Celaray',false],
[25,'FlyingManta_Thunder','Celaray Lux',true],
[26,'Garm','Direhowl',false],
[27,'ColorfulBird','Tocotoco',false],
[28,'FlowerRabbit','Flopie',false],
[29,'CowPal','Mozzarina',false],
[30,'LittleBriarRose','Bristla',false],
[31,'SharkKid','Gobfin',false],
[31,'SharkKid_Fire','Gobfin Ignis',true],
[32,'WindChimes','Hangyu',false],
[32,'WindChimes_Ice','Hangyu Cryst',true],
[33,'GrassPanda','Mossanda',false],
[33,'GrassPanda_Electric','Mossanda Lux',true],
[34,'SweetsSheep','Woolipop',false],
[35,'BerryGoat','Caprity',false],
[35,'BerryGoat_Dark','Caprity Noct',true],
[36,'Alpaca','Melpaca',false],
[37,'Deer','Eikthyrdeer',false],
[37,'Deer_Ground','Eikthyrdeer Terra',true],
[38,'HawkBird','Nitewing',false],
[39,'PinkRabbit','Ribbuny',false],
[39,'PinkRabbit_Grass','Ribbuny Botan',true],
[40,'Baphomet','Incineram',false],
[40,'Baphomet_Dark','Incineram Noct',true],
[41,'CuteButterfly','Cinnamoth',false],
[42,'FlameBuffalo','Arsox',false],
[43,'LazyCatfish','Dumud',false],
[43,'LazyCatfish_Gold','Dumud Gild',true],
[44,'DarkCrow','Cawgnito',false],
[45,'LizardMan','Leezpunk',false],
[45,'LizardMan_Fire','Leezpunk Ignis',true],
[46,'Werewolf','Loupmoon',false],
[46,'Werewolf_Ice','Loupmoon Cryst',true],
[47,'Eagle','Galeclaw',false],
[48,'RobinHood','Robinquill',false],
[48,'RobinHood_Ground','Robinquill Terra',true],
[49,'Gorilla','Gorirat',false],
[49,'Gorilla_Ground','Gorirat Terra',true],
[50,'SoldierBee','Beegarde',false],
[51,'QueenBee','Elizabee',false],
[52,'NaughtyCat','Grintale',false],
[53,'MopBaby','Swee',false],
[54,'MopKing','Sweepa',false],
[55,'WeaselDragon','Chillet',false],
[55,'WeaselDragon_Fire','Chillet Ignis',true],
[56,'Kirin','Univolt',false],
[57,'IceFox','Foxcicle',false],
[58,'FireKirin','Pyrin',false],
[58,'FireKirin_Dark','Pyrin Noct',true],
[59,'IceDeer','Reindrix',false],
[60,'ThunderDog','Rayhound',false],
[61,'AmaterasuWolf','Kitsun',false],
[61,'AmaterasuWolf_Dark','Kitsun Noct',true],
[62,'RaijinDaughter','Dazzi',false],
[62,'RaijinDaughter_Water','Dazzi Noct',true],
[63,'Mutant','Lunaris',false],
[64,'FlowerDinosaur','Dinossom',false],
[64,'FlowerDinosaur_Electric','Dinossom Lux',true],
[65,'Serpent','Surfent',false],
[65,'Serpent_Ground','Surfent Terra',true],
[66,'GhostBeast','Maraith',false],
[67,'DrillGame','Digtoise',false],
[68,'CatBat','Tombat',false],
[69,'PinkLizard','Lovander',false],
[70,'LavaGirl','Flambelle',false],
[71,'BirdDragon','Vanwyrm',false],
[71,'BirdDragon_Ice','Vanwyrm Cryst',true],
[72,'Ronin','Bushi',false],
[72,'Ronin_Dark','Bushi Noct',true],
[73,'ThunderBird','Beakon',false],
[74,'RedArmorBird','Ragnahawk',false],
[75,'CatMage','Katress',false],
[75,'CatMage_Fire','Katress',true],
[76,'FoxMage','Wixen',false],
[76,'FoxMage_Dark','Wixen Noct',true],
[77,'GrassRabbitMan','Verdash',false],
[78,'VioletFairy','Vaelet',false],
[79,'WhiteMoth','Sibelyx',false],
[80,'FairyDragon','Elphidran',false],
[80,'FairyDragon_Water','Elphidran Aqua',true],
[81,'Kelpie','Kelpsea',false],
[81,'Kelpie_Fire','Kelpsea Ignis',true],
[82,'BlueDragon','Azurobe',false],
[82,'BlueDragon_Ice','Azurobe Cryst',true],
[83,'WhiteTiger','Cryolinx',false],
[83,'WhiteTiger_Ground','Cryolinx Terra',true],
[84,'Manticore','Blazehowl',false],
[84,'Manticore_Dark','Blazehowl Noct',true],
[85,'LazyDragon','Relaxaurus',false],
[85,'LazyDragon_Electric','Relaxaurus Lux',true],
[86,'SakuraSaurus','Broncherry',false],
[86,'SakuraSaurus_Water','Broncherry Aqua',true],
[87,'FlowerDoll','Petallia',false],
[88,'VolcanicMonster','Reptyro',false],
[88,'VolcanicMonster_Ice','Reptyro Cryst',true],
[89,'KingAlpaca','Kingpaca',false],
[89,'KingAlpaca_Ice','Kingpaca Cryst',true],
[90,'GrassMammoth','Mammorest',false],
[90,'GrassMammoth_Ice','Mammorest Cryst',true],
[91,'Yeti','Wumpo',false],
[91,'Yeti_Grass','Wumpo Botan',true],
[92,'HerculesBeetle','Warsect',false],
[92,'HerculesBeetle_Ground','Warsect Terra',true],
[93,'FengyunDeeper','Fenglope',false],
[93,'FengyunDeeper_Electric','Fenglope Lux',true],
[94,'CatVampire','Felbat',false],
[95,'SkyDragon','Quivern',false],
[95,'SkyDragon_Grass','Quivern Botan',true],
[96,'KingBahamut','Blazamut',false],
[96,'KingBahamut_Dragon','Blazamut Ryu',true],
[97,'HadesBird','Helzephyr',false],
[97,'HadesBird_Electric','Helzephyr Lux',true],
[98,'BlackMetalDragon','Astegon',false],
[99,'DarkScorpion','Menasting',false],
[99,'DarkScorpion_Ground','Menasting Terra',true],
[100,'Anubis','Anubis',false],
[101,'Umihebi','Jormuntide',false],
[101,'Umihebi_Fire','Jormuntide Ignis',true],
[102,'Suzaku','Suzaku',false],
[102,'Suzaku_Water','Suzaku Aqua',true],
[103,'ElecPanda','Grizzbolt',false],
[104,'LilyQueen','Lyleen',false],
[104,'LilyQueen_Dark','Lyleen Noct',true],
[105,'Horus','Faleris',false],
[105,'Horus_Water','Faleris Aqua',true],
[106,'ThunderDragonMan','Orserk',false],
[107,'BlackGriffon','Shadowbeak',false],
[108,'SaintCentaur','Paladius',false],
[109,'BlackCentaur','Necromus',false],
[110,'IceHorse','Frostallion',false],
[110,'IceHorse_Dark','Frostallion Noct',true],
[111,'JetDragon','Jetragon',false],
[112,'NightLady','Bellanoir',false],
[112,'NightLady_Dark','Bellanoir Libero',true],
[113,'MoonQueen','Selyne',false],
[114,'KendoFrog','Croajiro',false],
[114,'KendoFrog_Dark','Croajiro Noct',true],
[115,'LeafPrincess','Lullu',false],
[116,'MushroomDragon','Shroomer',false],
[116,'MushroomDragon_Dark','Shroomer Noct',true],
[117,'SmallArmadillo','Kikit',false],
[118,'CandleGhost','Sootseer',false],
[119,'ScorpionMan','Prixter',false],
[120,'WingGolem','Knocklem',false],
[121,'GuardianDog','Yakumo',false],
[122,'SifuDog','Dogen',false],
[123,'FeatherOstrich','Dazemu',false],
[124,'MimicDog','Mimog',false],
[125,'DarkAlien','Xenovader',false],
[126,'WhiteAlienDragon','Xenogard',false],
[127,'DarkMechaDragon','Xenolord',false],
[128,'GhostRabbit','Nitemary',false],
[129,'NightBlueHorse','Starryon',false],
[130,'WhiteShieldDragon','Silvegis',false],
[131,'BlackPuppy','Smokie',false],
[132,'WhiteDeer','Celesdir',false],
[133,'MysteryMask','Omascul',false],
[134,'GrimGirl','Splatterina',false],
[135,'PurpleSpider','Tarantriss',false],
[136,'BlueThunderHorse','Azurmane',false],
[137,'SnowTigerBeastman','Bastigor',false],
[138,'BlueberryFairy','Prunelia',false],
[139,'BadCatgirl','Nyafia',false],
[140,'GoldenHorse','Gildane',false],
[141,'LeafMomonga','Herbil',false],
[142,'IceWitch','Icelyn',false],
[143,'SnowPeafowl','Frostplume',false],
[144,'TropicalOstrich','Palumba',false],
[145,'Plesiosaur','Braloha',false],
[146,'IceCrocodile','Munchill',false],
[147,'IceSeal','Polapup',false],
[148,'TentacleTurtle','Turtacle',false],
[148,'TentacleTurtle_Ground','Turtacle Terra',true],
[149,'JellyfishGhost','Jellroy',false],
[150,'JellyfishFairy','Jelliette',false],
[151,'OctopusGirl','Gloopie',false],
[152,'StuffedShark','Finsider',false],
[152,'StuffedShark_Fire','Finsider Ignis',true],
[153,'GhostAnglerfish','Ghangler',false],
[153,'GhostAnglerfish_Fire','Ghangler Ignis',true],
[154,'IceNarwhal','Whalaska',false],
[154,'IceNarwhal_Fire','Whalaska Ignis',true],
[155,'PoseidonOrca','Neptilius',false],
[156,'LegendDeer','Hartalis',false],
[10000,'YakushimaMonster003_Purple','Illuminant Bat',false],
[10001,'YakushimaMonster001_Rainbow','Rainbow Slime',false],
[10002,'YakushimaMonster003','Cave Bat',false],
[10003,'YakushimaBoss001','Eye of Cthulhu',false],
[10004,'YakushimaMonster002','Enchanted Sword',false],
[10005,'YakushimaBoss001_Small','Demon Eye',false],
[10006,'YakushimaMonster001_Purple','Purple Slime',false],
[10007,'YakushimaMonster001_Red','Red Slime',false],
[10008,'YakushimaMonster001','Green Slime',false],
[10009,'YakushimaMonster001_Blue','Blue Slime',false],
[10010,'YakushimaMonster001_Pink','Illuminant Slime',false]
];
var paldeckData=null;

// ---- Pal Box (individual Pals: stats, IVs, location) -------------------------
var palsData=null;
var PAL_LOOKUP=null;

// Curated species-level data (type, work suitability, partner skill, learnable
// skills, base stats) that the SAVE does not contain -- keyed by internal species
// name. Loaded once at boot; the preview's work-suit chips re-render when it lands.
var palSpecies=null;
function loadSpecies(){
  return fetch('/api/pal-species').then(function(r){return r.ok?r.json():{};})
    .then(function(d){palSpecies=d||{};
      if(typeof palsData!=='undefined'&&palsData&&palsData.pals)renderPals();})
    .catch(function(){palSpecies={};});
}
function speciesOf(p){return (palSpecies&&p&&palSpecies[p.species])||null;}
// Per active-skill metadata (element/power/cooldown/status/desc) for the tap-a-skill popup.
// Bundled static on the public site; served at /api/pal-skills on the admin dashboard.
var palSkills=null;
function loadSkills(){
  return fetch('/api/pal-skills').then(function(r){return r.ok?r.json():{};})
    .then(function(d){palSkills=d||{};})
    .catch(function(){palSkills={};});
}
// Per-passive effect text + rating rank for the tap-a-passive popup. Bundled static on the
// public site; served at /api/pal-passives on the admin dashboard.
var palPassives=null;
function loadPassives(){
  return fetch('/api/pal-passives').then(function(r){return r.ok?r.json():{};})
    .then(function(d){palPassives=d||{};})
    .catch(function(){palPassives={};});
}
// Blue Mars / red Venus glyphs (ASCII-safe entities) instead of "Male"/"Female" text.
// Mars / Venus drawn as inline SVG rather than the unicode glyphs. The text glyphs paint low
// in their line box on iOS WebKit (Safari/Chrome), so they never centered with the name there;
// an SVG centers by its own viewBox geometry, identically on every platform. currentColor +
// the g-m/g-f classes keep the blue/red tint.
function genderIcon(g){
  if(g==='Male')return '<svg class="gico g-m" viewBox="0 0 24 24" role="img" aria-label="Male"><title>Male</title><circle cx="10" cy="14" r="5"/><line x1="13.6" y1="10.4" x2="20" y2="4"/><polyline points="14.5,4 20,4 20,9.5"/></svg>';
  if(g==='Female')return '<svg class="gico g-f" viewBox="0 0 24 24" role="img" aria-label="Female"><title>Female</title><circle cx="12" cy="8" r="5"/><line x1="12" y1="13" x2="12" y2="21"/><line x1="7.5" y1="17.5" x2="16.5" y2="17.5"/></svg>';
  return '';
}
// Per-pal stat from the species' level-65 range (linear in IV) scaled to this level.
// HP: 500+5L+(s65-825)*(L/65); Atk/Def: off+(s65-off)*(L/65) with off 100/50. This is
// the BASE stat (level+IV), excluding passive/condensation/food bonuses. The reference
// is level 65 (the current cap, raised 55->60->65): paldb now publishes its Health/Attack/
// Defense ranges at level 65, and pal_species.json carries those, so the anchor moved from
// 55 to 65. 825 = 500 + 5*65 (the HP baseline at the reference level), divisor = 65.
function calcStat(range,level,iv,isHp,off){
  if(!range)return null;
  var L=level||1, s65=range[0]+(range[1]-range[0])*(iv<0?0:iv)/100;
  return isHp?Math.floor(500+5*L+(s65-825)*(L/65)):Math.floor(off+(s65-off)*(L/65));
}
// Bundled paldb suitability/element icons, served at /icons/ (static on the public
// site, via a dashboard route for admin). Maps the species-data strings to icon index.
var WORK_ICON={'Kindling':'00','Watering':'01','Planting':'02','Generating Electricity':'03','Handiwork':'04','Gathering':'05','Lumbering':'06','Mining':'07','Medicine Production':'08','Crude oil extraction':'09','Cooling':'10','Transporting':'11','Farming':'12'};
var ELEM_ICON={'Normal':'00','Fire':'01','Water':'02','Electricity':'03','Leaf':'04','Dark':'05','Dragon':'06','Earth':'07','Ice':'08'};
function workIco(w){var n=WORK_ICON[w];return n?'<img class="cic" src="icons/work_'+n+'.webp" alt="" loading="lazy">':'';}
function elemIco(t){var n=ELEM_ICON[t];return n?'<img class="cic" src="icons/elem_'+n+'.webp" alt="" loading="lazy">':'';}
// Effective work-suitability level for one work type, accounting for the per-pal boosts
// the save records (not just the species base): species base + work-suitability-up items
// (p.workAdd, from GotWorkSuitabilityAddRankList) + the 4-star condensation bonus (rank 5
// gives +1 to suitabilities the pal innately has). Capped at the in-game max of 5.
function workLevel(p,sp,w){
  var base=(sp&&sp.work&&sp.work[w])||0;
  var add=(p&&p.workAdd&&p.workAdd[w])||0;
  var eff=base+add;
  if(base>0 && p && (p.rank||1)>=5) eff+=1;
  return eff>5?5:eff;
}
// Every work type this pal has any suitability in (species base or item boost), so a work
// type granted purely by an item still shows up.
function workKeysOf(p,sp){
  var s={}; if(sp&&sp.work)Object.keys(sp.work).forEach(function(w){s[w]=1;});
  if(p&&p.workAdd)Object.keys(p.workAdd).forEach(function(w){s[w]=1;});
  return Object.keys(s);
}
// EXP_CURVE[L] = total exp to REACH level L (PAL curve, not the player's). Levels 1-55 came
// from save data; 56-65 were appended when the cap rose to 65 (Tides of Terraria), verified
// against the Pal XP table at thepalprofessor.com/xp-tables/ which matches 1-55 exactly.
// Levels 1-65 (65 = cap); index 0 unused.
var EXP_CURVE=[0,0,25,56,93,138,207,306,440,616,843,1131,1492,1941,2495,3175,4007,5021,6253,7747,9555,11740,14378,17559,21392,26007,31561,38241,46272,55925,67524,81458,98195,118294,142429,171406,206194,247955,298084,358255,430475,517155,621186,746039,895878,1075701,1291504,1550483,1861273,2234236,2681807,3218908,3863445,4636905,5565072,6678888,8015483,9619412,11544143,13853835,16625481,19535710,22591450,25799977,29168930,32706331];
var MAX_LEVEL=65;
// TRUST_REQ[n] = total friendship points to reach Trust level n (Palworld wiki). Max 10.
var TRUST_REQ=[0,6000,13000,21000,30000,40000,55000,80000,110000,150000,200000];
// A labelled progress bar with a "remaining to next" readout. Optional cls tints the fill.
function progBar(label,cur,floor,next,unit,cls){
  var span=next-floor, done=span>0?Math.max(0,Math.min(1,(cur-floor)/span)):0;
  return '<div class="pm-prog"><div class="pm-prog-top"><span>'+label+'</span>'
    +'<span class="pm-muted">'+Math.max(0,next-cur).toLocaleString()+' '+unit+' to next</span></div>'
    +'<div class="pm-bar"><div class="pm-bar-fill'+(cls?' '+cls:'')+'" style="width:'+(done*100).toFixed(1)+'%"></div></div></div>';
}
function maxedBar(label,cls){
  return '<div class="pm-prog"><div class="pm-prog-top"><span>'+label+'</span><span class="pm-muted">Max</span></div>'
    +'<div class="pm-bar"><div class="pm-bar-fill'+(cls?' '+cls:'')+'" style="width:100%"></div></div></div>';
}
function palLookup(internal){
  if(!PAL_LOOKUP){
    PAL_LOOKUP={};
    PAL_LIST.forEach(function(e){
      var no=e[0],noStr;
      if(no>=10000)noStr='T'+String(no-9999).padStart(2,'0');else noStr=String(no).padStart(3,'0');
      if(e[3])noStr=noStr+'v';
      PAL_LOOKUP[e[1].toLowerCase()]={no:no,name:e[2],isVar:e[3],noStr:noStr};
    });
  }
  return PAL_LOOKUP[(internal||'').toLowerCase()]||{no:99999,name:internal||'?',isVar:false,noStr:'---'};
}
function palPortrait(name){
  return '/api/palicon?name='+encodeURIComponent(name);
}

// --- Eggs view ----------------------------------------------------------------
// Eggs in base storage, joined to the species they hatch and the owning player.
// Tier (the _NN in PalEgg_Element_NN) maps to a rarity ramp grey->gold.
var eggsData=null;
var EGG_RARITY={1:{n:'T1',c:'#9ca3af'},2:{n:'T2',c:'#3fb950'},3:{n:'T3',c:'#58a6ff'},4:{n:'T4',c:'#a371f7'},5:{n:'T5',c:'#ffd84d'}};
function eggOwnerLabel(e){ return e.ownerName||(e.owner?('Player '+e.owner.slice(0,6)):'Unowned (ghost storage)'); }
async function fetchEggs(silent){
  var area=document.getElementById('eggs-area');
  if(!silent) area.innerHTML='<div class="empty-state">Loading...</div>';
  try{
    eggsData=await api('/api/eggs');
    if(eggsData.error)throw new Error(eggsData.error);
    loadWatches();
    buildEggOwnerSelect();
    buildEggFilterUI();
    maybeApplyEggPrefs();
    renderEggs();
  }catch(e){ area.innerHTML='<div class="empty-state">Failed to load eggs: '+esc(String(e&&e.message||e))+'</div>'; }
}
function buildEggOwnerSelect(){
  var sel=document.getElementById('eggs-owner');
  if(!sel||!eggsData)return;
  var seen={},opts='<option value="">All owners</option>';
  // Prefer the server-cached roster (eggsData.owners) so a player with zero eggs right now
  // still appears in the filter. (Coerce in case a single-entry roster serialized as one
  // object instead of an array.) The roster is already scoped server-side: admins get every
  // player; a scoped viewer gets only themselves, so no other names leak in here.
  var roster=eggsData.owners; if(!Array.isArray(roster)) roster=roster?[roster]:[];
  roster.forEach(function(o){
    var key=(o&&o.prefix)||''; if(!key||seen[key])return; seen[key]=1;
    opts+='<option value="'+esc(key)+'">'+esc((o&&o.name)||('Player '+key.slice(0,6)))+'</option>';
  });
  // Union in any owner present on an egg but missing from the roster (e.g. ghost/orphan
  // storage with no live player), keeping the prior behaviour for those.
  (eggsData.eggs||[]).forEach(function(e){
    var key=e.owner||'';
    if(seen[key])return; seen[key]=1;
    opts+='<option value="'+esc(key)+'">'+esc(eggOwnerLabel(e))+'</option>';
  });
  var cur=sel.value; sel.innerHTML=opts; sel.value=cur;
}
function renderEggs(){
  var area=document.getElementById('eggs-area');
  if(!eggsData){ area.innerHTML='<div class="empty-state">Loading...</div>'; return; }
  var owner=document.getElementById('eggs-owner').value;
  var fLoc=document.getElementById('eggs-location').value;
  var sort=document.getElementById('eggs-sort').value;
  var q=(document.getElementById('eggs-search').value||'').trim().toLowerCase();
  var onlyAlpha=document.getElementById('eggs-alpha').checked;
  var onlyLucky=document.getElementById('eggs-lucky').checked;
  // Advanced filters: type/work/gender/passives from efState; numeric from the inputs.
  var typesSel=Object.keys(efState.types).filter(function(k){return efState.types[k];});
  var workSel=Object.keys(efState.work).filter(function(k){return efState.work[k];});
  var workMin=parseInt(document.getElementById('ef-work-min').value,10)||1;
  var passSel=efState.passives;
  var passExact=document.getElementById('ef-pass-exact').checked;
  var palsSel=efState.pals;
  var fGender=efState.gender;
  var ivMin=parseInt(document.getElementById('ef-iv-min').value,10);
  var ivScope=document.getElementById('ef-iv-scope').value;
  var ivHpMin=parseInt(document.getElementById('ef-iv-hp').value,10);
  var ivAtkMin=parseInt(document.getElementById('ef-iv-atk').value,10);
  var ivDefMin=parseInt(document.getElementById('ef-iv-def').value,10);
  function ivAvg(p){var n=0,s=0;[p.ivHp,p.ivShot,p.ivDefense].forEach(function(v){if(v>=0){s+=v;n++;}});return n?s/n:-1;}
  var list=(eggsData.eggs||[]).filter(function(e){
    if(owner!==''&&(e.owner||'')!==owner)return false;
    if(fLoc&&e.locKind!==fLoc)return false;
    if(palsSel.length&&palsSel.indexOf(e.species)<0)return false;
    if(onlyAlpha&&!e.isAlpha)return false;
    if(onlyLucky&&!e.isLucky)return false;
    if(fGender&&e.gender!==fGender)return false;
    if(!isNaN(ivHpMin)&&e.ivHp<ivHpMin)return false;
    if(!isNaN(ivAtkMin)&&e.ivShot<ivAtkMin)return false;
    if(!isNaN(ivDefMin)&&e.ivDefense<ivDefMin)return false;
    if(!isNaN(ivMin)){
      if(ivScope==='all'){ if(e.ivHp<ivMin||e.ivShot<ivMin||e.ivDefense<ivMin)return false; }
      else if(ivScope==='any'){ if(!(e.ivHp>=ivMin||e.ivShot>=ivMin||e.ivDefense>=ivMin))return false; }
      else if(ivAvg(e)<ivMin)return false;
    }
    if(passSel.length){ var pp=e.passives||[]; for(var pi=0;pi<passSel.length;pi++){ if(pp.indexOf(passSel[pi])<0)return false; } }
    if(passExact&&(e.passives||[]).length!==passSel.length)return false;
    if(typesSel.length||workSel.length||workMin>1){
      var spF=speciesOf(e);
      if(typesSel.length){ var ty=(spF&&spF.types)||[],okT=false; for(var ti=0;ti<typesSel.length;ti++){ if(ty.indexOf(typesSel[ti])>=0){okT=true;break;} } if(!okT)return false; }
      if(workSel.length){ var wk=(spF&&spF.work)||{},okW=false; for(var wi=0;wi<workSel.length;wi++){ if((wk[workSel[wi]]||0)>=workMin){okW=true;break;} } if(!okW)return false; }
      else if(workMin>1){ var wkA=(spF&&spF.work)||{},okWA=false; for(var wkk in wkA){ if(wkA[wkk]>=workMin){okWA=true;break;} } if(!okWA)return false; }
    }
    if(q){
      var look=palLookup(e.species);
      var hay=(look.name+' '+e.species+' '+e.element+' '+(e.passives||[]).join(' ')).toLowerCase();
      if(hay.indexOf(q)<0)return false;
    }
    return true;
  });
  function workSortVal(p){var sp=speciesOf(p),w=(sp&&sp.work)||{},m=0;
    if(workSel.length){for(var i=0;i<workSel.length;i++){var v=w[workSel[i]]||0;if(v>m)m=v;}}
    else{for(var k in w){if(w[k]>m)m=w[k];}}
    return m;}
  list.sort(function(a,b){
    if(!!a.incubating!==!!b.incubating)return a.incubating?-1:1;   // incubating first
    if(sort==='iv')return (ivAvg(b)-ivAvg(a));
    if(sort==='work')return (workSortVal(b)-workSortVal(a))||(ivAvg(b)-ivAvg(a));
    if(sort==='species')return palLookup(a.species).name.localeCompare(palLookup(b.species).name);
    if(sort==='element')return (a.elementIdx-b.elementIdx)||(b.tier-a.tier);
    return (b.tier-a.tier)||(b.isAlpha-a.isAlpha)||palLookup(a.species).name.localeCompare(palLookup(b.species).name);
  });
  updateEggFilterCount();

  // Watches: evaluate every owned egg against each saved watch (independent of the
  // view filters above - watches surface matches, they don't hide anything).
  eggMatchedIds={};
  var matchCounts={}, watchHits=[];
  var pool=(eggsData.eggs||[]).filter(function(e){return e.available;});
  watches.forEach(function(w){
    var hits=pool.filter(function(e){return eggMatchesCrit(e,w.crit);});
    matchCounts[w.id]=hits.length;
    hits.forEach(function(e){eggMatchedIds[e.eggId]=1;});
    if(hits.length)watchHits.push({w:w,hits:hits});
  });
  renderEggWatches(matchCounts);
  notifyWatchFinds('eggs',watchHits,function(e){return e.eggId;});

  var matchesHtml='';
  if(watchHits.length){
    matchesHtml='<div class="egg-matches"><div class="egg-matches-hdr">&#9733; Watched matches</div>';
    watchHits.forEach(function(h){
      var sorted=h.hits.slice().sort(function(a,b){ return (b.ready?1:0)-(a.ready?1:0)||(ivAvg(b)-ivAvg(a)); });
      matchesHtml+='<div class="egg-match-sub">'+esc(h.w.name)+' <span class="cnt">'+h.hits.length+' match'+(h.hits.length===1?'':'es')+'</span></div>';
      matchesHtml+='<div class="pal-grid">'+sorted.map(function(e){return eggCard(e,true);}).join('')+'</div>';
    });
    matchesHtml+='</div>';
  }

  var s=eggsData.summary||{};
  var incList=list.filter(function(e){return e.incubating;});
  var incN=incList.length, readyN=incList.filter(function(e){return e.ready;}).length;
  document.getElementById('eggs-summary').textContent=
    list.length+' shown / '+(s.available||0)+' owned'+
    (incN?(', '+incN+' incubating'+(readyN?(' ('+readyN+' ready)'):'')):'')+', '+(s.orphanContainerEggs||0)+' ghost'+
    (s.orphanRecords?(' ('+s.orphanRecords+' orphaned records)'):'');

  var html='';
  if(!list.length){
    html='<div class="empty-state">No eggs match the current filters.</div>';
  } else {
    // group by owner (owned first, ghost last), then sub-group by location.
    var groups={},order=[];
    list.forEach(function(e){ var k=e.owner||''; if(!groups[k]){groups[k]=[];order.push(k);} groups[k].push(e); });
    order.sort(function(a,b){ if((a==='')!==(b===''))return a===''?1:-1; return 0; });
    order.forEach(function(k){
      var arr=groups[k];
      html+='<div class="egg-group-hdr">'+esc(eggOwnerLabel(arr[0]))+' <span class="cnt">'+arr.length+' egg'+(arr.length===1?'':'s')+'</span></div>';
      var locs={},lorder=[];
      arr.forEach(function(e){ var L=e.loc||'Storage'; if(!locs[L]){locs[L]=[];lorder.push(L);} locs[L].push(e); });
      lorder.sort(function(a,b){ var ea=locs[a][0],eb=locs[b][0]; return ((ea.locOrder||0)-(eb.locOrder||0))||((ea.incNo||0)-(eb.incNo||0))||a.localeCompare(b); });
      lorder.forEach(function(L){
        var le=locs[L];
        html+='<div class="egg-loc-hdr">'+esc(L)+' <span class="cnt">'+le.length+'</span></div>';
        html+='<div class="pal-grid">'+le.map(function(e){return eggCard(e);}).join('')+'</div>';
      });
    });
  }
  area.innerHTML=matchesHtml+html;
  savePrefs();
}

// ---- Eggs page advanced filters (same controls as the Pals page) -----------
var efState={types:{},work:{},gender:'',passives:[],pals:[]};
var efBuilt=false;
function toggleEggFilters(){document.getElementById('eggs-filters').classList.toggle('open');}
function buildEggFilterUI(){
  if(!efBuilt){
    var tc=document.getElementById('ef-types'); tc.innerHTML='';
    ELEM_NAMES.forEach(function(en){
      var c=document.createElement('span'); c.className='pf-chip'; c.title=en;
      c.innerHTML='<img src="icons/elem_'+ELEM_ICON[en]+'.webp" alt=""> '+en;
      c.onclick=function(){efState.types[en]=!efState.types[en];c.classList.toggle('on');renderEggs();};
      tc.appendChild(c);
    });
    var wc=document.getElementById('ef-work'); wc.innerHTML='';
    Object.keys(WORK_ICON).forEach(function(w){
      if(w==='Crude oil extraction')return;
      var c=document.createElement('span'); c.className='pf-chip'; c.title=w;
      c.innerHTML='<img src="icons/work_'+WORK_ICON[w]+'.webp" alt="">';
      c.onclick=function(){efState.work[w]=!efState.work[w];c.classList.toggle('on');renderEggs();};
      wc.appendChild(c);
    });
    efBuilt=true;
  }
  // Full known-passive list (PASSIVE_TIER), plus any extras present on current eggs,
  // so you can filter/watch for a passive even before an egg with it exists.
  var have={}; Object.keys(PASSIVE_TIER).forEach(function(s){have[s]=1;});
  (eggsData&&eggsData.eggs||[]).forEach(function(e){(e.passives||[]).forEach(function(s){have[s]=1;});});
  var sel=document.getElementById('ef-pass-add');
  sel.innerHTML='<option value="">+ Add passive...</option>'+Object.keys(have).sort().map(function(n){return '<option value="'+esc(n)+'">'+esc(n)+'</option>';}).join('');
  // Pal picker: every known species (so you can watch for one you don't have yet).
  var psel=document.getElementById('ef-pal-add');
  if(psel&&psel.options.length<=1){
    var seen={},opts=[];
    PAL_LIST.forEach(function(r){ if(seen[r[1]])return; seen[r[1]]=1; opts.push([r[1],r[2]]); });
    opts.sort(function(a,b){return a[1].localeCompare(b[1]);});
    psel.innerHTML='<option value="">+ Add pal...</option>'+opts.map(function(o){return '<option value="'+esc(o[0])+'">'+esc(o[1])+'</option>';}).join('');
  }
}
function addEggPal(internal){
  if(internal&&efState.pals.indexOf(internal)<0){efState.pals.push(internal);renderEggPalChips();renderEggs();}
  document.getElementById('ef-pal-add').value='';
}
function removeEggPal(internal){efState.pals=efState.pals.filter(function(n){return n!==internal;});renderEggPalChips();renderEggs();}
function renderEggPalChips(){
  var el=document.getElementById('ef-pal'); el.innerHTML='';
  efState.pals.forEach(function(n){
    var c=document.createElement('span'); c.className='pf-pass-chip'; c.textContent=palLookup(n).name;
    var x=document.createElement('b'); x.innerHTML='&times;'; x.onclick=function(){removeEggPal(n);};
    c.appendChild(x); el.appendChild(c);
  });
}
function addEggPassive(name){
  if(name&&efState.passives.indexOf(name)<0&&efState.passives.length<4){efState.passives.push(name);renderEggPassChips();renderEggs();}
  document.getElementById('ef-pass-add').value='';
}
function removeEggPassive(name){efState.passives=efState.passives.filter(function(n){return n!==name;});renderEggPassChips();renderEggs();}
function renderEggPassChips(){
  var el=document.getElementById('ef-pass'); el.innerHTML='';
  efState.passives.forEach(function(n){
    var c=document.createElement('span'); c.className='pf-pass-chip'; c.textContent=n;
    var x=document.createElement('b'); x.innerHTML='&times;'; x.onclick=function(){removeEggPassive(n);};
    c.appendChild(x); el.appendChild(c);
  });
}
function setEggGender(btn){
  efState.gender=btn.getAttribute('data-g');
  Array.prototype.forEach.call(document.getElementById('ef-gender').children,function(b){b.classList.toggle('on',b===btn);});
  renderEggs();
}
function clearEggFilters(){
  efState={types:{},work:{},gender:'',passives:[],pals:[]};
  ['ef-iv-min','ef-iv-hp','ef-iv-atk','ef-iv-def'].forEach(function(id){document.getElementById(id).value='';});
  document.getElementById('ef-iv-scope').value='avg';
  document.getElementById('ef-work-min').value='1';
  document.getElementById('ef-pass-exact').checked=false;
  ['eggs-alpha','eggs-lucky'].forEach(function(id){document.getElementById(id).checked=false;});
  // Owner/location are deliberate standing choices (e.g. "always show my player"), not
  // stray filter state, so Clear leaves them alone -- only the search box resets.
  document.getElementById('eggs-search').value='';
  Array.prototype.forEach.call(document.querySelectorAll('#ef-types .pf-chip,#ef-work .pf-chip'),function(c){c.classList.remove('on');});
  Array.prototype.forEach.call(document.getElementById('ef-gender').children,function(b){b.classList.toggle('on',b.getAttribute('data-g')==='');});
  renderEggPassChips();
  renderEggPalChips();
  renderEggs();
}
function updateEggFilterCount(){
  var n=0;
  n+=Object.keys(efState.types).filter(function(k){return efState.types[k];}).length;
  n+=Object.keys(efState.work).filter(function(k){return efState.work[k];}).length;
  n+=efState.passives.length;
  if(document.getElementById('ef-pass-exact').checked)n++;
  n+=efState.pals.length;
  if(efState.gender)n++;
  if(document.getElementById('ef-iv-min').value!=='')n++;
  ['ef-iv-hp','ef-iv-atk','ef-iv-def'].forEach(function(id){if(document.getElementById(id).value!=='')n++;});
  if(document.getElementById('eggs-alpha').checked)n++;
  if(document.getElementById('eggs-lucky').checked)n++;
  // Owner/location aren't counted -- they're standing choices Clear doesn't touch (see
  // clearEggFilters). Search is counted since Clear does reset it.
  if((document.getElementById('eggs-search').value||'').trim()!=='')n++;
  var badge=document.getElementById('eggs-filter-count');
  if(n){badge.textContent=n;badge.style.display='';}else{badge.style.display='none';}
  document.getElementById('eggs-clear').style.display=n?'':'none';
}

// ---- Egg watches (saved searches) ------------------------------------------
// A watch is a saved filter that does NOT hide anything; matching eggs are pinned
// in a "Watched matches" section at the top and starred in the list, so you can see
// when a breeding pair has produced an egg worth pulling. Stored per-browser.
// Watches are SHARED between the Eggs and Pals pages: a single saved-search list
// lives in localStorage 'palbox_watches' and both pages render it + evaluate it
// against their own data. A watch's crit may carry fields one page doesn't expose
// (egg-only passExact, pal-only level/cond); each matcher just ignores what it
// doesn't use, so the same watch works on both pages.
var watches=[];
function loadWatches(){
  try{
    var raw=localStorage.getItem('palbox_watches');
    if(raw!=null){ watches=JSON.parse(raw)||[]; return; }
    // First run after the split: fold the two old per-page keys into the shared list.
    var merged=[],seen={};
    ['palbox_pal_watches','palbox_egg_watches'].forEach(function(k){
      try{ (JSON.parse(localStorage.getItem(k)||'[]')||[]).forEach(function(w){ if(w&&w.id&&!seen[w.id]){seen[w.id]=1;merged.push(w);} }); }catch(e){}
    });
    watches=merged; if(merged.length)persistWatches();
  }catch(e){ watches=[]; }
}
function persistWatches(){ try{ localStorage.setItem('palbox_watches',JSON.stringify(watches)); }catch(e){} }
var eggMatchedIds={};
var eggEditId=null;   // when set, the Watch button updates this watch instead of adding
// Load a watch's saved criteria back into all the filter controls (for editing).
function applyEggCrit(c){
  efState={types:{},work:{},gender:c.gender||'',passives:(c.passives||[]).slice(),pals:(c.pals||[]).slice()};
  (c.types||[]).forEach(function(t){efState.types[t]=true;});
  (c.work||[]).forEach(function(w){efState.work[w]=true;});
  Array.prototype.forEach.call(document.querySelectorAll('#ef-types .pf-chip'),function(ch){ch.classList.toggle('on',!!efState.types[ch.title]);});
  Array.prototype.forEach.call(document.querySelectorAll('#ef-work .pf-chip'),function(ch){ch.classList.toggle('on',!!efState.work[ch.title]);});
  Array.prototype.forEach.call(document.getElementById('ef-gender').children,function(b){b.classList.toggle('on',b.getAttribute('data-g')===(c.gender||''));});
  document.getElementById('ef-work-min').value=String(c.workMin||1);
  document.getElementById('ef-iv-min').value=(c.ivMin!=null?c.ivMin:'');
  document.getElementById('ef-iv-scope').value=c.ivScope||'avg';
  document.getElementById('ef-iv-hp').value=(c.ivHpMin!=null?c.ivHpMin:'');
  document.getElementById('ef-iv-atk').value=(c.ivAtkMin!=null?c.ivAtkMin:'');
  document.getElementById('ef-iv-def').value=(c.ivDefMin!=null?c.ivDefMin:'');
  document.getElementById('ef-pass-exact').checked=!!c.passExact;
  document.getElementById('eggs-alpha').checked=!!c.alpha;
  document.getElementById('eggs-lucky').checked=!!c.lucky;
  document.getElementById('eggs-search').value=c.q||'';
  renderEggPassChips(); renderEggPalChips();
}
function editEggWatch(id){
  var w=watches.filter(function(x){return x.id===id;})[0]; if(!w)return;
  eggEditId=id;
  applyEggCrit(w.crit);
  document.getElementById('eggs-filters').classList.add('open');
  updateEggWatchBtn();
  renderEggs();
}
function cancelEggEdit(){ eggEditId=null; updateEggWatchBtn(); renderEggs(); }
function updateEggWatchBtn(){
  var btn=document.getElementById('eggs-watch-btn'), cancel=document.getElementById('eggs-cancel-edit');
  if(!btn)return;
  if(eggEditId){
    var w=watches.filter(function(x){return x.id===eggEditId;})[0];
    btn.innerHTML='&#10003; Update'+(w?(': '+esc(w.name)):' watch');
    if(cancel)cancel.style.display='';
  } else {
    btn.innerHTML='&#9733; Watch filter';
    if(cancel)cancel.style.display='none';
  }
}
// Snapshot the current filter controls as watch criteria (owner/location excluded -
// a watch is about the pal, not where you're browsing).
function currentEggCrit(){
  var ivv=document.getElementById('ef-iv-min').value;
  function num(id){var v=document.getElementById(id).value;return v!==''?parseInt(v,10):null;}
  return {
    types:Object.keys(efState.types).filter(function(k){return efState.types[k];}),
    work:Object.keys(efState.work).filter(function(k){return efState.work[k];}),
    workMin:parseInt(document.getElementById('ef-work-min').value,10)||1,
    passives:efState.passives.slice(),
    passExact:document.getElementById('ef-pass-exact').checked,
    pals:efState.pals.slice(),
    gender:efState.gender,
    ivMin:(ivv!==''?parseInt(ivv,10):null),
    ivScope:document.getElementById('ef-iv-scope').value,
    ivHpMin:num('ef-iv-hp'),
    ivAtkMin:num('ef-iv-atk'),
    ivDefMin:num('ef-iv-def'),
    alpha:document.getElementById('eggs-alpha').checked,
    lucky:document.getElementById('eggs-lucky').checked,
    q:(document.getElementById('eggs-search').value||'').trim().toLowerCase()
  };
}
function eggCritName(c){
  var p=[];
  if(c.q)p.push('"'+c.q+'"');
  if(c.pals&&c.pals.length)p.push(c.pals.map(function(n){return palLookup(n).name;}).join('/'));
  if(c.types.length)p.push(c.types.join('/'));
  if(c.passives.length)p.push(c.passives.join('+')+(c.passExact?' (exact)':''));
  else if(c.passExact)p.push('No passives');
  if(c.work.length)p.push(c.work.join('/')+(c.workMin>1?(' '+c.workMin+'+'):''));
  else if(c.workMin>1)p.push('Work '+c.workMin+'+');
  if(c.ivMin!=null)p.push('IV>='+c.ivMin+' '+c.ivScope);
  var st=[];
  if(c.ivHpMin!=null)st.push('HP'+c.ivHpMin); if(c.ivAtkMin!=null)st.push('Atk'+c.ivAtkMin); if(c.ivDefMin!=null)st.push('Def'+c.ivDefMin);
  if(st.length)p.push('IV '+st.join('/'));
  if(c.gender)p.push(c.gender);
  if(c.alpha)p.push('Alpha');
  if(c.lucky)p.push('Lucky');
  return p.join(', ');
}
function eggMatchesCrit(e,c){
  if(c.pals&&c.pals.length&&c.pals.indexOf(e.species)<0)return false;
  if(c.alpha&&!e.isAlpha)return false;
  if(c.lucky&&!e.isLucky)return false;
  if(c.gender&&e.gender!==c.gender)return false;
  if(c.ivHpMin!=null&&e.ivHp<c.ivHpMin)return false;
  if(c.ivAtkMin!=null&&e.ivShot<c.ivAtkMin)return false;
  if(c.ivDefMin!=null&&e.ivDefense<c.ivDefMin)return false;
  if(c.ivMin!=null&&!isNaN(c.ivMin)){
    var iv=[e.ivHp,e.ivShot,e.ivDefense];
    if(c.ivScope==='all'){ if(iv.some(function(v){return v<c.ivMin;}))return false; }
    else if(c.ivScope==='any'){ if(!iv.some(function(v){return v>=c.ivMin;}))return false; }
    else { var n=0,s=0; iv.forEach(function(v){if(v>=0){s+=v;n++;}}); if(!n||s/n<c.ivMin)return false; }
  }
  if(c.passives&&c.passives.length){ var pp=e.passives||[]; for(var i=0;i<c.passives.length;i++)if(pp.indexOf(c.passives[i])<0)return false; }
  if(c.passExact&&(e.passives||[]).length!==(c.passives?c.passives.length:0))return false;
  if((c.types&&c.types.length)||(c.work&&c.work.length)||(c.workMin||1)>1){
    var sp=speciesOf(e);
    if(c.types&&c.types.length){ var ty=(sp&&sp.types)||[],ok=false; for(var t=0;t<c.types.length;t++)if(ty.indexOf(c.types[t])>=0){ok=true;break;} if(!ok)return false; }
    if(c.work&&c.work.length){ var wk=(sp&&sp.work)||{},ok2=false; for(var w=0;w<c.work.length;w++)if((wk[c.work[w]]||0)>=(c.workMin||1)){ok2=true;break;} if(!ok2)return false; }
    else if((c.workMin||1)>1){ var wkA=(sp&&sp.work)||{},ok3=false; for(var k in wkA)if(wkA[k]>=c.workMin){ok3=true;break;} if(!ok3)return false; }
  }
  if(c.q){ var look=palLookup(e.species); var hay=(look.name+' '+e.species+' '+e.element+' '+(e.passives||[]).join(' ')).toLowerCase(); if(hay.indexOf(c.q)<0)return false; }
  return true;
}
// --- Watch find alerts -------------------------------------------------------
// When a refresh surfaces a NEW pal/egg matching a saved watch, flash a banner and
// play a chime. The matched-id set is baselined on the first render of each tab (so
// existing matches are silent on load); we alert only on ids that appear afterward.
// Saving/editing a watch sets _watchSuppress for that one render so a freshly created
// watch over existing pals doesn't self-trigger. Keyed per kind because the shared
// watch list is evaluated separately on the Pals and Eggs tabs.
var _watchSeen={pals:null,eggs:null}, _watchSuppress=false, _watchAudio=null;
function notifyWatchFinds(kind,watchHits,idOf){
  var seen=_watchSeen[kind];
  var cur={};
  watchHits.forEach(function(h){h.hits.forEach(function(it){cur[idOf(it)]=1;});});
  if(seen===null){ _watchSeen[kind]=cur; return; }            // first render: baseline only
  if(_watchSuppress){ for(var s in cur){seen[s]=1;} return; } // watch just saved/edited
  var names=[], newTotal=0;
  watchHits.forEach(function(h){
    var n=h.hits.filter(function(it){return !seen[idOf(it)];}).length;
    if(n>0){ names.push(h.w.name); newTotal+=n; }
  });
  for(var k in cur){ seen[k]=1; }                             // each item alerts only once
  if(newTotal>0) watchFoundAlert(kind,names,newTotal);
}
function watchFoundAlert(kind,names,count){
  var label=(kind==='eggs')?'egg':'pal';
  var uniq=names.filter(function(v,i){return names.indexOf(v)===i;});
  var who=uniq.slice(0,3).join(', ')+(uniq.length>3?(' +'+(uniq.length-3)+' more'):'');
  showWatchBanner('&#9733; Watch hit: '+count+' new '+label+(count===1?'':'s')+' matched &mdash; '+esc(who));
  playWatchChime();
  markTabNew(kind);
}
// Transient top banner, built on demand so no HTML template change is needed (works on
// both the admin dashboard and the generated public site). Click or 8s timeout dismisses.
function showWatchBanner(html){
  var b=document.getElementById('watch-banner');
  if(!b){
    b=document.createElement('div'); b.id='watch-banner';
    b.style.cssText='position:fixed;top:14px;left:50%;transform:translateX(-50%);z-index:9999;'+
      'background:#1c1f26;border:1px solid #ffd84d;color:#ffd84d;border-radius:10px;'+
      'padding:10px 16px;font-weight:700;box-shadow:0 6px 24px rgba(0,0,0,.5);cursor:pointer;'+
      'max-width:90vw;text-align:center;';
    b.onclick=function(){b.style.display='none';};
    document.body.appendChild(b);
  }
  b.innerHTML=html; b.style.display='';
  clearTimeout(b._t); b._t=setTimeout(function(){b.style.display='none';},8000);
}
// Two-note sine chime via WebAudio (no asset to bundle, ASCII-only source).
function playWatchChime(){
  try{
    if(!_watchAudio){ var AC=window.AudioContext||window.webkitAudioContext; if(!AC)return; _watchAudio=new AC(); }
    var ac=_watchAudio; if(ac.state==='suspended') ac.resume();
    var now=ac.currentTime;
    [880,1320].forEach(function(f,i){
      var o=ac.createOscillator(), g=ac.createGain();
      o.type='sine'; o.frequency.value=f;
      var t=now+i*0.16;
      g.gain.setValueAtTime(0.0001,t);
      g.gain.exponentialRampToValueAtTime(0.25,t+0.02);
      g.gain.exponentialRampToValueAtTime(0.0001,t+0.18);
      o.connect(g); g.connect(ac.destination); o.start(t); o.stop(t+0.2);
    });
  }catch(e){}
}
// Browsers block audio until a user gesture; prime/resume the context on the first
// interaction so the chime can play later during a silent auto-refresh.
function _primeWatchAudio(){
  try{
    if(!_watchAudio){ var AC=window.AudioContext||window.webkitAudioContext; if(AC)_watchAudio=new AC(); }
    if(_watchAudio&&_watchAudio.state==='suspended')_watchAudio.resume();
  }catch(e){}
  window.removeEventListener('pointerdown',_primeWatchAudio); window.removeEventListener('keydown',_primeWatchAudio);
}
window.addEventListener('pointerdown',_primeWatchAudio); window.addEventListener('keydown',_primeWatchAudio);
function saveEggWatch(){
  var c=currentEggCrit();
  var auto=eggCritName(c);
  if(!auto){ alert('Set at least one filter (type, passive, IV, etc.) before saving a watch.'); return; }
  if(eggEditId){
    var w=watches.filter(function(x){return x.id===eggEditId;})[0];
    if(w){
      var nm=prompt('Watch name:',w.name); if(nm===null)return;
      // Overlay this page's fields onto the existing crit so pal-only criteria
      // (level/cond) on a shared watch survive an edit made from the Eggs page.
      w.name=(nm||'').trim()||auto; w.crit=Object.assign({},w.crit,c);
    }
    eggEditId=null; updateEggWatchBtn(); persistWatches();
    // Watch saved: clear the composing filter and collapse the menu (clearEggFilters re-renders).
    // _watchSuppress stops that re-render from self-alerting for the watch we just edited.
    _watchSuppress=true; clearEggFilters(); _watchSuppress=false;
    document.getElementById('eggs-filters').classList.remove('open');
    return;
  }
  var name=prompt('Name this watch:',auto);
  if(name===null)return;
  name=(name||'').trim()||auto;
  watches.push({id:'w'+Date.now(),name:name,crit:c});
  persistWatches();
  // Watch saved: clear the now-redundant filter inputs and collapse the menu so the list
  // returns to the full set with the new watch marking matches. clearEggFilters re-renders.
  // _watchSuppress stops that re-render from firing a "found" alert for the watch we just made.
  _watchSuppress=true; clearEggFilters(); _watchSuppress=false;
  document.getElementById('eggs-filters').classList.remove('open');
}
function removeEggWatch(id){
  watches=watches.filter(function(w){return w.id!==id;});
  if(eggEditId===id){eggEditId=null;updateEggWatchBtn();}
  persistWatches(); renderEggs();
}
function renderEggWatches(matchCounts){
  var bar=document.getElementById('eggs-watches');
  if(!watches.length){ bar.style.display='none'; bar.innerHTML=''; return; }
  bar.style.display='';
  bar.innerHTML='<span style="color:var(--muted);font-size:12px;margin-right:2px;">Watches:</span>'+
    watches.map(function(w){
      var cnt=matchCounts[w.id]||0;
      return '<span class="egg-watch-chip'+(w.id===eggEditId?' editing':'')+'">'+
        '<span class="wc-n" onclick="editEggWatch(\''+w.id+'\')" title="Edit this watch">'+esc(w.name)+'</span>'+
        (cnt?('<span class="wc-c">'+cnt+'</span>'):'<span style="color:var(--muted);font-size:11px;">0</span>')+
        '<b class="wc-edit" onclick="editEggWatch(\''+w.id+'\')" title="Edit">&#9998;</b>'+
        '<b onclick="removeEggWatch(\''+w.id+'\')" title="Remove watch">&times;</b></span>';
    }).join('');
}

// Egg cards use the same layout as Pals cards (.pal-card) but never open a popup;
// the outline shows status (green=ready, yellow=incubating). Bred eggs carry the
// pre-rolled pal (IVs/passives); wild eggs roll their contents at hatch.
function eggCard(e,showLoc){
  var look=palLookup(e.species);
  var hasData=(e.ivHp!=null&&(e.ivHp>=0||e.ivShot>=0||e.ivDefense>=0))||(e.passives&&e.passives.length);
  var watched=!!eggMatchedIds[e.eggId];
  var border=e.incubating?(e.ready?' egg-ready':' egg-incu'):(e.isLucky?' lucky':(e.isAlpha?' alpha':''));
  var cls='pal-card egg-card-w'+border+(e.available?'':' egg-unowned')+(watched?' egg-watched':'');
  var genderBadge=e.gender?genderIcon(e.gender):'';
  var badges='';
  if(e.isAlpha)badges+='<span class="pal-badge pb-alpha">Alpha</span>';
  if(e.isLucky)badges+='<span class="pal-badge pb-lucky">Lucky</span>';
  var status;
  if(e.incubating){
    status=e.ready?'<span class="egg-status sr">Ready to hatch</span>':'<span class="egg-status si">Incubating</span>';
  } else {
    var rar=EGG_RARITY[e.tier]||{n:'T'+e.tier,c:'#9ca3af'};
    status='<span class="egg-status" style="color:'+rar.c+'">'+rar.n+' '+esc(e.element)+'</span>'
      +(e.available?'':'<span class="egg-ghost" title="In an orphaned container - not reachable in-game">ghost</span>');
  }
  var ivs=hasData?('<div class="pal-ivs">'+ivRow('HP',e.ivHp)+ivRow('Atk',e.ivShot)+ivRow('Def',e.ivDefense)+'</div>'):'';
  var passives=(e.passives&&e.passives.length)?('<div class="pm-pgrid">'+e.passives.map(passivePill).join('')+'</div>'):'';
  var hint=hasData?'':'<div class="egg-hint">contents roll at hatch</div>';
  // In the matches section, show where the egg is so it can be found/pulled.
  var locTag=showLoc?('<div class="egg-loc-tag">'+esc(e.ownerName||e.owner||'')+' &middot; '+esc(e.loc||'')+'</div>'):'';
  var incuTag=e.incubating?'<span class="egg-incu-tag" title="In an incubator">&#9203;</span>':'';
  var star=watched?'<span class="egg-watch-star" title="Matches a watch">&#9733;</span>':'';
  return '<div class="'+cls+'">'
    +'<div class="pal-card-top">'
      +'<img class="pal-portrait" loading="lazy" src="'+palPortrait(look.name)+'" onerror="this.style.visibility=\'hidden\'">'
      +'<div style="min-width:0;flex:1;">'
        +'<div class="pal-name">'+esc(look.name)+'</div>'
        +'<div class="pal-sub">#'+look.noStr+'</div>'
        +'<div class="pal-badges">'+genderBadge+badges+status+'</div>'
      +'</div>'
      +incuTag+star
    +'</div>'
    +ivs+passives+locTag+hint
    +'</div>';
}
// IV color ramp: red/orange/green by value, gold for a perfect 100.
function ivColor(v){ if(v<0)return 'var(--muted)'; if(v>=100)return '#ffd84d'; if(v<40)return '#f85149'; if(v<70)return '#d29922'; return '#3fb950'; }
// Element accent colors (r,g,b) chosen to complement each suitability icon, so the
// type pill is tinted to its element instead of the old flat purple.
var ELEM_RGB={'Normal':'156,163,175','Fire':'255,112,67','Water':'88,166,255','Electricity':'242,204,96','Leaf':'63,185,80','Dark':'163,113,247','Dragon':'45,212,191','Earth':'192,132,87','Ice':'86,212,221'};
function elemPill(t){
  var rgb=ELEM_RGB[t]||'163,113,247';
  return '<span class="elem-pill" style="background:rgba('+rgb+',.16);border-color:rgba('+rgb+',.55);color:rgb('+rgb+')">'+elemIco(t)+' '+esc(t)+'</span>';
}
// Move (active skill) -> element index, scraped from paldb (class element_color_NN).
// Used to tint skill chips by their element. Unknown moves fall back to Normal.
var ELEM_NAMES=['Normal','Fire','Water','Electricity','Leaf','Dark','Dragon','Earth','Ice'];
var MOVE_ELEM={
  'Absolute Frost':'08','Acid Rain':'02','Aegis Charge':'06','Air Blade':'00','Air Cannon':'00','All Range Thunder':'03','Antler Uppercut':'00','Apocalypse':'05',
  'Aqua Burst':'02','Aqua Gun':'02','Aqua Surge':'02','Astral Ray':'05','Beam Comet':'06','Beam Slash':'06','Beam Slicer':'06','Beckon Lightning':'03',
  'Bee Quiet':'04','Blast Cannon':'06','Blast Punch':'03','Blazing Horn':'01','Blizzard Claw':'08','Blizzard Spike':'08','Bog Blast':'07',
  'Bolt Blink':'03','Botanical Smash':'04','Bountiful Protection':'04','Brawn Impact':'01','Bubble Blast':'02','Cat Press':'00','Chaotic Spray':'08','Charge Cannon':'06',
  'Chicken Rush':'00','Circle Vine':'04','Cloud Tempest':'00','Comet Barrage':'06','Comet Strike':'06','Cosmic Meteor':'06','Crash Dash':'07','Cross Lightning':'03',
  'Crosswind':'04','Crushing Punch':'04','Crystal Breath':'08','Crystal Wing':'08','Curtain Splash':'02','Daring Flames':'01','Daring Shadowstorm':'05','Dark Arrow':'05',
  'Dark Ball':'05','Dark Cannon':'05','Dark Charge':'05','Dark Laser':'05','Dark Shot':'05','Dark Whisp':'05','Dash Kick':'04','Deep Breath':'04',
  'Diamond Rain':'08','Divine Disaster':'05','Divine Disaster II':'05','Divine Wing':'00','Double Blizzard Spike':'08','Draconic Breath':'06','Dragon Burst':'06','Dragon Cannon':'06',
  'Dragon Meteor':'06','Earth Dash':'07','Earth Impact':'07','Electric Ball':'03','Emperor Slide':'08','Evil Slash':'05','Fierce Fang':'00','Fire Ball':'01',
  'Fire Tackle':'01','Firefist Breathstorm':'06','Flame Breath':'01','Flame Funnel':'01','Flame Wall':'01','Flame Waltz':'05','Flare Arrow':'01','Flare Storm':'01',
  'Flare Twister':'01','Fluffy Tackle':'00','Focus Shot':'04','Forceful Charge':'07','Freeze Wall':'08','Freezing Charge':'08','Frenzied Charge':'05','Frost Burst':'08',
  'Frost Talon':'08','Gale Claw':'00','Geyser Gush':'02','Giga Horn':'07','Glacial Impact':'08',
  'Grass Tornado':'04','Ground Cutter':'07','Ground Pound':'00','Ground Smash':'07','Grudge Barrage':'05','Heavy Thunder Tank':'03','Hellfire Claw':'01',
  'High Breach':'08','Holy Burst':'00','Holy Nova':'00','Hydro Jet':'02','Hydro Laser':'02','Hydro Slicer':'02','Hydro Spin':'02',
  'Iaigiri':'01','Ice Missile':'08','Iceberg':'08','Icicle Bullet':'08','Icicle Cutter':'08','Icicle Line':'08','Ignis Blast':'01','Ignis Breath':'01',
  'Ignis Charge':'01','Ignis Rage':'01','Implode':'00','Intimidate':'00','Jumping Claw':'05','Jumping Stinger':'07','Kerauno':'03','Kingly Slam':'00',
  'Konoha Flip':'04','Lantern Sweep':'02','Lawn Bowling':'04','Leaping Roundhouse':'04','Lethal Laser':'03','Lethal Step':'05','Lightning Bolt':'03','Lightning Claw':'03',
  'Lightning Dive':'03','Lightning Gale':'03','Lightning Streak':'03','Lightning Strike':'03','Lock-On Lunge':'05','Lock-on Laser':'03','Magma Serpent':'01','Magna Crush':'06',
  'Megaton Implode':'00','Meteorain':'06','Moonlight Beam':'00','Multicutter':'04','Muscle Slam':'04','Mystic Whirlwind':'06','Needle Spear':'04','Nightmare Ball':'05',
  'Nightmare Bloom':'05','Nightmare Ray':'05','Ocular Rush':'05','Omega Laser':'06','Pal Blast':'00','Phantom Peck':'05','Phoenix Flare':'01','Phoenix Tide':'02',
  'Plasma Funnel':'03','Poison Blast':'05','Poison Fog':'05','Poison Shower':'05','Polykeraunos':'03','Power Bomb':'00',
  'Power Shot':'00','Predator Blast':'00','Predator Mark':'00','Predator Surge':'00','Psycho Gravity':'05','Punch':'00','Punch Flurry':'00','Purifying Light':'00',
  'Radiant Barrage':'00','Raging Flame Wave':'01','Raid Cutter':'04','Reckless Charge':'07','Reflect Leaf':'04','Rock Lance':'07','Rockburst':'07','Rocket Slam':'06',
  'Roly Poly':'00','Rush Beak':'01','Sacred Rain':'00','Sand Tornado':'07','Sand Twister':'07','Satellite Bit':'06','Scorching Lantern Sweep':'01','Scratch':'00',
  'Seed Machine Gun':'04','Seed Mine':'04','Seigetsu Blade':'00','Seigetsu Flash':'00','Servant Call':'05','Shadow Burst':'05','Shell Spin':'07','Shockwave':'03',
  'Slime Press (Dark)':'05','Slime Press (Fire)':'01','Slime Press (Grass)':'04','Slime Press (Neutral)':'00','Slime Press (Rainbow)':'00','Slime Press (Water)':'02','Slither Slam':'02','Smoke Jet':'02',
  'Snow Bowling':'08','Snow Claw':'08','Solar Blast':'04','Soul Drain':'05','Spark Blast':'03','Spear Thrust':'00','Spine Vine':'04',
  'Spinning Roundhouse':'07','Spinning Staff':'04','Spirit Dash':'05','Spirit Fire':'01','Spirit Flame':'05','Splash':'02','Star Mine':'00','Stone Beat':'07',
  'Stone Blast':'07','Stone Cannon':'07','Stone Claw':'07','Surfing Slam':'02','Sword Charge':'00','Tempest Blizzard':'08','Thalassonic Laser':'02','Throw':'00',
  'Thunder Rail':'03','Thunder Rain':'03','Thunder Spear':'03','Thunder Tempest':'03','Thunderslide':'03','Thunderstorm':'03','Tornado Attack':'00',
  'Torrential Blast':'02','Tri-Lightning':'03','TriSpark':'03','Trigger Happy':'02','Twin Spears':'05','Umbral Surge':'05',
  'Upper Smash':'05','Volcanic Burst':'01','Volcanic Fang':'01',
  'Volcanic Rain':'01','Webstrike Impact':'05','Wholehearted Stance':'00','Wind Barrier':'04','Wind Cutter':'04','Wind Edge':'04',
  'Winged Assault':'00'
};
// A skill chip tinted to the move's element, with the element icon. Clickable: a delegated
// handler (in the pal-modal script) opens the skill-detail popup keyed by data-skill.
function skillChip(name){
  var idx=MOVE_ELEM[name]; if(idx==null)idx='00';
  var en=ELEM_NAMES[+idx]||'Normal', rgb=ELEM_RGB[en]||'156,163,175';
  return '<span class="pal-chip skill-chip" data-skill="'+esc(name)+'" style="cursor:pointer;background:rgba('+rgb+',.16);border-color:rgba('+rgb+',.5);color:rgb('+rgb+')">'
    +'<img class="cic" src="icons/elem_'+idx+'.webp" alt="" loading="lazy">'+esc(name)+'</span>';
}
function skillChips(arr){return (arr&&arr.length)?arr.map(skillChip).join(''):'<span class="pm-muted">None</span>';}
// Passive rating (from paldb's raw passive-rank{N} HTML, authoritative): positive = good,
// negative = bad; magnitude is the tier (1-3 arrows). 4 = legendary passive. Drives the
// passive_pos_N/neg_N icon + tier color in passivePill (palworld.wiki.gg styling).
// Unlisted passives (gear/faction/skill-fruit) fall back to tier 0 (neutral, no arrow).
var PASSIVE_TIER={
  'Legend':4,'Lucky':4,'Demon God':4,'Diamond Body':4,'Remarkable Craftsmanship':4,'Mastery of Fasting':4,'Heart of the Immovable King':4,'Swift':4,'Eternal Engine':4,'Vampiric':4,'Lunker':4,'King of the Waves':4,'Siren of the Void':4,'Eternal Flame':4,'Blood Is Fuel':4,'Invader':4,'Savior':4,'Tempest Fury':4,
  'Ace Swimmer':3,'Artisan':3,'Burly Body':3,'Celestial Emperor':3,'Diet Lover':3,'Divine Dragon':3,'Earth Emperor':3,'Ferocious':3,'Flame Emperor':3,'Ice Emperor':3,'Infinite Stamina':3,'Logging Foreman':3,'Lord of Lightning':3,'Lord of the Sea':3,'Lord of the Underworld':3,'Mine Foreman':3,'Motivational Leader':3,'Noble':3,'Philanthropist':3,'Runner':3,'Serenity':3,'Spirit Emperor':3,'Stronghold Strategist':3,'Vanguard':3,'Workaholic':3,
  'Musclehead':2,
  'Abnormal':1,'Aggressive':1,'Blood of the Dragon':1,'Botanical Barrier':1,'Brave':1,'Capacitor':1,'Cheery':1,'Coldblooded':1,'Conceited':1,'Dainty Eater':1,'Dragonkiller':1,'Earthquake Resistant':1,'Fine Furs':1,'Fit as a Fiddle':1,'Fragrant Foliage':1,'Hard Skin':1,'Heated Body':1,'Hooligan':1,'Hydromaniac':1,'Impatient':1,'Insulated Body':1,'Masochist':1,'Nimble':1,'Nocturnal':1,'Otherworldly Cells':1,'Positive Thinker':1,'Power of Gaia':1,'Pyromaniac':1,'Sadist':1,'Serious':1,'Sleek Stroke':1,'Suntan Lover':1,'Veil of Darkness':1,'Waterproof':1,'Work Slave':1,'Zen Mind':1,
  'Clumsy':-1,'Coward':-1,'Downtrodden':-1,'Easygoing':-1,'Glutton':-1,'Mentally unstable':-1,'Mercy Hit':-1,'Shabby':-1,'Sickly':-1,'Unstable':-1,
  'Bottomless Stomach':-2,'Destructive':-2,
  'Brittle':-3,'Pacifist':-3,'Slacker':-3
};
// Renders one passive in the exact palworld.wiki.gg style (passive-skill-* markup):
// a chiseled-frame pill whose tier class drives the bundled arrow icon + tint (1-2
// neutral white, 3 gold, 4 legendary green/blue, negatives red). The <i> icon and the
// ::after frame are colored by CSS; unknown passives render plain with no arrow.
function passivePill(name){
  var t=PASSIVE_TIER[name]; if(t==null)t=0;
  var cls='ppill', ico='<i class="pp-ico"></i>', n;
  if(t>=4){ cls+=' pp-pos4'; }
  else if(t>0){ n=Math.min(t,3); cls+=' pp-pos'+n; }
  else if(t<0){ n=Math.min(-t,3); cls+=' pp-neg'+n; }
  else{ cls+=' pp-neu'; ico=''; }
  return '<span class="'+cls+'" data-passive="'+esc(name)+'" style="cursor:pointer;"><span class="pp-name">'+esc(name)+'</span>'+ico+'</span>';
}
// Work Speed has no value in the save; every pal bases at 100 and only a few passives
// move the general (non job-specific) work speed. Sum those that we can map reliably.
var WORK_SPEED_PASSIVE={'Artisan':50,'Remarkable Craftsmanship':100,'Lucky':15,'Work Slave':30,'Conceited':10};
function workSpeed(p){
  var s=70,arr=(p&&p.passives)||[],i;
  for(i=0;i<arr.length;i++){if(WORK_SPEED_PASSIVE[arr[i]]!=null)s+=WORK_SPEED_PASSIVE[arr[i]];}
  return s;
}

async function fetchPals(silent){
  var area=document.getElementById('pals-area');
  if(!silent) area.innerHTML='<div class="empty-state">Reading save file (this can take a few seconds)...</div>';
  try{
    var data=await api('/api/pals');
    palsData=data;
    loadWatches();
    // Player selector
    var psel=document.getElementById('pals-player');
    var prev=psel.value;
    psel.innerHTML='<option value="">All players</option>';
    (data.players||[]).forEach(function(p){
      var o=document.createElement('option');o.value=p.prefix;o.textContent=p.name;psel.appendChild(o);
    });
    if(prev)psel.value=prev;
    // Location selector
    var lsel=document.getElementById('pals-location');
    if(lsel.options.length<=1){
      lsel.innerHTML='<option value="">All locations</option>'
        +'<option value="party">Party</option>'
        +'<option value="palbox">Palbox</option>'
        +'<option value="base">Bases</option>';
    }
    buildPalFilterUI();
    maybeApplyPalPrefs();
    renderPals();
  }catch(e){
    area.innerHTML='<div class="empty-state err">Could not load Pals: '+e.message+'</div>';
  }
}

function renderPals(){
  var area=document.getElementById('pals-area');
  if(!palsData||!palsData.pals){area.innerHTML='<div class="empty-state">No pal data</div>';return;}
  var fPlayer=document.getElementById('pals-player').value;
  var fLoc=document.getElementById('pals-location').value;
  var sort=document.getElementById('pals-sort').value;
  var q=(document.getElementById('pals-search').value||'').trim().toLowerCase();
  var onlyAlpha=document.getElementById('pals-alpha').checked;
  var onlyLucky=document.getElementById('pals-lucky').checked;
  // Condensation star level (rank-1): 1-4 = min stars, NaN = off.
  var condMin=parseInt(document.getElementById('pf-cond').value,10);
  // Advanced filters: type/work/gender come from the toggle state (pfState); the rest
  // are read straight from their inputs (blank = inactive).
  var typesSel=Object.keys(pfState.types).filter(function(k){return pfState.types[k];});
  var workSel=Object.keys(pfState.work).filter(function(k){return pfState.work[k];});
  var workMin=parseInt(document.getElementById('pf-work-min').value,10)||1;
  var passSel=pfState.passives;
  var passExact=document.getElementById('pf-pass-exact').checked;
  var palsSel=pfState.pals;
  var fGender=pfState.gender;
  var ivMin=parseInt(document.getElementById('pf-iv-min').value,10);
  var ivScope=document.getElementById('pf-iv-scope').value;
  var ivHpMin=parseInt(document.getElementById('pf-iv-hp').value,10);
  var ivAtkMin=parseInt(document.getElementById('pf-iv-atk').value,10);
  var ivDefMin=parseInt(document.getElementById('pf-iv-def').value,10);
  var lvlMin=parseInt(document.getElementById('pf-lvl-min').value,10);
  var lvlMax=parseInt(document.getElementById('pf-lvl-max').value,10);
  var containers=palsData.containers||{};

  var list=palsData.pals.filter(function(p){
    // Filter by who can ACCESS the pal, not just who owns it: bases are guild
    // property with no per-pal owner (ownerPrefix=''), so key off the container's
    // viewers (guild members for bases, the owner for party/palbox). Fall back to
    // ownerPrefix if a container has no viewers data.
    if(fPlayer){
      var ctr=containers[p.container];
      var vw=ctr&&ctr.viewers;
      if(vw?vw.indexOf(fPlayer)<0:p.ownerPrefix!==fPlayer)return false;
    }
    if(fLoc&&p.locationType!==fLoc)return false;
    if(palsSel.length&&palsSel.indexOf(p.species)<0)return false;
    if(onlyAlpha&&!p.isAlpha)return false;
    if(onlyLucky&&!p.isLucky)return false;
    if(!isNaN(condMin)&&((p.rank||1)-1)<condMin)return false;
    if(fGender&&p.gender!==fGender)return false;
    if(!isNaN(lvlMin)&&(p.level||0)<lvlMin)return false;
    if(!isNaN(lvlMax)&&(p.level||0)>lvlMax)return false;
    if(!isNaN(ivHpMin)&&p.ivHp<ivHpMin)return false;
    if(!isNaN(ivAtkMin)&&p.ivShot<ivAtkMin)return false;
    if(!isNaN(ivDefMin)&&p.ivDefense<ivDefMin)return false;
    if(!isNaN(ivMin)){
      if(ivScope==='all'){ if(p.ivHp<ivMin||p.ivShot<ivMin||p.ivDefense<ivMin)return false; }
      else if(ivScope==='any'){ if(!(p.ivHp>=ivMin||p.ivShot>=ivMin||p.ivDefense>=ivMin))return false; }
      else if(ivAvg(p)<ivMin)return false;
    }
    // Passives: AND (pal must have every selected one).
    if(passSel.length){ var pp=p.passives||[]; for(var pi=0;pi<passSel.length;pi++){ if(pp.indexOf(passSel[pi])<0)return false; } }
    if(passExact&&(p.passives||[]).length!==passSel.length)return false;
    // Type/work need species data; OR within each group. workMin>1 alone (no work
    // chip selected) filters to pals with ANY work suitability at that level+.
    if(typesSel.length||workSel.length||workMin>1){
      var spF=speciesOf(p);
      if(typesSel.length){ var ty=(spF&&spF.types)||[],okT=false; for(var ti=0;ti<typesSel.length;ti++){ if(ty.indexOf(typesSel[ti])>=0){okT=true;break;} } if(!okT)return false; }
      if(workSel.length){ var okW=false; for(var wi=0;wi<workSel.length;wi++){ if(workLevel(p,spF,workSel[wi])>=workMin){okW=true;break;} } if(!okW)return false; }
      else if(workMin>1){ var okWA=false,wkA2=workKeysOf(p,spF); for(var waj=0;waj<wkA2.length;waj++){ if(workLevel(p,spF,wkA2[waj])>=workMin){okWA=true;break;} } if(!okWA)return false; }
    }
    if(q){
      var look=palLookup(p.species);
      var hay=(look.name+' '+p.species+' '+(p.nickname||'')+' '+(p.passives||[]).join(' ')).toLowerCase();
      if(hay.indexOf(q)<0)return false;
    }
    return true;
  });

  function ivAvg(p){var n=0,s=0;[p.ivHp,p.ivShot,p.ivDefense].forEach(function(v){if(v>=0){s+=v;n++;}});return n?s/n:-1;}
  // Highest work suitability level; if work chips are selected, rank by those works only.
  function workSortVal(p){var sp=speciesOf(p),w=(sp&&sp.work)||{},m=0;
    if(workSel.length){for(var i=0;i<workSel.length;i++){var v=w[workSel[i]]||0;if(v>m)m=v;}}
    else{for(var k in w){if(w[k]>m)m=w[k];}}
    return m;}
  list.sort(function(a,b){
    if(sort==='work')return (workSortVal(b)-workSortVal(a))||(b.level-a.level)||(ivAvg(b)-ivAvg(a));
    if(sort==='level')return (b.level-a.level)||(ivAvg(b)-ivAvg(a));
    if(sort==='paldex'){return (palLookup(a.species).no-palLookup(b.species).no)||(b.level-a.level);}
    if(sort==='name')return palLookup(a.species).name.localeCompare(palLookup(b.species).name);
    if(sort==='slot')return ((a.slotIndex==null?9999:a.slotIndex)-(b.slotIndex==null?9999:b.slotIndex));
    return (ivAvg(b)-ivAvg(a))||(b.level-a.level); // iv default
  });

  document.getElementById('pals-summary').textContent=list.length+' of '+palsData.pals.length+' pals';
  updateFilterCount();

  // Watches: evaluate every pal against each saved watch (independent of the view
  // filters above - watches surface matches, they don't hide anything).
  palMatchedIds={};
  var matchCounts={}, watchHits=[];
  (palsData.pals||[]).forEach(function(p){
    watches.forEach(function(w){
      if(palMatchesCrit(p,w.crit)){ matchCounts[w.id]=(matchCounts[w.id]||0)+1; palMatchedIds[p.instanceId]=1; }
    });
  });
  watches.forEach(function(w){
    if(matchCounts[w.id]) watchHits.push({w:w,hits:(palsData.pals||[]).filter(function(p){return palMatchesCrit(p,w.crit);})});
  });
  renderPalWatches(matchCounts);
  notifyWatchFinds('pals',watchHits,function(p){return p.instanceId;});
  var matchesHtml='';
  if(watchHits.length){
    matchesHtml='<div class="egg-matches"><div class="egg-matches-hdr">&#9733; Watched matches</div>';
    watchHits.forEach(function(h){
      var sorted=h.hits.slice().sort(function(a,b){return (ivAvg(b)-ivAvg(a))||(b.level-a.level);});
      matchesHtml+='<div class="egg-match-sub">'+esc(h.w.name)+' <span class="cnt">'+h.hits.length+' match'+(h.hits.length===1?'':'es')+'</span></div>';
      matchesHtml+='<div class="pal-grid">'+sorted.map(function(p){return palCard(p);}).join('')+'</div>';
    });
    matchesHtml+='</div>';
  }

  // Group by location container (label), ordered party > palbox > base
  var order={party:0,palbox:1,base:2,unknown:3};
  var groups={};
  list.forEach(function(p){
    var key=p.location||'Unknown';
    (groups[key]=groups[key]||[]).push(p);
  });
  var keys=Object.keys(groups).sort(function(a,b){
    var ga=groups[a][0],gb=groups[b][0];
    return (order[ga.locationType]-order[gb.locationType])||a.localeCompare(b);
  });

  var html='';
  if(!list.length){
    html='<div class="empty-state">No pals match the current filters.</div>';
  } else {
    var CAP=600,rendered=0;
    for(var ki=0;ki<keys.length;ki++){
      var k=keys[ki],arr=groups[k];
      html+='<div class="pal-group-hdr">'+esc(k)+' <span class="cnt">'+arr.length+'</span></div><div class="pal-grid">';
      for(var i=0;i<arr.length;i++){
        if(rendered>=CAP){html+='</div>';break;}
        html+=palCard(arr[i]);rendered++;
      }
      html+='</div>';
      if(rendered>=CAP)break;
    }
    if(rendered>=CAP&&list.length>CAP){
      html+='<div class="empty-state" style="padding:14px">Showing first '+CAP+' of '+list.length+'. Use the filters or search to narrow down.</div>';
    }
  }
  area.innerHTML=matchesHtml+html;
  savePrefs();
}

// ---- Pals page advanced filters --------------------------------------------
// Toggle-based filters (type/work chips, gender segment, passive chips) keep their
// state here; numeric/flag filters are read straight from their inputs in renderPals.
var pfState={types:{},work:{},gender:'',passives:[],pals:[]};
var pfBuilt=false;
function togglePalFilters(){document.getElementById('pals-filters').classList.toggle('open');}
// Build the type/work chip rows once, and (re)populate the passive dropdown from the
// passives that actually appear in the loaded data so you can't filter for a no-op.
function buildPalFilterUI(){
  if(!pfBuilt){
    var tc=document.getElementById('pf-types'); tc.innerHTML='';
    ELEM_NAMES.forEach(function(en){
      var c=document.createElement('span'); c.className='pf-chip'; c.title=en;
      c.innerHTML='<img src="icons/elem_'+ELEM_ICON[en]+'.webp" alt=""> '+en;
      c.onclick=function(){pfState.types[en]=!pfState.types[en];c.classList.toggle('on');renderPals();};
      tc.appendChild(c);
    });
    var wc=document.getElementById('pf-work'); wc.innerHTML='';
    Object.keys(WORK_ICON).forEach(function(w){
      if(w==='Crude oil extraction')return;
      var c=document.createElement('span'); c.className='pf-chip'; c.title=w;
      c.innerHTML='<img src="icons/work_'+WORK_ICON[w]+'.webp" alt="">';
      c.onclick=function(){pfState.work[w]=!pfState.work[w];c.classList.toggle('on');renderPals();};
      wc.appendChild(c);
    });
    pfBuilt=true;
  }
  // Full known-passive list (PASSIVE_TIER), plus any extras present on current pals,
  // so you can filter/watch for a passive even before a pal with it exists (matches Eggs).
  var have={}; Object.keys(PASSIVE_TIER).forEach(function(s){have[s]=1;});
  (palsData&&palsData.pals||[]).forEach(function(p){(p.passives||[]).forEach(function(s){have[s]=1;});});
  var sel=document.getElementById('pf-pass-add');
  sel.innerHTML='<option value="">+ Add passive...</option>'+Object.keys(have).sort().map(function(n){return '<option value="'+esc(n)+'">'+esc(n)+'</option>';}).join('');
  // Pal picker: every known species (built once), so you can filter by name directly.
  var psel=document.getElementById('pf-pal-add');
  if(psel&&psel.options.length<=1){
    var seen={},opts=[];
    PAL_LIST.forEach(function(r){ if(seen[r[1]])return; seen[r[1]]=1; opts.push([r[1],r[2]]); });
    opts.sort(function(a,b){return a[1].localeCompare(b[1]);});
    psel.innerHTML='<option value="">+ Add pal...</option>'+opts.map(function(o){return '<option value="'+esc(o[0])+'">'+esc(o[1])+'</option>';}).join('');
  }
}
function addPalFilter(internal){
  if(internal&&pfState.pals.indexOf(internal)<0){pfState.pals.push(internal);renderPalNameChips();renderPals();}
  document.getElementById('pf-pal-add').value='';
}
function removePalFilter(internal){pfState.pals=pfState.pals.filter(function(n){return n!==internal;});renderPalNameChips();renderPals();}
function renderPalNameChips(){
  var el=document.getElementById('pf-pal'); el.innerHTML='';
  pfState.pals.forEach(function(n){
    var c=document.createElement('span'); c.className='pf-pass-chip'; c.textContent=palLookup(n).name;
    var x=document.createElement('b'); x.innerHTML='&times;'; x.onclick=function(){removePalFilter(n);};
    c.appendChild(x); el.appendChild(c);
  });
}
function addPassiveFilter(name){
  if(name&&pfState.passives.indexOf(name)<0&&pfState.passives.length<4){pfState.passives.push(name);renderPassFilterChips();renderPals();}
  document.getElementById('pf-pass-add').value='';
}
function removePassiveFilter(name){pfState.passives=pfState.passives.filter(function(n){return n!==name;});renderPassFilterChips();renderPals();}
function renderPassFilterChips(){
  var el=document.getElementById('pf-pass'); el.innerHTML='';
  pfState.passives.forEach(function(n){
    var c=document.createElement('span'); c.className='pf-pass-chip'; c.textContent=n;
    var x=document.createElement('b'); x.innerHTML='&times;'; x.onclick=function(){removePassiveFilter(n);};
    c.appendChild(x); el.appendChild(c);
  });
}
function setGender(btn){
  pfState.gender=btn.getAttribute('data-g');
  Array.prototype.forEach.call(document.getElementById('pf-gender').children,function(b){b.classList.toggle('on',b===btn);});
  renderPals();
}
function clearPalFilters(){
  pfState={types:{},work:{},gender:'',passives:[],pals:[]};
  ['pf-iv-min','pf-iv-hp','pf-iv-atk','pf-iv-def','pf-lvl-min','pf-lvl-max'].forEach(function(id){document.getElementById(id).value='';});
  document.getElementById('pf-iv-scope').value='avg';
  document.getElementById('pf-work-min').value='1';
  document.getElementById('pf-pass-exact').checked=false;
  ['pals-alpha','pals-lucky'].forEach(function(id){document.getElementById(id).checked=false;});
  document.getElementById('pf-cond').value='';
  // Player/location are deliberate standing choices, not stray filter state -- see the
  // matching comment in clearEggFilters. Only the search box resets.
  document.getElementById('pals-search').value='';
  Array.prototype.forEach.call(document.querySelectorAll('#pf-types .pf-chip,#pf-work .pf-chip'),function(c){c.classList.remove('on');});
  Array.prototype.forEach.call(document.getElementById('pf-gender').children,function(b){b.classList.toggle('on',b.getAttribute('data-g')==='');});
  renderPassFilterChips();
  renderPalNameChips();
  renderPals();
}
function updateFilterCount(){
  var n=0;
  n+=Object.keys(pfState.types).filter(function(k){return pfState.types[k];}).length;
  n+=Object.keys(pfState.work).filter(function(k){return pfState.work[k];}).length;
  n+=pfState.passives.length;
  if(document.getElementById('pf-pass-exact').checked)n++;
  n+=pfState.pals.length;
  if(pfState.gender)n++;
  if(document.getElementById('pf-iv-min').value!=='')n++;
  ['pf-iv-hp','pf-iv-atk','pf-iv-def'].forEach(function(id){if(document.getElementById(id).value!=='')n++;});
  if(document.getElementById('pf-lvl-min').value!==''||document.getElementById('pf-lvl-max').value!=='')n++;
  if(document.getElementById('pals-alpha').checked)n++;
  if(document.getElementById('pals-lucky').checked)n++;
  if(document.getElementById('pf-cond').value!=='')n++;
  // Player/location aren't counted -- standing choices Clear doesn't touch. Search is
  // counted since Clear does reset it.
  if((document.getElementById('pals-search').value||'').trim()!=='')n++;
  var badge=document.getElementById('pals-filter-count');
  if(n){badge.textContent=n;badge.style.display='';}else{badge.style.display='none';}
  document.getElementById('pals-clear').style.display=n?'':'none';
}

// ---- Pal watches (saved searches; mirrors the Eggs page) -------------------
// A watch is a saved filter that doesn't hide anything; matching pals are pinned in
// a "Watched matches" section at the top and starred. Stored per-browser.
// Watch store (watches/loadWatches/persistWatches) is shared with the Eggs page.
var palMatchedIds={};
var palEditId=null;
function currentPalCrit(){
  function num(id){var v=document.getElementById(id).value;return v!==''?parseInt(v,10):null;}
  return {
    types:Object.keys(pfState.types).filter(function(k){return pfState.types[k];}),
    work:Object.keys(pfState.work).filter(function(k){return pfState.work[k];}),
    workMin:parseInt(document.getElementById('pf-work-min').value,10)||1,
    passives:pfState.passives.slice(),
    passExact:document.getElementById('pf-pass-exact').checked,
    pals:pfState.pals.slice(),
    gender:pfState.gender,
    ivMin:num('pf-iv-min'), ivScope:document.getElementById('pf-iv-scope').value,
    ivHpMin:num('pf-iv-hp'), ivAtkMin:num('pf-iv-atk'), ivDefMin:num('pf-iv-def'),
    lvlMin:num('pf-lvl-min'), lvlMax:num('pf-lvl-max'),
    cond:num('pf-cond'),
    alpha:document.getElementById('pals-alpha').checked,
    lucky:document.getElementById('pals-lucky').checked,
    q:(document.getElementById('pals-search').value||'').trim().toLowerCase()
  };
}
function palCritName(c){
  var p=[];
  if(c.q)p.push('"'+c.q+'"');
  if(c.pals&&c.pals.length)p.push(c.pals.map(function(n){return palLookup(n).name;}).join('/'));
  if(c.types.length)p.push(c.types.join('/'));
  if(c.passives.length)p.push(c.passives.join('+')+(c.passExact?' (exact)':''));
  else if(c.passExact)p.push('No passives');
  if(c.work.length)p.push(c.work.join('/')+(c.workMin>1?(' '+c.workMin+'+'):''));
  else if(c.workMin>1)p.push('Work '+c.workMin+'+');
  if(c.ivMin!=null)p.push('IV>='+c.ivMin+' '+c.ivScope);
  var st=[];
  if(c.ivHpMin!=null)st.push('HP'+c.ivHpMin); if(c.ivAtkMin!=null)st.push('Atk'+c.ivAtkMin); if(c.ivDefMin!=null)st.push('Def'+c.ivDefMin);
  if(st.length)p.push('IV '+st.join('/'));
  if(c.lvlMin!=null||c.lvlMax!=null)p.push('Lv '+(c.lvlMin!=null?c.lvlMin:'')+'-'+(c.lvlMax!=null?c.lvlMax:''));
  if(c.cond!=null)p.push(c.cond+'*+');
  if(c.gender)p.push(c.gender);
  if(c.alpha)p.push('Alpha');
  if(c.lucky)p.push('Lucky');
  return p.join(', ');
}
function palMatchesCrit(p,c){
  if(c.pals&&c.pals.length&&c.pals.indexOf(p.species)<0)return false;
  if(c.alpha&&!p.isAlpha)return false;
  if(c.lucky&&!p.isLucky)return false;
  if(c.gender&&p.gender!==c.gender)return false;
  if(c.cond!=null&&((p.rank||1)-1)<c.cond)return false;
  if(c.lvlMin!=null&&(p.level||0)<c.lvlMin)return false;
  if(c.lvlMax!=null&&(p.level||0)>c.lvlMax)return false;
  if(c.ivHpMin!=null&&p.ivHp<c.ivHpMin)return false;
  if(c.ivAtkMin!=null&&p.ivShot<c.ivAtkMin)return false;
  if(c.ivDefMin!=null&&p.ivDefense<c.ivDefMin)return false;
  if(c.ivMin!=null&&!isNaN(c.ivMin)){
    var iv=[p.ivHp,p.ivShot,p.ivDefense];
    if(c.ivScope==='all'){ if(iv.some(function(v){return v<c.ivMin;}))return false; }
    else if(c.ivScope==='any'){ if(!iv.some(function(v){return v>=c.ivMin;}))return false; }
    else { var n=0,s=0; iv.forEach(function(v){if(v>=0){s+=v;n++;}}); if(!n||s/n<c.ivMin)return false; }
  }
  if(c.passives&&c.passives.length){ var pp=p.passives||[]; for(var i=0;i<c.passives.length;i++)if(pp.indexOf(c.passives[i])<0)return false; }
  if(c.passExact&&(p.passives||[]).length!==(c.passives?c.passives.length:0))return false;
  if((c.types&&c.types.length)||(c.work&&c.work.length)||(c.workMin||1)>1){
    var sp=speciesOf(p);
    if(c.types&&c.types.length){ var ty=(sp&&sp.types)||[],ok=false; for(var t=0;t<c.types.length;t++)if(ty.indexOf(c.types[t])>=0){ok=true;break;} if(!ok)return false; }
    if(c.work&&c.work.length){ var ok2=false; for(var w=0;w<c.work.length;w++)if(workLevel(p,sp,c.work[w])>=(c.workMin||1)){ok2=true;break;} if(!ok2)return false; }
    else if((c.workMin||1)>1){ var ok3=false,wk3=workKeysOf(p,sp); for(var k3=0;k3<wk3.length;k3++)if(workLevel(p,sp,wk3[k3])>=c.workMin){ok3=true;break;} if(!ok3)return false; }
  }
  if(c.q){ var look=palLookup(p.species); var hay=(look.name+' '+p.species+' '+(p.nickname||'')+' '+(p.passives||[]).join(' ')).toLowerCase(); if(hay.indexOf(c.q)<0)return false; }
  return true;
}
function applyPalCrit(c){
  pfState={types:{},work:{},gender:c.gender||'',passives:(c.passives||[]).slice(),pals:(c.pals||[]).slice()};
  (c.types||[]).forEach(function(t){pfState.types[t]=true;});
  (c.work||[]).forEach(function(w){pfState.work[w]=true;});
  Array.prototype.forEach.call(document.querySelectorAll('#pf-types .pf-chip'),function(ch){ch.classList.toggle('on',!!pfState.types[ch.title]);});
  Array.prototype.forEach.call(document.querySelectorAll('#pf-work .pf-chip'),function(ch){ch.classList.toggle('on',!!pfState.work[ch.title]);});
  Array.prototype.forEach.call(document.getElementById('pf-gender').children,function(b){b.classList.toggle('on',b.getAttribute('data-g')===(c.gender||''));});
  document.getElementById('pf-work-min').value=String(c.workMin||1);
  document.getElementById('pf-iv-min').value=(c.ivMin!=null?c.ivMin:'');
  document.getElementById('pf-iv-scope').value=c.ivScope||'avg';
  document.getElementById('pf-iv-hp').value=(c.ivHpMin!=null?c.ivHpMin:'');
  document.getElementById('pf-iv-atk').value=(c.ivAtkMin!=null?c.ivAtkMin:'');
  document.getElementById('pf-iv-def').value=(c.ivDefMin!=null?c.ivDefMin:'');
  document.getElementById('pf-lvl-min').value=(c.lvlMin!=null?c.lvlMin:'');
  document.getElementById('pf-lvl-max').value=(c.lvlMax!=null?c.lvlMax:'');
  document.getElementById('pf-cond').value=(c.cond!=null?c.cond:'');
  document.getElementById('pf-pass-exact').checked=!!c.passExact;
  document.getElementById('pals-alpha').checked=!!c.alpha;
  document.getElementById('pals-lucky').checked=!!c.lucky;
  document.getElementById('pals-search').value=c.q||'';
  renderPassFilterChips();
  renderPalNameChips();
}
function savePalWatch(){
  var c=currentPalCrit(); var auto=palCritName(c);
  if(!auto){ alert('Set at least one filter before saving a watch.'); return; }
  if(palEditId){
    var w=watches.filter(function(x){return x.id===palEditId;})[0];
    if(w){ var nm=prompt('Watch name:',w.name); if(nm===null)return; w.name=(nm||'').trim()||auto; w.crit=Object.assign({},w.crit,c); }
    palEditId=null; updatePalWatchBtn(); persistWatches();
    // Watch saved: clear the composing filter and collapse the menu (clearPalFilters re-renders).
    // _watchSuppress stops that re-render from self-alerting for the watch we just edited.
    _watchSuppress=true; clearPalFilters(); _watchSuppress=false; document.getElementById('pals-filters').classList.remove('open'); return;
  }
  var name=prompt('Name this watch:',auto); if(name===null)return; name=(name||'').trim()||auto;
  watches.push({id:'w'+Date.now(),name:name,crit:c});
  // Watch saved: clear the composing filter and collapse the menu (clearPalFilters re-renders).
  // _watchSuppress stops that re-render from firing a "found" alert for the watch we just made.
  persistWatches(); _watchSuppress=true; clearPalFilters(); _watchSuppress=false; document.getElementById('pals-filters').classList.remove('open');
}
function removePalWatch(id){ watches=watches.filter(function(w){return w.id!==id;}); if(palEditId===id){palEditId=null;updatePalWatchBtn();} persistWatches(); renderPals(); }
function editPalWatch(id){
  var w=watches.filter(function(x){return x.id===id;})[0]; if(!w)return;
  palEditId=id; applyPalCrit(w.crit);
  document.getElementById('pals-filters').classList.add('open');
  updatePalWatchBtn(); renderPals();
}
function cancelPalEdit(){ palEditId=null; updatePalWatchBtn(); renderPals(); }
function updatePalWatchBtn(){
  var btn=document.getElementById('pals-watch-btn'), cancel=document.getElementById('pals-cancel-edit'); if(!btn)return;
  if(palEditId){
    var w=watches.filter(function(x){return x.id===palEditId;})[0];
    btn.innerHTML='&#10003; Update'+(w?(': '+esc(w.name)):' watch'); if(cancel)cancel.style.display='';
  } else { btn.innerHTML='&#9733; Watch filter'; if(cancel)cancel.style.display='none'; }
}
function renderPalWatches(matchCounts){
  var bar=document.getElementById('pals-watches'); if(!bar)return;
  if(!watches.length){ bar.style.display='none'; bar.innerHTML=''; return; }
  bar.style.display='';
  bar.innerHTML='<span style="color:var(--muted);font-size:12px;margin-right:2px;">Watches:</span>'+
    watches.map(function(w){
      var cnt=matchCounts[w.id]||0;
      return '<span class="egg-watch-chip'+(w.id===palEditId?' editing':'')+'">'+
        '<span class="wc-n" onclick="editPalWatch(\''+w.id+'\')" title="Edit this watch">'+esc(w.name)+'</span>'+
        (cnt?('<span class="wc-c">'+cnt+'</span>'):'<span style="color:var(--muted);font-size:11px;">0</span>')+
        '<b class="wc-edit" onclick="editPalWatch(\''+w.id+'\')" title="Edit">&#9998;</b>'+
        '<b onclick="removePalWatch(\''+w.id+'\')" title="Remove watch">&times;</b></span>';
    }).join('');
}

function palCard(p){
  var look=palLookup(p.species);
  var watched=!!palMatchedIds[p.instanceId];
  var cls='pal-card'+(p.isLucky?' lucky':(p.isAlpha?' alpha':''))+(watched?' egg-watched':'');
  var watchStar=watched?'<span class="egg-watch-star" title="Matches a watch">&#9733;</span>':'';
  // Exact location, mirroring the detail popup's Location section: container label
  // "(type)" on top, the in-game slot position (page/col/row) underneath. Shown on
  // every card now (was popup-only) so a pal can be found without opening it.
  var locMain=p.location?(esc(p.location)+(p.locationType?(' ('+esc(p.locationType)+')'):'')):'';
  var locSlot=(typeof palSlotPos==='function')?palSlotPos(p):'';
  var locTag=locMain?('<div class="egg-loc-tag">'+locMain+(locSlot?('<div class="pm-muted" style="margin-top:1px;">'+locSlot+'</div>'):'')+'</div>'):'';
  var stars=(p.rank>1)?('<span class="pal-stars">'+'&#9733;'.repeat(Math.min(p.rank-1,4))+'</span>'):'';
  var genderBadge=genderIcon(p.gender);
  var badges='';
  if(p.isAlpha)badges+='<span class="pal-badge pb-alpha">Alpha</span>';
  if(p.isLucky)badges+='<span class="pal-badge pb-lucky">Lucky</span>';
  var nick=p.nickname?('<div class="pal-nick">'+esc(p.nickname)+'</div>'):'';
  var ivs=''
    +ivRow('HP',p.ivHp)
    +ivRow('Atk',p.ivShot)
    +ivRow('Def',p.ivDefense);
  // Passives use the same colored 2x2 grid (icons + rarity banner) as the detail popup.
  var passives=(p.passives&&p.passives.length)?('<div class="pm-pgrid">'+p.passives.map(passivePill).join('')+'</div>'):'';
  var soulKeys=p.souls?Object.keys(p.souls).filter(function(k){return p.souls[k]>0;}):[];
  var soulChip=soulKeys.length?'<span class="pal-chip" title="Soul upgrades">Souls x'+soulKeys.length+'</span>':'';
  // Work-suitability chips come from the species table (not the save); empty until
  // loadSpecies() resolves, then renderPals() re-runs.
  var sp=speciesOf(p);
  var wchips=workKeysOf(p,sp).map(function(w){var lv=workLevel(p,sp,w);return lv>0?('<span class="pal-chip wchip" title="'+esc(w)+'">'+workIco(w)+' '+lv+'</span>'):'';}).join('');
  var work=wchips?('<div class="pal-chips pal-work">'+wchips+'</div>'):'';
  // (wchip keeps its icon sizing; the blue tint was removed in CSS per request.)
  // Card is tap-to-open: data-iid lets the delegated handler find this pal. Active
  // abilities (equipMoves) are intentionally NOT shown here -- they live in the popup.
  return '<div class="'+cls+'" data-iid="'+p.instanceId+'">'
    +'<div class="pal-card-top">'
      +'<img class="pal-portrait" loading="lazy" src="'+palPortrait(look.name)+'" onerror="this.style.visibility=\'hidden\'">'
      +'<div style="min-width:0;flex:1;">'
        +'<div class="pal-name">'+esc(look.name)+genderBadge+stars+'</div>'
        +nick
        +'<div class="pal-sub">#'+look.noStr+' &bull; Lv '+p.level+'</div>'
        +(badges?('<div class="pal-badges">'+badges+'</div>'):'')
      +'</div>'
      +watchStar
    +'</div>'
    +'<div class="pal-ivs">'+ivs+'</div>'
    +passives
    +(soulChip?('<div class="pal-chips">'+soulChip+'</div>'):'')
    +work
    +locTag
    +'</div>';
}

function ivRow(lbl,v){
  var w=v<0?0:Math.min(v,100);
  var disp=v<0?'-':String(v);
  return '<div class="iv-row"><span class="lbl">'+lbl+'</span>'
    +'<div class="iv-bar"><div class="iv-fill" style="width:'+w+'%;background:'+ivColor(v)+';"></div></div>'
    +'<span class="val">'+disp+'</span></div>';
}

async function fetchPaldeck(){
  var area=document.getElementById('paldeck-area');
  area.innerHTML='<div class="empty-state">Loading...</div>';
  try{
    var data=await api('/api/paldeck');
    paldeckData=data;
    // Try to match player names from online players (players global already fetched)
    if(data.players&&players.length){
      data.players.forEach(function(p){
        var match=players.find(function(op){
          var uid=((op.playerid||op.playeruid||op.userid||'')+'').replace(/-/g,'').toUpperCase();
          return uid&&uid===p.guid.toUpperCase();
        });
        if(match&&match.name) p.name=match.name;
      });
    }
    var sel=document.getElementById('paldeck-player');
    var prev=sel.value;
    sel.innerHTML='';
    (data.players||[]).forEach(function(p){
      var opt=document.createElement('option');
      opt.value=p.guid; opt.textContent=p.name;
      sel.appendChild(opt);
    });
    if(prev) sel.value=prev;
    else{if((data.players||[]).length)sel.value=data.players[0].guid;}
    maybeApplyPaldeckPrefs();
    renderPaldeck();
  }catch(e){
    area.innerHTML='<div class="empty-state err">Could not load Paldeck: '+e.message+'</div>';
  }
}

function renderPaldeck(){
  var area=document.getElementById('paldeck-area');
  if(!paldeckData||!paldeckData.players||!paldeckData.players.length){
    area.innerHTML='<div class="empty-state">No player data</div>';
    return;
  }
  var sel=document.getElementById('paldeck-player');
  var guid=sel.value;
  var player=(paldeckData.players||[]).find(function(p){return p.guid===guid;});
  if(!player){player=paldeckData.players[0];if(sel&&player)sel.value=player.guid;}
  if(!player){area.innerHTML='<div class="empty-state">Select a player</div>';return;}

  var counts=player.counts||{};
  var normCounts={};
  Object.keys(counts).forEach(function(k){normCounts[k.toLowerCase()]=Number(counts[k])||0;});

  var checkTotal=0,rows='',yakIdx=0;
  var sorted=PAL_LIST.slice().sort(function(a,b){
    return (a[0]-b[0])||((a[3]?1:0)-(b[3]?1:0));
  });
  var rowDataArr=[];
  sorted.forEach(function(e,idx){
    var no=e[0],key=e[1].toLowerCase(),name=e[2],isVar=e[3];
    var count=normCounts[key]||0;
    var isYak=no>=10000;
    var noStr;
    if(isYak){yakIdx++;noStr='T'+String(yakIdx).padStart(2,'0');}
    else{noStr=String(no).padStart(3,'0');}
    if(isVar)noStr=noStr+'v';
    rowDataArr.push({name:name,internal:e[1],noStr:noStr,count:count});
    var done=count>=12;
    if(done)checkTotal++;
    var bg=done?'background:rgba(63,185,80,0.06);':'';
    var cnt=count?('<span style="color:var(--text)">'+count+'</span>'):('<span style="color:var(--muted)">0</span>');
    var chk=done?'<span style="color:var(--green);font-weight:700">&#10003;</span>':'';
    var imgUrl='/api/palicon?name='+encodeURIComponent(name);
    rows+='<tr style="border-bottom:1px solid var(--border);'+bg+'">'
      +'<td style="padding:4px 10px;color:var(--muted);font-size:11px;text-align:right;white-space:nowrap;width:55px;">'+noStr+'</td>'
      +'<td style="padding:2px 4px;width:44px;text-align:center;cursor:pointer;" onclick="openPaldeckDetail('+idx+')"><img src="'+imgUrl+'" loading="lazy" onerror="this.style.display=\'none\'" style="width:40px;height:40px;object-fit:contain;vertical-align:middle;pointer-events:none;"></td>'
      +'<td style="padding:4px 10px;cursor:pointer;" onclick="openPaldeckDetail('+idx+')">'+name+'</td>'
      +'<td style="padding:4px 10px;text-align:center;width:60px;">'+cnt+'</td>'
      +'<td style="padding:4px 10px;text-align:center;width:32px;">'+chk+'</td>'
      +'</tr>';
  });
  window._palRowData=rowDataArr;
  var allCount=PAL_LIST.length;
  var sumStr=player.total+' unique captured | '+checkTotal+'/'+allCount+' at 12+';
  document.getElementById('paldeck-summary').textContent=sumStr;
  area.innerHTML=
    '<div style="overflow-y:auto;max-height:520px;">'
    +'<table style="width:100%;border-collapse:collapse;font-size:13px;">'
    +'<thead style="position:sticky;top:0;background:var(--surface2);z-index:1;">'
    +'<tr style="color:var(--muted);font-size:10px;text-transform:uppercase;letter-spacing:.6px;">'
    +'<th style="padding:6px 10px;text-align:right;width:55px;">#</th>'
    +'<th style="padding:6px 10px;width:44px;"></th>'
    +'<th style="padding:6px 10px;text-align:left;">Name</th>'
    +'<th style="padding:6px 10px;text-align:center;width:60px;">Caught</th>'
    +'<th style="padding:6px 10px;text-align:center;width:32px;">&#10003;</th>'
    +'</tr></thead>'
    +'<tbody>'+rows+'</tbody>'
    +'</table></div>';
  savePrefs();
}

var palMapLeaflet=null,palMapMarkers=[],palMapTime='dayTimeLocations',palMapCurrent=null,palMapAbort=null;
// Spawn-zone state: cached points for the current pal/time, the zone layers (kept separate from
// the boss markers), and the clustering tightness (lower = more, smaller zones).
var palSpawnLocs=[], palZoneLayers=[], palZoneTight=0.01;

function loadLeaflet(cb){
  if(window.L){cb();return;}
  var css=document.createElement('link');
  css.rel='stylesheet';
  css.href='https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css';
  document.head.appendChild(css);
  var js=document.createElement('script');
  js.src='https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js';
  js.onload=cb;
  document.head.appendChild(js);
}

function initPalLeafletMap(){
  if(palMapLeaflet) return;
  var blockSize=131072;
  window._palMapCfg={blockSize:blockSize,realMin:{X:-999940,Y:-737262},realMax:{X:447900,Y:710578}};
  palMapLeaflet=L.map('pal-leaflet-map',{minZoom:0,maxZoom:8,zoom:1,crs:L.CRS.Simple});
  var sw=palMapLeaflet.unproject([0,blockSize],8);
  var ne=palMapLeaflet.unproject([blockSize,0],8);
  var bounds=L.latLngBounds(sw,ne);
  palMapLeaflet.setMaxBounds(bounds).setView(palMapLeaflet.unproject([blockSize/2,blockSize/2],8),1);
  L.tileLayer('/api/palmaptile?z={z}&x={x}&y={y}',{
    bounds:bounds,maxNativeZoom:4,tileSize:512,keepBuffer:4
  }).addTo(palMapLeaflet);
}

function palRposToLatLng(rpos){
  var cfg=window._palMapCfg;
  var sx=(rpos.X-cfg.realMin.X)/(cfg.realMax.X-cfg.realMin.X);
  var sy=(rpos.Y-cfg.realMin.Y)/(cfg.realMax.Y-cfg.realMin.Y);
  return palMapLeaflet.unproject([sy*cfg.blockSize,(1-sx)*cfg.blockSize],8);
}
// Spawn-zone geometry helpers: a real position normalized to 0..1 of the world (for proximity
// clustering, independent of zoom), single-linkage clustering, convex hull (Andrew monotone
// chain), and a centroid-based expand so the zone border sits just outside the points.
function palSpawnNorm(rpos){
  var cfg=window._palMapCfg;
  return [(rpos.X-cfg.realMin.X)/(cfg.realMax.X-cfg.realMin.X),(rpos.Y-cfg.realMin.Y)/(cfg.realMax.Y-cfg.realMin.Y)];
}
function clusterSpawnPts(pts,thr){
  var n=pts.length, parent=[], i, j;
  for(i=0;i<n;i++)parent[i]=i;
  function find(a){while(parent[a]!==a){parent[a]=parent[parent[a]];a=parent[a];}return a;}
  var t2=thr*thr;
  for(i=0;i<n;i++)for(j=i+1;j<n;j++){
    var dx=pts[i].n[0]-pts[j].n[0], dy=pts[i].n[1]-pts[j].n[1];
    if(dx*dx+dy*dy<t2)parent[find(i)]=find(j);
  }
  var groups={};
  for(i=0;i<n;i++){var r=find(i);(groups[r]=groups[r]||[]).push(pts[i]);}
  return Object.keys(groups).map(function(k){return groups[k];});
}
function convexHull(P){
  if(P.length<3)return P.slice();
  P=P.slice().sort(function(a,b){return a[0]-b[0]||a[1]-b[1];});
  var cr=function(o,a,b){return (a[0]-o[0])*(b[1]-o[1])-(a[1]-o[1])*(b[0]-o[0]);};
  var lo=[],up=[],i;
  for(i=0;i<P.length;i++){while(lo.length>=2&&cr(lo[lo.length-2],lo[lo.length-1],P[i])<=0)lo.pop();lo.push(P[i]);}
  for(i=P.length-1;i>=0;i--){while(up.length>=2&&cr(up[up.length-2],up[up.length-1],P[i])<=0)up.pop();up.push(P[i]);}
  lo.pop();up.pop();
  return lo.concat(up);
}
function expandHull(hull,f){
  var cx=0,cy=0,n=hull.length,i;
  for(i=0;i<n;i++){cx+=hull[i][0];cy+=hull[i][1];}
  cx/=n;cy/=n;
  return hull.map(function(p){return [cx+(p[0]-cx)*f,cy+(p[1]-cy)*f];});
}
// Chaikin corner-cutting on a CLOSED polygon: each pass replaces every vertex with two points
// at 1/4 and 3/4 along its edges, rounding the corners into a smooth blob. A couple of passes
// is plenty for the few-vertex spawn hulls.
function smoothPoly(pts,iter){
  for(var k=0;k<iter;k++){
    if(pts.length<3)break;
    var out=[];
    for(var i=0;i<pts.length;i++){
      var a=pts[i], b=pts[(i+1)%pts.length];
      out.push([a[0]*0.75+b[0]*0.25, a[1]*0.75+b[1]*0.25]);
      out.push([a[0]*0.25+b[0]*0.75, a[1]*0.25+b[1]*0.75]);
    }
    pts=out;
  }
  return pts;
}
// Ray-casting point-in-polygon ([lat,lng] point, [[lat,lng],...] ring).
function pointInPoly(pt,poly){
  var x=pt[0],y=pt[1],inside=false,n=poly.length,i,j;
  for(i=0,j=n-1;i<n;j=i++){
    var xi=poly[i][0],yi=poly[i][1],xj=poly[j][0],yj=poly[j][1];
    if(((yi>y)!==(yj>y)) && (x<(xj-xi)*(y-yi)/(yj-yi)+xi)) inside=!inside;
  }
  return inside;
}
// Convex-polygon overlap test (Separating Axis Theorem). Exact for the convex hulls here.
function polysOverlap(A,B){
  var P=[A,B],pi,j,k;
  for(pi=0;pi<2;pi++){var poly=P[pi];
    for(j=0;j<poly.length;j++){
      var a=poly[j],b=poly[(j+1)%poly.length], nx=-(b[1]-a[1]), ny=(b[0]-a[0]);
      var mnA=Infinity,mxA=-Infinity,mnB=Infinity,mxB=-Infinity,v;
      for(k=0;k<A.length;k++){v=A[k][0]*nx+A[k][1]*ny;if(v<mnA)mnA=v;if(v>mxA)mxA=v;}
      for(k=0;k<B.length;k++){v=B[k][0]*nx+B[k][1]*ny;if(v<mnB)mnB=v;if(v>mxB)mxB=v;}
      if(mxA<mnB||mxB<mnA)return false;
    }
  }
  return true;
}
// Merge zones whose (convex, expanded) hulls overlap into one rounded blob: pool their points
// and re-hull. Iterate until no two hulls intersect, so a merged shape that now touches a third
// zone keeps merging. Each zone = {pts:[[lat,lng]...], hull:[[lat,lng]...] (expanded convex)}.
function mergeZones(zones){
  var changed=true;
  while(changed){
    changed=false;
    for(var i=0;i<zones.length && !changed;i++){
      for(var j=i+1;j<zones.length;j++){
        if(polysOverlap(zones[i].hull,zones[j].hull)){
          var pooled=zones[i].pts.concat(zones[j].pts);
          zones[i]={pts:pooled,hull:expandHull(convexHull(pooled),1.12)};
          zones.splice(j,1);
          changed=true;
          break;
        }
      }
    }
  }
  return zones;
}

function openPalMap(idx){
  var d=window._palRowData&&window._palRowData[idx];
  if(!d) return;
  palMapCurrent={internal:d.internal,name:d.name};
  document.getElementById('pal-map-modal').style.display='flex';
  document.getElementById('pal-map-name').textContent=d.name;
  var img=document.getElementById('pal-map-img');
  img.src='/api/palicon?name='+encodeURIComponent(d.name);
  img.style.display=''; img.onerror=function(){this.style.display='none';};
  document.getElementById('pal-map-status').textContent='Loading...';
  loadLeaflet(function(){
    requestAnimationFrame(function(){
      if(!palMapLeaflet){
        initPalLeafletMap();
      } else {
        palMapLeaflet.invalidateSize();
      }
      showPalMapData(d.internal,d.name);
    });
  });
}

function makeBossIcon(imgUrl){
  return L.divIcon({
    html:'<div style="width:38px;height:38px;border-radius:50%;border:2.5px solid #e3b341;'
        +'box-shadow:0 2px 8px rgba(0,0,0,0.85);overflow:hidden;background:#1a1a1a;">'
        +'<img src="'+imgUrl+'" style="width:100%;height:100%;object-fit:contain;" onerror="this.parentElement.style.background=\'#e3b341\'">'
        +'</div>',
    iconSize:[38,38],iconAnchor:[19,19],className:''
  });
}

async function showPalMapData(internal,displayName){
  if(palMapAbort){palMapAbort.abort();}
  palMapAbort=new AbortController();
  var sig=palMapAbort.signal;
  palMapMarkers.forEach(function(m){palMapLeaflet.removeLayer(m);});
  palMapMarkers=[];
  palZoneLayers.forEach(function(l){palMapLeaflet.removeLayer(l);});
  palZoneLayers=[];
  var _ee=document.getElementById('pal-map-empty'); if(_ee)_ee.style.display='none';
  var statusParts=[];
  try{
    var r=await fetch('/api/palspawn?pal='+encodeURIComponent(internal),{signal:sig});
    var locs=[];
    if(r.ok){
      var data=await r.json();
      locs=(data[palMapTime]&&data[palMapTime].locations)||[];
    } else if(r.status!==404){ throw new Error('HTTP '+r.status); }
    // Cache the points and draw the spawn zones (see drawSpawnZones); cached so a redraw can
    // re-cluster without re-fetching.
    palSpawnLocs=locs;
    drawSpawnZones();

    // Alpha (BOSS_) spawns -- portrait icons, always shown regardless of day/night
    var blocsCount=0;
    var palImg='/api/palicon?name='+encodeURIComponent(displayName||internal);
    try{
      var br=await fetch('/api/palspawn?pal=BOSS_'+encodeURIComponent(internal),{signal:sig});
      if(br.ok){
        var bdata=await br.json();
        var blocs=(bdata.dayTimeLocations&&bdata.dayTimeLocations.locations)||[];
        blocsCount=blocs.length;
        var bicon=makeBossIcon(palImg);
        blocs.forEach(function(rpos){
          var m=L.marker(palRposToLatLng(rpos),{icon:bicon,zIndexOffset:1000}).addTo(palMapLeaflet);
          palMapMarkers.push(m);
        });
        if(blocs.length) statusParts.push(blocs.length+' alpha'+(blocs.length===1?'':'s'));
      }
    }catch(e){if(e.name==='AbortError')throw e;}

    // Nothing to plot (no spawns AND no alphas) -> show a big "?" over the map instead of a
    // blank tile; otherwise hide it and frame whatever we drew.
    var emptyEl=document.getElementById('pal-map-empty');
    var allLayers=palZoneLayers.concat(palMapMarkers);
    if(allLayers.length>0){
      if(emptyEl)emptyEl.style.display='none';
      var lone=(locs.length<=1 && blocsCount===0);
      var grp=L.featureGroup(allLayers);
      palMapLeaflet.fitBounds(grp.getBounds().pad(lone?0.8:0.25),{maxZoom:5});
    } else if(emptyEl){
      emptyEl.style.display='flex';
    }
    document.getElementById('pal-map-status').textContent=statusParts.join(' + ');
  } catch(e){
    if(e.name==='AbortError') return;
    document.getElementById('pal-map-status').textContent='Error: '+e.message;
  }
}
// Redraw just the spawn-zone layers from the cached points using the current tightness, leaving
// the boss markers and the map view untouched -- this is what the tightness slider calls.
function drawSpawnZones(){
  if(!palMapLeaflet)return;
  palZoneLayers.forEach(function(l){palMapLeaflet.removeLayer(l);});
  palZoneLayers=[];
  var locs=palSpawnLocs||[];
  var pts=locs.map(function(rpos){return {ll:palRposToLatLng(rpos),n:palSpawnNorm(rpos)};});
  // Build zone candidates (clusters of 3+ points that form a polygon); collect isolated points.
  var zones=[], smalls=[];
  clusterSpawnPts(pts,palZoneTight).forEach(function(cl){
    if(cl.length>=3){
      var cp=cl.map(function(p){return [p.ll.lat,p.ll.lng];});
      var h=convexHull(cp);
      if(h.length>=3){ zones.push({pts:cp,hull:expandHull(h,1.12)}); return; }
    }
    cl.forEach(function(p){smalls.push(p);});
  });
  // Merge any overlapping zones into one rounded blob, then draw (Chaikin-smoothed) so the
  // merge reads as a single smooth shape rather than two intersecting polygons.
  zones=mergeZones(zones);
  var hulls=[];
  zones.forEach(function(z){
    hulls.push(z.hull);
    var poly=L.polygon(smoothPoly(z.hull,2),{
      color:'#1f6feb',weight:2,opacity:0.95,fillColor:'#58a6ff',fillOpacity:0.3,lineJoin:'round'
    }).addTo(palMapLeaflet);
    palZoneLayers.push(poly);
  });
  // Isolated points -> a minimum-size zone circle (~ the old dot size), styled like the zones;
  // skipped if it already falls inside a merged zone (avoids stray circles inside a zone).
  smalls.forEach(function(p){
    var ll=[p.ll.lat,p.ll.lng];
    for(var z=0;z<hulls.length;z++){ if(pointInPoly(ll,hulls[z])) return; }
    var m=L.circleMarker(p.ll,{radius:6,color:'#1f6feb',weight:2,fillColor:'#58a6ff',fillOpacity:0.3}).addTo(palMapLeaflet);
    palZoneLayers.push(m);
  });
}

function closePalMap(){
  document.getElementById('pal-map-modal').style.display='none';
}

function setPalMapTime(t){
  palMapTime=t;
  document.getElementById('btn-map-day').style.fontWeight=t==='dayTimeLocations'?'700':'400';
  document.getElementById('btn-map-night').style.fontWeight=t==='nightTimeLocations'?'700':'400';
  if(palMapCurrent) showPalMapData(palMapCurrent.internal,palMapCurrent.name);
}

// ── Effigy Tracker ────────────────────────────────────────────────────────────
var effigyLeaflet=null, effigyMarkerLayer=null, effigyLocations=null, effigyCollected=[], effigyInited=false;
var _effigyAwaitingRoster=false;
var _effigyPrefsWaitTries=0;
var EFFIGY_MAX_RANK=353;
// Bigger dots on touch devices (no hover there, and a 5px dot is a tiny tap target).
var EFF_DOT_R=(('ontouchstart' in window)||(navigator.maxTouchPoints>0))?9:5;
// Effigy/journal glyphs are divIcons, not SVG dots, so they need their own (slightly
// larger, so the shape actually reads) size in px rather than a radius.
var EFF_ACORN_SZ=EFF_DOT_R*4;
function effigyAcornIcon(found){
  return L.divIcon({
    className:'eff-map-marker'+(found?' eff-map-found':''),
    html:'<img src="icons/effigy_'+(found?'acorn_found':'acorn')+'.png" alt="">',
    iconSize:[EFF_ACORN_SZ,EFF_ACORN_SZ],
    iconAnchor:[EFF_ACORN_SZ/2,EFF_ACORN_SZ/2]
  });
}
function journalBookIcon(found){
  return L.divIcon({
    className:'eff-map-marker'+(found?' eff-map-found':''),
    html:'<img src="icons/journal_'+(found?'book_found':'book')+'.png" alt="">',
    iconSize:[EFF_ACORN_SZ,EFF_ACORN_SZ],
    iconAnchor:[EFF_ACORN_SZ/2,EFF_ACORN_SZ/2]
  });
}
// Bounty-boss (named legendary Alpha) marker: the Pal's own portrait in a circular ring
// (same style as makeBossIcon on the per-species spawn map) instead of a fixed glyph, since
// each bounty boss IS a different Pal. Grayed out via CSS (.bounty-marker.eff-map-found)
// once NormalBossDefeatFlag shows that species defeated, rather than swapping images -- we
// don't have a separate "grey" portrait asset per Pal.
var BOUNTY_ICON_SZ=EFF_ACORN_SZ*1.6;
function bountyBossIcon(name,found){
  var img='<img src="'+palPortrait(name)+'" onerror="this.style.visibility=\'hidden\'">';
  return L.divIcon({
    className:'eff-map-marker bounty-marker'+(found?' eff-map-found':''),
    html:'<div class="bounty-ring">'+img+'</div>',
    iconSize:[BOUNTY_ICON_SZ,BOUNTY_ICON_SZ],
    iconAnchor:[BOUNTY_ICON_SZ/2,BOUNTY_ICON_SZ/2]
  });
}
// Wanted Fugitive (human/Syndicate bosses), Eagle Statue (fast-travel points), NPC, and
// Landmarks (discovered areas, everything else) have no dedicated art -- plain
// colored-dot divIcons, same sizing as the acorn/book glyphs, distinguished by color only
// (see the toggle buttons' legend dots). `found` grays the dot out, same convention as
// effigies/journals -- only NPC currently passes a real found value; the others have no
// per-player state so always render in color.
function simpleDotIcon(colorHex,found){
  return L.divIcon({
    className:'eff-map-marker'+(found?' eff-map-found':''),
    html:'<div style="width:100%;height:100%;border-radius:50%;background:'+(found?'#484f58':colorHex)+';border:2px solid #fff;box-sizing:border-box;"></div>',
    iconSize:[EFF_ACORN_SZ,EFF_ACORN_SZ],
    iconAnchor:[EFF_ACORN_SZ/2,EFF_ACORN_SZ/2]
  });
}
function wantedFugitiveIcon(){ return simpleDotIcon('#f85149'); }
function landmarkIcon(){ return simpleDotIcon('#a371f7'); }
// Live player position marker: a colored dot, plus (if the save has a current Rotation --
// it's briefly absent right after a teleport/spawn, see /palworld-dataminer) a small
// triangular "nose" showing facing direction, rotated by yawDeg. NOTE: yawDeg's mapping onto
// this map's own screen orientation is a best-effort quaternion->compass-heading formula,
// NOT independently verified against the map's actual up/down/left/right -- if the arrow
// visibly doesn't match which way a player is really facing in-game, that's a rotation-offset
// bug to fix here, not a data bug.
// Compass-arrow shape (a chevron pointing "up" before rotation), same clip-path drawn
// twice at different insets to fake a white outline -- clip-path shapes can't take a
// plain CSS border like the circular markers elsewhere on this map do.
var PLAYER_ARROW_CLIP='polygon(50% 0%, 100% 100%, 50% 76%, 0% 100%)';
function playerMarkerIcon(yawDeg){
  var hasYaw=(typeof yawDeg==='number'&&!isNaN(yawDeg));
  // Facing is briefly unknown right after a teleport/spawn (see /palworld-dataminer) --
  // still point the arrow "up" so the marker isn't blank, but fade it to signal the
  // heading isn't real data.
  var op=hasYaw?'1':'0.45';
  var rot=hasYaw?yawDeg:0;
  return L.divIcon({
    className:'eff-map-marker',
    html:'<div style="width:100%;height:100%;position:relative;opacity:'+op+';transform:rotate('+rot+'deg);">'
      +'<div style="position:absolute;inset:-2px;background:#fff;clip-path:'+PLAYER_ARROW_CLIP+';"></div>'
      +'<div style="position:absolute;inset:0;background:#58a6ff;clip-path:'+PLAYER_ARROW_CLIP+';"></div>'
      +'</div>',
    iconSize:[EFF_ACORN_SZ,EFF_ACORN_SZ],
    iconAnchor:[EFF_ACORN_SZ/2,EFF_ACORN_SZ/2]
  });
}
function eagleStatueIcon(){ return simpleDotIcon('#e8b339'); }
function npcIcon(found){ return simpleDotIcon('#39c5bb',found); }

// Static lore-journal/diary note locations (game-world fixed, not per-save), loaded once
// from /api/journals and overlaid on the same map as blue dots.
var journalLocations=null;
// Per-player journal collection state, from NoteObtainForInstanceFlag in the save (same
// mechanism as effigies' RelicObtainForInstanceFlag). The in-game Notes/Journal count (49)
// also includes dungeon-boss lore notes (e.g. GrassBoss1, VikingBoss2) that have no map
// location at all, so journalCollectedCount (used for the toolbar "N / 49" summary) will
// never be fully reachable via the map alone. Per-DOT found/new coloring is only possible
// for entries that carry a "key" in journal_locations.json (currently the Castaway's
// Journal "DayN" entries, confirmed/inferred from the actual save key names) -- entries
// without a key always render as "new" since their found state can't be determined.
var journalCollected=[], journalCollectedCount=null;
var JOURNAL_MAX=49;
// Per-player NPC talked-to state, from NPCTalkCountMap (a count map, not a bool flag --
// "collected" here means the player has talked to that NPC at least once).
var npcCollected=[], npcCollectedCount=null;

// Static bounty-boss (named legendary Alpha) locations -- game-world fixed, not per-save,
// loaded once from /api/bounty-bosses (see bounty_bosses.json). Each entry has {species,
// name, x, y, z}; "species" is what NormalBossDefeatFlag entries in the save are matched
// against (see extract_bounty_data in pal_save_reader.py). The server already filters this
// down to Anthony's own confirmed species (see Merge-ConfirmedBounty) -- the Data Mine tab
// fetches the full unfiltered roster separately via a different route.
var bossLocations=null;
// Per-player defeat state: list of species codes, from NormalBossDefeatFlag.
var bossCollected=[];
// Manually-marked bounty bosses, for species NormalBossDefeatFlag can't identify (most of
// them -- the save only names a spawner instance descriptively for a handful of bosses; the
// rest are anonymous zone-numbered keys with no recoverable species). Keyed by player guid
// (not a flat list) so an admin viewing multiple players' maps can't cross-attribute a click
// to the wrong player; a scoped player only ever has their own guid in here anyway. Persisted
// via the existing /api/prefs store (PREFS.bountyManual), public-site only -- PREFS_ENABLED
// is false on admin, so toggleBountyManual is inert there (savePrefs no-ops).
var bountyManual={};
function bountyManualSetFor(guid){
  return new Set((bountyManual[guid]||[]).map(function(s){return s.toUpperCase();}));
}
function toggleBountyManual(species){
  if(!PREFS_ENABLED)return;  // admin dashboard has no /api/prefs write path
  var sel=document.getElementById('effigy-player');
  var guid=sel?sel.value:'';
  if(!guid)return;
  var list=bountyManual[guid]||(bountyManual[guid]=[]);
  var i=list.map(function(s){return s.toUpperCase();}).indexOf(species.toUpperCase());
  if(i===-1) list.push(species); else list.splice(i,1);
  renderEffigyMap();
  savePrefs();
}

// Global visibility filter for the effigy map. Two independent toggles let the player hide
// the effigies they have already found or the ones still new/undiscovered, to declutter the
// map. This is a VIEW filter only -- it never changes a Pal's actual found state (which comes
// solely from the save). Both default on. effigyShowJournal/effigyShowBounty are independent
// toggles for the journal-note / bounty-boss overlays (unrelated to found/new).
var effigyShowFound=true, effigyShowNew=true, effigyShowJournal=true, effigyShowBounty=true, effigyShowFugitive=true, effigyShowEagle=true, effigyShowNpc=true, effigyShowLandmark=true, effigyShowPlayers=true;
function setEffigyFilterBtns(){
  var bf=document.getElementById('eff-filt-found'), bn=document.getElementById('eff-filt-new'), bj=document.getElementById('eff-filt-journal'), bb=document.getElementById('eff-filt-bounty'), bh=document.getElementById('eff-filt-fugitive'), be=document.getElementById('eff-filt-eagle'), bp=document.getElementById('eff-filt-npc'), bl=document.getElementById('eff-filt-landmark'), bpl=document.getElementById('eff-filt-players');
  if(bf) bf.style.opacity=effigyShowFound?'1':'0.4';
  if(bn) bn.style.opacity=effigyShowNew?'1':'0.4';
  if(bj) bj.style.opacity=effigyShowJournal?'1':'0.4';
  if(bb) bb.style.opacity=effigyShowBounty?'1':'0.4';
  if(bh) bh.style.opacity=effigyShowFugitive?'1':'0.4';
  if(be) be.style.opacity=effigyShowEagle?'1':'0.4';
  if(bp) bp.style.opacity=effigyShowNpc?'1':'0.4';
  if(bl) bl.style.opacity=effigyShowLandmark?'1':'0.4';
  if(bpl) bpl.style.opacity=effigyShowPlayers?'1':'0.4';
}
function toggleEffigyFilter(which){
  if(which==='found') effigyShowFound=!effigyShowFound;
  else if(which==='journal') effigyShowJournal=!effigyShowJournal;
  else if(which==='players') effigyShowPlayers=!effigyShowPlayers;
  else if(which==='bounty') effigyShowBounty=!effigyShowBounty;
  else if(which==='fugitive') effigyShowFugitive=!effigyShowFugitive;
  else if(which==='eagle') effigyShowEagle=!effigyShowEagle;
  else if(which==='npc') effigyShowNpc=!effigyShowNpc;
  else if(which==='landmark') effigyShowLandmark=!effigyShowLandmark;
  else effigyShowNew=!effigyShowNew;
  setEffigyFilterBtns();
  renderEffigyMap();
}

// ---- Cross-device UI preferences ------------------------------------------------
// A player's filter / sort / selected-player choices are saved server-side (Worker
// PUT /api/prefs -> R2, keyed by their verified Access email) so they follow them across
// refreshes, sessions AND devices. PREFS_ENABLED is flipped on ONLY for the public site by
// the generator -- the admin dashboard has no /api/prefs route, so it stays off and these
// helpers are inert there (admin filter state is intentionally not persisted).
var PREFS_ENABLED=false;
var PREFS={}, prefsReady=false;
var prefsApplied={pals:false,eggs:false,effigy:false,paldeck:false};
var _prefsTimer=null, _prefsLast=null;
function _gv(id){var el=document.getElementById(id);return el?el.value:'';}
function _optExists(sel,val){
  if(!sel)return false;
  for(var i=0;i<sel.options.length;i++){if(sel.options[i].value===val)return true;}
  return false;
}
function loadPrefs(cb){
  if(!PREFS_ENABLED){if(cb)cb();return;}
  fetch('/api/prefs',{cache:'no-store'}).then(function(r){return r.ok?r.json():{};}).then(function(p){
    PREFS=(p&&typeof p==='object')?p:{};
    prefsReady=true;
    (cb||applyAllPrefs)();
  }).catch(function(){ PREFS={}; prefsReady=true; (cb||applyAllPrefs)(); });
}
// Snapshot the prefs to persist. CRITICAL: a section's live DOM only reflects the user's real
// choices AFTER that section has been applied (prefsApplied[x]). Eggs/Effigy apply lazily --
// only once you open those tabs -- so reading their DOM before then yields un-initialised
// defaults. We therefore BASE the snapshot on the loaded PREFS (preserving any section not yet
// applied) and override a section with live DOM only once it has actually been applied. Without
// this, rendering one tab would write empty defaults over another tab's still-unapplied saved
// filters -- the bug that made saving "spotty" across reloads.
function collectPrefs(){
  var o={v:1};
  if(PREFS&&typeof PREFS==='object'){
    if(PREFS.pals!==undefined)o.pals=PREFS.pals;
    if(PREFS.eggs!==undefined)o.eggs=PREFS.eggs;
    if(PREFS.effigy!==undefined)o.effigy=PREFS.effigy;
    if(PREFS.bountyManual!==undefined)o.bountyManual=PREFS.bountyManual;
  }
  if(prefsApplied.effigy) o.bountyManual=bountyManual;
  var players={};
  if(PREFS&&PREFS.players){ players.paldeck=PREFS.players.paldeck; players.effigy=PREFS.players.effigy; }
  if(prefsApplied.effigy) o.effigy={found:effigyShowFound,nw:effigyShowNew,journal:effigyShowJournal,bounty:effigyShowBounty,fugitive:effigyShowFugitive,eagle:effigyShowEagle,npc:effigyShowNpc,landmark:effigyShowLandmark,players:effigyShowPlayers};
  // Skip persisting while a watch is mid-edit-preview (palEditId/eggEditId set): the filter
  // controls hold that watch's criteria for live preview only, not the user's real standing
  // filter, and must not overwrite it just because a render happened to fire (e.g. clicking a
  // watch chip to inspect it, then leaving without hitting Update or Cancel edit).
  if(prefsApplied.pals&&!palEditId){ try{ o.pals={crit:currentPalCrit(),sort:_gv('pals-sort'),loc:_gv('pals-location'),player:_gv('pals-player')}; }catch(e){} }
  if(prefsApplied.eggs&&!eggEditId){ try{ o.eggs={crit:currentEggCrit(),owner:_gv('eggs-owner'),loc:_gv('eggs-location'),sort:_gv('eggs-sort')}; }catch(e){} }
  if(prefsApplied.paldeck) players.paldeck=_gv('paldeck-player');
  if(prefsApplied.effigy) players.effigy=_gv('effigy-player');
  o.players=players;
  return o;
}
// Persist (debounced) on any filter/sort/player change. Inert until prefs have loaded so the
// initial empty UI can't overwrite saved prefs before we apply them; a no-op if the snapshot
// is unchanged, so auto-refresh re-renders don't generate writes. On a failed PUT we clear
// _prefsLast so the next render (or the 60s auto-refresh) retries instead of giving up.
function savePrefs(){
  if(!PREFS_ENABLED||!prefsReady)return;
  var str;
  try{ str=JSON.stringify(collectPrefs()); }catch(e){ return; }
  if(str===_prefsLast)return;
  _prefsLast=str;
  if(_prefsTimer)clearTimeout(_prefsTimer);
  _prefsTimer=setTimeout(function(){
    fetch('/api/prefs',{method:'PUT',headers:{'Content-Type':'application/json'},body:str})
      .then(function(r){ if(!r||!r.ok) _prefsLast=null; })
      .catch(function(){ _prefsLast=null; });
  },700);
}
// Apply each section's saved prefs exactly once, when BOTH the prefs and that section's
// data/UI are ready -- whichever lands last triggers it (the section's fetch calls the
// maybe* hook, and loadPrefs's callback calls applyAllPrefs). The per-section guard keeps it
// idempotent so a later auto-refresh never clobbers a live in-session change.
function applyAllPrefs(){
  if(!prefsReady)return;
  if(palsData){ maybeApplyPalPrefs(); renderPals(); }
  if(typeof eggsData!=='undefined'&&eggsData){ maybeApplyEggPrefs(); renderEggs(); }
  if(effigyLocations){
    var beforeP=_gv('effigy-player'); maybeApplyEffigyPrefs();
    if(_gv('effigy-player')!==beforeP){ fetchEffigyPlayer(); }
    else if(effigyLeaflet){ renderEffigyMap(); }
  }
  if(paldeckData){ maybeApplyPaldeckPrefs(); renderPaldeck(); }
}
function maybeApplyPalPrefs(){
  if(prefsApplied.pals||!prefsReady)return;
  prefsApplied.pals=true;
  var pp=PREFS&&PREFS.pals; if(!pp)return;
  if(pp.crit){ try{ applyPalCrit(pp.crit); }catch(e){} }
  var s=document.getElementById('pals-sort'); if(s&&pp.sort&&_optExists(s,pp.sort))s.value=pp.sort;
  var l=document.getElementById('pals-location'); if(l&&pp.loc&&_optExists(l,pp.loc))l.value=pp.loc;
  var pl=document.getElementById('pals-player'); if(pl&&pp.player&&_optExists(pl,pp.player))pl.value=pp.player;
  if(typeof updateFilterCount==='function')updateFilterCount();
}
function maybeApplyEggPrefs(){
  if(prefsApplied.eggs||!prefsReady)return;
  prefsApplied.eggs=true;
  var ep=PREFS&&PREFS.eggs; if(!ep)return;
  if(ep.crit){ try{ applyEggCrit(ep.crit); }catch(e){} }
  var o=document.getElementById('eggs-owner'); if(o&&ep.owner&&_optExists(o,ep.owner))o.value=ep.owner;
  var l=document.getElementById('eggs-location'); if(l&&ep.loc&&_optExists(l,ep.loc))l.value=ep.loc;
  var s=document.getElementById('eggs-sort'); if(s&&ep.sort&&_optExists(s,ep.sort))s.value=ep.sort;
  if(typeof updateEggFilterCount==='function')updateEggFilterCount();
}
function maybeApplyEffigyPrefs(){
  if(prefsApplied.effigy||!prefsReady)return;
  prefsApplied.effigy=true;
  var e=PREFS&&PREFS.effigy;
  if(e){ effigyShowFound=e.found!==false; effigyShowNew=e.nw!==false; effigyShowJournal=e.journal!==false; effigyShowBounty=e.bounty!==false; effigyShowFugitive=e.fugitive!==false; effigyShowEagle=e.eagle!==false; effigyShowNpc=e.npc!==false; effigyShowLandmark=e.landmark!==false; effigyShowPlayers=e.players!==false; setEffigyFilterBtns(); }
  if(PREFS&&PREFS.bountyManual&&typeof PREFS.bountyManual==='object') bountyManual=PREFS.bountyManual;
  var pe=PREFS&&PREFS.players&&PREFS.players.effigy;
  var sel=document.getElementById('effigy-player');
  if(sel&&pe&&_optExists(sel,pe))sel.value=pe;
}
function maybeApplyPaldeckPrefs(){
  if(prefsApplied.paldeck||!prefsReady)return;
  prefsApplied.paldeck=true;
  var pe=PREFS&&PREFS.players&&PREFS.players.paldeck;
  var sel=document.getElementById('paldeck-player');
  if(sel&&pe&&_optExists(sel,pe))sel.value=pe;
}

function initEffigyView(){
  if(effigyInited){
    populateEffigyPlayerDropdown();
    return;
  }
  effigyInited=true;
  loadLeaflet(function(){
    requestAnimationFrame(function(){
      if(!effigyLeaflet){
        var blockSize=131072;
        if(!window._palMapCfg) window._palMapCfg={blockSize:blockSize,realMin:{X:-999940,Y:-737262},realMax:{X:447900,Y:710578}};
        effigyLeaflet=L.map('effigy-leaflet-map',{minZoom:0,maxZoom:8,zoom:1,crs:L.CRS.Simple});
        var sw=effigyLeaflet.unproject([0,blockSize],8);
        var ne=effigyLeaflet.unproject([blockSize,0],8);
        var bounds=L.latLngBounds(sw,ne);
        effigyLeaflet.setMaxBounds(bounds).setView(effigyLeaflet.unproject([blockSize/2,blockSize/2],8),1);
        L.tileLayer('/api/palmaptile?z={z}&x={x}&y={y}',{
          bounds:bounds,maxNativeZoom:4,tileSize:512,keepBuffer:4
        }).addTo(effigyLeaflet);
        // Plain layer group, no clustering -- every marker shows individually regardless of
        // how many are on screen or how tightly packed (Anthony asked to remove the
        // "nearby icons merge into a circle" behavior now that the confirmed-location set
        // is small, ~74 total across all categories, not the 700+ the old clustering was
        // sized for).
        effigyMarkerLayer=L.layerGroup();
        effigyLeaflet.addLayer(effigyMarkerLayer);
      } else {
        effigyLeaflet.invalidateSize();
      }
      fetchEffigyLocations();
      fetchJournalLocations();
      fetchBossLocations();
      fetchWantedFugitives();
      fetchEagleStatues();
      fetchNPCs();
      fetchLandmarks();
      fetchPlayerLocations();
    });
  });
}

function effigyRposToLatLng(x,y){
  var cfg=window._palMapCfg;
  var sx=(x-cfg.realMin.X)/(cfg.realMax.X-cfg.realMin.X);
  var sy=(y-cfg.realMin.Y)/(cfg.realMax.Y-cfg.realMin.Y);
  return effigyLeaflet.unproject([sy*cfg.blockSize,(1-sx)*cfg.blockSize],8);
}

async function fetchEffigyLocations(){
  if(effigyLocations){populateEffigyPlayerDropdown();return;}
  document.getElementById('effigy-summary').textContent='Loading locations...';
  try{
    effigyLocations=await api('/api/effigies');
    populateEffigyPlayerDropdown();
  }catch(e){
    document.getElementById('effigy-summary').textContent='Error loading effigy data: '+e.message;
  }
}

// Static, game-world-fixed journal/diary note locations. Loaded once and left in place for
// the session; failures are silent (no journal dots) rather than blocking the effigy map.
async function fetchJournalLocations(){
  if(journalLocations)return;
  try{
    journalLocations=await api('/api/journals');
    if(effigyLeaflet) renderEffigyMap();
  }catch(e){
    journalLocations=[];
  }
}

// Static, game-world-fixed bounty-boss (named legendary Alpha) locations. Same loading
// convention as journals above: loaded once, failures are silent (no boss markers) rather
// than blocking the rest of the effigy map.
async function fetchBossLocations(){
  if(bossLocations)return;
  try{
    bossLocations=await api('/api/bounty-bosses');
    if(effigyLeaflet) renderEffigyMap();
  }catch(e){
    bossLocations=[];
  }
}

// "Wanted Fugitive" (NPC/Syndicate boss locations) and "Landmarks" (fast-travel points,
// discovered areas, everything else) -- both static, game-world-fixed, sourced entirely
// from Anthony's own confirmed_locations.json (see Get-ConfirmedWantedFugitives/
// Get-ConfirmedLandmarks). Same loading convention as journals/bounty bosses: loaded
// once, failures are silent rather than blocking the rest of the effigy map.
var wantedFugitiveLocations=null;
async function fetchWantedFugitives(){
  if(wantedFugitiveLocations)return;
  try{
    wantedFugitiveLocations=await api('/api/wanted-fugitives');
    if(effigyLeaflet) renderEffigyMap();
  }catch(e){
    wantedFugitiveLocations=[];
  }
}
var landmarkLocations=null;
async function fetchLandmarks(){
  if(landmarkLocations)return;
  try{
    landmarkLocations=await api('/api/landmarks');
    if(effigyLeaflet) renderEffigyMap();
  }catch(e){
    landmarkLocations=[];
  }
}

// Live player positions -- UNLIKE the static overlays above, this is re-fetched on a timer
// (see refreshAll) whenever the Map tab is on screen, so markers track players as they move.
// A failed fetch leaves the previous positions on screen rather than clearing them (a
// transient save-read error shouldn't make everyone vanish from the map).
var playerLocations=null;
async function fetchPlayerLocations(){
  try{
    var data=await api('/api/player-locations');
    // The route's own name resolution (playtime steamid map + live REST players) only
    // covers online/recently-tracked players; overlay the already-loaded paldeck roster's
    // names (from Level.sav NickName, always available) so offline players show their real
    // name instead of falling back to a raw guid prefix.
    var nameByGuid={};
    if(paldeckData&&paldeckData.players) paldeckData.players.forEach(function(p){nameByGuid[p.guid]=p.name;});
    playerLocations=(data.players||[]).map(function(pl){
      if(nameByGuid[pl.guid]) pl.name=nameByGuid[pl.guid];
      return pl;
    });
    if(effigyLeaflet) renderEffigyMap();
  }catch(e){
    if(!playerLocations) playerLocations=[];
  }
}
// "Eagle Statues" (fast-travel points) -- static, same loading convention as above.
var eagleStatueLocations=null;
async function fetchEagleStatues(){
  if(eagleStatueLocations)return;
  try{
    eagleStatueLocations=await api('/api/eagle-statues');
    if(effigyLeaflet) renderEffigyMap();
  }catch(e){
    eagleStatueLocations=[];
  }
}
// NPC locations -- static list, but DOES get per-player found/unfound state (see
// fetchNPCPlayer below), unlike Eagle Statues/Landmarks/Wanted Fugitive.
var npcLocations=null;
async function fetchNPCs(){
  if(npcLocations)return;
  try{
    npcLocations=await api('/api/npcs');
    if(effigyLeaflet) renderEffigyMap();
  }catch(e){
    npcLocations=[];
  }
}

function populateEffigyPlayerDropdown(){
  var sel=document.getElementById('effigy-player');
  var prev=sel.value;
  sel.innerHTML='';
  if(!paldeckData){
    // The player roster lives in paldeckData, which may not have loaded yet on a fresh
    // reload that opens the Effigies tab before fetchPaldeck() resolved. Pull it and
    // re-populate when it arrives instead of dead-ending on "no players" until the user
    // toggles tabs. Guarded so concurrent calls don't fire a burst of fetches; on the retry
    // we only re-populate if the roster actually arrived, so a failed/empty load can't loop.
    sel.innerHTML='<option value="">-- loading --</option>';
    document.getElementById('effigy-summary').textContent='Loading players...';
    if(!_effigyAwaitingRoster && typeof fetchPaldeck==='function'){
      _effigyAwaitingRoster=true;
      Promise.resolve(fetchPaldeck()).then(function(){
        _effigyAwaitingRoster=false;
        if(paldeckData){ populateEffigyPlayerDropdown(); }
        else { sel.innerHTML='<option value="">-- no players --</option>'; document.getElementById('effigy-summary').textContent='No player data'; }
      }).catch(function(){ _effigyAwaitingRoster=false; });
    }
    return;
  }
  if(!paldeckData.players||!paldeckData.players.length){
    sel.innerHTML='<option value="">-- no players --</option>';
    document.getElementById('effigy-summary').textContent='No player data';
    return;
  }
  // On the FIRST-ever populate this session (no live selection to preserve yet), wait for
  // saved prefs to arrive before picking a fallback default player. Without this, a fresh
  // page load that reaches here before /api/prefs resolves would default to players[0] and
  // immediately fetch/render THAT player's data -- looking like the map "swapped back" to
  // the wrong player -- only self-correcting once prefs load a moment later (or never
  // visibly correcting if that request is slow/fails). Capped retries so a genuinely failed
  // prefs fetch (which still flips prefsReady=true in its own catch handler) can't hang this.
  if(!prev&&typeof PREFS_ENABLED!=='undefined'&&PREFS_ENABLED&&!prefsReady){
    _effigyPrefsWaitTries=(_effigyPrefsWaitTries||0)+1;
    if(_effigyPrefsWaitTries<=50){
      sel.innerHTML='<option value="">-- loading --</option>';
      document.getElementById('effigy-summary').textContent='Loading...';
      setTimeout(populateEffigyPlayerDropdown,100);
      return;
    }
  }
  _effigyPrefsWaitTries=0;
  paldeckData.players.forEach(function(p){
    var opt=document.createElement('option');
    opt.value=p.guid; opt.textContent=p.name;
    sel.appendChild(opt);
  });
  if(prev&&paldeckData.players.some(function(p){return p.guid===prev;})){
    sel.value=prev;
  }else{if(paldeckData.players.length)sel.value=paldeckData.players[0].guid;}
  maybeApplyEffigyPrefs();
  fetchEffigyPlayer();
}

async function fetchEffigyPlayer(){
  var sel=document.getElementById('effigy-player');
  var guid=sel?sel.value:'';
  if(!guid){effigyCollected=[];renderEffigyMap();fetchJournalPlayer(guid);fetchBossPlayer(guid);fetchNPCPlayer(guid);return;}
  document.getElementById('effigy-summary').textContent='Loading...';
  try{
    var data=await api('/api/player-effigies?guid='+encodeURIComponent(guid));
    effigyCollected=data.collected||[];
  }catch(e){
    effigyCollected=[];
    toast('Could not load effigy data for player: '+e.message,'error');
  }
  renderEffigyMap();
  fetchJournalPlayer(guid);
  fetchBossPlayer(guid);
  fetchNPCPlayer(guid);
}

// NPC talked-to state for the selected player (see npcCollected comment above).
async function fetchNPCPlayer(guid){
  if(!guid){npcCollected=[];npcCollectedCount=null;renderNpcSummary();if(effigyLeaflet)renderEffigyMap();return;}
  try{
    var data=await api('/api/player-npcs?guid='+encodeURIComponent(guid));
    npcCollected=data.collected||[];
    npcCollectedCount=npcCollected.length;
  }catch(e){
    npcCollected=[];
    npcCollectedCount=null;
  }
  renderNpcSummary();
  if(effigyLeaflet) renderEffigyMap();
}
function renderNpcSummary(){
  var el=document.getElementById('npc-summary');
  if(!el)return;
  var total=npcLocations?npcLocations.length:0;
  el.textContent=(npcCollectedCount===null||!total)?'':(npcCollectedCount+' / '+total+' met');
}

// Journal collection state for the selected player (see journalCollected comment above).
async function fetchJournalPlayer(guid){
  if(!guid){journalCollected=[];journalCollectedCount=null;renderJournalSummary();if(effigyLeaflet)renderEffigyMap();return;}
  try{
    var data=await api('/api/player-notes?guid='+encodeURIComponent(guid));
    journalCollected=data.collected||[];
    journalCollectedCount=journalCollected.length;
  }catch(e){
    journalCollected=[];
    journalCollectedCount=null;
  }
  renderJournalSummary();
  if(effigyLeaflet) renderEffigyMap();
}
function renderJournalSummary(){
  var el=document.getElementById('journal-summary');
  if(!el)return;
  el.textContent=(journalCollectedCount===null)?'':(journalCollectedCount+' / '+JOURNAL_MAX+' found');
}

// Bounty-boss defeat state for the selected player (see bossCollected comment above).
async function fetchBossPlayer(guid){
  if(!guid){bossCollected=[];renderBountySummary();if(effigyLeaflet)renderEffigyMap();return;}
  try{
    var data=await api('/api/player-bounties?guid='+encodeURIComponent(guid));
    bossCollected=data.collected||[];
  }catch(e){
    bossCollected=[];
  }
  renderBountySummary();
  if(effigyLeaflet) renderEffigyMap();
}
function renderBountySummary(){
  var el=document.getElementById('bounty-summary');
  if(!el)return;
  var total=bossLocations?bossLocations.length:0;
  el.textContent=total?(bossCollected.length+' / '+total+' defeated'):'';
}

// ── Data Mine tab ────────────────────────────────────────────────────────────
// Everything extracted from NormalBossDefeatFlag, side by side: named Alpha bounty bosses
// (bounty_bosses.json, known location), Syndicate/NPC "boss" fights (syndicate_bosses.json,
// flat keys, no location), and anonymous zone-numbered field-alpha spawns (no roster at all --
// auto-discovered per player). See extract_datamine_data in pal_save_reader.py. Journal/diary
// notes (NoteObtainForInstanceFlag, /api/journals + /api/player-notes) are folded in
// alongside these -- same "raw key, no roster" shape as the anonymous section, cross-
// referenced against journal_locations.json's confirmed pins. See palbox-journal-overlay skill.
var dmBountyRoster=null;    // [{species,name,x,y,z}, ...] from bounty_bosses.json
var dmSyndicateRoster=null; // [{key,label}, ...] from syndicate_bosses.json
var dmJournalRoster=null;   // [{name,x,y,gx,gy,key?}, ...] from journal_locations.json
var dmPlayers=null;         // [{guid,name,bounty:[...species],syndicate:[...keys],anonymous:[...keys],journal:[...keys],predatorDefeatCount,...}, ...]

function toggleDmSection(id){
  var el=document.getElementById(id);
  if(el) el.classList.toggle('collapsed');
}

async function fetchDataMine(){
  ['dm-bounty-area','dm-syndicate-area','dm-anon-area','dm-journal-area','dm-journal-unmapped-area'].forEach(function(id){
    document.getElementById(id).innerHTML='<div class="empty-state">Loading...</div>';
  });
  try{
    if(!paldeckData) await fetchPaldeck();
    var roster=(paldeckData&&paldeckData.players)?paldeckData.players:[];
    var bountyPromise=dmBountyRoster?Promise.resolve(dmBountyRoster):api('/api/bounty-bosses');
    var syndicatePromise=dmSyndicateRoster?Promise.resolve(dmSyndicateRoster):api('/api/syndicate-bosses');
    var journalPromise=dmJournalRoster?Promise.resolve(dmJournalRoster):(journalLocations?Promise.resolve(journalLocations):api('/api/journals'));
    var results=await Promise.all([bountyPromise,syndicatePromise,journalPromise].concat(roster.map(function(p){
      return Promise.all([
        api('/api/player-datamine?guid='+encodeURIComponent(p.guid)).catch(function(e){
          return {guid:p.guid,bounty:[],syndicate:[],anonymous:[],error:String(e&&e.message||e)};
        }),
        api('/api/player-notes?guid='+encodeURIComponent(p.guid)).catch(function(e){
          return {guid:p.guid,collected:[],error:String(e&&e.message||e)};
        })
      ]);
    })));
    dmBountyRoster=results[0]||[];
    dmSyndicateRoster=results[1]||[];
    dmJournalRoster=results[2]||[];
    dmPlayers=roster.map(function(p,i){
      var pair=results[i+3]||[{},{}];
      var d=pair[0]||{}, n=pair[1]||{};
      return {
        guid:p.guid, name:p.name,
        bounty:d.bounty||[], syndicate:d.syndicate||[], anonymous:d.anonymous||[],
        journal:n.collected||[],
        predatorDefeatCount:d.predatorDefeatCount||0,
        fixedDungeonClearCount:d.fixedDungeonClearCount||0,
        normalDungeonClearCount:d.normalDungeonClearCount||0
      };
    });
    renderDataMine();
  }catch(e){
    var msg='<div class="empty-state">Failed to load: '+esc(String(e&&e.message||e))+'</div>';
    document.getElementById('dm-bounty-area').innerHTML=msg;
    document.getElementById('dm-syndicate-area').innerHTML='';
    document.getElementById('dm-anon-area').innerHTML='';
    document.getElementById('dm-journal-area').innerHTML='';
    document.getElementById('dm-journal-unmapped-area').innerHTML='';
  }
}

// Builds a rows x players checkmark table. rowLabelHtml(row) renders the left-hand cell;
// hasFn(player,row) decides if that player's cell is checked. extraCols (optional) inserts
// extra [{header,cell(row)}] columns between the label and the player columns. rowHeader/
// doneLabel (optional) customize the row-label column header and the checkmark title text
// (default "Boss"/"Defeated"), so this can double as the journal-notes table.
function dmBuildTable(rows,players,rowLabelHtml,hasFn,extraCols,rowHeader,doneLabel){
  extraCols=extraCols||[];
  doneLabel=doneLabel||'Defeated';
  var html='<table class="syn-table"><thead><tr><th>'+esc(rowHeader||'Boss')+'</th>'
    +extraCols.map(function(c){return '<th>'+esc(c.header)+'</th>';}).join('')
    +players.map(function(p){return '<th style="text-align:center;">'+esc(p.name)+'</th>';}).join('')
    +'</tr></thead><tbody>';
  rows.forEach(function(r){
    html+='<tr><td>'+rowLabelHtml(r)+'</td>';
    extraCols.forEach(function(c){ html+='<td>'+c.cell(r)+'</td>'; });
    players.forEach(function(p){
      var done=hasFn(p,r);
      html+='<td class="syn-check" title="'+(done?doneLabel:'Not '+doneLabel.toLowerCase())+'">'+(done?'<span style="color:#3fb950;">&#10003;</span>':'<span style="color:var(--muted);">&#8212;</span>')+'</td>';
    });
    html+='</tr>';
  });
  return html+'</tbody></table>';
}

function renderDataMine(){
  var statsEl=document.getElementById('dm-stats');
  var sumEl=document.getElementById('dm-summary');
  var bountyArea=document.getElementById('dm-bounty-area');
  var syndicateArea=document.getElementById('dm-syndicate-area');
  var anonArea=document.getElementById('dm-anon-area');
  var journalArea=document.getElementById('dm-journal-area');
  var journalUnmappedArea=document.getElementById('dm-journal-unmapped-area');
  if(!dmBountyRoster||!dmSyndicateRoster||!dmJournalRoster||!dmPlayers){ return; }
  if(!dmPlayers.length){
    [bountyArea,syndicateArea,anonArea,journalArea,journalUnmappedArea].forEach(function(a){a.innerHTML='<div class="empty-state">No player data</div>';});
    statsEl.innerHTML=''; sumEl.textContent='';
    return;
  }

  statsEl.innerHTML=dmPlayers.map(function(p){
    return '<div class="syn-stat-card"><div class="syn-stat-name">'+esc(p.name)+'</div>'
      +'<div class="syn-stat-row"><span>Predators defeated</span><b>'+p.predatorDefeatCount+'</b></div>'
      +'<div class="syn-stat-row"><span>Fixed dungeons cleared</span><b>'+p.fixedDungeonClearCount+'</b></div>'
      +'<div class="syn-stat-row"><span>Normal dungeons cleared</span><b>'+p.normalDungeonClearCount+'</b></div>'
      +'</div>';
  }).join('')+'<div style="font-size:10px;color:var(--muted);width:100%;">Account-wide totals from the save -- not broken down per boss below (the save has no per-boss counter, only a defeated/not-defeated flag).</div>';

  // Bounty section: fixed roster (locations are the whole point of this one), sorted by name.
  var bountyRows=dmBountyRoster.slice().sort(function(a,b){return a.name<b.name?-1:a.name>b.name?1:0;});
  bountyArea.innerHTML=dmBuildTable(bountyRows,dmPlayers,function(r){
    var loc=Math.round(r.x)+', '+Math.round(r.y)+', '+Math.round(r.z);
    return esc(r.name)+'<div class="syn-key">'+esc(r.species)+' &bull; '+loc+'</div>';
  },function(p,r){return p.bounty.indexOf(r.species)!==-1;},[
    {header:'In-Game Coords',cell:function(r){
      // Same raw-world -> in-game conversion used by the effigy map tooltip
      // (cx=(y-158000)/459, cy=(x+123888)/459) so this matches what the player sees on
      // their in-game map, not the raw save/world units in the Species/Location line above.
      var cx=Math.round((r.y-158000)/459), cy=Math.round((r.x+123888)/459);
      return '<span class="syn-key">X: '+cx+', Y: '+cy+'</span>';
    }}
  ]);

  // Syndicate section: static roster unioned with any newly-observed key (mirrors the
  // owner-select union pattern used for eggs), so an unseen boss key still shows up.
  var synRows=dmSyndicateRoster.slice();
  var synKnown={}; synRows.forEach(function(r){synKnown[r.key]=1;});
  dmPlayers.forEach(function(p){
    p.syndicate.forEach(function(k){ if(!synKnown[k]){ synKnown[k]=1; synRows.push({key:k,label:null}); } });
  });
  synRows.sort(function(a,b){return a.key<b.key?-1:a.key>b.key?1:0;});
  syndicateArea.innerHTML=dmBuildTable(synRows,dmPlayers,function(r){
    return esc(r.label||r.key)+(r.label?'<div class="syn-key">'+esc(r.key)+'</div>':'');
  },function(p,r){return p.syndicate.indexOf(r.key)!==-1;});

  // Anonymous section: no roster at all, purely auto-discovered from whatever's in the saves.
  var anonKeys={};
  dmPlayers.forEach(function(p){ p.anonymous.forEach(function(k){ anonKeys[k]=1; }); });
  var anonRows=Object.keys(anonKeys).sort().map(function(k){return {key:k};});
  anonArea.innerHTML=anonRows.length
    ? dmBuildTable(anonRows,dmPlayers,function(r){return '<span class="syn-key">'+esc(r.key)+'</span>';},function(p,r){return p.anonymous.indexOf(r.key)!==-1;})
    : '<div class="empty-state">None found</div>';

  // Journal section 1: confirmed map pins (journal_locations.json entries carrying a "key"),
  // same case-insensitive match convention as the Effigy map (renderEffigyMap's
  // journalCollectedSet). Sorted by name.
  var journalHas=function(p,key){
    return p.journal.map(function(k){return k.toUpperCase();}).indexOf(key.toUpperCase())!==-1;
  };
  var journalRows=dmJournalRoster.filter(function(r){return !!r.key;})
    .sort(function(a,b){return a.name<b.name?-1:a.name>b.name?1:0;});
  journalArea.innerHTML=journalRows.length
    ? dmBuildTable(journalRows,dmPlayers,function(r){
        return esc(r.name)+'<div class="syn-key">'+esc(r.key)+' &bull; X: '+r.gx+', Y: '+r.gy+'</div>';
      },function(p,r){return journalHas(p,r.key);},null,'Journal Entry','Found')
    : '<div class="empty-state">No confirmed pins yet</div>';

  // Journal section 2: every raw NoteObtainForInstanceFlag key observed in ANY player's save,
  // confirmed or not -- lets the key<->name mapping above be audited against the full raw list
  // instead of trusting it silently. Mapped rows show which pin they're tied to; unmapped rows
  // are either an unconfirmed diary pin (needs a live-save diff to identify which) or a
  // dungeon-boss lore note (no map pin at all, ever) -- not auto-classified between the two.
  var confirmedKeyNames={}; journalRows.forEach(function(r){confirmedKeyNames[r.key.toUpperCase()]=r.name;});
  var allRawKeys={};
  dmPlayers.forEach(function(p){ p.journal.forEach(function(k){ allRawKeys[k]=1; }); });
  var journalRawRows=Object.keys(allRawKeys).sort().map(function(k){return {key:k};});
  journalUnmappedArea.innerHTML=journalRawRows.length
    ? dmBuildTable(journalRawRows,dmPlayers,function(r){return '<span class="syn-key">'+esc(r.key)+'</span>';},function(p,r){return journalHas(p,r.key);},[
        {header:'Mapped Pin',cell:function(r){
          var name=confirmedKeyNames[r.key.toUpperCase()];
          return name?esc(name):'<span style="color:var(--muted);">unmapped</span>';
        }}
      ],'Raw Key','Found')
    : '<div class="empty-state">None found</div>';

  var bountyDone=bountyRows.filter(function(r){return dmPlayers.some(function(p){return p.bounty.indexOf(r.species)!==-1;});}).length;
  var synDone=synRows.filter(function(r){return dmPlayers.some(function(p){return p.syndicate.indexOf(r.key)!==-1;});}).length;
  var journalDone=journalRows.filter(function(r){return dmPlayers.some(function(p){return journalHas(p,r.key);});}).length;
  var journalUnmappedCount=journalRawRows.filter(function(r){return !confirmedKeyNames[r.key.toUpperCase()];}).length;
  sumEl.textContent=bountyDone+'/'+bountyRows.length+' bounty | '+synDone+'/'+synRows.length+' syndicate | '+anonRows.length+' anonymous keys | '
    +journalDone+'/'+journalRows.length+' journal pins | '+journalRawRows.length+' raw journal keys ('+journalUnmappedCount+' unmapped)';
}

function renderEffigyMap(){
  if(!effigyLeaflet||!effigyLocations||!effigyMarkerLayer) return;
  effigyMarkerLayer.clearLayers();

  var collectedSet=new Set(effigyCollected.map(function(s){return s.toUpperCase();}));
  var ids=Object.keys(effigyLocations);
  var total=ids.length;
  var collectedCount=0;

  ids.forEach(function(id){
    var pos=effigyLocations[id];
    var got=collectedSet.has(id.toUpperCase());
    if(got) collectedCount++;
    // Global view filter: hide whichever category (found / new) the player has toggled off.
    // Runs after the count so the summary stays accurate regardless of what is shown.
    if((got&&!effigyShowFound)||(!got&&!effigyShowNew)) return;
    var cx=Math.round((pos.y-158000)/459), cy=Math.round((pos.x+123888)/459);
    var tip=(got?'<span style="color:#5a6573">&#10003; Found</span>':'<b style="color:#2f9e43">New</b>')
      +'<br><span style="color:#111;font-weight:600">X: '+cx+', Y: '+cy+'</span>';
    // Acorn glyph for both states: green = uncollected, grey/faded = already found.
    var m=L.marker(effigyRposToLatLng(pos.x,pos.y),{icon:effigyAcornIcon(got),interactive:true});
    m.on('mouseover',function(){var el=this.getElement();if(el)el.classList.add('eff-map-hover');this.setZIndexOffset(1000);});
    m.on('mouseout',function(){var el=this.getElement();if(el)el.classList.remove('eff-map-hover');});
    m.bindTooltip(tip,{direction:'top',offset:[0,-6],className:'eff-tip',opacity:0.97});
    effigyMarkerLayer.addLayer(m);
  });

  // Journal / diary note locations -- static, game-world-fixed. Entries that carry a "key"
  // (matched against the save's NoteObtainForInstanceFlag names) get real found/new coloring,
  // same convention as effigies (grey=found, blue=new); entries without a known key always
  // render blue since their found state can't be determined yet. Book glyph (Flaticon, see
  // footer credit), same acorn-marker divIcon plumbing as effigies.
  if(effigyShowJournal&&journalLocations&&journalLocations.length){
    var journalCollectedSet=new Set(journalCollected.map(function(s){return s.toUpperCase();}));
    journalLocations.forEach(function(j){
      var trackable=!!j.key;
      var jGot=trackable&&journalCollectedSet.has(j.key.toUpperCase());
      // The "found" toggle also hides already-found diary pickups, same as effigies.
      if(jGot&&!effigyShowFound) return;
      var jm=L.marker(effigyRposToLatLng(j.x,j.y),{icon:journalBookIcon(jGot),interactive:true});
      var jStatus=trackable?(jGot?'<span style="color:#5a6573">&#10003; Found</span>':'<b style="color:#1673d1">Not yet found</b>'):'<span style="color:#8a8f98">Found status unknown</span>';
      jm.bindTooltip('<b style="color:#1673d1">'+j.name+'</b><br>'+jStatus
        +'<br><span style="color:#111;font-weight:600">X: '+j.gx+', Y: '+j.gy+'</span>',
        {direction:'top',offset:[0,-6],className:'eff-tip',opacity:0.97});
      jm.on('mouseover',function(){var el=this.getElement();if(el)el.classList.add('eff-map-hover');this.setZIndexOffset(1000);});
      jm.on('mouseout',function(){var el=this.getElement();if(el)el.classList.remove('eff-map-hover');});
      effigyMarkerLayer.addLayer(jm);
    });
  }

  // Bounty-boss (named legendary Alpha) locations -- game-world fixed, one entry per known
  // boss species (bounty_bosses.json). Auto-"got" comes from NormalBossDefeatFlag via
  // extract_bounty_data (see pal_save_reader.py), but the save only names a spawner
  // instance descriptively for a couple of bosses -- most defeats are unrecoverable from
  // the save alone (anonymous zone-numbered keys). So a manual click-to-mark fallback
  // (bountyManual, PREFS-backed) covers the rest: click any boss the save hasn't already
  // confirmed to toggle your own "I defeated this" mark. The boss's own portrait shows in
  // color when neither signal has it, grayed out once either does. Unlike effigies/journals
  // there's no "New" state to hide -- effigyShowFound also governs whether defeated bosses
  // stay visible (grayed) or disappear, same convention as the found toggle elsewhere.
  if(effigyShowBounty&&bossLocations&&bossLocations.length){
    var bossCollectedSet=new Set(bossCollected.map(function(s){return s.toUpperCase();}));
    var bpSel=document.getElementById('effigy-player');
    var bpGuid=bpSel?bpSel.value:'';
    var manualSet=bountyManualSetFor(bpGuid);
    bossLocations.forEach(function(b){
      var sp=(b.species||'').toUpperCase();
      var bAuto=bossCollectedSet.has(sp);
      var bManual=manualSet.has(sp);
      var bGot=bAuto||bManual;
      if(bGot&&!effigyShowFound) return;
      var clickable=PREFS_ENABLED&&!bAuto&&!!bpGuid;
      var bm=L.marker(effigyRposToLatLng(b.x,b.y),{icon:bountyBossIcon(b.name,bGot),interactive:true});
      var bStatus=bAuto?'<span style="color:#5a6573">&#10003; Defeated (confirmed)</span>'
        :bManual?'<span style="color:#5a6573">&#10003; Marked defeated by you</span>'
        :'<b style="color:#e3b341">Alpha Boss</b>';
      if(clickable) bStatus+='<br><span style="color:#8a8f98;font-size:11px;">Click to '+(bManual?'unmark':'mark defeated')+'</span>';
      bm.bindTooltip('<b style="color:#111;">'+b.name+'</b><br>'+bStatus,
        {direction:'top',offset:[0,-6],className:'eff-tip',opacity:0.97});
      bm.on('mouseover',function(){var el=this.getElement();if(el)el.classList.add('eff-map-hover');this.setZIndexOffset(1000);});
      bm.on('mouseout',function(){var el=this.getElement();if(el)el.classList.remove('eff-map-hover');});
      if(clickable){
        bm.on('click',function(){toggleBountyManual(b.species);});
        bm.on('add',function(){var el=this.getElement();if(el)el.style.cursor='pointer';});
      }
      effigyMarkerLayer.addLayer(bm);
    });
  }

  // Wanted Fugitive (human/Syndicate bosses), Eagle Statue (fast-travel points), and
  // Landmarks (discovered areas, everything else) -- all static named pins with no
  // found/unfound state (see fetchWantedFugitives/fetchEagleStatues/fetchLandmarks above
  // for why). {key,name,x,y} shape.
  if(effigyShowFugitive&&wantedFugitiveLocations&&wantedFugitiveLocations.length){
    wantedFugitiveLocations.forEach(function(h){
      var hm=L.marker(effigyRposToLatLng(h.x,h.y),{icon:wantedFugitiveIcon(),interactive:true});
      var cx=Math.round((h.y-158000)/459), cy=Math.round((h.x+123888)/459);
      hm.bindTooltip('<b style="color:#f85149">'+h.name+'</b>'
        +'<br><span style="color:#111;font-weight:600">X: '+cx+', Y: '+cy+'</span>',
        {direction:'top',offset:[0,-6],className:'eff-tip',opacity:0.97});
      hm.on('mouseover',function(){var el=this.getElement();if(el)el.classList.add('eff-map-hover');this.setZIndexOffset(1000);});
      hm.on('mouseout',function(){var el=this.getElement();if(el)el.classList.remove('eff-map-hover');});
      effigyMarkerLayer.addLayer(hm);
    });
  }
  if(effigyShowEagle&&eagleStatueLocations&&eagleStatueLocations.length){
    eagleStatueLocations.forEach(function(es){
      var esm=L.marker(effigyRposToLatLng(es.x,es.y),{icon:eagleStatueIcon(),interactive:true});
      var cx=Math.round((es.y-158000)/459), cy=Math.round((es.x+123888)/459);
      esm.bindTooltip('<b style="color:#e8b339">'+es.name+'</b>'
        +'<br><span style="color:#111;font-weight:600">X: '+cx+', Y: '+cy+'</span>',
        {direction:'top',offset:[0,-6],className:'eff-tip',opacity:0.97});
      esm.on('mouseover',function(){var el=this.getElement();if(el)el.classList.add('eff-map-hover');this.setZIndexOffset(1000);});
      esm.on('mouseout',function(){var el=this.getElement();if(el)el.classList.remove('eff-map-hover');});
      effigyMarkerLayer.addLayer(esm);
    });
  }
  // NPC -- static list, but DOES track per-player found/unfound (talked to at least once
  // via NPCTalkCountMap), same convention as effigies/journals (grey=met, teal=not met yet).
  if(effigyShowNpc&&npcLocations&&npcLocations.length){
    var npcCollectedSet=new Set(npcCollected.map(function(s){return s.toUpperCase();}));
    npcLocations.forEach(function(n){
      var nGot=n.key&&npcCollectedSet.has(n.key.toUpperCase());
      if(nGot&&!effigyShowFound) return;
      var nm=L.marker(effigyRposToLatLng(n.x,n.y),{icon:npcIcon(nGot),interactive:true});
      var cx=Math.round((n.y-158000)/459), cy=Math.round((n.x+123888)/459);
      var nStatus=nGot?'<span style="color:#5a6573">&#10003; Met</span>':'<b style="color:#39c5bb">Not yet met</b>';
      nm.bindTooltip('<b style="color:#111;">'+n.name+'</b><br>'+nStatus
        +'<br><span style="color:#111;font-weight:600">X: '+cx+', Y: '+cy+'</span>',
        {direction:'top',offset:[0,-6],className:'eff-tip',opacity:0.97});
      nm.on('mouseover',function(){var el=this.getElement();if(el)el.classList.add('eff-map-hover');this.setZIndexOffset(1000);});
      nm.on('mouseout',function(){var el=this.getElement();if(el)el.classList.remove('eff-map-hover');});
      effigyMarkerLayer.addLayer(nm);
    });
  }
  if(effigyShowLandmark&&landmarkLocations&&landmarkLocations.length){
    landmarkLocations.forEach(function(lm){
      var lmk=L.marker(effigyRposToLatLng(lm.x,lm.y),{icon:landmarkIcon(),interactive:true});
      var cx=Math.round((lm.y-158000)/459), cy=Math.round((lm.x+123888)/459);
      lmk.bindTooltip('<b style="color:#a371f7">'+lm.name+'</b>'
        +'<br><span style="color:#111;font-weight:600">X: '+cx+', Y: '+cy+'</span>',
        {direction:'top',offset:[0,-6],className:'eff-tip',opacity:0.97});
      lmk.on('mouseover',function(){var el=this.getElement();if(el)el.classList.add('eff-map-hover');this.setZIndexOffset(1000);});
      lmk.on('mouseout',function(){var el=this.getElement();if(el)el.classList.remove('eff-map-hover');});
      effigyMarkerLayer.addLayer(lmk);
    });
  }

  // Live player positions, from each player's own save (Translation/Rotation), not the
  // static confirmed-location data above -- see fetchPlayerLocations. A player whose save
  // couldn't be read (x/y null -- e.g. mid-write) is skipped rather than plotted at (0,0).
  if(effigyShowPlayers&&playerLocations&&playerLocations.length){
    playerLocations.forEach(function(pl){
      if(typeof pl.x!=='number'||typeof pl.y!=='number') return;
      var pm=L.marker(effigyRposToLatLng(pl.x,pl.y),{icon:playerMarkerIcon(pl.yawDeg),interactive:true,zIndexOffset:900});
      var cx=Math.round((pl.y-158000)/459), cy=Math.round((pl.x+123888)/459);
      pm.bindTooltip('<b style="color:#58a6ff">'+esc(pl.name)+'</b>'
        +'<br><span style="color:#111;font-weight:600">X: '+cx+', Y: '+cy+'</span>',
        {direction:'top',offset:[0,-6],className:'eff-tip',opacity:0.97});
      pm.on('mouseover',function(){var el=this.getElement();if(el)el.classList.add('eff-map-hover');this.setZIndexOffset(1500);});
      pm.on('mouseout',function(){var el=this.getElement();if(el)el.classList.remove('eff-map-hover');});
      effigyMarkerLayer.addLayer(pm);
    });
  }

  var needed=Math.max(0,EFFIGY_MAX_RANK-collectedCount);
  var pct=total>0?Math.round(collectedCount/total*100):0;
  document.getElementById('effigy-summary').textContent=
    collectedCount+' / '+total+' ('+pct+'%)'
    +(needed>0?' \u2022 '+needed+' more for max rank':' \u2022 Max rank!');
  savePrefs();
}

async function reloadEffigyView(){
  effigyLocations=null;
  effigyCollected=[];
  document.getElementById('effigy-summary').textContent='Reloading...';
  await fetchEffigyLocations();
}

// ── Data fetchers ─────────────────────────────────────────────────────────────
async function refreshAll(){
  resetCountdown();
  await Promise.allSettled([fetchInfo(),fetchMetrics(),fetchPlayers(),fetchHistory(),fetchPlaytime(),fetchMaintenanceInfo(),fetchMaintLog(),fetchSaves(),fetchPaldeck()]);
  if(!sLoaded) fetchFileSettings();
  loadEggNotify();
  setText('last-updated',new Date().toLocaleTimeString());
  // Also refresh whichever data tab is on screen, silently (no loading flash), so its
  // content updates on the timer without a manual reload. Paldeck already refetched above.
  var at=(document.querySelector('.nav-tab.active')||{}).dataset; at=at&&at.tab;
  if(at==='pals') fetchPals(true);
  else if(at==='eggs') fetchEggs(true);
  else if(at==='effigies') fetchPlayerLocations();
}
async function fetchInfo(){
  try{
    var d=await api('/api/info');
    document.getElementById('dot').className='status-dot online';
    document.getElementById('btn-start-hdr').style.display='none';
    setText('s-version',pick(d,'version')||'-');
  }catch(e){
    document.getElementById('dot').className='status-dot offline';
    document.getElementById('btn-start-hdr').style.display='';
    clearLiveStats();
  }
}
// Reset the live stat cards when the server is unreachable so we never show
// stale numbers from when it was last online.
function clearLiveStats(){
  setText('s-players','-'); setText('s-fps','-'); setText('s-uptime','-');
  setText('s-bases','-'); setText('s-days','-'); setText('s-version','-');
  var fpsEl=document.getElementById('s-fps'); if(fpsEl) fpsEl.className='stat-val';
  setText('s-fps-sub','frame rate'); setText('s-uptime-sub',' ');
}
async function fetchMetrics(){
  try{
    var d=await api('/api/metrics');
    var fps=pick(d,'serverfps','fps'), cur=pick(d,'currentplayernum','currentplayers');
    var max=pick(d,'maxplayernum','maxplayers'), up=pick(d,'uptime');
    var bases=pick(d,'basecampnum','basecampcount','basecamps'), days=pick(d,'days');
    var ft=pick(d,'serverframetime','frametime');
    var fpsN=Number(fps), fpsEl=document.getElementById('s-fps');
    fpsEl.textContent=isNaN(fpsN)?(fps||'-'):Math.round(fpsN);
    fpsEl.className='stat-val'+(fpsN>=55?' good':fpsN>=30?' warn':' bad');
    var ftN=ft!=null?Math.round(parseFloat(ft)*10)/10:null;
    setText('s-fps-sub',ftN!=null?ftN+'ms / frame':'frame rate');
    if(max!=null) maxPlayers=Number(max);
    setText('s-players',cur!=null?cur:'-'); updatePlayersSub();
    var upN=up!=null?Number(up):null;
    setText('s-uptime',upN!=null?fmtUptime(upN):'-');
    if(upN!=null){var st=new Date(Date.now()-upN*1000);setText('s-uptime-sub','since '+st.getHours()+':'+String(st.getMinutes()).padStart(2,'0'));}
    setText('s-bases',bases!=null?bases:'-');
    if(days!=null){setText('s-days',Number(days));}
  }catch(e){}
}
function updatePlayersSub(){
  var peak=historyData.length?Math.max.apply(null,historyData.map(function(d){return d.players||0;})):null;
  var sub='of '+(maxPlayers!=null?maxPlayers:'?')+' max';
  if(peak!=null) sub+=' | peak '+peak;
  setText('s-players-sub',sub);
}
async function fetchPlayers(){
  try{
    var d=await api('/api/players');
    players=d.players||d.Players||[];
    renderPlayers(); setText('player-badge',players.length);
  }catch(e){
    document.getElementById('player-area').innerHTML='<div class="empty-state err">Could not reach server</div>';
    setText('player-badge',0);
  }
}
async function fetchHistory(){
  try{
    var data=await api('/api/history');
    historyData=Array.isArray(data)?data:[];
    renderCharts(); updatePlayersSub();
  }catch(e){}
}
async function fetchPlaytime(){
  try{var data=await api('/api/playtime');renderPlaytime(Array.isArray(data)?data:[]);}catch(e){}
}
// Egg-ready alert opt-in toggles. Roster comes from the already-loaded paldeck players
// (full save roster, not just online); saved state from /api/egg-notify. Admin-only --
// this whole block is stripped from the public site by gen_public_site.ps1.
async function loadEggNotify(){
  var box=document.getElementById('egg-notify-list'); if(!box) return;
  var roster=(paldeckData&&paldeckData.players)?paldeckData.players:[];
  if(!roster.length){ box.innerHTML='<div class="empty-state" style="padding:6px">No players yet.</div>'; return; }
  var cfg={};
  try{ cfg=await api('/api/egg-notify'); }catch(e){ cfg={}; }
  box.innerHTML=roster.map(function(p,i){
    var pfx=(p.guid||'').slice(0,8).toUpperCase();
    var on=cfg[pfx]&&cfg[pfx].enabled;
    return '<label style="display:flex;align-items:center;gap:8px;padding:3px 0;cursor:pointer;">'
      +'<input type="checkbox" '+(on?'checked':'')+' onchange="toggleEggNotify(this,'+i+')">'
      +'<span>'+esc(p.name)+'</span></label>';
  }).join('');
}
async function toggleEggNotify(el,i){
  var roster=(paldeckData&&paldeckData.players)?paldeckData.players:[];
  var p=roster[i]; if(!p) return;
  var pfx=(p.guid||'').slice(0,8).toUpperCase();
  try{
    await api('/api/egg-notify','POST',{prefix:pfx,name:p.name,enabled:el.checked});
    toast((el.checked?'Hatch alerts on for ':'Hatch alerts off for ')+p.name,'success');
  }catch(e){ el.checked=!el.checked; toast('Could not save: '+e.message,'error'); }
}
function renderPlayers(){
  var area=document.getElementById('player-area');
  if(!players.length){area.innerHTML='<div class="empty-state">No players online</div>';return;}
  var rows=players.map(function(p,i){
    var name=pick(p,'name')||'Unknown',lvl=pick(p,'level'),ping=pick(p,'ping');
    var pingTxt=ping!=null?ping+'ms':'-',pingC=ping!=null?pingCls(Number(ping)):'';
    return '<tr><td class="player-name">'+esc(name)+'</td><td>'+esc(lvl!=null?lvl:'-')+'</td>'
      +'<td class="'+pingC+'">'+pingTxt+'</td>'
      +'<td><button class="btn btn-ghost" onclick="kickPlayer('+i+')">Kick</button>'
      +'<button class="btn btn-danger" onclick="banPlayer('+i+')" style="margin-left:4px">Ban</button></td></tr>';
  }).join('');
  area.innerHTML='<table><thead><tr><th>Name</th><th>Level</th><th>Ping</th><th>Actions</th></tr></thead><tbody>'+rows+'</tbody></table>';
}
function renderPlaytime(data){
  var area=document.getElementById('playtime-area');
  if(!data.length){area.innerHTML='<div class="empty-state">No data yet &mdash; stats accumulate as players connect.</div>';return;}
  data.sort(function(a,b){return(b.totalSeconds||0)-(a.totalSeconds||0);});
  var hasPsn=data.some(function(p){return p.steamid;});
  var rows=data.map(function(p){
    var ts=p.lastSeen?new Date(p.lastSeen):null,seen=ts&&!isNaN(ts.getTime())?ts.toLocaleString():'-';
    var psnCell=hasPsn?('<td style="color:var(--muted);font-size:11px">'+esc(p.steamid||'-')+'</td>'):'';
    return '<tr><td class="player-name">'+esc(p.name||'?')+'</td>'+psnCell+'<td>'+fmtPlaytime(p.totalSeconds)+'</td>'
      +'<td>'+(p.sessions||0)+'</td><td>'+(p.avgPing?Math.round(p.avgPing)+'ms':'-')+'</td>'
      +'<td style="color:var(--muted);font-size:11px">'+esc(seen)+'</td></tr>';
  }).join('');
  var psnHead=hasPsn?'<th>Player ID</th>':'';
  area.innerHTML='<table><thead><tr><th>Player</th>'+psnHead+'<th>Playtime</th><th>Sessions</th><th>Avg Ping</th><th>Last Seen</th></tr></thead><tbody>'+rows+'</tbody></table>';
}

// ── Maintenance ───────────────────────────────────────────────────────────────
async function fetchMaintenanceInfo(){
  try{
    var d=await api('/api/maintenance-info');
    var dt=new Date(d.nextMaint);
    var ds=dt.toLocaleDateString(undefined,{weekday:'short',month:'short',day:'numeric'});
    var ts=dt.toLocaleTimeString(undefined,{hour:'2-digit',minute:'2-digit'});
    setText('maint-next-time',ds+' '+ts);
    maintSkip=d.skipPending;
    var sb=document.getElementById('btn-skip');
    if(sb){sb.textContent=maintSkip?'Unskip Next':'Skip Next';sb.className='btn btn-full '+(maintSkip?'btn-green':'btn-warn');}
    // Don't clobber an input the user is currently editing (auto-refresh fires
    // every 5 min and would otherwise wipe a half-typed time).
    var hEl=document.getElementById('maint-hour'),mEl=document.getElementById('maint-min');
    if(d.maintHour!=null && document.activeElement!==hEl) hEl.value=d.maintHour;
    if(d.maintMinute!=null && document.activeElement!==mEl) mEl.value=String(d.maintMinute).padStart(2,'0');
  }catch(e){}
}
async function fetchMaintLog(){
  try{
    var lines=await api('/api/maint-log');
    // A single-line log serializes as a bare string, not an array; coerce so .slice/.map are safe.
    if(!Array.isArray(lines)) lines=(lines==null||lines==='')?[]:[lines];
    var el=document.getElementById('maint-log');
    if(el) el.innerHTML=lines.slice(-6).map(function(l){return esc(l);}).join('<br>')||'No log yet.';
  }catch(e){}
}
async function toggleSkip(){
  try{
    if(maintSkip){await api('/api/maintenance-unskip','POST');toast('Skip cancelled.','info');}
    else{await api('/api/maintenance-skip','POST');toast('Next maintenance will be skipped.','warn');}
    await fetchMaintenanceInfo();
  }catch(e){toast('Failed: '+e.message,'error');}
}
async function saveMaintTime(){
  var h=parseInt(document.getElementById('maint-hour').value);
  var m=parseInt(document.getElementById('maint-min').value);
  if(isNaN(h)||isNaN(m)||h<0||h>23||m<0||m>59){toast('Invalid time.','error');return;}
  try{await api('/api/maintenance-time','POST',{hour:h,minute:m});toast('Maintenance time set to '+String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+'.','success');await fetchMaintenanceInfo();}
  catch(e){toast('Failed: '+e.message,'error');}
}
async function startServer(){
  try{var r=await api('/api/start','POST');toast(r.status||'Server start requested.','info');}
  catch(e){toast('Failed: '+e.message,'error');}
}

// ── Server actions ────────────────────────────────────────────────────────────
async function sendMsg(){
  var msg=document.getElementById('msg').value.trim();
  if(!msg){toast('Enter a message first.','error');return;}
  try{await api('/api/announce','POST',{message:msg});toast('Message broadcast.','success');document.getElementById('msg').value='';}
  catch(e){toast('Broadcast failed: '+e.message,'error');}
}
async function saveWorld(){
  try{await api('/api/save','POST');toast('World saved.','success');}
  catch(e){toast('Save failed: '+e.message,'error');}
}
async function rebootServer(){
  var secs=parseInt(document.getElementById('reboot-secs').value)||60;
  if(!confirm('Reboot with a '+secs+'s in-game warning?')) return;
  try{await api('/api/reboot','POST',{waittime:secs});toast('Reboot initiated - '+secs+'s countdown.','warn',7000);}
  catch(e){toast('Reboot failed: '+e.message,'error');}
}
async function shutdownServer(){
  var secs=parseInt(document.getElementById('shutdown-secs').value)||60;
  if(!confirm('Shut down the server with a '+secs+'s in-game warning?\nIt will stay offline until you start it again.')) return;
  try{await api('/api/shutdown-graceful','POST',{waittime:secs});toast('Shutdown initiated - '+secs+'s countdown. Server will stay offline.','warn',8000);}
  catch(e){toast('Shutdown failed: '+e.message,'error');}
}
async function forceStop(){
  if(!confirm('Force stop immediately?\nAll unsaved progress will be lost.')) return;
  try{await api('/api/stop','POST');toast('Server force-stopped.','warn');document.getElementById('dot').className='status-dot offline';}
  catch(e){toast('Stop failed: '+e.message,'error');}
}
async function kickPlayer(i){
  var p=players[i]; if(!p)return;
  var name=pick(p,'name')||'Player',uid=pick(p,'playeruid','userid','steamid')||'';
  var reason=prompt('Kick reason for '+name+':','Kicked by admin');
  if(reason===null)return;
  try{await api('/api/kick','POST',{userid:uid,message:reason});toast(name+' kicked.','success');await fetchPlayers();}
  catch(e){toast('Kick failed: '+e.message,'error');}
}
async function banPlayer(i){
  var p=players[i]; if(!p)return;
  var name=pick(p,'name')||'Player',uid=pick(p,'playeruid','userid','steamid')||'';
  if(!confirm('Permanently ban '+name+'?'))return;
  var reason=prompt('Ban reason:','Banned by admin');
  if(reason===null)return;
  try{await api('/api/ban','POST',{userid:uid,message:reason});toast(name+' banned.','success');await fetchPlayers();}
  catch(e){toast('Ban failed: '+e.message,'error');}
}

// ── Settings editor ───────────────────────────────────────────────────────────
function sGetVal(k){return k in sDirty?sDirty[k]:(k in sActive?sActive[k]:(sDefault[k]||''));}

function renderSettingsTabs(){
  var html=CATS.filter(function(c){return Object.keys(META).some(function(k){return META[k].c===c;});})
    .map(function(c){
      var dot=Object.keys(sDirty).some(function(k){return META[k]&&META[k].c===c;});
      return '<div class="tab'+(c===sCat?' active':'')+'" onclick="switchTab(\''+c+'\')">'
        +c+(dot?'<span class="tab-dot"></span>':'')+'</div>';
    }).join('');
  document.getElementById('settings-tab-bar').innerHTML=html;
}

function renderSettingsGrid(){
  var keys=Object.keys(META).filter(function(k){return META[k].c===sCat;});
  if(!keys.length){document.getElementById('settings-grid').innerHTML='<div class="empty-state">No settings here.</div>';return;}
  var html=keys.map(function(k){
    var m=META[k], v=sGetVal(k), def=sDefault[k]||'', dirty=k in sDirty;
    var ctrl='';
    if(m.t==='bool'){
      var chk=(String(v).toLowerCase()==='true')?'checked':'';
      ctrl='<label class="toggle"><input type="checkbox" '+chk+' onchange="sBool(\''+esc(k)+'\',this.checked)"><span class="tog-sl"></span></label>';
    } else if(m.t==='enum'&&m.opts){
      var opts=m.opts.map(function(o){return'<option value="'+esc(o)+'"'+(o===v?' selected':'')+'>'+esc(o)+'</option>';}).join('');
      ctrl='<select onchange="sVal(\''+esc(k)+'\',this.value)">'+opts+'</select>';
    } else if(m.t==='float'){
      ctrl='<input type="number" step="0.1" value="'+(parseFloat(v)||0)+'" onchange="sFloat(\''+esc(k)+'\',this.value)">';
    } else if(m.t==='int'){
      ctrl='<input type="number" step="1" value="'+(parseInt(v)||0)+'" onchange="sInt(\''+esc(k)+'\',this.value)">';
    } else {
      ctrl='<input type="text" value="'+esc(stripQ(v))+'" onchange="sStr(\''+esc(k)+'\',this.value)">';
    }
    var defDisp=stripQ(def);
    return '<div class="setting-row'+(dirty?' modified':'')+'"><div class="setting-info">'
      +'<div class="setting-name" title="'+esc(k)+'">'+esc(k)+'</div>'
      +'<div class="setting-desc">'+esc(m.d)+'</div>'
      +(defDisp?'<div class="setting-def">Default: '+esc(defDisp)+'</div>':'')
      +'</div><div class="setting-ctrl">'+ctrl+'</div></div>';
  }).join('');
  document.getElementById('settings-grid').innerHTML=html;
}

function switchTab(cat){sCat=cat;renderSettingsTabs();renderSettingsGrid();}

function updateDirtyBadge(){
  var n=Object.keys(sDirty).length, el=document.getElementById('dirty-badge');
  el.style.display=n?'':'none'; el.textContent=n+' unsaved change'+(n!==1?'s':'');
}
function sBool(k,v){sDirty[k]=v?'True':'False';updateDirtyBadge();renderSettingsTabs();}
function sVal(k,v){sDirty[k]=v;updateDirtyBadge();renderSettingsTabs();}
function sFloat(k,v){var f=parseFloat(v);if(!isNaN(f)){sDirty[k]=f.toFixed(6);}updateDirtyBadge();renderSettingsTabs();}
function sInt(k,v){var i=parseInt(v);if(!isNaN(i)){sDirty[k]=String(i);}updateDirtyBadge();renderSettingsTabs();}
function sStr(k,v){sDirty[k]='"'+v+'"';updateDirtyBadge();renderSettingsTabs();}

// Rebuild the "Editing:" dropdown from the current save list, preserving the
// selection. Active world = live file; other saves edit their stored settings.
function populateSettingsTarget(){
  var sel=document.getElementById('settings-target'); if(!sel)return;
  var active=savesList.filter(function(s){return s.isActive;})[0];
  var activeLabel=active?('Active: '+active.name+' - live'):'Active world - live';
  var html='<option value="">'+esc(activeLabel)+'</option>';
  savesList.filter(function(s){return !s.isActive;})
    .forEach(function(s){
      var tag=s.hasSettings?'':' (no saved settings)';
      html+='<option value="'+esc(s.id)+'">'+esc(s.name)+tag+'</option>';
    });
  sel.innerHTML=html;
  // Keep the current target if it still exists, else fall back to live.
  if(sTarget && !savesList.some(function(s){return s.id===sTarget && !s.isActive;})) sTarget='';
  sel.value=sTarget;
}
function changeSettingsTarget(){
  var sel=document.getElementById('settings-target');
  var next=sel.value;
  if(Object.keys(sDirty).length && !confirm('Discard unsaved changes and switch?')){ sel.value=sTarget; return; }
  sTarget=next; sLoaded=false; sDirty={}; fetchFileSettings();
}
async function fetchFileSettings(){
  try{
    var url='/api/file-settings'+(sTarget?('?slot='+encodeURIComponent(sTarget)):'');
    var d=await api(url);
    sActive=d.active||{}; sDefault=d.defaults||{}; sDirty={};
    sLoaded=true; updateDirtyBadge(); renderSettingsTabs(); renderSettingsGrid();
    if(sTarget && d.hasCustom===false) toast('This save had no stored settings yet - seeded from the live file. Saving creates them.','info',7000);
  }catch(e){document.getElementById('settings-grid').innerHTML='<div class="empty-state err">Could not load settings file.</div>';}
}
function reloadSettings(){sLoaded=false;sDirty={};fetchFileSettings();}
function resetDirty(){sDirty={};updateDirtyBadge();renderSettingsTabs();renderSettingsGrid();}

// Stages every setting in the current tab back to its default value (doesn't
// write the file until Save Settings is clicked, matching the normal dirty flow).
function resetTabToDefaults(){
  var keys=Object.keys(META).filter(function(k){return META[k].c===sCat;});
  if(!keys.length)return;
  if(!confirm('Reset all "'+sCat+'" settings to their defaults?\nThis only stages the change - click Save Settings to apply it.')) return;
  keys.forEach(function(k){ if(k in sDefault) sDirty[k]=sDefault[k]; });
  updateDirtyBadge(); renderSettingsTabs(); renderSettingsGrid();
}

async function saveFileSettings(){
  var merged=Object.assign({},sActive,sDirty);
  try{
    var r=await api('/api/file-settings','POST',{slot:sTarget||null, settings:merged});
    sActive=merged; sDirty={};
    updateDirtyBadge(); renderSettingsTabs(); renderSettingsGrid();
    if(r.target==='slot') toast('Saved to this save\'s settings. They apply when you load it.','success',8000);
    else toast('Settings saved. Restart or reboot the server for changes to take effect.','success',8000);
    fetchSaves();
  }catch(e){toast('Save failed: '+e.message,'error');}
}

// ── Save Manager ──────────────────────────────────────────────────────────────
var savesState = {serverRunning:false, activeSlot:null};
function fmtSize(mb){mb=Number(mb)||0;return mb>=1024?(mb/1024).toFixed(1)+' GB':mb.toFixed(0)+' MB';}
function fmtSaved(ts){if(!ts)return '-';var d=new Date(ts);return isNaN(d.getTime())?ts:d.toLocaleString();}
async function fetchSaves(){
  try{
    var d=await api('/api/saves');
    savesState={serverRunning:!!d.serverRunning, activeSlot:d.activeSlot};
    savesList=d.slots||[];
    populateSettingsTarget();
    renderSaves(d.slots||[]);
    var b=document.getElementById('saves-active-badge');
    var act=(d.slots||[]).filter(function(s){return s.isActive;})[0];
    b.textContent=act?('Active: '+act.name):(d.activeGuid?('Active world: '+String(d.activeGuid).substring(0,8)):'No active save');
  }catch(e){
    document.getElementById('saves-area').innerHTML='<div class="empty-state err">Could not load saves: '+esc(e.message)+'</div>';
  }
}
var expandedBackups={};   // save id (or '__orphan__') -> backups row expanded?
function isBackup(s){ return s.auto && !s.isActive; }   // active autos still show in main list
function backupsFor(id){
  return savesList.filter(function(s){return isBackup(s) && (s.parent||'')===id;})
    .sort(function(a,b){return String(b.saved||'').localeCompare(String(a.saved||''));});
}
function toggleBackups(id){ expandedBackups[id]=!expandedBackups[id]; renderSaves(savesList); }

function saveRowHtml(s){
  var tags='';
  if(s.isActive) tags+=' <span class="tag tag-green">Active</span>';
  if(s.pending)  tags+=' <span class="tag tag-blue">new</span>';
  if(s.auto)     tags+=' <span class="tag tag-muted">auto</span>';
  var savedTxt=s.pending&&!s.saved?'Generating on start':fmtSaved(s.saved);
  var actBtn=s.isActive
    ? '<button class="btn btn-ghost" disabled>Loaded</button>'
    : '<button class="btn btn-primary" onclick="activateSave(\''+esc(s.id)+'\',\''+esc(s.name)+'\')">Load</button>';
  var n=backupsFor(s.id).length;
  var open=expandedBackups[s.id];
  var bkBtn='<button class="btn btn-ghost" onclick="toggleBackups(\''+esc(s.id)+'\')"'+(n?'':' disabled')
    +' style="margin-left:4px" title="Auto-backups taken before switching away from this save">'
    +(open?'&#9662;':'&#9656;')+' Backups ('+n+')</button>';
  var delBtn=s.isActive
    ? '<button class="btn btn-danger" disabled title="Switch away before deleting">Delete</button>'
    : '<button class="btn btn-danger" onclick="deleteSave(\''+esc(s.id)+'\',\''+esc(s.name)+'\')" style="margin-left:4px">Delete</button>';
  return '<tr>'
    +'<td class="player-name">'+esc(s.name)+tags+(s.note?'<div class="hint">'+esc(s.note)+'</div>':'')+'</td>'
    +'<td style="font-family:monospace;font-size:11px">'+esc(String(s.guid||'').substring(0,8))+'</td>'
    +'<td>'+(s.players||0)+'</td>'
    +'<td>'+fmtSize(s.sizeMB)+'</td>'
    +'<td style="color:var(--muted);font-size:11px">'+esc(savedTxt)+'</td>'
    +'<td style="white-space:nowrap">'+actBtn
    +'<button class="btn btn-ghost" onclick="renameSave(\''+esc(s.id)+'\',\''+esc(s.name)+'\')" style="margin-left:4px">Rename</button>'
    +bkBtn+delBtn+'</td>'
    +'</tr>';
}
function backupRowsHtml(bks){
  if(!bks.length) return '<tr><td colspan="6" class="hint" style="padding-left:30px">No backups.</td></tr>';
  return bks.map(function(b){
    return '<tr style="background:rgba(255,255,255,.02)">'
      +'<td style="padding-left:30px"><span class="tag tag-muted">backup</span> '+esc(b.name)+(b.note?'<div class="hint">'+esc(b.note)+'</div>':'')+'</td>'
      +'<td style="font-family:monospace;font-size:11px">'+esc(String(b.guid||'').substring(0,8))+'</td>'
      +'<td>'+(b.players||0)+'</td>'
      +'<td>'+fmtSize(b.sizeMB)+'</td>'
      +'<td style="color:var(--muted);font-size:11px">'+esc(fmtSaved(b.saved))+'</td>'
      +'<td style="white-space:nowrap"><button class="btn btn-primary" onclick="activateSave(\''+esc(b.id)+'\',\''+esc(b.name)+'\')">Restore</button>'
      +'<button class="btn btn-danger" onclick="deleteSave(\''+esc(b.id)+'\',\''+esc(b.name)+'\')" style="margin-left:4px">Delete</button></td>'
      +'</tr>';
  }).join('');
}
function renderSaves(slots){
  var area=document.getElementById('saves-area');
  if(!slots.length){area.innerHTML='<div class="empty-state">No saves in your library yet. Use &ldquo;Save current world to library&rdquo; above to add your current game.</div>';return;}
  // Main list = real saves (and the active one even if it is a restored backup).
  var main=slots.filter(function(s){return !isBackup(s);})
    .sort(function(a,b){return String(b.saved||'').localeCompare(String(a.saved||''));});
  var rows='';
  main.forEach(function(s){
    rows+=saveRowHtml(s);
    if(expandedBackups[s.id]) rows+=backupRowsHtml(backupsFor(s.id));
  });
  // Backups whose parent save no longer exists (deleted, or pre-dating this feature).
  var orphans=slots.filter(function(b){return isBackup(b) && !main.some(function(m){return m.id===(b.parent||'');});})
    .sort(function(a,b){return String(b.saved||'').localeCompare(String(a.saved||''));});
  if(orphans.length){
    var o=expandedBackups['__orphan__'];
    rows+='<tr><td colspan="6" style="background:var(--surface2)"><button class="btn btn-ghost" onclick="toggleBackups(\'__orphan__\')">'
      +(o?'&#9662;':'&#9656;')+' Other backups ('+orphans.length+')</button></td></tr>';
    if(o) rows+=backupRowsHtml(orphans);
  }
  area.innerHTML='<table><thead><tr><th>Name</th><th>World ID</th><th>Players</th><th>Size</th><th>Saved</th><th>Actions</th></tr></thead><tbody>'+rows+'</tbody></table>';
}
async function captureSave(){
  var inp=document.getElementById('capture-name');
  var name=inp.value.trim();
  if(!name){toast('Enter a name for the save first.','error');return;}
  toast('Saving current world to library...','info');
  try{
    var r=await api('/api/save-capture','POST',{name:name});
    toast('Saved "'+(r.name||name)+'" to library.','success');
    inp.value='';
    await fetchSaves();
  }catch(e){toast('Save failed: '+e.message,'error');}
}
async function newWorld(){
  var inp=document.getElementById('newworld-name');
  var name=inp.value.trim();
  if(!name){toast('Enter a name for the new world first.','error');return;}
  var restart=document.getElementById('restart-after').checked;
  var warn='Create a brand-new empty world "'+name+'"?\n\n';
  if(savesState.serverRunning) warn+='- The running server will be stopped (players disconnected).\n';
  warn+='- Your current world is backed up to the library first.\n';
  warn+=restart?'- The server will start on the new empty world.':'- The new world will be generated next time you start the server.';
  if(!confirm(warn))return;
  toast('Creating new world...','warn',9000);
  try{
    var r=await api('/api/save-new','POST',{name:name,restart:restart});
    toast(r.status||('Created "'+name+'".'),'success',8000);
    inp.value='';
    sTarget=''; sLoaded=false; sDirty={};
    setTimeout(function(){ fetchSaves(); fetchFileSettings(); },1500);
    if(restart) setTimeout(refreshAll,5000);
  }catch(e){toast('Create failed: '+e.message,'error',8000);}
}
async function activateSave(id,name){
  var restart=document.getElementById('restart-after').checked;
  var warn='Load "'+name+'" as the active world?\n\n';
  if(savesState.serverRunning) warn+='- The running server will be stopped (players disconnected).\n';
  warn+='- A backup of the current world is saved to your library first.\n';
  warn+=restart?'- The server will restart on the loaded save.':'- The server will stay stopped after loading.';
  if(!confirm(warn))return;
  toast('Switching saves - this can take a moment...','warn',9000);
  try{
    var r=await api('/api/save-activate','POST',{slot:id,restart:restart});
    toast(r.status||('Loaded "'+name+'".'),'success',8000);
    // The loaded save's settings are now the live file (swapped server-side), so
    // reset the editor to the active save and reload it without a page refresh.
    sTarget=''; sLoaded=false; sDirty={};
    setTimeout(function(){ fetchSaves(); fetchFileSettings(); },1500);
    if(restart) setTimeout(refreshAll,4000);
  }catch(e){toast('Switch failed: '+e.message,'error',8000);}
}
async function renameSave(id,cur){
  var name=prompt('Rename save:',cur);
  if(name===null)return;
  name=name.trim(); if(!name){toast('Name cannot be empty.','error');return;}
  try{await api('/api/save-rename','POST',{slot:id,name:name});toast('Renamed.','success');await fetchSaves();}
  catch(e){toast('Rename failed: '+e.message,'error');}
}
async function deleteSave(id,name){
  if(!confirm('Delete the library copy "'+name+'"?\nThis cannot be undone. The active world is not affected.'))return;
  try{await api('/api/save-delete','POST',{slot:id});toast('Deleted "'+name+'".','success');await fetchSaves();}
  catch(e){toast('Delete failed: '+e.message,'error');}
}

// ── Countdown ─────────────────────────────────────────────────────────────────
function fmtCountdown(s){var m=Math.floor(s/60),sc=s%60;return m+':'+(sc<10?'0':'')+sc;}
function resetCountdown(){countdown=300;setText('countdown',fmtCountdown(300));}
function tick(){countdown--;setText('countdown',fmtCountdown(Math.max(0,countdown)));if(countdown<=0)refreshAll();}

// ── Boot ──────────────────────────────────────────────────────────────────────
initChartHover();
refreshAll();
setInterval(tick,1000);
loadSpecies();
loadSkills();
loadPassives();
// Restore the last-active tab once the whole DOM (including any late-injected views) is
// parsed. Registered before DOMContentLoaded fires (this inline boot script runs while
// the document is still parsing), so it survives the generator's boot rewrite too.
document.addEventListener('DOMContentLoaded',restoreView);
// Server-message chat banner: reflect the saved mute state on the bell, then poll.
(function(){ var b=document.getElementById('snd-toggle'); if(b) b.innerHTML=chatSoundOn()?'&#128276;':'&#128277;'; })();
pollServerMessages(); setInterval(pollServerMessages,8000);
// Canvas pixel dimensions are sized from offsetWidth at draw time, so a window
// resize leaves them stale (blurry/stretched). Re-render the charts, debounced.
var _rszT;
window.addEventListener('resize',function(){clearTimeout(_rszT);_rszT=setTimeout(renderCharts,200);});
</script>
<style>
/* Server-message chat banner (shared admin + public) */
.chat-banner-host{position:fixed;top:60px;left:50%;transform:translateX(-50%);z-index:9999;display:flex;flex-direction:column;gap:8px;align-items:center;width:min(92vw,520px);pointer-events:none;}
.chat-banner{background:var(--surface2,#21262d);border:1px solid var(--border,#30363d);border-left:3px solid var(--green,#3fb950);color:var(--text,#c9d1d9);border-radius:8px;padding:10px 14px;box-shadow:0 6px 24px rgba(0,0,0,.45);display:flex;align-items:center;gap:10px;font-size:13px;line-height:1.35;max-width:100%;opacity:0;transform:translateY(-10px);transition:opacity .35s ease,transform .35s ease;}
.chat-banner.show{opacity:1;transform:translateY(0);}
.chat-banner-ico{font-size:16px;flex-shrink:0;}
.chat-banner-msg{word-break:break-word;}
.msglog-panel{position:fixed;top:54px;right:14px;z-index:9998;width:360px;max-width:92vw;max-height:70vh;background:var(--surface2,#21262d);border:1px solid var(--border,#30363d);border-radius:10px;box-shadow:0 10px 32px rgba(0,0,0,.5);display:flex;flex-direction:column;overflow:hidden;}
.msglog-hdr{display:flex;align-items:center;justify-content:space-between;padding:8px 12px;border-bottom:1px solid var(--border,#30363d);font-size:13px;font-weight:700;color:var(--text,#c9d1d9);}
.msglog-hdr button{background:none;border:0;color:var(--muted,#8b949e);font-size:16px;cursor:pointer;line-height:1;padding:0 2px;}
.msglog-hdr button:hover{color:#f85149;}
.msglog-body{overflow-y:auto;padding:6px;display:flex;flex-direction:column;gap:6px;}
.msglog-item{background:var(--surface,#161b22);border:1px solid var(--border,#30363d);border-radius:8px;padding:7px 10px;font-size:12px;line-height:1.4;}
.msglog-item .ml-time{color:var(--muted,#8b949e);font-size:10.5px;display:block;margin-bottom:2px;}
.msglog-item .ml-msg{color:var(--text,#c9d1d9);word-break:break-word;}
.msglog-item.ml-egg{border-left:3px solid #ffd84d;}
.msglog-item.ml-maintenance{border-left:3px solid #58a6ff;}
.msglog-item.ml-broadcast{border-left:3px solid #3fb950;}
.pal-card{cursor:pointer;}
.pal-modal-overlay{position:fixed;inset:0;background:rgba(0,0,0,.62);display:none;align-items:flex-start;justify-content:center;z-index:200;padding:24px 12px;overflow:auto;}
.pal-modal{background:var(--surface);border:1px solid var(--border);border-radius:12px;max-width:520px;width:100%;padding:16px;}
/* Header grid: portrait spans rows 1-3; row1 name, row2 level, row3 element;
   the EXP bar fills the right column across rows 2-3 (beside level + element). */
.pm-top{display:grid;grid-template-columns:auto auto 1fr;gap:6px 14px;align-items:center;position:relative;}
.pm-portrait{width:74px;height:74px;border-radius:8px;background:var(--surface2);object-fit:cover;grid-row:1 / 4;grid-column:1;align-self:center;}
.pm-id{grid-column:2 / 4;grid-row:1;min-width:0;}
.pm-name{font-size:23px;font-weight:800;line-height:1.15;display:flex;align-items:center;gap:8px;flex-wrap:wrap;}
.pm-name .gico{font-size:20px;}
.pm-name .pm-no{font-size:14px;font-weight:600;color:var(--muted);}
.pm-name .pal-stars{font-size:14px;}
.pm-lv{grid-column:2;grid-row:2;font-size:18px;font-weight:700;white-space:nowrap;}
.pm-elems{grid-column:2;grid-row:3;display:flex;flex-direction:column;gap:4px;align-items:flex-start;}
.elem-pill{display:inline-flex;align-items:center;gap:4px;font-size:12px;font-weight:600;padding:2px 10px;border-radius:999px;border:1px solid;}
.elem-pill .cic{width:15px;height:15px;}
.pm-exp{grid-column:3;grid-row:2 / 4;align-self:center;}
.pm-exp .pm-prog{margin-top:0;}
/* Stats as centered pill cards: HP / ATK / DEF / Work Speed (work speed has no IV). */
.pm-stcards{display:flex;justify-content:center;flex-wrap:wrap;gap:10px;}
.pm-stcard{background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:8px 16px;text-align:center;min-width:62px;}
.pm-stcard .l{font-size:10px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);}
.pm-stcard .v{font-size:19px;font-weight:700;line-height:1.2;font-variant-numeric:tabular-nums;}
.pm-stcard .iv{font-size:12px;font-weight:700;min-height:15px;font-variant-numeric:tabular-nums;}
.pm-stcard .iv .ivl{color:var(--muted);font-weight:600;font-size:9px;}
/* Bordered card wrapper around the partner / active / learnable skill sections. */
.pm-card{background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:10px 12px;}
.pm-card .pal-chips{gap:5px;}
.skill-chip{display:inline-flex;align-items:center;gap:4px;font-size:11px;font-weight:600;padding:3px 8px;}
.skill-chip .cic{width:13px;height:13px;vertical-align:0;}
/* Work suitability: icon + level, 3 columns, greyed when zero. */
.pm-wgrid{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;}
.pm-wcell{display:flex;align-items:center;gap:7px;background:var(--surface2);border:1px solid var(--border);border-radius:7px;padding:5px 9px;}
.pm-wcell img{width:20px;height:20px;}
.pm-wcell .wl{font-size:15px;font-weight:700;}
.pm-wcell.off{opacity:.3;}
/* Passives: 2x2 grid, exact palworld.wiki.gg passive-skill styling. The chiseled frame
   (passive_frame.png, 9-slice) overlays via ::after; tier 1-2 neutral white, tier 3 gold,
   tier 4 legendary green/blue, negatives red -- arrows + frame tinted by the wiki's own
   CSS filter chains. Assets are bundled under icons/ (downloaded from the wiki). */
.pm-pgrid{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;}
.ppill{position:relative;display:inline-grid;grid-template-columns:minmax(0,1fr);align-items:center;justify-content:space-between;background-size:cover;font-size:13px;font-weight:700;line-height:1.3;}
.ppill .pp-name{grid-column:1;grid-row:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:3px 30px 3px 11px;color:#fff;}
.ppill .pp-ico{grid-column:1;grid-row:1;position:absolute;right:6px;width:1lh;height:1lh;background-position:center;background-repeat:no-repeat;background-size:100% calc(100% - 5px);}
.ppill::after{grid-column:1;grid-row:1;pointer-events:none;content:"";position:relative;display:inline-flex;width:100%;height:100%;border-image-source:url(icons/passive_frame.png);border-image-slice:6 fill;border-image-width:1px 1px 1px 6px;}
.pp-neu,.pp-pos1,.pp-pos2,.pp-neg1,.pp-neg2,.pp-neg3{background:#262e2e;}
.pp-pos3{background-image:linear-gradient(#ffdd0020,#ffdd0020),linear-gradient(#11111188,#111111ff),url(icons/passive_triangle.png);}
.pp-pos4{background-image:linear-gradient(to right,#59bb653d,#4543d17a),linear-gradient(#11111188,#111111ff),url(icons/passive_triangle.png);}
.pp-pos1 .pp-ico{background-image:url(icons/passive_pos_1.png);}
.pp-pos2 .pp-ico{background-image:url(icons/passive_pos_2.png);}
.pp-pos3 .pp-ico{background-image:url(icons/passive_pos_3.png);}
.pp-pos4 .pp-ico{background-image:url(icons/passive_pos_4.png);background-size:100% 100%;}
.pp-neg1 .pp-ico{background-image:url(icons/passive_neg_1.png);}
.pp-neg2 .pp-ico{background-image:url(icons/passive_neg_2.png);}
.pp-neg3 .pp-ico{background-image:url(icons/passive_neg_3.png);}
.pp-pos3 > *,.pp-pos3::after{filter:brightness(0) saturate(100%) invert(80%) sepia(83%) saturate(2225%) hue-rotate(350deg) brightness(95%) contrast(113%);}
.pp-pos4 > *,.pp-pos4::after{filter:brightness(0) saturate(100%) invert(80%) sepia(13%) saturate(1347%) hue-rotate(109deg) brightness(107%) contrast(103%);}
.pp-neg1 > .pp-ico,.pp-neg2 > .pp-ico,.pp-neg3 > .pp-ico,.pp-neg1::after,.pp-neg2::after,.pp-neg3::after{filter:brightness(0) saturate(100%) invert(28%) sepia(91%) saturate(1562%) hue-rotate(335deg) brightness(90%) contrast(94%);}
/* Compact passive pills on the dashboard cards (popup keeps the larger size). The
   frame border is also thinned here -- at 6px (the popup's width) it eats more of
   the pill's height than the 2px text padding leaves room for, overlapping the name. */
.pal-card .pm-pgrid,.egg-card .pm-pgrid{gap:5px;}
.pal-card .ppill,.egg-card .ppill{font-size:11px;}
.pal-card .ppill::after,.egg-card .ppill::after{border-image-width:1px 1px 1px 3px;}
/* On the dashboard cards, wrap long passive names instead of truncating with "..."
   so the grid keeps its column count (egg + pal cards alike). */
.pal-card .ppill .pp-name,.egg-card .ppill .pp-name{padding:3px 22px 3px 9px;white-space:normal;overflow:visible;text-overflow:clip;line-height:1.2;}
.pm-close{position:absolute;top:-4px;right:-4px;background:var(--surface2);border:1px solid var(--border);color:var(--text);width:30px;height:30px;border-radius:6px;font-size:18px;cursor:pointer;line-height:1;}
.pm-close:hover{background:var(--border);}
.pm-sec{margin-top:14px;}
.pm-sec-h{font-size:11px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);margin-bottom:6px;}
.pm-stats{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;}
.pm-stat{background:var(--surface2);border:1px solid var(--border);border-radius:8px;padding:6px 10px;}
.pm-stat-l{font-size:11px;color:var(--muted);}
.pm-stat-v{font-size:15px;font-weight:600;}
.pm-muted{color:var(--muted);font-size:13px;}
.pal-chip.tchip{background:rgba(163,113,247,.16);border-color:rgba(163,113,247,.45);font-weight:600;}
.pal-work{margin-top:4px;}
/* gender icon: inline SVG sized to the text (1em), tinted via currentColor. */
.gico{width:1em;height:1em;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;vertical-align:middle;flex:none;}
.gico.g-m{color:#58a6ff;}
.gico.g-f{color:#f85149;}
.pal-name .gico{font-size:.95em;}
/* elem_*.webp source images are 104x32 wide UI banner art (paldb's menu-status ribbon
   asset), not square icons like work_*.webp (64x64) -- stretching width/height evenly
   squished the glyph and dragged in the ribbon's excess background. object-fit:cover
   preserves aspect ratio and crops to a square instead of stretching; object-position:left
   keeps the crop on the glyph, which sits in the banner's left portion. No-op for the
   already-square work icons sharing this class. */
.cic{width:16px;height:16px;vertical-align:-3px;object-fit:cover;object-position:left center;}
.tchip .cic,.wchip .cic{width:15px;height:15px;}
.pm-prog{margin-top:8px;}
.pm-prog-top{display:flex;justify-content:space-between;font-size:12px;margin-bottom:3px;}
.pm-bar{height:7px;background:var(--surface2);border:1px solid var(--border);border-radius:5px;overflow:hidden;}
.pm-bar-fill{height:100%;background:var(--green);border-radius:5px;}
.pm-bar-fill.bar-exp{background:#22d3ee;}
.pm-bar-fill.bar-trust{background:#f472b6;}
</style>
<div id="pal-modal-overlay" class="pal-modal-overlay" onclick="if(event.target===this)closePalModal()"><div class="pal-modal" id="pal-modal-body"></div></div>
<div id="skill-modal-overlay" class="pal-modal-overlay" style="z-index:700;align-items:center;" onclick="if(event.target===this)closeSkillModal()"><div class="pal-modal" id="skill-modal-body" style="max-width:420px;"></div></div>
<script>
(function(){
  function chips(arr){return (arr&&arr.length)?arr.map(function(s){return '<span class="pal-chip">'+esc(s)+'</span>';}).join(''):'<span class="pm-muted">None</span>';}
  function sec(t,b){return b?('<div class="pm-sec"><div class="pm-sec-h">'+t+'</div>'+b+'</div>'):'';}
  function stat(l,v){return '<div class="pm-stat"><div class="pm-stat-l">'+l+'</div><div class="pm-stat-v">'+v+'</div></div>';}
  // Map a pal's flat container slot index to its in-game page/coordinate position,
  // matching PalCalc's layout: the Pal Box is a 6-wide x 5-tall grid per tab (30 per
  // tab), the party is a flat 6-slot row; everything 1-based. Returns '' if unplaceable.
  function palSlotPos(p){
    var idx=p.slotIndex;
    if(idx==null||idx<0)return '';
    var t=p.locationType;
    if(t==='party')return 'Slot '+(idx+1);
    if(t==='palbox'){
      var per=30,w=6,within=idx%per;
      return 'Page '+(Math.floor(idx/per)+1)+', col '+((within%w)+1)+', row '+(Math.floor(within/w)+1);
    }
    // base camp (and anything else) has no in-game grid view -- show the raw slot.
    return 'Slot '+(idx+1);
  }
  // Expose so the Pals-grid card (palCard, a top-level fn) can render the exact same
  // slot position as this detail popup, instead of duplicating the grid math.
  window.palSlotPos=palSlotPos;
  window.openPalModal=function(p){
    var look=palLookup(p.species);
    var stars=(p.rank>1)?(' <span class="pal-stars">'+'&#9733;'.repeat(Math.min(p.rank-1,4))+'</span>'):'';
    var badges=(p.isAlpha?'<span class="pal-badge pb-alpha">Alpha</span>':'')+(p.isLucky?'<span class="pal-badge pb-lucky">Lucky</span>':'');
    // Hp is stored as a x1000 fixed-point value in the save (this is the pal's max HP).
    var hp=(p.hp!=null)?Math.round(p.hp/1000):null;
    var st=stat('Sanity',(p.sanity!=null?Math.round(p.sanity):'Full'));
    // EXP progress to next level (shown under the header); Lv 65 = cap.
    var L=p.level||1;
    var expBar=(L>=MAX_LEVEL)?maxedBar('EXP','bar-exp'):((p.exp!=null&&EXP_CURVE[L+1]!=null)?progBar('EXP',p.exp,EXP_CURVE[L]||0,EXP_CURVE[L+1],'XP','bar-exp'):'');
    // Friendship -> Trust level (0-10) + progress to next.
    var trustHtml='';
    if(p.friendship!=null){var fp=p.friendship,tl=0,ti;for(ti=1;ti<TRUST_REQ.length;ti++){if(fp>=TRUST_REQ[ti])tl=ti;}
      trustHtml=(tl>=10)?maxedBar('<b>Trust Lv 10</b>','bar-trust'):progBar('<b>Trust Lv '+tl+'</b>',fp,TRUST_REQ[tl],TRUST_REQ[tl+1],'pts','bar-trust');}
    var soul='';
    if(p.souls){var sk=Object.keys(p.souls).filter(function(k){return p.souls[k]>0;});
      if(sk.length)soul=sk.map(function(k){return '<span class="pal-chip">'+esc(k)+' +'+p.souls[k]+'</span>';}).join('');}
    var loc=esc(p.location||'')+(p.locationType?(' ('+esc(p.locationType)+')'):'');
    // Container position (page/coords), PalCalc-style, shown under the container label.
    var locPos=palSlotPos(p);
    // Species-level data (absent for NPCs / un-catalogued creatures -> sections hide).
    var sp=speciesOf(p);
    // Element pill(s), tinted to the element color, shown under the level.
    var elemHtml=(sp&&sp.types&&sp.types.length)?('<div class="pm-elems">'+sp.types.map(elemPill).join('')+'</div>'):'';
    var pk=sp&&sp.partnerSkill;
    var partnerHtml=(pk&&pk.name)?('<div><b>'+esc(pk.name)+'</b>'+(pk.text?(' <span class="pm-muted">'+esc(pk.text)+'</span>'):'')+'</div>'):'';
    // Learned skills: every move the pal currently knows -- naturally learned moves up to
    // its level, plus equipped and mastered (incl. skill-fruit) moves -- deduped.
    var known=[],kseen={};
    var addKnown=function(m){if(m&&!kseen[m]){kseen[m]=1;known.push(m);}};
    if(sp&&sp.activeSkills)sp.activeSkills.forEach(function(s){if(s.level<=(p.level||1))addKnown(s.name);});
    (p.equipMoves||[]).forEach(addKnown);(p.masteredMoves||[]).forEach(addKnown);
    var learnHtml=known.length?known.map(skillChip).join(''):'';
    // Stats as centered pill cards. HP uses the save's true max HP; ATK/DEF are computed
    // from the species level-65 range scaled to level. Work Speed rides along (no IV slot).
    var bs=sp&&sp.stats;
    var statCard=function(lbl,sv,iv){
      var ivh=(iv==null)?'<div class="iv">&nbsp;</div>':'<div class="iv" style="color:'+ivColor(iv)+'"><span class="ivl">IV</span> '+(iv<0?'-':iv)+'</div>';
      return '<div class="pm-stcard"><div class="l">'+lbl+'</div><div class="v">'+(sv==null?'-':sv)+'</div>'+ivh+'</div>';};
    var statsHtml='<div class="pm-stcards">'
      +statCard('HP',(hp!=null?hp:(bs?calcStat(bs.hp,p.level,p.ivHp,true,0):null)),p.ivHp)
      +statCard('ATK',(bs?calcStat(bs.attack,p.level,p.ivShot,false,100):null),p.ivShot)
      +statCard('DEF',(bs?calcStat(bs.defense,p.level,p.ivDefense,false,50):null),p.ivDefense)
      +statCard('Work Speed',workSpeed(p),null)
      +'</div>';
    // Work suitability: every work type as icon + level (greyed when zero), 3 across.
    // Oil extraction is not a real in-game job, so it's excluded from the grid.
    var wgrid='';
    Object.keys(WORK_ICON).forEach(function(w){
      if(w==='Crude oil extraction')return;
      var lv=workLevel(p,sp,w);
      wgrid+='<div class="pm-wcell'+(lv?'':' off')+'">'+workIco(w)+'<span class="wl">'+lv+'</span></div>';
    });
    var workHtml=sp?('<div class="pm-wgrid">'+wgrid+'</div>'):'';
    // Passives: 2x2 grid, colored + chevroned by rarity tier.
    var passHtml=(p.passives&&p.passives.length)?('<div class="pm-pgrid">'+p.passives.map(passivePill).join('')+'</div>'):'<span class="pm-muted">None</span>';
    var html='<div class="pm-top">'
      +'<img class="pm-portrait" src="'+palPortrait(look.name)+'" onerror="this.style.visibility=\'hidden\'">'
      +'<div class="pm-id"><div class="pm-name">'+esc(look.name)+(p.gender?(' '+genderIcon(p.gender)):'')+stars+' <span class="pm-no">#'+look.noStr+'</span></div>'
      +(p.nickname?('<div class="pal-nick">'+esc(p.nickname)+'</div>'):'')
      +(badges?('<div class="pal-badges">'+badges+'</div>'):'')+'</div>'
      +'<div class="pm-lv">Lv '+(p.level||1)+'</div>'
      +elemHtml
      +'<div class="pm-exp">'+expBar+'</div>'
      +'<button class="pm-close" onclick="closePalModal()" aria-label="Close">&times;</button>'
      +'</div>'
      +sec('Friendship',trustHtml)
      +sec('Stats',statsHtml)
      +sec('Work Suitability',workHtml)
      +sec('Passives',passHtml)
      +sec('Partner Skill',partnerHtml?('<div class="pm-card">'+partnerHtml+'</div>'):'')
      +sec('Active Skills','<div class="pm-card"><div class="pal-chips">'+skillChips(p.equipMoves)+'</div></div>')
      +sec('Learned Skills',learnHtml?('<div class="pm-card"><div class="pal-chips">'+learnHtml+'</div></div>'):'')
      +sec('Status','<div class="pm-stats">'+st+'</div>')
      +sec('Condensation',soul?('<div class="pal-chips">'+soul+'</div>'):'')
      +sec('Location','<div class="pal-sub">'+loc+(locPos?('<div class="pm-muted" style="margin-top:3px;">'+locPos+'</div>'):'')+'</div>');
    document.getElementById('pal-modal-body').innerHTML=html;
    document.getElementById('pal-modal-overlay').style.display='flex';
  };
  // Paldeck species-detail popup: the same modal shell, but SPECIES-level info only (no
  // per-pal instance data) plus a button into the spawn map. Opened from a Paldeck row.
  // Gated on having caught at least one -- uncaught Pals stay locked (and on the public site
  // they are already masked with no click), so this never reveals an uncaught Pal's data.
  window.openPaldeckDetail=function(idx){
    var d=window._palRowData&&window._palRowData[idx];
    if(!d||(d.count||0)<1)return;
    var sp=(palSpecies&&palSpecies[d.internal])||null;
    var elemHtml=(sp&&sp.types&&sp.types.length)?('<div class="pm-elems">'+sp.types.map(elemPill).join('')+'</div>'):'';
    // Base stats as the level-65 range (IV 0 -> IV 100), since there's no single instance.
    var bs=sp&&sp.stats;
    var rangeCard=function(lbl,range,isHp,off){
      if(!range)return '<div class="pm-stcard"><div class="l">'+lbl+'</div><div class="v">-</div><div class="iv">&nbsp;</div></div>';
      var lo=calcStat(range,55,0,isHp,off), hi=calcStat(range,55,100,isHp,off);
      return '<div class="pm-stcard"><div class="l">'+lbl+'</div><div class="v">'+lo+'-'+hi+'</div><div class="iv">Lv 65</div></div>';
    };
    var statsHtml=bs?('<div class="pm-stcards">'+rangeCard('HP',bs.hp,true,0)+rangeCard('ATK',bs.attack,false,100)+rangeCard('DEF',bs.defense,false,50)+'</div>'):'';
    // Work suitability: species base level per work type (no per-pal boosts here).
    var wgrid='';
    Object.keys(WORK_ICON).forEach(function(w){
      if(w==='Crude oil extraction')return;
      var lv=(sp&&sp.work&&sp.work[w])||0;
      wgrid+='<div class="pm-wcell'+(lv?'':' off')+'">'+workIco(w)+'<span class="wl">'+lv+'</span></div>';
    });
    var workHtml=sp?('<div class="pm-wgrid">'+wgrid+'</div>'):'';
    var pk=sp&&sp.partnerSkill;
    var partnerHtml=(pk&&pk.name)?('<div><b>'+esc(pk.name)+'</b>'+(pk.text?(' <span class="pm-muted">'+esc(pk.text)+'</span>'):'')+'</div>'):'';
    // Learnable skills: the full learnset, each tagged with the level it's learned at.
    var learnHtml='';
    if(sp&&sp.activeSkills&&sp.activeSkills.length){
      var ls=sp.activeSkills.slice().sort(function(a,b){return (a.level||0)-(b.level||0);});
      learnHtml=ls.map(function(s){
        return '<span style="display:inline-flex;align-items:center;gap:4px;margin:2px 4px 2px 0;">'
          +'<span style="font-size:10px;color:var(--muted);min-width:32px;text-align:right;">Lv '+(s.level||1)+'</span>'+skillChip(s.name)+'</span>';
      }).join('');
    }
    var html='<div class="pm-top">'
      +'<img class="pm-portrait" src="'+palPortrait(d.name)+'" onerror="this.style.visibility=\'hidden\'">'
      +'<div class="pm-id"><div class="pm-name">'+esc(d.name)+' <span class="pm-no">#'+d.noStr+'</span></div>'
      +'<div class="pal-sub pm-muted">Caught: '+d.count+'</div></div>'
      +elemHtml
      +'<button class="pm-close" onclick="closePalModal()" aria-label="Close">&times;</button>'
      +'</div>'
      +'<div class="pm-sec"><button class="btn btn-primary btn-full" onclick="closePalModal();openPalMap('+idx+')">&#128205; View Spawn Map</button></div>'
      +sec('Base Stats',statsHtml)
      +sec('Work Suitability',workHtml)
      +sec('Partner Skill',partnerHtml?('<div class="pm-card">'+partnerHtml+'</div>'):'')
      +sec('Learnable Skills',learnHtml?('<div class="pm-card"><div class="pal-chips">'+learnHtml+'</div></div>'):'')
      +(sp?'':'<div class="pm-sec"><div class="pm-muted">No catalogued species data for this Pal.</div></div>');
    document.getElementById('pal-modal-body').innerHTML=html;
    document.getElementById('pal-modal-overlay').style.display='flex';
  };
  window.closePalModal=function(){var o=document.getElementById('pal-modal-overlay');if(o)o.style.display='none';};
  // Skill-detail popup (element/power/cooldown/status/description). Its own overlay layered
  // ABOVE the pal/paldeck modal (z 700), so tapping a skill chip in a learnset/active-skill
  // list opens it on top without losing the underlying detail view.
  window.openSkillModal=function(name){
    var s=(typeof palSkills!=='undefined'&&palSkills&&palSkills[name])||null;
    var stcard=function(l,v){return '<div class="pm-stcard"><div class="l">'+l+'</div><div class="v">'+v+'</div></div>';};
    var elem=s&&s.element;
    // Own centered header (the shared pm-top grid is built for the portrait layout and lets
    // the wide name run under the absolutely-positioned close X). Symmetric 34px padding
    // keeps the centered name clear of the X.
    var html='<div style="position:relative;text-align:center;padding:2px 34px 4px;">'
      +'<div class="pm-name" style="justify-content:center;">'+esc(name)+'</div>'
      +(elem?('<div class="pm-elems" style="align-items:center;margin-top:6px;">'+elemPill(elem)+'</div>'):'')
      +'<button class="pm-close" onclick="closeSkillModal()" aria-label="Close">&times;</button>'
      +'</div>';
    if(s){
      // DPS = damage per second = power / cooldown (rounded to 1 decimal), shown beside them.
      var dps=(s.power!=null&&s.cooldown)?(Math.round(s.power/s.cooldown*10)/10):null;
      html+='<div class="pm-sec"><div class="pm-stcards">'
        +stcard('Power',(s.power!=null?s.power:'&mdash;'))
        +stcard('Cooldown',(s.cooldown!=null?(s.cooldown+'s'):'&mdash;'))
        +(dps!=null?stcard('DPS',dps):'')
        +(s.status?stcard('Effect',esc(s.status)+(s.statusValue?(' '+esc(s.statusValue)):'')):'')
        +'</div></div>';
      if(s.desc) html+=sec('Description','<div class="pm-card">'+esc(s.desc)+'</div>');
    } else {
      html+='<div class="pm-sec"><div class="pm-muted">No details available for this skill.</div></div>';
    }
    document.getElementById('skill-modal-body').innerHTML=html;
    document.getElementById('skill-modal-overlay').style.display='flex';
  };
  window.closeSkillModal=function(){var o=document.getElementById('skill-modal-overlay');if(o)o.style.display='none';};
  // Passive-detail popup. Reuses the same top overlay as the skill popup (only one is open at
  // a time); shows the passive's rating tier + its effect text.
  window.openPassiveModal=function(name){
    var pv=(typeof palPassives!=='undefined'&&palPassives&&palPassives[name])||null;
    var t=(typeof PASSIVE_TIER!=='undefined'&&PASSIVE_TIER[name]); if(t==null)t=(pv&&pv.rank)||0;
    var rlabel, rcolor;
    if(t>=4){rlabel='Legendary';rcolor='#e3b341';}
    else if(t>0){rlabel='Positive &middot; Tier '+t;rcolor='#3fb950';}
    else if(t<0){rlabel='Negative &middot; Tier '+(-t);rcolor='#f85149';}
    else{rlabel='Neutral';rcolor='var(--muted)';}
    var html='<div style="position:relative;text-align:center;padding:2px 34px 4px;">'
      +'<div class="pm-name" style="justify-content:center;">'+esc(name)+'</div>'
      +'<div style="margin-top:6px;font-size:13px;font-weight:700;color:'+rcolor+'">'+rlabel+'</div>'
      +'<button class="pm-close" onclick="closeSkillModal()" aria-label="Close">&times;</button>'
      +'</div>';
    if(pv&&pv.effect){ html+=sec('Effect','<div class="pm-card">'+esc(pv.effect)+'</div>'); }
    else { html+='<div class="pm-sec"><div class="pm-muted">No effect details available for this passive.</div></div>'; }
    document.getElementById('skill-modal-body').innerHTML=html;
    document.getElementById('skill-modal-overlay').style.display='flex';
  };
  document.addEventListener('click',function(e){
    if(!e.target||!e.target.closest)return;
    // Tap a skill chip -> open its detail popup (works in both the Pals and Paldeck modals).
    var chip=e.target.closest('.skill-chip[data-skill]');
    if(chip){ openSkillModal(chip.getAttribute('data-skill')); return; }
    // Tap a passive pill -> its detail popup (in the detail modals AND the grid cards).
    var pp=e.target.closest('.ppill[data-passive]');
    if(pp){ openPassiveModal(pp.getAttribute('data-passive')); return; }
    var card=e.target.closest('.pal-card[data-iid]');
    if(!card)return;
    var iid=card.getAttribute('data-iid');
    var list=(typeof palsData!=='undefined'&&palsData&&palsData.pals)||[];
    var pal=list.find(function(p){return p.instanceId===iid;});
    if(pal)openPalModal(pal);
  });
  // Escape closes the topmost popup first (skill), then the pal/paldeck modal.
  document.addEventListener('keydown',function(e){
    if(e.key!=='Escape')return;
    var sm=document.getElementById('skill-modal-overlay');
    if(sm&&sm.style.display==='flex'){closeSkillModal();return;}
    closePalModal();
  });
})();
</script>
</body>
</html>
'@

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
                    Send-Response $res 200 "text/html; charset=utf-8" $HtmlPage
                    break
                }

                ($path -eq '/api/history' -and $method -eq 'GET') {
                    try {
                        if (Test-Path $LogFile) {
                            $lines   = @(Get-Content $LogFile -Tail 288 -Encoding UTF8)
                            $entries = @($lines | Where-Object { $_.Trim() } | ForEach-Object {
                                try { ConvertFrom-Json $_ } catch { $null }
                            } | Where-Object { $_ })
                            $json = if ($entries.Count) {
                                '[' + (($entries | ForEach-Object { ConvertTo-Json $_ -Depth 3 -Compress }) -join ',') + ']'
                            } else { '[]' }
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
                    $msgs = @(Get-ServerMessages 50)
                    $out  = if ($msgs.Count) { ConvertTo-Json $msgs -Depth 4 -Compress } else { '[]' }
                    # ConvertTo-Json unwraps a single-element array; force the [ ] back.
                    if ($msgs.Count -eq 1) { $out = '[' + (ConvertTo-Json $msgs[0] -Depth 4 -Compress) + ']' }
                    Send-Response $res 200 "application/json" $out
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
                        $rawJson = & python "$ServerDir\pal_save_reader.py" $saveDir 2>$null
                        if ($LASTEXITCODE -ne 0 -or -not $rawJson) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                        $data = ($rawJson -join '') | ConvertFrom-Json
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
                        if ($guidParam) {
                            $rawJson = & python "$ServerDir\pal_team_reader.py" $saveDir locations $guidParam 2>$null
                        } else {
                            $rawJson = & python "$ServerDir\pal_team_reader.py" $saveDir locations 2>$null
                        }
                        if ($LASTEXITCODE -ne 0 -or -not $rawJson) { throw "pal_team_reader.py failed (exit $LASTEXITCODE)" }
                        $data = ($rawJson -join '') | ConvertFrom-Json

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
                        $rawJson = & python "$ServerDir\pal_team_reader.py" $saveDir 2>$null
                        if ($LASTEXITCODE -ne 0 -or -not $rawJson) { throw "pal_team_reader.py failed (exit $LASTEXITCODE)" }
                        $data = ($rawJson -join '') | ConvertFrom-Json

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
                        $rawJson = & python "$ServerDir\pal_egg_reader.py" $saveDir 2>$null
                        if ($LASTEXITCODE -ne 0 -or -not $rawJson) { throw "pal_egg_reader.py failed (exit $LASTEXITCODE)" }
                        $data = ($rawJson -join '') | ConvertFrom-Json

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
                        if (-not $script:effigyData) {
                            # Prefer the LOCAL copy (python gen_pal_assets.py); only fall
                            # back to GitHub if it is missing, so the tracker keeps working
                            # offline / if the upstream repo changes.
                            $localEffigies = "$ServerDir\effigies.json"
                            if (Test-Path -LiteralPath $localEffigies) {
                                $raw = [System.IO.File]::ReadAllText($localEffigies)
                            } else {
                                $wc = New-Object System.Net.WebClient
                                $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
                                $raw = $wc.DownloadString(
                                    'https://raw.githubusercontent.com/oMaN-Rod/palworld-save-pal/main/data/json/effigies.json')
                            }
                            # Overlay Anthony's own live-play-confirmed coordinates on top of
                            # the public/upstream data -- see Merge-ConfirmedEffigies above.
                            $script:effigyData = Merge-ConfirmedEffigies $raw
                        }
                        Send-Response $res 200 "application/json" $script:effigyData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/journals' -and $method -eq 'GET') {
                    # Static lore-journal/diary locations (game-world fixed, not per-save),
                    # sourced from wiki-published in-game X/Y and converted to real world
                    # coords with the same formula the effigy tooltip uses in reverse
                    # (cx=(y-158000)/459, cy=(x+123888)/459). The public site bundles this
                    # as a static file; here we serve it from the same JSON so both match.
                    try {
                        if (-not $script:journalData) {
                            $f = "$ServerDir\journal_locations.json"
                            if (Test-Path -LiteralPath $f) {
                                $raw = [System.IO.File]::ReadAllText($f)
                            } else {
                                $raw = '[]'
                            }
                            # Overlay Anthony's own live-play-confirmed coordinates/names on
                            # top of the wiki-sourced base data -- see Merge-ConfirmedJournals.
                            $script:journalData = Merge-ConfirmedJournals $raw
                        }
                        Send-Response $res 200 "application/json" $script:journalData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/bounty-bosses' -and $method -eq 'GET') {
                    # Static bounty-boss (named legendary Alpha) locations, sourced from
                    # paldb's DT_PaldexDistributionData BOSS_<Species> entries with exactly
                    # one fixed world location (see bounty_bosses.json). The public site
                    # bundles this as a static file; here we serve it from the same JSON so
                    # both dashboards match.
                    try {
                        if (-not $script:bountyBossData) {
                            $f = "$ServerDir\bounty_bosses.json"
                            if (Test-Path -LiteralPath $f) {
                                $raw = [System.IO.File]::ReadAllText($f)
                            } else {
                                $raw = '[]'
                            }
                            # Overlay Anthony's own live-play-confirmed coordinates/names on
                            # top of the paldb-sourced base data -- see Merge-ConfirmedBounty.
                            $script:bountyBossData = Merge-ConfirmedBounty $raw
                        }
                        Send-Response $res 200 "application/json" $script:bountyBossData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/wanted-fugitives' -and $method -eq 'GET') {
                    # Anthony's own confirmed locations for NPC/Syndicate "boss" defeat-flag
                    # keys (see Get-ConfirmedWantedFugitives above) -- static named pins, no
                    # public/wiki-sourced base data exists for these at all.
                    try {
                        if (-not $script:wantedFugitiveData) {
                            $script:wantedFugitiveData = Get-ConfirmedWantedFugitives
                        }
                        Send-Response $res 200 "application/json" $script:wantedFugitiveData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/eagle-statues' -and $method -eq 'GET') {
                    # Anthony's own confirmed fast-travel point locations (see
                    # Get-ConfirmedEagleStatues above) -- static named pins, no public/wiki
                    # base data exists for these at all.
                    try {
                        if (-not $script:eagleStatueData) {
                            $script:eagleStatueData = Get-ConfirmedEagleStatues
                        }
                        Send-Response $res 200 "application/json" $script:eagleStatueData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/npcs' -and $method -eq 'GET') {
                    # Anthony's own confirmed NPC locations (see Get-ConfirmedNPCs above) --
                    # static named pins; per-player found state comes from a separate route,
                    # /api/player-npcs?guid=, below.
                    try {
                        if (-not $script:npcData) {
                            $script:npcData = Get-ConfirmedNPCs
                        }
                        Send-Response $res 200 "application/json" $script:npcData
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/landmarks' -and $method -eq 'GET') {
                    # Anthony's own confirmed locations that aren't an effigy, journal note,
                    # bounty boss, Wanted Fugitive, Eagle Statue, or NPC -- discovered areas
                    # etc. -- see Get-ConfirmedLandmarks above.
                    try {
                        if (-not $script:landmarkData) {
                            $script:landmarkData = Get-ConfirmedLandmarks
                        }
                        Send-Response $res 200 "application/json" $script:landmarkData
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
                    # here we serve it from the same JSON so both dashboards match.
                    try {
                        if (-not $script:palSpeciesData) {
                            $f = "$ServerDir\pal_species.json"
                            if (Test-Path -LiteralPath $f) {
                                $script:palSpeciesData = [System.IO.File]::ReadAllText($f)
                            } else {
                                $script:palSpeciesData = '{}'
                            }
                        }
                        Send-Response $res 200 "application/json" $script:palSpeciesData
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
                        $rawJson = & python "$ServerDir\pal_save_reader.py" $saveDir effigies $guid 2>$null
                        if ($LASTEXITCODE -ne 0 -or -not $rawJson) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                        Send-Response $res 200 "application/json" ($rawJson -join '')
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
                        $rawJson = & python "$ServerDir\pal_save_reader.py" $saveDir notes $guid 2>$null
                        if ($LASTEXITCODE -ne 0 -or -not $rawJson) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                        Send-Response $res 200 "application/json" ($rawJson -join '')
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
                        $rawJson = & python "$ServerDir\pal_save_reader.py" $saveDir bounties $guid 2>$null
                        if ($LASTEXITCODE -ne 0 -or -not $rawJson) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                        Send-Response $res 200 "application/json" ($rawJson -join '')
                    } catch {
                        Send-Response $res 500 "application/json" (ConvertTo-Json @{ error=$_.Exception.Message } -Compress)
                    }
                    break
                }

                ($path -eq '/api/player-npcs' -and $method -eq 'GET') {
                    # NPC talked-to state, read from NPCTalkCountMap in the player's save (a
                    # Name->Int count map, not a Name->Bool flag like effigies/journals/bounty
                    # -- see extract_npc_data in pal_save_reader.py, "collected" means count>0).
                    try {
                        $guid = $req.QueryString['guid']
                        if (-not $guid) { throw "Missing guid parameter" }
                        $activeGuid = Get-ActiveGuid
                        if (-not $activeGuid) { throw "No active world loaded" }
                        $saveDir = Join-Path $SaveGamesRoot $activeGuid
                        $rawJson = & python "$ServerDir\pal_save_reader.py" $saveDir npcs $guid 2>$null
                        if ($LASTEXITCODE -ne 0 -or -not $rawJson) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                        Send-Response $res 200 "application/json" ($rawJson -join '')
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
                        $rawJson = & python "$ServerDir\pal_save_reader.py" $saveDir datamine $guid 2>$null
                        if ($LASTEXITCODE -ne 0 -or -not $rawJson) { throw "pal_save_reader.py failed (exit $LASTEXITCODE)" }
                        Send-Response $res 200 "application/json" ($rawJson -join '')
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
