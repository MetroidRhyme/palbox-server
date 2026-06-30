# push_server_messages.ps1
# Mirrors the local server-message feed (server_messages.jsonl) to the public site's R2
# bucket as server-messages.json, so the read-only public dashboard's chat banner shows
# the same broadcasts the admin one does. Launched detached by Add-ServerMessage on each
# new broadcast, so the public banner is near-real-time (a few seconds after the message).
# Single-flight (a burst coalesces to one push that carries the latest file) and hash-gated
# (no upload when nothing changed), so it stays far under the R2 free tier.
#
# Credentials are read from the environment by wrangler (same as sync_public_data.ps1):
#   CLOUDFLARE_API_TOKEN  (needs Workers R2 Storage:Edit)  +  CLOUDFLARE_ACCOUNT_ID
[CmdletBinding()]
param(
  [string]$Root = $PSScriptRoot,
  [string]$Bucket = 'your-r2-bucket'
)

$ErrorActionPreference = 'Stop'

# Site-specific names come from a local, git-ignored config.ps1 (copy config.example.ps1).
$__cfg = Join-Path $PSScriptRoot 'config.ps1'
if (Test-Path $__cfg) { . $__cfg; if ($R2Bucket) { $Bucket = $R2Bucket } }

$MsgFile   = Join-Path $Root 'server_messages.jsonl'
$StageFile = Join-Path $Root '.r2_stage\server-messages.json'
$StateFile = Join-Path $Root '.palbox_msg_push_state.json'

# Fall back to the persisted User/Machine creds if not in this (detached) process.
foreach ($v in 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID') {
  if (-not [Environment]::GetEnvironmentVariable($v, 'Process')) {
    $val = [Environment]::GetEnvironmentVariable($v, 'User')
    if (-not $val) { $val = [Environment]::GetEnvironmentVariable($v, 'Machine') }
    if ($val) { Set-Item -Path ("Env:" + $v) -Value $val }
  }
}
if (-not $env:CLOUDFLARE_API_TOKEN -or -not $env:CLOUDFLARE_ACCOUNT_ID) { exit 0 }

# Single-flight: if a push is already running it will re-read the file and carry whatever
# we just appended, so skipping here loses nothing.
$mutex = New-Object System.Threading.Mutex($false, 'PalBoxMsgPush')
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
  if (-not (Test-Path -LiteralPath $MsgFile)) { exit 0 }

  $items = @()
  foreach ($line in @(Get-Content -LiteralPath $MsgFile -Encoding UTF8)) {
    if (-not $line.Trim()) { continue }
    try { $items += (ConvertFrom-Json $line) } catch {}
  }
  if ($items.Count -gt 50) { $items = $items[-50..-1] }
  # ConvertTo-Json unwraps a single-element array, so force the [ ] for the 1-item case.
  if ($items.Count -eq 0)    { $json = '[]' }
  elseif ($items.Count -eq 1) { $json = '[' + (ConvertTo-Json $items[0] -Depth 5 -Compress) + ']' }
  else                        { $json = ConvertTo-Json $items -Depth 5 -Compress }

  $sha  = [System.Security.Cryptography.SHA256]::Create()
  $hash = [System.BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace('-', '')
  $prev = ''
  if (Test-Path -LiteralPath $StateFile) { try { $prev = (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).hash } catch {} }
  if ($hash -eq $prev) { exit 0 }

  New-Item -ItemType Directory -Force -Path (Split-Path $StageFile) | Out-Null
  [IO.File]::WriteAllText($StageFile, $json, (New-Object System.Text.UTF8Encoding($false)))

  $wr = Get-Command wrangler -ErrorAction SilentlyContinue
  if ($wr) { & wrangler r2 object put "$Bucket/server-messages.json" --file $StageFile --content-type application/json --remote | Out-Host }
  else     { & npx wrangler r2 object put "$Bucket/server-messages.json" --file $StageFile --content-type application/json --remote | Out-Host }
  if ($LASTEXITCODE -eq 0) { (@{ hash = $hash } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StateFile -Encoding UTF8 }
}
finally {
  $mutex.ReleaseMutex(); $mutex.Dispose()
}
