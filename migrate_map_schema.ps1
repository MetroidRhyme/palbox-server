# migrate_map_schema.ps1
# Phase 2 of the map-data consolidation plan. Backfills confirmed_locations.json with
# a "category" field (effigy|journal|bounty|fugitive|eagle|tower|npc|landmark) and an
# "origin" field (scraped|live|manual), then folds the six *_confirmed_keys.json /
# bounty_confirmed_species.json overlay files into the single "verified" flag they were
# always a parallel signal for. The overlay files themselves are NOT deleted yet -- the
# routes still union them in on top of confirmed_locations.json's own verified flag, so
# leaving them in place keeps output unchanged even where an overlay key had no matching
# store row (a defensive branch below inserts one; in practice this never fires against
# today's data -- every current overlay key already has a store row).
#
# Idempotent: re-running with -Apply after a successful apply reports zero further
# changes (category/origin already set are left alone; verified promotions only ever
# flip false->true, never touch an already-true entry).
#
# Usage: powershell -File migrate_map_schema.ps1          (dry run, prints the report)
#        powershell -File migrate_map_schema.ps1 -Apply   (writes confirmed_locations.json)

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

. (Join-Path $Root 'map_data_lib.ps1')
Initialize-MapDataLib -Root $Root

function Write-Step($m) { Write-Host "[migrate] $m" }

# ── Load everything up front (read-only rosters, same convention as map_data_lib.ps1) ──
$confirmed = @(Get-ConfirmedLocations)
$baselineTotal = $confirmed.Count
$baselineVerifiedTrue = @($confirmed | Where-Object { $_.verified -eq $true }).Count

function Get-KeySet([string]$fileName, [string]$field) {
    $set = New-Object System.Collections.Generic.HashSet[string]
    $f = Join-Path $Root $fileName
    if (Test-Path -LiteralPath $f) {
        try {
            foreach ($e in (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                $v = $e.$field
                if ($v) { [void]$set.Add($v.ToUpper()) }
            }
        } catch {}
    }
    return $set
}

$towerNameSet = Get-TowerNameSet
$effigyKeySet = New-Object System.Collections.Generic.HashSet[string]
$effFile = Join-Path $Root 'effigies.json'
if (Test-Path -LiteralPath $effFile) {
    $effObj = Get-Content -LiteralPath $effFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $effObj.PSObject.Properties) { [void]$effigyKeySet.Add($p.Name.ToUpper()) }
}
$journalKeySet = Get-KeySet 'journal_locations.json' 'key'
$syndicateKeySet = Get-KeySet 'syndicate_bosses.json' 'key'
$fastTravelKeySet = Get-KeySet 'fast_travel_keys.json' 'key'
$npcKeySet = Get-KeySet 'npc_keys.json' 'key'
$anonymousBossKeySet = Get-KeySet 'anonymous_boss_keys.json' 'key'

# Same classification precedence as today's live Merge-Confirmed*/Get-Confirmed* functions
# (tower name match overrides everything, then source, then roster-membership fallback for
# entries that predate the "source" field) -- reproduced here as a single decision instead
# of scattered across 7 functions, purely to LABEL existing rows. Does not change what any
# route currently returns; see map_data_lib.ps1's category-first fast path for the part
# that starts consuming this field.
function Get-CategoryForEntry($c) {
    if ($c.name -and $towerNameSet.Contains($c.name.ToUpper())) { return 'tower' }
    switch ($c.source) {
        'RelicObtainForInstanceFlag' { return 'effigy' }
        'NoteObtainForInstanceFlag'  { return 'journal' }
        'FastTravelPointUnlockFlag'  { return 'eagle' }
        'NPCTalkCountMap'            { return 'npc' }
        'NormalBossDefeatFlag'       { if (Test-SyndicateKeyShape $c.key) { return 'fugitive' } else { return 'bounty' } }
        'FindAreaFlagMap'            { return 'landmark' }
    }
    if ($c.key) {
        $k = $c.key.ToUpper()
        if ($effigyKeySet.Contains($k)) { return 'effigy' }
        if ($journalKeySet.Contains($k)) { return 'journal' }
        if ($syndicateKeySet.Contains($k)) { return 'fugitive' }
        if ($fastTravelKeySet.Contains($k)) { return 'eagle' }
        if ($npcKeySet.Contains($k)) { return 'npc' }
        if ($anonymousBossKeySet.Contains($k)) { return 'bounty' }
    }
    return 'landmark'
}

# ── Step 2: backfill category ──────────────────────────────────────────────────
$categoryBackfilled = 0
foreach ($c in $confirmed) {
    if (-not $c.PSObject.Properties['category'] -or -not $c.category) {
        $cat = Get-CategoryForEntry $c
        if ($c.PSObject.Properties['category']) { $c.category = $cat }
        else { $c | Add-Member -NotePropertyName category -NotePropertyValue $cat -Force }
        $categoryBackfilled++
    }
}

# ── Step 3: backfill origin (BEFORE any verified promotion below, so origin reflects how
# the row actually came to exist, not its post-migration verified state) ───────────────
$originBackfilled = 0
foreach ($c in $confirmed) {
    if (-not $c.PSObject.Properties['origin'] -or -not $c.origin) {
        $org = if ($c.verified -eq $true) { if ($c.source) { 'live' } else { 'manual' } } else { 'scraped' }
        if ($c.PSObject.Properties['origin']) { $c.origin = $org }
        else { $c | Add-Member -NotePropertyName origin -NotePropertyValue $org -Force }
        $originBackfilled++
    }
}

# ── Step 4: fold the six manual-confirm overlay files into verified:true ───────────────
# Each overlay file uses a DIFFERENT identity than the others (matching each one's own
# Merge-Confirmed* consumer): effigy/journal by key, bounty by species, tower/fugitive/
# eagle by name. Overlay files are NOT deleted here -- see the file header.
$overlayPromotions = @{}
$overlayInserts = @{}

function Backfill-ByKey([string]$categoryLabel, [string]$fileName) {
    $overlayPromotions[$categoryLabel] = 0
    $overlayInserts[$categoryLabel] = 0
    $keys = Get-ManualConfirmSet $fileName
    if ($keys.Count -eq 0) { return }
    $byKey = @{}
    foreach ($c in $confirmed) { if ($c.key) { $byKey[$c.key.ToUpper()] = $c } }
    foreach ($k in $keys.Keys) {
        if ($byKey.ContainsKey($k)) {
            $c = $byKey[$k]
            if ($c.verified -ne $true) { $c.verified = $true; $overlayPromotions[$categoryLabel]++ }
        } else {
            # Defensive-only branch: every overlay key in today's data already has a store
            # row (checked by hand before writing this script), so this should never fire.
            # If it ever does, insert a bare entry rather than silently dropping the confirm.
            $script:confirmed += [pscustomobject]@{
                key = $k; category = $categoryLabel; name = $null; gx = $null; gy = $null
                x = $null; y = $null; species = $null; lv = $null; source = $null
                origin = 'manual'; verified = $true
            }
            $overlayInserts[$categoryLabel]++
        }
    }
}

function Backfill-ByName([string]$categoryLabel, [string]$fileName) {
    $overlayPromotions[$categoryLabel] = 0
    $overlayInserts[$categoryLabel] = 0
    $names = Get-ManualConfirmSet $fileName
    if ($names.Count -eq 0) { return }
    $byName = @{}
    foreach ($c in $confirmed) { if ($c.name) { $byName[$c.name.ToUpper()] = $c } }
    foreach ($n in $names.Keys) {
        if ($byName.ContainsKey($n)) {
            $c = $byName[$n]
            if ($c.verified -ne $true) { $c.verified = $true; $overlayPromotions[$categoryLabel]++ }
        } else {
            $script:confirmed += [pscustomobject]@{
                key = $null; category = $categoryLabel; name = $n; gx = $null; gy = $null
                x = $null; y = $null; species = $null; lv = $null; source = $null
                origin = 'manual'; verified = $true
            }
            $overlayInserts[$categoryLabel]++
        }
    }
}

function Backfill-BySpecies([string]$fileName) {
    $overlayPromotions['bounty'] = 0
    $overlayInserts['bounty'] = 0
    $species = Get-ManualConfirmSet $fileName
    if ($species.Count -eq 0) { return }
    $anonMap = Get-AnonymousBossKeyMap
    $bySpecies = @{}
    foreach ($c in $confirmed) {
        if (-not $c.key) { continue }
        $sp = $anonMap[$c.key.ToUpper()]
        if (-not $sp) { $sp = $c.key }
        $bySpecies[$sp.ToUpper()] = $c
    }
    foreach ($sp in $species.Keys) {
        if ($bySpecies.ContainsKey($sp)) {
            $c = $bySpecies[$sp]
            if ($c.verified -ne $true) { $c.verified = $true; $overlayPromotions['bounty']++ }
        } else {
            $script:confirmed += [pscustomobject]@{
                key = $null; category = 'bounty'; name = $null; gx = $null; gy = $null
                x = $null; y = $null; species = $sp; lv = $null; source = $null
                origin = 'manual'; verified = $true
            }
            $overlayInserts['bounty']++
        }
    }
}

Backfill-ByKey 'effigy' 'effigy_confirmed_keys.json'
Backfill-ByKey 'journal' 'journal_confirmed_keys.json'
Backfill-BySpecies 'bounty_confirmed_species.json'
Backfill-ByName 'tower' 'tower_confirmed_keys.json'
Backfill-ByName 'fugitive' 'fugitive_confirmed_keys.json'
Backfill-ByName 'eagle' 'eagle_confirmed_keys.json'

# ── Accounting report ───────────────────────────────────────────────────────────
$finalTotal = $confirmed.Count
$finalVerifiedTrue = @($confirmed | Where-Object { $_.verified -eq $true }).Count
$categoryPartition = $confirmed | Group-Object category | Sort-Object Count -Descending

Write-Step "baseline: total=$baselineTotal verifiedTrue=$baselineVerifiedTrue"
Write-Step "category backfilled on $categoryBackfilled entries; origin backfilled on $originBackfilled entries"
foreach ($k in $overlayPromotions.Keys) {
    Write-Step "overlay fold [$k]: $($overlayPromotions[$k]) promoted to verified:true, $($overlayInserts[$k]) new rows inserted"
}
Write-Step "category partition:"
$categoryPartition | ForEach-Object { Write-Step ("  {0,-10} {1,4}" -f $_.Name, $_.Count) }
$partitionSum = ($categoryPartition | Measure-Object Count -Sum).Sum
Write-Step "partition sum: $partitionSum (must equal final total: $finalTotal)"
Write-Step "final: total=$finalTotal verifiedTrue=$finalVerifiedTrue"

if ($partitionSum -ne $finalTotal) {
    throw "Partition sum ($partitionSum) does not equal final total ($finalTotal) -- an entry has no category or was double-counted. Aborting before write."
}

if (-not $Apply) {
    Write-Step "DRY RUN -- no file written. Re-run with -Apply to write confirmed_locations.json."
    exit 0
}

Save-ConfirmedLocations $confirmed
Write-Step "confirmed_locations.json written ($finalTotal entries, $finalVerifiedTrue verified)."
