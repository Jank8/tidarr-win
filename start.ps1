$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
# Always work from the project folder, no matter where the script was started.
Set-Location $root
try { $Host.UI.RawUI.WindowTitle = "Tidarr" } catch {}
# Parent cmd.exe (start.cmd) is closed on shutdown so it cannot ask about
# "Terminate batch job" after Ctrl+C.
$parentProcessId = 0
try {
    $parentProcessId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
} catch {}

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
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        # Skip the Microsoft Store alias stub: probing it raises a noisy error.
        if ($found -and $found.Source -notmatch 'WindowsApps') { $candidates.Add($found.Source) }
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

function Add-ToPath {
    # Make a tool folder visible now and in future sessions (the API spawns
    # binaries by name, so PATH is what matters).
    param([string]$Directory)
    if (-not $Directory) { return }
    $onPath = ($env:PATH -split ';') | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') }
    if (-not $onPath) { $env:PATH = "$Directory;$env:PATH" }

    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $persisted = ($userPath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') }
    if (-not $persisted) {
        [System.Environment]::SetEnvironmentVariable("PATH", "$Directory;$userPath", "User")
    }
}

function Get-Setting {
    # Reads a flag from the environment first, then from .env (like dotenv).
    param([string]$Key)
    $value = [System.Environment]::GetEnvironmentVariable($Key)
    if ($value) { return $value }
    $envFile = Join-Path $root ".env"
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") {
                return $Matches[1].Trim().Trim('"').Trim("'")
            }
        }
    }
    return ""
}

function Get-BeetsPackageSpec {
    # beets extras change between releases (e.g. advancedrewrite disappeared in
    # 2.x), so ask PyPI which ones this release actually provides.
    $wanted = @("fetchart", "lastgenre", "lastimport")
    try {
        $pypi = Invoke-RestMethod -Uri "https://pypi.org/pypi/beets/json" -TimeoutSec 8 -UseBasicParsing
        $available = @($pypi.info.provides_extra)
        if ($available.Count -gt 0) {
            $valid = $wanted | Where-Object { $available -contains $_ }
            if ($valid) { return "beets[$($valid -join ',')]" }
        }
    } catch {}
    return "beets"
}

function Install-Rsgain {
    # rsgain has no winget package: fetch the portable win64 build from GitHub.
    Write-Host "  Installing rsgain (REPLAY_GAIN)..."
    $destination = Join-Path $root "tools\rsgain"
    $zip = Join-Path $env:TEMP "rsgain-win64.zip"
    $extract = Join-Path $env:TEMP "rsgain-extract"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/complexlogic/rsgain/releases/latest" -TimeoutSec 20 -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -like "*win64.zip" } | Select-Object -First 1
        if (-not $asset) { throw "no win64 asset in $($release.tag_name)" }

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $extract -Force

        if (Test-Path $destination) { Remove-Item $destination -Recurse -Force }
        # Move-Item cannot create intermediate folders, so make tools/ first.
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        $inner = Get-ChildItem $extract -Directory | Select-Object -First 1
        if ($inner) {
            Move-Item $inner.FullName $destination
        } else {
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Move-Item (Join-Path $extract "*") $destination
        }

        if (-not (Test-Path (Join-Path $destination "rsgain.exe"))) {
            throw "rsgain.exe missing after extraction"
        }

        Add-ToPath $destination
        Write-Host "  rsgain $($release.tag_name) OK" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: rsgain install failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  REPLAY_GAIN will not work until rsgain.exe is on PATH." -ForegroundColor Yellow
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
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
    Add-ToPath $scriptsDir
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

# ── 3b. optional tools (installed only when their feature is enabled) ───────
if ((Get-Setting "ENABLE_BEETS") -eq "true") {
    Write-Host "  Checking beets (ENABLE_BEETS)..."
    if (Get-Command beet -ErrorAction SilentlyContinue) {
        Write-Host "  beets OK" -ForegroundColor Green
    } else {
        $beetsSpec = Get-BeetsPackageSpec
        Write-Host "  Installing $beetsSpec..."
        Invoke-Py $py.Command @("-m", "pip", "install", "--upgrade", "--no-warn-script-location", "--quiet", $beetsSpec)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Plugin install failed, trying plain beets..." -ForegroundColor Yellow
            Invoke-Py $py.Command @("-m", "pip", "install", "--upgrade", "--no-warn-script-location", "--quiet", "beets")
        }
        if ($LASTEXITCODE -eq 0 -and (Get-Command beet -ErrorAction SilentlyContinue)) {
            Write-Host "  beets OK" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: beets install failed. ENABLE_BEETS will not work." -ForegroundColor Yellow
            Write-Host "  Try: $scriptsDir\pip install beets" -ForegroundColor Yellow
        }
    }
}

if ((Get-Setting "REPLAY_GAIN") -eq "true") {
    Write-Host "  Checking rsgain (REPLAY_GAIN)..."
    if (Get-Command rsgain -ErrorAction SilentlyContinue) {
        Write-Host "  rsgain OK" -ForegroundColor Green
    } else {
        Install-Rsgain
    }
}

# .sh hooks need a POSIX shell. Git for Windows ships one but does not always
# put it on PATH, so make it available for this session when such a hook exists.
$shHooks = @("custom-script.sh", "custom-post-script.sh") |
    ForEach-Object { Join-Path $root "userfiles\shared\$_" } |
    Where-Object { Test-Path $_ }
if ($shHooks -and -not (Get-Command sh -ErrorAction SilentlyContinue)) {
    foreach ($gitBin in @("C:\Program Files\Git\bin", (Join-Path $env:LOCALAPPDATA "Programs\Git\bin"))) {
        if (Test-Path (Join-Path $gitBin "sh.exe")) {
            $env:PATH = "$gitBin;$env:PATH"
            Write-Host "  Git Bash found for .sh hooks" -ForegroundColor Green
            break
        }
    }
}

# ── 4. Node dependencies ─────────────────────────────────────────────────────
Write-Host "[4/4] Checking Node dependencies..."
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing pnpm..."
    $null = Run-Cmd "npm install -g pnpm@10"
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
    $null = Run-Cmd "npm install -g tsx"
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
Write-Host " API      : http://127.0.0.1:8484"
Write-Host "----------------------------------------"
Write-Host ""

# Ports must be free; a stale instance of this folder is stopped, anything
# else is reported instead of failing later with EADDRINUSE.
function Get-PortOwner {
    param([int]$Port)
    $connection = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $connection) { return $null }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)" -ErrorAction SilentlyContinue
    return @{
        Port        = $Port
        Id          = $connection.OwningProcess
        Name        = $process.Name
        CommandLine = $process.CommandLine
    }
}

function Test-ProcessFromThisFolder {
    # The API runs through a globally installed tsx, so the process command line
    # may not contain the project path; walk up the parent chain instead
    # (launcher -> cmd -> concurrently -> tsx -> node).
    param([int]$ProcessId)
    $current = $ProcessId
    for ($depth = 0; $depth -lt 10 -and $current; $depth++) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
        if (-not $process) { return $false }
        if ($process.CommandLine -and $process.CommandLine.Contains($root)) { return $true }
        $current = $process.ParentProcessId
    }
    return $false
}

foreach ($port in @(3000, 8484)) {
    $owner = Get-PortOwner -Port $port
    if (-not $owner) { continue }

    if (Test-ProcessFromThisFolder -ProcessId $owner.Id) {
        Write-Host "  Port $port held by a previous Tidarr instance (PID $($owner.Id)), stopping it..." -ForegroundColor Yellow
        Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue
        for ($wait = 0; $wait -lt 20; $wait++) {
            if (-not (Get-PortOwner -Port $port)) { break }
            Start-Sleep -Milliseconds 500
        }
        continue
    }

    Write-Host "  ERROR: port $port is already in use by $($owner.Name) (PID $($owner.Id))." -ForegroundColor Red
    Write-Host "  Close that program (or its console window) and run start.cmd again." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"; exit 1
}

# Open the browser only once the API answers, so the UI does not greet the user
# with "Tidarr API is not reachable" during startup. Poll the API directly: a
# request through Vite would log proxy errors while the API is still down.
Start-Job -ScriptBlock {
    param($api, $url)
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        try {
            $null = Invoke-WebRequest -Uri "$api/api/is-auth-active" -UseBasicParsing -TimeoutSec 2
            Start-Process $url
            return
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
} -ArgumentList "http://127.0.0.1:8484", "http://localhost:3000" | Out-Null

# ── Run + graceful stop ─────────────────────────────────────────────────────
# Ctrl+C should stop the whole tree (concurrently, tsx, vite) and free the
# ports instead of leaving orphaned node processes behind.
function Stop-DevTree {
    param([int]$ProcessId)
    if ($ProcessId) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }

    # 1. Everything started from this folder (cmd, concurrently, vite).
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $left = Get-CimInstance Win32_Process | Where-Object {
            $_.Name -in @("node.exe", "tsx.exe", "cmd.exe") -and
            $_.CommandLine -and $_.CommandLine.Contains($root)
        }
        if (-not $left) { break }
        $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
    }

    # 2. The API runs through a globally installed tsx, so its command line has
    #    no project path. Both ports were verified free before starting, so any
    #    listener now belongs to this run.
    foreach ($port in @(3000, 8484)) {
        $listeners = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
        foreach ($listener in $listeners) {
            $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
            if ($owner -and $owner.Name -eq "node.exe") {
                Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 3. tsx --watch would restart the API after its child dies; stop the watcher.
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "node.exe" -and
        $_.CommandLine -and
        $_.CommandLine.Contains("tsx") -and
        $_.CommandLine.Contains("index.ts")
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not (Get-NetTCPConnection -State Listen -LocalPort 3000, 8484 -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
}

# Keep the console readable.
# npm exports FORCE_COLOR for its scripts, so a NO_COLOR inherited from the
# terminal makes every node child print a warning about the conflict; and Vite 8
# warns about the CommonJS config loader unless this variable is set.
Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
$env:VITE_CONFIG_NATIVE_IGNORE_WARNING = "true"

Write-Host " Press Ctrl+C to stop Tidarr."

# Run the `dev` script from package.json without pnpm: pnpm runs it through a
# pnpm.cmd batch file, and cmd.exe answers Ctrl+C on batch files with
# "Terminate batch job (Y/N)?". The script itself starts plain node processes.
$devScript = $null
try {
    $devScript = (Get-Content (Join-Path $root "package.json") -Raw | ConvertFrom-Json).scripts.dev
} catch {}
if (-not $devScript) {
    Write-Host "  ERROR: cannot read scripts.dev from package.json." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}
$devProcess = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/d /s /c `"$devScript`"" `
    -WorkingDirectory $root -NoNewWindow -PassThru

# Swallow the first Ctrl+C so the shutdown can finish cleanly: kill the tree,
# then let Wait-Process return and the finally block confirm the ports.
$shutdownState = [hashtable]::Synchronized(@{
    Root   = $root
    Parent = $parentProcessId
    Stopping = $false
})
try {
    Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -MessageData $shutdownState -Action {
        $state = $Event.MessageData
        if ($state.Stopping) { return }
        $state.Stopping = $true
        $Event.SourceEventArgs.Cancel = $true
        Get-CimInstance Win32_Process | Where-Object {
            $_.Name -in @("node.exe", "tsx.exe", "cmd.exe") -and
            $_.CommandLine -and $_.CommandLine.Contains($state.Root)
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } | Out-Null
} catch {
    # No console attached (e.g. run from a service): rely on the finally block.
}

try {
    Wait-Process -Id $devProcess.Id -ErrorAction SilentlyContinue
} finally {
    Write-Host ""
    Write-Host " Stopping Tidarr..." -ForegroundColor Yellow
    Stop-DevTree -ProcessId $devProcess.Id

    $busy = Get-NetTCPConnection -State Listen -LocalPort 3000, 8484 -ErrorAction SilentlyContinue
    if ($busy) {
        $ports = ($busy | Select-Object -ExpandProperty LocalPort | Sort-Object -Unique) -join ", "
        Write-Host " WARNING: port(s) $ports are still in use." -ForegroundColor Yellow
        Write-Host " Run cleanup.cmd if the process does not exit on its own." -ForegroundColor Yellow
    } else {
        Write-Host " Tidarr stopped - ports 3000 and 8484 are free." -ForegroundColor Green
    }
    Write-Host ""

    # Keep the summary on screen. This must live in the finally block: after
    # Ctrl+C the script unwinds through it and would not reach code placed after
    # the try/finally.
    if (-not [Console]::IsInputRedirected) {
        Write-Host " Press Enter to close this window."
        Read-Host | Out-Null
    } else {
        Start-Sleep -Seconds 2
    }

    # Close the batch (when started through start.cmd) only now, so it cannot
    # print "Terminate batch job (Y/N)?" on top of the summary.
    if ($parentProcessId) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$parentProcessId" -ErrorAction SilentlyContinue
        if ($parent -and $parent.Name -eq "cmd.exe" -and $parent.CommandLine -and $parent.CommandLine -match "start\.cmd") {
            Stop-Process -Id $parent.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}
