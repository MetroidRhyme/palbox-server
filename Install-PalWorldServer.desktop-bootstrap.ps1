# Install-PalWorldServer.desktop-bootstrap.ps1
# ARCHIVED one-time machine bootstrap (the original script that first stood this box up).
# This is NOT the re-runnable updater -- for routine SteamCMD installs/game updates use
# the sanitized Install-PalWorldServer.ps1 in this folder. This copy is kept for reference
# because it also does the extra first-time machine setup that the updater does NOT:
#   - installs the DirectX End-User Runtime (d3dx9_43.dll)
#   - installs the Visual C++ 2022 x64 redistributable (required by UE5)
#   - creates the inbound Windows Firewall rules (UDP 8211 game, UDP 27015 Steam query)
#   - sets the active power plan to High Performance
# NOTE: unlike the rest of the repo, this archived script uses hardcoded paths
# (C:\SteamCMD, C:\PalWorldServer) rather than $PSScriptRoot -- kept as historical record.
#
# Original header:
# Install-PalWorldServer.ps1
# Downloads SteamCMD (if needed) and installs the PalWorld Dedicated Server

$SteamCmdDir = "C:\SteamCMD"
$SteamCmdExe = "$SteamCmdDir\steamcmd.exe"
$ServerInstallDir = "C:\PalWorldServer"

# --- Download SteamCMD if not already present ---
if (-not (Test-Path $SteamCmdExe)) {
    Write-Host "SteamCMD not found. Downloading..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $SteamCmdDir | Out-Null
    $ZipPath = "$SteamCmdDir\steamcmd.zip"
    Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $ZipPath
    Expand-Archive -Path $ZipPath -DestinationPath $SteamCmdDir -Force
    Remove-Item $ZipPath
    Write-Host "SteamCMD downloaded to $SteamCmdDir" -ForegroundColor Green
} else {
    Write-Host "SteamCMD already present at $SteamCmdExe" -ForegroundColor Green
}

# --- Install DirectX End-User Runtime ---
# Check for d3dx9_43.dll -- the key DLL installed by the June 2010 redist
if (Test-Path "$env:SystemRoot\System32\d3dx9_43.dll") {
    Write-Host "DirectX Runtime already installed." -ForegroundColor Green
} else {
    Write-Host "Installing DirectX Runtime..." -ForegroundColor Cyan
    $DxSetup = "$env:TEMP\directx_Jun2010_redist.exe"
    Invoke-WebRequest -Uri "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe" -OutFile $DxSetup
    $DxExtractDir = "$env:TEMP\DirectXRedist"
    New-Item -ItemType Directory -Force -Path $DxExtractDir | Out-Null
    Start-Process -FilePath $DxSetup -ArgumentList "/Q /T:`"$DxExtractDir`"" -Wait
    Start-Process -FilePath "$DxExtractDir\DXSETUP.exe" -ArgumentList "/silent" -Wait
    Write-Host "DirectX Runtime installed." -ForegroundColor Green
}

# --- Create server install directory ---
New-Item -ItemType Directory -Force -Path $ServerInstallDir | Out-Null

# --- Install / update PalWorld Dedicated Server (App ID 2394010) ---
Write-Host "`nInstalling PalWorld Dedicated Server to $ServerInstallDir ..." -ForegroundColor Cyan
Write-Host "This may take several minutes.`n"

& $SteamCmdExe `
    +force_install_dir $ServerInstallDir `
    +login anonymous `
    +app_update 2394010 validate `
    +quit

# --- Visual C++ 2022 Redistributable (required by Unreal Engine 5) ---
Write-Host "`nInstalling Visual C++ 2022 Redistributable..." -ForegroundColor Cyan
$VcInstalled = Get-Package -Name "Microsoft Visual C++ 2022*" -ErrorAction SilentlyContinue
if ($VcInstalled) {
    Write-Host "Visual C++ 2022 already installed." -ForegroundColor Green
} else {
    $VcUrl  = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    $VcExe  = "$env:TEMP\vc_redist.x64.exe"
    Invoke-WebRequest -Uri $VcUrl -OutFile $VcExe
    Start-Process -FilePath $VcExe -ArgumentList "/install /quiet /norestart" -Wait
    Write-Host "Visual C++ 2022 installed." -ForegroundColor Green
}

# --- Windows Firewall rules ---
Write-Host "`nConfiguring Windows Firewall..." -ForegroundColor Cyan

$FirewallRules = @(
    @{ Name = "PalWorld Server - Game (UDP 8211)";  Port = 8211;  Proto = "UDP" },
    @{ Name = "PalWorld Server - Steam Query (UDP 27015)"; Port = 27015; Proto = "UDP" }
)

foreach ($rule in $FirewallRules) {
    if (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue) {
        Write-Host "  Rule already exists: $($rule.Name)" -ForegroundColor Green
    } else {
        New-NetFirewallRule `
            -DisplayName $rule.Name `
            -Direction   Inbound `
            -Protocol    $rule.Proto `
            -LocalPort   $rule.Port `
            -Action      Allow | Out-Null
        Write-Host "  Created rule: $($rule.Name)" -ForegroundColor Green
    }
}

# --- Set power plan to High Performance ---
$ActivePlan = powercfg /getactivescheme
if ($ActivePlan -match "High performance") {
    Write-Host "`nPower plan already set to High Performance." -ForegroundColor Green
} else {
    Write-Host "`nSetting power plan to High Performance..." -ForegroundColor Cyan
    $HighPerf = powercfg /list | Select-String "High performance"
    if ($HighPerf) {
        $Guid = ($HighPerf -split '\s+')[3]
        powercfg /setactive $Guid
        Write-Host "Power plan set to High Performance." -ForegroundColor Green
    } else {
        Write-Host "High Performance plan not found; skipping." -ForegroundColor Yellow
    }
}

Write-Host "`nDone! PalWorld Dedicated Server installed at:" -ForegroundColor Green
Write-Host "  $ServerInstallDir" -ForegroundColor Yellow
Write-Host "`nRun PalServer.exe inside that folder to start your server."
