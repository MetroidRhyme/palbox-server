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

# BOM-free canonical writer for confirmed_locations.json -- the single writer that every
# map-confirm/add-icon/import/datamine route should funnel through, so the atomic-write
# guarantee below is applied uniformly no matter who is saving.
#
# Atomic temp-file + Move-Item swap (NOT a direct in-place WriteAllText): this file is
# re-read on every dashboard poll (Get-ConfirmedLocations' mtime check) AND by the Desktop
# palworld-dataminer script via plain Python json.load, so a concurrent reader must never
# see a half-written/truncated file. A direct WriteAllText here crashed the listener once
# already (2026-07-07); the singular /api/datamine-mapping route was hardened to temp+move
# at the time but this canonical helper (used by far more callers, incl. the batch auto-fill
# that writes 100+ entries) was left doing the unsafe in-place write. Move-Item -Force is an
# atomic rename on the same volume, so a reader sees either the whole old file or the whole
# new one. No-BOM UTF8Encoding keeps a BOM from creeping back in (Python json.load chokes
# on one).
function Save-ConfirmedLocations($arr) {
    $f = "$script:MapDataRoot\confirmed_locations.json"
    $json = ConvertTo-Json -InputObject @($arr) -Depth 6
    $tmp = "$f.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    # Atomic swap with brief retry. A same-volume rename means a concurrent reader always
    # sees the whole old OR whole new file, never a truncated one -- that is the property
    # we need (a truncate-in-place WriteAllText crashed the listener on 2026-07-07). But the
    # rename ITSELF fails (non-terminating: "Cannot create a file when that file already
    # exists") if a reader is holding the destination open at that instant, which would
    # otherwise leak the .tmp and, worse, let the cache below advance to data that never
    # reached disk. Readers here (dashboard polls, the Desktop Python dataminer, the sync
    # scripts) open/close in microseconds, so a few quick retries clear any collision.
    $moved = $false
    for ($i = 0; $i -lt 12 -and -not $moved; $i++) {
        try { Move-Item -LiteralPath $tmp -Destination $f -Force -ErrorAction Stop; $moved = $true }
        catch { Start-Sleep -Milliseconds 40 }
    }
    if (-not $moved) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "Save-ConfirmedLocations: could not replace $f after retries (held open by a reader)."
    }
    # Only advance the in-memory cache once the new data is actually on disk, so a failed
    # swap can never leave the cache describing a file that was never written.
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
            foreach ($k in @('x', 'y', 'z', 'lv', 'boss', 'bossPal', 'bossKey')) {
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
# {name,x,y,key,m}, plus "species" for bounty, "lv" for tower/fugitive, "boss"/"bossPal"
# for tower (the human raid-boss's name + their partner Pal's name, scraped from
# paldb.cc -- static display data only), and "bossKey" for tower (added 2026-07-07:
# the TowerBossDefeatFlag key for that tower's raid-boss fight, supplied by Anthony
# from a decoded save snippet -- normal difficulty only, hard-mode's key was lost in
# an earlier consolidation and hasn't been re-identified; null for Feybreak Tower,
# whose key hasn't been seen yet either). Tower now tracks TWO independent per-player
# signals: "key" (Eagle Statue / FastTravelPointUnlockFlag, drives the small badge
# icon) and "bossKey" (TowerBossDefeatFlag, drives the main tower icon) -- see
# dashboard.html's Tower render block and the palbox-confirmed-locations skill.

# Cave-entrance sub-pins (2026-07-08): an optional "entrances" array on any row, each a
# hand-typed {gx,gy} that dashboard.html renders as a cave icon joined to the parent pin
# by a line in the parent's status color (some map icons sit underground -- this marks the
# real surface access point). Emits each as world x/y (derived the same way the parent's
# own coords are, via ConvertTo-WorldXY) plus the raw gx/gy for tooltip display. Returns
# $null when the row has no entrances so Get-MapCategoryJson only adds the field where it
# actually exists.
function ConvertTo-EntranceList($c) {
    if (-not $c.PSObject.Properties['entrances'] -or -not $c.entrances) { return $null }
    $out = @()
    foreach ($e in @($c.entrances)) {
        if ($null -ne $e.x -and $null -ne $e.y) { $wx = $e.x; $wy = $e.y }
        else { $w = ConvertTo-WorldXY $e.gx $e.gy; $wx = $w.x; $wy = $w.y }
        $out += @{ x = $wx; y = $wy; gx = $e.gx; gy = $e.gy }
    }
    return $out
}
function Get-MapCategoryJson([string]$category) {
    $confirmed = Get-ConfirmedLocations
    if ($category -eq 'effigy') {
        $result = [ordered]@{}
        foreach ($c in $confirmed) {
            if ($c.category -ne 'effigy' -or -not $c.key) { continue }
            $entry = @{ x = $c.x; y = $c.y; z = $c.z }
            if ($c.verified -eq $true) { $entry.m = $true }
            if ($c.custom -eq $true) { $entry.custom = $true }
            $ents = ConvertTo-EntranceList $c
            if ($ents) { $entry.entrances = @($ents) }
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
        if ($c.custom -eq $true) { $out.custom = $true }
        if ($category -eq 'bounty') {
            $out.species = if ($c.species) { $c.species } else { $c.key }
        }
        # Boss prerequisites (2026-07-09, extended to Tower 2026-07-10): see Add-BossPrereq
        # below -- dashboard.html draws a line to each listed species and locks this pin's
        # marker until every one of them is defeated. Originally bounty-only; Towers can
        # also require a Field Boss be cleared first, so this is emitted for any category
        # whose row happens to carry a "prereqs" array rather than gated to one category.
        if ($c.PSObject.Properties['prereqs'] -and $c.prereqs) { $out.prereqs = @($c.prereqs) }
        if ($c.PSObject.Properties['lv'] -and $null -ne $c.lv) { $out.lv = $c.lv }
        if ($c.PSObject.Properties['boss'] -and $c.boss) { $out.boss = $c.boss }
        if ($c.PSObject.Properties['bossPal'] -and $c.bossPal) { $out.bossPal = $c.bossPal }
        if ($c.PSObject.Properties['bossKey'] -and $c.bossKey) { $out.bossKey = $c.bossKey }
        if ($category -eq 'tower') {
            # Tower's two save keys (Eagle Statue "key", raid-boss "bossKey") are verified
            # independently of each other and of the pin's own "m"/verified (added
            # 2026-07-07 -- Anthony wanted separate map checkboxes since he supplied the
            # bossKey mapping from memory and isn't sure all 7 are right yet). Default true
            # for eagleVerified (that linkage was already working/trusted before this
            # session) and false for bossVerified (explicitly unconfirmed) wherever the
            # field doesn't exist on the row yet, rather than reading absence as false for
            # both -- see the migration note in import_scraped_rosters.ps1/towers.json.
            $out.eagleVerified = if ($c.PSObject.Properties['eagleVerified']) { $c.eagleVerified -eq $true } else { $true }
            $out.bossVerified = if ($c.PSObject.Properties['bossVerified']) { $c.bossVerified -eq $true } else { $false }
        }
        if ($category -eq 'journal') {
            # Journal is the one category whose client tooltip (buildJournalMarker) and Data
            # Mine tab roster-fallback (getGxGy) read gx/gy straight off the roster item
            # instead of deriving it from x/y client-side -- keep emitting it to match.
            if ($null -ne $c.gx -and $null -ne $c.gy) { $out.gx = $c.gx; $out.gy = $c.gy }
            else { $grid = ConvertTo-GridXY $xy.x $xy.y; $out.gx = $grid.gx; $out.gy = $grid.gy }
        }
        $ents = ConvertTo-EntranceList $c
        if ($ents) { $out.entrances = @($ents) }
        $result += $out
    }
    return (ConvertTo-Json -InputObject @($result) -Depth 6)
}

# Shared identity resolver used by Set-MapConfirmVerified and the custom-icon
# edit/delete routes -- resolves a confirmed_locations.json row by the
# category-appropriate identity the client already displays for that pin (key for
# effigy/journal, species for bounty, name for tower/fugitive/eagle). $confirmed is the
# array to search (caller's own Get-ConfirmedLocations() result, so a caller doing a
# subsequent write reuses the same array instance rather than re-reading).
function Find-ConfirmedRow($confirmed, [string]$category, [string]$key, [string]$species, [string]$name) {
    if ($key) {
        $keyU = $key.ToUpper()
        return $confirmed | Where-Object { $_.key -and $_.key.ToUpper() -eq $keyU -and $_.category -eq $category } | Select-Object -First 1
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
        return $matched
    } elseif ($name) {
        $nameU = $name.ToUpper()
        return $confirmed | Where-Object { $_.name -and $_.name.ToUpper() -eq $nameU -and $_.category -eq $category } | Select-Object -First 1
    }
    return $null
}

# The one write path behind every POST .../*-confirm route (and the new consolidated
# /api/map-confirm) -- flips "verified" on the row Find-ConfirmedRow resolves. Since
# Get-MapCategoryJson above always emits the STORE's own name/species/key (never a
# blended roster value), whatever identity the client echoes back on toggle is
# guaranteed to match a row here exactly -- no fuzzy matching needed on the write side
# at all, unlike the read-side importer.
function Set-MapConfirmVerified([string]$category, [string]$key, [string]$species, [string]$name, [bool]$verified) {
    $confirmed = Get-ConfirmedLocations
    $matched = Find-ConfirmedRow $confirmed $category $key $species $name
    if (-not $matched) { return $false }
    Set-EntryProp $matched 'verified' $verified
    Save-ConfirmedLocations $confirmed
    return $true
}

# The 6 map categories the "Add Icon" manual-creation feature supports -- npc/landmark
# stay retired (see Get-CategoryForEntry's note below on why), so they're deliberately
# excluded here rather than silently accepted and then never rendered anywhere.
$script:CustomIconCategories = @('effigy', 'journal', 'bounty', 'fugitive', 'eagle', 'tower')

# Creates a brand-new, hand-typed confirmed_locations.json row for the "Add Icon"
# dashboard feature (see the palbox-confirmed-locations skill) -- stamped custom:true so
# it's distinguishable later from every other creation path (scraped-roster import,
# live Desktop-script capture, Data Mine tab key-to-name typing). Effigy requires a real
# key: Get-MapCategoryJson's effigy branch skips any row with no key entirely, so a
# keyless "custom" effigy pin would silently never render. Every other category may be
# keyless (bounty/fugitive/eagle routinely are, per the existing schema) and is
# identified by name/species instead, same convention Find-ConfirmedRow already uses.
function Add-CustomMapEntry([string]$category, [string]$key, [string]$name, [string]$species, $gx, $gy) {
    if ($category -notin $script:CustomIconCategories) { throw "Unsupported category: $category" }
    if ($category -eq 'effigy' -and -not $key) { throw "Effigy pins require a key -- pick one from the Unmapped Keys dropdown." }
    if ($category -ne 'effigy' -and -not $name) { throw "Display name is required for this category." }
    if ($null -eq $gx -or $null -eq $gy) { throw "Coordinates (gx/gy) are required." }
    if ($category -eq 'bounty' -and -not $species) { $species = $name }

    $confirmed = @(Get-ConfirmedLocations)
    if ($key) {
        $existing = Find-ConfirmedRow $confirmed $category $key $null $null
        if ($existing) { throw "A $category pin with that key already exists." }
    }

    $newEntry = [pscustomobject]@{
        key = $key; category = $category; name = $name; gx = $gx; gy = $gy
        x = $null; y = $null; z = $null; species = $species; lv = $null; source = $null
        origin = 'manual'; verified = $false; custom = $true
    }
    $confirmed = $confirmed + $newEntry
    Save-ConfirmedLocations $confirmed

    # Same parity the existing /api/datamine-mapping route gives a scraped-row key link
    # (PalWorldServerManager.ps1's NormalBossDefeatFlag branch) -- without this, a custom
    # bounty pin's defeat state can never resolve to "found" even after the key fires in
    # a save, since pal_save_reader.py resolves bounty species via anonymous_boss_keys.json,
    # not confirmed_locations.json.
    if ($category -eq 'bounty' -and $key -and -not (Test-SyndicateKeyShape $key)) {
        Add-AnonymousBossKey $key $species
    }
    return $newEntry
}

# Edits a custom-created row in place. Hard-requires custom:true on the matched row --
# refuses to touch a scraped/live pin even if the supplied identity happens to collide
# with one, so this route can never be used (accidentally or otherwise) to corrupt real
# imported/live-captured data. $fields is a hashtable of only the values to change
# (name/gx/gy/key/species) -- omit a key to leave that field untouched.
function Edit-CustomMapEntry([string]$category, [string]$identKey, [string]$identSpecies, [string]$identName, [hashtable]$fields) {
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $identKey $identSpecies $identName
    if (-not $matched) { throw "No matching custom entry found." }
    if ($matched.custom -ne $true) { throw "Refusing to edit a non-custom entry through this route." }
    foreach ($k in @('name', 'gx', 'gy', 'key', 'species')) {
        if ($fields.ContainsKey($k)) { Set-EntryProp $matched $k $fields[$k] }
    }
    if ($category -eq 'effigy' -and -not $matched.key) { throw "Effigy pins require a key." }
    if ($category -ne 'effigy' -and -not $matched.name) { throw "Display name is required for this category." }
    Save-ConfirmedLocations $confirmed
    return $matched
}

# Deletes a custom-created row. Same custom:true guard as Edit-CustomMapEntry above.
function Remove-CustomMapEntry([string]$category, [string]$key, [string]$species, [string]$name) {
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $key $species $name
    if (-not $matched) { throw "No matching custom entry found." }
    if ($matched.custom -ne $true) { throw "Refusing to delete a non-custom entry through this route." }
    $remaining = @($confirmed | Where-Object { $_ -ne $matched })
    Save-ConfirmedLocations $remaining
    return $true
}

# The 7 map categories that actually render pins on the Map tab (npc/landmark are retired --
# no marker/popup exists for them at all, see the palbox-confirmed-locations skill -- so
# they're deliberately excluded here the same way they're excluded from
# $script:CustomIconCategories above).
$script:EditableMapCategories = @('effigy', 'journal', 'bounty', 'fugitive', 'eagle', 'tower', 'sam')

# Corrects a pin's location and/or display name -- added 2026-07-12 so Anthony can fix
# locations that shifted after the Palworld 1.0 update, WITHOUT the custom:true guard
# Edit-CustomMapEntry enforces (this must work on scraped/live rows too, not just hand-added
# ones). $identKey/$identSpecies/$identName resolve the row via Find-ConfirmedRow using its
# CURRENT identity (same convention as Edit-CustomMapEntry) -- $fields is what's changing,
# so renaming a fugitive/eagle/tower/sam pin (identified BY name) still resolves correctly
# since the old name is what's passed as the identity, not the new one. Providing gx
# requires gy and vice versa (a coordinate pair, not two independent edits); when supplied,
# always writes gx/gy and nulls x/y/z so the corrected grid position actually takes effect --
# Get-MapCategoryJson prefers x/y over gx/gy when both are present (see its
# coordinate-precedence comment above), so leaving a stale x/y in place would silently keep
# showing the OLD position. This is the same x/y-null convention Add-CustomMapEntry already
# uses for a brand-new hand-typed pin. Effigy pins have no display name at all (see
# Get-MapCategoryJson's effigy dict shape -- {x,y,z,m}, no "name" field ever emitted), so a
# name edit there is rejected rather than silently written and never read.
#
# $fields.key (added 2026-07-12, same day): edits the row's raw save-flag key -- for effigy/
# journal this doubles as their primary identity, for bounty/fugitive/eagle/tower/sam it's
# the same key a keyless pin's "Map to key..." dropdown would otherwise set, just typed
# freehand instead of picked from a dropdown of currently-unmapped keys (so this can ALSO
# correct a wrong key, not just link a fresh one). Effigy requires a non-blank key --
# Get-MapCategoryJson's effigy branch silently skips any row with no key at all, so blanking
# it would make the pin vanish instead of erroring. A blank key on any other category clears
# it (un-links the pin, e.g. to undo a bad mapping). Guards against two rows in the same
# category sharing a key (would make Find-ConfirmedRow's key-branch match ambiguous). Bounty
# gets the same anonymous_boss_keys.json upsert Add-CustomMapEntry already does at create
# time (Test-SyndicateKeyShape decides whether a bounty key needs this species link at all),
# so re-keying an existing bounty pin keeps defeat-status resolution working. Tower has TWO
# independent keys ("key" = Eagle Statue link, "bossKey" = Boss Defeat link, see
# Get-MapCategoryJson's tower branch) -- this generic field only ever touches "key" (matching
# every other category's single-key model); bossKey is intentionally untouched/out of scope.
function Edit-MapEntry([string]$category, [string]$identKey, [string]$identSpecies, [string]$identName, [hashtable]$fields) {
    if ($category -notin $script:EditableMapCategories) { throw "Unsupported category: $category" }
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $identKey $identSpecies $identName
    if (-not $matched) { throw "No matching map entry found." }
    if ($fields.ContainsKey('name')) {
        if ($category -eq 'effigy') { throw "Effigy pins have no display name to edit." }
        if (-not $fields['name']) { throw "Display name cannot be blank." }
        Set-EntryProp $matched 'name' $fields['name']
    }
    if ($fields.ContainsKey('key')) {
        $newKey = $fields['key']
        if ($category -eq 'effigy' -and -not $newKey) { throw "Effigy pins require a key." }
        if ($newKey) {
            $dupe = $confirmed | Where-Object { $_ -ne $matched -and $_.category -eq $category -and $_.key -and $_.key.ToUpper() -eq $newKey.ToUpper() } | Select-Object -First 1
            if ($dupe) { throw "Another $category pin already uses that key." }
        }
        Set-EntryProp $matched 'key' $newKey
        if ($category -eq 'bounty' -and $newKey -and -not (Test-SyndicateKeyShape $newKey)) {
            $sp = if ($matched.species) { $matched.species } else { $matched.name }
            Add-AnonymousBossKey $newKey $sp
        }
    }
    if ($fields.ContainsKey('gx') -or $fields.ContainsKey('gy')) {
        if ($null -eq $fields['gx'] -or $null -eq $fields['gy']) { throw "Coordinates (gx/gy) are required together." }
        Set-EntryProp $matched 'gx' $fields['gx']
        Set-EntryProp $matched 'gy' $fields['gy']
        Set-EntryProp $matched 'x' $null
        Set-EntryProp $matched 'y' $null
        Set-EntryProp $matched 'z' $null
    }
    # $fields.lv (added 2026-07-12): generic level passthrough, no category restriction --
    # Get-MapCategoryJson already emits "lv" for ANY row that has it regardless of category
    # (originally populated for fugitive/tower only, via wanted_fugitives.json/towers.json).
    # Anthony wanted this editable for bounty too (bounty_bosses.json never scraped a level
    # at all, so every bounty row starts with no lv) and for fugitive (lv already exists on
    # those rows from the roster import, just was never exposed for editing or display
    # before). Null clears it same as any other optional field.
    if ($fields.ContainsKey('lv')) {
        Set-EntryProp $matched 'lv' $fields['lv']
    }
    Save-ConfirmedLocations $confirmed
    return $matched
}

# Deletes ANY pin outright (scraped/live/custom, any of the 7 renderable categories) -- the
# other half of the post-1.0 map-cleanup ask, alongside Edit-MapEntry above. Deliberately
# a hard delete with no "blacklist" file: if the roster importer (import_scraped_rosters.ps1)
# is ever re-run and the deleted pin is still in its source roster file, it can resurface as a
# fresh verified:false row -- Anthony's explicit call (2026-07-12), simplest option, and easy
# to just delete again if it happens.
function Remove-MapEntry([string]$category, [string]$key, [string]$species, [string]$name) {
    if ($category -notin $script:EditableMapCategories) { throw "Unsupported category: $category" }
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $key $species $name
    if (-not $matched) { throw "No matching map entry found." }
    $remaining = @($confirmed | Where-Object { $_ -ne $matched })
    Save-ConfirmedLocations $remaining
    return $true
}

# Cave-entrance sub-pins (2026-07-08): attaches a hand-typed {gx,gy} to an existing map
# pin (resolved by the same category-appropriate identity Find-ConfirmedRow uses for every
# other write). Purely additive location metadata -- unlike Edit/Remove-CustomMapEntry there
# is deliberately NO custom:true guard, because adding an entrance never mutates the parent
# row's own identity/data, and any pin (scraped, live, or custom) can legitimately sit
# underground and need a surface entrance marked. See dashboard.html desireEntrances/
# buildCaveMarker and the ConvertTo-EntranceList read path above.
function Add-MapEntrance([string]$category, [string]$key, [string]$species, [string]$name, $gx, $gy) {
    if ($null -eq $gx -or $null -eq $gy) { throw "Coordinates (gx/gy) are required." }
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $key $species $name
    if (-not $matched) { throw "No matching pin found to attach an entrance to." }
    $ents = @()
    if ($matched.PSObject.Properties['entrances'] -and $matched.entrances) { $ents = @($matched.entrances) }
    $ents += [pscustomobject]@{ gx = [int]$gx; gy = [int]$gy }
    Set-EntryProp $matched 'entrances' @($ents)
    Save-ConfirmedLocations $confirmed
    return $matched
}

# Removes one entrance from a parent pin by its 0-based index (the client renders entrances
# in stored array order, so the index it echoes back lines up). Same identity resolution as
# Add-MapEntrance; no custom:true guard for the same reason.
function Remove-MapEntrance([string]$category, [string]$key, [string]$species, [string]$name, [int]$index) {
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $key $species $name
    if (-not $matched) { throw "No matching pin found." }
    $ents = @()
    if ($matched.PSObject.Properties['entrances'] -and $matched.entrances) { $ents = @($matched.entrances) }
    if ($index -lt 0 -or $index -ge $ents.Count) { throw "Entrance index out of range." }
    $remaining = @(for ($i = 0; $i -lt $ents.Count; $i++) { if ($i -ne $index) { $ents[$i] } })
    Set-EntryProp $matched 'entrances' $remaining
    Save-ConfirmedLocations $confirmed
    return $matched
}

# Boss prerequisites (2026-07-09, extended to Tower 2026-07-10): an optional "prereqs" array
# of bounty species codes on a bounty OR tower row -- dashboard.html draws a line from each
# listed prerequisite boss to this one and shows a big red lock over this pin's marker until
# every prerequisite is defeated (see desireBossPrereqLines/bountyBossIcon/towerIcon). The
# LOCKED row can be either category (bounty, identified by $species; tower, identified by
# $name -- same convention Find-ConfirmedRow already uses for each), but the prerequisite
# itself is always resolved as a bounty species, since "required bosses" only ever means
# Field Bosses. Purely additive like Add/Remove-MapEntrance above -- no custom:true guard,
# since linking two existing pins never mutates either one's own identity/location data.
function Add-BossPrereq([string]$category, [string]$species, [string]$name, [string]$preSpecies) {
    if ($category -notin @('bounty', 'tower')) { throw "Unsupported category for prerequisites: $category" }
    if (-not $preSpecies) { throw "A prerequisite boss is required." }
    if ($category -eq 'bounty' -and -not $species) { throw "The boss is required." }
    if ($category -eq 'tower' -and -not $name) { throw "The tower name is required." }
    if ($category -eq 'bounty' -and $species.ToUpper() -eq $preSpecies.ToUpper()) { throw "A boss cannot require itself." }
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $null $species $name
    if (-not $matched) { throw "No matching $category found." }
    $preMatched = Find-ConfirmedRow $confirmed 'bounty' $null $preSpecies $null
    if (-not $preMatched) { throw "No matching Field Boss found for $preSpecies." }
    $preqs = @()
    if ($matched.PSObject.Properties['prereqs'] -and $matched.prereqs) { $preqs = @($matched.prereqs) }
    if ($preqs | Where-Object { $_.ToUpper() -eq $preSpecies.ToUpper() }) { throw "That prerequisite is already linked." }
    $preqs += $preSpecies
    Set-EntryProp $matched 'prereqs' @($preqs)
    Save-ConfirmedLocations $confirmed
    return $matched
}

# Removes one prerequisite link by species (order doesn't matter -- unlike entrances there is
# no index to line up, since each prereq is already uniquely identified by its own species).
function Remove-BossPrereq([string]$category, [string]$species, [string]$name, [string]$preSpecies) {
    if ($category -notin @('bounty', 'tower')) { throw "Unsupported category for prerequisites: $category" }
    if (-not $preSpecies) { throw "A prerequisite boss is required." }
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $null $species $name
    if (-not $matched) { throw "No matching $category found." }
    $preqs = @()
    if ($matched.PSObject.Properties['prereqs'] -and $matched.prereqs) { $preqs = @($matched.prereqs) }
    $remaining = @($preqs | Where-Object { $_.ToUpper() -ne $preSpecies.ToUpper() })
    Set-EntryProp $matched 'prereqs' $remaining
    Save-ConfirmedLocations $confirmed
    return $matched
}

# Flips Tower's per-key verification flags (added 2026-07-07) -- independent of
# Set-MapConfirmVerified's "verified" (the pin's own location) above. $field is
# whitelisted, not passed straight through to Set-EntryProp, since it arrives from a
# client POST body and Set-EntryProp will happily create ANY named property on the
# matched row otherwise.
function Set-TowerKeyVerified([string]$towerName, [string]$field, [bool]$verified) {
    if ($field -notin @('eagleVerified', 'bossVerified')) { return $false }
    $confirmed = Get-ConfirmedLocations
    $nameU = $towerName.ToUpper()
    $matched = $confirmed | Where-Object { $_.category -eq 'tower' -and $_.name -and $_.name.ToUpper() -eq $nameU } | Select-Object -First 1
    if (-not $matched) { return $false }
    Set-EntryProp $matched $field $verified
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

# Upsert one key/species pair into anonymous_boss_keys.json -- called from the Data Mine
# tab's manual-mapping route (/api/datamine-mapping) whenever it attaches a
# NormalBossDefeatFlag key to an already-scraped Field Boss pin whose species is already
# known, so pal_save_reader.py's bounty/datamine resolution (which reads this file, not
# confirmed_locations.json) picks up the mapping immediately -- without this, a manually
# confirmed key never shows as "defeated" on the map since /api/player-bounties has no way
# to resolve it to a species. No-ops if the exact pair is already present; overwrites the
# species if the key exists with a different one (Anthony correcting a prior mapping).
# Written with a temp-file + Move-Item swap, matching the atomic-write convention used
# elsewhere for confirmed_locations.json, since this file is also read by the live server's
# own request handlers on every /api/player-bounties and /api/player-datamine call.
function Add-AnonymousBossKey([string]$key, [string]$species) {
    if (-not $key -or -not $species) { return }
    $anonFile = "$script:MapDataRoot\anonymous_boss_keys.json"
    $arr = @()
    if (Test-Path -LiteralPath $anonFile) {
        # Do NOT wrap the pipeline in @() here -- same PS 5.1 ConvertFrom-Json gotcha
        # documented on Get-ConfirmedLocations above: it emits an already-parsed JSON array
        # as a SINGLE pipeline object rather than enumerating it, so @() re-wraps that one
        # object into a bogus 1-element array whose sole element is the real array. Confirmed
        # the hard way (2026-07-07): wrapping it here silently nested the whole 28-entry
        # roster under a {value:[...],Count:28} wrapper as element 0 of a 2-element array,
        # which every reader (Python's load_anonymous_boss_keys, Get-AnonymousBossKeyMap)
        # then silently failed to recognize as valid entries.
        try { $arr = Get-Content -LiteralPath $anonFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $arr = @() }
    }
    $arr = @($arr)
    $existing = $arr | Where-Object { $_.key -and $_.key.ToUpper() -eq $key.ToUpper() } | Select-Object -First 1
    if ($existing) {
        if ($existing.species -eq $species) { return }
        $existing.species = $species
    } else {
        $arr = @($arr) + [pscustomobject]@{ key = $key; species = $species }
    }
    $json = ConvertTo-Json -InputObject @($arr) -Depth 6
    $tmp = "$anonFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $anonFile -Force
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
        'DestroyedWeapon' { return 'sam' }
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
