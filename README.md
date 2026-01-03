# AmiDevBox

Amiga development environment with VBCC compiler, NDK 3.9, and build tools.

## Quick Start

Install AmiDevBox in one command:

```powershell
irm https://github.com/vbuzzano/AmiDevBox/raw/main/install.ps1 | iex
```

Then restart PowerShell and create a project:

```powershell
boxer init MyAmiProject
cd MyAmiProject
box install
```

## Type

**dev** - Complete Amiga 68k development environment

## Features

- VBCC compiler for AmigaOS 68k
- NDK 3.9 (Native Development Kit)
- ApolloExplorer (acp upload tool)
- Build system (Makefile for VBCC)
- Remote debugging support (bgdbserver)
- LHA archiver support

## Installation

**One-line install** (recommended):
```powershell
irm https://github.com/vbuzzano/AmiDevBox/raw/main/install.ps1 | iex
```

**Manual install** (if Boxing already installed):
```powershell
boxer install https://github.com/vbuzzano/AmiDevBox
```

## Usage

Create a new Amiga project:
```powershell
boxer init MyAmiProject
cd MyAmiProject
box install
```

Build your project:
```bash
make
```

Upload to Vampire/Apollo:
```bash
make upload
```

Clean:
```bash
make clean
```

## Configuration

Edit `config.psd1` to customize:
- VBCC version and target
- NDK version
- Build directories
- Additional packages

## Packages Included

- **VBCC Compiler**: Cross-compiler for AmigaOS
- **VBCC Target**: m68k-amigaos target
- **NDK 3.9**: AmigaOS headers and libraries
- **LHA**: Archive tool for .lha files
- **ApolloExplorer**: Upload tool for Apollo/Vampire boards
- **bgdbserver**: Remote debugger

## Environment Variables

- `VBCC`: Path to VBCC compiler
- `NDK39`: Path to NDK 3.9
- `ACP`: Path to acp.exe (upload tool)
- `GDB`: Path to bgdbserver
- `LHATOOL`: Path to lha tool


