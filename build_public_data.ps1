# build_public_data.ps1
# Shared data builder for the PalBox public site. Emits the JSON data files the
# read-only dashboard consumes, into <OutDir>\data\... Two callers use it:
#   * gen_public_site.ps1  -Mode Static    -> effigies.json + pal-species.json
#       (the rarely-changing files that ship with the Pages "shell" deploy)
#   * sync_public_data.ps1 -Mode Frequent  -> the per-save, per-player sets that
#       are pushed to R2 every poll (pals/paldeck/eggs/player-effigies/settings)
#
# Splitting the two is the whole point of the R2 architecture: the frequent data
# updates via cheap R2 object puts with NO Cloudflare Pages deploy (so we never
# touch the 500-deploys/month cap), while the static shell deploys only when the
# UI changes. The per-user scoping (data/by-player/<guid>) is produced here exactly
# as before; the Worker still gates who may read which key -- see site_src\_worker.js.
#
# This logic was extracted verbatim from gen_public_site.ps1 (which used to build
# everything inline) so there is a single source of truth for the data shapes.

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Root,
  [Parameter(Mandatory)][string]$OutDir,
  [ValidateSet('Frequent', 'Static', 'All')][string]$Mode = 'All'
)

$ErrorActionPreference = 'Stop'

$SaveGamesRoot = Join-Path $Root 'Pal\Saved\SaveGames\0'
$IniPath = Join-Path $Root 'Pal\Saved\Config\WindowsServer\GameUserSettings.ini'
$EffigiesLocal = Join-Path $Root 'effigies.json'
$BountyBossesLocal = Join-Path $Root 'bounty_bosses.json'
$DashBase = 'http://localhost:8213'

$PubData = Join-Path $OutDir 'data'
$PubAll = Join-Path $PubData 'all'
$PubByPlayer = Join-Path $PubData 'by-player'
$PubEffig = Join-Path $PubData 'player-effigies'
$PubNotes = Join-Path $PubData 'player-notes'
$PubBounty = Join-Path $PubData 'player-bounties'
$PubNPCs = Join-Path $PubData 'player-npcs'
$PubLocation = Join-Path $PubData 'player-location'
$PubFugitives = Join-Path $PubData 'player-fugitives'
$PubEagles = Join-Path $PubData 'player-eagles'

$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-Step($m) { Write-Host "[data] $m" }

# ── Resolve the active world save directory ────────────────────────────────────
function Get-ActiveSaveDir {
  if (-not (Test-Path -LiteralPath $IniPath)) { throw "GameUserSettings.ini not found at $IniPath" }
  $m = Select-String -LiteralPath $IniPath -Pattern 'DedicatedServerName=([0-9A-Fa-f]+)'
  if (-not $m) { throw "Could not find DedicatedServerName in $IniPath" }
  $guid = $m.Matches[0].Groups[1].Value
  $dir = Join-Path $SaveGamesRoot $guid
  if (-not (Test-Path -LiteralPath $dir)) { throw "Active save dir not found: $dir" }
  return $dir
}

# ── Fetch raw JSON text from the live dashboard (or $null on any failure) ───────
# Only /api/file-settings still goes through this -- everything else below now invokes
# its reader directly (see the Frequent block), since this builder runs INSIDE the same
# poll cycle that would otherwise call back into the dashboard's own single-threaded
# HTTP listener for no benefit. -TimeoutSec dropped from 180 to 30 accordingly: the one
# remaining caller is a cheap settings-file read, not a full save-reader parse.
function Get-DashJson($pathAndQuery) {
  try {
    $r = Invoke-WebRequest -Uri ($DashBase + $pathAndQuery) -UseBasicParsing -TimeoutSec 30
    if ($r.StatusCode -eq 200 -and $r.Content) { return [string]$r.Content }
  } catch {
    Write-Step "live dashboard unreachable for $pathAndQuery ($($_.Exception.Message)); will use reader fallback"
  }
  return $null
}

# ── Hand-confirmed map locations (Anthony's own live-play data) ────────────────
# confirmed_locations.json holds flag-key -> {name,gx,gy} entries Anthony has
# personally verified in-game via a companion save-watching script (Desktop
# DataMine\palworld_full_save_dump.py, see the palworld-project skill). These
# are the source of truth wherever they overlap a key in effigies.json /
# journal_locations.json / bounty_bosses.json, which were sourced from a public
# GitHub dataset or third-party wiki guides. Mirrors the same-named functions
# in PalWorldServerManager.ps1 so the admin dashboard and this static bundle
# always agree -- kept as an independent copy rather than a shared module,
# matching this codebase's existing convention (no dot-sourcing between these
# two files).
$ConfirmedLocationsLocal = Join-Path $Root 'confirmed_locations.json'
$script:confirmedLocationsCache = $null
function Get-ConfirmedLocations {
  if ($null -eq $script:confirmedLocationsCache) {
    if (Test-Path -LiteralPath $ConfirmedLocationsLocal) {
      # NOTE: do NOT wrap the pipeline in @() here -- under Windows PowerShell 5.1 (this
      # script also runs there, via the Manager's automated Frequent sync),
      # ConvertFrom-Json emits an already-parsed JSON array as a SINGLE pipeline object
      # rather than enumerating it, so @() re-wraps that one object into a bogus
      # 1-element array (confirmed via direct test: a 47-element array collapsed to
      # Count=1, which then threw "cannot call a method on a null-valued expression"
      # once code assumed a normal array). Plain assignment handles 0/1/N-element JSON
      # arrays correctly on both PS 5.1 and PS 7.
      try { $script:confirmedLocationsCache = Get-Content -LiteralPath $ConfirmedLocationsLocal -Raw -Encoding UTF8 | ConvertFrom-Json }
      catch { $script:confirmedLocationsCache = @() }
      if ($null -eq $script:confirmedLocationsCache) { $script:confirmedLocationsCache = @() }
    } else {
      $script:confirmedLocationsCache = @()
    }
  }
  return $script:confirmedLocationsCache
}

# gx/gy (in-game grid coords) <-> real world x/y transform constants -- single source of
# truth in map_constants.json (also read by PalWorldServerManager.ps1's own copy of
# ConvertTo-WorldXY) so the two can't drift apart the way individual map categories already
# have in the past (Chillet/WeaselDragon, Landmarks misclassification bugs).
$script:mapConstCache = $null
function Get-MapConstants {
  if ($null -eq $script:mapConstCache) {
    $path = Join-Path $Root 'map_constants.json'
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

# Keys/species Anthony has manually clicked "Confirm" on in an admin dashboard popup -- each
# kept in its own file rather than confirmed_locations.json, which stays owned exclusively
# by the Desktop dataminer script. See the matching PalWorldServerManager.ps1 function's
# comment for why this is a separate signal from "picked up/defeated in-game".
function Get-ManualConfirmSet([string]$fileName) {
  $keys = @{}
  $f = "$Root\$fileName"
  if (Test-Path -LiteralPath $f) {
    try {
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
# Anthony asked for the full scraped roster back so he can see unconfirmed effigies he hasn't
# logged yet, just tagged with whether he's manually confirmed each one -- so this one
# function OVERLAYS instead of filtering, using the scraped x/y/z as-is (more accurate than
# the gx/gy round-trip) and adding an m:true flag for an exact GUID-key match against EITHER
# confirmed_locations.json (the Desktop script) OR effigy_confirmed_keys.json (a manual
# dashboard click). NOTE: build with -InputObject rather than piping into ConvertTo-Json --
# piping a PowerShell array with exactly one element unwraps it into a bare JSON object
# instead of a 1-item array (confirmed via direct test), which would break the client's
# .forEach() the moment a filtered list happens to have one entry.
function Merge-ConfirmedEffigies([string]$json) {
  $confirmed = Get-ConfirmedLocations
  $manualKeys = @{}
  foreach ($c in $confirmed) { if ($c.key) { $manualKeys[$c.key.ToUpper()] = $true } }
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

function Merge-ConfirmedJournals([string]$json) {
  $confirmed = Get-ConfirmedLocations
  # No @() wrap -- see the note on Get-ConfirmedLocations above.
  try { $arr = $json | ConvertFrom-Json } catch { $arr = @() }
  if ($null -eq $arr) { $arr = @() }
  $byKey = @{}
  foreach ($c in $confirmed) { if ($c.key) { $byKey[$c.key.ToUpper()] = $c } }
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

# Resolve a confirmed key to a bounty species via anonymous_boss_keys.json (the world map
# is fixed, so a confirmed key/species pair holds for every save -- see the
# palbox-bounty-tracker skill) plus literal species-named keys (BlueDragon/FairyDragon,
# the two that self-name-tag in the save). Shared by Merge-ConfirmedBounty and
# Get-ConfirmedLandmarks (which needs to know a key is already claimed as a bounty
# species so it doesn't ALSO show up as a landmark).
function Get-AnonymousBossKeyMap {
  $anonMap = @{}
  $anonFile = Join-Path $Root 'anonymous_boss_keys.json'
  if (Test-Path -LiteralPath $anonFile) {
    try {
      foreach ($e in (Get-Content -LiteralPath $anonFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($e.key -and $e.species) { $anonMap[$e.key.ToUpper()] = $e.species }
      }
    } catch {}
  }
  return $anonMap
}

# Human/Syndicate boss keys (syndicate_bosses.json, e.g. BOSS_MALE_SOLDIER02) never carry a
# zone-number prefix, unlike Field Boss species keys (e.g. "81_2_DESSERT_FBOSS_3") -- used
# below to tell the two apart from key shape alone when a NormalBossDefeatFlag-sourced
# confirmed entry hasn't been added to either roster yet.
function Test-SyndicateKeyShape([string]$key) { return $key -match '^BOSS_' }

# Towers (towers.json, 7 raid-boss tower locations scraped from paldb.cc, added 2026-07-06)
# were previously confirmed by Anthony under the Eagle Statue bucket, since walking up to
# one behaves like a fast-travel point in his own mental model.
# Merge-ConfirmedWantedFugitives/EagleStatues below explicitly exclude any confirmed entry
# whose name matches one of these 7 so it routes to Merge-ConfirmedTowers instead.
function Get-TowerNameSet {
  $names = New-Object System.Collections.Generic.HashSet[string]
  $f = Join-Path $Root 'towers.json'
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
# Fugitive/Eagle Statue). Unlike Journals (matched by a stable "key") or Bounty (matched by
# species), paldb's own scrape carries no save-flag key or species id at all -- only a
# display name + gx/gy -- so a confirmed_locations.json entry can only line up by exact name
# (primary), a short-callsign suffix match (added 2026-07-06, mirroring
# PalWorldServerManager.ps1's copy: Anthony's confirmed Wanted Fugitive entries are recorded
# under the short in-game callsign alone, e.g. "Aloha", while the paldb roster's display name
# is the full title, e.g. "Pineapple Pizza Enthusiast Aloha" -- a confirmed entry whose short
# name is the roster name's final word, on a word boundary, counts as a match), or close
# gx/gy proximity (fallback, for an entry with no name set yet).
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
# Get-TowerNameSet above for why this needed splitting out of Eagle Statues. `m:true` marks
# a name/coord match against confirmed_locations.json OR a manual dashboard-popup confirm
# (tower_confirmed_keys.json). No per-player "cleared" signal exists yet for raid towers, so
# status can only reach confirmed (yellow) or unconfirmed (red) until that's built.
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

function Merge-ConfirmedBounty([string]$json) {
  $confirmed = Get-ConfirmedLocations
  # No @() wrap -- see the note on Get-ConfirmedLocations above.
  try { $arr = $json | ConvertFrom-Json } catch { $arr = @() }
  if ($null -eq $arr) { $arr = @() }
  $anonMap = Get-AnonymousBossKeyMap
  # Reverse of $anonMap (species -> raw NormalBossDefeatFlag key) -- mirrors
  # PalWorldServerManager.ps1's copy, kept in sync for data-shape parity even though the
  # public site doesn't render this field.
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
    # Anthony's dataminer script already told us (via confirmed_locations.json's "source"
    # field) that this key is a NormalBossDefeatFlag hit, and its shape says Field Boss, not
    # Wanted Fugitive -- show it now from his own confirmed name/coords rather than waiting
    # on a manual anonymous_boss_keys.json edit, if it isn't already covered by a
    # bounty_bosses.json roster entry above.
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
# (added 2026-07-06, replacing the old confirmed-only/no-base-roster version). Excludes any
# confirmed entry whose name is a Tower (Get-TowerNameSet above) -- those route to
# Merge-ConfirmedTowers instead. The real save-flag key still comes through on a match (from
# the confirmed entry itself) so per-player defeat tracking (player-fugitives) keeps working
# for anything Anthony has actually confirmed.
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

# "Eagle Statues" -- OVERLAYS the 83-entry paldb-scraped eagle_travel_locations.json roster
# (added 2026-07-06, replacing the old confirmed-only/no-base-roster version; paldb's own
# raw 89-entry Fast Travel list had 6 broken "en Text"/blank placeholder rows sitting
# exactly on Tower coordinates, filtered out when eagle_travel_locations.json was built).
# Same exclusion/matching/key-passthrough pattern as Merge-ConfirmedWantedFugitives above.
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
# fallback for entries confirmed before "source" existed. Gets per-player tracking via
# /api/player-npcs, bundled separately in the Frequent branch below.
function Get-ConfirmedNPCs {
  $confirmed = Get-ConfirmedLocations
  $roster = New-Object System.Collections.Generic.HashSet[string]
  $npcFile = Join-Path $Root 'npc_keys.json'
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

# "Landmarks" -- everything else in confirmed_locations.json that isn't already plotted
# as an effigy, journal note, bounty boss, Wanted Fugitive, Eagle Statue, or NPC --
# discovered-area markers and any other named spot Anthony has confirmed.
function Get-ConfirmedLandmarks {
  $confirmed = Get-ConfirmedLocations
  $claimed = New-Object System.Collections.Generic.HashSet[string]
  $effFile = Join-Path $Root 'effigies.json'
  if (Test-Path -LiteralPath $effFile) {
    try {
      $effObj = Get-Content -LiteralPath $effFile -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $effObj.PSObject.Properties) { [void]$claimed.Add($p.Name.ToUpper()) }
    } catch {}
  }
  $journalFile = Join-Path $Root 'journal_locations.json'
  if (Test-Path -LiteralPath $journalFile) {
    try {
      foreach ($e in (Get-Content -LiteralPath $journalFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
      }
    } catch {}
  }
  $anonMap = Get-AnonymousBossKeyMap
  $bountyFile = Join-Path $Root 'bounty_bosses.json'
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
  $synFile = Join-Path $Root 'syndicate_bosses.json'
  if (Test-Path -LiteralPath $synFile) {
    try {
      foreach ($e in (Get-Content -LiteralPath $synFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
      }
    } catch {}
  }
  $ftFile = Join-Path $Root 'fast_travel_keys.json'
  if (Test-Path -LiteralPath $ftFile) {
    try {
      foreach ($e in (Get-Content -LiteralPath $ftFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
      }
    } catch {}
  }
  $npcFile = Join-Path $Root 'npc_keys.json'
  if (Test-Path -LiteralPath $npcFile) {
    try {
      foreach ($e in (Get-Content -LiteralPath $npcFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($e.key) { [void]$claimed.Add($e.key.ToUpper()) }
      }
    } catch {}
  }
  # Tower/Wanted Fugitive/Eagle Statue (added 2026-07-06) match confirmed entries by NAME,
  # not by a GUID-roster membership check like the blocks above -- claim by name here too so
  # a matched entry doesn't leak into Landmarks.
  $namedRosterNames = New-Object System.Collections.Generic.HashSet[string]
  foreach ($rn in @('towers.json', 'wanted_fugitives.json', 'eagle_travel_locations.json')) {
    $rf = Join-Path $Root $rn
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
  # FastTravelPointUnlockFlag/NPCTalkCountMap always resolve into Eagle Statues/NPCs above;
  # NormalBossDefeatFlag always resolves into either Wanted Fugitive or Field Boss above
  # (species-matched or not -- Merge-ConfirmedBounty's fallback branch shows it either way),
  # so any of these three sources means it's claimed even before the roster files above catch
  # up. Only FindAreaFlagMap (genuine discovered-zone landmarks) and entries with no "source"
  # at all (pre-dating this field) fall through to Landmarks below.
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

# ── Run a Python reader and return its stdout as a single string ───────────────
# Under $ErrorActionPreference = 'Stop' (set above), a native command's stderr line
# becomes a terminating exception the instant it's written -- even with "2>$null" on
# the call, since that redirect only takes effect after the error-vs-stop check. That
# turned every stderr WARNING (not just real failures) into an aborted build with only
# the first traceback line as the message and the exit-code check below as dead code
# (2026-07-02: a stray warning took the sync down for ~15 hours). Fix: relax EAP to
# 'Continue' for just this native call (local to the function scope, so it doesn't
# affect the rest of the script) and merge both streams so stderr lines arrive as
# ErrorRecord objects we can separate out and report in full, rather than as thrown
# exceptions.
function Invoke-Reader([string[]]$ScriptArgs) {
  $ErrorActionPreference = 'Continue'
  $raw = & python @ScriptArgs 2>&1
  $code = $LASTEXITCODE
  $out = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
  $errText = ($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
  if ($code -ne 0 -or -not $out) {
    throw "python $($ScriptArgs -join ' ') failed (exit ${code}):`n$errText"
  }
  return ($out -join "`n")
}

$doFreq = ($Mode -eq 'Frequent' -or $Mode -eq 'All')
$doStatic = ($Mode -eq 'Static' -or $Mode -eq 'All')

New-Item -ItemType Directory -Force -Path $PubData | Out-Null

# ════════════════════════════════════════════════════════════════════════════════
# FREQUENT: per-save, per-player data (-> R2). Rebuilt fresh each run so a removed
# player never lingers in the output set.
# ════════════════════════════════════════════════════════════════════════════════
if ($doFreq) {
  foreach ($d in @($PubAll, $PubEffig, $PubNotes, $PubBounty, $PubNPCs, $PubLocation, $PubFugitives, $PubEagles)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  Get-ChildItem -LiteralPath $PubAll -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubEffig -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubNotes -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubBounty -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubNPCs -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubLocation -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubFugitives -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubEagles -File -ErrorAction SilentlyContinue | Remove-Item -Force
  if (Test-Path -LiteralPath $PubByPlayer) { Remove-Item -LiteralPath $PubByPlayer -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $PubByPlayer | Out-Null

  $saveDir = Get-ActiveSaveDir
  Write-Step "active save dir: $saveDir"

  # ── Fetch full data sets ─────────────────────────────────────────────────────
  # Invoke the readers directly rather than trying the live dashboard's HTTP API first --
  # this builder IS the thing the dashboard's own routes call under the hood, so going
  # through HTTP here just adds a round-trip (and a stall risk on the single-threaded
  # listener) for no benefit. Get-DashJson is kept only for /api/file-settings below,
  # which has no reader equivalent to call directly.
  Write-Step "fetching pals + paldeck"
  # Reader output is the same shape the /api/pals handler emits (sans live-name enrichment).
  $palsJson = Invoke-Reader @((Join-Path $Root 'pal_team_reader.py'), $saveDir)
  # pal_save_reader emits {players:[{guid,name,tribeCaptureCount,counts}]}; the dashboard
  # handler reshapes tribeCaptureCount -> total, so we do the same.
  $rawPlayers = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $saveDir) | ConvertFrom-Json
  $outPlayers = @($rawPlayers.players | ForEach-Object {
      $name = if ($_.PSObject.Properties['name'] -and $_.name) { [string]$_.name } else { ([string]$_.guid).Substring(0, 8) }
      [ordered]@{ guid = [string]$_.guid; name = $name; total = [int]$_.tribeCaptureCount; counts = $_.counts }
    })
  $paldeckJson = (@{ players = $outPlayers } | ConvertTo-Json -Depth 6 -Compress)

  $palsObj = $palsJson | ConvertFrom-Json
  $paldeckObj = $paldeckJson | ConvertFrom-Json

  # Full ("admin") sets under data/all/ -- the Worker serves these only to admins and
  # blocks direct client access. There is intentionally NO unscoped data/pals.json.
  Write-Step "writing data/all/*.json (admin set)"
  [System.IO.File]::WriteAllText((Join-Path $PubAll 'pals.json'), $palsJson, $utf8)
  [System.IO.File]::WriteAllText((Join-Path $PubAll 'paldeck.json'), $paldeckJson, $utf8)

  # Per-player sets under data/by-player/<guid>/ : only the pals a player may VIEW --
  # their own party/palbox plus their guild's base camps (per container.viewers from
  # the reader). The Worker maps an authenticated email -> guid and serves the match.
  Write-Step "writing data/by-player/<guid>/*.json (scoped sets)"
  $cidViewers = @{}
  foreach ($prop in $palsObj.containers.PSObject.Properties) { $cidViewers[$prop.Name] = @($prop.Value.viewers) }
  foreach ($pp in @($paldeckObj.players)) {
    $guid = [string]$pp.guid
    if (-not $guid) { continue }
    $prefix = $guid.Substring(0, 8).ToUpperInvariant()
    $fpals = @($palsObj.pals | Where-Object { $cidViewers[$_.container] -contains $prefix })
    $fcont = [ordered]@{}
    foreach ($prop in $palsObj.containers.PSObject.Properties) {
      if (@($prop.Value.viewers) -contains $prefix) { $fcont[$prop.Name] = $prop.Value }
    }
    $prec = @($palsObj.players | Where-Object { $_.prefix -eq $prefix })
    if (-not $prec) { $prec = @([pscustomobject]@{ prefix = $prefix; name = $pp.name }) }
    $scoped = [ordered]@{ players = $prec; containers = $fcont; pals = $fpals }
    $dir = Join-Path $PubByPlayer $guid
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'pals.json'), ($scoped | ConvertTo-Json -Depth 12 -Compress), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $dir 'paldeck.json'), (@{ players = @($pp) } | ConvertTo-Json -Depth 8 -Compress), $utf8)
  }

  # ── eggs (per-player) ────────────────────────────────────────────────────────
  # Eggs in base storage joined to their hatch species + owner. The admin set has
  # every egg (incl. ghost/orphaned ones); each player's scoped set has only the eggs
  # they own. Owner is the 8-hex player prefix, matching the by-player guid prefix.
  Write-Step "writing data/all/eggs.json + by-player eggs"
  # --no-names: this builder already has an authoritative guid->name roster from
  # paldeckObj above (pal_save_reader.py's own name resolution) -- letting the egg reader
  # resolve names too would decompress + NickName-scan Level.sav a second time for data
  # this script immediately overwrites anyway. Names are backfilled from that roster below.
  $eggsJson = Invoke-Reader @((Join-Path $Root 'pal_egg_reader.py'), $saveDir, '--no-names')
  if ($eggsJson) {
    $eggsObj = $eggsJson | ConvertFrom-Json
    $nameByPrefix = @{}
    foreach ($pp in @($paldeckObj.players)) {
      $guid = [string]$pp.guid; if (-not $guid) { continue }
      $nameByPrefix[$guid.Substring(0, 8).ToUpperInvariant()] = [string]$pp.name
    }
    # Backfill each egg's ownerName (blank -- --no-names above skipped it) from the paldeck
    # roster. The UI reads e.ownerName directly per egg (group headers, location tags), not
    # just the top-level owners roster below.
    foreach ($egg in @($eggsObj.eggs)) {
      $pfx = ([string]$egg.owner).ToUpperInvariant()
      if ($pfx -and $nameByPrefix.ContainsKey($pfx)) { $egg.ownerName = $nameByPrefix[$pfx] }
    }
    # Player-name roster (8-hex prefix -> name) so the Eggs owner filter keeps every player
    # even when they have zero eggs right now. The ADMIN set gets the full roster; each
    # scoped set gets ONLY that player (so a scoped viewer never sees the other players'
    # names in their filter).
    $allOwners = @()
    foreach ($pp in @($paldeckObj.players)) {
      $guid = [string]$pp.guid; if (-not $guid) { continue }
      $allOwners += [ordered]@{ prefix = $guid.Substring(0, 8).ToUpperInvariant(); name = [string]$pp.name }
    }
    # Re-serialize the admin set (instead of writing it verbatim) so the roster rides along.
    $eggsObj | Add-Member -NotePropertyName owners -NotePropertyValue $allOwners -Force
    [System.IO.File]::WriteAllText((Join-Path $PubAll 'eggs.json'), ($eggsObj | ConvertTo-Json -Depth 12 -Compress), $utf8)
    foreach ($pp in @($paldeckObj.players)) {
      $guid = [string]$pp.guid
      if (-not $guid) { continue }
      $prefix = $guid.Substring(0, 8).ToUpperInvariant()
      $mine = @($eggsObj.eggs | Where-Object { ([string]$_.owner).ToUpperInvariant() -eq $prefix })
      # Per-player summary: only their own eggs; ghost/orphan stats are admin-only.
      $sum = [ordered]@{ realEggs = $mine.Count; available = $mine.Count; orphanContainerEggs = 0; orphanContainers = 0; orphanRecords = 0 }
      # Force a single-element array so ConvertTo-Json emits a JSON array, not a bare object.
      $myOwners = @([ordered]@{ prefix = $prefix; name = [string]$pp.name })
      $dir = Join-Path $PubByPlayer $guid
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      [System.IO.File]::WriteAllText((Join-Path $dir 'eggs.json'), ([ordered]@{ eggs = $mine; owners = $myOwners; summary = $sum } | ConvertTo-Json -Depth 12 -Compress), $utf8)
    }
  } else {
    Write-Step "WARNING: no egg data available; Eggs tab will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubAll 'eggs.json'), '{"eggs":[],"summary":{}}', $utf8)
  }

  # -- player-effigies/player-notes/player-bounties/player-npcs/player-fugitives/
  #    player-eagles/<guid>.json (one call per player instead of six) ------------
  # pal_save_reader.py's playerall mode decompresses each player's small .sav ONCE and
  # returns all six sections in one JSON, instead of six separate process spawns each
  # re-decompressing the same file (which is what this loop used to do, calling
  # effigies/notes/bounties/npcs/fugitives/eagles modes one at a time). Each section's
  # shape is unchanged ({"guid":...,"collected":[...]}), so the split below just wraps
  # each field into the same per-player file this always wrote.
  Write-Step "building data/player-effigies, -notes, -bounties, -npcs, -fugitives, -eagles/*.json"
  foreach ($p in @($paldeckObj.players)) {
    $guid = [string]$p.guid
    if (-not $guid) { continue }
    try {
      $pa = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $saveDir, 'playerall', $guid) | ConvertFrom-Json
    } catch {
      Write-Step "  skipped playerall for $guid ($($_.Exception.Message))"
      continue
    }
    $sections = @{
      $PubEffig     = $pa.effigies
      $PubNotes     = $pa.notes
      $PubBounty    = $pa.bounties
      $PubNPCs      = $pa.npcs
      $PubFugitives = $pa.fugitives
      $PubEagles    = $pa.eagles
    }
    foreach ($dir in $sections.Keys) {
      $body = [ordered]@{ guid = $guid; collected = $sections[$dir] } | ConvertTo-Json -Compress
      [System.IO.File]::WriteAllText((Join-Path $dir ($guid + '.json')), $body, $utf8)
    }
  }

  # ── player-location/<guid>.json (live world position, one per player) ────────
  # Separate from playerall above: this comes from pal_team_reader.py's "locations" mode
  # (Translation/Rotation via the GVAS parser), not pal_save_reader.py's byte-scanner, so
  # there's no shared decompress to fold it into.
  Write-Step "building data/player-location/*.json"
  foreach ($p in @($paldeckObj.players)) {
    $guid = [string]$p.guid
    if (-not $guid) { continue }
    try {
      $pl = Invoke-Reader @((Join-Path $Root 'pal_team_reader.py'), $saveDir, 'locations', $guid)
    } catch {
      Write-Step "  skipped location for $guid ($($_.Exception.Message))"
      continue
    }
    $one = $null
    try { $one = @(($pl | ConvertFrom-Json).players)[0] } catch {}
    $body = if ($one) { [ordered]@{ x = $one.x; y = $one.y; z = $one.z; yawDeg = $one.yawDeg } } else { [ordered]@{} }
    [System.IO.File]::WriteAllText((Join-Path $PubLocation ($guid + '.json')), ($body | ConvertTo-Json -Compress), $utf8)
  }

  # ── Server settings (read-only view) ─────────────────────────────────────────
  # Publishes data/settings.json for the public Settings tab. The entire 'Server'
  # category (server/admin passwords, ports, RCON/REST toggles) is dropped here at the
  # data layer so no secret is ever written to a file the browser can fetch -- the
  # client renderer also hides that category. The list below MUST stay in sync with the
  # META entries whose category is 'Server' in PalWorldServerManager.ps1. Any key whose
  # name contains "Password" is dropped as a backstop, even if not listed.
  Write-Step "building data/settings.json"
  $ServerCatKeys = @(
    'ServerName', 'ServerDescription', 'ServerPassword', 'AdminPassword', 'PublicPort',
    'ServerPlayerMaxNum', 'CoopPlayerMaxNum', 'RCONEnabled', 'RCONPort', 'RESTAPIEnabled',
    'RESTAPIPort', 'bUseAuth', 'bIsUseBackupSaveData', 'bAllowClientMod', 'bShowPlayerList',
    'ChatPostLimitPerMinute', 'bIsShowJoinLeftMessage'
  )
  $settingsRaw = Get-DashJson '/api/file-settings'
  if ($settingsRaw) {
    $sObj = $settingsRaw | ConvertFrom-Json
    $activeOut = [ordered]@{}
    $defOut = [ordered]@{}
    if ($sObj.active) {
      foreach ($p in $sObj.active.PSObject.Properties) {
        if ($ServerCatKeys -notcontains $p.Name -and $p.Name -notmatch 'Password') { $activeOut[$p.Name] = $p.Value }
      }
    }
    if ($sObj.defaults) {
      foreach ($p in $sObj.defaults.PSObject.Properties) {
        if ($ServerCatKeys -notcontains $p.Name -and $p.Name -notmatch 'Password') { $defOut[$p.Name] = $p.Value }
      }
    }
    $pubSettings = [ordered]@{ active = $activeOut; defaults = $defOut }
    [System.IO.File]::WriteAllText((Join-Path $PubData 'settings.json'), ($pubSettings | ConvertTo-Json -Depth 6 -Compress), $utf8)
    # Hard guard: a leaked password here would be world-readable to every signed-in player.
    # Check KEY NAMES only -- a setting *value* that legitimately contains the word
    # "password" (e.g. a server description like "Password protected") must not trip the
    # guard, because throwing here aborts the whole Frequent build and kills the entire
    # R2 sync (pals/eggs/everything), not just settings.
    $leakKeys = @($activeOut.Keys) + @($defOut.Keys) | Where-Object { $_ -match 'Password' }
    if ($leakKeys) { throw "settings.json contains a Password key ($($leakKeys -join ', ')) -- redaction failed" }
  } else {
    Write-Step "  dashboard unreachable; writing empty settings.json"
    [System.IO.File]::WriteAllText((Join-Path $PubData 'settings.json'), '{"active":{},"defaults":{}}', $utf8)
  }
}

# ════════════════════════════════════════════════════════════════════════════════
# STATIC: rarely-changing data that ships with the Pages shell (NOT R2).
# ════════════════════════════════════════════════════════════════════════════════
if ($doStatic) {
  # ── effigies.json (static location data) ─────────────────────────────────────
  Write-Step "building data/effigies.json"
  $effJson = $null
  if (Test-Path -LiteralPath $EffigiesLocal) {
    $effJson = [System.IO.File]::ReadAllText($EffigiesLocal)
  } else {
    $effJson = Get-DashJson '/api/effigies'
  }
  if (-not $effJson) { throw "No effigy data available (missing $EffigiesLocal and dashboard unreachable)" }
  # Overlay Anthony's own live-play-confirmed coordinates on top of the
  # public/upstream data -- see Merge-ConfirmedEffigies above.
  [System.IO.File]::WriteAllText((Join-Path $PubData 'effigies.json'), (Merge-ConfirmedEffigies $effJson), $utf8)

  # ── journals.json (static journal/diary note locations, game-world fixed) ────
  # Built once (converted from wiki-published in-game X/Y); bundled as a static file.
  # The dashboard serves the same JSON at /api/journals, which the data-fetch repoint
  # points here. Anthony's own confirmed coordinates/names (Merge-ConfirmedJournals)
  # override the wiki-sourced base data wherever they overlap.
  Write-Step "building data/journals.json"
  $journalsLocal = Join-Path $Root 'journal_locations.json'
  if (Test-Path -LiteralPath $journalsLocal) {
    $journalsJson = [System.IO.File]::ReadAllText($journalsLocal)
    [System.IO.File]::WriteAllText((Join-Path $PubData 'journals.json'), (Merge-ConfirmedJournals $journalsJson), $utf8)
  } else {
    Write-Step "WARNING: journal_locations.json missing; journal overlay will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubData 'journals.json'), '[]', $utf8)
  }

  # ── bounty-bosses.json (static bounty-boss / named-Alpha locations, game-world fixed) ──
  # Curated from paldb's DT_PaldexDistributionData BOSS_<Species> entries with exactly one
  # fixed world location; bundled as a static file. The dashboard serves the same JSON at
  # /api/bounty-bosses, which the data-fetch repoint points here. Anthony's own confirmed
  # coordinates/names (Merge-ConfirmedBounty) override the paldb-sourced base data wherever
  # they overlap.
  Write-Step "building data/bounty-bosses.json"
  if (Test-Path -LiteralPath $BountyBossesLocal) {
    $bountyJson = [System.IO.File]::ReadAllText($BountyBossesLocal)
    [System.IO.File]::WriteAllText((Join-Path $PubData 'bounty-bosses.json'), (Merge-ConfirmedBounty $bountyJson), $utf8)
  } else {
    Write-Step "WARNING: bounty_bosses.json missing; bounty-boss overlay will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubData 'bounty-bosses.json'), '[]', $utf8)
  }

  # wanted-fugitives.json (paldb-scraped human/Syndicate boss locations, added
  # 2026-07-06) -- Bundled as a static file; Anthony's own confirmed coordinates/names
  # (Merge-ConfirmedWantedFugitives) override the paldb-sourced base data wherever they
  # overlap. The dashboard serves the same JSON at /api/wanted-fugitives.
  Write-Step "building data/wanted-fugitives.json"
  $fugitivesLocal = Join-Path $Root 'wanted_fugitives.json'
  if (Test-Path -LiteralPath $fugitivesLocal) {
    $fugitivesJson = [System.IO.File]::ReadAllText($fugitivesLocal)
    [System.IO.File]::WriteAllText((Join-Path $PubData 'wanted-fugitives.json'), (Merge-ConfirmedWantedFugitives $fugitivesJson), $utf8)
  } else {
    Write-Step "WARNING: wanted_fugitives.json missing; wanted-fugitive overlay will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubData 'wanted-fugitives.json'), '[]', $utf8)
  }

  # eagle-statues.json (paldb-scraped fast-travel point locations, added 2026-07-06) --
  # Bundled as a static file; Anthony's own confirmed coordinates/names
  # (Merge-ConfirmedEagleStatues) override the paldb-sourced base data wherever they overlap.
  # The dashboard serves the same JSON at /api/eagle-statues.
  Write-Step "building data/eagle-statues.json"
  $eaglesLocal = Join-Path $Root 'eagle_travel_locations.json'
  if (Test-Path -LiteralPath $eaglesLocal) {
    $eaglesJson = [System.IO.File]::ReadAllText($eaglesLocal)
    [System.IO.File]::WriteAllText((Join-Path $PubData 'eagle-statues.json'), (Merge-ConfirmedEagleStatues $eaglesJson), $utf8)
  } else {
    Write-Step "WARNING: eagle_travel_locations.json missing; eagle-statue overlay will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubData 'eagle-statues.json'), '[]', $utf8)
  }

  # towers.json (paldb-scraped raid Tower locations, added 2026-07-06) -- Split out of
  # Eagle Statues -- see Get-TowerNameSet's comment. Bundled as a static file; the dashboard
  # serves the same JSON at /api/towers.
  Write-Step "building data/towers.json"
  $towersLocal = Join-Path $Root 'towers.json'
  if (Test-Path -LiteralPath $towersLocal) {
    $towersJson = [System.IO.File]::ReadAllText($towersLocal)
    [System.IO.File]::WriteAllText((Join-Path $PubData 'towers.json'), (Merge-ConfirmedTowers $towersJson), $utf8)
  } else {
    Write-Step "WARNING: towers.json missing; tower overlay will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubData 'towers.json'), '[]', $utf8)
  }

  # ── npcs.json (Anthony's confirmed NPC locations, static; per-player state is separate) ──
  # Entirely sourced from confirmed_locations.json. The dashboard serves the same JSON at
  # /api/npcs; per-player talked-to state is player-npcs/<guid>.json (Frequent branch above).
  Write-Step "building data/npcs.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'npcs.json'), (Get-ConfirmedNPCs), $utf8)

  # ── landmarks.json (Anthony's other confirmed locations: discovered areas, etc.) ──
  # Entirely sourced from confirmed_locations.json -- catch-all for anything not already an
  # effigy/journal/bounty/Wanted-Fugitive/Eagle-Statue/NPC. Dashboard serves the same JSON
  # at /api/landmarks.
  Write-Step "building data/landmarks.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'landmarks.json'), (Get-ConfirmedLandmarks), $utf8)

  # ── pal-species.json (curated species data: type/work/skills/stats) ──────────
  # Built once by build_pal_species.py; bundled as a static file. The dashboard serves
  # the same JSON at /api/pal-species, which the data-fetch repoint points here.
  Write-Step "building data/pal-species.json"
  $speciesLocal = Join-Path $Root 'pal_species.json'
  if (Test-Path -LiteralPath $speciesLocal) {
    Copy-Item -Path $speciesLocal -Destination (Join-Path $PubData 'pal-species.json') -Force
  } else {
    Write-Step "WARNING: pal_species.json missing; species sections will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubData 'pal-species.json'), '{}', $utf8)
  }

  # ── pal-skills.json (per active-skill: element/power/cooldown/status/desc) ────
  # Built once by build_pal_skills.py; bundled as a static file. The dashboard serves
  # the same JSON at /api/pal-skills, which the data-fetch repoint points here. Powers
  # the tap-a-skill detail popup.
  Write-Step "building data/pal-skills.json"
  $skillsLocal = Join-Path $Root 'pal_skills.json'
  if (Test-Path -LiteralPath $skillsLocal) {
    Copy-Item -Path $skillsLocal -Destination (Join-Path $PubData 'pal-skills.json') -Force
  } else {
    Write-Step "WARNING: pal_skills.json missing; skill detail popup will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubData 'pal-skills.json'), '{}', $utf8)
  }

  # ── pal-passives.json (per passive: effect text + rating rank) ───────────────
  # Built once by build_pal_passives.py; bundled as a static file. The dashboard serves
  # the same JSON at /api/pal-passives, which the data-fetch repoint points here. Powers
  # the tap-a-passive detail popup.
  Write-Step "building data/pal-passives.json"
  $passivesLocal = Join-Path $Root 'pal_passives.json'
  if (Test-Path -LiteralPath $passivesLocal) {
    Copy-Item -Path $passivesLocal -Destination (Join-Path $PubData 'pal-passives.json') -Force
  } else {
    Write-Step "WARNING: pal_passives.json missing; passive detail popup will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubData 'pal-passives.json'), '{}', $utf8)
  }
}

Write-Step "data build complete ($Mode) -> $PubData"
