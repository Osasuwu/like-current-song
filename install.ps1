<#
.SYNOPSIS
    One-liner installer for Like Current Song on Windows.

.DESCRIPTION
    Checks for Python 3.11+, installs pipx if missing, installs the
    like-current-song package from this repo, runs the interactive setup
    wizard. Re-runnable; existing tokens are kept unless -Reauth is
    passed. An existing pipx install under the old package name
    (like-spotify) is uninstalled first; config and tokens are kept.

.EXAMPLE
    iwr https://raw.githubusercontent.com/Osasuwu/like-current-song/main/install.ps1 -OutFile install.ps1
    .\install.ps1

.EXAMPLE
    # Re-run OAuth (after revoking access or switching accounts):
    .\install.ps1 -Reauth
#>

[CmdletBinding()]
param(
    [switch] $Reauth,
    [switch] $SkipSetup,
    [string] $Source = "."
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host ">> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "   ok: $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "   warn: $msg" -ForegroundColor Yellow }

# ── Python ─────────────────────────────────────────────────────────────

Write-Step "Checking for Python >= 3.11"

# Each candidate is (exe, extra-args-array). `py -3` is the py launcher
# with a version selector; `python` / `python3` are direct shims.
$candidates = @(
    @{ exe = "python";  args = @() },
    @{ exe = "py";      args = @("-3") },
    @{ exe = "python3"; args = @() }
)

$python = $null
foreach ($c in $candidates) {
    try {
        $version = & $c.exe @($c.args + "--version") 2>$null
        if ($LASTEXITCODE -eq 0 -and $version -match "Python (\d+)\.(\d+)") {
            $major = [int]$matches[1]; $minor = [int]$matches[2]
            if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 11)) {
                $python = $c
                $label = if ($c.args) { "$($c.exe) $($c.args -join ' ')" } else { $c.exe }
                Write-Ok "found $version via '$label'"
                break
            }
        }
    } catch {}
}

if (-not $python) {
    Write-Host ""
    Write-Host "Python 3.11+ not found." -ForegroundColor Red
    Write-Host "Install it from https://www.python.org/downloads/windows/ then re-run this script."
    Write-Host "Tip: tick 'Add Python to PATH' in the installer."
    exit 2
}

# ── pipx ───────────────────────────────────────────────────────────────

Write-Step "Ensuring pipx is available"
$hasPipx = $false
try {
    & pipx --version *>$null
    if ($LASTEXITCODE -eq 0) { $hasPipx = $true }
} catch {}

if (-not $hasPipx) {
    Write-Step "Installing pipx via pip (--user)"
    & $python.Split(" ")[0] $python.Split(" ")[1..($python.Split(" ").Count - 1)] -m pip install --user --upgrade pipx
    if ($LASTEXITCODE -ne 0) { throw "pipx install failed" }
    & $python.Split(" ")[0] $python.Split(" ")[1..($python.Split(" ").Count - 1)] -m pipx ensurepath
    Write-Warn2 "If 'pipx' isn't on PATH after this, open a new terminal and re-run install.ps1."
    Write-Ok "pipx installed"
} else {
    Write-Ok "pipx already present"
}

# ── like-current-song ──────────────────────────────────────────────────

# Before #101 the package was called `like-spotify`. Both packages ship the
# `like-spotify` / `like-spotify-gui` commands (the new one keeps them as
# deprecated aliases), so pipx can't hold both. Remove the old pipx package
# first. Config and tokens in ~/.like_spotify/ are not touched.
$hadOld = $false
try {
    $pipxList = & pipx list --short 2>$null
    if ($LASTEXITCODE -eq 0 -and ($pipxList | Where-Object { $_ -match '^like-spotify\s' })) {
        $hadOld = $true
    }
} catch {}
if ($hadOld) {
    Write-Step "Removing the old 'like-spotify' pipx package (now called like-current-song)"
    & pipx uninstall like-spotify
    if ($LASTEXITCODE -ne 0) { throw "pipx uninstall of like-spotify failed" }
    Write-Ok "old package removed; config in ~/.like_spotify/ is kept"
}

Write-Step "Installing like-current-song from '$Source'"
# The ytmusic extra only pulls small winrt wheels for the Windows media
# session, so install it up front: switching service in --setup then just works.
& pipx install --force "${Source}[ytmusic]"
if ($LASTEXITCODE -ne 0) { throw "pipx install of like-current-song failed" }
Write-Ok "like-current-song on PATH"

# ── setup ──────────────────────────────────────────────────────────────

if ($SkipSetup) {
    Write-Step "Skipping --setup (per -SkipSetup)"
    Write-Host "Next: run 'like-current-song --setup' manually."
    if ($hadOld) {
        # The old autostart entry pointed into the removed package. Starting
        # the tray once (or --setup's autostart step) rewrites it.
        Write-Warn2 "If autostart was on, launch 'like-current-song-gui' once to point it at the new install."
    }
    exit 0
}

Write-Step "Launching interactive setup"
$setupArgs = @("--setup")
if ($Reauth) { $setupArgs += "--reauth" }
& like-current-song @setupArgs
$setupExit = $LASTEXITCODE
if ($setupExit -ne 0) {
    Write-Warn2 "setup exited with code $setupExit. Re-run 'like-current-song --setup' once you have the credentials."
    exit $setupExit
}

Write-Host ""
Write-Step "Done. Launch the tray host with: like-current-song-gui"
Write-Host "      (like-current-song also works but shows a console; -gui is the windowed twin)"
Write-Host "      Default hotkey: Ctrl+Shift+Alt+W"
