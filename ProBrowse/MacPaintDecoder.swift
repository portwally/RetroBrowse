//
//  MacPaintDecoder.swift
//  ProBrowse
//
//  Decoder for MacPaint graphics files (.mac, .pntg)
//  Based on CiderPress2 implementation and Macintosh Technical Notes
//

import Foundation
import CoreGraphics

// MARK: - MacPaint Decoder

class MacPaintDecoder {

    // MacPaint image dimensions
    static let IMAGE_WIDTH = 576
    static let IMAGE_HEIGHT = 720
    static let ROW_STRIDE = 72  // 576 pixels / 8 bits per byte
    static let HEADER_SIZE = 512
    static let UNCOMPRESSED_SIZE = ROW_STRIDE * IMAGE_HEIGHT  // 51,840 bytes

    // Minimum file size: header + at least some compressed data
    static let MIN_FILE_SIZE = HEADER_SIZE + 100

    // Version numbers
    static let VERSION_0 = 0
    static let VERSION_2 = 2
    static let VERSION_3 = 3

    /// Check if data looks like a MacPaint file
    static func isMacPaint(_ data: Data) -> Bool {
        guard data.count >= MIN_FILE_SIZE else { return false }

        // Check version number (big-endian 32-bit)
        let version = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 |
                      UInt32(data[2]) << 8 | UInt32(data[3])

        // Valid versions are 0, 2, or 3
        if version != 0 && version != 2 && version != 3 {
            return false
        }

        // PackBits never grows a row by more than one byte
        guard data.count <= HEADER_SIZE + IMAGE_HEIGHT * (ROW_STRIDE + 1) + HEADER_SIZE else { return false }

        // Every one of the 720 rows must decode from the data that is there
        var testOutput = [UInt8](repeating: 0, count: ROW_STRIDE)
        var srcOffset = HEADER_SIZE

        for _ in 0..<IMAGE_HEIGHT {
            guard srcOffset < data.count else { return false }
            let result = unpackBitsRow(
                data: data,
                srcOffset: srcOffset,
                dstBuffer: &testOutput,
                dstOffset: 0,
                dstLength: ROW_STRIDE
            )
            if result < 0 { return false }
            srcOffset = result
        }

        return true
    }

    /// Decode MacPaint file to CGImage
    static func decode(_ data: Data) -> CGImage? {
        guard data.count >= MIN_FILE_SIZE else { return nil }

        // Decompress the bitmap data
        var bitmap = [UInt8](repeating: 0, count: UNCOMPRESSED_SIZE)
        var srcOffset = HEADER_SIZE
        var dstOffset = 0

        for _ in 0..<IMAGE_HEIGHT {
            let result = unpackBitsRow(
                data: data,
                srcOffset: srcOffset,
                dstBuffer: &bitmap,
                dstOffset: dstOffset,
                dstLength: ROW_STRIDE
            )
            if result < 0 {
                // Error decompressing - fill rest with white
                for i in dstOffset..<UNCOMPRESSED_SIZE {
                    bitmap[i] = 0
                }
                break
            }
            srcOffset = result
            dstOffset += ROW_STRIDE
        }

        // Convert 1-bit bitmap to 8-bit grayscale for CGImage
        var pixels = [UInt8](repeating: 255, count: IMAGE_WIDTH * IMAGE_HEIGHT)

        for row in 0..<IMAGE_HEIGHT {
            for col in 0..<IMAGE_WIDTH {
                let byteIndex = row * ROW_STRIDE + col / 8
                let bitIndex = 7 - (col % 8)  // MSB is leftmost pixel

                let bit = (bitmap[byteIndex] >> bitIndex) & 1
                let pixelIndex = row * IMAGE_WIDTH + col

                // 1 = black, 0 = white (MacPaint convention)
                pixels[pixelIndex] = bit == 1 ? 0 : 255
            }
        }

        // Create CGImage from a copy of the pixels that the image owns
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }

        return CGImage(
            width: IMAGE_WIDTH,
            height: IMAGE_HEIGHT,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: IMAGE_WIDTH,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Unpack a single row using PackBits decompression
    /// Returns new source offset, or -1 on error
    private static func unpackBitsRow(
        data: Data,
        srcOffset: Int,
        dstBuffer: inout [UInt8],
        dstOffset: Int,
        dstLength: Int
    ) -> Int {
        var src = srcOffset
        var dst = dstOffset
        let dstEnd = dstOffset + dstLength

        while dst < dstEnd && src < data.count {
            let flagByte = Int8(bitPattern: data[src])
            src += 1

            if flagByte == -128 {
                // Reserved, skip
                continue
            } else if flagByte < 0 {
                // Run-length encoded: repeat next byte (1 - flagByte) times
                let count = 1 - Int(flagByte)
                guard src < data.count else { return -1 }
                let value = data[src]
                src += 1

                for _ in 0..<count {
                    if dst < dstEnd && dst < dstBuffer.count {
                        dstBuffer[dst] = value
                        dst += 1
                    }
                }
            } else {
                // Literal bytes: copy (flagByte + 1) bytes
                let count = Int(flagByte) + 1
                for _ in 0..<count {
                    if src < data.count && dst < dstEnd && dst < dstBuffer.count {
                        dstBuffer[dst] = data[src]
                        src += 1
                        dst += 1
                    }
                }
            }
        }

        // Pad remaining bytes with 0 (white)
        while dst < dstEnd && dst < dstBuffer.count {
            dstBuffer[dst] = 0
            dst += 1
        }

        return src
    }

    /// Get pattern data from header (for version 2 files)
    static func getPatterns(_ data: Data) -> [[UInt8]]? {
        guard data.count >= HEADER_SIZE else { return nil }

        // Check version
        let version = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 |
                      UInt32(data[2]) << 8 | UInt32(data[3])

        guard version == 2 else { return nil }

        // Extract 38 patterns, 8 bytes each
        var patterns: [[UInt8]] = []
        for i in 0..<38 {
            let offset = 4 + (i * 8)
            var pattern = [UInt8](repeating: 0, count: 8)
            for j in 0..<8 {
                pattern[j] = data[offset + j]
            }
            patterns.append(pattern)
        }

        return patterns
    }
}

// MARK: - PackBits Compression (for writing)

extension MacPaintDecoder {

    /// Compress a row using PackBits
    static func packBitsRow(_ row: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var i = 0

        while i < row.count {
            // Look for a run of identical bytes
            var runLength = 1
            while i + runLength < row.count &&
                  runLength < 128 &&
                  row[i + runLength] == row[i] {
                runLength += 1
            }

            if runLength >= 3 {
                // Encode as run
                output.append(UInt8(bitPattern: Int8(1 - runLength)))
                output.append(row[i])
                i += runLength
            } else {
                // Look for literal sequence
                let literalStart = i
                var literalLength = 0

                while i < row.count && literalLength < 128 {
                    // Check if next bytes would be better as a run
                    var nextRunLen = 1
                    while i + nextRunLen < row.count &&
                          nextRunLen < 128 &&
                          row[i + nextRunLen] == row[i] {
                        nextRunLen += 1
                    }

                    if nextRunLen >= 3 {
                        break
                    }

                    literalLength += 1
                    i += 1
                }

                if literalLength > 0 {
                    output.append(UInt8(literalLength - 1))
                    for j in 0..<literalLength {
                        output.append(row[literalStart + j])
                    }
                }
            }
        }

        return output
    }
}
