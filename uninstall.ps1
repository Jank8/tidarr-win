param([switch]$Uninstall, [switch]$Force, [switch]$SystemStage)

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

$MinimumPython = [version]"3.13"

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

function Get-RemovablePythons {
    return @(Get-PythonInstallations | Where-Object {
        $_.Version -and ([version]$_.Version -ge $MinimumPython)
    })
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

function Remove-WingetPackage([string]$Id, [string]$Label) {
    $output = & winget uninstall --id $Id --silent --accept-source-agreements 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "      WARNING: could not uninstall $Label ($Id), exit $LASTEXITCODE" -ForegroundColor Yellow
        $output | Select-Object -Last 2 | ForEach-Object { Write-Host "        $_" }
    }
}

function Remove-UserDependencies {
    Write-Host "[1/2] Removing tools, project dependencies and Python packages..."
    Stop-TidarrProcesses
    foreach ($python in Get-PythonInstallations) {
        & $python.Path -m pip uninstall -y tiddl beets 2>$null | Out-Null
    }
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        & npm uninstall -g pnpm tsx 2>$null | Out-Null
    }
    foreach ($path in @("tools", "node_modules", "api\node_modules", "app\node_modules", "api\dist", "app\dist")) {
        Remove-Item (Join-Path $root $path) -Recurse -Force
    }
    Write-Host "      Done."

    Write-Host "[2/2] Uninstalling user-scope packages (Python 3.13+, ffmpeg)..."
    $removable = Get-RemovablePythons
    $kept = Get-PythonInstallations | Where-Object { $_.Version -and ([version]$_.Version -lt $MinimumPython) }
    foreach ($python in $kept) {
        Write-Host "      Keeping Python $($python.Version) ($($python.Path))"
    }
    foreach ($python in $removable) {
        if ($python.Path -match "Python(\d)(\d+)") {
            Remove-WingetPackage -Id "Python.Python.$($Matches[1]).$($Matches[2])" -Label "Python $($python.Version)"
        }
    }
    Remove-WingetPackage -Id "Gyan.FFmpeg" -Label "ffmpeg"
    Write-Host "      Done."
}

function Remove-SystemDependencies {
    Write-Host "[admin] Uninstalling Node.js..."
    Remove-WingetPackage -Id "OpenJS.NodeJS.LTS" -Label "Node.js"
    Write-Host "        Done."

    Write-Host "[admin] Cleaning PATH entries..."
    $entries = @(
        (Join-Path $root "tools\rsgain"),
        (Join-Path $env:APPDATA "npm"),
        "C:\Program Files\nodejs"
    )
    # Only PATH entries of the Python versions that were removed; older
    # interpreters (and the py launcher they use) stay untouched.
    foreach ($python in Get-PythonInstallations) {
        if ($python.Version -and ([version]$python.Version -ge $MinimumPython) -and $python.Path -match "^(.*)\\python\.exe$") {
            $entries += $Matches[1]
            $entries += (Join-Path $Matches[1] "Scripts")
        }
    }
    foreach ($entry in $entries | Select-Object -Unique) { Remove-FromPath $entry }
    Write-Host "        Done."
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

    Remove-UserDependencies

    if (Test-Admin) {
        Remove-SystemDependencies
    } else {
        Write-Host ""
        Write-Host " Administrator rights are needed for Node.js and the machine PATH."
        Write-Host " Accept the UAC prompt - the second stage continues in a new window."
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-SystemStage")
        if ($Force) { $arguments += "-Force" }
        Start-Process powershell -Verb RunAs -ArgumentList $arguments
    }

    Write-Host ""
    Write-Host " ----------------------------------------"
    Write-Host " User-scope uninstall complete."
    Write-Host " ----------------------------------------"
    Write-Host ""
}

if ($SystemStage) {
    if (-not (Test-Admin)) {
        Write-Host "This stage must run as administrator." -ForegroundColor Red
        exit 1
    }
    Remove-SystemDependencies
    Write-Host ""
    Write-Host " ----------------------------------------"
    Write-Host " Uninstall complete. Restart the terminal so PATH changes apply."
    Write-Host " ----------------------------------------"
    if (-not $Force) {
        Write-Host " Press Enter to close this window."
        Read-Host | Out-Null
    }
    exit
}

if ($Uninstall) {
    Invoke-Uninstall
    exit
}

Write-Host ""
Write-Host " Tidarr Tools"
Write-Host " ----------------------------------------"
Write-Host "  [1] Uninstall all dependencies"
Write-Host "      (Node.js, Python 3.13+, tiddl + beets, ffmpeg, pnpm/tsx, rsgain)"
Write-Host ""
Write-Host "  [2] Check installed dependencies"
Write-Host " ----------------------------------------"
Write-Host ""

$choice = Read-Host "Choose [1/2]"
switch ($choice) {
    "1" { Invoke-Uninstall }
    "2" { Show-Dependencies }
    default { Write-Host "Invalid choice."; exit 1 }
}
