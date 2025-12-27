<#
.SYNOPSIS
    DevBox - Unified Development Workspace Manager

.DESCRIPTION
    Compiled from modular sources by build-box.ps1

.NOTES
    Compilation Date: 2025-12-27 02:09:14
    Source Modules: 16
    Build System: Feature 001 - Compilation System
#>

<#
.SYNOPSIS
    ApolloDevBox Development Environment Setup

.DESCRIPTION
    Manages the development environment for AmigaOS cross-compilation.

.PARAMETER Command
    The command to execute: install, uninstall, env, pkg, help

.EXAMPLE
    .\box.ps1                    # Install (default)
    .\box.ps1 install            # Install all
    .\box.ps1 uninstall          # Uninstall environment
    .\box.ps1 env list           # List environment variables
    .\box.ps1 env reset          # Regenerate env files
    .\box.ps1 env add KEY=VALUE  # Add environment variable
    .\box.ps1 pkg list           # List packages
    .\box.ps1 pkg update         # Update packages
    .\box.ps1 help               # Show help

.NOTES
    Author: Vincent Buzzano (ReddoC)
    Date: December 2025
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "uninstall", "env", "pkg", "template", "help", "")]
    [string]$Command = "install",

    [Parameter(Position = 1)]
    [string]$SubCommand = "",

    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$Args,

    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Quick Help (before loading config)
# ============================================================================

function Show-QuickHelp {
    Write-Host ""
    Write-Host "Usage: setup.ps1 [command] [subcommand]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  install          Install all dependencies (default)" -ForegroundColor White
    Write-Host "  uninstall        Remove all generated files (back to factory state)" -ForegroundColor White
    Write-Host "  env              Manage environment variables" -ForegroundColor White
    Write-Host "  pkg              Manage packages" -ForegroundColor White
    Write-Host "  template         Manage template generation" -ForegroundColor White
    Write-Host "  help             Show this help" -ForegroundColor White
    Write-Host ""
    Write-Host "Env subcommands:" -ForegroundColor Yellow
    Write-Host "  env list         List all environment variables" -ForegroundColor White
    Write-Host "  env update       Regenerate .env file" -ForegroundColor White
    Write-Host ""
    Write-Host "Pkg subcommands:" -ForegroundColor Yellow
    Write-Host "  pkg list         List all packages with status" -ForegroundColor White
    Write-Host "  pkg update       Update/install packages interactively" -ForegroundColor White
    Write-Host ""
    Write-Host "Template subcommands:" -ForegroundColor Yellow
    Write-Host "  template update  Regenerate all templates" -ForegroundColor White
    Write-Host "  template apply <name>  Regenerate specific template" -ForegroundColor White
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  box env update           # Regenerate all templates from .env and config" -ForegroundColor Gray
    Write-Host "  box template apply Makefile  # Regenerate only Makefile" -ForegroundColor Gray
    Write-Host "  box template apply README.md # Regenerate only README.md" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Template system replaces {{TOKEN}} with values from .env and config files." -ForegroundColor Cyan
    Write-Host "Backups are created automatically before regeneration (.bak.timestamp)." -ForegroundColor Cyan
    Write-Host ""
}

if ($Help -or $Command -eq "help") {
    Show-QuickHelp
    exit 0
}

# ============================================================================
# Base Paths (defined here, used by init.ps1)
# ============================================================================

$_scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ((Split-Path $_scriptDir -Leaf) -eq 'scripts') {
    $script:BaseDir = Split-Path -Parent $_scriptDir
} else {
    $script:BaseDir = $_scriptDir
}
$script:SetupDir = Join-Path $BaseDir ".setup"
$script:SetupCommand = $Command

# ============================================================================
# Initialize (loads configs, functions, and derived paths)
# ============================================================================




# ══════════════════════════════════════════════════════════════════════════════
# COMPILED MODULES (injected by build-box.ps1 - replaces init.ps1 loading)
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/commands.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Command Functions (Invoke-*)
# ============================================================================

function Invoke-Install {
    # Run wizard if config doesn't exist
    if ($NeedsWizard) {
        if (-not (Invoke-ConfigWizard)) {
            return
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "  $($Config.Project.Name) Setup" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta

    # Run install script if exists
    $installScript = Join-Path $SetupDir "install.ps1"
    if (Test-Path $installScript) {
        & $installScript
    } else {
        # Inline install
        Create-Directories
        Ensure-SevenZip

        # T035: Try/catch wrapper for continue-on-error (FR-016)
        foreach ($pkg in $AllPackages) {
            try {
                Process-Package $pkg
            } catch {
                Write-Err "Failed to process $($pkg.Name): $_"
                Write-Info "Continuing with remaining packages..."
            }
        }

        Cleanup-Temp
        Setup-Makefile
        Generate-AllEnvFiles

        Show-InstallComplete
    }
}

function Invoke-Uninstall {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  Uninstall Environment" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow

    $uninstallScript = Join-Path $SetupDir "uninstall.ps1"
    if (Test-Path $uninstallScript) {
        & $uninstallScript
    } else {
        Do-Uninstall
    }
}

function Invoke-Env {
    param([string]$Sub, [string[]]$Params)

    switch ($Sub) {
        "list" {
            Show-EnvList
        }
        "update" {
            Generate-AllEnvFiles
            Write-Host "[OK] .env updated" -ForegroundColor Green
        }
        default {
            Write-Host "Unknown env subcommand: $Sub" -ForegroundColor Red
            Write-Host "Use: list, update" -ForegroundColor Gray
            exit 1
        }
    }
}

function Invoke-Pkg {
    param([string]$Sub)

    switch ($Sub) {
        "list" {
            Show-PackageList
        }
        "update" {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host "  Update Packages" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan

            Ensure-SevenZip

            # T035: Try/catch wrapper for continue-on-error
            foreach ($pkg in $AllPackages) {
                try {
                    Process-Package $pkg
                } catch {
                    Write-Err "Failed to process $($pkg.Name): $_"
                    Write-Info "Continuing with remaining packages..."
                }
            }

            # Only update env files, not Makefile
            Generate-AllEnvFiles

            Write-Host ""
            Write-Host "[OK] Packages updated" -ForegroundColor Green
        }
        default {
            Write-Host " Unknown pkg subcommand: $Sub" -ForegroundColor Red
            Write-Host "Use: list, update" -ForegroundColor Gray
            exit 1
        }
    }
}

# ============================================================================
# Template Commands
# ============================================================================

function Invoke-EnvUpdate {
    <#
    .SYNOPSIS
        Regenerate all template files from current environment

    .DESCRIPTION
        Regenerates Makefile, README.md and other template-based files
        using current values from .env and box.config.psd1.

    .EXAMPLE
        box env update
    #>

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Updating Templates" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Verbose info
    if ($VerbosePreference -eq 'Continue') {
        Write-Verbose "Template directory: .box/templates/"
        Write-Verbose "Variable sources: .env, box.config.psd1"
    }

    # Load template variables
    $variables = Merge-TemplateVariables

    if ($VerbosePreference -eq 'Continue' -and $variables.Count -gt 0) {
        Write-Verbose "Loaded $($variables.Count) variables:"
        foreach ($key in ($variables.Keys | Sort-Object)) {
            Write-Verbose "  $key = $($variables[$key])"
        }
    }

    if ($variables.Count -eq 0) {
        Write-Host "  [WARN] No variables found in .env or box.config.psd1" -ForegroundColor Yellow
    }

    # Get available templates
    $templates = Get-AvailableTemplates -TemplateDir '.box/templates'

    if ($templates.Count -eq 0) {
        Write-Host "  [INFO] No templates found in .box/templates/" -ForegroundColor Cyan
        return
    }

    $successCount = 0
    $failCount = 0

    foreach ($template in $templates) {
        $outputPath = $template

        # Find the actual template file - search for *.template and *.template.*
        # Pattern: For "README.md", search for "README.template.md" or "README.template"
        # Pattern: For "Makefile", search for "Makefile.template" or "Makefile.template.*"

        $actualTemplate = $null

        # Try: output_name.template (e.g., Makefile.template)
        if (Test-Path ".box/templates/$template.template" -PathType Leaf) {
            $actualTemplate = Get-Item ".box/templates/$template.template"
        }
        else {
            # Try: output_name_without_ext.template.ext (e.g., README.template.md)
            $templateWithExt = ".box/templates/$($template -split '\.' | Select-Object -First 1).template.$($template -split '\.' | Select-Object -Last 1)"
            if (Test-Path $templateWithExt -PathType Leaf) {
                $actualTemplate = Get-Item $templateWithExt
            }
        }

        if (-not $actualTemplate) {
            Write-Host "  [!] Template file not found for: $template" -ForegroundColor Yellow
            $failCount++
            continue
        }
        $templatePath = $actualTemplate.FullName

        Write-Host "  [*] Processing: $template..." -ForegroundColor White

        if ($VerbosePreference -eq 'Continue') {
            Write-Verbose "Template file: $templatePath"
            Write-Verbose "Output file: $outputPath"
        }

        try {
            # Validate file size
            if (-not (Test-TemplateFileSize -FilePath $templatePath)) {
                $failCount++
                continue
            }

            # Validate encoding
            if (-not (Test-FileEncoding -FilePath $templatePath)) {
                Write-Host "    [WARN] Template may not be UTF-8 encoded: $template" -ForegroundColor Yellow
            }

            # Read template
            $content = Get-Content $templatePath -Raw -Encoding UTF8

            # Process tokens
            $processed = Process-Template -TemplateContent $content -Variables $variables -TemplateName $template

            # Add generation header based on file type
            $fileType = if ($template -like '*.md') { 'markdown' } elseif ($template -eq 'Makefile*') { 'makefile' } else { 'generic' }
            $header = New-GenerationHeader -FileType $fileType
            $output = $header + "`n`n" + $processed

            # Backup existing file if exists
            if (Test-Path $outputPath) {
                $backupPath = Backup-File -FilePath $outputPath
                if ($backupPath) {
                    Write-Host "    [BKP] Backed up: $(Split-Path $backupPath -Leaf)" -ForegroundColor Gray
                    if ($VerbosePreference -eq 'Continue') {
                        Write-Verbose "Backup created: $backupPath"
                    }
                }
            }

            # Write generated file
            Set-Content -Path $outputPath -Value $output -Encoding UTF8 -Force
            Write-Host "    [OK] Generated: $outputPath" -ForegroundColor Green
            if ($VerbosePreference -eq 'Continue') {
                Write-Verbose "Written $($output.Length) characters to $outputPath"
            }
            $successCount++
        }
        catch {
            Write-Host "    [ERR] Error: $_" -ForegroundColor Red
            $failCount++
        }
    }

    Write-Host ""
    Write-Host "Summary: $successCount generated" -ForegroundColor Green
    if ($failCount -gt 0) {
        Write-Host "         $failCount failed" -ForegroundColor Red
    }
}

function Invoke-TemplateApply {
    <#
    .SYNOPSIS
        Regenerate a single template file

    .DESCRIPTION
        Regenerates one specific template-based file using current
        environment values.

    .PARAMETER Template
        Template name to apply (e.g., 'Makefile', 'README.md')

    .EXAMPLE
        box template apply Makefile
    #>
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Template
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Applying Template: $Template" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if ($VerbosePreference -eq 'Continue') {
        Write-Verbose "Template name: $Template"
    }

    # Normalize template name (add .template if missing)
    if (-not $Template.EndsWith('.template')) {
        $templatePath = ".box/templates/$Template.template"
        $outputPath = $Template
    }
    else {
        $templatePath = ".box/templates/$Template"
        $outputPath = $Template -replace '\.template$', ''
    }

    # Check if template exists
    if (-not (Test-Path $templatePath)) {
        $available = Get-AvailableTemplates -TemplateDir '.box/templates'
        Write-Host "  [ERR] Template not found: $Template" -ForegroundColor Red
        Write-Host ""
        Write-Host "Available templates:" -ForegroundColor Yellow
        foreach ($t in $available) {
            Write-Host "  - $t" -ForegroundColor White
        }
        exit 1
    }

    try {
        # Load template variables
        $variables = Merge-TemplateVariables

        if ($VerbosePreference -eq 'Continue') {
            Write-Verbose "Loaded $($variables.Count) variables from .env and config"
            Write-Verbose "Template path: $templatePath"
            Write-Verbose "Output path: $outputPath"
        }

        # Validate file size
        if (-not (Test-TemplateFileSize -FilePath $templatePath)) {
            exit 1
        }

        # Validate encoding
        if (-not (Test-FileEncoding -FilePath $templatePath)) {
            Write-Host "  [WARN] Template may not be UTF-8 encoded" -ForegroundColor Yellow
        }

        # Read template
        $content = Get-Content $templatePath -Raw -Encoding UTF8

        # Process tokens
        Write-Host "  [*] Processing template..." -ForegroundColor White
        $processed = Process-Template -TemplateContent $content -Variables $variables -TemplateName $Template

        # Add generation header
        $fileType = if ($outputPath -like '*.md') { 'markdown' } elseif ($outputPath -like 'Makefile*') { 'makefile' } else { 'generic' }
        $header = New-GenerationHeader -FileType $fileType
        $output = $header + "`n`n" + $processed

        # Backup existing file if exists
        if (Test-Path $outputPath) {
            $backupPath = Backup-File -FilePath $outputPath
            if ($backupPath) {
                Write-Host "  [BKP] Backed up: $(Split-Path $backupPath -Leaf)" -ForegroundColor Gray
            }
        }

        # Write generated file
        Set-Content -Path $outputPath -Value $output -Encoding UTF8 -Force
        Write-Host "  [OK] Generated: $outputPath" -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERR] Error: $_" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/common.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Common Functions - State, Output, User Input, Config Merge
# ============================================================================

# ============================================================================
# Logging
# ============================================================================

function Write-PackageLog {
    <#
    .SYNOPSIS
    Writes a log message to the package installation log file.

    .DESCRIPTION
    Appends a timestamped log entry to the package installation log.
    Creates the log directory if it doesn't exist.

    .PARAMETER Message
    The message to log

    .PARAMETER LogPath
    Optional custom log path. If not specified, uses .box/logs/package-install.log

    .PARAMETER Level
    Log level: INFO, WARN, ERROR (default: INFO)

    .EXAMPLE
    Write-PackageLog -Message "Installing package: vbcc" -Level INFO
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [string]$LogPath,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    # Determine log file path
    if (-not $LogPath) {
        $logDir = Join-Path $BaseDir ".box\logs"
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $LogPath = Join-Path $logDir "package-install.log"
    }

    # Format log entry
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Append to log file
    try {
        Add-Content -Path $LogPath -Value $logEntry -Encoding UTF8
    }
    catch {
        # Silently fail if logging fails (don't block operations)
        Write-Verbose "Failed to write log: $_"
    }
}

# ============================================================================
# Configuration Merge
# ============================================================================

function Merge-Hashtable {
    param(
        [hashtable]$Base,
        [hashtable]$Override
    )

    $result = $Base.Clone()

    foreach ($key in $Override.Keys) {
        $overrideValue = $Override[$key]

        if ($result.ContainsKey($key)) {
            $baseValue = $result[$key]

            # Both are hashtables -> recursive merge
            if ($baseValue -is [hashtable] -and $overrideValue -is [hashtable]) {
                $result[$key] = Merge-Hashtable $baseValue $overrideValue
            }
            # Both are arrays -> concatenate (Override first for priority)
            elseif ($baseValue -is [array] -and $overrideValue -is [array]) {
                $result[$key] = $overrideValue + $baseValue
            }
            # Override replaces base
            else {
                $result[$key] = $overrideValue
            }
        }
        else {
            # New key from override
            $result[$key] = $overrideValue
        }
    }

    return $result
}

function Merge-Config {
    param(
        [hashtable]$SysConfig,
        [hashtable]$UserConfig
    )

    return Merge-Hashtable $SysConfig $UserConfig
}

# ============================================================================
# State Management
# ============================================================================

function Load-State {
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{ packages = @{} }
}

function Save-State {
    param([hashtable]$State)
    $State | ConvertTo-Json -Depth 10 | Out-File $StateFile -Encoding UTF8
}

function Get-PackageState {
    param([string]$Name)
    $state = Load-State
    if ($state.packages.ContainsKey($Name)) {
        return $state.packages[$Name]
    }
    return $null
}

function Set-PackageState {
    param(
        [string]$Name,
        [bool]$Installed,
        [array]$Files,
        [array]$Dirs,
        [hashtable]$Envs
    )
    $state = Load-State
    $state.packages[$Name] = @{
        installed = $Installed
        files = $Files
        dirs = if ($Dirs) { $Dirs } else { @() }
        envs = $Envs
        date = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    Save-State $state
}

function Remove-PackageState {
    param([string]$Name)
    $state = Load-State
    if ($state.packages.ContainsKey($Name)) {
        $state.packages.Remove($Name)
        Save-State $state
    }
}

# ============================================================================
# Output Functions
# ============================================================================

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Gray
}

function Write-Success {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Err {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

# ============================================================================
# User Input Functions
# ============================================================================

function Ask-YesNo {
    param(
        [string]$Question,
        [bool]$Default = $true
    )
    $defaultText = if ($Default) { "Y/n" } else { "y/N" }
    $response = Read-Host "$Question [$defaultText]"
    if ([string]::IsNullOrWhiteSpace($response)) { return $Default }
    return $response -match '^[Yy]'
}

function Ask-Choice {
    param(
        [string]$Question,
        [string]$Default = "S"
    )
    $response = Read-Host "$Question"
    if ([string]::IsNullOrWhiteSpace($response)) { return $Default.ToUpper() }
    return $response.Substring(0,1).ToUpper()
}

function Ask-String {
    param(
        [string]$Prompt,
        [string]$Default = "",
        [bool]$Required = $true
    )

    $defaultText = if ($Default) { " [$Default]" } else { "" }
    $response = Read-Host "    $Prompt$defaultText"

    if ([string]::IsNullOrWhiteSpace($response)) {
        if ($Default) { return $Default }
        if ($Required) {
            Write-Err "Value is required!"
            exit 1
        }
        return ""
    }
    return $response
}

function Ask-Number {
    param(
        [string]$Prompt,
        [int]$Default = 0,
        [int]$Min = [int]::MinValue,
        [int]$Max = [int]::MaxValue
    )

    $defaultText = if ($Default -ne 0) { " [$Default]" } else { "" }
    $response = Read-Host "    $Prompt$defaultText"

    if ([string]::IsNullOrWhiteSpace($response)) {
        return $Default
    }

    $number = 0
    if (-not [int]::TryParse($response, [ref]$number)) {
        Write-Err "Invalid number: $response"
        exit 1
    }

    if ($number -lt $Min -or $number -gt $Max) {
        Write-Err "Number must be between $Min and $Max"
        exit 1
    }

    return $number
}

function Ask-Path {
    param(
        [string]$Prompt,
        [string]$Default = "",
        [bool]$MustExist = $true
    )

    $path = Ask-String -Prompt $Prompt -Default $Default -Required $MustExist

    if ([string]::IsNullOrWhiteSpace($path)) { return "" }

    # Convert to absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $BaseDir $path
    }

    if ($MustExist -and -not (Test-Path $path)) {
        Write-Err "Path does not exist: $path"
        exit 1
    }

    return $path
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/constants.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Constants and helper functions for inc/ modules
# ============================================================================
# This file provides small helpers to avoid repeating filenames and to allow
# dot-sourcing inc files without typing the .ps1 extension everywhere.
# ============================================================================

# Expected: $IncDir is set by the caller (functions.ps1 loader)

# Common filenames (can be referenced by other scripts)
$script:ConfigFileName = 'config.psd1'
$script:UserConfigFileName = 'setup.config.psd1'
$script:MakefileTemplateName = '.setup/template/Makefile.template'

function Get-IncPath {
    param([string]$Name)
    if (-not $script:IncDir) {
        throw "Get-IncPath: `$script:IncDir is not set"
    }
    return Join-Path $script:IncDir ("$Name.ps1")
}

function Source-Inc {
    param([string]$Name)
    $path = Get-IncPath $Name
    if (-not (Test-Path $path)) {
        throw "Source-Inc: file not found: $path"
    }
    . $path
}

# Convenience: dot-source by relative path without extension
function Source-Rel {
    param([string]$RelativePath)
    $full = Join-Path $script:IncDir $RelativePath
    if (-not $full.EndsWith('.ps1')) { $full += '.ps1' }
    if (-not (Test-Path $full)) { throw "Source-Rel: not found: $full" }
    . $full
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/directories.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Directory Management Functions
# ============================================================================

function Create-Directories {
    Write-Step "Creating project directories"
    
    foreach ($dir in $Config.Directories) {
        $fullPath = Join-Path $BaseDir $dir
        if (-not (Test-Path $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
            Write-Info "Created: $dir/"
        }
    }
    
    Write-Success "Directories ready"
}

function Cleanup-Temp {
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "Cleaned up temp/"
    }
}

function Do-Uninstall {
    Write-Step "Removing installed packages and generated files"
    
    $state = Load-State
    $removedCount = 0
    
    # Remove installed packages (files and dirs tracked in state)
    foreach ($pkgName in @($state.packages.Keys)) {
        $pkgState = $state.packages[$pkgName]
        if ($pkgState.installed) {
            Write-Info "Removing $pkgName..."
            
            # First remove files
            if ($pkgState.files) {
                foreach ($file in $pkgState.files) {
                    if (Test-Path $file) {
                        Remove-Item $file -Recurse -Force -ErrorAction SilentlyContinue
                        $removedCount++
                    }
                }
            }
            
            # Then remove created directories (if empty)
            if ($pkgState.dirs) {
                foreach ($dir in $pkgState.dirs) {
                    Remove-DirectoryIfEmpty -Path $dir
                }
            }
            
            # Clean empty parent directories (bottom-up from files)
            if ($pkgState.files) {
                foreach ($file in $pkgState.files) {
                    $parent = Split-Path $file -Parent
                    Remove-EmptyParents -Path $parent
                }
            }
        }
        Remove-PackageState $pkgName
    }
    
    # Remove generated env files
    @(".env", ".env.custom") | ForEach-Object {
        $path = Join-Path $BaseDir $_
        if (Test-Path $path) {
            Remove-Item $path -Force
            Write-Info "Removed $_"
            $removedCount++
        }
    }
    
    # Remove .setup internal directories (cache, tools)
    @(".setup/cache", ".setup/tools") | ForEach-Object {
        $path = Join-Path $BaseDir $_
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force
            Write-Info "Removed $_/"
            $removedCount++
        }
    }
    
    # Always remove build and dist directories
    @("build", "dist") | ForEach-Object {
        $path = Join-Path $BaseDir $_
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force
            Write-Info "Removed $_/"
            $removedCount++
        }
    }
    
    # Remove state file last
    $statePath = Join-Path $BaseDir ".setup/state.json"
    if (Test-Path $statePath) {
        Remove-Item $statePath -Force
        Write-Info "Removed .setup/state.json"
    }
    
    if ($removedCount -eq 0) {
        Write-Info "Nothing to remove"
    }
    
    Write-Success "Uninstall complete"
    Write-Host ""
}

# Remove a directory only if it's empty
function Remove-DirectoryIfEmpty {
    param([string]$Path)
    
    if (Test-Path $Path) {
        $items = Get-ChildItem $Path -Force -ErrorAction SilentlyContinue
        if ($items.Count -eq 0) {
            Remove-Item $Path -Force -ErrorAction SilentlyContinue
        }
    }
}

# Remove empty parent directories up to BaseDir
function Remove-EmptyParents {
    param([string]$Path)
    
    while ($Path -and $Path -ne $BaseDir -and (Test-Path $Path)) {
        $items = Get-ChildItem $Path -Force -ErrorAction SilentlyContinue
        if ($items.Count -eq 0) {
            Remove-Item $Path -Force -ErrorAction SilentlyContinue
            $Path = Split-Path $Path -Parent
        } else {
            break
        }
    }
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/download.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Download Functions
# ============================================================================

function Invoke-WithRetry {
    <#
    .SYNOPSIS
    Executes a script block with retry logic and exponential backoff.

    .DESCRIPTION
    Retries a script block up to a specified number of times with exponential backoff
    between attempts. Useful for network operations that may fail temporarily.

    .PARAMETER ScriptBlock
    The script block to execute

    .PARAMETER MaxAttempts
    Maximum number of retry attempts (default: 3)

    .PARAMETER InitialDelaySeconds
    Initial delay in seconds before first retry (default: 1)

    .EXAMPLE
    Invoke-WithRetry -ScriptBlock { Invoke-WebRequest -Uri $url } -MaxAttempts 3
    #>
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,

        [int]$MaxAttempts = 3,

        [int]$InitialDelaySeconds = 1
    )

    $attempt = 1
    $delay = $InitialDelaySeconds

    while ($attempt -le $MaxAttempts) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                throw
            }

            Write-Info "Attempt $attempt failed. Retrying in $delay seconds..."
            Start-Sleep -Seconds $delay

            # Exponential backoff: 1s, 2s, 4s, 8s...
            $delay = $delay * 2
            $attempt++
        }
    }
}

function Test-FileHash {
    <#
    .SYNOPSIS
    Verifies the SHA256 hash of a downloaded file.

    .DESCRIPTION
    Computes the SHA256 hash of a file and compares it to the expected hash value.
    Returns $true if hashes match, $false otherwise.

    .PARAMETER FilePath
    Path to the file to verify

    .PARAMETER ExpectedHash
    Expected SHA256 hash value (case-insensitive)

    .OUTPUTS
    Returns $true if hash matches, $false if mismatch or error

    .EXAMPLE
    if (Test-FileHash -FilePath $file -ExpectedHash $hash) { ... }
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,

        [Parameter(Mandatory=$true)]
        [string]$ExpectedHash
    )

    if (-not (Test-Path $FilePath)) {
        Write-Err "File not found: $FilePath"
        return $false
    }

    try {
        $actualHash = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash

        if ($actualHash -eq $ExpectedHash) {
            Write-Info "Hash verified: OK"
            return $true
        }
        else {
            Write-Err "Hash mismatch!"
            Write-Err "Expected: $ExpectedHash"
            Write-Err "Actual:   $actualHash"
            return $false
        }
    }
    catch {
        Write-Err "Hash verification failed: $_"
        return $false
    }
}

function Download-File {
    <#
    .SYNOPSIS
    Downloads a file from a URL with support for different source types.

    .DESCRIPTION
    Downloads a file with automatic retry logic and special handling for SourceForge redirects.
    Supports HTTP, HTTPS, and SourceForge download links.

    .PARAMETER Url
    The URL to download from

    .PARAMETER FileName
    The filename to save as in the cache directory

    .PARAMETER SourceType
    The type of source: 'http' (default), 'sourceforge'

    .OUTPUTS
    Returns the path to the downloaded file, or $null on failure

    .EXAMPLE
    Download-File -Url $url -FileName "tool.zip" -SourceType "sourceforge"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Url,

        [Parameter(Mandatory=$true)]
        [string]$FileName,

        [ValidateSet('http', 'sourceforge')]
        [string]$SourceType = 'http'
    )

    # Ensure cache directory exists
    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    $outPath = Join-Path $CacheDir $FileName

    if (Test-Path $outPath) {
        Write-Info "Already downloaded: $FileName"
        return $outPath
    }

    Write-Info "Downloading $FileName..."

    # T020/T037: Progress reporting for SourceForge
    if ($SourceType -eq 'sourceforge') {
        Write-Info "[1/2] Following SourceForge redirects..."
    }

    # T019: Integrate Invoke-WithRetry for downloads
    try {
        $downloadResult = Invoke-WithRetry -ScriptBlock {
            $ProgressPreference = 'SilentlyContinue'

            # T018: SourceForge redirect handling - needs two-step process
            if ($SourceType -eq 'sourceforge') {
                # Step 1: Get the download page to extract real download URL
                Write-Info "[1/2] Fetching SourceForge download page..."
                $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 5 -AllowInsecureRedirect

                # Extract the real download URL from meta refresh or download link
                $realUrl = $null
                if ($response.Content -match 'url=([^"]+lha[^"]+\.zip[^"]*)"') {
                    $realUrl = $Matches[1]
                }
                elseif ($response.Content -match 'href="(https://downloads\.sourceforge\.net[^"]+)"') {
                    $realUrl = $Matches[1]
                }

                if ($realUrl) {
                    # Decode HTML entities
                    $realUrl = $realUrl -replace '&amp;', '&'
                    Write-Info "[2/2] Downloading binary from: $($realUrl.Substring(0, [Math]::Min(80, $realUrl.Length)))..."

                    # Step 2: Download from real URL
                    Invoke-WebRequest -Uri $realUrl -OutFile $outPath -UseBasicParsing -MaximumRedirection 5 -AllowInsecureRedirect
                }
                else {
                    throw "Could not extract download URL from SourceForge page"
                }
            }
            else {
                # Standard HTTP download
                $webParams = @{
                    Uri = $Url
                    OutFile = $outPath
                    UseBasicParsing = $true
                }

                Invoke-WebRequest @webParams
            }

            $ProgressPreference = 'Continue'
        } -MaxAttempts 3 -InitialDelaySeconds 1

        $size = [math]::Round((Get-Item $outPath).Length / 1KB, 1)
        Write-Success "Downloaded: $size KB"
        return $outPath
    }
    catch {
        # T021: SourceForge-specific error messages
        if ($SourceType -eq 'sourceforge') {
            Write-Err "SourceForge download failed: $_"
            Write-Err "Tip: Verify the URL is correct. SourceForge links may change."
            Write-Err "Visit the project page to get the latest download link."
        }
        else {
            Write-Err "Download failed: $_"
        }

        # Clean up partial download
        if (Test-Path $outPath) {
            Remove-Item $outPath -Force -ErrorAction SilentlyContinue
        }

        return $null
    }
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/envs.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Environment Files Generation
# ============================================================================

function Generate-DotEnvFile {
    $envPath = Join-Path $BaseDir ".env"
    $state = Load-State
    
    $lines = @(
        "# Generated by setup.ps1 - DO NOT EDIT"
        "# Re-run 'setup.ps1 env update' to regenerate"
        "# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ""
        "# Project Settings"
    )
    
    # Project settings from merged config
    if ($Config.Project) {
        if ($Config.Project.Name) {
            $lines += "PROGRAM_NAME=$($Config.Project.Name)"
        }
        if ($Config.Project.DefaultCPU) {
            $lines += "DEFAULT_CPU=$($Config.Project.DefaultCPU)"
        }
        if ($Config.Project.DefaultFPU) {
            $lines += "DEFAULT_FPU=$($Config.Project.DefaultFPU)"
        }
        if ($Config.Project.Version) {
            $lines += "VERSION=$($Config.Project.Version)"
        }
    }
    
    $lines += ""
    $lines += "# Project Paths"
    
    # Paths from merged config
    if ($Config.Paths) {
        foreach ($key in $Config.Paths.Keys) {
            $value = $Config.Paths[$key]
            $envKey = ($key -creplace '([A-Z])', '_$1').ToUpper().TrimStart('_')
            $lines += "$envKey=$value"
        }
    }
    
    $lines += ""
    $lines += "# Package Paths"
    
    foreach ($pkgName in $state.packages.Keys) {
        $pkg = $state.packages[$pkgName]
        if ($pkg.envs) {
            foreach ($envName in $pkg.envs.Keys) {
                $envValue = $pkg.envs[$envName]
                $lines += "$envName=$envValue"
            }
        }
    }
    
    # Custom envs from config (Envs section)
    if ($Config.Envs -and $Config.Envs.Count -gt 0) {
        $lines += ""
        $lines += "# Custom Variables"
        foreach ($key in $Config.Envs.Keys) {
            $value = $Config.Envs[$key]
            $lines += "$key=$value"
        }
    }
    
    $lines -join "`n" | Out-File $envPath -Encoding UTF8 -NoNewline
    Write-Success "Generated .env"
}

function Generate-AllEnvFiles {
    Generate-DotEnvFile
}

# ============================================================================
# Env Commands
# ============================================================================

function Show-EnvList {
    Write-Host ""
    Write-Host "Environment Variables:" -ForegroundColor Cyan
    Write-Host ""
    
    $state = Load-State
    
    # Project settings
    Write-Host "  [Project Settings]" -ForegroundColor Yellow
    if ($Config.Project) {
        if ($Config.Project.Name) {
            Write-Host "    PROGRAM_NAME = $($Config.Project.Name)" -ForegroundColor White
        }
        if ($Config.Project.DefaultCPU) {
            Write-Host "    DEFAULT_CPU = $($Config.Project.DefaultCPU)" -ForegroundColor White
        }
        if ($Config.Project.DefaultFPU) {
            Write-Host "    DEFAULT_FPU = $($Config.Project.DefaultFPU)" -ForegroundColor White
        }
        if ($Config.Project.Version) {
            Write-Host "    VERSION = $($Config.Project.Version)" -ForegroundColor White
        }
    }
    
    # Paths
    Write-Host ""
    Write-Host "  [Project Paths]" -ForegroundColor Yellow
    if ($Config.Paths) {
        foreach ($key in $Config.Paths.Keys) {
            $value = $Config.Paths[$key]
            $envKey = ($key -creplace '([A-Z])', '_$1').ToUpper().TrimStart('_')
            Write-Host "    $envKey = $value" -ForegroundColor White
        }
    }
    
    # Package envs
    Write-Host ""
    Write-Host "  [Package Paths]" -ForegroundColor Yellow
    foreach ($pkgName in $state.packages.Keys) {
        $pkg = $state.packages[$pkgName]
        if ($pkg.envs -and $pkg.envs.Count -gt 0) {
            foreach ($envName in $pkg.envs.Keys) {
                $envValue = $pkg.envs[$envName]
                Write-Host "    $envName = $envValue" -ForegroundColor White -NoNewline
                Write-Host " ($pkgName)" -ForegroundColor DarkGray
            }
        }
    }
    
    # Custom envs from config
    if ($Config.Envs -and $Config.Envs.Count -gt 0) {
        Write-Host ""
        Write-Host "  [Custom Variables]" -ForegroundColor Yellow
        foreach ($key in $Config.Envs.Keys) {
            $value = $Config.Envs[$key]
            Write-Host "    $key = $value" -ForegroundColor White
        }
    }
    
    Write-Host ""
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/extract.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Extract Functions
# ============================================================================

function Test-ExtractionTool {
    <#
    .SYNOPSIS
    Checks if required extraction tool is available.

    .DESCRIPTION
    Verifies that the extraction tool needed for a specific archive format
    is available in the system PATH or as a known executable.

    .PARAMETER ToolType
    The type of tool to check: 'git', '7z', 'lha', 'tar'

    .OUTPUTS
    Returns $true if tool is available, $false otherwise

    .EXAMPLE
    if (Test-ExtractionTool -ToolType '7z') { ... }
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('git', '7z', 'lha', 'tar')]
        [string]$ToolType
    )

    $toolCommand = switch ($ToolType) {
        'git' { 'git' }
        '7z' { '7z' }
        'lha' { 'lha' }
        'tar' { 'tar' }
    }

    try {
        $null = Get-Command $toolCommand -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Parse-ExtractRule {
    param([string]$Rule)

    # Format: TYPE:pattern:destination[:ENV_VAR]
    $parts = $Rule -split ":"

    if ($parts.Count -lt 3) {
        Write-Warn "Invalid rule format: $Rule"
        return $null
    }

    return @{
        Type = $parts[0]
        Pattern = $parts[1]
        Destination = $parts[2]
        EnvVar = if ($parts.Count -ge 4) { $parts[3] } else { $null }
    }
}

function Copy-WithPattern {
    param(
        [string]$Source,
        [string]$Pattern,
        [string]$Destination
    )

    $destPath = Join-Path $BaseDir $Destination
    $destIsFile = -not $Destination.EndsWith("/") -and [System.IO.Path]::HasExtension($Destination)

    $createdDirs = @()

    if ($destIsFile) {
        $destDir = Split-Path $destPath -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            $createdDirs += $destDir
        }
    } else {
        if (-not (Test-Path $destPath)) {
            New-Item -ItemType Directory -Path $destPath -Force | Out-Null
            $createdDirs += $destPath
        }
    }

    $copiedFiles = @()

    # Handle "dir/*" pattern
    if ($Pattern -match '^(.+)/\*$') {
        $subDir = $Matches[1]
        $srcPath = Join-Path $Source $subDir
        if (Test-Path $srcPath) {
            Get-ChildItem -Path $srcPath -Force | ForEach-Object {
                $itemDest = Join-Path $destPath $_.Name
                if ($_.PSIsContainer) {
                    Copy-Item $_.FullName -Destination $itemDest -Recurse -Force
                } else {
                    Copy-Item $_.FullName -Destination $itemDest -Force
                }
                $copiedFiles += $itemDest
            }
            Write-Info "Copied $subDir/* -> $Destination"
        }
    }
    # Handle "**/*.ext" or "**/filename" pattern
    elseif ($Pattern -match '^\*\*/(.+)$') {
        $filePattern = $Matches[1]
        Get-ChildItem -Path $Source -Recurse -Filter $filePattern -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($destIsFile) {
                Copy-Item $_.FullName -Destination $destPath -Force
                $copiedFiles += $destPath
            } else {
                $target = Join-Path $destPath $_.Name
                Copy-Item $_.FullName -Destination $target -Force
                $copiedFiles += $target
            }
            Write-Info "Copied $($_.Name)"
        }
    }
    # Handle "*" pattern
    elseif ($Pattern -eq "*") {
        Get-ChildItem -Path $Source -Force | ForEach-Object {
            $itemDest = Join-Path $destPath $_.Name
            if ($_.PSIsContainer) {
                Copy-Item $_.FullName -Destination $itemDest -Recurse -Force
            } else {
                Copy-Item $_.FullName -Destination $itemDest -Force
            }
            $copiedFiles += $itemDest
        }
        Write-Info "Copied all -> $Destination"
    }
    # Specific file pattern
    else {
        Get-ChildItem -Path $Source -Recurse -Filter $Pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($destIsFile) {
                Copy-Item $_.FullName -Destination $destPath -Force
                $copiedFiles += $destPath
            } else {
                $target = Join-Path $destPath $_.Name
                Copy-Item $_.FullName -Destination $target -Force
                $copiedFiles += $target
            }
            Write-Info "Copied $($_.Name)"
        }
    }

    return @{
        Files = $copiedFiles
        Dirs = $createdDirs
    }
}

function Extract-Package {
    param(
        [string]$Archive,
        [string]$Name,
        [string]$ArchiveType,
        [array]$ExtractRules
    )

    $tempExtract = Join-Path $TempDir $Name

    # Clean temp
    if (Test-Path $tempExtract) {
        Remove-Item $tempExtract -Recurse -Force
    }
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null

    # Extract
    Write-Info "Extracting $ArchiveType archive..."
    $result = & $SevenZipExe x $Archive -o"$tempExtract" -y 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Extraction warning: $result"
    }

    $allFiles = @()
    $allDirs = @()
    $allEnvs = @{}

    # T037: Progress for extract rules
    $totalRules = $ExtractRules.Count
    $currentRule = 0

    # Process each extract rule - save state after each rule for crash recovery
    foreach ($rule in $ExtractRules) {
        $currentRule++
        $parsed = Parse-ExtractRule $rule
        if (-not $parsed) { continue }

        Write-Info "[$currentRule/$totalRules] Copying $($parsed.Pattern) to $($parsed.Destination)..."
        $copyResult = Copy-WithPattern -Source $tempExtract -Pattern $parsed.Pattern -Destination $parsed.Destination
        $allFiles += $copyResult.Files
        $allDirs += $copyResult.Dirs

        if ($parsed.EnvVar) {
            $allEnvs[$parsed.EnvVar] = $parsed.Destination
        }

        # Save state incrementally after each rule (crash recovery)
        Set-PackageState -Name $Name -Installed $true -Files $allFiles -Dirs $allDirs -Envs $allEnvs
    }

    Write-Success "Extracted $($allFiles.Count) files, $($allDirs.Count) directories"

    # Cleanup
    Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

    return @{
        Files = $allFiles
        Dirs = $allDirs
        Envs = $allEnvs
    }
}

function Install-SingleFile {
    param(
        [string]$FilePath,
        [string]$Name,
        [array]$ExtractRules
    )

    $allFiles = @()
    $allDirs = @()
    $allEnvs = @{}

    foreach ($rule in $ExtractRules) {
        $parsed = Parse-ExtractRule $rule
        if (-not $parsed) { continue }

        $destPath = Join-Path $BaseDir $parsed.Destination

        if ([System.IO.Path]::HasExtension($parsed.Destination)) {
            $destDir = Split-Path $destPath -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                $allDirs += $destDir
            }
            Copy-Item $FilePath -Destination $destPath -Force
        } else {
            if (-not (Test-Path $destPath)) {
                New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                $allDirs += $destPath
            }
            $fileName = Split-Path $FilePath -Leaf
            $destPath = Join-Path $destPath $fileName
            Copy-Item $FilePath -Destination $destPath -Force
        }

        $allFiles += $destPath
        Write-Info "Copied to $($parsed.Destination)"

        if ($parsed.EnvVar) {
            $allEnvs[$parsed.EnvVar] = $parsed.Destination
        }

        # Save state incrementally after each rule (crash recovery)
        Set-PackageState -Name $Name -Installed $true -Files $allFiles -Dirs $allDirs -Envs $allEnvs
    }

    return @{
        Files = $allFiles
        Dirs = $allDirs
        Envs = $allEnvs
    }
}

function Get-EnvVarsFromRules {
    param([array]$ExtractRules)

    $envs = @{}
    foreach ($rule in $ExtractRules) {
        $parsed = Parse-ExtractRule $rule
        if ($parsed -and $parsed.EnvVar) {
            $envs[$parsed.EnvVar] = $null
        }
    }
    return $envs
}

function Ask-ManualEnvs {
    param(
        [array]$ExtractRules,
        [hashtable]$ExistingEnvs = @{}
    )

    $envs = @{}
    $needsInput = $false

    foreach ($rule in $ExtractRules) {
        $parsed = Parse-ExtractRule $rule
        if ($parsed -and $parsed.EnvVar) {
            if ($ExistingEnvs.ContainsKey($parsed.EnvVar) -and $ExistingEnvs[$parsed.EnvVar]) {
                $envs[$parsed.EnvVar] = $ExistingEnvs[$parsed.EnvVar]
                Write-Info "Using existing: $($parsed.EnvVar) = $($ExistingEnvs[$parsed.EnvVar])"
            } else {
                $needsInput = $true
            }
        }
    }

    if ($needsInput) {
        Write-Info "Please provide paths for required variables:"

        foreach ($rule in $ExtractRules) {
            $parsed = Parse-ExtractRule $rule
            if ($parsed -and $parsed.EnvVar -and -not $envs.ContainsKey($parsed.EnvVar)) {
                $path = Ask-Path $parsed.EnvVar
                if ($path.StartsWith($BaseDir)) {
                    $path = $path.Substring($BaseDir.Length + 1).Replace('\', '/')
                }
                $envs[$parsed.EnvVar] = $path
            }
        }
    }

    return $envs
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/functions.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# AmigaDevBox - Setup Functions Loader
# ============================================================================
# This file loads all modular function files
# DO NOT MODIFY - changes will be overwritten on updates
# ============================================================================

# Determine inc directory. Prefer $SetupDir if provided by the caller,
# otherwise fall back to script location.
if ($SetupDir) {
    $script:IncDir = Join-Path $SetupDir "inc"
} else {
    $script:IncDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Load all modules directly (dot-source must be at script level, not inside a function)
















# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/help.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Help Functions
# ============================================================================

function Show-Help {
    Write-Host ""
    Write-Host "Usage: setup.ps1 [command] [subcommand]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  install          Install all dependencies (default)" -ForegroundColor White
    Write-Host "  uninstall        Remove all generated files (back to factory state)" -ForegroundColor White
    Write-Host "  env              Manage environment variables" -ForegroundColor White
    Write-Host "  pkg              Manage packages" -ForegroundColor White
    Write-Host "  help             Show this help" -ForegroundColor White
    Write-Host ""
    Write-Host "Env subcommands:" -ForegroundColor Yellow
    Write-Host "  env list         List all environment variables" -ForegroundColor White
    Write-Host "  env update       Regenerate .env file" -ForegroundColor White
    Write-Host ""
    Write-Host "Pkg subcommands:" -ForegroundColor Yellow
    Write-Host "  pkg list         List all packages with status" -ForegroundColor White
    Write-Host "  pkg update       Update/install packages interactively" -ForegroundColor White
    Write-Host ""
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/init.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# AmigaDevBox - Initialization Module
# ============================================================================
# This file handles all setup initialization: paths, configs, and functions.
# Dot-source this from setup.ps1 to keep the main script clean.
# ============================================================================

# ============================================================================
# Constants (local to init, no $script: needed)
# ============================================================================

$CONFIG_FILENAME = 'config.psd1'
$USER_CONFIG_FILENAME = 'setup.config.psd1'
$STATE_FILENAME = '.setup/state.json'
$FUNCTIONS_LOADER = 'inc\functions.ps1'

# ============================================================================
# Derived Paths (BaseDir and SetupDir are set by caller)
# ============================================================================

$script:StateFile = Join-Path $BaseDir $STATE_FILENAME
$script:EnvFile = Join-Path $BaseDir ".env"

# ============================================================================
# Load Functions (before config loading - needed for Merge-Config)
# ============================================================================

$script:FunctionsLoader = Join-Path $SetupDir $FUNCTIONS_LOADER
if (-not (Test-Path $FunctionsLoader)) {
    Write-Host "Functions loader not found: $FunctionsLoader" -ForegroundColor Red
    exit 1
}
. $FunctionsLoader

# ============================================================================
# Configuration Loading
# ============================================================================

# Load system config
$script:SysConfigFile = Join-Path $SetupDir $CONFIG_FILENAME
if (-not (Test-Path $SysConfigFile)) {
    Write-Host "$CONFIG_FILENAME not found in .setup/" -ForegroundColor Red
    exit 1
}
$script:SysConfig = Import-PowerShellDataFile $SysConfigFile

# User config
$script:UserConfigFile = Join-Path $BaseDir $USER_CONFIG_FILENAME
$script:UserConfigTemplate = Join-Path $BaseDir $SysConfig.UserConfigTemplate

# Handle missing user config based on command
$script:SkipExecution = $false
$script:StateExists = Test-Path (Join-Path $BaseDir $STATE_FILENAME)

# Commands that require state (not install, not help)
if ($SetupCommand -in @("uninstall", "env", "pkg")) {
    if (-not $StateExists) {
        Write-Host ""
        Write-Host "No configuration found." -ForegroundColor Red
        Write-Host "Run 'setup' or 'setup install' first." -ForegroundColor Gray
        Write-Host ""
        $script:SkipExecution = $true
    }
}

# Load config if not skipping
if (-not $SkipExecution) {
    if (Test-Path $UserConfigFile) {
        $script:UserConfig = Import-PowerShellDataFile $UserConfigFile
        $script:Config = Merge-Config -SysConfig $SysConfig -UserConfig $UserConfig
    }
    elseif ($SetupCommand -eq "install" -or $SetupCommand -eq "") {
        # install: will run wizard later in Invoke-Install
        $script:UserConfig = @{}
        $script:Config = $SysConfig
        $script:NeedsWizard = $true
    }
    else {
        # Other commands without config but with state - use minimal config
        $script:UserConfig = @{}
        $script:Config = $SysConfig
    }
}

# ============================================================================
# Derived Paths (from merged config)
# ============================================================================

# Cache path (with override support)
$script:CacheDir = if ($Config.CachePath) { 
    if ([System.IO.Path]::IsPathRooted($Config.CachePath)) { $Config.CachePath } 
    else { Join-Path $BaseDir $Config.CachePath }
} else { 
    Join-Path $BaseDir $Config.SetupPaths.Cache 
}
$script:DownloadsDir = $CacheDir
$script:TempDir = Join-Path $CacheDir "temp"
$script:SetupToolsDir = Join-Path $BaseDir $Config.SetupPaths.Tools

# 7-Zip paths
$script:SevenZipExe = Join-Path $SetupToolsDir "7z.exe"
$script:SevenZipDll = Join-Path $SetupToolsDir "7z.dll"

# All packages (merged - UserConfig.Packages first for priority)
$script:AllPackages = if ($Config.Packages) { $Config.Packages } else { @() }



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/makefile.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Makefile Generation Functions
# ============================================================================

function Setup-Makefile {
    $templatePath = Join-Path $BaseDir $Config.MakefileTemplate
    $makefilePath = Join-Path $BaseDir "Makefile"
    
    if (-not (Test-Path $makefilePath)) {
        if (-not (Test-Path $templatePath)) {
            Write-Warn "Makefile.template not found at $($Config.MakefileTemplate), skipping Makefile creation"
            return
        }
        
        Copy-Item $templatePath $makefilePath -Force
        Write-Success "Created Makefile from template"
    } else {
        Write-Info "Makefile already exists (not modified)"
    }
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/packages.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Package Management Functions
# ============================================================================

function Test-PackageInstalled {
    <#
    .SYNOPSIS
    Checks if a package is already installed via system, vendor, or environment variable.

    .DESCRIPTION
    Detection priority:
    1. DetectEnv - Environment variable exists (fastest)
    2. DetectFile - File found in system PATH
    3. DetectFile - File found in vendor/tools/
    4. DetectCommand - Command executes successfully
    5. Package state - Previously installed by box

    .PARAMETER Package
    Hashtable with package definition including DetectEnv, DetectFile, DetectCommand properties

    .OUTPUTS
    PSCustomObject with properties: Installed (bool), Source (string), Path (string)
    #>
    param([hashtable]$Package)

    # Priority 1: Environment variable
    if ($Package.DetectEnv) {
        $envValue = [System.Environment]::GetEnvironmentVariable($Package.DetectEnv)
        if ($envValue) {
            Write-Info "Found $($Package.Name) via `$env:$($Package.DetectEnv): $envValue"
            return @{
                Installed = $true
                Source = "env"
                Path = $envValue
            }
        }
    }

    # Priority 2: File in system PATH
    if ($Package.DetectFile) {
        $systemCmd = Get-Command $Package.DetectFile -ErrorAction SilentlyContinue
        if ($systemCmd) {
            Write-Info "Found system $($Package.Name): $($systemCmd.Source)"
            return @{
                Installed = $true
                Source = "system"
                Path = $systemCmd.Source
            }
        }

        # Priority 3: File in vendor/tools/
        $vendorPath = Join-Path $VendorDir "tools/$($Package.DetectFile)"
        if (Test-Path $vendorPath) {
            Write-Info "Found local $($Package.Name): $vendorPath"
            return @{
                Installed = $true
                Source = "vendor"
                Path = $vendorPath
            }
        }
    }

    # Priority 4: Execute command test
    if ($Package.DetectCommand) {
        try {
            $null = Invoke-Expression "$($Package.DetectCommand) 2>&1"
            if ($LASTEXITCODE -eq 0) {
                Write-Info "Verified $($Package.Name) via: $($Package.DetectCommand)"
                return @{
                    Installed = $true
                    Source = "command"
                    Path = $Package.DetectCommand
                }
            }
        } catch {
            # Command failed, continue
        }
    }

    # Priority 5: Package state (installed by box previously)
    $state = Get-PackageState -Name $Package.Name
    if ($state -and $state.installed) {
        return @{
            Installed = $true
            Source = "state"
            Path = "vendor/$($Package.Name)"
        }
    }

    return @{
        Installed = $false
        Source = $null
        Path = $null
    }
}

function Ensure-Tool {
    <#
    .SYNOPSIS
    Ensures a critical tool is available, auto-installing to vendor/tools/ if missing.

    .DESCRIPTION
    Used for essential tools like 7z.exe that are required for package extraction.
    Checks system PATH first, then vendor/tools/, then auto-installs if missing.

    .PARAMETER ToolName
    Name of the tool executable (e.g., "7z.exe")

    .PARAMETER PackageConfig
    Hashtable with package definition for auto-install (Name, Url, File, Archive, Extract)

    .OUTPUTS
    String path to the tool executable
    #>
    param(
        [string]$ToolName,
        [hashtable]$PackageConfig
    )

    # Check system PATH
    $systemTool = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($systemTool) {
        Write-Info "Using system $ToolName from: $($systemTool.Source)"
        return $systemTool.Source
    }

    # Check vendor/tools/
    $vendorPath = Join-Path $VendorDir "tools/$ToolName"
    if (Test-Path $vendorPath) {
        Write-Info "Using local $ToolName from: $vendorPath"
        return $vendorPath
    }

    # Auto-install
    Write-Info "Installing $ToolName to vendor/tools/..."

    $sourceType = if ($PackageConfig.SourceType) { $PackageConfig.SourceType } else { "http" }
    $archive = Download-File -Url $PackageConfig.Url -FileName $PackageConfig.File -SourceType $sourceType

    if (-not $archive) {
        Write-Err "Failed to download $ToolName"
        throw "Cannot proceed without $ToolName"
    }

    $result = Extract-Package -Archive $archive -Name $PackageConfig.Name -ArchiveType $PackageConfig.Archive -ExtractRules $PackageConfig.Extract

    if (Test-Path $vendorPath) {
        Write-Success "$ToolName installed successfully"
        return $vendorPath
    } else {
        throw "$ToolName installation failed"
    }
}

function Validate-PackageDependencies {
    <#
    .SYNOPSIS
    Validates that required environment variables exist when package installation is refused.

    .DESCRIPTION
    When user chooses not to install a package, this function:
    1. Extracts required env vars from Extract rules
    2. Checks if env vars already exist
    3. Prompts for manual paths if missing
    4. Validates paths with Test-Path
    5. Saves to .env file

    .PARAMETER Package
    Hashtable with package definition including Extract rules

    .OUTPUTS
    Hashtable of environment variable names and paths
    #>
    param([hashtable]$Package)

    # Extract required env vars from Extract rules
    $requiredEnvs = @()
    if ($Package.Extract) {
        foreach ($rule in $Package.Extract) {
            if ($rule -match ':([A-Z_]+)$') {
                $requiredEnvs += $Matches[1]
            }
        }
    }

    if ($requiredEnvs.Count -eq 0) {
        return @{}
    }

    $envPaths = @{}

    foreach ($envVar in $requiredEnvs) {
        # Check if already set
        $existingValue = [System.Environment]::GetEnvironmentVariable($envVar)
        if ($existingValue) {
            $envPaths[$envVar] = $existingValue
            Write-Info "$envVar already set to: $existingValue"
            continue
        }

        # Prompt for manual path
        Write-Warn "$envVar is required for compilation/build"

        while ($true) {
            $manualPath = Read-Host "Enter path for $envVar (or 'skip' to abort)"

            if ($manualPath -eq 'skip' -or [string]::IsNullOrWhiteSpace($manualPath)) {
                Write-Err "Missing required dependency: $envVar"
                throw "Cannot proceed without $envVar"
            }

            # Validate path
            if (Test-Path $manualPath) {
                $envPaths[$envVar] = $manualPath

                # Save to .env
                $envFilePath = Join-Path $ProjectRoot ".env"
                Add-Content -Path $envFilePath -Value "$envVar=$manualPath"

                # Set in current session
                [System.Environment]::SetEnvironmentVariable($envVar, $manualPath)

                Write-Success "Set $envVar=$manualPath"
                break
            } else {
                Write-Warn "Path not found: $manualPath"
                Write-Info "Please provide a valid path or type 'skip' to abort"
            }
        }
    }

    return $envPaths
}

function Remove-Package {
    param([string]$Name)

    $pkgState = Get-PackageState $Name
    if (-not $pkgState) { return }

    if ($pkgState.installed -and $pkgState.files) {
        foreach ($file in $pkgState.files) {
            if (Test-Path $file) {
                Remove-Item $file -Recurse -Force -ErrorAction SilentlyContinue
                Write-Info "Removed: $file"
            }
        }
    }

    Remove-PackageState $Name
}

function Process-Package {
    param([hashtable]$Item)

    $name = $Item.Name
    $mode = if ($Item.Mode) { $Item.Mode } else { "auto" }
    $pkgState = Get-PackageState $name
    $isInstalled = $pkgState -and $pkgState.installed
    $isManual = $pkgState -and -not $pkgState.installed
    $existingEnvs = if ($pkgState -and $pkgState.envs) { $pkgState.envs } else { @{} }

    Write-Step "$name - $($Item.Description)"

    # T029: Check if package already installed via system/vendor/env (US3)
    $detection = Test-PackageInstalled -Package $Item

    if ($detection.Installed) {
        # T030: Prompt user to use existing installation
        Write-Info "$name detected: $($detection.Source) - $($detection.Path)"
        $useExisting = Ask-Choice "Use existing installation? [Y/n]"

        if ($useExisting -ne "N") {
            Write-Success "Using existing $name"

            # If env var based, ensure it's set
            if ($detection.Source -eq "env" -and $Item.Extract) {
                $envs = @{}
                foreach ($rule in $Item.Extract) {
                    if ($rule -match ':([A-Z_]+)$') {
                        $envs[$Matches[1]] = $detection.Path
                    }
                }
                Set-PackageState -Name $name -Installed $false -Files @() -Dirs @() -Envs $envs
            }

            return
        }
        # User chose to install anyway, continue below
    }

    # Already installed -> ask: Skip, Reinstall, Manual
    if ($isInstalled) {
        $choice = Ask-Choice "$name already installed. [S]kip / [R]einstall / [M]anual?"

        switch ($choice) {
            "S" {
                Write-Info "Skipped"
                return
            }
            "R" {
                Write-Info "Removing previous installation..."
                Remove-Package $name
                # Continue to install below
            }
            "M" {
                $envs = Ask-ManualEnvs -ExtractRules $Item.Extract -ExistingEnvs $existingEnvs
                Set-PackageState -Name $name -Installed $false -Files @() -Dirs @() -Envs $envs
                Write-Success "Manual paths configured"
                return
            }
        }
    }
    # Manual config exists -> ask: Skip, Install, Reconfigure
    elseif ($isManual) {
        $choice = Ask-Choice "$name has manual config. [S]kip / [I]nstall / [R]econfigure?"

        switch ($choice) {
            "S" {
                Write-Info "Skipped"
                return
            }
            "I" {
                # Continue to install below
            }
            "R" {
                $envs = Ask-ManualEnvs -ExtractRules $Item.Extract -ExistingEnvs $existingEnvs
                Set-PackageState -Name $name -Installed $false -Files @() -Dirs @() -Envs $envs
                Write-Success "Manual paths reconfigured"
                return
            }
        }
    }
    # Not installed -> ask if mode=ask, otherwise auto-install
    else {
        if ($mode -eq "ask") {
            $choice = Ask-Choice "Install? [Y/n]"

            if ($choice -eq "N") {
                # T031-T032: User refused install, validate dependencies
                try {
                    $envs = Validate-PackageDependencies -Package $Item
                    Set-PackageState -Name $name -Installed $false -Files @() -Dirs @() -Envs $envs
                    Write-Success "Manual paths configured"
                } catch {
                    Write-Err "Dependency validation failed: $_"
                }
                return
            }
        }
        # mode=auto or user said Yes -> continue to install
    }

    # Detect SourceType (T016)
    $sourceType = if ($Item.SourceType) { $Item.SourceType } else { "http" }

    # Download and install
    $archive = Download-File -Url $Item.Url -FileName $Item.File -SourceType $sourceType

    if (-not $archive) {
        Write-Err "Download failed for $name"
        return
    }

    if ($Item.Archive -eq "file") {
        $result = Install-SingleFile -FilePath $archive -Name $name -ExtractRules $Item.Extract
    } else {
        $result = Extract-Package -Archive $archive -Name $name -ArchiveType $Item.Archive -ExtractRules $Item.Extract
    }

    Set-PackageState -Name $name -Installed $true -Files $result.Files -Dirs $result.Dirs -Envs $result.Envs
    Write-Success "Installed"
}
    }

    if ($Item.Archive -eq "file") {
        $result = Install-SingleFile -FilePath $archive -Name $name -ExtractRules $Item.Extract
    } else {
        $result = Extract-Package -Archive $archive -Name $name -ArchiveType $Item.Archive -ExtractRules $Item.Extract
    }

    Set-PackageState -Name $name -Installed $true -Files $result.Files -Dirs $result.Dirs -Envs $result.Envs
    Write-Success "Installed"
}

function Show-PackageList {
    Write-Host ""
    Write-Host "Packages:" -ForegroundColor Cyan
    Write-Host ""

    $state = Load-State

    # Table columns
    $colName = 20
    $colEnv = 18
    $colValue = 35
    $colStatus = 9

    Write-Host ("  {0,-$colName} {1,-$colEnv} {2,-$colValue} {3}" -f "NAME", "ENV VARS", "DESCRIPTION", "INSTALLED") -ForegroundColor DarkGray
    Write-Host ("  {0,-$colName} {1,-$colEnv} {2,-$colValue} {3}" -f ("-" * $colName), ("-" * $colEnv), ("-" * $colValue), ("-" * $colStatus)) -ForegroundColor DarkGray

    foreach ($item in $AllPackages) {
        $name = $item.Name
        $pkgState = if ($state.packages.ContainsKey($name)) { $state.packages[$name] } else { $null }

        # Get ENV vars (from state if installed, from rules if not)
        $envVars = @{}
        if ($pkgState -and $pkgState.envs) {
            $envVars = $pkgState.envs
        } elseif ($item.Extract) {
            foreach ($rule in $item.Extract) {
                $parsed = Parse-ExtractRule $rule
                if ($parsed -and $parsed.EnvVar) {
                    $envVars[$parsed.EnvVar] = $null
                }
            }
        }

        # Status indicator (last column)
        $isInstalled = $pkgState -and $pkgState.installed
        $isManual = $pkgState -and -not $pkgState.installed
        $hasEnvVars = $envVars.Count -gt 0
        $statusMark = if ($isInstalled) { [char]0x1F60A } elseif ($isManual) { [char]0x1F4E6 } else { "" }
        $statusColor = if ($isInstalled) { "Green" } elseif ($isManual) { "Yellow" } else { "DarkGray" }

        # First line: package name + first ENV or description
        $firstEnv = $envVars.Keys | Select-Object -First 1

        Write-Host ("  {0,-$colName}" -f $name) -ForegroundColor White -NoNewline

        if ($firstEnv) {
            $firstValue = if ($envVars[$firstEnv]) { $envVars[$firstEnv] } else { $item.Description }
            $valueColor = if ($envVars[$firstEnv]) { "Gray" } else { "DarkGray" }
            Write-Host (" {0,-$colEnv}" -f $firstEnv) -ForegroundColor Cyan -NoNewline
            Write-Host (" {0,-$colValue}" -f $firstValue) -ForegroundColor $valueColor -NoNewline
        } else {
            Write-Host (" {0,-$colEnv} {1,-$colValue}" -f "", $item.Description) -ForegroundColor DarkGray -NoNewline
        }
        Write-Host $statusMark -ForegroundColor $statusColor

        # Additional ENV vars (skip first)
        $remaining = $envVars.Keys | Select-Object -Skip 1
        foreach ($envName in $remaining) {
            $envValue = if ($envVars[$envName]) { $envVars[$envName] } else { $item.Description }
            $valueColor = if ($envVars[$envName]) { "Gray" } else { "DarkGray" }

            Write-Host ("  {0,-$colName}" -f "") -NoNewline
            Write-Host (" {0,-$colEnv}" -f $envName) -ForegroundColor Cyan -NoNewline
            Write-Host (" {0,-$colValue}" -f $envValue) -ForegroundColor $valueColor
        }
    }

    Write-Host ""
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/sevenzip.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# 7-Zip Setup
# ============================================================================

function Ensure-SevenZip {
    if (Test-Path $SevenZipExe) {
        Write-Info "7-Zip already present"
        return
    }
    
    Write-Step "Setting up 7-Zip extractor"
    
    # Create directories
    $sevenZipTempDir = Join-Path $TempDir "7zip"
    @($SetupToolsDir, $CacheDir, $TempDir, $sevenZipTempDir) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }
    
    $ProgressPreference = 'SilentlyContinue'
    
    try {
        $sevenZrPath = Join-Path $TempDir "7zr.exe"
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $sevenZrPath -UseBasicParsing
        Write-Info "Downloaded 7zr.exe"
        
        $installerPath = Join-Path $TempDir "7z2501.exe"
        Invoke-WebRequest -Uri "https://github.com/ip7z/7zip/releases/download/25.01/7z2501.exe" -OutFile $installerPath -UseBasicParsing
        Write-Info "Downloaded 7z2501.exe"
        
        & $sevenZrPath x $installerPath -o"$sevenZipTempDir" -y | Out-Null
        
        Copy-Item (Join-Path $sevenZipTempDir "7z.exe") $SevenZipExe -Force
        Copy-Item (Join-Path $sevenZipTempDir "7z.dll") $SevenZipDll -Force
        
        Write-Success "7-Zip ready"
    }
    catch {
        Write-Err "Failed to setup 7-Zip: $_"
        exit 1
    }
    finally {
        $ProgressPreference = 'Continue'
    }
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/templates.ps1
# ──────────────────────────────────────────────────────────────────────────────
<#
.SYNOPSIS
    Template processor module for DevBox

.DESCRIPTION
    Provides functions to load variables, process templates with token replacement,
    manage backups, and apply template-based file generation.

.NOTES
    Module: templates.ps1
    Version: 0.1.0
#>

# ============================================================================
# TEMPLATE VARIABLE FUNCTIONS
# ============================================================================

function Get-TemplateVariables {
    <#
    .SYNOPSIS
        Load environment variables from .env file into hashtable

    .DESCRIPTION
        Reads .env file and parses key=value pairs into hashtable for use in
        template token replacement.

    .PARAMETER EnvPath
        Path to .env file. Defaults to .env in current directory.

    .OUTPUTS
        [hashtable] Key-value pairs from .env file

    .EXAMPLE
        $vars = Get-TemplateVariables
        # Returns: @{ PROJECT_NAME = "MyProject"; VERSION = "0.1.0" }
    #>
    param(
        [string]$EnvPath = '.env'
    )

    $variables = @{}

    if (-not (Test-Path $EnvPath)) {
        Write-Verbose "Env file not found: $EnvPath"
        return $variables
    }

    $content = Get-Content $EnvPath -Raw -Encoding utf8

    # Parse key=value pairs, skip comments and empty lines
    $content -split "`n" | ForEach-Object {
        $line = $_.Trim()

        # Skip comments and empty lines
        if ($line.StartsWith('#') -or [string]::IsNullOrWhiteSpace($line)) {
            return
        }

        # Parse key=value
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $variables[$key] = $value
        }
    }

    return $variables
}

function Get-ConfigBoxVariables {
    <#
    .SYNOPSIS
        Load variables from config.psd1 PowerShell config file

    .DESCRIPTION
        Reads config.psd1 and extracts key-value pairs from the hashtable.
        Supports nested keys (converts to uppercase with _ prefix).

    .PARAMETER ConfigPath
        Path to config.psd1 file. Defaults to box.config.psd1 in current directory.

    .OUTPUTS
        [hashtable] Configuration variables from box.config.psd1

    .EXAMPLE
        $config = Get-ConfigBoxVariables
        # Returns: @{ PROJECT_NAME = "MyProject"; VERSION = "0.1.0" }
    #>
    param(
        [string]$ConfigPath = 'box.config.psd1'
    )

    $variables = @{}

    if (-not (Test-Path $ConfigPath)) {
        Write-Verbose "Config file not found: $ConfigPath"
        return $variables
    }

    try {
        $data = Invoke-Expression (Get-Content $ConfigPath -Raw -Encoding utf8)

        if ($data -is [hashtable]) {
            foreach ($key in $data.Keys) {
                $variables[$key] = $data[$key]
            }
        }
    }
    catch {
        Write-Warning "Failed to parse config.psd1: $_"
    }

    return $variables
}

function Merge-TemplateVariables {
    <#
    .SYNOPSIS
        Merge .env and config.psd1 variables into single hashtable

    .DESCRIPTION
        Combines environment and config variables. Config variables take
        precedence over .env in case of conflicts.

    .PARAMETER EnvPath
        Path to .env file

    .PARAMETER ConfigPath
        Path to config.psd1 file

    .OUTPUTS
        [hashtable] Merged variables

    .EXAMPLE
        $vars = Merge-TemplateVariables
        # Returns merged hashtable with both .env and config.psd1 values
    #>
    param(
        [string]$EnvPath = '.env',
        [string]$ConfigPath = 'box.config.psd1'
    )

    $merged = @{}

    # Load .env first
    $envVars = Get-TemplateVariables -EnvPath $EnvPath
    foreach ($key in $envVars.Keys) {
        $merged[$key] = $envVars[$key]
    }

    # Load config.psd1 and override conflicts
    $configVars = Get-ConfigBoxVariables -ConfigPath $ConfigPath
    foreach ($key in $configVars.Keys) {
        $merged[$key] = $configVars[$key]
    }

    # Validate case sensitivity
    Test-TokenCaseSensitivity -Variables $merged

    return $merged
}

# ============================================================================
# TEMPLATE PROCESSING FUNCTIONS
# ============================================================================

function Process-Template {
    <#
    .SYNOPSIS
        Replace {{TOKEN}} placeholders in template with variable values

    .DESCRIPTION
        Scans template content for {{TOKEN}} patterns and replaces with values
        from variables hashtable. Unknown tokens are left as-is with warning.

    .PARAMETER TemplateContent
        Template file content as string

    .PARAMETER Variables
        Hashtable with variable values for replacement

    .PARAMETER TemplateName
        Template name for logging (optional)

    .OUTPUTS
        [string] Template content with tokens replaced

    .EXAMPLE
        $template = "PROJECT: {{PROJECT_NAME}}"
        $vars = @{ PROJECT_NAME = "MyApp" }
        $result = Process-Template -TemplateContent $template -Variables $vars
        # Returns: "PROJECT: MyApp"
    #>
    param(
        [string]$TemplateContent,
        [hashtable]$Variables,
        [string]$TemplateName = "template"
    )

    $result = $TemplateContent
    $tokensReplaced = 0
    $tokensUnknown = @()

    # Detect circular references
    Test-CircularReferences -Variables $Variables -TemplateName $TemplateName

    # Find all {{TOKEN}} patterns
    $pattern = '\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}'
    $matches = [regex]::Matches($result, $pattern)

    foreach ($match in $matches) {
        $token = $match.Groups[1].Value
        $placeholder = $match.Groups[0].Value

        if ($Variables.ContainsKey($token)) {
            $value = $Variables[$token]
            # Escape $ in replacement value (PowerShell -replace treats $ as special)
            $safeValue = $value -replace '\$', '$$'
            $result = $result -replace [regex]::Escape($placeholder), $safeValue
            $tokensReplaced++
        }
        else {
            $tokensUnknown += $token
        }
    }

    # Report unknown tokens
    if ($tokensUnknown.Count -gt 0) {
        $unknownList = $tokensUnknown | Select-Object -Unique | Join-String -Separator ', '
        Write-Warning "Unknown tokens in $TemplateName : $unknownList"
    }

    Write-Verbose "Replaced $tokensReplaced tokens in $TemplateName"

    return $result
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

function Test-TokenCaseSensitivity {
    <#
    .SYNOPSIS
        Detect tokens with different cases (e.g., PROJECT_NAME vs project_name)

    .DESCRIPTION
        Checks if the same token exists in multiple case variations and warns the user.

    .PARAMETER Variables
        Hashtable with variable values

    .EXAMPLE
        Test-TokenCaseSensitivity -Variables @{ PROJECT_NAME = "App"; project_name = "app" }
        # Warns about case sensitivity issue
    #>
    param(
        [hashtable]$Variables
    )

    $lowercaseKeys = @{}
    $duplicates = @()

    foreach ($key in $Variables.Keys) {
        $lower = $key.ToLower()
        if ($lowercaseKeys.ContainsKey($lower)) {
            $duplicates += "$($lowercaseKeys[$lower]) vs $key"
        }
        else {
            $lowercaseKeys[$lower] = $key
        }
    }

    if ($duplicates.Count -gt 0) {
        $dupeList = $duplicates -join ', '
        Write-Warning "Case sensitivity issue detected in tokens: $dupeList"
    }
}

function Test-CircularReferences {
    <#
    .SYNOPSIS
        Detect circular token references in variables

    .DESCRIPTION
        Checks if variable values contain references to other variables that could
        create circular dependencies (e.g., VAR1={{VAR2}}, VAR2={{VAR1}}).

    .PARAMETER Variables
        Hashtable with variable values

    .PARAMETER TemplateName
        Template name for logging

    .EXAMPLE
        Test-CircularReferences -Variables @{ VAR1 = "{{VAR2}}"; VAR2 = "{{VAR1}}" }
        # Warns about circular reference
    #>
    param(
        [hashtable]$Variables,
        [string]$TemplateName = "template"
    )

    $pattern = '\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}'
    $circularRefs = @()

    foreach ($key in $Variables.Keys) {
        $value = $Variables[$key]
        if ($value -match $pattern) {
            $referencedToken = $matches[1]
            # Check if referenced token also references back
            if ($Variables.ContainsKey($referencedToken)) {
                $referencedValue = $Variables[$referencedToken]
                if ($referencedValue -match "\{\{$key\}\}") {
                    $circularRefs += "$key <-> $referencedToken"
                }
            }
        }
    }

    if ($circularRefs.Count -gt 0) {
        $circularList = $circularRefs | Select-Object -Unique | Join-String -Separator ', '
        Write-Warning "Circular reference detected in $TemplateName : $circularList"
    }
}

function Test-FileEncoding {
    <#
    .SYNOPSIS
        Validate that file is UTF-8 encoded

    .DESCRIPTION
        Checks file encoding to ensure it's UTF-8 compatible.

    .PARAMETER FilePath
        Path to file to validate

    .OUTPUTS
        [bool] True if UTF-8, False otherwise

    .EXAMPLE
        $isUtf8 = Test-FileEncoding -FilePath 'Makefile.template'
    #>
    param(
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        return $false
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)

        # Check for UTF-8 BOM
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return $true
        }

        # Try to decode as UTF-8
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        try {
            $null = $encoding.GetString($bytes)
            return $true
        }
        catch {
            return $false
        }
    }
    catch {
        Write-Warning "Failed to validate encoding for $FilePath : $_"
        return $false
    }
}

function Test-TemplateFileSize {
    <#
    .SYNOPSIS
        Validate template file size is within acceptable limits

    .DESCRIPTION
        Checks if file is larger than 10MB and rejects it to prevent performance issues.

    .PARAMETER FilePath
        Path to template file

    .OUTPUTS
        [bool] True if acceptable size, False if too large

    .EXAMPLE
        $isValid = Test-TemplateFileSize -FilePath 'large.template'
    #>
    param(
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        return $false
    }

    $maxSizeBytes = 10MB
    $fileSize = (Get-Item $FilePath).Length

    if ($fileSize -gt $maxSizeBytes) {
        $sizeMB = [math]::Round($fileSize / 1MB, 2)
        Write-Error "Template file too large: $FilePath ($sizeMB MB). Maximum size is 10 MB."
        return $false
    }

    return $true
}

function Test-FileWritePermission {
    <#
    .SYNOPSIS
        Test if current user has write permission to path

    .DESCRIPTION
        Checks write access to a directory or file without actually writing.

    .PARAMETER Path
        Path to test (file or directory)

    .OUTPUTS
        [bool] True if writable, False otherwise

    .EXAMPLE
        $canWrite = Test-FileWritePermission -Path 'C:\Projects'
    #>
    param(
        [string]$Path
    )

    try {
        $testPath = $Path
        if (Test-Path $testPath -PathType Container) {
            $testFile = Join-Path $testPath ".write_test_$(Get-Random)"
        }
        else {
            $testFile = "$Path.write_test"
        }

        # Try to create a test file
        $null = New-Item -Path $testFile -ItemType File -Force -ErrorAction Stop
        Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

# ============================================================================
# FILE MANAGEMENT FUNCTIONS
# ============================================================================

function Backup-File {
    <#
    .SYNOPSIS
        Create timestamped backup of file before modification

    .DESCRIPTION
        Copies file to .bak.TIMESTAMP version to preserve original.
        Uses format: filename.bak.yyyyMMdd-HHmmss

    .PARAMETER FilePath
        Path to file to backup

    .PARAMETER Force
        Overwrite existing backup (optional)

    .OUTPUTS
        [string] Path to backup file created

    .EXAMPLE
        $backupPath = Backup-File -FilePath 'Makefile'
        # Creates: Makefile.bak.20251224-143045
    #>
    param(
        [string]$FilePath,
        [switch]$Force
    )

    if (-not (Test-Path $FilePath)) {
        Write-Warning "File not found for backup: $FilePath"
        return $null
    }

    # Test write permission before attempting backup
    $directory = Split-Path $FilePath -Parent
    if (-not (Test-FileWritePermission -Path $directory)) {
        Write-Error "Insufficient permissions to create backup in: $directory"
        return $null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$FilePath.bak.$timestamp"

    try {
        Copy-Item -Path $FilePath -Destination $backupPath -Force:$Force -ErrorAction Stop
        Write-Verbose "Backed up to: $backupPath"
        return $backupPath
    }
    catch {
        Write-Error "Failed to backup $FilePath : $_"
        return $null
    }
}

function New-GenerationHeader {
    <#
    .SYNOPSIS
        Create file header comment indicating auto-generation

    .DESCRIPTION
        Returns a comment block that warns users not to edit the file directly.
        Includes generation timestamp for tracking.

    .PARAMETER FileType
        Type of file (for comment syntax): 'makefile', 'powershell', 'markdown', etc.

    .OUTPUTS
        [string] Comment header for file

    .EXAMPLE
        $header = New-GenerationHeader -FileType 'makefile'
        # Returns: "# Generated by DevBox - DO NOT EDIT\n# Generated: 2025-12-24 14:30:45"
    #>
    param(
        [ValidateSet('makefile', 'powershell', 'markdown', 'generic')]
        [string]$FileType = 'generic'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = switch ($FileType) {
        'makefile' { '#' }
        'powershell' { '#' }
        'markdown' { '<!--' }
        default { '#' }
    }

    $suffix = if ($FileType -eq 'markdown') { '-->' } else { '' }

    $header = @"
$prefix Generated by DevBox - DO NOT EDIT
$prefix Generated: $timestamp
$suffix
"@

    return $header.TrimEnd()
}

function Get-AvailableTemplates {
    <#
    .SYNOPSIS
        List all available template files in .box/templates/

    .DESCRIPTION
        Discovers all .template files in .box/templates/ directory.

    .PARAMETER TemplateDir
        Path to templates directory. Defaults to .box/templates/

    .OUTPUTS
        [array] Array of template filenames (without .template extension)

    .EXAMPLE
        $templates = Get-AvailableTemplates
        # Returns: @( "Makefile", "README.md", "Makefile.amiga" )
    #>
    param(
        [string]$TemplateDir = '.box/templates'
    )

    $templates = @()

    if (-not (Test-Path $TemplateDir)) {
        Write-Verbose "Templates directory not found: $TemplateDir"
        return $templates
    }

    Get-ChildItem -Path $TemplateDir -Filter '*.template*' -File | ForEach-Object {
        # Remove .template or .template.* extension
        $name = $_.Name -replace '\.template.*$', ''
        # Add back the extension if it's a secondary extension (like .md)
        if ($_.Name -match '\.template\.(\w+)$') {
            $name = $name + '.' + $Matches[1]
        }
        $templates += $name
    }

    return $templates
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/ui.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# UI Functions (completion messages, etc.)
# ============================================================================

function Show-List {
    Write-Host ""
    Write-Host "Installed Components:" -ForegroundColor Cyan
    Write-Host ""
    
    $state = Load-State
    
    foreach ($item in $AllPackages) {
        $name = $item.Name
        $pkgState = if ($state.packages.ContainsKey($name)) { $state.packages[$name] } else { $null }
        
        if ($pkgState) {
            $status = if ($pkgState.installed) { "[installed]" } else { "[manual]" }
            $date = $pkgState.date
            $path = if ($pkgState.envs.Count -gt 0) { ($pkgState.envs.Values | Select-Object -First 1) } else { "-" }
            Write-Host "  $status $name" -ForegroundColor Green -NoNewline
            Write-Host " -> $path ($date)" -ForegroundColor Gray
        } else {
            Write-Host "  [        ] $name" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

function Show-InstallComplete {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Setup Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  . .\.env              # Load environment (PowerShell)" -ForegroundColor Cyan
    Write-Host "  make                  # Build project" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  .\box.ps1 pkg list     # Show packages" -ForegroundColor Gray
    Write-Host "  .\box.ps1 env list     # Show environment" -ForegroundColor Gray
    Write-Host "  .\box.ps1 uninstall    # Uninstall setup" -ForegroundColor Gray
    Write-Host ""
}



# ──────────────────────────────────────────────────────────────────────────────
# Source: inc/wizard.ps1
# ──────────────────────────────────────────────────────────────────────────────
# ============================================================================
# Project Configuration Wizard
# ============================================================================
# Called by Invoke-Install when setup.config.psd1 doesn't exist.
# ============================================================================

function Invoke-ConfigWizard {
    if (-not (Test-Path $UserConfigTemplate)) {
        Write-Host "User config template not found: $($SysConfig.UserConfigTemplate)" -ForegroundColor Red
        return $false
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Project Configuration" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Get folder name as default
    $folderName = Split-Path $BaseDir -Leaf

    # Ask for project info (only essential)
    Write-Host "Project name" -ForegroundColor Yellow -NoNewline
    Write-Host " [$folderName]: " -ForegroundColor DarkGray -NoNewline
    $projectName = Read-Host
    if ([string]::IsNullOrWhiteSpace($projectName)) { $projectName = $folderName }
    
    Write-Host "Description" -ForegroundColor Yellow -NoNewline
    Write-Host " [Amiga program]: " -ForegroundColor DarkGray -NoNewline
    $description = Read-Host
    if ([string]::IsNullOrWhiteSpace($description)) { $description = "Amiga program" }
    
    Write-Host "Version" -ForegroundColor Yellow -NoNewline
    Write-Host " [1.0.0]: " -ForegroundColor DarkGray -NoNewline
    $version = Read-Host
    if ([string]::IsNullOrWhiteSpace($version)) { $version = "1.0.0" }
    
    Write-Host ""
    
    # Read template and replace placeholders
    $templateContent = Get-Content $UserConfigTemplate -Raw
    $templateContent = $templateContent -replace 'Name\s*=\s*"MyProgram"', "Name        = `"$projectName`""
    $templateContent = $templateContent -replace 'Description\s*=\s*"Program Description"', "Description = `"$description`""
    $templateContent = $templateContent -replace 'Version\s*=\s*"0\.1\.0"', "Version     = `"$version`""
    $templateContent = $templateContent -replace 'ProgramName\s*=\s*"MyProgram"', "ProgramName = `"$projectName`""
    
    $templateContent | Out-File $UserConfigFile -Encoding UTF8
    Write-Host "[OK] Created setup.config.psd1" -ForegroundColor Green
    Write-Host ""
    
    # Load the new config
    $script:UserConfig = Import-PowerShellDataFile $UserConfigFile
    $script:Config = Merge-Config -SysConfig $SysConfig -UserConfig $UserConfig
    
    return $true
}



# ══════════════════════════════════════════════════════════════════════════════
# END COMPILED MODULES
# ══════════════════════════════════════════════════════════════════════════════


# Main Application (source: app.ps1)
$script:SkipExecution = $false


# Exit early if init signals to skip
if ($SkipExecution) {
    exit 0
}

# ============================================================================
# Main
# ============================================================================

switch ($Command) {
    "install" {
        Invoke-Install
    }
    "uninstall" {
        Invoke-Uninstall
    }
    "env" {
        if ([string]::IsNullOrEmpty($SubCommand)) {
            Show-EnvList
        } else {
            Invoke-Env -Sub $SubCommand -Params $Args
        }
    }
    "pkg" {
        if ([string]::IsNullOrEmpty($SubCommand)) {
            Show-PackageList
        } else {
            Invoke-Pkg -Sub $SubCommand
        }
    }
    "template" {
        if ($SubCommand -eq "apply") {
            if ($Args.Count -eq 0) {
                Write-Host "Error: template name required" -ForegroundColor Red
                Write-Host "Usage: box template apply <name>" -ForegroundColor Yellow
                exit 1
            }
            Invoke-TemplateApply -Template $Args[0]
        }
        else {
            Invoke-EnvUpdate
        }
    }
    default {
        Invoke-Install
    }
}