//
//  AppleIIgsFontDecoder.swift
//  ProBrowse
//
//  Decoder for Apple IIgs QuickDraw II bitmap fonts ($C8/FNT)
//

import Foundation
import CoreGraphics

// MARK: - Apple IIgs Font Structure

struct AppleIIgsFont {
    let fontType: UInt16
    let firstChar: Int
    let lastChar: Int
    let maxWidth: Int
    let fontHeight: Int
    let ascent: Int
    let descent: Int
    let leading: Int
    let rowWords: Int      // Words per row in the strike bitmap
    let strikeData: Data   // Raw bitmap data
    let locationTable: [Int]  // Pixel offsets for each character
    let widthTable: [Int]     // Width of each character

    var characterCount: Int {
        return lastChar - firstChar + 1
    }
}

// MARK: - Font Decoder

class AppleIIgsFontDecoder {

    /// Decode an Apple IIgs font file - tries multiple header formats
    static func decode(data: Data) -> AppleIIgsFont? {
        guard data.count >= 30 else { return nil }

        // Try different starting offsets for the font record
        // Apple IIgs fonts can have various headers before the actual font data:
        // - Raw font record (offset 0)
        // - NFNT resource: familyID(2) + style(2) + size(2) + version(2) = 8 bytes header
        // - Other variations with 2, 4, 6, etc byte headers
        let offsets = [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32]

        for startOffset in offsets {
            if let font = tryDecode(data: data, startOffset: startOffset) {
                return font
            }
        }

        // Try detecting Pascal string name header and skip it
        if let font = tryDecodeWithNameHeader(data: data) {
            return font
        }

        // Try NFNT-style format with explicit header parsing
        if let font = tryDecodeNFNT(data: data) {
            return font
        }

        // Try scanning for valid font signature
        if let font = scanForFont(data: data) {
            return font
        }

        return nil
    }

    /// Try to decode font that has a Pascal string name header
    private static func tryDecodeWithNameHeader(data: Data) -> AppleIIgsFont? {
        guard data.count >= 32 else { return nil }

        // Check if first byte looks like a Pascal string length (font family name)
        let nameLength = Int(data[0])

        // Font family names are typically 4-31 characters
        if nameLength >= 4 && nameLength <= 31 && nameLength + 30 < data.count {
            // Verify it looks like ASCII text
            var isAsciiName = true
            for i in 1...min(nameLength, data.count - 1) {
                let byte = data[i]
                // Allow printable ASCII and some extended chars
                if byte < 0x20 || byte > 0x7F {
                    // Allow high-ASCII for special chars but not control chars
                    if byte < 0x80 && byte != 0 {
                        isAsciiName = false
                        break
                    }
                }
            }

            if isAsciiName {
                // Try offsets after the name string
                // Font record might be aligned to word boundary
                let baseOffset = 1 + nameLength
                let alignedOffset = (baseOffset + 1) & ~1  // Word-align

                // Try various offsets after the name
                for additionalOffset in stride(from: 0, to: 64, by: 2) {
                    let offset = alignedOffset + additionalOffset
                    if let font = tryDecode(data: data, startOffset: offset) {
                        return font
                    }
                }
            }
        }

        return nil
    }

    /// Try to decode as NFNT resource format (with family/style/size header)
    private static func tryDecodeNFNT(data: Data) -> AppleIIgsFont? {
        guard data.count >= 38 else { return nil }

        // NFNT format might have: familyID(2), style(2), size(2), version(2)
        // Then the font record follows

        // Try to find where font data starts by looking for valid font record
        for headerSize in stride(from: 0, to: 64, by: 2) {
            guard headerSize + 26 <= data.count else { break }

            let offset = headerSize

            // Read what should be fontType
            let fontType = readWord(data, at: offset)

            // fontType is typically 0x0000 for bitmap fonts, 0x9000 for proportional
            // or various other values < 0xFFFF
            if fontType > 0x9FFF { continue }

            let firstChar = Int(readWord(data, at: offset + 2))
            let lastChar = Int(readWord(data, at: offset + 4))

            // Check for valid character range
            if firstChar > 255 || lastChar > 255 || lastChar <= firstChar { continue }

            let widMax = Int(readWord(data, at: offset + 6))
            if widMax == 0 || widMax > 127 { continue }

            // This looks promising - try full decode
            if let font = tryDecode(data: data, startOffset: headerSize) {
                return font
            }
        }

        return nil
    }

    /// Try to decode font starting at a specific offset
    private static func tryDecode(data: Data, startOffset: Int) -> AppleIIgsFont? {
        var offset = startOffset

        guard offset + 26 <= data.count else { return nil }

        // Read font record fields
        // Standard QuickDraw II Font Record layout:
        // fontType, firstChar, lastChar, widMax, kernMax, nDescent,
        // fRectWidth, fRectHeight, owTLoc, ascent, descent, leading, rowWords

        let fontType = readWord(data, at: offset)
        offset += 2

        let firstChar = Int(readWord(data, at: offset))
        offset += 2

        let lastChar = Int(readWord(data, at: offset))
        offset += 2

        // Validate character range
        guard firstChar <= 255 && lastChar <= 255 && lastChar >= firstChar else {
            return nil
        }
        guard lastChar - firstChar < 256 else { return nil }

        let widMax = Int(readWord(data, at: offset))
        offset += 2

        // Validate max width
        guard widMax > 0 && widMax < 128 else { return nil }

        _ = readWord(data, at: offset)  // kernMax - not used
        offset += 2

        _ = readWord(data, at: offset)  // nDescent - not used
        offset += 2

        let fRectWidth = Int(readWord(data, at: offset))
        offset += 2

        let fRectHeight = Int(readWord(data, at: offset))
        offset += 2

        // Validate font dimensions
        guard fRectWidth > 0 && fRectWidth < 2000 else { return nil }
        guard fRectHeight > 0 && fRectHeight < 128 else { return nil }

        // owTLoc - offset to width/offset table FROM this word
        _ = readWord(data, at: offset)  // owTLoc not directly used
        offset += 2

        let ascent = Int(readWord(data, at: offset))
        offset += 2

        let descent = Int(readWord(data, at: offset))
        offset += 2

        let leading = Int(readWord(data, at: offset))
        offset += 2

        let rowWords = Int(readWord(data, at: offset))
        offset += 2

        // Validate rowWords
        guard rowWords > 0 && rowWords < 500 else { return nil }

        // Validate ascent/descent
        guard ascent >= 0 && ascent <= fRectHeight else { return nil }
        guard descent >= 0 && descent <= fRectHeight else { return nil }

        // Calculate sizes
        let strikeSize = rowWords * 2 * fRectHeight
        let numChars = lastChar - firstChar + 2  // +2 for missing char entry

        // Read strike bitmap
        guard offset + strikeSize <= data.count else {
            return nil
        }
        let strikeData = data.subdata(in: offset..<(offset + strikeSize))
        offset += strikeSize

        // Read location table (numChars + 1 entries)
        var locationTable: [Int] = []
        for _ in 0..<(numChars + 1) {
            guard offset + 2 <= data.count else { break }
            locationTable.append(Int(readWord(data, at: offset)))
            offset += 2
        }

        // Validate location table
        guard locationTable.count >= numChars else { return nil }
        for loc in locationTable {
            if loc > rowWords * 16 + 16 {  // Allow some slack
                return nil
            }
        }

        // Read width/offset table
        var widthTable: [Int] = []
        for _ in 0..<numChars {
            guard offset + 2 <= data.count else { break }
            let entry = readWord(data, at: offset)
            // Low byte is width, high byte is offset adjustment
            let width = Int(entry & 0xFF)
            widthTable.append(width > 0 ? width : widMax)
            offset += 2
        }

        // Fill in missing widths if needed
        while widthTable.count < numChars {
            widthTable.append(widMax)
        }

        return AppleIIgsFont(
            fontType: fontType,
            firstChar: firstChar,
            lastChar: lastChar,
            maxWidth: widMax,
            fontHeight: fRectHeight,
            ascent: ascent,
            descent: descent,
            leading: leading,
            rowWords: rowWords,
            strikeData: strikeData,
            locationTable: locationTable,
            widthTable: widthTable
        )
    }

    /// Scan data for a valid font structure by looking for reasonable values
    private static func scanForFont(data: Data) -> AppleIIgsFont? {
        // Scan through data looking for valid font headers
        // Try every 2-byte offset up to 1024 bytes into the file (extended range for fonts with large headers)
        let maxScanOffset = min(data.count - 30, 1024)

        for i in stride(from: 0, to: maxScanOffset, by: 2) {
            // Look for reasonable firstChar/lastChar values
            let possibleFirstChar = Int(readWord(data, at: i + 2))
            let possibleLastChar = Int(readWord(data, at: i + 4))

            // Common font ranges: 0-127, 32-127, 0-255, or subset
            if possibleFirstChar <= 255 && possibleLastChar <= 255 && possibleLastChar > possibleFirstChar {
                // Also check widMax is reasonable (allow up to 127 like in tryDecode)
                let possibleWidMax = Int(readWord(data, at: i + 6))
                if possibleWidMax > 0 && possibleWidMax < 128 {
                    if let font = tryDecode(data: data, startOffset: i) {
                        return font
                    }
                }
            }
        }

        // Also try odd offsets in case of unusual alignment
        for i in stride(from: 1, to: min(maxScanOffset, 256), by: 2) {
            let possibleFirstChar = Int(readWord(data, at: i + 2))
            let possibleLastChar = Int(readWord(data, at: i + 4))

            if possibleFirstChar <= 255 && possibleLastChar <= 255 && possibleLastChar > possibleFirstChar {
                let possibleWidMax = Int(readWord(data, at: i + 6))
                if possibleWidMax > 0 && possibleWidMax < 128 {
                    if let font = tryDecode(data: data, startOffset: i) {
                        return font
                    }
                }
            }
        }

        return nil
    }

    /// Render a single character from the font
    static func renderCharacter(font: AppleIIgsFont, charCode: Int) -> CGImage? {
        let charIndex = charCode - font.firstChar
        guard charIndex >= 0 && charIndex < font.locationTable.count - 1 else {
            return nil
        }

        let startX = font.locationTable[charIndex]
        let endX = font.locationTable[charIndex + 1]
        let charWidth = endX - startX

        guard charWidth > 0 && charWidth <= font.maxWidth * 2 else {
            return nil
        }

        let height = font.fontHeight
        let rowBytes = font.rowWords * 2

        // Create bitmap for character
        var pixels = [UInt8](repeating: 0, count: charWidth * height * 4)

        for y in 0..<height {
            for x in 0..<charWidth {
                let strikeX = startX + x
                let byteOffset = y * rowBytes + (strikeX / 8)
                let bitOffset = 7 - (strikeX % 8)

                guard byteOffset < font.strikeData.count else { continue }

                let bit = (font.strikeData[byteOffset] >> bitOffset) & 1
                let pixelIndex = (y * charWidth + x) * 4

                if bit == 1 {
                    pixels[pixelIndex] = 0       // R
                    pixels[pixelIndex + 1] = 0   // G
                    pixels[pixelIndex + 2] = 0   // B
                    pixels[pixelIndex + 3] = 255 // A
                } else {
                    pixels[pixelIndex] = 255
                    pixels[pixelIndex + 1] = 255
                    pixels[pixelIndex + 2] = 255
                    pixels[pixelIndex + 3] = 0
                }
            }
        }

        return ImageHelpers.createCGImage(from: pixels, width: charWidth, height: height)
    }

    /// Render text string using the font
    static func renderText(font: AppleIIgsFont, text: String, scale: Int = 1) -> CGImage? {
        // Calculate total width
        var totalWidth = 0
        for char in text {
            let charCode = Int(char.asciiValue ?? 0)
            let charIndex = charCode - font.firstChar
            if charIndex >= 0 && charIndex < font.widthTable.count {
                totalWidth += font.widthTable[charIndex]
            } else {
                totalWidth += font.maxWidth
            }
        }

        guard totalWidth > 0 else { return nil }

        let height = font.fontHeight
        let rowBytes = font.rowWords * 2

        // Create bitmap for text
        var pixels = [UInt8](repeating: 255, count: totalWidth * height * 4)
        // Set all alpha to 255 (opaque white background)
        for i in stride(from: 3, to: pixels.count, by: 4) {
            pixels[i] = 255
        }

        var currentX = 0

        for char in text {
            let charCode = Int(char.asciiValue ?? 0)
            let charIndex = charCode - font.firstChar

            if charIndex >= 0 && charIndex < font.locationTable.count - 1 {
                let startX = font.locationTable[charIndex]
                let endX = font.locationTable[charIndex + 1]
                // A malformed location table can run backwards
                let charWidth = max(0, endX - startX)

                // Render character
                for y in 0..<height {
                    for x in 0..<charWidth {
                        let strikeX = startX + x
                        let byteOffset = y * rowBytes + (strikeX / 8)
                        let bitOffset = 7 - (strikeX % 8)

                        guard byteOffset < font.strikeData.count else { continue }

                        let bit = (font.strikeData[byteOffset] >> bitOffset) & 1
                        let destX = currentX + x
                        guard destX < totalWidth else { continue }

                        let pixelIndex = (y * totalWidth + destX) * 4

                        if bit == 1 {
                            pixels[pixelIndex] = 0       // R
                            pixels[pixelIndex + 1] = 0   // G
                            pixels[pixelIndex + 2] = 0   // B
                        }
                    }
                }

                currentX += charIndex < font.widthTable.count ? font.widthTable[charIndex] : charWidth
            } else {
                // Unknown character - advance by max width
                currentX += font.maxWidth
            }
        }

        return ImageHelpers.createCGImage(from: pixels, width: totalWidth, height: height)
    }

    /// Render a character grid showing all characters in the font
    static func renderCharacterGrid(font: AppleIIgsFont, columns: Int = 16, cellPadding: Int = 2) -> CGImage? {
        let charCount = font.lastChar - font.firstChar + 1
        let rows = (charCount + columns - 1) / columns

        let cellWidth = font.maxWidth + cellPadding * 2
        let cellHeight = font.fontHeight + cellPadding * 2

        let totalWidth = cellWidth * columns
        let totalHeight = cellHeight * rows

        guard totalWidth > 0 && totalHeight > 0 else { return nil }

        let rowBytes = font.rowWords * 2

        // Create bitmap with light gray background
        var pixels = [UInt8](repeating: 0, count: totalWidth * totalHeight * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 240     // R - light gray
            pixels[i + 1] = 240 // G
            pixels[i + 2] = 240 // B
            pixels[i + 3] = 255 // A
        }

        // Draw each character
        for charOffset in 0..<charCount {
            let charIndex = charOffset

            let gridCol = charOffset % columns
            let gridRow = charOffset / columns

            let cellX = gridCol * cellWidth
            let cellY = gridRow * cellHeight

            // Draw cell background (white)
            for y in (cellY + 1)..<(cellY + cellHeight - 1) {
                for x in (cellX + 1)..<(cellX + cellWidth - 1) {
                    let pixelIndex = (y * totalWidth + x) * 4
                    guard pixelIndex + 3 < pixels.count else { continue }
                    pixels[pixelIndex] = 255
                    pixels[pixelIndex + 1] = 255
                    pixels[pixelIndex + 2] = 255
                }
            }

            guard charIndex < font.locationTable.count - 1 else { continue }

            let startX = font.locationTable[charIndex]
            let endX = font.locationTable[charIndex + 1]
            let charWidth = endX - startX

            guard charWidth > 0 && charWidth <= font.maxWidth * 2 else { continue }

            // Center character in cell
            let offsetX = cellX + cellPadding + max(0, (font.maxWidth - charWidth) / 2)
            let offsetY = cellY + cellPadding

            // Render character
            for y in 0..<font.fontHeight {
                for x in 0..<charWidth {
                    let strikeX = startX + x
                    let byteOffset = y * rowBytes + (strikeX / 8)
                    let bitOffset = 7 - (strikeX % 8)

                    guard byteOffset < font.strikeData.count else { continue }

                    let bit = (font.strikeData[byteOffset] >> bitOffset) & 1

                    if bit == 1 {
                        let destX = offsetX + x
                        let destY = offsetY + y
                        guard destX >= 0 && destX < totalWidth && destY >= 0 && destY < totalHeight else { continue }

                        let pixelIndex = (destY * totalWidth + destX) * 4
                        guard pixelIndex + 3 < pixels.count else { continue }

                        pixels[pixelIndex] = 0       // R
                        pixels[pixelIndex + 1] = 0   // G
                        pixels[pixelIndex + 2] = 0   // B
                    }
                }
            }
        }

        return ImageHelpers.createCGImage(from: pixels, width: totalWidth, height: totalHeight)
    }

    // MARK: - Helpers

    private static func readWord(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        // Little-endian
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}
