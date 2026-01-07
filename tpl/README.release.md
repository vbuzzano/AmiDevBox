# AmigaDevBox

Complete Amiga OS development kit setup for cross-compilation on Windows with VBCC.

## 🚀 Quick Start

```powershell
# Install Boxing globally (one-time setup)
irm https://github.com/vbuzzano/AmiDevBox/raw/main/install.ps1 | iex

# Create and setup your project
boxer init MyProject
cd MyProject
box install

# Build your project
make
```

## 📦 What Is It

- **Automate Projects** - Reproducible development environment setup
- **Easy Recreation** - Share and recreate projects effortlessly
- **Compiler Ready** - Auto-installs VBCC (more compilers coming soon)
- **Complete Toolchain** - Downloads NDK headers and libraries automatically
- **Zero Config** - Pre-configured Makefiles and build system ready to use

## 🛠️ Commands

```powershell
# Project setup
box install                # Install all packages
box uninstall              # Remove packages

# Environment
box env list               # Show environment variables
box env set KEY VAL        # Set environment variable

# Package management
box pkg list               # List installed packages
box pkg info NAME          # Show package details

# Help
box help                   # Show all available commands
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

## 🩹 Troubleshooting

### DevBox Not Recognized

If `devbox` command is not found after installation:

```powershell
# Reload your PowerShell profile
. $PROFILE

# Or restart PowerShell
```

### Box Command Outside Project

If you get "No DevBox project found" error:
- Ensure you are inside a DevBox project directory
- Create a new project: `devbox init MyProject`
- The `box` command searches parent directories for `.box/`

### Installation Issues

**Problem**: Script execution policy error
```powershell
# Solution: Enable script execution (one-time)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**Problem**: Profile corruption or duplicate entries
- Check `$PROFILE.CurrentUserAllHosts` for multiple `#region devbox initialize` blocks
- Remove duplicates, keeping only one block
- Future: Use `devbox uninstall` (Feature 007)

**Problem**: Installation hangs or fails
- Check internet connection for package downloads
- Verify GitHub access (not blocked by firewall)
- Try manual installation: Download `devbox.ps1` and run `.\devbox.ps1`

## 📖 Resources

- AmigaOS Documentation: [Amiga.org](https://www.amiga.org)
- VBCC Compiler: [VBCC Homepage](http://www.compilers.de/vbcc.html)
- NDK Resources: Various AmigaOS development resources

## 📄 License

See LICENSE file for details.

---

**AmigaDevBox** - Making AmigaOS development accessible and simple.

Built with ❤️ by Vincent Buzzano (ReddoC)
