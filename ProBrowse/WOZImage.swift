//
//  WOZImage.swift
//  ProBrowse
//
//  Reads WOZ 1 and WOZ 2 disk images and decodes their tracks into sectors.
//  A WOZ file holds the bits the drive head reads (sync, address and data fields
//  in GCR nibbles), so the sectors have to be found and decoded before a file
//  system parser can read them.
//  Format: WOZ Disk Image Reference 1.0 / 2.0 / 2.1 by John K. Morris (applesaucefdc.com)
//

import Foundation

struct WOZImage {

    /// How the disk is laid out, decided by which sector format decoded best
    enum Kind: Equatable {
        /// 5.25" with 16 sectors per track (DOS 3.3, ProDOS, Pascal): 6-and-2 encoding
        case disk525Sector16
        /// 5.25" with 13 sectors per track (DOS 3.2): 5-and-3 encoding
        case disk525Sector13
        /// 3.5" 400K or 800K: Sony GCR with 8 to 12 sectors per track
        case disk35
    }

    /// The INFO chunk. Fields from version 2 on are 0 in a WOZ 1 file.
    struct Info: Equatable {
        var version = 0
        /// 1 = 5.25", 2 = 3.5"
        var diskType = 0
        var isWriteProtected = false
        var isSynchronized = false
        var isCleaned = false
        var creator = ""
        var sides = 0
        /// 0 unknown, 1 = 16-sector, 2 = 13-sector, 3 = both
        var bootSectorFormat = 0
        /// In 125 ns units (32 = 4 µs for 5.25", 16 = 2 µs for 3.5")
        var optimalBitTiming = 0
        /// Bit field of Apple II models the disk runs on
        var compatibleHardware = 0
        /// Kilobytes, 0 when unknown
        var requiredRAM = 0
        /// 512-byte blocks used by the largest track
        var largestTrack = 0
    }

    /// One track (one side of a cylinder on a 3.5" disk) and how many of its sectors decoded
    struct Track: Equatable {
        let track: Int
        let side: Int
        /// False when the track map has no bits for this track
        let isPresent: Bool
        let expected: Int
        /// Sectors whose address field was read. When these are all there but fewer sectors
        /// decoded, the data is damaged; when they are missing too, the track is unformatted
        /// or uses a copy-protection format.
        let addressesFound: Int
        let decoded: Int
    }

    enum Error: Swift.Error, LocalizedError {
        case notWOZ
        case missingChunk(String)
        case unsupportedDiskType(Int)

        var errorDescription: String? {
            switch self {
            case .notWOZ: return "The file is not a WOZ disk image."
            case .missingChunk(let id): return "The WOZ file is damaged: its \(id) chunk is missing or cut short."
            case .unsupportedDiskType(let type): return "The WOZ file describes an unknown kind of disk (type \(type))."
            }
        }
    }

    /// 1 or 2, from the file signature
    let version: Int
    let info: Info
    /// The META chunk: title, publisher, side, requires_ram and so on
    let metadata: [String: String]
    /// False when the stored CRC32 doesn't match the file. A stored CRC of 0 means none was written.
    let checksumMatches: Bool
    let kind: Kind
    /// Every decoded sector, missing ones left as zeros, or nil if no sector decoded.
    /// 16-sector disks come in DOS 3.3 order (143,360 bytes), 13-sector disks in
    /// address-field order (116,480 bytes), 3.5" disks in ProDOS block order.
    let sectorImage: Data?
    let tracks: [Track]

    /// Longest track read, in bits. Real tracks are about 51,000 (5.25") or 80,000 (3.5") bits;
    /// the cap keeps a damaged track entry from making the decoder crawl through the whole file.
    static let maximumTrackBits = 64 * 512 * 8

    var sectorsDecoded: Int { tracks.reduce(0) { $0 + $1.decoded } }
    var sectorsExpected: Int { tracks.reduce(0) { $0 + $1.expected } }

    /// Whether the data starts with a WOZ 1 or WOZ 2 header
    static func isWOZ(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = data.startIndex
        let signature = [UInt8](data[b..<b + 8])
        return (signature.prefix(4) == [0x57, 0x4F, 0x5A, 0x31] || signature.prefix(4) == [0x57, 0x4F, 0x5A, 0x32])
            && signature.suffix(4) == [0xFF, 0x0A, 0x0D, 0x0A]
    }

    init(data: Data) throws {
        guard Self.isWOZ(data) else { throw Error.notWOZ }
        let file = [UInt8](data)
        version = file[3] == 0x32 ? 2 : 1

        let storedCRC = Self.le32(file, 8)
        checksumMatches = storedCRC == 0 || ArchiveCRC32.checksum(data.subdata(in: data.startIndex + 12..<data.endIndex)) == storedCRC

        // Chunks: 4-character id, UInt32 size, data. A chunk cut short by the end of the file
        // keeps what is there, so tracks before the cut still decode.
        var chunks: [String: Range<Int>] = [:]
        var offset = 12
        while offset + 8 <= file.count {
            let id = String(decoding: file[offset..<offset + 4], as: UTF8.self)
            let size = Self.le32(file, offset + 4)
            let start = offset + 8
            let end = start + min(size, file.count - start)
            if chunks[id] == nil { chunks[id] = start..<end }
            offset = end
        }

        guard let infoRange = chunks["INFO"], infoRange.count >= 37 else { throw Error.missingChunk("INFO") }
        guard let tmapRange = chunks["TMAP"], tmapRange.count >= 160 else { throw Error.missingChunk("TMAP") }
        guard let trksRange = chunks["TRKS"] else { throw Error.missingChunk("TRKS") }

        info = Self.readInfo(file, infoRange)
        metadata = chunks["META"].map { Self.readMeta(file, $0) } ?? [:]

        let trackMap = Array(file[tmapRange.lowerBound..<tmapRange.lowerBound + 160])
        let isWOZ2 = version == 2
        // The bits of one track (as an index from the track map) and how many of them count
        func trackBits(_ index: Int) -> (bytes: ArraySlice<UInt8>, bitCount: Int)? {
            if isWOZ2 {
                // 160 entries of 8 bytes: first 512-byte block in the file, block count, bit count
                let entry = trksRange.lowerBound + index * 8
                guard index < 160, entry + 8 <= trksRange.upperBound else { return nil }
                let start = Self.le16(file, entry) * 512
                let length = Self.le16(file, entry + 2) * 512
                guard start < file.count, length > 0 else { return nil }
                let bytes = file[start..<min(start + length, file.count)]
                return (bytes, min(Self.le32(file, entry + 4), bytes.count * 8, Self.maximumTrackBits))
            } else {
                // Fixed 6656-byte records: 6646 bytes of bits, bytes used, bit count
                let record = trksRange.lowerBound + index * 6656
                guard record + 6650 <= trksRange.upperBound else { return nil }
                let bytes = file[record..<record + 6646]
                return (bytes, min(Self.le16(file, record + 6648), bytes.count * 8))
            }
        }

        switch info.diskType {
        case 1:
            // Whole track t sits at quarter track t * 4
            let nibbleTracks: [[UInt8]?] = (0..<35).map { track in
                let index = Int(trackMap[track * 4])
                guard index != 0xFF, let bits = trackBits(index), bits.bitCount > 0 else { return nil }
                return Self.nibbles(bits.bytes, bitCount: bits.bitCount)
            }
            let sixteen = nibbleTracks.map { track in track.map { Self.sectors16($0) } ?? TrackSectors() }
            let thirteen = nibbleTracks.map { track in track.map { Self.sectors13($0) } ?? TrackSectors() }
            let count16 = sixteen.reduce(0) { $0 + $1.sectors.count }
            let count13 = thirteen.reduce(0) { $0 + $1.sectors.count }
            let use13 = count13 > count16 || (count16 == 0 && info.bootSectorFormat == 2)
            let found = use13 ? thirteen : sixteen
            let perTrack = use13 ? 13 : 16

            kind = use13 ? .disk525Sector13 : .disk525Sector16
            tracks = (0..<35).map { Track(track: $0, side: 0, isPresent: nibbleTracks[$0] != nil, expected: perTrack,
                                          addressesFound: found[$0].addresses.count, decoded: found[$0].sectors.count) }

            if found.allSatisfy({ $0.sectors.isEmpty }) {
                sectorImage = nil
            } else {
                var image = [UInt8](repeating: 0, count: 35 * perTrack * 256)
                for (track, result) in found.enumerated() {
                    for (sector, bytes) in result.sectors {
                        // DOS 3.3 reorders sectors in software: the address field holds the physical number
                        let logical = use13 ? sector : Self.dosLogicalSector[sector]
                        let offset = (track * perTrack + logical) * 256
                        image.replaceSubrange(offset..<offset + 256, with: bytes)
                    }
                }
                sectorImage = Data(image)
            }

        case 2:
            // Track map index = track * 2 + side; sectors per track drop by one every 16 tracks
            let sides = info.sides == 1 ? 1 : 2
            var image = [UInt8](repeating: 0, count: sides * 800 * 512)
            var list: [Track] = []
            var block = 0
            for track in 0..<80 {
                let perTrack = 12 - track / 16
                for side in 0..<sides {
                    let index = Int(trackMap[track * 2 + side])
                    var result = TrackSectors()
                    var isPresent = false
                    if index != 0xFF, let bits = trackBits(index), bits.bitCount > 0 {
                        isPresent = true
                        result = Self.sectors35(Self.nibbles(bits.bytes, bitCount: bits.bitCount), perTrack: perTrack)
                    }
                    for (sector, bytes) in result.sectors {
                        let offset = (block + sector) * 512
                        image.replaceSubrange(offset..<offset + 512, with: bytes)
                    }
                    list.append(Track(track: track, side: side, isPresent: isPresent, expected: perTrack,
                                      addressesFound: result.addresses.count, decoded: result.sectors.count))
                    block += perTrack
                }
            }
            kind = .disk35
            tracks = list
            sectorImage = list.contains { $0.decoded > 0 } ? Data(image) : nil

        default:
            throw Error.unsupportedDiskType(info.diskType)
        }
    }

    // MARK: - Chunks

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> Int {
        return le16(bytes, offset) | le16(bytes, offset + 2) << 16
    }

    private static func readInfo(_ file: [UInt8], _ range: Range<Int>) -> Info {
        let o = range.lowerBound
        var info = Info()
        info.version = Int(file[o])
        info.diskType = Int(file[o + 1])
        info.isWriteProtected = file[o + 2] == 1
        info.isSynchronized = file[o + 3] == 1
        info.isCleaned = file[o + 4] == 1
        info.creator = String(decoding: file[o + 5..<o + 37], as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
        if info.version >= 2, range.count >= 46 {
            info.sides = Int(file[o + 37])
            info.bootSectorFormat = Int(file[o + 38])
            info.optimalBitTiming = Int(file[o + 39])
            info.compatibleHardware = le16(file, o + 40)
            info.requiredRAM = le16(file, o + 42)
            info.largestTrack = le16(file, o + 44)
        }
        return info
    }

    /// Lines of "key<tab>value"
    private static func readMeta(_ file: [UInt8], _ range: Range<Int>) -> [String: String] {
        var result: [String: String] = [:]
        for line in String(decoding: file[range], as: UTF8.self).split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    // MARK: - Bits to nibbles

    /// The disk bytes the drive's shift register would produce, read twice around the track
    /// so a sector that runs across the end of the bit stream is found whole
    private static func nibbles(_ bytes: ArraySlice<UInt8>, bitCount: Int) -> [UInt8] {
        let track = Array(bytes)
        var result: [UInt8] = []
        result.reserveCapacity(bitCount / 4 + 1)
        var shift: UInt8 = 0
        var byte: UInt8 = 0
        var bit = 0
        // Plain loops: this runs for every bit, and range iteration is slow in debug builds
        while bit < bitCount * 2 {
            let position = bit % bitCount
            if position & 7 == 0 { byte = track[position >> 3] }
            shift = shift << 1 | byte >> 7
            byte <<= 1
            if shift & 0x80 != 0 {
                result.append(shift)
                shift = 0
            }
            bit += 1
        }
        return result
    }

    // MARK: - 6-and-2 and 5-and-3 tables

    /// Disk bytes for 6-bit values (5.25" 16-sector and 3.5")
    static let diskBytes62: [UInt8] = [
        0x96, 0x97, 0x9A, 0x9B, 0x9D, 0x9E, 0x9F, 0xA6, 0xA7, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB2, 0xB3,
        0xB4, 0xB5, 0xB6, 0xB7, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xCB, 0xCD, 0xCE, 0xCF, 0xD3,
        0xD6, 0xD7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE5, 0xE6, 0xE7, 0xE9, 0xEA, 0xEB, 0xEC,
        0xED, 0xEE, 0xEF, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF]

    /// Disk bytes for 5-bit values (5.25" 13-sector)
    static let diskBytes53: [UInt8] = [
        0xAB, 0xAD, 0xAE, 0xAF, 0xB5, 0xB6, 0xB7, 0xBA, 0xBB, 0xBD, 0xBE, 0xBF, 0xD6, 0xD7, 0xDA, 0xDB,
        0xDD, 0xDE, 0xDF, 0xEA, 0xEB, 0xED, 0xEE, 0xEF, 0xF5, 0xF6, 0xF7, 0xFA, 0xFB, 0xFD, 0xFE, 0xFF]

    /// Inverse tables, 0xFF for bytes that are not valid disk bytes
    private static let values62 = inverse(diskBytes62)
    private static let values53 = inverse(diskBytes53)

    private static func inverse(_ table: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0xFF, count: 256)
        for (value, byte) in table.enumerated() { result[Int(byte)] = UInt8(value) }
        return result
    }

    /// DOS 3.3 logical sector stored in each physical sector
    static let dosLogicalSector = [0, 7, 14, 6, 13, 5, 12, 4, 11, 3, 10, 2, 9, 1, 8, 15]

    /// Decodes `count` nibbles at `start` through a table, or nil if any is not a valid disk byte
    private static func values(_ n: [UInt8], _ start: Int, _ count: Int, _ table: [UInt8]) -> [UInt8]? {
        guard start >= 0, start + count <= n.count else { return nil }
        var result = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let value = table[Int(n[start + i])]
            if value == 0xFF { return nil }
            result[i] = value
        }
        return result
    }

    private static func isMark(_ n: [UInt8], _ i: Int, _ a: UInt8, _ b: UInt8, _ c: UInt8) -> Bool {
        return i + 3 <= n.count && n[i] == a && n[i + 1] == b && n[i + 2] == c
    }

    /// Where the data field prologue D5 AA AD starts, looking a short way past an address field
    private static func dataMark(_ n: [UInt8], after start: Int) -> Int? {
        var j = start
        while j < start + 64 && j + 3 <= n.count {
            if isMark(n, j, 0xD5, 0xAA, 0xAD) { return j + 3 }
            // Another address field first means this sector has no data field
            if isMark(n, j, 0xD5, 0xAA, 0x96) || isMark(n, j, 0xD5, 0xAA, 0xB5) { return nil }
            j += 1
        }
        return nil
    }

    /// The sectors that decoded on one track, and every sector number whose address field was read
    private struct TrackSectors {
        var sectors: [Int: [UInt8]] = [:]
        var addresses: Set<Int> = []
    }

    // MARK: - 5.25" sectors

    /// Address field after D5 AA 96 / D5 AA B5: volume, track, sector, checksum in 4-and-4.
    /// Returns the sector number if the checksum matches.
    private static func addressSector525(_ n: [UInt8], _ i: Int) -> Int? {
        guard i + 8 <= n.count else { return nil }
        func fourAndFour(_ k: Int) -> UInt8 { (n[i + k] << 1 | 1) & n[i + k + 1] }
        let volume = fourAndFour(0), track = fourAndFour(2), sector = fourAndFour(4), checksum = fourAndFour(6)
        guard volume ^ track ^ sector == checksum else { return nil }
        return Int(sector)
    }

    /// The 256-byte sectors of a 16-sector track by physical sector number
    private static func sectors16(_ n: [UInt8]) -> TrackSectors {
        var result = TrackSectors()
        var i = 0
        while i + 3 <= n.count && result.sectors.count < 16 {
            guard isMark(n, i, 0xD5, 0xAA, 0x96) else { i += 1; continue }
            i += 3
            guard let sector = addressSector525(n, i), sector < 16 else { continue }
            result.addresses.insert(sector)
            guard result.sectors[sector] == nil,
                  let start = dataMark(n, after: i + 8),
                  let raw = values(n, start, 343, values62) else { continue }
            // Each nibble holds the XOR of two neighbouring 6-bit values; the last one is the checksum
            var buffer = [UInt8](repeating: 0, count: 342)
            var last: UInt8 = 0
            for k in 0..<342 { last ^= raw[k]; buffer[k] = last }
            guard last == raw[342] else { continue }
            // The first 86 values carry the low two bits of three bytes each, bit pairs swapped
            var sector256 = [UInt8](repeating: 0, count: 256)
            for k in 0..<256 {
                let pair = buffer[k % 86] >> (2 * UInt8(k / 86))
                sector256[k] = buffer[86 + k] << 2 | (pair & 1) << 1 | (pair >> 1) & 1
            }
            result.sectors[sector] = sector256
            i = start + 343
        }
        return result
    }

    /// The 256-byte sectors of a 13-sector (DOS 3.2) track by address-field sector number
    private static func sectors13(_ n: [UInt8]) -> TrackSectors {
        var result = TrackSectors()
        var i = 0
        while i + 3 <= n.count && result.sectors.count < 13 {
            guard isMark(n, i, 0xD5, 0xAA, 0xB5) else { i += 1; continue }
            i += 3
            guard let sector = addressSector525(n, i), sector < 13 else { continue }
            result.addresses.insert(sector)
            guard result.sectors[sector] == nil,
                  let start = dataMark(n, after: i + 8),
                  let raw = values(n, start, 411, values53) else { continue }
            // 154 values with the low three bits (stored last to first), then 256 with the high five
            var threes = [UInt8](repeating: 0, count: 154)
            var fives = [UInt8](repeating: 0, count: 256)
            var last: UInt8 = 0
            for k in 0..<154 { last ^= raw[k]; threes[153 - k] = last }
            for k in 0..<256 { last ^= raw[154 + k]; fives[k] = last << 3 }
            guard last == raw[410] else { continue }
            var sector256 = [UInt8](repeating: 0, count: 256)
            var out = 0
            for k in stride(from: 50, through: 0, by: -1) {
                let a = threes[k], b = threes[51 + k], c = threes[102 + k]
                let d = (a & 2) << 1 | (b & 2) | (c & 2) >> 1
                let e = (a & 1) << 2 | (b & 1) << 1 | (c & 1)
                sector256[out] = fives[k] | (a >> 2) & 7
                sector256[out + 1] = fives[51 + k] | (b >> 2) & 7
                sector256[out + 2] = fives[102 + k] | (c >> 2) & 7
                sector256[out + 3] = fives[153 + k] | d
                sector256[out + 4] = fives[204 + k] | e
                out += 5
            }
            sector256[255] = fives[255] | threes[153] & 7
            result.sectors[sector] = sector256
            i = start + 411
        }
        return result
    }

    // MARK: - 3.5" sectors

    /// The 512 data bytes of each sector of a 3.5" track (the 12 tag bytes are dropped)
    private static func sectors35(_ n: [UInt8], perTrack: Int) -> TrackSectors {
        var result = TrackSectors()
        var i = 0
        while i + 3 <= n.count && result.sectors.count < perTrack {
            guard isMark(n, i, 0xD5, 0xAA, 0x96) else { i += 1; continue }
            i += 3
            // Track, sector, side, format, checksum
            guard let address = values(n, i, 5, values62),
                  address[0] ^ address[1] ^ address[2] ^ address[3] == address[4] else { continue }
            let sector = Int(address[1])
            guard sector < perTrack else { continue }
            result.addresses.insert(sector)
            guard result.sectors[sector] == nil,
                  let start = dataMark(n, after: i + 5),
                  let raw = values(n, start, 1 + 699 + 4, values62),
                  Int(raw[0]) == sector,
                  let bytes = denibblize35(Array(raw[1...])) else { continue }
            result.sectors[sector] = Array(bytes[12..<524])
            i = start + 704
        }
        return result
    }

    /// 699 data values (groups of a high-bits value and three 6-bit values, the last group short)
    /// and 4 checksum values into 524 bytes, checking the three running checksums
    private static func denibblize35(_ v: [UInt8]) -> [UInt8]? {
        guard v.count == 703 else { return nil }
        var b1 = [UInt8](repeating: 0, count: 175), b2 = b1, b3 = b1
        var j = 0
        for k in 0..<175 {
            let high = v[j], w1 = v[j + 1], w2 = v[j + 2]
            j += 3
            var w3: UInt8 = 0
            if k != 174 { w3 = v[j]; j += 1 }
            b1[k] = w1 | (high << 2) & 0xC0
            b2[k] = w2 | (high << 4) & 0xC0
            b3[k] = w3 | (high << 6) & 0xC0
        }
        var out = [UInt8](repeating: 0, count: 524)
        var c1 = 0, c2 = 0, c3 = 0
        var i = 0
        for k in 0..<175 {
            c1 = (c1 & 0xFF) << 1
            if c1 & 0x100 != 0 { c1 += 1 }
            var value = Int(b1[k]) ^ (c1 & 0xFF)
            c3 += value
            if c1 & 0x100 != 0 { c3 += 1; c1 &= 0xFF }
            out[i] = UInt8(value); i += 1

            value = Int(b2[k]) ^ (c3 & 0xFF)
            c2 += value
            if c3 > 0xFF { c2 += 1; c3 &= 0xFF }
            out[i] = UInt8(value); i += 1

            if i == 524 { break }
            value = Int(b3[k]) ^ (c2 & 0xFF)
            c1 += value
            if c2 > 0xFF { c1 += 1; c2 &= 0xFF }
            out[i] = UInt8(value); i += 1
        }
        // Stored after the data as high bits, then c3, c2, c1
        let high = (c1 & 0xC0) >> 6 | (c2 & 0xC0) >> 4 | (c3 & 0xC0) >> 2
        guard Int(v[699]) == high, Int(v[700]) == c3 & 0x3F, Int(v[701]) == c2 & 0x3F, Int(v[702]) == c1 & 0x3F else { return nil }
        return out
    }
}
