<#
.SYNOPSIS
    AmiDevBox One-Line Installer

.DESCRIPTION
    Installs Boxing system and AmiDevBox in one command.

    Usage:
      irm https://github.com/vbuzzano/AmiDevBox/raw/main/install.ps1 | iex

.NOTES
    After installation, restart PowerShell and use:
      boxer init MyProject
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ""
Write-Host "🚀 AmiDevBox Installer" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host ""

try {
    $BoxingScriptsDir = "$env:USERPROFILE\Documents\PowerShell\Scripts"
    $BoxerPath = Join-Path $BoxingScriptsDir "boxer.ps1"
    $BoxPath = Join-Path $BoxingScriptsDir "box.ps1"

    # Check if Boxing is already installed
    $boxingInstalled = (Test-Path $BoxerPath) -and (Test-Path $BoxPath)

    if (-not $boxingInstalled) {
        Write-Host "📦 Boxing system not found. Installing..." -ForegroundColor Yellow
        Write-Host ""

        # Create Scripts directory if needed
        if (-not (Test-Path $BoxingScriptsDir)) {
            New-Item -ItemType Directory -Path $BoxingScriptsDir -Force | Out-Null
        }

        # Download boxer.ps1 from box repo
        Write-Host "📥 Downloading boxer.ps1..." -ForegroundColor Yellow
        $boxerUrl = "https://github.com/vbuzzano/AmiDevBox/raw/main/boxer.ps1"
        Invoke-RestMethod -Uri $boxerUrl -OutFile $BoxerPath
        Write-Host "   ✓ Downloaded boxer.ps1" -ForegroundColor Green
        Write-Host ""

        # Download box.ps1 from box repo
        Write-Host "📥 Downloading box.ps1..." -ForegroundColor Yellow
        $boxUrl = "https://github.com/vbuzzano/AmiDevBox/raw/main/box.ps1"
        Invoke-RestMethod -Uri $boxUrl -OutFile $BoxPath
        Write-Host "   ✓ Downloaded box.ps1" -ForegroundColor Green
        Write-Host ""

        # Run boxer --install to setup profile and directories
        Write-Host "⚙️  Setting up Boxing system..." -ForegroundColor Yellow
        $setupOutput = & $BoxerPath --install 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Boxing installation failed: $setupOutput"
        }
        Write-Host "   ✓ Boxing system ready" -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host "✓ Boxing system already installed" -ForegroundColor Green
        Write-Host ""
    }

    # Install the box using boxer install
    Write-Host "📦 Installing AmiDevBox..." -ForegroundColor Yellow
    $installOutput = & $BoxerPath install "https://github.com/vbuzzano/AmiDevBox" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "AmiDevBox installation failed: $installOutput"
    }
    Write-Host "   ✓ AmiDevBox installed" -ForegroundColor Green
    Write-Host ""

    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host "✅ Installation complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Restart PowerShell" -ForegroundColor White
    Write-Host "  2. Run: boxer init MyProject" -ForegroundColor White
    Write-Host "  3. cd MyProject && box install" -ForegroundColor White
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "❌ Installation failed: $_" -ForegroundColor Red
    Write-Host ""
    exit 1
}

