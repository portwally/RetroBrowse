//
//  AppleWorksDecoder.swift
//  ProBrowse
//
//  Decoder for AppleWorks Word Processor (AWP), Database (ADB), and Spreadsheet (ASP) files
//  Based on CiderPress2 implementation and AppleWorks file format documentation
//

import Foundation

// MARK: - AppleWorks Document Types

enum AppleWorksDocumentType {
    case wordProcessor      // $1A / AWP (Classic AppleWorks)
    case database           // $19 / ADB
    case spreadsheet        // $1B / ASP
    case gsWordProcessor    // $50 / GWP (AppleWorks GS)
}

// MARK: - AppleWorks Text Formatting

struct AWPTextRun {
    let text: String
    let isBold: Bool
    let isItalic: Bool
    let isUnderline: Bool
    let isSuperscript: Bool
    let isSubscript: Bool

    // WYSIWYG properties for AppleWorks GS
    let fontFamily: UInt16?      // IIgs font family number (nil for classic)
    let fontSize: UInt8?         // Point size (nil for classic)
    let colorIndex: UInt8?       // Color palette index (nil for classic)

    // Convenience init for classic AppleWorks (no italic, no WYSIWYG)
    init(text: String, isBold: Bool, isUnderline: Bool, isSuperscript: Bool, isSubscript: Bool) {
        self.text = text
        self.isBold = isBold
        self.isItalic = false
        self.isUnderline = isUnderline
        self.isSuperscript = isSuperscript
        self.isSubscript = isSubscript
        self.fontFamily = nil
        self.fontSize = nil
        self.colorIndex = nil
    }

    // Full init for AppleWorks GS (style flags only, no WYSIWYG)
    init(text: String, isBold: Bool, isItalic: Bool, isUnderline: Bool, isSuperscript: Bool, isSubscript: Bool) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isSuperscript = isSuperscript
        self.isSubscript = isSubscript
        self.fontFamily = nil
        self.fontSize = nil
        self.colorIndex = nil
    }

    // WYSIWYG init for AppleWorks GS with font, size, and color
    init(text: String, isBold: Bool, isItalic: Bool, isUnderline: Bool, isSuperscript: Bool, isSubscript: Bool,
         fontFamily: UInt16, fontSize: UInt8, colorIndex: UInt8) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isSuperscript = isSuperscript
        self.isSubscript = isSubscript
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.colorIndex = colorIndex
    }
}

struct AWPLine {
    let runs: [AWPTextRun]
    let isCentered: Bool
    let isRightJustified: Bool
    let isFullyJustified: Bool
}

// MARK: - AppleWorks Word Processor Document

/// Color entry from IIgs color palette (RGB444 format)
struct GWPColor {
    let red: UInt8      // 0-15
    let green: UInt8    // 0-15
    let blue: UInt8     // 0-15

    /// Convert to NSColor-compatible RGB (0-255)
    var red255: UInt8 { UInt8(red) * 17 }
    var green255: UInt8 { UInt8(green) * 17 }
    var blue255: UInt8 { UInt8(blue) * 17 }
}

struct AppleWorksDocument {
    let type: AppleWorksDocumentType
    let lines: [AWPLine]
    let plainText: String

    // Database specific
    let categories: [String]?
    let records: [[String]]?

    // Spreadsheet specific
    let cells: [[String]]?
    let maxColumn: Int?
    let maxRow: Int?

    // AppleWorks GS specific - 16-color palette
    let colorPalette: [GWPColor]?
}

// MARK: - AppleWorks Decoder

class AppleWorksDecoder {

    // MARK: - Word Processor Constants

    private static let AWP_HEADER_SIZE = 300
    private static let SIGNATURE_OFFSET = 4
    private static let SIGNATURE_VALUE: UInt8 = 79  // 0x4F
    private static let MIN_VERS_OFFSET = 183

    // Line record codes
    private static let CODE_TEXT: UInt8 = 0x00
    private static let CODE_CARRIAGE_RETURN: UInt8 = 0xD0
    private static let CODE_END_OF_FILE: UInt8 = 0xFF

    // Command codes
    private static let CMD_RIGHT_JUSTIFY: UInt8 = 0xD7
    private static let CMD_CENTER: UInt8 = 0xE1
    private static let CMD_JUSTIFY: UInt8 = 0xDF
    private static let CMD_UNJUSTIFY: UInt8 = 0xE0
    private static let CMD_NEW_PAGE: UInt8 = 0xE9

    // Text formatting control codes
    private static let CTRL_BOLD_BEGIN: UInt8 = 0x01
    private static let CTRL_BOLD_END: UInt8 = 0x02
    private static let CTRL_SUPER_BEGIN: UInt8 = 0x03
    private static let CTRL_SUPER_END: UInt8 = 0x04
    private static let CTRL_SUB_BEGIN: UInt8 = 0x05
    private static let CTRL_SUB_END: UInt8 = 0x06
    private static let CTRL_UNDERLINE_BEGIN: UInt8 = 0x07
    private static let CTRL_UNDERLINE_END: UInt8 = 0x08
    private static let CTRL_PAGE_NUMBER: UInt8 = 0x09
    private static let CTRL_STICKY_SPACE: UInt8 = 0x0B
    private static let CTRL_DATE: UInt8 = 0x0E
    private static let CTRL_TIME: UInt8 = 0x0F
    private static let CTRL_TAB: UInt8 = 0x16
    private static let CTRL_TAB_FILL: UInt8 = 0x17

    // MARK: - AppleWorks GS Constants

    private static let GWP_HEADER_SIZE = 282
    private static let GWP_GLOBALS_SIZE = 386
    private static let GWP_RULER_SIZE = 52
    private static let GWP_VERSION_1011: UInt16 = 0x1011  // v1.0v2 and v1.1
    private static let GWP_VERSION_0006: UInt16 = 0x0006  // Early beta

    // GWP control codes within paragraphs
    private static let GWP_CTRL_FONT: UInt8 = 0x01      // Followed by 2-byte font family
    private static let GWP_CTRL_STYLE: UInt8 = 0x02    // Followed by 1-byte style flags
    private static let GWP_CTRL_SIZE: UInt8 = 0x03     // Followed by 1-byte point size
    private static let GWP_CTRL_COLOR: UInt8 = 0x04    // Followed by 1-byte color index
    private static let GWP_CTRL_PAGENUM: UInt8 = 0x05  // Page number placeholder
    private static let GWP_CTRL_DATE: UInt8 = 0x06     // Date placeholder
    private static let GWP_CTRL_TIME: UInt8 = 0x07     // Time placeholder
    private static let GWP_CTRL_TAB: UInt8 = 0x09      // Tab character
    private static let GWP_CTRL_CR: UInt8 = 0x0D       // End of paragraph

    // GWP style flags
    private static let GWP_STYLE_BOLD: UInt8 = 0x01
    private static let GWP_STYLE_ITALIC: UInt8 = 0x02
    private static let GWP_STYLE_UNDERLINE: UInt8 = 0x04
    private static let GWP_STYLE_OUTLINE: UInt8 = 0x08
    private static let GWP_STYLE_SHADOW: UInt8 = 0x10
    private static let GWP_STYLE_SUPER: UInt8 = 0x40
    private static let GWP_STYLE_SUB: UInt8 = 0x80

    // MARK: - Database Constants

    private static let ADB_HEADER_MIN_SIZE = 379
    private static let ADB_CATEGORY_HEADER_SIZE = 22
    private static let ADB_REPORT_SIZE = 600

    // MARK: - Spreadsheet Constants

    private static let ASP_HEADER_SIZE = 300
    private static let ASP_MIN_VERS_OFFSET = 242

    // MARK: - Public Interface

    /// Decode an AppleWorks file based on its file type and aux type
    static func decode(data: Data, fileType: UInt8, auxType: UInt16 = 0) -> AppleWorksDocument? {
        switch fileType {
        case 0x1A:  // AWP (Classic AppleWorks Word Processor)
            return decodeWordProcessor(data: data)
        case 0x19:  // ADB (Classic AppleWorks Database)
            return decodeDatabase(data: data)
        case 0x1B:  // ASP (Classic AppleWorks Spreadsheet)
            return decodeSpreadsheet(data: data)
        case 0x50:  // GWP (AppleWorks GS Word Processor)
            if auxType == 0x8010 {
                return decodeGSWordProcessor(data: data)
            }
            return nil
        default:
            return nil
        }
    }

    /// Check if file type/aux type combination is an AppleWorks file
    static func isAppleWorksFile(fileType: UInt8, auxType: UInt16) -> Bool {
        switch fileType {
        case 0x19, 0x1A, 0x1B:  // Classic AppleWorks
            return true
        case 0x50:  // GWP
            return auxType == 0x8010
        default:
            return false
        }
    }

    /// Check if data appears to be a valid AppleWorks Word Processor file
    static func isValidAWP(data: Data) -> Bool {
        guard data.count >= AWP_HEADER_SIZE else { return false }
        return data[SIGNATURE_OFFSET] == SIGNATURE_VALUE
    }

    // MARK: - Word Processor Decoder

    private static func decodeWordProcessor(data: Data) -> AppleWorksDocument? {
        guard data.count >= AWP_HEADER_SIZE else { return nil }

        // Validate signature
        guard data[SIGNATURE_OFFSET] == SIGNATURE_VALUE else { return nil }

        // Check version - v3.0+ files have extra handling
        let minVers = data[MIN_VERS_OFFSET]
        let isVersion3Plus = (minVers >= 30)

        var lines: [AWPLine] = []
        var plainTextLines: [String] = []
        var offset = AWP_HEADER_SIZE

        // AppleWorks 3.0 and later write two unused bytes before the first line record
        if isVersion3Plus {
            offset += 2
        }

        // Current formatting state
        var isCentered = false
        var isRightJustified = false
        var isFullyJustified = false

        // Parse line records
        while offset + 2 <= data.count {
            let lineRecData = data[offset]
            let lineRecCode = data[offset + 1]
            offset += 2

            // Check for EOF
            if lineRecData == 0xFF && lineRecCode == 0xFF {
                break
            }

            switch lineRecCode {
            case CODE_TEXT:
                // Text record: the data byte is its length, which also covers tab rulers
                let recordEnd = min(offset + Int(lineRecData), data.count)
                defer { offset = recordEnd }
                if let (line, plainText) = parseTextRecord(data: data, offset: &offset,
                                                           isCentered: isCentered,
                                                           isRightJustified: isRightJustified,
                                                           isFullyJustified: isFullyJustified,
                                                           isVersion3Plus: isVersion3Plus) {
                    lines.append(line)
                    plainTextLines.append(plainText)
                }

            case CODE_CARRIAGE_RETURN:
                // Empty line (carriage return only)
                let emptyLine = AWPLine(runs: [], isCentered: false, isRightJustified: false, isFullyJustified: false)
                lines.append(emptyLine)
                plainTextLines.append("")

            case CMD_CENTER:
                isCentered = true
                isRightJustified = false
                isFullyJustified = false

            case CMD_RIGHT_JUSTIFY:
                isRightJustified = true
                isCentered = false
                isFullyJustified = false

            case CMD_JUSTIFY:
                isFullyJustified = true
                isCentered = false
                isRightJustified = false

            case CMD_UNJUSTIFY:
                isCentered = false
                isRightJustified = false
                isFullyJustified = false

            case CMD_NEW_PAGE:
                // Add page break marker
                let pageBreak = AWPLine(runs: [AWPTextRun(text: "--- Page Break ---", isBold: false, isUnderline: false, isSuperscript: false, isSubscript: false)],
                                       isCentered: true, isRightJustified: false, isFullyJustified: false)
                lines.append(pageBreak)
                plainTextLines.append("")

            default:
                // Skip other command codes (formatting commands we don't display)
                break
            }
        }

        let plainText = plainTextLines.joined(separator: "\n")

        return AppleWorksDocument(
            type: .wordProcessor,
            lines: lines,
            plainText: plainText,
            categories: nil,
            records: nil,
            cells: nil,
            maxColumn: nil,
            maxRow: nil,
            colorPalette: nil
        )
    }

    /// Parse a text record and return formatted line
    private static func parseTextRecord(data: Data, offset: inout Int,
                                        isCentered: Bool, isRightJustified: Bool, isFullyJustified: Bool,
                                        isVersion3Plus: Bool) -> (AWPLine, String)? {
        guard offset + 2 <= data.count else { return nil }

        let crPosTabFlag = data[offset]
        let remCountCrFlag = data[offset + 1]
        offset += 2

        // Check if this is a ruler line (skip it)
        if crPosTabFlag == 0xFF {
            // Skip ruler data - find next record
            return nil
        }

        // Get text byte count (bits 0-6 of remCountCrFlag)
        let textByteCount = Int(remCountCrFlag & 0x7F)

        guard offset + textByteCount <= data.count else { return nil }

        // Extract text bytes
        let textData = data.subdata(in: offset..<(offset + textByteCount))
        offset += textByteCount

        // Parse text with formatting
        var runs: [AWPTextRun] = []
        var currentText = ""
        var isBold = false
        var isUnderline = false
        var isSuperscript = false
        var isSubscript = false
        var plainText = ""

        func flushRun() {
            if !currentText.isEmpty {
                runs.append(AWPTextRun(text: currentText, isBold: isBold, isUnderline: isUnderline,
                                       isSuperscript: isSuperscript, isSubscript: isSubscript))
                currentText = ""
            }
        }

        for byte in textData {
            switch byte {
            case CTRL_BOLD_BEGIN:
                flushRun()
                isBold = true

            case CTRL_BOLD_END:
                flushRun()
                isBold = false

            case CTRL_UNDERLINE_BEGIN:
                flushRun()
                isUnderline = true

            case CTRL_UNDERLINE_END:
                flushRun()
                isUnderline = false

            case CTRL_SUPER_BEGIN:
                flushRun()
                isSuperscript = true

            case CTRL_SUPER_END:
                flushRun()
                isSuperscript = false

            case CTRL_SUB_BEGIN:
                flushRun()
                isSubscript = true

            case CTRL_SUB_END:
                flushRun()
                isSubscript = false

            case CTRL_TAB, CTRL_TAB_FILL:
                currentText += "\t"
                plainText += "\t"

            case CTRL_STICKY_SPACE:
                currentText += " "
                plainText += " "

            case CTRL_PAGE_NUMBER:
                currentText += "#"
                plainText += "#"

            case CTRL_DATE:
                currentText += "[DATE]"
                plainText += "[DATE]"

            case CTRL_TIME:
                currentText += "[TIME]"
                plainText += "[TIME]"

            case 0x00...0x1F:
                // Other control codes - skip
                break

            default:
                // Regular character or extended character
                let char = convertAppleWorksChar(byte)
                currentText += char
                plainText += char
            }
        }

        flushRun()

        let line = AWPLine(runs: runs, isCentered: isCentered, isRightJustified: isRightJustified, isFullyJustified: isFullyJustified)
        return (line, plainText)
    }

    /// Convert AppleWorks extended character to Unicode string
    private static func convertAppleWorksChar(_ byte: UInt8) -> String {
        switch byte {
        case 0x20...0x7F:
            // Standard ASCII
            return String(UnicodeScalar(byte))

        case 0x80...0x9F:
            // Inverse uppercase @, A-Z (map to normal)
            return String(UnicodeScalar(byte - 0x40))

        case 0xA0...0xBF:
            // Inverse symbols/numbers (map to normal)
            return String(UnicodeScalar(byte - 0x80))

        case 0xC0...0xDF:
            // MouseText - map to approximations
            return mouseTextChar(byte - 0xC0)

        case 0xE0...0xFF:
            // Inverse lowercase (map to normal a-z)
            return String(UnicodeScalar(byte - 0x80))

        default:
            return "?"
        }
    }

    /// Map MouseText character to Unicode approximation
    private static func mouseTextChar(_ index: UInt8) -> String {
        // MouseText character approximations
        let mouseText: [String] = [
            "@",  // 0: closed apple
            "O",  // 1: open apple
            "v",  // 2: pointer down
            ">",  // 3: hourglass
            "?",  // 4: checkmark
            "?",  // 5: inverse checkmark
            "|",  // 6: running man
            "?",  // 7: inverse running man
            "<-", // 8: left arrow
            "...",// 9: ellipsis
            "v",  // 10: down arrow
            "^",  // 11: up arrow
            "|",  // 12: vertical bar
            "CR", // 13: return symbol
            "?",  // 14: solid block
            "_",  // 15: underscore cursor
            "->", // 16: right arrow
            "?",  // 17: scroll arrows
            "-",  // 18: horizontal line
            "?",  // 19: check box empty
            "?",  // 20: check box checked
            "?",  // 21: diamond
            "+",  // 22: folder left
            "+",  // 23: folder right
            "{",  // 24: left brace
            "}",  // 25: right brace
            "[",  // 26: open folder
            "]",  // 27: close folder
            "|",  // 28: vertical bar
            "?",  // 29: scroll up
            "?",  // 30: scroll down
            " "   // 31: space
        ]

        if index < mouseText.count {
            return mouseText[Int(index)]
        }
        return "?"
    }

    // MARK: - AppleWorks GS Word Processor Decoder

    private static let GWP_PALETTE_OFFSET = 0x38  // Color palette at offset 56 in header

    private static func decodeGSWordProcessor(data: Data) -> AppleWorksDocument? {
        // Minimum size: header (282) + globals (386) + at least some chunk data
        guard data.count >= GWP_HEADER_SIZE + GWP_GLOBALS_SIZE + 10 else { return nil }

        // Check version
        let version = readWord(data, at: 0)
        guard version == GWP_VERSION_1011 || version == GWP_VERSION_0006 else { return nil }

        // Check header size
        let headerSize = Int(readWord(data, at: 2))
        guard headerSize == GWP_HEADER_SIZE else { return nil }

        // Parse 16-color palette from header (at offset $38, 32 bytes = 16 colors × 2 bytes)
        // IIgs palette format: each color is 2 bytes, RGB444 format ($0RGB)
        var colorPalette: [GWPColor] = []
        for i in 0..<16 {
            let colorWord = readWord(data, at: GWP_PALETTE_OFFSET + i * 2)
            let red = UInt8((colorWord >> 8) & 0x0F)
            let green = UInt8((colorWord >> 4) & 0x0F)
            let blue = UInt8(colorWord & 0x0F)
            colorPalette.append(GWPColor(red: red, green: green, blue: blue))
        }

        // Skip to document body chunk (after header + globals)
        var offset = GWP_HEADER_SIZE + GWP_GLOBALS_SIZE

        // Parse the document body chunk
        var lines: [AWPLine] = []
        var plainTextLines: [String] = []

        if let (chunkLines, chunkPlainText) = parseGWPChunk(data: data, offset: &offset) {
            lines.append(contentsOf: chunkLines)
            plainTextLines.append(contentsOf: chunkPlainText)
        }

        let plainText = plainTextLines.joined(separator: "\n")

        return AppleWorksDocument(
            type: .gsWordProcessor,
            lines: lines,
            plainText: plainText,
            categories: nil,
            records: nil,
            cells: nil,
            maxColumn: nil,
            maxRow: nil,
            colorPalette: colorPalette
        )
    }

    /// Parse a GWP chunk (document body, header, or footer)
    private static func parseGWPChunk(data: Data, offset: inout Int) -> ([AWPLine], [String])? {
        guard offset + 2 <= data.count else { return nil }

        // Read SaveArray count
        let saveArrayCount = Int(readWord(data, at: offset))
        offset += 2

        guard saveArrayCount > 0 && saveArrayCount < 65535 else { return nil }

        // Read SaveArray entries (12 bytes each)
        var saveArrayEntries: [(textBlock: Int, textOffset: Int, rulerNum: Int, isPageBreak: Bool)] = []
        var maxRulerNum = 0
        var maxTextBlock = 0

        for _ in 0..<saveArrayCount {
            guard offset + 12 <= data.count else { break }

            let textBlock = Int(readWord(data, at: offset))
            let textOffset = Int(readWord(data, at: offset + 2))
            let attributes = Int(readWord(data, at: offset + 4))
            let rulerNum = Int(readWord(data, at: offset + 6))
            // Pixel height and line count not needed for text extraction
            offset += 12

            let isPageBreak = (attributes == 1)
            saveArrayEntries.append((textBlock, textOffset, rulerNum, isPageBreak))

            // A page break entry has no text and no ruler; its other fields are not meaningful
            if !isPageBreak {
                maxRulerNum = max(maxRulerNum, rulerNum)
                maxTextBlock = max(maxTextBlock, textBlock)
            }
        }

        // Read rulers (52 bytes each)
        var rulers: [(isCentered: Bool, isRightJust: Bool, isFullJust: Bool)] = []
        let rulerCount = maxRulerNum + 1

        for _ in 0..<rulerCount {
            guard offset + GWP_RULER_SIZE <= data.count else { break }

            let statusBits = readWord(data, at: offset + 2)
            offset += GWP_RULER_SIZE

            // Parse justification from status bits
            let isFullJust = (statusBits & 0x80) != 0
            let isRightJust = (statusBits & 0x40) != 0
            let isCentered = (statusBits & 0x20) != 0

            rulers.append((isCentered, isRightJust, isFullJust))
        }

        // Read text blocks. Each is a 4-byte size followed by the block, which starts with its
        // own size and used count (2 bytes each); paragraph offsets count from the block start.
        var textBlocks: [(start: Int, end: Int)] = []
        for _ in 0...maxTextBlock {
            guard offset + 4 <= data.count else { break }
            let blockSize = Int(readDWord(data, at: offset))
            let blockStart = offset + 4
            guard blockSize >= 4, blockStart + blockSize <= data.count else { break }
            textBlocks.append((blockStart, blockStart + blockSize))
            offset = blockStart + blockSize
        }

        var lines: [AWPLine] = []
        var plainTextLines: [String] = []

        // Each SaveArray entry names its paragraph by text block and offset
        for entry in saveArrayEntries {
            if entry.isPageBreak {
                let pageBreak = AWPLine(
                    runs: [AWPTextRun(text: "--- Page Break ---", isBold: false, isItalic: false,
                                     isUnderline: false, isSuperscript: false, isSubscript: false)],
                    isCentered: true, isRightJustified: false, isFullyJustified: false
                )
                lines.append(pageBreak)
                plainTextLines.append("")
                continue
            }

            guard entry.textBlock < textBlocks.count else { continue }
            let block = textBlocks[entry.textBlock]
            var paragraphOffset = block.start + entry.textOffset

            // Get ruler info for this paragraph
            let rulerNum = entry.rulerNum
            let ruler = rulerNum < rulers.count ? rulers[rulerNum] : (isCentered: false, isRightJust: false, isFullJust: false)

            if let (line, plainText) = parseGWPParagraph(data: data, offset: &paragraphOffset, endOffset: block.end,
                                                         isCentered: ruler.0,
                                                         isRightJustified: ruler.1,
                                                         isFullyJustified: ruler.2) {
                lines.append(line)
                plainTextLines.append(plainText)
            }
        }

        return (lines, plainTextLines)
    }

    /// Parse a single GWP paragraph with WYSIWYG font/size/color tracking
    private static func parseGWPParagraph(data: Data, offset: inout Int, endOffset: Int,
                                          isCentered: Bool, isRightJustified: Bool,
                                          isFullyJustified: Bool) -> (AWPLine, String)? {
        guard offset + 7 <= endOffset else { return nil }

        // Read paragraph header (7 bytes)
        // Bytes 0-1: first font family (UInt16, little-endian)
        // Byte 2: first style flags
        // Byte 3: first point size (0 = default 12pt)
        // Byte 4: first color index (0-15)
        // Bytes 5-6: reserved
        let firstFont = readWord(data, at: offset)
        let firstStyle = data[offset + 2]
        let firstSize = data[offset + 3]
        let firstColor = data[offset + 4]
        offset += 7

        // Initialize WYSIWYG state from paragraph header
        var currentFont = firstFont
        var currentStyle = firstStyle
        var currentSize = firstSize == 0 ? UInt8(12) : firstSize  // Default 12pt
        var currentColor = firstColor

        var runs: [AWPTextRun] = []
        var currentText = ""
        var plainText = ""

        func flushRun() {
            if !currentText.isEmpty {
                let run = AWPTextRun(
                    text: currentText,
                    isBold: (currentStyle & GWP_STYLE_BOLD) != 0,
                    isItalic: (currentStyle & GWP_STYLE_ITALIC) != 0,
                    isUnderline: (currentStyle & GWP_STYLE_UNDERLINE) != 0,
                    isSuperscript: (currentStyle & GWP_STYLE_SUPER) != 0,
                    isSubscript: (currentStyle & GWP_STYLE_SUB) != 0,
                    fontFamily: currentFont,
                    fontSize: currentSize,
                    colorIndex: currentColor
                )
                runs.append(run)
                currentText = ""
            }
        }

        // Parse paragraph content until CR or end
        while offset < endOffset {
            let byte = data[offset]
            offset += 1

            switch byte {
            case GWP_CTRL_FONT:
                // Font change - read 2-byte font family
                flushRun()
                guard offset + 2 <= endOffset else { break }
                currentFont = readWord(data, at: offset)
                offset += 2

            case GWP_CTRL_STYLE:
                // Style change
                flushRun()
                guard offset < endOffset else { break }
                currentStyle = data[offset]
                offset += 1

            case GWP_CTRL_SIZE:
                // Size change - read 1-byte point size
                flushRun()
                guard offset < endOffset else { break }
                let newSize = data[offset]
                currentSize = newSize == 0 ? 12 : newSize
                offset += 1

            case GWP_CTRL_COLOR:
                // Color change - read 1-byte color index
                flushRun()
                guard offset < endOffset else { break }
                currentColor = data[offset]
                offset += 1

            case GWP_CTRL_TAB:
                currentText += "\t"
                plainText += "\t"

            case GWP_CTRL_PAGENUM:
                currentText += "#"
                plainText += "#"

            case GWP_CTRL_DATE:
                currentText += "[DATE]"
                plainText += "[DATE]"

            case GWP_CTRL_TIME:
                currentText += "[TIME]"
                plainText += "[TIME]"

            case GWP_CTRL_CR:
                // End of paragraph
                flushRun()
                let line = AWPLine(runs: runs, isCentered: isCentered,
                                  isRightJustified: isRightJustified,
                                  isFullyJustified: isFullyJustified)
                return (line, plainText)

            case 0x00...0x08, 0x0A...0x0C, 0x0E...0x1F:
                // Other control codes - skip
                break

            default:
                // Regular character (Mac OS Roman encoding)
                let char = convertMacRomanChar(byte)
                currentText += char
                plainText += char
            }
        }

        // Flush any remaining text
        flushRun()
        let line = AWPLine(runs: runs, isCentered: isCentered,
                          isRightJustified: isRightJustified,
                          isFullyJustified: isFullyJustified)
        return (line, plainText)
    }

    /// Convert Mac OS Roman character to Unicode
    private static func convertMacRomanChar(_ byte: UInt8) -> String {
        // Standard ASCII range
        if byte >= 0x20 && byte < 0x80 {
            return String(UnicodeScalar(byte))
        }

        // Mac OS Roman high characters mapping to Unicode
        let macRomanToUnicode: [UInt8: String] = [
            0x80: "Ä", 0x81: "Å", 0x82: "Ç", 0x83: "É", 0x84: "Ñ", 0x85: "Ö", 0x86: "Ü", 0x87: "á",
            0x88: "à", 0x89: "â", 0x8A: "ä", 0x8B: "ã", 0x8C: "å", 0x8D: "ç", 0x8E: "é", 0x8F: "è",
            0x90: "ê", 0x91: "ë", 0x92: "í", 0x93: "ì", 0x94: "î", 0x95: "ï", 0x96: "ñ", 0x97: "ó",
            0x98: "ò", 0x99: "ô", 0x9A: "ö", 0x9B: "õ", 0x9C: "ú", 0x9D: "ù", 0x9E: "û", 0x9F: "ü",
            0xA0: "†", 0xA1: "°", 0xA2: "¢", 0xA3: "£", 0xA4: "§", 0xA5: "•", 0xA6: "¶", 0xA7: "ß",
            0xA8: "®", 0xA9: "©", 0xAA: "™", 0xAB: "´", 0xAC: "¨", 0xAD: "≠", 0xAE: "Æ", 0xAF: "Ø",
            0xB0: "∞", 0xB1: "±", 0xB2: "≤", 0xB3: "≥", 0xB4: "¥", 0xB5: "µ", 0xB6: "∂", 0xB7: "∑",
            0xB8: "∏", 0xB9: "π", 0xBA: "∫", 0xBB: "ª", 0xBC: "º", 0xBD: "Ω", 0xBE: "æ", 0xBF: "ø",
            0xC0: "¿", 0xC1: "¡", 0xC2: "¬", 0xC3: "√", 0xC4: "ƒ", 0xC5: "≈", 0xC6: "∆", 0xC7: "«",
            0xC8: "»", 0xC9: "…", 0xCA: " ", 0xCB: "À", 0xCC: "Ã", 0xCD: "Õ", 0xCE: "Œ", 0xCF: "œ",
            0xD0: "–", 0xD1: "—", 0xD2: "\u{201C}", 0xD3: "\u{201D}", 0xD4: "\u{2018}", 0xD5: "\u{2019}", 0xD6: "÷", 0xD7: "◊",
            0xD8: "ÿ", 0xD9: "Ÿ", 0xDA: "⁄", 0xDB: "€", 0xDC: "‹", 0xDD: "›", 0xDE: "ﬁ", 0xDF: "ﬂ",
            0xE0: "‡", 0xE1: "·", 0xE2: "‚", 0xE3: "„", 0xE4: "‰", 0xE5: "Â", 0xE6: "Ê", 0xE7: "Á",
            0xE8: "Ë", 0xE9: "È", 0xEA: "Í", 0xEB: "Î", 0xEC: "Ï", 0xED: "Ì", 0xEE: "Ó", 0xEF: "Ô",
            0xF0: "", 0xF1: "Ò", 0xF2: "Ú", 0xF3: "Û", 0xF4: "Ù", 0xF5: "ı", 0xF6: "ˆ", 0xF7: "˜",
            0xF8: "¯", 0xF9: "˘", 0xFA: "˙", 0xFB: "˚", 0xFC: "¸", 0xFD: "˝", 0xFE: "˛", 0xFF: "ˇ"
        ]

        return macRomanToUnicode[byte] ?? "?"
    }

    /// Read a 32-bit little-endian value
    private static func readDWord(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) |
               (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) |
               (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - Database Decoder

    private static func decodeDatabase(data: Data) -> AppleWorksDocument? {
        guard data.count >= ADB_HEADER_MIN_SIZE else { return nil }

        // Read header length
        let headerLength = Int(readWord(data, at: 0))
        guard headerLength >= ADB_HEADER_MIN_SIZE && headerLength <= data.count else { return nil }

        // Number of categories (offset 35)
        let numCats = Int(data[35])
        guard numCats >= 1 && numCats <= 30 else { return nil }

        // Number of records (offset 36-37)
        var numRecs = Int(readWord(data, at: 36))
        numRecs &= 0x7FFF  // Clear bit 15 (v3.0 signal)

        // Number of reports (offset 38)
        let numReports = Int(data[38])

        // Check version (reserved for future use)
        let dbMinVers = data[218]
        _ = (dbMinVers >= 30)  // isVersion3Plus - may be used for extended features

        // Read category names (starting at offset 357)
        var categories: [String] = []
        var catOffset = 357

        for _ in 0..<numCats {
            guard catOffset + ADB_CATEGORY_HEADER_SIZE <= data.count else { break }

            let nameLen = Int(data[catOffset])
            if nameLen > 0 && nameLen <= 20 {
                let nameData = data.subdata(in: (catOffset + 1)..<(catOffset + 1 + nameLen))
                if let name = String(data: nameData, encoding: .ascii) {
                    categories.append(name)
                } else {
                    categories.append("Category \(categories.count + 1)")
                }
            } else {
                categories.append("Category \(categories.count + 1)")
            }
            catOffset += ADB_CATEGORY_HEADER_SIZE
        }

        // Skip report definitions
        var dataOffset = headerLength + (numReports * ADB_REPORT_SIZE)

        // Parse records
        var records: [[String]] = []

        // Skip standard values record first
        if dataOffset + 2 <= data.count {
            let recLen = Int(readWord(data, at: dataOffset))
            dataOffset += 2 + recLen
        }

        // Read data records
        for _ in 0..<numRecs {
            guard dataOffset + 2 <= data.count else { break }

            let recLen = Int(readWord(data, at: dataOffset))
            if recLen == 0xFFFF { break }  // EOF marker

            dataOffset += 2
            guard dataOffset + recLen <= data.count else { break }

            let record = parseDBRecord(data: data, offset: dataOffset, length: recLen, numCats: numCats)
            records.append(record)

            dataOffset += recLen
        }

        // Build plain text representation
        var plainTextLines: [String] = []
        plainTextLines.append(categories.joined(separator: "\t"))
        for record in records {
            plainTextLines.append(record.joined(separator: "\t"))
        }
        let plainText = plainTextLines.joined(separator: "\n")

        return AppleWorksDocument(
            type: .database,
            lines: [],
            plainText: plainText,
            categories: categories,
            records: records,
            cells: nil,
            maxColumn: nil,
            maxRow: nil,
            colorPalette: nil
        )
    }

    /// Parse a database record
    private static func parseDBRecord(data: Data, offset: Int, length: Int, numCats: Int) -> [String] {
        var fields: [String] = Array(repeating: "", count: numCats)
        var pos = offset
        let endPos = offset + length
        var catIndex = 0

        while pos < endPos && catIndex < numCats {
            let ctrlByte = data[pos]
            pos += 1

            if ctrlByte == 0xFF {
                // End of record
                break
            } else if ctrlByte >= 0x81 && ctrlByte <= 0x9E {
                // Skip categories
                let skipCount = Int(ctrlByte) - 0x80
                catIndex += skipCount
            } else if ctrlByte >= 0x01 && ctrlByte <= 0x7F {
                // Field data
                let fieldLen = Int(ctrlByte)
                guard pos + fieldLen <= endPos else { break }

                let fieldData = data.subdata(in: pos..<(pos + fieldLen))
                pos += fieldLen

                // Check for special date/time entries
                if fieldLen == 6 && fieldData[0] == 0xC0 {
                    // Date entry
                    fields[catIndex] = parseDateField(fieldData)
                } else if fieldLen == 4 && fieldData[0] == 0xD4 {
                    // Time entry
                    fields[catIndex] = parseTimeField(fieldData)
                } else {
                    // Regular text field
                    var text = ""
                    for byte in fieldData {
                        text += convertAppleWorksChar(byte)
                    }
                    fields[catIndex] = text
                }

                catIndex += 1
            }
        }

        return fields
    }

    /// Parse a date field from ADB format
    private static func parseDateField(_ data: Data) -> String {
        guard data.count >= 6 else { return "" }

        let yearHi = data[1]
        let yearLo = data[2]
        let monthCode = data[3]
        let dayHi = data[4]
        let dayLo = data[5]

        let year = String(UnicodeScalar(yearHi)) + String(UnicodeScalar(yearLo))
        let day = String(UnicodeScalar(dayHi)) + String(UnicodeScalar(dayLo))

        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let monthIndex = Int(monthCode) - Int(Character("A").asciiValue!)
        let month = (monthIndex >= 0 && monthIndex < 12) ? months[monthIndex] : "???"

        return "\(day)-\(month)-\(year)"
    }

    /// Parse a time field from ADB format
    private static func parseTimeField(_ data: Data) -> String {
        guard data.count >= 4 else { return "" }

        let hourCode = data[1]
        let minTens = data[2]
        let minOnes = data[3]

        let hour24 = Int(hourCode) - Int(Character("A").asciiValue!)
        let minutes = String(UnicodeScalar(minTens)) + String(UnicodeScalar(minOnes))

        let hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24)
        let ampm = hour24 < 12 ? "AM" : "PM"

        return String(format: "%d:%@ %@", hour12, minutes, ampm)
    }

    // MARK: - Spreadsheet Decoder

    private static func decodeSpreadsheet(data: Data) -> AppleWorksDocument? {
        guard data.count >= ASP_HEADER_SIZE else { return nil }

        // Check version
        let ssMinVers = data[ASP_MIN_VERS_OFFSET]
        let isVersion3Plus = (ssMinVers != 0)

        // Start after header
        var offset = ASP_HEADER_SIZE

        // Skip 2 bytes if v3.0+
        if isVersion3Plus {
            offset += 2
        }

        // Parse rows
        var cells: [[String]] = []
        var maxRow = 0
        var maxCol = 0

        while offset + 4 <= data.count {
            // Check for EOF
            if data[offset] == 0xFF && data[offset + 1] == 0xFF {
                break
            }

            let rowLen = Int(readWord(data, at: offset))
            let rowNum = Int(readWord(data, at: offset + 2))
            offset += 4

            if rowLen == 0 { continue }

            guard offset + rowLen - 2 <= data.count else { break }

            // Ensure we have enough rows
            while cells.count <= rowNum {
                cells.append([])
            }

            // Parse cells in this row
            let rowEndOffset = offset + rowLen - 2  // -2 because rowLen includes the 2-byte row number
            var colIndex = 0

            while offset < rowEndOffset {
                let ctrlByte = data[offset]
                offset += 1

                if ctrlByte == 0xFF {
                    // End of row
                    break
                } else if ctrlByte >= 0x81 && ctrlByte <= 0xFE {
                    // Skip columns
                    let skipCount = Int(ctrlByte) - 0x80
                    colIndex += skipCount
                } else if ctrlByte >= 0x01 && ctrlByte <= 0x7F {
                    // Cell data
                    let cellLen = Int(ctrlByte)
                    guard offset + cellLen <= data.count else { break }

                    let cellData = data.subdata(in: offset..<(offset + cellLen))
                    offset += cellLen

                    // Ensure we have enough columns
                    while cells[rowNum].count <= colIndex {
                        cells[rowNum].append("")
                    }

                    // Parse cell
                    cells[rowNum][colIndex] = parseSSCell(cellData)

                    if colIndex > maxCol { maxCol = colIndex }
                    colIndex += 1
                }
            }

            if rowNum > maxRow { maxRow = rowNum }
        }

        // Build plain text (CSV-like)
        var plainTextLines: [String] = []
        for row in cells {
            plainTextLines.append(row.joined(separator: "\t"))
        }
        let plainText = plainTextLines.joined(separator: "\n")

        return AppleWorksDocument(
            type: .spreadsheet,
            lines: [],
            plainText: plainText,
            categories: nil,
            records: nil,
            cells: cells,
            maxColumn: maxCol,
            maxRow: maxRow,
            colorPalette: nil
        )
    }

    /// Parse a spreadsheet cell
    private static func parseSSCell(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        let flag0 = data[0]

        if (flag0 & 0x80) == 0 {
            // Label cell
            if (flag0 & 0x20) != 0 {
                // Propagated label (repeated character)
                if data.count >= 2 {
                    let char = convertAppleWorksChar(data[1])
                    return String(repeating: char, count: 8)
                }
            } else {
                // Regular label
                var text = ""
                for i in 1..<data.count {
                    text += convertAppleWorksChar(data[i])
                }
                return text
            }
        } else {
            // Value cell
            if data.count >= 2 {
                let flag1 = data[1]

                if (flag0 & 0x20) != 0 {
                    // Value constant (8-byte double)
                    if data.count >= 10 {
                        let doubleData = data.subdata(in: 2..<10)
                        let value = doubleFromData(doubleData)
                        return formatNumber(value)
                    }
                } else {
                    // Formula - check for display string or cached result
                    if (flag1 & 0x08) != 0 {
                        // Has display string
                        if data.count >= 3 {
                            let strLen = Int(data[2])
                            if data.count >= 3 + strLen {
                                var text = ""
                                for i in 3..<(3 + strLen) {
                                    text += convertAppleWorksChar(data[i])
                                }
                                return text
                            }
                        }
                    } else {
                        // Has cached result (8-byte double)
                        if data.count >= 10 {
                            let doubleData = data.subdata(in: 2..<10)
                            let value = doubleFromData(doubleData)
                            return formatNumber(value)
                        }
                    }
                }
            }
        }

        return ""
    }

    /// Convert 8 bytes (little-endian) to Double
    private static func doubleFromData(_ data: Data) -> Double {
        guard data.count >= 8 else { return 0 }

        var value: Double = 0
        let bytes = [UInt8](data)
        withUnsafeMutableBytes(of: &value) { ptr in
            for i in 0..<8 {
                ptr[i] = bytes[i]
            }
        }
        return value
    }

    /// Format a number for display
    private static func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e10 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.6g", value)
        }
    }

    // MARK: - Helpers

    private static func readWord(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}
