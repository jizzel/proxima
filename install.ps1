# Proxima install script for Windows (PowerShell)
# Usage: irm https://raw.githubusercontent.com/jizzel/proxima/main/install.ps1 | iex
#
# By default installs to $env:LOCALAPPDATA\proxima\proxima.exe and adds it to the
# user PATH. Override with $env:PROXIMA_INSTALL_DIR before running.

$ErrorActionPreference = 'Stop'

$Repo        = 'jizzel/proxima'
$BinaryName  = 'proxima.exe'
$AssetName   = 'proxima-windows-x64.exe'
$InstallDir  = if ($env:PROXIMA_INSTALL_DIR) { $env:PROXIMA_INSTALL_DIR }
               else { Join-Path $env:LOCALAPPDATA 'proxima' }

# ── Resolve latest release tag ────────────────────────────────────────────────

$ApiUrl    = "https://api.github.com/repos/$Repo/releases/latest"
$Release   = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing
$LatestTag = $Release.tag_name

if (-not $LatestTag) {
    Write-Error "Could not determine latest release tag."
    exit 1
}

$DownloadUrl = "https://github.com/$Repo/releases/download/$LatestTag/$AssetName"

# ── Download ──────────────────────────────────────────────────────────────────

Write-Host "Installing Proxima $LatestTag -> $InstallDir\$BinaryName"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}

$Dest = Join-Path $InstallDir $BinaryName
Invoke-WebRequest -Uri $DownloadUrl -OutFile $Dest -UseBasicParsing

# ── Add to user PATH if not already present ───────────────────────────────────

$UserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($UserPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable(
        'PATH',
        "$UserPath;$InstallDir",
        'User'
    )
    Write-Host "Added $InstallDir to your PATH (restart your terminal to apply)."
}

Write-Host "Done. Run: proxima --version"
