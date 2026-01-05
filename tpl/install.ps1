<#
.SYNOPSIS
    AmiDevBox Installation Script

.DESCRIPTION
    Downloads and installs Boxing system with AmiDevBox box.
    Run via: irm https://raw.githubusercontent.com/vbuzzano/AmiDevBox/main/install.ps1 | iex

.NOTES
    This script downloads boxer.ps1 from Boxing repository and triggers installation.
#>

param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Boxing repository configuration
$BoxingRepo = "vbuzzano/Boxing"
$BoxingBranch = "main"
$BoxerUrl = "https://raw.githubusercontent.com/$BoxingRepo/$BoxingBranch/dist/boxer.ps1"

# Box configuration (current repository)
$BoxRepo = "AmiDevBox"

Write-Host ""
Write-Host "🥊 AmiDevBox Installation" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host ""

try {
    Write-Host "📥 Downloading boxer.ps1..." -ForegroundColor Yellow

    # Download boxer.ps1 content
    $BoxerContent = Invoke-RestMethod -Uri $BoxerUrl -ErrorAction Stop

    Write-Host "✓ Downloaded boxer.ps1 from Boxing repository" -ForegroundColor Green
    Write-Host ""

    # Execute boxer.ps1 in current scope with $SourceRepo variable set
    # This will:
    # 1. Install Boxing system (boxer.ps1 + profile functions)
    # 2. Download and install AmiDevBox box files
    $SourceRepo = $BoxRepo
    Invoke-Expression $BoxerContent

} catch {
    Write-Host ""
    Write-Host "❌ Installation failed: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Manual installation:" -ForegroundColor Yellow
    Write-Host "  1. Download Boxing: irm https://raw.githubusercontent.com/$BoxingRepo/$BoxingBranch/dist/boxer.ps1 | iex" -ForegroundColor White
    Write-Host "  2. Install AmiDevBox: boxer install https://github.com/vbuzzano/$BoxRepo" -ForegroundColor White
    Write-Host ""
    exit 1
}
