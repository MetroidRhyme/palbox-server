# server_messages.ps1
# Shared helper for the dashboard "server message" banner feed. Every server-originated
# chat broadcast -- maintenance countdowns, egg-ready alerts, manual broadcasts, and the
# reboot/shutdown countdowns -- is recorded here as one JSONL line. The admin dashboard
# reads it via GET /api/server-messages; the public site reads a mirrored copy from R2
# (server-messages.json) that push_server_messages.ps1 uploads. PalWorld exposes no
# chat-read API, so this captures only what WE send through /v1/api/announce; there is no
# player chat here.
#
# Dot-source this file to get Add-ServerMessage / Get-ServerMessages. Safe to call from
# any process (Manager job, maintenance script, nested reboot/shutdown jobs): a system
# mutex serializes the read-modify-write so concurrent writers never clobber the file.

$ServerMsgFile = "$PSScriptRoot\server_messages.jsonl"
$ServerMsgKeep = 50

function Add-ServerMessage {
    param([string]$Message, [string]$Kind = 'broadcast')
    if (-not $Message) { return }
    $mtx = New-Object System.Threading.Mutex($false, 'PalBoxServerMsg')
    $held = $false
    try {
        $held = $mtx.WaitOne(2000)
        # Millisecond unix id is the client's "have I seen this?" key; monotonic enough
        # that a banner is shown once. ts is a human/ISO stamp for display.
        $entry = [ordered]@{
            id      = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            ts      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            kind    = $Kind
            message = $Message
        }
        Add-Content -LiteralPath $ServerMsgFile -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
        $all = @(Get-Content -LiteralPath $ServerMsgFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($all.Count -gt $ServerMsgKeep) { $all[-$ServerMsgKeep..-1] | Set-Content -LiteralPath $ServerMsgFile -Encoding UTF8 }
    } catch {
    } finally {
        if ($held) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
    }
    # Mirror to the public R2 copy promptly (detached so it never blocks the caller; the
    # push script is single-flight + hash-gated so a burst won't spam R2).
    try {
        $push = "$PSScriptRoot\push_server_messages.ps1"
        if (Test-Path $push) {
            Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $push) `
                -WindowStyle Hidden
        }
    } catch {}
}

function Get-ServerMessages {
    param([int]$Limit = 50)
    if (-not (Test-Path $ServerMsgFile)) { return @() }
    $out = @()
    foreach ($line in @(Get-Content -LiteralPath $ServerMsgFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if (-not $line.Trim()) { continue }
        try { $out += (ConvertFrom-Json $line) } catch {}
    }
    if ($out.Count -gt $Limit) { $out = $out[-$Limit..-1] }
    return $out
}
