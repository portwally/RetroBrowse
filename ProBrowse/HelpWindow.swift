//
//  HelpWindow.swift
//  ProBrowse
//
//  Help documentation window with sidebar navigation
//

import SwiftUI

// MARK: - Help Topic Model

enum HelpTopic: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case formats = "Disk Formats"
    case fileOperations = "File Operations"
    case fileInspector = "File Inspector"
    case fileTypes = "File Types"
    case shortcuts = "Keyboard Shortcuts"
    case graphics = "Graphics Preview"
    case sound = "Sound & Music"
    case troubleshooting = "Troubleshooting"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "house"
        case .formats: return "opticaldiscdrive"
        case .fileOperations: return "doc.on.doc"
        case .fileInspector: return "doc.text.magnifyingglass"
        case .fileTypes: return "tag"
        case .shortcuts: return "keyboard"
        case .graphics: return "photo"
        case .sound: return "speaker.wave.2"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Help Window View

struct HelpWindow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTopic: HelpTopic = .overview

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(HelpTopic.allCases, selection: $selectedTopic) { topic in
                Label(topic.rawValue, systemImage: topic.icon)
                    .tag(topic)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            // Detail View
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    helpContent(for: selectedTopic)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Help text can be selected and copied
                .textSelection(.enabled)
            }
        }
        .frame(width: 700, height: 500)
        .navigationTitle("RetroBrowse Help")
    }

    @ViewBuilder
    private func helpContent(for topic: HelpTopic) -> some View {
        switch topic {
        case .overview:
            OverviewHelpView()
        case .formats:
            FormatsHelpView()
        case .fileOperations:
            FileOperationsHelpView()
        case .fileInspector:
            FileInspectorHelpView()
        case .fileTypes:
            FileTypesHelpView()
        case .shortcuts:
            ShortcutsHelpView()
        case .graphics:
            GraphicsHelpView()
        case .sound:
            SoundHelpView()
        case .troubleshooting:
            TroubleshootingHelpView()
        }
    }
}

// MARK: - Overview Help

struct OverviewHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpTitle("Getting Started")

            Text("RetroBrowse is a dual-pane file manager for Apple II disk images. It allows you to browse, copy, and manage files on vintage disk formats.")
                .helpBody()

            HelpSection("Quick Start") {
                HelpBullet("Open disk images in the left and right panes")
                HelpBullet("Browse directories by double-clicking folders")
                HelpBullet("Drag and drop files between panes to copy")
                HelpBullet("Right-click files for more options")
                HelpBullet("Press **Cmd+I** to inspect file contents (BASIC, graphics, hex)")
                HelpBullet("Export files to your Mac via context menu")
            }

            HelpSection("Interface") {
                HelpBullet("**Left/Right Panes** - Each pane shows one disk image")
                HelpBullet("**Header Bar** - Shows volume name, filesystem, and size")
                HelpBullet("**File List** - Displays files with type, size, and dates")
                HelpBullet("**Back Button** - Navigate up from subdirectories")
                HelpBullet("**Expand / Collapse All** - The two buttons at the right of the header bar open or close every folder in that pane")
                HelpBullet("**Skins** - RetroBrowse > Settings: System, Light, Dark, Norton Commander or Apple IIGS 640")
            }

            HelpSection("Skin Fonts") {
                HelpBullet("**Shaston 640** by Kreative Software (kreativekorp.com), used under the Kreative Software Relay Fonts Free Use License")
                HelpBullet("**Modern DOS 9x16**, public domain (CC0)")
            }

            HelpNote("Always backup your disk images before making changes!")
        }
    }
}

// MARK: - Formats Help

struct FormatsHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpTitle("Supported Disk Formats")

            HelpSection("Disk Image Formats") {
                FormatRow(ext: ".po", name: "ProDOS Order", read: true, write: true)
                FormatRow(ext: ".do", name: "DOS Order", read: true, write: true)
                FormatRow(ext: ".dsk", name: "Generic DSK", read: true, write: true)
                FormatRow(ext: ".2mg", name: "Universal 2IMG", read: true, write: true)
                FormatRow(ext: ".hdv", name: "Hard Disk Volume", read: true, write: true)
                FormatRow(ext: ".img", name: "Raw image or DiskCopy 4.2", read: true, write: true)
                FormatRow(ext: ".vol", name: "UCSD Pascal", read: true, write: false)
            }

            HelpSection("Archive Formats") {
                FormatRow(ext: ".shk", name: "ShrinkIt Archive", read: true, write: true)
                FormatRow(ext: ".sdk", name: "ShrinkIt Disk", read: true, write: true)
                FormatRow(ext: ".bxy", name: "Binary II + ShrinkIt", read: true, write: true)
                FormatRow(ext: ".bny", name: "Binary II", read: true, write: true)
                FormatRow(ext: ".gz", name: "Gzip", read: true, write: false)
                FormatRow(ext: ".zip", name: "ZIP Archive", read: true, write: false)
            }

            HelpSection("File Systems") {
                HelpBullet("**ProDOS** - Full read/write with subdirectories")
                HelpBullet("**DOS 3.3** - Full read/write support")
                HelpBullet("**ShrinkIt/Binary II** - Full read/write with native LZW compression")
                HelpBullet("**UCSD Pascal** - Read-only")
                HelpBullet("**Gzip/ZIP** - Read-only")
            }

            HelpNote("All archive formats are handled natively - no external tools required.")
        }
    }
}

// MARK: - File Operations Help

struct FileOperationsHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpTitle("File Operations")

            HelpSection("Copying Files") {
                HelpBullet("**Drag & Drop** - Drag files from one pane to another")
                HelpBullet("**Import from Finder** - Drag files from Finder into a pane")
                HelpBullet("**Archives and images from Finder** - Dropped onto an open disk, RetroBrowse asks whether to copy it as a file, unpack the archive's files, or open it in the pane")
                HelpBullet("**Copy/Paste** - Use Cmd+C and Cmd+V")
                HelpBullet("**Cut/Paste** - Use Cmd+X and Cmd+V (moves files)")
            }

            HelpSection("Managing Files") {
                HelpBullet("**Rename** - Right-click and select Rename")
                HelpBullet("**Delete** - Right-click and select Delete, or press Delete key")
                HelpBullet("**Get Info** - Right-click and select Get Info, or press Cmd+I")
                HelpBullet("**Export** - Right-click and select Export to Finder")
            }

            HelpSection("Directories") {
                HelpBullet("**Navigate** - Double-click to enter a directory")
                HelpBullet("**Go Back** - Click the back arrow or navigate up")
                HelpBullet("**Create** - Use File > New Directory (ProDOS only)")
            }

            HelpSection("Selection") {
                HelpBullet("**Single** - Click to select one file")
                HelpBullet("**Multiple** - Cmd+click to add to selection")
                HelpBullet("**Range** - Shift+click to select a range")
            }
        }
    }
}

// MARK: - File Inspector Help

struct FileInspectorHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpTitle("File Inspector")

            Text("The File Inspector provides a comprehensive view of any file's contents with three tabs: Content, Hex, and Info.")
                .helpBody()

            HelpSection("Opening the Inspector") {
                HelpBullet("Right-click a file and select \"Inspect File...\"")
                HelpBullet("Or press **Space** or **Cmd+I** with a file selected")
                HelpBullet("Or click the magnifying glass icon in the toolbar")
                HelpBullet("Press **Space** or **Esc** again to close it, like Quick Look in the Finder")
                HelpBullet("While it is open, **Up** and **Down** move to the file above or below, and the inspector shows that file")
            }

            HelpSection("Preview Pane") {
                HelpBullet("Click **Preview** above a pane to turn it into a live preview of the file selected in the other pane; click it again to get that pane's disk back")
                HelpBullet("It follows clicks and the arrow keys, and shows the content, every directory field and a hex dump")
                HelpBullet("**Info** - Change the file type and aux type, picking from the known types or typing hex, then Apply")
                HelpBullet("**Resources** - Every resource in a IIgs resource fork, with its type name, ID and size; pick one to see its bytes")
                HelpBullet("**Song** - The title and sample names of a MOD file, where musicians leave their credits; edit them and Save (fields keep their fixed widths)")
                HelpBullet("Changes need a ProDOS disk that isn't read-only")
            }

            HelpSection("Content Tab") {
                HelpBullet("**BASIC Programs** - Detokenized listing with syntax highlighting")
                HelpBullet("**Merlin Assembler** - 6502 source code with column formatting")
                HelpBullet("**6502 Disassembly** - Machine code with mnemonics for BIN/SYS files")
                HelpBullet("**Text Files** - Plain text display")
                HelpBullet("**AppleWorks** - Classic and GS word processor, database, and spreadsheet")
                HelpBullet("**Teach Documents** - Apple IIgs Teach files with fonts, styles, and colors")
                HelpBullet("**Graphics** - HGR, DHGR, SHR, and packed formats with 1x/2x/3x scaling")
                HelpBullet("**Hi-Res Fonts** - Apple II screen fonts ($07/FNT) with character grid")
                HelpBullet("**Sound and Music** - IIgs sounds, SoundSmith, NinjaTracker Plus, MOD, MIDI and AIFF start playing when opened; use Play and Stop to replay or end")
                HelpBullet("**Fonts** - Apple IIgs font preview with sample text and character grid")
                HelpBullet("**Icons** - Apple IIgs icon files with 16-color palette and transparency")
                HelpBullet("**Other Files** - Hex dump with ASCII sidebar")
            }

            HelpSection("BASIC Listing Features") {
                HelpBullet("Keywords highlighted in cyan")
                HelpBullet("String literals in green")
                HelpBullet("REM comments in gray italic")
                HelpBullet("Line numbers in yellow")
                HelpBullet("Long lines wrap with proper indentation")
            }

            HelpSection("Merlin Assembler Features") {
                HelpBullet("Auto-detects TXT files with .S extension")
                HelpBullet("Supports both high-ASCII (Apple II) and low-ASCII (modern) text")
                HelpBullet("Labels in purple, opcodes in blue, comments in green")
                HelpBullet("Proper column alignment (label/opcode/operand/comment)")
                HelpBullet("Long lines wrap with proper indentation")
            }

            HelpSection("Disassembly Features") {
                HelpBullet("**6502** - Automatic for BIN, SYS, REL files")
                HelpBullet("**65816** - For S16, EXE, and other IIgs executables")
                HelpBullet("Uses aux type as load address")
                HelpBullet("Mnemonics in blue, addresses in default color")
                HelpBullet("Comments for known Apple II ROM and I/O addresses")
            }

            HelpSection("Hex Tab") {
                HelpBullet("16 bytes per line with offset column")
                HelpBullet("ASCII sidebar shows printable characters")
                HelpBullet("Supports files up to 64KB display")
            }

            HelpSection("Info Tab") {
                HelpBullet("**File** - Name, type, aux type, and size")
                HelpBullet("**Catalog Entry** - Storage type, key pointer, access flags")
                HelpBullet("**Dates** - Creation and modification dates")
                HelpBullet("**Data** - Blocks used, EOF, and load address")
            }

            HelpNote("The Info tab shows detailed ProDOS metadata including storage type (Seedling, Sapling, Tree) and access permissions.")
        }
    }
}

// MARK: - File Types Help

struct FileTypesHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpTitle("File Types & Aux Types")

            Text("ProDOS files have a file type (1 byte) and auxiliary type (2 bytes) that identify the file format.")
                .helpBody()

            HelpSection("All Known File Types") {
                Text("Every ProDOS and GS/OS file type RetroBrowse knows, with its specific aux types. A checkmark means the inspector can show the file's contents; every file can also be viewed as hex and its details under Info. Hover over a checkmark to see how it is shown.")
                    .helpBody()
                FileTypeTable()
            }

            HelpSection("Changing File Types") {
                HelpBullet("Right-click a file and select \"Change File Type...\"")
                HelpBullet("Enter new file type in hex (e.g., 06 for BIN)")
                HelpBullet("Enter new aux type in hex (e.g., 2000 for load address)")
                HelpBullet("Only available for ProDOS disk images")
            }

            HelpNote("The aux type meaning depends on the file type. For BIN files, it's the load address. For text files, it's usually 0.")
        }
    }
}

// MARK: - File Type Table

/// The file type database with a column showing what the inspector can read
struct FileTypeTable: View {
    @State private var filter = ""

    private var rows: [ProDOSFileTypeInfo.Entry] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return ProDOSFileTypeInfo.allEntries }
        return ProDOSFileTypeInfo.allEntries.filter { row in
            let type = String(format: "$%02x", row.fileType)
            let aux = row.auxType.map { String(format: "$%04x", $0) } ?? ""
            return [type, aux, row.info.shortName.lowercased(), row.info.description.lowercased()]
                .contains { $0.contains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter by type, aux type or name", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            VStack(spacing: 0) {
                row(type: "Type", aux: "Aux", name: "Name", description: "Description", viewer: nil, header: true)
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        let viewer = InspectorSupport.viewer(fileType: entry.fileType, auxType: entry.auxType)
                        row(type: String(format: "$%02X", entry.fileType),
                            aux: entry.auxType.map { String(format: "$%04X", $0) } ?? "any",
                            name: entry.info.shortName,
                            description: entry.info.description,
                            viewer: viewer,
                            header: false)
                            .background(index % 2 == 1 ? Color.secondary.opacity(0.08) : Color.clear)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            Text("\(ProDOSFileTypeInfo.allEntries.count) entries, \(ProDOSFileTypeInfo.allEntries.filter { InspectorSupport.viewer(fileType: $0.fileType, auxType: $0.auxType) != nil }.count) readable")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func row(type: String, aux: String, name: String, description: String, viewer: String?, header: Bool) -> some View {
        HStack(spacing: 8) {
            Text(type).frame(width: 40, alignment: .leading)
            Text(aux).frame(width: 52, alignment: .leading)
                .foregroundColor(!header && aux == "any" ? .secondary : .primary)
            Text(name).frame(width: 48, alignment: .leading)
            Text(description).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Group {
                if header {
                    Text("Read")
                } else if let viewer {
                    Image(systemName: "checkmark").foregroundColor(.green).help(viewer)
                } else {
                    Text("")
                }
            }
            .frame(width: 36)
        }
        .font(header ? .system(size: 11, weight: .semibold) : .system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

// MARK: - Shortcuts Help

struct ShortcutsHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpTitle("Keyboard Shortcuts")

            HelpSection("File Operations") {
                ShortcutRow(keys: "Cmd + C", action: "Copy selected files")
                ShortcutRow(keys: "Cmd + X", action: "Cut selected files")
                ShortcutRow(keys: "Cmd + V", action: "Paste files")
                ShortcutRow(keys: "Delete", action: "Delete selected files")
            }

            HelpSection("Navigation") {
                ShortcutRow(keys: "Space or Cmd + I", action: "Inspect File (Space again closes it)")
                ShortcutRow(keys: "Up / Down", action: "Move the selection (with Shift: extend it)")
                ShortcutRow(keys: "Double-click", action: "Open directory")
                ShortcutRow(keys: "Cmd + click", action: "Add to selection")
                ShortcutRow(keys: "Shift + click", action: "Range selection")
            }

            HelpSection("Application") {
                ShortcutRow(keys: "Cmd + N", action: "New disk image")
                ShortcutRow(keys: "Cmd + O", action: "Open disk image")
                ShortcutRow(keys: "Cmd + Q", action: "Quit RetroBrowse")
            }
        }
    }
}

// MARK: - Graphics Help

struct GraphicsHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpTitle("Graphics Preview")

            Text("RetroBrowse can display Apple II graphics files directly in the preview pane.")
                .helpBody()

            HelpSection("Supported Graphics Formats") {
                HelpBullet("**HGR** - Hi-Res Graphics (280x192, 6 colors)")
                HelpBullet("**DHGR** - Double Hi-Res (560x192, 16 colors)")
                HelpBullet("**SHR** - Super Hi-Res (320x200, 256 colors)")
                HelpBullet("**PIC/PNT** - Packed graphics files")
                HelpBullet("**APF** - Apple Preferred Format")
            }

            HelpSection("Viewing Graphics") {
                HelpBullet("Select a graphics file to see preview")
                HelpBullet("Double-click to open in larger view")
                HelpBullet("Export to save as modern image format")
            }

            HelpNote("Graphics detection is based on file type and aux type. Some files may not be recognized automatically.")
        }
    }
}

// MARK: - Sound & Music Help

struct SoundHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpTitle("Sound & Music")

            Text("RetroBrowse plays Apple IIgs sounds and music right in the inspector and the preview pane.")
                .helpBody()

            HelpSection("Playing") {
                HelpBullet("Select a sound or song and press **Space**, or turn on **Preview** for the other pane: it starts playing on its own")
                HelpBullet("**Play** starts it again from the beginning, **Stop** ends it; moving to another file stops it too")
                HelpBullet("Songs are rendered on the Mac first, so a long song takes a moment before it starts; at most the first 10 minutes are played")
            }

            HelpSection("Sounds") {
                HelpBullet("**Sampled sounds** ($D8) - Apple IIgs sound files, including sounds kept as rSoundSample resources in a resource fork")
                HelpBullet("**ASIF instruments** ($D8/$0002) - each wave in the instrument is listed and can be played")
                HelpBullet("**HyperStudio sounds** ($D8/$8001)")
                HelpBullet("**AIFF and AIFF-C** ($D8/$0000-$0001) - played as they are")
            }

            HelpSection("Music") {
                HelpBullet("**SoundSmith songs** ($D5/$0007) - need their instruments in the same folder: a wave bank, usually named like the song with .W added, or the separate ASIF instrument files the song names (SoundSmith 1.0)")
                HelpBullet("**NinjaTracker Plus songs** ($D5/$0008)")
                HelpBullet("**MOD tracker modules** - ProTracker, NoiseTracker and similar, 4 to 32 channels, found by their contents whatever their file type")
                HelpBullet("**Standard MIDI files** ($D7) - played with the Mac's built-in General MIDI instruments")
            }

            HelpSection("MOD Song Texts") {
                HelpBullet("In the preview pane, the **Song** tab shows a MOD file's title and its 31 sample names, where musicians leave their name, greetings and notes")
                HelpBullet("Edit them and click **Save**; each field keeps its fixed width (20 characters for the title, 22 for a sample name)")
            }

            HelpNote("MIDI Synth wave banks ($D8/$0004) and SoundSmith songs without their instruments can't be played. The inspector says what is missing.")
        }
    }
}

// MARK: - Troubleshooting Help

struct TroubleshootingHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpTitle("Troubleshooting")

            HelpSection("Disk Won't Open") {
                HelpBullet("Check if the file extension is supported")
                HelpBullet("The disk image may be corrupted")
                HelpBullet("Try opening in another tool to verify")
            }

            HelpSection("Can't Write to Disk") {
                HelpBullet("UCSD Pascal volumes are read-only")
                HelpBullet("Gzip and ZIP archives are read-only")
                HelpBullet("Check if disk image file is locked")
            }

            HelpSection("File Type Not Recognized") {
                HelpBullet("Use \"Change File Type\" to set correct type")
                HelpBullet("Check ProDOS file type documentation")
            }

            HelpSection("Getting Help") {
                HelpBullet("Visit GitHub for issues and updates")
                HelpBullet("Check the README for latest information")
                HelpBullet("Report bugs on the GitHub issue tracker")
            }
        }
    }
}

// MARK: - Helper Views

struct HelpTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.title)
            .fontWeight(.bold)
    }
}

struct HelpSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            content
        }
    }
}

struct HelpBullet: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.secondary)
            Text(text)
                .helpBody()
        }
    }
}

struct HelpNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

struct FormatRow: View {
    let ext: String
    let name: String
    let read: Bool
    let write: Bool

    var body: some View {
        HStack {
            Text(ext)
                .font(.system(.body, design: .monospaced))
                .frame(width: 50, alignment: .leading)
            Text(name)
                .frame(width: 150, alignment: .leading)
            HStack(spacing: 16) {
                Label(read ? "Read" : "—", systemImage: read ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundColor(read ? .green : .secondary)
                Label(write ? "Write" : "—", systemImage: write ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundColor(write ? .green : .secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

struct FileTypeRow: View {
    let type: String
    let name: String
    let desc: String

    var body: some View {
        HStack {
            Text(type)
                .font(.system(.body, design: .monospaced))
                .frame(width: 40, alignment: .leading)
            Text(name)
                .fontWeight(.medium)
                .frame(width: 50, alignment: .leading)
            Text(desc)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
                .frame(width: 140, alignment: .leading)
            Text(action)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension Text {
    func helpBody() -> some View {
        self.font(.body)
            .foregroundColor(.primary)
    }
}

// MARK: - Preview

#Preview {
    HelpWindow()
}
