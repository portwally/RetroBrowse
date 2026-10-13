//
//  NuFXArchive.swift
//  ProBrowse
//
//  Native NuFX/ShrinkIt archive implementation
//  Based on CiderPress2 implementation and NuFX specification
//

import Foundation

// MARK: - NuFX Constants

enum NuFXConstants {
    // Archive signatures
    // Both signatures alternate low and high ASCII
    static let MASTER_SIGNATURE: [UInt8] = [0x4E, 0xF5, 0x46, 0xE9, 0x6C, 0xE5]  // "NuFile"
    static let RECORD_SIGNATURE: [UInt8] = [0x4E, 0xF5, 0x46, 0xD8]  // "NuFX"

    // Header sizes
    static let MASTER_HEADER_SIZE = 48
    static let RECORD_HEADER_MIN_SIZE = 56
    static let THREAD_HEADER_SIZE = 16

    // Thread classes
    static let THREAD_CLASS_MESSAGE: UInt16 = 0
    static let THREAD_CLASS_CONTROL: UInt16 = 1
    static let THREAD_CLASS_DATA: UInt16 = 2
    static let THREAD_CLASS_FILENAME: UInt16 = 3

    // Thread kinds
    static let THREAD_KIND_DATA_FORK: UInt16 = 0
    static let THREAD_KIND_DISK_IMAGE: UInt16 = 1
    static let THREAD_KIND_RESOURCE_FORK: UInt16 = 2
    static let THREAD_KIND_FILENAME: UInt16 = 0

    // Compression formats
    static let FORMAT_UNCOMPRESSED: UInt16 = 0
    static let FORMAT_SQUEEZE: UInt16 = 1
    static let FORMAT_LZW1: UInt16 = 2
    static let FORMAT_LZW2: UInt16 = 3
    static let FORMAT_LZC12: UInt16 = 4
    static let FORMAT_LZC16: UInt16 = 5
    static let FORMAT_DEFLATE: UInt16 = 6

    // Filesystem IDs
    static let FS_PRODOS: UInt16 = 1
    static let FS_DOS33: UInt16 = 2
    static let FS_HFS: UInt16 = 6
}

// MARK: - NuFX Error Types

enum NuFXError: Error {
    case invalidSignature
    case invalidHeader
    case invalidRecord
    case checksumMismatch
    case decompressionFailed
    case unsupportedCompression
    case dataCorrupted
}

// MARK: - NuFX Master Header

struct NuFXMasterHeader {
    let crc: UInt16
    let totalRecords: UInt32
    let creationDate: Date?
    let modificationDate: Date?
    let masterVersion: UInt16
    let archiveEOF: UInt32

    static func parse(from data: Data) -> NuFXMasterHeader? {
        guard data.count >= NuFXConstants.MASTER_HEADER_SIZE else { return nil }

        // Check signature
        for i in 0..<6 {
            if data[i] != NuFXConstants.MASTER_SIGNATURE[i] {
                return nil
            }
        }

        let crc = UInt16(data[6]) | (UInt16(data[7]) << 8)
        let totalRecords = UInt32(data[8]) | (UInt32(data[9]) << 8) |
                          (UInt32(data[10]) << 16) | (UInt32(data[11]) << 24)
        let creationDate = parseProDOSDate(data, offset: 12)
        let modificationDate = parseProDOSDate(data, offset: 20)
        let masterVersion = UInt16(data[28]) | (UInt16(data[29]) << 8)
        let archiveEOF = UInt32(data[38]) | (UInt32(data[39]) << 8) |
                        (UInt32(data[40]) << 16) | (UInt32(data[41]) << 24)

        return NuFXMasterHeader(
            crc: crc,
            totalRecords: totalRecords,
            creationDate: creationDate,
            modificationDate: modificationDate,
            masterVersion: masterVersion,
            archiveEOF: archiveEOF
        )
    }
}

// MARK: - NuFX Thread Header

struct NuFXThreadHeader {
    let threadClass: UInt16
    let threadFormat: UInt16
    let threadKind: UInt16
    let threadCRC: UInt16
    let threadEOF: UInt32      // Uncompressed size
    let compThreadEOF: UInt32  // Compressed size in archive
    var fileOffset: Int = 0    // Position in file

    static func parse(from data: Data, offset: Int) -> NuFXThreadHeader? {
        guard offset + NuFXConstants.THREAD_HEADER_SIZE <= data.count else { return nil }

        return NuFXThreadHeader(
            threadClass: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8),
            threadFormat: UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8),
            threadKind: UInt16(data[offset + 4]) | (UInt16(data[offset + 5]) << 8),
            threadCRC: UInt16(data[offset + 6]) | (UInt16(data[offset + 7]) << 8),
            threadEOF: UInt32(data[offset + 8]) | (UInt32(data[offset + 9]) << 8) |
                      (UInt32(data[offset + 10]) << 16) | (UInt32(data[offset + 11]) << 24),
            compThreadEOF: UInt32(data[offset + 12]) | (UInt32(data[offset + 13]) << 8) |
                          (UInt32(data[offset + 14]) << 16) | (UInt32(data[offset + 15]) << 24)
        )
    }

    var isDataFork: Bool {
        threadClass == NuFXConstants.THREAD_CLASS_DATA &&
        threadKind == NuFXConstants.THREAD_KIND_DATA_FORK
    }

    var isResourceFork: Bool {
        threadClass == NuFXConstants.THREAD_CLASS_DATA &&
        threadKind == NuFXConstants.THREAD_KIND_RESOURCE_FORK
    }

    var isFilename: Bool {
        threadClass == NuFXConstants.THREAD_CLASS_FILENAME
    }

    var isDiskImage: Bool {
        threadClass == NuFXConstants.THREAD_CLASS_DATA &&
        threadKind == NuFXConstants.THREAD_KIND_DISK_IMAGE
    }
}

// MARK: - NuFX Record (File Entry)

struct NuFXRecord {
    let headerCRC: UInt16
    let attribCount: UInt16
    let recordVersion: UInt16
    let numThreads: UInt32
    let filesystemID: UInt16
    let separatorChar: UInt8
    let accessFlags: UInt8
    let fileType: UInt32
    let auxType: UInt32
    let storageType: UInt16
    let creationDate: Date?
    let modificationDate: Date?
    let archiveDate: Date?
    var filename: String = ""
    var threads: [NuFXThreadHeader] = []
    var headerOffset: Int = 0

    static func parse(from data: Data, offset: Int) -> (record: NuFXRecord, nextOffset: Int)? {
        guard offset + NuFXConstants.RECORD_HEADER_MIN_SIZE <= data.count else { return nil }

        // Check signature
        for i in 0..<4 {
            if data[offset + i] != NuFXConstants.RECORD_SIGNATURE[i] {
                return nil
            }
        }

        let headerCRC = UInt16(data[offset + 4]) | (UInt16(data[offset + 5]) << 8)
        let attribCount = UInt16(data[offset + 6]) | (UInt16(data[offset + 7]) << 8)
        let recordVersion = UInt16(data[offset + 8]) | (UInt16(data[offset + 9]) << 8)
        let numThreads = UInt32(data[offset + 10]) | (UInt32(data[offset + 11]) << 8) |
                        (UInt32(data[offset + 12]) << 16) | (UInt32(data[offset + 13]) << 24)
        let filesystemID = UInt16(data[offset + 14]) | (UInt16(data[offset + 15]) << 8)
        let separatorChar = data[offset + 16]
        let accessFlags = data[offset + 18]
        let fileType = UInt32(data[offset + 22]) | (UInt32(data[offset + 23]) << 8) |
                      (UInt32(data[offset + 24]) << 16) | (UInt32(data[offset + 25]) << 24)
        let auxType = UInt32(data[offset + 26]) | (UInt32(data[offset + 27]) << 8) |
                     (UInt32(data[offset + 28]) << 16) | (UInt32(data[offset + 29]) << 24)
        let storageType = UInt16(data[offset + 30]) | (UInt16(data[offset + 31]) << 8)
        let creationDate = parseProDOSDate(data, offset: offset + 32)
        let modificationDate = parseProDOSDate(data, offset: offset + 40)
        let archiveDate = parseProDOSDate(data, offset: offset + 48)

        // attrib_count is the offset of the (deprecated) in-header filename. The two
        // bytes before it hold that filename's length, and the thread headers follow it.
        var filename = ""
        let filenameOffset = offset + Int(attribCount)
        guard attribCount >= NuFXConstants.RECORD_HEADER_MIN_SIZE, filenameOffset <= data.count else { return nil }
        let filenameLength = Int(data[filenameOffset - 2]) | (Int(data[filenameOffset - 1]) << 8)
        guard filenameOffset + filenameLength <= data.count else { return nil }
        if filenameLength > 0 {
            filename = decodeName(data[filenameOffset..<(filenameOffset + filenameLength)])
        }

        // Parse thread headers
        var threads: [NuFXThreadHeader] = []
        var threadOffset = filenameOffset + filenameLength

        for _ in 0..<numThreads {
            guard let thread = NuFXThreadHeader.parse(from: data, offset: threadOffset) else {
                break
            }
            threadOffset += NuFXConstants.THREAD_HEADER_SIZE
            threads.append(thread)
        }

        // Calculate file data offset and update thread file offsets
        var dataOffset = threadOffset
        for i in 0..<threads.count {
            threads[i].fileOffset = dataOffset
            dataOffset += Int(threads[i].compThreadEOF)

            // If this is a filename thread, extract the filename
            if threads[i].isFilename && threads[i].threadEOF > 0 {
                let fnStart = threads[i].fileOffset
                let fnEnd = min(fnStart + Int(threads[i].threadEOF), data.count)
                if fnEnd > fnStart {
                    let extracted = decodeName(data[fnStart..<fnEnd])
                    if !extracted.isEmpty {
                        filename = extracted
                    }
                }
            }
        }

        let record = NuFXRecord(
            headerCRC: headerCRC,
            attribCount: attribCount,
            recordVersion: recordVersion,
            numThreads: numThreads,
            filesystemID: filesystemID,
            separatorChar: separatorChar,
            accessFlags: accessFlags,
            fileType: fileType,
            auxType: auxType,
            storageType: storageType,
            creationDate: creationDate,
            modificationDate: modificationDate,
            archiveDate: archiveDate,
            filename: filename,
            threads: threads,
            headerOffset: offset
        )

        return (record, dataOffset)
    }

    /// Filenames are low ASCII, sometimes with the high bit set, padded with NULs
    private static func decodeName(_ bytes: Data) -> String {
        let characters = bytes.map { $0 & 0x7F }.filter { $0 >= 0x20 }
        return String(decoding: characters, as: UTF8.self)
    }

    /// Size of the disk in a disk image thread. The thread's own EOF field is
    /// unreliable there; the record gives the block count and block size instead.
    var diskImageSize: Int {
        return Int(auxType) * Int(storageType)
    }

    var fileTypeString: String {
        ProDOSFileTypeInfo.getFileTypeInfo(fileType: UInt8(fileType & 0xFF), auxType: UInt16(auxType & 0xFFFF)).shortName
    }

    /// Get the data fork thread
    var dataForkThread: NuFXThreadHeader? {
        threads.first { $0.isDataFork }
    }

    /// Get the resource fork thread
    var resourceForkThread: NuFXThreadHeader? {
        threads.first { $0.isResourceFork }
    }
}

// MARK: - NuFX Archive

class NuFXArchive {
    let data: Data
    var masterHeader: NuFXMasterHeader?
    var records: [NuFXRecord] = []
    var wrapperOffset: Int = 0  // Offset to NuFX data (for Binary II wrapped files)

    init(data: Data) {
        self.data = data
    }

    /// Check if data looks like a NuFX archive
    static func isNuFXArchive(_ data: Data) -> Bool {
        // Check for plain NuFX
        if data.count >= 6 {
            var isNuFX = true
            for i in 0..<6 {
                if data[i] != NuFXConstants.MASTER_SIGNATURE[i] {
                    isNuFX = false
                    break
                }
            }
            if isNuFX { return true }
        }

        // Check for Binary II wrapper (.bxy)
        if data.count >= 128 + 6 {
            if data[0] == 0x0A && data[1] == 0x47 && data[2] == 0x4C {
                // Binary II signature
                var isNuFX = true
                for i in 0..<6 {
                    if data[128 + i] != NuFXConstants.MASTER_SIGNATURE[i] {
                        isNuFX = false
                        break
                    }
                }
                if isNuFX { return true }
            }
        }

        return false
    }

    /// Parse the archive
    func parse() throws {
        // Find NuFX data start (check for wrappers)
        wrapperOffset = 0

        // Check for Binary II wrapper
        if data.count >= 128 + 6 &&
           data[0] == 0x0A && data[1] == 0x47 && data[2] == 0x4C {
            wrapperOffset = 128
        }

        // Parse master header
        let headerData = data.subdata(in: wrapperOffset..<min(wrapperOffset + NuFXConstants.MASTER_HEADER_SIZE, data.count))
        guard let header = NuFXMasterHeader.parse(from: headerData) else {
            throw NuFXError.invalidSignature
        }
        masterHeader = header

        // Parse records
        var offset = wrapperOffset + NuFXConstants.MASTER_HEADER_SIZE
        var recordCount = 0

        while offset < data.count && recordCount < header.totalRecords {
            guard let result = NuFXRecord.parse(from: data, offset: offset) else {
                break
            }
            records.append(result.record)
            offset = result.nextOffset
            recordCount += 1
        }
    }

    /// Extract file data from a record
    func extractData(for record: NuFXRecord) throws -> Data {
        guard let thread = record.dataForkThread ?? record.threads.first(where: { $0.isDiskImage }) else {
            return Data()
        }

        return try extractThread(thread, of: record)
    }

    /// Largest thread this reader will expand. NuFX holds Apple II files and
    /// disk images; anything bigger is a damaged or hostile header.
    static let maxThreadSize = 64 * 1024 * 1024

    /// Extract a specific thread's data
    func extractThread(_ thread: NuFXThreadHeader, of record: NuFXRecord) throws -> Data {
        guard thread.fileOffset >= 0, thread.fileOffset <= data.count else {
            throw NuFXError.dataCorrupted
        }
        let compData = data.subdata(in: thread.fileOffset..<min(thread.fileOffset + Int(thread.compThreadEOF), data.count))

        let isSizedByRecord = thread.isDiskImage && record.diskImageSize > 0
        let expectedSize = isSizedByRecord ? record.diskImageSize : Int(thread.threadEOF)
        guard expectedSize <= NuFXArchive.maxThreadSize else {
            throw NuFXError.dataCorrupted
        }

        // An empty file has no compressed stream at all
        if expectedSize == 0 {
            return Data()
        }

        let output: Data
        switch thread.threadFormat {
        case NuFXConstants.FORMAT_UNCOMPRESSED:
            output = compData.prefix(expectedSize)

        case NuFXConstants.FORMAT_LZW1:
            output = try NuFXLZW.decompressLZW1(compData, expectedSize: expectedSize)

        case NuFXConstants.FORMAT_LZW2:
            output = try NuFXLZW.decompressLZW2(compData, expectedSize: expectedSize)

        case NuFXConstants.FORMAT_SQUEEZE:
            output = try NuFXSqueeze.decompress(compData, expectedSize: expectedSize)

        default:
            throw NuFXError.unsupportedCompression
        }

        guard output.count == expectedSize else {
            throw NuFXError.decompressionFailed
        }

        // Version 3 records store a CRC of the uncompressed thread. It is not checked
        // for disk images, whose thread EOF field is not reliable.
        if record.recordVersion >= 3 && !thread.isDiskImage &&
           NuFXCRC.crc16(output, initialValue: 0xFFFF) != thread.threadCRC {
            throw NuFXError.checksumMismatch
        }

        return output
    }
}

// MARK: - ProDOS Date Parsing

private func parseProDOSDate(_ data: Data, offset: Int) -> Date? {
    guard offset + 4 <= data.count else { return nil }

    let datePart = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    let timePart = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)

    if datePart == 0 && timePart == 0 { return nil }

    let year = Int((datePart >> 9) & 0x7F)
    let month = Int((datePart >> 5) & 0x0F)
    let day = Int(datePart & 0x1F)
    let hour = Int((timePart >> 8) & 0x1F)
    let minute = Int(timePart & 0x3F)

    // ProDOS years are 0-99, assume 1940-2039 range
    let fullYear = year < 40 ? 2000 + year : 1900 + year

    var components = DateComponents()
    components.year = fullYear
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute

    return Calendar.current.date(from: components)
}

// MARK: - CRC-16/XMODEM

class NuFXCRC {
    static func crc16(_ data: Data, initialValue: UInt16 = 0) -> UInt16 {
        var crc = initialValue

        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }

        return crc
    }
}

// MARK: - LZW Decompression

class NuFXLZW {

    static let LZW_START_BITS = 9
    static let LZW_MAX_BITS = 12
    static let LZW_TABLE_CLEAR = 0x0100
    static let LZW_FIRST_CODE = 0x0101
    static let CHUNK_SIZE = 4096

    /// Decompress LZW/1 format (older P8 ShrinkIt)
    static func decompressLZW1(_ data: Data, expectedSize: Int) throws -> Data {
        var output = Data()
        var offset = 0

        // LZW/1 has a 4-byte header: CRC (2) + volume (1) + RLE delimiter (1)
        guard data.count >= 4 else {
            throw NuFXError.decompressionFailed
        }

        let rleDelim = data[3]
        offset = 4

        while output.count < expectedSize && offset < data.count {
            // Read chunk header
            guard offset + 3 <= data.count else { break }

            let rleLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            let lzwFlag = data[offset + 2]
            offset += 3

            // Decompress this chunk
            var chunkData: Data

            if lzwFlag != 0 {
                // LZW compressed
                // LZW/1 starts each chunk with a fresh table and yields rleLen bytes
                let (decompressed, bytesUsed) = try LZWDecompressor().decompress(data, from: offset, maxOutput: rleLen)
                chunkData = decompressed
                offset += bytesUsed
            } else if rleLen == CHUNK_SIZE {
                // Uncompressed
                chunkData = Data(data[offset..<min(offset + CHUNK_SIZE, data.count)])
                offset += chunkData.count
            } else {
                // RLE only
                chunkData = Data(data[offset..<min(offset + rleLen, data.count)])
                offset += chunkData.count
            }

            // Expand RLE
            let expanded = expandRLE(chunkData, delimiter: rleDelim, targetSize: CHUNK_SIZE)
            output.append(expanded)
        }

        // Trim to expected size
        if output.count > expectedSize {
            output = output.prefix(expectedSize)
        }

        return output
    }

    /// Decompress LZW/2 format (GS/ShrinkIt standard)
    static func decompressLZW2(_ data: Data, expectedSize: Int) throws -> Data {
        var output = Data()
        var offset = 0

        // LZW/2 has a 2-byte header: volume (1) + RLE delimiter (1)
        guard data.count >= 2 else {
            throw NuFXError.decompressionFailed
        }

        let rleDelim = data[1]
        offset = 2

        // LZW/2 maintains table across chunks
        let lzwState = LZWDecompressor()

        while output.count < expectedSize && offset < data.count {
            // Read chunk header (2 bytes)
            guard offset + 2 <= data.count else { break }

            let header = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2

            let lzwFlag = (header & 0x8000) != 0
            let rleLen = header & 0x7FFF

            // A chunk stored without LZW starts the table over
            if !lzwFlag { lzwState.reset() }

            var chunkData: Data

            if lzwFlag {
                // Skip 2-byte compressed length field (unreliable)
                guard offset + 2 <= data.count else { break }
                offset += 2

                // LZW compressed
                let (decompressed, bytesUsed) = try lzwState.decompress(data, from: offset, maxOutput: rleLen)
                chunkData = decompressed
                offset += bytesUsed
            } else if rleLen == CHUNK_SIZE {
                // Uncompressed
                chunkData = Data(data[offset..<min(offset + CHUNK_SIZE, data.count)])
                offset += chunkData.count
            } else {
                // RLE only
                chunkData = Data(data[offset..<min(offset + rleLen, data.count)])
                offset += chunkData.count
            }

            // Expand RLE
            let expanded = expandRLE(chunkData, delimiter: rleDelim, targetSize: CHUNK_SIZE)
            output.append(expanded)
        }

        // Trim to expected size
        if output.count > expectedSize {
            output = output.prefix(expectedSize)
        }

        return output
    }

    /// Expand RLE encoded data
    private static func expandRLE(_ data: Data, delimiter: UInt8, targetSize: Int) -> Data {
        if data.count == targetSize {
            return data
        }

        var output = Data()
        var i = 0

        while i < data.count && output.count < targetSize {
            let byte = data[i]
            i += 1

            if byte == delimiter {
                guard i + 1 < data.count else { break }
                let value = data[i]
                let count = Int(data[i + 1]) + 1
                i += 2

                for _ in 0..<count {
                    output.append(value)
                    if output.count >= targetSize { break }
                }
            } else {
                output.append(byte)
            }
        }

        // Pad to target size
        while output.count < targetSize {
            output.append(0)
        }

        return output
    }

    /// LZW Decompressor state machine
    class LZWDecompressor {
        private var table: [[UInt8]] = []
        private var codeSize = LZW_START_BITS
        private var nextCode = LZW_FIRST_CODE
        // The previous code's string; LZW/2 carries it from one chunk to the next
        private var prevEntry: [UInt8]? = nil

        init() {
            reset()
        }

        func reset() {
            // Initialize table with single-byte entries
            table = (0..<256).map { [UInt8($0)] }
            // Reserve entries 256-257
            table.append([])  // 256 = clear
            table.append([])  // 257 = unused
            codeSize = LZW_START_BITS
            nextCode = LZW_FIRST_CODE
            prevEntry = nil
        }

        /// Decodes one chunk starting at `start`. Returns the output and the number of input bytes used.
        func decompress(_ data: Data, from start: Int, maxOutput: Int) throws -> (Data, Int) {
            var output = Data()
            var bitBuffer: UInt32 = 0
            var bitsInBuffer = 0
            var dataOffset = start

            while output.count < maxOutput && dataOffset < data.count {
                // Read bits into buffer
                while bitsInBuffer < codeSize && dataOffset < data.count {
                    bitBuffer |= UInt32(data[dataOffset]) << bitsInBuffer
                    bitsInBuffer += 8
                    dataOffset += 1
                }

                if bitsInBuffer < codeSize {
                    break
                }

                // Extract code
                let codeMask = (1 << codeSize) - 1
                let code = Int(bitBuffer) & codeMask
                bitBuffer >>= codeSize
                bitsInBuffer -= codeSize

                // Handle table clear
                if code == NuFXLZW.LZW_TABLE_CLEAR {
                    reset()
                    continue
                }

                // Get entry for this code
                var entry: [UInt8]

                if code < table.count && !table[code].isEmpty {
                    entry = table[code]
                } else if code == nextCode && prevEntry != nil {
                    // KwKwK case
                    entry = prevEntry! + [prevEntry![0]]
                } else {
                    // Invalid code
                    break
                }

                output.append(contentsOf: entry)

                // Add new entry to table
                if let prev = prevEntry {
                    let newEntry = prev + [entry[0]]
                    if nextCode < (1 << NuFXLZW.LZW_MAX_BITS) {
                        if nextCode < table.count {
                            table[nextCode] = newEntry
                        } else {
                            table.append(newEntry)
                        }
                        nextCode += 1

                        // The code width grows one entry before the table fills it
                        if nextCode + 1 >= (1 << codeSize) && codeSize < NuFXLZW.LZW_MAX_BITS {
                            codeSize += 1
                        }
                    }
                }

                prevEntry = entry
            }

            return (output.prefix(maxOutput), dataOffset - start)
        }
    }
}

// MARK: - Squeeze Decompression (Huffman)

class NuFXSqueeze {
    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        // Squeeze format: magic (2) + checksum (2) + filename + tree + data
        guard data.count >= 4 else {
            throw NuFXError.decompressionFailed
        }

        // Check magic
        if data[0] != 0x76 || data[1] != 0xFF {
            throw NuFXError.decompressionFailed
        }

        var offset = 4  // Skip magic and checksum

        // Skip filename (null-terminated)
        while offset < data.count && data[offset] != 0 {
            offset += 1
        }
        offset += 1  // Skip null

        // Read node count
        guard offset + 2 <= data.count else {
            throw NuFXError.decompressionFailed
        }
        let nodeCount = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        offset += 2

        // Read Huffman tree
        var tree: [(left: Int16, right: Int16)] = []
        for _ in 0..<nodeCount {
            guard offset + 4 <= data.count else {
                throw NuFXError.decompressionFailed
            }
            let left = Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
            let right = Int16(bitPattern: UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8))
            tree.append((left, right))
            offset += 4
        }

        // Decompress using Huffman tree. The decoded stream is still run-length
        // encoded, and a literal $90 takes two bytes, so allow twice the output size.
        var huffmanOutput = Data()
        var bitBuffer: UInt32 = 0
        var bitsInBuffer = 0
        let squeezeEOF = 256

        while huffmanOutput.count < expectedSize * 2 {
            var node = 0

            // Traverse tree
            while node >= 0 {
                // Get a bit
                if bitsInBuffer == 0 {
                    guard offset < data.count else { break }
                    bitBuffer = UInt32(data[offset])
                    offset += 1
                    bitsInBuffer = 8
                }

                let bit = bitBuffer & 1
                bitBuffer >>= 1
                bitsInBuffer -= 1

                // Follow tree (with bounds check for malformed archives)
                guard node >= 0 && node < tree.count else { break }
                if bit == 0 {
                    node = Int(tree[node].left)
                } else {
                    node = Int(tree[node].right)
                }
            }

            if node < 0 {
                // Leaf node - extract character
                let value = -(node + 1)
                if value == squeezeEOF { break }
                guard value < squeezeEOF else { throw NuFXError.decompressionFailed }
                huffmanOutput.append(UInt8(value))
            } else {
                break
            }
        }

        // Expand runs: <byte> $90 <count> repeats <byte> count times in total; $90 $00 is a literal $90
        var output = Data()
        var i = 0
        while i < huffmanOutput.count && output.count < expectedSize {
            let byte = huffmanOutput[i]
            i += 1
            guard byte == 0x90, i < huffmanOutput.count else {
                output.append(byte)
                continue
            }
            let count = Int(huffmanOutput[i])
            i += 1
            if count == 0 {
                output.append(0x90)
            } else if let last = output.last, count > 1 {
                output.append(contentsOf: [UInt8](repeating: last, count: min(count - 1, expectedSize - output.count)))
            }
        }

        return output
    }
}

// MARK: - NuFX Writer

class NuFXWriter {

    /// File to be added to archive
    struct FileEntry {
        let filename: String
        let data: Data
        let resourceFork: Data?
        let fileType: UInt8
        let auxType: UInt16
        let accessFlags: UInt8
        let creationDate: Date?
        let modificationDate: Date?
        let storageType: UInt16
        let isDiskImage: Bool

        init(filename: String, data: Data, resourceFork: Data? = nil,
             fileType: UInt8 = 0x06, auxType: UInt16 = 0,
             accessFlags: UInt8 = 0xE3, creationDate: Date? = nil,
             modificationDate: Date? = nil, storageType: UInt16 = 1,
             isDiskImage: Bool = false) {
            self.filename = filename
            self.data = data
            self.resourceFork = resourceFork
            self.fileType = fileType
            self.auxType = auxType
            self.accessFlags = accessFlags
            self.creationDate = creationDate ?? Date()
            self.modificationDate = modificationDate ?? Date()
            self.storageType = storageType
            self.isDiskImage = isDiskImage
        }
    }

    /// Create a NuFX archive from files
    static func createArchive(files: [FileEntry], compress: Bool = true) -> Data {
        var output = Data()

        // Master header
        let masterHeader = createMasterHeader(recordCount: UInt32(files.count))
        output.append(masterHeader)

        // Records
        for file in files {
            let recordData = createRecord(for: file, compress: compress)
            output.append(recordData)
        }

        // Update master header with correct EOF
        let archiveEOF = UInt32(output.count)
        output[38] = UInt8(archiveEOF & 0xFF)
        output[39] = UInt8((archiveEOF >> 8) & 0xFF)
        output[40] = UInt8((archiveEOF >> 16) & 0xFF)
        output[41] = UInt8((archiveEOF >> 24) & 0xFF)

        // Calculate and update master header CRC
        let headerCRC = NuFXCRC.crc16(output.subdata(in: 8..<48))
        output[6] = UInt8(headerCRC & 0xFF)
        output[7] = UInt8((headerCRC >> 8) & 0xFF)

        return output
    }

    /// Create a NuFX archive containing a single disk image
    static func createDiskImageArchive(diskData: Data, filename: String, compress: Bool = true) -> Data {
        let entry = FileEntry(
            filename: filename,
            data: diskData,
            fileType: 0xE0,  // LBR
            auxType: 0x8002, // SHK
            isDiskImage: true
        )
        return createArchive(files: [entry], compress: compress)
    }

    // MARK: - Header Creation

    private static func createMasterHeader(recordCount: UInt32) -> Data {
        var header = Data(count: NuFXConstants.MASTER_HEADER_SIZE)

        // Signature "NuFile"
        for (i, byte) in NuFXConstants.MASTER_SIGNATURE.enumerated() {
            header[i] = byte
        }

        // CRC placeholder (bytes 6-7, will be calculated later)
        header[6] = 0
        header[7] = 0

        // Total records
        header[8] = UInt8(recordCount & 0xFF)
        header[9] = UInt8((recordCount >> 8) & 0xFF)
        header[10] = UInt8((recordCount >> 16) & 0xFF)
        header[11] = UInt8((recordCount >> 24) & 0xFF)

        // Creation date (bytes 12-19)
        let now = Date()
        writeProDOSDate(&header, offset: 12, date: now)

        // Modification date (bytes 20-27)
        writeProDOSDate(&header, offset: 20, date: now)

        // Master version (bytes 28-29)
        header[28] = 0  // Version 0
        header[29] = 0

        // Reserved (bytes 30-37)
        // Already zero

        // Master EOF placeholder (bytes 38-41, will be calculated later)
        // Already zero

        // Reserved (bytes 42-47)
        // Already zero

        return header
    }

    private static func createRecord(for file: FileEntry, compress: Bool) -> Data {
        var record = Data()

        // Compress data if requested
        let compressedData: Data
        let compressedResourceFork: Data?
        var dataFormat: UInt16 = NuFXConstants.FORMAT_UNCOMPRESSED
        var resourceFormat: UInt16 = NuFXConstants.FORMAT_UNCOMPRESSED

        if compress && file.data.count > 0 {
            let compressed = compressLZW2(file.data)
            if compressed.count < file.data.count {
                compressedData = compressed
                dataFormat = NuFXConstants.FORMAT_LZW2
            } else {
                compressedData = file.data
            }
        } else {
            compressedData = file.data
        }

        if let resourceData = file.resourceFork, compress && resourceData.count > 0 {
            let compressed = compressLZW2(resourceData)
            if compressed.count < resourceData.count {
                compressedResourceFork = compressed
                resourceFormat = NuFXConstants.FORMAT_LZW2
            } else {
                compressedResourceFork = resourceData
            }
        } else {
            compressedResourceFork = file.resourceFork
        }

        // Count threads: filename + data + optional resource fork
        var threadCount: UInt32 = 2  // filename + data fork
        if compressedResourceFork != nil {
            threadCount += 1
        }

        // Record header (56 bytes fixed)
        var header = Data(count: 56)

        // Signature "NuFX"
        for (i, byte) in NuFXConstants.RECORD_SIGNATURE.enumerated() {
            header[i] = byte
        }

        // Header CRC placeholder (bytes 4-5)
        header[4] = 0
        header[5] = 0

        // Attrib count (bytes 6-7) - fixed at 56 for version 3
        header[6] = 56
        header[7] = 0

        // Version number (bytes 8-9)
        header[8] = 3  // Version 3
        header[9] = 0

        // Total threads (bytes 10-13)
        header[10] = UInt8(threadCount & 0xFF)
        header[11] = UInt8((threadCount >> 8) & 0xFF)
        header[12] = UInt8((threadCount >> 16) & 0xFF)
        header[13] = UInt8((threadCount >> 24) & 0xFF)

        // Filesystem ID (bytes 14-15)
        header[14] = UInt8(NuFXConstants.FS_PRODOS & 0xFF)
        header[15] = UInt8((NuFXConstants.FS_PRODOS >> 8) & 0xFF)

        // Filesystem separator (byte 16)
        header[16] = 0x2F  // '/'

        // Filesystem reserved (byte 17)
        header[17] = 0

        // Access (bytes 18-21)
        header[18] = file.accessFlags
        header[19] = 0
        header[20] = 0
        header[21] = 0

        // File type (bytes 22-25)
        header[22] = file.fileType
        header[23] = 0
        header[24] = 0
        header[25] = 0

        // Aux type (bytes 26-29)
        header[26] = UInt8(file.auxType & 0xFF)
        header[27] = UInt8((file.auxType >> 8) & 0xFF)
        header[28] = 0
        header[29] = 0

        // Storage type (bytes 30-31)
        header[30] = UInt8(file.storageType & 0xFF)
        header[31] = UInt8((file.storageType >> 8) & 0xFF)

        // Creation date (bytes 32-39)
        if let date = file.creationDate {
            writeProDOSDate(&header, offset: 32, date: date)
        }

        // Modification date (bytes 40-47)
        if let date = file.modificationDate {
            writeProDOSDate(&header, offset: 40, date: date)
        }

        // Archive date (bytes 48-55)
        writeProDOSDate(&header, offset: 48, date: Date())

        record.append(header)

        // Thread headers (16 bytes each)

        // Filename thread
        let filenameData = file.filename.data(using: .ascii) ?? Data()
        let filenameThread = createThreadHeader(
            threadClass: NuFXConstants.THREAD_CLASS_FILENAME,
            threadFormat: NuFXConstants.FORMAT_UNCOMPRESSED,
            threadKind: NuFXConstants.THREAD_KIND_FILENAME,
            threadEOF: UInt32(filenameData.count),
            compThreadEOF: UInt32(filenameData.count)
        )
        record.append(filenameThread)

        // Data fork thread
        let dataThread = createThreadHeader(
            threadClass: NuFXConstants.THREAD_CLASS_DATA,
            threadFormat: dataFormat,
            threadKind: file.isDiskImage ? NuFXConstants.THREAD_KIND_DISK_IMAGE : NuFXConstants.THREAD_KIND_DATA_FORK,
            threadEOF: UInt32(file.data.count),
            compThreadEOF: UInt32(compressedData.count)
        )
        record.append(dataThread)

        // Resource fork thread (if present)
        if let resourceData = compressedResourceFork {
            let resourceThread = createThreadHeader(
                threadClass: NuFXConstants.THREAD_CLASS_DATA,
                threadFormat: resourceFormat,
                threadKind: NuFXConstants.THREAD_KIND_RESOURCE_FORK,
                threadEOF: UInt32(file.resourceFork?.count ?? 0),
                compThreadEOF: UInt32(resourceData.count)
            )
            record.append(resourceThread)
        }

        // Calculate and set header CRC (covers bytes 6 onwards through thread headers)
        let headerCRC = NuFXCRC.crc16(record.subdata(in: 6..<record.count))
        record[4] = UInt8(headerCRC & 0xFF)
        record[5] = UInt8((headerCRC >> 8) & 0xFF)

        // Thread data
        record.append(filenameData)
        record.append(compressedData)
        if let resourceData = compressedResourceFork {
            record.append(resourceData)
        }

        return record
    }

    private static func createThreadHeader(
        threadClass: UInt16,
        threadFormat: UInt16,
        threadKind: UInt16,
        threadEOF: UInt32,
        compThreadEOF: UInt32
    ) -> Data {
        var header = Data(count: NuFXConstants.THREAD_HEADER_SIZE)

        // Thread class (bytes 0-1)
        header[0] = UInt8(threadClass & 0xFF)
        header[1] = UInt8((threadClass >> 8) & 0xFF)

        // Thread format (bytes 2-3)
        header[2] = UInt8(threadFormat & 0xFF)
        header[3] = UInt8((threadFormat >> 8) & 0xFF)

        // Thread kind (bytes 4-5)
        header[4] = UInt8(threadKind & 0xFF)
        header[5] = UInt8((threadKind >> 8) & 0xFF)

        // Thread CRC (bytes 6-7) - placeholder
        header[6] = 0
        header[7] = 0

        // Thread EOF (bytes 8-11)
        header[8] = UInt8(threadEOF & 0xFF)
        header[9] = UInt8((threadEOF >> 8) & 0xFF)
        header[10] = UInt8((threadEOF >> 16) & 0xFF)
        header[11] = UInt8((threadEOF >> 24) & 0xFF)

        // Comp thread EOF (bytes 12-15)
        header[12] = UInt8(compThreadEOF & 0xFF)
        header[13] = UInt8((compThreadEOF >> 8) & 0xFF)
        header[14] = UInt8((compThreadEOF >> 16) & 0xFF)
        header[15] = UInt8((compThreadEOF >> 24) & 0xFF)

        return header
    }

    // MARK: - LZW/2 Compression

    private static func compressLZW2(_ input: Data) -> Data {
        guard input.count > 0 else { return Data() }

        var output = Data()

        // LZW/2 header: volume (1 byte) + RLE delimiter (1 byte)
        output.append(0)     // Volume number
        output.append(0xDB)  // RLE delimiter (standard ShrinkIt value)

        let rleDelim: UInt8 = 0xDB
        let chunkSize = NuFXLZW.CHUNK_SIZE

        var inputOffset = 0

        while inputOffset < input.count {
            // Get next chunk
            let chunkEnd = min(inputOffset + chunkSize, input.count)
            let chunk = input.subdata(in: inputOffset..<chunkEnd)

            // Apply RLE
            let rleData = applyRLE(chunk, delimiter: rleDelim)

            // Try LZW compression
            let compressor = LZWCompressor()
            let lzwData = compressor.compress(rleData)

            // Decide whether to use LZW or just RLE
            let useLZW = lzwData.count < rleData.count

            // Chunk header (2 bytes)
            // Bit 15: 1 = LZW compressed, 0 = RLE only
            // Bits 0-14: RLE length after decompression
            var header = UInt16(rleData.count & 0x7FFF)
            if useLZW {
                header |= 0x8000
            }

            output.append(UInt8(header & 0xFF))
            output.append(UInt8((header >> 8) & 0xFF))

            if useLZW {
                // Compressed length (2 bytes) - not reliable but required by format
                output.append(UInt8(lzwData.count & 0xFF))
                output.append(UInt8((lzwData.count >> 8) & 0xFF))
                output.append(lzwData)
            } else if rleData.count == chunkSize {
                // Uncompressed
                output.append(chunk)
            } else {
                // RLE only
                output.append(rleData)
            }

            inputOffset = chunkEnd
        }

        return output
    }

    private static func applyRLE(_ data: Data, delimiter: UInt8) -> Data {
        var output = Data()
        var i = 0

        while i < data.count {
            let byte = data[i]

            // Count consecutive bytes
            var count = 1
            while i + count < data.count && data[i + count] == byte && count < 256 {
                count += 1
            }

            if byte == delimiter {
                // Always escape the delimiter
                output.append(delimiter)
                output.append(byte)
                output.append(UInt8(count - 1))
            } else if count >= 4 {
                // Use RLE for runs of 4 or more
                output.append(delimiter)
                output.append(byte)
                output.append(UInt8(count - 1))
            } else {
                // Output literal bytes
                for _ in 0..<count {
                    output.append(byte)
                }
            }

            i += count
        }

        return output
    }

    /// LZW Compressor
    class LZWCompressor {
        private var dictionary: [[UInt8]: Int] = [:]
        private var nextCode = NuFXLZW.LZW_FIRST_CODE
        private var codeSize = NuFXLZW.LZW_START_BITS

        init() {
            reset()
        }

        func reset() {
            dictionary = [:]
            for i in 0..<256 {
                dictionary[[UInt8(i)]] = i
            }
            nextCode = NuFXLZW.LZW_FIRST_CODE
            codeSize = NuFXLZW.LZW_START_BITS
        }

        func compress(_ input: Data) -> Data {
            guard input.count > 0 else { return Data() }

            var output = Data()
            var bitBuffer: UInt32 = 0
            var bitsInBuffer = 0

            func writeCode(_ code: Int) {
                bitBuffer |= UInt32(code) << bitsInBuffer
                bitsInBuffer += codeSize

                while bitsInBuffer >= 8 {
                    output.append(UInt8(bitBuffer & 0xFF))
                    bitBuffer >>= 8
                    bitsInBuffer -= 8
                }
            }

            var current: [UInt8] = [input[0]]

            for i in 1..<input.count {
                let byte = input[i]
                var next = current
                next.append(byte)

                if dictionary[next] != nil {
                    current = next
                } else {
                    // Output code for current
                    if let code = dictionary[current] {
                        writeCode(code)
                    }

                    // Add new entry to dictionary
                    if nextCode < (1 << NuFXLZW.LZW_MAX_BITS) {
                        dictionary[next] = nextCode
                        nextCode += 1

                        // Increase code size if needed
                        if nextCode > (1 << codeSize) && codeSize < NuFXLZW.LZW_MAX_BITS {
                            codeSize += 1
                        }
                    } else {
                        // Table full - emit clear code and reset
                        writeCode(NuFXLZW.LZW_TABLE_CLEAR)
                        reset()
                    }

                    current = [byte]
                }
            }

            // Output final code
            if let code = dictionary[current] {
                writeCode(code)
            }

            // Flush remaining bits
            if bitsInBuffer > 0 {
                output.append(UInt8(bitBuffer & 0xFF))
            }

            return output
        }
    }

    // MARK: - Date Helpers

    private static func writeProDOSDate(_ data: inout Data, offset: Int, date: Date) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)

        let year = (components.year ?? 2000) - 1900
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0

        // Date word: year (bits 9-15), month (bits 5-8), day (bits 0-4)
        let dateWord = UInt16((year & 0x7F) << 9) | UInt16((month & 0x0F) << 5) | UInt16(day & 0x1F)
        data[offset] = UInt8(dateWord & 0xFF)
        data[offset + 1] = UInt8((dateWord >> 8) & 0xFF)

        // Time word: minute (bits 8-15), hour (bits 0-7)
        let timeWord = UInt16((minute & 0x3F) << 8) | UInt16(hour & 0x1F)
        data[offset + 2] = UInt8(timeWord & 0xFF)
        data[offset + 3] = UInt8((timeWord >> 8) & 0xFF)

        // Additional bytes (unused in basic format)
        data[offset + 4] = 0
        data[offset + 5] = 0
        data[offset + 6] = 0
        data[offset + 7] = 0
    }
}
