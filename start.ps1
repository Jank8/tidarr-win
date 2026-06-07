$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Refresh-Path {
    $machine = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $user    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = "$machine;$user"
}

function Run-Npm {
    param([string]$npmArgs)
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c cd /d `"$root`" && npm $npmArgs" `
        -NoNewWindow -Wait -PassThru
    return $proc.ExitCode
}

Write-Host ""
Write-Host " _____ ___ ____    _    ____  ____"
Write-Host "|_   _|_ _|  _ \  / \  |  _ \|  _ \"
Write-Host "  | |  | || | | |/ _ \ | |_) | |_) |"
Write-Host "  | |  | || |_| / ___ \|  _ <|  _ <"
Write-Host "  |_| |___|____/_/   \_\_| \_\_| \_\"
Write-Host ""
Write-Host " Windows Launcher"
Write-Host "----------------------------------------"

# ── 1. Node.js ──────────────────────────────────────────────────────────────
Write-Host "[1/4] Checking Node.js..."
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing Node.js..."
    winget install OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Host "  ERROR: Node.js not found after install." -ForegroundColor Red
        Read-Host "Press Enter to exit"; exit 1
    }
}
Write-Host "  Node.js $(node -v) OK" -ForegroundColor Green

# ── 2. Python ───────────────────────────────────────────────────────────────
Write-Host "[2/4] Checking Python..."
$pythonOk = $false
try { $null = & python --version 2>&1; if ($LASTEXITCODE -eq 0) { $pythonOk = $true } } catch {}
if (-not $pythonOk) {
    Write-Host "  Installing Python..."
    winget install Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    try { $null = & python --version 2>&1; if ($LASTEXITCODE -eq 0) { $pythonOk = $true } } catch {}
    if (-not $pythonOk) {
        Write-Host "  ERROR: Python not found after install." -ForegroundColor Red
        Read-Host "Press Enter to exit"; exit 1
    }
}
Write-Host "  $(python --version) OK" -ForegroundColor Green

Write-Host "  Checking tiddl..."
if (-not (Get-Command tiddl -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing tiddl 3.4.3..."
    python -m pip install tiddl==3.4.3 --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: tiddl install failed." -ForegroundColor Red
        Read-Host "Press Enter to exit"; exit 1
    }
    Refresh-Path
}
Write-Host "  tiddl OK" -ForegroundColor Green

# ── 3. ffmpeg ────────────────────────────────────────────────────────────────
Write-Host "[3/4] Checking ffmpeg..."
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing ffmpeg..."
    winget install Gyan.FFmpeg --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
}
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Write-Host "  ffmpeg OK" -ForegroundColor Green
} else {
    Write-Host "  WARNING: ffmpeg not in PATH. Audio conversion may not work." -ForegroundColor Yellow
}

# ── 4. Node dependencies ─────────────────────────────────────────────────────
Write-Host "[4/4] Checking Node dependencies..."
$concurrently = Join-Path $root "node_modules\concurrently"
if (-not (Test-Path $concurrently)) {
    Write-Host "  Installing dependencies..."
    $exit = Run-Npm "install"
    if ($exit -ne 0) {
        Write-Host "  ERROR: npm install failed." -ForegroundColor Red
        Read-Host "Press Enter to exit"; exit 1
    }
} else {
    Write-Host "  node_modules OK" -ForegroundColor Green
}

# ── Start ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "----------------------------------------"
Write-Host " Starting Tidarr..."
Write-Host " Frontend : http://localhost:3000"
Write-Host " API      : http://localhost:8484"
Write-Host "----------------------------------------"
Write-Host ""

Run-Npm "run dev"
