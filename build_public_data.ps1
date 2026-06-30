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
$DashBase = 'http://localhost:8213'

$PubData = Join-Path $OutDir 'data'
$PubAll = Join-Path $PubData 'all'
$PubByPlayer = Join-Path $PubData 'by-player'
$PubEffig = Join-Path $PubData 'player-effigies'

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

# ── Run a Python reader and return its stdout as a single string ───────────────
function Invoke-Reader([string[]]$ScriptArgs) {
  $out = & python @ScriptArgs 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $out) {
    throw "python $($ScriptArgs -join ' ') failed (exit $LASTEXITCODE)"
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
  foreach ($d in @($PubAll, $PubEffig)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  Get-ChildItem -LiteralPath $PubAll -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -LiteralPath $PubEffig -File -ErrorAction SilentlyContinue | Remove-Item -Force
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
  [System.IO.File]::WriteAllText((Join-Path $PubData 'effigies.json'), $effJson, $utf8)

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
