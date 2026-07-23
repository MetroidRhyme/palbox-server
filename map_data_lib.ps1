# map_data_lib.ps1
# Shared map-location data layer, dot-sourced by BOTH PalWorldServerManager.ps1 (the
# live admin dashboard) and build_public_data.ps1 (the public-site batch builder).
# Extracted 2026-07-06 from two hand-kept, drifted-only-in-path-and-caching copies --
# see the palbox-confirmed-locations skill for the full history of why each of these
# functions exists. Call Initialize-MapDataLib -Root <dir> once before using anything
# else in this file.
#
# -- Hand-confirmed map locations (Anthony's own live-play data) --------------
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
        # The in-place editors (Edit-MapEntry, Set-MapConfirmVerified, entrance/prereq add-remove)
        # mutate cached row objects BEFORE calling this, so those edits are already sitting in
        # $script:confirmedLocations even though they never reached disk. Invalidate the cache
        # (2026-07-13) so the next Get-ConfirmedLocations reloads the real on-disk state instead
        # of serving the failed edit until a Manager restart.
        $script:confirmedLocations = $null
        $script:confirmedLocationsMtime = $null
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

# Forces the next Get-ConfirmedLocations to re-read from disk instead of serving the cache.
#
# Required by any write path that mutates rows BEFORE it has finished validating them (both
# Edit-* functions below do -- some of their rules can only be checked against the post-edit
# state). Get-ConfirmedLocations caches the parsed array and hands out those LIVE row objects,
# and its only invalidation signal is the file's mtime -- which never moves when a validation
# throw skips the save. So without this, a rejected edit's half-applied mutation silently stays
# in memory, is served to every subsequent reader, and gets written to disk for real by the next
# unrelated successful Save-ConfirmedLocations (2026-07-15: found by a smoke test where a
# rejected name-blanking left name=$null in the cache, which then defeated the keyless duplicate
# -name guard on a later add).
function Reset-ConfirmedLocationsCache {
    $script:confirmedLocations = $null
    $script:confirmedLocationsMtime = $null
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
            foreach ($k in @('x', 'y', 'z', 'lv', 'boss', 'bossPal')) {
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

# Per-map grid constants. map8 (Palpagos overworld) is single-sourced from map_constants.json.
# treemap8 (The World Tree) is SEEDED equal to the overworld: the World Tree occupies a
# world-coordinate block (X ~347k..689k) contiguous with the overworld (whose X ends at 349400),
# so the in-game compass is almost certainly the same continuous 459-scale grid. If an in-game
# check ever shows the World Tree uses a distinct compass grid, calibrate ONLY the treemap8 numbers
# here -- a one-line change; nothing else in the map system assumes these values are equal.
function Get-MapGrid([string]$mapId = 'map8') {
    if ($mapId -eq 'treemap8') {
        return [pscustomobject]@{ scale = 459; offsetX = 123888; offsetY = 158000 }
    }
    return Get-MapConstants
}

# A row's map id, defaulting to the overworld for every legacy row (which has no "map" field) so
# no migration is needed -- only World Tree pins carry map='treemap8'.
function Get-EntryMap($e) { if ($e.map) { $e.map } else { 'map8' } }

# gx/gy (in-game grid coords) -> real world x/y. Inverse of the effigy tooltip's
# cx=(y-offsetY)/scale, cy=(x+offsetX)/scale -- see the palbox-journal-overlay skill's
# coordinate-transform section. $mapId selects the per-map grid (default overworld); a World Tree
# row passes 'treemap8' so its gx/gy derive into the World Tree world block.
function ConvertTo-WorldXY([int]$gx, [int]$gy, [string]$mapId = 'map8') {
    $mc = Get-MapGrid $mapId
    return @{ x = ($gy * $mc.scale) - $mc.offsetX; y = ($gx * $mc.scale) + $mc.offsetY }
}

# Real world x/y -> gx/gy (in-game grid coords). Inverse of ConvertTo-WorldXY above -- used
# by the scraped-roster importers (import_scraped_rosters.ps1) to derive gx/gy for a
# roster that only ships raw world x/y (e.g. effigies.json), so a brand-new inserted row
# still has grid coords for anything that displays them. Rounds to the nearest integer
# rather than truncating, since a scrape's x/y is rarely an exact multiple of the 459
# scale constant.
function ConvertTo-GridXY([double]$x, [double]$y, [string]$mapId = 'map8') {
    $mc = Get-MapGrid $mapId
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
# for tower (the human raid-boss's name + their partner Pal's name, originally scraped from
# paldb.cc via towers.json at import; editable through Edit-MapEntry as of 2026-07-15 --
# unrelated to "key").
#
# Tower's "key" (added 2026-07-07, unified onto the single generic key model 2026-07-15) is
# the TowerBossDefeatFlag key for that tower's raid-boss fight -- normal difficulty only,
# hard-mode's key was lost in an earlier consolidation and hasn't been re-identified. Until
# 2026-07-15 this lived in a separate "bossKey" field that towers.json baked in at import
# time (always present regardless of real verification -- see the git history around
# 2026-07-15 for the "yellow towers" bug that caused), plus a second "bossVerified" flag
# mirroring Set-MapConfirmVerified's own "verified". Both are gone now: Tower uses the exact
# same single key/single verified model as Field Boss/Wanted Fugitive/Eagle Statue/SAM Site --
# "key" starts null and is only populated once genuinely linked (Map to key.../Pick unmapped
# key.../Record next key/manual edit), "verified" is the only confirmation signal. See
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
            if ($c.category -ne 'effigy') { continue }
            # A keyless effigy (2026-07-13) is one whose save-flag GUID Anthony cleared to
            # re-record it by playing (see Edit-MapEntry / the "Record next key" feature). The
            # effigy dict is keyed by that GUID and a keyless row has none, so it renders under a
            # synthetic "__PENDING__:gx,gy" key instead, flagged pending + carrying its gx/gy so
            # the client can draw it as untrackable and round-trip its grid identity back for
            # edit/record. Grid coords ARE its only identity here (effigies have no name), so a
            # row with neither key nor a gx/gy pair can't be identified at all -- skip it (this
            # can't happen via the supported write paths: Add-CustomMapEntry/Edit-MapEntry both
            # require a gx/gy pair on any keyless effigy).
            if (-not $c.key -and ($null -eq $c.gx -or $null -eq $c.gy)) { continue }
            # Prefer scraped world x/y; fall back to Anthony's gx/gy grid via ConvertTo-WorldXY
            # (2026-07-13) -- mirrors the array-category branch below. Without this, any effigy
            # whose row has only gx/gy reads back as null coords and the pin vanishes. That path
            # is now reachable: Edit-MapEntry nulls x/y/z on a coordinate edit, and
            # Add-CustomMapEntry creates effigy rows with gx/gy only.
            # Per-map grid: derive x/y from gx/gy using the row's own map (default overworld), and
            # emit "map" so the client routes the pin to the right base map (see pinOnActiveMap).
            $rowMap = if ($c.map) { $c.map } else { 'map8' }
            $hasXY = ($null -ne $c.x -and $null -ne $c.y)
            $xy = if ($hasXY) { @{ x = $c.x; y = $c.y } } else { ConvertTo-WorldXY $c.gx $c.gy $rowMap }
            $entry = @{ x = $xy.x; y = $xy.y; z = $c.z; map = $rowMap }
            if ($c.verified -eq $true) { $entry.m = $true }
            if ($c.custom -eq $true) { $entry.custom = $true }
            $ents = ConvertTo-EntranceList $c
            if ($ents) { $entry.entrances = @($ents) }
            if ($c.key) {
                $result[$c.key] = $entry
            } else {
                $entry.pending = $true
                $entry.gx = $c.gx
                $entry.gy = $c.gy
                $result["__PENDING__:$($c.gx),$($c.gy)"] = $entry
            }
        }
        return (ConvertTo-Json -InputObject $result -Depth 6 -Compress)
    }
    $result = @()
    foreach ($c in $confirmed) {
        if ($c.category -ne $category) { continue }
        $rowMap = if ($c.map) { $c.map } else { 'map8' }
        $hasXY = ($null -ne $c.x -and $null -ne $c.y)
        $xy = if ($hasXY) { @{ x = $c.x; y = $c.y } } else { ConvertTo-WorldXY $c.gx $c.gy $rowMap }
        $name = if ($c.name) { $c.name } else { $c.key }
        $out = @{ name = $name; x = $xy.x; y = $xy.y; m = ($c.verified -eq $true); map = $rowMap }
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
        if ($category -eq 'journal') {
            # Journal is the one category whose client tooltip (buildJournalMarker) and Data
            # Mine tab roster-fallback (getGxGy) read gx/gy straight off the roster item
            # instead of deriving it from x/y client-side -- keep emitting it to match.
            if ($null -ne $c.gx -and $null -ne $c.gy) { $out.gx = $c.gx; $out.gy = $c.gy }
            else { $grid = ConvertTo-GridXY $xy.x $xy.y $rowMap; $out.gx = $grid.gx; $out.gy = $grid.gy }
            # A keyless AND nameless journal only exists mid-wizard (2026-07-22, "coords ->
            # record -> name") -- every real (scraped or hand-typed) journal row already has a
            # name even while keyless, so this deliberately does NOT fire for any of them; only
            # gates the transient wizard state before its display name is saved.
            if (-not $c.key -and -not $c.name) { $out.pending = $true }
        }
        if ($category -eq 'itempickup') {
            # itempickup (Schematic) resolves a keyless pin by its gx/gy grid identity (like a
            # keyless effigy). Emit the EXACT stored gx/gy so the client round-trips the same
            # integer identity on edit/record rather than re-deriving it from x/y (which could
            # rounding-drift off the stored value and fail the backend's gx/gy match). A keyless
            # one is flagged pending so the client draws it untrackable + shows "Record next key",
            # same signal the effigy dict shape's "pending" carries.
            if ($null -ne $c.gx -and $null -ne $c.gy) { $out.gx = $c.gx; $out.gy = $c.gy }
            else { $grid = ConvertTo-GridXY $xy.x $xy.y $rowMap; $out.gx = $grid.gx; $out.gy = $grid.gy }
            if (-not $c.key) { $out.pending = $true }
        }
        if ($category -eq 'sam' -and -not $c.key -and -not $c.name) {
            # SAM Site's Add Icon wizard is "coords -> record" with no name step at all
            # (2026-07-22) -- a brand-new pin starts fully keyless AND nameless, identified
            # purely by gx/gy exactly like effigy/itempickup. Every existing (scraped) SAM row
            # already has a real name even while keyless, so this never fires for them -- only
            # for the transient state between wizard creation and its key being recorded.
            if ($null -ne $c.gx -and $null -ne $c.gy) { $out.gx = $c.gx; $out.gy = $c.gy }
            else { $grid = ConvertTo-GridXY $xy.x $xy.y $rowMap; $out.gx = $grid.gx; $out.gy = $grid.gy }
            $out.pending = $true
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
function Find-ConfirmedRow($confirmed, [string]$category, [string]$key, [string]$species, [string]$name, $gx = $null, $gy = $null, [string]$map = 'map8') {
    $mapVal = if ([string]::IsNullOrEmpty($map)) { 'map8' } else { $map }
    if ($key) {
        $keyU = $key.ToUpper()
        return $confirmed | Where-Object { $_.key -and $_.key.ToUpper() -eq $keyU -and $_.category -eq $category } | Select-Object -First 1
    } elseif ($category -in $script:CoordIdentityCategories -and $null -ne $gx -and $null -ne $gy) {
        # A keyless effigy/itempickup is identified by its gx/gy grid position (2026-07-13, see
        # Get-MapCategoryJson's __PENDING__/pending branch). Checked before $species/$name --
        # those are always empty for an effigy, and for an itempickup the name is a mutable
        # display attribute, never its identity, so a keyless one still resolves purely by coords.
        # gx/gy is a per-map grid, so it's only unique WITHIN a map -- scope by map so a World Tree
        # pin can't resolve to an overworld pin that happens to share the same grid coords.
        return $confirmed | Where-Object { $_.category -eq $category -and -not $_.key -and $_.gx -eq $gx -and $_.gy -eq $gy -and (Get-EntryMap $_) -eq $mapVal } | Select-Object -First 1
    } elseif ($species) {
        $spU = $species.ToUpper()
        $matched = $confirmed | Where-Object { $_.species -and $_.species.ToUpper() -eq $spU -and $_.category -eq $category } | Select-Object -First 1
        if (-not $matched) {
            # Self-named species (BlueDragon/FairyDragon) store their identity directly in
            # "key" -- the raw save-flag key text IS the species name.
            $matched = $confirmed | Where-Object { $_.key -and $_.key.ToUpper() -eq $spU -and $_.category -eq $category } | Select-Object -First 1
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

# Categories whose KEYLESS pins are identified solely by their gx/gy grid position (not by a
# name or species). Effigy has no name at all; itempickup (Schematic) is created coords-first
# and gets its key/name added later (Add Icon -> Record next key -> type a name), so its name
# can't be its stable identity either. A keyless pin in one of these requires a gx/gy pair, and
# two keyless ones can't share a spot (ambiguous to the key recorder). Every other category
# resolves a keyless pin by name/species instead. Used by Find-ConfirmedRow / Add-CustomMapEntry
# / Edit-MapEntry below.
#
# sam and journal joined 2026-07-22 for the same reason as itempickup: their Add Icon wizard
# steps are "coords -> record" (sam) / "coords -> record -> name" (journal), i.e. a brand-new
# pin is created with no name at all yet. Both categories' EXISTING data is exclusively
# keyless-but-NAMED (every scraped sam/journal row already carries a real display name) --
# Get-MapCategoryJson only sets the "pending" flag (and buildSamMarker/buildJournalMarker only
# hide Confirm/cave) when a row is BOTH keyless AND nameless, so none of that existing data is
# affected; this only ever fires for a wizard-created row before its key is recorded.
$script:CoordIdentityCategories = @('effigy', 'itempickup', 'sam', 'journal')

# The 8 map categories the "Add Icon" manual-creation feature supports -- npc/landmark
# stay retired (see Get-CategoryForEntry's note below on why), so they're deliberately
# excluded here rather than silently accepted and then never rendered anywhere. itempickup
# (Schematic) was added 2026-07-14 -- coords-first creation, key recorded by playing.
# sam was added 2026-07-15 -- it was already fully wired everywhere else (rendered by
# Get-MapCategoryJson, resolvable by Find-ConfirmedRow, offered DestroyedWeapon keys by the
# Data Mine tab); only this list was missing, which made Add Icon reject it as unsupported.
$script:CustomIconCategories = @('effigy', 'journal', 'bounty', 'fugitive', 'eagle', 'tower', 'sam', 'itempickup')

# Creates a brand-new, hand-typed confirmed_locations.json row for the "Add Icon"
# dashboard feature (see the palbox-confirmed-locations skill) -- stamped custom:true so
# it's distinguishable later from every other creation path (scraped-roster import,
# live Desktop-script capture, Data Mine tab key-to-name typing). Effigy requires a real
# key: Get-MapCategoryJson's effigy branch skips any row with no key entirely, so a
# keyless "custom" effigy pin would silently never render. Every other category may be
# keyless (bounty/fugitive/eagle routinely are, per the existing schema) and is
# identified by name/species instead, same convention Find-ConfirmedRow already uses.
function Add-CustomMapEntry([string]$category, [string]$key, [string]$name, [string]$species, $gx, $gy, [string]$map = 'map8', $lv = $null, $boss = $null, $bossPal = $null) {
    if ($category -notin $script:CustomIconCategories) { throw "Unsupported category: $category" }
    # Which base map the pin belongs to. Only 'treemap8' (World Tree) is stored; the overworld
    # default is left absent on the row (Get-EntryMap treats absent as 'map8'), so overworld pins
    # serialize exactly as before -- no migration of existing rows.
    $mapVal = if ($map -eq 'treemap8') { 'treemap8' } else { 'map8' }
    # A [string]-typed param re-coerces $null to '' on assignment, so it can never hold $null --
    # compute the stored key as an UNTYPED value below so a keyless pin serializes as "key": null
    # (the schema convention every -not $_.key / Find-ConfirmedRow check expects), not "key": "".
    $keyVal = if ([string]::IsNullOrEmpty($key)) { $null } else { $key }
    # Effigy and itempickup (Schematic) MAY be keyless -- a hand-placed pin you'll walk to and
    # record the key for later. Their identity is purely gx/gy while keyless (effigy has no name;
    # itempickup's name is added later), so a display name is optional and the coord-clash guard
    # below refuses a second keyless pin of that category at the same spot.
    if ($category -notin $script:CoordIdentityCategories -and -not $name) { throw "Display name is required for this category." }
    if ($null -eq $gx -or $null -eq $gy) { throw "Coordinates (gx/gy) are required." }
    if ($category -eq 'bounty' -and -not $species) { $species = $name }
    # Same untyped-value reason as $keyVal above: [string]$name/[string]$species can never hold
    # $null, so without this a keyless pin serialized "name": "" / "species": "" instead of null,
    # which every -not $_.name / -not $_.species check reads as "absent" but which Get-CategoryForEntry's
    # $c.name branch and the JSON consumers see as a real empty string (2026-07-15: this is what
    # produced the 21 ""-valued rows the one-time normalization pass cleaned up).
    $nameVal = if ([string]::IsNullOrEmpty($name)) { $null } else { $name }
    $speciesVal = if ([string]::IsNullOrEmpty($species)) { $null } else { $species }

    $confirmed = @(Get-ConfirmedLocations)
    if ($key) {
        $existing = Find-ConfirmedRow $confirmed $category $key $null $null
        if ($existing) { throw "A $category pin with that key already exists." }
    } elseif ($category -in $script:CoordIdentityCategories) {
        # gx/gy is a per-map grid, so a clash is only a clash on the SAME map -- a World Tree effigy
        # and an overworld effigy may legitimately share grid coords.
        $clash = $confirmed | Where-Object { $_.category -eq $category -and -not $_.key -and $_.gx -eq $gx -and $_.gy -eq $gy -and (Get-EntryMap $_) -eq $mapVal } | Select-Object -First 1
        if ($clash) { throw "Another keyless $category pin is already at ($gx,$gy) -- move one first, or record its key." }
    } elseif ($nameVal -and $nameVal.IndexOf('?') -lt 0) {
        # Name-identity categories: a SECOND keyless pin with the same name would be ambiguous to
        # Find-ConfirmedRow's name branch (it takes -First 1, so the edit/delete/confirm routes
        # would silently all hit the same one). Keyless-vs-keyless only -- a KEYED row with the
        # same name is the legitimate scraped-pin + mapped-key pair the importer reconciles.
        #
        # Skipped entirely for a placeholder name containing "?" (2026-07-22) -- unconfirmed Field
        # Boss pins are deliberately named "???" (see the palbox-bounty-tracker skill), and MANY of
        # them legitimately share that exact placeholder. Find-ConfirmedRow never resolves these
        # pins by name anyway once they're keyed (bounty identity is key-first), so the ambiguity
        # this guard exists to prevent doesn't apply to "?"-named rows.
        # NOTE: use .IndexOf, not -like '*?*' -- PowerShell's -like treats "?" as a wildcard
        # (matches any single character), so '*?*' would match every non-empty string, not just
        # ones containing a literal "?".
        $nameU = $nameVal.ToUpper()
        $clash = $confirmed | Where-Object { $_.category -eq $category -and -not $_.key -and $_.name -and $_.name.ToUpper() -eq $nameU } | Select-Object -First 1
        if ($clash) { throw "A keyless $category pin named '$nameVal' already exists in this category." }
    }

    $newEntry = [pscustomobject]@{
        key = $keyVal; category = $category; name = $nameVal; gx = $gx; gy = $gy
        x = $null; y = $null; z = $null; species = $speciesVal; lv = $null; source = $null
        origin = 'manual'; verified = $false; custom = $true
    }
    # lv/boss/bossPal (2026-07-22): the Add Icon wizard captures Field Boss/Wanted Fugitive's
    # level and Tower's level + boss/partner-Pal names on the SAME page as the display name
    # (before recording starts), unlike a scraped import which never has these at creation.
    # Untyped params (not [string]/[int]) so $null passes through as $null instead of coercing
    # to '' or 0 -- same reasoning as $keyVal/$nameVal/$speciesVal above.
    if ($null -ne $lv -and [string]$lv -ne '') { $newEntry.lv = $lv }
    if ($boss) { $newEntry | Add-Member -NotePropertyName boss -NotePropertyValue $boss }
    if ($bossPal) { $newEntry | Add-Member -NotePropertyName bossPal -NotePropertyValue $bossPal }
    # Only the World Tree carries an explicit map tag; overworld pins stay tag-free (Get-EntryMap
    # reads absent as 'map8'), so this doesn't change how existing/overworld rows serialize.
    if ($mapVal -eq 'treemap8') { $newEntry | Add-Member -NotePropertyName map -NotePropertyValue 'treemap8' }
    $confirmed = $confirmed + $newEntry
    Save-ConfirmedLocations $confirmed
    return $newEntry
}

# Edits a custom-created row in place. Hard-requires custom:true on the matched row --
# refuses to touch a scraped/live pin even if the supplied identity happens to collide
# with one, so this route can never be used (accidentally or otherwise) to corrupt real
# imported/live-captured data. $fields is a hashtable of only the values to change
# (name/gx/gy/key/species) -- omit a key to leave that field untouched.
#
# $identGx/$identGy (2026-07-15) resolve a KEYLESS coord-identity pin (effigy/itempickup),
# whose gx/gy is its only identity -- this function predates that work, so without them a
# hand-added keyless Schematic/effigy row was unreachable from the Data Mine tab's Custom
# Icons section ("No matching custom entry found") and could never be edited or deleted.
function Edit-CustomMapEntry([string]$category, [string]$identKey, [string]$identSpecies, [string]$identName, [hashtable]$fields, $identGx = $null, $identGy = $null, [string]$identMap = 'map8') {
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $identKey $identSpecies $identName $identGx $identGy $identMap
    if (-not $matched) { throw "No matching custom entry found." }
    if ($matched.custom -ne $true) { throw "Refusing to edit a non-custom entry through this route." }
    # Mutations below happen before the post-edit validation can run, so any throw past this point
    # must drop the cache rather than leave a rejected edit live in memory -- see
    # Reset-ConfirmedLocationsCache.
    try {
        foreach ($k in @('name', 'gx', 'gy', 'key', 'species')) {
            if ($fields.ContainsKey($k)) { Set-EntryProp $matched $k $fields[$k] }
        }
        # Validated AFTER the fields are applied, so these check the row's post-edit state. Mirrors
        # Edit-MapEntry's rules (which this used to contradict by hardcoding 'effigy'): a
        # coord-identity pin may be keyless -- that's the "pending, go record it" state -- as long as
        # it keeps the gx/gy that is then its only identity, and doesn't land on top of another
        # keyless pin of the same category (ambiguous to both the recorder and Find-ConfirmedRow).
        # Every other category is name-identified, so it needs a name and never a key.
        if ($category -notin $script:CoordIdentityCategories -and -not $matched.name) { throw "Display name is required for this category." }
        if ($category -in $script:CoordIdentityCategories -and -not $matched.key) {
            if ($null -eq $matched.gx -or $null -eq $matched.gy) { throw "A keyless $category pin needs grid coordinates (gx/gy) to stay on the map." }
            $clash = $confirmed | Where-Object { $_ -ne $matched -and $_.category -eq $category -and -not $_.key -and $_.gx -eq $matched.gx -and $_.gy -eq $matched.gy -and (Get-EntryMap $_) -eq (Get-EntryMap $matched) } | Select-Object -First 1
            if ($clash) { throw "Another keyless $category pin is already at ($($matched.gx),$($matched.gy)) -- move one first." }
        }
        Save-ConfirmedLocations $confirmed
    } catch {
        Reset-ConfirmedLocationsCache
        throw
    }
    return $matched
}

# Deletes a custom-created row. Same custom:true guard as Edit-CustomMapEntry above, and the
# same $gx/$gy keyless coord-identity resolution.
function Remove-CustomMapEntry([string]$category, [string]$key, [string]$species, [string]$name, $gx = $null, $gy = $null, [string]$map = 'map8') {
    $confirmed = @(Get-ConfirmedLocations)
    $matched = Find-ConfirmedRow $confirmed $category $key $species $name $gx $gy $map
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
$script:EditableMapCategories = @('effigy', 'journal', 'bounty', 'fugitive', 'eagle', 'tower', 'sam', 'itempickup')

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
# category sharing a key (would make Find-ConfirmedRow's key-branch match ambiguous). Tower's "key" IS
# its Boss Defeat link (2026-07-15 -- previously a separate "bossKey" field this generic
# field never touched; see Get-MapCategoryJson's comment), so it's edited exactly like every
# other category's single-key model, no special-casing needed here.
function Edit-MapEntry([string]$category, [string]$identKey, [string]$identSpecies, [string]$identName, [hashtable]$fields, $identGx = $null, $identGy = $null, [string]$identMap = 'map8') {
    if ($category -notin $script:EditableMapCategories) { throw "Unsupported category: $category" }
    $confirmed = @(Get-ConfirmedLocations)
    # $identGx/$identGy resolve an ALREADY-keyless effigy (its gx/gy is its only identity) --
    # needed when editing/deleting a pin whose key was previously cleared. A keyed pin still
    # resolves by $identKey as before. $identMap scopes the coord-identity match to the pin's map
    # (gx/gy is only unique within a map).
    $matched = Find-ConfirmedRow $confirmed $category $identKey $identSpecies $identName $identGx $identGy $identMap
    if (-not $matched) { throw "No matching map entry found." }
    # Hoisted above every mutation (2026-07-15): this is a pure precondition on $fields.
    # Checked first, nothing has happened yet.
    if ($fields.ContainsKey('gx') -or $fields.ContainsKey('gy')) {
        if ($null -eq $fields['gx'] -or $null -eq $fields['gy']) { throw "Coordinates (gx/gy) are required together." }
    }
    # Same cache-safety contract as Edit-CustomMapEntry: everything below mutates $matched
    # before later rules can throw, so any failure has to
    # drop the cache instead of leaving a rejected edit live in memory for the next save to
    # persist -- see Reset-ConfirmedLocationsCache.
    try {
    if ($fields.ContainsKey('name')) {
        if ($category -eq 'effigy') { throw "Effigy pins have no display name to edit." }
        if (-not $fields['name']) { throw "Display name cannot be blank." }
        Set-EntryProp $matched 'name' $fields['name']
    }
    if ($fields.ContainsKey('key')) {
        $newKey = $fields['key']
        # Clearing an effigy's key (2026-07-13) turns it into a "pending" pin you re-record by
        # playing. Only allowed if it keeps a gx/gy pair (its sole identity once keyless -- see
        # Get-MapCategoryJson's __PENDING__ branch; with no coords it would vanish AND be
        # unresolvable), and only if no OTHER keyless effigy already sits at that exact spot
        # (two would be ambiguous to the recorder). Uses the incoming gx/gy edit if this same
        # call also moves the pin, else the row's current gx/gy.
        if ($category -in $script:CoordIdentityCategories -and -not $newKey) {
            $egx = if ($fields.ContainsKey('gx')) { $fields['gx'] } else { $matched.gx }
            $egy = if ($fields.ContainsKey('gy')) { $fields['gy'] } else { $matched.gy }
            if ($null -eq $egx -or $null -eq $egy) { throw "A keyless $category pin needs grid coordinates (gx/gy) to stay on the map." }
            $clash = $confirmed | Where-Object { $_ -ne $matched -and $_.category -eq $category -and -not $_.key -and $_.gx -eq $egx -and $_.gy -eq $egy -and (Get-EntryMap $_) -eq (Get-EntryMap $matched) } | Select-Object -First 1
            if ($clash) { throw "Another keyless $category pin is already at ($egx,$egy) -- move one first." }
        }
        if ($newKey) {
            $dupe = $confirmed | Where-Object { $_ -ne $matched -and $_.category -eq $category -and $_.key -and $_.key.ToUpper() -eq $newKey.ToUpper() } | Select-Object -First 1
            if ($dupe) { throw "Another $category pin already uses that key." }
        }
        Set-EntryProp $matched 'key' $newKey
    }
    if ($fields.ContainsKey('gx') -or $fields.ContainsKey('gy')) {
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
    # $fields.boss/$fields.bossPal (added 2026-07-15): Tower's raid-boss NPC name and their
    # partner Pal's name -- previously static display data baked in from towers.json at
    # import with no edit path at all (unlike lv right above, which already had one).
    # Generic passthrough, no category restriction, same reasoning as lv -- Get-MapCategoryJson
    # already emits both for any row that has them. Null clears either field.
    if ($fields.ContainsKey('boss')) {
        Set-EntryProp $matched 'boss' $fields['boss']
    }
    if ($fields.ContainsKey('bossPal')) {
        Set-EntryProp $matched 'bossPal' $fields['bossPal']
    }
    Save-ConfirmedLocations $confirmed
    } catch {
        Reset-ConfirmedLocationsCache
        throw
    }
    return $matched
}

# Deletes ANY pin outright (scraped/live/custom, any of the 7 renderable categories) -- the
# other half of the post-1.0 map-cleanup ask, alongside Edit-MapEntry above. Deliberately
# a hard delete with no "blacklist" file: if the roster importer (import_scraped_rosters.ps1)
# is ever re-run and the deleted pin is still in its source roster file, it can resurface as a
# fresh verified:false row -- Anthony's explicit call (2026-07-12), simplest option, and easy
# to just delete again if it happens.
function Remove-MapEntry([string]$category, [string]$key, [string]$species, [string]$name, $gx = $null, $gy = $null, [string]$map = 'map8') {
    if ($category -notin $script:EditableMapCategories) { throw "Unsupported category: $category" }
    $confirmed = @(Get-ConfirmedLocations)
    # $gx/$gy resolve a keyless effigy (its gx/gy is its only identity, see Edit-MapEntry); $map
    # scopes that coord match to the pin's map.
    $matched = Find-ConfirmedRow $confirmed $category $key $species $name $gx $gy $map
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

# Human/Syndicate boss keys (syndicate_bosses.json, e.g. BOSS_MALE_SOLDIER02) never
# carry a zone-number prefix, unlike Field Boss species keys (e.g.
# "81_2_DESSERT_FBOSS_3") -- used below to tell the two apart from key shape alone
# when a NormalBossDefeatFlag-sourced confirmed entry hasn't been added to either
# roster yet.
function Test-SyndicateKeyShape([string]$key) { return $key -match '^BOSS_' }

# Towers (towers.json, 7 raid-boss tower locations scraped from paldb.cc, added
# 2026-07-06) were previously confirmed by Anthony under the Eagle Statue bucket, since
# walking up to one behaves like a fast-travel point in his own mental model.
# import_scraped_rosters.ps1's Import-KeylessRoster (Wanted Fugitive/Eagle Statue) skips
# inserting any keyless roster row whose exact name already belongs to a DIFFERENT
# category, which is what actually keeps a same-named Tower from also being inserted
# under those categories -- see its "skipped-cross-category-duplicate" comment. Read
# fresh every call here, same convention as the other small roster files.
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
# name match first (a keyless Tower row imported straight from towers.json has no
# "source" of its own yet), then the entry's own "source" field, then roster-membership
# fallback for legacy entries that predate "source". Originally migrate_map_schema.ps1's
# own private copy (used there for the one-time bulk backfill); moved here so
# PalWorldServerManager.ps1's Data Mine tab write endpoints (/api/datamine-mapping,
# /api/datamine-mapping-batch) can stamp a category on a freshly-typed-in entry
# immediately, instead of it sitting uncategorized -- and therefore invisible to
# Get-MapCategoryJson -- until the next manual re-run of the migration script.
#
# The tower name-match is a genuine soft spot (flagged 2026-07-15): it's the ONLY path to
# 'tower' for a row that hasn't had a key mapped to it yet, with no roster-membership
# fallback the way effigy/journal/fugitive/eagle/bounty each get below. Renaming a tower
# pin away from its exact towers.json name, before its key is ever linked, would make it
# fall through to $null here (and thus disappear from Get-MapCategoryJson('tower')) the
# next time this function re-runs on it. Once a key HAS been linked ('source' gets
# stamped 'TowerBossDefeatFlag' by /api/datamine-mapping), the switch case below takes
# over and the pin is safe from that point on regardless of its name.
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
        'ItemPickupObtainForInstanceFlag' { return 'itempickup' }
        'TowerBossDefeatFlag' { return 'tower' }
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
    }
    return $null
}
