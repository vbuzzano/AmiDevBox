# ============================================================================
# Boxing - Project Configuration
# ============================================================================
# This file contains project-specific settings and package dependencies.
# Edit this file to customize your development environment.
# ============================================================================

@{
    # ========================================================================
    # Project Information
    # ========================================================================
    Project = @{
        Name        = 'MyProject'
        Description = 'Amiga development project'
        Version     = '0.1.0'
        Author      = ''
    }

    # ========================================================================
    # Custom Environment Variables (added to .env)
    # ========================================================================
    # These variables are automatically exported when running 'box install'
    # ========================================================================
    Envs = @{
        # Example:
        # PROJECT_ROOT = '$pwd'
        # OUTPUT_DIR   = 'build'
    }

    # ========================================================================
    # Package Dependencies
    # ========================================================================
    # Add packages from registries or custom URLs
    # After editing, run: box install
    # ========================================================================
    Packages = @(
        # Example package from Aminet:
        # @{
        #     Name        = "vbcc"
        #     Url         = "https://aminet.net/dev/c/vbcc.lha"
        #     File        = "vbcc.lha"
        #     Description = "VBCC C compiler for Amiga"
        #     Archive     = "lha"
        #     Mode        = "auto"
        #     Extract     = @(
        #         "SDK:vbcc/*:vendor/vbcc:VBCC_PATH"
        #         "INC:vbcc/include/*:include"
        #     )
        # }
    )
}
