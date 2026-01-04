<#
.SYNOPSIS
    AmiDevBox Installation Script

.DESCRIPTION
    Installs or updates AmiDevBox box system.
    - If Boxing not installed: Downloads boxer.ps1 and installs AmiDevBox
    - If Boxing already installed: Updates AmiDevBox box if newer version available

.EXAMPLE
    irm https://raw.githubusercontent.com/vbuzzano/AmiDevBox/main/install.ps1 | iex
#>

param()

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "🥊 AmiDevBox Installation" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host ""

# Determine Boxing directory
$BoxingDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "PowerShell\Boxing"
$BoxerPath = Join-Path $BoxingDir "boxer.ps1"
$BoxDir = Join-Path $BoxingDir "Boxes\AmiDevBox"
$MetadataPath = Join-Path $BoxDir "metadata.psd1"

# Check if Boxing is installed
if (Test-Path $BoxerPath) {
    Write-Host "✅ Boxing system detected" -ForegroundColor Green
    Write-Host ""

    # Get installed version
    $InstalledVersion = $null
    if (Test-Path $MetadataPath) {
        try {
            $metadata = Import-PowerShellDataFile -Path $MetadataPath
            $InstalledVersion = $metadata.Version
        } catch {
            Write-Host "⚠️  Could not read installed version" -ForegroundColor Yellow
        }
    }

    # Get remote version
    $RemoteVersion = $null
    try {
        $RemoteMetadataUrl = "https://raw.githubusercontent.com/vbuzzano/AmiDevBox/main/metadata.psd1"
        $RemoteContent = Invoke-RestMethod -Uri $RemoteMetadataUrl
        if ($RemoteContent -match 'Version\s*=\s*"([^"]+)"') {
            $RemoteVersion = $Matches[1]
        }
    } catch {
        Write-Host "⚠️  Could not fetch remote version" -ForegroundColor Yellow
    }

    # Compare versions
    if ($InstalledVersion -and $RemoteVersion) {
        try {
            $v1 = [version]$RemoteVersion
            $v2 = [version]$InstalledVersion

            if ($v1 -gt $v2) {
                Write-Host "📦 Update available: v$InstalledVersion → v$RemoteVersion" -ForegroundColor Cyan
                Write-Host "   Installing update..." -ForegroundColor Gray
                Write-Host ""
                & $BoxerPath install AmiDevBox
                Write-Host ""
                Write-Host "✅ AmiDevBox updated to v$RemoteVersion" -ForegroundColor Green
            } elseif ($v1 -eq $v2) {
                Write-Host "✅ AmiDevBox already up-to-date (v$InstalledVersion)" -ForegroundColor Green
            } else {
                Write-Host "⚠️  Installed version (v$InstalledVersion) is newer than remote (v$RemoteVersion)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "⚠️  Could not compare versions, forcing reinstall..." -ForegroundColor Yellow
            & $BoxerPath install AmiDevBox
        }
    } else {
        # No version info, just install/reinstall
        Write-Host "📦 Installing AmiDevBox..." -ForegroundColor Cyan
        & $BoxerPath install AmiDevBox
    }
} else {
    Write-Host "📥 Boxing system not found, installing..." -ForegroundColor Cyan
    Write-Host ""

    # Download and execute boxer.ps1 from Boxing repository
    $BoxerUrl = "https://raw.githubusercontent.com/vbuzzano/Boxing/main/dist/boxer.ps1"
    try {
        Write-Host "   Downloading boxer.ps1..." -ForegroundColor Gray
        $boxerScript = Invoke-RestMethod -Uri $BoxerUrl
        Write-Host "   Installing Boxing system..." -ForegroundColor Gray
        Invoke-Expression $boxerScript

        Write-Host ""
        Write-Host "✅ Boxing system installed" -ForegroundColor Green
        Write-Host ""

        # Now install AmiDevBox
        Write-Host "📦 Installing AmiDevBox..." -ForegroundColor Cyan
        & $BoxerPath install AmiDevBox

        Write-Host ""
        Write-Host "✅ AmiDevBox installed successfully" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "❌ Installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        exit 1
    }
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "🚀 Next steps:" -ForegroundColor Cyan
Write-Host "   1. Restart PowerShell (or run: . $PROFILE)" -ForegroundColor Gray
Write-Host "   2. Create a project: boxer init MyProject" -ForegroundColor Gray
Write-Host "   3. Install packages: box install" -ForegroundColor Gray
Write-Host ""
