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

# Shared upsert used by import_scraped_rosters.ps1's six importers. $confirmedRef is a
# [ref] to the caller's array (PowerShell arrays can't grow in place, so an insert has to
# reassign through the ref). $matched is the existing entry found by the caller's own
# identity rule (key for effigy/journal, species for bounty, name/coord for
# tower/fugitive/eagle), or $null if this is a brand-new roster row. $fields is a
# hashtable of the roster's own data for this row.
#
# Upsert rule (never touches name/gx/gy/key on an EXISTING row, regardless of verified --
# those are Anthony's own domain, either hand-typed or resolved by the Desktop dataminer
# script; a scrape only ever supplies x/y/z/lv/species):
#   - matched, verified:true  -> fill x/y/z/lv/species ONLY where currently null
#   - matched, verified:false -> refresh x/y/z/lv always; refresh name only if the row has
#     no name yet or its origin is already "scraped" (never overwrite a live/manual name)
#   - no match -> insert a new row: category stamped, origin "scraped", verified false
# Add-Member -Force works whether $name is already a property (overwrites its value) or
# not (creates it) -- unlike plain dot-notation assignment, which THROWS if the property
# doesn't exist yet (confirmed_locations.json rows created before this schema had x/y/z/
# species/lv literally don't have those properties at all until something adds them).
function Set-EntryProp($obj, [string]$name, $value) {
    $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
}

function Update-CanonicalEntry([ref]$confirmedRef, $matched, [string]$category, [hashtable]$fields) {
    if ($matched) {
        if ($matched.verified -eq $true) {
            foreach ($k in $fields.Keys) {
                if ($k -in @('name', 'gx', 'gy', 'key')) { continue }
                $cur = if ($matched.PSObject.Properties[$k]) { $matched.$k } else { $null }
                if ($null -eq $cur -or $cur -eq '') { Set-EntryProp $matched $k $fields[$k] }
            }
            return 'matched-verified'
        } else {
            foreach ($k in @('x', 'y', 'z', 'lv')) {
                if ($fields.ContainsKey($k)) { Set-EntryProp $matched $k $fields[$k] }
            }
            if ($fields.ContainsKey('name') -and (-not $matched.name -or $matched.origin -eq 'scraped')) {
                Set-EntryProp $matched 'name' $fields['name']
            }
            return 'matched-unverified'
        }
    } else {
        $newEntry = [pscustomobject]@{
            key = $null; category = $category; name = $null; gx = $null; gy = $null
            x = $null; y = $null; z = $null; species = $null; lv = $null; source = $null
            origin = 'scraped'; verified = $false
        }
        foreach ($k in $fields.Keys) { Set-EntryProp $newEntry $k $fields[$k] }
        $confirmedRef.Value += $newEntry
        return 'inserted'
    }
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

# Real world x/y -> gx/gy (in-game grid coords). Inverse of ConvertTo-WorldXY above -- used
# by the scraped-roster importers (import_scraped_rosters.ps1) to derive gx/gy for a
# roster that only ships raw world x/y (e.g. effigies.json), so a brand-new inserted row
# still has grid coords for anything that displays them. Rounds to the nearest integer
# rather than truncating, since a scrape's x/y is rarely an exact multiple of the 459
# scale constant.
function ConvertTo-GridXY([double]$x, [double]$y) {
    $mc = Get-MapConstants
    return @{ gx = [Math]::Round(($y - $mc.offsetY) / $mc.scale); gy = [Math]::Round(($x + $mc.offsetX) / $mc.scale) }
}

# Serves every map category from confirmed_locations.json directly -- Phase 3's importer
# (import_scraped_rosters.ps1) already upserted every scraped roster row into the
# canonical store as verified:false, so there is no separate roster file left to overlay
# at request time the way Merge-ConfirmedEffigies/Journals/etc. used to. `m` = verified.
# Coordinate precedence: the store's own x/y (scraped precision, or Anthony's own
# hand-entered value once Phase 5-that-never-shipped or a future dashboard edit sets it)
# when present, else derived from gx/gy -- gx/gy-only entries are exactly the ones Phase 3
# never touched, which predate x/y existing on any row at all.
#
# Effigies alone keep their historical DICT shape (GUID -> {x,y,z,m}), matched by
# dashboard.html's effigyLocations[key] lookups -- every other category is an array of
# {name,x,y,key,m}, plus "species" for bounty and "lv" for tower/fugitive.
function Get-MapCategoryJson([string]$category) {
    $confirmed = Get-ConfirmedLocations
    if ($category -eq 'effigy') {
        $result = [ordered]@{}
        foreach ($c in $confirmed) {
            if ($c.category -ne 'effigy' -or -not $c.key) { continue }
            $entry = @{ x = $c.x; y = $c.y; z = $c.z }
            if ($c.verified -eq $true) { $entry.m = $true }
            $result[$c.key] = $entry
        }
        return (ConvertTo-Json -InputObject $result -Depth 6 -Compress)
    }
    $result = @()
    foreach ($c in $confirmed) {
        if ($c.category -ne $category) { continue }
        $hasXY = ($null -ne $c.x -and $null -ne $c.y)
        $xy = if ($hasXY) { @{ x = $c.x; y = $c.y } } else { ConvertTo-WorldXY $c.gx $c.gy }
        $name = if ($c.name) { $c.name } else { $c.key }
        $out = @{ name = $name; x = $xy.x; y = $xy.y; m = ($c.verified -eq $true) }
        if ($c.key) { $out.key = $c.key }
        if ($category -eq 'bounty') { $out.species = if ($c.species) { $c.species } else { $c.key } }
        if ($c.PSObject.Properties['lv'] -and $null -ne $c.lv) { $out.lv = $c.lv }
        if ($category -eq 'journal') {
            # Journal is the one category whose client tooltip (buildJournalMarker) and Data
            # Mine tab roster-fallback (getGxGy) read gx/gy straight off the roster item
            # instead of deriving it from x/y client-side -- keep emitting it to match.
            if ($null -ne $c.gx -and $null -ne $c.gy) { $out.gx = $c.gx; $out.gy = $c.gy }
            else { $grid = ConvertTo-GridXY $xy.x $xy.y; $out.gx = $grid.gx; $out.gy = $grid.gy }
        }
        $result += $out
    }
    return (ConvertTo-Json -InputObject @($result) -Depth 6)
}

# The one write path behind every POST .../*-confirm route (and the new consolidated
# /api/map-confirm) -- resolves a confirmed_locations.json row by the category-appropriate
# identity the client already displays for that pin (key for effigy/journal, species for
# bounty, name for tower/fugitive/eagle) and flips
# its "verified" flag. Since Get-MapCategoryJson above always emits the STORE's own
# name/species/key (never a blended roster value), whatever identity the client echoes
# back on toggle is guaranteed to match a row here exactly -- no fuzzy matching needed on
# the write side at all, unlike the read-side importer.
function Set-MapConfirmVerified([string]$category, [string]$key, [string]$species, [string]$name, [bool]$verified) {
    $confirmed = Get-ConfirmedLocations
    $matched = $null
    if ($key) {
        $keyU = $key.ToUpper()
        $matched = $confirmed | Where-Object { $_.key -and $_.key.ToUpper() -eq $keyU -and $_.category -eq $category } | Select-Object -First 1
    } elseif ($species) {
        $spU = $species.ToUpper()
        $matched = $confirmed | Where-Object { $_.species -and $_.species.ToUpper() -eq $spU -and $_.category -eq $category } | Select-Object -First 1
        if (-not $matched) {
            # Self-named species (BlueDragon/FairyDragon) or one resolved only via
            # anonymous_boss_keys.json store their identity in "key", not "species" --
            # same fallback the old Merge-ConfirmedBounty always needed.
            $anonMap = Get-AnonymousBossKeyMap
            $reverseAnon = @{}
            foreach ($ak in $anonMap.Keys) { $reverseAnon[$anonMap[$ak].ToUpper()] = $ak }
            if ($reverseAnon.ContainsKey($spU)) {
                $rk = $reverseAnon[$spU].ToUpper()
                $matched = $confirmed | Where-Object { $_.key -and $_.key.ToUpper() -eq $rk -and $_.category -eq $category } | Select-Object -First 1
            }
            if (-not $matched) {
                $matched = $confirmed | Where-Object { $_.key -and $_.key.ToUpper() -eq $spU -and $_.category -eq $category } | Select-Object -First 1
            }
        }
    } elseif ($name) {
        $nameU = $name.ToUpper()
        $matched = $confirmed | Where-Object { $_.name -and $_.name.ToUpper() -eq $nameU -and $_.category -eq $category } | Select-Object -First 1
    }
    if (-not $matched) { return $false }
    Set-EntryProp $matched 'verified' $verified
    Save-ConfirmedLocations $confirmed
    return $true
}

# Resolve a confirmed key to a bounty species via anonymous_boss_keys.json (the world
# map is fixed, so a confirmed key/species pair holds for every save -- see the
# palbox-bounty-tracker skill) plus literal species-named keys (BlueDragon/FairyDragon,
# the two that self-name-tag in the save). Used by Get-CategoryForEntry's bounty
# roster-membership fallback above.
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

# Classifies a confirmed_locations.json entry into one of the 6 map categories: tower
# name match first (paldb's Tower scrape has no save-flag key of its own), then the
# entry's own "source" field, then roster-membership fallback for legacy entries that
# predate "source". Originally migrate_map_schema.ps1's own private copy (used there for
# the one-time bulk backfill); moved here so PalWorldServerManager.ps1's Data Mine tab
# write endpoints (/api/datamine-mapping, /api/datamine-mapping-batch) can stamp a
# category on a freshly-typed-in entry immediately, instead of it sitting
# uncategorized -- and therefore invisible to Get-MapCategoryJson -- until the next
# manual re-run of the migration script.
#
# Returns $null (genuinely uncategorized) if nothing matches -- NPC and Landmark were
# retired as map categories (2026-07-07, Anthony's call: Landmark existed only as a
# catch-all fallback here and was never meant to hold real data going forward) rather
# than silently bucketing an unrecognized entry into a fake category again.
function Get-CategoryForEntry($c) {
    $towerNames = Get-TowerNameSet
    if ($c.name -and $towerNames.Contains($c.name.ToUpper())) { return 'tower' }
    switch ($c.source) {
        'RelicObtainForInstanceFlag' { return 'effigy' }
        'NoteObtainForInstanceFlag' { return 'journal' }
        'FastTravelPointUnlockFlag' { return 'eagle' }
        'NormalBossDefeatFlag' { if ($c.key -and (Test-SyndicateKeyShape $c.key)) { return 'fugitive' } else { return 'bounty' } }
    }
    if ($c.key) {
        $k = $c.key.ToUpper()
        $effFile = "$script:MapDataRoot\effigies.json"
        if (Test-Path -LiteralPath $effFile) {
            $effObj = Get-Content -LiteralPath $effFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $effObj.PSObject.Properties) { if ($p.Name.ToUpper() -eq $k) { return 'effigy' } }
        }
        $journalFile = "$script:MapDataRoot\journal_locations.json"
        if (Test-Path -LiteralPath $journalFile) {
            foreach ($e in (Get-Content -LiteralPath $journalFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key -and $e.key.ToUpper() -eq $k) { return 'journal' }
            }
        }
        $synFile = "$script:MapDataRoot\syndicate_bosses.json"
        if (Test-Path -LiteralPath $synFile) {
            foreach ($e in (Get-Content -LiteralPath $synFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key -and $e.key.ToUpper() -eq $k) { return 'fugitive' }
            }
        }
        $ftFile = "$script:MapDataRoot\fast_travel_keys.json"
        if (Test-Path -LiteralPath $ftFile) {
            foreach ($e in (Get-Content -LiteralPath $ftFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key -and $e.key.ToUpper() -eq $k) { return 'eagle' }
            }
        }
        $anonFile = "$script:MapDataRoot\anonymous_boss_keys.json"
        if (Test-Path -LiteralPath $anonFile) {
            foreach ($e in (Get-Content -LiteralPath $anonFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($e.key -and $e.key.ToUpper() -eq $k) { return 'bounty' }
            }
        }
    }
    return $null
}
