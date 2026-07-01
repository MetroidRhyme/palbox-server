# sync_public_data.ps1
# Pushes the frequently-changing PalBox data (pals/paldeck/eggs/player-effigies/
# settings, per-player scoped) to the R2 bucket the public site's Worker reads from.
# This is the cheap, high-frequency path: it runs every Server Manager poll and does
# real work only when the world save actually changed, uploading just the files whose
# content changed. It NEVER triggers a Cloudflare Pages deploy, so it is exempt from
# the 500-deploys/month cap -- the static "shell" (index.html, worker, portraits,
# icons, effigies/species data) is deployed separately and rarely by
# deploy_public_site.ps1.
#
# How it stays cheap:
#   * If Level.sav is unchanged since the last successful sync (and not -Force), it
#     exits immediately without rebuilding anything.
#   * Otherwise it rebuilds the frequent data, then uploads ONLY the files whose
#     SHA-256 differs from the last upload (tracked in .palbox_r2_sync_state.json).
#     A typical sync touches a handful of small JSON files -> a few R2 Class A ops,
#     far under the 1M/month free tier.
#   * Keys for players that no longer exist are deleted from the bucket.
#
# R2 key layout (mirrors the build's data/ tree minus the leading 'data/'), and MUST
# match the keys site_src\_worker.js requests:
#   all/pals.json  all/paldeck.json  all/eggs.json            (admin set)
#   by-player/<GUID>/{pals,paldeck,eggs}.json                 (per-player scoped)
#   player-effigies/<GUID>.json                               (per-player)
#   settings.json                                             (shared, redacted)
#
# Credentials (read from the environment by wrangler; never stored in this repo):
#   CLOUDFLARE_API_TOKEN     -- needs BOTH Cloudflare Pages:Edit AND Workers R2 Storage:Edit
#   CLOUDFLARE_ACCOUNT_ID

[CmdletBinding()]
param(
  [string]$Root = $PSScriptRoot,
  [string]$Bucket = 'your-r2-bucket',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# This script runs detached and hidden (launched by the Manager's Trigger-PublicDeploy
# via Start-Process -WindowStyle Hidden with no stdio redirection), so an unhandled error
# previously vanished completely -- no console, no log, nothing -- and the public site's
# data could go stale indefinitely with zero visible signal. Log every failure here so it
# can be diagnosed instead of silently repeating every poll forever.
$LogFile = Join-Path $Root 'sync_public_data.log'
trap {
  $entry = "[{0:yyyy-MM-dd HH:mm:ss}] FAILED: {1}`n{2}`n{3}`n" -f (Get-Date), $_.Exception.Message, $_.InvocationInfo.PositionMessage, $_.ScriptStackTrace
  try { Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8 } catch {}
  Write-Host $entry
  exit 1
}

# Site-specific names come from a local, git-ignored config.ps1 (copy config.example.ps1).
$__cfg = Join-Path $PSScriptRoot 'config.ps1'
if (Test-Path $__cfg) { . $__cfg; if ($R2Bucket) { $Bucket = $R2Bucket } }

$SaveGamesRoot = Join-Path $Root 'Pal\Saved\SaveGames\0'
$IniPath = Join-Path $Root 'Pal\Saved\Config\WindowsServer\GameUserSettings.ini'
$StateFile = Join-Path $Root '.palbox_r2_sync_state.json'
$StageDir = Join-Path $Root '.r2_stage'
$StageData = Join-Path $StageDir 'data'

function Write-Step($m) { Write-Host ("[r2sync {0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

# ── Credentials: fall back to persisted User/Machine scope if not in this process ──
foreach ($v in 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID') {
  if (-not [Environment]::GetEnvironmentVariable($v, 'Process')) {
    $val = [Environment]::GetEnvironmentVariable($v, 'User')
    if (-not $val) { $val = [Environment]::GetEnvironmentVariable($v, 'Machine') }
    if ($val) { Set-Item -Path ("Env:" + $v) -Value $val }
  }
}

# ── Single-flight: the Manager fires this every poll; never overlap two runs ────
$mutex = New-Object System.Threading.Mutex($false, 'PalBoxR2Sync')
if (-not $mutex.WaitOne(0)) { Write-Step 'another sync run is in progress; skipping.'; exit 0 }

# ── State: { levelStamp: <Level.sav ticks>, files: { "<key>": "<sha256>" } } ────
# levelStamp is bumped only after a fully successful sync, so a partial/failed run is
# retried next poll. files{} is updated per uploaded key, so completed uploads persist
# even if a later one fails.
function Get-State {
  if (Test-Path -LiteralPath $StateFile) {
    try {
      $s = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
      $files = @{}
      if ($s.files) { foreach ($p in $s.files.PSObject.Properties) { $files[$p.Name] = [string]$p.Value } }
      return [pscustomobject]@{ levelStamp = [string]$s.levelStamp; files = $files }
    } catch {}
  }
  return [pscustomobject]@{ levelStamp = ''; files = @{} }
}
function Save-State($s) {
  # Write via temp file + rename (atomic on the same volume) rather than Set-Content
  # directly to $StateFile -- this runs on every uploaded file (see the per-file Save-State
  # call below), so a mid-write interruption (e.g. the nightly maintenance window killing
  # the game server, disk hiccup, etc.) landing exactly here would otherwise leave truncated/
  # corrupt JSON that every subsequent sync attempt has to parse.
  $obj = [ordered]@{ levelStamp = $s.levelStamp; files = $s.files }
  $tmp = "$StateFile.tmp"
  ($obj | ConvertTo-Json -Compress) | Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $StateFile -Force
}

# ── Locate the active world's Level.sav and stamp it ───────────────────────────
$m = Select-String -LiteralPath $IniPath -Pattern 'DedicatedServerName=([0-9A-Fa-f]+)'
if (-not $m) { throw "Could not find DedicatedServerName in $IniPath" }
$guid = $m.Matches[0].Groups[1].Value
$levelSav = Join-Path (Join-Path $SaveGamesRoot $guid) 'Level.sav'
if (-not (Test-Path -LiteralPath $levelSav)) { throw "Level.sav not found: $levelSav" }
$stamp = [string]([System.IO.File]::GetLastWriteTimeUtc($levelSav).Ticks)

$state = Get-State
if (-not $Force -and $stamp -eq $state.levelStamp) {
  Write-Step "Level.sav unchanged since last sync; nothing to do."
  exit 0
}

# ── Require credentials before doing real work ─────────────────────────────────
if (-not $env:CLOUDFLARE_API_TOKEN) { throw "CLOUDFLARE_API_TOKEN is not set in the environment." }
if (-not $env:CLOUDFLARE_ACCOUNT_ID) { throw "CLOUDFLARE_ACCOUNT_ID is not set in the environment." }

# ── Resolve wrangler once ──────────────────────────────────────────────────────
$wranglerCmd = Get-Command wrangler -ErrorAction SilentlyContinue
function Invoke-Wrangler([string[]]$WArgs) {
  # Pipe wrangler's stdout to the host so it does NOT land on this function's output
  # stream -- otherwise the caller's `$code = Invoke-Wrangler ...` would capture the
  # console text mixed with the exit code instead of the integer exit code. Out-Host
  # is a cmdlet, so it leaves $LASTEXITCODE (set by the native wrangler call) intact.
  if ($wranglerCmd) { & wrangler @WArgs | Out-Host }
  else { & npx wrangler @WArgs | Out-Host }
  return $LASTEXITCODE
}

# ── Build the frequent data into the staging dir ───────────────────────────────
Write-Step "building frequent data -> $StageData"
& (Join-Path $Root 'build_public_data.ps1') -Root $Root -OutDir $StageDir -Mode Frequent
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "build_public_data.ps1 failed (exit $LASTEXITCODE)" }

# ── Enumerate built files -> R2 keys (relative to data\, forward slashes) ───────
# SHA-256 via the .NET API rather than Get-FileHash: Get-FileHash lives in the
# Microsoft.PowerShell.Utility module, which fails to resolve when this script is launched
# as a detached powershell.exe whose PSModulePath was inherited from a PowerShell 7 parent
# (e.g. the Manager started from a pwsh session). The .NET class has no such dependency, so
# the high-frequency auto-sync works regardless of how the Manager was launched. Output is
# uppercase hex with no separators -- identical to Get-FileHash, so existing state hashes
# stay comparable and only genuinely-changed files re-upload.
function Get-Sha256Hex([string]$path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($path))).Replace('-', '') }
  finally { $sha.Dispose() }
}
$current = @{}
foreach ($f in Get-ChildItem -LiteralPath $StageData -Recurse -File) {
  $rel = $f.FullName.Substring($StageData.Length + 1).Replace('\', '/')
  $current[$rel] = Get-Sha256Hex $f.FullName
}

# ── Upload changed/new files ───────────────────────────────────────────────────
$uploaded = 0; $skipped = 0
foreach ($key in $current.Keys) {
  if ($state.files[$key] -eq $current[$key]) { $skipped++; continue }
  $full = Join-Path $StageData ($key -replace '/', '\')
  Write-Step "put $key"
  $code = Invoke-Wrangler @('r2', 'object', 'put', "$Bucket/$key", '--file', $full, '--content-type', 'application/json', '--remote')
  if ($code -ne 0) { throw "wrangler r2 object put failed for $key (exit $code)" }
  $state.files[$key] = $current[$key]
  $uploaded++
  Save-State $state   # persist progress per-file so a later failure doesn't redo this one
}

# ── Delete keys for files that no longer exist (e.g. a removed player) ──────────
$deleted = 0
foreach ($key in @($state.files.Keys)) {
  if ($current.ContainsKey($key)) { continue }
  Write-Step "delete $key (no longer produced)"
  $code = Invoke-Wrangler @('r2', 'object', 'delete', "$Bucket/$key", '--remote')
  if ($code -ne 0) { Write-Step "  WARNING: delete failed for $key (exit $code); will retry next sync"; continue }
  $state.files.Remove($key)
  $deleted++
}

# ── Record success ─────────────────────────────────────────────────────────────
# Publish a freshness marker the public site reads (data/meta.json) so it can show the
# TRUE data age. The shell's baked-in generation time is no longer a valid data stamp
# now that the shell deploys independently of the per-save R2 data. savedAt = the
# Level.sav mtime this sync reflects; written to its OWN R2 key, outside StageData, so
# it never perturbs the per-file change detection above.
$savedAtIso = [DateTime]::new([long]$stamp, [DateTimeKind]::Utc).ToString('yyyy-MM-ddTHH:mm:ssZ')
$metaPath = Join-Path $StageDir 'meta.json'
$metaObj = [ordered]@{ savedAt = $savedAtIso; syncedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
[IO.File]::WriteAllText($metaPath, ($metaObj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
Write-Step "put meta.json (savedAt=$savedAtIso)"
$mcode = Invoke-Wrangler @('r2', 'object', 'put', "$Bucket/meta.json", '--file', $metaPath, '--content-type', 'application/json', '--remote')
if ($mcode -ne 0) { throw "wrangler r2 object put failed for meta.json (exit $mcode)" }

$state.levelStamp = $stamp
Save-State $state
Write-Step "sync complete: $uploaded uploaded, $skipped unchanged, $deleted deleted."
