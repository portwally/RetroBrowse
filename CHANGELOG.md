# Changelog

All notable changes to ProBrowse will be documented in this file.

## [2.6] - Unreleased

### Fixed
- **DOS 3.3 writing** - The free-sector map was read with its bytes swapped, so adding a file could overwrite existing data
- **DOS-ordered ProDOS images (.dsk, .do)** - Block 7 of each track was read and written from the wrong sector
- **Files with the same name in different directories** - Delete, rename and change type now act on the selected file
- **Cut and paste** - A file is only removed from the source after it was copied; paste goes into the active pane
- **Deleting a directory** - Its contents are deleted and their blocks freed
- **ShrinkIt archives** - Archives now open; LZW/1 and LZW/2 decoding and thread layout corrected, checksums verified
- **Binary II and ZIP archives** - Header layout corrected; ZIP files written by Finder now open
- **Crashes** - 65816 disassembler, dates from 2028 on, large DOS 3.3 files, and several malformed-file cases
- **Dates** - ProDOS years 2000-2039 and hour/minute order
- **Viewers** - Screen dumps no longer mistaken for MacPaint; 640-mode APF pictures; Merlin columns; DOS 3.3 BASIC and binary files; monitor labels in the disassembler; AppleWorks characters and colors; Teach styles
- **New .2mg images** now have a 2IMG header

### Added
- **File archives are browsable** - ShrinkIt and Binary II archives without a disk image open as a read-only catalog
- **Errors are shown** - Failed imports, copies, deletes and loads report what went wrong
- **Delete confirmation**, Delete key, Cmd+O / Cmd+Shift+O
- **Multiple files** can be dropped from Finder at once
- **Read-only protection** for images opened from inside an archive
- **Tests** - `Tests/run-tests.sh`

### Changed
- The disk writers never allocate a block or sector that a file already uses, even if the disk's own free map says it is free
- UCSD Pascal images in DOS order use the correct sector map

## [2.5] - 2026-01-26

### Improved
- **BASIC Listing Text Wrapping** - Long lines now wrap properly with hanging indent
  - DATA statements and other long lines stay readable within the window
  - Wrapped text aligns with code column (after line number)
  - Works for both Applesoft and Integer BASIC
- **Merlin Assembler Text Wrapping** - Same hanging indent for wrapped lines
  - Long operands and comments stay properly aligned when wrapped
- **Merlin Source Detection** - Now recognizes both high-ASCII and low-ASCII text
  - High-ASCII: Authentic Apple II format with $8D line endings and $A0 column separators
  - Low-ASCII: Modern text files with LF/CR line endings and standard spaces
  - .S extension files automatically detected as Merlin source
- **File Import from Finder** - Drag & drop now preserves original filename
  - Files dropped from Finder keep their name (e.g., HELLO.S instead of DROPPED.TXT)
  - Proper handling of content types (public.assembly-source, public.source-code)
  - Automatic file type detection based on extension (.s, .asm, .txt)

## [2.0] - 2026-01-26

### Added
- **File Inspector** - Comprehensive file viewer with tabbed interface (Content, Hex, Info)
  - Context menu "Inspect File..." or Cmd+I to open
  - Automatic content type detection based on file type and data analysis
- **BASIC Listing Viewer** - View Applesoft and Integer BASIC programs with syntax highlighting
  - Keywords highlighted in cyan
  - String literals in green
  - REM comments in gray italic
  - Line numbers in yellow
- **Merlin Assembler Viewer** - View 6502 assembly source files (TXT with .S extension)
  - Automatic detection of Merlin source format
  - Syntax highlighting: labels (purple), opcodes (blue), comments (green)
  - Proper column alignment matching original Merlin editor
  - Supports high-ASCII encoding with $A0 column separators
- **6502 Disassembler** - View machine code with mnemonics for BIN/SYS/REL files
  - Complete 6502 instruction set (56 instructions, all addressing modes)
  - Uses aux type as starting address (or type-specific defaults)
  - Syntax highlighting: addresses, bytes, mnemonics, operands
  - Comments for known Apple II ROM routines and I/O addresses
- **Graphics Preview** - Native Apple II graphics decoding
  - Hi-Res (HGR) - 280x192, 6 colors
  - Double Hi-Res (DHGR) - 560x192, 16 colors
  - Super Hi-Res (SHR) - 320x200, 16 colors per scanline
  - 3200-color SHR mode
  - Packed SHR formats: APF (Apple Preferred Format), Paintworks, generic PackBytes
  - Scalable display (1x, 2x, 3x)
- **Hex Dump Viewer** - Professional hex viewer with ASCII sidebar
  - 16 bytes per line with offset column
  - Supports files up to 64KB display
- **Apple IIgs Font Preview** - View IIgs bitmap fonts ($C8/FNT files)
  - Sample text rendering with the font
  - Character grid showing all glyphs
  - Font metrics display (height, ascent, descent, etc.)
  - Scalable preview (1x-4x)
- **Hi-Res Font Preview** - View Apple II screen fonts ($07/FNT files)
  - Standard fonts: 768 bytes (96 chars) or 1024 bytes (128 chars)
  - Double-size fonts: 3072 bytes (96 chars at 14x16 pixels)
  - Character grid with 16 columns
  - Interactive sample text rendering
  - Scalable preview (1x-4x)
- **Apple IIgs Icon Preview** - View icon files ($CA/ICN files)
  - Displays large and small icons with 16-color Apple IIgs palette
  - Transparency mask support with checkerboard background option
  - Shows associated file path patterns
  - Scalable preview (2x-8x)
- **AppleWorks Document Viewer** - View AppleWorks files natively
  - Classic Word Processor ($1A/AWP) with bold, underline, and formatting
  - AppleWorks GS Word Processor ($50/GWP) with WYSIWYG fonts, sizes, and colors
  - Database ($19/ADB) as searchable table with category headers
  - Spreadsheet ($1B/ASP) with cell grid and formulas
  - Full character encoding support including MouseText and Mac OS Roman
- **Teach Document Viewer** - View Apple IIgs Teach files ($50/$5445)
  - WYSIWYG display with fonts, styles, and colors
  - Parses resource fork for style information
  - Paper-like rendering with white background
- **Extended File Support** - Read files with resource forks (storage type 5)
  - Extracts both data fork and resource fork from ProDOS extended files
  - Required for Teach documents and other IIgs applications
- **Native Disk Image Verification** - Verify image integrity without external tools
  - Validates file size, format structure, and 2IMG containers
  - Reports volume name, format, and file count
- **Enhanced File Info Panel** - Detailed metadata display similar to DiskBrowser2
  - Storage type with description (Seedling, Sapling, Tree, etc.)
  - Key pointer, blocks used, EOF in hex and decimal
  - Access flags with permission descriptions (read, write, rename, destroy)
  - Version and min version fields
  - Header pointer for subdirectories

### Removed
- **Cadius dependency** - All operations now use native Swift implementations

### Improved
- Graphics detection now handles BIN files with aux type hints ($2000, $4000)
- Better file type routing for APP ($B3) and PNT ($C0) files
- Cleaner inspector UI with icon-based controls
- **Apple IIgs Icon Rendering** - Fixed icon display to properly handle 4bpp mask format
  - Mask data now correctly interpreted (same size as pixel data, 4bpp format)
  - 0 = transparent, non-zero = opaque (matching CiderPress2 implementation)
  - All standard Finder icon files now render correctly

## [1.0] - 2026-01-25

### Added
- **Change File Type/Aux Type** - Right-click any file on a ProDOS disk to change its file type and auxiliary type
  - Hex input fields with validation
  - Quick-select buttons for common file types (TXT, BIN, SYS, BAS, AWP)
  - Quick-select buttons for common aux types ($0000, $0800, $2000, $4000)
  - Live preview of file type description
- **Help Window** - Built-in help with keyboard shortcuts, supported formats, and troubleshooting tips (Help menu or Cmd+?)
- **NuFX/ShrinkIt Archive Support** - Browse and extract .shk, .sdk, .bxy, and .bny archives
- **UCSD Pascal Support** - Read-only support for UCSD Pascal volumes (.vol files)

### Improved
- DOS 3.3 write support with full file operations
- Better .po and .dsk format detection
- README documentation updates

## [0.8.0] - 2025-01

### Added
- **DOS 3.3 Read/Write Support** - Full support for DOS 3.3 disk images
- **Copy/Cut/Paste** - Context menu with clipboard operations
- **Delete Files** - Delete files and directories from disk images
- **Directory Operations** - Copy and export complete directories with structure

### Fixed
- Directory navigation crash fixes
- Erratic filename display issues
- Column display improvements

## [0.7.0] - 2024-12

### Added
- **Dual-Pane Browser** - Work with two disk images simultaneously
- **Drag & Drop** - Copy files between disk images
- **ProDOS Write Support** - Add, rename, and delete files on ProDOS images
- **Graphics Preview** - View Apple II graphics (HGR, DHGR, SHR, APF) inline
- **File Type Database** - Recognition of 200+ ProDOS file types
- **Date/Time Display** - Shows creation and modification dates
- **Export to Finder** - Extract files to macOS

### Supported Formats
- ProDOS Order (.po)
- DOS Order (.do)
- Universal 2IMG (.2mg)
- Hard Disk Volume (.hdv)
- Generic DSK (.dsk)

---

## Version History Summary

| Version | Date | Highlights |
|---------|------|------------|
| 2.5 | 2026-01-26 | Text wrapping with hanging indent, Merlin low-ASCII support, Finder import fix |
| 2.0 | 2026-01-26 | File Inspector, BASIC viewer, graphics preview, hex dump |
| 1.0 | 2026-01-25 | Change file type, NuFX/ShrinkIt, UCSD Pascal, DOS 3.3 write |
| 0.7.0 | 2024-12 | Initial dual-pane browser release |
