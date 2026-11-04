//
//  MODMetadata.swift
//  ProBrowse
//
//  The texts inside a ProTracker-style module: the song title and the 31 sample names,
//  where musicians usually leave their name, greetings and notes. Read for the preview
//  pane and written back in place, since every field has a fixed width.
//

import Foundation

struct MODMetadata: Equatable {
    static let titleLength = 20
    static let sampleNameLength = 22
    static let sampleCount = 31

    /// Song title, at most `titleLength` characters
    var title: String
    /// One name per sample slot, at most `sampleNameLength` characters each
    var sampleNames: [String]

    /// Sample sizes in bytes, 0 for an empty slot
    let sampleLengths: [Int]
    /// Format tag at offset 1080, e.g. "M.K."
    let tag: String
    let channels: Int
    /// Patterns stored in the file
    let patternCount: Int
    /// Positions in the song's order list
    let songLength: Int

    /// Reads a module with a format tag; nil for anything else
    init?(data: Data) {
        guard let channels = MODRenderer.channelCount(data) else { return nil }
        let bytes = [UInt8](data)
        self.channels = channels
        tag = String(bytes: bytes[1080..<1084], encoding: .ascii) ?? ""
        title = Self.text(bytes[0..<Self.titleLength])
        var names: [String] = []
        var lengths: [Int] = []
        for i in 0..<Self.sampleCount {
            let header = 20 + i * 30
            names.append(Self.text(bytes[header..<header + Self.sampleNameLength]))
            lengths.append((Int(bytes[header + 22]) << 8 | Int(bytes[header + 23])) * 2)
        }
        sampleNames = names
        sampleLengths = lengths
        songLength = Int(bytes[950])
        patternCount = Int(bytes[952..<1080].max() ?? 0) + 1
    }

    /// The module with this title and these sample names. Only fields that differ from
    /// what `data` holds are rewritten, so untouched names keep their bytes exactly.
    /// Returns nil if `data` is not a module.
    func applied(to data: Data) -> Data? {
        guard let original = MODMetadata(data: data) else { return nil }
        var bytes = [UInt8](data)
        if title != original.title {
            bytes.replaceSubrange(0..<Self.titleLength, with: Self.field(title, width: Self.titleLength))
        }
        for i in 0..<Self.sampleCount where i < sampleNames.count && sampleNames[i] != original.sampleNames[i] {
            let header = 20 + i * 30
            bytes.replaceSubrange(header..<header + Self.sampleNameLength,
                                  with: Self.field(sampleNames[i], width: Self.sampleNameLength))
        }
        return Data(bytes)
    }

    /// Text of a fixed-width field: up to the first NUL, other control bytes shown as spaces
    private static func text(_ field: ArraySlice<UInt8>) -> String {
        let used = field.prefix { $0 != 0 }.map { $0 < 0x20 ? 0x20 : $0 }
        return String(bytes: used, encoding: .isoLatin1) ?? ""
    }

    /// A string as a fixed-width field, padded with NULs; characters Latin-1 can't hold become "?"
    static func field(_ string: String, width: Int) -> [UInt8] {
        let encoded = string.unicodeScalars.prefix(width).map { $0.value < 0x100 ? UInt8($0.value) : UInt8(ascii: "?") }
        return encoded + [UInt8](repeating: 0, count: width - encoded.count)
    }
}
