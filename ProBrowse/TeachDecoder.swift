//
//  TeachDecoder.swift
//  ProBrowse
//
//  Decoder for Apple IIgs Teach documents
//  Teach files use file type GWP ($50) with aux type $5445 ('TE')
//  Data fork: Plain text in Mac OS Roman encoding
//  Resource fork: rStyleBlock ($8012) with TEFormat structure
//

import Foundation

// MARK: - Teach Document Model

struct TeachDocument {
    let lines: [TeachLine]
    let plainText: String
}

struct TeachLine {
    let runs: [TeachTextRun]
}

struct TeachTextRun {
    let text: String
    let fontFamily: UInt16
    let fontSize: UInt8
    let isBold: Bool
    let isItalic: Bool
    let isUnderline: Bool
    let isSuperscript: Bool
    let isSubscript: Bool
    let foregroundColor: UInt16
}

// MARK: - TEFormat Structures (from Apple IIgs Toolbox Reference)

struct TEStyle {
    let fontFamily: UInt16
    let fontStyle: UInt8
    let fontSize: UInt8
    let foreColor: UInt16
    let backColor: UInt16
}

struct StyleItem {
    let length: Int32       // Number of characters using this style (-1 = unused)
    let styleOffset: Int32  // Byte offset into styleList for TEStyle
}

// MARK: - Teach Decoder

class TeachDecoder {

    // Font style bits
    private static let STYLE_BOLD: UInt8 = 0x01
    private static let STYLE_ITALIC: UInt8 = 0x02
    private static let STYLE_UNDERLINE: UInt8 = 0x04
    private static let STYLE_SUPER: UInt8 = 0x40
    private static let STYLE_SUB: UInt8 = 0x80

    // Resource type for style block
    private static let RSTYLE_BLOCK: UInt16 = 0x8012

    /// Check if a file is a Teach document
    static func isTeachDocument(fileType: UInt8, auxType: UInt16) -> Bool {
        return fileType == 0x50 && auxType == 0x5445  // GWP/$5445 = 'TE'
    }

    /// Decode a Teach document from data fork and resource fork
    static func decode(dataFork: Data, resourceFork: Data?) -> TeachDocument? {
        // Get plain text from data fork (Mac OS Roman encoding)
        let plainText = convertMacRomanToString(dataFork)

        // If no resource fork, return plain text document
        guard let rsrcFork = resourceFork, !rsrcFork.isEmpty else {
            return createPlainTextDocument(plainText)
        }

        // Parse resource fork to get style information
        guard let teFormat = parseResourceFork(rsrcFork) else {
            return createPlainTextDocument(plainText)
        }

        // Apply styles to create formatted document
        return applyStyles(plainText: plainText, styles: teFormat.styles, styleItems: teFormat.styleItems)
    }

    // MARK: - Resource Fork Parsing

    private struct TEFormat {
        let styles: [TEStyle]
        let styleItems: [StyleItem]
    }

    /// Parse Apple IIgs resource fork to extract TEFormat
    private static func parseResourceFork(_ data: Data) -> TEFormat? {
        // Apple IIgs resource fork format:
        // Offset 0: Resource file header (varies)
        // The rStyleBlock resource ($8012) contains the TEFormat structure

        // Try to find the rStyleBlock resource
        guard let styleBlockData = findResource(data, type: RSTYLE_BLOCK, id: 1) else {
            return nil
        }

        return parseTEFormat(styleBlockData)
    }

    /// Find a resource by type and ID in the resource fork
    private static func findResource(_ data: Data, type: UInt16, id: UInt32) -> Data? {
        guard data.count >= 12 else { return nil }

        // Resource file header:
        // +$00: rFileVersion (4 bytes)
        // +$04: rFileToMap (4 bytes) - offset to resource map
        // +$08: rFileMapSize (4 bytes) - size of resource map
        let mapOffset = Int(readDWord(data, at: 4))
        let mapSize = Int(readDWord(data, at: 8))
        guard mapOffset > 0, mapSize >= 0x20, mapOffset + mapSize <= data.count else { return nil }

        // Resource map:
        // +$0E: mapToIndex (2 bytes) - offset from the map to the reference records
        // +$18: mapIndexUsed (4 bytes) - number of reference records in use
        // The free list sits between the map header and the reference records.
        let indexOffset = mapOffset + Int(readWord(data, at: mapOffset + 0x0E))
        let indexUsed = Int(readDWord(data, at: mapOffset + 0x18))

        // Resource reference record, 20 bytes:
        // +$00: resType (2 bytes), zero in an unused record
        // +$02: resID (4 bytes)
        // +$06: resOffset (4 bytes) - offset from start of file to resource data
        // +$0A: resAttr (2 bytes)
        // +$0C: resSize (4 bytes)
        // +$10: resHandle (4 bytes) - runtime only
        let recordSize = 20
        let mapEnd = mapOffset + mapSize
        var entryOffset = indexOffset
        var remaining = indexUsed

        while remaining > 0 && entryOffset + recordSize <= mapEnd {
            let resType = readWord(data, at: entryOffset)
            if resType != 0 {
                remaining -= 1
                if resType == type && readDWord(data, at: entryOffset + 2) == id {
                    let resOffset = Int(readDWord(data, at: entryOffset + 6))
                    let resSize = Int(readDWord(data, at: entryOffset + 0x0C))
                    guard resOffset + resSize <= data.count else { return nil }
                    return data.subdata(in: resOffset..<(resOffset + resSize))
                }
            }
            entryOffset += recordSize
        }

        return nil
    }

    /// Parse TEFormat structure from style block data
    private static func parseTEFormat(_ data: Data) -> TEFormat? {
        guard data.count >= 6 else { return nil }

        var offset = 0

        // Version (2 bytes) - should be 0
        let version = readWord(data, at: offset)
        guard version == 0 else { return nil }
        offset += 2

        // rulerListLength (4 bytes)
        let rulerListLength = Int(readDWord(data, at: offset))
        offset += 4

        // Skip theRulerList
        guard rulerListLength <= data.count - offset else { return nil }
        offset += rulerListLength

        guard offset + 4 <= data.count else { return nil }

        // styleListLength (4 bytes)
        let styleListLength = Int(readDWord(data, at: offset))
        offset += 4

        let styleListStart = offset
        guard styleListLength <= data.count - styleListStart else { return nil }

        // Parse styles (TEStyle is 12 bytes each)
        var styles: [TEStyle] = []
        var styleOffset = styleListStart
        while styleOffset + 12 <= styleListStart + styleListLength {
            let fontID = readDWord(data, at: styleOffset)
            let foreColor = readWord(data, at: styleOffset + 4)
            let backColor = readWord(data, at: styleOffset + 6)
            // userData at +8 (4 bytes) - ignored

            // Decode fontID: bits 0-15 = family, 16-23 = style, 24-31 = size
            let fontFamily = UInt16(fontID & 0xFFFF)
            let fontStyle = UInt8((fontID >> 16) & 0xFF)
            let fontSize = UInt8((fontID >> 24) & 0xFF)

            styles.append(TEStyle(
                fontFamily: fontFamily,
                fontStyle: fontStyle,
                fontSize: fontSize == 0 ? 12 : fontSize,
                foreColor: foreColor,
                backColor: backColor
            ))

            styleOffset += 12
        }

        offset = styleListStart + styleListLength
        guard offset + 4 <= data.count else { return nil }

        // numberOfStyles (4 bytes)
        let numberOfStyles = Int(readDWord(data, at: offset))
        offset += 4

        // Parse StyleItems (8 bytes each)
        var styleItems: [StyleItem] = []
        for _ in 0..<numberOfStyles {
            guard offset + 8 <= data.count else { break }

            let length = Int32(bitPattern: readDWord(data, at: offset))
            let styleOff = Int32(bitPattern: readDWord(data, at: offset + 4))
            offset += 8

            if length != -1 {  // -1 means unused
                styleItems.append(StyleItem(length: length, styleOffset: styleOff))
            }
        }

        return TEFormat(styles: styles, styleItems: styleItems)
    }

    // MARK: - Document Building

    private static func createPlainTextDocument(_ text: String) -> TeachDocument {
        let lines = text.components(separatedBy: "\r").map { lineText in
            TeachLine(runs: [TeachTextRun(
                text: lineText,
                fontFamily: 0x0003,  // Geneva
                fontSize: 12,
                isBold: false,
                isItalic: false,
                isUnderline: false,
                isSuperscript: false,
                isSubscript: false,
                foregroundColor: 0x0000  // Black
            )])
        }
        return TeachDocument(lines: lines, plainText: text.replacingOccurrences(of: "\r", with: "\n"))
    }

    private static func applyStyles(plainText: String, styles: [TEStyle], styleItems: [StyleItem]) -> TeachDocument {
        guard !styleItems.isEmpty, !styles.isEmpty else {
            return createPlainTextDocument(plainText)
        }

        var allRuns: [TeachTextRun] = []
        var textIndex = 0
        let textChars = Array(plainText)

        for item in styleItems {
            guard item.length > 0 else { continue }

            // Find the style for this run
            let styleIndex = Int(item.styleOffset) / 12  // TEStyle is 12 bytes
            let style = styles.indices.contains(styleIndex) ? styles[styleIndex] : styles[0]

            // Extract text for this run
            let endIndex = min(textIndex + Int(item.length), textChars.count)
            if textIndex < endIndex {
                let runText = String(textChars[textIndex..<endIndex])

                let run = TeachTextRun(
                    text: runText,
                    fontFamily: style.fontFamily,
                    fontSize: style.fontSize,
                    isBold: (style.fontStyle & STYLE_BOLD) != 0,
                    isItalic: (style.fontStyle & STYLE_ITALIC) != 0,
                    isUnderline: (style.fontStyle & STYLE_UNDERLINE) != 0,
                    isSuperscript: (style.fontStyle & STYLE_SUPER) != 0,
                    isSubscript: (style.fontStyle & STYLE_SUB) != 0,
                    foregroundColor: style.foreColor
                )
                allRuns.append(run)

                textIndex = endIndex
            }
        }

        // If there's remaining text, add it with default style
        if textIndex < textChars.count {
            let remainingText = String(textChars[textIndex...])
            let defaultStyle = styles.first ?? TEStyle(fontFamily: 0x0003, fontStyle: 0, fontSize: 12, foreColor: 0, backColor: 0)
            allRuns.append(TeachTextRun(
                text: remainingText,
                fontFamily: defaultStyle.fontFamily,
                fontSize: defaultStyle.fontSize,
                isBold: false,
                isItalic: false,
                isUnderline: false,
                isSuperscript: false,
                isSubscript: false,
                foregroundColor: 0x0000
            ))
        }

        // Split runs by newlines into lines
        var lines: [TeachLine] = []
        var currentLineRuns: [TeachTextRun] = []

        for run in allRuns {
            let parts = run.text.components(separatedBy: "\r")

            for (index, part) in parts.enumerated() {
                if !part.isEmpty {
                    currentLineRuns.append(TeachTextRun(
                        text: part,
                        fontFamily: run.fontFamily,
                        fontSize: run.fontSize,
                        isBold: run.isBold,
                        isItalic: run.isItalic,
                        isUnderline: run.isUnderline,
                        isSuperscript: run.isSuperscript,
                        isSubscript: run.isSubscript,
                        foregroundColor: run.foregroundColor
                    ))
                }

                // If not the last part, this is a line break
                if index < parts.count - 1 {
                    lines.append(TeachLine(runs: currentLineRuns))
                    currentLineRuns = []
                }
            }
        }

        // Add final line
        if !currentLineRuns.isEmpty {
            lines.append(TeachLine(runs: currentLineRuns))
        }

        // Ensure at least one empty line if document is empty
        if lines.isEmpty {
            lines.append(TeachLine(runs: []))
        }

        return TeachDocument(
            lines: lines,
            plainText: plainText.replacingOccurrences(of: "\r", with: "\n")
        )
    }

    // MARK: - Character Encoding

    private static func convertMacRomanToString(_ data: Data) -> String {
        var result = ""
        for byte in data {
            result += convertMacRomanChar(byte)
        }
        return result
    }

    private static func convertMacRomanChar(_ byte: UInt8) -> String {
        // Standard ASCII range
        if byte >= 0x20 && byte < 0x80 {
            return String(UnicodeScalar(byte))
        }

        // Special control characters
        if byte == 0x0D {
            return "\r"  // Carriage return (paragraph break)
        }
        if byte == 0x09 {
            return "\t"  // Tab
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

        return macRomanToUnicode[byte] ?? " "
    }

    // MARK: - Helpers

    private static func readWord(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readDWord(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) |
               (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) |
               (UInt32(data[offset + 3]) << 24)
    }
}
