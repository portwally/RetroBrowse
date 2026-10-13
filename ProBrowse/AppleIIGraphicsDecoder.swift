//
//  AppleIIGraphicsDecoder.swift
//  ProBrowse
//
//  Apple II graphics decoders for HGR, DHGR, and SHR formats
//  Adapted from RetroGraphics-Converter
//

import Foundation
import CoreGraphics

// MARK: - Apple II Image Type

enum AppleIIImageType: Equatable {
    case HGR
    case DHGR
    case SHR(is3200Color: Bool)
    case PackedSHR(mode: String)
    case MacPaint
    case Unknown

    var displayName: String {
        switch self {
        case .HGR: return "Hi-Res (HGR)"
        case .DHGR: return "Double Hi-Res (DHGR)"
        case .SHR(let is3200): return is3200 ? "Super Hi-Res (3200 color)" : "Super Hi-Res (SHR)"
        case .PackedSHR(let mode): return "Super Hi-Res (\(mode))"
        case .MacPaint: return "MacPaint"
        case .Unknown: return "Unknown"
        }
    }

    var resolution: (width: Int, height: Int) {
        switch self {
        case .HGR: return (280, 192)
        case .DHGR: return (560, 192)
        case .SHR, .PackedSHR: return (320, 200)
        case .MacPaint: return (576, 720)
        case .Unknown: return (0, 0)
        }
    }
}

// MARK: - Image Helpers

class ImageHelpers {

    static func createCGImage(from buffer: [UInt8], width: Int, height: Int) -> CGImage? {
        let bytesPerPixel = 4
        let bitsPerComponent = 8
        let bytesPerRow = width * bytesPerPixel
        let expectedSize = bytesPerRow * height

        guard buffer.count == expectedSize else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue)

        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bytesPerPixel * bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func readPalette(from data: Data, offset: Int, reverseOrder: Bool) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        var colors = [(r: UInt8, g: UInt8, b: UInt8)](repeating: (0,0,0), count: 16)

        for i in 0..<16 {
            let colorIdx = reverseOrder ? (15 - i) : i
            guard offset + (i * 2) + 1 < data.count else { continue }
            let byte1 = data[offset + (i * 2)]
            let byte2 = data[offset + (i * 2) + 1]

            let red4   = (byte2 & 0x0F)
            let green4 = (byte1 & 0xF0) >> 4
            let blue4  = (byte1 & 0x0F)

            let r = red4 * 17
            let g = green4 * 17
            let b = blue4 * 17

            colors[colorIdx] = (r, g, b)
        }
        return colors
    }

    static func generateDefaultPalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        var palette: [(r: UInt8, g: UInt8, b: UInt8)] = []
        for i in 0..<16 {
            let gray = UInt8(i * 17)
            palette.append((r: gray, g: gray, b: gray))
        }
        return palette
    }

    static func scaleCGImage(_ image: CGImage, to newSize: CGSize) -> CGImage? {
        guard let colorSpace = image.colorSpace else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(origin: .zero, size: newSize))
        return ctx.makeImage()
    }
}

// MARK: - Apple II Graphics Decoder

class AppleIIDecoder {

    // MARK: - Auto-detect and decode

    /// Attempt to detect and decode an Apple II graphics file
    static func detectAndDecode(data: Data, fileType: UInt8, auxType: UInt16) -> (image: CGImage?, type: AppleIIImageType) {
        let size = data.count

        // Check by ProDOS file type first
        switch fileType {
        case 0x08:  // FOT (Apple II Graphics File)
            switch auxType {
            case 0x4000:  // HGR
                if let image = decodeHGR(data: data) {
                    return (image, .HGR)
                }
            case 0x4001:  // DHGR
                if let image = decodeDHGR(data: data) {
                    return (image, .DHGR)
                }
            default:
                break
            }

        case 0xC0:  // PNT (Packed Super Hi-Res)
            if let result = PackedSHRDecoder.detectAndDecodePNT(data: data) {
                return result
            }

        case 0xC1:  // PIC (Super Hi-Res Picture)
            switch auxType {
            case 0x0000:  // Standard SHR
                if let image = decodeSHR(data: data, is3200Color: false) {
                    return (image, .SHR(is3200Color: false))
                }
            case 0x0002:  // 3200 color
                if let image = decodeSHR(data: data, is3200Color: true) {
                    return (image, .SHR(is3200Color: true))
                }
            default:
                if let image = decodeSHR(data: data, is3200Color: false) {
                    return (image, .SHR(is3200Color: false))
                }
            }

        case 0x06:  // BIN - a screen dump is recognised by its size below
            break

        case 0xB3:  // APP - Some SHR files use this type (especially packed)
            if let result = PackedSHRDecoder.detectAndDecodePNT(data: data) {
                return result
            }
            // Try standard SHR by size
            if size >= 32000 && size <= 32768 {
                if let image = decodeSHR(data: data, is3200Color: false) {
                    return (image, .SHR(is3200Color: false))
                }
            }

        default:
            break
        }

        // Fallback: detect by file size
        switch size {
        case 8184...8200:  // HGR (8192 bytes typical, some have header)
            if let image = decodeHGR(data: data) {
                return (image, .HGR)
            }

        case 16384:  // DHGR
            if let image = decodeDHGR(data: data) {
                return (image, .DHGR)
            }

        case 32000...32768:  // Standard SHR
            if let image = decodeSHR(data: data, is3200Color: false) {
                return (image, .SHR(is3200Color: false))
            }

        case 38400...39000:  // 3200 color SHR
            if let image = decodeSHR(data: data, is3200Color: true) {
                return (image, .SHR(is3200Color: true))
            }

        default:
            break
        }

        // Check for MacPaint format (has 512-byte header + PackBits compressed data).
        // This comes last: its header check is weak and would claim screen dumps that start with zeros.
        if MacPaintDecoder.isMacPaint(data) {
            if let image = MacPaintDecoder.decode(data) {
                return (image, .MacPaint)
            }
        }

        return (nil, .Unknown)
    }

    // MARK: - SHR Decoder (320x200, 32KB)

    static func decodeSHR(data: Data, is3200Color: Bool) -> CGImage? {
        let width = 320
        let height = 200
        var rgbaBuffer = [UInt8](repeating: 255, count: width * height * 4)

        let pixelDataStart = 0
        let scbOffset = 32000
        let standardPaletteOffset = 32256
        let brooksPaletteOffset = 32000

        guard data.count >= 32000 else { return nil }

        if !is3200Color {
            var palettes = [[(r: UInt8, g: UInt8, b: UInt8)]]()

            for i in 0..<16 {
                let pOffset = standardPaletteOffset + (i * 32)
                if pOffset + 32 <= data.count {
                    palettes.append(ImageHelpers.readPalette(from: data, offset: pOffset, reverseOrder: false))
                } else {
                    palettes.append(ImageHelpers.generateDefaultPalette())
                }
            }

            for y in 0..<height {
                let scb: UInt8
                if scbOffset + y < data.count {
                    scb = data[scbOffset + y]
                } else {
                    scb = 0
                }
                let paletteIndex = Int(scb & 0x0F)
                let currentPalette = palettes[paletteIndex]
                renderSHRLine(y: y, data: data, pixelStart: pixelDataStart, palette: currentPalette, to: &rgbaBuffer, width: width)
            }

        } else {
            for y in 0..<height {
                let pOffset = brooksPaletteOffset + (y * 32)
                let currentPalette: [(r: UInt8, g: UInt8, b: UInt8)]
                if pOffset + 32 <= data.count {
                    currentPalette = ImageHelpers.readPalette(from: data, offset: pOffset, reverseOrder: true)
                } else {
                    currentPalette = ImageHelpers.generateDefaultPalette()
                }
                renderSHRLine(y: y, data: data, pixelStart: pixelDataStart, palette: currentPalette, to: &rgbaBuffer, width: width)
            }
        }

        return ImageHelpers.createCGImage(from: rgbaBuffer, width: width, height: height)
    }

    private static func renderSHRLine(y: Int, data: Data, pixelStart: Int, palette: [(r: UInt8, g: UInt8, b: UInt8)], to buffer: inout [UInt8], width: Int) {
        let bytesPerLine = 160
        let lineStart = pixelStart + (y * bytesPerLine)

        guard lineStart + bytesPerLine <= data.count else { return }

        for xByte in 0..<bytesPerLine {
            let byte = data[lineStart + xByte]

            let idx1 = (byte & 0xF0) >> 4
            let idx2 = (byte & 0x0F)

            let c1 = palette[Int(idx1)]
            let bufferIdx1 = (y * width + (xByte * 2)) * 4
            buffer[bufferIdx1]     = c1.r
            buffer[bufferIdx1 + 1] = c1.g
            buffer[bufferIdx1 + 2] = c1.b
            buffer[bufferIdx1 + 3] = 255

            let c2 = palette[Int(idx2)]
            let bufferIdx2 = (y * width + (xByte * 2) + 1) * 4
            buffer[bufferIdx2]     = c2.r
            buffer[bufferIdx2 + 1] = c2.g
            buffer[bufferIdx2 + 2] = c2.b
            buffer[bufferIdx2 + 3] = 255
        }
    }

    // MARK: - DHGR Decoder (560x192, 16KB)

    static func decodeDHGR(data: Data) -> CGImage? {
        let width = 560
        let height = 192
        var rgbaBuffer = [UInt8](repeating: 0, count: width * height * 4)

        guard data.count >= 16384 else { return nil }

        let mainData = data.subdata(in: 0..<8192)
        let auxData = data.subdata(in: 8192..<16384)

        let dhgrPalette: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (0, 0, 0),           // 0: Black
            (134, 18, 192),      // 1: Magenta
            (0, 101, 43),        // 2: Dark Green
            (48, 48, 255),       // 3: Blue
            (165, 95, 0),        // 4: Brown
            (172, 172, 172),     // 5: Light Gray
            (0, 226, 0),         // 6: Light Green
            (0, 255, 146),       // 7: Aqua
            (224, 0, 39),        // 8: Red
            (223, 17, 212),      // 9: Purple
            (81, 81, 81),        // 10: Dark Gray
            (78, 158, 255),      // 11: Light Blue
            (255, 39, 0),        // 12: Orange
            (255, 150, 153),     // 13: Pink
            (255, 253, 0),       // 14: Yellow
            (255, 255, 255)      // 15: White
        ]

        for y in 0..<height {
            let base = (y & 0x07) << 10
            let row = (y >> 3) & 0x07
            let block = (y >> 6) & 0x03
            let offset = base | (row << 7) | (block * 40)

            guard offset + 40 <= 8192 else { continue }

            var bits: [UInt8] = []
            for xByte in 0..<40 {
                let mainByte = mainData[offset + xByte]
                let auxByte = auxData[offset + xByte]

                for bitPos in 0..<7 {
                    bits.append((mainByte >> bitPos) & 0x1)
                }
                for bitPos in 0..<7 {
                    bits.append((auxByte >> bitPos) & 0x1)
                }
            }

            var pixelX = 0
            var bitIndex = 0

            while bitIndex + 3 < bits.count && pixelX < width {
                let bit0 = bits[bitIndex]
                let bit1 = bits[bitIndex + 1]
                let bit2 = bits[bitIndex + 2]
                let bit3 = bits[bitIndex + 3]

                let colorIndex = Int(bit0 | (bit1 << 1) | (bit2 << 2) | (bit3 << 3))
                let color = dhgrPalette[colorIndex]

                for _ in 0..<4 {
                    let bufferIdx = (y * width + pixelX) * 4
                    if bufferIdx + 3 < rgbaBuffer.count && pixelX < width {
                        rgbaBuffer[bufferIdx] = color.r
                        rgbaBuffer[bufferIdx + 1] = color.g
                        rgbaBuffer[bufferIdx + 2] = color.b
                        rgbaBuffer[bufferIdx + 3] = 255
                    }
                    pixelX += 1
                }

                bitIndex += 4
            }
        }

        guard let fullImage = ImageHelpers.createCGImage(from: rgbaBuffer, width: width, height: height) else {
            return nil
        }

        // Scale down to 280x192 for proper aspect ratio
        return ImageHelpers.scaleCGImage(fullImage, to: CGSize(width: 280, height: 192))
    }

    // MARK: - HGR Decoder (280x192, 8KB)

    static func decodeHGR(data: Data) -> CGImage? {
        let width = 280
        let height = 192
        var rgbaBuffer = [UInt8](repeating: 0, count: width * height * 4)

        let hgrColors: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (0, 0, 0),       // 0: Black
            (255, 255, 255), // 1: White
            (32, 192, 32),   // 2: Green
            (160, 32, 240),  // 3: Violet
            (255, 100, 0),   // 4: Orange
            (60, 60, 255)    // 5: Blue
        ]

        guard data.count >= 8184 else { return nil }

        for y in 0..<height {
            let i = y % 8
            let j = (y / 8) % 8
            let k = y / 64

            let fileOffset = (i * 1024) + (j * 128) + (k * 40)

            guard fileOffset + 40 <= data.count else { continue }

            for xByte in 0..<40 {
                let currentByte = data[fileOffset + xByte]
                let nextByte: UInt8 = (xByte + 1 < 40) ? data[fileOffset + xByte + 1] : 0

                let highBit = (currentByte >> 7) & 0x1

                for bitIndex in 0..<7 {
                    let pixelIndex = (xByte * 7) + bitIndex
                    let bufferIdx = (y * width + pixelIndex) * 4

                    let bitA = (currentByte >> bitIndex) & 0x1

                    let bitB: UInt8
                    if bitIndex == 6 {
                        bitB = (nextByte >> 0) & 0x1
                    } else {
                        bitB = (currentByte >> (bitIndex + 1)) & 0x1
                    }

                    var colorIndex = 0

                    if bitA == 0 && bitB == 0 {
                        colorIndex = 0
                    } else if bitA == 1 && bitB == 1 {
                        colorIndex = 1
                    } else {
                        let isEvenColumn = (pixelIndex % 2) == 0

                        if highBit == 1 {
                            if isEvenColumn {
                                colorIndex = (bitA == 1) ? 5 : 4
                            } else {
                                colorIndex = (bitA == 1) ? 4 : 5
                            }
                        } else {
                            if isEvenColumn {
                                colorIndex = (bitA == 1) ? 3 : 2
                            } else {
                                colorIndex = (bitA == 1) ? 2 : 3
                            }
                        }
                    }

                    let c = hgrColors[colorIndex]
                    rgbaBuffer[bufferIdx] = c.r
                    rgbaBuffer[bufferIdx + 1] = c.g
                    rgbaBuffer[bufferIdx + 2] = c.b
                    rgbaBuffer[bufferIdx + 3] = 255
                }
            }
        }

        return ImageHelpers.createCGImage(from: rgbaBuffer, width: width, height: height)
    }
}

// MARK: - Packed SHR Decoder

class PackedSHRDecoder {

    // MARK: - Apple IIgs PackBytes Decompression

    static func unpackBytes(data: Data, maxOutputSize: Int = 65536) -> Data {
        var output = Data()
        output.reserveCapacity(min(maxOutputSize, data.count * 4))

        var pos = 0

        while pos < data.count && output.count < maxOutputSize {
            let flag = data[pos]
            pos += 1

            let flagCount = Int(flag & 0x3F) + 1
            let mode = flag & 0xC0

            switch mode {
            case 0x00:  // Literal: copy next flagCount bytes
                let bytesToCopy = min(flagCount, data.count - pos, maxOutputSize - output.count)
                if bytesToCopy > 0 {
                    output.append(data.subdata(in: pos..<(pos + bytesToCopy)))
                    pos += bytesToCopy
                }

            case 0x40:  // Repeat 8-bit value flagCount times
                if pos < data.count {
                    let repeatByte = data[pos]
                    pos += 1
                    let bytesToWrite = min(flagCount, maxOutputSize - output.count)
                    output.append(contentsOf: repeatElement(repeatByte, count: bytesToWrite))
                }

            case 0x80:  // Repeat 32-bit pattern flagCount times
                if pos + 4 <= data.count {
                    let pattern = Array(data[pos..<(pos + 4)])
                    pos += 4
                    for _ in 0..<flagCount {
                        if output.count + 4 <= maxOutputSize {
                            output.append(contentsOf: pattern)
                        } else {
                            let remaining = maxOutputSize - output.count
                            output.append(contentsOf: pattern.prefix(remaining))
                            break
                        }
                    }
                }

            case 0xC0:  // Repeat 8-bit value flagCount * 4 times
                if pos < data.count {
                    let repeatByte = data[pos]
                    pos += 1
                    let bytesToWrite = min(flagCount * 4, maxOutputSize - output.count)
                    output.append(contentsOf: repeatElement(repeatByte, count: bytesToWrite))
                }

            default:
                break
            }
        }

        return output
    }

    // MARK: - Detection and Decoding

    static func detectAndDecodePNT(data: Data) -> (image: CGImage?, type: AppleIIImageType)? {
        // Try APF format first
        if isAPFFormat(data) {
            return decodeAPF(data: data)
        }

        // Try Paintworks format. The check is weak (a packed screen that starts
        // black passes it), so carry on if the file does not decode that way.
        if isPaintworksFormat(data), let result = decodePaintworks(data: data) {
            return result
        }

        // Try PackBytes compressed
        if let result = tryDecodePackedSHR(data: data) {
            return result
        }

        return nil
    }

    private static func isAPFFormat(_ data: Data) -> Bool {
        guard data.count >= 20 else { return false }

        let blockLength = Int(data[0]) | (Int(data[1]) << 8) | (Int(data[2]) << 16) | (Int(data[3]) << 24)
        guard blockLength >= 10 && blockLength <= data.count else { return false }

        let nameLength = Int(data[4])
        guard nameLength >= 4 && nameLength <= 15 && 5 + nameLength <= data.count else { return false }

        let nameData = data[5..<(5 + nameLength)]
        guard let blockName = String(data: nameData, encoding: .ascii) else { return false }

        return ["MAIN", "PATS", "SCIB", "PALETTES", "MASK", "MULTIPAL", "NOTE"].contains(blockName)
    }

    private static func isPaintworksFormat(_ data: Data) -> Bool {
        guard data.count >= 0x222 else { return false }
        for i in 0..<16 {
            if (data[i * 2 + 1] & 0xF0) != 0 { return false }
        }
        return true
    }

    // MARK: - APF Decoder

    private static func decodeAPF(data: Data) -> (image: CGImage?, type: AppleIIImageType)? {
        var blocks: [(name: String, data: Data)] = []
        var pos = 0

        while pos + 5 <= data.count {
            let blockLength = Int(data[pos]) | (Int(data[pos + 1]) << 8) |
                             (Int(data[pos + 2]) << 16) | (Int(data[pos + 3]) << 24)

            guard blockLength >= 5 && pos + blockLength <= data.count else { break }

            let nameLength = Int(data[pos + 4])
            guard nameLength > 0 && nameLength <= 20 && pos + 5 + nameLength <= data.count else { break }

            let nameData = data[(pos + 5)..<(pos + 5 + nameLength)]
            guard let blockName = String(data: nameData, encoding: .ascii) else { break }

            let dataOffset = pos + 5 + nameLength
            let dataLength = blockLength - 5 - nameLength

            if dataLength > 0 && dataOffset + dataLength <= data.count {
                let blockData = data.subdata(in: dataOffset..<(dataOffset + dataLength))
                blocks.append((name: blockName, data: blockData))
            }

            pos += blockLength
        }

        guard let mainBlock = blocks.first(where: { $0.name == "MAIN" }) else {
            return nil
        }

        // Parse MAIN block
        guard let mainData = parseMAINBlock(mainBlock.data) else {
            return nil
        }

        // Check for MULTIPAL (3200 color mode)
        var palettes3200: [[(r: UInt8, g: UInt8, b: UInt8)]]? = nil
        if let multipalBlock = blocks.first(where: { $0.name == "MULTIPAL" }) {
            palettes3200 = parseMULTIPALBlock(multipalBlock.data)
        }

        let image: CGImage?
        let modeString: String

        if let palettes = palettes3200, palettes.count >= mainData.numScanLines {
            image = renderSHR3200(mainData: mainData, palettes: palettes)
            modeString = "APF 3200"
        } else {
            image = renderSHRStandard(mainData: mainData)
            modeString = "APF"
        }

        return (image, .PackedSHR(mode: modeString))
    }

    private struct MAINBlockData {
        let masterMode: UInt16
        let pixelsPerScanLine: Int
        let colorTables: [[(r: UInt8, g: UInt8, b: UInt8)]]
        let numScanLines: Int
        let scanLineDirectory: [(packedBytes: Int, mode: UInt16)]
        let pixels: Data
    }

    private static func parseMAINBlock(_ data: Data) -> MAINBlockData? {
        var pos = 0

        guard pos + 6 <= data.count else { return nil }

        let masterMode = UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8)
        let pixelsPerScanLine = Int(data[pos + 2]) | (Int(data[pos + 3]) << 8)
        let numColorTables = Int(data[pos + 4]) | (Int(data[pos + 5]) << 8)
        pos += 6

        guard pixelsPerScanLine > 0 && pixelsPerScanLine <= 1280 else { return nil }

        var colorTables: [[(r: UInt8, g: UInt8, b: UInt8)]] = []
        for _ in 0..<numColorTables {
            guard pos + 32 <= data.count else { break }
            colorTables.append(readColorTable(from: data, at: pos))
            pos += 32
        }

        guard pos + 2 <= data.count else { return nil }
        let numScanLines = Int(data[pos]) | (Int(data[pos + 1]) << 8)
        pos += 2

        guard numScanLines > 0 && numScanLines <= 400 else { return nil }

        var scanLineDirectory: [(packedBytes: Int, mode: UInt16)] = []
        for _ in 0..<numScanLines {
            guard pos + 4 <= data.count else { break }
            let packedBytes = Int(data[pos]) | (Int(data[pos + 1]) << 8)
            let mode = UInt16(data[pos + 2]) | (UInt16(data[pos + 3]) << 8)
            scanLineDirectory.append((packedBytes: packedBytes, mode: mode))
            pos += 4
        }

        guard scanLineDirectory.count == numScanLines else { return nil }

        // 640 mode packs four pixels into a byte, 320 mode two
        let bytesPerLine = (masterMode & 0x80) != 0 ? pixelsPerScanLine / 4 : pixelsPerScanLine / 2
        var allPixels = Data()
        allPixels.reserveCapacity(bytesPerLine * numScanLines)

        for entry in scanLineDirectory {
            guard pos + entry.packedBytes <= data.count else {
                allPixels.append(contentsOf: repeatElement(UInt8(0), count: bytesPerLine))
                continue
            }

            let packedLine = data.subdata(in: pos..<(pos + entry.packedBytes))
            pos += entry.packedBytes

            var unpackedLine = unpackBytes(data: packedLine, maxOutputSize: bytesPerLine)

            if unpackedLine.count < bytesPerLine {
                unpackedLine.append(contentsOf: repeatElement(UInt8(0), count: bytesPerLine - unpackedLine.count))
            }

            allPixels.append(unpackedLine.prefix(bytesPerLine))
        }

        return MAINBlockData(
            masterMode: masterMode,
            pixelsPerScanLine: pixelsPerScanLine,
            colorTables: colorTables,
            numScanLines: numScanLines,
            scanLineDirectory: scanLineDirectory,
            pixels: allPixels
        )
    }

    private static func parseMULTIPALBlock(_ data: Data) -> [[(r: UInt8, g: UInt8, b: UInt8)]]? {
        guard data.count >= 2 else { return nil }

        let numColorTables = Int(data[0]) | (Int(data[1]) << 8)
        guard numColorTables > 0 && numColorTables <= 400 else { return nil }

        var palettes: [[(r: UInt8, g: UInt8, b: UInt8)]] = []
        var pos = 2

        for _ in 0..<numColorTables {
            guard pos + 32 <= data.count else { break }
            palettes.append(readColorTable(from: data, at: pos))
            pos += 32
        }

        return palettes.isEmpty ? nil : palettes
    }

    private static func readColorTable(from data: Data, at offset: Int) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        var colors: [(r: UInt8, g: UInt8, b: UInt8)] = []

        for i in 0..<16 {
            let entryOffset = offset + (i * 2)
            guard entryOffset + 1 < data.count else {
                colors.append((0, 0, 0))
                continue
            }

            let low = data[entryOffset]
            let high = data[entryOffset + 1]

            let red = high & 0x0F
            let green = (low >> 4) & 0x0F
            let blue = low & 0x0F

            colors.append((r: red * 17, g: green * 17, b: blue * 17))
        }

        return colors
    }

    private static func renderSHRStandard(mainData: MAINBlockData) -> CGImage? {
        let width = mainData.pixelsPerScanLine
        let height = mainData.numScanLines
        let is640 = (mainData.masterMode & 0x80) != 0
        let bytesPerLine = is640 ? width / 4 : width / 2

        var rgbaBuffer = [UInt8](repeating: 0, count: width * height * 4)

        let defaultPalette: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (0,0,0), (221,0,51), (0,0,153), (221,34,153),
            (0,119,34), (85,85,85), (34,34,255), (102,170,255),
            (136,85,0), (255,102,0), (170,170,170), (255,153,136),
            (17,221,0), (255,255,0), (68,255,153), (255,255,255)
        ]

        for y in 0..<height {
            let lineOffset = y * bytesPerLine
            let entry = y < mainData.scanLineDirectory.count ? mainData.scanLineDirectory[y] : (packedBytes: 0, mode: UInt16(0))
            let paletteIndex = Int(entry.mode & 0x0F)

            let palette = paletteIndex < mainData.colorTables.count ?
                         mainData.colorTables[paletteIndex] :
                         (mainData.colorTables.first ?? defaultPalette)

            for xByte in 0..<bytesPerLine {
                let dataIndex = lineOffset + xByte
                guard dataIndex < mainData.pixels.count else { continue }
                let byte = mainData.pixels[dataIndex]

                if is640 {
                    // Four 2-bit pixels; each column of the four uses its own quarter of the palette
                    let paletteBase = [8, 12, 0, 4]
                    for column in 0..<4 {
                        let x = xByte * 4 + column
                        let colorIndex = paletteBase[column] + Int((byte >> UInt8(6 - column * 2)) & 0x03)
                        guard x < width, colorIndex < palette.count else { continue }
                        let color = palette[colorIndex]
                        let bufIdx = (y * width + x) * 4
                        rgbaBuffer[bufIdx] = color.0
                        rgbaBuffer[bufIdx + 1] = color.1
                        rgbaBuffer[bufIdx + 2] = color.2
                        rgbaBuffer[bufIdx + 3] = 255
                    }
                    continue
                }

                let x = xByte * 2

                let colorIndex1 = Int((byte >> 4) & 0x0F)
                let color1 = colorIndex1 < palette.count ? palette[colorIndex1] : (0, 0, 0)

                if x < width {
                    let bufIdx1 = (y * width + x) * 4
                    rgbaBuffer[bufIdx1] = color1.0
                    rgbaBuffer[bufIdx1 + 1] = color1.1
                    rgbaBuffer[bufIdx1 + 2] = color1.2
                    rgbaBuffer[bufIdx1 + 3] = 255
                }

                let colorIndex2 = Int(byte & 0x0F)
                let color2 = colorIndex2 < palette.count ? palette[colorIndex2] : (0, 0, 0)

                if x + 1 < width {
                    let bufIdx2 = (y * width + x + 1) * 4
                    rgbaBuffer[bufIdx2] = color2.0
                    rgbaBuffer[bufIdx2 + 1] = color2.1
                    rgbaBuffer[bufIdx2 + 2] = color2.2
                    rgbaBuffer[bufIdx2 + 3] = 255
                }
            }
        }

        return ImageHelpers.createCGImage(from: rgbaBuffer, width: width, height: height)
    }

    private static func renderSHR3200(mainData: MAINBlockData, palettes: [[(r: UInt8, g: UInt8, b: UInt8)]]) -> CGImage? {
        let width = mainData.pixelsPerScanLine
        let height = mainData.numScanLines
        let bytesPerLine = width / 2

        var rgbaBuffer = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            let lineOffset = y * bytesPerLine
            let palette = y < palettes.count ? palettes[y] : ImageHelpers.generateDefaultPalette()

            for xByte in 0..<bytesPerLine {
                let dataIndex = lineOffset + xByte
                guard dataIndex < mainData.pixels.count else { continue }
                let byte = mainData.pixels[dataIndex]

                let x = xByte * 2

                let colorIndex1 = Int((byte >> 4) & 0x0F)
                let color1 = colorIndex1 < palette.count ? palette[colorIndex1] : (0, 0, 0)

                let bufIdx1 = (y * width + x) * 4
                guard bufIdx1 + 3 < rgbaBuffer.count else { continue }
                rgbaBuffer[bufIdx1] = color1.0
                rgbaBuffer[bufIdx1 + 1] = color1.1
                rgbaBuffer[bufIdx1 + 2] = color1.2
                rgbaBuffer[bufIdx1 + 3] = 255

                let colorIndex2 = Int(byte & 0x0F)
                let color2 = colorIndex2 < palette.count ? palette[colorIndex2] : (0, 0, 0)

                let bufIdx2 = (y * width + x + 1) * 4
                guard bufIdx2 + 3 < rgbaBuffer.count else { continue }
                rgbaBuffer[bufIdx2] = color2.0
                rgbaBuffer[bufIdx2 + 1] = color2.1
                rgbaBuffer[bufIdx2 + 2] = color2.2
                rgbaBuffer[bufIdx2 + 3] = 255
            }
        }

        return ImageHelpers.createCGImage(from: rgbaBuffer, width: width, height: height)
    }

    // MARK: - Paintworks Decoder

    private static func decodePaintworks(data: Data) -> (image: CGImage?, type: AppleIIImageType)? {
        guard data.count >= 0x222 else { return nil }

        var palette: [(r: UInt8, g: UInt8, b: UInt8)] = []
        for i in 0..<16 {
            let low = data[i * 2]
            let high = data[i * 2 + 1]
            let red = high & 0x0F
            let green = (low >> 4) & 0x0F
            let blue = low & 0x0F
            palette.append((r: red * 17, g: green * 17, b: blue * 17))
        }

        let startOffset = 0x222
        guard data.count > startOffset else { return nil }

        let remainingData = data.subdata(in: startOffset..<data.count)
        let width = 320
        let bytesPerLine = 160

        var unpackedData: Data?
        var decodedHeight = 200

        // Try PackBytes decompression
        let packedBytes = unpackBytes(data: remainingData, maxOutputSize: 64000)
        if packedBytes.count >= 32000 {
            unpackedData = packedBytes
            decodedHeight = min(packedBytes.count / bytesPerLine, 396)
        }

        // Try uncompressed
        if unpackedData == nil || unpackedData!.count < 32000 {
            if remainingData.count >= 32000 && remainingData.count <= 33000 {
                unpackedData = remainingData.prefix(32000)
                decodedHeight = 200
            }
        }

        guard let finalData = unpackedData, finalData.count >= bytesPerLine else {
            return nil
        }

        let height = min(decodedHeight, finalData.count / bytesPerLine)
        guard height > 0 else { return nil }

        var rgbaBuffer = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for xByte in 0..<bytesPerLine {
                let dataIndex = y * bytesPerLine + xByte
                guard dataIndex < finalData.count else { continue }
                let byte = finalData[dataIndex]

                let x = xByte * 2

                let color1 = palette[Int((byte >> 4) & 0x0F)]
                let bufIdx1 = (y * width + x) * 4
                rgbaBuffer[bufIdx1] = color1.0
                rgbaBuffer[bufIdx1 + 1] = color1.1
                rgbaBuffer[bufIdx1 + 2] = color1.2
                rgbaBuffer[bufIdx1 + 3] = 255

                let color2 = palette[Int(byte & 0x0F)]
                let bufIdx2 = (y * width + x + 1) * 4
                rgbaBuffer[bufIdx2] = color2.0
                rgbaBuffer[bufIdx2 + 1] = color2.1
                rgbaBuffer[bufIdx2 + 2] = color2.2
                rgbaBuffer[bufIdx2 + 3] = 255
            }
        }

        guard let cgImage = ImageHelpers.createCGImage(from: rgbaBuffer, width: width, height: height) else {
            return nil
        }

        return (cgImage, .PackedSHR(mode: "Paintworks"))
    }

    // MARK: - Generic Packed SHR

    private static func tryDecodePackedSHR(data: Data) -> (image: CGImage?, type: AppleIIImageType)? {
        let unpackedData = unpackBytes(data: data, maxOutputSize: 65536)

        guard unpackedData.count >= 32000 else { return nil }

        if let image = AppleIIDecoder.decodeSHR(data: unpackedData, is3200Color: false) {
            return (image, .PackedSHR(mode: "Packed"))
        }

        return nil
    }
}
