//
//  BinaryIIArchive.swift
//  ProBrowse
//
//  Binary II archive format read/write support
//  Binary II is a simple wrapper format that preserves ProDOS file attributes
//

import Foundation

// MARK: - Binary II Constants

enum BinaryIIConstants {
    static let HEADER_SIZE = 128
    static let MAGIC: [UInt8] = [0x0A, 0x47, 0x4C]  // "^J" + "GL"
    static let ID_BYTE: UInt8 = 0x02  // Standard Binary II
}

// MARK: - Binary II Entry

struct BinaryIIEntry {
    let accessFlags: UInt8
    let fileType: UInt8
    let auxType: UInt16
    let storageType: UInt8
    let blockCount: UInt16
    let modificationDate: Date?
    let creationDate: Date?
    let fileLength: UInt32
    let filename: String
    var dataOffset: Int = 0

    var fileTypeString: String {
        ProDOSFileTypeInfo.getFileTypeInfo(fileType: fileType, auxType: auxType).shortName
    }
}

// MARK: - Binary II Archive

class BinaryIIArchive {
    let data: Data
    var entries: [BinaryIIEntry] = []

    init(data: Data) {
        self.data = data
    }

    /// Check if data is a Binary II archive
    static func isBinaryII(_ data: Data) -> Bool {
        guard data.count >= BinaryIIConstants.HEADER_SIZE else { return false }
        return data[0] == BinaryIIConstants.MAGIC[0] &&
               data[1] == BinaryIIConstants.MAGIC[1] &&
               data[2] == BinaryIIConstants.MAGIC[2]
    }

    /// Check if file has Binary II extension
    static func isBinaryIIExtension(_ ext: String) -> Bool {
        let lower = ext.lowercased()
        return lower == "bny" || lower == "bqy" || lower == "bii"
    }

    /// Parse the archive
    func parse() throws {
        entries = []
        var offset = 0

        while offset + BinaryIIConstants.HEADER_SIZE <= data.count {
            // Check for magic bytes
            guard data[offset] == BinaryIIConstants.MAGIC[0] &&
                  data[offset + 1] == BinaryIIConstants.MAGIC[1] &&
                  data[offset + 2] == BinaryIIConstants.MAGIC[2] else {
                break
            }

            // Parse header
            let accessFlags = data[offset + 3]
            let fileType = data[offset + 4]
            let auxType = UInt16(data[offset + 5]) | (UInt16(data[offset + 6]) << 8)
            let storageType = data[offset + 7]
            let blockCount = UInt16(data[offset + 8]) | (UInt16(data[offset + 9]) << 8)

            // Dates
            let modDate = UInt16(data[offset + 10]) | (UInt16(data[offset + 11]) << 8)
            let modTime = UInt16(data[offset + 12]) | (UInt16(data[offset + 13]) << 8)
            let createDate = UInt16(data[offset + 14]) | (UInt16(data[offset + 15]) << 8)
            let createTime = UInt16(data[offset + 16]) | (UInt16(data[offset + 17]) << 8)

            // ID byte check
            let idByte = data[offset + 18]
            if idByte != BinaryIIConstants.ID_BYTE && idByte != 0x00 {
                // Some implementations use different ID bytes
                print("BinaryII: Non-standard ID byte \(String(format: "$%02X", idByte))")
            }

            // File length: 3 bytes
            let fileLength = UInt32(data[offset + 20]) |
                           (UInt32(data[offset + 21]) << 8) |
                           (UInt32(data[offset + 22]) << 16)

            // Filename or partial pathname: length byte at +23, up to 64 characters at +24
            let filenameLength = min(Int(data[offset + 23]), 64)
            let filenameBytes = data[(offset + 24)..<(offset + 24 + filenameLength)].map { $0 & 0x7F }
            let filename = String(decoding: filenameBytes, as: UTF8.self)

            // Data offset
            let dataOffset = offset + BinaryIIConstants.HEADER_SIZE

            let entry = BinaryIIEntry(
                accessFlags: accessFlags,
                fileType: fileType,
                auxType: auxType,
                storageType: storageType,
                blockCount: blockCount,
                modificationDate: parseProDOSDateTime(modDate, modTime),
                creationDate: parseProDOSDateTime(createDate, createTime),
                fileLength: fileLength,
                filename: filename,
                dataOffset: dataOffset
            )

            entries.append(entry)

            // Move to next entry
            // File data is padded to 128-byte boundary
            let paddedLength = ((Int(fileLength) + 127) / 128) * 128
            offset = dataOffset + paddedLength
        }
    }

    /// Extract data for a specific entry
    func extractData(for entry: BinaryIIEntry) -> Data? {
        let endOffset = entry.dataOffset + Int(entry.fileLength)
        guard endOffset <= data.count else { return nil }
        return data.subdata(in: entry.dataOffset..<endOffset)
    }

    /// Extract first file from archive
    func extractFirst() -> (entry: BinaryIIEntry, data: Data)? {
        guard let entry = entries.first,
              let fileData = extractData(for: entry) else {
            return nil
        }
        return (entry, fileData)
    }

    // MARK: - Date Parsing

    private func parseProDOSDateTime(_ date: UInt16, _ time: UInt16) -> Date? {
        if date == 0 && time == 0 { return nil }

        let year = Int((date >> 9) & 0x7F)
        let month = Int((date >> 5) & 0x0F)
        let day = Int(date & 0x1F)
        let hour = Int((time >> 8) & 0x1F)
        let minute = Int(time & 0x3F)

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
}

// MARK: - Binary II Writer

class BinaryIIWriter {

    /// File entry for writing
    struct FileEntry {
        let filename: String
        let data: Data
        let fileType: UInt8
        let auxType: UInt16
        let accessFlags: UInt8
        let storageType: UInt8
        let creationDate: Date?
        let modificationDate: Date?

        init(filename: String, data: Data,
             fileType: UInt8 = 0x06, auxType: UInt16 = 0,
             accessFlags: UInt8 = 0xE3, storageType: UInt8 = 1,
             creationDate: Date? = nil, modificationDate: Date? = nil) {
            self.filename = filename
            self.data = data
            self.fileType = fileType
            self.auxType = auxType
            self.accessFlags = accessFlags
            self.storageType = storageType
            self.creationDate = creationDate ?? Date()
            self.modificationDate = modificationDate ?? Date()
        }
    }

    /// Create a Binary II archive from files
    static func createArchive(files: [FileEntry]) -> Data {
        var output = Data()

        for file in files {
            // Create header
            let header = createHeader(for: file)

            // Pad data to 128-byte boundary
            var fileData = file.data
            let paddingNeeded = (128 - (fileData.count % 128)) % 128
            if paddingNeeded > 0 {
                fileData.append(contentsOf: [UInt8](repeating: 0, count: paddingNeeded))
            }

            output.append(header)
            output.append(fileData)
        }

        return output
    }

    /// Create a single-file Binary II archive
    static func createSingleFileArchive(
        filename: String,
        data: Data,
        fileType: UInt8 = 0x06,
        auxType: UInt16 = 0
    ) -> Data {
        let entry = FileEntry(
            filename: filename,
            data: data,
            fileType: fileType,
            auxType: auxType
        )
        return createArchive(files: [entry])
    }

    // MARK: - Header Creation

    private static func createHeader(for file: FileEntry) -> Data {
        var header = Data(count: BinaryIIConstants.HEADER_SIZE)

        // Magic bytes
        header[0] = BinaryIIConstants.MAGIC[0]
        header[1] = BinaryIIConstants.MAGIC[1]
        header[2] = BinaryIIConstants.MAGIC[2]

        // Access flags
        header[3] = file.accessFlags

        // File type
        header[4] = file.fileType

        // Aux type (little-endian)
        header[5] = UInt8(file.auxType & 0xFF)
        header[6] = UInt8((file.auxType >> 8) & 0xFF)

        // Storage type
        header[7] = file.storageType

        // Block count (file size / 512, rounded up)
        let blockCount = UInt16((file.data.count + 511) / 512)
        header[8] = UInt8(blockCount & 0xFF)
        header[9] = UInt8((blockCount >> 8) & 0xFF)

        // Modification date/time
        if let modDate = file.modificationDate {
            let (date, time) = encodeProDOSDateTime(modDate)
            header[10] = UInt8(date & 0xFF)
            header[11] = UInt8((date >> 8) & 0xFF)
            header[12] = UInt8(time & 0xFF)
            header[13] = UInt8((time >> 8) & 0xFF)
        }

        // Creation date/time
        if let createDate = file.creationDate {
            let (date, time) = encodeProDOSDateTime(createDate)
            header[14] = UInt8(date & 0xFF)
            header[15] = UInt8((date >> 8) & 0xFF)
            header[16] = UInt8(time & 0xFF)
            header[17] = UInt8((time >> 8) & 0xFF)
        }

        // ID byte
        header[18] = BinaryIIConstants.ID_BYTE

        // Reserved byte
        header[19] = 0

        // File length (little-endian)
        let fileLength = UInt32(file.data.count)
        header[20] = UInt8(fileLength & 0xFF)
        header[21] = UInt8((fileLength >> 8) & 0xFF)
        header[22] = UInt8((fileLength >> 16) & 0xFF)
        header[23] = UInt8((fileLength >> 24) & 0xFF)

        // Filename (bytes 24-63, null-terminated)
        let filenameBytes = Array(file.filename.prefix(39).utf8)
        for (i, byte) in filenameBytes.enumerated() {
            header[24 + i] = byte
        }
        // Null terminator (already zero from initialization)

        // Bytes 64-127 are reserved (already zero)

        return header
    }

    // MARK: - Date Encoding

    private static func encodeProDOSDateTime(_ date: Date) -> (date: UInt16, time: UInt16) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)

        var year = (components.year ?? 2000) - 1900
        if year >= 100 { year -= 100 }  // Convert 2000+ to 0-39
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0

        // Date word: year (bits 9-15), month (bits 5-8), day (bits 0-4)
        let dateWord = UInt16((year & 0x7F) << 9) | UInt16((month & 0x0F) << 5) | UInt16(day & 0x1F)

        // Time word: hour (bits 8-12), minute (bits 0-5)
        let timeWord = UInt16((hour & 0x1F) << 8) | UInt16(minute & 0x3F)

        return (dateWord, timeWord)
    }
}
