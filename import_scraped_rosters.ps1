# import_scraped_rosters.ps1
# Phase 3 of the map-data consolidation plan. Upserts every scraped roster file
# (effigies.json, journal_locations.json, bounty_bosses.json, wanted_fugitives.json,
# eagle_travel_locations.json, towers.json) into confirmed_locations.json as
# verified:false / origin:scraped rows, using Update-CanonicalEntry's upsert rule (see
# map_data_lib.ps1) so a row Anthony has already verified is NEVER overwritten -- only its
# null fields get filled in, and only x/y/z/lv/species (never name/gx/gy/key) ever refresh
# on an unverified match.
#
# Effigy/journal have a stable key in their own roster file, so matching is exact (no
# fuzzy risk at all). Bounty matches by species (also exact), falling back to
# anonymous_boss_keys.json's key->species map for a roster row a real save key already
# resolves. Tower/fugitive/eagle have NO save-flag key in their roster at all -- matching
# reuses Find-ConfirmedByNameOrCoord's existing exact-name / callsign-suffix / coordinate-
# proximity rules, restricted to already-that-category candidates, so a wrong-category
# collision can't merge two distinct locations.
#
# Because every insert lands as verified:false, and every Merge-Confirmed*/Get-Confirmed*
# function in map_data_lib.ps1 was hardened (Phase 2) to gate its m-flag/candidate
# matching on verified, running this importer changes NO live route output by itself --
# it only pre-populates rows for Anthony (or the Desktop dataminer script, from Phase 5
# onward) to confirm later. Verify this claim yourself: diff all 8 map API routes
# before/after -Apply.
#
# ALWAYS review the dry-run match table before -Apply, especially the tower/fugitive/
# eagle sections -- that's the one place a wrong match could misfile a real location.
# Re-running with -Apply a second time should report zero further changes (idempotent).
#
# Usage: powershell -File import_scraped_rosters.ps1          (dry run, prints the table)
#        powershell -File import_scraped_rosters.ps1 -Apply   (writes confirmed_locations.json)

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

. (Join-Path $Root 'map_data_lib.ps1')
Initialize-MapDataLib -Root $Root

function Write-Step($m) { Write-Host "[import] $m" }

$confirmed = @(Get-ConfirmedLocations)
$baselineTotal = $confirmed.Count

$report = @()  # { Category, Action, Identity }
function Add-Report([string]$category, [string]$action, [string]$identity) {
    $script:report += [pscustomobject]@{ Category = $category; Action = $action; Identity = $identity }
}

# ── Effigies (605 GUID -> {x,y,z}; exact-key match, zero fuzzy risk) ───────────────────
function Import-Effigies {
    $f = Join-Path $Root 'effigies.json'
    if (-not (Test-Path -LiteralPath $f)) { Write-Step 'effigies.json missing, skipping'; return }
    $obj = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $byKey = @{}
    foreach ($c in $confirmed) { if ($c.key) { $byKey[$c.key.ToUpper()] = $c } }
    foreach ($p in $obj.PSObject.Properties) {
        $k = $p.Name.ToUpper()
        $matched = $byKey[$k]
        $grid = ConvertTo-GridXY $p.Value.x $p.Value.y
        $fields = @{ key = $p.Name; x = $p.Value.x; y = $p.Value.y; z = $p.Value.z; gx = $grid.gx; gy = $grid.gy }
        $action = Update-CanonicalEntry ([ref]$script:confirmed) $matched 'effigy' $fields
        Add-Report 'effigy' $action $p.Name
        if ($action -eq 'inserted') { $byKey[$k] = $script:confirmed[-1] }
    }
}

# ── Journals (48 {name,x,y,gx,gy,key}; exact-key match for the 21 rows that have a
# "key" -- 27 of the 48 don't (the wiki source never resolved a save-flag key for them),
# so those fall back to the same name/coord matching as the keyless rosters below,
# restricted to existing journal-category rows that ALSO have no key yet (an
# already-keyed row is never a valid merge target for a keyless roster entry). ─────────
function Import-Journals {
    $f = Join-Path $Root 'journal_locations.json'
    if (-not (Test-Path -LiteralPath $f)) { Write-Step 'journal_locations.json missing, skipping'; return }
    $arr = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $arr) { $arr = @() }
    $byKey = @{}
    foreach ($c in $confirmed) { if ($c.key) { $byKey[$c.key.ToUpper()] = $c } }
    foreach ($entry in $arr) {
        $fields = @{ name = $entry.name; x = $entry.x; y = $entry.y; gx = $entry.gx; gy = $entry.gy }
        $matched = $null
        if ($entry.key) {
            $fields['key'] = $entry.key
            $matched = $byKey[$entry.key.ToUpper()]
        }
        if (-not $matched) {
            $candidates = @($confirmed | Where-Object { $_.category -eq 'journal' -and -not $_.key })
            $matched = Find-ConfirmedByNameOrCoord $entry $candidates
        }
        $identity = if ($entry.key) { $entry.key } else { $entry.name }
        $action = Update-CanonicalEntry ([ref]$script:confirmed) $matched 'journal' $fields
        Add-Report 'journal' $action $identity
        if ($action -eq 'inserted' -and $entry.key) { $byKey[$entry.key.ToUpper()] = $script:confirmed[-1] }
    }
}

# ── Bounty (71 {species,name,x,y,z}; species match, falling back to anonymous_boss_keys
# .json's key->species map so a roster row already resolved by a real save key lines up
# with the confirmed entry that key lives on, not a duplicate) ────────────────────────
function Import-BountyBosses {
    $f = Join-Path $Root 'bounty_bosses.json'
    if (-not (Test-Path -LiteralPath $f)) { Write-Step 'bounty_bosses.json missing, skipping'; return }
    $arr = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $arr) { $arr = @() }
    $anonMap = Get-AnonymousBossKeyMap
    $bySpecies = @{}
    foreach ($c in $confirmed) {
        $sp = $null
        if ($c.key) { $sp = $anonMap[$c.key.ToUpper()]; if (-not $sp) { $sp = $c.key } }
        elseif ($c.species) { $sp = $c.species }
        if ($sp) { $bySpecies[$sp.ToUpper()] = $c }
    }
    foreach ($entry in $arr) {
        if (-not $entry.species) { continue }
        $sp = $entry.species.ToUpper()
        $matched = $bySpecies[$sp]
        $fields = @{ species = $entry.species; name = $entry.name; x = $entry.x; y = $entry.y; z = $entry.z }
        $action = Update-CanonicalEntry ([ref]$script:confirmed) $matched 'bounty' $fields
        Add-Report 'bounty' $action $entry.species
        if ($action -eq 'inserted') { $bySpecies[$sp] = $script:confirmed[-1] }
    }
}

# ── Shared name/coord matcher for the three keyless rosters (Tower/Wanted Fugitive/Eagle
# Statue) -- restricted to already-that-category, verified-or-not candidates so a
# cross-category name collision (see Phase 2's "Ice Wind Island" finding) can't merge two
# distinct locations. Reuses Find-ConfirmedByNameOrCoord's exact-name / callsign-suffix /
# proximity rules unchanged. ─────────────────────────────────────────────────────────
function Import-KeylessRoster([string]$fileName, [string]$category) {
    $f = Join-Path $Root $fileName
    if (-not (Test-Path -LiteralPath $f)) { Write-Step "$fileName missing, skipping"; return }
    $arr = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $arr) { $arr = @() }
    foreach ($entry in $arr) {
        $candidates = @($confirmed | Where-Object { $_.category -eq $category })
        $matched = Find-ConfirmedByNameOrCoord $entry $candidates
        if (-not $matched -and $entry.name) {
            # A roster row with no same-category match is about to become a new pin --
            # but if its exact name already belongs to a DIFFERENT category (e.g.
            # "Moonflower Tower" scraped into both towers.json and
            # eagle_travel_locations.json for the same real landmark, confirmed by
            # Anthony 2026-07-06 as a scrape duplicate, not two distinct locations),
            # skip it instead of creating a same-named duplicate pin in the wrong
            # category. Same reasoning as Phase 2's "Ice Wind Island" finding, just
            # applied at import time instead of discovered via a route diff.
            $crossCategoryHit = $confirmed | Where-Object { $_.name -and $_.name.ToUpper() -eq $entry.name.ToUpper() -and $_.category -ne $category } | Select-Object -First 1
            if ($crossCategoryHit) {
                Add-Report $category 'skipped-cross-category-duplicate' "$($entry.name) (already category=$($crossCategoryHit.category))"
                continue
            }
        }
        # towers.json's own "bossKey" field is NOT copied into $fields here (removed
        # 2026-07-15) -- Tower's "key" is now the same genuinely-earned, editable field every
        # other category uses (Map to key.../Record next key/manual edit), not a value
        # auto-populated from the static roster at import time. See map_data_lib.ps1's
        # Get-MapCategoryJson comment for why a pre-baked key broke Tower's status display.
        $fields = @{ name = $entry.name; x = $entry.x; y = $entry.y }
        if ($entry.PSObject.Properties['lv']) { $fields['lv'] = $entry.lv }
        if ($entry.PSObject.Properties['boss']) { $fields['boss'] = $entry.boss }
        if ($entry.PSObject.Properties['bossPal']) { $fields['bossPal'] = $entry.bossPal }
        $grid = ConvertTo-GridXY $entry.x $entry.y
        $fields['gx'] = $grid.gx
        $fields['gy'] = $grid.gy
        $action = Update-CanonicalEntry ([ref]$script:confirmed) $matched $category $fields
        Add-Report $category $action $entry.name
    }
}

Import-Effigies
Import-Journals
Import-BountyBosses
Import-KeylessRoster 'towers.json' 'tower'
Import-KeylessRoster 'wanted_fugitives.json' 'fugitive'
Import-KeylessRoster 'eagle_travel_locations.json' 'eagle'

# ── Report ──────────────────────────────────────────────────────────────────────────
Write-Step "baseline total: $baselineTotal"
foreach ($cat in @('effigy', 'journal', 'bounty', 'tower', 'fugitive', 'eagle')) {
    $rows = $report | Where-Object { $_.Category -eq $cat }
    $counts = $rows | Group-Object Action
    $summary = ($counts | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    Write-Step "$cat -> $summary"
}
Write-Step ""
Write-Step "--- inserted rows (these are the ones without an exact-key match; review the tower/fugitive/eagle entries especially) ---"
$report | Where-Object { $_.Action -eq 'inserted' } | Group-Object Category | ForEach-Object {
    Write-Step "  [$($_.Name)] $($_.Count) new rows:"
    $_.Group | ForEach-Object { Write-Step "    $($_.Identity)" }
}

$finalTotal = $confirmed.Count
Write-Step ""
Write-Step "final total: $finalTotal (baseline $baselineTotal + $($finalTotal - $baselineTotal) inserted)"

if (-not $Apply) {
    Write-Step "DRY RUN -- no file written. Review the table above, then re-run with -Apply."
    exit 0
}

Save-ConfirmedLocations $confirmed
Write-Step "confirmed_locations.json written ($finalTotal entries)."
