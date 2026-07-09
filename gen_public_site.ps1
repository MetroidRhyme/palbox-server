# gen_public_site.ps1
# Builds <server-root>\public\ : a READ-ONLY static copy of the Pal dashboard
# (Pals / Paldeck / Effigy + Spawn maps) for publishing to Cloudflare Pages.
#
# Data is pulled from the live local dashboard (http://localhost:8213/api/*), which
# already runs the Python readers and applies live name enrichment, so the JSON is
# byte-for-byte what the UI expects. If the dashboard is not reachable we fall back
# to running the readers directly (names then come from the save, not live sessions).
#
# index.html is produced by reading the dashboard's HTML/JS straight from dashboard.html
# (PalWorldServerManager.ps1 reads the same file at startup instead of holding it inline)
# and surgically (a) removing the entire control surface and (b) repointing data fetches
# at the static files. The two maps keep their exact /api/palmaptile and /api/palspawn
# paths, served by Cloudflare Pages Functions.

[CmdletBinding()]
param(
  [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

$IconDir = Join-Path $Root 'PalAssets\Pals'
$SiteSrc = Join-Path $Root 'site_src'

$Pub = Join-Path $Root 'public'
$PubData = Join-Path $Pub 'data'
$PubPals = Join-Path $Pub 'pals'
$PubFunc = Join-Path $Pub 'functions'

# The frequently-changing per-player data + the save/dashboard plumbing it needed
# now lives in build_public_data.ps1 (called below for the STATIC subset) and is
# pushed to R2 by sync_public_data.ps1. This script only builds the Pages "shell".

function Write-Step($m) { Write-Host "[gen] $m" }

# --- Prepare output tree -------------------------------------------------------
# The frequently-changing, per-player data (pals/paldeck/eggs/player-effigies/
# settings) now lives in R2 and is served by the Worker -- it is NOT shipped with the
# Pages shell. So the shell deploy rebuilds data fresh with ONLY the static files
# (effigies + pal-species) via the shared builder; the per-player sets are pushed to
# R2 separately by sync_public_data.ps1. Clearing data first also drops any stale
# pre-R2 per-player files so they never get deployed.
Write-Step "output root: $Pub"
New-Item -ItemType Directory -Force -Path $Pub | Out-Null
New-Item -ItemType Directory -Force -Path $PubPals | Out-Null
if (Test-Path -LiteralPath $PubData) { Remove-Item -LiteralPath $PubData -Recurse -Force }
& (Join-Path $Root 'build_public_data.ps1') -Root $Root -OutDir $Pub -Mode Static
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "build_public_data.ps1 (Static) failed (exit $LASTEXITCODE)" }

# --- Pal portraits -------------------------------------------------------------
Write-Step "copying portraits -> pals/"
if (-not (Test-Path -LiteralPath $IconDir)) { throw "Portrait dir not found: $IconDir (run gen_pal_assets.py)" }
Copy-Item -Path (Join-Path $IconDir '*.png') -Destination $PubPals -Force

# ── Work / element suitability icons ───────────────────────────────────────────
# Downloaded from paldb (hotlinking blocked) into pal_icons\; served at /icons/.
Write-Step "copying suitability icons -> icons/"
$IconSrc2 = Join-Path $Root 'pal_icons'
if (Test-Path -LiteralPath $IconSrc2) {
  $PubIcons = Join-Path $Pub 'icons'
  if (-not (Test-Path -LiteralPath $PubIcons)) { New-Item -ItemType Directory -Path $PubIcons | Out-Null }
  Copy-Item -Path (Join-Path $IconSrc2 '*.webp') -Destination $PubIcons -Force
  # Passive rank icons + frame (from palworld.wiki.gg) are PNGs, so copy those too.
  Copy-Item -Path (Join-Path $IconSrc2 '*.png') -Destination $PubIcons -Force
} else {
  Write-Step "WARNING: pal_icons\ missing; type/work icons will 404"
}

# ── Cloudflare Pages worker (advanced mode) ────────────────────────────────────
# A single _worker.js handles the two paldb.cc proxy routes and passes everything
# else to static assets. Advanced mode is used instead of a functions/ directory
# because Pages reliably runs _worker.js for every request.
Write-Step "writing _worker.js"
if (Test-Path -LiteralPath $PubFunc) { Remove-Item -LiteralPath $PubFunc -Recurse -Force }  # drop any stale functions/ dir
Copy-Item -Path (Join-Path $SiteSrc '_worker.js') -Destination (Join-Path $Pub '_worker.js') -Force

# -- index.html : transform the dashboard source --------------------------------
Write-Step "building index.html"
$DashboardHtmlPath = Join-Path $Root 'dashboard.html'
if (-not (Test-Path -LiteralPath $DashboardHtmlPath)) { throw "dashboard.html not found: $DashboardHtmlPath" }
$html = [System.IO.File]::ReadAllText($DashboardHtmlPath, [System.Text.UTF8Encoding]::new($false))

# (1) Remove the Dashboard nav tab and make Pals the default active tab. The button's
# label is "Pal Box" (matching the view's own panel-header) but data-tab/switchView stay
# "pals" -- see the explanatory comment at the nav-tab source; not renamed here either.
$html = $html.Replace(
  '<button class="nav-tab active" data-tab="dashboard" onclick="switchView(''dashboard'')">Dashboard</button>', '')
$html = $html.Replace(
  '<button class="nav-tab" data-tab="pals" onclick="switchView(''pals'')">Pal Box</button>',
  '<button class="nav-tab active" data-tab="pals" onclick="switchView(''pals'')">Pal Box</button>')

# (1b) Remove the Data Mine nav tab -- an admin-only raw-data view (see
# /palbox-bounty-tracker) whose API calls (/api/syndicate-bosses,
# /api/player-datamine) only exist in the Manager's own HttpListener, not in
# _worker.js. Left in place it would show players a tab that always fails to
# load. Same treatment as #view-dashboard below: nav button + the whole view
# block removed; switchView's line for it is already null-guarded
# (`if(vdm)vdm.style...`) so it doesn't need stripping for safety.
$html = $html.Replace(
  '<button class="nav-tab" data-tab="datamine" onclick="switchView(''datamine'')">Data Mine</button>', '')

# (2) Strip the header server-control bits and remove the Refresh control entirely.
# On the static published copy there is no live poll to trigger, so the button has
# nothing to do -- removing it (rather than rewiring it to location.reload) keeps the
# read-only site from advertising a control that doesn't apply.
$html = $html.Replace(
  '<button class="btn btn-green" id="btn-start-hdr" onclick="startServer()" style="display:none">&#9654; Start Server</button>', '')
# Repurpose the live "Updated ... refresh in 5:00 ... sync status" span into a static
# data-age indicator. Drop the hdr-mid class (it's hidden on mobile) so players see the
# data's age on phones too. renderDataAge() (injected below) fills #last-updated from the
# generation stamp. The sync-status pill is admin-ops-only (R2 sync health), meaningless
# to players, so it's dropped along with the countdown rather than carried over.
$before = $html
$html = $html.Replace(
  '<span class="hdr-mid">Updated <b id="last-updated">-</b> &bull; refresh in <b id="countdown">5:00</b> &bull; <span id="sync-pill" class="sync-pill-ok">-</span></span>',
  '<span id="data-fresh" style="color:var(--muted);font-size:12px;white-space:nowrap;">Updated <b id="last-updated">-</b></span>')
if ($html -eq $before) { throw "hdr-mid span (Updated/refresh/sync-pill) was not repointed" }
$before = $html
$html = $html.Replace('<button class="btn btn-ghost hdr-more-row" onclick="refreshAll();closeAllOverflowMenus();">&#8635; Refresh now</button>', '')
if ($html -eq $before) { throw "header 'Refresh now' row was not removed" }

# (2a2) Remove the "+ Add Icon" header button, its "Key Available" badge, and the modal --
# admin-only manual map-pin creation (POSTs to /api/map-add-icon, which only exists in the
# Manager's own HttpListener, not in _worker.js). The modal's own JS (openAddIconModal/
# saveAddIcon/dmRenderCustomIcons/etc.) already falls inside the "-- Data Mine tab --" JS
# block removed in step (3c) below, so only the HTML markup needs stripping here.
$before = $html
$html = $html.Replace(
  '<span id="eff-key-available-badge" class="btn btn-ghost" style="display:none;cursor:pointer;" onclick="openAddIconModal()" title="An unmapped save-flag key is available to link to a new map pin -- open Add Icon and pick it from the Unmapped Key dropdown">&#128273; Key Available</span>', '')
if ($html -eq $before) { throw "Key Available badge was not removed" }
$before = $html
$html = $html.Replace(
  '<button class="btn btn-primary" onclick="openAddIconModal()" title="Manually add a map pin before scraped/live data confirms it">+ Add Icon</button>', '')
if ($html -eq $before) { throw "Add Icon header button was not removed" }
$before = $html
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html, '<div id="addicon-modal-overlay".*?</div>\s*</div>\s*</div>', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
if ($html -eq $before) { throw "Add Icon modal markup was not removed" }

# (2a3) Remove the "Add cave entrance" modal -- admin-only sub-pin creation (POSTs to
# /api/map-add-entrance). Its JS (openEntranceModal/saveEntrance/removeEntrance/wireCaveAdd/
# caveAddButtonHtml) also lives inside the "-- Data Mine tab --" block stripped in (3c), and
# the cave RENDERING (desireEntrances/buildCaveMarker) is deliberately NOT stripped -- the
# cave icons + lines are map data players should see; only these admin controls come out.
$before = $html
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html, '<div id="entrance-modal-overlay".*?</div>\s*</div>\s*</div>', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
if ($html -eq $before) { throw "Add entrance modal markup was not removed" }

# (2b) Remove the per-view "Reload" buttons (Pals / Paldeck / Effigies). On the static
# site they only re-fetch the same generated JSON -- there's no live server to pull
# fresher data from -- so they appear broken to players. The fetch functions themselves
# stay (used on initial load and tab switch); only the now-pointless buttons are dropped.
$html = $html.Replace('<button class="btn btn-ghost" onclick="fetchPaldeck()">&#8635; Reload</button>', '')
$html = $html.Replace('<button class="btn btn-ghost" onclick="reloadEffigyView()">&#8635; Reload</button>', '')
$html = $html.Replace('<button class="btn btn-ghost" onclick="fetchPals()">&#8635; Reload</button>', '')

# (3) Remove the entire #view-dashboard block -- the whole control surface
# (broadcast, save, reboot/shutdown, maintenance, danger zone, save manager,
# settings editor). It is a single sibling div ending right before #view-paldeck.
$rxOpts = [System.Text.RegularExpressions.RegexOptions]::Singleline
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html, '<div id="view-dashboard" class="page">.*?(?=<div id="view-paldeck")', '', $rxOpts)

# switchView() still toggles #view-dashboard's display; with that element gone the
# getElementById(...).style access throws a TypeError, which breaks the boot (blank
# page) and every tab click. Drop that one line.
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html, "(?m)^\s*document\.getElementById\('view-dashboard'\)\.style\.display=[^\r\n]*\r?\n", '')

# (3b) Remove the entire #view-datamine block (see 1b above) -- a single sibling div
# ending right before #view-pals.
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html, '<div id="view-datamine" class="page" style="display:none">.*?(?=<div id="view-pals")', '', $rxOpts)

# (3c) Remove the Data Mine tab's own JS (fetchDataMine/renderDataMine + their roster
# vars) -- unlike #view-dashboard's admin JS, this isn't inside the refreshAll-to-
# fetchPaldeck strip in step (6) below, so it survived as dead code calling
# /api/syndicate-bosses and /api/player-datamine (routes with no public equivalent --
# caught by the leaked-route scan further down). switchView's own call site is a
# typeof-guarded no-op once this is gone (see the shared source), same as the vdm null
# guard already covers its display-toggle line. Anchored on the "-- Data Mine tab --"
# section-header comment rather than a specific variable name -- a prior refactor
# (pre-2026-07-07, before the anchor was ever exercised by an actual public-site build)
# renamed the old dmBountyRoster var this used to key off, silently breaking this without
# anyone noticing since gen_public_site.ps1 hadn't been run end-to-end in the meantime.
$before = $html
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html, '// -- Data Mine tab -+.*?(?=function renderEffigyMap\(\))', '', $rxOpts)
if ($html -eq $before) { throw "Data Mine JS block was not found to remove" }

# (4) Replace the boot sequence: no live polling, just load the data views. The data-age
# indicator (#last-updated) is filled by renderDataAge() in the injected script below
# from the real generation stamp -- NOT page-load time, which would be misleading.
# NOTE: loadPrefs() must come AFTER fetchPaldeck() here. The admin-JS strip in step (6)
# lazily deletes everything from `async function refreshAll(){` up to the boot's
# `fetchPaldeck();`, so anything placed BEFORE that call would be swallowed by the strip.
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html,
  'initChartHover\(\);\s*refreshAll\(\);\s*setInterval\(tick,1000\);',
  "fetchPaldeck();loadPrefs();`r`nswitchView('pals');")

# (4d) Enable cross-device UI preferences (PUBLIC ONLY). The shared source ships
# PREFS_ENABLED=false so the admin dashboard (which has no /api/prefs route) leaves the
# prefs helpers inert; here we flip it on so the public site loads/saves each player's
# filter/sort/selected-player choices via the Worker's /api/prefs -> R2 store.
$before = $html
$html = $html.Replace('var PREFS_ENABLED=false;', 'var PREFS_ENABLED=true;')
if ($html -eq $before) { throw "prefs: PREFS_ENABLED flag not found to enable" }

# (4e) Disable the admin-only effigy "Confirm" checkbox (ADMIN ONLY, reverse of the flag
# above). The shared source ships EFFIGY_CONFIRM_ENABLED=true so the admin dashboard shows
# the popup checkbox that POSTs to /api/effigy-confirm; that route only exists in the
# Manager's own HttpListener, not in _worker.js, so it must be flipped off here or the
# public site would show a control that always fails.
$before = $html
$html = $html.Replace('var EFFIGY_CONFIRM_ENABLED=true;', 'var EFFIGY_CONFIRM_ENABLED=false;')
if ($html -eq $before) { throw "effigy confirm: EFFIGY_CONFIRM_ENABLED flag not found to disable" }

# toggleMapConfirm itself is dead code on the public site (its own EFFIGY_CONFIRM_ENABLED
# check above already no-ops it) but its fetch('/api/map-confirm') literal would still
# trip the generic leaked-route scan further down, so remove the whole function rather than
# whitelist a route that genuinely doesn't exist in _worker.js. (Was six separate
# toggle*Confirm functions pre-Phase-4B; consolidated into this one shared function, whose
# comment starts with the same anchor text the regex below still looks for.)
$before = $html
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html, '// Admin-only manual confirm from a map marker popup checkbox.*?(?=// Global visibility filter for the effigy map)', '', $rxOpts)
if ($html -eq $before) { throw "toggleMapConfirm function was not found to remove" }

# (4b) Make the public Pals view self-heal and stay refreshable. The Pals "Reload"
# button was removed in (2b), so the only Pals load is the boot's guarded fetch -- if
# that first fetch is interrupted (a transient Access re-auth or network blip right
# after a page reload) palsData stays null and nothing re-pulls, leaving the player
# stuck until they manually toggle tabs (which re-fires the guard). Unlike the admin --
# whose fetchPals re-reads the save file and is expensive -- the public fetch is cheap
# static JSON, so we (1) refetch every time the Pals tab is entered (drop the
# !palsData guard; also restores a refresh affordance now that the button is gone) and
# (2) auto-retry a couple seconds after a failed load so recovery needs no user action.
$before = $html
$html = $html.Replace(
  "if(name==='pals' && !palsData) fetchPals();",
  "if(name==='pals') fetchPals();")
if ($html -eq $before) { throw "Pals tab-enter guard was not relaxed (source string not found)" }

$before = $html
$html = $html.Replace(
  "area.innerHTML='<div class=""empty-state err"">Could not load Pals: '+e.message+'</div>';",
  "area.innerHTML='<div class=""empty-state err"">Could not load Pals: '+e.message+' &mdash; retrying...</div>';if(!palsData)setTimeout(fetchPals,2000);")
if ($html -eq $before) { throw "Pals fetch auto-retry was not injected (source string not found)" }

# (4c) Spoiler guards (PUBLIC ONLY) ---------------------------------------------------
# Two anti-spoiler tweaks the admin dashboard must NOT have, so they live here as
# generator surgery rather than in the shared $HtmlPage source.
#
#   Paldeck: a Pal the viewer has never caught (count 0) shows a '?' portrait and a
#   scrambled name, and is NOT clickable -- so its spawn map stays hidden. Catching even
#   one reveals the real portrait + name and re-enables the tap-to-open spawn map.
#
#   Effigy map: instead of plotting every effigy, only the ones the player has already
#   found are shown, plus -- as a breadcrumb -- the nearest still-undiscovered effigy to
#   each found one. Everything else is hidden until they get closer.
# These run BEFORE step (5) so the preserved palicon literal below gets repointed too.

# cryptName(): deterministic scramble (FNV-1a over the internal name) so a masked Pal's
# fake name stays stable across re-renders instead of flickering. The glyph set is the
# Unicode Runic block (U+16A0..) -- a non-Latin alphabet so the fake names read as truly
# cryptic, not jumbled letters/symbols. Built from numeric code points via
# String.fromCharCode so the SOURCE stays pure ASCII (the runes only exist at runtime),
# satisfying the generator's ASCII assert.
$before = $html
$html = $html.Replace('function renderPaldeck(){', @'
function cryptName(s){s=String(s||'');var cg=[0x16A0,0x16A2,0x16A6,0x16A8,0x16B1,0x16B2,0x16B7,0x16B9,0x16BA,0x16BE,0x16C1,0x16C8,0x16CB,0x16CF,0x16D2,0x16D6,0x16D7,0x16DA,0x16DC,0x16DE,0x16DF];var n=2166136261;for(var i=0;i<s.length;i++){n^=s.charCodeAt(i);n=(n*16777619)>>>0;}var len=5+(n%5);var o='';for(var i=0;i<len;i++){n=(n*1103515245+12345)>>>0;o+=String.fromCharCode(cg[n%cg.length]);}return o;}function renderPaldeck(){
'@)
if ($html -eq $before) { throw "paldeck spoiler: cryptName injection point not found" }

# Compute the per-row mask flag + scrambled display name alongside imgUrl.
$before = $html
$html = $html.Replace(@'
    var imgUrl='/api/palicon?name='+encodeURIComponent(name);
'@, @'
    var imgUrl='/api/palicon?name='+encodeURIComponent(name);var _msk=(count===0);var _dn=_msk?cryptName(e[1]):name;
'@)
if ($html -eq $before) { throw "paldeck spoiler: imgUrl line not found" }

# Portrait cell: '?' placeholder (no onclick) when masked, real clickable portrait otherwise.
$before = $html
$html = $html.Replace(@'
      +'<td style="padding:2px 4px;width:44px;text-align:center;cursor:pointer;" onclick="openPaldeckDetail('+idx+')"><img src="'+imgUrl+'" alt="" loading="lazy" onerror="this.style.display=\'none\'" style="width:40px;height:40px;object-fit:contain;vertical-align:middle;pointer-events:none;"></td>'
'@, @'
      +(_msk?'<td style="padding:2px 4px;width:44px;text-align:center;"><span style="display:inline-flex;width:40px;height:40px;align-items:center;justify-content:center;font-size:22px;font-weight:700;color:var(--muted);border:1px dashed var(--border);border-radius:6px;">?</span></td>':'<td style="padding:2px 4px;width:44px;text-align:center;cursor:pointer;" onclick="openPaldeckDetail('+idx+')"><img src="'+imgUrl+'" alt="" loading="lazy" onerror="this.style.display=\'none\'" style="width:40px;height:40px;object-fit:contain;vertical-align:middle;pointer-events:none;"></td>')
'@)
if ($html -eq $before) { throw "paldeck spoiler: portrait cell not found" }

# Name cell: scrambled monospace name (no onclick, not keyboard-focusable -- there is
# nothing to activate) when masked, real clickable + keyboard-focusable name otherwise.
$before = $html
$html = $html.Replace(@'
      +'<td tabindex="0" role="button" style="padding:4px 10px;cursor:pointer;" onclick="openPaldeckDetail('+idx+')" onkeydown="if(event.key===\'Enter\'||event.key===\' \'){event.preventDefault();openPaldeckDetail('+idx+');}">'+name+'</td>'
'@, @'
      +(_msk?'<td style="padding:4px 10px;color:var(--muted);font-family:monospace;letter-spacing:2px;">'+_dn+'</td>':'<td tabindex="0" role="button" style="padding:4px 10px;cursor:pointer;" onclick="openPaldeckDetail('+idx+')" onkeydown="if(event.key===\'Enter\'||event.key===\' \'){event.preventDefault();openPaldeckDetail('+idx+');}">'+name+'</td>')
'@)
if ($html -eq $before) { throw "paldeck spoiler: name cell not found" }

# Effigy breadcrumb: build the revealed set (each found effigy's nearest uncollected
# neighbour) right after collectedCount is declared, using the collectedSet+ids above it.
$before = $html
$html = $html.Replace(
  '  var collectedCount=0;',
  '  var collectedCount=0;var revealedSet=new Set();ids.forEach(function(cid){if(!collectedSet.has(cid.toUpperCase()))return;var cp=effigyLocations[cid],bId=null,bD=Infinity;ids.forEach(function(oid){if(collectedSet.has(oid.toUpperCase()))return;var op=effigyLocations[oid],dx=op.x-cp.x,dy=op.y-cp.y,d=dx*dx+dy*dy;if(d<bD){bD=d;bId=oid;}});if(bId)revealedSet.add(bId.toUpperCase());});')
if ($html -eq $before) { throw "effigy spoiler: collectedCount anchor not found" }

# Effigy render loop: skip any effigy that is neither collected nor a revealed breadcrumb.
$before = $html
$html = $html.Replace(
  '    if(got) collectedCount++;',
  '    if(got) collectedCount++;if(!got&&!revealedSet.has(id.toUpperCase()))return;')
if ($html -eq $before) { throw "effigy spoiler: render-loop skip anchor not found" }

# (5) Repoint data fetches to the static files. The two map endpoints
# (/api/palmaptile, /api/palspawn) are intentionally left unchanged -- the
# Pages Functions serve those exact paths.
$html = $html.Replace("'/api/pals'", "'data/pals.json'")
$html = $html.Replace("'/api/eggs'", "'data/eggs.json'")
# Server-message banner feed: admin reads the live route, public the R2 mirror.
$html = $html.Replace("'/api/server-messages'", "'data/server-messages.json'")
$html = $html.Replace("'/api/paldeck'", "'data/paldeck.json'")
$html = $html.Replace("'/api/effigies'", "'data/effigies.json'")
$html = $html.Replace("'/api/journals'", "'data/journals.json'")
$html = $html.Replace("'/api/bounty-bosses'", "'data/bounty-bosses.json'")
$html = $html.Replace("'/api/wanted-fugitives'", "'data/wanted-fugitives.json'")
$html = $html.Replace("'/api/eagle-statues'", "'data/eagle-statues.json'")
$html = $html.Replace("'/api/towers'", "'data/towers.json'")
$html = $html.Replace("'/api/pal-species'", "'data/pal-species.json'")
$html = $html.Replace("'/api/pal-skills'", "'data/pal-skills.json'")
$html = $html.Replace("'/api/pal-passives'", "'data/pal-passives.json'")
$html = $html.Replace(
  "'/api/player-effigies?guid='+encodeURIComponent(guid)",
  "'data/player-effigies/'+encodeURIComponent(guid)+'.json'")
$html = $html.Replace(
  "'/api/player-notes?guid='+encodeURIComponent(guid)",
  "'data/player-notes/'+encodeURIComponent(guid)+'.json'")
# Data Mine's per-player bulk fetch uses the same route with a different guid expression
# (p.guid instead of guid) -- same repoint, second call site. Dead code on public (the
# Data Mine tab/button is stripped above) but must not leak a raw /api/ URL either way.
$html = $html.Replace(
  "'/api/player-notes?guid='+encodeURIComponent(p.guid)",
  "'data/player-notes/'+encodeURIComponent(p.guid)+'.json'")
$html = $html.Replace(
  "'/api/player-bounties?guid='+encodeURIComponent(guid)",
  "'data/player-bounties/'+encodeURIComponent(guid)+'.json'")
$html = $html.Replace(
  "'/api/player-fugitives?guid='+encodeURIComponent(guid)",
  "'data/player-fugitives/'+encodeURIComponent(guid)+'.json'")
$html = $html.Replace(
  "'/api/player-eagles?guid='+encodeURIComponent(guid)",
  "'data/player-eagles/'+encodeURIComponent(guid)+'.json'")
$html = $html.Replace(
  "'/api/player-tower-bosses?guid='+encodeURIComponent(guid)",
  "'data/player-tower-bosses/'+encodeURIComponent(guid)+'.json'")

# (5b) Player locations (PUBLIC ONLY). The admin build's fetchPlayerLocations() calls one
# unscoped route returning EVERY player's live position, for the "all players on the map"
# admin feature. The public build may only ever see its own (Access-scoped) player -- there
# is no roster to pick from, just the single entry the scoped /data/paldeck.json already
# gave it -- so this is a whole-function-body replace (not a simple URL swap like the
# repoints above): different endpoint shape entirely (one player's fields vs an array).
# Matched via regex (not a literal multi-line string) so this survives if
# PalWorldServerManager.ps1's line endings ever change -- .*? with Singleline spans the
# CRLF-vs-LF question entirely; only the single-line start/end anchors need to match exactly.
$pubFetchPlayerLocations = @'
async function fetchPlayerLocations(){
  var sel=document.getElementById('effigy-player');
  var guid=sel?sel.value:'';
  if(!guid){ if(effigyLeaflet) renderPlayerMarkers(); return; }
  try{
    var r=await fetch('data/player-location/'+encodeURIComponent(guid)+'.json',{cache:'no-store'});
    var d=r.ok?await r.json():{};
    var nm=(sel.options[sel.selectedIndex]||{}).text||guid;
    playerLocations=(typeof d.x==='number')?[{guid:guid,name:nm,x:d.x,y:d.y,z:d.z,yawDeg:d.yawDeg}]:[];
  }catch(e){
    playerLocations=[];
  }
  if(effigyLeaflet) renderPlayerMarkers();
}
'@
$before = $html
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html,
  'async function fetchPlayerLocations\(\)\{.*?\r?\n\}',
  $pubFetchPlayerLocations.Trim(),
  $rxOpts)
if ($html -eq $before) { throw "player-locations: fetchPlayerLocations override not found" }

# Re-fetch the (own) player's position whenever fetchEffigyPlayer settles the selected
# player -- covers initEffigyView's own fetchPlayerLocations() call possibly racing ahead
# of the effigy-player dropdown actually being populated/selected on first load.
$before = $html
$html = $html.Replace(
  "if(!guid){effigyCollected=[];renderEffigyMap();fetchJournalPlayer(guid);fetchBossPlayer(guid);fetchFugitivePlayer(guid);fetchEaglePlayer(guid);fetchTowerBossPlayer(guid);return;}",
  "if(!guid){effigyCollected=[];renderEffigyMap();fetchJournalPlayer(guid);fetchBossPlayer(guid);fetchFugitivePlayer(guid);fetchEaglePlayer(guid);fetchTowerBossPlayer(guid);fetchPlayerLocations();return;}")
if ($html -eq $before) { throw "player-locations: fetchEffigyPlayer empty-guid hook not found" }
$before = $html
$html = $html.Replace(
  "  fetchFugitivePlayer(guid);",
  "  fetchFugitivePlayer(guid);fetchPlayerLocations();")
if ($html -eq $before) { throw "player-locations: fetchEffigyPlayer main-guid hook not found" }

# Portraits: 3 distinct call sites cover all 4 usages (palPortrait body + paldeck row,
# spawn-modal header img, alpha/boss icon).
$html = $html.Replace(
  "'/api/palicon?name='+encodeURIComponent(name)",
  "'pals/'+encodeURIComponent(name)+'.png'")
$html = $html.Replace(
  "'/api/palicon?name='+encodeURIComponent(d.name)",
  "'pals/'+encodeURIComponent(d.name)+'.png'")
$html = $html.Replace(
  "'/api/palicon?name='+encodeURIComponent(displayName||internal)",
  "'pals/'+encodeURIComponent(displayName||internal)+'.png'")

# (6) Remove the now-unreachable admin JS (refreshAll + all live pollers, settings,
# save manager, maintenance, and the kick/ban/reboot/shutdown action functions).
# It is one contiguous run from refreshAll() up to the boot call we injected above,
# and nothing the data views use lives inside it (renderCharts is defined earlier).
# This makes the published source genuinely read-only -- no admin endpoint URLs at all.
$html = [System.Text.RegularExpressions.Regex]::Replace(
  $html, 'async function refreshAll\(\)\{.*?(?=fetchPaldeck\(\);)', '', $rxOpts)

# (6b) Inject a READ-ONLY "Server Settings" tab. The admin keeps its full editable
# settings panel (in the stripped #view-dashboard); this is a public-only viewer that
# reuses the surviving META/CATS/esc/stripQ globals and loads the redacted
# data/settings.json. The 'Server' category is hidden in the renderer too, matching the
# data-layer redaction above.
$html = $html.Replace(
  "<button class=""nav-tab"" data-tab=""effigies"" onclick=""switchView('effigies')"">Map</button>",
  "<button class=""nav-tab"" data-tab=""effigies"" onclick=""switchView('effigies')"">Map</button>`r`n    <button class=""nav-tab"" data-tab=""settings"" onclick=""switchView('settings')"">Settings</button>")
# NOTE: view-settings is injected just before </body>, i.e. AFTER the boot script
# (fetchPaldeck();switchView('pals');) runs. So on the first switchView call the div
# does not exist yet -- a bare getElementById('view-settings').style would throw a
# TypeError, aborting switchView BEFORE it reaches fetchPals(), leaving the Pals view
# stuck on "loading" until the user toggles tabs (by then the div is parsed). Guard it
# so the boot completes; the div is display:none by default, so skipping it is fine.
$html = $html.Replace(
  "document.getElementById('view-effigies').style.display=name==='effigies'?'':'none';",
  "document.getElementById('view-effigies').style.display=name==='effigies'?'':'none';`r`n  var _vs=document.getElementById('view-settings');if(_vs)_vs.style.display=name==='settings'?'':'none';")
$html = $html.Replace(
  "if(name==='effigies') initEffigyView();",
  "if(name==='effigies') initEffigyView();`r`n  if(name==='settings') fetchSettings();")

$settingsBlock = @'
<div id="view-settings" class="page" style="display:none">
  <div class="panel">
    <div class="panel-header">
      <span>Server Settings</span>
      <span class="hint">Read-only &bull; current world configuration</span>
    </div>
    <div id="sv-tab-bar" class="tab-bar"><div class="empty-state" style="padding:12px">Loading settings...</div></div>
    <div id="sv-grid" class="settings-grid"></div>
  </div>
</div>
<script>
(function(){
  var svData=null, svCat=null;
  var SV_CATS=CATS.filter(function(c){return c!=='Server';});

  // -- Data freshness ----------------------------------------------------------
  // DATA_TS is the ISO-8601 UTC stamp baked in when this site was generated. We show
  // it as a relative age ("3 hr ago") so players know how stale the data is, with the
  // exact local time on hover. Refreshed every minute so the label stays current.
  // DATA_TS is overwritten from data/meta.json (the true Level.sav save time) on load;
  // the baked __GEN_TS__ is only a FALLBACK (it is the shell's generation time, which
  // since the R2 split no longer tracks the data -- the shell deploys independently of
  // the per-save data, so the baked stamp would show shell-deploy age, not data age).
  var DATA_TS='__GEN_TS__';
  function relAge(ms){
    var s=Math.max(0,Math.floor(ms/1000));
    if(s<60) return 'just now';
    var m=Math.floor(s/60); if(m<60) return m+' min ago';
    var h=Math.floor(m/60); if(h<24) return h+' hr'+(h===1?'':'s')+' ago';
    var d=Math.floor(h/24); return d+' day'+(d===1?'':'s')+' ago';
  }
  function renderDataAge(){
    var el=document.getElementById('last-updated'); if(!el) return;
    var t=Date.parse(DATA_TS);
    if(isNaN(t)){ el.textContent='-'; return; }
    var ageMs=Date.now()-t;
    el.textContent=relAge(ageMs);
    var box=document.getElementById('data-fresh');
    if(box){
      box.title='Data generated '+new Date(t).toLocaleString();
      // Tint the "Updated ... ago" text so stale data is visible at a glance instead of
      // reading identically whether it's 3 minutes or 6 hours old.
      var mins=ageMs/60000;
      box.style.color=mins>60?'var(--red)':mins>15?'var(--yellow)':'var(--muted)';
    }
  }
  function svLookup(map,k){
    if(!map) return undefined;
    if(k in map) return map[k];
    var lk=k.toLowerCase(), ks=Object.keys(map);
    for(var i=0;i<ks.length;i++){ if(ks[i].toLowerCase()===lk) return map[ks[i]]; }
    return undefined;
  }
  function svVal(k){
    var v=svLookup(svData&&svData.active,k);
    if(v===undefined||v==='') v=svLookup(svData&&svData.defaults,k);
    return v==null?'':String(v);
  }
  function svFmt(k){
    var m=META[k], v=svVal(k);
    if(m.t==='bool'){
      var on=String(v).toLowerCase()==='true';
      return '<span class="tag '+(on?'tag-green':'tag-muted')+'">'+(on?'On':'Off')+'</span>';
    }
    v=stripQ(v);
    if(m.t==='float'){ var f=parseFloat(v); if(!isNaN(f)) v=String(Math.round(f*1000)/1000); }
    if(v==='') return '<span style="color:var(--muted)">&mdash;</span>';
    return '<span style="font-weight:600;color:var(--text)">'+esc(v)+'</span>';
  }
  function renderSvTabs(){
    var bar=document.getElementById('sv-tab-bar'); if(!bar) return;
    bar.innerHTML=SV_CATS.filter(function(c){return Object.keys(META).some(function(k){return META[k].c===c;});})
      .map(function(c){
        return '<button type="button" class="tab'+(c===svCat?' active':'')+'" onclick="svSwitch(\''+c+'\')">'+esc(c)+'</button>';
      }).join('');
  }
  function renderSvGrid(){
    var grid=document.getElementById('sv-grid'); if(!grid) return;
    var keys=Object.keys(META).filter(function(k){return META[k].c===svCat;});
    if(!keys.length){ grid.innerHTML='<div class="empty-state">No settings here.</div>'; return; }
    grid.innerHTML=keys.map(function(k){
      var m=META[k], def=stripQ(svLookup(svData&&svData.defaults,k)||'');
      return '<div class="setting-row"><div class="setting-info">'
        +'<div class="setting-name" title="'+esc(k)+'">'+esc(k)+'</div>'
        +'<div class="setting-desc">'+esc(m.d)+'</div>'
        +(def?'<div class="setting-def">Default: '+esc(def)+'</div>':'')
        +'</div><div class="setting-ctrl">'+svFmt(k)+'</div></div>';
    }).join('');
  }
  window.svSwitch=function(c){ svCat=c; renderSvTabs(); renderSvGrid(); };
  window.fetchSettings=async function(){
    if(svData) return;
    try{
      var r=await fetch('data/settings.json');
      svData=await r.json();
    }catch(e){
      var g=document.getElementById('sv-grid'); if(g) g.innerHTML='<div class="empty-state err">Could not load settings.</div>';
      var b=document.getElementById('sv-tab-bar'); if(b) b.innerHTML='';
      return;
    }
    if(!svCat) svCat=SV_CATS[0];
    renderSvTabs(); renderSvGrid();
  };

  // Pull the real data age from the freshness marker on load (it matches the data the page
  // just fetched). _lastSaved tracks which save the on-screen data reflects, so the
  // auto-refresh below only re-pulls when a genuinely newer sync has landed.
  var _lastSaved=null;
  function loadDataAge(){
    fetch('data/meta.json',{cache:'no-store'}).then(function(r){return r.ok?r.json():null;}).then(function(m){
      if(m && m.savedAt){ DATA_TS=m.savedAt; _lastSaved=m.savedAt; }
      renderDataAge();
    }).catch(function(){ renderDataAge(); });
  }
  // Auto-refresh the page WITHOUT a manual reload. Poll the tiny freshness marker every
  // 30s (the sync itself only lands new data every ~60s, so this just halves the average
  // wait to notice it -- polling faster than the sync cadence wouldn't reduce latency
  // further); when savedAt advances (a new R2 sync landed), silently re-pull whatever's on
  // screen. pals/eggs refetch with no loading flash; paldeck keeps its selection; effigies
  // (the Map tab) re-pulls the SELECTED player's collected effigies/journals/bounties via
  // fetchEffigyPlayer -- the marker LOCATIONS are static but the collected STATE is exactly
  // what changes when someone picks one up in-game, so this is the one that makes "pick up
  // an effigy -> map updates on its own" work. It only touches per-player state, not the
  // Leaflet map instance or the player roster. Only a real data change triggers any of
  // this, so idle polling is just one small meta.json request.
  function autoRefresh(){
    fetch('data/meta.json',{cache:'no-store'}).then(function(r){return r.ok?r.json():null;}).then(function(m){
      if(!m || !m.savedAt) return;
      DATA_TS=m.savedAt; renderDataAge();
      if(m.savedAt===_lastSaved) return;
      _lastSaved=m.savedAt;
      var t=(document.querySelector('.nav-tab.active')||{}).dataset; t=t&&t.tab;
      try{
        if(t==='pals' && typeof fetchPals==='function') fetchPals(true);
        else if(t==='eggs' && typeof fetchEggs==='function') fetchEggs(true);
        else if(t==='paldeck' && typeof fetchPaldeck==='function') fetchPaldeck();
        else if(t==='effigies' && typeof fetchEffigyPlayer==='function') fetchEffigyPlayer();
      }catch(e){}
    }).catch(function(){});
  }
  loadDataAge();
  setInterval(renderDataAge,60000);
  setInterval(autoRefresh,30000);
})();
</script>
'@
# Bake the real generation time (ISO-8601 UTC) into the injected script so the data-age
# label reflects when the data was built, independent of the viewer's clock/timezone.
$genStamp = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
$settingsBlock = $settingsBlock.Replace('__GEN_TS__', $genStamp)
# Inject before the FINAL </body> only. A plain .Replace('</body>', ...) would also fire
# on any literal "</body>" sitting in a script string/comment, splicing this block (which
# ends with </script>) into the middle of the main script and closing it early -- the rest
# of the page then renders as raw text. LastIndexOf anchors to the real closing tag.
$bodyClose = $html.LastIndexOf('</body>')
if ($bodyClose -lt 0) { throw "Could not find closing </body> to inject the Settings block" }
$html = $html.Substring(0, $bodyClose) + $settingsBlock + "`r`n" + $html.Substring($bodyClose)

# (7) Normalize inherited non-ASCII so the served file is pure ASCII:
#  - U+2500 box-drawing appears only in section-divider comments -> '-'
#  - U+00A0 non-breaking space (a stray in a string literal) -> regular space
$html = $html.Replace([char]0x2500, '-')
$html = $html.Replace([char]0x00A0, ' ')

# Sanity: the transforms above must have actually fired.
if ($html.Contains('id="view-dashboard"')) { throw "view-dashboard was not removed" }
if ($html.Contains("getElementById('view-dashboard')")) { throw "switchView still references removed view-dashboard" }
if ($html.Contains('id="view-datamine"')) { throw "view-datamine was not removed" }
if ($html.Contains('data-tab="datamine"')) { throw "Data Mine nav tab was not removed" }
if ($html.Contains('function fetchDataMine(') -or $html.Contains('function renderDataMine(')) { throw "Data Mine JS block was not removed" }
if ($html.Contains('function kickPlayer')) { throw "admin JS block was not removed" }
if ($html.Contains("switchView('pals')") -eq $false) { throw "boot was clobbered by admin strip" }
if ($html.Contains('Refresh now')) { throw "header Refresh row was not removed" }
if ($html.Contains('onclick="fetchPals()"') -or $html.Contains('onclick="fetchPaldeck()"') -or $html.Contains('onclick="reloadEffigyView()"')) { throw "a per-view Reload button was not removed" }
if (-not $html.Contains('data-tab="settings"')) { throw "Settings nav tab was not injected" }
if (-not $html.Contains('id="view-settings"')) { throw "Settings view was not injected" }
$vsCount = ([regex]::Matches($html, 'id="view-settings"')).Count
if ($vsCount -ne 1) { throw "Settings block injected $vsCount times (expected 1) -- a stray </body> in the source likely tripped the injector" }
if (-not $html.Contains('window.fetchSettings')) { throw "Settings script was not injected" }
if (-not $html.Contains("if(name==='settings') fetchSettings();")) { throw "switchView was not wired for the Settings tab" }
if (-not $html.Contains('function cryptName(')) { throw "paldeck spoiler: cryptName helper missing from output" }
if (-not $html.Contains('var _msk=(count===0)')) { throw "paldeck spoiler: mask flag missing from output" }
if (-not $html.Contains('var revealedSet=new Set()')) { throw "effigy spoiler: revealed-set computation missing from output" }
if (-not $html.Contains('!revealedSet.has(id.toUpperCase())')) { throw "effigy spoiler: render-loop skip missing from output" }
# Marker cache + diff engine (2026-07-06 perf pass): renderEffigyMapNow/renderPlayerMarkers
# must survive intact and exactly-once -- both are string-surgery-adjacent to the anchors
# above (collectedCount/revealedSet live inside renderEffigyMapNow), so a future edit that
# shifts them out of place would otherwise gen clean and only surface as a silent perf
# regression or blank map on the live site.
$rmnCount = ([regex]::Matches($html, 'function renderEffigyMapNow\(')).Count
if ($rmnCount -ne 1) { throw "renderEffigyMapNow found $rmnCount times in output (expected 1)" }
$rpmCount = ([regex]::Matches($html, 'function renderPlayerMarkers\(')).Count
if ($rpmCount -ne 1) { throw "renderPlayerMarkers found $rpmCount times in output (expected 1)" }
if (-not $html.Contains('var PREFS_ENABLED=true;')) { throw "prefs: were not enabled for the public site" }
if (-not $html.Contains('fetchPaldeck();loadPrefs();')) { throw "prefs: loadPrefs was not wired into boot" }
if ($html.Contains('__GEN_TS__')) { throw "data-age generation stamp placeholder was not substituted" }

# Generic leaked-route scan: catches ANY admin-only /api/* reference left in the output,
# not just the handful of routes the old asserts named one-by-one (that list had already
# fallen behind -- it missed /api/paldeck, /api/effigies, /api/bounty-bosses, /api/npcs,
# /api/landmarks, /api/pal-species, and more). A route added to the admin dashboard without
# a matching repoint here would previously gen clean and 404 silently on whichever public
# tab hit it; this covers every route by construction instead of needing a new named assert
# each time one is added. Only the two Pages Functions routes and the Worker's prefs route
# are meant to survive into the public output.
$apiWhitelist = @('/api/palmaptile', '/api/palspawn', '/api/prefs')
foreach ($m in [regex]::Matches($html, '/api/[A-Za-z0-9_-]+')) {
  if ($apiWhitelist -notcontains $m.Value) { throw "leaked admin route in public output: $($m.Value)" }
}

# Expected data/*.json references must all be present -- catches a repoint whose source
# string quietly stopped matching (Replace() no-ops instead of erroring, e.g. after an
# unrelated admin-JS reformat) just as surely as one that was never added, since either way
# the tab ends up fetching nothing.
$expectedDataRefs = @(
  'data/pals.json', 'data/eggs.json', 'data/server-messages.json', 'data/paldeck.json',
  'data/effigies.json', 'data/journals.json', 'data/bounty-bosses.json',
  'data/wanted-fugitives.json', 'data/eagle-statues.json', 'data/towers.json',
  'data/pal-species.json', 'data/pal-skills.json',
  'data/pal-passives.json', 'data/settings.json', 'data/meta.json',
  'data/player-location/', 'data/player-effigies/', 'data/player-notes/',
  'data/player-bounties/', 'data/player-fugitives/', 'data/player-eagles/',
  'data/player-tower-bosses/'
)
foreach ($ref in $expectedDataRefs) {
  if (-not $html.Contains($ref)) { throw "expected data reference missing from output: $ref" }
}

foreach ($ch in $html.ToCharArray()) { if ([int]$ch -gt 127) { throw ("non-ASCII char U+{0:X4} left in output" -f [int]$ch) } }

[System.IO.File]::WriteAllText((Join-Path $Pub 'index.html'), $html, [System.Text.UTF8Encoding]::new($false))

Write-Step "done. Site at $Pub"
