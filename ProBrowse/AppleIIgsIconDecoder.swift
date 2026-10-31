//
//  AppleIIgsIconDecoder.swift
//  ProBrowse
//
//  Decoder for Apple IIgs icon files ($CA/ICN)
//

import Foundation
import CoreGraphics

// MARK: - Apple IIgs Icon Structures

/// Single icon image (small or large)
struct AppleIIgsIconImage {
    let width: Int
    let height: Int
    let pixelData: Data      // 4-bit per pixel data
    let maskData: Data       // 1-bit per pixel mask
    let bytesPerRow: Int     // Bytes per row in pixel data

    init(width: Int, height: Int, pixelData: Data, maskData: Data, actualBytesPerRow: Int? = nil) {
        self.width = width
        self.height = height
        self.pixelData = pixelData
        self.maskData = maskData

        // Use actual bytes per row if provided, otherwise calculate from Apple formula
        if let actual = actualBytesPerRow, actual > 0 {
            self.bytesPerRow = actual
        } else {
            // Apple IIgs formula for 4bpp row width: 1 + (width - 1) / 2
            self.bytesPerRow = 1 + (width - 1) / 2
        }
    }
}

/// An icon entry with path and both icon sizes
struct AppleIIgsIconEntry {
    let pathname: String           // File path pattern (e.g., "*/DOS3.3/DOS3.3.LAUNCHER")
    let largeIcon: AppleIIgsIconImage?
    let smallIcon: AppleIIgsIconImage?
}

/// Decoded icon file containing multiple icon entries
struct AppleIIgsIconFile {
    let entries: [AppleIIgsIconEntry]
}

// MARK: - Finder Icon Palette

/// The Finder runs in 640 mode, where each 4-bit icon pixel becomes two dithered screen pixels
/// from the standard 640 palette. These are the blended colors (as CiderPress2 uses them).
let appleIIgsPalette: [(r: UInt8, g: UInt8, b: UInt8)] = [
    (0x00, 0x00, 0x00),  // 0: Black + Black
    (0x00, 0x00, 0x7F),  // 1: Black + Blue
    (0x7F, 0x7F, 0x00),  // 2: Black + Yellow
    (0x6F, 0x6F, 0x6F),  // 3: Black + White
    (0x7F, 0x00, 0x00),  // 4: Red + Black
    (0x7F, 0x00, 0x7F),  // 5: Red + Blue
    (0xFF, 0x7F, 0x00),  // 6: Red + Yellow
    (0xFF, 0x7F, 0x7F),  // 7: Red + White
    (0x00, 0x7F, 0x00),  // 8: Green + Black
    (0x00, 0x7F, 0x7F),  // 9: Green + Blue
    (0x7F, 0xFF, 0x00),  // 10: Green + Yellow
    (0x7F, 0xFF, 0x7F),  // 11: Green + White
    (0x8F, 0x8F, 0x8F),  // 12: White + Black
    (0x7F, 0x7F, 0xFF),  // 13: White + Blue
    (0xFF, 0xFF, 0x7F),  // 14: White + Yellow
    (0xFF, 0xFF, 0xFF),  // 15: White + White
]

// MARK: - Icon Decoder

class AppleIIgsIconDecoder {

    /// Decode an Apple IIgs icon file using the documented Finder icon file format
    static func decode(data: Data) -> AppleIIgsIconFile? {
        guard data.count >= 50 else { return nil }

        var entries: [AppleIIgsIconEntry] = []

        // Primary approach: Parse using documented Finder icon file format
        // File header is 26 bytes (0x1A), icon records start at offset 0x1A
        if let structuredEntries = parseFinderIconFile(data: data) {
            entries.append(contentsOf: structuredEntries)
        }

        // Fallback: Scan for 0x8000 icon type markers (only if structured parse found nothing)
        if entries.isEmpty {
            if let markerEntries = scanForIconTypeMarkers(data: data) {
                entries.append(contentsOf: markerEntries)
            }
        }

        // Debug: If we still have no entries, try with relaxed validation
        if entries.isEmpty {
            if let relaxedEntries = parseFinderIconFileRelaxed(data: data) {
                entries.append(contentsOf: relaxedEntries)
            }
        }

        guard !entries.isEmpty else { return nil }
        return AppleIIgsIconFile(entries: entries)
    }

    /// Relaxed parsing - try different offsets and less strict validation
    private static func parseFinderIconFileRelaxed(data: Data) -> [AppleIIgsIconEntry]? {
        // Try parsing with the icon at different base offsets
        // Some files might have extra header data
        for baseOffset in stride(from: 0x1A, through: min(0x60, data.count - 0x60), by: 2) {
            if let entries = tryParseIconsAtOffset(data: data, baseOffset: baseOffset), !entries.isEmpty {
                return entries
            }
        }
        return nil
    }

    /// Try to parse icons starting at a specific offset
    private static func tryParseIconsAtOffset(data: Data, baseOffset: Int) -> [AppleIIgsIconEntry]? {
        var entries: [AppleIIgsIconEntry] = []
        var recordOffset = baseOffset

        while recordOffset + 0x58 < data.count {
            let recordLen = Int(readWord(data, at: recordOffset))
            if recordLen == 0 { break }
            if recordLen < 0x58 || recordLen > 0x4000 { break }
            if recordOffset + recordLen > data.count { break }

            // Try to find icon at the expected offset within the record
            let largeIconOffset = recordOffset + 0x56
            if let (icon, _) = parseIconImage(data: data, offset: largeIconOffset) {
                let pathname = "Icon \(entries.count + 1)"
                entries.append(AppleIIgsIconEntry(pathname: pathname, largeIcon: icon, smallIcon: nil))
            }

            recordOffset += recordLen
        }

        return entries.isEmpty ? nil : entries
    }

    /// Parse using the documented Finder icon file format from Apple File Type Note $CA
    /// Structure: 26-byte header, then variable-length icon records
    private static func parseFinderIconFile(data: Data) -> [AppleIIgsIconEntry]? {
        guard data.count >= 0x1A + 0x58 else { return nil }  // Header + minimum record

        // Verify file ID at offset 0x04 should be 0x0001
        // Note: Try parsing even if ID doesn't match - some files may not be strict
        let fileID = readWord(data, at: 0x04)
        let isStandardFormat = (fileID == 0x0001)

        // Check first record length to see if structure looks valid
        // Minimum record size: 0x56 (fixed fields) + 8 (icon header) + 16 (minimal icon data) = ~0x6E
        let firstRecordLen = Int(readWord(data, at: 0x1A))
        if firstRecordLen == 0 || firstRecordLen < 0x60 || firstRecordLen > 0x4000 {
            // Record length looks invalid, probably not this format
            if !isStandardFormat { return nil }
        }

        var entries: [AppleIIgsIconEntry] = []
        var recordOffset = 0x1A  // Icon records start after 26-byte header

        while recordOffset + 0x60 < data.count {  // Need at least minimal record size
            // Read record length (iDataLen) - 0 marks end of records
            let recordLen = Int(readWord(data, at: recordOffset))
            if recordLen == 0 { break }
            if recordLen < 0x60 || recordLen > 0x4000 { break }  // Reasonable size range
            if recordOffset + recordLen > data.count { break }

            // iDataBoss: 64-byte application pathname at offset +2 (Pascal string in 64-byte field)
            let bossPathData = data.subdata(in: (recordOffset + 2)..<(recordOffset + 2 + 64))
            let bossPath = extractPascalStringFromField(bossPathData)

            // iDataName: 16-byte filename filter at offset +0x42 (Pascal string in 16-byte field)
            let nameFilterData = data.subdata(in: (recordOffset + 0x42)..<(recordOffset + 0x42 + 16))
            let nameFilter = extractPascalStringFromField(nameFilterData)

            // Combine for display (use nameFilter if available, else bossPath)
            let pathname = nameFilter.isEmpty ? (bossPath.isEmpty ? "Icon \(entries.count + 1)" : bossPath) : nameFilter

            // iDataBig: Large icon starts at offset +0x56 (decimal 86)
            let largeIconOffset = recordOffset + 0x56
            var largeIcon: AppleIIgsIconImage?
            var smallIcon: AppleIIgsIconImage?
            var nextOffset = largeIconOffset

            if let (icon, endOffset) = parseIconImage(data: data, offset: largeIconOffset) {
                largeIcon = icon
                nextOffset = endOffset

                // iDataSmall: Small icon follows immediately after large icon
                if nextOffset + 8 < recordOffset + recordLen {
                    if let (small, _) = parseIconImage(data: data, offset: nextOffset) {
                        smallIcon = small
                    }
                }
            }

            if largeIcon != nil || smallIcon != nil {
                entries.append(AppleIIgsIconEntry(pathname: pathname, largeIcon: largeIcon, smallIcon: smallIcon))
            }

            recordOffset += recordLen
        }

        return entries.isEmpty ? nil : entries
    }

    /// Extract a Pascal-style string from a fixed-size field
    /// Pascal strings have a length byte followed by that many characters
    private static func extractPascalStringFromField(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        // First byte is the length
        let length = Int(data[0])

        // Validate length - must be reasonable and fit in field
        if length > 0 && length < data.count {
            // Extract the string bytes
            let stringData = data.subdata(in: 1..<(1 + length))

            // Verify all bytes are printable ASCII
            var valid = true
            for byte in stringData {
                if byte < 0x20 || byte > 0x7E {
                    valid = false
                    break
                }
            }

            if valid, let str = String(data: stringData, encoding: .ascii), !str.isEmpty {
                return str
            }
        }

        // Fallback: scan for longest printable sequence (handles malformed files)
        return extractPrintableString(from: data)
    }

    /// Extract the longest printable ASCII string from data
    private static func extractPrintableString(from data: Data) -> String {
        var bestStart = 0
        var bestLen = 0
        var currentStart = -1

        for i in 0..<data.count {
            let byte = data[i]
            if byte >= 0x20 && byte <= 0x7E {
                if currentStart < 0 {
                    currentStart = i
                }
                let currentLen = i - currentStart + 1
                if currentLen > bestLen {
                    bestStart = currentStart
                    bestLen = currentLen
                }
            } else {
                currentStart = -1
            }
        }

        if bestLen >= 2 {
            let stringData = data.subdata(in: bestStart..<(bestStart + bestLen))
            return String(data: stringData, encoding: .ascii) ?? ""
        }

        return ""
    }

    /// Parse a single icon image (rIcon format from QuickDraw II) at the given offset
    /// rIcon format: iconType(2), iconSize(2), iconHeight(2), iconWidth(2), pixelData, maskData
    /// Both pixel data AND mask are stored as 4bpp with the same iconSize bytes each
    private static func parseIconImage(data: Data, offset: Int) -> (AppleIIgsIconImage, Int)? {
        guard offset + 8 <= data.count else { return nil }

        let _ = readWord(data, at: offset)  // iconType - not used for format detection
        let iconSize = Int(readWord(data, at: offset + 2))
        let iconHeight = Int(readWord(data, at: offset + 4))
        let iconWidth = Int(readWord(data, at: offset + 6))

        // Validate dimensions - must be reasonable for Apple IIgs icons
        guard iconWidth >= 4 && iconWidth <= 128 &&
              iconHeight >= 4 && iconHeight <= 128 else { return nil }

        // Validate iconSize is reasonable
        guard iconSize > 0 && iconSize < 32767 else { return nil }
        guard iconHeight > 0 else { return nil }

        let dataOffset = offset + 8

        // Both pixel data and mask are the same size (iconSize bytes each)
        // This matches CiderPress2's implementation
        // Check we have enough data for both pixel and mask (iconSize * 2)
        guard dataOffset + iconSize * 2 <= data.count else { return nil }

        let pixelData = data.subdata(in: dataOffset..<(dataOffset + iconSize))
        let maskOffset = dataOffset + iconSize
        let maskData = data.subdata(in: maskOffset..<(maskOffset + iconSize))

        // Calculate bytes per row from iconSize
        let actualBytesPerRow = iconSize / iconHeight

        let icon = AppleIIgsIconImage(width: iconWidth, height: iconHeight, pixelData: pixelData, maskData: maskData,
                                       actualBytesPerRow: actualBytesPerRow)

        // Return the end offset for finding the next icon (pixel + mask = iconSize * 2)
        let endOffset = maskOffset + iconSize
        return (icon, endOffset)
    }

    /// Fallback: Scan for icon entries by looking for 0x8000 color icon type markers
    private static func scanForIconTypeMarkers(data: Data) -> [AppleIIgsIconEntry]? {
        var entries: [AppleIIgsIconEntry] = []
        var foundOffsets = Set<Int>()

        var offset = 0x20  // Start after minimal header
        while offset < data.count - 20 {
            if foundOffsets.contains(where: { abs($0 - offset) < 50 }) {
                offset += 2
                continue
            }

            let typeWord = readWord(data, at: offset)
            if typeWord == 0x8000 || typeWord == 0x0000 {
                // Check if this looks like a valid icon header
                let sizeWord = Int(readWord(data, at: offset + 2))
                let heightWord = Int(readWord(data, at: offset + 4))
                let widthWord = Int(readWord(data, at: offset + 6))

                if widthWord >= 8 && widthWord <= 48 &&
                   heightWord >= 8 && heightWord <= 48 &&
                   sizeWord > 20 && sizeWord < 5000 {

                    if let (icon, nextPos) = parseIconImage(data: data, offset: offset) {
                        var smallIcon: AppleIIgsIconImage?
                        if let (small, _) = parseIconImage(data: data, offset: nextPos) {
                            if small.width <= 16 && small.height <= 16 {
                                smallIcon = small
                            }
                        }

                        let pathname = findPathnameBeforeOffset(in: data, iconOffset: offset) ?? "Icon \(entries.count + 1)"
                        entries.append(AppleIIgsIconEntry(pathname: pathname, largeIcon: icon, smallIcon: smallIcon))
                        foundOffsets.insert(offset)
                        offset = nextPos + 20
                        continue
                    }
                }
            }

            offset += 2
        }

        return entries.isEmpty ? nil : entries
    }

    /// Try to find a pathname before the given icon offset
    private static func findPathnameBeforeOffset(in data: Data, iconOffset: Int) -> String? {
        let searchStart = max(0, iconOffset - 150)

        // Try to find Pascal string (length-prefixed)
        for i in stride(from: iconOffset - 2, through: searchStart, by: -1) {
            let len = Int(data[i])
            if len >= 3 && len <= 64 && i + len + 1 <= iconOffset {
                var valid = true
                var hasPathChar = false
                for j in 0..<len {
                    let byte = data[i + 1 + j]
                    if byte < 0x20 || byte > 0x7E {
                        valid = false
                        break
                    }
                    if byte == 0x2F || byte == 0x2E || byte == 0x2A { // '/', '.', '*'
                        hasPathChar = true
                    }
                }
                if valid && hasPathChar {
                    let pathData = data.subdata(in: (i + 1)..<(i + 1 + len))
                    if let path = String(data: pathData, encoding: .ascii) {
                        return path
                    }
                }
            }
        }

        // Try to find C-string (null-terminated) - common in icon files
        // Look for a path starting with '/' or containing path characters
        for i in stride(from: searchStart, to: iconOffset - 5, by: 1) {
            let byte = data[i]
            // Look for start of path ('/' or alpha)
            if byte == 0x2F || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
                // Scan forward to find null terminator or end
                var endPos = i
                var hasPathChar = false
                while endPos < min(iconOffset, i + 80) && data[endPos] != 0x00 {
                    let c = data[endPos]
                    if c < 0x20 || c > 0x7E {
                        break
                    }
                    if c == 0x2F || c == 0x2E { // '/' or '.'
                        hasPathChar = true
                    }
                    endPos += 1
                }

                let pathLen = endPos - i
                if pathLen >= 4 && pathLen <= 64 && hasPathChar {
                    let pathData = data.subdata(in: i..<endPos)
                    if let path = String(data: pathData, encoding: .ascii) {
                        // Verify it looks like a valid path
                        if path.contains("/") || path.contains(".") {
                            return path
                        }
                    }
                }
            }
        }

        return nil
    }

    private static func readWord(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    // MARK: - Rendering

    /// Render an icon to a CGImage
    static func renderIcon(_ icon: AppleIIgsIconImage, scale: Int = 1) -> CGImage? {
        let width = icon.width
        let height = icon.height
        let scaledWidth = width * scale
        let scaledHeight = height * scale

        // Use the actual bytes per row from the icon data
        let bytesPerRow = icon.bytesPerRow

        // Create pixel data array
        var pixels = [UInt8](repeating: 0, count: scaledWidth * scaledHeight * 4)

        for y in 0..<height {
            for x in 0..<width {
                // 4 bits per pixel (2 pixels per byte) for both pixels AND mask
                let byteIndex = y * bytesPerRow + x / 2
                guard byteIndex < icon.pixelData.count else { continue }

                let pixelByte = icon.pixelData[byteIndex]
                let colorIndex: UInt8
                // Apple IIgs 320 mode: high nibble = left pixel, low nibble = right pixel
                if x % 2 == 0 {
                    colorIndex = (pixelByte >> 4) & 0x0F   // High nibble for even pixels (leftmost)
                } else {
                    colorIndex = pixelByte & 0x0F          // Low nibble for odd pixels (rightmost)
                }

                // Read mask value - ALSO 4bpp format (same as pixel data)
                // Mask value 0 = transparent, non-zero = opaque
                var isTransparent = false
                if byteIndex < icon.maskData.count {
                    let maskByte = icon.maskData[byteIndex]
                    let maskValue: UInt8
                    if x % 2 == 0 {
                        maskValue = (maskByte >> 4) & 0x0F
                    } else {
                        maskValue = maskByte & 0x0F
                    }
                    isTransparent = (maskValue == 0)
                }

                // Get color from palette
                let color = appleIIgsPalette[Int(colorIndex)]
                let alpha: UInt8 = isTransparent ? 0 : 255

                // Write scaled pixels
                for sy in 0..<scale {
                    for sx in 0..<scale {
                        let destX = x * scale + sx
                        let destY = y * scale + sy
                        let destIndex = (destY * scaledWidth + destX) * 4

                        pixels[destIndex + 0] = color.r
                        pixels[destIndex + 1] = color.g
                        pixels[destIndex + 2] = color.b
                        pixels[destIndex + 3] = alpha
                    }
                }
            }
        }

        // Create CGImage using Data to ensure memory stays valid
        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: scaledWidth * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Render an icon with a checkerboard background for transparency
    static func renderIconWithBackground(_ icon: AppleIIgsIconImage, scale: Int = 1, checkerSize: Int = 4) -> CGImage? {
        let width = icon.width
        let height = icon.height
        let scaledWidth = width * scale
        let scaledHeight = height * scale

        // Use the actual bytes per row from the icon data
        let bytesPerRow = icon.bytesPerRow

        // Light and dark gray for checkerboard
        let light: (UInt8, UInt8, UInt8) = (240, 240, 240)
        let dark: (UInt8, UInt8, UInt8) = (200, 200, 200)

        var pixels = [UInt8](repeating: 0, count: scaledWidth * scaledHeight * 4)

        for y in 0..<height {
            for x in 0..<width {
                // 4 bits per pixel (2 pixels per byte) for both pixels AND mask
                let byteIndex = y * bytesPerRow + x / 2
                guard byteIndex < icon.pixelData.count else { continue }

                let pixelByte = icon.pixelData[byteIndex]
                let colorIndex: UInt8
                // Apple IIgs 320 mode: high nibble = left pixel, low nibble = right pixel
                if x % 2 == 0 {
                    colorIndex = (pixelByte >> 4) & 0x0F   // High nibble for even pixels (leftmost)
                } else {
                    colorIndex = pixelByte & 0x0F          // Low nibble for odd pixels (rightmost)
                }

                // Read mask value - ALSO 4bpp format (same as pixel data)
                // Mask value 0 = transparent, non-zero = opaque
                var isTransparent = false
                if byteIndex < icon.maskData.count {
                    let maskByte = icon.maskData[byteIndex]
                    let maskValue: UInt8
                    if x % 2 == 0 {
                        maskValue = (maskByte >> 4) & 0x0F
                    } else {
                        maskValue = maskByte & 0x0F
                    }
                    isTransparent = (maskValue == 0)
                }

                // Get color from palette
                let color = appleIIgsPalette[Int(colorIndex)]

                // Write scaled pixels
                for sy in 0..<scale {
                    for sx in 0..<scale {
                        let destX = x * scale + sx
                        let destY = y * scale + sy
                        let destIndex = (destY * scaledWidth + destX) * 4

                        if isTransparent {
                            // Checkerboard pattern
                            let checkerX = destX / checkerSize
                            let checkerY = destY / checkerSize
                            let isLight = (checkerX + checkerY) % 2 == 0
                            let bg = isLight ? light : dark
                            pixels[destIndex + 0] = bg.0
                            pixels[destIndex + 1] = bg.1
                            pixels[destIndex + 2] = bg.2
                            pixels[destIndex + 3] = 255
                        } else {
                            pixels[destIndex + 0] = color.r
                            pixels[destIndex + 1] = color.g
                            pixels[destIndex + 2] = color.b
                            pixels[destIndex + 3] = 255
                        }
                    }
                }
            }
        }

        // Create CGImage using Data to ensure memory stays valid
        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: scaledWidth * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
