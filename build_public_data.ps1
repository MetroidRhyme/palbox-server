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
$DashBase = 'http://localhost:8213'

$PubData = Join-Path $OutDir 'data'
$PubAll = Join-Path $PubData 'all'
$PubByPlayer = Join-Path $PubData 'by-player'
$PubEffig = Join-Path $PubData 'player-effigies'
$PubNotes = Join-Path $PubData 'player-notes'
$PubBounty = Join-Path $PubData 'player-bounties'
$PubLocation = Join-Path $PubData 'player-location'
$PubFugitives = Join-Path $PubData 'player-fugitives'
$PubEagles = Join-Path $PubData 'player-eagles'
$PubTowerBosses = Join-Path $PubData 'player-tower-bosses'
$PubItemPickups = Join-Path $PubData 'player-itempickups'

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

# Shared map-location data layer (Get-ConfirmedLocations, Get-MapCategoryJson, etc.) --
# also dot-sourced by PalWorldServerManager.ps1, so both callers share one implementation
# instead of two hand-kept, drifting copies. See map_data_lib.ps1 for the full function
# list.
. (Join-Path $Root 'map_data_lib.ps1')
Initialize-MapDataLib -Root $Root

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
  foreach ($d in @($PubAll, $PubEffig, $PubNotes, $PubBounty, $PubLocation, $PubFugitives, $PubEagles, $PubTowerBosses, $PubItemPickups)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  Get-ChildItem -LiteralPath $PubAll -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubEffig -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubNotes -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubBounty -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubLocation -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubFugitives -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubEagles -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubTowerBosses -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubItemPickups -File -ErrorAction SilentlyContinue | Remove-Item -Force
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

  # -- player-effigies/player-notes/player-bounties/player-fugitives/player-eagles/
  #    player-tower-bosses/<guid>.json (one call per player instead of six) --------
  # pal_save_reader.py's playerall mode decompresses each player's small .sav ONCE and
  # returns all six sections in one JSON, instead of six separate process spawns each
  # re-decompressing the same file (which is what this loop used to do, calling
  # effigies/notes/bounties/fugitives/eagles/towerbosses modes one at a time). Each
  # section's shape is unchanged ({"guid":...,"collected":[...]}), so the split below
  # just wraps each field into the same per-player file this always wrote.
  Write-Step "building data/player-effigies, -notes, -bounties, -fugitives, -eagles, -tower-bosses/*.json"
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
      $PubEffig       = $pa.effigies
      $PubNotes       = $pa.notes
      $PubBounty      = $pa.bounties
      $PubFugitives   = $pa.fugitives
      $PubEagles      = $pa.eagles
      $PubTowerBosses = $pa.towerBosses
      $PubItemPickups = $pa.itemPickups
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
  # All six map categories now read straight from confirmed_locations.json via
  # Get-MapCategoryJson -- Phase 3's importer already upserted every scraped roster
  # (effigies.json, journal_locations.json, bounty_bosses.json, wanted_fugitives.json,
  # eagle_travel_locations.json, towers.json) into the canonical store, so there is no
  # longer a separate roster file to read/overlay at build time. Those roster files stay
  # on disk purely as importer inputs (re-run import_scraped_rosters.ps1 after a game
  # patch to pick up new locations).
  Write-Step "building data/effigies.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'effigies.json'), (Get-MapCategoryJson 'effigy'), $utf8)

  Write-Step "building data/journals.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'journals.json'), (Get-MapCategoryJson 'journal'), $utf8)

  Write-Step "building data/bounty-bosses.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'bounty-bosses.json'), (Get-MapCategoryJson 'bounty'), $utf8)

  Write-Step "building data/wanted-fugitives.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'wanted-fugitives.json'), (Get-MapCategoryJson 'fugitive'), $utf8)

  Write-Step "building data/eagle-statues.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'eagle-statues.json'), (Get-MapCategoryJson 'eagle'), $utf8)

  Write-Step "building data/towers.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'towers.json'), (Get-MapCategoryJson 'tower'), $utf8)

  Write-Step "building data/sam-sites.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'sam-sites.json'), (Get-MapCategoryJson 'sam'), $utf8)

  Write-Step "building data/itempickups.json"
  [System.IO.File]::WriteAllText((Join-Path $PubData 'itempickups.json'), (Get-MapCategoryJson 'itempickup'), $utf8)

  # Destroyed SAM Site (fixed weapon) keys -- world-scoped (Level.sav), from
  # pal_save_reader.py's "destroyed-weapons" mode, not map_data_lib.ps1 (this isn't
  # confirmed_locations.json data, it's the live save-side "got" signal a SAM pin's status
  # is computed against on the public site too, same as eagle-statues/wanted-fugitives).
  # $saveDir is a Frequent-block-only local (see above) -- NOT in scope here, so resolve it
  # again via Get-ActiveSaveDir rather than reusing that variable name (a stale/blank
  # $saveDir would silently drop from the native `python` arg list on splat, shifting every
  # positional argument left by one -- caught live: this returned "Players dir not found:
  # destroyed-weapons\Players", i.e. the mode string itself got treated as the save dir).
  Write-Step "building data/destroyed-weapons.json"
  $staticSaveDir = Get-ActiveSaveDir
  $destroyedWeaponsJson = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $staticSaveDir, 'destroyed-weapons')
  [System.IO.File]::WriteAllText((Join-Path $PubData 'destroyed-weapons.json'), $destroyedWeaponsJson, $utf8)

  # Effigy GUID -> relic type ("CapturePower"/"GliderSpeed"/...), from
  # RelicObtainForInstanceFlagByType (ALL relic types; the flat RelicObtainForInstanceFlag is
  # CapturePower-only). World-fixed, so the reader's no-guid effigy-types mode merges across
  # every player save. Same static bucket / Get-ActiveSaveDir resolution as destroyed-weapons
  # above -- purely a display label on the public map, not a found/collected signal.
  Write-Step "building data/effigy-types.json"
  $effigyTypesJson = Invoke-Reader @((Join-Path $Root 'pal_save_reader.py'), $staticSaveDir, 'effigy-types')
  [System.IO.File]::WriteAllText((Join-Path $PubData 'effigy-types.json'), $effigyTypesJson, $utf8)

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
