//
//  GzipZipArchive.swift
//  ProBrowse
//
//  Support for gzip (.gz) and zip (.zip) archive reading
//  Uses built-in Compression framework for gzip
//  Uses native ZIP parsing for zip files
//

import Foundation
import Compression

// MARK: - Gzip Support

class GzipArchive {

    /// Magic number for gzip
    static let GZIP_MAGIC: [UInt8] = [0x1F, 0x8B]

    /// Check if data is gzip compressed
    static func isGzip(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == GZIP_MAGIC[0] && data[1] == GZIP_MAGIC[1]
    }

    /// Check if file has gzip extension
    static func isGzipExtension(_ ext: String) -> Bool {
        return ext.lowercased() == "gz" || ext.lowercased() == "gzip"
    }

    /// Decompress gzip data
    static func decompress(_ data: Data) -> Data? {
        guard isGzip(data) else { return nil }
        guard data.count >= 10 else { return nil }

        // Parse gzip header
        // Bytes 0-1: Magic number
        // Byte 2: Compression method (must be 8 for deflate)
        // Byte 3: Flags
        // Bytes 4-7: Modification time
        // Byte 8: Extra flags
        // Byte 9: OS

        let compressionMethod = data[2]
        guard compressionMethod == 8 else {
            print("Gzip: Unsupported compression method \(compressionMethod)")
            return nil
        }

        let flags = data[3]
        var offset = 10

        // FEXTRA: Extra field present
        if (flags & 0x04) != 0 {
            guard offset + 2 <= data.count else { return nil }
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
        }

        // FNAME: Original filename present
        if (flags & 0x08) != 0 {
            while offset < data.count && data[offset] != 0 {
                offset += 1
            }
            offset += 1  // Skip null terminator
        }

        // FCOMMENT: Comment present
        if (flags & 0x10) != 0 {
            while offset < data.count && data[offset] != 0 {
                offset += 1
            }
            offset += 1  // Skip null terminator
        }

        // FHCRC: Header CRC present
        if (flags & 0x02) != 0 {
            offset += 2
        }

        guard offset < data.count - 8 else { return nil }

        // Compressed data is from offset to data.count - 8
        // (last 8 bytes are CRC32 + original size)
        let compressedData = data.subdata(in: offset..<(data.count - 8))

        // Original size from last 4 bytes
        let origSize = Int(data[data.count - 4]) |
                      (Int(data[data.count - 3]) << 8) |
                      (Int(data[data.count - 2]) << 16) |
                      (Int(data[data.count - 1]) << 24)

        // Decompress using Compression framework
        return decompressDeflate(compressedData, expectedSize: origSize)
    }

    /// Largest result the decompressors will produce. These archives hold Apple II
    /// disk images; a bigger size in a header is damage or a decompression bomb.
    static let maxDecompressedSize = 64 * 1024 * 1024

    /// Decompress raw deflate data
    static func decompressDeflate(_ data: Data, expectedSize: Int) -> Data? {
        // The size in the header is untrusted, so the buffer is capped
        let capacity = min(max(expectedSize, data.count * 10), maxDecompressedSize)
        guard capacity > 0 else { return nil }
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let sourceBaseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                capacity,
                sourceBaseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        if decompressedSize > 0 {
            return Data(bytes: destinationBuffer, count: decompressedSize)
        }

        return nil
    }
}

// MARK: - ZIP Support

class ZipArchive {

    /// Magic numbers for ZIP
    static let ZIP_LOCAL_HEADER: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    static let ZIP_CENTRAL_HEADER: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
    static let ZIP_END_OF_CENTRAL: [UInt8] = [0x50, 0x4B, 0x05, 0x06]

    /// ZIP entry
    struct ZipEntry {
        let filename: String
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let compressionMethod: UInt16
        let dataOffset: Int
        let crc32: UInt32
        let modificationTime: Date?
    }

    /// Check if data is a ZIP archive
    static func isZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == ZIP_LOCAL_HEADER[0] &&
               data[1] == ZIP_LOCAL_HEADER[1] &&
               data[2] == ZIP_LOCAL_HEADER[2] &&
               data[3] == ZIP_LOCAL_HEADER[3]
    }

    /// Check if file has zip extension
    static func isZipExtension(_ ext: String) -> Bool {
        return ext.lowercased() == "zip"
    }

    /// Parse ZIP archive and return list of entries.
    /// The central directory is used when present: archives written as a stream
    /// (Finder, ditto) leave the sizes in the local headers at zero.
    static func parseEntries(from data: Data) -> [ZipEntry] {
        return parseCentralDirectory(data) ?? parseLocalHeaders(data)
    }

    private static func parseCentralDirectory(_ data: Data) -> [ZipEntry]? {
        // The end-of-central-directory record sits at the end, before an optional comment
        guard data.count >= 22 else { return nil }
        var eocd = data.count - 22
        let searchLimit = max(0, data.count - 22 - 0xFFFF)
        while eocd >= searchLimit && !hasSignature(ZIP_END_OF_CENTRAL, in: data, at: eocd) {
            eocd -= 1
        }
        guard eocd >= searchLimit else { return nil }

        let entryCount = Int(readUInt16(data, offset: eocd + 10))
        var offset = Int(readUInt32(data, offset: eocd + 16))
        var entries: [ZipEntry] = []

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, hasSignature(ZIP_CENTRAL_HEADER, in: data, at: offset) else { return nil }

            let filenameLength = Int(readUInt16(data, offset: offset + 28))
            let extraLength = Int(readUInt16(data, offset: offset + 30))
            let commentLength = Int(readUInt16(data, offset: offset + 32))
            let localOffset = Int(readUInt32(data, offset: offset + 42))
            guard offset + 46 + filenameLength <= data.count,
                  localOffset + 30 <= data.count, hasSignature(ZIP_LOCAL_HEADER, in: data, at: localOffset) else { return nil }

            let filenameData = data.subdata(in: (offset + 46)..<(offset + 46 + filenameLength))
            // The local header has its own name and extra field lengths
            let dataOffset = localOffset + 30 + Int(readUInt16(data, offset: localOffset + 26)) + Int(readUInt16(data, offset: localOffset + 28))

            entries.append(ZipEntry(
                filename: String(data: filenameData, encoding: .utf8) ?? String(data: filenameData, encoding: .ascii) ?? "",
                compressedSize: readUInt32(data, offset: offset + 20),
                uncompressedSize: readUInt32(data, offset: offset + 24),
                compressionMethod: readUInt16(data, offset: offset + 10),
                dataOffset: dataOffset,
                crc32: readUInt32(data, offset: offset + 16),
                modificationTime: parseDOSDateTime(readUInt16(data, offset: offset + 14), readUInt16(data, offset: offset + 12))
            ))

            offset += 46 + filenameLength + extraLength + commentLength
        }

        return entries
    }

    private static func hasSignature(_ signature: [UInt8], in data: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset + 4 <= data.count else { return false }
        return (0..<4).allSatisfy { data[offset + $0] == signature[$0] }
    }

    /// Fallback for archives without a readable central directory
    private static func parseLocalHeaders(_ data: Data) -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var offset = 0

        while offset + 30 <= data.count {
            // Check for local file header signature
            guard data[offset] == ZIP_LOCAL_HEADER[0] &&
                  data[offset + 1] == ZIP_LOCAL_HEADER[1] &&
                  data[offset + 2] == ZIP_LOCAL_HEADER[2] &&
                  data[offset + 3] == ZIP_LOCAL_HEADER[3] else {
                break
            }

            // Parse local file header
            let compressionMethod = readUInt16(data, offset: offset + 8)
            let modTime = readUInt16(data, offset: offset + 10)
            let modDate = readUInt16(data, offset: offset + 12)
            let crc32 = readUInt32(data, offset: offset + 14)
            let compressedSize = readUInt32(data, offset: offset + 18)
            let uncompressedSize = readUInt32(data, offset: offset + 22)
            let filenameLength = Int(readUInt16(data, offset: offset + 26))
            let extraLength = Int(readUInt16(data, offset: offset + 28))

            // Read filename
            let filenameStart = offset + 30
            let filenameEnd = min(filenameStart + filenameLength, data.count)
            let filenameData = data.subdata(in: filenameStart..<filenameEnd)
            let filename = String(data: filenameData, encoding: .utf8) ??
                          String(data: filenameData, encoding: .ascii) ?? ""

            // Data offset
            let dataOffset = filenameEnd + extraLength
            guard dataOffset <= data.count else { break }

            // Parse DOS time/date
            let modificationTime = parseDOSDateTime(modDate, modTime)

            let entry = ZipEntry(
                filename: filename,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                compressionMethod: compressionMethod,
                dataOffset: dataOffset,
                crc32: crc32,
                modificationTime: modificationTime
            )
            entries.append(entry)

            // Move to next entry
            offset = dataOffset + Int(compressedSize)
        }

        return entries
    }

    /// Extract a specific entry from a ZIP archive
    static func extractEntry(_ entry: ZipEntry, from data: Data) -> Data? {
        guard entry.dataOffset >= 0, entry.dataOffset <= data.count else { return nil }
        let compressedData = data.subdata(
            in: entry.dataOffset..<min(entry.dataOffset + Int(entry.compressedSize), data.count)
        )

        switch entry.compressionMethod {
        case 0:  // Stored (no compression)
            return compressedData

        case 8:  // Deflate
            return GzipArchive.decompressDeflate(compressedData, expectedSize: Int(entry.uncompressedSize))

        default:
            print("ZIP: Unsupported compression method \(entry.compressionMethod)")
            return nil
        }
    }

    /// Extract first file from ZIP archive (convenience method)
    static func extractFirst(from data: Data) -> (filename: String, data: Data)? {
        let entries = parseEntries(from: data)

        // Find first non-directory entry
        for entry in entries {
            if !entry.filename.hasSuffix("/") && entry.uncompressedSize > 0 {
                if let extracted = extractEntry(entry, from: data) {
                    return (entry.filename, extracted)
                }
            }
        }

        return nil
    }

    /// Extract all files from ZIP archive
    static func extractAll(from data: Data) -> [(filename: String, data: Data)] {
        let entries = parseEntries(from: data)
        var results: [(String, Data)] = []

        for entry in entries {
            if !entry.filename.hasSuffix("/") {
                if let extracted = extractEntry(entry, from: data) {
                    results.append((entry.filename, extracted))
                }
            }
        }

        return results
    }

    // MARK: - Helpers

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return UInt32(data[offset]) |
               (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) |
               (UInt32(data[offset + 3]) << 24)
    }

    private static func parseDOSDateTime(_ date: UInt16, _ time: UInt16) -> Date? {
        let year = Int((date >> 9) & 0x7F) + 1980
        let month = Int((date >> 5) & 0x0F)
        let day = Int(date & 0x1F)
        let hour = Int((time >> 11) & 0x1F)
        let minute = Int((time >> 5) & 0x3F)
        let second = Int((time & 0x1F) * 2)

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        return Calendar.current.date(from: components)
    }
}
