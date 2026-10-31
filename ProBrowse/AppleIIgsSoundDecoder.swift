//
//  AppleIIgsSoundDecoder.swift
//  ProBrowse
//
//  Turns Apple IIgs sound files into playable PCM.
//
//  Sources:
//  - rSoundSample ($8024): Apple IIgs Technical Note #76
//  - Resource forks: Apple IIgs Toolbox Reference Vol. 3 ch. 45 (as summarised in CiderPress II's ResourceFork-notes.md)
//  - HyperStudio ($D8/$8001): Apple II File Type Note $D8/$8001
//  - ASIF ($D8/$0002): Apple II File Type Note $D8/$0002
//

import Foundation

/// One playable sound: mono samples in -1...1 at a given rate
nonisolated struct DecodedSound: Identifiable, Sendable {
    let id = UUID()
    let name: String
    /// Mono samples, or the left channel when `right` is set
    let samples: [Float]
    let right: [Float]?
    let sampleRate: Double
    let detail: String
    /// Min/max pairs for drawing the waveform, worked out once so drawing stays cheap
    let envelope: [Float]

    var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    init(name: String, samples: [Float], right: [Float]? = nil, sampleRate: Double, detail: String) {
        self.name = name
        self.samples = samples
        self.right = right
        self.sampleRate = sampleRate
        self.detail = detail
        self.envelope = DecodedSound.envelope(samples, right)
    }

    static let envelopeColumns = 800

    private static func envelope(_ left: [Float], _ right: [Float]?) -> [Float] {
        guard !left.isEmpty else { return [] }
        let columns = min(envelopeColumns, left.count)
        var out = [Float](repeating: 0, count: columns * 2)
        for c in 0..<columns {
            let start = c * left.count / columns
            let end = max(start + 1, (c + 1) * left.count / columns)
            var lo: Float = 0, hi: Float = 0
            for i in start..<end {
                lo = min(lo, left[i]); hi = max(hi, left[i])
                if let right, i < right.count { lo = min(lo, right[i]); hi = max(hi, right[i]) }
            }
            out[c * 2] = lo
            out[c * 2 + 1] = hi
        }
        return out
    }
}

/// What the inspector can do with a sound or music file
nonisolated enum SoundDocument: Sendable {
    case samples([DecodedSound])
    case midi(Data)
    /// AIFF / AIFF-C, played through AVAudioFile
    case audioFile(Data)
    case unsupported(String)
}

nonisolated enum AppleIIgsSoundDecoder {

    // MARK: - Detection

    /// True when the inspector should show the audio player for this file
    static func isAudio(fileType: UInt8, auxType: UInt16, data: Data) -> Bool {
        if fileType == 0xD7 || fileType == 0xD8 { return true }
        if fileType == 0xD5 && auxType == 0x0007 { return true }
        return iffType(data) == "ASIF" || iffType(data) == "AIFF" || iffType(data) == "AIFC"
            || hasPrefix(data, "SSHS") || MODRenderer.isModule(data)
    }

    /// `companions` holds the other files in the same folder by upper-case name, for
    /// formats that keep their instruments in a separate file
    static func decode(fileType: UInt8, auxType: UInt16, data: Data, resourceFork: Data?,
                       name: String = "", companions: [String: Data] = [:]) -> SoundDocument {
        if fileType == 0xD5 && auxType == 0x0007 {
            return decodeSoundSmith(data, name: name, companions: companions)
        }
        if fileType == 0xD7 {
            return data.count >= 4 && hasPrefix(data, "MThd")
                ? .midi(data) : .unsupported("This MIDI file has no standard MIDI header.")
        }

        if MODRenderer.isModule(data) {
            guard let module = MODRenderer.parse(data) else {
                return .unsupported("This tracker module is damaged or incomplete.")
            }
            let (left, right) = MODRenderer.render(module)
            guard !left.isEmpty else { return .unsupported("This tracker module has no notes.") }
            let cut = Double(left.count) >= MODRenderer.maxSeconds * MODRenderer.outputRate - 1 ? ", first 10 minutes" : ""
            let title = module.title.isEmpty ? "Tracker module" : module.title
            return .samples([DecodedSound(name: title, samples: left, right: right, sampleRate: MODRenderer.outputRate,
                                          detail: "\(module.channels)-channel tracker module (ProTracker / NoiseTracker)\(cut)")])
        }

        switch iffType(data) {
        case "ASIF":
            let sounds = decodeASIF(data)
            return sounds.isEmpty ? .unsupported("This ASIF instrument has no wave data.") : .samples(sounds)
        case "AIFF", "AIFC":
            return .audioFile(data)
        default:
            break
        }

        if hasPrefix(data, "SSHS") || (fileType == 0xD8 && auxType == 0x8001) {
            return decodeHyperStudio(data)
        }

        if let fork = resourceFork, !fork.isEmpty {
            let sounds = decodeSoundResources(fork)
            if !sounds.isEmpty { return .samples(sounds) }
        }

        if fileType == 0xD8 && auxType == 0x0004 {
            return .unsupported("MIDI Synth wave banks can't be played yet.")
        }
        if fileType == 0xD8 && auxType == 0x0003 {
            return .unsupported("This sound resource file has no sound resources.")
        }
        return .unsupported("This sound format can't be played yet.")
    }

    // MARK: - SoundSmith

    static func decodeSoundSmith(_ data: Data, name: String, companions: [String: Data]) -> SoundDocument {
        guard let song = SoundSmithRenderer.parseSong(data) else {
            return .unsupported("This SoundSmith song is damaged or incomplete.")
        }
        let bank: SoundSmithRenderer.Wavebank
        let source: String
        if let (bankName, bankData) = SoundSmithRenderer.findWavebank(forSong: name, in: companions) {
            guard let parsed = SoundSmithRenderer.parseWavebank(bankData) else {
                return .unsupported("The wave bank \(bankName) can't be read.")
            }
            bank = parsed
            // A bank not named after the song is a best guess from the folder
            let guessed = bankName.hasPrefix(name.uppercased() + ".") ? "" : " (picked by its contents)"
            source = "wave bank \(bankName)\(guessed), \(parsed.instruments.count) instruments"
        } else if let built = SoundSmithRenderer.buildWavebank(for: song, from: companions) {
            // SoundSmith 1.0 style: one ASIF instrument file per instrument, named in the song
            bank = built.bank
            let used = song.instrumentNames.filter { !$0.isEmpty }.count - built.missing.count
            source = "\(used) ASIF instrument files" + (built.missing.isEmpty ? "" : ", missing: \(built.missing.joined(separator: ", "))")
        } else {
            return .unsupported("This SoundSmith song needs its wave bank (usually \(name).W) or its instrument files in the same folder.")
        }
        let (left, right) = SoundSmithRenderer.render(song: song, bank: bank)
        guard !left.isEmpty else { return .unsupported("This SoundSmith song has no notes.") }
        let cut = Double(left.count) >= SoundSmithRenderer.maxSeconds * SoundSmithRenderer.docRate - 1 ? ", first 10 minutes" : ""
        return .samples([DecodedSound(name: name, samples: left, right: right, sampleRate: SoundSmithRenderer.docRate,
                                      detail: "SoundSmith song with \(source)\(cut)")])
    }

    // MARK: - 8-bit DOC samples

    /// Converts unsigned 8-bit DOC samples ($80 = silence). A $00 byte stops the
    /// Ensoniq oscillator, so playback ends there like it does on the real machine.
    static func pcm(fromDOC bytes: Data) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(bytes.count)
        for b in bytes {
            if b == 0 { break }
            out.append((Float(b) - 128) / 128)
        }
        return out
    }

    // MARK: - Resource forks and rSoundSample

    struct Resource: Sendable {
        let type: UInt16
        let id: UInt32
        let data: Data
    }

    /// Lists the resources in an Apple IIgs resource fork
    static func resources(in fork: Data) -> [Resource] {
        guard fork.count >= 140, le32(fork, 0) == 0 else { return [] }
        let map = Int(le32(fork, 4))
        guard map + 0x20 <= fork.count else { return [] }
        let toIndex = Int(le16(fork, map + 0x0E))
        let used = Int(le32(fork, map + 0x18))
        var result: [Resource] = []
        var rec = map + toIndex
        for _ in 0..<min(used, 10_000) {
            guard rec + 20 <= fork.count else { break }
            let type = le16(fork, rec)
            if type == 0 { break }
            let id = le32(fork, rec + 2)
            let offset = Int(le32(fork, rec + 6))
            let size = Int(le32(fork, rec + 12))
            if offset >= 0, size >= 0, offset + size <= fork.count {
                result.append(Resource(type: type, id: id, data: fork.subdata(in: offset..<offset + size)))
            }
            rec += 20
        }
        return result
    }

    /// Resource names come from the rResName ($8014) resource whose ID is $0001_xxxx for type xxxx
    static func resourceNames(in resources: [Resource], type: UInt16) -> [UInt32: String] {
        guard let table = resources.first(where: { $0.type == 0x8014 && $0.id == (0x0001_0000 | UInt32(type)) })?.data,
              table.count >= 6 else { return [:] }
        var names: [UInt32: String] = [:]
        let count = Int(le32(table, 2))
        var p = 6
        for _ in 0..<min(count, 10_000) {
            guard p + 5 <= table.count else { break }
            let id = le32(table, p)
            let len = Int(table[table.startIndex + p + 4])
            guard p + 5 + len <= table.count else { break }
            let s = table.subdata(in: table.startIndex + p + 5..<table.startIndex + p + 5 + len)
            names[id] = String(data: s, encoding: .macOSRoman) ?? ""
            p += 5 + len
        }
        return names
    }

    static func decodeSoundResources(_ fork: Data) -> [DecodedSound] {
        let all = resources(in: fork)
        let names = resourceNames(in: all, type: 0x8024)
        return all.filter { $0.type == 0x8024 && $0.data.count > 10 }.compactMap { res in
            let d = res.data
            var rate = Double(le16(d, 8))
            if rate < 1000 { rate = 22050 }  // missing rate: a typical IIgs default
            let samples = pcm(fromDOC: d.subdata(in: d.startIndex + 10..<d.endIndex))
            guard !samples.isEmpty else { return nil }
            let name = names[res.id].flatMap { $0.isEmpty ? nil : $0 } ?? String(format: "Sound $%04X", res.id)
            return DecodedSound(name: name, samples: samples, sampleRate: rate,
                                detail: "rSound resource, 8-bit, \(Int(rate)) Hz")
        }
    }

    // MARK: - HyperStudio

    /// HyperStudio sounds. Files from Sound Shop 1.6 replace the "SSHS" ID block with
    /// the sound's name but keep the same fields from offset 24 on.
    static func decodeHyperStudio(_ data: Data) -> SoundDocument {
        guard data.count > 64 else { return .unsupported("This HyperStudio sound is empty.") }
        let pages = Int(le16(data, 24))
        let ace = le16(data, 26) >> 14
        let rateCode = Double(le16(data, 28))
        if ace != 0 {
            return .unsupported("This HyperStudio sound is ACE-compressed, which isn't supported yet.")
        }
        let rate = (rateCode + 40) * 51.40625
        let end = pages > 0 && 64 + pages * 256 <= data.count ? 64 + pages * 256 : data.count
        let samples = pcm(fromDOC: data.subdata(in: data.startIndex + 64..<data.startIndex + end))
        guard !samples.isEmpty else { return .unsupported("This HyperStudio sound has no samples.") }
        let source = hasPrefix(data, "SSHS") ? "HyperStudio sound" : "HyperStudio sound (Sound Shop)"
        return .samples([DecodedSound(name: "Sound", samples: samples, sampleRate: rate,
                                      detail: "\(source), 8-bit, \(Int(rate.rounded())) Hz")])
    }

    // MARK: - ASIF instruments

    /// Plays each waveform in the ASIF WAVE chunks
    static func decodeASIF(_ data: Data) -> [DecodedSound] {
        var sounds: [DecodedSound] = []
        var p = 12
        while p + 8 <= data.count {
            let id = String(data: data.subdata(in: data.startIndex + p..<data.startIndex + p + 4), encoding: .ascii) ?? ""
            // Some files (NoiseTracker GS) store a chunk size past the end of the file
            let body = p + 8
            let size = min(Int(be32(data, p + 4)), data.count - body)
            if id == "WAVE" {
                sounds += decodeASIFWave(data, chunk: body, size: size)
            }
            p = body + size + (size & 1)
        }
        return sounds
    }

    private static func decodeASIFWave(_ data: Data, chunk: Int, size: Int) -> [DecodedSound] {
        let end = chunk + size
        guard chunk < end else { return [] }
        let nameLen = Int(data[data.startIndex + chunk])
        // Names are often padded with leftover bytes, so keep only the printable start
        let nameBytes = data.subdata(in: data.startIndex + chunk + 1..<data.startIndex + min(end, chunk + 1 + nameLen))
        let name = (String(data: Data(nameBytes.prefix { $0 >= 0x20 && $0 < 0x7F }), encoding: .ascii) ?? "")
            .trimmingCharacters(in: .whitespaces)
        var q = chunk + 1 + nameLen
        guard q + 4 <= end else { return [] }
        let waveSize = Int(le16(data, q)) + 1
        let numSamples = Int(le16(data, q + 2))
        q += 4
        let tableEnd = q + numSamples * 12
        let waveStart = tableEnd
        guard tableEnd <= end else { return [] }
        let waveData = data.subdata(in: data.startIndex + waveStart..<data.startIndex + min(end, waveStart + waveSize))

        // Use the first sample's recorded rate when present; otherwise play at the
        // DOC's usual 26.32 kHz output rate (32 oscillators)
        var rate = 26320.0
        if numSamples > 0 {
            let r = Double(le32(data, q + 8)) / 65536
            if r >= 1000 && r <= 64000 { rate = r }
        }
        let samples = pcm(fromDOC: waveData)
        guard !samples.isEmpty else { return [] }
        return [DecodedSound(name: name.isEmpty ? "Wave" : name, samples: samples, sampleRate: rate,
                             detail: "ASIF instrument wave, 8-bit, \(Int(rate.rounded())) Hz, \(numSamples) sample(s)")]
    }

    // MARK: - Helpers

    static func iffType(_ data: Data) -> String? {
        guard data.count >= 12, hasPrefix(data, "FORM") else { return nil }
        return String(data: data.subdata(in: data.startIndex + 8..<data.startIndex + 12), encoding: .ascii)
    }

    static func hasPrefix(_ data: Data, _ s: String) -> Bool {
        let bytes = Array(s.utf8)
        return data.count >= bytes.count && data.prefix(bytes.count).elementsEqual(bytes)
    }

    static func le16(_ d: Data, _ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= d.count else { return 0 }
        let i = d.startIndex + o
        return UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }

    static func le32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(le16(d, o)) | UInt32(le16(d, o + 2)) << 16
    }

    static func be32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        let i = d.startIndex + o
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
}
