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
    /// Decode an Apple II or IIgs picture. The routing follows Retro Graphics Converter (SHRDecoder),
    /// whose PackedSHRDecoder and DreamGrafixDecoder are shared with this app.
    /// `filename` lets .3201 and .PNT files stored as BIN be recognized.
    static func detectAndDecode(data: Data, fileType: UInt8, auxType: UInt16,
                                filename: String? = nil) -> (image: CGImage?, type: AppleIIImageType) {
        let size = data.count
        let name = (filename ?? "").lowercased()

        // Check by ProDOS file type first
        switch fileType {
        case 0x08:  // FOT: raw screens are recognized by size below; Apple's packed Hi-Res ($4000)
                    // and Double Hi-Res ($4001) use PackBytes (some carry aux $0000)
            if !(8184...8200).contains(size) && size != 16384, let result = decodePackedFOT(data: data) {
                return result
            }

        case 0xC0:  // PNT (Packed Super Hi-Res)
            var result: (image: CGImage?, type: AppleIIImageType)
            switch auxType {
            case 0x0000:
                // PaintWorks. Some programs save a plain packed screen ($C0/$0001 layout) under
                // aux $0000. A PaintWorks file starts with a palette whose high bytes are $0R;
                // if it does not, try the packed screen first.
                let looksLikePaintworks = size >= 0x222 && (0..<16).allSatisfy { data[$0 * 2 + 1] & 0xF0 == 0 }
                result = (nil, .Unknown)
                if !looksLikePaintworks { result = PackedSHRDecoder.decodePNT0001(data: data) }
                if result.image == nil { result = PackedSHRDecoder.decodePNT0000(data: data) }
                if result.image == nil { result = PackedSHRDecoder.decodePNT0001(data: data) }
            case 0x0001:
                result = PackedSHRDecoder.decodePNT0001(data: data)
            case 0x0002, 0x0003:
                result = PackedSHRDecoder.decodePNT0002(data: data)
            case 0x8005:
                result = DreamGrafixDecoder.decodeDreamGrafixPacked(data: data)
            default:
                // Other aux types: an unpacked 32 KB screen is drawn by size below
                result = (nil, .Unknown)
                if !(32767...32768).contains(size) {
                    result = PackedSHRDecoder.detectAndDecodePNT(data: data) ?? (nil, .Unknown)
                }
            }
            if result.image != nil { return result }

        case 0xC1:  // PIC (Super Hi-Res Picture)
            if auxType == 0x8003 {
                let result = DreamGrafixDecoder.decodeDreamGrafixUnpacked(data: data)
                if result.image != nil { return result }
            }
            // 3200-color only when the file is big enough; some 32 KB screens carry aux $0002
            if auxType == 0x0002 && size >= 38400, let image = decodeSHR(data: data, is3200Color: true) {
                return (image, .SHR(is3200Color: true))
            }
            if size >= 32000, let image = decodeSHR(data: data, is3200Color: false) {
                return (image, .SHR(is3200Color: false))
            }

        case 0xC2:  // ANI: a PaintWorks animation starts with a complete 32 KB screen (first frame)
            if size >= 32768, let image = decodeSHR(data: data, is3200Color: false) {
                return (image, .PackedSHR(mode: "Animation, first frame"))
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

        // Files without the right type: .3201 (packed 3200-color), .PNT, APF and DreamGrafix by signature
        if name.hasSuffix(".3201"), let image = decode3201(data: data) {
            return (image, .PackedSHR(mode: "3200 Packed"))
        }
        if name.hasSuffix(".pnt"), let result = PackedSHRDecoder.detectAndDecodePNT(data: data), result.image != nil {
            return result
        }
        if let result = PackedSHRDecoder.tryDecodeAPF(data: data), result.image != nil {
            return result
        }
        if DreamGrafixDecoder.isDreamGrafixFormat(data) {
            let packed = DreamGrafixDecoder.decodeDreamGrafixPacked(data: data)
            if packed.image != nil { return packed }
            let unpacked = DreamGrafixDecoder.decodeDreamGrafixUnpacked(data: data)
            if unpacked.image != nil { return unpacked }
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

    /// Apple's packed Hi-Res and Double Hi-Res (FOT): PackBytes, told apart by the unpacked size
    static func decodePackedFOT(data: Data) -> (image: CGImage?, type: AppleIIImageType)? {
        let unpacked = PackedSHRDecoder.unpackBytes(data: data, maxOutputSize: 16384 + 64)
        if (8184...8200).contains(unpacked.count) {
            var screen = Data(unpacked.prefix(8192))
            if screen.count < 8192 { screen.append(contentsOf: repeatElement(UInt8(0), count: 8192 - screen.count)) }
            if let image = decodeHGR(data: screen) { return (image, .HGR) }
        } else if unpacked.count == 16384, let image = decodeDHGR(data: unpacked) {
            return (image, .DHGR)
        }
        return nil
    }

    /// .3201: "APP" + $00 (high ASCII), 200 palettes in 3200-color (Brooks) order, PackBytes pixels.
    /// Unpacked pixels plus the palettes make a 3200-color screen.
    static func decode3201(data: Data) -> CGImage? {
        let hasHeader = data.count > 4 && data[0] == 0xC1 && data[1] == 0xD0 && data[2] == 0xD0 && data[3] == 0x00
        let paletteOffset = hasHeader ? 4 : 0
        guard data.count > paletteOffset + 6400 else { return nil }
        let pixels = PackedSHRDecoder.unpackBytes(data: data.subdata(in: (paletteOffset + 6400)..<data.count),
                                                  maxOutputSize: 32000)
        guard pixels.count >= 32000 else { return nil }
        var screen = Data(pixels.prefix(32000))
        screen.append(data.subdata(in: paletteOffset..<(paletteOffset + 6400)))
        return decodeSHR(data: screen, is3200Color: true)
    }

    // MARK: - SHR Decoder (320x200, 32KB)

    /// Standard screens (`is3200Color` false) honor each line's SCB: palette number and 320/640 mode.
    /// A screen with any 640-mode line is drawn 640 pixels wide, its 320-mode lines doubled.
    /// `paletteOverride` replaces the 16 palettes stored in the file (palette editor).
    static func decodeSHR(data: Data, is3200Color: Bool,
                          paletteOverride: [[(r: UInt8, g: UInt8, b: UInt8)]]? = nil) -> CGImage? {
        var width = 320
        let height = 200

        let pixelDataStart = 0
        let scbOffset = 32000
        let standardPaletteOffset = 32256
        let brooksPaletteOffset = 32000

        // Standard SHR requires at least 32768 bytes (32000 pixels + 256 SCB + 512 palette)
        // But some files may have less - we need at least pixels + SCB + 1 palette (32000 + 256 + 32)
        guard data.count >= 32000 else { return nil }

        if !is3200Color {
            var palettes = [[(r: UInt8, g: UInt8, b: UInt8)]]()

            // Read palettes (with bounds checking)
            for i in 0..<16 {
                let pOffset = standardPaletteOffset + (i * 32)
                if let override = paletteOverride, !override.isEmpty {
                    palettes.append(i < override.count ? override[i] : override[0])
                } else if pOffset + 32 <= data.count {
                    palettes.append(ImageHelpers.readPalette(from: data, offset: pOffset, reverseOrder: false))
                } else {
                    // Use default palette if not enough data
                    palettes.append(ImageHelpers.generateDefaultPalette())
                }
            }

            let scbs = (0..<height).map { scbOffset + $0 < data.count ? data[scbOffset + $0] : 0 }
            if scbs.contains(where: { $0 & 0x80 != 0 }) { width = 640 }
            var rgbaBuffer = [UInt8](repeating: 255, count: width * height * 4)

            for y in 0..<height {
                let currentPalette = palettes[Int(scbs[y] & 0x0F)]
                if scbs[y] & 0x80 != 0 {
                    renderLine640(y: y, data: data, pixelStart: pixelDataStart, palette: currentPalette, to: &rgbaBuffer)
                } else {
                    renderLine(y: y, data: data, pixelStart: pixelDataStart, palette: currentPalette, to: &rgbaBuffer,
                               width: width, scale: width / 320)
                }
            }
            return ImageHelpers.createCGImage(from: rgbaBuffer, width: width, height: height)

        } else {
            var rgbaBuffer = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                let pOffset = brooksPaletteOffset + (y * 32)
                let currentPalette: [(r: UInt8, g: UInt8, b: UInt8)]
                if pOffset + 32 <= data.count {
                    currentPalette = ImageHelpers.readPalette(from: data, offset: pOffset, reverseOrder: true)
                } else {
                    currentPalette = ImageHelpers.generateDefaultPalette()
                }
                renderLine(y: y, data: data, pixelStart: pixelDataStart, palette: currentPalette, to: &rgbaBuffer, width: width)
            }
            return ImageHelpers.createCGImage(from: rgbaBuffer, width: width, height: height)
        }
    }
    
    /// 320-mode line: two 4-bit pixels per byte. `scale` 2 doubles them on a 640-wide screen.
    private static func renderLine(y: Int, data: Data, pixelStart: Int, palette: [(r: UInt8, g: UInt8, b: UInt8)],
                                   to buffer: inout [UInt8], width: Int, scale: Int = 1) {
        let lineStart = pixelStart + y * 160
        for xByte in 0..<160 {
            let byte = data[lineStart + xByte]
            for (n, index) in [Int(byte >> 4), Int(byte & 0x0F)].enumerated() {
                let c = palette[index]
                for s in 0..<scale {
                    let i = (y * width + (xByte * 2 + n) * scale + s) * 4
                    buffer[i] = c.r; buffer[i + 1] = c.g; buffer[i + 2] = c.b; buffer[i + 3] = 255
                }
            }
        }
    }

    /// 640-mode line: four 2-bit pixels per byte, each using its own quarter of the palette
    /// (colors 8-11, 12-15, 0-3, 4-7), on a 640-wide screen
    private static func renderLine640(y: Int, data: Data, pixelStart: Int, palette: [(r: UInt8, g: UInt8, b: UInt8)],
                                      to buffer: inout [UInt8]) {
        let lineStart = pixelStart + y * 160
        for xByte in 0..<160 {
            let byte = data[lineStart + xByte]
            for n in 0..<4 {
                let c = palette[[8, 12, 0, 4][n] + Int((byte >> (6 - n * 2)) & 0x03)]
                let i = (y * 640 + xByte * 4 + n) * 4
                buffer[i] = c.r; buffer[i + 1] = c.g; buffer[i + 2] = c.b; buffer[i + 3] = 255
            }
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

        // Indexed with the leftmost bit as bit 0 (IIe Tech Ref patterns: aux $11 = dark blue)
        let dhgrPalette: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (0, 0, 0),           // 0: Black
            (0, 0, 153),         // 1: Dark Blue
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
