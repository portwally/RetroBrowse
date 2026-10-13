//
//  MerlinView.swift
//  ProBrowse
//
//  View for displaying Merlin Assembler source code with syntax highlighting
//  Based on CiderPress2 format documentation
//

import SwiftUI

// MARK: - Merlin Assembler Decoder

/// Decodes Merlin assembler source files (TXT with .S extension)
/// Merlin uses a column-based format with high-ASCII encoding
class MerlinDecoder {

    // Column positions (0-indexed, for display formatting)
    static let COL_LABEL = 0
    static let COL_OPCODE = 9
    static let COL_OPERAND = 15
    static let COL_COMMENT = 26

    /// Parsed line of Merlin source
    struct MerlinLine {
        let label: String
        let opcode: String
        let operand: String
        let comment: String
        let isFullLineComment: Bool  // Line starts with * or ;
    }

    /// Convert Merlin source file to structured lines
    /// Handles both high-ASCII (0x8D line endings) and low-ASCII (0x0A/0x0D)
    static func decode(_ data: Data) -> [MerlinLine] {
        var lines: [MerlinLine] = []
        var offset = 0

        while offset < data.count {
            // Find end of line (0x8D for high-ASCII, 0x0A or 0x0D for low-ASCII)
            var lineEnd = offset
            while lineEnd < data.count {
                let byte = data[lineEnd]
                if byte == 0x8D || byte == 0x0A || byte == 0x0D {
                    break
                }
                lineEnd += 1
            }

            // Parse this line
            let line = parseLine(data: data, start: offset, end: lineEnd)
            lines.append(line)

            // Move past the line ending
            offset = lineEnd + 1
            // Skip CR after LF (Windows-style line endings)
            if offset < data.count && data[offset - 1] == 0x0D && data[offset] == 0x0A {
                offset += 1
            }
        }

        return lines
    }

    /// Parse a single line of Merlin source
    private static func parseLine(data: Data, start: Int, end: Int) -> MerlinLine {
        guard start < end else {
            return MerlinLine(label: "", opcode: "", operand: "", comment: "", isFullLineComment: false)
        }

        // Check for full-line comment
        let firstByte = data[start]
        let firstChar = firstByte & 0x7F

        if firstChar == UInt8(ascii: "*") || firstChar == UInt8(ascii: ";") {
            // Full line comment - extract entire line as comment
            let comment = extractText(data: data, start: start, end: end, stripHigh: true)
            return MerlinLine(label: "", opcode: "", operand: "", comment: comment, isFullLineComment: true)
        }

        // Fields are separated by spaces (one high-ASCII space in a Merlin file, often
        // several in a low-ASCII listing). A line that starts with a space has no label.
        func isSpace(_ byte: UInt8) -> Bool {
            return byte == 0xA0 || byte == 0x20 || byte == 0x09
        }

        var fields: [String] = []   // label, opcode, operand
        var comment = ""
        var pos = start

        while pos < end && fields.count < 3 {
            // A semicolon where a field would start begins the comment
            if !fields.isEmpty && (data[pos] & 0x7F) == UInt8(ascii: ";") {
                break
            }

            let fieldStart = pos
            var quoteChar: UInt8? = nil

            while pos < end {
                let lowByte = data[pos] & 0x7F

                if let quote = quoteChar {
                    if lowByte == quote { quoteChar = nil }
                } else if isSpace(data[pos]) {
                    break
                } else if fields.count == 2 && (lowByte == UInt8(ascii: "'") || lowByte == UInt8(ascii: "\"")) {
                    // Spaces inside a quoted operand belong to it. A quote that is never
                    // closed (as in LDA #"A) is just a character.
                    let hasClosingQuote = ((pos + 1)..<end).contains { (data[$0] & 0x7F) == lowByte }
                    if hasClosingQuote { quoteChar = lowByte }
                }
                pos += 1
            }

            fields.append(extractText(data: data, start: fieldStart, end: pos, stripHigh: true))

            while pos < end && isSpace(data[pos]) {
                pos += 1
            }
        }

        // Whatever follows the operand is the comment
        if pos < end {
            comment = extractText(data: data, start: pos, end: end, stripHigh: true)
        }

        while fields.count < 3 {
            fields.append("")
        }

        return MerlinLine(
            label: fields[0],
            opcode: fields[1],
            operand: fields[2],
            comment: comment,
            isFullLineComment: false
        )
    }

    /// Extract text from data range, converting from high-ASCII
    private static func extractText(data: Data, start: Int, end: Int, stripHigh: Bool) -> String {
        var result = ""
        for i in start..<end {
            let byte = data[i]
            let charByte = stripHigh ? (byte & 0x7F) : byte
            if charByte >= 0x20 && charByte < 0x7F {
                result += String(UnicodeScalar(charByte))
            }
        }
        return result
    }

    /// Convert to plain text with proper column alignment
    static func toPlainText(_ data: Data) -> String {
        let lines = decode(data)
        var result = ""

        for line in lines {
            if line.isFullLineComment {
                result += line.comment + "\n"
            } else {
                var lineText = ""

                // Label column (starts at 0)
                lineText += line.label

                // Opcode column (starts at 9)
                if !line.opcode.isEmpty || !line.operand.isEmpty || !line.comment.isEmpty {
                    while lineText.count < COL_OPCODE {
                        lineText += " "
                    }
                    lineText += line.opcode
                }

                // Operand column (starts at 15)
                if !line.operand.isEmpty || !line.comment.isEmpty {
                    while lineText.count < COL_OPERAND {
                        lineText += " "
                    }
                    lineText += line.operand
                }

                // Comment column (starts at 26)
                if !line.comment.isEmpty {
                    while lineText.count < COL_COMMENT {
                        lineText += " "
                    }
                    lineText += line.comment
                }

                result += lineText + "\n"
            }
        }

        return result
    }

    /// Check if data looks like Merlin assembler source
    /// Supports both high-ASCII (authentic Apple II) and low-ASCII (modern) text
    static func isMerlinSource(_ data: Data) -> Bool {
        guard data.count > 0 && data.count <= 64 * 1024 else { return false }

        var lineCount = 0
        var validLineCount = 0
        var spaceLineCount = 0  // Lines starting with space (instructions)
        var isLineStart = true
        var highASCIICount = 0
        var lowASCIICount = 0

        for byte in data {
            // Track ASCII type
            if (byte & 0x80) != 0 {
                highASCIICount += 1
            } else if byte >= 0x20 && byte < 0x7F {
                lowASCIICount += 1
            }

            // Check for line endings (both high-ASCII CR and low-ASCII LF/CR)
            let isLineEnd = byte == 0x8D || byte == 0x0A || byte == 0x0D

            if isLineStart && !isLineEnd {
                lineCount += 1
                let ascVal = byte & 0x7F

                if ascVal == UInt8(ascii: "*") || ascVal == UInt8(ascii: ";") {
                    // Comment line
                    validLineCount += 1
                } else if (ascVal >= UInt8(ascii: "a") && ascVal <= UInt8(ascii: "z")) ||
                          (ascVal >= UInt8(ascii: "A") && ascVal <= UInt8(ascii: "Z")) ||
                          ascVal == UInt8(ascii: "_") || ascVal == UInt8(ascii: "]") || ascVal == UInt8(ascii: ":") {
                    // Label line
                    validLineCount += 1
                } else if ascVal == UInt8(ascii: " ") {
                    // Space at start (instruction without label)
                    validLineCount += 1
                    spaceLineCount += 1
                }

                isLineStart = false
            }

            if isLineEnd {
                isLineStart = true
            }
        }

        guard lineCount > 0 else { return false }

        // At least 90% of lines should be valid format (relaxed from 96%)
        let validPercent = (validLineCount * 100) / lineCount
        if validPercent < 90 {
            return false
        }

        // Typical asm files have 30%+ lines starting with space (instructions)
        let spacePercent = (spaceLineCount * 100) / lineCount
        return spacePercent > 25
    }
}

// MARK: - Merlin View

struct MerlinView: View {
    let entry: DiskCatalogEntry

    @State private var lines: [MerlinDecoder.MerlinLine] = []
    @State private var plainText: String = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    MerlinLineView(line: line, lineNumber: index + 1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            decodeSource()
        }
    }

    private func decodeSource() {
        lines = MerlinDecoder.decode(entry.data)
        plainText = MerlinDecoder.toPlainText(entry.data)
    }
}

struct MerlinLineView: View {
    let line: MerlinDecoder.MerlinLine
    let lineNumber: Int

    // Colors for syntax highlighting
    private let labelColor = NSColor.systemPurple
    private let opcodeColor = NSColor.systemBlue
    private let operandColor = NSColor.textColor
    private let commentColor = NSColor.systemGreen
    private let lineNumColor = NSColor.secondaryLabelColor

    // Column widths for hanging indent
    private let lineNumWidth: CGFloat = 40   // "1234 "
    private let labelWidth: CGFloat = 72      // 9 chars monospace
    private let opcodeWidth: CGFloat = 48     // 6 chars monospace
    private let hangingIndent: CGFloat = 160  // Total indent for wrapped lines

    var body: some View {
        Text(buildAttributedLine())
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Build AttributedString with proper hanging indent for wrapped text
    private func buildAttributedLine() -> AttributedString {
        // Create paragraph style with hanging indent
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = hangingIndent  // Wrapped lines start here
        paragraphStyle.firstLineHeadIndent = 0     // First line starts at left
        paragraphStyle.lineBreakMode = .byWordWrapping

        var result = AttributedString()

        // Line number
        var lineNumAttr = AttributedString(String(format: "%4d ", lineNumber))
        lineNumAttr.foregroundColor = Color(lineNumColor)
        result.append(lineNumAttr)

        if line.isFullLineComment {
            // Full line comment in green
            var commentAttr = AttributedString(line.comment)
            commentAttr.foregroundColor = Color(commentColor)
            result.append(commentAttr)
        } else {
            // Label (padded to 9 chars)
            let paddedLabel = line.label.padding(toLength: 9, withPad: " ", startingAt: 0)
            var labelAttr = AttributedString(paddedLabel)
            labelAttr.foregroundColor = line.label.isEmpty ? .clear : Color(labelColor)
            result.append(labelAttr)

            // Opcode (padded to 6 chars)
            let paddedOpcode = line.opcode.padding(toLength: 6, withPad: " ", startingAt: 0)
            var opcodeAttr = AttributedString(paddedOpcode)
            opcodeAttr.foregroundColor = line.opcode.isEmpty ? .clear : Color(opcodeColor)
            opcodeAttr.font = .system(size: 12, weight: .semibold, design: .monospaced)
            result.append(opcodeAttr)

            // Operand
            var operandAttr = AttributedString(line.operand)
            operandAttr.foregroundColor = Color(operandColor)
            result.append(operandAttr)

            // Comment (if any)
            if !line.comment.isEmpty {
                var commentAttr = AttributedString(" " + line.comment)
                commentAttr.foregroundColor = Color(commentColor)
                result.append(commentAttr)
            }
        }

        // Apply paragraph style for hanging indent
        result.paragraphStyle = paragraphStyle

        return result
    }
}

// MARK: - Preview

#Preview {
    // Sample Merlin source (high-ASCII encoded)
    let sampleData = Data([
        // "* SAMPLE PROGRAM" (comment line)
        0xAA, 0xA0, 0xD3, 0xC1, 0xCD, 0xD0, 0xCC, 0xC5, 0xA0, 0xD0, 0xD2, 0xCF, 0xC7, 0xD2, 0xC1, 0xCD, 0x8D,
        // " ORG $300" (instruction)
        0xA0, 0xCF, 0xD2, 0xC7, 0xA0, 0xA4, 0xB3, 0xB0, 0xB0, 0x8D,
        // "START LDA #$00" (label + instruction)
        0xD3, 0xD4, 0xC1, 0xD2, 0xD4, 0xA0, 0xCC, 0xC4, 0xC1, 0xA0, 0xA3, 0xA4, 0xB0, 0xB0, 0x8D,
    ])

    return MerlinView(entry: DiskCatalogEntry(
        name: "TEST.S",
        fileType: 0x04,
        fileTypeString: "TXT",
        auxType: 0x0000,
        size: sampleData.count,
        blocks: 1,
        loadAddress: nil,
        length: sampleData.count,
        data: sampleData,
        isImage: false,
        isDirectory: false,
        children: nil,
        modificationDate: "01-Jan-25",
        creationDate: "01-Jan-25"
    ))
}
