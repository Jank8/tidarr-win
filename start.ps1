$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
# Always work from the project folder, no matter where the script was started.
Set-Location $root

function Refresh-Path {
    # Merge the registry PATH with the inherited one, so tools installed after
    # this shell was opened (or PATH entries added by an installer) are visible
    # without dropping anything the current session already has.
    $machine = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $user    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $entries = @($machine -split ';') + @($user -split ';') + @($env:PATH -split ';')
    $entries = $entries | Where-Object { $_ } | Select-Object -Unique
    $env:PATH = $entries -join ';'
}

function Run-Cmd {
    param([string]$cmdArgs)
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c cd /d `"$root`" && $cmdArgs" `
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
Refresh-Path
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

# ── 2. Python + tiddl ───────────────────────────────────────────────────────
# The launcher asks PyPI for the current tiddl release, reads the Python version
# it requires, resolves an interpreter that satisfies it (installing Python if
# needed) and installs/upgrades tiddl with that interpreter. When PyPI cannot be
# reached (offline start) it falls back to known-good versions.
Write-Host "[2/4] Checking Python..."

$FallbackTiddlVersion = "3.4.4"
$FallbackMinPython    = [version]"3.13"

function Invoke-Py {
    param([string[]]$Python, [string[]]$Arguments)
    $exe = $Python[0]
    $pre = @()
    if ($Python.Count -gt 1) { $pre = $Python[1..($Python.Count - 1)] }
    & $exe @pre @Arguments
}

function Get-PythonVersion {
    param([string]$Exe)
    try {
        $out = Invoke-Py @($Exe) @("-c", "import sys;print('%d.%d.%d' % sys.version_info[:3])") 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        return [version]("$out".Trim())
    } catch { return $null }
}

function Get-PythonCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    # Every interpreter registered with the py launcher.
    try {
        $lines = & py -0p 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $lines) {
                if ($line -match '-V:\d+\.\d+\s*\*?\s+(.+?)\s*$') {
                    $candidates.Add($Matches[1].Trim())
                }
            }
        }
    } catch {}

    foreach ($cmd in @("python", "python3")) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) { $candidates.Add($cmd) }
    }

    # Per-user installs that may not be on PATH yet.
    $pythonRoot = Join-Path $env:LOCALAPPDATA "Programs\Python"
    Get-ChildItem $pythonRoot -Directory -Filter "Python3*" -ErrorAction SilentlyContinue | ForEach-Object {
        $exe = Join-Path $_.FullName "python.exe"
        if (Test-Path $exe) { $candidates.Add($exe) }
    }

    return $candidates | Select-Object -Unique
}

function Find-CompatiblePython {
    param([version]$Minimum)
    $best = $null
    foreach ($exe in Get-PythonCandidates) {
        $version = Get-PythonVersion $exe
        if ($version -and $version -ge $Minimum) {
            if (-not $best -or $version -gt $best.Version) {
                $best = @{ Command = @($exe); Version = $version }
            }
        }
    }
    return $best
}

function Install-Python {
    param([version]$Version)
    $id = "Python.Python.$($Version.Major).$($Version.Minor)"
    Write-Host "  Installing Python $($Version.Major).$($Version.Minor)..."
    winget install $id --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
}

function Get-TiddlRelease {
    # Latest stable tiddl and the Python requirement it declares, from PyPI.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $pypi = Invoke-RestMethod -Uri "https://pypi.org/pypi/tiddl/json" -TimeoutSec 8 -UseBasicParsing
        if (-not $pypi.info.version) { return $null }
        $minimum = $null
        if ($pypi.info.requires_python -match '>=\s*(\d+)\.(\d+)') {
            $minimum = [version]"$($Matches[1]).$($Matches[2])"
        }
        return @{ Version = "$($pypi.info.version)"; MinPython = $minimum }
    } catch {
        return $null
    }
}

# ── which tiddl does the launcher target? ───────────────────────────────────
$release = Get-TiddlRelease
if ($env:TIDARR_TIDDL_VERSION) {
    $TiddlVersion = $env:TIDARR_TIDDL_VERSION
    $MinPython = if ($release -and $release.MinPython) { $release.MinPython } else { $FallbackMinPython }
    Write-Host "  tiddl $TiddlVersion requested via TIDARR_TIDDL_VERSION"
} elseif ($release) {
    $TiddlVersion = $release.Version
    $MinPython = if ($release.MinPython -and $release.MinPython -ge $FallbackMinPython) {
        $release.MinPython
    } else {
        $FallbackMinPython
    }
    Write-Host "  Latest tiddl: $TiddlVersion (Python $($MinPython.Major).$($MinPython.Minor)+)"
} else {
    $TiddlVersion = $FallbackTiddlVersion
    $MinPython = $FallbackMinPython
    Write-Host "  PyPI unreachable, using tiddl $TiddlVersion" -ForegroundColor Yellow
}

# ── interpreter that satisfies tiddl ────────────────────────────────────────
$py = Find-CompatiblePython -Minimum $MinPython
if (-not $py) {
    Install-Python -Version $MinPython
    $py = Find-CompatiblePython -Minimum $MinPython
    if (-not $py) {
        Write-Host "  ERROR: no Python $($MinPython.Major).$($MinPython.Minor)+ found after install." -ForegroundColor Red
        Write-Host "  Install it from https://www.python.org/downloads/ and run start.cmd again." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"; exit 1
    }
}
Write-Host "  Python $($py.Version) OK" -ForegroundColor Green

Write-Host "  Checking tiddl..."
$scriptsDir = ""
try {
    $scriptsDir = (Invoke-Py $py.Command @("-c", "import sysconfig;print(sysconfig.get_path('scripts'))") 2>$null | Out-String).Trim()
} catch {}
if (-not $scriptsDir -and $py.Command[0].Contains('\') -and (Test-Path $py.Command[0])) {
    $scriptsDir = Join-Path (Split-Path -Parent $py.Command[0]) "Scripts"
}

$tiddlInstalled = ""
try {
    $tiddlInstalled = (Invoke-Py $py.Command @("-c", "from importlib.metadata import version;print(version('tiddl'))") 2>$null | Out-String).Trim()
} catch {}

$needsTiddl = $true
if ($tiddlInstalled) {
    try {
        $current = [version]$tiddlInstalled
        $target = [version]$TiddlVersion
        if ($current -lt $target) {
            $needsTiddl = $true
        } else {
            $needsTiddl = $false
            if ($current -gt $target) {
                Write-Host "  tiddl $tiddlInstalled is newer than $TiddlVersion, keeping it"
                $TiddlVersion = $tiddlInstalled
            }
        }
    } catch { $needsTiddl = $true }
}

if ($needsTiddl) {
    if ($tiddlInstalled) {
        Write-Host "  Upgrading tiddl $tiddlInstalled -> $TiddlVersion..."
    } else {
        Write-Host "  Installing tiddl $TiddlVersion..."
    }
    Invoke-Py $py.Command @("-m", "pip", "install", "--upgrade", "--no-warn-script-location", "tiddl==$TiddlVersion", "--quiet")
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: tiddl $TiddlVersion install failed (Python $($py.Version))." -ForegroundColor Red
        Read-Host "Press Enter to exit"; exit 1
    }
    $tiddlInstalled = $TiddlVersion
}

# tiddl.exe lives in the interpreter's Scripts folder; make sure that exact
# executable wins on PATH (an old tiddl from a Python 3.12 install may still be
# registered) and that it stays reachable in future sessions, since the API
# spawns `tiddl` by name.
$expectedTiddl = if ($scriptsDir) { Join-Path $scriptsDir "tiddl.exe" } else { "" }
if ($expectedTiddl -and (Test-Path $expectedTiddl)) {
    $resolved = (Get-Command tiddl -ErrorAction SilentlyContinue).Source
    if (-not $resolved -or ($resolved -ine $expectedTiddl)) {
        $env:PATH = "$scriptsDir;$env:PATH"
    }

    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $persisted = ($userPath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $scriptsDir.TrimEnd('\') }
    if (-not $persisted) {
        [System.Environment]::SetEnvironmentVariable("PATH", "$scriptsDir;$userPath", "User")
    }
}

$isLatest = $release -and ($tiddlInstalled -eq $release.Version)
$latestNote = if ($isLatest) { " (latest)" } else { "" }
Write-Host "  tiddl $tiddlInstalled$latestNote OK ($scriptsDir\tiddl.exe)" -ForegroundColor Green

$tiddlOk = $false
if (Get-Command tiddl -ErrorAction SilentlyContinue) {
    $null = & tiddl --help 2>&1
    $tiddlOk = ($LASTEXITCODE -eq 0)
}
if (-not $tiddlOk) {
    Write-Host "  ERROR: tiddl is installed but not runnable from PATH." -ForegroundColor Red
    Write-Host "  Try opening a new terminal, or check that $scriptsDir is on PATH." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"; exit 1
}

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
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing pnpm..."
    Run-Cmd "npm install -g pnpm@10"
    Refresh-Path
    if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
        Write-Host "  ERROR: pnpm not found after install." -ForegroundColor Red
        Read-Host "Press Enter to exit"; exit 1
    }
}
Write-Host "  pnpm $(pnpm -v) OK" -ForegroundColor Green

# The API's start script runs `npx tsx`; upstream provides tsx globally in the
# Docker image, so without this npx would download it from npm on every launch.
if (-not (Get-Command tsx -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing tsx..."
    Run-Cmd "npm install -g tsx"
    Refresh-Path
}

$pnpmStore = Join-Path $root "node_modules\.pnpm"
if (-not (Test-Path $pnpmStore)) {
    Write-Host "  Installing dependencies (first run, may take a few minutes)..."
    $exit = Run-Cmd "pnpm install"
    if ($exit -ne 0) {
        Write-Host "  ERROR: pnpm install failed." -ForegroundColor Red
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

# Open browser before starting server - modern browsers will auto-reload
Start-Process "http://localhost:3000"

Run-Cmd "pnpm dev"
