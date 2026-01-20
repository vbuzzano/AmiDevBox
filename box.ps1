#Requires -Version 7.0
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
    Standalone box.ps1 with embedded core libraries and modules

.NOTES
    Build Date: 2026-01-20
    Version: 0.1.115
    Build Type: Embedded
#>

param(
    [Parameter(Position=0)]
    [string]$Command,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Find .box directory
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

# Global variables
$script:BoxingRoot = $BaseDir
$script:Mode = 'box'
$script:IsEmbedded = $true
$script:BoxerVersion = "0.1.115"
$script:LoadedModules = @{}
$script:Commands = @{}
$script:CommandRegistry = @{}
$script:BaseDir = $BaseDir
$script:BoxDir = $BoxDir
$script:VendorDir = Join-Path $BaseDir "vendor"
$script:TempDir = Join-Path $BaseDir "temp"
$script:StateFile = Join-Path $BoxDir "state.json"

# BEGIN core/bootstrapper.ps1
# Bootstrapper - Core initialization and mode detection
#
# Handles:
# - Mode detection (boxer vs box)
# - Core library loading
# - Global variables initialization

# Strict mode for better error detection
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Global variables
# Handle irm|iex context where $PSScriptRoot is empty
if (-not $script:BoxingRoot) {
    if ($PSScriptRoot) {
        $script:BoxingRoot = Split-Path -Parent $PSScriptRoot
    } else {
        # irm|iex context - use temp location or current directory
        $script:BoxingRoot = $env:TEMP
    }
}
if (-not $script:Mode) { $script:Mode = $null }
if (-not $script:LoadedModules) { $script:LoadedModules = @{} }
if (-not $script:Commands) { $script:Commands = @{} }
if (-not $script:CommandRegistry) { $script:CommandRegistry = @{} }
if (-not (Get-Variable -Name BoxerVersion -Scope Script -ErrorAction SilentlyContinue)) {
    $script:BoxerVersion = $null
}

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

    $coreFiles = Get-ChildItem -Path $corePath -Filter '*.ps1' |
        Where-Object { $_.Name -notin @('bootstrapper.ps1', 'module-loader.ps1', 'dispatcher.ps1', 'metadata.ps1') } |
        Sort-Object Name

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

# Main bootstrapping function
function Initialize-Boxing {
    param(
        [string[]]$Arguments = @()
    )

    try {
        # Auto-installation/update if executed via irm|iex
        # Check: no PSScriptRoot OR explicit IsIrmIexContext flag (set in embedded builds)
        $isIrmIex = (-not $PSScriptRoot) -or (Get-Variable -Name IsIrmIexContext -Scope Script -ValueOnly -ErrorAction SilentlyContinue)

        if ($isIrmIex -and $Arguments.Count -eq 0) {
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
                        Install-BoxingSystem

                        # Check if we're in a project directory with .box
                        Update-LocalBoxIfNeeded
                        return
                    } elseif ($InstalledVersion -and $CurrentVersion) {
                        # Already up-to-date or newer installed
                        Write-Host "✓ Boxer already up-to-date (v$InstalledVersion)" -ForegroundColor Green
                        # Check if box needs update (Install-BoxingSystem handles this)
                        Install-BoxingSystem

                        # Check if we're in a project directory with .box
                        Update-LocalBoxIfNeeded
                        return
                    }
                } catch {
                    # Version parsing failed, skip update
                }
            } else {
                # First-time installation
                Install-BoxingSystem
                return
            }
        }

        # Step 1: Detect mode
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

            $exitCode = Invoke-Command -CommandName $command -Arguments $cmdArgs
            if ($exitCode -and $exitCode -ne 0) { return $exitCode }
            return
        }
        else {
            Show-Help
            return
        }
    }
    catch {
        Write-Error "Boxing initialization failed: $_"
        return 1
    }
}

# Update local .box directory if needed
function Update-LocalBoxIfNeeded {
    try {
        $currentDir = Get-Location
        $localBoxDir = $null

        # Search for .box directory
        $testDir = $currentDir
        while ($testDir) {
            $boxPath = Join-Path $testDir '.box'
            if (Test-Path $boxPath) {
                $localBoxDir = $boxPath
                break
            }

            $parent = Split-Path $testDir -Parent
            if (-not $parent -or $parent -eq $testDir) { break }
            $testDir = $parent
        }

        if (-not $localBoxDir) { return }

        # Check version
        $localBoxPs1 = Join-Path $localBoxDir 'box.ps1'
        if (-not (Test-Path $localBoxPs1)) { return }

        $localContent = Get-Content $localBoxPs1 -Raw
        $localVersion = if ($localContent -match 'Version:\s*(\S+)') { $Matches[1] } else { $null }
        $newVersion = Get-BoxerVersion

        if (-not $localVersion -or -not $newVersion) { return }

        if ([version]$newVersion -gt [version]$localVersion) {
            Write-Host ""
            Write-Host "🔄 Updating local .box to v$newVersion" -ForegroundColor Cyan

            # Copy new box.ps1
            $boxerDir = "$env:USERPROFILE\Documents\PowerShell\Boxing"
            $sourceBox = Join-Path $boxerDir 'box.ps1'
            if (Test-Path $sourceBox) {
                Copy-Item -Path $sourceBox -Destination $localBoxPs1 -Force
            }

            # Remove boxer.ps1 if it was copied (not needed in projects)
            $boxerInProject = Join-Path $localBoxDir "boxer.ps1"
            if (Test-Path $boxerInProject) {
                Remove-Item -Path $boxerInProject -Force
            }

            Write-Host "✓ Local .box updated to v$newVersion" -ForegroundColor Green
            Write-Host ""
            Write-Host "⚠ Restart your PowerShell session to use the new version" -ForegroundColor Yellow
        }

    } catch {
        Write-Verbose "Failed to update local .box: $_"
    }
}

# ============================================================================
# Helper Functions for irm|iex Auto-Installation
# ============================================================================

function Get-InstalledVersion {
    <#
    .SYNOPSIS
    Gets the version from an installed boxer.ps1 file.

    .PARAMETER BoxerPath
    Path to boxer.ps1 file

    .OUTPUTS
    Version string (e.g., "1.0.0") or $null if not found
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$BoxerPath
    )

    if (-not (Test-Path $BoxerPath)) {
        return $null
    }

    try {
        $content = Get-Content $BoxerPath -Raw
        if ($content -match '\$script:BoxerVersion\s*=\s*"([^"]+)"') {
            return $Matches[1]
        }
        return $null
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

        # Get versions for comparison (read from actual file, not metadata)
        $InstalledVersion = Get-InstalledVersion -BoxerPath $BoxerPath

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

        # Check if profile already configured BEFORE modifying anything
        $ProfileIsReady = $ProfileContent -match '#region boxing'

        # Install box if this is a box repository (not Boxing main repo)
        if ($SourceRepo) {
            Install-CurrentBox -BoxName $SourceRepo -BoxingDir $BoxingDir
        }

        # Determine if we need to load functions in current session
        $FunctionsNeedLoading = (-not $ProfileIsReady) -or -not (Get-Command -Name boxer -ErrorAction SilentlyContinue)

        # Load functions in current session only if needed
        if ($FunctionsNeedLoading) {
            Set-Item -Path function:global:boxer -Value {
                $boxerPath = "$env:USERPROFILE\Documents\PowerShell\Boxing\boxer.ps1"
                if (Test-Path $boxerPath) {
                    & $boxerPath @args
                } else {
                    Write-Host "Error: boxer.ps1 not found at $boxerPath" -ForegroundColor Red
                }
            }

            Set-Item -Path function:global:box -Value {
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

        # Configure profile if needed (AFTER loading functions in current session)
        if (-not $ProfileIsReady) {
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
        } else {
            Write-Success "Profile ready"
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
            Write-Host ""
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
        $BoxScriptPath = Join-Path $BoxDir "box.ps1"

        # Base URL for downloads
        $BaseUrl = "https://raw.githubusercontent.com/vbuzzano/$BoxName/main"

        # Get installed version from box.ps1 file (source of truth)
        $InstalledVersion = Get-InstalledVersion -BoxerPath $BoxScriptPath
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

        # Remove existing box directory if updating (clean install)
        if (Test-Path $BoxDir) {
            Remove-Item -Path $BoxDir -Recurse -Force
        }

        # Create fresh box directory
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


# END core/bootstrapper.ps1
# BEGIN core/metadata.ps1
# Metadata - Handler and descriptor utilities
#
# Handles:
# - Metadata handler resolution
# - Descriptor field access
# - Descriptor help display
# - Handler invocation

# Parse metadata handler string into executable descriptor
function Resolve-MetadataHandler {
    param(
        [string]$ModulePath,
        [string]$Value
    )

    if (-not $Value) { return $null }

    if ($Value -like '*::*') {
        $parts = $Value -split '::', 2
        return @{
            Type = 'file-function'
            Path = Join-Path $ModulePath $parts[0]
            Function = $parts[1]
        }
    }

    if ($Value -like '*.ps1') {
        return @{
            Type = 'script'
            Path = Join-Path $ModulePath $Value
        }
    }

    return @{
        Type = 'function'
        Function = $Value
        ModulePath = $ModulePath
    }
}

# Safe descriptor lookup
function Get-DescriptorField {
    param(
        [hashtable]$Descriptor,
        [string]$Key
    )

    if ($Descriptor -and $Descriptor.ContainsKey($Key)) {
        return $Descriptor[$Key]
    }

    return $null
}

# Execute handler descriptor consistently
function Invoke-HandlerDescriptor {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Descriptor,
        [object[]]$Arguments = @()
    )

    switch ($Descriptor.Type) {
        'script' {
            if ($Arguments.Count -gt 0 -and $Arguments[0] -is [hashtable]) {
                $splat = $Arguments[0]
                $rest = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @() }
                & $Descriptor.Path @splat @rest
            }
            else {
                & $Descriptor.Path @Arguments
            }
        }
        'function' {
            if ($Descriptor.ContainsKey('ModulePath') -and $Descriptor.ModulePath) {
                if (-not (Get-Command -Name $Descriptor.Function -ErrorAction SilentlyContinue)) {
                    Get-ChildItem -Path $Descriptor.ModulePath -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
                        Where-Object { (Select-String -Path $_.FullName -Pattern 'function\s+' -Quiet) } |
                        ForEach-Object { . $_.FullName }
                }
            }

            if ($Arguments.Count -gt 0 -and $Arguments[0] -is [hashtable]) {
                $splat = $Arguments[0]
                $rest = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @() }
                & $Descriptor.Function @splat @rest
            }
            else {
                & $Descriptor.Function @Arguments
            }
        }
        'file-function' {
            . $Descriptor.Path

            if ($Arguments.Count -gt 0 -and $Arguments[0] -is [hashtable]) {
                $splat = $Arguments[0]
                $rest = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @() }
                & $Descriptor.Function @splat @rest
            }
            else {
                & $Descriptor.Function @Arguments
            }
        }
        default { throw "Unsupported handler type: $($Descriptor.Type)" }
    }
}

# Display help for a handler descriptor
function Show-DescriptorHelp {
    param([hashtable]$Descriptor)

    if (-not $Descriptor) { return }

    switch ($Descriptor.Type) {
        'script' { Get-Help $Descriptor.Path -ErrorAction SilentlyContinue | Out-String | Write-Output }
        'function' { Get-Help $Descriptor.Function -ErrorAction SilentlyContinue | Out-String | Write-Output }
        'file-function' {
            . $Descriptor.Path
            Get-Help $Descriptor.Function -ErrorAction SilentlyContinue | Out-String | Write-Output
        }
        default { Write-Output "No help available" }
    }
}

# END core/metadata.ps1
# BEGIN core/module-loader.ps1
# Module Loader - Module discovery and registration
#
# Handles:
# - External module discovery
# - Module registration (file, directory, metadata)
# - Mode-specific module loading
# - Shared module loading

# Build list of external module roots by mode and priority
# box-override: External modules in .box/modules/ and modules/ override embedded modules
function Get-ExternalModuleRoots {
    param([string]$Mode)

    $roots = @()

    if ($Mode -eq 'box') {
        $projectRoot = Get-Location
        # box-override priority: custom modules before project modules
        $roots += @{ Path = Join-Path $projectRoot '.box\modules'; Source = 'custom' }
        $roots += @{ Path = Join-Path $projectRoot 'modules'; Source = 'project' }
    }
    else {
        $roots += @{ Path = Join-Path $script:BoxingRoot 'modules'; Source = 'custom' }
    }

    return $roots | Where-Object { Test-Path $_.Path }
}

# Register external modules (files, directories, metadata)
function Register-ExternalModules {
    param(
        [string]$Root,
        [string]$Source,
        [string]$Mode
    )

    if (-not (Test-Path $Root)) {
        return
    }

    $fileModules = Get-ChildItem -Path $Root -File -Filter '*.ps1' -ErrorAction SilentlyContinue
    foreach ($file in $fileModules) {
        $commandName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).ToLower()

        if ($commandName -eq 'help') {
            Write-Warning "Command 'help' is reserved (builtin). Module '$($file.Name)' ignored."
            continue
        }

        if ($script:CommandRegistry.ContainsKey($commandName)) { continue }

        $script:Commands[$commandName] = $file.FullName
        $script:CommandRegistry[$commandName] = @{
            Name = $commandName
            Kind = 'external-file'
            Source = $Source
            Handler = $file.FullName
        }

        $script:LoadedModules[$file.Name] = $file.FullName
        Write-Verbose "Registered external file ($Source): $commandName"
    }

    $directories = Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $directories) {
        if ($Mode -and (@('box', 'boxer', 'shared') -contains $dir.Name.ToLower())) { continue }
        $metadataPath = Join-Path $dir.FullName 'metadata.psd1'
        if (Test-Path $metadataPath) {
            Register-MetadataModule -ModulePath $dir.FullName -Source $Source
        }
        else {
            Register-ExternalDirectoryModule -ModulePath $dir.FullName -ModuleName $dir.Name -Source $Source
        }
    }
}

# Register a directory-based module (no metadata)
function Register-ExternalDirectoryModule {
    param(
        [string]$ModulePath,
        [string]$ModuleName,
        [string]$Source
    )

    $commandName = $ModuleName.ToLower()

    if ($commandName -eq 'help') {
        Write-Warning "Command 'help' is reserved (builtin). Module directory '$ModuleName' ignored."
        return
    }

    $ps1Files = Get-ChildItem -Path $ModulePath -File -Filter '*.ps1' -ErrorAction SilentlyContinue
    $subcommands = @{}
    $defaultHandler = $null
    $helpHandler = $null

    foreach ($file in $ps1Files) {
        $name = $file.BaseName.ToLower()

        switch ($name) {
            'metadata' { continue }
            'help' { $helpHandler = $file.FullName; continue }
            {$name -eq $ModuleName.ToLower()} { $defaultHandler = $file.FullName; continue }
            default { $subcommands[$name] = $file.FullName }
        }
    }

    if ($script:CommandRegistry.ContainsKey($ModuleName.ToLower())) { return }

    $mappedValue = if ($defaultHandler) { $defaultHandler } else { $ModulePath }
    $script:Commands[$ModuleName.ToLower()] = $mappedValue
    $script:CommandRegistry[$ModuleName.ToLower()] = @{
        Name = $ModuleName.ToLower()
        Kind = 'external-directory'
        Source = $Source
        Subcommands = $subcommands
        DefaultHandler = $defaultHandler
        HelpHandler = $helpHandler
        Root = $ModulePath
    }

    Write-Verbose "Registered external directory ($Source): $ModuleName"
}

# Register metadata-driven module commands
function Register-MetadataModule {
    param(
        [string]$ModulePath,
        [string]$Source
    )

    $metadataPath = Join-Path $ModulePath 'metadata.psd1'

    try {
        $metadata = Import-PowerShellDataFile -Path $metadataPath
    }
    catch {
        Write-Warning "Failed to load metadata.psd1 for module at ${ModulePath}: $($_)"
        return
    }

    $missing = @()

    foreach ($key in @('ModuleName', 'Commands')) {
        if (-not $metadata.ContainsKey($key) -or -not $metadata[$key]) {
            $missing += $key
        }
    }

    if ($missing.Count -gt 0) {
        Write-Warning "Metadata module $ModulePath missing required keys: $($missing -join ', ')"
        return
    }

    $moduleName = $metadata.ModuleName

    $helpHandler = $null
    $helpFile = Join-Path $ModulePath 'help.ps1'
    if (Test-Path $helpFile) { $helpHandler = $helpFile }

    foreach ($entry in $metadata.Commands.GetEnumerator()) {
        $cmdName = $entry.Key.ToLower()

        if ($cmdName -eq 'help') {
            Write-Warning "Command 'help' is reserved (builtin). Metadata command '$cmdName' in module '$moduleName' ignored."
            continue
        }

        if ($script:CommandRegistry.ContainsKey($cmdName)) { continue }

        $config = $entry.Value
        $hasHandler = ($config.ContainsKey('Handler') -and -not [string]::IsNullOrWhiteSpace($config['Handler']))
        $hasDispatcher = ($config.ContainsKey('Dispatcher') -and -not [string]::IsNullOrWhiteSpace($config['Dispatcher']))
        $hasSubcommands = ($config.ContainsKey('Subcommands') -and $config['Subcommands'])

        if ($hasHandler -and $hasDispatcher) {
            Write-Warning "Metadata command $cmdName cannot define both Handler and Dispatcher. Skipping."
            continue
        }

        if (-not $hasHandler -and -not $hasDispatcher -and -not $hasSubcommands) {
            Write-Warning "Metadata command $cmdName must define Handler, Dispatcher, or Subcommands. Skipping."
            continue
        }

        $handler = $null
        $dispatcher = $null

        if ($hasHandler) {
            $handler = Resolve-MetadataHandler -ModulePath $ModulePath -Value $config['Handler']
            if (-not $handler) {
                Write-Warning "Metadata command $cmdName has invalid Handler. Skipping."
                continue
            }
        }

        if ($hasDispatcher) {
            $dispatcher = Resolve-MetadataHandler -ModulePath $ModulePath -Value $config['Dispatcher']
            if (-not $dispatcher) {
                Write-Warning "Metadata command $cmdName has invalid Dispatcher. Skipping."
                continue
            }
        }

        $subcommands = @{}
        if ($hasSubcommands) {
            foreach ($subEntry in $config['Subcommands'].GetEnumerator()) {
                $subValue = $subEntry.Value
                $subHandler = if ($subValue.ContainsKey('Handler')) { Resolve-MetadataHandler -ModulePath $ModulePath -Value $subValue['Handler'] } else { $null }
                if (-not $subHandler) {
                    Write-Warning "Metadata subcommand $($subEntry.Key.ToLower()) for $cmdName missing valid Handler. Skipping subcommand."
                    continue
                }
                $subcommands[$subEntry.Key.ToLower()] = @{
                    Name = $subEntry.Key.ToLower()
                    Handler = $subHandler
                    Synopsis = if ($subValue.ContainsKey('Synopsis')) { $subValue['Synopsis'] } else { $null }
                    Description = if ($subValue.ContainsKey('Description')) { $subValue['Description'] } else { $null }
                }
            }
        }

        $script:Commands[$cmdName] = $ModulePath
        $script:CommandRegistry[$cmdName] = @{
            Name = $cmdName
            Kind = 'metadata'
            Source = $Source
            ModuleName = $moduleName
            ModulePath = $ModulePath
            Handler = $handler
            Dispatcher = $dispatcher
            Subcommands = $subcommands
            HelpHandler = $helpHandler
            Synopsis = if ($config.ContainsKey('Synopsis')) { $config['Synopsis'] } else { $null }
            Description = if ($config.ContainsKey('Description')) { $config['Description'] } else { $null }
            Hidden = if ($config.ContainsKey('Hidden')) { [bool]$config['Hidden'] } else { $false }
        }

        Write-Verbose "Registered metadata command ($Source): $cmdName"
    }
}

# Discover and load mode-specific modules
function Import-ModeModules {
    param([string]$Mode)

    if (-not $Mode) {
        $Mode = Initialize-Mode
    }

    $script:Mode = $Mode

    if (-not $script:CommandRegistry) {
        $script:CommandRegistry = @{}
    }

    if ($script:IsEmbedded) {
        Write-Verbose "Embedded mode: $Mode modules already loaded"
        Register-EmbeddedCommands -Mode $Mode
        return
    }

    $roots = Get-ExternalModuleRoots -Mode $Mode

    foreach ($root in $roots) {
        Register-ExternalModules -Root $root.Path -Source $root.Source -Mode $Mode
    }

    $modulesPath = Join-Path $script:BoxingRoot "modules\$Mode"

    if (Test-Path $modulesPath) {
        $moduleFiles = Get-ChildItem -Path $modulesPath -Filter '*.ps1' | Sort-Object Name

        foreach ($file in $moduleFiles) {
            try {
                . $file.FullName

                $commandName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

                if (-not $script:Commands.ContainsKey($commandName)) {
                    $script:Commands[$commandName] = $file.FullName
                }

                if (-not $script:LoadedModules.ContainsKey($file.Name)) {
                    $script:LoadedModules[$file.Name] = $file.FullName
                }

                Write-Verbose "Loaded module (embedded): $Mode/$($file.Name)"
            }
            catch {
                Write-Warning "Failed to load module $($file.Name): $_"
            }
        }
    }

    Register-EmbeddedCommands -Mode $Mode
}

# Register embedded commands (when modules are already loaded)
function Register-EmbeddedCommands {
    param([string]$Mode)

    # For embedded versions, discover commands dynamically by scanning loaded functions
    $modeName = if ($Mode) { ($Mode.Substring(0,1).ToUpper() + $Mode.Substring(1).ToLower()) } else { $Mode }
    $prefix = "Invoke-$modeName-"
    $functions = Get-Command -Name "$prefix*" -CommandType Function -ErrorAction SilentlyContinue | Sort-Object Name

    # Group functions by command
    $commandGroups = @{}

    foreach ($func in $functions) {
        $funcName = $func.Name
        $namePart = $funcName.Substring($prefix.Length)

        # Split into Command and (Optional) Subcommand
        # Invoke-Box-Pkg -> "pkg" (no subcommand)
        # Invoke-Box-Pkg-Install -> "pkg", "install"

        $parts = $namePart -split '-', 2
        $commandName = $parts[0].ToLower()
        $subcommandName = if ($parts.Count -gt 1) { $parts[1].ToLower() } else { $null }

        if (-not $commandGroups.ContainsKey($commandName)) {
            $commandGroups[$commandName] = @{
                DefaultHandler = $null
                Subcommands = @{}
                Synopsis = $null
            }
        }

        $group = $commandGroups[$commandName]

        if (-not $subcommandName) {
            # This is the Default Handler (e.g. Invoke-Box-Pkg)
            $group.DefaultHandler = $funcName

            # Extract synopsis from main handler
            $helpInfo = Get-Help $funcName -ErrorAction SilentlyContinue
            if ($helpInfo -and $helpInfo.Synopsis -and $helpInfo.Synopsis -ne $funcName) {
                 $group.Synopsis = $helpInfo.Synopsis
            }
        } else {
            # This is a Subcommand (e.g. Invoke-Box-Pkg-Install)
            # Extract help info for the subcommand
            $subHelpInfo = Get-Help $funcName -ErrorAction SilentlyContinue
            $subSynopsis = if ($subHelpInfo -and $subHelpInfo.Synopsis -and $subHelpInfo.Synopsis -ne $funcName) { $subHelpInfo.Synopsis } else { $null }
            $subDescription = if ($subHelpInfo -and $subHelpInfo.Description) { ($subHelpInfo.Description | Out-String).Trim() } else { $null }
            
            $group.Subcommands[$subcommandName] = @{
                Handler = @{ Type = 'function'; Function = $funcName }
                Synopsis = $subSynopsis
                Description = $subDescription
            }
        }
    }

    # Register commands
    foreach ($entry in $commandGroups.GetEnumerator()) {
        $commandName = $entry.Key
        $group = $entry.Value

        if ($script:CommandRegistry.ContainsKey($commandName)) {
            Write-Verbose "Skipping duplicate embedded command: $commandName"
            continue
        }

        if (-not $script:Commands.ContainsKey($commandName)) {
            $script:Commands[$commandName] = if ($group.DefaultHandler) { $group.DefaultHandler } else { "group:$commandName" }
        }

        # Determine Kind
        # If it has subcommands, treat as 'external-directory' (supports Subcommands + DefaultHandler)
        # If ONLY default handler, treat as 'embedded' (simple)

        if ($group.Subcommands.Count -gt 0) {
             $script:CommandRegistry[$commandName] = @{
                Name = $commandName
                Kind = 'external-directory' # Reusing logic that supports Subcommands + DefaultHandler
                Source = 'built-in'
                Subcommands = $group.Subcommands
                DefaultHandler = $group.DefaultHandler
                Synopsis = $group.Synopsis
             }
             Write-Verbose "Registered embedded group: $commandName ($($group.Subcommands.Count) subcommands)"
        } else {
             $script:CommandRegistry[$commandName] = @{
                Name = $commandName
                Kind = 'embedded'
                Source = 'built-in'
                Handler = $group.DefaultHandler
                Path = (Get-Command $group.DefaultHandler).ScriptBlock.File
                Synopsis = $group.Synopsis
             }
             Write-Verbose "Registered embedded command: $commandName -> $($group.DefaultHandler)"
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

    $moduleDirs = Get-ChildItem -Path $sharedPath -Directory -Recurse

    foreach ($moduleDir in $moduleDirs) {
        $metadataPath = Join-Path $moduleDir.FullName 'metadata.psd1'
        if (-not (Test-Path $metadataPath)) {
            throw "Shared module missing metadata.psd1: $($moduleDir.FullName)"
        }

        $metadata = Import-PowerShellDataFile -Path $metadataPath

        $missingKeys = @()
        if (-not $metadata.ContainsKey('ModuleName') -or [string]::IsNullOrWhiteSpace($metadata.ModuleName)) {
            $missingKeys += 'ModuleName'
        }
        if (-not $metadata.ContainsKey('Commands') -or -not $metadata.Commands -or $metadata.Commands.Count -eq 0) {
            $missingKeys += 'Commands'
        }

        if ($missingKeys.Count -gt 0) {
            throw "Shared module $($moduleDir.FullName) missing required metadata keys: $($missingKeys -join ', ')"
        }

        $moduleName = $metadata.ModuleName
        $privateFunctions = @()
        if ($metadata.ContainsKey('PrivateFunctions')) {
            $privateFunctions = $metadata.PrivateFunctions
        }

        $moduleFiles = Get-ChildItem -Path $moduleDir.FullName -Filter '*.ps1'

        foreach ($file in $moduleFiles) {
            . $file.FullName
            Write-Verbose "Loaded shared module: $moduleName/$($file.Name)"
        }

        $missingCommands = @()
        foreach ($cmd in $metadata.Commands) {
            $boxFunc = "Invoke-Box-$cmd"
            $boxerFunc = "Invoke-Boxer-$cmd"
            $boxCmd = Get-Command -Name $boxFunc -CommandType Function -ErrorAction SilentlyContinue
            $boxerCmd = Get-Command -Name $boxerFunc -CommandType Function -ErrorAction SilentlyContinue

            $hasEntry = $false
            if ($boxCmd -and $boxCmd.ScriptBlock.File -like "$($moduleDir.FullName)*") { $hasEntry = $true }
            if ($boxerCmd -and $boxerCmd.ScriptBlock.File -like "$($moduleDir.FullName)*") { $hasEntry = $true }

            if (-not $hasEntry) {
                $missingCommands += $cmd
            }
            else {
                $script:Commands[$cmd] = $moduleName

                if (-not $script:CommandRegistry.ContainsKey($cmd)) {
                    $script:CommandRegistry[$cmd] = @{
                        Name = $cmd
                        Kind = 'embedded'
                        Source = 'built-in'
                        Handler = if ($boxCmd) { $boxFunc } elseif ($boxerCmd) { $boxerFunc } else { $null }
                    }
                }
            }
        }

        if ($missingCommands.Count -gt 0) {
            throw "Shared module $($moduleDir.FullName) missing entrypoints for commands: $($missingCommands -join ', ')"
        }

        $moduleFunctions = Get-Command -Name 'Invoke-*' -CommandType Function -ErrorAction SilentlyContinue | Where-Object { $_.ScriptBlock.File -like "$($moduleDir.FullName)*" }
        $unexpected = @()
        foreach ($func in $moduleFunctions) {
            if ($func.Name -match '^Invoke-[^-]+-(?<cmd>[^-]+)') {
                $cmdName = $matches['cmd']
                if (-not $metadata.Commands -or -not ($metadata.Commands -contains $cmdName)) {
                    if (-not ($privateFunctions -contains $cmdName)) {
                        $unexpected += $cmdName
                    }
                }
            }
        }

        if ($unexpected.Count -gt 0) {
            throw "Shared module $($moduleDir.FullName) has undeclared functions: $($unexpected -join ', ')"
        }

        $script:LoadedModules[$moduleName] = $moduleDir.FullName
    }
}

# END core/module-loader.ps1
# BEGIN core/dispatcher.ps1
# Dispatcher - Command routing and invocation
#
# Handles:
# - Command dispatching
# - Help system integration
# - Subcommand routing
# - Dispatcher descriptor invocation

# Show available subcommands for directory/metadata modules
function Show-SubcommandHelp {
    param(
        [hashtable]$Entry
    )

    $lines = @()
    $lines += "Available subcommands for $($Entry.Name):"

    $subNames = $Entry.Subcommands.Keys | Sort-Object
    foreach ($name in $subNames) {
        $sub = $Entry.Subcommands[$name]
        $desc = ''
        if ($sub -is [hashtable]) {
            $subDescription = Get-DescriptorField -Descriptor $sub -Key 'Description'
            $subSynopsis = Get-DescriptorField -Descriptor $sub -Key 'Synopsis'
            if ($subDescription) { $desc = $subDescription }
            elseif ($subSynopsis) { $desc = $subSynopsis }
        }

        $line = "  $name"
        if ($desc) { $line += " - $desc" }
        $lines += $line
    }

    $lines | ForEach-Object { Write-Output $_ }
}

# Invoke dispatcher descriptor with explicit parameters
function Invoke-DispatcherDescriptor {
    param(
        [hashtable]$Descriptor,
        [string[]]$CommandPath,
        [string[]]$Arguments
    )

    switch ($Descriptor.Type) {
        'function' {
            if ($Descriptor.ContainsKey('ModulePath') -and $Descriptor.ModulePath) {
                if (-not (Get-Command -Name $Descriptor.Function -ErrorAction SilentlyContinue)) {
                    Get-ChildItem -Path $Descriptor.ModulePath -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
                        Where-Object { (Select-String -Path $_.FullName -Pattern 'function\s+' -Quiet) } |
                        ForEach-Object { . $_.FullName }
                }
            }

            return (& $Descriptor.Function -CommandPath $CommandPath -Arguments $Arguments)
        }
        'script' {
            return (& $Descriptor.Path -CommandPath $CommandPath -Arguments $Arguments)
        }
        'file-function' {
            . $Descriptor.Path
            return (& $Descriptor.Function -CommandPath $CommandPath -Arguments $Arguments)
        }
        default {
            throw "Unsupported dispatcher type: $($Descriptor.Type)"
        }
    }
}

# Dispatch command to appropriate handler
function Invoke-Command {
    param(
        [string]$CommandName,
        [string[]]$Arguments
    )

    $normalized = $CommandName.ToLower()

    if ($normalized -eq 'help') {
        Show-Help -CommandPath $Arguments
        return
    }

    if (-not $script:CommandRegistry.ContainsKey($normalized)) {
        Write-Error "Unknown command: $CommandName"
        Show-Help
        return 1
    }

    $entry = $script:CommandRegistry[$normalized]
    $kind = Get-DescriptorField -Descriptor $entry -Key 'Kind'

    try {
        switch ($kind) {
            'embedded' {
                $handler = Get-DescriptorField -Descriptor $entry -Key 'Handler'
                $handlerPath = Get-DescriptorField -Descriptor $entry -Key 'Path'

                if (-not (Get-Command -Name $handler -ErrorAction SilentlyContinue) -and $handlerPath) {
                    . $handlerPath
                }

                return (& $handler @Arguments)
            }
            'external-file' {
                $handler = Get-DescriptorField -Descriptor $entry -Key 'Handler'
                return (& $handler @Arguments)
            }
            'external-directory' {
                $subcommands = Get-DescriptorField -Descriptor $entry -Key 'Subcommands'
                if (-not $subcommands) { $subcommands = @{} }
                $defaultHandler = Get-DescriptorField -Descriptor $entry -Key 'DefaultHandler'

                $callArgs = $Arguments
                $subName = $null
                if ($Arguments.Count -gt 0) {
                    $candidate = $Arguments[0].ToLower()
                    if ($subcommands.ContainsKey($candidate)) {
                        $subName = $candidate
                        $callArgs = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @() }
                    }
                }

                if ($subName) {
                    $subHandler = $subcommands[$subName]
                    if ($subHandler -is [hashtable] -and $subHandler.ContainsKey('Handler')) {
                        # New format: hashtable with Handler descriptor
                        return (Invoke-HandlerDescriptor -Descriptor $subHandler.Handler -Arguments $callArgs)
                    } else {
                        # Old format: direct function name or script path
                        return (& $subHandler @callArgs)
                    }
                }

                if ($defaultHandler) {
                    return (& $defaultHandler @Arguments)
                }

                Show-SubcommandHelp -Entry $entry
                return
            }
            'metadata' {
                $callArgs = $Arguments
                $commandPath = @($normalized)
                $subName = $null

                $subcommands = Get-DescriptorField -Descriptor $entry -Key 'Subcommands'
                if (-not $subcommands) { $subcommands = @{} }
                $dispatcher = Get-DescriptorField -Descriptor $entry -Key 'Dispatcher'
                $handler = Get-DescriptorField -Descriptor $entry -Key 'Handler'

                if ($Arguments.Count -gt 0) {
                    $candidate = $Arguments[0].ToLower()
                    if ($subcommands.ContainsKey($candidate)) {
                        $subName = $candidate
                        $commandPath += $candidate
                        $callArgs = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @() }
                    }
                }

                if ($dispatcher) {
                    if (-not $subName -and $callArgs.Count -gt 0 -and $callArgs[0] -notmatch '^-') {
                        $commandPath += $callArgs[0]
                        $callArgs = if ($callArgs.Count -gt 1) { $callArgs[1..($callArgs.Count - 1)] } else { @() }
                    }

                    return (Invoke-DispatcherDescriptor -Descriptor $dispatcher -CommandPath $commandPath -Arguments $callArgs)
                }

                if ($subName) {
                    $subHandler = Get-DescriptorField -Descriptor $subcommands[$subName] -Key 'Handler'
                    return (Invoke-HandlerDescriptor -Descriptor $subHandler -Arguments $callArgs)
                }

                if ($handler) {
                    return (Invoke-HandlerDescriptor -Descriptor $handler -Arguments $callArgs)
                }

                Show-SubcommandHelp -Entry $entry
                return
            }
            default {
                Write-Error "Unknown command kind: $($entry.Kind)"
                return 1
            }
        }
    }
    catch {
        Write-Error "Command execution failed: $_"
        return 1
    }
}

# Help system supporting embedded, external, and metadata modules
function Show-Help {
    param([string[]]$CommandPath = @())

    if (-not (Get-Command -Name 'New-HelpProfileFromRegistry' -ErrorAction SilentlyContinue)) {
        $localHelp = Join-Path $script:BoxingRoot 'core/help.ps1'
        $fallbackHelp = Join-Path $PSScriptRoot 'core/help.ps1'

        if (Test-Path $localHelp) {
            . $localHelp
        }
        elseif (Test-Path $fallbackHelp) {
            . $fallbackHelp
        }
    }

    if (-not $CommandPath) {
        $CommandPath = @()
    }
    else {
        $CommandPath = @($CommandPath)
    }

    if (-not $CommandPath -or $CommandPath.Count -eq 0) {
        $context = if ($script:Mode -and $script:Mode.ToLower() -eq 'boxer') { 'boxer' } else { 'box' }
        $profile = New-HelpProfileFromRegistry -Context $context -Registry $script:CommandRegistry -Title $null -Description $null -Header $null
        $lines = Render-HelpProfile -Profile $profile
        foreach ($line in $lines) { Write-Output $line }
        return
    }

    $commandName = $CommandPath[0].ToLower()

    if (-not $script:CommandRegistry.ContainsKey($commandName)) {
        Write-Output "Unknown command: $commandName"
        return
    }

    $entry = $script:CommandRegistry[$commandName]
    $subPath = if ($CommandPath.Count -gt 1) { @($CommandPath[1..($CommandPath.Count - 1)]) } else { @() }
    $subPath = @($subPath)
    $kind = Get-DescriptorField -Descriptor $entry -Key 'Kind'

    switch ($kind) {
        'embedded' {
            $handler = Get-DescriptorField -Descriptor $entry -Key 'Handler'
            $profile = New-HelpProfile -Context 'boxer' -Title $null -Description $null -Header $null -Commands @(Convert-RegistryEntryToHelpCommand -Entry $entry -Context 'boxer')
            $lines = Render-CommandHelp -Entry (Convert-RegistryEntryToHelpCommand -Entry $entry -Context 'boxer') -Profile $profile -SubPath $subPath
            foreach ($line in $lines) { Write-Output $line }
        }
        'external-file' {
            $handler = Get-DescriptorField -Descriptor $entry -Key 'Handler'
            $profile = New-HelpProfile -Context 'box' -Title $null -Description $null -Header $null -Commands @(Convert-RegistryEntryToHelpCommand -Entry $entry -Context 'box')
            $lines = Render-CommandHelp -Entry (Convert-RegistryEntryToHelpCommand -Entry $entry -Context 'box') -Profile $profile -SubPath $subPath
            foreach ($line in $lines) { Write-Output $line }
        }
        'external-directory' {
            $subcommands = Get-DescriptorField -Descriptor $entry -Key 'Subcommands'
            if (-not $subcommands) { $subcommands = @{} }
            $helpHandler = Get-DescriptorField -Descriptor $entry -Key 'HelpHandler'
            $defaultHandler = Get-DescriptorField -Descriptor $entry -Key 'DefaultHandler'

            if ($subPath.Count -gt 0) {
                $subName = $subPath[0].ToLower()
                if ($subcommands.ContainsKey($subName)) {
                    $subHandler = Get-DescriptorField -Descriptor $subcommands[$subName] -Key 'Handler'
                    Show-DescriptorHelp -Descriptor $subHandler
                    return
                }
            }

            if ($helpHandler) {
                $helpOutput = & $helpHandler @()
                if ($helpOutput) { $helpOutput | ForEach-Object { Write-Output $_ } }
                return
            }

            $profile = New-HelpProfile -Context 'box' -Title $null -Description $null -Header $null -Commands @(Convert-RegistryEntryToHelpCommand -Entry $entry -Context 'box')
            $lines = Render-CommandHelp -Entry (Convert-RegistryEntryToHelpCommand -Entry $entry -Context 'box') -Profile $profile -SubPath $subPath
            foreach ($line in $lines) { Write-Output $line }
        }
        'metadata' {
            $dispatcher = Get-DescriptorField -Descriptor $entry -Key 'Dispatcher'
            $subcommands = Get-DescriptorField -Descriptor $entry -Key 'Subcommands'
            if (-not $subcommands) { $subcommands = @{} }
            $helpHandler = Get-DescriptorField -Descriptor $entry -Key 'HelpHandler'
            $handler = Get-DescriptorField -Descriptor $entry -Key 'Handler'
            $name = Get-DescriptorField -Descriptor $entry -Key 'Name'

            if ($dispatcher) {
                $helpPath = @($name)
                if ($subPath.Count -gt 0) { $helpPath += $subPath }
                $helpPath += 'help'
                Invoke-DispatcherDescriptor -Descriptor $dispatcher -CommandPath $helpPath -Arguments @()
                return
            }

            if ($subPath.Count -gt 0) {
                $subName = $subPath[0].ToLower()
                if ($subcommands.ContainsKey($subName)) {
                    $subHandler = Get-DescriptorField -Descriptor $subcommands[$subName] -Key 'Handler'
                    Show-DescriptorHelp -Descriptor $subHandler
                    return
                }
            }

            if ($helpHandler) {
                $helpOutput = & $helpHandler @()
                if ($helpOutput) { $helpOutput | ForEach-Object { Write-Output $_ } }
                return
            }

            if ($handler) {
                Show-DescriptorHelp -Descriptor $handler
            }
            else {
                $profile = New-HelpProfile -Context 'box' -Title $null -Description $null -Header $null -Commands @(Convert-RegistryEntryToHelpCommand -Entry $entry -Context 'box')
                $lines = Render-CommandHelp -Entry (Convert-RegistryEntryToHelpCommand -Entry $entry -Context 'box') -Profile $profile -SubPath $subPath
                foreach ($line in $lines) { Write-Output $line }
            }
        }
        default {
            Write-Output "No help available for $commandName"
        }
    }
}

# END core/dispatcher.ps1

# ============================================================================
# EMBEDDED src/core/*.ps1 (shared libraries)
# ============================================================================

# BEGIN core/common.ps1
# ============================================================================
# Common Functions - Utility & State Management
# ============================================================================
#
# Consolidated common utilities, after extracting UI functions to ui.ps1
# and config functions to config.ps1. This file now contains:
# - Utility functions (descriptor field lookup)
# - State management (Load/Save/Get/Set/Remove package state)

# ============================================================================
# Utility Functions
# ============================================================================

function Invoke-Handler {
    <#
    .SYNOPSIS
    Invokes a module handler in both embedded and standalone modes

    .DESCRIPTION
    Routes to the appropriate handler based on mode:
    - Embedded: Calls function (e.g., Invoke-Box-Pkg-List)
    - Standalone: Executes file (e.g., modules/box/pkg/list.ps1)

    .PARAMETER Module
    Module name (e.g., "pkg", "env")

    .PARAMETER Handler
    Handler name (e.g., "list", "install")

    .PARAMETER Arguments
    Optional arguments to pass to the handler

    .EXAMPLE
    Invoke-Handler -Module "pkg" -Handler "list"
    Routes to list.ps1 or Invoke-Box-Pkg-List depending on mode

    .EXAMPLE
    Invoke-Handler -Module "env" -Handler "load" -Arguments @("dev")
    Routes to env/load.ps1 or Invoke-Box-Env-Load with "dev" arg
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Module,

        [Parameter(Mandatory=$true)]
        [string]$Handler,

        [Parameter(ValueFromRemainingArguments=$true)]
        [string[]]$Arguments
    )

    if ($script:IsEmbedded) {
        # Embedded mode: call function
        # Convert module/handler to function name: pkg/list -> Invoke-Box-Pkg-List
        $parts = @($script:Mode) + $Module.Split('/') + $Handler.Split('/')
        $funcName = "Invoke-" + ($parts | ForEach-Object {
            $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower()
        }) -join '-'

        if (Get-Command $funcName -ErrorAction SilentlyContinue) {
            if ($Arguments) {
                & $funcName @Arguments
            } else {
                & $funcName
            }
        } else {
            Write-Error "Handler function not found: $funcName"
        }
    } else {
        # Standalone mode: execute file
        $handlerPath = Join-Path $PSScriptRoot "..\modules\$($script:Mode)\$Module\$Handler.ps1"
        if (Test-Path $handlerPath) {
            if ($Arguments) {
                & $handlerPath @Arguments
            } else {
                & $handlerPath
            }
        } else {
            Write-Error "Handler file not found: $handlerPath"
        }
    }
}

function Get-DescriptorField {
    <#
    .SYNOPSIS
    Safely retrieves a field from a descriptor hashtable

    .PARAMETER Descriptor
    The descriptor hashtable

    .PARAMETER Key
    The key to retrieve

    .EXAMPLE
    $handler = Get-DescriptorField -Descriptor $entry -Key 'Handler'
    #>
    param(
        [hashtable]$Descriptor,
        [string]$Key
    )

    if ($Descriptor -and $Descriptor.ContainsKey($Key)) {
        return $Descriptor[$Key]
    }

    return $null
}

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
# Help Renderer Models and Defaults
# ============================================================================
# Defines the data shapes and default values used by the unified help renderer.
# This file introduces no rendering logic to avoid behavior changes while the
# renderer is being adopted elsewhere.

$script:HelpRendererDefaults = [ordered]@{
    WrapWidth = 100
    NoCommandsMessage = 'No commands available.'
    FallbackSynopsis = 'No synopsis available.'
    FallbackDescription = 'No description available.'
    Boxer = [ordered]@{
        Title = 'Boxer'
        Description = 'Command-line toolbox manager.'
    }
    Box = [ordered]@{
        Title = 'Box'
        Description = 'Project command helper.'
    }
}

function Get-HelpDefaults {
    param(
        [ValidateSet('box', 'boxer')]
        [string]$Context
    )

    $contextDefaults = if ($Context -eq 'box') { $script:HelpRendererDefaults.Box } else { $script:HelpRendererDefaults.Boxer }

    return [ordered]@{
        Title = $contextDefaults.Title
        Description = $contextDefaults.Description
        WrapWidth = $script:HelpRendererDefaults.WrapWidth
        NoCommandsMessage = $script:HelpRendererDefaults.NoCommandsMessage
        FallbackSynopsis = $script:HelpRendererDefaults.FallbackSynopsis
        FallbackDescription = $script:HelpRendererDefaults.FallbackDescription
    }
}

function New-HelpCommandEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$Synopsis,
        [string]$Description,
        [hashtable[]]$Subcommands = @(),
        [bool]$IsHidden = $false,
        [string]$Source
    )

    $fallbacks = Get-HelpDefaults -Context 'box'
    $effectiveSynopsis = if ([string]::IsNullOrWhiteSpace($Synopsis)) { $fallbacks.FallbackSynopsis } else { $Synopsis }
    $effectiveDescription = if ([string]::IsNullOrWhiteSpace($Description)) { $fallbacks.FallbackDescription } else { $Description }

    return [ordered]@{
        Name = $Name.ToLower()
        Synopsis = $effectiveSynopsis
        Description = $effectiveDescription
        Subcommands = if ($Subcommands) { @($Subcommands) } else { @() }
        IsHidden = [bool]$IsHidden
        Source = $Source
    }
}

function New-HelpSubcommandEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$Synopsis,
        [string]$Description,
        [hashtable]$Handler
    )

    $fallbacks = Get-HelpDefaults -Context 'box'
    $effectiveSynopsis = if ([string]::IsNullOrWhiteSpace($Synopsis)) { $fallbacks.FallbackSynopsis } else { $Synopsis }
    $effectiveDescription = if ([string]::IsNullOrWhiteSpace($Description)) { $fallbacks.FallbackDescription } else { $Description }

    return [ordered]@{
        Name = $Name.ToLower()
        Synopsis = $effectiveSynopsis
        Description = $effectiveDescription
        Handler = $Handler
        Subcommands = @()
        IsHidden = $false
        Source = $null
    }
}

function New-HelpProfile {
    param(
        [ValidateSet('box', 'boxer')]
        [string]$Context,
        [string]$Title,
        [string]$Description,
        [string]$Header,
        [hashtable[]]$Commands = @()
    )

    $defaults = Get-HelpDefaults -Context $Context

    $effectiveTitle = if ([string]::IsNullOrWhiteSpace($Title)) { $defaults.Title } else { $Title }
    $effectiveDescription = if ([string]::IsNullOrWhiteSpace($Description)) { $defaults.Description } else { $Description }

    return [ordered]@{
        Context = $Context
        Title = $effectiveTitle
        Description = $effectiveDescription
        Header = $Header
        Commands = if ($Commands) { @($Commands) } else { @() }
        WrapWidth = $defaults.WrapWidth
        NoCommandsMessage = $defaults.NoCommandsMessage
    }
}

function Get-HelpFromScript {
    param(
        [string]$ScriptPath
    )

    if (-not $ScriptPath) {
        return @{ Synopsis = $null; Description = $null }
    }

    try {
        # Check if it's a function name (no path separators)
        if ($ScriptPath -notmatch '[\\/]' -and (Get-Command $ScriptPath -CommandType Function -ErrorAction SilentlyContinue)) {
            $helpInfo = Get-Help $ScriptPath -ErrorAction SilentlyContinue
            if ($helpInfo) {
                return @{
                    Synopsis = if ($helpInfo.Synopsis -and $helpInfo.Synopsis -ne $ScriptPath) { $helpInfo.Synopsis.Trim() } else { $null }
                    Description = if ($helpInfo.Description) { ($helpInfo.Description | Out-String).Trim() } else { $null }
                }
            }
        }
        # Otherwise treat as file path
        elseif (Test-Path $ScriptPath) {
            $helpInfo = Get-Help $ScriptPath -ErrorAction SilentlyContinue
            if ($helpInfo) {
                return @{
                    Synopsis = if ($helpInfo.Synopsis -and $helpInfo.Synopsis -ne $ScriptPath) { $helpInfo.Synopsis.Trim() } else { $null }
                    Description = if ($helpInfo.Description) { ($helpInfo.Description | Out-String).Trim() } else { $null }
                }
            }
        }
    }
    catch {
        Write-Verbose "Failed to get help from ${ScriptPath}: $($_.Exception.Message)"
    }

    return @{ Synopsis = $null; Description = $null }
}

function Convert-RegistryEntryToHelpCommand {
    param(
        [hashtable]$Entry,
        [ValidateSet('box', 'boxer')]
        [string]$Context
    )

    if (-not $Entry) { return $null }

    $name = Get-DescriptorField -Descriptor $Entry -Key 'Name'
    $kind = Get-DescriptorField -Descriptor $Entry -Key 'Kind'
    $synopsis = Get-DescriptorField -Descriptor $Entry -Key 'Synopsis'
    $description = Get-DescriptorField -Descriptor $Entry -Key 'Description'
    $source = Get-DescriptorField -Descriptor $Entry -Key 'Source'
    $isHidden = [bool](Get-DescriptorField -Descriptor $Entry -Key 'Hidden')

    # For external-directory without synopsis, try to extract from default handler or first subcommand
    if ($kind -eq 'external-directory' -and -not $synopsis) {
        $defaultHandler = Get-DescriptorField -Descriptor $Entry -Key 'DefaultHandler'
        if ($defaultHandler) {
            $helpData = Get-HelpFromScript -ScriptPath $defaultHandler
            $synopsis = $helpData.Synopsis
            $description = $helpData.Description
        }
    }

    # For external-file, extract help from the script
    if ($kind -eq 'external-file' -and -not $synopsis) {
        $handler = Get-DescriptorField -Descriptor $Entry -Key 'Handler'
        if ($handler) {
            $helpData = Get-HelpFromScript -ScriptPath $handler
            $synopsis = $helpData.Synopsis
            $description = $helpData.Description
        }
    }

    $subcommands = switch ($kind) {
        'external-directory' { Convert-RegistrySubcommands -Subcommands (Get-DescriptorField -Descriptor $Entry -Key 'Subcommands') -Context $Context }
        'metadata' { Convert-RegistrySubcommands -Subcommands (Get-DescriptorField -Descriptor $Entry -Key 'Subcommands') -Context $Context }
        Default { @() }
    }

    return New-HelpCommandEntry -Name $name -Synopsis $synopsis -Description $description -Subcommands $subcommands -IsHidden $isHidden -Source $source
}

function Convert-RegistrySubcommands {
    param(
        [hashtable]$Subcommands,
        [ValidateSet('box', 'boxer')]
        [string]$Context
    )

    if (-not $Subcommands) { return @() }

    $results = @()
    foreach ($key in ($Subcommands.Keys | Sort-Object)) {
        $value = $Subcommands[$key]
        $handler = $null
        $synopsis = $null
        $description = $null

        if ($value -is [string]) {
            $handler = @{ Type = 'script'; Path = $value }
            # Extract help from the script file
            $helpData = Get-HelpFromScript -ScriptPath $value
            $synopsis = $helpData.Synopsis
            $description = $helpData.Description
        }
        elseif ($value -is [hashtable]) {
            $handler = Get-DescriptorField -Descriptor $value -Key 'Handler'
            $synopsis = Get-DescriptorField -Descriptor $value -Key 'Synopsis'
            $description = Get-DescriptorField -Descriptor $value -Key 'Description'
            if (-not $handler -and $value.ContainsKey('Path')) { $handler = @{ Type = 'script'; Path = $value['Path'] } }
            
            # If synopsis/description not in metadata, extract from handler
            if (-not $synopsis -and $handler -and $handler.ContainsKey('Path')) {
                $helpData = Get-HelpFromScript -ScriptPath $handler.Path
                $synopsis = $helpData.Synopsis
                $description = $helpData.Description
            }
        }

        $results += New-HelpSubcommandEntry -Name $key -Synopsis $synopsis -Description $description -Handler $handler
    }

    return $results
}

function Get-HelpRegistrySnapshot {
    param(
        [ValidateSet('box', 'boxer')]
        [string]$Context,
        [hashtable]$Registry
    )

    $commands = @()

    if (-not $Registry) { return $commands }

    foreach ($entry in $Registry.GetEnumerator() | Sort-Object Key) {
        $command = Convert-RegistryEntryToHelpCommand -Entry $entry.Value -Context $Context
        if ($command -and -not $command.IsHidden) {
            $commands += $command
        }
    }

    return $commands
}

function New-HelpProfileFromRegistry {
    param(
        [ValidateSet('box', 'boxer')]
        [string]$Context,
        [hashtable]$Registry,
        [string]$Title,
        [string]$Description,
        [string]$Header
    )

    $commands = Get-HelpRegistrySnapshot -Context $Context -Registry $Registry
    return New-HelpProfile -Context $Context -Title $Title -Description $Description -Header $Header -Commands $commands
}

function Wrap-Text {
    param(
        [string]$Text,
        [int]$Width,
        [string]$Indent = ''
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @('') }
    $words = $Text -split '\s+'
    $lines = @()
    $current = ''

    foreach ($word in $words) {
        if ($current.Length -eq 0) {
            $current = $word
            continue
        }

        if (($current.Length + 1 + $word.Length) -le $Width) {
            $current = "$current $word"
        }
        else {
            $lines += $current
            $current = $word
        }
    }

    if ($current.Length -gt 0) { $lines += $current }

    if ($Indent) {
        return $lines | ForEach-Object { "$Indent$_" }
    }

    return $lines
}

function Render-HelpProfile {
    param(
        [hashtable]$Profile
    )

    if (-not $Profile) { return @() }

    $lines = @()

    if ($Profile.Header) {
        $headerLines = $Profile.Header -split "`n"
        $lines += $headerLines
        $lines += ''
    }

    $titleLines = Wrap-Text -Text $Profile.Title -Width $Profile.WrapWidth
    $descriptionLines = Wrap-Text -Text $Profile.Description -Width $Profile.WrapWidth

    $lines += $titleLines
    $lines += $descriptionLines
    $lines += ''
    $lines += 'Available commands:'

    $commands = @($Profile.Commands)

    if (-not $commands -or $commands.Count -eq 0) {
        $lines += "  $($Profile.NoCommandsMessage)"
        return $lines
    }

    $nameWidth = 16
    $textWidth = [Math]::Max(20, $Profile.WrapWidth - ($nameWidth + 2))

    foreach ($cmd in ($commands | Sort-Object Name)) {
        $wrapped = @(Wrap-Text -Text $cmd.Synopsis -Width $textWidth)
        if (-not $wrapped -or $wrapped.Count -eq 0) { $wrapped = @('') }

        $lines += ("  {0,-$nameWidth} {1}" -f $cmd.Name, $wrapped[0])

        if ($wrapped.Count -gt 1) {
            for ($i = 1; $i -lt $wrapped.Count; $i++) {
                $lines += ("  {0,-$nameWidth} {1}" -f '', $wrapped[$i])
            }
        }
    }

    return $lines
}

function Render-CommandHelp {
    param(
        [hashtable]$Entry,
        [hashtable]$Profile,
        [string[]]$SubPath = @()
    )

    if (-not $Entry -or -not $Profile) { return @() }

    $lines = @()
    $wrap = $Profile.WrapWidth
    $nameWidth = 16
    $textWidth = [Math]::Max(20, $wrap - ($nameWidth + 2))

    $title = if ($Entry.Name) { $Entry.Name } else { 'Command' }
    $desc = if ($Entry.Description) { $Entry.Description } else { $Profile.Description }

    $lines += Wrap-Text -Text $title -Width $wrap
    $lines += Wrap-Text -Text $desc -Width $wrap
    $lines += ''

    $subcommands = @($Entry.Subcommands)

    if ($subcommands.Count -eq 0) {
        return $lines
    }

    $lines += 'Available subcommands:'

    foreach ($sub in ($subcommands | Sort-Object Name)) {
        $wrapped = @(Wrap-Text -Text $sub.Synopsis -Width $textWidth)
        if (-not $wrapped -or $wrapped.Count -eq 0) { $wrapped = @('') }

        $lines += ("  {0,-$nameWidth} {1}" -f $sub.Name, $wrapped[0])

        if ($wrapped.Count -gt 1) {
            for ($i = 1; $i -lt $wrapped.Count; $i++) {
                $lines += ("  {0,-$nameWidth} {1}" -f '', $wrapped[$i])
            }
        }
    }

    return $lines
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
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
    Provides functions to load variables, process templates with token replacement,
    manage backups, and apply template-based file generation.

.NOTES
    Module: templates.ps1
    Version: 0.1.115
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
    # In src/ structure, boxer.version is at same level as core/
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

    # 4. Development mode (no version set)
    if (-not $script:IsEmbedded) {
        return "DEV"
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
# EMBEDDED src/modules/box/*.ps1 (box commands + pkg submodule)
# ============================================================================

# BEGIN modules/box/clean.ps1
function Invoke-Box-Clean {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Removes build directories (build/, dist/, out/, bin/, obj/)
and temporary files (*.tmp, *.log) from the project.

.EXAMPLE
box clean
Remove all build artifacts and temporary files
#>
# ============================================================================
# Box Clean Command
# ============================================================================
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
# BEGIN modules/box/env\env.ps1
function Invoke-Box-Env-Env {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Manages environment variables for the project.
Subcommands: list, load, replace, update.
Default action when called without subcommand is 'list'.

.PARAMETER Sub
Subcommand to execute (list, load, replace, update).

.EXAMPLE
box env
List all environment variables (default)

.EXAMPLE
box env list
Explicitly list environment variables

.EXAMPLE
box env load
Load .env into current PowerShell session

.EXAMPLE
box env replace *.md -Force
Replace tagged values in Markdown files

.EXAMPLE
box env update
Regenerate .env from installed packages
#>
# ============================================================================
# Box Env Command (Dispatcher)
# ============================================================================
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
# END modules/box/env\env.ps1
# BEGIN modules/box/env\list.ps1
function Invoke-Box-Env-List {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Lists environment variables defined by all installed packages.
Shows package name and associated environment variables.

.EXAMPLE
box env list
Display all configured environment variables

.EXAMPLE
box env
Same as 'box env list' (default behavior)
#>
# ============================================================================
# Box Env List Subcommand
# ============================================================================
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
function Invoke-Box-Env-Load {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Reads .env file and sets all variables as environment variables
in the current PowerShell session. Also adds .box/ and scripts/
to PATH for immediate access to tools.

.EXAMPLE
box env load
Load environment variables into current session

.NOTES
This only affects the current PowerShell session.
For permanent changes, use 'box env update' and restart terminal.
#>
# ============================================================================
# Box Env Load Subcommand
# ============================================================================
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
function Invoke-Box-Env-Replace {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Processes files and replaces tagged values with current environment
variable values. Supports in-place updates (preserves tags) or
release mode (strips tags).

Supported tag syntaxes:
- ~value[VAR_NAME]~ : Universal tag format
- Box-specific syntaxes via hooks (e.g., #define for C files)

.PARAMETER Path
Path pattern to files to process (*.md, src/, README.md, etc.).

.PARAMETER OutputDir
Optional output directory for processed files.
If specified, copies files with tags stripped (release mode).
If not specified, updates files in-place preserving tags.

.PARAMETER Force
Required for in-place updates to prevent accidental overwrites.

.EXAMPLE
box env replace *.md -Force
Update all Markdown files in-place with current env values

.EXAMPLE
box env replace . -OutputDir dist/ -Force
Copy all files to dist/ with tags replaced and stripped

.EXAMPLE
box env replace README.md -Force
Update single file in-place
#>
# ============================================================================
# Box Env Replace Subcommand
# ============================================================================
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
function Invoke-Box-Env-Update {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Regenerates .env file from all installed package configurations,
updates VS Code terminal environment variables, and updates
tagged files throughout the project.

This command should be run after:
- Installing new packages
- Changing package configurations
- Updating package versions

.EXAMPLE
box env update
Regenerate environment files from package state

.NOTES
Automatically updates:
- .env file with all package environment variables
- .vscode/settings.json terminal environment
- Tagged files in project (calls Update-TaggedFiles)
#>
# ============================================================================
# Box Env Update Subcommand
# ============================================================================
Generate-AllEnvFiles
Update-VSCodeEnv
Update-TaggedFiles -Path $BaseDir -Recurse
Write-Success ".env updated"

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

}
# END modules/box/env\update.ps1
# BEGIN modules/box/info.ps1
function Invoke-Box-Info {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Shows comprehensive information about the current Box workspace including:
- Box runtime version
- Box metadata (name, version, type, author, tags)
- Build date and core version
- Workspace configuration

.EXAMPLE
box info
Display all workspace information
#>
# ============================================================================
# Box Info Command
# ============================================================================
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
function Invoke-Box-Install {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Executes the complete installation workflow for a Box project:
- Runs configuration wizard if needed
- Creates required directories
- Ensures 7-Zip is available
- Processes and installs all configured packages
- Generates Makefile and environment files
- Displays installation summary

.EXAMPLE
box install
Install all packages defined in configuration
#>
# ============================================================================
# Box Install Command
# ============================================================================
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
        Invoke-Box-Pkg-Install -Item $pkg
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
function Invoke-Box-Load {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Sets up the complete environment in one command:
1. Updates .env file from packages
2. Updates VS Code settings
3. Loads .env variables into current PowerShell session
4. Adds .box/ and scripts/ to PATH

.EXAMPLE
box load
Load full environment for current project
#>
# ============================================================================
# Box Load Command
# ============================================================================
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
function Invoke-Box-Pkg {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Package management command dispatcher.
When 'box pkg' is called without subcommand, shows package list.
Subcommands (install, list, state, uninstall) are auto-routed.

.PARAMETER Arguments
Subcommand and its arguments.

.EXAMPLE
box pkg
List all packages (default behavior)

.EXAMPLE
box pkg install vbcc
Install vbcc package

.EXAMPLE
box pkg list
Explicitly list packages

.NOTES
Auto-routing handles: box pkg install, box pkg list, box pkg state, box pkg uninstall
This file handles: box pkg (no args) → list packages
#>
# If subcommand provided, route to it
if ($Arguments -and $Arguments.Count -gt 0) {
    $subcommand = $Arguments[0]
    $subArgs = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @() }
    Invoke-Handler -Module "pkg" -Handler $subcommand -Arguments $subArgs
} else {
    # No args: default to list
    Invoke-Handler -Module "pkg" -Handler "list"
}

}
# END modules/box/pkg.ps1
# BEGIN modules/box/pkg\helpers\dependencies.ps1
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

# END modules/box/pkg\helpers\dependencies.ps1
# BEGIN modules/box/pkg\helpers\detection.ps1
function Test-PackageInstalled {
    param([hashtable]$Package)

    if (-not $Package -or -not $Package.Name) {
        return @{ Installed = $false; Source = $null; Path = $null }
    }

    $state = Load-State
    if ($state.packages.ContainsKey($Package.Name)) {
        $pkgState = $state.packages[$Package.Name]
        return @{ Installed = ($pkgState.installed -eq $true); Source = 'state'; Path = $global:VendorDir }
    }

    return @{ Installed = $false; Source = $null; Path = $null }
}

# END modules/box/pkg\helpers\detection.ps1
# BEGIN modules/box/pkg\helpers\extraction.ps1
# Load core extract library if not embedded (embedded builds already have it)
if (-not $script:IsEmbedded) {
    # Check if Extract-Package function already exists (already loaded)
    if (-not (Get-Command -Name Extract-Package -ErrorAction SilentlyContinue)) {
        $extractCore = Join-Path $PSScriptRoot '..\..\..\core\extract.ps1'
        if (Test-Path $extractCore) {
            . $extractCore
        }
        else {
            throw "Missing core extract library at $extractCore"
        }
    }
}

# END modules/box/pkg\helpers\extraction.ps1
# BEGIN modules/box/pkg\install.ps1
function Invoke-Box-Pkg-Install {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Handles complete package installation workflow:
- Checks if package already installed (system/vendor/env)
- Prompts user for installation decisions
- Downloads and extracts package files
- Updates package state and environment
- Handles manual configuration if user refuses install

.PARAMETER Item
Hashtable with package definition containing:
- Name: Package name
- Url: Download URL
- File: Target filename
- Archive: Archive type (zip, lha, tar.gz)
- Extract: Extraction rules
- Mode: Installation mode (auto/manual)

.EXAMPLE
box pkg install vbcc
Install vbcc package with user prompts

.NOTES
Internal function called by Invoke-Box-Install for each package.
Handles detection of existing installations and user prompts.
#>
# ============================================================================
# Box Pkg Install Subcommand
# ============================================================================
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
# END modules/box/pkg\install.ps1
# BEGIN modules/box/pkg\list.ps1
function Invoke-Box-Pkg-List {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Shows table with package information:
- Package names
- Environment variables configured
- Package descriptions
- Installation status with visual indicators

.EXAMPLE
box pkg list
Display all packages and their status

.EXAMPLE
box pkg
Same as 'box pkg list' (default behavior)

.NOTES
Status indicators:
- ✓ : Installed from package definition
- ⚙ : Manually configured (user-provided paths)
- ✗ : Not installed
#>
# ============================================================================
# Box Pkg List Subcommand
# ============================================================================
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
# END modules/box/pkg\list.ps1
# BEGIN modules/box/pkg\state.ps1
function Invoke-Box-Pkg-State {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Shows raw package state for debugging purposes:
- Installation status for each package
- Installed files and directories
- Environment variable configurations
- Installation timestamps and metadata

.EXAMPLE
box pkg state
Display detailed state of all packages

.NOTES
Useful for debugging package issues and verifying installations.
Shows the internal state file (.box/state.json) in human-readable format.
#>
# ============================================================================
# Box Pkg State Subcommand
# ============================================================================
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
# END modules/box/pkg\state.ps1
# BEGIN modules/box/pkg\uninstall.ps1
function Invoke-Box-Pkg-Uninstall {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Uninstalls a package by:
- Deleting all installed files and directories
- Removing package from state file
- Cleaning up environment variable configurations

.PARAMETER Name
The package name to uninstall.

.EXAMPLE
box pkg uninstall vbcc
Remove vbcc package and all its files

.NOTES
Only removes files tracked in package state.
Manually added files are not affected.
#>
# ============================================================================
# Box Pkg Uninstall Subcommand
# ============================================================================
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
# END modules/box/pkg\uninstall.ps1
# BEGIN modules/box/status.ps1
function Invoke-Box-Status {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Shows current project status including:
- Project metadata (name, description, version)
- Package installation statistics (installed, manual, total)
- Directory structure and paths
- Configuration summary

.EXAMPLE
box status
Display complete project status
#>
# ============================================================================
# Box Status Command
# ============================================================================
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
function Invoke-Box-Uninstall {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Removes all installed packages and cleans up:
- Removes package files from vendor directory
- Cleans up package state
- Removes vendor directory
- Deletes state file

.EXAMPLE
box uninstall
Remove all packages and clean up project
#>
# ============================================================================
# Box Uninstall Command
# ============================================================================
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
# BEGIN modules/box/update.ps1
function Invoke-Box-Update {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Reads .box/metadata.psd1 to find source repository,
then downloads and updates box.ps1 and related files
from the source GitHub repository.

.EXAMPLE
box update
Update current Box project to latest version
#>
# ============================================================================
# Box Update Command
# ============================================================================
Write-Host ""
Write-Host "Updating box..." -ForegroundColor Cyan
Write-Host ""

# Verify we're in a box project
if (-not $script:BoxDir -or -not (Test-Path $script:BoxDir)) {
    Write-Host "❌ Not in a box project" -ForegroundColor Red
    Write-Host ""
    Write-Host "Run 'boxer init' to create a new project" -ForegroundColor Gray
    return 1
}

# Read metadata to get source repository
$metadataPath = Join-Path $script:BoxDir "metadata.psd1"
if (-not (Test-Path $metadataPath)) {
    Write-Host "❌ metadata.psd1 not found in .box/" -ForegroundColor Red
    return 1
}

try {
    $metadata = Import-PowerShellDataFile -Path $metadataPath
    $sourceRepo = $metadata.SourceRepo

    if (-not $sourceRepo) {
        Write-Host "❌ SourceRepo not defined in metadata.psd1" -ForegroundColor Red
        return 1
    }

    $boxName = $metadata.BoxName
        Write-Host "Box: $boxName" -ForegroundColor Gray
    Write-Host "Source: $sourceRepo" -ForegroundColor Gray
    Write-Host ""

    # Construct download URL
    $url = "https://raw.githubusercontent.com/$sourceRepo/main/box.ps1"

    Write-Host "Downloading and executing update..." -ForegroundColor Cyan
    Write-Host "  $url" -ForegroundColor Gray
    Write-Host ""

    # Execute irm|iex (will trigger Update-LocalBoxIfNeeded in Initialize-Boxing)
    Invoke-RestMethod -Uri $url | Invoke-Expression

    Write-Host ""
    Write-Host "⚠ Restart your PowerShell session to use the updated box" -ForegroundColor Yellow

} catch {
    Write-Host ""
    Write-Host "❌ Update failed: $_" -ForegroundColor Red
    return 1
}

}
# END modules/box/update.ps1
# BEGIN modules/box/version.ps1
function Invoke-Box-Version {
    param([string[]]$Arguments)
<#
.SYNOPSIS
    AmiDevBox - Complete Amiga development environment setup system

.DESCRIPTION
Shows the current version of the Box runtime.
Version is embedded in box.ps1 during build.

.EXAMPLE
box version
Displays: Box v2.1.0
#>
# ============================================================================
# Box Version Command
# ============================================================================
$BoxVersion = Get-BoxerVersion
if (-not $BoxVersion) { $BoxVersion = "Unknown" }

Write-Host "Box v$BoxVersion" -ForegroundColor Cyan

}
# END modules/box/version.ps1

# ============================================================================
# MAIN - Call Initialize-Boxing (Spec 010 architecture)
# ============================================================================

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


