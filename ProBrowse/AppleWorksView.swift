//
//  AppleWorksView.swift
//  ProBrowse
//
//  View for displaying AppleWorks Word Processor, Database, and Spreadsheet documents
//

import SwiftUI

struct AppleWorksView: View {
    let entry: DiskCatalogEntry

    @State private var document: AppleWorksDocument?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let doc = document {
                switch doc.type {
                case .wordProcessor, .gsWordProcessor:
                    WordProcessorView(document: doc)
                case .database:
                    DatabaseView(document: doc)
                case .spreadsheet:
                    SpreadsheetView(document: doc)
                }
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("Unable to decode AppleWorks file")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Decoding...")
            }
        }
        .onAppear {
            decodeDocument()
        }
    }

    private func decodeDocument() {
        if let doc = AppleWorksDecoder.decode(data: entry.data, fileType: entry.fileType, auxType: entry.auxType) {
            document = doc
        } else {
            errorMessage = "File format not recognized or corrupted"
        }
    }
}

// MARK: - Word Processor View

struct WordProcessorView: View {
    let document: AppleWorksDocument

    /// Check if this is a GS document with WYSIWYG rendering
    private var isWYSIWYG: Bool {
        document.type == .gsWordProcessor && document.colorPalette != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isWYSIWYG ? 4 : 2) {
                ForEach(Array(document.lines.enumerated()), id: \.offset) { _, line in
                    LineView(line: line, colorPalette: document.colorPalette, isWYSIWYG: isWYSIWYG)
                }
            }
            .padding(isWYSIWYG ? 40 : 16)  // More padding for paper-like appearance
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isWYSIWYG ? Color.white : Color.clear)
        }
        .font(isWYSIWYG ? .system(size: 12) : .system(.body, design: .monospaced))
        .background(isWYSIWYG ? Color(white: 0.85) : Color(NSColor.textBackgroundColor))  // Gray surround for paper effect
    }
}

struct LineView: View {
    let line: AWPLine
    let colorPalette: [GWPColor]?
    let isWYSIWYG: Bool

    var body: some View {
        Group {
            if line.runs.isEmpty {
                Text(" ")  // Empty line placeholder
            } else {
                // One Text for the whole line, so a long paragraph wraps as a unit
                line.runs.reduce(Text("")) { $0 + RunView(run: $1, colorPalette: colorPalette, isWYSIWYG: isWYSIWYG).text }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        if line.isCentered {
            return .center
        } else if line.isRightJustified {
            return .trailing
        } else {
            return .leading
        }
    }
}

struct RunView: View {
    let run: AWPTextRun
    let colorPalette: [GWPColor]?
    let isWYSIWYG: Bool

    var body: some View {
        text
    }

    var text: Text {
        Text(run.text)
            .font(wysiwygFont)
            .fontWeight(run.isBold ? .bold : .regular)
            .italic(run.isItalic)
            .underline(run.isUnderline)
            .baselineOffset(baselineOffset)
            .foregroundColor(textColor)
    }

    /// Get the font for WYSIWYG rendering
    private var wysiwygFont: Font {
        guard isWYSIWYG, let fontFamily = run.fontFamily, let fontSize = run.fontSize else {
            // Classic AppleWorks - use monospace
            let size: CGFloat = run.isSuperscript || run.isSubscript ? 10 : 13
            return .system(size: size, design: .monospaced)
        }

        // WYSIWYG rendering with actual font and size
        var size = CGFloat(fontSize)
        if run.isSuperscript || run.isSubscript {
            size *= 0.7  // Smaller for super/subscript
        }

        let fontName = mapIIgsFontFamily(fontFamily)
        if let customFont = Font.custom(fontName, size: size) as Font? {
            return customFont
        }
        return .system(size: size)
    }

    /// Map IIgs font family numbers to macOS font names
    private func mapIIgsFontFamily(_ family: UInt16) -> String {
        switch family {
        case 0x0000:  // System font
            return "Helvetica Neue"
        case 0x0001:  // Application font
            return "Helvetica Neue"
        case 0x0002:  // New York
            return "Times New Roman"
        case 0x0003:  // Geneva
            return "Helvetica Neue"
        case 0x0004:  // Monaco
            return "Menlo"
        case 0x0005:  // Venice
            return "Zapfino"
        case 0x0006:  // London
            return "Copperplate"
        case 0x0007:  // Athens
            return "Times New Roman"
        case 0x0008:  // San Francisco
            return "SF Pro"
        case 0x0009:  // Toronto
            return "Helvetica Neue"
        case 0x000B:  // Cairo
            return "Zapf Dingbats"
        case 0x000C:  // Los Angeles
            return "Script MT Bold"
        case 0x0014:  // Times
            return "Times New Roman"
        case 0x0015:  // Helvetica
            return "Helvetica"
        case 0x0016:  // Courier
            return "Courier"
        case 0x0017:  // Symbol
            return "Symbol"
        case 0x0018:  // Taliesin (Mobile)
            return "Zapfino"
        case 0x0061:  // Shaston
            return "Menlo"
        default:
            return "Helvetica Neue"  // Default to Geneva equivalent
        }
    }

    /// Calculate baseline offset for super/subscript
    private var baselineOffset: CGFloat {
        guard isWYSIWYG, let fontSize = run.fontSize else {
            // Classic offset
            return run.isSuperscript ? 4 : (run.isSubscript ? -4 : 0)
        }
        // Scale offset based on font size
        let offset = CGFloat(fontSize) * 0.3
        return run.isSuperscript ? offset : (run.isSubscript ? -offset : 0)
    }

    /// Get text color from palette
    private var textColor: Color {
        guard isWYSIWYG, let palette = colorPalette, let colorIndex = run.colorIndex else {
            return .primary  // Default text color
        }

        let index = Int(colorIndex) & 0x0F  // Ensure 0-15 range
        guard index < palette.count else {
            return .primary
        }

        let gwpColor = palette[index]
        return Color(
            red: Double(gwpColor.red255) / 255.0,
            green: Double(gwpColor.green255) / 255.0,
            blue: Double(gwpColor.blue255) / 255.0
        )
    }
}

// MARK: - Database View

struct DatabaseView: View {
    let document: AppleWorksDocument

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                if let categories = document.categories {
                    HStack(spacing: 0) {
                        ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                            Text(category)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(minWidth: 100, alignment: .leading)
                                .background(Color.accentColor.opacity(0.2))
                                .border(Color.gray.opacity(0.3), width: 0.5)
                        }
                    }
                }

                // Data rows
                if let records = document.records {
                    ForEach(Array(records.enumerated()), id: \.offset) { rowIndex, record in
                        HStack(spacing: 0) {
                            ForEach(Array(record.enumerated()), id: \.offset) { colIndex, value in
                                Text(value)
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .frame(minWidth: 100, alignment: .leading)
                                    .background(rowIndex % 2 == 0 ? Color.clear : Color.gray.opacity(0.05))
                                    .border(Color.gray.opacity(0.3), width: 0.5)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - Spreadsheet View

struct SpreadsheetView: View {
    let document: AppleWorksDocument

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Column headers (A, B, C, ...)
                if let maxCol = document.maxColumn {
                    HStack(spacing: 0) {
                        // Row number header
                        Text("")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.bold)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .frame(width: 40, alignment: .center)
                            .background(Color.gray.opacity(0.2))
                            .border(Color.gray.opacity(0.3), width: 0.5)

                        ForEach(0...maxCol, id: \.self) { col in
                            Text(columnName(col))
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(minWidth: 80, alignment: .center)
                                .background(Color.gray.opacity(0.2))
                                .border(Color.gray.opacity(0.3), width: 0.5)
                        }
                    }
                }

                // Data rows
                if let cells = document.cells, let maxCol = document.maxColumn {
                    ForEach(Array(cells.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 0) {
                            // Row number
                            Text("\(rowIndex + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.bold)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 4)
                                .frame(width: 40, alignment: .center)
                                .background(Color.gray.opacity(0.2))
                                .border(Color.gray.opacity(0.3), width: 0.5)

                            ForEach(0...maxCol, id: \.self) { colIndex in
                                let value = colIndex < row.count ? row[colIndex] : ""
                                Text(value)
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .frame(minWidth: 80, alignment: isNumeric(value) ? .trailing : .leading)
                                    .background(rowIndex % 2 == 0 ? Color.clear : Color.gray.opacity(0.05))
                                    .border(Color.gray.opacity(0.3), width: 0.5)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func columnName(_ index: Int) -> String {
        var result = ""
        var n = index

        repeat {
            let remainder = n % 26
            result = String(UnicodeScalar(65 + remainder)!) + result
            n = n / 26 - 1
        } while n >= 0

        return result
    }

    private func isNumeric(_ str: String) -> Bool {
        guard !str.isEmpty else { return false }
        return Double(str) != nil
    }
}

// MARK: - Preview

#Preview("Word Processor") {
    AppleWorksView(entry: DiskCatalogEntry(
        name: "TEST.DOC",
        fileType: 0x1A,
        fileTypeString: "AWP",
        auxType: 0x0000,
        size: 1000,
        blocks: 10,
        loadAddress: nil,
        length: 1000,
        data: Data(),
        isImage: false,
        isDirectory: false,
        children: nil,
        modificationDate: "01-Jan-25",
        creationDate: "01-Jan-25"
    ))
}
