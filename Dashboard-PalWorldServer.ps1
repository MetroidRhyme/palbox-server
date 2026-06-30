# Dashboard-PalWorldServer.ps1
# Starts a local admin dashboard at http://localhost:8080 and opens your browser.
# Run this in its own PowerShell window. Press Ctrl+C to stop.

$AdminPassword = $(try{$m=[regex]::Match((Get-Content (Join-Path $PSScriptRoot 'Pal\Saved\Config\WindowsServer\PalWorldSettings.ini') -Raw),'AdminPassword="([^"]*)"');if($m.Success){$m.Groups[1].Value}else{''}}catch{''})
$PalApiBase    = "http://localhost:8212"
$DashPort      = 8213
$StartScript   = "$PSScriptRoot\Start-PalWorldServer.ps1"

function Get-PalHeaders {
    $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$AdminPassword"))
    return @{ Authorization = "Basic $cred"; "Content-Type" = "application/json" }
}

function Send-Response {
    param($Response, [int]$StatusCode, [string]$ContentType, [string]$Body)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode  = $StatusCode
    $Response.ContentType = $ContentType
    try {
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Response.OutputStream.Close()
    } catch {}
}

# ── Proxy route table ───────────────────────────────────────────────────────
$ProxyRoutes = @{
    "GET /api/info"      = @{ PalPath = "info";     Method = "GET"  }
    "GET /api/metrics"   = @{ PalPath = "metrics";  Method = "GET"  }
    "GET /api/players"   = @{ PalPath = "players";  Method = "GET"  }
    "GET /api/settings"  = @{ PalPath = "settings"; Method = "GET"  }
    "POST /api/announce" = @{ PalPath = "announce"; Method = "POST" }
    "POST /api/kick"     = @{ PalPath = "kick";     Method = "POST" }
    "POST /api/ban"      = @{ PalPath = "ban";      Method = "POST" }
    "POST /api/unban"    = @{ PalPath = "unban";    Method = "POST" }
    "POST /api/save"     = @{ PalPath = "save";     Method = "POST" }
    "POST /api/shutdown" = @{ PalPath = "shutdown"; Method = "POST" }
    "POST /api/stop"     = @{ PalPath = "stop";     Method = "POST" }
}

# ── HTML dashboard ──────────────────────────────────────────────────────────
# All non-ASCII characters use HTML entities or JS \uXXXX escapes to avoid
# encoding issues when PowerShell serves the string as UTF-8 bytes.
$HtmlPage = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Palworld Admin</title>
<style>
:root {
  --bg:      #0d1117;
  --surface: #161b22;
  --surface2:#21262d;
  --border:  #30363d;
  --text:    #c9d1d9;
  --muted:   #8b949e;
  --green:   #3fb950;
  --red:     #f85149;
  --yellow:  #e3b341;
  --blue:    #58a6ff;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: var(--bg); color: var(--text); font-family: 'Segoe UI', system-ui, sans-serif; font-size: 14px; min-height: 100vh; }

/* Header */
header {
  background: var(--surface); border-bottom: 1px solid var(--border);
  padding: 0 24px; height: 52px;
  display: flex; align-items: center; justify-content: space-between;
  position: sticky; top: 0; z-index: 100;
}
.header-left { display: flex; align-items: center; gap: 10px; }
.logo { font-size: 18px; font-weight: 700; letter-spacing: -0.3px; }
.logo span { color: var(--green); }
.status-dot { width: 9px; height: 9px; border-radius: 50%; background: var(--muted); transition: background 0.4s, box-shadow 0.4s; }
.status-dot.online  { background: var(--green); box-shadow: 0 0 6px var(--green); }
.status-dot.offline { background: var(--red); }
.header-right { display: flex; align-items: center; gap: 12px; color: var(--muted); font-size: 12px; }
.btn-icon { background: var(--surface2); border: 1px solid var(--border); color: var(--text); padding: 4px 10px; border-radius: 6px; cursor: pointer; font-size: 12px; font-family: inherit; }
.btn-icon:hover { background: var(--border); }

/* Main */
main { padding: 20px 24px; max-width: 1280px; margin: 0 auto; }

/* Stats */
.stats-grid { display: grid; grid-template-columns: repeat(5,1fr); gap: 12px; margin-bottom: 20px; }
@media (max-width: 900px) { .stats-grid { grid-template-columns: repeat(3,1fr); } }
@media (max-width: 560px) { .stats-grid { grid-template-columns: repeat(2,1fr); } }
.stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; }
.stat-label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.6px; color: var(--muted); margin-bottom: 6px; }
.stat-val   { font-size: 26px; font-weight: 700; color: var(--blue); line-height: 1; }
.stat-val.good { color: var(--green); }
.stat-val.warn { color: var(--yellow); }
.stat-val.bad  { color: var(--red); }
.stat-val.sm   { font-size: 15px; padding-top: 6px; }
.stat-sub { font-size: 11px; color: var(--muted); margin-top: 5px; }

/* Content grid */
.content-grid { display: grid; grid-template-columns: 1fr 310px; gap: 16px; align-items: start; }
@media (max-width: 800px) { .content-grid { grid-template-columns: 1fr; } }

/* Panel */
.panel { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; overflow: hidden; }
.panel-header { padding: 12px 16px; border-bottom: 1px solid var(--border); font-weight: 600; font-size: 13px; display: flex; align-items: center; justify-content: space-between; }
.badge { background: var(--surface2); border-radius: 20px; padding: 2px 8px; font-size: 11px; color: var(--muted); font-weight: 400; }

/* Table */
table { width: 100%; border-collapse: collapse; }
th { text-align: left; padding: 9px 16px; font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; color: var(--muted); border-bottom: 1px solid var(--border); background: var(--surface2); }
td { padding: 10px 16px; border-bottom: 1px solid var(--border); vertical-align: middle; }
tr:last-child td { border-bottom: none; }
tr:hover td { background: rgba(255,255,255,0.02); }
.player-name { font-weight: 500; }
.ping-good { color: var(--green); }
.ping-ok   { color: var(--yellow); }
.ping-bad  { color: var(--red); }
.empty-state { padding: 48px 16px; text-align: center; color: var(--muted); }
.empty-state.err { color: var(--red); }

/* Buttons */
.btn { padding: 5px 10px; border-radius: 6px; border: 1px solid var(--border); cursor: pointer; font-size: 12px; font-family: inherit; transition: all 0.12s; display: inline-flex; align-items: center; gap: 4px; }
.btn:disabled { opacity: 0.35; cursor: not-allowed; }
.btn-ghost   { background: transparent; color: var(--muted); }
.btn-ghost:hover:not(:disabled)   { background: var(--surface2); color: var(--text); }
.btn-primary { background: var(--blue); color: #0d1117; border-color: var(--blue); font-weight: 600; }
.btn-primary:hover:not(:disabled) { opacity: 0.85; }
.btn-green   { background: transparent; color: var(--green); border-color: var(--green); }
.btn-green:hover:not(:disabled)   { background: rgba(63,185,80,0.1); }
.btn-warn    { background: transparent; color: var(--yellow); border-color: var(--yellow); }
.btn-warn:hover:not(:disabled)    { background: rgba(227,179,65,0.1); }
.btn-danger  { background: transparent; color: var(--red); border-color: var(--red); }
.btn-danger:hover:not(:disabled)  { background: rgba(248,81,73,0.1); }
.btn-full    { width: 100%; justify-content: center; padding: 8px; font-size: 13px; }

/* Actions panel */
.actions-inner { padding: 16px; display: flex; flex-direction: column; gap: 16px; }
.action-group  { display: flex; flex-direction: column; gap: 8px; }
.action-label  { font-size: 11px; text-transform: uppercase; letter-spacing: 0.6px; color: var(--muted); font-weight: 600; }
hr.divider { border: none; border-top: 1px solid var(--border); }
input[type=text], input[type=number], textarea {
  width: 100%; background: var(--surface2); border: 1px solid var(--border);
  border-radius: 6px; padding: 7px 10px; color: var(--text); font-family: inherit; font-size: 13px; outline: none;
}
input:focus, textarea:focus { border-color: var(--blue); }
textarea { resize: vertical; min-height: 64px; }
.row { display: flex; gap: 8px; }
.row input[type=number] { width: 68px; flex-shrink: 0; text-align: center; }
.hint { font-size: 11px; color: var(--muted); }

/* Toasts */
#toasts { position: fixed; bottom: 20px; right: 20px; display: flex; flex-direction: column; gap: 8px; z-index: 999; }
.toast { background: var(--surface2); border: 1px solid var(--border); border-radius: 8px; padding: 11px 15px; font-size: 13px; max-width: 320px; animation: fadeIn 0.18s ease; }
.toast.success { border-left: 3px solid var(--green); }
.toast.error   { border-left: 3px solid var(--red); }
.toast.info    { border-left: 3px solid var(--blue); }
.toast.warn    { border-left: 3px solid var(--yellow); }
@keyframes fadeIn { from { opacity: 0; transform: translateX(12px); } to { opacity: 1; transform: none; } }
</style>
</head>
<body>

<header>
  <div class="header-left">
    <div class="status-dot" id="dot"></div>
    <div class="logo">Server<span>Six</span> Admin</div>
  </div>
  <div class="header-right">
    <span>Updated <b id="last-updated">-</b> &bull; refresh in <b id="countdown">15:00</b></span>
    <button class="btn-icon" onclick="refreshAll()">&#8635; Refresh now</button>
  </div>
</header>

<main>
  <div class="stats-grid">
    <div class="stat-card">
      <div class="stat-label">Players</div>
      <div class="stat-val" id="s-players">-</div>
      <div class="stat-sub" id="s-players-sub">of ? max</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">FPS</div>
      <div class="stat-val" id="s-fps">-</div>
      <div class="stat-sub">server frame rate</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Uptime</div>
      <div class="stat-val" id="s-uptime">-</div>
      <div class="stat-sub" id="s-uptime-sub"></div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Base Camps</div>
      <div class="stat-val" id="s-bases">-</div>
      <div class="stat-sub">active bases</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Version</div>
      <div class="stat-val sm" id="s-version">-</div>
      <div class="stat-sub" id="s-world">-</div>
    </div>
  </div>

  <div class="content-grid">

    <!-- Players panel -->
    <div class="panel">
      <div class="panel-header">
        Online Players
        <span class="badge" id="player-badge">0</span>
      </div>
      <div id="player-area">
        <div class="empty-state">Loading...</div>
      </div>
    </div>

    <!-- Actions panel -->
    <div class="panel">
      <div class="panel-header">Server Actions</div>
      <div class="actions-inner">

        <div class="action-group">
          <div class="action-label">Broadcast Message</div>
          <textarea id="msg" placeholder="Message to all players..."></textarea>
          <button class="btn btn-primary btn-full" onclick="sendMsg()">Send Message</button>
        </div>

        <hr class="divider">

        <div class="action-group">
          <div class="action-label">World</div>
          <button class="btn btn-green btn-full" onclick="saveWorld()">Save World</button>
        </div>

        <hr class="divider">

        <div class="action-group">
          <div class="action-label">Reboot Server</div>
          <div class="row">
            <input type="number" id="reboot-secs" value="60" min="10" max="600" title="Warning seconds">
            <button class="btn btn-warn btn-full" onclick="rebootServer()">Reboot</button>
          </div>
          <div class="hint">Broadcasts an in-game countdown, then restarts the server.</div>
        </div>

        <hr class="divider">

        <div class="action-group">
          <div class="action-label">Danger Zone</div>
          <button class="btn btn-danger btn-full" onclick="forceStop()">Force Stop</button>
        </div>

      </div>
    </div>

  </div>
</main>

<div id="toasts"></div>

<script>
// ── Globals ─────────────────────────────────────────────────────────────────
var players   = [];
var countdown = 900;

// ── Toast ────────────────────────────────────────────────────────────────────
function toast(msg, type, ms) {
  type = type || 'info'; ms = ms || 4500;
  var el = document.createElement('div');
  el.className = 'toast ' + type;
  el.textContent = msg;
  document.getElementById('toasts').appendChild(el);
  setTimeout(function() { el.remove(); }, ms);
}

// ── API ──────────────────────────────────────────────────────────────────────
async function api(path, method, body) {
  method = method || 'GET';
  var opts = { method: method, headers: { 'Content-Type': 'application/json' } };
  if (body) opts.body = JSON.stringify(body);
  var res  = await fetch(path, opts);
  var data = await res.json().catch(function() { return {}; });
  if (!res.ok) throw new Error(data.error || 'HTTP ' + res.status);
  return data;
}

// ── Helpers ──────────────────────────────────────────────────────────────────
function pick(obj) {
  var keys = Array.prototype.slice.call(arguments, 1);
  for (var i = 0; i < keys.length; i++) {
    var lk = keys[i].toLowerCase();
    var entries = Object.entries(obj);
    for (var j = 0; j < entries.length; j++) {
      if (entries[j][0].toLowerCase() === lk && entries[j][1] !== undefined && entries[j][1] !== null) {
        return entries[j][1];
      }
    }
  }
  return null;
}

function fmtUptime(secs) {
  secs = Number(secs) || 0;
  var h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60);
  return h > 0 ? h + 'h ' + m + 'm' : m + 'm';
}

function pingCls(ms) { return ms < 80 ? 'ping-good' : ms < 150 ? 'ping-ok' : 'ping-bad'; }

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}

function setText(id, val) { document.getElementById(id).textContent = val == null ? '-' : val; }

// ── Refresh ───────────────────────────────────────────────────────────────────
async function refreshAll() {
  resetCountdown();
  await Promise.allSettled([fetchInfo(), fetchMetrics(), fetchPlayers()]);
  setText('last-updated', new Date().toLocaleTimeString());
}

async function fetchInfo() {
  try {
    var d = await api('/api/info');
    document.getElementById('dot').className = 'status-dot online';
    setText('s-version', pick(d,'version') || '-');
    var guid = String(pick(d,'worldguid') || '');
    setText('s-world', guid ? guid.substring(0,8) + '...' : '-');
  } catch(e) {
    document.getElementById('dot').className = 'status-dot offline';
  }
}

async function fetchMetrics() {
  try {
    var d     = await api('/api/metrics');
    var fps   = pick(d,'serverfps','fps');
    var cur   = pick(d,'currentplayernum','currentplayers');
    var max   = pick(d,'maxplayernum','maxplayers');
    var up    = pick(d,'uptime');
    var bases = pick(d,'basecampcount','basecamps');

    var fpsN  = Number(fps);
    var fpsEl = document.getElementById('s-fps');
    fpsEl.textContent = isNaN(fpsN) ? (fps || '-') : Math.round(fpsN);
    fpsEl.className   = 'stat-val' + (fpsN >= 55 ? ' good' : fpsN >= 30 ? ' warn' : ' bad');

    setText('s-players',     cur != null ? cur : '-');
    setText('s-players-sub', 'of ' + (max != null ? max : '?') + ' max');
    setText('s-uptime',      up != null ? fmtUptime(up) : '-');
    setText('s-bases',       bases != null ? bases : '-');
  } catch(e) {}
}

async function fetchPlayers() {
  try {
    var d = await api('/api/players');
    players = d.players || d.Players || [];
    renderPlayers();
    setText('player-badge', players.length);
  } catch(e) {
    document.getElementById('player-area').innerHTML = '<div class="empty-state err">Could not reach server</div>';
    setText('player-badge', 0);
  }
}

function renderPlayers() {
  var area = document.getElementById('player-area');
  if (!players.length) {
    area.innerHTML = '<div class="empty-state">No players online</div>';
    return;
  }
  var rows = players.map(function(p, i) {
    var name  = pick(p,'name')  || 'Unknown';
    var lvl   = pick(p,'level');
    var ping  = pick(p,'ping');
    var pingTxt = ping != null ? ping + 'ms' : '-';
    var pingC   = ping != null ? pingCls(Number(ping)) : '';
    return '<tr>'
      + '<td class="player-name">' + esc(name) + '</td>'
      + '<td>' + esc(lvl != null ? lvl : '-') + '</td>'
      + '<td class="' + pingC + '">' + pingTxt + '</td>'
      + '<td>'
      +   '<button class="btn btn-ghost" onclick="kickPlayer(' + i + ')">Kick</button>'
      +   '<button class="btn btn-danger" onclick="banPlayer(' + i + ')" style="margin-left:4px">Ban</button>'
      + '</td>'
      + '</tr>';
  }).join('');
  area.innerHTML = '<table>'
    + '<thead><tr><th>Name</th><th>Level</th><th>Ping</th><th>Actions</th></tr></thead>'
    + '<tbody>' + rows + '</tbody>'
    + '</table>';
}

// ── Actions ───────────────────────────────────────────────────────────────────
async function sendMsg() {
  var msg = document.getElementById('msg').value.trim();
  if (!msg) { toast('Enter a message first.', 'error'); return; }
  try {
    await api('/api/announce', 'POST', { message: msg });
    toast('Message broadcast to all players.', 'success');
    document.getElementById('msg').value = '';
  } catch(e) { toast('Broadcast failed: ' + e.message, 'error'); }
}

async function saveWorld() {
  try {
    await api('/api/save', 'POST');
    toast('World saved.', 'success');
  } catch(e) { toast('Save failed: ' + e.message, 'error'); }
}

async function rebootServer() {
  var secs = parseInt(document.getElementById('reboot-secs').value) || 60;
  if (!confirm('Reboot the server with a ' + secs + '-second in-game warning?')) return;
  try {
    await api('/api/reboot', 'POST', { waittime: secs });
    toast('Reboot initiated - ' + secs + 's countdown running in-game.', 'warn', 7000);
  } catch(e) { toast('Reboot failed: ' + e.message, 'error'); }
}

async function forceStop() {
  if (!confirm('Force stop the server immediately?\nAll unsaved progress will be lost.')) return;
  try {
    await api('/api/stop', 'POST');
    toast('Server force-stopped.', 'warn');
    document.getElementById('dot').className = 'status-dot offline';
  } catch(e) { toast('Stop failed: ' + e.message, 'error'); }
}

async function kickPlayer(i) {
  var p = players[i]; if (!p) return;
  var name   = pick(p,'name') || 'Player';
  var uid    = pick(p,'playeruid','userid','steamid') || '';
  var reason = prompt('Kick reason for ' + name + ':', 'Kicked by admin');
  if (reason === null) return;
  try {
    await api('/api/kick', 'POST', { userid: uid, message: reason });
    toast(name + ' kicked.', 'success');
    await fetchPlayers();
  } catch(e) { toast('Kick failed: ' + e.message, 'error'); }
}

async function banPlayer(i) {
  var p = players[i]; if (!p) return;
  var name   = pick(p,'name') || 'Player';
  var uid    = pick(p,'playeruid','userid','steamid') || '';
  if (!confirm('Permanently ban ' + name + '?')) return;
  var reason = prompt('Ban reason:', 'Banned by admin');
  if (reason === null) return;
  try {
    await api('/api/ban', 'POST', { userid: uid, message: reason });
    toast(name + ' banned.', 'success');
    await fetchPlayers();
  } catch(e) { toast('Ban failed: ' + e.message, 'error'); }
}

// ── Countdown ─────────────────────────────────────────────────────────────────
function fmtCountdown(s) {
  var m = Math.floor(s / 60), sec = s % 60;
  return m + ':' + (sec < 10 ? '0' : '') + sec;
}

function resetCountdown() { countdown = 900; setText('countdown', fmtCountdown(900)); }

function tick() {
  countdown--;
  setText('countdown', fmtCountdown(Math.max(0, countdown)));
  if (countdown <= 0) refreshAll();
}

// ── Boot ──────────────────────────────────────────────────────────────────────
refreshAll();
setInterval(tick, 1000);
</script>
</body>
</html>
'@

# ── HTTP listener ────────────────────────────────────────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$DashPort/")
try { $listener.Start() }
catch {
    Write-Host "ERROR: Could not start listener on port $DashPort. Is it already in use?" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  Palworld Admin Dashboard" -ForegroundColor Cyan
Write-Host "  http://localhost:$DashPort" -ForegroundColor Green
Write-Host ""
Write-Host "  Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

Start-Process "http://localhost:$DashPort"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        $path     = $req.Url.AbsolutePath
        $method   = $req.HttpMethod
        $routeKey = "$method $path"

        $reqBody = $null
        if ($req.HasEntityBody) {
            $reader  = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
            $reqBody = $reader.ReadToEnd()
            $reader.Close()
        }

        # ── Dashboard HTML
        if ($path -eq "/" -or $path -eq "/index.html") {
            Send-Response $res 200 "text/html; charset=utf-8" $HtmlPage

        # ── Proxy to Palworld API
        } elseif ($ProxyRoutes.ContainsKey($routeKey)) {
            $route   = $ProxyRoutes[$routeKey]
            $palUri  = "$PalApiBase/v1/api/$($route.PalPath)"
            $headers = Get-PalHeaders
            try {
                if ($reqBody) {
                    $result = Invoke-RestMethod -Uri $palUri -Method $route.Method -Headers $headers `
                                -Body $reqBody -ContentType "application/json" -ErrorAction Stop
                } else {
                    $result = Invoke-RestMethod -Uri $palUri -Method $route.Method -Headers $headers `
                                -ErrorAction Stop
                }
                $json = ConvertTo-Json $result -Depth 10 -Compress
                Send-Response $res 200 "application/json" $json
            } catch {
                $errJson = ConvertTo-Json @{ error = $_.Exception.Message } -Compress
                Send-Response $res 502 "application/json" $errJson
            }

        # ── Custom reboot: broadcast countdown, stop, restart
        } elseif ($path -eq "/api/reboot" -and $method -eq "POST") {
            $params   = if ($reqBody) { $reqBody | ConvertFrom-Json -ErrorAction SilentlyContinue } else { $null }
            $waitSecs = if ($params -and $null -ne $params.waittime) { [int]$params.waittime } else { 60 }

            $palBase = $PalApiBase; $adminPw = $AdminPassword; $startSc = $StartScript

            Start-Job -Name "PalReboot" -ScriptBlock {
                param($palBase, $adminPw, $startSc, $waitSecs)

                function BC([string]$msg) {
                    $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$adminPw"))
                    $h = @{ Authorization = "Basic $cred"; "Content-Type" = "application/json" }
                    try { Invoke-RestMethod -Uri "$palBase/v1/api/announce" -Method POST -Headers $h `
                              -Body (ConvertTo-Json @{ message = $msg }) | Out-Null } catch {}
                }

                BC "Server rebooting in $waitSecs seconds!"

                $remaining = $waitSecs
                foreach ($mark in @(300, 120, 60, 30, 10, 5)) {
                    if ($remaining -gt $mark) {
                        Start-Sleep -Seconds ($remaining - $mark)
                        $remaining = $mark
                        BC "Server rebooting in $mark seconds!"
                    }
                }
                if ($remaining -gt 0) { Start-Sleep -Seconds $remaining }

                BC "Rebooting now. Back online soon!"
                Start-Sleep -Seconds 2

                # Shut down via REST API so the server closes itself cleanly
                $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$adminPw"))
                $h = @{ Authorization = "Basic $cred"; "Content-Type" = "application/json" }
                try {
                    Invoke-RestMethod -Uri "$palBase/v1/api/shutdown" -Method POST -Headers $h `
                        -Body (ConvertTo-Json @{ waittime = 15; message = "Shutting down now." }) | Out-Null
                } catch {}

                # Wait for the process to fully exit (up to 60s)
                $waited = 0
                while ((Get-Process | Where-Object { $_.Name -like "*PalServer*" }) -and $waited -lt 60) {
                    Start-Sleep -Seconds 2
                    $waited += 2
                }

                Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$startSc`""

            } -ArgumentList $palBase, $adminPw, $startSc, $waitSecs | Out-Null

            $respJson = ConvertTo-Json @{ status = "Reboot initiated"; waittime = $waitSecs } -Compress
            Send-Response $res 200 "application/json" $respJson

        # ── 404
        } else {
            Send-Response $res 404 "application/json" '{"error":"Not found"}'
        }
    }
} finally {
    $listener.Stop()
    Write-Host "Dashboard stopped." -ForegroundColor Yellow
}
