//
//  HiResFontView.swift
//  ProBrowse
//
//  View for displaying Apple II Hi-Res fonts (FNT $07)
//  Based on CiderPress2 format documentation
//

import SwiftUI
import AppKit

// MARK: - Hi-Res Font Decoder

/// Decodes Apple II Hi-Res font files
/// Standard fonts: 768 bytes (96 chars) or 1024 bytes (128 chars)
/// Double-size fonts: 3072 bytes (96 chars at 14x16 pixels)
class HiResFontDecoder {

    // Standard glyph dimensions
    static let GLYPH_WIDTH = 7
    static let GLYPH_HEIGHT = 8
    static let BYTES_PER_GLYPH = 8

    // Double-size glyph dimensions
    static let DOUBLE_GLYPH_WIDTH = 14
    static let DOUBLE_GLYPH_HEIGHT = 16
    static let DOUBLE_BYTES_PER_GLYPH = 32

    // Grid layout
    static let GRID_COLUMNS = 16

    /// Font type based on file size
    enum FontType {
        case standard96     // 768 bytes, chars $20-$7F
        case standard128    // 1024 bytes, chars $00-$7F
        case double96       // 3072 bytes, chars $20-$7F at 14x16
        case unknown
    }

    /// Parsed font data
    struct HiResFont {
        let type: FontType
        let glyphCount: Int
        let firstChar: UInt8
        let glyphWidth: Int
        let glyphHeight: Int
        let glyphs: [[UInt8]]  // Array of glyph data (8 or 32 bytes each)
    }

    /// Detect font type from file size
    static func detectFontType(_ data: Data) -> FontType {
        switch data.count {
        case 768:
            return .standard96
        case 1024:
            return .standard128
        case 3072:
            return .double96
        default:
            return .unknown
        }
    }

    /// Check if data looks like a valid Hi-Res font
    static func isHiResFont(_ data: Data) -> Bool {
        let type = detectFontType(data)
        return type != .unknown
    }

    /// Decode font file into structured data
    static func decode(_ data: Data) -> HiResFont? {
        let type = detectFontType(data)

        switch type {
        case .standard96:
            return decodeStandard(data, glyphCount: 96, firstChar: 0x20)
        case .standard128:
            return decodeStandard(data, glyphCount: 128, firstChar: 0x00)
        case .double96:
            return decodeDouble(data)
        case .unknown:
            return nil
        }
    }

    /// Decode standard 7x8 font
    private static func decodeStandard(_ data: Data, glyphCount: Int, firstChar: UInt8) -> HiResFont {
        var glyphs: [[UInt8]] = []

        for i in 0..<glyphCount {
            let offset = i * BYTES_PER_GLYPH
            if offset + BYTES_PER_GLYPH <= data.count {
                let glyphData = Array(data[offset..<(offset + BYTES_PER_GLYPH)])
                glyphs.append(glyphData)
            }
        }

        return HiResFont(
            type: glyphCount == 96 ? .standard96 : .standard128,
            glyphCount: glyphCount,
            firstChar: firstChar,
            glyphWidth: GLYPH_WIDTH,
            glyphHeight: GLYPH_HEIGHT,
            glyphs: glyphs
        )
    }

    /// Decode double-size 14x16 font
    private static func decodeDouble(_ data: Data) -> HiResFont {
        var glyphs: [[UInt8]] = []

        for i in 0..<96 {
            let offset = i * DOUBLE_BYTES_PER_GLYPH
            if offset + DOUBLE_BYTES_PER_GLYPH <= data.count {
                let glyphData = Array(data[offset..<(offset + DOUBLE_BYTES_PER_GLYPH)])
                glyphs.append(glyphData)
            }
        }

        return HiResFont(
            type: .double96,
            glyphCount: 96,
            firstChar: 0x20,
            glyphWidth: DOUBLE_GLYPH_WIDTH,
            glyphHeight: DOUBLE_GLYPH_HEIGHT,
            glyphs: glyphs
        )
    }

    /// Render a single glyph to a CGImage
    static func renderGlyph(_ glyphData: [UInt8], width: Int, height: Int, scale: Int = 2) -> CGImage? {
        let scaledWidth = width * scale
        let scaledHeight = height * scale

        var pixels = [UInt8](repeating: 255, count: scaledWidth * scaledHeight * 4) // RGBA white background

        for row in 0..<height {
            for col in 0..<width {
                let byteIndex: Int
                let bitIndex: Int

                if width == 14 {
                    // Double-size: 2 bytes per row
                    byteIndex = row * 2 + (col / 7)
                    bitIndex = col % 7
                } else {
                    // Standard: 1 byte per row
                    byteIndex = row
                    bitIndex = col
                }

                guard byteIndex < glyphData.count else { continue }

                // LSB is leftmost pixel (bit 0 = leftmost)
                let byte = glyphData[byteIndex] & 0x7F  // Mask off high bit
                let isSet = (byte & (1 << bitIndex)) != 0

                if isSet {
                    // Draw scaled pixel (black)
                    for sy in 0..<scale {
                        for sx in 0..<scale {
                            let px = col * scale + sx
                            let py = row * scale + sy
                            let pixelOffset = (py * scaledWidth + px) * 4
                            pixels[pixelOffset] = 0      // R
                            pixels[pixelOffset + 1] = 0  // G
                            pixels[pixelOffset + 2] = 0  // B
                            pixels[pixelOffset + 3] = 255 // A
                        }
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: scaledWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        return context.makeImage()
    }

    /// Render the entire font grid as a CGImage
    static func renderFontGrid(_ font: HiResFont, scale: Int = 2, showGrid: Bool = true) -> CGImage? {
        let columns = GRID_COLUMNS
        let rows = (font.glyphCount + columns - 1) / columns

        let cellWidth = font.glyphWidth * scale + (showGrid ? 1 : 0)
        let cellHeight = font.glyphHeight * scale + (showGrid ? 1 : 0)

        let totalWidth = columns * cellWidth + (showGrid ? 1 : 0)
        let totalHeight = rows * cellHeight + (showGrid ? 1 : 0)

        var pixels = [UInt8](repeating: 255, count: totalWidth * totalHeight * 4)

        // Draw grid lines if enabled
        if showGrid {
            let gridColor: UInt8 = 200  // Light gray

            // Vertical lines
            for col in 0...columns {
                let x = col * cellWidth
                for y in 0..<totalHeight {
                    let offset = (y * totalWidth + x) * 4
                    pixels[offset] = gridColor
                    pixels[offset + 1] = gridColor
                    pixels[offset + 2] = gridColor
                    pixels[offset + 3] = 255
                }
            }

            // Horizontal lines
            for row in 0...rows {
                let y = row * cellHeight
                for x in 0..<totalWidth {
                    let offset = (y * totalWidth + x) * 4
                    pixels[offset] = gridColor
                    pixels[offset + 1] = gridColor
                    pixels[offset + 2] = gridColor
                    pixels[offset + 3] = 255
                }
            }
        }

        // Draw each glyph
        for (index, glyphData) in font.glyphs.enumerated() {
            let col = index % columns
            let row = index / columns

            let startX = col * cellWidth + (showGrid ? 1 : 0)
            let startY = row * cellHeight + (showGrid ? 1 : 0)

            for glyphRow in 0..<font.glyphHeight {
                for glyphCol in 0..<font.glyphWidth {
                    let byteIndex: Int
                    let bitIndex: Int

                    if font.glyphWidth == 14 {
                        byteIndex = glyphRow * 2 + (glyphCol / 7)
                        bitIndex = glyphCol % 7
                    } else {
                        byteIndex = glyphRow
                        bitIndex = glyphCol
                    }

                    guard byteIndex < glyphData.count else { continue }

                    let byte = glyphData[byteIndex] & 0x7F
                    let isSet = (byte & (1 << bitIndex)) != 0

                    if isSet {
                        for sy in 0..<scale {
                            for sx in 0..<scale {
                                let px = startX + glyphCol * scale + sx
                                let py = startY + glyphRow * scale + sy
                                let pixelOffset = (py * totalWidth + px) * 4
                                pixels[pixelOffset] = 0
                                pixels[pixelOffset + 1] = 0
                                pixels[pixelOffset + 2] = 0
                                pixels[pixelOffset + 3] = 255
                            }
                        }
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: totalWidth,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: totalWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        return context.makeImage()
    }

    /// Render sample text using the font
    static func renderText(_ text: String, font: HiResFont, scale: Int = 2) -> CGImage? {
        let chars = Array(text.utf8)
        guard !chars.isEmpty else { return nil }

        let width = chars.count * font.glyphWidth * scale
        let height = font.glyphHeight * scale

        var pixels = [UInt8](repeating: 255, count: width * height * 4)

        for (charIndex, charCode) in chars.enumerated() {
            let glyphIndex = Int(charCode) - Int(font.firstChar)
            guard glyphIndex >= 0 && glyphIndex < font.glyphs.count else { continue }

            let glyphData = font.glyphs[glyphIndex]
            let startX = charIndex * font.glyphWidth * scale

            for glyphRow in 0..<font.glyphHeight {
                for glyphCol in 0..<font.glyphWidth {
                    let byteIndex: Int
                    let bitIndex: Int

                    if font.glyphWidth == 14 {
                        byteIndex = glyphRow * 2 + (glyphCol / 7)
                        bitIndex = glyphCol % 7
                    } else {
                        byteIndex = glyphRow
                        bitIndex = glyphCol
                    }

                    guard byteIndex < glyphData.count else { continue }

                    let byte = glyphData[byteIndex] & 0x7F
                    let isSet = (byte & (1 << bitIndex)) != 0

                    if isSet {
                        for sy in 0..<scale {
                            for sx in 0..<scale {
                                let px = startX + glyphCol * scale + sx
                                let py = glyphRow * scale + sy
                                let pixelOffset = (py * width + px) * 4
                                pixels[pixelOffset] = 0
                                pixels[pixelOffset + 1] = 0
                                pixels[pixelOffset + 2] = 0
                                pixels[pixelOffset + 3] = 255
                            }
                        }
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        return context.makeImage()
    }
}

// MARK: - Hi-Res Font View

struct HiResFontView: View {
    let entry: DiskCatalogEntry

    @State private var font: HiResFontDecoder.HiResFont?
    @State private var gridImage: NSImage?
    @State private var sampleImage: NSImage?
    @State private var scale: Int = 3
    @State private var showGrid: Bool = true
    @State private var sampleText: String = "HELLO WORLD!"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Font info header
                if let font = font {
                    fontInfoHeader(font)
                }

                // Controls
                controlsSection

                Divider()

                // Font grid
                if let gridImage = gridImage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Character Grid")
                            .font(.headline)

                        Image(nsImage: gridImage)
                            .interpolation(.none)
                    }
                }

                Divider()

                // Sample text
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sample Text")
                        .font(.headline)

                    HStack {
                        TextField("Enter text", text: $sampleText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                            .onChange(of: sampleText) { _, _ in
                                renderSample()
                            }
                    }

                    if let sampleImage = sampleImage {
                        Image(nsImage: sampleImage)
                            .interpolation(.none)
                            .padding(.top, 8)
                    }
                }
            }
            .padding()
        }
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            decodeFont()
        }
    }

    @ViewBuilder
    private func fontInfoHeader(_ font: HiResFontDecoder.HiResFont) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Font Type")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(fontTypeName(font.type))
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Glyph Size")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(font.glyphWidth)×\(font.glyphHeight) pixels")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Characters")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(font.glyphCount) ($\(String(format: "%02X", font.firstChar))-$\(String(format: "%02X", Int(font.firstChar) + font.glyphCount - 1)))")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("File Size")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(entry.data.count) bytes")
                    .font(.headline)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var controlsSection: some View {
        HStack(spacing: 16) {
            Text("Scale:")
            Picker("Scale", selection: $scale) {
                Text("1x").tag(1)
                Text("2x").tag(2)
                Text("3x").tag(3)
                Text("4x").tag(4)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .onChange(of: scale) { _, _ in
                renderGrid()
                renderSample()
            }

            Toggle("Show Grid", isOn: $showGrid)
                .onChange(of: showGrid) { _, _ in
                    renderGrid()
                }
        }
    }

    private func fontTypeName(_ type: HiResFontDecoder.FontType) -> String {
        switch type {
        case .standard96:
            return "Standard 96-char (768 bytes)"
        case .standard128:
            return "Standard 128-char (1024 bytes)"
        case .double96:
            return "Double-size 96-char (3072 bytes)"
        case .unknown:
            return "Unknown"
        }
    }

    private func decodeFont() {
        guard let decoded = HiResFontDecoder.decode(entry.data) else { return }
        font = decoded
        renderGrid()
        renderSample()
    }

    private func renderGrid() {
        guard let font = font else { return }
        if let cgImage = HiResFontDecoder.renderFontGrid(font, scale: scale, showGrid: showGrid) {
            gridImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    private func renderSample() {
        guard let font = font, !sampleText.isEmpty else {
            sampleImage = nil
            return
        }
        if let cgImage = HiResFontDecoder.renderText(sampleText, font: font, scale: scale) {
            sampleImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }
}

// MARK: - Preview

#Preview {
    // Create a simple test font (just a few characters)
    var fontData = Data(repeating: 0, count: 768)

    // Character 'A' at position 33 (0x41 - 0x20 = 0x21 = 33)
    // Simple 'A' pattern
    let aPattern: [UInt8] = [
        0b0001000,  // Row 0:    *
        0b0010100,  // Row 1:   * *
        0b0100010,  // Row 2:  *   *
        0b0111110,  // Row 3:  *****
        0b0100010,  // Row 4:  *   *
        0b0100010,  // Row 5:  *   *
        0b0100010,  // Row 6:  *   *
        0b0000000,  // Row 7:
    ]
    for (i, byte) in aPattern.enumerated() {
        fontData[33 * 8 + i] = byte
    }

    return HiResFontView(entry: DiskCatalogEntry(
        name: "TEST.FNT",
        fileType: 0x07,
        fileTypeString: "FNT",
        auxType: 0x0000,
        size: fontData.count,
        blocks: 2,
        loadAddress: nil,
        length: fontData.count,
        data: fontData,
        isImage: false,
        isDirectory: false,
        children: nil,
        modificationDate: "01-Jan-25",
        creationDate: "01-Jan-25"
    ))
}
