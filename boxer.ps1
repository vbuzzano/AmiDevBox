#Requires -Version 7.0
<#
.SYNOPSIS
    Boxer - Global Boxing Manager (Embedded Build)

.DESCRIPTION
    Standalone boxer.ps1 with embedded core libraries and modules

.NOTES
    Build Date: 2026-01-20 04:29:39
    Version: 0.1.195
    Build Type: Embedded
#>

param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Global variables
# Handle irm|iex context where $PSScriptRoot is empty
$script:BoxingRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $env:TEMP }
$script:Mode = 'boxer'
$script:IsEmbedded = $true
$script:BoxerVersion = "0.1.195"
$script:LoadedModules = @{}
$script:Commands = @{}
$script:CommandRegistry = @{}
$script:IsIrmIexContext = -not $PSScriptRoot  # Flag for irm|iex detection


# ============================================================================
# EMBEDDED src/core/*.ps1 (core bootstrapper files)
# ============================================================================

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
            default {
                # Extract help metadata for subcommands
                $helpInfo = Get-Help $file.FullName -ErrorAction SilentlyContinue
                $synopsis = if ($helpInfo -and $helpInfo.Synopsis -and $helpInfo.Synopsis -ne $file.FullName) {
                    $helpInfo.Synopsis
                } else { $null }
                $description = if ($helpInfo -and ($helpInfo.PSObject.Properties.Name -contains 'Description') -and $helpInfo.Description -and $helpInfo.Description.Text) {
                    $helpInfo.Description.Text
                } else { $null }

                # Store as hashtable with metadata
                $subcommands[$name] = @{
                    Handler = @{ Type = 'script'; Path = $file.FullName }
                    Synopsis = $synopsis
                    Description = $description
                }
            }
        }
    }

    if ($script:CommandRegistry.ContainsKey($ModuleName.ToLower())) { return }

    # Extract help metadata from DefaultHandler
    $commandSynopsis = $null
    $commandDescription = $null

    if ($defaultHandler) {
        $helpInfo = Get-Help $defaultHandler -ErrorAction SilentlyContinue
        if ($helpInfo -and $helpInfo.Synopsis -and $helpInfo.Synopsis -ne $defaultHandler) {
            $commandSynopsis = $helpInfo.Synopsis
        }
        if ($helpInfo -and ($helpInfo.PSObject.Properties.Name -contains 'Description') -and $helpInfo.Description -and $helpInfo.Description.Text) {
            $commandDescription = $helpInfo.Description.Text
        }
    }

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
        Synopsis = $commandSynopsis
        Description = $commandDescription
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
                Description = $null
            }
        }

        $group = $commandGroups[$commandName]

        if (-not $subcommandName) {
            # This is the Default Handler (e.g. Invoke-Box-Pkg)
            $group.DefaultHandler = $funcName

            # Extract synopsis and description from main handler
            $helpInfo = Get-Help $funcName -ErrorAction SilentlyContinue
            if ($helpInfo -and $helpInfo.Synopsis -and $helpInfo.Synopsis -ne $funcName) {
                 $group.Synopsis = $helpInfo.Synopsis
            }
            if ($helpInfo -and ($helpInfo.PSObject.Properties.Name -contains 'Description') -and $helpInfo.Description -and $helpInfo.Description.Text) {
                 $group.Description = $helpInfo.Description.Text
            }
        } else {
            # This is a Subcommand (e.g. Invoke-Box-Pkg-Install)
            # Extract synopsis for subcommand
            $helpInfo = Get-Help $funcName -ErrorAction SilentlyContinue
            $synopsis = if ($helpInfo -and $helpInfo.Synopsis -and $helpInfo.Synopsis -ne $funcName) {
                $helpInfo.Synopsis
            } else { $null }
            $description = if ($helpInfo -and ($helpInfo.PSObject.Properties.Name -contains 'Description') -and $helpInfo.Description -and $helpInfo.Description.Text) {
                $helpInfo.Description.Text
            } else { $null }

            # Store as hashtable with metadata
            $group.Subcommands[$subcommandName] = @{
                Handler = @{ Type = 'function'; Function = $funcName }
                Synopsis = $synopsis
                Description = $description
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
                Description = $group.Description
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
                Description = $group.Description
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
                    return (& $subcommands[$subName] @callArgs)
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
                    $subValue = $subcommands[$subName]
                    
                    # Handle both legacy (string) and new (hashtable) formats
                    if ($subValue -is [string]) {
                        # Legacy: direct file path
                        $subHandler = @{ Type = 'script'; Path = $subValue }
                    } else {
                        # New: hashtable with Handler field
                        $subHandler = Get-DescriptorField -Descriptor $subValue -Key 'Handler'
                    }
                    
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
            # Legacy fallback: extract help metadata on-the-fly
            $helpInfo = Get-Help $value -ErrorAction SilentlyContinue
            if ($helpInfo -and $helpInfo.Synopsis -and $helpInfo.Synopsis -ne $value) {
                $synopsis = $helpInfo.Synopsis
            }
            if ($helpInfo -and ($helpInfo.PSObject.Properties.Name -contains 'Description') -and $helpInfo.Description -and $helpInfo.Description.Text) {
                $description = $helpInfo.Description.Text
            }
            $handler = @{ Type = 'script'; Path = $value }
        }
        elseif ($value -is [hashtable]) {
            $handler = Get-DescriptorField -Descriptor $value -Key 'Handler'
            $synopsis = Get-DescriptorField -Descriptor $value -Key 'Synopsis'
            $description = Get-DescriptorField -Descriptor $value -Key 'Description'
            if (-not $handler -and $value.ContainsKey('Path')) { $handler = @{ Type = 'script'; Path = $value['Path'] } }
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
    $description = if ($Profile.ContainsKey('Description')) { $Profile['Description'] } else { 'No description available.' }
    $descriptionLines = Wrap-Text -Text $description -Width $Profile.WrapWidth

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
    $fallbackDesc = if ($Profile.ContainsKey('Description')) { $Profile['Description'] } else { 'No description available.' }
    $desc = if ($Entry.ContainsKey('Description') -and $Entry['Description']) { $Entry['Description'] } else { $fallbackDesc }

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

# ============================================================================
# EMBEDDED src/modules/boxer/*.ps1 (boxer commands)
# ============================================================================

# BEGIN modules/boxer/init.ps1
function Invoke-Boxer-Init {
<#
.SYNOPSIS
Creates a new Box project with full structure.

.PARAMETER Name
Name of the project to create (optional - will prompt if not provided)

.PARAMETER Path
Custom path where to create the project (optional - uses Name in current dir if not provided)

.PARAMETER Description
Description of the project (optional)

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
# ============================================================================
# Boxer Init Module
# ============================================================================
#
# Handles boxer init command - creating new Box projects
param(
    [Parameter(Position=0)]
    [string]$Name = "",

    [Parameter(Position=1)]
    [string]$Path = "",

    [Parameter(Position=2)]
    [string]$Description = "",

    [string]$Box = ""
)

# ============================================================================
# Helper Functions (must be defined before use)
# ============================================================================

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

# ============================================================================
# Main Logic
# ============================================================================

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
# END modules/boxer/init.ps1
# BEGIN modules/boxer/install.ps1
function Invoke-Boxer-Install {
<#
.SYNOPSIS
Install a Box from registry or GitHub.

.DESCRIPTION
Downloads and installs a Box type from GitHub repository.
Can install from registry name (AmiDevBox) or direct GitHub URL.

.PARAMETER Arguments
Box name from registry or GitHub repository URL.

.EXAMPLE
boxer install AmiDevBox
Install AmiDevBox from registry

.EXAMPLE
boxer install https://github.com/vbuzzano/AmiDevBox
Install directly from GitHub URL
#>
# ============================================================================
# Boxer Install Command
# ============================================================================
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

# Box Registry - Maps simple names to GitHub repository URLs
$script:BoxRegistry = @{
    'AmiDevBox' = 'https://github.com/vbuzzano/AmiDevBox'
    # 'BoxBuilder' = 'https://github.com/vbuzzano/BoxBuilder'  # Commented out until box exists
}

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

# ============================================================================
# Helper Functions
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


}
# END modules/boxer/install.ps1
# BEGIN modules/boxer/list.ps1
function Invoke-Boxer-List {
<#
.SYNOPSIS
List all installed Box types.

.DESCRIPTION
Displays all Boxes installed in ~/Documents/PowerShell/Boxing/Boxes/.
Shows boxes actually installed on the user's system,
not development boxes in the repository.

.EXAMPLE
boxer list
Show all installed boxes with version and description
#>
# ============================================================================
# Boxer List Command
# ============================================================================
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
# BEGIN modules/boxer/update.ps1
function Invoke-Boxer-Update {
<#
.SYNOPSIS
Update a Box project to latest version.

.DESCRIPTION
Navigates to the specified project directory (or current directory)
and executes 'box update' which updates the .box/ directory
from the box's source repository.

.PARAMETER Path
Path to the box project directory. Defaults to current directory.

.EXAMPLE
boxer update
Update Box project in current directory

.EXAMPLE
boxer update C:\Projects\MyProject
Update specific project at given path
#>
# ============================================================================
# Boxer Update Command
# ============================================================================
param(
    [Parameter(Position=0)]
    [string]$Path = "."
)

# Resolve to absolute path
$targetPath = Resolve-Path -Path $Path -ErrorAction SilentlyContinue

if (-not $targetPath) {
    Write-Host "❌ Path not found: $Path" -ForegroundColor Red
    return 1
}

# Check if .box exists
$boxDir = Join-Path $targetPath ".box"
if (-not (Test-Path $boxDir)) {
    Write-Host "❌ Not a box project: $targetPath" -ForegroundColor Red
    Write-Host ""
    Write-Host "No .box/ directory found" -ForegroundColor Gray
    return 1
}

# Save current location
$originalLocation = Get-Location

try {
    # Navigate to project
    Set-Location $targetPath

    # Check if box.ps1 exists in .box
    $boxScript = Join-Path $boxDir "box.ps1"
    if (-not (Test-Path $boxScript)) {
        Write-Host "❌ Invalid box project: box.ps1 not found in .box/" -ForegroundColor Red
        return 1
    }

    # Execute box update
    & $boxScript update

} finally {
    # Restore location
    Set-Location $originalLocation
}


}
# END modules/boxer/update.ps1
# BEGIN modules/boxer/version.ps1
function Invoke-Boxer-Version {
<#
.SYNOPSIS
Display Boxer version information.

.DESCRIPTION
Shows the current version of the Boxer system.
Version is embedded in the boxer.ps1 script during build.

.EXAMPLE
boxer version
Displays: Boxer v2.1.0
#>
# ============================================================================
# Boxer Version Command
# ============================================================================
$BoxerVersion = Get-BoxerVersion
if (-not $BoxerVersion) { $BoxerVersion = "Unknown" }

Write-Host "Boxer v$BoxerVersion" -ForegroundColor Cyan


}
# END modules/boxer/version.ps1

# ============================================================================
# MAIN - Invoke bootstrapper
# ============================================================================

# Ensure Arguments is an array (can be null in irm|iex context)
if (-not $Arguments) { $Arguments = @() }
Initialize-Boxing -Arguments $Arguments

