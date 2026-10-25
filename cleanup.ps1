$ErrorActionPreference = "SilentlyContinue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Stop-TidarrProcesses {
    # Only processes started from this folder: killing every node.exe would take
    # down unrelated applications.
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -in @("node.exe", "tsx.exe", "tiddl.exe", "rsgain.exe") -and
            $_.CommandLine -and $_.CommandLine.Contains($root)
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-Sleep -Milliseconds 800
}

Write-Host ""
Write-Host " Tidarr Cleanup"
Write-Host " ----------------------------------------"
Write-Host "  [1] Quick cleanup (default)"
Write-Host "      - config, Tidal token, queue, processing folders"
Write-Host "      - build output"
Write-Host "      - keeps node_modules and downloaded tools (faster next start)"
Write-Host ""
Write-Host "  [2] Full cleanup"
Write-Host "      - everything above plus node_modules and tools\rsgain"
Write-Host "      - dependencies are downloaded again on next start"
Write-Host " ----------------------------------------"
Write-Host ""

$choice = Read-Host "Choose [1/2] (default: 1)"
if ($choice -eq "") { $choice = "1" }
if ($choice -notin @("1", "2")) { Write-Host "Invalid choice."; exit 1 }
$full = $choice -eq "2"

Write-Host ""
Write-Host " Music is never touched. Everything else (including the Tidal token)"
Write-Host " will be removed, so you will have to authorize again."
$confirm = Read-Host "Continue? (y/N)"
if ($confirm -notmatch "^y") { Write-Host "Cancelled."; exit 0 }

Write-Host ""
Write-Host "[0] Stopping Tidarr processes..."
Stop-TidarrProcesses
Write-Host "    Done."

Write-Host "[1] Removing configuration, tokens, queue and processing folders..."
Remove-Item (Join-Path $root "userfiles\shared") -Recurse -Force
Remove-Item (Join-Path $root "userfiles\.processing") -Recurse -Force
Remove-Item (Join-Path $root "shared") -Recurse -Force
Write-Host "    Done."

Write-Host "[2] Removing build output..."
foreach ($path in @("api\dist", "app\dist", "app\build", "app\.vite")) {
    Remove-Item (Join-Path $root $path) -Recurse -Force
}
Write-Host "    Done."

if ($full) {
    Write-Host "[3] Removing node_modules and tools..."
    foreach ($path in @("node_modules", "api\node_modules", "app\node_modules", "tools")) {
        Remove-Item (Join-Path $root $path) -Recurse -Force
    }
    Write-Host "    Done."
} else {
    Write-Host "[3] Keeping node_modules and tools."
}

Write-Host ""
Write-Host " ----------------------------------------"
Write-Host " Cleanup complete."
Write-Host " Run start.cmd to launch (dependencies are reinstalled if removed)."
Write-Host " ----------------------------------------"
Write-Host ""
