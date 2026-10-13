//
//  FileInspectorSheet.swift
//  ProBrowse
//
//  File inspector with tabbed interface for viewing file contents
//

import SwiftUI
import AppKit

struct FileInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: DiskCatalogEntry

    enum InspectorTab: String, CaseIterable {
        case content = "Content"
        case hex = "Hex"
        case info = "Info"
    }

    @State private var selectedTab: InspectorTab = .content

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(entry.name)
                    .font(.headline)

                Spacer()

                // Print button
                Button(action: { printContent() }) {
                    Image(systemName: "printer")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Print (Cmd+P)")
                .keyboardShortcut("p", modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Tab Picker
            Picker(selection: $selectedTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Tab Content
            switch selectedTab {
            case .content:
                FileContentView(entry: entry)
            case .hex:
                HexDumpView(data: entry.data)
            case .info:
                FileInfoView(entry: entry)
            }

            Divider()

            // Footer
            HStack {
                Text("\(entry.data.count) bytes")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
        }
        .frame(width: 700, height: 800)
    }

    // MARK: - Print Functionality

    private func printContent() {
        let printView: NSView

        switch selectedTab {
        case .content:
            printView = createContentPrintView()
        case .hex:
            printView = createHexPrintView()
        case .info:
            printView = createInfoPrintView()
        }

        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .automatic
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false
        printInfo.leftMargin = 50
        printInfo.rightMargin = 50
        printInfo.topMargin = 50
        printInfo.bottomMargin = 50

        let printOperation = NSPrintOperation(view: printView, printInfo: printInfo)
        printOperation.showsPrintPanel = true
        printOperation.showsProgressPanel = true
        printOperation.jobTitle = entry.name

        printOperation.run()
    }

    private func createContentPrintView() -> NSView {
        let contentType = detectContentType()

        switch contentType {
        case .text:
            return createTextPrintView(convertAppleIIText(entry.data))
        case .applesoftBasic:
            let listing = ApplesoftDetokenizer.detokenize(entry.data)
            return createBasicPrintView(listing, title: "Applesoft BASIC: \(entry.name)")
        case .integerBasic:
            let listing = IntegerBasicDetokenizer.detokenize(entry.data)
            return createBasicPrintView(listing, title: "Integer BASIC: \(entry.name)")
        case .merlin:
            let listing = MerlinDecoder.toPlainText(entry.data)
            return createBasicPrintView(listing, title: "Merlin Assembler: \(entry.name)")
        case .disassembly:
            let startAddr = entry.auxType != 0 ? entry.auxType : (entry.fileType == 0xFF ? 0x2000 : 0x0800)
            let listing = Disassembler6502.toPlainText(data: entry.data, startAddress: startAddr)
            return createBasicPrintView(listing, title: "6502 Disassembly: \(entry.name)")
        case .disassembly65816:
            let startAddr: UInt32 = entry.auxType != 0 ? UInt32(entry.auxType) : 0x010000
            let listing = Disassembler65816.toPlainText(data: entry.data, startAddress: startAddr)
            return createBasicPrintView(listing, title: "65816 Disassembly: \(entry.name)")
        case .graphics:
            return createGraphicsPrintView()
        case .font:
            return createFontPrintView()
        case .hiResFont:
            return createHiResFontPrintView()
        case .icon:
            return createIconPrintView()
        case .appleWorks:
            return createAppleWorksPrintView()
        case .teach:
            return createTeachPrintView()
        case .binary:
            return createHexPrintView()
        }
    }

    private func createTextPrintView(_ text: String) -> NSView {
        return PrintableTextView(text: text)
    }

    private func createBasicPrintView(_ listing: String, title: String) -> NSView {
        let text = "\(title)\n\n\(listing)"
        return createTextPrintView(text)
    }

    private func createGraphicsPrintView() -> NSView {
        // Try to decode the image
        if let image = decodeGraphicsImage() {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            return imageView
        }
        return createTextPrintView("Unable to decode graphics")
    }

    private func decodeGraphicsImage() -> NSImage? {
        // Try various graphics decoders
        let result = AppleIIDecoder.detectAndDecode(data: entry.data, fileType: entry.fileType, auxType: entry.auxType)
        if let cgImage = result.image {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }

    private func createFontPrintView() -> NSView {
        // Create a simple text representation of font info
        var text = "Apple IIgs Font: \(entry.name)\n\n"
        if let fontFile = AppleIIgsFontDecoder.decode(data: entry.data) {
            text += "Font Height: \(fontFile.fontHeight)\n"
            text += "First Char: \(fontFile.firstChar)\n"
            text += "Last Char: \(fontFile.lastChar)\n"
            text += "Max Width: \(fontFile.maxWidth)\n"
            text += "Ascent: \(fontFile.ascent)\n"
            text += "Descent: \(fontFile.descent)\n"
        }
        return createTextPrintView(text)
    }

    private func createHiResFontPrintView() -> NSView {
        // Render the font grid as an image for printing
        if let font = HiResFontDecoder.decode(entry.data),
           let cgImage = HiResFontDecoder.renderFontGrid(font, scale: 3, showGrid: true) {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: nsImage.size.width, height: nsImage.size.height))
            imageView.image = nsImage
            return imageView
        }
        return createTextPrintView("Unable to decode Hi-Res font")
    }

    private func createIconPrintView() -> NSView {
        // Decode and render icons
        if let iconFile = AppleIIgsIconDecoder.decode(data: entry.data),
           let firstEntry = iconFile.entries.first,
           let largeIcon = firstEntry.largeIcon,
           let cgImage = AppleIIgsIconDecoder.renderIcon(largeIcon, scale: 4) {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: nsImage.size.width, height: nsImage.size.height))
            imageView.image = nsImage
            return imageView
        }
        return createTextPrintView("Unable to decode icons")
    }

    private func createAppleWorksPrintView() -> NSView {
        if let doc = AppleWorksDecoder.decode(data: entry.data, fileType: entry.fileType, auxType: entry.auxType) {
            return createTextPrintView("AppleWorks Document: \(entry.name)\n\n\(doc.plainText)")
        }
        return createTextPrintView("Unable to decode AppleWorks document")
    }

    private func createTeachPrintView() -> NSView {
        if let doc = TeachDecoder.decode(dataFork: entry.data, resourceFork: entry.resourceForkData) {
            return createTextPrintView("Teach Document: \(entry.name)\n\n\(doc.plainText)")
        }
        return createTextPrintView("Unable to decode Teach document")
    }

    private func createHexPrintView() -> NSView {
        var hexText = "Hex Dump: \(entry.name)\n\n"
        let bytesPerLine = 16
        let data = entry.data

        for lineStart in stride(from: 0, to: min(data.count, 65536), by: bytesPerLine) {
            let lineEnd = min(lineStart + bytesPerLine, data.count)
            let lineData = data[lineStart..<lineEnd]

            // Offset
            hexText += String(format: "%08X  ", lineStart)

            // Hex bytes
            for (index, byte) in lineData.enumerated() {
                hexText += String(format: "%02X ", byte)
                if index == 7 { hexText += " " }
            }

            // Padding if short line
            let missing = bytesPerLine - lineData.count
            for i in 0..<missing {
                hexText += "   "
                if lineData.count + i == 7 { hexText += " " }
            }

            hexText += " |"

            // ASCII
            for byte in lineData {
                let char = (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : "."
                hexText += String(char)
            }

            hexText += "|\n"
        }

        if data.count > 65536 {
            hexText += "\n... (truncated at 64KB)"
        }

        return createTextPrintView(hexText)
    }

    private func createInfoPrintView() -> NSView {
        var infoText = "File Information: \(entry.name)\n\n"
        infoText += "File Type: \(entry.fileTypeString) ($\(String(format: "%02X", entry.fileType)))\n"
        infoText += "Aux Type: $\(String(format: "%04X", entry.auxType))\n"
        infoText += "Size: \(entry.size) bytes\n"
        if let blocks = entry.blocks {
            infoText += "Blocks: \(blocks)\n"
        }
        if let storageType = entry.storageType {
            infoText += "Storage Type: \(entry.storageTypeDescription) ($\(String(format: "%02X", storageType)))\n"
        }
        if let accessFlags = entry.accessFlags {
            infoText += "Access: \(entry.accessFlagsDescription) ($\(String(format: "%02X", accessFlags)))\n"
        }
        if let modDate = entry.modificationDate {
            infoText += "Modified: \(modDate)\n"
        }
        if let createDate = entry.creationDate {
            infoText += "Created: \(createDate)\n"
        }

        return createTextPrintView(infoText)
    }

    // MARK: - Apple II Text Conversion

    /// Convert Apple II text data to a printable string
    /// Handles high-ASCII (bit 7 set) and converts CR to newline
    private func convertAppleIIText(_ data: Data) -> String {
        var result = ""
        for byte in data {
            // Handle Apple II high-ASCII (high bit set for normal text)
            let lowByte = byte & 0x7F
            if lowByte >= 0x20 && lowByte < 0x7F {
                result += String(UnicodeScalar(lowByte))
            } else if lowByte == 0x0D {
                result += "\n"  // Convert CR to newline
            } else if lowByte == 0x0A {
                // Skip LF (often follows CR)
            } else if lowByte == 0x00 {
                // Padding between the records of a random-access text file:
                // start a new line once per run of NULs rather than stopping
                if !result.isEmpty && !result.hasSuffix("\n") {
                    result += "\n"
                }
            } else {
                result += "."
            }
        }
        return result
    }

    // MARK: - Content Type Detection for Printing

    private enum PrintContentType {
        case text
        case applesoftBasic
        case integerBasic
        case merlin
        case disassembly
        case disassembly65816
        case graphics
        case font
        case hiResFont
        case icon
        case appleWorks
        case teach
        case binary
    }

    private func detectContentType() -> PrintContentType {
        // Check by ProDOS file type
        switch entry.fileType {
        case 0x04:  // TXT
            // Check if this is Merlin assembler source
            if isMerlinSource() {
                return .merlin
            }
            return .text
        case 0xFC:  // BAS (Applesoft)
            return .applesoftBasic
        case 0xFA:  // INT (Integer BASIC)
            return .integerBasic
        case 0x19:  // ADB (AppleWorks Database)
            return .appleWorks
        case 0x1A:  // AWP (AppleWorks Word Processor)
            return .appleWorks
        case 0x1B:  // ASP (AppleWorks Spreadsheet)
            return .appleWorks
        case 0x50:  // GWP - check aux type for AppleWorks GS or Teach
            if entry.auxType == 0x8010 {
                return .appleWorks  // AppleWorks GS Word Processor
            } else if entry.auxType == 0x5445 {
                return .teach  // Teach document ('TE')
            }
            return .binary
        case 0x06:  // BIN - check if graphics by size, otherwise disassemble
            if isLikelyGraphics() {
                return .graphics
            }
            return .disassembly
        case 0xFF:  // SYS - System file (executable)
            return .disassembly
        case 0xFE:  // REL - Relocatable code
            return .disassembly
        case 0x08:  // FOT (Apple II Graphics)
            return .graphics
        case 0xC0:  // PNT (Packed SHR)
            return .graphics
        case 0xC1:  // PIC (SHR)
            return .graphics
        case 0x07:  // FNT (Hi-Res Font)
            // Validate it's a valid hi-res font size
            if HiResFontDecoder.isHiResFont(entry.data) {
                return .hiResFont
            }
            return .binary
        case 0xC8:  // FNT (Apple IIgs Font)
            return .font
        case 0xCA:  // ICN (Apple IIgs Icons)
            return .icon
        case 0xB3:  // S16 - GS/OS Application (65816)
            if isLikelyGraphics() {
                return .graphics
            }
            return .disassembly65816
        case 0xB5:  // EXE - GS/OS Executable (65816)
            return .disassembly65816
        case 0xBC:  // OSU - GS/OS Utility (65816)
            return .disassembly65816
        default:
            // Check if it looks like text
            if isLikelyText() {
                return .text
            }
            return .binary
        }
    }

    private func isLikelyGraphics() -> Bool {
        let size = entry.data.count
        let auxType = entry.auxType

        // Check aux type hints for graphics load addresses
        if auxType == 0x2000 || auxType == 0x4000 {
            // HGR load addresses - accept HGR size range
            if size >= 8184 && size <= 8200 {
                return true
            }
        }

        // Common Apple II graphics sizes
        return (size >= 8184 && size <= 8200) ||  // HGR (8192 typical, 8184 common)
               size == 16384 ||                    // DHGR
               (size >= 32000 && size <= 32768) || // SHR
               (size >= 38400 && size <= 39000)    // 3200-color SHR
    }

    private func isMerlinSource() -> Bool {
        // Check filename extension (.S is common for Merlin source)
        let name = entry.name.uppercased()
        let hasExtension = name.hasSuffix(".S")

        // Check if content looks like Merlin assembler
        let looksLikeMerlin = MerlinDecoder.isMerlinSource(entry.data)

        // If has .S extension and content matches, definitely Merlin
        // Or if content strongly matches Merlin format
        return (hasExtension && looksLikeMerlin) || looksLikeMerlin
    }

    private func isLikelyText() -> Bool {
        guard entry.data.count > 0 else { return false }

        // Sample first 256 bytes
        let sampleSize = min(256, entry.data.count)
        var printableCount = 0

        for i in 0..<sampleSize {
            let byte = entry.data[i]
            let lowByte = byte & 0x7F  // Handle high-ASCII
            if (lowByte >= 0x20 && lowByte < 0x7F) || lowByte == 0x0D || lowByte == 0x0A {
                printableCount += 1
            }
        }

        // If more than 80% is printable, treat as text
        return Double(printableCount) / Double(sampleSize) > 0.8
    }
}

// MARK: - File Content View

struct FileContentView: View {
    let entry: DiskCatalogEntry

    var body: some View {
        Group {
            switch detectContentType() {
            case .text:
                TextContentView(data: entry.data)
            case .applesoftBasic:
                BasicListingView(data: entry.data, isApplesoft: true)
            case .integerBasic:
                BasicListingView(data: entry.data, isApplesoft: false)
            case .merlin:
                MerlinView(entry: entry)
            case .disassembly:
                DisassemblyView(entry: entry)
            case .disassembly65816:
                Disassembly65816View(entry: entry)
            case .graphics:
                GraphicsPreviewView(entry: entry)
            case .font:
                FontPreviewView(entry: entry)
            case .hiResFont:
                HiResFontView(entry: entry)
            case .icon:
                IconPreviewView(entry: entry)
            case .appleWorks:
                AppleWorksView(entry: entry)
            case .teach:
                TeachView(entry: entry)
            case .binary:
                HexDumpView(data: entry.data)
            }
        }
    }

    enum FileContentType {
        case text
        case applesoftBasic
        case integerBasic
        case merlin
        case disassembly
        case disassembly65816
        case graphics
        case font
        case hiResFont
        case icon
        case appleWorks
        case teach
        case binary
    }

    private func detectContentType() -> FileContentType {
        // Check by ProDOS file type
        switch entry.fileType {
        case 0x04:  // TXT
            // Check if this is Merlin assembler source (.S extension or Merlin content)
            if isMerlinSource() {
                return .merlin
            }
            return .text
        case 0xFC:  // BAS (Applesoft)
            return .applesoftBasic
        case 0xFA:  // INT (Integer BASIC)
            return .integerBasic
        case 0x19:  // ADB (AppleWorks Database)
            return .appleWorks
        case 0x1A:  // AWP (AppleWorks Word Processor)
            return .appleWorks
        case 0x1B:  // ASP (AppleWorks Spreadsheet)
            return .appleWorks
        case 0x50:  // GWP - check aux type for AppleWorks GS or Teach
            if entry.auxType == 0x8010 {
                return .appleWorks  // AppleWorks GS Word Processor
            } else if entry.auxType == 0x5445 {
                return .teach  // Teach document ('TE')
            }
            return .binary
        case 0x06:  // BIN - check if graphics by size, otherwise disassemble
            if isLikelyGraphics() {
                return .graphics
            }
            return .disassembly
        case 0xFF:  // SYS - System file (executable)
            return .disassembly
        case 0xFE:  // REL - Relocatable code
            return .disassembly
        case 0x08:  // FOT (Apple II Graphics)
            return .graphics
        case 0xC0:  // PNT (Packed SHR)
            return .graphics
        case 0xC1:  // PIC (SHR)
            return .graphics
        case 0x07:  // FNT (Hi-Res Font)
            // Validate it's a valid hi-res font size
            if HiResFontDecoder.isHiResFont(entry.data) {
                return .hiResFont
            }
            return .binary
        case 0xC8:  // FNT (Apple IIgs Font)
            return .font
        case 0xCA:  // ICN (Apple IIgs Icons)
            return .icon
        case 0xB3:  // S16 - GS/OS Application (65816)
            if isLikelyGraphics() {
                return .graphics
            }
            return .disassembly65816
        case 0xB5:  // EXE - GS/OS Executable (65816)
            return .disassembly65816
        case 0xBC:  // OSU - GS/OS Utility (65816)
            return .disassembly65816
        default:
            // Check if it looks like text
            if isLikelyText() {
                return .text
            }
            return .binary
        }
    }

    private func isLikelyGraphics() -> Bool {
        let size = entry.data.count
        let auxType = entry.auxType

        // Check aux type hints for graphics load addresses
        if auxType == 0x2000 || auxType == 0x4000 {
            // HGR load addresses - accept HGR size range
            if size >= 8184 && size <= 8200 {
                return true
            }
        }

        // Common Apple II graphics sizes
        return (size >= 8184 && size <= 8200) ||  // HGR (8192 typical, 8184 common)
               size == 16384 ||                    // DHGR
               (size >= 32000 && size <= 32768) || // SHR
               (size >= 38400 && size <= 39000)    // 3200-color SHR
    }

    private func isMerlinSource() -> Bool {
        // Check filename extension (.S is common for Merlin source)
        let name = entry.name.uppercased()
        let hasExtension = name.hasSuffix(".S")

        // Check if content looks like Merlin assembler
        let looksLikeMerlin = MerlinDecoder.isMerlinSource(entry.data)

        // If has .S extension and content matches, definitely Merlin
        if hasExtension && looksLikeMerlin {
            return true
        }

        // If content strongly matches Merlin format, use it even without extension
        if looksLikeMerlin {
            return true
        }

        return false
    }

    private func isLikelyText() -> Bool {
        guard entry.data.count > 0 else { return false }

        // Sample first 256 bytes
        let sampleSize = min(256, entry.data.count)
        var printableCount = 0

        for i in 0..<sampleSize {
            let byte = entry.data[i]
            let lowByte = byte & 0x7F  // Handle high-ASCII
            if (lowByte >= 0x20 && lowByte < 0x7F) || lowByte == 0x0D || lowByte == 0x0A {
                printableCount += 1
            }
        }

        // If more than 80% is printable, treat as text
        return Double(printableCount) / Double(sampleSize) > 0.8
    }
}

// MARK: - Text Content View

struct TextContentView: View {
    let data: Data

    var body: some View {
        ScrollView {
            Text(convertToText())
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
    }

    private func convertToText() -> String {
        var result = ""
        for byte in data {
            // Handle Apple II high-ASCII (high bit set for normal text)
            let lowByte = byte & 0x7F
            if lowByte >= 0x20 && lowByte < 0x7F {
                result += String(UnicodeScalar(lowByte))
            } else if lowByte == 0x0D {
                result += "\n"
            } else if lowByte == 0x0A {
                // Skip LF if it follows CR
            } else if lowByte == 0x00 {
                // Padding between the records of a random-access text file:
                // start a new line once per run of NULs rather than stopping
                if !result.isEmpty && !result.hasSuffix("\n") {
                    result += "\n"
                }
            } else {
                result += "."
            }
        }
        return result
    }
}

// MARK: - BASIC Listing View

struct BasicListingView: View {
    let data: Data
    let isApplesoft: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(getLines().enumerated()), id: \.offset) { index, line in
                    BasicLineView(line: line, isApplesoft: isApplesoft, isEvenRow: index % 2 == 0)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    private func getLines() -> [String] {
        let listing = isApplesoft
            ? ApplesoftDetokenizer.detokenize(data)
            : IntegerBasicDetokenizer.detokenize(data)
        return listing.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}

struct BasicLineView: View {
    let line: String
    let isApplesoft: Bool
    let isEvenRow: Bool

    // Constants for layout - line number column width
    private let lineNumWidth: CGFloat = 55  // Width for line number + padding

    var body: some View {
        Text(buildAttributedLine())
            .font(.system(size: 13, design: .monospaced))
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Build a single AttributedString with line number and code,
    /// using paragraph style for proper hanging indent on wrapped lines
    private func buildAttributedLine() -> AttributedString {
        // Parse line number and code using regex to handle right-aligned line numbers
        // Format from detokenizer is "%5d " e.g. "   10 PRINT" or "  100 DATA..."
        let pattern = #"^(\s*\d+)\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let lineNumRange = Range(match.range(at: 1), in: line),
              let codeRange = Range(match.range(at: 2), in: line) else {
            // No match - just return the line as-is
            var result = AttributedString(line)
            result.foregroundColor = .primary
            return result
        }

        let lineNum = String(line[lineNumRange]).trimmingCharacters(in: .whitespaces)
        let code = String(line[codeRange])

        // Create paragraph style with hanging indent
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = lineNumWidth  // Continuation lines start here
        paragraphStyle.firstLineHeadIndent = 0     // First line starts at left
        paragraphStyle.lineBreakMode = .byWordWrapping

        // Build attributed string: line number (padded) + code
        var result = AttributedString()

        // Line number - right-aligned within fixed width by padding
        let paddedLineNum = lineNum.padding(toLength: 5, withPad: " ", startingAt: 0)
        var lineNumAttr = AttributedString(paddedLineNum + " ")
        lineNumAttr.foregroundColor = .yellow
        lineNumAttr.font = .system(size: 13, weight: .semibold, design: .monospaced)
        result.append(lineNumAttr)

        // Code with syntax highlighting
        var codeAttr = highlightCode(code)
        codeAttr.font = .system(size: 13, design: .monospaced)
        result.append(codeAttr)

        // Apply paragraph style to entire string
        result.paragraphStyle = paragraphStyle

        return result
    }

    /// Apply syntax highlighting to code portion
    private func highlightCode(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = .primary

        // Highlight strings (text between quotes)
        let stringPattern = "\"[^\"]*\""
        if let regex = try? NSRegularExpression(pattern: stringPattern) {
            let range = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: range) {
                if let swiftRange = Range(match.range, in: code),
                   let attrRange = Range(swiftRange, in: result) {
                    result[attrRange].foregroundColor = .green
                }
            }
        }

        // Highlight REM comments (everything after REM)
        if let remRange = code.range(of: "REM") {
            let commentStart = remRange.lowerBound
            if let attrRange = Range(commentStart..<code.endIndex, in: result) {
                result[attrRange].foregroundColor = .gray
                result[attrRange].inlinePresentationIntent = .emphasized
            }
        }

        // Highlight keywords
        let keywords = [
            "GOTO", "GOSUB", "RETURN", "IF", "THEN", "FOR", "TO", "STEP", "NEXT",
            "PRINT", "INPUT", "LET", "DIM", "READ", "DATA", "END", "STOP",
            "ON", "POKE", "PEEK", "CALL", "HOME", "HTAB", "VTAB", "TEXT", "GR", "HGR",
            "HCOLOR=", "COLOR=", "PLOT", "HPLOT", "HLIN", "VLIN", "DRAW", "XDRAW",
            "GET", "DEF", "FN", "AND", "OR", "NOT", "ONERR", "RESUME"
        ]

        for keyword in keywords {
            var searchStart = code.startIndex
            while let range = code.range(of: keyword, range: searchStart..<code.endIndex) {
                // Only highlight if it's a whole word (not part of a variable name)
                let beforeOK = range.lowerBound == code.startIndex ||
                    !code[code.index(before: range.lowerBound)].isLetter
                let afterOK = range.upperBound == code.endIndex ||
                    !code[range.upperBound].isLetter

                if beforeOK && afterOK {
                    if let attrRange = Range(range, in: result) {
                        result[attrRange].foregroundColor = .cyan
                    }
                }
                searchStart = range.upperBound
            }
        }

        return result
    }
}

// MARK: - Graphics Preview View

struct GraphicsPreviewView: View {
    let entry: DiskCatalogEntry

    @State private var decodedImage: CGImage?
    @State private var imageType: AppleIIImageType = .Unknown
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var scale: Double = 2.0

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                if imageType != .Unknown {
                    Text(imageType.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // The decoded picture's own size; the type's nominal size is wrong for 640-mode and tall pictures
                    let res = decodedImage.map { (width: $0.width, height: $0.height) } ?? imageType.resolution
                    Text("\(res.width)x\(res.height)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Picker(selection: $scale) {
                    Text("1x").tag(1.0)
                    Text("2x").tag(2.0)
                    Text("3x").tag(3.0)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Image display
            ScrollView([.horizontal, .vertical]) {
                if isLoading {
                    ProgressView("Decoding...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image = decodedImage {
                    Image(decorative: image, scale: 1.0)
                        .interpolation(.none)
                        .scaleEffect(scale)
                        .frame(
                            width: CGFloat(image.width) * scale,
                            height: CGFloat(image.height) * scale
                        )
                        .background(Color.black)
                } else if let error = errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Unable to decode image")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            decodeImage()
        }
    }

    private func decodeImage() {
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppleIIDecoder.detectAndDecode(
                data: entry.data,
                fileType: entry.fileType,
                auxType: entry.auxType
            )

            DispatchQueue.main.async {
                self.decodedImage = result.image
                self.imageType = result.type
                self.isLoading = false

                if result.image == nil && result.type == .Unknown {
                    self.errorMessage = "Unknown or unsupported graphics format"
                }
            }
        }
    }
}

// MARK: - File Info View

struct FileInfoView: View {
    let entry: DiskCatalogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // File Section
                GroupBox("File") {
                    VStack(alignment: .leading, spacing: 6) {
                        FileInfoRow(label: "File name", value: entry.name)
                        FileInfoRow(label: "File type", value: String(format: "$%02X (%@)", entry.fileType, entry.fileTypeString))
                        FileInfoHexRow(label: "EOF", hex: entry.size, width: 6)
                        if let blocks = entry.blocks {
                            FileInfoHexRow(label: "Blocks used", hex: blocks, width: 4)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Catalog Entry Section
                GroupBox("Catalog Entry") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let storageType = entry.storageType {
                            FileInfoHexRow(label: "Storage type", hex: Int(storageType), width: 2, suffix: entry.storageTypeDescription)
                        }
                        FileInfoHexRow(label: "File type", hex: Int(entry.fileType), width: 2, suffix: entry.fileTypeString)
                        if let keyPtr = entry.keyPointer {
                            FileInfoHexRow(label: "Key ptr", hex: keyPtr, width: 4)
                        }
                        if let blocks = entry.blocks {
                            FileInfoHexRow(label: "Blocks used", hex: blocks, width: 4)
                        }
                        FileInfoHexRow(label: "EOF", hex: entry.size, width: 6)
                        FileInfoHexRow(label: "Auxtype", hex: Int(entry.auxType), width: 4)

                        if let access = entry.accessFlags {
                            FileInfoHexRow(label: "Access", hex: Int(access), width: 2, suffix: entry.accessFlagsDescription)
                        }
                        if let version = entry.version {
                            FileInfoHexRow(label: "Version", hex: Int(version), width: 2)
                        }
                        if let minVersion = entry.minVersion {
                            FileInfoHexRow(label: "Min version", hex: Int(minVersion), width: 2)
                        }
                        if let headerPtr = entry.headerPointer, headerPtr > 0 {
                            FileInfoHexRow(label: "Header ptr", hex: headerPtr, width: 4)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Dates Section
                if entry.creationDate != nil || entry.modificationDate != nil {
                    GroupBox("Dates") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let created = entry.creationDate {
                                FileInfoRow(label: "Created", value: created)
                            }
                            if let modified = entry.modificationDate {
                                FileInfoRow(label: "Modified", value: modified)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Data Statistics
                GroupBox("Data") {
                    VStack(alignment: .leading, spacing: 6) {
                        FileInfoHexRow(label: "Data size", hex: entry.data.count, width: 6)
                        if entry.data.count > 0 {
                            FileInfoRow(label: "First byte", value: String(format: "$%02X", entry.data[0]))
                            if entry.data.count >= 2 {
                                let lastByte = entry.data[entry.data.count - 1]
                                FileInfoRow(label: "Last byte", value: String(format: "$%02X", lastByte))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
    }
}

// MARK: - File Info Row Helpers

struct FileInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

/// Displays a value in hex and decimal format, similar to DiskBrowser2
struct FileInfoHexRow: View {
    let label: String
    let hex: Int
    let width: Int  // Number of hex digits (2, 4, or 6)
    var suffix: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            // Hex value
            Text(hexString)
                .foregroundColor(.blue)
                .frame(width: 60, alignment: .trailing)

            // Decimal value
            Text(decimalString)
                .frame(width: 70, alignment: .trailing)

            // Optional suffix (description)
            if let suffix = suffix {
                Text(suffix)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
    }

    private var hexString: String {
        switch width {
        case 2: return String(format: "%02X", hex & 0xFF)
        case 4: return String(format: "%04X", hex & 0xFFFF)
        case 6: return String(format: "%06X", hex & 0xFFFFFF)
        default: return String(format: "%X", hex)
        }
    }

    private var decimalString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: hex)) ?? "\(hex)"
    }
}

// MARK: - Printable Text View

/// Custom NSView for printing text without pagination issues
/// Uses CoreText for direct text rendering with proper page breaks
class PrintableTextView: NSView {
    private let text: String
    private let font: NSFont
    private let textColor: NSColor
    private let pageWidth: CGFloat = 500
    private let pageHeight: CGFloat = 700
    private let margin: CGFloat = 20

    private var attributedString: NSAttributedString!
    private var framesetter: CTFramesetter!
    private var pageRanges: [CFRange] = []

    init(text: String, font: NSFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), textColor: NSColor = .black) {
        self.text = text
        self.font = font
        self.textColor = textColor
        super.init(frame: .zero)

        setupText()
        calculatePages()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupText() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        attributedString = NSAttributedString(string: text, attributes: attributes)
        framesetter = CTFramesetterCreateWithAttributedString(attributedString as CFAttributedString)
    }

    private func calculatePages() {
        pageRanges.removeAll()

        let textLength = attributedString.length
        var currentIndex = 0
        let contentWidth = pageWidth - (margin * 2)
        let contentHeight = pageHeight - (margin * 2)

        while currentIndex < textLength {
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(currentIndex, 0), path, nil)
            let frameRange = CTFrameGetVisibleStringRange(frame)

            if frameRange.length == 0 {
                break  // Prevent infinite loop
            }

            pageRanges.append(CFRangeMake(currentIndex, frameRange.length))
            currentIndex += frameRange.length
        }

        // Set frame to accommodate all pages
        let totalHeight = CGFloat(max(1, pageRanges.count)) * pageHeight
        self.frame = NSRect(x: 0, y: 0, width: pageWidth, height: totalHeight)
    }

    // MARK: - Pagination for Printing

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, pageRanges.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let pageIndex = page - 1
        let y = CGFloat(pageRanges.count - 1 - pageIndex) * pageHeight
        return NSRect(x: 0, y: y, width: pageWidth, height: pageHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Fill background white
        context.setFillColor(NSColor.white.cgColor)
        context.fill(dirtyRect)

        let contentWidth = pageWidth - (margin * 2)
        let contentHeight = pageHeight - (margin * 2)

        for (pageIndex, range) in pageRanges.enumerated() {
            let pageY = CGFloat(pageRanges.count - 1 - pageIndex) * pageHeight

            // Only draw if this page intersects with dirtyRect
            let pageRect = NSRect(x: 0, y: pageY, width: pageWidth, height: pageHeight)
            guard pageRect.intersects(dirtyRect) else { continue }

            context.saveGState()

            // Translate to page position with margins
            context.translateBy(x: margin, y: pageY + margin)

            // Create frame for this page's text
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)

            // Draw the text frame
            CTFrameDraw(frame, context)

            context.restoreGState()
        }
    }
}

#Preview {
    FileInspectorSheet(entry: DiskCatalogEntry(
        name: "TEST.BAS",
        fileType: 0xFC,
        fileTypeString: "BAS",
        auxType: 0x0801,
        size: 256,
        blocks: 2,
        loadAddress: 0x0801,
        length: 256,
        data: Data(repeating: 0x00, count: 256),
        isImage: false,
        isDirectory: false,
        children: nil,
        modificationDate: "01-Jan-25",
        creationDate: "01-Jan-25"
    ))
}
