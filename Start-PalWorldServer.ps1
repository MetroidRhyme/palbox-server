# Start-PalWorldServer.ps1
# Launches the PalWorld Dedicated Server as a public community server (required for PS5/Xbox)

$ServerDir = $PSScriptRoot
$ServerExe = "$ServerDir\PalServer.exe"

if (-not (Test-Path $ServerExe)) {
    Write-Host "PalServer.exe not found at $ServerExe" -ForegroundColor Red
    Write-Host "Run Install-PalWorldServer.ps1 first." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Starting PalWorld Dedicated Server..." -ForegroundColor Cyan
Write-Host "  Community server (PS5/Xbox visible): ON" -ForegroundColor Green
Write-Host "  Port: 8211"
Write-Host ""
Write-Host "Keep this window open while the server is running." -ForegroundColor Yellow
Write-Host "Close it to shut down the server." -ForegroundColor Yellow
Write-Host ""

& $ServerExe -publiclobby -port=8211 -players=4 -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS
