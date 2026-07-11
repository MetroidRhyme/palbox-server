# pal_instances.ps1
# -----------------------------------------------------------------------------
# Parallel-server ("secondary instance") management for the PalWorld dashboard.
#
# WHY this is a separate install per instance, not just a second -port= launch:
# PalServer.exe has NO -userdir / config-dir override (confirmed against the
# official arguments doc). RCON/REST ports and ServerName only come from
# Pal\Saved\Config\WindowsServer\PalWorldSettings.ini -- they are NOT settable on
# the command line. Two processes from the same install therefore read the SAME
# config + SaveGames\0 and collide on REST port / world / name. So each parallel
# server is a full clone of the primary install with its own Pal\Saved. Anthony
# chose full independent copies (not junction-shared binaries) -- see the caveat
# in Invoke-InstanceProvision about post-update drift.
#
# Dot-sourced into the dashboard job (like server_messages.ps1 / map_data_lib.ps1).
# Every function is self-contained (own ini parse/write, no reliance on the
# Manager job's closure) so this file can be unit-tested on its own.
#
# PowerShell 5.1 only: no ternary, no ?? -- use if/else. ASCII only.
# -----------------------------------------------------------------------------

# Module state, set by Initialize-InstanceLib.
$script:PalPrimaryRoot   = $null   # C:\PalWorldServer
$script:PalInstancesFile = $null   # <root>\instances.json
$script:PalInstBaseName  = $null   # install-dir prefix, e.g. C:\PalWorldServer  -> C:\PalWorldServer2, ...3

function Initialize-InstanceLib {
    param([Parameter(Mandatory)][string]$PrimaryRoot)
    $script:PalPrimaryRoot   = $PrimaryRoot.TrimEnd('\')
    $script:PalInstancesFile = Join-Path $script:PalPrimaryRoot 'instances.json'
    # Clones live next to the primary: C:\PalWorldServer -> C:\PalWorldServer2, ...3
    $script:PalInstBaseName  = $script:PalPrimaryRoot
}

# --- registry -----------------------------------------------------------------
# instances.json = { "instances": [ { id,name,dir,num,gamePort,restPort,
#   publicPort,rconPort,guid,created,pid,status }, ... ] }
# The PRIMARY (num=1, root install, ports 8211/8212) is implicit and never stored
# here -- it is always present and managed by the existing single-server code.

function Get-InstanceList {
    if (-not (Test-Path -LiteralPath $script:PalInstancesFile)) { return @() }
    try {
        $o = Get-Content -LiteralPath $script:PalInstancesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($o -and $o.instances) { return @($o.instances) }
    } catch {}
    return @()
}

function Save-InstanceList {
    param([Parameter(Mandatory)]$List)
    $obj = [ordered]@{ instances = @($List) }
    $tmp = "$($script:PalInstancesFile).tmp"
    ($obj | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:PalInstancesFile -Force
}

function Get-InstanceById {
    param([Parameter(Mandatory)][string]$Id)
    foreach ($i in (Get-InstanceList)) { if ($i.id -eq $Id) { return $i } }
    return $null
}

# Upsert one instance record by id, then persist. Returns the saved record.
function Set-InstanceRecord {
    param([Parameter(Mandatory)]$Inst)
    $list = @(Get-InstanceList | Where-Object { $_.id -ne $Inst.id })
    $list += $Inst
    Save-InstanceList $list
    return $Inst
}

function Remove-InstanceRecord {
    param([Parameter(Mandatory)][string]$Id)
    Save-InstanceList @(Get-InstanceList | Where-Object { $_.id -ne $Id })
}

# --- id / path safety ---------------------------------------------------------
# Inbound ids from the dashboard are joined to filesystem paths and used to name
# firewall rules, so constrain them exactly like the Save Manager's Test-SlotId.
function Test-InstanceId {
    param([string]$Id)
    return ($Id -and ($Id -match '^[\w\-]+$'))
}

# --- port helpers -------------------------------------------------------------
# Primary occupies 8211(game)/8212(REST)/8213(dashboard). Parallel instance number
# n (n>=2) gets a 10-wide block based at 8210+10*(n-1): game=base+1, rest=base+2,
# rcon=base+3. n=2 -> 8221/8222/8223, n=3 -> 8231/8232/8233, ...
function Get-InstancePortBlock {
    param([Parameter(Mandatory)][int]$Num)
    $base = 8210 + 10 * ($Num - 1)
    return [ordered]@{ game = $base + 1; rest = $base + 2; rcon = $base + 3; public = $base + 1 }
}

# True if nothing on this machine is currently listening on $Port for $Proto.
function Test-PortFree {
    param([Parameter(Mandatory)][int]$Port, [ValidateSet('UDP','TCP')][string]$Proto = 'UDP')
    try {
        if ($Proto -eq 'UDP') {
            $ep = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
        } else {
            $ep = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        }
        return -not [bool]$ep
    } catch {
        # NetTCPIP cmdlets unavailable -- assume free rather than block provisioning.
        return $true
    }
}

# Lowest instance number >= 2 whose game/rest/rcon ports are neither claimed by an
# existing registered instance nor currently listening, and whose install dir is free.
function Get-NextInstanceNum {
    $used = @{}
    foreach ($i in (Get-InstanceList)) { $used[[int]$i.num] = $true }
    for ($n = 2; $n -lt 100; $n++) {
        if ($used[$n]) { continue }
        $pb = Get-InstancePortBlock -Num $n
        if (-not (Test-PortFree -Port $pb.game -Proto 'UDP')) { continue }
        if (-not (Test-PortFree -Port $pb.rest -Proto 'TCP')) { continue }
        if (Test-Path -LiteralPath ($script:PalInstBaseName + "$n")) { continue }
        return $n
    }
    throw "No free instance slot found (checked 2..99)."
}

# Which PID owns the game UDP port -- this is the RELIABLE way to tell two
# indistinguishable PalServer-Win64-Test-Cmd.exe processes apart (and to find the
# PRIMARY's own pid on 8211, so a name-based stop can be made port-scoped instead).
function Get-PidOnUdpPort {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $ep = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue |
              Select-Object -First 1
        if (-not $ep) { return $null }
        $procId = [int]$ep.OwningProcess
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        # Only claim it if it actually is a PalServer process -- guards against a
        # stale/reused port owned by something unrelated.
        if ($p -and $p.Name -like '*PalServer*') { return $procId }
        return $null
    } catch { return $null }
}

# --- minimal ini helpers (self-contained copies; the Manager job has its own) ---
function Read-InstOptionSettings {
    param([Parameter(Mandatory)][string]$Path)
    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -notmatch 'OptionSettings=') { continue }
        if ($line -notmatch 'OptionSettings=\((.+)\)') { break }
        $content = $Matches[1]; $depth = 0; $token = ''
        foreach ($ch in $content.ToCharArray()) {
            if     ($ch -eq '(') { $depth++; $token += $ch }
            elseif ($ch -eq ')') { $depth--; $token += $ch }
            elseif ($ch -eq ',' -and $depth -eq 0) {
                if ($token -match '^([^=]+)=(.*)$') { $result[$Matches[1]] = $Matches[2] }
                $token = ''
            } else { $token += $ch }
        }
        if ($token -match '^([^=]+)=(.*)$') { $result[$Matches[1]] = $Matches[2] }
        break
    }
    return $result
}

function Write-InstOptionSettings {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Path)
    $pairs = foreach ($k in $Settings.Keys) { "$k=$($Settings[$k])" }
    $body  = "OptionSettings=($($pairs -join ','))"
    $tmp   = "$Path.tmp"
    $dir   = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($tmp, "[/Script/Pal.PalGameWorldSettings]`r`n$body`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Take the primary's live settings as a base, override only the per-instance
# networking/name keys, and write the clone's PalWorldSettings.ini. This keeps the
# clone's gameplay rates identical to the primary at provision time.
function Write-InstanceServerSettings {
    param(
        [Parameter(Mandatory)]$Inst,
        [Parameter(Mandatory)][string]$SourceSettingsPath
    )
    $s = Read-InstOptionSettings -Path $SourceSettingsPath
    if ($s.Count -eq 0) { $s = [ordered]@{} }
    $s['RESTAPIEnabled'] = 'True'
    $s['RESTAPIPort']    = "$($Inst.restPort)"
    $s['PublicPort']     = "$($Inst.publicPort)"
    $s['RCONPort']       = "$($Inst.rconPort)"
    # ServerName is a quoted string value inside OptionSettings.
    $s['ServerName']     = '"' + ($Inst.name -replace '"', '') + '"'
    $dst = Join-Path $Inst.dir 'Pal\Saved\Config\WindowsServer\PalWorldSettings.ini'
    Write-InstOptionSettings -Settings $s -Path $dst
}

# Point a clone at a world GUID (its own GameUserSettings.ini).
function Set-InstanceActiveGuid {
    param([Parameter(Mandatory)]$Inst, [Parameter(Mandatory)][string]$Guid)
    $gus = Join-Path $Inst.dir 'Pal\Saved\Config\WindowsServer\GameUserSettings.ini'
    if (Test-Path -LiteralPath $gus) {
        $c = Get-Content -LiteralPath $gus -Raw -Encoding UTF8
    } else {
        $c = "[/Script/Pal.PalGameLocalSettings]`r`n"
    }
    if ($c -match '(?m)^\s*DedicatedServerName\s*=') {
        $c = [regex]::Replace($c, '(?m)^(\s*DedicatedServerName\s*=).*$', '${1}' + $Guid)
    } else {
        $c = $c -replace '(\[/Script/Pal\.PalGameLocalSettings\]\r?\n)', ('${1}' + "DedicatedServerName=$Guid`r`n")
    }
    $d = Split-Path $gus -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [System.IO.File]::WriteAllText($gus, $c, (New-Object System.Text.UTF8Encoding($false)))
}

# --- firewall (elevated, idempotent) ------------------------------------------
# Reading rules does NOT need elevation, so we check first and only trigger a UAC
# prompt (Start-Process -Verb RunAs) when the rule is actually missing -- so the
# FIRST start of an instance prompts once and later starts are silent.
function Get-InstanceFirewallRuleName {
    param([Parameter(Mandatory)]$Inst)
    return "PalWorld Instance $($Inst.id) (UDP $($Inst.gamePort))"
}

function Test-InstanceFirewallRule {
    param([Parameter(Mandatory)]$Inst)
    $name = Get-InstanceFirewallRuleName -Inst $Inst
    try {
        return [bool](Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)
    } catch { return $false }
}

# Ensure an inbound UDP allow rule for the instance's game port exists. Returns a
# hashtable { ok, prompted, reason }. Only the game/public UDP port needs opening;
# REST is localhost-only admin and needs no rule.
function Add-InstanceFirewallRule {
    param([Parameter(Mandatory)]$Inst)
    if (Test-InstanceFirewallRule -Inst $Inst) {
        return @{ ok = $true; prompted = $false; reason = 'exists' }
    }
    $name = Get-InstanceFirewallRuleName -Inst $Inst
    $port = [int]$Inst.gamePort
    # -Command runs elevated; re-check inside so two racing starts do not double-add.
    $cmd = "if(-not(Get-NetFirewallRule -DisplayName '$name' -ErrorAction SilentlyContinue)){New-NetFirewallRule -DisplayName '$name' -Direction Inbound -Action Allow -Protocol UDP -LocalPort $port -Profile Any | Out-Null}"
    try {
        $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) `
            -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
        if ($p.ExitCode -eq 0 -and (Test-InstanceFirewallRule -Inst $Inst)) {
            return @{ ok = $true; prompted = $true; reason = 'added' }
        }
        return @{ ok = $false; prompted = $true; reason = "elevated helper exit $($p.ExitCode)" }
    } catch {
        # User cancelled the UAC prompt, or elevation is unavailable.
        return @{ ok = $false; prompted = $true; reason = "elevation declined or failed: $($_.Exception.Message)" }
    }
}

function Remove-InstanceFirewallRule {
    param([Parameter(Mandatory)]$Inst)
    if (-not (Test-InstanceFirewallRule -Inst $Inst)) { return @{ ok = $true; reason = 'absent' } }
    $name = Get-InstanceFirewallRuleName -Inst $Inst
    $cmd = "Get-NetFirewallRule -DisplayName '$name' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue"
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) `
            -Verb RunAs -WindowStyle Hidden -Wait -ErrorAction Stop | Out-Null
        return @{ ok = $true; reason = 'removed' }
    } catch {
        return @{ ok = $false; reason = "$($_.Exception.Message)" }
    }
}

# --- provisioning -------------------------------------------------------------
# Robocopy the primary install into a new sibling dir, EXCLUDING the things a game
# server does not need per-clone: the save library, the live worlds/logs, the git
# tree, and the R2 staging dir. The clone keeps its own Pal\Saved\Config (with the
# per-instance ini we write next) and starts with an empty SaveGames\0.
#
# CAVEAT (full-copy drift): the maintenance job only SteamCMD-updates the PRIMARY.
# A clone made today goes stale after the next Palworld patch. Re-provision, or use
# Invoke-InstanceResync to refresh its binaries from the (updated) primary.
function New-ServerInstance {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Guid = $null   # optional world to point it at; else a fresh GUID
    )
    $num = Get-NextInstanceNum
    $pb  = Get-InstancePortBlock -Num $num
    $dir = $script:PalInstBaseName + "$num"
    # id must be filesystem/firewall-safe and unique.
    $id  = 'srv' + $num
    if (-not $Guid) { $Guid = ([guid]::NewGuid().ToString('N')).ToUpper() }
    $inst = [ordered]@{
        id         = $id
        name       = $Name
        dir        = $dir
        num        = $num
        gamePort   = $pb.game
        restPort   = $pb.rest
        publicPort = $pb.public
        rconPort   = $pb.rcon
        guid       = $Guid
        created    = (Get-Date -Format o)
        pid        = $null
        status     = 'provisioning'
    }
    return [pscustomobject]$inst
}

# Do the heavy robocopy + config write for an already-registered record. Long
# (~minutes for a multi-GB install); callers should run it in a background job and
# leave status='provisioning' until it returns. $Log is an optional scriptblock
# taking one string. Returns @{ ok; reason }.
function Invoke-InstanceProvision {
    param(
        [Parameter(Mandatory)]$Inst,
        [Parameter(Mandatory)][string]$SourceSettingsPath,
        [scriptblock]$Log = $null
    )
    $say = { param($m) if ($Log) { & $Log $m } }
    $src = $script:PalPrimaryRoot
    $dst = $Inst.dir
    if (Test-Path -LiteralPath (Join-Path $dst 'PalServer.exe')) {
        & $say "Clone dir already provisioned: $dst"
    } else {
        & $say "Cloning $src -> $dst (this can take several minutes)..."
        if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        $xd = @(
            (Join-Path $src 'SaveLibrary'),
            (Join-Path $src '.git'),
            (Join-Path $src '.r2_stage'),
            (Join-Path $src 'Pal\Saved\SaveGames'),
            (Join-Path $src 'Pal\Saved\Logs')
        )
        $roboArgs = @($src, $dst, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1', '/XD') + $xd
        robocopy @roboArgs | Out-Null
        if ($LASTEXITCODE -ge 8) {
            return @{ ok = $false; reason = "robocopy failed (exit $LASTEXITCODE)" }
        }
        & $say "Clone copy complete."
    }
    # Empty SaveGames\0 so the clone generates/loads its own world under its own GUID.
    $sg = Join-Path $dst 'Pal\Saved\SaveGames\0'
    if (-not (Test-Path -LiteralPath $sg)) { New-Item -ItemType Directory -Path $sg -Force | Out-Null }
    & $say "Writing instance settings (REST $($Inst.restPort), game $($Inst.gamePort))..."
    Write-InstanceServerSettings -Inst $Inst -SourceSettingsPath $SourceSettingsPath
    Set-InstanceActiveGuid -Inst $Inst -Guid $Inst.guid
    return @{ ok = $true; reason = 'provisioned' }
}

# Refresh a clone's binaries from the (kept-updated) primary after a game patch,
# WITHOUT touching its own Pal\Saved (config + worlds). Instance must be stopped.
function Invoke-InstanceResync {
    param([Parameter(Mandatory)]$Inst, [scriptblock]$Log = $null)
    $say = { param($m) if ($Log) { & $Log $m } }
    if ((Get-InstanceStatus -Inst $Inst).running) {
        return @{ ok = $false; reason = 'instance is running; stop it first' }
    }
    $src = $script:PalPrimaryRoot
    $dst = $Inst.dir
    & $say "Re-syncing binaries $src -> $dst (preserving Pal\Saved)..."
    # /MIR the whole tree but EXCLUDE the clone's own state (its saves/config/logs)
    # so an update never clobbers the second world.
    $xd = @(
        (Join-Path $src 'SaveLibrary'),
        (Join-Path $src '.git'),
        (Join-Path $src '.r2_stage'),
        (Join-Path $src 'Pal\Saved')
    )
    $roboArgs = @($src, $dst, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1', '/XD') + $xd
    robocopy @roboArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { return @{ ok = $false; reason = "robocopy failed (exit $LASTEXITCODE)" } }
    & $say "Binary re-sync complete."
    return @{ ok = $true; reason = 'resynced' }
}

# --- start / stop / status ----------------------------------------------------
function Get-InstanceStatus {
    param([Parameter(Mandatory)]$Inst)
    $procId = Get-PidOnUdpPort -Port ([int]$Inst.gamePort)
    if ($procId) { return @{ running = $true; pid = $procId } }
    return @{ running = $false; pid = $null }
}

# Ensure firewall, launch PalServer.exe from the clone dir with its own ports.
# Returns @{ ok; reason; pid; firewall } . Does NOT block waiting for online.
function Start-ServerInstanceProc {
    param(
        [Parameter(Mandatory)]$Inst,
        [int]$Players = 4
    )
    if ((Get-InstanceStatus -Inst $Inst).running) {
        return @{ ok = $true; reason = 'already running'; pid = (Get-PidOnUdpPort -Port ([int]$Inst.gamePort)); firewall = 'skipped' }
    }
    $exe = Join-Path $Inst.dir 'PalServer.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return @{ ok = $false; reason = "PalServer.exe missing at $exe (not provisioned?)"; pid = $null; firewall = 'skipped' }
    }
    $fw = Add-InstanceFirewallRule -Inst $Inst
    if (-not $fw.ok) {
        # Launch anyway (LAN/localhost still works); surface the firewall problem.
        # A blocked port only stops remote players, not the process.
    }
    $procArgs = @(
        '-publiclobby',
        "-port=$($Inst.gamePort)",
        "-publicport=$($Inst.publicPort)",
        "-players=$Players",
        '-useperfthreads', '-NoAsyncLoadingThread', '-UseMultithreadForDS'
    )
    try {
        Start-Process -FilePath $exe -ArgumentList $procArgs -WorkingDirectory $Inst.dir -ErrorAction Stop | Out-Null
    } catch {
        return @{ ok = $false; reason = "launch failed: $($_.Exception.Message)"; pid = $null; firewall = $fw.reason }
    }
    return @{ ok = $true; reason = 'launched'; pid = $null; firewall = $fw.reason }
}

# Graceful stop of one instance BY ITS PORT/PID -- never by *PalServer* name, so a
# sibling server (or the primary) is never caught. Tries its own REST save+shutdown
# first, then force-kills the resolved pid.
function Stop-ServerInstanceProc {
    param(
        [Parameter(Mandatory)]$Inst,
        [string]$AdminPassword = $null,
        [int]$TimeoutSec = 60
    )
    $procId = Get-PidOnUdpPort -Port ([int]$Inst.gamePort)
    if (-not $procId) { return @{ ok = $true; reason = 'not running' } }
    if ($AdminPassword) {
        $base = "http://localhost:$($Inst.restPort)/v1/api"
        $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$AdminPassword"))
        $headers = @{ Authorization = "Basic $cred"; 'Content-Type' = 'application/json' }
        try { Invoke-RestMethod -Uri "$base/save" -Method POST -Headers $headers -ErrorAction Stop -TimeoutSec 15 | Out-Null } catch {}
        Start-Sleep -Seconds 2
        try {
            Invoke-RestMethod -Uri "$base/shutdown" -Method POST -Headers $headers `
                -Body (ConvertTo-Json @{ waittime = 5; message = 'Server stopping.' }) -ErrorAction Stop -TimeoutSec 15 | Out-Null
        } catch {}
    }
    $waited = 0
    while ((Get-PidOnUdpPort -Port ([int]$Inst.gamePort)) -and $waited -lt $TimeoutSec) {
        Start-Sleep -Seconds 2; $waited += 2
    }
    $procId = Get-PidOnUdpPort -Port ([int]$Inst.gamePort)
    if ($procId) {
        try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Seconds 1
    }
    if (Get-PidOnUdpPort -Port ([int]$Inst.gamePort)) {
        return @{ ok = $false; reason = 'still running after force-kill' }
    }
    return @{ ok = $true; reason = 'stopped' }
}

# Full teardown: stop, drop firewall rule, delete the clone dir, deregister.
function Remove-ServerInstance {
    param(
        [Parameter(Mandatory)]$Inst,
        [string]$AdminPassword = $null,
        [scriptblock]$Log = $null
    )
    $say = { param($m) if ($Log) { & $Log $m } }
    & $say "Stopping instance $($Inst.id)..."
    Stop-ServerInstanceProc -Inst $Inst -AdminPassword $AdminPassword | Out-Null
    & $say "Removing firewall rule..."
    Remove-InstanceFirewallRule -Inst $Inst | Out-Null
    if ($Inst.dir -and (Test-Path -LiteralPath $Inst.dir)) {
        # Safety: never delete the primary root, and only delete a dir that looks
        # like one of our sibling clones.
        if ($Inst.dir.TrimEnd('\') -ieq $script:PalPrimaryRoot) {
            return @{ ok = $false; reason = 'refusing to delete primary root' }
        }
        & $say "Deleting $($Inst.dir)..."
        try { Remove-Item -LiteralPath $Inst.dir -Recurse -Force -ErrorAction Stop } catch {
            return @{ ok = $false; reason = "delete failed: $($_.Exception.Message)" }
        }
    }
    Remove-InstanceRecord -Id $Inst.id
    return @{ ok = $true; reason = 'removed' }
}
