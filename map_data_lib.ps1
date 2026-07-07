# map_data_lib.ps1
# Shared map-location data layer, dot-sourced by BOTH PalWorldServerManager.ps1 (the
# live admin dashboard) and build_public_data.ps1 (the public-site batch builder).
# Extracted 2026-07-06 from two hand-kept, drifted-only-in-path-and-caching copies --
# see the palbox-confirmed-locations skill for the full history of why each of these
# functions exists. Call Initialize-MapDataLib -Root <dir> once before using anything
# else in this file.
#
# ── Hand-confirmed map locations (Anthony's own live-play data) ──────────────
# confirmed_locations.json holds flag-key -> {name,gx,gy} entries Anthony has
# personally verified in-game via a companion save-watching script (Desktop
# DataMine\palworld_full_save_dump.py, see the palworld-project skill). These
# are the source of truth wherever they overlap a key in effigies.json /
# journal_locations.json / bounty_bosses.json, which were sourced from a
# public GitHub dataset or third-party wiki guides -- see Merge-Confirmed*
# below, applied inside the /api/effigies, /api/journals, and
# /api/bounty-bosses handlers.

function Initialize-MapDataLib([string]$Root) {
    $script:MapDataRoot = $Root
    $script:confirmedLocations = $null
    $script:confirmedLocationsMtime = $null
    $script:mapConstCache = $null
}

function Get-ConfirmedLocations {
    $f = "$script:MapDataRoot\confirmed_locations.json"
    # Re-read whenever the file's mtime has moved on from what we last loaded, so
    # edits from the companion save-watching script (palworld-dataminer) show up on
    # the next API poll instead of requiring a Manager restart.
    $mtime = if (Test-Path -LiteralPath $f) { (Get-Item -LiteralPath $f).LastWriteTimeUtc } else { $null }
    if ($null -eq $script:confirmedLocations -or $mtime -ne $script:confirmedLocationsMtime) {
        if ($null -ne $mtime) {
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
        $script:confirmedLocationsMtime = $mtime
    }
    return $script:confirmedLocations
}

# BOM-free canonical writer, added for the schema-migration/importer phases that follow
# Phase 1 -- not yet called by anything in this commit. [System.IO.File]::WriteAllText
# with a no-BOM UTF8Encoding matches the fix applied to confirmed_locations.json writes
# elsewhere (commit a16801c) so a BOM never creeps back into this file.
function Save-ConfirmedLocations($arr) {
    $f = "$script:MapDataRoot\confirmed_locations.json"
    $json = ConvertTo-Json -InputObject @($arr) -Depth 6
    [System.IO.File]::WriteAllText($f, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:confirmedLocations = $arr
    $script:confirmedLocationsMtime = (Get-Item -LiteralPath $f).LastWriteTimeUtc
}

# gx/gy (in-game grid coords) <-> real world x/y transform constants -- single source
# of truth in map_constants.json (also read by build_public_data.ps1's own copy of
# ConvertTo-WorldXY) so the two can't drift apart the way individual map categories
# already have in the past (Chillet/WeaselDragon, Landmarks misclassification bugs).
function Get-MapConstants {
    if ($null -eq $script:mapConstCache) {
        $path = "$script:MapDataRoot\map_constants.json"
        try { $script:mapConstCache = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
        catch { $script:mapConstCache = [pscustomobject]@{ scale = 459; offsetX = 123888; offsetY = 158000 } }
    }
    return $script:mapConstCache
}

# gx/gy (in-game grid coords) -> real world x/y. Inverse of the effigy tooltip's
# cx=(y-offsetY)/scale, cy=(x+offsetX)/scale -- see the palbox-journal-overlay skill's
# coordinate-transform section.
function ConvertTo-WorldXY([int]$gx, [int]$gy) {
    $mc = Get-MapConstants
    return @{ x = ($gy * $mc.scale) - $mc.offsetX; y = ($gx * $mc.scale) + $mc.offsetY }
}

# Keys/species Anthony has manually clicked "Confirm" on in a dashboard marker popup (see
# EFFIGY_CONFIRM_ENABLED / toggleEffigyConfirm+toggleJournalConfirm+toggleBountyConfirm in
# dashboard.html and the /api/effigy-confirm, /api/journal-confirm, /api/bounty-confirm
# routes below). Each kept in its OWN file rather than confirmed_locations.json, which
# stays owned exclusively by the Desktop dataminer script -- picking something up/
# defeating it in-game doesn't prove the scraped coordinate is right, so this is a
# separate, purely UI-driven confirmation signal. Read fresh every call, same convention
# as the other small roster files (anonymous_boss_keys.json etc.) -- no caching needed for
# files this size.
function Get-ManualConfirmSet([string]$fileName) {
    $keys = @{}
    $f = "$script:MapDataRoot\$fileName"
    if (Test-Path -LiteralPath $f) {
        try {
            # No @() wrap around the ConvertFrom-Json pipe -- see the critical PS 5.1
            # gotcha documented on Get-ConfirmedLocations/Merge-ConfirmedJournals above.
            $arr = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $arr) { $arr = @() }
            if ($arr -is [string]) { $arr = @($arr) }
            foreach ($k in $arr) { if ($k) { $keys[$k.ToUpper()] = $true } }
        } catch {}
    }
    return $keys
}
function Get-EffigyConfirmedKeys { return Get-ManualConfirmSet 'effigy_confirmed_keys.json' }
function Get-JournalConfirmedKeys { return Get-ManualConfirmSet 'journal_confirmed_keys.json' }
function Get-BountyConfirmedSpecies { return Get-ManualConfirmSet 'bounty_confirmed_species.json' }
function Get-TowerConfirmedNames { return Get-ManualConfirmSet 'tower_confirmed_keys.json' }
function Get-FugitiveConfirmedNames { return Get-ManualConfirmSet 'fugitive_confirmed_keys.json' }
function Get-EagleConfirmedNames { return Get-ManualConfirmSet 'eagle_confirmed_keys.json' }

# Anthony wants ONLY his own confirmed locations on the map for Journals/Bounty -- those
# Merge-Confirmed* functions FILTER the base public/wiki-sourced data down to matches only
# (not overlay onto the full set). Effigies is the one exception (reverted 2026-07-05):
# Anthony asked for the full scraped roster back so he can see grey/unconfirmed effigies
# he hasn't logged yet, just tagged with whether he's manually confirmed each one -- so
# this one function OVERLAYS instead of filtering, using the scraped x/y/z as-is (more
# accurate than the gx/gy round-trip) and adding an `m:true` flag for an exact GUID-key
# match against EITHER confirmed_locations.json (the Desktop script) OR
# effigy_confirmed_keys.json (a manual dashboard click). NOTE: build with -InputObject
# rather than piping into ConvertTo-Json -- piping a PowerShell array with exactly one
# element unwraps it into a bare JSON object instead of a 1-item array (confirmed via
# direct test), which would break the client's .forEach() the moment a filtered list
# happens to have one entry.
function Merge-ConfirmedEffigies([string]$json) {
    $confirmed = Get-ConfirmedLocations
    $manualKeys = @{}
    # verified:false means dmAutoFillFromRosters auto-persisted this as a candidate
    # location (see dashboard.html), not a real confirmation -- must not count as m:true.
    foreach ($c in $confirmed) { if ($c.key -and $c.verified -ne $false) { $manualKeys[$c.key.ToUpper()] = $true } }
    foreach ($k in (Get-EffigyConfirmedKeys).Keys) { $manualKeys[$k] = $true }
    try { $obj = $json | ConvertFrom-Json } catch { $obj = $null }
    $result = [ordered]@{}
    if ($obj) {
        foreach ($p in $obj.PSObject.Properties) {
            $entry = @{ x = $p.Value.x; y = $p.Value.y; z = $p.Value.z }
            if ($manualKeys.ContainsKey($p.Name.ToUpper())) { $entry.m = $true }
            $result[$p.Name] = $entry
        }
    }
    return (ConvertTo-Json -InputObject $result -Depth 6 -Compress)
}

# OVERLAYS the full wiki-sourced journal_locations.json roster (reverted 2026-07-05,
# matching the Effigies precedent above) instead of filtering to confirmed-only --
# Anthony wants every scraped journal visible with a red/yellow/green status (see
# renderEffigyMap's journal block) instead of only seeing ones he's personally logged.
# `m:true` marks an exact key match against confirmed_locations.json (Anthony's script is
# still the source of truth for name/coordinates when a match exists -- wiki data is
# overridden, not the scraped x/y kept as-is like effigies, since journal_locations.json
# is less trustworthy than his own hands-on confirmation) OR a manual dashboard-popup
# confirm (journal_confirmed_keys.json, see Get-JournalConfirmedKeys/toggleJournalConfirm)
# -- a manual click doesn't have a gx/gy to override coordinates with, so it only flips
# the flag, same as effigies' manual confirm.
function Merge-ConfirmedJournals([string]$json) {
    $confirmed = Get-ConfirmedLocations
    # No @() wrap -- see the note on Get-ConfirmedLocations above.
    try { $arr = $json | ConvertFrom-Json } catch { $arr = @() }
    if ($null -eq $arr) { $arr = @() }
    $byKey = @{}
    # verified:false means dmAutoFillFromRosters auto-persisted this as a candidate
    # location (see dashboard.html), not a real confirmation -- must not count as m:true.
    foreach ($c in $confirmed) { if ($c.key -and $c.verified -ne $false) { $byKey[$c.key.ToUpper()] = $c } }
    $manualKeys = Get-JournalConfirmedKeys
    $result = @()
    foreach ($entry in $arr) {
        $out = @{ name = $entry.name; x = $entry.x; y = $entry.y; gx = $entry.gx; gy = $entry.gy; key = $entry.key }
        $c = if ($entry.key) { $byKey[$entry.key.ToUpper()] } else { $null }
        if ($c) {
            $xy = ConvertTo-WorldXY $c.gx $c.gy
            $out.x = $xy.x
            $out.y = $xy.y
            $out.gx = $c.gx
            $out.gy = $c.gy
            if ($c.name) { $out.name = $c.name }
            $out.m = $true
        } elseif ($entry.key -and $manualKeys.ContainsKey($entry.key.ToUpper())) {
            $out.m = $true
        }
        $result += $out
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
    $anonFile = "$script:MapDataRoot\anonymous_boss_keys.json"
    if (Test-Path -LiteralPath $anonFile) {
        try {
            foreach ($e in (Get-Content -LiteralPath $anonFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key -and $e.species) { $anonMap[$e.key.ToUpper()] = $e.species }
            }
        } catch {}
    }
    return $anonMap
}

# Human/Syndicate boss keys (syndicate_bosses.json, e.g. BOSS_MALE_SOLDIER02) never
# carry a zone-number prefix, unlike Field Boss species keys (e.g.
# "81_2_DESSERT_FBOSS_3") -- used below to tell the two apart from key shape alone
# when a NormalBossDefeatFlag-sourced confirmed entry hasn't been added to either
# roster yet.
function Test-SyndicateKeyShape([string]$key) { return $key -match '^BOSS_' }

# Towers (towers.json, 7 raid-boss tower locations scraped from paldb.cc, added
# 2026-07-06) were previously confirmed by Anthony under the Eagle Statue bucket, since
# walking up to one behaves like a fast-travel point in his own mental model.
# Merge-ConfirmedWantedFugitives/EagleStatues below explicitly exclude any confirmed
# entry whose name matches one of these 7 so it routes to Merge-ConfirmedTowers instead,
# splitting the two apart. Read fresh every call, same convention as the other small
# roster files.
function Get-TowerNameSet {
    $names = New-Object System.Collections.Generic.HashSet[string]
    $f = "$script:MapDataRoot\towers.json"
    if (Test-Path -LiteralPath $f) {
        try {
            foreach ($e in (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.name) { [void]$names.Add($e.name.ToUpper()) }
            }
        } catch {}
    }
    return $names
}

# Shared matcher for the three paldb-name-only roster overlays below (Tower/Wanted
# Fugitive/Eagle Statue). Unlike Journals (matched by a stable "key") or Bounty (matched
# by species), paldb's own scrape carries no save-flag key or species id at all -- only a
# display name + gx/gy -- so a confirmed_locations.json entry can only line up by exact
# name (primary; most confirmed entries for these categories DO have a name recorded), a
# short-callsign suffix match (added 2026-07-06: Anthony's own confirmed Wanted Fugitive
# entries are recorded under the short in-game callsign alone, e.g. "Aloha", "Dyna",
# "Cache" -- while the paldb roster's display name is the FULL title, e.g. "Pineapple
# Pizza Enthusiast Aloha", "Twin Bombers Dyna", "Human Collector Cache". A confirmed entry
# whose short name is the roster name's final word, on a word boundary, counts as a match),
# or close gx/gy proximity (fallback, for an entry with no name set yet).
function Find-ConfirmedByNameOrCoord($rosterEntry, $candidates) {
    $nameU = if ($rosterEntry.name) { $rosterEntry.name.ToUpper() } else { $null }
    foreach ($c in $candidates) {
        if ($nameU -and $c.name -and $c.name.ToUpper() -eq $nameU) { return $c }
    }
    foreach ($c in $candidates) {
        if ($nameU -and $c.name -and $nameU.EndsWith(' ' + $c.name.ToUpper())) { return $c }
    }
    foreach ($c in $candidates) {
        if (-not $c.name -and [Math]::Abs($c.gx - $rosterEntry.gx) -le 3 -and [Math]::Abs($c.gy - $rosterEntry.gy) -le 3) { return $c }
    }
    return $null
}

# OVERLAYS the 7-entry paldb-scraped towers.json roster (added 2026-07-06). See
# Get-TowerNameSet above for why this needed splitting out of Eagle Statues. `m:true`
# marks a name/coord match against confirmed_locations.json OR a manual dashboard-popup
# confirm (tower_confirmed_keys.json, see Get-TowerConfirmedNames/toggleTowerConfirm). No
# per-player "cleared" signal exists yet for raid towers, so status can only reach
# confirmed (yellow) or unconfirmed (red) until that's built -- never found (green).
function Merge-ConfirmedTowers([string]$json) {
    $confirmed = Get-ConfirmedLocations
    try { $arr = $json | ConvertFrom-Json } catch { $arr = @() }
    if ($null -eq $arr) { $arr = @() }
    $manualNames = Get-TowerConfirmedNames
    $result = @()
    foreach ($entry in $arr) {
        $out = @{ name = $entry.name; x = $entry.x; y = $entry.y; lv = $entry.lv }
        $c = Find-ConfirmedByNameOrCoord $entry $confirmed
        if ($c) {
            $xy = ConvertTo-WorldXY $c.gx $c.gy
            $out.x = $xy.x
            $out.y = $xy.y
            if ($c.name) { $out.name = $c.name }
            $out.key = $c.key
            $out.m = $true
        } elseif ($entry.name -and $manualNames.ContainsKey($entry.name.ToUpper())) {
            $out.m = $true
        }
        $result += $out
    }
    return (ConvertTo-Json -InputObject @($result) -Depth 6)
}

# OVERLAYS the full paldb-scraped bounty_bosses.json roster (reverted 2026-07-05, same
# reasoning as Merge-ConfirmedJournals above) instead of filtering to confirmed-only --
# every known Alpha now shows with a red/yellow/green status. `m:true` marks a species
# match against confirmed_locations.json (via Get-AnonymousBossKeyMap); when matched, the
# confirmed entry's own gx/gy (more trustworthy than paldb) overrides x/y and name, same
# override precedent as before. OR a manual dashboard-popup confirm
# (bounty_confirmed_species.json, see Get-BountyConfirmedSpecies/toggleBountyConfirm) --
# same as journals, a manual click only flips the flag, no coordinate override.
function Merge-ConfirmedBounty([string]$json) {
    $confirmed = Get-ConfirmedLocations
    # No @() wrap -- see the note on Get-ConfirmedLocations above.
    try { $arr = $json | ConvertFrom-Json } catch { $arr = @() }
    if ($null -eq $arr) { $arr = @() }
    $anonMap = Get-AnonymousBossKeyMap
    # Reverse of $anonMap (species -> raw NormalBossDefeatFlag key), so a roster entry can
    # show the actual save-data key it's linked to even when it hasn't also been hand-
    # confirmed via confirmed_locations.json. Species self-name-tagged in the save (e.g.
    # BlueDragon/FairyDragon, matched by suffix rather than an anonymous-key entry -- see
    # /palbox-bounty-tracker) have no single static key on file, so they fall through to
    # the confirmed-match key (if any) or the missing-key note client-side.
    $reverseAnon = @{}
    foreach ($k in $anonMap.Keys) { $reverseAnon[$anonMap[$k].ToUpper()] = $k }
    $bySpecies = @{}
    foreach ($c in $confirmed) {
        $species = $anonMap[$c.key.ToUpper()]
        if (-not $species) { $species = $c.key }
        $bySpecies[$species.ToUpper()] = $c
    }
    $manualSpecies = Get-BountyConfirmedSpecies
    $result = @()
    $claimedSpecies = New-Object System.Collections.Generic.HashSet[string]
    foreach ($entry in $arr) {
        if (-not $entry.species) { continue }
        $sp = $entry.species.ToUpper()
        $out = @{ species = $entry.species; name = $entry.name; x = $entry.x; y = $entry.y }
        $c = $bySpecies[$sp]
        if ($c) {
            $xy = ConvertTo-WorldXY $c.gx $c.gy
            $out.x = $xy.x
            $out.y = $xy.y
            if ($c.name) { $out.name = $c.name }
            $out.key = $c.key
            $out.m = $true
            [void]$claimedSpecies.Add($sp)
        } else {
            if ($reverseAnon.ContainsKey($sp)) { $out.key = $reverseAnon[$sp] }
            if ($manualSpecies.ContainsKey($sp)) { $out.m = $true }
        }
        $result += $out
    }
    foreach ($c in $confirmed) {
        # Anthony's dataminer script already told us (via confirmed_locations.json's
        # "source" field) that this key is a NormalBossDefeatFlag hit, and its shape says
        # Field Boss, not Wanted Fugitive -- show it now from his own confirmed
        # name/coords rather than waiting on a manual anonymous_boss_keys.json edit, if it
        # isn't already covered by a bounty_bosses.json roster entry above.
        if ($c.source -ne 'NormalBossDefeatFlag' -or (Test-SyndicateKeyShape $c.key)) { continue }
        $species = $anonMap[$c.key.ToUpper()]
        if (-not $species) { $species = $c.key }
        if ($claimedSpecies.Contains($species.ToUpper())) { continue }
        $xy = ConvertTo-WorldXY $c.gx $c.gy
        $name = if ($c.name) { $c.name } else { $c.key }
        $result += @{ species = $c.key; name = $name; x = $xy.x; y = $xy.y; key = $c.key; m = $true }
    }
    return (ConvertTo-Json -InputObject @($result) -Depth 6)
}

# "Wanted Fugitive" -- OVERLAYS the 33-entry paldb-scraped wanted_fugitives.json roster
# (added 2026-07-06, replacing the old confirmed-only/no-base-roster version -- same
# revert-to-overlay precedent as Journals/Bounty on 2026-07-06). Excludes any confirmed
# entry whose name is a Tower (Get-TowerNameSet above) -- those route to
# Merge-ConfirmedTowers instead. Matched by name/gx-gy via Find-ConfirmedByNameOrCoord;
# `m:true` also from a manual dashboard-popup confirm (fugitive_confirmed_keys.json). The
# real save-flag key still comes through on a match (from the confirmed entry itself) so
# per-player defeat tracking (fugitiveCollected, see /api/player-fugitives) keeps working
# for anything Anthony has actually confirmed -- an unconfirmed roster pin has no known
# key, so it can never show "found" until he does.
function Merge-ConfirmedWantedFugitives([string]$json) {
    $confirmed = Get-ConfirmedLocations
    try { $arr = $json | ConvertFrom-Json } catch { $arr = @() }
    if ($null -eq $arr) { $arr = @() }
    $towerNames = Get-TowerNameSet
    $candidates = @($confirmed | Where-Object { -not ($_.name -and $towerNames.Contains($_.name.ToUpper())) })
    $manualNames = Get-FugitiveConfirmedNames
    $result = @()
    foreach ($entry in $arr) {
        $out = @{ name = $entry.name; x = $entry.x; y = $entry.y; lv = $entry.lv }
        $c = Find-ConfirmedByNameOrCoord $entry $candidates
        if ($c) {
            $xy = ConvertTo-WorldXY $c.gx $c.gy
            $out.x = $xy.x
            $out.y = $xy.y
            if ($c.name) { $out.name = $c.name }
            $out.key = $c.key
            $out.m = $true
        } elseif ($entry.name -and $manualNames.ContainsKey($entry.name.ToUpper())) {
            $out.m = $true
        }
        $result += $out
    }
    return (ConvertTo-Json -InputObject @($result) -Depth 6)
}

# "Eagle Statues" -- OVERLAYS the 83-entry paldb-scraped eagle_travel_locations.json
# roster (added 2026-07-06, replacing the old confirmed-only/no-base-roster version;
# paldb's own raw 89-entry Fast Travel list had 6 broken "en Text"/blank placeholder rows
# sitting exactly on Tower coordinates, filtered out when eagle_travel_locations.json was
# built). Same exclusion/matching/key-passthrough pattern as
# Merge-ConfirmedWantedFugitives above.
function Merge-ConfirmedEagleStatues([string]$json) {
    $confirmed = Get-ConfirmedLocations
    try { $arr = $json | ConvertFrom-Json } catch { $arr = @() }
    if ($null -eq $arr) { $arr = @() }
    $towerNames = Get-TowerNameSet
    $candidates = @($confirmed | Where-Object { -not ($_.name -and $towerNames.Contains($_.name.ToUpper())) })
    $manualNames = Get-EagleConfirmedNames
    $result = @()
    foreach ($entry in $arr) {
        $out = @{ name = $entry.name; x = $entry.x; y = $entry.y }
        $c = Find-ConfirmedByNameOrCoord $entry $candidates
        if ($c) {
            $xy = ConvertTo-WorldXY $c.gx $c.gy
            $out.x = $xy.x
            $out.y = $xy.y
            if ($c.name) { $out.name = $c.name }
            $out.key = $c.key
            $out.m = $true
        } elseif ($entry.name -and $manualNames.ContainsKey($entry.name.ToUpper())) {
            $out.m = $true
        }
        $result += $out
    }
    return (ConvertTo-Json -InputObject @($result) -Depth 6)
}

# "NPC" -- NPCTalkCountMap keys. Primary classifier is the "source" field (see
# Merge-ConfirmedBounty's comment above); npc_keys.json (a roster of confirmed NPC GUIDs,
# grown from real save data -- see pal_save_reader.py's extract_npc_data) is kept as a
# fallback for entries confirmed before "source" existed. Unlike Eagle Statues/Landmarks,
# this DOES get per-player tracking: /api/player-npcs (below) marks an NPC "found" once
# its key shows up in that player's own NPCTalkCountMap, same mechanism as
# effigies/journals/bounty.
function Get-ConfirmedNPCs {
    $confirmed = Get-ConfirmedLocations
    $roster = New-Object System.Collections.Generic.HashSet[string]
    $npcFile = "$script:MapDataRoot\npc_keys.json"
    if (Test-Path -LiteralPath $npcFile) {
        try {
            foreach ($e in (Get-Content -LiteralPath $npcFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key) { [void]$roster.Add($e.key.ToUpper()) }
            }
        } catch {}
    }
    $result = @()
    foreach ($c in $confirmed) {
        $isNpc = ($c.source -eq 'NPCTalkCountMap') -or $roster.Contains($c.key.ToUpper())
        if ($isNpc) {
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
    $effFile = "$script:MapDataRoot\effigies.json"
    if (Test-Path -LiteralPath $effFile) {
        try {
            $effObj = Get-Content -LiteralPath $effFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $effObj.PSObject.Properties) { [void]$claimed.Add($p.Name.ToUpper()) }
        } catch {}
    }
    $journalFile = "$script:MapDataRoot\journal_locations.json"
    if (Test-Path -LiteralPath $journalFile) {
        try {
            foreach ($e in (Get-Content -LiteralPath $journalFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
            }
        } catch {}
    }
    $anonMap = Get-AnonymousBossKeyMap
    $bountyFile = "$script:MapDataRoot\bounty_bosses.json"
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
    $synFile = "$script:MapDataRoot\syndicate_bosses.json"
    if (Test-Path -LiteralPath $synFile) {
        try {
            foreach ($e in (Get-Content -LiteralPath $synFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
            }
        } catch {}
    }
    $ftFile = "$script:MapDataRoot\fast_travel_keys.json"
    if (Test-Path -LiteralPath $ftFile) {
        try {
            foreach ($e in (Get-Content -LiteralPath $ftFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
            }
        } catch {}
    }
    $npcFile = "$script:MapDataRoot\npc_keys.json"
    if (Test-Path -LiteralPath $npcFile) {
        try {
            foreach ($e in (Get-Content -LiteralPath $npcFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
            }
        } catch {}
    }
    # Tower/Wanted Fugitive/Eagle Statue (added 2026-07-06) match confirmed entries by
    # NAME, not by a GUID-roster membership check like the blocks above -- claim by name
    # here too so a matched entry doesn't leak into Landmarks. See
    # Merge-ConfirmedTowers/WantedFugitives/EagleStatues.
    $namedRosterNames = New-Object System.Collections.Generic.HashSet[string]
    foreach ($rn in @('towers.json', 'wanted_fugitives.json', 'eagle_travel_locations.json')) {
        $rf = "$script:MapDataRoot\$rn"
        if (Test-Path -LiteralPath $rf) {
            try {
                foreach ($e in (Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    if ($e.name) { [void]$namedRosterNames.Add($e.name.ToUpper()) }
                }
            } catch {}
        }
    }
    foreach ($c in $confirmed) {
        if ($c.name -and $namedRosterNames.Contains($c.name.ToUpper())) { [void]$claimed.Add($c.key.ToUpper()) }
    }
    # Anthony's dataminer script stamps a "source" (raw save-flag name) on every newly
    # confirmed entry now -- trust it directly instead of waiting on a roster-file edit.
    # FastTravelPointUnlockFlag/NPCTalkCountMap always resolve into Eagle Statues/NPCs
    # above; NormalBossDefeatFlag always resolves into either Wanted Fugitive or Field
    # Boss above (species-matched or not -- Merge-ConfirmedBounty's fallback branch shows
    # it either way), so any of these three sources means it's claimed even before the
    # roster files above catch up. Only FindAreaFlagMap (genuine discovered-zone
    # landmarks) and entries with no "source" at all (pre-dating this field) fall through
    # to Landmarks below.
    foreach ($c in $confirmed) {
        if ($c.source -eq 'FastTravelPointUnlockFlag' -or $c.source -eq 'NPCTalkCountMap' -or
            $c.source -eq 'NormalBossDefeatFlag') {
            [void]$claimed.Add($c.key.ToUpper())
        }
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
