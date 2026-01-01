@{
    Name = "AmiDevBox"
    Type = "dev"
    Description = "Amiga development environment with VBCC, NDK, and tools"
    Version = "1.0.0"

    # Build directories
    Directories = @(
        "build/asm"
        "build/obj"
        "dist"
        "src"
        "include"
        "docs"
        "scripts"
    )

    # Packages to install
    Packages = @(
        @{
            Name        = "VBCC Compiler"
            Url         = "http://phoenix.owl.de/vbcc/current/vbcc_bin_win64.zip"
            File        = "vbcc_bin_win64.zip"
            Description = "VBCC compiler for Windows x64"
            Archive     = "zip"
            Mode        = "auto"
            DetectEnv   = "VBCC"
            DetectFile  = "vc.exe"
            Extract     = @(
                "TOOL:*:vendor/vbcc:VBCC"
            )
        },
        @{
            Name        = "VBCC Target"
            Url         = "http://phoenix.owl.de/vbcc/2022-05-22/vbcc_target_m68k-amigaos.lha"
            File        = "vbcc_target_m68k-amigaos.lha"
            Description = "VBCC AmigaOS 68k target"
            Archive     = "lha"
            Mode        = "auto"
            Extract     = @(
                "TOOL:vbcc_target_m68k-amigaos/*:vendor/vbcc"
            )
        },
        @{
            Name        = "NDK 3.9"
            Url         = "https://os.amigaworld.de/download.php?id=3"
            File        = "NDK_3.9.lha"
            Description = "AmigaOS NDK 3.9"
            Archive     = "lha"
            Mode        = "auto"
            DetectEnv   = "NDK39"
            Extract     = @(
                "NDK:NDK_3.9/*:vendor/NDK_3.9:NDK39"
            )
        },
        @{
            Name        = "Lha for Windows"
            Url         = "https://aminet.net/util/arc/lhant.lha"
            File        = "lhant.lha"
            Description = "Windows version of LHA"
            Archive     = "lha"
            Mode        = "auto"
            DetectEnv   = "LHATOOL"
            Extract     = @(
                "TOOL:lhant.exe:vendor/tools/lhant.exe:LHATOOL"
                "TOOL:lhant.readme:vendor/tools"
            )
        }
        @{
            Name        = "ApolloExplorer"
            Url         = "https://github.com/ronybeck/ApolloExplorer/releases/download/1.1.3/ApolloExplorer.1.1.3.zip"
            File        = "ApolloExplorer.1.1.3.zip"
            Description = "ApolloExplorer (acp upload tool)"
            Archive     = "zip"
            Mode        = "auto"
            Extract     = @(
                "TOOL:ApolloExplorer 1.1.3/Windows Client/acp.exe:vendor/tools/acp/acp.exe:ACP"
                "TOOL:ApolloExplorer 1.1.3/Windows Client/ApolloIcon.info:vendor/tools/acp/ApolloIcon.info"
                "TOOL:ApolloExplorer 1.1.3/Windows Client/ApolloIcon_Debug.info:vendor/tools/acp/ApolloIcon_Debug.info"
                "TOOL:ApolloExplorer 1.1.3/Windows Client/libgcc_s_seh-1.dll:vendor/tools/acp/libgcc_s_seh-1.dll"
                "TOOL:ApolloExplorer 1.1.3/Windows Client/libstdc++-6.dll:vendor/tools/acp/libstdc++-6.dll"
                "TOOL:ApolloExplorer 1.1.3/Windows Client/libwinpthread-1.dll:vendor/tools/acp/libwinpthread-1.dll"
                "TOOL:ApolloExplorer 1.1.3/Windows Client/Qt5Core.dll:vendor/tools/acp/Qt5Core.dll"
                "TOOL:ApolloExplorer 1.1.3/Windows Client/Qt5Network.dll:vendor/tools/acp/Qt5Network.dll"
            )
        },
        @{
            Name        = "bgdbserver"
            Url         = "https://franke.ms/git/bebbo/bgdbserver/raw/master/bgdbserver"
            File        = "bgdbserver"
            Description = "Remote debugger for Amiga"
            Archive     = "file"
            Mode        = "auto"
            Extract     = @(
                "TOOL:*:vendor/tools/bgdbserver:GDB"
            )
        }
    )

    # Environment variables
    Envs = @{
        SRC_DIR = "src"
        INCLUDE_DIR = "include"
        BUILD_DIR = "build"
        ASM_DIR = "build/asm"
        OBJ_DIR = "build/obj"
        DIST_DIR = "dist"
        VENDOR_DIR = "vendor"
    }

    # Workspace initialization
    InitWorkspace = $true

    # Makefile template
    MakefileTemplate = "assets/Makefile.template"
}

