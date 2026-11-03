//
//  ProDOSFileTypes.swift
//  ProBrowse
//
//  Complete ProDOS File Type definitions based on a2infinitum/apple2-filetypes
//  Source: https://github.com/a2infinitum/apple2-filetypes
//

import Foundation

struct ProDOSFileTypeInfo {
    let shortName: String
    let description: String
    let icon: String

    static func getFileTypeInfo(fileType: UInt8, auxType: UInt16 = 0) -> ProDOSFileTypeInfo {
        // A specific aux type first, then the file type in general
        if let info = specificTypes[fileType]?[auxType] {
            return info
        }
        return genericTypes[fileType]
            ?? ProDOSFileTypeInfo(shortName: String(format: "$%02X", fileType), description: "Unknown Type", icon: "❓")
    }

    /// One row of the database: a file type in general (`auxType` nil) or with a specific aux type
    struct Entry: Identifiable {
        let fileType: UInt8
        let auxType: UInt16?
        let info: ProDOSFileTypeInfo
        var id: String { String(format: "%02X", fileType) + (auxType.map { String(format: "/%04X", $0) } ?? "") }
    }

    /// Every known type, each general entry followed by its specific aux types, in file type order
    static let allEntries: [Entry] = {
        var rows: [Entry] = []
        let types = Set(genericTypes.keys).union(specificTypes.keys).sorted()
        for type in types {
            if let info = genericTypes[type] { rows.append(Entry(fileType: type, auxType: nil, info: info)) }
            for (aux, info) in (specificTypes[type] ?? [:]).sorted(by: { $0.key < $1.key }) {
                rows.append(Entry(fileType: type, auxType: aux, info: info))
            }
        }
        return rows
    }()

    private static func t(_ shortName: String, _ description: String, _ icon: String) -> ProDOSFileTypeInfo {
        ProDOSFileTypeInfo(shortName: shortName, description: description, icon: icon)
    }

    // MARK: - Specific Aux Types

    private static let specificTypes: [UInt8: [UInt16: ProDOSFileTypeInfo]] = [
        0x08: [
            0x4000: t("HGR", "Packed Hi-Res Image", "🖼️"),
            0x4001: t("DHGR", "Packed Double Hi-Res Image", "🖼️"),
            0x8001: t("HGR", "Printographer Packed HGR", "🖼️"),
            0x8002: t("DHGR", "Printographer Packed DHGR", "🖼️"),
            0x8003: t("HGR", "Softdisk Hi-Res image", "🖼️"),
            0x8004: t("DHGR", "Softdisk Double Hi-Res", "🖼️"),
        ],
        0x0B: [
            0x8001: t("WTW", "Write This Way document", "📝"),
            0x8002: t("W&P", "Writing & Publishing document", "📝"),
        ],
        0x16: [
            0x0001: t("PFS", "PFS:File document", "📄"),
            0x0002: t("PFS", "PFS:Write document", "📝"),
            0x0003: t("PFS", "PFS:Graph document", "📊"),
            0x0004: t("PFS", "PFS:Plan document", "📊"),
            0x0016: t("PFS", "PFS internal data", "📄"),
        ],
        0x2B: [
            0x8001: t("8OB", "GBBS Pro object code", "⚙️"),
        ],
        0x2C: [
            0x8003: t("APX", "APEX Program File", "⚙️"),
        ],
        0x2E: [
            0x8001: t("DVX", "Davex 8 Command", "⚙️"),
            0x8002: t("PTP", "Point-to-Point drivers", "⚙️"),
            0x8003: t("PTP", "Point-to-Point code", "⚙️"),
        ],
        0x41: [
            0x8001: t("OCR", "InWords OCR font table", "🔤"),
        ],
        0x50: [
            0x8001: t("DWR", "DeluxeWrite document", "📝"),
            0x8003: t("PJR", "Personal Journal document", "📓"),
            0x8010: t("AWGS", "AppleWorks GS Word Processor", "📝"),
            0x8011: t("SD", "Softdisk issue text", "📝"),
            0x5445: t("TCH", "Teach document", "📚"),
        ],
        0x51: [
            0x8010: t("AWGS", "AppleWorks GS Spreadsheet", "📊"),
        ],
        0x52: [
            0x8001: t("GTV", "GTv database", "🗄️"),
            0x8010: t("AWGS", "AppleWorks GS Database", "🗄️"),
            0x8011: t("AWGS", "AppleWorks GS DB Template", "🗄️"),
            0x8013: t("GSAS", "GSAS database", "🗄️"),
            0x8014: t("GSAS", "GSAS accounting journals", "💰"),
            0x8015: t("ADR", "Address Manager document", "📇"),
            0x8016: t("ADR", "Address Manager defaults", "📇"),
            0x8017: t("ADR", "Address Manager index", "📇"),
        ],
        0x53: [
            0x8002: t("GDL", "Graphic Disk Labeler", "🎨"),
            0x8010: t("AWGS", "AppleWorks GS Graphics", "🎨"),
        ],
        0x54: [
            0x8002: t("GWR", "GraphicWriter document", "📰"),
            0x8003: t("LBL", "Label It document", "🏷️"),
            0x8010: t("AWGS", "AppleWorks GS Page Layout", "📰"),
            0xDD3E: t("MDL", "Medley document", "📰"),
        ],
        0x55: [
            0x0001: t("HC", "HyperCard IIgs stack", "🗂️"),
            0x8001: t("TTH", "Tutor-Tech document", "📚"),
            0x8002: t("HS", "HyperStudio document", "🗂️"),
            0x8003: t("NXS", "Nexus document", "🗂️"),
            0x8004: t("HS", "HyperSoft stack", "🗂️"),
            0x8005: t("HS", "HyperSoft card", "🗂️"),
            0x8006: t("HS", "HyperSoft external command", "⚙️"),
        ],
        0x56: [
            0x8001: t("TTH", "Tutor-Tech Scores", "📚"),
            0x8007: t("GRD", "GradeBook Data", "📚"),
        ],
        0x57: [
            0x8003: t("MW", "Music Writer format", "🎵"),
        ],
        0x58: [
            0x8002: t("DVX", "Davex 8 Help File", "❓"),
            0x8006: t("LOC", "Locator help document", "❓"),
            0x8007: t("PJR", "Personal Journal help", "❓"),
            0x8008: t("HR", "Home Refinancer help", "❓"),
        ],
        0x59: [
            0x8010: t("AWGS", "AppleWorks GS Communications", "📡"),
        ],
        0x5A: [
            0x0002: t("RAM", "Battery RAM configuration", "⚙️"),
            0x0003: t("ALN", "AutoLaunch preferences", "⚙️"),
            0x0005: t("GSB", "GSBug configuration", "⚙️"),
            0x8001: t("MTJ", "Master Tracks Jr. preferences", "⚙️"),
            0x8002: t("GWR", "GraphicWriter preferences", "⚙️"),
            0x8005: t("DVX", "Davex 8 configuration", "⚙️"),
            0x8009: t("PTP", "Point-to-Point preferences", "⚙️"),
            0x8010: t("AWGS", "AppleWorks GS configuration", "⚙️"),
            0x801C: t("PP", "Platinum Paint preferences", "⚙️"),
        ],
        0x5B: [
            0x8001: t("CTN", "Cartooners movie", "🎬"),
            0x8002: t("CTN", "Cartooners actors", "🎬"),
            0x8005: t("AK", "Arcade King Super document", "🎬"),
            0x8006: t("AK", "Arcade King DHRG document", "🎬"),
            0x8007: t("DV", "DreamVision movie", "🎬"),
        ],
        0x5C: [
            0x8001: t("GTV", "GTv multimedia playlist", "🎭"),
        ],
        0x5D: [
            0x8001: t("SR", "Solitaire Royale document", "🎮"),
            0x8002: t("BF", "BattleFront scenario", "🎮"),
            0x8003: t("BF", "BattleFront saved game", "🎮"),
            0x8004: t("GA", "Gold of the Americas game", "🎮"),
            0x8006: t("BJT", "Blackjack Tutor document", "🎮"),
        ],
        0x5E: [
            0x0001: t("RSC", "Resource file", "🔧"),
            0x8001: t("ORC", "ORCA/Disassembler template", "🔧"),
            0x8003: t("DSM", "DesignMaster document", "🔧"),
        ],
        0x5F: [
            0x8002: t("HR", "Home Refinancer document", "💰"),
        ],
        0xB0: [
            0x0001: t("TXT", "APW Text file", "📄"),
            0x0003: t("ASM", "APW 65816 Assembly source", "📄"),
            0x0005: t("PAS", "ORCA/Pascal source code", "📄"),
            0x0006: t("CMD", "APW command file", "⚙️"),
            0x0008: t("C", "ORCA/C source code", "📄"),
            0x0009: t("LNK", "APW Linker command file", "⚙️"),
            0x000A: t("C", "APW C source code", "📄"),
            0x000C: t("CMD", "ORCA/Desktop command file", "⚙️"),
            0x0015: t("REZ", "APW Rez source file", "📄"),
            0x0017: t("INS", "Installer script", "⚙️"),
            0x001E: t("PAS", "TML Pascal source code", "📄"),
            0x0116: t("SCR", "ORCA/Disassembler script", "📄"),
            0x0503: t("ASM", "SDE Assembler source code", "📄"),
            0x0506: t("CMD", "SDE command script", "⚙️"),
            0x0601: t("NFL", "Nifty List data", "📄"),
            0x0719: t("PS", "PostScript file", "📄"),
        ],
        0xBB: [
            0x7F01: t("GTV", "GTv videodisc serial driver", "💿"),
            0x7F02: t("GTV", "GTv videodisc game port driver", "💿"),
        ],
        0xBC: [
            0x4001: t("NFL", "Nifty List Module", "⚙️"),
            0x4002: t("SI", "Super Info module", "⚙️"),
            0x4004: t("TWL", "Twilight document", "⚙️"),
            0x4007: t("HS", "HyperStudio New Button Action", "⚙️"),
            0x4008: t("HS", "HyperStudio Screen Transition", "⚙️"),
            0x4009: t("DGX", "DreamGrafix module", "⚙️"),
            0x400A: t("HS", "HyperStudio Extra utility", "⚙️"),
            0x400F: t("HP", "HardPressed compression module", "⚙️"),
        ],
        0xC0: [
            0x0000: t("PNT", "Paintworks Packed picture", "🎨"),
            0x0001: t("SHR", "Packed Super Hi-Res Image", "🖼️"),
            0x0002: t("APF", "Apple Preferred Format picture", "🖼️"),
            0x0003: t("PICT", "Packed QuickDraw II PICT file", "🖼️"),
            0x8001: t("GTV", "GTv background image", "🖼️"),
            0x8005: t("DGX", "DreamGrafix document", "🎨"),
            0x8006: t("GIF", "GIF document", "🖼️"),
        ],
        0xC1: [
            0x0000: t("SHR", "Super Hi-Res Screen image", "🖼️"),
            0x0001: t("PICT", "QuickDraw PICT file", "🖼️"),
            0x0002: t("SHR", "Super Hi-Res 3200 color image", "🖼️"),
            0x8001: t("ALL", "Allison raw image doc", "🖼️"),
            0x8002: t("THN", "ThunderScan image doc", "🖼️"),
            0x8003: t("DGX", "DreamGrafix document", "🎨"),
        ],
        0xC5: [
            0x8000: t("DP", "Draw Plus document", "🎨"),
            0xC000: t("DYOH", "DYOH Architecture doc", "🏗️"),
            0xC001: t("DYOH", "DYOH predrawn objects", "🏗️"),
            0xC002: t("DYOH", "DYOH custom objects", "🏗️"),
            0xC003: t("DYOH", "DYOH clipboard", "🏗️"),
            0xC006: t("DYOH", "DYOH Landscape Document", "🏗️"),
            0xC007: t("PYW", "PyWare Document", "🎨"),
            0xC008: t("AN3", "Animasia 3-D Project", "🎬"),
        ],
        0xC8: [
            0x0000: t("FON", "QuickDraw II Font", "🔤"),
            0x0001: t("TTF", "TrueType font", "🔤"),
        ],
        0xD5: [
            0x0000: t("MCS", "Music Construction Set song", "🎵"),
            0x0001: t("MID", "MIDI Synth sequence", "🎵"),
            0x0007: t("SS", "SoundSmith document", "🎵"),
            0x0008: t("NTP", "NinjaTrackerPlus sequence", "🎵"),
            0x8002: t("DT", "Diversi-Tune sequence", "🎵"),
            0x8003: t("MTJ", "Master Tracks Jr. sequence", "🎵"),
            0x8005: t("AK", "Arcade King Super music", "🎵"),
        ],
        0xD6: [
            0x0000: t("MCS", "Music Construction Set instrument", "🎹"),
            0x0001: t("MID", "MIDI Synth instrument", "🎹"),
            0x8002: t("DT", "Diversi-Tune instrument", "🎹"),
        ],
        0xD7: [
            0x0000: t("MID", "MIDI standard data", "🎵"),
        ],
        0xD8: [
            0x0000: t("AIFF", "Audio IFF document", "🔊"),
            0x0001: t("AIFC", "AIFF-C document", "🔊"),
            0x0002: t("ASIF", "ASIF instrument", "🔊"),
            0x0003: t("SND", "Sound resource file", "🔊"),
            0x0004: t("MID", "MIDI Synth wave data", "🔊"),
            0x0005: t("CDDA", "CD Digital Audio Track", "💿"),
            0x0006: t("CDDD", "CD Digital Data Track", "💿"),
            0x8001: t("HS", "HyperStudio sound", "🔊"),
            0x8002: t("AK", "Arcade King Super sound", "🔊"),
            0x8003: t("SO", "SoundOff! sound bank", "🔊"),
        ],
        0xDB: [
            0x0001: t("DBM", "DB Master document", "🗄️"),
        ],
        0xE0: [
            0x0000: t("ALU", "ALU library", "📦"),
            0x0001: t("AS", "AppleSingle File", "📦"),
            0x0002: t("AD", "AppleDouble Header File", "📦"),
            0x0003: t("AD", "AppleDouble Data File", "📦"),
            0x0005: t("DC", "DiskCopy disk image", "💾"),
            0x8000: t("BNY", "Binary II File", "📦"),
            0x8001: t("ACU", "AppleLink ACU document", "📦"),
            0x8002: t("SHK", "ShrinkIt (NuFX) document", "📦"),
            0x8004: t("DVX", "Davex archived volume", "📦"),
            0x8006: t("EZB", "EZ Backup Saveset doc", "📦"),
            0x8007: t("ELS", "ELS DOS 3.3 volume", "💾"),
            0x8009: t("UW", "UtilityWorks document", "📦"),
            0x800A: t("REP", "Replicator document", "📦"),
            0x800D: t("HP", "HardPressed (data fork)", "📦"),
            0x800E: t("HP", "HardPressed (rsrc fork)", "📦"),
            0x800F: t("HP", "HardPressed (both forks)", "📦"),
        ],
        0xE2: [
            0xFFFF: t("EM", "EasyMount document", "🌐"),
        ],
    ]

    // MARK: - Generic File Types

    private static let genericTypes: [UInt8: ProDOSFileTypeInfo] = [
        0x00: t("NON", "Unknown", "❓"),
        0x01: t("BAD", "Bad blocks", "⚠️"),
        0x02: t("PCD", "Pascal code", "📄"),
        0x03: t("PTX", "Pascal text", "📄"),
        0x04: t("TXT", "ASCII text", "📄"),
        0x05: t("PDA", "Pascal data", "📄"),
        0x06: t("BIN", "Binary", "🔢"),
        0x07: t("FNT", "Apple /// Font", "🔤"),
        0x08: t("FOT", "Apple II Graphics", "🖼️"),
        0x09: t("BA3", "Apple /// BASIC program", "📄"),
        0x0A: t("DA3", "Apple /// BASIC data", "📄"),
        0x0B: t("WPF", "Word Processor", "📝"),
        0x0C: t("SOS", "Apple /// SOS System", "⚙️"),
        0x0F: t("DIR", "Folder", "📁"),
        0x10: t("RPD", "Apple /// RPS data", "📄"),
        0x11: t("RPI", "Apple /// RPS index", "📄"),
        0x12: t("AFD", "Apple /// AppleFile discard", "📄"),
        0x13: t("AFM", "Apple /// AppleFile model", "📄"),
        0x14: t("AFR", "Apple /// AppleFile report", "📄"),
        0x15: t("SCL", "Apple /// screen library", "📄"),
        0x16: t("PFS", "PFS document", "📄"),
        0x19: t("ADB", "AppleWorks Data Base", "🗄️"),
        0x1A: t("AWP", "AppleWorks Word Processor", "📝"),
        0x1B: t("ASP", "AppleWorks Spreadsheet", "📊"),
        0x20: t("TDM", "Desktop Manager document", "📄"),
        0x21: t("IPS", "Instant Pascal source", "📄"),
        0x22: t("UPV", "UCSD Pascal Volume", "💾"),
        0x29: t("DIC", "Apple /// SOS Dictionary", "📕"),
        0x2A: t("8SC", "Apple II Source Code", "📄"),
        0x2B: t("8OB", "Apple II Object Code", "⚙️"),
        0x2C: t("8IC", "Apple II Interpreted Code", "⚙️"),
        0x2D: t("8LD", "Apple II Language Data", "📄"),
        0x2E: t("P8C", "ProDOS 8 code module", "⚙️"),
        0x40: t("DIC", "Dictionary file", "📕"),
        0x41: t("OCR", "OCR data", "🔤"),
        0x42: t("FTD", "File Type Descriptors", "📄"),
        0x43: t("PRD", "Peripheral data", "⚙️"),
        0x50: t("GWP", "Apple IIgs Word Processor", "📝"),
        0x51: t("GSS", "Apple IIgs Spreadsheet", "📊"),
        0x52: t("GDB", "Apple IIgs Data Base", "🗄️"),
        0x53: t("DRW", "Drawing", "🎨"),
        0x54: t("GDP", "Desktop Publishing", "📰"),
        0x55: t("HMD", "Hypermedia", "🗂️"),
        0x56: t("EDU", "Educational Data", "📚"),
        0x57: t("STN", "Stationery", "📄"),
        0x58: t("HLP", "Help File", "❓"),
        0x59: t("COM", "Communications File", "📡"),
        0x5A: t("CFG", "Configuration file", "⚙️"),
        0x5B: t("ANM", "Animation file", "🎬"),
        0x5C: t("MUM", "Multimedia document", "🎭"),
        0x5D: t("ENT", "Game/Entertainment", "🎮"),
        0x5E: t("DVU", "Development utility", "🔧"),
        0x5F: t("FIN", "Financial document", "💰"),
        0x6B: t("BIO", "PC Transporter BIOS", "💿"),
        0x6D: t("TDR", "PC Transporter driver", "💿"),
        0x6E: t("PRE", "PC Transporter pre-boot", "💿"),
        0x6F: t("HDV", "PC Transporter volume", "💿"),
        0xA0: t("WP", "WordPerfect document", "📝"),
        0xAB: t("GSB", "Apple IIgs BASIC program", "📄"),
        0xAC: t("TDF", "Apple IIgs BASIC TDF", "📄"),
        0xAD: t("BDF", "Apple IIgs BASIC data", "📄"),
        0xB0: t("SRC", "Apple IIgs source code", "📄"),
        0xB1: t("OBJ", "Apple IIgs object code", "⚙️"),
        0xB2: t("LIB", "Apple IIgs Library file", "📚"),
        0xB3: t("S16", "GS/OS application", "🖥️"),
        0xB4: t("RTL", "GS/OS Run-Time Library", "📚"),
        0xB5: t("EXE", "GS/OS Shell application", "⚙️"),
        0xB6: t("PIF", "Permanent init file", "⚙️"),
        0xB7: t("TIF", "Temporary init file", "⚙️"),
        0xB8: t("NDA", "New desk accessory", "🔧"),
        0xB9: t("CDA", "Classic desk accessory", "🔧"),
        0xBA: t("TOL", "Tool", "🔧"),
        0xBB: t("DVR", "Device Driver", "⚙️"),
        0xBC: t("LDF", "Load file (generic)", "⚙️"),
        0xBD: t("FST", "File System Translator", "⚙️"),
        0xBF: t("DOC", "GS/OS document", "📄"),
        0xC0: t("PNT", "Packed Super Hi-Res", "🎨"),
        0xC1: t("PIC", "Super Hi-Res picture", "🖼️"),
        0xC2: t("ANI", "Paintworks animation", "🎬"),
        0xC3: t("PAL", "Paintworks palette", "🎨"),
        0xC5: t("OOG", "Object-oriented graphics", "🎨"),
        0xC6: t("SCR", "Script", "📄"),
        0xC7: t("CDV", "Control Panel document", "⚙️"),
        0xC8: t("FON", "Font", "🔤"),
        0xC9: t("FND", "Finder data", "🗂️"),
        0xCA: t("ICN", "Icons", "🖼️"),
        0xD5: t("MUS", "Music sequence", "🎵"),
        0xD6: t("INS", "Instrument", "🎹"),
        0xD7: t("MDI", "MIDI data", "🎵"),
        0xD8: t("SND", "Sampled sound", "🔊"),
        0xDB: t("DBM", "DB Master document", "🗄️"),
        0xE0: t("LBR", "Archival library", "📦"),
        0xE2: t("ATK", "AppleTalk data", "🌐"),
        0xEE: t("R16", "EDASM 816 relocatable", "⚙️"),
        0xEF: t("PAS", "Pascal area", "📄"),
        0xF0: t("CMD", "BASIC command", "⚙️"),
        0xF1: t("U01", "User #1", "📄"),
        0xF2: t("U02", "User #2", "📄"),
        0xF3: t("U03", "User #3", "📄"),
        0xF4: t("U04", "User #4", "📄"),
        0xF5: t("U05", "User #5", "📄"),
        0xF6: t("U06", "User #6", "📄"),
        0xF7: t("U07", "User #7", "📄"),
        0xF8: t("U08", "User #8", "📄"),
        0xF9: t("OS", "GS/OS System file", "⚙️"),
        0xFA: t("INT", "Integer BASIC program", "📄"),
        0xFB: t("IVR", "Integer BASIC variables", "📄"),
        0xFC: t("BAS", "AppleSoft BASIC program", "📄"),
        0xFD: t("VAR", "AppleSoft BASIC variables", "📄"),
        0xFE: t("REL", "Relocatable code", "⚙️"),
        0xFF: t("SYS", "ProDOS 8 application", "⚙️"),
    ]
}
