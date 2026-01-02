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
    # Step 1: Create Boxing directory
    $BoxingDir = "$env:USERPROFILE\Documents\PowerShell\Boxing"
    Write-Host "📁 Creating Boxing directory..." -ForegroundColor Yellow
    if (-not (Test-Path $BoxingDir)) {
        New-Item -ItemType Directory -Path $BoxingDir -Force | Out-Null
    }
    Write-Host "   ✓ $BoxingDir" -ForegroundColor Green
    Write-Host ""

    # Step 2: Download boxer.ps1
    Write-Host "📥 Downloading boxer.ps1..." -ForegroundColor Yellow
    $boxerUrl = "https://github.com/vbuzzano/AmiDevBox/raw/main/boxer.ps1"
    $boxerPath = Join-Path $BoxingDir "boxer.ps1"
    Invoke-RestMethod -Uri $boxerUrl -OutFile $boxerPath
    Write-Host "   ✓ Downloaded boxer.ps1" -ForegroundColor Green
    Write-Host ""

    # Step 3: Download box.ps1
    Write-Host "📥 Downloading box.ps1..." -ForegroundColor Yellow
    $boxUrl = "https://github.com/vbuzzano/AmiDevBox/raw/main/box.ps1"
    $boxPath = Join-Path $BoxingDir "box.ps1"
    Invoke-RestMethod -Uri $boxUrl -OutFile $boxPath
    Write-Host "   ✓ Downloaded box.ps1" -ForegroundColor Green
    Write-Host ""

    # Step 4: Install AmiDevBox
    Write-Host "📦 Installing AmiDevBox..." -ForegroundColor Yellow
    $amidevboxDir = Join-Path $BoxingDir "AmiDevBox"
    if (-not (Test-Path $amidevboxDir)) {
        New-Item -ItemType Directory -Path $amidevboxDir -Force | Out-Null
    }

    # Download config.psd1
    $configUrl = "https://github.com/vbuzzano/AmiDevBox/raw/main/config.psd1"
    $configPath = Join-Path $amidevboxDir "config.psd1"
    Invoke-RestMethod -Uri $configUrl -OutFile $configPath

    # Download metadata.psd1
    $metadataUrl = "https://github.com/vbuzzano/AmiDevBox/raw/main/metadata.psd1"
    $metadataPath = Join-Path $amidevboxDir "metadata.psd1"
    Invoke-RestMethod -Uri $metadataUrl -OutFile $metadataPath

    # Download tpl/ directory (we'll create it and download key files)
    $tplDir = Join-Path $amidevboxDir "tpl"
    if (-not (Test-Path $tplDir)) {
        New-Item -ItemType Directory -Path $tplDir -Force | Out-Null
    }

    # Create .boxer manifest
    $boxerManifest = @"
Name=AmiDevBox
Version=0.1.0
Repository=https://github.com/vbuzzano/AmiDevBox
"@
    Set-Content -Path (Join-Path $amidevboxDir ".boxer") -Value $boxerManifest

    Write-Host "   ✓ AmiDevBox installed" -ForegroundColor Green
    Write-Host ""

    # Step 5: Configure PowerShell profile
    Write-Host "⚙️  Configuring PowerShell profile..." -ForegroundColor Yellow
    $profilePath = $PROFILE.CurrentUserAllHosts
    
    if (-not (Test-Path $profilePath)) {
        $profileDir = Split-Path $profilePath -Parent
        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -notmatch '#region boxing') {
        $injection = @"

#region boxing
# Managed by Boxing installer
function boxer {
    & "`$env:USERPROFILE\Documents\PowerShell\Boxing\boxer.ps1" @args
}

function box {
    `$boxScript = `$null
    `$current = (Get-Location).Path

    while (`$current -ne [System.IO.Path]::GetPathRoot(`$current)) {
        `$testPath = Join-Path `$current ".box\box.ps1"
        if (Test-Path `$testPath) {
            `$boxScript = `$testPath
            break
        }
        `$parent = Split-Path `$current -Parent
        if (-not `$parent) { break }
        `$current = `$parent
    }

    if (-not `$boxScript) {
        Write-Host "❌ No boxing project found" -ForegroundColor Red
        Write-Host ""
        Write-Host "Create a new project:" -ForegroundColor Cyan
        Write-Host "  boxer init MyProject" -ForegroundColor White
        return
    }

    & `$boxScript @args
}
#endregion boxing
"@
        Add-Content -Path $profilePath -Value $injection
        Write-Host "   ✓ Profile configured" -ForegroundColor Green
    } else {
        Write-Host "   ℹ️  Profile already configured" -ForegroundColor Cyan
    }
    Write-Host ""

    # Step 6: Success message
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host "✅ Installation complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "📍 Location: $BoxingDir" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Restart PowerShell (or run: . `$PROFILE)" -ForegroundColor White
    Write-Host "  2. Create a project: boxer init MyProject" -ForegroundColor White
    Write-Host "  3. cd MyProject && box install" -ForegroundColor White
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "❌ Installation failed: $_" -ForegroundColor Red
    Write-Host ""
    exit 1
}
