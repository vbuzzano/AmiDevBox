<#
.SYNOPSIS
    Box - Project Workspace Manager

.DESCRIPTION
    Standalone box.ps1 with embedded modules

.NOTES
    Build Date: 2026-01-12 21:29:25
    Version: 0.1.84
#>

param(
    [Parameter(Position=0)]
    [string]$Command,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Bootstrap - Find .box directory
# ============================================================================

# Embedded version information (injected by build script)
$script:BoxerVersion = "0.1.84"

$BaseDir = Get-Location
$BoxDir = $null

while ($true) {
    $testPath = Join-Path $BaseDir '.box'
    if (Test-Path $testPath) {
        $BoxDir = $testPath
        break
    }
    $parent = Split-Path $BaseDir -Parent
    if (-not $parent -or $parent -eq $BaseDir) {
        Write-Host "ERROR: No .box directory found" -ForegroundColor Red
        Write-Host "Run this from a box project directory" -ForegroundColor Gray
        exit 1
    }
    $BaseDir = $parent
}

# Set global paths
$script:BaseDir = $BaseDir
$script:BoxDir = $BoxDir
$script:VendorDir = Join-Path $BaseDir "vendor"
$script:TempDir = Join-Path $BaseDir "temp"
$script:StateFile = Join-Path $BoxDir "state.json"

# ============================================================================
# EMBEDDED boxing.ps1 (bootstrapper functions)
# ============================================================================

# BEGIN boxing.ps1 (functions only)
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

# BEGIN core/commands.ps1
# ============================================================================
# Command Functions (Invoke-*)
# ============================================================================

function Invoke-Install {
    # Generate project files from templates if they don't exist
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
    $installScript = Join-Path $BoxDir "install.ps1"
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

    $uninstallScript = Join-Path $BoxDir "uninstall.ps1"
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
        Write-Verbose "Template directory: .box/tpl/"
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
    $templates = Get-AvailableTemplates -TemplateDir '.box/tpl'

    if ($templates.Count -eq 0) {
        Write-Host "  [INFO] No templates found in .box/tpl/" -ForegroundColor Cyan
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
        if (Test-Path ".box/tpl/$template.template" -PathType Leaf) {
            $actualTemplate = Get-Item ".box/tpl/$template.template"
        }
        else {
            # Try: output_name_without_ext.template.ext (e.g., README.template.md)
            $templateWithExt = ".box/tpl/$($template -split '\.' | Select-Object -First 1).template.$($template -split '\.' | Select-Object -Last 1)"
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
        $templatePath = ".box/tpl/$Template.template"
        $outputPath = $Template
    }
    else {
        $templatePath = ".box/tpl/$Template"
        $outputPath = $Template -replace '\.template$', ''
    }

    # Check if template exists
    if (-not (Test-Path $templatePath)) {
        $available = Get-AvailableTemplates -TemplateDir '.box/tpl'
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

function Invoke-Init {
    <#
    .SYNOPSIS
        Generate missing project files from templates

    .DESCRIPTION
        Calls Invoke-BoxInit from templates.ps1 module to generate
        README.md, box.config.psd1, and other files from .box/tpl/ templates.
        Only creates missing files - safe to re-run.

    .EXAMPLE
        box init
    #>

    Invoke-BoxInit
}

# END core/commands.ps1
# BEGIN core/common.ps1
# ============================================================================
# Common Functions - State Management
# ============================================================================
#
# Consolidated common utilities, after extracting UI functions to ui.ps1
# and config functions to config.ps1. This file now contains:
# - State management (Load/Save/Get/Set/Remove package state)

# ============================================================================
# State Management
# ============================================================================

function Load-State {
    <#
    .SYNOPSIS
    Loads the package state from the state file.

    .DESCRIPTION
    Returns a hashtable with package installation state.
    Creates an empty state if file doesn't exist.

    .EXAMPLE
    $state = Load-State
    #>
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{ packages = @{} }
}

function Save-State {
    <#
    .SYNOPSIS
    Saves the package state to the state file.

    .PARAMETER State
    The state hashtable to save

    .EXAMPLE
    Save-State -State $state
    #>
    param([hashtable]$State)
    $State | ConvertTo-Json -Depth 10 | Out-File $StateFile -Encoding UTF8
}

function Get-PackageState {
    <#
    .SYNOPSIS
    Gets the state for a specific package.

    .PARAMETER Name
    The package name

    .EXAMPLE
    $pkgState = Get-PackageState -Name "vbcc"
    #>
    param([string]$Name)
    $state = Load-State
    if ($state.packages.ContainsKey($Name)) {
        return $state.packages[$Name]
    }
    return $null
}

function Set-PackageState {
    <#
    .SYNOPSIS
    Sets/updates the state for a specific package.

    .PARAMETER Name
    The package name

    .PARAMETER Installed
    Whether the package is installed

    .PARAMETER Files
    List of installed files

    .PARAMETER Dirs
    List of installed directories

    .PARAMETER Envs
    Environment variables set by the package

    .EXAMPLE
    Set-PackageState -Name "vbcc" -Installed $true -Files @() -Dirs @() -Envs @{}
    #>
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
    <#
    .SYNOPSIS
    Removes the state for a specific package.

    .PARAMETER Name
    The package name

    .EXAMPLE
    Remove-PackageState -Name "vbcc"
    #>
    param([string]$Name)
    $state = Load-State
    if ($state.packages.ContainsKey($Name)) {
        $state.packages.Remove($Name)
        Save-State $state
    }
}

# END core/common.ps1
# BEGIN core/config.ps1
# ============================================================================
# Configuration Management
# ============================================================================
#
# This file contains configuration merge utilities extracted from common.ps1

function Merge-Hashtable {
    <#
    .SYNOPSIS
    Recursively merges two hashtables.

    .DESCRIPTION
    Merges Override into Base, with Override values taking precedence.
    - Nested hashtables are merged recursively
    - Arrays are concatenated (Override first for priority)
    - Other values are replaced by Override

    .PARAMETER Base
    The base hashtable

    .PARAMETER Override
    The override hashtable

    .EXAMPLE
    $merged = Merge-Hashtable -Base $defaults -Override $userConfig
    #>
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
    <#
    .SYNOPSIS
    Merges system configuration with user configuration.

    .DESCRIPTION
    Convenience wrapper around Merge-Hashtable for config merging.

    .PARAMETER SysConfig
    System/default configuration

    .PARAMETER UserConfig
    User configuration (overrides)

    .EXAMPLE
    $config = Merge-Config -SysConfig $sysConfig -UserConfig $userConfig
    #>
    param(
        [hashtable]$SysConfig,
        [hashtable]$UserConfig
    )

    return Merge-Hashtable $SysConfig $UserConfig
}

# END core/config.ps1
# BEGIN core/constants.ps1
# ============================================================================
# Constants
# ============================================================================

# Common filenames
$script:ConfigFileName = 'config.psd1'
$script:UserConfigFileName = 'box.config.psd1'
$script:MakefileTemplateName = '.box/tpl/Makefile.template'

# END core/constants.ps1
# BEGIN core/directories.ps1
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

    # Remove .box internal directories (cache, tools)
    @(".box/cache", ".box/tools") | ForEach-Object {
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
    $statePath = Join-Path $BaseDir ".box/state.json"
    if (Test-Path $statePath) {
        Remove-Item $statePath -Force
        Write-Info "Removed .box/state.json"
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

# END core/directories.ps1
# BEGIN core/download.ps1
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

# END core/download.ps1
# BEGIN core/envs.ps1
# ============================================================================
# Environment Files Generation
# ============================================================================

function Generate-DotEnvFile {
    $envPath = Join-Path $BaseDir ".env"
    $state = Load-State

    $lines = @(
        "# Generated by box - DO NOT EDIT"
        "# Re-run 'box env update' to regenerate"
        "# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ""
        "# Project Settings"
    )

    # Project settings from merged config
    # Support: flat (PROJECT_NAME), nested (Project.Name), or direct (Name)
    if ($Config.PROJECT_NAME) {
        $lines += "PROJECT_NAME=$($Config.PROJECT_NAME)"
        $programName = if ($Config.PROGRAM_NAME) { $Config.PROGRAM_NAME } else { $Config.PROJECT_NAME }
        $lines += "PROGRAM_NAME=$programName"
    } elseif ($Config.Name) {
        $lines += "PROJECT_NAME=$($Config.Name)"
        $programName = if ($Config.ProgramName) { $Config.ProgramName } else { $Config.Name }
        $lines += "PROGRAM_NAME=$programName"
    } elseif ($Config.Project -and $Config.Project.Name) {
        $lines += "PROJECT_NAME=$($Config.Project.Name)"
        $lines += "PROGRAM_NAME=$($Config.Project.Name)"
    }

    if ($Config.DESCRIPTION) {
        $lines += "DESCRIPTION=$($Config.DESCRIPTION)"
    } elseif ($Config.Description) {
        $lines += "DESCRIPTION=$($Config.Description)"
    } elseif ($Config.Project -and $Config.Project.Description) {
        $lines += "DESCRIPTION=$($Config.Project.Description)"
    }

    if ($Config.VERSION) {
        $lines += "VERSION=$($Config.VERSION)"
    } elseif ($Config.Version) {
        $lines += "VERSION=$($Config.Version)"
    } elseif ($Config.Project -and $Config.Project.Version) {
        $lines += "VERSION=$($Config.Project.Version)"
    }

    $lines += ""
    $lines += "# Build Configuration"

    # Build settings - use keys as-is (no transformation)
    if ($Config.Build) {
        foreach ($key in $Config.Build.Keys) {
            $value = $Config.Build[$key]
            $lines += "$key=$value"
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
            Write-Host "    PROJECT_NAME = $($Config.Project.Name)" -ForegroundColor White
        }
        if ($Config.Project.Version) {
            Write-Host "    VERSION = $($Config.Project.Version)" -ForegroundColor White
        }
    }

    # Build configuration
    Write-Host ""
    Write-Host "  [Build Configuration]" -ForegroundColor Yellow
    if ($Config.Build) {
        foreach ($key in $Config.Build.Keys) {
            $value = $Config.Build[$key]
            Write-Host "    $key = $value" -ForegroundColor White
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

# END core/envs.ps1
# BEGIN core/extract.ps1
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

# END core/extract.ps1
# BEGIN core/help.ps1
# ============================================================================
# Help Functions
# ============================================================================

function Show-Help {
    Write-Host ""
    Write-Host "Usage: box [command] [subcommand]" -ForegroundColor Cyan
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

# END core/help.ps1
# BEGIN core/makefile.ps1
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

# END core/makefile.ps1
# BEGIN core/sevenzip.ps1
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
    @($BoxToolsDir, $CacheDir, $TempDir, $sevenZipTempDir) | ForEach-Object {
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

# END core/sevenzip.ps1
# BEGIN core/templates.ps1
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
        Path to config.psd1 file. Defaults to box.psd1 in current directory.

    .OUTPUTS
        [hashtable] Configuration variables from box.psd1

    .EXAMPLE
        $config = Get-ConfigBoxVariables
        # Returns: @{ PROJECT_NAME = "MyProject"; VERSION = "0.1.0" }
    #>
    param(
        [string]$ConfigPath = 'box.psd1'
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
        List all available template files in .box/tpl/

    .DESCRIPTION
        Discovers all .template files in .box/tpl/ directory.

    .PARAMETER TemplateDir
        Path to templates directory. Defaults to .box/tpl/

    .OUTPUTS
        [array] Array of template filenames (without .template extension)

    .EXAMPLE
        $templates = Get-AvailableTemplates
        # Returns: @( "Makefile", "README.md", "Makefile.amiga" )
    #>
    param(
        [string]$TemplateDir = '.box/tpl'
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

# ============================================================================
# BOX INIT - GENERATE FILES FROM TEMPLATES
# ============================================================================

function Invoke-BoxInit {
    <#
    .SYNOPSIS
        Generate project files from .box/tpl/ templates

    .DESCRIPTION
        Reads template files from .box/tpl/ and generates corresponding files
        in the project root. Replaces {{TOKEN}} placeholders with values from
        box.config.psd1 and .env.

        Only creates missing files - safe to re-run without overwriting existing files.

    .EXAMPLE
        Invoke-BoxInit
        Generates all missing files from templates
    #>

    Write-Host ""
    Write-Host "━" * 60 -ForegroundColor DarkCyan
    Write-Host "  Generating Files from Templates" -ForegroundColor Cyan
    Write-Host "━" * 60 -ForegroundColor DarkCyan

    # Check if we're in a project with .box/
    if (-not (Test-Path ".box")) {
        Write-Host "  ❌ Not in a DevBox project (no .box/ directory found)" -ForegroundColor Red
        Write-Host "  Run 'devbox init' to create a new project" -ForegroundColor Gray
        return
    }

    # Load configuration
    $configVars = Get-ConfigBoxVariables

    # Load environment variables
    $envVars = Get-TemplateVariables

    # Merge both (env overrides config)
    $allVars = $configVars.Clone()
    foreach ($key in $envVars.Keys) {
        $allVars[$key] = $envVars[$key]
    }

    # Find all template files
    $templatePath = ".box/tpl"
    if (-not (Test-Path $templatePath)) {
        Write-Host "  ❌ Template directory not found: $templatePath" -ForegroundColor Red
        return
    }

    $templates = Get-ChildItem -Path $templatePath -Filter "*.template*" -File
    if ($templates.Count -eq 0) {
        Write-Warning "No template files found in $templatePath"
        return
    }

    Write-Host ""
    $generated = 0
    $skipped = 0

    foreach ($template in $templates) {
        # Determine output filename
        $outputName = $template.Name -replace '\.template', ''
        $outputPath = Join-Path (Get-Location) $outputName

        # Skip if file already exists
        if (Test-Path $outputPath) {
            Write-Host "  ⏭️  Skipping $outputName (already exists)" -ForegroundColor Gray
            $skipped++
            continue
        }

        # Read template content
        $content = Get-Content $template.FullName -Raw -Encoding UTF8

        # Replace all {{TOKEN}} placeholders
        foreach ($key in $allVars.Keys) {
            $content = $content -replace "{{$key}}", $allVars[$key]
        }

        # Write output file
        try {
            Set-Content -Path $outputPath -Value $content -Encoding UTF8 -NoNewline
            Write-Host "  ✅ Generated $outputName" -ForegroundColor Green
            $generated++
        }
        catch {
            Write-Host "  ❌ Failed to create $outputName`: $_" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "━" * 60 -ForegroundColor DarkCyan
    Write-Host "  Summary: $generated generated, $skipped skipped" -ForegroundColor Cyan
    Write-Host "━" * 60 -ForegroundColor DarkCyan

    if ($generated -eq 0 -and $skipped -gt 0) {
        Write-Host ""
        Write-Host "  💡 All files already exist. Use 'box env update' to regenerate." -ForegroundColor Yellow
    }
}

# ============================================================================
# TAGGED FILE UPDATE SYSTEM (with Hooks)
# ============================================================================

function Update-TaggedFiles {
    <#
    .SYNOPSIS
        Updates tagged values in project files using environment variables.

    .DESCRIPTION
        Scans project files for tagged values and replaces them with current
        environment variable values. Supports hook system for box-specific
        replacement syntaxes.

        Core syntaxes:
        - ~value[VAR_NAME]~ : Universal tag (works in any text file)

        Box-specific syntaxes can be added via hooks in:
        boxers/<BoxName>/core/hooks.ps1

    .PARAMETER Path
        Path to file or directory to process. Defaults to current directory.

    .PARAMETER Recurse
        Process files recursively in subdirectories.

    .PARAMETER ReleaseMode
        If true, strips tags from output (for release builds).
        If false, preserves tags for future updates.

    .PARAMETER Variables
        Hashtable of variables to use for replacement. If not provided,
        loads from .env file.

    .EXAMPLE
        Update-TaggedFiles -Path "README.md"
        Updates tagged values in README.md

    .EXAMPLE
        Update-TaggedFiles -Path "." -Recurse
        Updates all tagged files in project recursively
    #>
    param(
        [string]$Path = ".",
        [switch]$Recurse,
        [switch]$ReleaseMode,
        [hashtable]$Variables = $null
    )

    # Load variables if not provided
    if (-not $Variables) {
        $Variables = Get-TemplateVariables
        if ($Variables.Count -eq 0) {
            Write-Verbose "No variables found in .env"
            return
        }
    }

    # Find files to process
    $files = @()
    if (Test-Path $Path -PathType Container) {
        $files = Get-ChildItem -Path $Path -File -Recurse:$Recurse
    } elseif (Test-Path $Path -PathType Leaf) {
        $files = @(Get-Item $Path)
    } else {
        Write-Warn "Path not found: $Path"
        return
    }

    if ($files.Count -eq 0) {
        Write-Verbose "No files to process"
        return
    }

    $processedCount = 0

    foreach ($file in $files) {
        # Skip binary files
        if (-not (Test-TextFile $file.FullName)) {
            continue
        }

        $text = Get-Content $file.FullName -Raw -Encoding UTF8
        $originalText = $text

        # Hook: Before replacement (box-specific syntaxes)
        if (Get-Command "Hook-BeforeTemplateReplace" -ErrorAction SilentlyContinue) {
            $text = Hook-BeforeTemplateReplace $text $Variables $ReleaseMode
        }

        # Core syntax: ~value[VAR_NAME]~
        $text = Apply-TildeSyntax $text $Variables $ReleaseMode

        # Hook: After replacement (box-specific post-processing)
        if (Get-Command "Hook-AfterTemplateReplace" -ErrorAction SilentlyContinue) {
            $text = Hook-AfterTemplateReplace $text $Variables $ReleaseMode
        }

        # Save if changed
        if ($text -ne $originalText) {
            Set-Content -Path $file.FullName -Value $text -Encoding UTF8 -NoNewline
            Write-Verbose "Updated: $($file.Name)"
            $processedCount++
        }
    }

    if ($processedCount -gt 0) {
        Write-Verbose "Updated $processedCount file(s)"
    }
}

function Apply-TildeSyntax {
    <#
    .SYNOPSIS
        Applies ~value[VAR]~ replacement syntax.

    .DESCRIPTION
        Replaces tagged values in format ~oldvalue[VAR_NAME]~

        In-place mode: ~oldvalue[VAR]~ → ~newvalue[VAR]~ (preserves tags)
        Release mode:  ~oldvalue[VAR]~ → newvalue (strips tags)
    #>
    param(
        [string]$Text,
        [hashtable]$Variables,
        [bool]$ReleaseMode
    )

    $Text = [regex]::Replace($Text, '~([^\[~]*?)(\[[^\]]+\]~)', {
        param($match)

        $taggedVar = $match.Groups[2].Value  # [VAR_NAME]~
        $varName = $taggedVar -replace '[\[\]~]', ''

        # Find matching variable (case-insensitive)
        $matchedKey = $Variables.Keys | Where-Object { $_ -ieq $varName } | Select-Object -First 1

        if ($matchedKey) {
            $newValue = $Variables[$matchedKey]

            if ($ReleaseMode) {
                # Release: strip tags completely
                return $newValue
            } else {
                # In-place: preserve tags, update value
                return "~$newValue$taggedVar"
            }
        }

        return $match.Value
    })

    return $Text
}

function Test-TextFile {
    <#
    .SYNOPSIS
        Tests if a file is a text file (not binary).
    #>
    param([string]$Path)

    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $buffer = New-Object byte[] 512
        $read = $stream.Read($buffer, 0, 512)
        $stream.Close()

        $sample = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)

        # If contains null bytes or control chars (except CR/LF/TAB), it's binary
        if ($sample -match "[\x00-\x08\x0B\x0E-\x1F]" -and $sample -notmatch "\r|\n|\t") {
            return $false
        }

        return $true
    }
    catch {
        return $false
    }
}


# END core/templates.ps1
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
# BEGIN core/wizard.ps1
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

# END core/wizard.ps1

# ============================================================================
# EMBEDDED modules/box/*.ps1 (box commands)
# ============================================================================

# BEGIN modules/box/clean.ps1
# ============================================================================
# Box Clean Module
# ============================================================================
#
# Handles box clean command - cleaning build artifacts

function Invoke-Box-Clean {
    <#
    .SYNOPSIS
    Cleans build artifacts from the project.

    .EXAMPLE
    box clean
    #>

    Write-Title "Cleaning Build Artifacts"

    # Clean common build directories
    $cleanDirs = @('build', 'dist', 'out', 'bin', 'obj')

    foreach ($dir in $cleanDirs) {
        $dirPath = Join-Path $BaseDir $dir
        if (Test-Path $dirPath) {
            Remove-Item $dirPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Success "Removed: $dir/"
        }
    }

    # Clean temp files
    Get-ChildItem -Path $BaseDir -Filter "*.tmp" -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $BaseDir -Filter "*.log" -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Success "Clean complete"
}

# END modules/box/clean.ps1
# BEGIN modules/box/env.ps1
# ============================================================================
# Box Env Module - Main Dispatcher
# ============================================================================
#
# Handles box env command with subcommands (list, load, replace, update)

function Invoke-Box-Env {
    <#
    .SYNOPSIS
    Manages environment variables for the project.

    .PARAMETER Sub
    Subcommand to execute: list, load, replace, update

    .EXAMPLE
    box env list
    box env load
    box env replace KEY=VALUE
    box env update
    #>

    param(
        [Parameter(Position=0)]
        [string]$Sub
    )

    # Default to list if no subcommand
    if (-not $Sub) {
        $Sub = 'list'
    }

    # Dispatch to appropriate subcommand
    switch ($Sub.ToLower()) {
        'list' {
            Invoke-Box-Env-List
        }
        'load' {
            Invoke-Box-Env-Load
        }
        'replace' {
            Invoke-Box-Env-Replace -KeyValue $args
        }
        'update' {
            Invoke-Box-Env-Update
        }
        default {
            Write-Host "Unknown env subcommand: $Sub" -ForegroundColor Red
            Write-Host "Available: list, load, replace, update" -ForegroundColor Gray
            exit 1
        }
    }
}

# END modules/box/env.ps1
# BEGIN modules/box/env\list.ps1
# ============================================================================
# Box Env Module - List subcommand
# ============================================================================

function Invoke-Box-Env-List {
    <#
    .SYNOPSIS
    Displays all environment variables configured for the project.

    .EXAMPLE
    box env list
    box env
    #>

    Write-Host ""
    Write-Host "Environment Variables:" -ForegroundColor Cyan
    Write-Host ""

    $state = Load-State
    if ($state.packages) {
        foreach ($pkgName in $state.packages.Keys) {
            $pkg = $state.packages[$pkgName]
            if ($pkg.envs) {
                Write-Host "  $pkgName" -ForegroundColor White
                foreach ($envName in $pkg.envs.Keys) {
                    $envValue = $pkg.envs[$envName]
                    Write-Host ("    {0,-20} = {1}" -f $envName, $envValue) -ForegroundColor Gray
                }
            }
        }
    } else {
        Write-Info "No packages installed yet"
    }

    Write-Host ""
}

# END modules/box/env\list.ps1
# BEGIN modules/box/env\load.ps1
# ============================================================================
# Box Env Module - Load subcommand
# ============================================================================

function Invoke-Box-Env-Load {
    <#
    .SYNOPSIS
    Loads .env file into current PowerShell session environment variables.

    .DESCRIPTION
    Reads .env file and sets all variables as environment variables in the
    current PowerShell session. Also adds .box/ and scripts/ to PATH.

    .EXAMPLE
    box env load
    #>

    $envFile = Join-Path $BaseDir ".env"

    if (-not (Test-Path $envFile)) {
        Write-Err ".env file not found. Run 'box env update' first."
        return
    }

    $loadedCount = 0
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^([^#=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            Set-Item "env:$key" $value
            $loadedCount++
        }
    }

    # Add .box and scripts to PATH
    $boxPath = Join-Path $BaseDir ".box"
    $scriptsPath = Join-Path $BaseDir "scripts"
    $env:PATH = "$boxPath;$scriptsPath;$env:PATH"

    Write-Success "Loaded $loadedCount variables from .env into session"
    Write-Info "Added to PATH: .box/, scripts/"
}

# END modules/box/env\load.ps1
# BEGIN modules/box/env\replace.ps1
# ============================================================================
# Box Env Module - Replace subcommand
# ============================================================================

function Invoke-Box-Env-Replace {
    <#
    .SYNOPSIS
    Replaces tagged values in files with environment variables.

    .DESCRIPTION
    Processes files and replaces tagged values with current environment
    variable values. Supports in-place updates (preserves tags) or
    release mode (strips tags).

    Syntaxes supported:
    - ~value[VAR_NAME]~ : Universal tag
    - Box-specific syntaxes via hooks (e.g., #define for C)

    .PARAMETER Path
    Path pattern to files to process (e.g., *.md, src/, README.md)

    .PARAMETER OutputDir
    If specified, copies processed files to this directory with tags stripped.
    If not specified, updates files in-place preserving tags.

    .PARAMETER Force
    Required for in-place updates to prevent accidental overwrites.

    .EXAMPLE
    box env replace *.md -Force
    Updates all Markdown files in-place

    .EXAMPLE
    box env replace . -OutputDir dist/ -Force
    Copies all files to dist/ with tags stripped (release mode)
    #>
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$OutputDir = $null,

        [switch]$Force
    )

    # Load variables
    $variables = Get-TemplateVariables
    if ($variables.Count -eq 0) {
        Write-Warn "No variables found in .env"
        return
    }

    # Determine mode
    $releaseMode = $null -ne $OutputDir

    # Require -Force for in-place updates
    if (-not $releaseMode -and -not $Force) {
        Write-Err "In-place replacement requires -Force flag"
        Write-Info "Use: box env replace $Path -Force"
        return
    }

    # Create output directory if needed
    if ($releaseMode -and -not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # Process files
    Update-TaggedFiles -Path $Path -ReleaseMode:$releaseMode -Variables $variables

    if ($releaseMode) {
        Write-Success "Files processed to $OutputDir (tags stripped)"
    } else {
        Write-Success "Files updated in-place (tags preserved)"
    }
}

# END modules/box/env\replace.ps1
# BEGIN modules/box/env\update.ps1
# ============================================================================
# Box Env Module - Update subcommand
# ============================================================================

function Invoke-Box-Env-Update {
    <#
    .SYNOPSIS
    Updates .env file and VS Code settings from installed packages.

    .DESCRIPTION
    Regenerates .env file from all installed package configurations,
    updates VS Code terminal environment variables, and updates
    tagged files throughout the project.

    .EXAMPLE
    box env update
    #>

    Generate-AllEnvFiles
    Update-VSCodeEnv
    Update-TaggedFiles -Path $BaseDir -Recurse
    Write-Success ".env updated"
}

function Update-VSCodeEnv {
    <#
    .SYNOPSIS
    Updates .vscode/settings.json with environment variables from .env file.
    Only updates the terminal.integrated.env.windows section.
    #>
    $envFile = Join-Path $BaseDir ".env"
    $settingsFile = Join-Path $BaseDir ".vscode\settings.json"

    if (-not (Test-Path $settingsFile)) {
        Write-Verbose ".vscode/settings.json not found, skipping VS Code env update"
        return
    }

    if (-not (Test-Path $envFile)) {
        Write-Verbose ".env file not found, skipping VS Code env update"
        return
    }

    # Parse .env file
    $envVars = @{}
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^([^#=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            # Remove quotes if present
            $value = $value -replace '^"(.*)"$', '$1'
            $value = $value -replace "^'(.*)'$", '$1'
            $envVars[$key] = $value
        }
    }

    if ($envVars.Count -eq 0) {
        Write-Verbose "No variables found in .env"
        return
    }

    # Read settings.json
    try {
        $settingsContent = Get-Content $settingsFile -Raw -Encoding UTF8
        $settings = $settingsContent | ConvertFrom-Json -AsHashtable
    }
    catch {
        Write-Warn "Failed to parse .vscode/settings.json: $_"
        return
    }

    # Update terminal.integrated.env.windows
    if (-not $settings.ContainsKey('terminal.integrated.env.windows')) {
        $settings['terminal.integrated.env.windows'] = @{}
    }

    # Merge .env vars into existing settings (keep user-added variables)
    $existingEnv = $settings['terminal.integrated.env.windows']
    foreach ($key in $envVars.Keys) {
        $existingEnv[$key] = $envVars[$key]
    }
    $settings['terminal.integrated.env.windows'] = $existingEnv

    # Save back to file
    try {
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
        Write-Verbose "Updated .vscode/settings.json with $($envVars.Count) environment variables"
    }
    catch {
        Write-Warn "Failed to save .vscode/settings.json: $_"
    }
}

# END modules/box/env\update.ps1
# BEGIN modules/box/info.ps1
# Box Info Command
# Display detailed information for current box workspace

function Invoke-Box-Info {
    Write-Host ""
    Write-Host "Box Workspace Information" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkGray
    Write-Host ""

    # Detect box.ps1 version (from embedded variable)
    $BoxVersion = if ($script:BoxerVersion) {
        $script:BoxerVersion
    } else {
        "Unknown"
    }

    Write-Host "Box Runtime:" -ForegroundColor Yellow
    Write-Host "  Version: $BoxVersion" -ForegroundColor Gray
    Write-Host ""

    # Read box metadata
    if ($script:BoxDir) {
        $metadataFile = Join-Path $script:BoxDir "metadata.psd1"

        if (Test-Path $metadataFile) {
            try {
                $metadata = Import-PowerShellDataFile -Path $metadataFile

                Write-Host "Box Information:" -ForegroundColor Yellow
                Write-Host "  Name:         $($metadata.BoxName)" -ForegroundColor Gray
                Write-Host "  Version:      $($metadata.Version)" -ForegroundColor Gray

                if ($metadata.BoxerVersion) {
                    Write-Host "  Core Version: $($metadata.BoxerVersion)" -ForegroundColor Gray
                }

                if ($metadata.BuildDate) {
                    Write-Host "  Build Date:   $($metadata.BuildDate)" -ForegroundColor Gray
                }

                if ($metadata.BoxType) {
                    Write-Host "  Type:         $($metadata.BoxType)" -ForegroundColor Gray
                }

                if ($metadata.Author) {
                    Write-Host "  Author:       $($metadata.Author)" -ForegroundColor Gray
                }

                if ($metadata.Tags) {
                    Write-Host "  Tags:         $($metadata.Tags -join ', ')" -ForegroundColor Gray
                }

                Write-Host ""
            } catch {
                Write-Host "Error reading metadata: $_" -ForegroundColor Red
                Write-Host ""
            }
        } else {
            Write-Host "No metadata.psd1 found in .box directory" -ForegroundColor Yellow
            Write-Host ""
        }
    }

    # Workspace info
    if ($script:BaseDir) {
        Write-Host "Workspace:" -ForegroundColor Yellow
        Write-Host "  Location: $script:BaseDir" -ForegroundColor Gray
        Write-Host ""
    }
}

# END modules/box/info.ps1
# BEGIN modules/box/install.ps1
# ============================================================================
# Box Install Module
# ============================================================================
#
# Handles box install command - installing packages in a project

function Invoke-Box-Install {
    <#
    .SYNOPSIS
    Installs all configured packages for the project.

    .EXAMPLE
    box install
    #>

    Write-Title "$($Config.Project.Name) Setup"

    # Run config wizard if needed
    if ($NeedsWizard) {
        if (-not (Invoke-ConfigWizard)) {
            return
        }
    }

    # Create directories
    Create-Directories

    # Ensure 7-Zip is available
    Ensure-SevenZip

    # Install all packages
    foreach ($pkg in $AllPackages) {
        try {
            Process-Package $pkg
        } catch {
            Write-Err "Failed to process $($pkg.Name): $_"
            Write-Info "Continuing with remaining packages..."
        }
    }

    # Cleanup
    Cleanup-Temp

    # Generate Makefile if box-specific
    if (Get-Command Setup-Makefile -ErrorAction SilentlyContinue) {
        Setup-Makefile
    }

    # Generate env files
    Generate-AllEnvFiles

    Show-InstallComplete
}

# END modules/box/install.ps1
# BEGIN modules/box/load.ps1
# ============================================================================
# Box Load Module
# ============================================================================
#
# Handles box load command - complete environment setup in one command

function Invoke-Box-Load {
    <#
    .SYNOPSIS
    Loads the complete Boxing environment in one command.

    .DESCRIPTION
    This command does everything needed to start working:
    1. Updates .env file from packages
    2. Updates VS Code settings
    3. Loads .env variables into current PowerShell session
    4. Adds .box/ and scripts/ to PATH

    .EXAMPLE
    box load
    #>
    param()

    Write-Host ""
    Write-Host "Loading Boxing environment..." -ForegroundColor Cyan
    Write-Host ""

    # 1. Generate .env file
    Write-Step "Updating .env file"
    Generate-AllEnvFiles
    Write-Success ".env updated"

    # 2. Update VS Code settings
    Write-Step "Updating VS Code settings"
    Update-VSCodeEnv
    Write-Success "VS Code env updated"

    # 3. Load .env into current session
    Write-Step "Loading environment into session"
    $envFile = Join-Path $BaseDir ".env"

    if (-not (Test-Path $envFile)) {
        Write-Err ".env file not found after update"
        return
    }

    $loadedCount = 0
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^([^#=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            Set-Item "env:$key" $value
            $loadedCount++
        }
    }
    Write-Success "Loaded $loadedCount variables into session"

    # 4. Add .box and scripts to PATH
    Write-Step "Updating PATH"
    $boxPath = Join-Path $BaseDir ".box"
    $scriptsPath = Join-Path $BaseDir "scripts"
    $env:PATH = "$boxPath;$scriptsPath;$env:PATH"
    Write-Success "Added .box/ and scripts/ to PATH"

    Write-Host ""
    Write-Host "✓ Boxing environment ready!" -ForegroundColor Green
    Write-Host ""
}

# END modules/box/load.ps1
# BEGIN modules/box/pkg.ps1
# ============================================================================
# Package Management Dispatcher
# ============================================================================
#
# Provides pkg subcommand dispatcher for direct package management CLI access.
# Routes commands: install, list, validate, uninstall, state

function Invoke-Box-Pkg {
    <#
    .SYNOPSIS
    Package management dispatcher for box pkg subcommands.

    .DESCRIPTION
    Routes pkg subcommands to appropriate handlers:
    - install: Install specific package by name
    - list: Display all installed packages
    - validate: Check package dependencies
    - uninstall: Remove specific package
    - state: Display package state from state.json
    - (no subcommand): Display help

    .PARAMETER Subcommand
    Package action to perform (install, list, validate, uninstall, state)

    .PARAMETER Args
    Arguments to pass to the subcommand handler

    .EXAMPLE
    Invoke-Box-Pkg 'list'
    Displays all installed packages

    .EXAMPLE
    Invoke-Box-Pkg 'install' @('NDK39')
    Installs the NDK39 package
    #>
    param(
        [Parameter(Position=0)]
        [string]$Subcommand,

        [Parameter(Position=1, ValueFromRemainingArguments=$true)]
        [string[]]$Args
    )

    # No subcommand or empty string -> show help
    if ([string]::IsNullOrWhiteSpace($Subcommand)) {
        Show-PkgHelp
        return
    }

    # Route to appropriate handler
    switch ($Subcommand.ToLower()) {
        'install' {
            if ($Args.Count -eq 0) {
                Write-Error "Package name required. Usage: box pkg install <name>"
                return
            }

            # Find package definition in config
            $packageName = $Args[0]
            $package = $AllPackages | Where-Object { $_.Name -eq $packageName }

            if (-not $package) {
                Write-Error "Package '$packageName' not found in config.psd1"
                Write-Host "Available packages:" -ForegroundColor Gray
                foreach ($pkg in $AllPackages) {
                    Write-Host "  - $($pkg.Name)" -ForegroundColor DarkGray
                }
                return
            }

            Process-Package -Item $package
        }

        'list' {
            Show-PackageList
        }

        'validate' {
            # Validate all packages
            Write-Host ""
            Write-Host "Validating package dependencies..." -ForegroundColor Cyan
            Write-Host ""

            $hasErrors = $false
            foreach ($pkg in $AllPackages) {
                try {
                    $envs = Validate-PackageDependencies -Package $pkg
                    Write-Host "  ✓ $($pkg.Name): Dependencies satisfied" -ForegroundColor Green
                }
                catch {
                    Write-Host "  ✗ $($pkg.Name): $_" -ForegroundColor Red
                    $hasErrors = $true
                }
            }

            Write-Host ""
            if ($hasErrors) {
                Write-Host "Some packages have dependency issues" -ForegroundColor Yellow
            } else {
                Write-Host "All package dependencies validated successfully" -ForegroundColor Green
            }
        }

        'uninstall' {
            if ($Args.Count -eq 0) {
                Write-Error "Package name required. Usage: box pkg uninstall <name>"
                return
            }

            $packageName = $Args[0]
            Remove-Package -Name $packageName
        }

        'state' {
            Show-PackageState
        }

        default {
            Write-Error "Unknown pkg subcommand: $Subcommand. Run 'box pkg' for help."
            Show-PkgHelp
        }
    }
}

function Show-PkgHelp {
    <#
    .SYNOPSIS
    Displays help text for pkg subcommands.

    .DESCRIPTION
    Shows available pkg subcommands with descriptions and usage examples.

    .EXAMPLE
    Show-PkgHelp
    #>

    Write-Host ""
    Write-Host "Package Management Commands:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  box pkg install <name>    " -NoNewline -ForegroundColor White
    Write-Host "Install specific package" -ForegroundColor Gray

    Write-Host "  box pkg list              " -NoNewline -ForegroundColor White
    Write-Host "List installed packages" -ForegroundColor Gray

    Write-Host "  box pkg validate          " -NoNewline -ForegroundColor White
    Write-Host "Validate package dependencies" -ForegroundColor Gray

    Write-Host "  box pkg uninstall <name>  " -NoNewline -ForegroundColor White
    Write-Host "Remove package" -ForegroundColor Gray

    Write-Host "  box pkg state             " -NoNewline -ForegroundColor White
    Write-Host "Display package state" -ForegroundColor Gray

    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  box pkg install NDK39" -ForegroundColor DarkGray
    Write-Host "  box pkg list" -ForegroundColor DarkGray
    Write-Host "  box pkg state" -ForegroundColor DarkGray
    Write-Host ""
}

# END modules/box/pkg.ps1
# BEGIN modules/box/status.ps1
# ============================================================================
# Box Status Module
# ============================================================================
#
# Handles box status command - showing project status

function Invoke-Box-Status {
    <#
    .SYNOPSIS
    Displays project status and configuration.

    .EXAMPLE
    box status
    #>

    Write-Host ""
    Write-Host "Project Status" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkGray
    Write-Host ""

    # Project info
    if ($Config.Project) {
        Write-Host "Project:" -ForegroundColor White
        Write-Host ("  Name:        {0}" -f $Config.Project.Name) -ForegroundColor Gray
        Write-Host ("  Description: {0}" -f $Config.Project.Description) -ForegroundColor Gray
        Write-Host ("  Version:     {0}" -f $Config.Project.Version) -ForegroundColor Gray
        Write-Host ""
    }

    # Packages status
    $state = Load-State
    $installedCount = 0
    $manualCount = 0

    if ($state.packages) {
        foreach ($pkgName in $state.packages.Keys) {
            $pkg = $state.packages[$pkgName]
            if ($pkg.installed) {
                $installedCount++
            } else {
                $manualCount++
            }
        }
    }

    Write-Host "Packages:" -ForegroundColor White
    Write-Host ("  Installed:   {0}" -f $installedCount) -ForegroundColor Green
    Write-Host ("  Manual:      {0}" -f $manualCount) -ForegroundColor Yellow
    Write-Host ("  Total:       {0}" -f ($installedCount + $manualCount)) -ForegroundColor Gray
    Write-Host ""

    # Directories
    Write-Host "Directories:" -ForegroundColor White
    Write-Host ("  Base:        {0}" -f $BaseDir) -ForegroundColor Gray
    Write-Host ("  Vendor:      {0}" -f $VendorDir) -ForegroundColor Gray
    Write-Host ("  Temp:        {0}" -f $TempDir) -ForegroundColor Gray
    Write-Host ""
}

# END modules/box/status.ps1
# BEGIN modules/box/uninstall.ps1
# ============================================================================
# Box Uninstall Module
# ============================================================================
#
# Handles box uninstall command - removing installed packages

function Invoke-Box-Uninstall {
    <#
    .SYNOPSIS
    Uninstalls all packages from the project.

    .EXAMPLE
    box uninstall
    #>

    Write-Title "Uninstall Environment"

    # Check for custom uninstall script
    $uninstallScript = Join-Path $BoxDir "uninstall.ps1"
    if (Test-Path $uninstallScript) {
        & $uninstallScript
    } else {
        # Default uninstall: remove all package files
        $state = Load-State
        if ($state.packages) {
            foreach ($pkgName in $state.packages.Keys) {
                Write-Step "Removing $pkgName"
                Remove-Package -Name $pkgName
            }
        }

        # Remove vendor directory
        if (Test-Path $VendorDir) {
            Remove-Item $VendorDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Success "Removed vendor directory"
        }

        # Remove state file
        if (Test-Path $StateFile) {
            Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
            Write-Success "Removed state file"
        }

        Write-Success "Uninstall complete"
    }
}

# END modules/box/uninstall.ps1
# BEGIN modules/box/version.ps1
# Box Version Command
# Display box runtime version (simple output like boxer version)

function Invoke-Box-Version {
    $BoxVersion = if ($script:BoxerVersion) {
        $script:BoxerVersion
    } else {
        "Unknown"
    }

    Write-Host "Box v$BoxVersion" -ForegroundColor Cyan
}

# END modules/box/version.ps1

# ============================================================================
# EMBEDDED modules/shared/pkg/*.ps1 (pkg module)
# ============================================================================

# BEGIN modules/shared/pkg/dependencies.ps1
# ============================================================================
# Package Dependency Validation Module
# ============================================================================
#
# Functions for validating package dependencies and manual configuration.

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

# END modules/shared/pkg/dependencies.ps1
# BEGIN modules/shared/pkg/install.ps1
# ============================================================================
# Package Installation Module
# ============================================================================
#
# Main package installation logic with user interaction and state management.

function Process-Package {
    <#
    .SYNOPSIS
    Processes a package installation with user interaction.

    .DESCRIPTION
    Handles the complete package installation workflow:
    - Checks if package already installed (system/vendor/env)
    - Prompts user for installation decisions
    - Downloads and extracts package
    - Updates package state
    - Handles manual configuration if user refuses install

    .PARAMETER Item
    Hashtable with package definition (Name, Url, File, Archive, Extract, Mode, etc.)

    .EXAMPLE
    Process-Package -Item $packageDef
    #>
    param([hashtable]$Item)

    $name = $Item.Name
    $mode = if ($Item.Mode) { $Item.Mode } else { "auto" }
    $pkgState = Get-PackageState $name
    $isInstalled = $pkgState -and $pkgState.installed
    $isManual = $pkgState -and -not $pkgState.installed
    $existingEnvs = if ($pkgState -and $pkgState.envs) { $pkgState.envs } else { @{} }

    Write-Step "$name - $($Item.Description)"

    # Check if package already installed via system/vendor/env
    $detection = Test-PackageInstalled -Package $Item

    # Skip the "install anyway?" prompt for local installations (state/vendor source)
    # Go directly to the "Local installation found" prompt instead
    if ($detection.Installed -and $detection.Source -notin @("state", "vendor")) {
        # Prompt user to use existing installation (global/system only)
        $sourceLabel = if ($detection.Source -eq "env") { "global" } elseif ($detection.Source -eq "command") { "system" } else { $detection.Source }
        Write-Info "Found $sourceLabel installation: $($detection.Path)"
        $useExisting = Ask-Choice "Install locally in project anyway? [y/N]"

        if ($useExisting -ne "Y") {
            Write-Success "Using $sourceLabel $name"
            # Don't save any state - we're just using the existing installation
            # The detection will find it again next time
            return
        }
        # User chose to install anyway, continue below
    }

    # Already installed -> ask: Keep, Reinstall, Manual
    if ($isInstalled) {
        $choice = Ask-Choice "Local installation found. [K]eep / [R]einstall / [M]anual?"

        switch ($choice) {
            "K" {
                Write-Info "Keeping existing local installation"
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
                # User refused install, validate dependencies
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

    # Detect SourceType
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

# END modules/shared/pkg/install.ps1
# BEGIN modules/shared/pkg/list.ps1
# ============================================================================
# Package List Module
# ============================================================================
#
# Functions for displaying package information.

function Show-PackageList {
    <#
    .SYNOPSIS
    Displays a formatted list of all packages with their status.

    .DESCRIPTION
    Shows a table with package names, environment variables, descriptions,
    and installation status with visual indicators.

    .EXAMPLE
    Show-PackageList
    #>
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

# END modules/shared/pkg/list.ps1
# BEGIN modules/shared/pkg/state.ps1
# ============================================================================
# Package State Display Module
# ============================================================================
#
# Functions for displaying package state information from .box/state.json.

function Show-PackageState {
    <#
    .SYNOPSIS
    Displays the current package state from .box/state.json.

    .DESCRIPTION
    Shows the raw package state for debugging purposes, including:
    - Installation status
    - Installed files and directories
    - Environment variable configurations
    - Installation timestamps

    .EXAMPLE
    Show-PackageState
    #>

    $statePath = Join-Path $ProjectRoot ".box\state.json"

    if (-not (Test-Path $statePath)) {
        Write-Host ""
        Write-Host "No package state file found (.box/state.json)" -ForegroundColor Yellow
        Write-Host "Run 'box install' to initialize package state" -ForegroundColor Gray
        Write-Host ""
        return
    }

    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json

        Write-Host ""
        Write-Host "Package State (.box/state.json):" -ForegroundColor Cyan
        Write-Host ""

        if (-not $state.packages -or $state.packages.PSObject.Properties.Count -eq 0) {
            Write-Host "  No packages installed" -ForegroundColor Gray
            Write-Host ""
            return
        }

        foreach ($pkgName in $state.packages.PSObject.Properties.Name) {
            $pkg = $state.packages.$pkgName

            Write-Host "  $pkgName" -ForegroundColor White
            Write-Host "    Installed: $($pkg.installed)" -ForegroundColor $(if ($pkg.installed) { "Green" } else { "Yellow" })

            if ($pkg.files -and $pkg.files.Count -gt 0) {
                Write-Host "    Files: $($pkg.files.Count) file(s)" -ForegroundColor Gray
            }

            if ($pkg.dirs -and $pkg.dirs.Count -gt 0) {
                Write-Host "    Directories: $($pkg.dirs.Count) dir(s)" -ForegroundColor Gray
            }

            if ($pkg.envs -and $pkg.envs.PSObject.Properties.Count -gt 0) {
                Write-Host "    Environment Variables:" -ForegroundColor Gray
                foreach ($envName in $pkg.envs.PSObject.Properties.Name) {
                    $envValue = $pkg.envs.$envName
                    Write-Host "      $envName = $envValue" -ForegroundColor DarkGray
                }
            }

            Write-Host ""
        }
    }
    catch {
        Write-Error "Failed to read package state: $_"
    }
}

# END modules/shared/pkg/state.ps1
# BEGIN modules/shared/pkg/uninstall.ps1
# ============================================================================
# Package Uninstallation Module
# ============================================================================
#
# Functions for removing installed packages.

function Remove-Package {
    <#
    .SYNOPSIS
    Removes an installed package.

    .DESCRIPTION
    Deletes all files and directories installed by the package,
    then removes the package state.

    .PARAMETER Name
    The package name

    .EXAMPLE
    Remove-Package -Name "vbcc"
    #>
    param([string]$Name)

    $pkgState = Get-PackageState $Name
    if (-not $pkgState) {
        Write-Warn "Package $Name not found in state"
        return
    }

    if ($pkgState.installed -and $pkgState.files) {
        Write-Info "Removing $($pkgState.files.Count) files and $($pkgState.dirs.Count) directories..."

        foreach ($file in $pkgState.files) {
            if (Test-Path $file) {
                Remove-Item $file -Recurse -Force -ErrorAction SilentlyContinue
                Write-Info "Removed: $file"
            }
        }
    }

    Remove-PackageState $Name
    Write-Success "Package $Name removed"
}

# END modules/shared/pkg/uninstall.ps1

# ============================================================================
# MAIN - Call Initialize-Boxing (Spec 010 architecture)
# ============================================================================

# Set embedded flag and mode before calling Initialize-Boxing
$script:IsEmbedded = $true
$script:Mode = 'box'

# Build arguments array (Command + remaining Arguments)
$allArgs = @()
if ($Command) {
    $allArgs += $Command
}
if ($Arguments) {
    $allArgs += $Arguments
}

# Call main bootstrapper with all arguments
Initialize-Boxing -Arguments $allArgs

