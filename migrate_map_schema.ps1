# migrate_map_schema.ps1
# Originally Phase 2 of the map-data consolidation plan: backfills confirmed_locations.json
# with a "category" field (effigy|journal|bounty|fugitive|eagle|tower) and an
# "origin" field (scraped|live|manual) on any entry missing them -- which, going forward,
# should only ever be a fresh row inserted by something that predates Get-CategoryForEntry
# (e.g. the Desktop dataminer script, which doesn't stamp these fields itself). Kept around
# as a re-runnable safety net, not a one-time script -- re-run it any time an uncategorized
# entry shows up.
#
# Idempotent: re-running with -Apply after a successful apply reports zero further changes.
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

# Get-CategoryForEntry (tower name match, then source, then roster-membership fallback)
# now lives in map_data_lib.ps1 -- moved there (Phase 4) so PalWorldServerManager.ps1's
# Data Mine tab write endpoints can classify a freshly-typed-in entry immediately too.

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

# Step 4 (fold the six *_confirmed_keys.json / bounty_confirmed_species.json overlay
# files into verified:true) applied once and is gone -- those files were deleted in
# Phase 4B once every route/client call moved to the single confirmed_locations.json
# "verified" flag. See git history (Phase 2 commit) for that step if it's ever needed
# as a reference.

# ── Accounting report ───────────────────────────────────────────────────────────
$finalTotal = $confirmed.Count
$finalVerifiedTrue = @($confirmed | Where-Object { $_.verified -eq $true }).Count
$categoryPartition = $confirmed | Group-Object category | Sort-Object Count -Descending

Write-Step "baseline: total=$baselineTotal verifiedTrue=$baselineVerifiedTrue"
Write-Step "category backfilled on $categoryBackfilled entries; origin backfilled on $originBackfilled entries"
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
