# AmigaDevBox

Complete Amiga OS development kit setup for cross-compilation on Windows with VBCC.

## 🚀 Quick Start

```powershell
# Run the interactive installer
irm https://github.com/vbuzzano/AmigaDevBox/raw/main/install.ps1 | iex

# Follow the wizard to create your project
# Then install packages:
cd MyProject
.\box.ps1 install

# Build your project
make
```

## 📦 What's Included

- **VBCC Compiler** - m68k AmigaOS C compiler
- **NDK 3.2+** - AmigaOS development kit headers and libraries
- **Build System** - Pre-configured Makefiles and build scripts
- **Templates** - Ready-to-use project templates

## 🛠️ Commands

```powershell
# Project setup
.\box.ps1 install          # Install all packages
.\box.ps1 uninstall        # Remove packages

# Environment
.\box.ps1 env list         # Show environment variables
.\box.ps1 env set KEY VAL  # Set environment variable

# Package management
.\box.ps1 pkg list         # List installed packages
.\box.ps1 pkg info NAME    # Show package details

# Help
.\box.ps1 help             # Show all available commands
```

## 📚 Documentation

- `.box/` - Core DevBox system
- `.box/tpl/` - Project templates and Makefile examples
- `.vscode/` - Pre-configured VS Code settings

## 🔧 Configuration

Edit `.box/config.psd1` to customize:
- Package versions
- Installation paths
- Build environment variables

## 📖 Resources

- AmigaOS Documentation: [Amiga.org](https://www.amiga.org)
- VBCC Compiler: [VBCC Homepage](http://www.compilers.de/vbcc.html)
- NDK Resources: Various AmigaOS development resources

## 📄 License

See LICENSE file for details.

---

**AmigaDevBox** - Making AmigaOS development accessible and simple.

Built with ❤️ by Vincent Buzzano (ReddoC)
