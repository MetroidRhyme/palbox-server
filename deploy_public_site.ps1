# deploy_public_site.ps1
# Deploys the STATIC "shell" of the public site (index.html, _worker.js, portraits,
# icons, effigies + pal-species data) to Cloudflare Pages. Since the move to R2, the
# frequently-changing per-player data is NO LONGER deployed here -- it is pushed to the
# R2 bucket by sync_public_data.ps1 on the Manager's poll cadence, with no Pages deploy.
# So this script only needs to run when the dashboard UI (the shell) actually changes,
# which is a manual dev action. RUN IT WITH -Force:
#
#     & <server-root>\deploy_public_site.ps1 -Force
#
# The Manager no longer calls this script automatically (it calls sync_public_data.ps1
# instead), so shell deploys stay rare and far under the 500-deploys/month free cap.
#
# The cadence gating below is LEGACY from when this script published the data too. It
# only applies if you run without -Force; for a shell deploy you always want -Force.
# (Kept rather than removed so the script still no-ops safely if invoked bare.)
#
# Credentials are read by Wrangler from the process environment:
#   CLOUDFLARE_API_TOKEN   (scoped: Account > Cloudflare Pages > Edit)
#   CLOUDFLARE_ACCOUNT_ID
# Set these once as user environment variables; they are never stored in this repo.

[CmdletBinding()]
param(
  [string]$Root = $PSScriptRoot,
  [string]$Project = 'your-pages-project',
  [int]$MinIntervalMinutes = 60,   # min gap between deploys while players are online
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Site-specific names come from a local, git-ignored config.ps1 (copy config.example.ps1).
$__cfg = Join-Path $PSScriptRoot 'config.ps1'
if (Test-Path $__cfg) { . $__cfg; if ($PagesProject) { $Project = $PagesProject } }

$SaveGamesRoot = Join-Path $Root 'Pal\Saved\SaveGames\0'
$IniPath = Join-Path $Root 'Pal\Saved\Config\WindowsServer\GameUserSettings.ini'
$StateFile = Join-Path $Root '.palbox_deploy_state.json'
$Pub = Join-Path $Root 'public'
$DashBase = 'http://localhost:8213'

function Write-Step($m) { Write-Host ("[deploy {0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

# Make credentials available no matter how we were launched (manual shell, the
# Server Manager's detached child process, etc.): if they aren't in this process's
# environment, fall back to the persisted User/Machine scopes. Wrangler reads them
# from the process environment.
foreach ($v in 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID') {
  if (-not [Environment]::GetEnvironmentVariable($v, 'Process')) {
    $val = [Environment]::GetEnvironmentVariable($v, 'User')
    if (-not $val) { $val = [Environment]::GetEnvironmentVariable($v, 'Machine') }
    if ($val) { Set-Item -Path ("Env:" + $v) -Value $val }
  }
}

# Single-flight: the Manager fires this every poll, so never let two runs overlap
# (a long wrangler upload must not collide with the next tick). The OS releases the
# mutex automatically when this process exits, so no explicit cleanup is needed.
$mutex = New-Object System.Threading.Mutex($false, 'PalBoxPublicDeploy')
if (-not $mutex.WaitOne(0)) { Write-Step 'another deploy run is in progress; skipping.'; exit 0 }

# ── Load / default persistent state ────────────────────────────────────────────
# wasOnline        : was a player online at the previous check?
# finalSyncPending : do we still owe a "server emptied" final sync?
# lastDeployStamp  : Level.sav LastWriteTime ticks at last successful deploy
# lastDeployTicks  : wall-clock (UTC ticks) of last successful deploy
function Get-State {
  if (Test-Path -LiteralPath $StateFile) {
    try { return (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json) } catch {}
  }
  return [pscustomobject]@{ wasOnline = $false; finalSyncPending = $false; lastDeployStamp = ''; lastDeployTicks = 0 }
}
function Save-State($s) {
  ($s | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

# ── Online player count from the local dashboard (-1 = unknown/unreachable) ────
function Get-OnlineCount {
  try {
    $r = Invoke-WebRequest -Uri "$DashBase/api/players" -UseBasicParsing -TimeoutSec 20
    $d = $r.Content | ConvertFrom-Json
    $arr = if ($d.players) { $d.players } elseif ($d.Players) { $d.Players } else { @() }
    return @($arr).Count
  } catch {
    try {
      $r = Invoke-WebRequest -Uri "$DashBase/api/metrics" -UseBasicParsing -TimeoutSec 20
      $d = $r.Content | ConvertFrom-Json
      foreach ($k in 'currentplayernum', 'currentplayers', 'players') {
        if ($d.PSObject.Properties[$k]) { return [int]$d.$k }
      }
    } catch {}
  }
  return -1
}

# ── Locate the active world's Level.sav ────────────────────────────────────────
$m = Select-String -LiteralPath $IniPath -Pattern 'DedicatedServerName=([0-9A-Fa-f]+)'
if (-not $m) { throw "Could not find DedicatedServerName in $IniPath" }
$guid = $m.Matches[0].Groups[1].Value
$levelSav = Join-Path (Join-Path $SaveGamesRoot $guid) 'Level.sav'
if (-not (Test-Path -LiteralPath $levelSav)) { throw "Level.sav not found: $levelSav" }
$stamp = [string]([System.IO.File]::GetLastWriteTimeUtc($levelSav).Ticks)

$state = Get-State
$changed = ($stamp -ne $state.lastDeployStamp)

# ── Decide whether to deploy ───────────────────────────────────────────────────
$deploy = $false
$reason = ''

if ($Force) {
  $deploy = $true; $reason = 'forced'
} else {
  $online = Get-OnlineCount
  if ($online -lt 0) {
    Write-Step "online status unknown (dashboard unreachable); skipping with no state change."
    exit 0
  }

  if ($online -ge 1) {
    # Someone is playing: throttle to once per hour, only when there's new info.
    # Mark that we'll owe a final sync once they all leave.
    $state.wasOnline = $true
    $state.finalSyncPending = $true
    $elapsedMin = ([DateTime]::UtcNow - [DateTime]::new([long]$state.lastDeployTicks, [DateTimeKind]::Utc)).TotalMinutes
    if ($changed -and $elapsedMin -ge $MinIntervalMinutes) {
      $deploy = $true; $reason = "hourly sync ($online online, save changed)"
    } else {
      Write-Step ("no deploy: {0} online, changed={1}, {2:N0} min since last (need {3})." -f $online, $changed, $elapsedMin, $MinIntervalMinutes)
    }
  } else {
    # Nobody online.
    if ($state.wasOnline) { $state.wasOnline = $false }   # just emptied
    if ($state.finalSyncPending) {
      # PalWorld's autosave writes Level.sav on its own ~30-min timer, usually AFTER
      # the player has logged off. So at the moment the server empties the save often
      # hasn't changed yet. Keep finalSyncPending set until a sync with real changes
      # actually fires -- the Manager polls this script every tick even while empty, so
      # the deferred autosave still gets published once, then we go quiet.
      if ($changed) {
        $deploy = $true; $reason = 'final sync (server emptied)'
        $state.finalSyncPending = $false   # cleared only once the post-session save is actually published
      } else {
        Write-Step "server empty; waiting for the post-logout autosave to land before final sync."
      }
    } else {
      Write-Step "server empty and already synced; waiting for a player to return."
    }
  }
}

if (-not $deploy) {
  Save-State $state
  exit 0
}

# ── Require credentials before doing real work ─────────────────────────────────
if (-not $env:CLOUDFLARE_API_TOKEN) { throw "CLOUDFLARE_API_TOKEN is not set in the environment." }
if (-not $env:CLOUDFLARE_ACCOUNT_ID) { throw "CLOUDFLARE_ACCOUNT_ID is not set in the environment." }

# ── Generate + deploy ──────────────────────────────────────────────────────────
Write-Step "deploying: $reason"
& (Join-Path $Root 'gen_public_site.ps1') -Root $Root
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "gen_public_site.ps1 failed (exit $LASTEXITCODE)" }

$wrangler = Get-Command wrangler -ErrorAction SilentlyContinue
if ($wrangler) {
  & wrangler pages deploy $Pub --project-name=$Project
} else {
  Write-Step "wrangler not on PATH; using npx wrangler"
  & npx wrangler pages deploy $Pub --project-name=$Project
}
if ($LASTEXITCODE -ne 0) { throw "wrangler deploy failed (exit $LASTEXITCODE)" }

# ── Record success ─────────────────────────────────────────────────────────────
$state.lastDeployStamp = $stamp
$state.lastDeployTicks = [DateTime]::UtcNow.Ticks
Save-State $state
Write-Step "deploy complete; state saved."
