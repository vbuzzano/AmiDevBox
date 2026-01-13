<#
.SYNOPSIS
    Boxer - Global Boxing Manager

.DESCRIPTION
    Standalone boxer.ps1 with embedded modules

.NOTES
    Build Date: 2026-01-13 20:08:04
    Version: 0.1.102
#>

param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# EMBEDDED boxing.ps1 (bootstrapper)
# ============================================================================

# Flag indicating this is an embedded/compiled version
$script:IsEmbedded = $true

# Embedded version information (injected by build script)
$script:BoxerVersion = "0.1.102"

# BEGIN boxing.ps1
# Boxing - Common bootstrapper for boxer and box
#
# This script serves as the shared foundation for both boxer.ps1 (global manager)
# and box.ps1 (project manager). It handles:
# - Mode detection (boxer vs box)
# - Core library loading
# - Module discovery and loading
# - Command dispatching

# Strict mode for better error detection
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Global variables
$script:BoxingRoot = $PSScriptRoot
$script:Mode = $null
$script:LoadedModules = @{}
$script:Commands = @{}

# Embedded flag - set to $true by build process for compiled versions
if (-not (Get-Variable -Name IsEmbedded -Scope Script -ErrorAction SilentlyContinue)) {
    $script:IsEmbedded = $false
}

# Detect execution mode
function Initialize-Mode {
    # If mode already set (by embedded script), use it
    if ($script:Mode) {
        Write-Verbose "Mode already set: $script:Mode"
        return $script:Mode
    }

    # When executed via irm|iex, $MyInvocation.PSCommandPath is empty
    # In this case, default to 'boxer' mode for installation
    if (-not $MyInvocation.PSCommandPath) {
        $script:Mode = 'boxer'
        return $script:Mode
    }

    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath)

    if ($scriptName -eq 'boxer') {
        $script:Mode = 'boxer'
    }
    elseif ($scriptName -eq 'box') {
        $script:Mode = 'box'
    }
    else {
        throw "Unknown execution mode. Script must be named 'boxer.ps1' or 'box.ps1'"
    }

    return $script:Mode
}

# Load core libraries
function Import-CoreLibraries {
    # Skip if embedded version - libraries already loaded
    if ($script:IsEmbedded) {
        Write-Verbose "Embedded mode: core libraries already loaded"
        return
    }

    $corePath = Join-Path $script:BoxingRoot 'core'

    if (-not (Test-Path $corePath)) {
        throw "Core directory not found: $corePath"
    }

    $coreFiles = Get-ChildItem -Path $corePath -Filter '*.ps1' | Sort-Object Name

    foreach ($file in $coreFiles) {
        try {
            . $file.FullName
            Write-Verbose "Loaded core: $($file.Name)"
        }
        catch {
            throw "Failed to load core library $($file.Name): $_"
        }
    }
}

# Discover and load mode-specific modules
function Import-ModeModules {
    param([string]$Mode)

    # Skip if embedded version - modules already loaded
    if ($script:IsEmbedded) {
        Write-Verbose "Embedded mode: $Mode modules already loaded"
        # Still need to register commands for embedded version
        Register-EmbeddedCommands -Mode $Mode
        return
    }

    # Collect module files from multiple sources with priority order
    $allModules = @{}

    # Priority 1: Box-specific modules (.box/modules/) - highest priority
    $boxModulesPath = Join-Path (Get-Location) ".box\modules"
    if (Test-Path $boxModulesPath) {
        $boxModuleFiles = Get-ChildItem -Path $boxModulesPath -Filter '*.ps1' -ErrorAction SilentlyContinue
        foreach ($file in $boxModuleFiles) {
            $commandName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            if (-not $allModules.ContainsKey($commandName)) {
                $allModules[$commandName] = @{
                    File = $file
                    Source = 'box-override'
                }
            }
        }
    }

    # Priority 2: Core modules (modules/$Mode/) - fallback
    $modulesPath = Join-Path $script:BoxingRoot "modules\$Mode"
    if (Test-Path $modulesPath) {
        $moduleFiles = Get-ChildItem -Path $modulesPath -Filter '*.ps1' | Sort-Object Name
        foreach ($file in $moduleFiles) {
            $commandName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            if (-not $allModules.ContainsKey($commandName)) {
                $allModules[$commandName] = @{
                    File = $file
                    Source = 'core'
                }
            }
        }
    }

    if ($allModules.Count -eq 0) {
        Write-Verbose "No modules found for mode: $Mode"
        return
    }

    # Load all collected modules
    foreach ($commandName in $allModules.Keys) {
        $moduleInfo = $allModules[$commandName]
        $file = $moduleInfo.File
        $source = $moduleInfo.Source

        try {
            . $file.FullName

            $script:Commands[$commandName] = $file.FullName
            $script:LoadedModules[$file.Name] = $file.FullName

            Write-Verbose "Loaded module ($source): $Mode/$($file.Name)"
        }
        catch {
            Write-Warning "Failed to load module $($file.Name): $_"
        }
    }
}

# Register embedded commands (when modules are already loaded)
function Register-EmbeddedCommands {
    param([string]$Mode)

    # For embedded versions, discover commands dynamically by scanning loaded functions
    $prefix = "Invoke-$Mode-"
    $functions = Get-Command -Name "$prefix*" -CommandType Function -ErrorAction SilentlyContinue

    foreach ($func in $functions) {
        $funcName = $func.Name
        # Extract command name: Invoke-Box-Install → install, Invoke-Box-Env-List → env
        $commandName = $funcName.Substring($prefix.Length).ToLower()

        # For sub-commands (env-list), keep only base command
        if ($commandName -match '^([^-]+)-') {
            $commandName = $matches[1]
        }

        if (-not $script:Commands.ContainsKey($commandName)) {
            $script:Commands[$commandName] = $funcName
            Write-Verbose "Registered command: $commandName → $funcName"
        }
    }
}

# Discover and load shared modules
function Import-SharedModules {
    # Skip if embedded version - shared modules already loaded
    if ($script:IsEmbedded) {
        Write-Verbose "Embedded mode: shared modules already loaded"
        return
    }

    $sharedPath = Join-Path $script:BoxingRoot 'modules\shared'

    if (-not (Test-Path $sharedPath)) {
        Write-Verbose "No shared modules found"
        return
    }

    # Load complex modules with metadata
    $metadataFiles = Get-ChildItem -Path $sharedPath -Filter 'metadata.psd1' -Recurse

    foreach ($metaFile in $metadataFiles) {
        try {
            $metadata = Import-PowerShellDataFile -Path $metaFile.FullName
            $moduleName = $metadata.ModuleName
            $moduleDir = $metaFile.Directory.FullName

            # Load all .ps1 files in the module directory
            $moduleFiles = Get-ChildItem -Path $moduleDir -Filter '*.ps1'

            foreach ($file in $moduleFiles) {
                . $file.FullName
                Write-Verbose "Loaded shared module: $moduleName/$($file.Name)"
            }

            # Register module commands
            if ($metadata.Commands) {
                foreach ($cmd in $metadata.Commands) {
                    $script:Commands[$cmd] = $moduleName
                }
            }

            $script:LoadedModules[$moduleName] = $moduleDir
        }
        catch {
            Write-Warning "Failed to load shared module $($metaFile.Directory.Name): $_"
        }
    }
}

# Dispatch command to appropriate handler
function Invoke-Command {
    param(
        [string]$CommandName,
        [string[]]$Arguments
    )

    if (-not $script:Commands.ContainsKey($CommandName)) {
        Write-Error "Unknown command: $CommandName"
        Show-Help
        return 1
    }

    try {
        # Build function name from command
        $functionName = "Invoke-$($script:Mode)-$CommandName"

        if (Get-Command $functionName -ErrorAction SilentlyContinue) {
            & $functionName @Arguments
            return $LASTEXITCODE
        }
        else {
            Write-Error "Command handler not found: $functionName"
            return 1
        }
    }
    catch {
        Write-Error "Command execution failed: $_"
        return 1
    }
}

# Main bootstrapping function
function Initialize-Boxing {
    param(
        [string[]]$Arguments = @()
    )

    try {
        # Auto-installation/update if executed via irm|iex (no $PSScriptRoot)
        if (-not $PSScriptRoot -and $Arguments.Count -eq 0) {
            $BoxerInstalled = "$env:USERPROFILE\Documents\PowerShell\Boxing\boxer.ps1"

            # 1. Check if already installed
            if (Test-Path $BoxerInstalled) {
                # 2. Compare versions
                $InstalledContent = Get-Content $BoxerInstalled -Raw
                $InstalledVersion = if ($InstalledContent -match 'Version:\s*(\S+)') { $Matches[1] } else { $null }

                # Get current version via core API (works in all modes)
                $CurrentVersion = Get-BoxerVersion

                # 3. Decision: upgrade only if new version > installed version
                try {
                    if ($InstalledVersion -and $CurrentVersion -and ([version]$CurrentVersion -gt [version]$InstalledVersion)) {
                        Write-Host ""
                        Write-Host "🔄 Boxer update: $InstalledVersion → $CurrentVersion" -ForegroundColor Cyan
                        Install-BoxingSystem | Out-Null
                        return
                    } elseif ($InstalledVersion -and $CurrentVersion) {
                        # Already up-to-date or newer installed
                        Write-Host "✓ Boxer already up-to-date (v$InstalledVersion)" -ForegroundColor Green
                        # Check if box needs update (Install-BoxingSystem handles this)
                        Install-BoxingSystem | Out-Null
                        return
                    }
                } catch {
                    # Version parsing failed, skip update
                }
            } else {
                # First-time installation
                Install-BoxingSystem | Out-Null
                return
            }
        }        # Step 1: Detect mode
        $mode = Initialize-Mode
        Write-Verbose "Mode: $mode"

        # Step 2: Load core libraries
        Import-CoreLibraries
        Write-Verbose "Core libraries loaded"

        # Step 3: Load mode-specific modules
        Import-ModeModules -Mode $mode
        Write-Verbose "Mode modules loaded: $($script:Commands.Count) commands"

        # Step 4: Load shared modules
        Import-SharedModules
        Write-Verbose "Shared modules loaded"

        # Step 5: Dispatch command
        if ($Arguments.Count -gt 0) {
            $command = $Arguments[0]
            $cmdArgs = if ($Arguments.Count -gt 1) {
                $Arguments[1..($Arguments.Count - 1)]
            } else {
                @()
            }

            Invoke-Command -CommandName $command -Arguments $cmdArgs | Out-Null
        }
        else {
            Show-Help
        }
    }
    catch {
        Write-Error "Boxing initialization failed: $_"
        return 1
    }
}

# END boxing.ps1

# ============================================================================
# EMBEDDED core/*.ps1 (shared libraries)
# ============================================================================

# BEGIN core/ui.ps1
# ============================================================================
# UI Functions - Consolidated output and user input
# ============================================================================
#
# This file consolidates all UI-related functions from common.ps1 and ui.ps1:
# - Output functions (Write-*)
# - User input functions (Ask-*)
# - Display functions (Show-*)

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

function Write-PackageLog {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$LogPath,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if (-not $LogPath) {
        $logDir = Join-Path $BaseDir ".box\logs"
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $LogPath = Join-Path $logDir "package-install.log"
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    try {
        Add-Content -Path $LogPath -Value $logEntry -Encoding UTF8
    }
    catch {
        Write-Verbose "Failed to write log: $_"
    }
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

    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $BaseDir $path
    }

    if ($MustExist -and -not (Test-Path $path)) {
        Write-Err "Path does not exist: $path"
        exit 1
    }

    return $path
}

# ============================================================================
# Display Functions
# ============================================================================

function Show-Help {
    Write-Host ""
    Write-Host "Boxing - Reproducible Environment Manager" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow

    $cmdName = if ($script:Mode -eq 'boxer') { 'boxer' } else { 'box' }

    # Generate help from registered commands dynamically
    if ($script:Commands.Count -gt 0) {
        $sortedCommands = $script:Commands.Keys | Sort-Object
        foreach ($cmd in $sortedCommands) {
            $description = switch ($cmd) {
                'init'      { 'Create a new Box project' }
                'list'      { 'List available Box types' }
                'install'   { if ($script:Mode -eq 'boxer') { 'Install a Box from GitHub' } else { 'Install workspace packages' } }
                'status'    { 'Show installation status' }
                'env'       { 'Manage environment variables' }
                'clean'     { 'Clean installation' }
                'uninstall' { 'Remove all packages' }
                'load'      { 'Load environment into current shell' }
                'info'      { 'Show workspace information' }
                'version'   { 'Show version' }
                default     { $cmd }
            }
            $padding = ' ' * (16 - $cmd.Length)
            Write-Host "  $cmdName $cmd$padding$description" -ForegroundColor White
        }
    }
    Write-Host ""
}

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

# END core/ui.ps1
# BEGIN core/version.ps1
# ============================================================================
# Version Management Functions
# ============================================================================

function Get-BoxerVersion {
    <#
    .SYNOPSIS
    Gets the current boxer version from various sources.

    .DESCRIPTION
    Returns the boxer version, trying in order:
    1. Embedded $script:BoxerVersion (compiled mode)
    2. boxer.version file (development mode)
    3. Header comment from boxer.ps1 (fallback)

    .OUTPUTS
    Version string (e.g., "1.0.10") or $null if not found
    #>

    # 1. Try embedded version (compiled/runtime)
    if ($script:BoxerVersion) {
        return $script:BoxerVersion
    }

    # 2. Try reading from source file (development mode)
    $versionFile = Join-Path $script:BoxingRoot "boxer.version"
    if (Test-Path $versionFile) {
        $version = (Get-Content $versionFile -Raw).Trim()
        if ($version) {
            return $version
        }
    }

    # 3. Try reading from boxer.ps1 header (fallback)
    $boxerFile = Join-Path $script:BoxingRoot "dist\boxer.ps1"
    if (Test-Path $boxerFile) {
        $content = Get-Content $boxerFile -Raw
        if ($content -match 'Version:\s*(\S+)') {
            return $Matches[1]
        }
    }

    # Not found
    return $null
}

# END core/version.ps1

# ============================================================================
# EMBEDDED modules/boxer/*.ps1 (boxer commands)
# ============================================================================

# BEGIN modules/boxer/init.ps1
# ============================================================================
# Boxer Init Module
# ============================================================================
#
# Handles boxer init command - creating new Box projects

function Get-InstalledVersion {
    <#
    .SYNOPSIS
    Gets the version from a metadata.psd1 file.

    .PARAMETER MetadataPath
    Path to metadata.psd1 file

    .OUTPUTS
    Version string (e.g., "1.0.0") or $null if not found
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$MetadataPath
    )

    if (-not (Test-Path $MetadataPath)) {
        return $null
    }

    try {
        $metadata = Import-PowerShellDataFile -Path $MetadataPath -ErrorAction Stop
        return $metadata.Version
    } catch {
        return $null
    }
}

function Compare-Version {
    <#
    .SYNOPSIS
    Compares two version strings.

    .OUTPUTS
    -1 if v1 < v2, 0 if equal, 1 if v1 > v2
    #>
    param(
        [string]$Version1,
        [string]$Version2
    )

    try {
        $v1 = [version]$Version1
        $v2 = [version]$Version2
        return $v1.CompareTo($v2)
    } catch {
        # Fallback to string comparison
        return [string]::Compare($Version1, $Version2)
    }
}

function Sanitize-ProjectName {
    <#
    .SYNOPSIS
    Sanitizes a project name to make it a valid directory name.

    .PARAMETER Name
    The project name to sanitize

    .OUTPUTS
    Sanitized project name suitable for directory creation
    #>
    param([string]$Name)

    # Remove/replace invalid characters for directory names
    $sanitized = $Name -replace '[/\\()^''":\[\]<>|?*]', '-'
    # Convert to lowercase
    $sanitized = $sanitized.ToLower()
    # Remove trailing dots and spaces
    $sanitized = $sanitized -replace '[\s.]+$', ''
    # Remove leading/trailing dashes
    $sanitized = $sanitized -replace '^-+|-+$', ''
    # Keep only alphanumeric, dash, dot, underscore, plus
    $sanitized = $sanitized -replace '[^a-z0-9.\-_+]', '-'

    return $sanitized
}

function Get-InstalledBoxes {
    <#
    .SYNOPSIS
    Gets list of installed boxes from Boxing directory.

    .OUTPUTS
    Array of box names (directory names in Boxing\Boxes\)
    #>

    $BoxingDir = "$env:USERPROFILE\Documents\PowerShell\Boxing"
    $BoxesDir = Join-Path $BoxingDir "Boxes"

    if (-not (Test-Path $BoxesDir)) {
        return @()
    }

    $boxes = @(Get-ChildItem -Path $BoxesDir -Directory | Select-Object -ExpandProperty Name)
    return $boxes
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

function Invoke-Boxer-Init {
    <#
    .SYNOPSIS
    Creates a new Box project with full structure.

    .PARAMETER Name
    Name of the project to create (optional - will prompt if not provided)

    .PARAMETER Path
    Custom path where to create the project (optional - uses Name in current dir if not provided)

    .PARAMETER Box
    Which box to use (optional - auto-detects if only one installed, prompts if multiple)

    .EXAMPLE
    boxer init
    # Prompts for name, uses current directory, auto-selects box

    .EXAMPLE
    boxer init MyProject
    # Creates MyProject in current directory, auto-selects box

    .EXAMPLE
    boxer init MyProject C:\Dev\MyProject
    # Creates project at specific path

    .EXAMPLE
    boxer init -Name MyProject -Box AmiDevBox
    # Explicitly specifies box to use
    #>
    param(
        [Parameter(Position=0)]
        [string]$Name = "",

        [Parameter(Position=1)]
        [string]$Path = "",

        [Parameter(Position=2)]
        [string]$Description = "",

        [string]$Box = ""
    )

    # FIRST: Detect if current directory is already a box project
    $CurrentDirIsBox = Test-Path (Join-Path (Get-Location) ".box")

    # Determine target directory and update mode
    $IsUpdate = $false
    $TargetDir = ""

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        # Path explicitly provided - resolve and check
        $TargetDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $BoxPath = Join-Path $TargetDir ".box"
        $IsUpdate = (Test-Path $TargetDir) -and (Test-Path $BoxPath)

        # Error if directory exists but not a box project
        if ((Test-Path $TargetDir) -and -not $IsUpdate) {
            Write-Err "Directory '$TargetDir' exists but is not a Box project"
            Write-Host "  Remove the directory or choose a different path" -ForegroundColor Yellow
            return
        }
    } elseif ($CurrentDirIsBox) {
        # No path provided but current dir is a box → update current directory
        $TargetDir = (Get-Location).Path
        $IsUpdate = $true
    }

    # In update mode, extract name from existing directory
    if ($IsUpdate) {
        $SafeName = Split-Path -Leaf $TargetDir
    } else {
        # Creation mode - prompt for name if not provided
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $Name = Read-Host "Project name"
            if ([string]::IsNullOrWhiteSpace($Name)) {
                Write-Err "Project name is required"
                return
            }
        }

        # Sanitize project name
        $SafeName = Sanitize-ProjectName -Name $Name
        if ([string]::IsNullOrWhiteSpace($SafeName)) {
            Write-Err "Invalid project name after sanitization"
            return
        }

        # Prompt for description if not provided
        if ([string]::IsNullOrWhiteSpace($Description)) {
            $Description = Read-Host "Description (optional)"
        }

        # Determine target directory
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $TargetDir = Join-Path (Get-Location) $SafeName
        } else {
            $TargetDir = $Path
        }

        # Resolve to absolute path
        $TargetDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetDir)
    }

    # Update BoxPath for later use
    $BoxPath = Join-Path $TargetDir ".box"

    # Get installed boxes (force array to avoid $null)
    $InstalledBoxes = @(Get-InstalledBoxes)

    if ($InstalledBoxes.Count -eq 0) {
        Write-Err "No boxes installed"
        Write-Host ""
        Write-Host "  Install a box first:" -ForegroundColor Yellow
        Write-Host "    irm https://raw.githubusercontent.com/vbuzzano/AmiDevBox/main/boxer.ps1 | iex" -ForegroundColor Cyan
        return
    }

    # Determine which box to use
    $SelectedBox = ""

    if (-not [string]::IsNullOrWhiteSpace($Box)) {
        # Box explicitly specified
        if ($InstalledBoxes -contains $Box) {
            $SelectedBox = $Box
        } else {
            Write-Err "Box '$Box' not found"
            Write-Host ""
            Write-Host "  Available boxes:" -ForegroundColor Yellow
            $InstalledBoxes | ForEach-Object { Write-Host "    - $_" -ForegroundColor Cyan }
            return
        }
    } elseif ($InstalledBoxes.Count -eq 1) {
        # Auto-select if only one box installed
        $SelectedBox = $InstalledBoxes[0]
        Write-Host "  Using box: $SelectedBox" -ForegroundColor Gray
    } else {
        # Multiple boxes - prompt user
        Write-Host ""
        Write-Host "  Select a box:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $InstalledBoxes.Count; $i++) {
            Write-Host "    [$($i+1)] $($InstalledBoxes[$i])" -ForegroundColor Cyan
        }
        Write-Host ""
        $choice = Read-Host "  Choose box (1-$($InstalledBoxes.Count))"

        $choiceNum = 0
        if ([int]::TryParse($choice, [ref]$choiceNum) -and $choiceNum -ge 1 -and $choiceNum -le $InstalledBoxes.Count) {
            $SelectedBox = $InstalledBoxes[$choiceNum - 1]
        } else {
            Write-Err "Invalid choice"
            return
        }
    }

    # Verify box compatibility for updates
    if ($IsUpdate) {
        $BoxMetadataPath = Join-Path $BoxPath "metadata.psd1"
        if (Test-Path $BoxMetadataPath) {
            try {
                $metadata = Import-PowerShellDataFile $BoxMetadataPath
                $CurrentBoxName = $metadata.BoxName

                if ($CurrentBoxName -ne $SelectedBox) {
                    Write-Err "Cannot update: existing project uses '$CurrentBoxName', trying to init '$SelectedBox'"
                    Write-Host ""
                    Write-Host "  To change box type, create a new project" -ForegroundColor Yellow
                    return
                }
            } catch {
                Write-Host "  ⚠ Could not read box metadata, proceeding with update..." -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
    if ($IsUpdate) {
        # UPDATE MODE
        Write-Step "Updating project: $SafeName"
        Write-Host "  Directory: $TargetDir" -ForegroundColor Gray
        Write-Host "  Box: $SelectedBox" -ForegroundColor Gray
        Write-Host ""

        try {
            $BoxingDir = "$env:USERPROFILE\Documents\PowerShell\Boxing"
            $SourceBoxDir = Join-Path (Join-Path $BoxingDir "Boxes") $SelectedBox

            Write-Step "Updating box files..."

            # Update .box/ files
            $filesToCopy = Get-ChildItem -Path $SourceBoxDir -File
            foreach ($file in $filesToCopy) {
                if ($file.Name -eq "boxer.ps1") { continue }
                $destPath = Join-Path $BoxPath $file.Name
                Copy-Item -Path $file.FullName -Destination $destPath -Force
                Write-Success "Updated: $($file.Name)"
            }

            # Update tpl/
            $SourceTplDir = Join-Path $SourceBoxDir "tpl"
            if (Test-Path $SourceTplDir) {
                $DestTplDir = Join-Path $BoxPath "tpl"
                if (Test-Path $DestTplDir) {
                    Remove-Item -Path $DestTplDir -Recurse -Force
                }
                Copy-Item -Path $SourceTplDir -Destination $DestTplDir -Recurse -Force
                $tplCount = (Get-ChildItem -Path $DestTplDir -File -Recurse).Count
                Write-Success "Updated: tpl/ ($tplCount templates)"
            }

            Write-Host ""
            Write-Success "Project updated: $SafeName ($SelectedBox)"
            Write-Host ""

        } catch {
            Write-Host ""
            Write-Host "❌ Project update failed: $_" -ForegroundColor Red
            Write-Host ""
        }

    } else {
        # CREATION MODE
        Write-Step "Creating project: $SafeName"
        Write-Host "  Directory: $TargetDir" -ForegroundColor Gray
        Write-Host "  Box: $SelectedBox" -ForegroundColor Gray
        Write-Host ""

        try {
            # Create project directory
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Track-Creation $TargetDir 'directory'

            # Create .box directory
            $BoxPath = Join-Path $TargetDir ".box"
            New-Item -ItemType Directory -Path $BoxPath -Force | Out-Null
            Track-Creation $BoxPath 'directory'

            # Copy box files from Boxing\Boxes\{SelectedBox}\ to .box\
            $BoxingDir = "$env:USERPROFILE\Documents\PowerShell\Boxing"
            $SourceBoxDir = Join-Path (Join-Path $BoxingDir "Boxes") $SelectedBox

            Write-Step "Copying box files..."

            # Get all files in source box directory
            $filesToCopy = Get-ChildItem -Path $SourceBoxDir -File

            foreach ($file in $filesToCopy) {
                # Skip boxer.ps1 (global only, not for projects)
                if ($file.Name -eq "boxer.ps1") {
                    continue
                }

                $destPath = Join-Path $BoxPath $file.Name
                Copy-Item -Path $file.FullName -Destination $destPath -Force
                Track-Creation $destPath 'file'
                Write-Success "Copied: $($file.Name)"
            }

            # Copy tpl/ directory recursively if it exists
            $SourceTplDir = Join-Path $SourceBoxDir "tpl"
            if (Test-Path $SourceTplDir) {
                $DestTplDir = Join-Path $BoxPath "tpl"
                Copy-Item -Path $SourceTplDir -Destination $DestTplDir -Recurse -Force
                Track-Creation $DestTplDir 'directory'

                $tplCount = (Get-ChildItem -Path $DestTplDir -File -Recurse).Count
                Write-Success "Copied: tpl/ ($tplCount templates)"
            }

            # Create basic project structure
            Write-Step "Creating project structure..."
            @('src', 'docs', 'scripts') | ForEach-Object {
                $dirPath = Join-Path $TargetDir $_
                New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
                Track-Creation $dirPath 'directory'
            }
            Write-Success "Created: src, docs, scripts"

            # Generate box.psd1 at root from template
            Write-Step "Creating project config..."
            $BoxPsd1Path = Join-Path $TargetDir "box.psd1"
            $BoxPsd1Template = Join-Path $BoxPath "tpl\box.psd1.template"
            if (Test-Path $BoxPsd1Template) {
                $content = Get-Content $BoxPsd1Template -Raw -Encoding UTF8
                $content = $content -replace '{{PROJECT_NAME}}', $Name
                $content = $content -replace '{{DESCRIPTION}}', $Description
                $content = $content -replace '{{PROGRAM_NAME}}', $Name
                Set-Content -Path $BoxPsd1Path -Value $content -Encoding UTF8
                Track-Creation $BoxPsd1Path 'file'
                Write-Success "Created: box.psd1"
            } else {
                Write-Host "  ⚠ box.psd1.template not found, skipping" -ForegroundColor Yellow
            }

            # Generate src/main.c from template
            $MainCPath = Join-Path $TargetDir "src\main.c"
            $MainCTemplate = Join-Path $BoxPath "tpl\main.c.template"
            if (Test-Path $MainCTemplate) {
                $content = Get-Content $MainCTemplate -Raw -Encoding UTF8
                $content = $content -replace '{{PROJECT_NAME}}', $Name
                Set-Content -Path $MainCPath -Value $content -Encoding UTF8
                Track-Creation $MainCPath 'file'
                Write-Success "Created: src/main.c"
            } else {
                Write-Host "  ⚠ main.c.template not found, skipping" -ForegroundColor Yellow
            }

            # Generate .vscode/settings.json from template (only if not exists)
            $VSCodeDir = Join-Path $TargetDir ".vscode"
            $VSCodeSettingsPath = Join-Path $VSCodeDir "settings.json"

            if (-not (Test-Path $VSCodeSettingsPath)) {
                $VSCodeTemplate = Join-Path $BoxPath "tpl\vscode-settings.json.template"
                if (Test-Path $VSCodeTemplate) {
                    New-Item -ItemType Directory -Path $VSCodeDir -Force | Out-Null
                    Track-Creation $VSCodeDir 'directory'
                    Copy-Item -Path $VSCodeTemplate -Destination $VSCodeSettingsPath
                    Track-Creation $VSCodeSettingsPath 'file'
                    Write-Success "Created: .vscode/settings.json"
                } else {
                    Write-Host "  ⚠ vscode-settings.json.template not found, skipping" -ForegroundColor Yellow
                }
            } else {
                Write-Success "Preserved: .vscode/settings.json (already exists)"
            }

            Write-Host ""
            Write-Success "Project created: $SafeName"
            Write-Host ""
            Write-Host "  Next steps:" -ForegroundColor Cyan
            Write-Host "    box install" -ForegroundColor White
            Write-Host ""

            # Navigate to the new project directory
            Set-Location -Path $TargetDir

        } catch {
            Write-Host ""
            Write-Host "❌ Project creation failed: $_" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Possible causes:" -ForegroundColor Yellow
            Write-Host "    - Insufficient disk space" -ForegroundColor White
            Write-Host "    - Permission denied" -ForegroundColor White
            Write-Host "    - Path too long" -ForegroundColor White
            Write-Host ""
            Rollback-Creation
        }
    }
}

function Install-BoxingSystem {
    <#
    .SYNOPSIS
    Installs Boxing system globally (boxer.ps1 and box.ps1).

    .DESCRIPTION
    Sets up Boxing for global use by:
    - Creating Scripts directory in PowerShell folder
    - Copying boxer.ps1 and box.ps1 to Scripts
    - Creating Boxing directory for box storage
    - Modifying PowerShell profile with boxer and box functions
    - Avoiding duplication if already installed

    .EXAMPLE
    Install-BoxingSystem
    #>

    Write-Step "Installing Boxing system globally..."

    try {
        # Paths
        $BoxingDir = "$env:USERPROFILE\Documents\PowerShell\Boxing"
        $ProfilePath = $PROFILE.CurrentUserAllHosts

        # Fallback if PROFILE is not set (rare but possible in some contexts)
        if (-not $ProfilePath) {
            $ProfilePath = "$env:USERPROFILE\Documents\PowerShell\profile.ps1"
        }

        # Create Boxing directory
        if (-not (Test-Path $BoxingDir)) {
            Write-Step "Creating Boxing directory..."
            New-Item -ItemType Directory -Path $BoxingDir -Force | Out-Null
            Write-Success "Created: $BoxingDir"
        }

        # Create Boxes subdirectory
        $BoxesDir = Join-Path $BoxingDir "Boxes"
        if (-not (Test-Path $BoxesDir)) {
            Write-Step "Creating Boxes directory..."
            New-Item -ItemType Directory -Path $BoxesDir -Force | Out-Null
            Write-Success "Created: $BoxesDir"
        }

        # Copy boxer.ps1 to Boxing directory (self-installation pattern)
        $BoxerPath = Join-Path $BoxingDir "boxer.ps1"
        $BoxerMetadataPath = Join-Path $BoxingDir "boxer-metadata.psd1"
        $BoxerAlreadyInstalled = Test-Path $BoxerPath

        # Always set source repo for AmiDevBox release (hardcoded in dist build)
        $SourceRepo = "AmiDevBox"

        # Get versions for comparison
        $InstalledVersion = Get-InstalledVersion -MetadataPath $BoxerMetadataPath

        # Get new version via core API (works in all modes)
        $NewVersion = Get-BoxerVersion

        # Determine if update is needed
        $NeedsUpdate = $false
        if (-not $BoxerAlreadyInstalled) {
            $NeedsUpdate = $true
            Write-Step "Installing boxer.ps1..."
        } elseif ($InstalledVersion -and (Compare-Version -Version1 $NewVersion -Version2 $InstalledVersion) -gt 0) {
            $NeedsUpdate = $true
            Write-Step "Updating boxer.ps1 ($InstalledVersion → $NewVersion)..."
        } else {
            Write-Success "boxer.ps1 already up-to-date (v$InstalledVersion)"
        }

        if ($NeedsUpdate) {
            # If executed via irm|iex, $PSCommandPath is empty - download from GitHub
            if (-not $PSCommandPath -or -not (Test-Path $PSCommandPath)) {
                $boxerUrl = "https://raw.githubusercontent.com/vbuzzano/AmiDevBox/main/boxer.ps1"

                try {
                    Invoke-RestMethod -Uri $boxerUrl -OutFile $BoxerPath
                    Write-Success "Installed: boxer.ps1"
                } catch {
                    throw "Failed to download boxer.ps1: $_"
                }
            } else {
                # Local installation (running from file)
                Copy-Item -Path $PSCommandPath -Destination $BoxerPath -Force
                Write-Success "Installed: boxer.ps1"
            }

            # Save metadata with version
            $BoxerMetadata = @"
@{
    Version = "$NewVersion"
    InstallDate = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}
"@
            Set-Content -Path $BoxerMetadataPath -Value $BoxerMetadata -Encoding UTF8

            # Create/update init.ps1 alongside boxer.ps1
            $InitScript = @"
# Boxing Session Loader
# Run this to load boxer and box functions in current session without restarting PowerShell
#
# Usage: . `$env:USERPROFILE\Documents\PowerShell\Boxing\init.ps1

function boxer {
    `$boxerPath = "`$env:USERPROFILE\Documents\PowerShell\Boxing\boxer.ps1"
    if (Test-Path `$boxerPath) {
        & `$boxerPath @args
    } else {
        Write-Host "Error: boxer.ps1 not found at `$boxerPath" -ForegroundColor Red
    }
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
        Write-Host "❌ No box project found" -ForegroundColor Red
        Write-Host ""
        Write-Host "Create a new project:" -ForegroundColor Cyan
        Write-Host "  boxer init MyProject" -ForegroundColor White
        return
    }

    & `$boxScript @args
}

Write-Host "✓ Boxing functions loaded (boxer, box)" -ForegroundColor Green
"@
            $InitPath = Join-Path $BoxingDir "init.ps1"
            Set-Content -Path $InitPath -Value $InitScript -Encoding UTF8
            Write-Success "Created: init.ps1"
        }

        # Modify PowerShell profile
        Write-Step "Configuring PowerShell profile..."

        # Create profile directory if needed
        $ProfileDir = Split-Path $ProfilePath -Parent
        if (-not (Test-Path $ProfileDir)) {
            New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
        }

        # Read existing profile or create empty
        $ProfileContent = ""
        if (Test-Path $ProfilePath) {
            $ProfileContent = Get-Content $ProfilePath -Raw
        }

        # Check if #region boxing already exists
        if ($ProfileContent -match '#region boxing') {
            Write-Success "Profile ready"
        } else {
            # Add Boxing region to profile (lightweight dot-source approach)
            $BoxingRegion = @"

#region boxing
`$boxingInit = "`$env:USERPROFILE\Documents\PowerShell\Boxing\init.ps1"
if (Test-Path `$boxingInit) {
    . `$boxingInit
}
#endregion boxing
"@

            # Append to profile
            $ProfileContent += $BoxingRegion
            Set-Content -Path $ProfilePath -Value $ProfileContent -Encoding UTF8
            Write-Success "Profile configured"
        }

        # Install box if this is a box repository (not Boxing main repo)
        if ($SourceRepo) {
            Install-CurrentBox -BoxName $SourceRepo -BoxingDir $BoxingDir
        }

        # Determine if we need to load functions in current session
        $ProfileNeedsConfig = -not ($ProfileContent -match '#region boxing')
        $FunctionsNeedLoading = $ProfileNeedsConfig -or -not (Get-Command -Name boxer -ErrorAction SilentlyContinue)

        # Load functions in current session only if needed (profile not configured or function missing)
        if ($FunctionsNeedLoading) {
            $global:function:boxer = {
                $boxerPath = "$env:USERPROFILE\Documents\PowerShell\Boxing\boxer.ps1"
                if (Test-Path $boxerPath) {
                    & $boxerPath @args
                } else {
                    Write-Host "Error: boxer.ps1 not found at $boxerPath" -ForegroundColor Red
                }
            }

            $global:function:box = {
                $boxScript = $null
                $current = (Get-Location).Path

                while ($current -ne [System.IO.Path]::GetPathRoot($current)) {
                    $testPath = Join-Path $current ".box\box.ps1"
                    if (Test-Path $testPath) {
                        $boxScript = $testPath
                        break
                    }
                    $parent = Split-Path $current -Parent
                    if (-not $parent) { break }
                    $current = $parent
                }

                if (-not $boxScript) {
                    Write-Host "❌ No box project found" -ForegroundColor Red
                    Write-Host ""
                    Write-Host "Create a new project:" -ForegroundColor Cyan
                    Write-Host "  boxer init MyProject" -ForegroundColor White
                    return
                }

                & $boxScript @args
            }
        }

        # Display appropriate completion message
        if (-not $BoxerAlreadyInstalled) {
            # First installation
            Write-Success "✓ Boxing functions loaded (boxer, box)"
            Write-Success "Boxing system installed successfully!"
            Write-Host ""
            Write-Host "  Ready to use! Try:" -ForegroundColor Cyan
            Write-Host "    boxer init MyProject" -ForegroundColor White
            Write-Host ""
            Write-Host "  💡 Recommended: Restart PowerShell for permanent installation" -ForegroundColor Yellow
            Write-Host "     (functions work now, but restart ensures they persist)" -ForegroundColor DarkGray
        }
        # Update or already up-to-date: no additional message needed

    } catch {
        Write-Host "Installation failed: $_" -ForegroundColor Red
        throw
    }
}

function Install-CurrentBox {
    <#
    .SYNOPSIS
    Installs the current box from its GitHub repository.

    .PARAMETER BoxName
    Name of the box to install (e.g., AmiDevBox)

    .PARAMETER BoxingDir
    Path to Boxing directory
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$BoxName,

        [Parameter(Mandatory=$true)]
        [string]$BoxingDir
    )

    try {
        $BoxesDir = Join-Path $BoxingDir "Boxes"
        $BoxDir = Join-Path $BoxesDir $BoxName
        $BoxMetadataPath = Join-Path $BoxDir "metadata.psd1"

        # Base URL for downloads
        $BaseUrl = "https://raw.githubusercontent.com/vbuzzano/$BoxName/main"

        # Get installed version and boxer version
        $InstalledVersion = Get-InstalledVersion -MetadataPath $BoxMetadataPath
        $InstalledBoxerVersion = $null
        if (Test-Path $BoxMetadataPath) {
            $metadata = Import-PowerShellDataFile $BoxMetadataPath
            $InstalledBoxerVersion = $metadata.BoxerVersion
        }

        # Get remote version and boxer version from GitHub
        $RemoteVersion = $null
        $RemoteBoxerVersion = $null
        try {
            $RemoteMetadataUrl = "$BaseUrl/metadata.psd1"
            $RemoteMetadataContent = Invoke-RestMethod -Uri $RemoteMetadataUrl -ErrorAction Stop

            # Parse version and boxer version from downloaded content
            if ($RemoteMetadataContent -match 'Version\s*=\s*"([^"]+)"') {
                $RemoteVersion = $Matches[1]
            }
            if ($RemoteMetadataContent -match 'BoxerVersion\s*=\s*"([^"]+)"') {
                $RemoteBoxerVersion = $Matches[1]
            }
        } catch {
            Write-Warn "Could not fetch remote version, proceeding with install"
        }

        # Determine if update is needed
        $NeedsUpdate = $false
        $UpdateReason = ""

        if (-not (Test-Path $BoxDir)) {
            $NeedsUpdate = $true
            $UpdateReason = "Installing $BoxName box..."
        } elseif ($RemoteVersion -and $InstalledVersion -and (Compare-Version -Version1 $RemoteVersion -Version2 $InstalledVersion) -gt 0) {
            $NeedsUpdate = $true
            $UpdateReason = "Updating $BoxName box ($InstalledVersion → $RemoteVersion)..."
        } elseif ($RemoteVersion -and $InstalledVersion -and (Compare-Version -Version1 $RemoteVersion -Version2 $InstalledVersion) -eq 0) {
            Write-Host ""
            Write-Host "=== $BoxName Box ===" -ForegroundColor Cyan
            Write-Success "$BoxName already up-to-date (v$InstalledVersion)"
            return
        } else {
            Write-Host ""
            Write-Host "=== $BoxName Box ===" -ForegroundColor Cyan
            Write-Success "$BoxName already installed (v$InstalledVersion)"
            return
        }

        if ($NeedsUpdate) {
            Write-Step $UpdateReason
        }

        if (-not $NeedsUpdate) {
            return
        }

        # Create box directory
        New-Item -ItemType Directory -Path $BoxDir -Force | Out-Null

        # Download box.ps1
        Write-Step "Downloading box.ps1..."
        try {
            Invoke-RestMethod -Uri "$BaseUrl/box.ps1" -OutFile (Join-Path $BoxDir "box.ps1")
            $action = if ($InstalledVersion) { "Updated" } else { "Installed" }
            Write-Success "${action}: box.ps1"
        } catch {
            throw "Failed to download box.ps1: $_"
        }

        # Download config.psd1
        Write-Step "Downloading config.psd1..."
        try {
            Invoke-RestMethod -Uri "$BaseUrl/config.psd1" -OutFile (Join-Path $BoxDir "config.psd1")
            $action = if ($InstalledVersion) { "Updated" } else { "Installed" }
            Write-Success "${action}: config.psd1"
        } catch {
            Write-Warn "config.psd1 not found (optional)"
        }

        # Download metadata.psd1
        Write-Step "Downloading metadata.psd1..."
        try {
            Invoke-RestMethod -Uri "$BaseUrl/metadata.psd1" -OutFile (Join-Path $BoxDir "metadata.psd1")
            $action = if ($InstalledVersion) { "Updated" } else { "Installed" }
            Write-Success "${action}: metadata.psd1"
        } catch {
            Write-Warn "metadata.psd1 not found (optional)"
        }

        # Download env.ps1 (environment configuration)
        Write-Step "Downloading env.ps1..."
        try {
            Invoke-RestMethod -Uri "$BaseUrl/env.ps1" -OutFile (Join-Path $BoxDir "env.ps1")
            $action = if ($InstalledVersion) { "Updated" } else { "Installed" }
            Write-Success "${action}: env.ps1"
        } catch {
            Write-Warn "env.ps1 not found (optional)"
        }

        # Download tpl/ directory (FILES ONLY, no subdirectories)
        Write-Step "Downloading templates..."
        $TplDir = Join-Path $BoxDir "tpl"

        # Clean tpl directory if updating (remove old files)
        if (Test-Path $TplDir) {
            Remove-Item -Path $TplDir -Recurse -Force
        }

        New-Item -ItemType Directory -Path $TplDir -Force | Out-Null

        # Use GitHub API to list tpl/ contents
        try {
            $ApiUrl = "https://api.github.com/repos/vbuzzano/$BoxName/contents/tpl"
            $TplFiles = Invoke-RestMethod -Uri $ApiUrl

            foreach ($File in $TplFiles) {
                # Download ONLY files at root of tpl/, skip directories (docs/, src/, etc.)
                if ($File.type -eq 'file') {
                    $FilePath = Join-Path $TplDir $File.name
                    Invoke-RestMethod -Uri $File.download_url -OutFile $FilePath
                    $action = if ($InstalledVersion) { "Updated" } else { "Installed" }
                    Write-Success "${action}: tpl/$($File.name)"
                }
            }
        } catch {
            Write-Warn "tpl/ directory not found or empty"
        }

        Write-Success "$BoxName box installed successfully!"

    } catch {
        Write-Err "Box installation failed: $_"

        # Cleanup on error
        if (Test-Path $BoxDir) {
            Remove-Item -Path $BoxDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}


# END modules/boxer/init.ps1
# BEGIN modules/boxer/install.ps1
# ============================================================================
# Boxer Install Command Dispatcher
# ============================================================================

function Invoke-Boxer-Install {
    <#
    .SYNOPSIS
    Boxer install command dispatcher.

    .PARAMETER Arguments
    Command arguments (box name or GitHub URL).

    .EXAMPLE
    boxer install AmiDevBox
    boxer install https://github.com/vbuzzano/AmiDevBox
    #>
    param(
        [Parameter(ValueFromRemainingArguments=$true)]
        [string[]]$Arguments
    )

    if (-not $Arguments -or $Arguments.Count -eq 0) {
        Write-Host ""
        Write-Host "Usage: boxer install <box-name|github-url>" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Install from registry:" -ForegroundColor Yellow
        Write-Host "  boxer install AmiDevBox" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "Install from GitHub URL:" -ForegroundColor Yellow
        Write-Host "  boxer install https://github.com/user/BoxName" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "Available boxes:" -ForegroundColor Cyan
        foreach ($boxName in $script:BoxRegistry.Keys | Sort-Object) {
            $url = $script:BoxRegistry[$boxName]
            Write-Host "  - $boxName" -ForegroundColor White -NoNewline
            Write-Host " ($url)" -ForegroundColor DarkGray
        }
        Write-Host ""
        return
    }

    # Get box name or URL from first argument
    $boxNameOrUrl = $Arguments[0]

    # Call Install-Box
    Install-Box -BoxUrl $boxNameOrUrl
}

# ============================================================================
# Box Registry - Maps simple names to GitHub repository URLs
# ============================================================================

$script:BoxRegistry = @{
    'AmiDevBox' = 'https://github.com/vbuzzano/AmiDevBox'
    # 'BoxBuilder' = 'https://github.com/vbuzzano/BoxBuilder'  # Commented out until box exists
}

# ============================================================================
# Box URL Resolution
# ============================================================================

function Get-BoxUrl {
    <#
    .SYNOPSIS
    Resolves a box name or URL to a full GitHub repository URL.

    .PARAMETER NameOrUrl
    Either a simple box name (e.g., "AmiDevBox") or a full GitHub URL.

    .RETURNS
    Full GitHub repository URL.

    .EXAMPLE
    Get-BoxUrl "AmiDevBox"
    Returns: https://github.com/vbuzzano/AmiDevBox

    .EXAMPLE
    Get-BoxUrl "https://github.com/user/CustomBox"
    Returns: https://github.com/user/CustomBox (passthrough)
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$NameOrUrl
    )

    # If already a URL, return as-is (passthrough)
    if ($NameOrUrl -match '^https?://') {
        return $NameOrUrl
    }

    # Try to resolve from registry
    if ($script:BoxRegistry.ContainsKey($NameOrUrl)) {
        return $script:BoxRegistry[$NameOrUrl]
    }

    # Not found in registry
    Write-Host ""
    Write-Host "Box '$NameOrUrl' not found in registry." -ForegroundColor Red
    Write-Host ""
    Write-Host "Available boxes:" -ForegroundColor Cyan
    foreach ($boxName in $script:BoxRegistry.Keys | Sort-Object) {
        $url = $script:BoxRegistry[$boxName]
        Write-Host "  - $boxName" -ForegroundColor White -NoNewline
        Write-Host " ($url)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "You can also install from any GitHub URL:" -ForegroundColor Cyan
    Write-Host "  boxer install https://github.com/user/BoxName" -ForegroundColor DarkGray
    Write-Host ""

    throw "Box '$NameOrUrl' not found"
}

# ============================================================================
# Box Installation
# ============================================================================

function Install-Box {
    <#
    .SYNOPSIS
    Installs a box from GitHub URL or simple name.

    .PARAMETER BoxUrl
    GitHub repository URL or simple box name (e.g., "AmiDevBox").

    .EXAMPLE
    boxer install AmiDevBox
    boxer install https://github.com/vbuzzano/AmiDevBox
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$BoxUrl
    )

    # Resolve name to URL if needed
    try {
        $resolvedUrl = Get-BoxUrl -NameOrUrl $BoxUrl
    }
    catch {
        Write-Error $_.Exception.Message
        return
    }

    Write-Step "Installing box from $resolvedUrl..."

    try {
        # Parse GitHub URL to extract owner, repo, branch
        if ($resolvedUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
            $Owner = $Matches['owner']
            $Repo = $Matches['repo']
            $BoxName = $Repo
        } else {
            throw "Invalid GitHub URL format. Expected: https://github.com/user/repo"
        }

        Write-Step "Box name: $BoxName"

        # Target directory
        $BoxingDir = "$env:USERPROFILE\Documents\PowerShell\Boxing"
        $BoxesDir = Join-Path $BoxingDir "Boxes"
        $BoxDir = Join-Path $BoxesDir $BoxName

        # Create Boxes directory if needed
        if (-not (Test-Path $BoxesDir)) {
            New-Item -ItemType Directory -Path $BoxesDir -Force | Out-Null
        }

        # Check if box already installed
        if (Test-Path $BoxDir) {
            throw "Box '$BoxName' is already installed at $BoxDir"
        }

        # Create box directory
        New-Item -ItemType Directory -Path $BoxDir -Force | Out-Null
        Write-Success "Created: $BoxDir"

        # Download config.psd1
        Write-Step "Downloading config.psd1..."
        $ConfigUrl = "https://github.com/$Owner/$Repo/raw/main/config.psd1"
        $ConfigPath = Join-Path $BoxDir "config.psd1"
        try {
            Invoke-RestMethod -Uri $ConfigUrl -OutFile $ConfigPath
            Write-Success "Downloaded: config.psd1"
        } catch {
            Write-Host "  Warning: config.psd1 not found (optional)" -ForegroundColor Yellow
        }

        # Download metadata.psd1
        Write-Step "Downloading metadata.psd1..."
        $MetadataUrl = "https://github.com/$Owner/$Repo/raw/main/metadata.psd1"
        $MetadataPath = Join-Path $BoxDir "metadata.psd1"
        try {
            Invoke-RestMethod -Uri $MetadataUrl -OutFile $MetadataPath
            Write-Success "Downloaded: metadata.psd1"
        } catch {
            Write-Host "  Warning: metadata.psd1 not found (optional)" -ForegroundColor Yellow
        }

        # Download tpl/ directory (recursive)
        Write-Step "Downloading templates..."
        $TplDir = Join-Path $BoxDir "tpl"
        New-Item -ItemType Directory -Path $TplDir -Force | Out-Null

        # Use GitHub API to list files in tpl/
        $ApiUrl = "https://api.github.com/repos/$Owner/$Repo/contents/tpl"
        try {
            $TplFiles = Invoke-RestMethod -Uri $ApiUrl
            foreach ($File in $TplFiles) {
                if ($File.type -eq 'file') {
                    $FilePath = Join-Path $TplDir $File.name
                    Invoke-RestMethod -Uri $File.download_url -OutFile $FilePath
                    Write-Success "Downloaded: tpl/$($File.name)"
                }
            }
        } catch {
            Write-Host "  Warning: tpl/ directory not found or empty" -ForegroundColor Yellow
        }

        # Download box.ps1 from repo
        Write-Step "Downloading box.ps1..."
        $BoxUrl = "https://github.com/$Owner/$Repo/raw/main/box.ps1"
        $BoxDest = Join-Path $BoxDir "box.ps1"
        try {
            Invoke-RestMethod -Uri $BoxUrl -OutFile $BoxDest
            Write-Success "Downloaded: box.ps1"
        } catch {
            throw "Failed to download box.ps1: $_"
        }

        # Create .boxer manifest
        Write-Step "Creating manifest..."
        $ManifestPath = Join-Path $BoxDir ".boxer"
        $ManifestContent = @"
Name=$BoxName
Version=0.1.0
Repository=$BoxUrl
"@
        Set-Content -Path $ManifestPath -Value $ManifestContent -Encoding UTF8
        Write-Success "Created: .boxer manifest"

        Write-Success "Box '$BoxName' installed successfully!"
        Write-Host ""
        Write-Host "  Next steps:" -ForegroundColor Cyan
        Write-Host "    boxer init MyProject" -ForegroundColor White

    } catch {
        Write-Host "Box installation failed: $_" -ForegroundColor Red

        # Cleanup on error
        if (Test-Path $BoxDir) {
            Remove-Item -Path $BoxDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

# ============================================================================
# Version Detection Functions
# ============================================================================

function Get-InstalledBoxVersion {
    <#
    .SYNOPSIS
    Gets the version of an installed box.

    .PARAMETER BoxName
    Name of the box to check.

    .RETURNS
    Version string if installed, $null otherwise.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$BoxName
    )

    $BoxingDir = "$env:USERPROFILE\Documents\PowerShell\Boxing"
    $MetadataPath = Join-Path $BoxingDir "$BoxName\metadata.psd1"

    if (Test-Path $MetadataPath) {
        try {
            $Metadata = Import-PowerShellDataFile $MetadataPath
            return $Metadata.Version
        } catch {
            Write-Verbose "Failed to read metadata for ${BoxName}: $($_.Exception.Message)"
            return $null
        }
    }

    return $null
}

function Get-RemoteBoxVersion {
    <#
    .SYNOPSIS
    Gets the version from remote metadata content.

    .PARAMETER MetadataContent
    Raw content of metadata.psd1 file.

    .RETURNS
    Version string if found, $null otherwise.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$MetadataContent
    )

    if ($MetadataContent -match 'Version\s*=\s*"([^"]*)"') {
        return $Matches[1]
    }

    return $null
}


# END modules/boxer/install.ps1
# BEGIN modules/boxer/list.ps1
# ============================================================================
# Boxer List Module
# ============================================================================
#
# Handles boxer list command - listing installed boxes from user installation directory

function Invoke-Boxer-List {
    <#
    .SYNOPSIS
    Lists all installed Box types from ~/Documents/PowerShell/Boxing/Boxes/.

    .DESCRIPTION
    Displays boxes that are actually installed on the user's system,
    not development boxes in the repository.

    .EXAMPLE
    boxer list
    #>
    Write-Host ""
    Write-Host "Installed Boxes:" -ForegroundColor Cyan
    Write-Host ""

    # Read from user installation directory, not repository
    $boxesPath = Join-Path $env:USERPROFILE "Documents\PowerShell\Boxing\Boxes"

    if (-not (Test-Path $boxesPath)) {
        Write-Host "  No boxes installed yet." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To install a box, run:" -ForegroundColor Gray
        Write-Host "    boxer install <box-name-or-url>" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Examples:" -ForegroundColor Gray
        Write-Host "    boxer install AmiDevBox" -ForegroundColor DarkGray
        Write-Host "    boxer install https://github.com/user/MyBox" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    $boxes = Get-ChildItem -Path $boxesPath -Directory -ErrorAction SilentlyContinue

    if (-not $boxes -or @($boxes).Count -eq 0) {
        Write-Host "  No boxes installed yet." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To install a box, run:" -ForegroundColor Gray
        Write-Host "    boxer install <box-name-or-url>" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    # Display installed boxes with version and description
    $hasValidBoxes = $false

    foreach ($boxDir in $boxes) {
        $metadataPath = Join-Path $boxDir.FullName "metadata.psd1"

        if (Test-Path $metadataPath) {
            try {
                $metadata = Import-PowerShellDataFile $metadataPath
                $version = if ($metadata.ContainsKey('Version')) { "v$($metadata.Version)" } else { "(no version)" }
                $description = if ($metadata.ContainsKey('Description')) { $metadata.Description } else { "(no description)" }

                Write-Host ("  {0,-20} {1,-12} - {2}" -f $boxDir.Name, $version, $description) -ForegroundColor White
                $hasValidBoxes = $true
            }
            catch {
                # Corrupted metadata.psd1 - show warning but continue
                Write-Host ("  {0,-20} " -f $boxDir.Name) -NoNewline -ForegroundColor Yellow
                Write-Host "(corrupted metadata)" -ForegroundColor DarkYellow
                Write-Warning "Failed to read metadata for $($boxDir.Name): $_"
            }
        }
        else {
            # No metadata - still show the box
            Write-Host ("  {0,-20} " -f $boxDir.Name) -NoNewline -ForegroundColor Gray
            Write-Host "(no metadata)" -ForegroundColor DarkGray
            $hasValidBoxes = $true
        }
    }

    if (-not $hasValidBoxes) {
        Write-Host "  No valid boxes found in: $boxesPath" -ForegroundColor Yellow
    }

    Write-Host ""
}

# END modules/boxer/list.ps1
# BEGIN modules/boxer/version.ps1
# Boxer Version Command
# Display version information for boxer and installed boxes

function Invoke-Boxer-Version {
    # Detect version (prefer embedded variable, fallback to file parsing)
    $BoxerVersion = if ($script:BoxerVersion) {
        $script:BoxerVersion
    } else {
        "Unknown"
    }

    Write-Host "Boxer v$BoxerVersion" -ForegroundColor Cyan
}

# END modules/boxer/version.ps1

# ============================================================================
# MAIN - Invoke bootstrapper
# ============================================================================

# Ensure Arguments is an array (can be null in irm|iex context)
if (-not $Arguments) { $Arguments = @() }
Initialize-Boxing -Arguments $Arguments

