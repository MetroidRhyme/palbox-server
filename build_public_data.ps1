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
function Get-DashJson($pathAndQuery) {
  try {
    $r = Invoke-WebRequest -Uri ($DashBase + $pathAndQuery) -UseBasicParsing -TimeoutSec 180
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

# gx/gy (in-game grid coords) -> real world x/y. Inverse of the effigy
# tooltip's cx=(y-158000)/459, cy=(x+123888)/459 -- see the
# palbox-journal-overlay skill's coordinate-transform section.
function ConvertTo-WorldXY([int]$gx, [int]$gy) {
  return @{ x = ($gy * 459) - 123888; y = ($gx * 459) + 158000 }
}

# Anthony wants ONLY his own confirmed locations on the map -- these Merge-Confirmed*
# functions FILTER the base public/wiki-sourced data down to matches only (not overlay
# onto the full set). NOTE: build with -InputObject rather than piping into
# ConvertTo-Json -- piping a PowerShell array with exactly one element unwraps it into a
# bare JSON object instead of a 1-item array (confirmed via direct test), which would
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
      # Anthony's script is the source of truth -- override the name too, not
      # just the coordinates, if it has one for this key.
      if ($c.name) { $entry.name = $c.name }
      $result += $entry
    }
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
    $xy = ConvertTo-WorldXY $c.gx $c.gy
    if ($entry) {
      $entry.x = $xy.x
      $entry.y = $xy.y
      if ($c.name) { $entry.name = $c.name }
      $result += $entry
    } elseif ($c.source -eq 'NormalBossDefeatFlag' -and -not (Test-SyndicateKeyShape $c.key)) {
      # Anthony's dataminer script already told us (via confirmed_locations.json's "source"
      # field) that this key is a NormalBossDefeatFlag hit, and its shape says Field Boss,
      # not Wanted Fugitive -- show it now from his own confirmed name/coords rather than
      # waiting on a manual anonymous_boss_keys.json edit. No per-player found/unfound fade
      # until a species gets assigned there (same static-pin limitation Wanted
      # Fugitive/Eagle Statue/Landmarks already have).
      $name = if ($c.name) { $c.name } else { $c.key }
      $result += @{ species = $c.key; name = $name; x = $xy.x; y = $xy.y }
    }
  }
  return (ConvertTo-Json -InputObject @($result) -Depth 6)
}

# "Wanted Fugitive" -- NPC/Syndicate boss defeat-flag keys (syndicate_bosses.json, e.g.
# BOSS_MALE_SOLDIER02) that Anthony has personally located. Unlike bounty bosses these
# carry no location at all in the base roster, so this is entirely sourced from
# confirmed_locations.json. Primary classifier is the "source" field Anthony's dataminer
# script now stamps on each entry (source == NormalBossDefeatFlag + syndicate key shape, see
# Test-SyndicateKeyShape) -- the syndicate_bosses.json roster match is kept only as a
# fallback for entries confirmed before "source" existed, and as a name-label source. No
# per-player found/unfound state -- static named pins only, same as Landmarks below.
function Get-ConfirmedWantedFugitives {
  $confirmed = Get-ConfirmedLocations
  $roster = @{}
  $synFile = Join-Path $Root 'syndicate_bosses.json'
  if (Test-Path -LiteralPath $synFile) {
    try {
      foreach ($e in (Get-Content -LiteralPath $synFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($e.key) { $roster[$e.key.ToUpper()] = $e.label }
      }
    } catch {}
  }
  $result = @()
  foreach ($c in $confirmed) {
    $isFugitive = $roster.ContainsKey($c.key.ToUpper()) -or
      ($c.source -eq 'NormalBossDefeatFlag' -and (Test-SyndicateKeyShape $c.key))
    if ($isFugitive) {
      $xy = ConvertTo-WorldXY $c.gx $c.gy
      $name = if ($c.name) { $c.name } else { $roster[$c.key.ToUpper()] }
      if (-not $name) { $name = $c.key }
      $result += @{ key = $c.key; name = $name; x = $xy.x; y = $xy.y }
    }
  }
  return (ConvertTo-Json -InputObject @($result) -Depth 6)
}

# "Eagle Statues" -- fast-travel points (FastTravelPointUnlockFlag). Primary classifier is
# the "source" field (see Merge-ConfirmedBounty's comment above); fast_travel_keys.json (a
# roster of confirmed fast-travel point GUIDs, grown from real save data -- see
# pal_save_reader.py's extract_fast_travel_data) is kept as a fallback for entries confirmed
# before "source" existed. Static named pins only.
function Get-ConfirmedEagleStatues {
  $confirmed = Get-ConfirmedLocations
  $roster = New-Object System.Collections.Generic.HashSet[string]
  $ftFile = Join-Path $Root 'fast_travel_keys.json'
  if (Test-Path -LiteralPath $ftFile) {
    try {
      foreach ($e in (Get-Content -LiteralPath $ftFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($e.key) { [void]$roster.Add($e.key.ToUpper()) }
      }
    } catch {}
  }
  $result = @()
  foreach ($c in $confirmed) {
    $isEagle = ($c.source -eq 'FastTravelPointUnlockFlag') -or $roster.Contains($c.key.ToUpper())
    if ($isEagle) {
      $xy = ConvertTo-WorldXY $c.gx $c.gy
      $name = if ($c.name) { $c.name } else { $c.key }
      $result += @{ key = $c.key; name = $name; x = $xy.x; y = $xy.y }
    }
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
  Write-Step "fetching pals + paldeck"
  $palsJson = Get-DashJson '/api/pals'
  if (-not $palsJson) {
    # Reader output is the same shape the /api/pals handler emits (sans live-name enrichment).
    $palsJson = Invoke-Reader @((Join-Path $Root 'pal_team_reader.py'), $saveDir)
  }
  $paldeckJson = Get-DashJson '/api/paldeck'
  if (-not $paldeckJson) {
    # Fallback: pal_save_reader emits {players:[{guid,name,tribeCaptureCount,counts}]};
    # the dashboard handler reshapes tribeCaptureCount -> total, so we do the same.
    $raw = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $saveDir) | ConvertFrom-Json
    $outPlayers = @($raw.players | ForEach-Object {
        $name = if ($_.PSObject.Properties['name'] -and $_.name) { [string]$_.name } else { ([string]$_.guid).Substring(0, 8) }
        [ordered]@{ guid = [string]$_.guid; name = $name; total = [int]$_.tribeCaptureCount; counts = $_.counts }
      })
    $paldeckJson = (@{ players = $outPlayers } | ConvertTo-Json -Depth 6 -Compress)
  }

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
  $eggsJson = Get-DashJson '/api/eggs'
  if (-not $eggsJson) {
    $eggsJson = Invoke-Reader @((Join-Path $Root 'pal_egg_reader.py'), $saveDir)
  }
  if ($eggsJson) {
    $eggsObj = $eggsJson | ConvertFrom-Json
    # Player-name roster (8-hex prefix -> name) so the Eggs owner filter keeps every player
    # even when they have zero eggs right now. Names come from the paldeck roster, preferring
    # any owner names the dashboard already cached on the egg payload. The ADMIN set gets the
    # full roster; each scoped set gets ONLY that player (so a scoped viewer never sees the
    # other players' names in their filter).
    $apiOwners = @{}
    if ($eggsObj.owners) { foreach ($o in @($eggsObj.owners)) { if ($o.prefix) { $apiOwners[([string]$o.prefix).ToUpperInvariant()] = [string]$o.name } } }
    $allOwners = @()
    foreach ($pp in @($paldeckObj.players)) {
      $guid = [string]$pp.guid; if (-not $guid) { continue }
      $pfx = $guid.Substring(0, 8).ToUpperInvariant()
      $nm = [string]$pp.name; if ($apiOwners.ContainsKey($pfx) -and $apiOwners[$pfx]) { $nm = $apiOwners[$pfx] }
      $allOwners += [ordered]@{ prefix = $pfx; name = $nm }
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
      $nm = [string]$pp.name; if ($apiOwners.ContainsKey($prefix) -and $apiOwners[$prefix]) { $nm = $apiOwners[$prefix] }
      # Force a single-element array so ConvertTo-Json emits a JSON array, not a bare object.
      $myOwners = @([ordered]@{ prefix = $prefix; name = $nm })
      $dir = Join-Path $PubByPlayer $guid
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      [System.IO.File]::WriteAllText((Join-Path $dir 'eggs.json'), ([ordered]@{ eggs = $mine; owners = $myOwners; summary = $sum } | ConvertTo-Json -Depth 12 -Compress), $utf8)
    }
  } else {
    Write-Step "WARNING: no egg data available; Eggs tab will be empty"
    [System.IO.File]::WriteAllText((Join-Path $PubAll 'eggs.json'), '{"eggs":[],"summary":{}}', $utf8)
  }

  # ── player-effigies/<guid>.json (one per player in the paldeck) ──────────────
  Write-Step "building data/player-effigies/*.json"
  foreach ($p in @($paldeckObj.players)) {
    $guid = [string]$p.guid
    if (-not $guid) { continue }
    $pe = Get-DashJson ('/api/player-effigies?guid=' + $guid)
    if (-not $pe) {
      try {
        $pe = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $saveDir, 'effigies', $guid)
      } catch {
        Write-Step "  skipped effigies for $guid ($($_.Exception.Message))"
        continue
      }
    }
    [System.IO.File]::WriteAllText((Join-Path $PubEffig ($guid + '.json')), $pe, $utf8)
  }

  # ── player-notes/<guid>.json (journal/diary collection COUNT, one per player) ─
  # Mirrors player-effigies above but for NoteObtainForInstanceFlag. There is no known
  # instance-ID -> named-journal mapping (unlike effigies), so this only supports a
  # collected COUNT on the client, not per-location found/new marking.
  Write-Step "building data/player-notes/*.json"
  foreach ($p in @($paldeckObj.players)) {
    $guid = [string]$p.guid
    if (-not $guid) { continue }
    $pn = Get-DashJson ('/api/player-notes?guid=' + $guid)
    if (-not $pn) {
      try {
        $pn = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $saveDir, 'notes', $guid)
      } catch {
        Write-Step "  skipped notes for $guid ($($_.Exception.Message))"
        continue
      }
    }
    [System.IO.File]::WriteAllText((Join-Path $PubNotes ($guid + '.json')), $pn, $utf8)
  }

  # ── player-location/<guid>.json (live world position, one per player) ────────
  # Mirrors player-notes above but for Translation/Rotation, via pal_team_reader.py's
  # lightweight "locations" mode. /api/player-locations always answers {players:[...]}
  # (even scoped to one guid, to match the admin "all players" shape) -- unwrap to that
  # one player's flat {x,y,z,yawDeg} object here, since the Worker/public client expects
  # a single object per file (same convention as every other per-player route).
  Write-Step "building data/player-location/*.json"
  foreach ($p in @($paldeckObj.players)) {
    $guid = [string]$p.guid
    if (-not $guid) { continue }
    $pl = Get-DashJson ('/api/player-locations?guid=' + $guid)
    if (-not $pl) {
      try {
        $pl = Invoke-Reader @((Join-Path $Root 'pal_team_reader.py'), $saveDir, 'locations', $guid)
      } catch {
        Write-Step "  skipped location for $guid ($($_.Exception.Message))"
        continue
      }
    }
    $one = $null
    try { $one = @(($pl | ConvertFrom-Json).players)[0] } catch {}
    $body = if ($one) { [ordered]@{ x = $one.x; y = $one.y; z = $one.z; yawDeg = $one.yawDeg } } else { [ordered]@{} }
    [System.IO.File]::WriteAllText((Join-Path $PubLocation ($guid + '.json')), ($body | ConvertTo-Json -Compress), $utf8)
  }

  # ── player-bounties/<guid>.json (bounty-boss / named-Alpha defeat state, one per player) ─
  # Mirrors player-effigies/player-notes above but for NormalBossDefeatFlag, resolved to
  # bounty-boss species codes by pal_save_reader.py's extract_bounty_data (matched against
  # bounty_bosses.json so the species list and map locations can't drift apart).
  Write-Step "building data/player-bounties/*.json"
  foreach ($p in @($paldeckObj.players)) {
    $guid = [string]$p.guid
    if (-not $guid) { continue }
    $pb = Get-DashJson ('/api/player-bounties?guid=' + $guid)
    if (-not $pb) {
      try {
        $pb = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $saveDir, 'bounties', $guid)
      } catch {
        Write-Step "  skipped bounties for $guid ($($_.Exception.Message))"
        continue
      }
    }
    [System.IO.File]::WriteAllText((Join-Path $PubBounty ($guid + '.json')), $pb, $utf8)
  }

  # ── player-npcs/<guid>.json (NPC talked-to state, one per player) ────────────
  # Mirrors player-notes above but for NPCTalkCountMap via pal_save_reader.py's
  # extract_npc_data ("collected" = count>0, not a bool flag).
  Write-Step "building data/player-npcs/*.json"
  foreach ($p in @($paldeckObj.players)) {
    $guid = [string]$p.guid
    if (-not $guid) { continue }
    $pnpc = Get-DashJson ('/api/player-npcs?guid=' + $guid)
    if (-not $pnpc) {
      try {
        $pnpc = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $saveDir, 'npcs', $guid)
      } catch {
        Write-Step "  skipped npcs for $guid ($($_.Exception.Message))"
        continue
      }
    }
    [System.IO.File]::WriteAllText((Join-Path $PubNPCs ($guid + '.json')), $pnpc, $utf8)
  }

  # ── player-fugitives/<guid>.json (Wanted Fugitive defeat state, one per player) ─
  # Mirrors player-npcs above but for NormalBossDefeatFlag matched by exact key, via
  # pal_save_reader.py's extract_fugitive_data.
  Write-Step "building data/player-fugitives/*.json"
  foreach ($p in @($paldeckObj.players)) {
    $guid = [string]$p.guid
    if (-not $guid) { continue }
    $pf = Get-DashJson ('/api/player-fugitives?guid=' + $guid)
    if (-not $pf) {
      try {
        $pf = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $saveDir, 'fugitives', $guid)
      } catch {
        Write-Step "  skipped fugitives for $guid ($($_.Exception.Message))"
        continue
      }
    }
    [System.IO.File]::WriteAllText((Join-Path $PubFugitives ($guid + '.json')), $pf, $utf8)
  }

  # ── player-eagles/<guid>.json (Eagle Statue unlock state, one per player) ──────
  # Mirrors player-npcs above but for FastTravelPointUnlockFlag, via pal_save_reader.py's
  # extract_fast_travel_data.
  Write-Step "building data/player-eagles/*.json"
  foreach ($p in @($paldeckObj.players)) {
    $guid = [string]$p.guid
    if (-not $guid) { continue }
    $pea = Get-DashJson ('/api/player-eagles?guid=' + $guid)
    if (-not $pea) {
      try {
        $pea = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $saveDir, 'eagles', $guid)
      } catch {
        Write-Step "  skipped eagles for $guid ($($_.Exception.Message))"
        continue
      }
    }
    [System.IO.File]::WriteAllText((Join-Path $PubEagles ($guid + '.json')), $pea, $utf8)
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

  # ── wanted-fugitives.json (Anthony's confirmed NPC/Syndicate boss locations) ───
  # Entirely sourced from confirmed_locations.json -- no public/wiki base data exists for
  # these at all. The dashboard serves the same JSON at /api/wanted-fugitives.
  Write-Step "building data/wanted-fugitives.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'wanted-fugitives.json'), (Get-ConfirmedWantedFugitives), $utf8)

  # ── eagle-statues.json (Anthony's confirmed fast-travel point locations) ─────
  # Entirely sourced from confirmed_locations.json. The dashboard serves the same JSON at
  # /api/eagle-statues.
  Write-Step "building data/eagle-statues.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'eagle-statues.json'), (Get-ConfirmedEagleStatues), $utf8)

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
