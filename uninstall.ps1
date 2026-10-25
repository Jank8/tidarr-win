param([switch]$Uninstall, [switch]$Force)

$ErrorActionPreference = "SilentlyContinue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

function Update-ProcessPath {
    # A freshly spawned shell may not see PATH entries added by the launcher.
    $machine = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $user = [Environment]::GetEnvironmentVariable("PATH", "User")
    $entries = @($machine -split ';') + @($user -split ';') + @($env:PATH -split ';')
    $env:PATH = ($entries | Where-Object { $_ } | Select-Object -Unique) -join ';'
}
Update-ProcessPath

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

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

function Get-PythonInstallations {
    $installations = @()
    $seen = @{}

    try {
        $lines = & py -0p 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $lines) {
                if ($line -match "-V:(\d+\.\d+)\s*\*?\s+(.+?)\s*$") {
                    $path = $Matches[2].Trim()
                    $key = $path.ToLower()
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        $installations += @{ Version = $Matches[1]; Path = $path }
                    }
                }
            }
        }
    } catch {}

    if ($installations.Count -eq 0) {
        foreach ($command in @("python", "python3")) {
            $found = Get-Command $command -ErrorAction SilentlyContinue
            if (-not $found) { continue }
            $key = $found.Source.ToLower()
            if ($seen.ContainsKey($key)) { continue }
            $version = (& $found.Source -c "import sys;print('%d.%d' % sys.version_info[:2])" 2>$null) -join ""
            if ($version) {
                $seen[$key] = $true
                $installations += @{ Version = $version.Trim(); Path = $found.Source }
            }
        }
    }

    return $installations
}

function Show-Dependencies {
    Write-Host ""
    Write-Host " ----------------------------------------"
    Write-Host " Installed dependencies"
    Write-Host " ----------------------------------------"

    function Show-Command {
        param([string]$Label, [string]$Command, [string[]]$Arguments)
        $found = Get-Command $Command -ErrorAction SilentlyContinue
        if (-not $found) {
            Write-Host ("  {0,-10} NOT FOUND" -f $Label)
            return
        }
        $value = (& $found.Source @Arguments 2>&1 | Select-Object -First 1) -join ""
        Write-Host ("  {0,-10} {1}" -f $Label, $value.Trim())
    }

    Show-Command -Label "node" -Command "node" -Arguments @("-v")
    Show-Command -Label "npm" -Command "npm" -Arguments @("-v")
    Show-Command -Label "pnpm" -Command "pnpm" -Arguments @("-v")
    Show-Command -Label "tsx" -Command "tsx" -Arguments @("--version")
    Show-Command -Label "ffmpeg" -Command "ffmpeg" -Arguments @("-version")
    Show-Command -Label "beet" -Command "beet" -Arguments @("--version")
    Show-Command -Label "rsgain" -Command "rsgain" -Arguments @("--version")
    Show-Command -Label "git" -Command "git" -Arguments @("--version")

    $pythons = Get-PythonInstallations
    if ($pythons.Count -eq 0) {
        Write-Host "  python     NOT FOUND"
    } else {
        foreach ($python in $pythons) {
            $version = (& $python.Path -c "import sys;print('%d.%d.%d' % sys.version_info[:3])" 2>$null) -join ""
            Write-Host ("  python     {0} ({1})" -f $version.Trim(), $python.Path)
        }
    }

    $tiddl = $null
    if ($pythons.Count -gt 0) {
        $tiddl = & $pythons[0].Path -m pip show tiddl 2>$null |
            Select-String "^Version:" |
            ForEach-Object { $_.Line -replace "Version:\s*", "" }
    }
    Write-Host ("  tiddl      {0}" -f $(if ($tiddl) { $tiddl } else { "NOT INSTALLED" }))
    Write-Host ""
}

function Remove-FromPath([string]$Entry) {
    if (-not $Entry) { return }
    foreach ($scope in @("User", "Machine")) {
        $current = [Environment]::GetEnvironmentVariable("PATH", $scope)
        if (-not $current) { continue }
        $kept = ($current -split ";" | Where-Object { $_ -and ($_.TrimEnd("\") -ine $Entry.TrimEnd("\")) }) -join ";"
        if ($kept -ne $current) {
            [Environment]::SetEnvironmentVariable("PATH", $kept, $scope)
        }
    }
}

function Invoke-Uninstall {
    Write-Host " Tidarr - Uninstall dependencies"
    Write-Host " ----------------------------------------"
    Write-Host " This removes: Node.js, Python 3.13+, tiddl + beets, ffmpeg,"
    Write-Host " pnpm/tsx, rsgain, tools\, node_modules and the PATH entries added"
    Write-Host " for them. Older Python versions and your music files are NOT"
    Write-Host " touched. userfiles\ is kept."
    Write-Host " ----------------------------------------"
    if (-not $Force) {
        $confirm = Read-Host "Continue? (y/N)"
        if ($confirm -notmatch "^y") { Write-Host "Cancelled."; return }
    }

    Write-Host ""
    Write-Host "[1/6] Stopping Tidarr processes..."
    Stop-TidarrProcesses
    Write-Host "      Done."

    Write-Host "[2/6] Removing Python packages from every detected interpreter..."
    foreach ($python in Get-PythonInstallations) {
        & $python.Path -m pip uninstall -y tiddl beets 2>$null | Out-Null
    }
    Write-Host "      Done."

    Write-Host "[3/6] Removing downloaded tools and project dependencies..."
    foreach ($path in @("tools", "node_modules", "api\node_modules", "app\node_modules", "api\dist", "app\dist")) {
        Remove-Item (Join-Path $root $path) -Recurse -Force
    }
    Write-Host "      Done."

    Write-Host "[4/6] Removing global npm tools (pnpm, tsx)..."
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        & npm uninstall -g pnpm tsx 2>$null | Out-Null
    }
    Write-Host "      Done."

    Write-Host "[5/6] Uninstalling winget packages..."
    # Only Python 3.13+ can have been installed by the launcher (tiddl needs it);
    # older interpreters on the machine belong to the user and are left alone.
    $minimumPython = [version]"3.13"
    $pythons = Get-PythonInstallations
    $removablePython = $pythons | Where-Object {
        $_.Version -and ([version]$_.Version -ge $minimumPython)
    }
    $keptPython = $pythons | Where-Object {
        -not ($_.Version -and ([version]$_.Version -ge $minimumPython))
    }
    foreach ($python in $keptPython) {
        Write-Host "      Keeping Python $($python.Version) ($($python.Path)) — older than the version Tidarr installs."
    }
    foreach ($python in $removablePython) {
        if ($python.Path -match "Python(\d)(\d+)") {
            & winget uninstall "Python.Python.$($Matches[1]).$($Matches[2])" --silent --accept-source-agreements 2>$null | Out-Null
        }
    }
    & winget uninstall "Gyan.FFmpeg" --silent --accept-source-agreements 2>$null | Out-Null
    & winget uninstall "OpenJS.NodeJS.LTS" --silent --accept-source-agreements 2>$null | Out-Null
    Write-Host "      Done."

    Write-Host "[6/6] Cleaning PATH entries..."
    $entries = @(
        (Join-Path $root "tools\rsgain"),
        (Join-Path $env:APPDATA "npm"),
        "C:\Program Files\nodejs",
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Launcher")
    )
    foreach ($python in $removablePython) {
        if ($python.Path -match "^(.*)\\python\.exe$") {
            $entries += $Matches[1]
            $entries += (Join-Path $Matches[1] "Scripts")
        }
    }
    foreach ($entry in $entries | Select-Object -Unique) { Remove-FromPath $entry }
    Write-Host "      Done."

    Write-Host ""
    Write-Host " ----------------------------------------"
    Write-Host " Uninstall complete. Restart the terminal so PATH changes apply."
    Write-Host " ----------------------------------------"
    Write-Host ""
}

if ($Uninstall) {
    if (-not (Test-Admin)) {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Uninstall")
        if ($Force) { $arguments += "-Force" }
        Start-Process powershell -Verb RunAs -ArgumentList $arguments
        exit
    }
    Invoke-Uninstall
    if (-not $Force) {
        Write-Host " Press Enter to close this window."
        Read-Host | Out-Null
    }
    exit
}

Write-Host ""
Write-Host " Tidarr Tools"
Write-Host " ----------------------------------------"
Write-Host "  [1] Uninstall all dependencies"
Write-Host "      (Node.js, Python, tiddl + beets, ffmpeg, pnpm/tsx, rsgain)"
Write-Host ""
Write-Host "  [2] Check installed dependencies"
Write-Host " ----------------------------------------"
Write-Host ""

$choice = Read-Host "Choose [1/2]"
switch ($choice) {
    "1" {
        if (-not (Test-Admin)) {
            $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Uninstall")
            if ($Force) { $arguments += "-Force" }
            Start-Process powershell -Verb RunAs -ArgumentList $arguments
            exit
        }
        Invoke-Uninstall
    }
    "2" { Show-Dependencies }
    default { Write-Host "Invalid choice."; exit 1 }
}
