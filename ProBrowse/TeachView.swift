//
//  TeachView.swift
//  ProBrowse
//
//  View for displaying Apple IIgs Teach documents with WYSIWYG rendering
//

import SwiftUI

struct TeachView: View {
    let entry: DiskCatalogEntry

    @State private var document: TeachDocument?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let doc = document {
                TeachDocumentView(document: doc)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("Unable to decode Teach document")
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
        if let doc = TeachDecoder.decode(dataFork: entry.data, resourceFork: entry.resourceForkData) {
            document = doc
        } else {
            errorMessage = "File format not recognized or corrupted"
        }
    }
}

// MARK: - Teach Document View

struct TeachDocumentView: View {
    let document: TeachDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(document.lines.enumerated()), id: \.offset) { _, line in
                    TeachLineView(line: line)
                }
            }
            .padding(40)  // Paper-like margins
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)  // Paper background
        }
        .background(Color(white: 0.85))  // Gray canvas surround
    }
}

struct TeachLineView: View {
    let line: TeachLine

    var body: some View {
        Group {
            if line.runs.isEmpty {
                Text(" ")  // Empty line placeholder
            } else {
                // One Text for the whole line, so a long paragraph wraps as a unit
                line.runs.reduce(Text("")) { $0 + TeachRunView(run: $1).text }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TeachRunView: View {
    let run: TeachTextRun

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
        var size = CGFloat(run.fontSize)
        if run.isSuperscript || run.isSubscript {
            size *= 0.7  // Smaller for super/subscript
        }

        let fontName = mapIIgsFontFamily(run.fontFamily)
        return Font.custom(fontName, size: size)
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
        case 0x0061, 0xFFFE:  // Shaston
            return "Menlo"
        default:
            return "Helvetica Neue"  // Default to Geneva equivalent
        }
    }

    /// Calculate baseline offset for super/subscript
    private var baselineOffset: CGFloat {
        let offset = CGFloat(run.fontSize) * 0.3
        return run.isSuperscript ? offset : (run.isSubscript ? -offset : 0)
    }

    /// Get text color from foreground color
    /// QuickDraw II colors are 16-bit patterns, we interpret as simple palette index
    private var textColor: Color {
        let colorValue = run.foregroundColor

        // Handle common QuickDraw II solid colors
        // 0x0000 = black, 0xFFFF = white
        // Simple pattern colors like 0x4444 = dark red pattern

        if colorValue == 0x0000 {
            return .black
        } else if colorValue == 0xFFFF {
            return .white
        }

        // Try to interpret as a solid color or pattern
        // QuickDraw II patterns are repeated; we look at the base nibble
        let nibble = colorValue & 0x000F

        // Map IIgs 16-color palette (roughly)
        switch nibble {
        case 0x0: return .black
        case 0x1: return Color(red: 0.5, green: 0, blue: 0)    // Dark red
        case 0x2: return Color(red: 0, green: 0.5, blue: 0)    // Dark green
        case 0x3: return Color(red: 0.5, green: 0.25, blue: 0) // Brown
        case 0x4: return Color(red: 0, green: 0, blue: 0.5)    // Dark blue
        case 0x5: return Color(red: 0.5, green: 0, blue: 0.5)  // Purple
        case 0x6: return Color(red: 0, green: 0.5, blue: 0.5)  // Teal
        case 0x7: return Color(white: 0.75)                     // Light gray
        case 0x8: return Color(white: 0.5)                      // Gray
        case 0x9: return .red
        case 0xA: return .green
        case 0xB: return .yellow
        case 0xC: return .blue
        case 0xD: return Color(red: 1, green: 0, blue: 1)      // Magenta
        case 0xE: return .cyan
        case 0xF: return .white
        default: return .black
        }
    }
}

// MARK: - Preview

#Preview("Teach Document") {
    TeachView(entry: DiskCatalogEntry(
        name: "READ.ME",
        fileType: 0x50,
        fileTypeString: "GWP",
        auxType: 0x5445,
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
