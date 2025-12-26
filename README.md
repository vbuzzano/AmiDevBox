# AmigaDevBox

Complete Amiga OS development kit setup for cross-compilation on Windows with VBCC.

## 🚀 Quick Start

```powershell
# Install DevBox globally (one-time setup)
irm https://github.com/vbuzzano/AmiDevBox/raw/main/devbox.ps1 | iex

# Create and setup your project
devbox init MyProject
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

## 📖 Resources

- AmigaOS Documentation: [Amiga.org](https://www.amiga.org)
- VBCC Compiler: [VBCC Homepage](http://www.compilers.de/vbcc.html)
- NDK Resources: Various AmigaOS development resources

## 📄 License

See LICENSE file for details.

---

**AmigaDevBox** - Making AmigaOS development accessible and simple.

Built with ❤️ by Vincent Buzzano (ReddoC)
