<#
.SYNOPSIS
    Boxer - Global Boxing Manager

.DESCRIPTION
    Standalone boxer.ps1 with embedded modules

.NOTES
    Build Date: 2026-01-05 05:34:46
    Version: 0.1.35
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
$script:BoxerVersion = "0.1.35"

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

    $modulesPath = Join-Path $script:BoxingRoot "modules\$Mode"

    if (-not (Test-Path $modulesPath)) {
        Write-Verbose "No modules found for mode: $Mode"
        return
    }

    $moduleFiles = Get-ChildItem -Path $modulesPath -Filter '*.ps1' | Sort-Object Name

    foreach ($file in $moduleFiles) {
        try {
            . $file.FullName

            $commandName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $script:Commands[$commandName] = $file.FullName
            $script:LoadedModules[$file.Name] = $file.FullName

            Write-Verbose "Loaded module: $Mode/$($file.Name)"
        }
        catch {
            Write-Warning "Failed to load module $($file.Name): $_"
        }
    }
}

# Register embedded commands (when modules are already loaded)
function Register-EmbeddedCommands {
    param([string]$Mode)

    # For embedded versions, register known commands
    if ($Mode -eq 'boxer') {
        $script:Commands['init'] = 'Invoke-Boxer-Init'
        $script:Commands['install'] = 'Install-Box'
        $script:Commands['list'] = 'Invoke-Boxer-List'
        $script:Commands['version'] = 'Invoke-Boxer-Version'
    }
    elseif ($Mode -eq 'box') {
        $script:Commands['install'] = 'Invoke-Box-Install'
        $script:Commands['env'] = 'Invoke-Box-Env'
        $script:Commands['clean'] = 'Invoke-Box-Clean'
        $script:Commands['status'] = 'Invoke-Box-Status'
        $script:Commands['uninstall'] = 'Invoke-Box-Uninstall'
        $script:Commands['version'] = 'Invoke-Box-Version'
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

# Export main entry point
# Export-ModuleMember removed (compiled script)

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
    Write-Host "Boxing - Reproducible Development Environment Manager" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow
    if ($script:Mode -eq 'boxer') {
        Write-Host "  boxer init <name>     Create a new Box project" -ForegroundColor White
        Write-Host "  boxer list            List available Box types" -ForegroundColor White
        Write-Host "  boxer install <url>   Install a Box from GitHub" -ForegroundColor White
    } else {
        Write-Host "  box install           Install workspace packages" -ForegroundColor White
        Write-Host "  box status            Show installation status" -ForegroundColor White
        Write-Host "  box env list          List environment variables" -ForegroundColor White
        Write-Host "  box clean             Clean installation" -ForegroundColor White
        Write-Host "  box uninstall         Remove all packages" -ForegroundColor White
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

function Invoke-Boxer-Init {
    <#
    .SYNOPSIS
    Creates a new Box project with full structure.

    .PARAMETER ProjectName
    Name of the project to create

    .PARAMETER Description
    Optional project description

    .EXAMPLE
    boxer init MyProject "My awesome project"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProjectName,
        [string]$Description = ""
    )

    # Sanitize project name
    $SafeName = $ProjectName -replace '[^\w\-]', '-'
    $TargetDir = Join-Path (Get-Location) $SafeName

    # Check if directory exists
    if (Test-Path $TargetDir) {
        Write-Err "Directory '$SafeName' already exists"
        return
    }

    Write-Step "Creating project: $ProjectName"

    try {
        # Create project directory
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

        # Create .box directory
        $BoxPath = Join-Path $TargetDir ".box"
        New-Item -ItemType Directory -Path $BoxPath -Force | Out-Null

        # Copy box.ps1 and boxing.ps1
        $LocalBoxPath = Join-Path (Split-Path -Parent $PSScriptRoot) "boxing.ps1"
        if (Test-Path $LocalBoxPath) {
            Copy-Item $LocalBoxPath (Join-Path $BoxPath "boxing.ps1") -Force
            Write-Success "Copied: boxing.ps1"
        }

        # Copy config.psd1
        $LocalConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) "config.psd1"
        if (Test-Path $LocalConfigPath) {
            Copy-Item $LocalConfigPath (Join-Path $BoxPath "config.psd1") -Force
            Write-Success "Copied: config.psd1"
        }

        # Create basic structure
        @('src', 'docs', 'scripts', 'vendor') | ForEach-Object {
            New-Item -ItemType Directory -Path (Join-Path $TargetDir $_) -Force | Out-Null
        }

        Write-Success "Project created: $SafeName"
        Write-Host "  Next steps:" -ForegroundColor Cyan
        Write-Host "    cd $SafeName" -ForegroundColor White
        Write-Host "    box install" -ForegroundColor White

    } catch {
        Write-Err "Project creation failed: $_"
        if (Test-Path $TargetDir) {
            Remove-Item $TargetDir -Recurse -Force -ErrorAction SilentlyContinue
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
                $boxerUrl = "https://raw.githubusercontent.com/vbuzzano/AmiDevBox/refs/heads/main/boxer.ps1"

                try {
                    Invoke-RestMethod -Uri $boxerUrl -OutFile $BoxerPath
                    Write-Success "Downloaded: boxer.ps1"
                } catch {
                    throw "Failed to download boxer.ps1 from $boxerUrl : $_"
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
        }        # Modify PowerShell profile
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
            Write-Success "Profile already configured (skipping)"
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
            Write-Success "Profile configured with Boxing loader"
        }

        # Install box if this is a box repository (not Boxing main repo)
        if ($SourceRepo) {
            Install-CurrentBox -BoxName $SourceRepo -BoxingDir $BoxingDir
        }

        # Determine if we need to configure profile and load functions
        $ProfileNeedsConfig = -not ($ProfileContent -match '#region boxing')
        $FunctionsNeedLoading = $ProfileNeedsConfig -or -not (Get-Command -Name boxer -ErrorAction SilentlyContinue)

        # Create/update init.ps1 only on first install or update
        if (-not $BoxerAlreadyInstalled -or $NeedsUpdate) {
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
        }

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
        } elseif ($NeedsUpdate) {
            # Update
            if ($FunctionsNeedLoading) {
                Write-Success "✓ Boxing functions loaded (boxer, box)"
            }
            Write-Host ""
            Write-Host "  💡 Restart PowerShell to apply changes" -ForegroundColor Yellow
        }
        # Else: already up-to-date, no message (already displayed earlier)

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
        $BaseUrl = "https://raw.githubusercontent.com/vbuzzano/$BoxName/refs/heads/main"

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
        } elseif ($RemoteBoxerVersion -and $InstalledBoxerVersion -and (Compare-Version -Version1 $RemoteBoxerVersion -Version2 $InstalledBoxerVersion) -gt 0) {
            $NeedsUpdate = $true
            $UpdateReason = "Updating $BoxName box (core $InstalledBoxerVersion → $RemoteBoxerVersion)..."
        } elseif ($RemoteVersion -and $InstalledVersion -and (Compare-Version -Version1 $RemoteVersion -Version2 $InstalledVersion) -eq 0) {
            Write-Success "$BoxName already up-to-date (v$InstalledVersion)"
            return
        } else {
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
            Write-Success "Downloaded: box.ps1"
        } catch {
            throw "Failed to download box.ps1: $_"
        }

        # Download config.psd1
        Write-Step "Downloading config.psd1..."
        try {
            Invoke-RestMethod -Uri "$BaseUrl/config.psd1" -OutFile (Join-Path $BoxDir "config.psd1")
            Write-Success "Downloaded: config.psd1"
        } catch {
            Write-Warn "config.psd1 not found (optional)"
        }

        # Download metadata.psd1
        Write-Step "Downloading metadata.psd1..."
        try {
            Invoke-RestMethod -Uri "$BaseUrl/metadata.psd1" -OutFile (Join-Path $BoxDir "metadata.psd1")
            Write-Success "Downloaded: metadata.psd1"
        } catch {
            Write-Warn "metadata.psd1 not found (optional)"
        }

        # Download env.ps1 (environment configuration)
        Write-Step "Downloading env.ps1..."
        try {
            Invoke-RestMethod -Uri "$BaseUrl/env.ps1" -OutFile (Join-Path $BoxDir "env.ps1")
            Write-Success "Downloaded: env.ps1"
        } catch {
            Write-Warn "env.ps1 not found (optional)"
        }

        # Download tpl/ directory (FILES ONLY, no subdirectories)
        Write-Step "Downloading templates..."
        $TplDir = Join-Path $BoxDir "tpl"
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
                    Write-Success "Downloaded: tpl/$($File.name)"
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
# Boxer Install Module
# ============================================================================
#
# Handles boxer install command - installing boxes from GitHub URLs

function Install-Box {
    <#
    .SYNOPSIS
    Installs a box from a GitHub URL.

    .PARAMETER BoxUrl
    GitHub repository URL (e.g., https://github.com/user/BoxName)

    .EXAMPLE
    boxer install https://github.com/vbuzzano/AmiDevBox
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$BoxUrl
    )

    Write-Step "Installing box from $BoxUrl..."

    try {
        # Parse GitHub URL to extract owner, repo, branch
        if ($BoxUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
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
# Handles boxer list command - listing available boxes

function Invoke-Boxer-List {
    <#
    .SYNOPSIS
    Lists all available Box types.

    .EXAMPLE
    boxer list
    #>
    Write-Host ""
    Write-Host "Available Boxes:" -ForegroundColor Cyan
    Write-Host ""

    $boxersPath = Join-Path (Split-Path -Parent $PSScriptRoot) "boxers"

    if (Test-Path $boxersPath) {
        Get-ChildItem -Path $boxersPath -Directory | ForEach-Object {
            $metadataPath = Join-Path $_.FullName "metadata.psd1"
            if (Test-Path $metadataPath) {
                $metadata = Import-PowerShellDataFile $metadataPath
                Write-Host ("  {0,-20} - {1}" -f $_.Name, $metadata.Description) -ForegroundColor White
            } else {
                Write-Host ("  {0,-20} - {1}" -f $_.Name, "(No description)") -ForegroundColor Gray
            }
        }
    } else {
        Write-Warn "No boxes found in: $boxersPath"
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

