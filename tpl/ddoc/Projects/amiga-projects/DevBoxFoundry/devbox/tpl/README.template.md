# {{PROJECT_NAME}}

**{{PROJECT_DESCRIPTION}}**

## 🚀 Quick Start

```powershell
# Install dependencies
.\box.ps1 install

# Build
make

# Upload to Vampire
make upload
```

## 📝 Project Configuration

Edit `box.config.psd1` to customize packages and build settings.

## 🛠️ Available Commands

```powershell
.\box.ps1 install      # Install dependencies
.\box.ps1 env list     # List environment variables
.\box.ps1 pkg list     # List packages
.\box.ps1 help         # Show all commands
```

## 📦 Build Targets

```powershell
make                   # Build (default)
make clean             # Clean build artifacts
make upload            # Upload to Vampire V4
```

## 📚 Documentation

See `.box/tpl/` for Makefile examples and templates.

---

**Powered by ApolloDevBox**
