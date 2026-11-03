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
        let creationDate = parseNuFXDate(data, offset: 12)
        let modificationDate = parseNuFXDate(data, offset: 20)
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
        let creationDate = parseNuFXDate(data, offset: offset + 32)
        let modificationDate = parseNuFXDate(data, offset: offset + 40)
        let archiveDate = parseNuFXDate(data, offset: offset + 48)

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

// MARK: - Date Parsing

/// NuFX dates are IIgs Date/Time records: second, minute, hour, year - 1900,
/// day (0-30), month (0-11), filler, weekday.
private func parseNuFXDate(_ data: Data, offset: Int) -> Date? {
    guard offset >= 0, offset + 8 <= data.count else { return nil }
    if (0..<8).allSatisfy({ data[offset + $0] == 0 }) { return nil }

    let second = Int(data[offset])
    let minute = Int(data[offset + 1])
    let hour = Int(data[offset + 2])
    var year = Int(data[offset + 3])
    let day = Int(data[offset + 4])
    let month = Int(data[offset + 5])
    guard second < 60, minute < 60, hour < 24, day < 31, month < 12 else { return nil }

    // P8 ShrinkIt stores 2000-2039 as 0-39
    if year < 40 { year += 100 }

    var components = DateComponents()
    components.year = 1900 + year
    components.month = month + 1
    components.day = day + 1
    components.hour = hour
    components.minute = minute
    components.second = second

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

        // CRC-16 of the expanded data, counting every chunk as a full 4096 bytes
        let storedCRC = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let rleDelim = data[3]
        offset = 4

        while output.count < expectedSize && offset < data.count {
            // Read chunk header
            guard offset + 3 <= data.count else { break }

            let rleLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            let lzwFlag = data[offset + 2]
            offset += 3
            guard rleLen > 0, rleLen <= CHUNK_SIZE, lzwFlag <= 1 else {
                throw NuFXError.decompressionFailed
            }

            // Decompress this chunk
            var chunkData: Data

            if lzwFlag != 0 {
                // LZW compressed
                // LZW/1 starts each chunk with a fresh table and yields rleLen bytes
                let (decompressed, bytesUsed) = try LZWDecompressor().decompress(data, from: offset, maxOutput: rleLen)
                guard decompressed.count == rleLen else { throw NuFXError.decompressionFailed }
                chunkData = decompressed
                offset += bytesUsed
            } else {
                // Uncompressed (rleLen is 4096) or RLE only
                chunkData = Data(data[offset..<min(offset + rleLen, data.count)])
                offset += chunkData.count
            }

            let expanded = try expandChunk(chunkData, rleLen: rleLen, delimiter: rleDelim,
                                           remaining: expectedSize - output.count)
            output.append(expanded)
        }

        if output.count >= expectedSize && NuFXCRC.crc16(output) != storedCRC {
            throw NuFXError.checksumMismatch
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

            // Bit 15 flags LZW; the length is in the low 13 bits (as in NufxLib)
            let lzwFlag = (header & 0x8000) != 0
            let rleLen = header & 0x1FFF
            guard rleLen > 0, rleLen <= CHUNK_SIZE else {
                throw NuFXError.decompressionFailed
            }

            // A chunk stored without LZW starts the table over
            if !lzwFlag { lzwState.reset() }

            var chunkData: Data

            if lzwFlag {
                // Skip 2-byte compressed length field (unreliable)
                guard offset + 2 <= data.count else { break }
                offset += 2

                // LZW compressed
                let (decompressed, bytesUsed) = try lzwState.decompress(data, from: offset, maxOutput: rleLen)
                guard decompressed.count == rleLen else { throw NuFXError.decompressionFailed }
                chunkData = decompressed
                offset += bytesUsed
            } else {
                // Uncompressed (rleLen is 4096) or RLE only
                chunkData = Data(data[offset..<min(offset + rleLen, data.count)])
                offset += chunkData.count
            }

            let expanded = try expandChunk(chunkData, rleLen: rleLen, delimiter: rleDelim,
                                           remaining: expectedSize - output.count)
            output.append(expanded)
        }

        // Trim to expected size
        if output.count > expectedSize {
            output = output.prefix(expectedSize)
        }

        return output
    }

    /// Turns one chunk's data (after LZW) into its 4096 bytes. A chunk length of
    /// 4096 means no RLE. A short stored final chunk is accepted when it still covers
    /// the rest of the file; it is padded with zeros as ShrinkIt pads it.
    private static func expandChunk(_ chunk: Data, rleLen: Int, delimiter: UInt8, remaining: Int) throws -> Data {
        if rleLen == CHUNK_SIZE {
            guard chunk.count == CHUNK_SIZE || chunk.count >= remaining else {
                throw NuFXError.decompressionFailed
            }
            var full = Data(chunk.prefix(CHUNK_SIZE))
            if full.count < CHUNK_SIZE {
                full.append(Data(count: CHUNK_SIZE - full.count))
            }
            return full
        }
        guard chunk.count == rleLen else { throw NuFXError.decompressionFailed }
        return try expandRLE(chunk, delimiter: delimiter)
    }

    /// Expands RLE data, which must yield exactly 4096 bytes and use all its input
    private static func expandRLE(_ data: Data, delimiter: UInt8) throws -> Data {
        var output = Data()
        output.reserveCapacity(CHUNK_SIZE)
        var i = data.startIndex

        while output.count < CHUNK_SIZE {
            guard i < data.endIndex else { throw NuFXError.decompressionFailed }
            let byte = data[i]
            i += 1

            if byte == delimiter {
                guard i + 1 < data.endIndex else { throw NuFXError.decompressionFailed }
                let value = data[i]
                let count = Int(data[i + 1]) + 1
                i += 2
                guard output.count + count <= CHUNK_SIZE else { throw NuFXError.decompressionFailed }
                output.append(contentsOf: [UInt8](repeating: value, count: count))
            } else {
                output.append(byte)
            }
        }

        guard i == data.endIndex else { throw NuFXError.decompressionFailed }
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
    static let RLE_DELIM: UInt8 = 0x90
    static let EOF_TOKEN = 256

    /// Expands a NuFX squeeze thread. ShrinkIt leaves out the SQ file header
    /// (magic, checksum, filename); a stream that has one is accepted too.
    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        return try expand(data, limit: expectedSize, requireEOF: false)
    }

    /// Expands a complete SQ stream (as in Binary II), which must end with its
    /// stop symbol within `maxSize` bytes of output.
    static func decompressStream(_ data: Data, maxSize: Int) throws -> Data {
        return try expand(data, limit: maxSize, requireEOF: true)
    }

    private static func expand(_ data: Data, limit: Int, requireEOF: Bool) throws -> Data {
        var offset = 0
        var storedChecksum: UInt16? = nil

        // Full SQ header: 76 FF, checksum, NUL-terminated filename. A headerless
        // stream starts with the node count, which is below 257, so this can't clash.
        if data.count >= 2 && data[0] == 0x76 && data[1] == 0xFF {
            guard data.count >= 5 else { throw NuFXError.decompressionFailed }
            storedChecksum = UInt16(data[2]) | (UInt16(data[3]) << 8)
            offset = 4
            while offset < data.count && data[offset] != 0 {
                offset += 1
            }
            offset += 1  // Skip null
        }

        // Read node count
        guard offset + 2 <= data.count else {
            throw NuFXError.decompressionFailed
        }
        let nodeCount = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        offset += 2
        guard nodeCount <= EOF_TOKEN else { throw NuFXError.decompressionFailed }

        // Read Huffman tree. A child >= 0 is a node index; -(n + 1) is symbol n.
        var tree: [(left: Int, right: Int)] = []
        for _ in 0..<nodeCount {
            guard offset + 4 <= data.count else {
                throw NuFXError.decompressionFailed
            }
            let left = Int(Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)))
            let right = Int(Int16(bitPattern: UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)))
            guard left >= -(EOF_TOKEN + 1), left < nodeCount,
                  right >= -(EOF_TOKEN + 1), right < nodeCount else {
                throw NuFXError.decompressionFailed
            }
            tree.append((left, right))
            offset += 4
        }

        // Decode symbols and expand runs as they arrive: <byte> $90 <count> repeats
        // <byte> count times in total; $90 $00 is a literal $90.
        var output = Data()
        var checksum: UInt16 = 0
        var bitBuffer = 0
        var bitsInBuffer = 0
        var lastByte: UInt8 = 0
        var inRun = false
        var sawEOF = false

        decode: while output.count < limit {
            // An empty tree only holds the stop symbol
            var symbol = EOF_TOKEN
            if !tree.isEmpty {
                var node = 0
                while true {
                    if bitsInBuffer == 0 {
                        guard offset < data.count else { break decode }
                        bitBuffer = Int(data[offset])
                        offset += 1
                        bitsInBuffer = 8
                    }
                    let bit = bitBuffer & 1
                    bitBuffer >>= 1
                    bitsInBuffer -= 1

                    let child = bit == 0 ? tree[node].left : tree[node].right
                    if child < 0 {
                        symbol = -(child + 1)
                        break
                    }
                    node = child
                }
            }

            if symbol == EOF_TOKEN {
                sawEOF = true
                break
            }

            if inRun {
                inRun = false
                if symbol == 0 {
                    lastByte = RLE_DELIM
                    output.append(RLE_DELIM)
                    checksum &+= UInt16(RLE_DELIM)
                } else if symbol > 1 {
                    let count = min(symbol - 1, limit - output.count)
                    output.append(contentsOf: [UInt8](repeating: lastByte, count: count))
                    checksum &+= UInt16(count) &* UInt16(lastByte)
                }
            } else if symbol == Int(RLE_DELIM) {
                inRun = true
            } else {
                lastByte = UInt8(symbol)
                output.append(lastByte)
                checksum &+= UInt16(lastByte)
            }
        }

        if requireEOF && (!sawEOF || inRun) {
            throw NuFXError.decompressionFailed
        }
        // The SQ header's checksum is the 16-bit sum of the expanded bytes
        if sawEOF, let stored = storedChecksum, stored != checksum {
            throw NuFXError.checksumMismatch
        }

        return output
    }
}
