//
//  BinaryIIArchive.swift
//  ProBrowse
//
//  Binary II archive format read support
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
    /// Length of the data as stored (the squeezed length for a squeezed file)
    let fileLength: UInt32
    let filename: String
    var dataOffset: Int = 0
    /// The stored data is an SQ stream; `extractData` expands it
    var isSqueezed: Bool = false

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

            // File length: 3 bytes at +20, high byte (GS/OS EOF) at +116
            var fileLength = UInt32(data[offset + 20]) |
                           (UInt32(data[offset + 21]) << 8) |
                           (UInt32(data[offset + 22]) << 16) |
                           (UInt32(data[offset + 116]) << 24)

            // Directories carry no data, though BLU fills in a length for them
            if fileType == 0x0F {
                fileLength = 0
            }

            // Phantom files (+124 nonzero) hold metadata such as option lists, not files
            let isPhantom = data[offset + 124] != 0

            // Filename or partial pathname: length byte at +23, up to 64 characters at +24
            let filenameLength = min(Int(data[offset + 23]), 64)
            let filenameBytes = data[(offset + 24)..<(offset + 24 + filenameLength)].map { $0 & 0x7F }
            let filename = String(decoding: filenameBytes, as: UTF8.self)

            // Data offset
            let dataOffset = offset + BinaryIIConstants.HEADER_SIZE

            // Squeezed if the data flags (+125) say compressed (bit 7) or, as BLU
            // also accepts, the name ends in .QQ; the data must start with the SQ magic.
            let dataFlags = data[offset + 125]
            let claimsSqueezed = (dataFlags & 0x80) != 0 || filename.lowercased().hasSuffix(".qq")
            let isSqueezed = claimsSqueezed && fileLength >= 2 && dataOffset + 2 <= data.count &&
                data[dataOffset] == 0x76 && data[dataOffset + 1] == 0xFF

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
                dataOffset: dataOffset,
                isSqueezed: isSqueezed
            )

            if !isPhantom {
                entries.append(entry)
            }

            // Move to next entry
            // File data is padded to 128-byte boundary
            let paddedLength = ((Int(fileLength) + 127) / 128) * 128
            offset = dataOffset + paddedLength
        }
    }

    /// Extract data for a specific entry, expanding squeezed files.
    /// Returns nil if the data is truncated or does not expand.
    func extractData(for entry: BinaryIIEntry) -> Data? {
        let endOffset = entry.dataOffset + Int(entry.fileLength)
        guard entry.dataOffset >= 0, endOffset <= data.count else { return nil }
        let stored = data.subdata(in: entry.dataOffset..<endOffset)
        guard entry.isSqueezed else { return stored }
        return try? NuFXSqueeze.decompressStream(stored, maxSize: NuFXArchive.maxThreadSize)
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
