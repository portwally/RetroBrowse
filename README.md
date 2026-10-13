# ProBrowse

This is an early version under active development. It may contain bugs that could corrupt your disk images. **Always backup your disk images before using ProBrowse!**

---

<img width="1561" height="820" alt="Bildschirmfoto 2025-12-27 um 20 02 29" src="https://github.com/user-attachments/assets/19469707-805b-4c16-9fb5-c9f4bc5179f8" />

## What is ProBrowse?

ProBrowse is a modern macOS dual-pane file manager for Apple II disk images, bringing vintage computing into the 21st century.

### Features

- **Dual-Pane Browser** - Work with two disk images simultaneously
- **File Inspector** - View file contents with Cmd+I or context menu
- **Native ProDOS Support** - Read and write ProDOS disk images natively in Swift
- **DOS 3.3 Support** - Full read and write support for DOS 3.3 disk images
- **UCSD Pascal Support** - Read UCSD Pascal volumes (read-only)
- **ShrinkIt Archives** - Browse and extract NuFX archives (.shk, .sdk, .bxy)
- **Binary II Archives** - Browse and extract Binary II archives (.bny, .bqy)
- **Drag & Drop** - Copy files between disk images or import from Finder
- **Change File Type** - Right-click to modify file type and aux type
- **Complete File Type Database** - Recognizes 200+ ProDOS file types with proper names
- **Graphics Preview** - View Apple II graphics (HGR, DHGR, SHR, APF) directly
- **Font Preview** - Apple IIgs fonts and Apple II hi-res screen fonts
- **Icon Preview** - Apple IIgs Finder icons with 16-color palette and transparency
- **BASIC Viewer** - Syntax-highlighted Applesoft and Integer BASIC listings
- **Merlin Viewer** - 6502 assembler source with syntax highlighting
- **Disassembler** - 6502 and 65816 machine code disassembly
- **AppleWorks Viewer** - Classic and GS word processor, database, and spreadsheet
- **Teach Viewer** - Apple IIgs Teach documents with fonts, styles, and colors
- **Date/Time Support** - Displays creation and modification dates from ProDOS
- **Modern UI** - Clean SwiftUI interface with resizable columns
- **Export Capability** - Extract files to your Mac  

### Supported Disk Image Formats

| Format | Extension | Read | Write |
|--------|-----------|------|-------|
| ProDOS Order | `.po` | ✅ | ✅ |
| DOS Order | `.do` | ✅ | ✅ |
| Universal 2IMG | `.2mg` | ✅ | ✅ |
| Hard Disk Volume | `.hdv` | ✅ | ✅ |
| Generic DSK | `.dsk` | ✅ | ✅ |
| UCSD Pascal Volume | `.vol` | ✅ | ❌ |

### Supported Archive Formats

| Format | Extension | Read | Write | Description |
|--------|-----------|------|-------|-------------|
| ShrinkIt Disk | `.sdk` | ✅ | ❌ | Compressed disk images |
| ShrinkIt Archive | `.shk` | ✅ | ❌ | Compressed file archives |
| Binary II + ShrinkIt | `.bxy` | ✅ | ❌ | Binary II wrapped ShrinkIt |
| Binary II | `.bny`, `.bqy` | ✅ | ❌ | Binary II archives |
| Gzip | `.gz` | ✅ | ❌ | Gzip compressed files |
| ZIP | `.zip` | ✅ | ❌ | ZIP archives |

*All archive formats are handled natively - no external tools required.*

### Supported File Systems

| File System | Read | Write | Notes |
|-------------|------|-------|-------|
| ProDOS | ✅ | ✅ | Full support including subdirectories |
| DOS 3.3 | ✅ | ✅ | Full support |
| UCSD Pascal | ✅ | ❌ | Read-only |
| ShrinkIt Archives | ✅ | ❌ | Native LZW decompression |
| Binary II Archives | ✅ | ❌ | Read-only |


### Requirements

- macOS 15.7 or later
- Apple Silicon or Intel Mac

### Current Limitations

- UCSD Pascal volumes are read-only
- ShrinkIt, Binary II, Gzip and ZIP archives are read-only; copy files to a disk image to change them
- Beta quality - expect bugs!

---

## Quick Start

1. Open two disk images (left and right panes)
2. Browse files with full directory support
3. Press **Cmd+I** to inspect any file (view BASIC listings, graphics, hex dump)
4. Drag & drop files between images
5. Export files to your Mac
6. View Apple II graphics inline

## Building

Requires Xcode 16+ and macOS 15.7+

```bash
open ProBrowse.xcodeproj
```

---

## Development

Built with Swift and SwiftUI for modern macOS.

**License**: MIT

**Status**: Active development - contributions welcome!

---

**Remember: Always backup your disk images before using beta software!**

[![Downloads](https://img.shields.io/github/downloads/portwally/ProBrowse/total?style=flat&color=0d6efd)](https://github.com/portwally/ProBrowse/releases)
[![Stars](https://img.shields.io/github/stars/portwally/ProBrowse?style=flat&color=f1c40f)](https://github.com/portwally/ProBrowse/stargazers)
[![Forks](https://img.shields.io/github/forks/portwally/ProBrowse?style=flat&color=2ecc71)](https://github.com/portwally/ProBrowse/network/members)
