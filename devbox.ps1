<#
.SYNOPSIS
    DevBox Bootstrap Installer

.DESCRIPTION
    Creates or initializes a DevBox project structure for cross-platform development.
    Supports two modes: init (new project) and add (existing project).

    Usage:
      devbox init MyProject [Description]
      devbox add [in existing directory]

    Remote installation:
      irm https://github.com/vbuzzano/DevBoxFoundry/raw/main/devbox.ps1 | iex -ArgumentList 'init', 'MyProject'

.PARAMETER Mode
    Operation mode: 'init' or 'add'. Auto-detected if not specified.

.PARAMETER ProjectName
    Project name (required for init mode). Can contain spaces - will be sanitized.

.PARAMETER Description
    Project description (optional). Used in config and README generation.

.PARAMETER UseVSCode
    Auto-answer for VS Code integration (for scripting). Prompts if not specified.

.EXAMPLE
    devbox init MyProject "My awesome project"
    devbox add
    irm https://.../devbox.ps1 | iex

.NOTES
    Author: ReddoC
    Version: 0.1.0
    Requires: PowerShell 7+, Git
#>

param(
    [Parameter(Position=0, ValueFromRemainingArguments=$true)]
    [object[]]$Arguments
)

# Parse arguments (support for both direct call and irm | iex)
$Mode = ''
$ProjectName = ''
$Description = ''
$UseVSCode = $false

if ($Arguments.Count -gt 0) {
    $Mode = $Arguments[0] -as [string]
    if ($Arguments.Count -gt 1) { $ProjectName = $Arguments[1] -as [string] }
    if ($Arguments.Count -gt 2) { $Description = $Arguments[2] -as [string] }
    if ($Arguments.Count -gt 3) { $UseVSCode = [bool]::Parse($Arguments[3] -as [string]) }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ============================================================================
# CONFIGURATION
# ============================================================================

$Script:Config = @{
    Version = '0.1.0'
    RepositoryUrl = 'https://github.com/vbuzzano/DevBoxFoundry.git'
    BoxDir = '.box'
    ConfigFile = 'box.config.psd1'
    EnvFile = '.env'
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

function Write-Title {
    param([string]$Text)
    Write-Host "`n" -NoNewline
    Write-Host '━' * 60 -ForegroundColor DarkMagenta
    Write-Host "  $Text" -ForegroundColor White
    Write-Host '━' * 60 -ForegroundColor DarkMagenta
}

function Write-Step {
    param([string]$Text)
    Write-Host "  ⏳ $Text" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Text)
    Write-Host "  ✓ $Text" -ForegroundColor Green
}

function Write-Error-Custom {
    param([string]$Text)
    Write-Host "  ❌ $Text" -ForegroundColor Red
}

function Test-Prerequisites {
    # Check if git is installed
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error-Custom 'git is not installed'
        Write-Host ''
        Write-Host '  Download from: https://git-scm.com/download/win' -ForegroundColor Yellow
        exit 1
    }
    Write-Success 'git is installed'
}

function Get-RemoteDownloadUrl {
    # Returns URL to download devbox.ps1 from GitHub
    $org = 'vbuzzano'
    $repo = 'DevBoxFoundry'
    $branch = 'main'
    return "https://github.com/$org/$repo/raw/$branch/dist/devbox.ps1"
}

function Show-RemoteInstallationError {
    param([string]$ErrorMessage)

    Write-Host ''
    Write-Error-Custom 'Remote installation failed'
    Write-Host "  $ErrorMessage" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Manual download:' -ForegroundColor White
    Write-Host "    irm $(Get-RemoteDownloadUrl) -OutFile devbox.ps1" -ForegroundColor Cyan
    Write-Host "    .\devbox.ps1 init MyProject" -ForegroundColor Cyan
    Write-Host ''
}

function Sanitize-ProjectName {
    param([string]$Name)
    # Remove/replace invalid characters for directory names
    $sanitized = $Name -replace '[/\\()^''":\[\]<>|?*]', '-'
    # Remove trailing dots and spaces
    $sanitized = $sanitized -replace '[\s.]+$', ''
    # Remove leading/trailing dashes
    $sanitized = $sanitized -replace '^-+|-+$', ''
    return $sanitized
}

# Rollback tracking for error recovery
$Script:CreatedItems = @()

function Track-Creation {
    param([string]$Path, [string]$Type = 'file')
    $Script:CreatedItems += @{ Path = $Path; Type = $Type }
}

function Rollback-Creation {
    Write-Host ''
    Write-Step 'Rolling back changes...'

    # Reverse order (newest first)
    for ($i = $Script:CreatedItems.Count - 1; $i -ge 0; $i--) {
        $item = $Script:CreatedItems[$i]
        if (Test-Path $item.Path) {
            try {
                Remove-Item $item.Path -Recurse -Force -ErrorAction SilentlyContinue
                Write-Success "Removed: $($item.Path)"
            }
            catch {
                Write-Host "  ⚠ Could not remove: $($item.Path)" -ForegroundColor Yellow
            }
        }
    }

    $Script:CreatedItems = @()
}

# ============================================================================
# PHASE 1: INIT MODE
# ============================================================================

function Initialize-NewProject {
    param(
        [string]$ProjectName,
        [string]$Description,
        [switch]$VSCode
    )

    # Sanitize project name
    $SafeName = Sanitize-ProjectName -Name $ProjectName
    if (-not $SafeName) {
        Write-Error-Custom 'Invalid project name after sanitization'
        exit 1
    }

    $TargetDir = Join-Path (Get-Location) $SafeName

    # Check if directory exists
    if (Test-Path $TargetDir) {
        Write-Error-Custom "Directory '$SafeName' already exists"
        exit 1
    }

    Write-Title "Creating Project: $ProjectName"
    Write-Host "Directory: $SafeName" -ForegroundColor Gray
    Write-Host ''

    try {
        # Create project directory
        Write-Step 'Creating project directory'
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        Track-Creation $TargetDir 'directory'
        Write-Success "Created: $SafeName"

        # Create .box directory
        Write-Step 'Creating .box directory'
        $BoxPath = Join-Path $TargetDir $Script:Config.BoxDir
        New-Item -ItemType Directory -Path $BoxPath -Force | Out-Null
        Track-Creation $BoxPath 'directory'
        Write-Success 'Created: .box'

        # Download/copy box.ps1 from release
        Write-Step 'Downloading box.ps1'
        try {
            $BoxUrl = 'https://github.com/vbuzzano/DevBoxFoundry/raw/main/dist/box.ps1'
            $BoxDest = Join-Path $BoxPath 'box.ps1'

            # Try local copy first (for development), then remote download
            $LocalBoxPath = Join-Path (Split-Path $Script:MyInvocation.MyCommand.Path) 'box.ps1'
            if (-not (Test-Path $LocalBoxPath)) {
                $LocalBoxPath = 'box.ps1'
            }

            if (Test-Path $LocalBoxPath) {
                Copy-Item $LocalBoxPath $BoxDest -Force
                Write-Success 'Copied: box.ps1 to .box/'
            }
            else {
                # Fallback to remote download
                $ProgressPreference = 'SilentlyContinue'
                Invoke-RestMethod -Uri $BoxUrl -OutFile $BoxDest -ErrorAction Stop
                Write-Success 'Downloaded: box.ps1 to .box/'
            }

            if (-not (Test-Path $BoxDest)) {
                throw 'box.ps1 not found'
            }
        }
        catch {
            Write-Error-Custom "Setup failed: $_"
            throw
        }

        # Generate box.config.psd1
        Write-Step 'Generating configuration file'
        $ConfigPath = Join-Path $TargetDir $Script:Config.ConfigFile
        $TemplateConfig = @"
@{
    Name = '$ProjectName'
    Description = '$Description'
    ProgramName = '$SafeName'
    Version = '0.1.0'
    DefaultCPU = 'm68020'
    DefaultFPU = ''
}
"@
        Set-Content -Path $ConfigPath -Value $TemplateConfig -Encoding UTF8
        Track-Creation $ConfigPath 'file'
        Write-Success "Generated: box.config.psd1"

        # Create .env file
        Write-Step 'Creating environment file'
        $EnvPath = Join-Path $TargetDir $Script:Config.EnvFile
        $EnvContent = @"
# DevBox environment - $ProjectName
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

# Project
PROJECT_NAME=$ProjectName
PROGRAM_NAME=$SafeName
VERSION=0.1.0

# Amiga Development
DefaultCPU=m68020
DefaultFPU=
"@
        Set-Content -Path $EnvPath -Value $EnvContent -Encoding UTF8
        Track-Creation $EnvPath 'file'
        Write-Success 'Created: .env'

        # Create directories
        Write-Step 'Creating project structure'
        foreach ($Dir in @('src', 'include', 'lib', 'bin')) {
            $DirPath = Join-Path $TargetDir $Dir
            New-Item -ItemType Directory -Path $DirPath -Force | Out-Null
            Track-Creation $DirPath 'directory'
        }
        Write-Success 'Created: src/, include/, lib/, bin/'

        # Create README.md
        Write-Step 'Generating README'
        $ReadmePath = Join-Path $TargetDir 'README.md'
        $ReadmeContent = @"
# $ProjectName

$Description

## Project Structure

- **src/**: Source code
- **include/**: Header files
- **lib/**: Libraries
- **bin/**: Compiled binaries
- **.box/**: DevBox development tools

## Getting Started

1. Review configuration: \`box.config.psd1\`
2. Load environment: \`. .\.env.ps1\` (in PowerShell)
3. Build: \`box build\` (or \`make\` if configured)

## Documentation

See **.box/** directory for build system documentation.
"@
        Set-Content -Path $ReadmePath -Value $ReadmeContent -Encoding UTF8
        Track-Creation $ReadmePath 'file'
        Write-Success 'Generated: README.md'

        # VS Code integration (optional)
        if ($VSCode) {
            Write-Step 'Configuring VS Code'
            $VSCodeDir = Join-Path $TargetDir '.vscode'
            New-Item -ItemType Directory -Path $VSCodeDir -Force | Out-Null
            Track-Creation $VSCodeDir 'directory'

            $SettingsPath = Join-Path $VSCodeDir 'settings.json'
            $SettingsContent = @"
{
  "terminal.integrated.env.windows": {
    "DEVBOX_ENV": ".env"
  },
  "terminal.integrated.env.linux": {
    "DEVBOX_ENV": ".env"
  },
  "terminal.integrated.env.osx": {
    "DEVBOX_ENV": ".env"
  },
  "powershell.codeFormatting.preset": "OTBS",
  "[powershell]": {
    "editor.defaultFormatter": "ms-vscode.powershell",
    "editor.formatOnSave": true
  }
}
"@
            Set-Content -Path $SettingsPath -Value $SettingsContent -Encoding UTF8
            Track-Creation $SettingsPath 'file'
            Write-Success 'Created: .vscode/settings.json'
        }

        # Copy box.ps1 to project root
        Write-Step 'Setting up box.ps1'
        $SourceBox = Join-Path $BoxPath 'box.ps1'
        $TargetBox = Join-Path $TargetDir 'box.ps1'
        if (Test-Path $SourceBox) {
            Copy-Item $SourceBox $TargetBox -Force
            Write-Success 'Copied: box.ps1 to root'
        }

        # Final success message
        Write-Title 'Project Created Successfully'
        Write-Host "  📁 Location: $TargetDir" -ForegroundColor Cyan
        Write-Host "  🚀 Next steps:" -ForegroundColor Cyan
        Write-Host "    cd $SafeName" -ForegroundColor Gray
        Write-Host "    .\box.ps1 help" -ForegroundColor Gray
        Write-Host ''

        # Clear tracking on success
        $Script:CreatedItems = @()
    }
    catch {
        Write-Host ''
        Write-Error-Custom "Project creation failed: $_"
        Rollback-Creation
        exit 1
    }
}

# ============================================================================
# PHASE 2: ADD MODE
# ============================================================================

function Add-ToExistingProject {
    Write-Title 'Adding DevBox to Existing Project'

    $CurrentDir = Get-Location
    Write-Host "Directory: $CurrentDir" -ForegroundColor Gray
    Write-Host ''

    try {
        $BoxDir = Join-Path $CurrentDir $Script:Config.BoxDir

        # Check if .box already exists
        if (Test-Path $BoxDir) {
            Write-Host '  ℹ️ .box/ directory already exists, skipping download' -ForegroundColor Cyan
        }
        else {
            Write-Step 'Creating .box directory'
            New-Item -ItemType Directory -Path $BoxDir -Force | Out-Null
            Track-Creation $BoxDir 'directory'
            Write-Success 'Created: .box'

            # Download/copy box.ps1
            Write-Step 'Downloading box.ps1'
            try {
                $BoxUrl = 'https://github.com/vbuzzano/DevBoxFoundry/raw/main/dist/box.ps1'
                $BoxDest = Join-Path $BoxDir 'box.ps1'

                # Try local copy first (for development), then remote download
                $LocalBoxPath = Join-Path (Split-Path $Script:MyInvocation.MyCommand.Path) 'box.ps1'
                if (-not (Test-Path $LocalBoxPath)) {
                    $LocalBoxPath = 'box.ps1'
                }

                if (Test-Path $LocalBoxPath) {
                    Copy-Item $LocalBoxPath $BoxDest -Force
                    Write-Success 'Copied: box.ps1 to .box/'
                }
                else {
                    # Fallback to remote download
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-RestMethod -Uri $BoxUrl -OutFile $BoxDest -ErrorAction Stop
                    Write-Success 'Downloaded: box.ps1 to .box/'
                }

                if (-not (Test-Path $BoxDest)) {
                    throw 'box.ps1 not found'
                }
            }
            catch {
                Write-Error-Custom "Setup failed: $_"
                throw
            }
        }

        # Create/update config
        $ConfigPath = Join-Path $CurrentDir $Script:Config.ConfigFile
        if (-not (Test-Path $ConfigPath)) {
            Write-Step 'Generating configuration file'
            $ProjectName = Split-Path $CurrentDir -Leaf
            $ConfigContent = @"
@{
    Name = '$ProjectName'
    Description = ''
    ProgramName = '$ProjectName'
    Version = '0.1.0'
    DefaultCPU = 'm68020'
    DefaultFPU = ''
}
"@
            Set-Content -Path $ConfigPath -Value $ConfigContent -Encoding UTF8
            Track-Creation $ConfigPath 'file'
            Write-Success 'Generated: box.config.psd1'
        }
        else {
            Write-Host '  ℹ️ box.config.psd1 already exists, skipping' -ForegroundColor Cyan
        }

        # Create/backup .env
        $EnvPath = Join-Path $CurrentDir $Script:Config.EnvFile
        if (-not (Test-Path $EnvPath)) {
            Write-Step 'Creating environment file'
            $EnvContent = @"
# DevBox environment
# Add your custom environment variables here

DefaultCPU=m68020
DefaultFPU=
"@
            Set-Content -Path $EnvPath -Value $EnvContent -Encoding UTF8
            Track-Creation $EnvPath 'file'
            Write-Success 'Created: .env'
        }
        else {
            Write-Step 'Backing up existing .env'
            $BackupPath = "$EnvPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $EnvPath $BackupPath
            Write-Success "Backup: $([System.IO.Path]::GetFileName($BackupPath))"
        }

        # Backup existing critical files ONLY if they will be overwritten
        # Currently, we only keep .env backup since others are skipped or created fresh
        # This preserves user data when adding DevBox to existing projects
        $FilesToBackup = @{
            '.env' = $EnvPath  # Already backed up above if exists
        }

        # Note: box.config.psd1 is NOT backed up (skipped if exists)
        # Note: README.md is NOT backed up (not modified in add mode)
        # Note: Makefile is NOT backed up (not generated in add mode)

        # Copy box.ps1 to root
        Write-Step 'Setting up box.ps1'
        $SourceBox = Join-Path $BoxDir 'box.ps1'
        $TargetBox = Join-Path $CurrentDir 'box.ps1'
        if (Test-Path $SourceBox) {
            Copy-Item $SourceBox $TargetBox -Force
            Track-Creation $TargetBox 'file'
            Write-Success 'Copied: box.ps1 to root'
        }
        else {
            Write-Host "  ⚠️ box.ps1 not found in .box/" -ForegroundColor Yellow
        }

        # VS Code integration (optional)
        Write-Host ''
        $VSCodeAnswer = Read-Host 'Configure VS Code integration? [y/n]'
        if ($VSCodeAnswer -eq 'y' -or $VSCodeAnswer -eq 'yes') {
            Write-Step 'Configuring VS Code'
            $VSCodeDir = Join-Path $CurrentDir '.vscode'
            New-Item -ItemType Directory -Path $VSCodeDir -Force | Out-Null
            Track-Creation $VSCodeDir 'directory'

            $SettingsPath = Join-Path $VSCodeDir 'settings.json'
            $SettingsContent = @"
{
  "terminal.integrated.env.windows": {
    "DEVBOX_ENV": ".env"
  },
  "terminal.integrated.env.linux": {
    "DEVBOX_ENV": ".env"
  },
  "terminal.integrated.env.osx": {
    "DEVBOX_ENV": ".env"
  },
  "powershell.codeFormatting.preset": "OTBS",
  "[powershell]": {
    "editor.defaultFormatter": "ms-vscode.powershell",
    "editor.formatOnSave": true
  }
}
"@
            Set-Content -Path $SettingsPath -Value $SettingsContent -Encoding UTF8
            Track-Creation $SettingsPath 'file'
            Write-Success 'Created: .vscode/settings.json'
        }

        Write-Title 'DevBox Added Successfully'
        Write-Host "  📁 Location: $CurrentDir" -ForegroundColor Cyan
        Write-Host "  🚀 Next steps:" -ForegroundColor Cyan
        Write-Host "    .\box.ps1 help" -ForegroundColor Gray
        Write-Host ''

        # Clear tracking on success
        $Script:CreatedItems = @()
    }
    catch {
        Write-Host ''
        Write-Error-Custom "Adding DevBox failed: $_"
        Rollback-Creation
        exit 1
    }
}

# ============================================================================
# MAIN
# ============================================================================

function Main {
    Write-Host ''
    Write-Host '🧙 DevBox Bootstrap v0.1.0' -ForegroundColor Cyan
    Write-Host ''

    try {
        # Check prerequisites
        Test-Prerequisites

        # Validate mode if specified
        if ($Mode -and $Mode -notin @('init', 'add')) {
            Write-Error-Custom "Invalid mode: $Mode (must be 'init' or 'add')"
            Show-RemoteInstallationError "Invalid mode parameter"
            exit 1
        }

        # Detect mode if not specified
        if (-not $Mode) {
            if ($ProjectName) {
                $Mode = 'init'
            }
            elseif (Test-Path '.box') {
                $Mode = 'add'
            }
            else {
                # Interactive mode
                Write-Host 'What would you like to do?' -ForegroundColor Yellow
                Write-Host "  [i] init - Create new project" -ForegroundColor White
                Write-Host "  [a] add  - Add DevBox to existing project" -ForegroundColor White
                $Choice = Read-Host 'Select'

                if ($Choice -eq 'i') {
                    $Mode = 'init'
                }
                elseif ($Choice -eq 'a') {
                    $Mode = 'add'
                }
                else {
                    Write-Error-Custom 'Invalid choice'
                    exit 1
                }
            }
        }

        # Execute mode
        switch ($Mode) {
            'init' {
                if (-not $ProjectName) {
                    $ProjectName = Read-Host 'Project name'
                    if (-not $ProjectName) {
                        Write-Error-Custom 'Project name is required'
                        exit 1
                    }
                }

                if (-not $Description) {
                    $Description = Read-Host 'Description (optional)'
                }

                Initialize-NewProject -ProjectName $ProjectName -Description $Description -VSCode:$UseVSCode
            }
            'add' {
                Add-ToExistingProject
            }
        }

        Write-Host ''
    }
    catch {
        Write-Host ''
        Write-Error-Custom "Bootstrap failed: $_"
        Show-RemoteInstallationError $_
        exit 1
    }
}

# Run main
Main
